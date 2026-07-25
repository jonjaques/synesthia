import SwiftUI
import AppKit
import Observation
import UniformTypeIdentifiers
import CoreAudio

/// Track metadata for the on-screen badge (Music.app source only — no other
/// source knows what's playing).
struct NowPlayingInfo {
    var title: String
    var artist: String
    var album: String
    var artwork: NSImage?
}

/// Central app state: which audio source is active, which visualizer is
/// selected, and the glue between transport controls and the capture engines.
///
/// This is the app's composition root — it owns the analyzer, the Music
/// controller, the settings store, and one instance of each capture engine,
/// and it is the only place that starts/stops them. It's `@Observable`, so
/// SwiftUI views re-render when the properties they read change; note that
/// the *audio data itself* never flows through here (the render loop pulls
/// it straight from the analyzer) — only control state does.
@Observable
final class AppState {
    static let shared = AppState()

    let analyzer = AudioAnalyzer.shared
    let music = MusicController()
    let settings = VisualizerSettings()

    private let systemCapture: SystemAudioCapture
    private let inputCapture: InputDeviceCapture
    private let filePlayer: FilePlayer

    /// The active audio source; persisted, and switching it retargets all
    /// the capture machinery (see `handleSourceChange`).
    var sourceKind: AudioSourceKind {
        didSet {
            guard sourceKind != oldValue else { return }
            UserDefaults.standard.set(sourceKind.rawValue, forKey: "sourceKind")
            handleSourceChange()
        }
    }
    /// Selected visualizer's descriptor id; the render loop watches this and
    /// swaps visualizers when it changes.
    var visualizerID: String {
        didSet { UserDefaults.standard.set(visualizerID, forKey: "visualizerID") }
    }

    var inputDevices: [AudioInputDevice] = []
    var selectedInputDeviceID: AudioDeviceID?
    private(set) var fileURL: URL?
    private(set) var isCapturing = false
    /// Mirrors `FilePlayer.isPlaying`; the player isn't observable on its own.
    private(set) var isFilePlaying = false
    /// Transient user-facing error/hint, shown as a banner and auto-cleared.
    var statusMessage: String?

    /// Auto-latching onto an already-playing Music.app is attempted once per
    /// launch, so a user who deliberately stopped capture isn't fought with.
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
        // dead, so latch on first. Deliberately only when Music is *not*
        // playing: if it is, the user may just be re-attaching capture after
        // granting the permission, and toggling would pause their music.
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

    /// Tears everything down (all engines stopped, analyzer cleared so the
    /// old source's tail doesn't linger) and brings up whatever the new
    /// source needs. Stopping every engine unconditionally is simpler and
    /// safer than tracking which one was running.
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

    /// If Music is already playing when the app opens, attach the system
    /// audio tap automatically so the visuals come alive without a click.
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

    /// Shows a banner message and schedules its disappearance; a newer
    /// message cancels the older one's clear timer.
    private func setStatus(_ message: String) {
        statusMessage = message
        statusClearTask?.cancel()
        statusClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { self?.statusMessage = nil }
        }
    }
}
