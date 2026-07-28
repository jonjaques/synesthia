import SwiftUI

/// The Settings window (⌘,). App-wide preferences live here; everything
/// scoped to one visualizer (sensitivity, speed, palette, its own options)
/// stays in the canvas options popover instead.
struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        Form {
            Section("Audio") {
                Toggle(isOn: $appState.loudnessNormalizationEnabled) {
                    Text("Normalize Loudness")
                    Text(
                        "Slowly adapts to the source's overall loudness, so a quiet microphone and loud music read the same without retuning Sensitivity."
                    )
                }
                .toggleStyle(.switch)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }
}
