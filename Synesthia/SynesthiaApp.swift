import SwiftUI
import AppKit

/// App entry point: one window containing `ContentView`, plus the menu-bar
/// commands. The shared `AppState` is injected through the SwiftUI
/// environment so every view (and the menus here) drive the same state.
@main
struct SynesthiaApp: App {
    @State private var appState = AppState.shared

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
        case .audioFile: appState.isCaptureActive ? "Pause File" : "Play File"
        default: appState.isCaptureActive ? "Stop Listening" : "Start Listening"
        }
    }

    var body: some Scene {
        WindowGroup {
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

                Divider()

                Button("Synesthia Support") {
                    Self.open("https://synesthia.app/support")
                }
                Button("Privacy Policy") {
                    Self.open("https://synesthia.app/privacy")
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
                Picker("Palette", selection: appState.settings.binding(appState.visualizerID, \.paletteIndex)) {
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
        }
    }
}
