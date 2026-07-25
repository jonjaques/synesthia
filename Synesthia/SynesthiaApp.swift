import SwiftUI

@main
struct SynesthiaApp: App {
    @State private var appState = AppState.shared

    private var currentVisualizerName: String {
        VisualizerRegistry.descriptor(id: appState.visualizerID)?.name ?? "Visualizer"
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
