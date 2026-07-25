import SwiftUI
import CoreAudio

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var controlsVisible = true
    @State private var hideControlsTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            MetalVisualizerView(appState: appState)
                .ignoresSafeArea()

            VStack {
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
                Spacer()
                HStack(alignment: .bottom) {
                    if let info = appState.nowPlaying {
                        NowPlayingBadge(info: info)
                    }
                    Spacer()
                }
                .padding(16)
            }

            VStack {
                Spacer()
                ControlsBar()
                    .padding(.bottom, 24)
                    .opacity(controlsVisible ? 1 : 0)
                    .animation(.easeInOut(duration: 0.25), value: controlsVisible)
            }
        }
        .background(Color.black)
        .navigationTitle(appState.windowTitle)
        .preferredColorScheme(.dark)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                showControlsTemporarily()
            case .ended:
                break
            }
        }
        .onAppear {
            appState.onAppear()
            showControlsTemporarily()
        }
    }

    private func showControlsTemporarily() {
        controlsVisible = true
        hideControlsTask?.cancel()
        hideControlsTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled {
                controlsVisible = false
            }
        }
    }
}

// MARK: - Now playing badge

struct NowPlayingBadge: View {
    let info: NowPlayingInfo

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
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(info.title)
                    .font(.headline)
                if !info.artist.isEmpty {
                    Text(info.artist)
                        .font(.subheadline)
                        .opacity(0.85)
                }
                if !info.album.isEmpty {
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
        .frame(maxWidth: 380, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}

// MARK: - Controls bar

struct ControlsBar: View {
    @Environment(AppState.self) private var appState
    @State private var optionsShown = false

    var body: some View {
        @Bindable var state = appState

        GlassEffectContainer(spacing: 16) {
            HStack(spacing: 16) {
                // Source + transport pod
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
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    Divider().frame(height: 20)

                    Button {
                        appState.previousTrack()
                    } label: {
                        Image(systemName: "backward.fill")
                    }
                    .buttonStyle(.plain)

                    Button {
                        appState.togglePlay()
                    } label: {
                        Image(systemName: appState.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 34))
                    }
                    .buttonStyle(.plain)

                    Button {
                        appState.nextTrack()
                    } label: {
                        Image(systemName: "forward.fill")
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .glassEffect(.regular.interactive(), in: .capsule)

                // Visualizer + options pod
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
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    Divider().frame(height: 20)

                    Button {
                        optionsShown.toggle()
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .buttonStyle(.plain)
                    .help("Visualizer options")
                    .popover(isPresented: $optionsShown, arrowEdge: .top) {
                        OptionsPanel()
                    }

                    Button {
                        NSApp.keyWindow?.toggleFullScreen(nil)
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.plain)
                    .help("Toggle full screen")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
        }
        .foregroundStyle(.white)
    }

    private var currentVisualizerName: String {
        VisualizerRegistry.descriptor(id: appState.visualizerID)?.name ?? "Visualizer"
    }
}

// MARK: - Options panel

struct OptionsPanel: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var settings = appState.settings
        let descriptor = VisualizerRegistry.descriptor(id: appState.visualizerID)

        VStack(alignment: .leading, spacing: 16) {
            if let descriptor {
                VStack(alignment: .leading, spacing: 3) {
                    Label(descriptor.name, systemImage: "sparkles")
                        .font(.headline)
                    Text(descriptor.tagline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Palette")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                PalettePicker(selection: $settings.paletteIndex)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Audio Response")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                LabeledSlider(name: "Sensitivity", value: $settings.sensitivity, range: 0.2...3.0)
                LabeledSlider(name: "Speed", value: $settings.speed, range: 0.2...3.0)
            }

            if let descriptor, !descriptor.options.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(descriptor.name) Options")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(descriptor.options) { option in
                        LabeledSlider(
                            name: option.name,
                            value: Binding(
                                get: { appState.settings.value(visualizer: descriptor.id, option: option) },
                                set: { appState.settings.setValue($0, visualizer: descriptor.id, option: option) }),
                            range: option.range)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

/// Horizontal row of gradient swatches, one per palette.
struct PalettePicker: View {
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(Palettes.names.enumerated()), id: \.offset) { index, name in
                Button {
                    selection = index
                } label: {
                    Capsule()
                        .fill(gradient(for: index))
                        .frame(height: 22)
                        .overlay {
                            Capsule()
                                .strokeBorder(selection == index ? Color.white : .white.opacity(0.15),
                                              lineWidth: selection == index ? 2 : 1)
                        }
                }
                .buttonStyle(.plain)
                .help(name)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(name).font(.caption)
                Spacer()
                Text(value, format: .number.precision(.fractionLength(2)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }
}
