import AppKit
import CoreAudio
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Track metadata for the on-screen badge.
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
    #if MUSIC_APP_SOURCE
    let music = MusicController()
    #endif
    let settings = VisualizerSettings()

    private let systemCapture: SystemAudioCapture
    private let inputCapture: InputDeviceCapture
    private let filePlayer: FilePlayer
    /// Separate from `filePlayer` so switching between the demo and a chosen
    /// file doesn't make them fight over one engine's loaded file.
    private let demoPlayer: FilePlayer

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
    /// Loudness normalization: the analyzer slowly adapts its dB mappings to
    /// the source's program level, so a quiet mic and loud mastered music
    /// both land in the useful visual range without retuning Sensitivity.
    /// Persisted; the analyzer owns the DSP, this just switches it.
    var loudnessNormalizationEnabled: Bool {
        didSet {
            UserDefaults.standard.set(loudnessNormalizationEnabled, forKey: Self.loudnessKey)
            analyzer.setAutoGainEnabled(loudnessNormalizationEnabled)
        }
    }

    var inputDevices: [AudioInputDevice] = []
    /// Changing the device while already listening retargets the capture
    /// engine immediately — the engine itself only reads the ID at start.
    var selectedInputDeviceID: AudioDeviceID? {
        didSet {
            guard selectedInputDeviceID != oldValue, sourceKind == .inputDevice, isCapturing
            else { return }
            Task {
                inputCapture.stop()
                do {
                    try await inputCapture.start(deviceID: selectedInputDeviceID)
                } catch {
                    isCapturing = false
                    setStatus(error.localizedDescription)
                }
            }
        }
    }
    private(set) var fileURL: URL?
    private(set) var isCapturing = false { didSet { refreshPowerAssertion() } }
    /// Mirrors `FilePlayer.isPlaying`; the player isn't observable on its own.
    private(set) var isFilePlaying = false { didSet { refreshPowerAssertion() } }
    private(set) var isDemoPlaying = false { didSet { refreshPowerAssertion() } }
    /// Transient user-facing error/hint, shown as a banner and auto-cleared.
    var statusMessage: String?
    /// Drives the first-run explainer sheet.
    var showsWelcome = false

    #if MUSIC_APP_SOURCE
    /// Auto-latching onto an already-playing Music.app is attempted once per
    /// launch, so a user who deliberately stopped capture isn't fought with.
    private var attemptedAutoCapture = false
    #endif
    private var statusClearTask: Task<Void, Never>?
    /// Held while audio is flowing so the display doesn't sleep mid-song.
    private var powerAssertion: NSObjectProtocol?
    /// The security-scoped resource currently open for `fileURL`, if any.
    private var scopedFileURL: URL?

    private static let welcomeKey = "hasSeenWelcome"
    private static let bookmarkKey = "audioFileBookmark"
    private static let loudnessKey = "loudnessNormalization"

    private init() {
        systemCapture = SystemAudioCapture(analyzer: AudioAnalyzer.shared)
        inputCapture = InputDeviceCapture(analyzer: AudioAnalyzer.shared)
        filePlayer = FilePlayer(analyzer: AudioAnalyzer.shared)
        demoPlayer = FilePlayer(analyzer: AudioAnalyzer.shared)
        // First launch defaults to the bundled demo: it needs no permission,
        // so the canvas is alive before anything can be denied.
        let stored = UserDefaults.standard.string(forKey: "sourceKind") ?? ""
        sourceKind = AudioSourceKind(rawValue: stored) ?? .demo
        let storedViz = UserDefaults.standard.string(forKey: "visualizerID") ?? ""
        visualizerID = VisualizerRegistry.descriptor(id: storedViz)?.id ?? VisualizerRegistry.all[0].id
        // Default on; read via `bool(forKey:)` (not a plain object cast) so
        // the screenshots-style `-loudnessNormalization NO` argument-domain
        // injection keeps working.
        loudnessNormalizationEnabled =
            UserDefaults.standard.object(forKey: Self.loudnessKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: Self.loudnessKey)
        showsWelcome = !UserDefaults.standard.bool(forKey: Self.welcomeKey)
        fileURL = resolveBookmarkedFile()
        systemCapture.onExternalStop = { [weak self] in self?.handleSystemCaptureStopped() }
        // didSet doesn't fire during init, so push the stored value once.
        analyzer.setAutoGainEnabled(loudnessNormalizationEnabled)
    }

    /// The SCK stream died without us stopping it (permission revoked, display
    /// reconfigured). Without this the app would keep the display awake and
    /// render at full rate while showing a frozen, silent canvas.
    private func handleSystemCaptureStopped() {
        guard isCapturing else { return }
        isCapturing = false
        setStatus("System audio capture stopped. Press play to reconnect.")
    }

    func onAppear() {
        inputDevices = AudioInputDeviceList.all()
        switch sourceKind {
        case .demo:
            startDemo()
        #if MUSIC_APP_SOURCE
        case .musicApp:
            music.startPolling()
            autoStartCaptureIfMusicPlaying()
        #endif
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
        case .demo: isDemoPlaying
        #if MUSIC_APP_SOURCE
        case .musicApp: music.isPlaying
        #endif
        case .systemAudio, .inputDevice: isCapturing
        case .audioFile: isFilePlaying
        }
    }

    /// Whether audio is currently flowing into the analyzer.
    var isCaptureActive: Bool {
        switch sourceKind {
        case .demo: isDemoPlaying
        #if MUSIC_APP_SOURCE
        case .musicApp: isCapturing
        #endif
        case .systemAudio, .inputDevice: isCapturing
        case .audioFile: isFilePlaying
        }
    }

    /// Which sources give us prev/play/next rather than being capture-only.
    var showsTransport: Bool {
        #if MUSIC_APP_SOURCE
        sourceKind == .musicApp
        #else
        false
        #endif
    }

    var windowTitle: String {
        #if MUSIC_APP_SOURCE
        if sourceKind == .musicApp, let track = music.track, !track.title.isEmpty {
            return track.artist.isEmpty ? track.title : "\(track.title) — \(track.artist)"
        }
        #endif
        if sourceKind == .demo {
            return DemoTrack.title
        }
        if sourceKind == .audioFile, let fileURL {
            return fileURL.deletingPathExtension().lastPathComponent
        }
        return "Synesthia"
    }

    /// Track metadata, only when we genuinely have some.
    var nowPlaying: NowPlayingInfo? {
        #if MUSIC_APP_SOURCE
        if sourceKind == .musicApp, let track = music.track {
            return NowPlayingInfo(
                title: track.title, artist: track.artist,
                album: track.album, artwork: music.artwork)
        }
        #endif
        if sourceKind == .demo {
            return NowPlayingInfo(
                title: DemoTrack.title, artist: DemoTrack.subtitle,
                album: "", artwork: nil)
        }
        return nil
    }

    // MARK: - Transport

    /// Play/pause the *source*. Only drivable sources respond; for live
    /// sources this is the same thing as toggling capture.
    func togglePlay() {
        Task { await handlePlay() }
    }

    private func handlePlay() async {
        #if MUSIC_APP_SOURCE
        if sourceKind == .musicApp {
            // Starting playback with no capture attached would leave the canvas
            // dead, so latch on first. Deliberately only when Music is *not*
            // playing: if it is, the user may just be re-attaching capture after
            // granting the permission, and toggling would pause their music.
            if !music.isPlaying && !isCapturing {
                await startSystemCapture()
            }
            music.togglePlayPause()
            if music.automationDenied {
                setStatus(
                    "Synesthia isn't allowed to control Music. Enable it in System Settings › Privacy & Security › Automation."
                )
            }
            return
        }
        #endif
        await handleCaptureToggle()
    }

    /// Start/stop the audio capture feeding the analyzer, independent of transport.
    func toggleCapture() {
        Task { await handleCaptureToggle() }
    }

    private func handleCaptureToggle() async {
        switch sourceKind {
        case .demo:
            if isDemoPlaying {
                demoPlayer.pause()
                isDemoPlaying = false
            } else {
                startDemo()
            }
        #if MUSIC_APP_SOURCE
        case .musicApp:
            await toggleSystemCapture()
        #endif
        case .systemAudio:
            await toggleSystemCapture()
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
            if let fileURL {
                do {
                    // After a relaunch the bookmark restored fileURL, but the
                    // player has nothing loaded yet.
                    if filePlayer.currentURL != fileURL {
                        try filePlayer.load(url: fileURL)
                    }
                    try filePlayer.togglePlayPause()
                    isFilePlaying = filePlayer.isPlaying
                } catch {
                    setStatus(error.localizedDescription)
                }
            } else {
                openFilePanel()
            }
        }
    }

    private func toggleSystemCapture() async {
        if isCapturing {
            await systemCapture.stop()
            isCapturing = false
        } else {
            await startSystemCapture()
        }
    }

    func nextTrack() {
        #if MUSIC_APP_SOURCE
        if sourceKind == .musicApp {
            music.nextTrack()
            return
        }
        #endif
        restartCurrentPlayer()
    }

    func previousTrack() {
        #if MUSIC_APP_SOURCE
        if sourceKind == .musicApp {
            music.previousTrack()
            return
        }
        #endif
        restartCurrentPlayer()
    }

    private func restartCurrentPlayer() {
        switch sourceKind {
        case .audioFile:
            try? filePlayer.restart()
            isFilePlaying = filePlayer.isPlaying
        case .demo:
            try? demoPlayer.restart()
            isDemoPlaying = demoPlayer.isPlaying
        default:
            break
        }
    }

    // MARK: - First run

    /// Switches to a source from the welcome sheet.
    func selectSource(_ kind: AudioSourceKind) {
        sourceKind = kind
    }

    func completeWelcome() {
        UserDefaults.standard.set(true, forKey: Self.welcomeKey)
        showsWelcome = false
    }

    /// Reopens the explainer from the Help menu.
    func showWelcome() {
        showsWelcome = true
    }

    func openPermissionSettings(_ permission: PrivacyPermission) {
        guard let url = permission.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Demo playback

    private func startDemo() {
        guard let url = DemoTrack.url else {
            setStatus("The bundled demo track is missing from this build.")
            return
        }
        do {
            if demoPlayer.currentURL != url {
                try demoPlayer.load(url: url)
            }
            try demoPlayer.play()
            isDemoPlaying = demoPlayer.isPlaying
            statusMessage = nil
        } catch {
            setStatus("Couldn't play the demo track: \(error.localizedDescription)")
        }
    }

    // MARK: - File source

    func openFilePanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an audio file to visualize"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try filePlayer.load(url: url)
            adoptFile(url)
            sourceKind = .audioFile
            try filePlayer.play()
            isFilePlaying = filePlayer.isPlaying
            statusMessage = nil
        } catch {
            setStatus("Couldn't open \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Records the chosen file and stores a security-scoped bookmark, which is
    /// the only way a sandboxed app can reopen it after relaunch — the
    /// open-panel grant itself does not survive the process.
    private func adoptFile(_ url: URL) {
        releaseScopedFile()
        fileURL = url
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil)
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        } catch {
            // Not fatal: the file still plays this session, it just won't come
            // back on next launch.
            UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        }
    }

    /// Resolves the stored bookmark at launch and opens security-scoped access
    /// to it. Returns nil when there is no bookmark or the file has moved.
    private func resolveBookmarkedFile() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return nil }
        var isStale = false
        guard
            let url = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale),
            url.startAccessingSecurityScopedResource()
        else {
            UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
            return nil
        }
        scopedFileURL = url
        // A stale bookmark still resolves; refresh it so it keeps working.
        if isStale,
            let fresh = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil)
        {
            UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey)
        }
        return url
    }

    private func releaseScopedFile() {
        scopedFileURL?.stopAccessingSecurityScopedResource()
        scopedFileURL = nil
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
            demoPlayer.pause()
            isFilePlaying = false
            isDemoPlaying = false
            isCapturing = false
            analyzer.reset()
            statusMessage = nil

            switch sourceKind {
            case .demo:
                stopMusicPolling()
                startDemo()
            #if MUSIC_APP_SOURCE
            case .musicApp:
                music.startPolling()
                autoStartCaptureIfMusicPlaying()
            #endif
            case .systemAudio:
                stopMusicPolling()
                await startSystemCapture()
            case .inputDevice:
                stopMusicPolling()
                inputDevices = AudioInputDeviceList.all()
            case .audioFile:
                stopMusicPolling()
                if let fileURL {
                    // After a relaunch the bookmark gave us a URL but the
                    // player has nothing loaded yet.
                    if filePlayer.currentURL != fileURL {
                        try? filePlayer.load(url: fileURL)
                    }
                    try? filePlayer.play()
                    isFilePlaying = filePlayer.isPlaying
                }
            }
        }
    }

    private func stopMusicPolling() {
        #if MUSIC_APP_SOURCE
        music.stopPolling()
        #endif
    }

    #if MUSIC_APP_SOURCE
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
    #endif

    private func startSystemCapture() async {
        guard !isCapturing else { return }
        do {
            try await systemCapture.start()
            isCapturing = true
            statusMessage = nil
        } catch {
            setStatus(
                "System audio capture unavailable — allow it in System Settings › Privacy & Security › Screen & System Audio Recording, then try again."
            )
        }
    }

    // MARK: - Power

    /// Holds an activity assertion while audio is flowing, so a fullscreen
    /// visualizer doesn't get interrupted by the display going to sleep — and,
    /// just as importantly, releases it the moment nothing is playing so an
    /// idle window isn't holding the machine awake.
    private func refreshPowerAssertion() {
        let shouldHold = isCaptureActive
        if shouldHold, powerAssertion == nil {
            powerAssertion = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .userInitiated],
                reason: "Rendering an audio visualizer")
        } else if !shouldHold, let assertion = powerAssertion {
            ProcessInfo.processInfo.endActivity(assertion)
            powerAssertion = nil
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
