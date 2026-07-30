import AppKit
import SwiftUI

/// App entry point: one window containing `ContentView`, plus the menu-bar
/// commands. The shared `AppState` is injected through the SwiftUI
/// environment so every view (and the menus here) drive the same state.
@main
struct SynesthiaApp: App {
    /// Scene id for the canvas window, so Window ▸ Synesthia can ask for it
    /// by name.
    static let mainWindowID = "canvas"

    @State private var appState = AppState.shared
    @Environment(\.openWindow) private var openWindow

    init() {
        // Single-window app: disable window tabbing so View ▸ Show Tab Bar /
        // Show All Tabs don't appear in the menu bar.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    private var currentVisualizerName: String {
        VisualizerRegistry.descriptor(id: appState.visualizerID)?.name ?? "Visualizer"
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Mirrors the wording of the control bar's capture button (which acts
    /// as play/pause for the file source).
    private var captureMenuTitle: String {
        switch appState.sourceKind {
        case .demo: appState.isCaptureActive ? "Pause Demo Track" : "Play Demo Track"
        case .audioFile: appState.isCaptureActive ? "Pause File" : "Play File"
        default: appState.isCaptureActive ? "Stop Listening" : "Start Listening"
        }
    }

    var body: some Scene {
        // MUST stay the first scene. SwiftUI treats whichever scene is declared
        // first as the app's primary one: it is what launch opens, what a Dock
        // click reopens, and what "open untitled" resolves to. With `Settings`
        // first, an app quit while the canvas window was closed relaunched with
        // *only* the settings window — and clicking the Dock icon opened
        // another settings window rather than the canvas, so there was no way
        // back short of File ▸ New Window. Reproduced on macOS 26.5; see
        // MainWindowGuard below for the second line of defence.
        WindowGroup(id: Self.mainWindowID) {
            ContentView()
                .environment(appState)
        }
        .defaultSize(width: 1100, height: 700)
        // No title bar strip: the visuals run to the very top of the window.
        .windowStyle(.hiddenTitleBar)
        .commands {
            // Replaces the default "Synesthia Help" item, which would otherwise
            // point at a help book that doesn't exist. App Store apps are
            // expected to offer a support affordance, and this is where the
            // Support URL belongs.
            CommandGroup(replacing: .help) {
                // Present only in builds that link Sparkle (the direct
                // download); the Mac App Store build has no updater.
                CheckForUpdatesCommand()

                Button("Audio Sources & Permissions…") {
                    appState.showWelcome()
                }

                // The demo left the source picker (it isn't a real source);
                // this and the welcome sheet are how it comes back.
                Button("Play Demo Track") {
                    appState.playDemo()
                }

                Divider()

                Button("Synesthia Website") {
                    Self.open("https://synesthia.app")
                }
                Button("Synesthia Support") {
                    Self.open("https://synesthia.app/support")
                }
                Button("Privacy Policy") {
                    Self.open("https://synesthia.app/privacy")
                }

                Divider()

                // Synesthia is open source (MIT). Both the store and direct
                // builds link out to the repository — the source is the same
                // for either, only the build configuration differs.
                Button("Source Code on GitHub") {
                    Self.open("https://github.com/jonjaques/synesthia")
                }
                Button("Report an Issue") {
                    Self.open("https://github.com/jonjaques/synesthia/issues/new")
                }
            }

            CommandMenu("Playback") {
                Button(appState.isPlaying ? "Pause" : "Play") {
                    appState.togglePlay()
                }
                .keyboardShortcut(.space, modifiers: [])

                Button("Next Track") {
                    appState.nextTrack()
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command])

                Button("Previous Track") {
                    appState.previousTrack()
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command])

                // Same opt-in as the control pod's menu; the transport items
                // above only reach the detected player once this is granted.
                if let offer = appState.playerControlOffer {
                    Divider()

                    Button("Control \(offer.name)…") {
                        appState.connectPlayerControl()
                    }
                }

                Divider()

                Button(captureMenuTitle) {
                    appState.toggleCapture()
                }
                .keyboardShortcut("l")

                Divider()

                Button("Open Audio File…") {
                    appState.openFilePanel()
                }
                .keyboardShortcut("o")
            }

            CommandMenu("Visualizer") {
                ForEach(Array(VisualizerRegistry.all.enumerated()), id: \.element.id) { index, descriptor in
                    Button(descriptor.name) {
                        appState.visualizerID = descriptor.id
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command])
                }

                Divider()

                // Palette belongs to the selected visualizer, not the app.
                Picker("Palette", selection: appState.settings.binding(appState.visualizerID, \.paletteIndex))
                {
                    ForEach(Array(Palettes.names.enumerated()), id: \.offset) { index, name in
                        Text(name).tag(index)
                    }
                }

                Button("Reset \(currentVisualizerName)") {
                    if let descriptor = VisualizerRegistry.descriptor(id: appState.visualizerID) {
                        appState.settings.reset(descriptor)
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }

            // A named way back to the canvas when its window has been closed.
            // Every macOS app that can end up windowless offers one; without
            // it the only route is File ▸ New Window, which reads as "make a
            // second one" rather than "show me the app again".
            CommandGroup(after: .windowList) {
                Button("Synesthia") {
                    openWindow(id: Self.mainWindowID)
                }
                .keyboardShortcut("0", modifiers: .command)
            }
        }

        // Registers the app-menu "Settings…" item and ⌘, automatically. Keep
        // it last: see the note on the WindowGroup above.
        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}
