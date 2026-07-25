import SwiftUI
import AppKit
import Observation
import UniformTypeIdentifiers
import CoreAudio

struct NowPlayingInfo {
    var title: String
    var artist: String
    var album: String
    var artwork: NSImage?
}

/// Central app state: which audio source is active, which visualizer is
/// selected, and the glue between transport controls and the capture engines.
@Observable
final class AppState {
    static let shared = AppState()

    let analyzer = AudioAnalyzer.shared
    let music = MusicController()
    let settings = VisualizerSettings()

    private let systemCapture: SystemAudioCapture
    private let inputCapture: InputDeviceCapture
    private let filePlayer: FilePlayer

    var sourceKind: AudioSourceKind {
        didSet {
            guard sourceKind != oldValue else { return }
            UserDefaults.standard.set(sourceKind.rawValue, forKey: "sourceKind")
            handleSourceChange()
        }
    }
    var visualizerID: String {
        didSet { UserDefaults.standard.set(visualizerID, forKey: "visualizerID") }
    }

    var inputDevices: [AudioInputDevice] = []
    var selectedInputDeviceID: AudioDeviceID?
    private(set) var fileURL: URL?
    private(set) var isCapturing = false
    /// Mirrors `FilePlayer.isPlaying`; the player isn't observable on its own.
    private(set) var isFilePlaying = false
    var statusMessage: String?

    private var attemptedAutoCapture = false
    private var statusClearTask: Task<Void, Never>?

    private init() {
        systemCapture = SystemAudioCapture(analyzer: AudioAnalyzer.shared)
        inputCapture = InputDeviceCapture(analyzer: AudioAnalyzer.shared)
        filePlayer = FilePlayer(analyzer: AudioAnalyzer.shared)
        sourceKind = AudioSourceKind(rawValue: UserDefaults.standard.string(forKey: "sourceKind") ?? "") ?? .musicApp
        let storedViz = UserDefaults.standard.string(forKey: "visualizerID") ?? ""
        visualizerID = VisualizerRegistry.descriptor(id: storedViz)?.id ?? VisualizerRegistry.all[0].id
    }

    func onAppear() {
        inputDevices = AudioInputDeviceList.all()
        switch sourceKind {
        case .musicApp:
            music.startPolling()
            autoStartCaptureIfMusicPlaying()
        case .systemAudio:
            Task { await startSystemCapture() }
        case .inputDevice, .audioFile:
            break
        }
    }

    // MARK: - Derived UI state

    /// Transport state — only meaningful for sources we can actually drive.
    var isPlaying: Bool {
        switch sourceKind {
        case .musicApp: music.isPlaying
        case .systemAudio, .inputDevice: isCapturing
        case .audioFile: isFilePlaying
        }
    }

    /// Whether audio is currently flowing into the analyzer.
    var isCaptureActive: Bool {
        switch sourceKind {
        case .musicApp, .systemAudio, .inputDevice: isCapturing
        case .audioFile: isFilePlaying
        }
    }

    /// Only Music.app gives us prev/play/next; everything else is capture-only.
    var showsTransport: Bool { sourceKind == .musicApp }

    var windowTitle: String {
        if sourceKind == .musicApp, let track = music.track, !track.title.isEmpty {
            return track.artist.isEmpty ? track.title : "\(track.title) — \(track.artist)"
        }
        if sourceKind == .audioFile, let fileURL {
            return fileURL.deletingPathExtension().lastPathComponent
        }
        return "Synesthia"
    }

    /// Track metadata, only when we genuinely have some: Music.app mode.
    var nowPlaying: NowPlayingInfo? {
        guard sourceKind == .musicApp, let track = music.track else { return nil }
        return NowPlayingInfo(title: track.title, artist: track.artist,
                              album: track.album, artwork: music.artwork)
    }

    // MARK: - Transport

    /// Play/pause the *source*. Only Music.app and local files can be driven;
    /// for live sources this is the same thing as toggling capture.
    func togglePlay() {
        Task { await handlePlay() }
    }

    private func handlePlay() async {
        guard sourceKind == .musicApp else {
            await handleCaptureToggle()
            return
        }
        // Starting playback with no capture attached would leave the canvas
        // dead, so latch on first.
        if !music.isPlaying && !isCapturing {
            await startSystemCapture()
        }
        music.togglePlayPause()
        if music.automationDenied {
            setStatus("Synesthia isn't allowed to control Music. Enable it in System Settings › Privacy & Security › Automation.")
        }
    }

    /// Start/stop the audio capture feeding the analyzer, independent of transport.
    func toggleCapture() {
        Task { await handleCaptureToggle() }
    }

    private func handleCaptureToggle() async {
        switch sourceKind {
        case .musicApp, .systemAudio:
            if isCapturing {
                await systemCapture.stop()
                isCapturing = false
            } else {
                await startSystemCapture()
            }
        case .inputDevice:
            if isCapturing {
                inputCapture.stop()
                isCapturing = false
            } else {
                do {
                    try await inputCapture.start(deviceID: selectedInputDeviceID)
                    isCapturing = true
                } catch {
                    setStatus(error.localizedDescription)
                }
            }
        case .audioFile:
            if fileURL == nil {
                openFilePanel()
            } else {
                do {
                    try filePlayer.togglePlayPause()
                    isFilePlaying = filePlayer.isPlaying
                } catch {
                    setStatus(error.localizedDescription)
                }
            }
        }
    }

    func nextTrack() {
        guard sourceKind == .musicApp else {
            if sourceKind == .audioFile { restartFile() }
            return
        }
        music.nextTrack()
    }

    func previousTrack() {
        guard sourceKind == .musicApp else {
            if sourceKind == .audioFile { restartFile() }
            return
        }
        music.previousTrack()
    }

    private func restartFile() {
        try? filePlayer.restart()
        isFilePlaying = filePlayer.isPlaying
    }

    func openFilePanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an audio file to visualize"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try filePlayer.load(url: url)
            fileURL = url
            sourceKind = .audioFile
            try filePlayer.play()
            isFilePlaying = filePlayer.isPlaying
            statusMessage = nil
        } catch {
            setStatus("Couldn't open \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    // MARK: - Source plumbing

    private func handleSourceChange() {
        Task {
            await systemCapture.stop()
            inputCapture.stop()
            filePlayer.pause()
            isFilePlaying = false
            isCapturing = false
            analyzer.reset()
            statusMessage = nil

            switch sourceKind {
            case .musicApp:
                music.startPolling()
                autoStartCaptureIfMusicPlaying()
            case .systemAudio:
                music.stopPolling()
                await startSystemCapture()
            case .inputDevice:
                music.stopPolling()
                inputDevices = AudioInputDeviceList.all()
            case .audioFile:
                music.stopPolling()
                if fileURL != nil {
                    try? filePlayer.play()
                    isFilePlaying = filePlayer.isPlaying
                }
            }
        }
    }

    private func autoStartCaptureIfMusicPlaying() {
        guard !attemptedAutoCapture, music.isMusicAppRunning else { return }
        attemptedAutoCapture = true
        Task {
            // Give the first poll a moment to land, then latch on if Music is already playing.
            try? await Task.sleep(for: .seconds(1.5))
            if sourceKind == .musicApp, music.isPlaying, !isCapturing {
                await startSystemCapture()
            }
        }
    }

    private func startSystemCapture() async {
        guard !isCapturing else { return }
        do {
            try await systemCapture.start()
            isCapturing = true
            statusMessage = nil
        } catch {
            setStatus("System audio capture unavailable — allow it in System Settings › Privacy & Security › Screen & System Audio Recording, then try again.")
        }
    }

    private func setStatus(_ message: String) {
        statusMessage = message
        statusClearTask?.cancel()
        statusClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { self?.statusMessage = nil }
        }
    }
}
