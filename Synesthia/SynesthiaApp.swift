import SwiftUI

@main
struct SynesthiaApp: App {
    @State private var appState = AppState.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
        }
        .defaultSize(width: 1100, height: 700)
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

                Picker("Palette", selection: Binding(
                    get: { appState.settings.paletteIndex },
                    set: { appState.settings.paletteIndex = $0 })) {
                    ForEach(Array(Palettes.names.enumerated()), id: \.offset) { index, name in
                        Text(name).tag(index)
                    }
                }
            }
        }
    }
}
