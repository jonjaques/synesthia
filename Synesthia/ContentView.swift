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
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.yellow)
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
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(info.title)
                    .font(.headline)
                if !info.artist.isEmpty {
                    Text(info.artist)
                        .font(.subheadline)
                }
                if !info.album.isEmpty {
                    Text(info.album)
                        .font(.subheadline)
                        .opacity(0.7)
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.8), radius: 3, y: 1)
            .lineLimit(1)
        }
        .frame(maxWidth: 380, alignment: .leading)
    }
}

// MARK: - Controls bar

struct ControlsBar: View {
    @Environment(AppState.self) private var appState
    @State private var optionsShown = false

    var body: some View {
        @Bindable var state = appState

        HStack(spacing: 14) {
            // Source picker
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

            // Transport
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

            Divider().frame(height: 20)

            // Visualizer picker
            Picker("Visualizer", selection: $state.visualizerID) {
                ForEach(VisualizerRegistry.all) { descriptor in
                    Text(descriptor.name).tag(descriptor.id)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            // Options
            Button {
                optionsShown.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.plain)
            .popover(isPresented: $optionsShown, arrowEdge: .top) {
                OptionsPanel()
            }

            // Fullscreen
            Button {
                NSApp.keyWindow?.toggleFullScreen(nil)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .foregroundStyle(.white)
    }
}

// MARK: - Options panel

struct OptionsPanel: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var settings = appState.settings
        let descriptor = VisualizerRegistry.descriptor(id: appState.visualizerID)

        VStack(alignment: .leading, spacing: 14) {
            if let descriptor {
                Text(descriptor.name)
                    .font(.headline)
                Text(descriptor.tagline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Palette", selection: $settings.paletteIndex) {
                ForEach(Array(Palettes.names.enumerated()), id: \.offset) { index, name in
                    Text(name).tag(index)
                }
            }

            LabeledSlider(name: "Sensitivity", value: $settings.sensitivity, range: 0.2...3.0)
            LabeledSlider(name: "Speed", value: $settings.speed, range: 0.2...3.0)

            if let descriptor, !descriptor.options.isEmpty {
                Divider()
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
        .padding(18)
        .frame(width: 300)
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
