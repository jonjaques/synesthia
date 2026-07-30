import AppKit
import Combine
import CoreAudio
import SwiftUI

/// How long the cursor may sit still before the foreground UI fades away.
private let chromeIdleDelay: Duration = .seconds(3)

/// Smallest window the chrome can lay out in without clipping: the transport pod
/// is the widest indivisible element.
let minimumContentSize = CGSize(width: 460, height: 380)

/// Every pod along the bottom is exactly this tall. The three used to size
/// themselves from their own contents, which left the badge, the transport and
/// the visualizer controls at three unrelated heights — bottom-aligned but
/// visibly ragged in the wide layout, and three different silhouettes when
/// stacked. One height makes them read as a single band. It is set by the
/// badge, the only pod carrying two lines of text next to artwork.
let chromePodHeight: CGFloat = 56

/// How the three bottom pods arrange themselves, chosen from the viewport width.
enum ChromeLayout {
    /// Now playing leading, transport centered, visualizer trailing — one row.
    case wide
    /// Now playing on its own row above transport + visualizer.
    case medium
    /// Every pod on its own centered row.
    case compact

    init(width: CGFloat) {
        // Thresholds are the measured widths of the pods plus breathing room:
        // transport ≈ 360, visualizer ≈ 240, a legible badge ≈ 260.
        if width >= 940 {
            self = .wide
        } else if width >= 680 {
            self = .medium
        } else {
            self = .compact
        }
    }
}

/// The window's entire content: the Metal canvas edge to edge, with floating
/// "chrome" layered on top — a status banner and title capsule at the top,
/// and three glass pods at the bottom (now-playing badge, transport,
/// visualizer controls). The chrome fades out after 3 s of pointer stillness
/// and reappears on movement, like a video player's controls.
struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var chromeVisible = true
    @State private var hideChromeTask: Task<Void, Never>?
    @State private var pointerOverControls = false
    @State private var pointerOverVisualizer = false
    @State private var optionsShown = false
    @State private var viewportWidth: CGFloat = 1100

    private var layout: ChromeLayout { ChromeLayout(width: viewportWidth) }

    /// The chrome can't fade out from under an interaction: pointer resting on
    /// one of the pods, or the options popover open.
    private var chromePinned: Bool {
        pointerOverControls || pointerOverVisualizer || optionsShown
    }

    var body: some View {
        @Bindable var state = appState

        ZStack(alignment: .bottom) {
            // No Metal device (most plausibly a VM) means no canvas — say so
            // rather than crashing. See MetalRenderContext.
            if let context = MetalRenderContext.shared {
                MetalVisualizerView(appState: appState, context: context)
                    .ignoresSafeArea()
            } else {
                MetalUnavailableView()
                    .ignoresSafeArea()
            }

            VStack(spacing: 8) {
                if let message = appState.statusMessage {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.yellow)
                            .accessibilityHidden(true)
                        Text(message)
                            .font(.callout)
                    }
                    .chromeForeground()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: 520)
                    .chromeGlass(in: .rect(cornerRadius: 18))
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                // The window has no title bar text any more, so sources without
                // a now-playing badge get their name here instead.
                if appState.nowPlaying == nil, appState.windowTitle != "Synesthia" {
                    Text(appState.windowTitle)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .chromeGlass(in: .capsule)
                        .padding(.top, appState.statusMessage == nil ? 12 : 0)
                        .opacity(chromeVisible ? 1 : 0)
                        .animation(.easeInOut(duration: 0.35), value: chromeVisible)
                }
                Spacer()
            }

            // The canvas can't come alive without the permission, so the call
            // to action sits centered where the visuals would be — and stays
            // put while the rest of the chrome fades.
            if let blocked = appState.blockedPermission {
                PermissionCard(permission: blocked)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }

            bottomChrome
                .opacity(chromeVisible ? 1 : 0)
                .allowsHitTesting(chromeVisible)
                .animation(.easeInOut(duration: 0.35), value: chromeVisible)
        }
        .animation(.easeInOut(duration: 0.25), value: appState.statusMessage)
        .animation(.easeOut(duration: 0.2), value: appState.blockedPermission)
        .background(Color.black)
        .background(ChromelessWindow())
        .frame(minWidth: minimumContentSize.width, minHeight: minimumContentSize.height)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            viewportWidth = $0
        }
        .navigationTitle(appState.windowTitle)
        .preferredColorScheme(.dark)
        .onContinuousHover { phase in
            // Only fires on actual pointer movement, so a still cursor lets the
            // idle timer run out.
            if case .active = phase { showChromeTemporarily() }
        }
        .onChange(of: chromePinned) { _, pinned in
            if pinned {
                hideChromeTask?.cancel()
                chromeVisible = true
            } else {
                showChromeTemporarily()
            }
        }
        .onAppear {
            appState.onAppear()
            showChromeTemporarily()
        }
        // Re-activation is the moment a user comes back from System Settings,
        // so it's when cached permission state is most likely stale.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) {
            _ in
            appState.handleAppActivation()
        }
        .sheet(isPresented: $state.showsWelcome) {
            WelcomeView()
                .environment(appState)
        }
    }

    /// Arranges the three pods for the current width: side by side while there is
    /// room, then progressively stacked so they never overlap.
    @ViewBuilder
    private var bottomChrome: some View {
        Group {
            switch layout {
            case .wide:
                // Transport stays optically centered in the window, the other two
                // pods hug the edges around it.
                ZStack(alignment: .bottom) {
                    HStack(alignment: .bottom, spacing: 12) {
                        badge
                        Spacer(minLength: 0)
                        visualizerPod
                    }
                    controlsPod
                }
            case .medium:
                VStack(alignment: .leading, spacing: 10) {
                    badge
                    HStack(alignment: .bottom, spacing: 12) {
                        controlsPod
                        Spacer(minLength: 0)
                        visualizerPod
                    }
                }
            case .compact:
                VStack(spacing: 10) {
                    badge
                    controlsPod
                    visualizerPod
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
    }

    @ViewBuilder
    private var badge: some View {
        if let info = appState.nowPlaying {
            NowPlayingBadge(info: info, compact: layout == .compact)
                .frame(maxWidth: badgeMaxWidth, alignment: .leading)
        }
    }

    private var controlsPod: some View {
        ControlsPod()
            .onHover { pointerOverControls = $0 }
    }

    private var visualizerPod: some View {
        VisualizerPod(optionsShown: $optionsShown)
            .onHover { pointerOverVisualizer = $0 }
    }

    /// Keeps the badge clear of the centered transport pod in the wide layout,
    /// and merely readable in the others. Never `.infinity`: a full-width frame
    /// pins the badge to the leading edge while the pods below it center, which
    /// is exactly the lopsidedness the compact layout is trying to avoid. A
    /// finite cap lets the frame shrink to the badge and the stack center it.
    private var badgeMaxWidth: CGFloat {
        switch layout {
        case .wide: max(220, (viewportWidth - 400) / 2 - 28)
        case .medium: 420
        case .compact: max(240, viewportWidth - 40)
        }
    }

    private func showChromeTemporarily() {
        chromeVisible = true
        hideChromeTask?.cancel()
        // Fading the controls out on pointer idle is right for a mouse and
        // actively hostile to anyone driving the app by keyboard or switch —
        // they never generate the pointer movement that brings it back. With
        // VoiceOver running, the chrome simply stays put.
        guard !chromePinned, !NSWorkspace.shared.isVoiceOverEnabled else { return }
        hideChromeTask = Task {
            try? await Task.sleep(for: chromeIdleDelay)
            if !Task.isCancelled && !chromePinned {
                chromeVisible = false
            }
        }
    }
}

// MARK: - Hit targets

extension View {
    /// Grows a control's clickable area without changing what the layout sees:
    /// pad out, claim the padded rect for hit testing, then pad back in by the
    /// same amount. SF Symbols hit-test to their tight glyph box otherwise, so
    /// the icon buttons demand pixel-accurate aim.
    ///
    /// Keep `horizontal` below half the row spacing so neighbours don't overlap.
    func hitTarget(horizontal: CGFloat = 6, vertical: CGFloat = 10) -> some View {
        padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .contentShape(.rect)
            .padding(.horizontal, -horizontal)
            .padding(.vertical, -vertical)
    }
}

// MARK: - Chrome vocabulary

extension View {
    /// The foreground treatment every pod's contents share. The shadow is
    /// invisible against the dark material and does the work when a bright
    /// frame pushes the glass light — white-on-glass over an arbitrary moving
    /// canvas has no guaranteed contrast otherwise. Apply it *inside*
    /// `chromeGlass`, or the shadow lands on the capsule instead of the glyphs.
    func chromeForeground() -> some View {
        foregroundStyle(.white)
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
    }
}

/// Leading symbol plus name, shared by the source menu and the visualizer menu
/// so the two pods carry identical weight. The symbol is a step dimmer than the
/// name and a step heavier than its default, which reads as more present than
/// the old full-white regular glyph while leaving the word as the emphasis.
private struct PodMenuLabel: View {
    let symbol: String
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))
                .frame(width: 17)
            Text(title)
                .font(.callout.weight(.semibold))
        }
        .hitTarget(horizontal: 4, vertical: 10)
    }
}

/// The hairline between groups inside a pod. A plain `Divider()` picks up the
/// system separator colour, which over glass reads as a hard dark scratch;
/// this is a soft white rule at the height of the icon buttons beside it.
private struct PodDivider: View {
    var body: some View {
        Capsule()
            .fill(.white.opacity(0.18))
            .frame(width: 1, height: 20)
            .padding(.horizontal, 2)
    }
}

/// Shared look for the glyph buttons in the bottom pods: a uniform circular hit
/// target, a semibold glyph, and a soft disc on hover and press. The fixed
/// frame is what keeps previous/next, options and fullscreen optically
/// identical across two pods that don't otherwise know about each other — and
/// it replaces `hitTarget`, which grew the tap area without making the buttons
/// look like peers.
///
/// `prominent` is the transport's play/pause: already a filled disc, so it
/// takes no hover backing and stays at full white while its neighbours sit
/// back at 78%.
struct ChromeIconButtonStyle: ButtonStyle {
    var size: CGFloat = 15
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        Glyph(configuration: configuration, size: size, prominent: prominent)
    }

    private struct Glyph: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        let prominent: Bool
        @State private var hovering = false

        var body: some View {
            let diameter = prominent ? size + 6 : 32

            configuration.label
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white.opacity(prominent || hovering ? 1 : 0.78))
                .frame(width: diameter, height: diameter)
                .background {
                    if !prominent {
                        Circle()
                            .fill(.white.opacity(configuration.isPressed ? 0.18 : hovering ? 0.1 : 0))
                    }
                }
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .contentShape(.circle)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        }
    }
}

// MARK: - Chrome material

extension View {
    /// The background shared by every floating pod. On macOS 26 this is real
    /// Liquid Glass; on macOS 15 it degrades to a shaped material with a
    /// hairline edge and a drop shadow, which is the same job the glass does —
    /// separate the chrome from an arbitrary, moving Metal canvas behind it.
    ///
    /// `interactive` maps to `Glass.interactive()`, the highlight-on-press
    /// variant used by the two pods that contain controls. It has no pre-26
    /// equivalent and is simply ignored there.
    func chromeGlass<S: InsettableShape>(in shape: S, interactive: Bool = false) -> some View {
        modifier(ChromeGlass(shape: shape, interactive: interactive))
    }
}

private struct ChromeGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay { shape.strokeBorder(.white.opacity(0.14), lineWidth: 1) }
                .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
        }
    }
}

// MARK: - Permission card

/// Centered over a canvas that can't come alive because a macOS privacy
/// permission is missing. Replaces what used to be a yellow one-line banner:
/// it names the permission, restates what granting it buys, and offers the
/// fix. `AppState.handleAppActivation` clears it automatically when the user
/// returns from System Settings with the box ticked.
struct PermissionCard: View {
    @Environment(AppState.self) private var appState
    let permission: PrivacyPermission

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: permission.symbol)
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.bottom, 6)
                .accessibilityHidden(true)
            title
                .font(.title3.weight(.semibold))
            Text(permission.explanation)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Open System Settings…") {
                    appState.openPermissionSettings(permission)
                }
                .buttonStyle(.borderedProminent)
                Button("Try Again") {
                    appState.retryBlockedSource()
                }
            }
            .padding(.top, 12)
        }
        .chromeForeground()
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .frame(width: 430)
        .chromeGlass(in: .rect(cornerRadius: 24))
    }

    private var title: Text {
        switch permission {
        case .screenAndSystemAudio: Text("Allow System Audio Capture")
        case .automation: Text("Allow Control of Music")
        case .microphone: Text("Allow Microphone Access")
        }
    }
}

// MARK: - Now playing badge

struct NowPlayingBadge: View {
    let info: NowPlayingInfo
    /// Drops the album from the subtitle when horizontal room is tight.
    var compact = false

    /// The badge's own corner, and the inset its artwork sits at. The artwork's
    /// radius is the difference between them, so the two curves stay concentric
    /// — the same rule the system uses for anything nested in a rounded window.
    private static let cornerRadius: CGFloat = 16
    private static let inset: CGFloat = 6

    private var artSize: CGFloat { chromePodHeight - Self.inset * 2 }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let artwork = info.artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Rectangle().fill(.white.opacity(0.08))
                        Image(systemName: "music.note")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
            }
            .frame(width: artSize, height: artSize)
            .clipShape(.rect(cornerRadius: Self.cornerRadius - Self.inset))

            VStack(alignment: .leading, spacing: 1) {
                Text(info.title)
                    .font(.headline)
                subtitle
            }
            .lineLimit(1)
            .padding(.trailing, 6)
        }
        .chromeForeground()
        .padding(Self.inset)
        .frame(height: chromePodHeight)
        .chromeGlass(in: .rect(cornerRadius: Self.cornerRadius))
    }

    /// Artist and album share one line — three stacked lines no longer fit the
    /// shared pod height, and a dimmer album beside the artist gives the badge
    /// the same two-step hierarchy the pods have.
    @ViewBuilder
    private var subtitle: some View {
        HStack(spacing: 5) {
            if !info.artist.isEmpty {
                Text(info.artist)
                    .foregroundStyle(.white.opacity(0.82))
                    .layoutPriority(1)
            }
            if !compact, !info.album.isEmpty {
                if !info.artist.isEmpty {
                    Text(verbatim: "·").foregroundStyle(.white.opacity(0.4))
                }
                Text(info.album).foregroundStyle(.white.opacity(0.55))
            }
        }
        .font(.subheadline)
    }
}

// MARK: - Source, capture and transport (centered)

/// The main control pod: audio-source menu (with per-source extras like the
/// input-device picker), the capture button, and — for sources that can be
/// driven — previous/play/next transport buttons.
struct ControlsPod: View {
    @Environment(AppState.self) private var appState

    /// The selectable sources whose permission is granted (or unneeded),
    /// plus whatever is active right now — the demo, or a source whose
    /// permission was just revoked — so the checkmark always has a row.
    private var pickerSources: [AudioSourceKind] {
        var kinds = AudioSourceKind.selectable.filter { appState.isSourceAvailable($0) }
        if !kinds.contains(appState.sourceKind) {
            kinds.insert(appState.sourceKind, at: 0)
        }
        return kinds
    }

    /// Sources that need a permission the user hasn't granted, shown disabled.
    private var lockedSources: [AudioSourceKind] {
        AudioSourceKind.selectable.filter {
            !appState.isSourceAvailable($0) && $0 != appState.sourceKind
        }
    }

    var body: some View {
        @Bindable var state = appState

        HStack(spacing: 8) {
            Menu {
                Picker("Audio Source", selection: $state.sourceKind) {
                    ForEach(pickerSources) { kind in
                        Label(kind.label, systemImage: kind.symbol).tag(kind)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()

                if !lockedSources.isEmpty {
                    Section("Needs Permission") {
                        ForEach(lockedSources) { kind in
                            Button {
                            } label: {
                                Label(kind.label, systemImage: kind.symbol)
                            }
                            .disabled(true)
                        }
                        Button("Grant Access…") { appState.showWelcome() }
                    }
                }

                if state.sourceKind == .inputDevice {
                    Divider()
                    Picker("Input Device", selection: $state.selectedInputDeviceID) {
                        Text("Default input").tag(AudioDeviceID?.none)
                        ForEach(appState.inputDevices) { device in
                            Text(device.name).tag(AudioDeviceID?.some(device.id))
                        }
                    }
                }
                if state.sourceKind == .audioFile {
                    Divider()
                    Button("Choose File…") { appState.openFilePanel() }
                }
            } label: {
                PodMenuLabel(symbol: appState.sourceKind.symbol, title: appState.sourceKind.label)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            PodDivider()

            CaptureButton()

            if appState.showsTransport {
                PodDivider()

                Button {
                    appState.previousTrack()
                } label: {
                    Image(systemName: "backward.fill")
                }
                .buttonStyle(ChromeIconButtonStyle())
                .help("Previous track")
                .accessibilityLabel("Previous track")

                Button {
                    appState.togglePlay()
                } label: {
                    Image(systemName: appState.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(ChromeIconButtonStyle(size: 32, prominent: true))
                .help(appState.isPlaying ? "Pause" : "Play")
                .accessibilityLabel(appState.isPlaying ? "Pause" : "Play")

                Button {
                    appState.nextTrack()
                } label: {
                    Image(systemName: "forward.fill")
                }
                .buttonStyle(ChromeIconButtonStyle())
                .help("Next track")
                .accessibilityLabel("Next track")
            }
        }
        .chromeForeground()
        .padding(.horizontal, 14)
        .frame(height: chromePodHeight)
        .chromeGlass(in: .capsule, interactive: true)
    }
}

/// Starts and stops the audio feeding the analyzer, separate from transport.
struct CaptureButton: View {
    @Environment(AppState.self) private var appState

    /// The purple of macOS's menu-bar audio-capture pill (#7163FF). Not a
    /// built-in system color — the closest, `.systemIndigo` (#5856D6), is
    /// visibly darker — so it's hardcoded.
    private static let captureTint = Color(red: 0x71 / 255.0, green: 0x63 / 255.0, blue: 0xFF / 255.0)

    var body: some View {
        let active = appState.isCaptureActive

        Button {
            appState.toggleCapture()
        } label: {
            Image(systemName: symbol)
                // Active: white glyph inside a purple disc, like the menu bar chip.
                .symbolRenderingMode(active ? .palette : .monochrome)
                // Applied inside the label so it wins over the button style's
                // own dimming — capture is a primary action and stays lit.
                .foregroundStyle(.white, Self.captureTint)
                .shadow(color: Self.captureTint.opacity(active ? 0.7 : 0), radius: 6)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(ChromeIconButtonStyle(size: 24, prominent: true))
        .animation(.easeInOut(duration: 0.2), value: active)
        .help(helpText)
        .accessibilityLabel(helpText)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var symbol: String {
        if appState.sourceKind == .audioFile {
            return appState.isCaptureActive ? "pause.circle.fill" : "play.circle.fill"
        }
        return appState.isCaptureActive ? "waveform.circle.fill" : "waveform.circle"
    }

    private var helpText: String {
        switch appState.sourceKind {
        case .audioFile:
            return appState.isCaptureActive ? "Pause file" : "Play file"
        default:
            return appState.isCaptureActive ? "Stop listening" : "Start listening"
        }
    }
}

// MARK: - Visualizer pod (trailing)

/// Visualizer picker, options-popover button, and fullscreen toggle.
struct VisualizerPod: View {
    @Environment(AppState.self) private var appState
    /// Owned by ContentView so the chrome stays up while the popover is open.
    @Binding var optionsShown: Bool
    /// Only so the toggle can show the direction it will move in. Read once on
    /// appear because the window may already be fullscreen when the pod is built.
    @State private var isFullScreen = false

    var body: some View {
        @Bindable var state = appState

        HStack(spacing: 8) {
            Menu {
                Picker("Visualizer", selection: $state.visualizerID) {
                    ForEach(VisualizerRegistry.all) { descriptor in
                        Text(descriptor.name).tag(descriptor.id)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                PodMenuLabel(symbol: "sparkles", title: currentVisualizerName)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            PodDivider()

            Button {
                optionsShown.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(ChromeIconButtonStyle())
            .help("Visualizer options")
            .accessibilityLabel("Visualizer options")
            .popover(isPresented: $optionsShown, arrowEdge: .top) {
                OptionsPanel()
            }

            Button {
                NSApp.keyWindow?.toggleFullScreen(nil)
            } label: {
                Image(
                    systemName: isFullScreen
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right"
                )
                .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(ChromeIconButtonStyle())
            .help(isFullScreen ? "Exit full screen" : "Enter full screen")
            .accessibilityLabel(isFullScreen ? "Exit full screen" : "Enter full screen")
        }
        .chromeForeground()
        .padding(.horizontal, 14)
        .frame(height: chromePodHeight)
        .chromeGlass(in: .capsule, interactive: true)
        .onAppear {
            isFullScreen = NSApp.keyWindow?.styleMask.contains(.fullScreen) ?? false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isFullScreen = false
        }
    }

    private var currentVisualizerName: String {
        VisualizerRegistry.descriptor(id: appState.visualizerID)?.name ?? "Visualizer"
    }
}

// MARK: - Options panel

/// The popover for tuning the current visualizer: palette swatches, the
/// shared Sensitivity/Speed sliders, and whatever options the visualizer's
/// descriptor declares — the UI is generated from the descriptor, so new
/// visualizers get their controls for free.
struct OptionsPanel: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let settings = appState.settings
        let descriptor = VisualizerRegistry.descriptor(id: appState.visualizerID)

        VStack(alignment: .leading, spacing: 0) {
            if let descriptor {
                header(descriptor, settings: settings)

                Divider()

                VStack(alignment: .leading, spacing: 20) {
                    OptionSection("Palette") {
                        PalettePicker(selection: settings.binding(descriptor.id, \.paletteIndex))
                    }

                    OptionSection("Audio Response") {
                        LabeledSlider(
                            name: "Sensitivity",
                            value: settings.binding(descriptor.id, \.sensitivity),
                            range: 0.2...3.0,
                            defaultValue: 1.0)
                        LabeledSlider(
                            name: "Speed",
                            value: settings.binding(descriptor.id, \.speed),
                            range: 0.2...3.0,
                            defaultValue: 1.0)
                    }

                    if !descriptor.options.isEmpty {
                        OptionSection("\(descriptor.name) Options") {
                            ForEach(descriptor.options) { option in
                                switch option.kind {
                                case .slider:
                                    LabeledSlider(
                                        name: option.name,
                                        value: settings.binding(descriptor.id, option: option),
                                        range: option.range,
                                        defaultValue: option.defaultValue)
                                case .toggle:
                                    LabeledToggle(
                                        name: option.name,
                                        isOn: settings.binding(descriptor.id, toggle: option))
                                }
                            }
                        }
                    }
                }
                .padding(18)
            }
        }
        .frame(width: 340)
    }

    /// Name, tagline, and the reset that only applies to this visualizer.
    private func header(_ descriptor: VisualizerDescriptor, settings: VisualizerSettings) -> some View {
        let isDefault = settings.isDefault(descriptor)

        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(descriptor.name)
                    .font(.headline)
                Text(descriptor.tagline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { settings.reset(descriptor) }
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .hitTarget(horizontal: 8, vertical: 8)
            }
            .buttonStyle(.borderless)
            .disabled(isDefault)
            .help(isDefault ? "Already at defaults" : "Reset \(descriptor.name) to defaults")
            .accessibilityLabel(isDefault ? "Already at defaults" : "Reset \(descriptor.name) to defaults")
        }
        .padding(18)
    }
}

/// Small caption-headed group used throughout the options popover.
struct OptionSection<Content: View>: View {
    private let title: String
    private let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content
        }
    }
}

/// Horizontal row of gradient swatches, one per palette, each labelled.
struct PalettePicker: View {
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(Palettes.names.enumerated()), id: \.offset) { index, name in
                let isSelected = selection == index
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { selection = index }
                } label: {
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(gradient(for: index))
                            .frame(height: 26)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(
                                        isSelected ? Color.white : .white.opacity(0.15),
                                        lineWidth: isSelected ? 2 : 1)
                            }
                        Text(name)
                            .font(.system(size: 9))
                            .foregroundStyle(isSelected ? .primary : .secondary)
                            .lineLimit(1)
                    }
                    // The label and the gap between it and the swatch count too.
                    .hitTarget(horizontal: 3, vertical: 4)
                }
                .buttonStyle(.plain)
                .help(name)
                .accessibilityLabel("\(name) palette")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    private func gradient(for palette: Int) -> LinearGradient {
        let stops = (0..<6).map { i -> Color in
            let c = Palettes.color(Float(i) / 5.0, palette: palette)
            return Color(
                red: Double(max(0, min(1, c.x))),
                green: Double(max(0, min(1, c.y))),
                blue: Double(max(0, min(1, c.z))))
        }
        return LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing)
    }
}

struct LabeledSlider: View {
    let name: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// When given, the row offers a one-click revert once it's been moved.
    var defaultValue: Double?

    private var isModified: Bool {
        guard let defaultValue else { return false }
        return abs(value - defaultValue) > 0.005
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(name).font(.caption)
                Spacer(minLength: 4)
                if isModified, let defaultValue {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { value = defaultValue }
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 9))
                            .hitTarget(horizontal: 8, vertical: 8)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Reset to default")
                    .accessibilityLabel("Reset \(name) to default")
                    .transition(.opacity)
                }
                Text(value, format: .number.precision(.fractionLength(2)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isModified ? .primary : .secondary)
            }
            Slider(value: $value, in: range)
        }
    }
}

/// The switch counterpart of `LabeledSlider`, for options that are on or off.
/// No per-row revert: flipping it back is already one click.
struct LabeledToggle: View {
    let name: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(name).font(.caption)
            Spacer(minLength: 4)
            Toggle(name, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(name)
        }
    }
}
