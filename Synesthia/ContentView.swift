import SwiftUI
import AppKit
import CoreAudio

/// How long the cursor may sit still before the foreground UI fades away.
private let chromeIdleDelay: Duration = .seconds(3)

/// Smallest window the chrome can lay out in without clipping: the transport pod
/// is the widest indivisible element.
let minimumContentSize = CGSize(width: 460, height: 380)

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
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glassEffect(.regular, in: .capsule)
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
                        .glassEffect(.regular, in: .capsule)
                        .padding(.top, appState.statusMessage == nil ? 12 : 0)
                        .opacity(chromeVisible ? 1 : 0)
                        .animation(.easeInOut(duration: 0.35), value: chromeVisible)
                }
                Spacer()
            }

            bottomChrome
                .opacity(chromeVisible ? 1 : 0)
                .allowsHitTesting(chromeVisible)
                .animation(.easeInOut(duration: 0.35), value: chromeVisible)
        }
        .background(Color.black)
        .background(ChromelessWindow())
        .frame(minWidth: minimumContentSize.width, minHeight: minimumContentSize.height)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
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
    /// and merely readable in the others.
    private var badgeMaxWidth: CGFloat {
        switch layout {
        case .wide: max(220, (viewportWidth - 400) / 2 - 28)
        case .medium: 420
        case .compact: .infinity
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

// MARK: - Now playing badge

struct NowPlayingBadge: View {
    let info: NowPlayingInfo
    /// Drops the album line and shrinks the artwork when vertical room is tight.
    var compact = false

    private var artSize: CGFloat { compact ? 40 : 52 }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let artwork = info.artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Rectangle().fill(.white.opacity(0.08))
                        Image(systemName: "music.note")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            .frame(width: artSize, height: artSize)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(info.title)
                    .font(.headline)
                if !info.artist.isEmpty {
                    Text(info.artist)
                        .font(.subheadline)
                        .opacity(0.85)
                }
                if !compact, !info.album.isEmpty {
                    Text(info.album)
                        .font(.caption)
                        .opacity(0.6)
                }
            }
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.trailing, 6)
        }
        .padding(8)
        .fixedSize(horizontal: false, vertical: true)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}

// MARK: - Source, capture and transport (centered)

/// The main control pod: audio-source menu (with per-source extras like the
/// input-device picker), the capture button, and — for sources that can be
/// driven — previous/play/next transport buttons.
struct ControlsPod: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        HStack(spacing: 14) {
            Menu {
                Picker("Audio Source", selection: $state.sourceKind) {
                    ForEach(AudioSourceKind.allCases) { kind in
                        Label(kind.label, systemImage: kind.symbol).tag(kind)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()

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
                Label(appState.sourceKind.label, systemImage: appState.sourceKind.symbol)
                    .hitTarget(horizontal: 4, vertical: 10)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Divider().frame(height: 20)

            CaptureButton()

            if appState.showsTransport {
                Divider().frame(height: 20)

                Button {
                    appState.previousTrack()
                } label: {
                    Image(systemName: "backward.fill")
                        .hitTarget()
                }
                .buttonStyle(.plain)
                .help("Previous track")
                .accessibilityLabel("Previous track")

                Button {
                    appState.togglePlay()
                } label: {
                    Image(systemName: appState.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 34))
                        .hitTarget(horizontal: 6, vertical: 4)
                }
                .buttonStyle(.plain)
                .help(appState.isPlaying ? "Pause" : "Play")
                .accessibilityLabel(appState.isPlaying ? "Pause" : "Play")

                Button {
                    appState.nextTrack()
                } label: {
                    Image(systemName: "forward.fill")
                        .hitTarget()
                }
                .buttonStyle(.plain)
                .help("Next track")
                .accessibilityLabel("Next track")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .glassEffect(.regular.interactive(), in: .capsule)
        .foregroundStyle(.white)
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
                .font(.system(size: 22))
                // Active: white glyph inside a purple disc, like the menu bar chip.
                .symbolRenderingMode(active ? .palette : .monochrome)
                .foregroundStyle(.white, Self.captureTint)
                .shadow(color: Self.captureTint.opacity(active ? 0.7 : 0), radius: 6)
                .hitTarget()
        }
        .buttonStyle(.plain)
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

    var body: some View {
        @Bindable var state = appState

        HStack(spacing: 12) {
            Menu {
                Picker("Visualizer", selection: $state.visualizerID) {
                    ForEach(VisualizerRegistry.all) { descriptor in
                        Text(descriptor.name).tag(descriptor.id)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                    Text(currentVisualizerName)
                        .fontWeight(.medium)
                }
                .hitTarget(horizontal: 4, vertical: 10)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Divider().frame(height: 20)

            Button {
                optionsShown.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .hitTarget()
            }
            .buttonStyle(.plain)
            .help("Visualizer options")
            .accessibilityLabel("Visualizer options")
            .popover(isPresented: $optionsShown, arrowEdge: .top) {
                OptionsPanel()
            }

            Button {
                NSApp.keyWindow?.toggleFullScreen(nil)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .hitTarget()
            }
            .buttonStyle(.plain)
            .help("Toggle full screen")
            .accessibilityLabel("Toggle full screen")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .glassEffect(.regular.interactive(), in: .capsule)
        .foregroundStyle(.white)
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
                        LabeledSlider(name: "Sensitivity",
                                      value: settings.binding(descriptor.id, \.sensitivity),
                                      range: 0.2...3.0,
                                      defaultValue: 1.0)
                        LabeledSlider(name: "Speed",
                                      value: settings.binding(descriptor.id, \.speed),
                                      range: 0.2...3.0,
                                      defaultValue: 1.0)
                    }

                    if !descriptor.options.isEmpty {
                        OptionSection("\(descriptor.name) Options") {
                            ForEach(descriptor.options) { option in
                                LabeledSlider(name: option.name,
                                              value: settings.binding(descriptor.id, option: option),
                                              range: option.range,
                                              defaultValue: option.defaultValue)
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
                                    .strokeBorder(isSelected ? Color.white : .white.opacity(0.15),
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
            return Color(red: Double(max(0, min(1, c.x))),
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
