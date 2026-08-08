import AVFoundation
import AppKit
import CoreAudio
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Track metadata for the on-screen badge, whatever its origin — a media
/// player we detected, the bundled demo, or a file the user opened.
struct NowPlayingInfo {
    var title: String
    var artist: String
    var album: String
    /// Real cover art, only when a player handed over the actual bytes. Nil
    /// otherwise, and the badge draws a palette tile in its place rather than
    /// an empty square.
    var artwork: NSImage?
    /// The player this came from, when it came from one. Drives whether
    /// transport and click-through-to-the-player are on offer.
    var player: MediaPlayer?
    /// That player's Dock icon, for the corner badge on the artwork tile.
    var playerIcon: NSImage?
    /// False when the reporting player is paused, which dims the badge.
    var isPlaying: Bool
    /// Glyph for the tile when there is neither cover art nor a player icon.
    var symbol: String
    /// Stable string the tile's gradient is derived from. The album where
    /// there is one, so a whole record shares a colour.
    var seed: String
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
    /// Passive, permission-free detection of what any known media player is
    /// playing. Runs in every build; see `NowPlayingObserver`.
    let nowPlayingObserver = NowPlayingObserver()
    #if MUSIC_APP_SOURCE
    /// The opt-in Apple Events layer: transport control and real cover art.
    let remote = PlayerRemote()
    #endif
    let settings: VisualizerSettings

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
            defaults.set(sourceKind.rawValue, forKey: Self.sourceKindKey)
            handleSourceChange()
        }
    }
    /// Selected visualizer's descriptor id; the render loop watches this and
    /// swaps visualizers when it changes.
    var visualizerID: String {
        didSet { defaults.set(visualizerID, forKey: Self.visualizerIDKey) }
    }
    /// Loudness normalization: the analyzer slowly adapts its dB mappings to
    /// the source's program level, so a quiet mic and loud mastered music
    /// both land in the useful visual range without retuning Sensitivity.
    /// Persisted; the analyzer owns the DSP, this just switches it.
    var loudnessNormalizationEnabled: Bool {
        didSet {
            defaults.set(loudnessNormalizationEnabled, forKey: Self.loudnessKey)
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
    /// True while the *first-run* welcome sheet is up and the user hasn't
    /// picked a source yet — i.e. while Continue still means "just show me
    /// something". Nothing plays on first launch until that is answered, so
    /// this is also what tells `completeWelcome` to start the demo. Cleared by
    /// the first explicit choice, and never set when the sheet is reopened
    /// later from the Help menu.
    private(set) var firstRunDemoPending = false
    /// Cached privacy-permission state, driving which sources the picker
    /// offers and the welcome rows' footnotes. Refreshed on app activation
    /// and around every capture attempt — macOS has no TCC change
    /// notification to subscribe to.
    private(set) var screenAudioGranted = CGPreflightScreenCaptureAccess()
    private(set) var microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    /// The permission the active source is stuck behind after a failed
    /// capture start. Rendered as a centered explainer card over the canvas
    /// rather than a status banner.
    private(set) var blockedPermission: PrivacyPermission?

    #if MUSIC_APP_SOURCE
    /// Whether the user has opted into driving their player over Apple Events.
    /// Persisted, because the macOS Automation grant persists too — asking
    /// again on every launch would be worse than remembering the answer.
    private(set) var playerControlEnabled: Bool
    #endif
    private var statusClearTask: Task<Void, Never>?
    /// Held while audio is flowing so the display doesn't sleep mid-song.
    private var powerAssertion: NSObjectProtocol?
    /// The security-scoped resource currently open for `fileURL`, if any.
    private var scopedFileURL: URL?

    /// Where every persisted preference above is read and written. Handed in
    /// rather than reached for globally so the store has a test surface; the
    /// app always gets `.standard`, which is also the only domain
    /// `NSArgumentDomain` injection reaches (`CLAUDE.md` §Screenshots).
    private let defaults: UserDefaults

    private static let sourceKindKey = "sourceKind"
    private static let visualizerIDKey = "visualizerID"
    private static let welcomeKey = "hasSeenWelcome"
    private static let bookmarkKey = "audioFileBookmark"
    private static let loudnessKey = "loudnessNormalization"
    private static let playerControlKey = "playerControlEnabled"

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = VisualizerSettings(defaults: defaults)
        systemCapture = SystemAudioCapture(analyzer: AudioAnalyzer.shared)
        inputCapture = InputDeviceCapture(analyzer: AudioAnalyzer.shared)
        filePlayer = FilePlayer(analyzer: AudioAnalyzer.shared)
        demoPlayer = FilePlayer(analyzer: AudioAnalyzer.shared)
        // First launch defaults to the bundled demo: it needs no permission,
        // so the canvas is alive before anything can be denied.
        let stored = defaults.string(forKey: Self.sourceKindKey) ?? ""
        sourceKind = AudioSourceKind(rawValue: Self.migrated(stored)) ?? .demo
        let storedViz = defaults.string(forKey: Self.visualizerIDKey) ?? ""
        visualizerID = VisualizerRegistry.descriptor(id: storedViz)?.id ?? VisualizerRegistry.all[0].id
        // Default on; read via `bool(forKey:)` (not a plain object cast) so
        // the screenshots-style `-loudnessNormalization NO` argument-domain
        // injection keeps working.
        loudnessNormalizationEnabled =
            defaults.object(forKey: Self.loudnessKey) == nil
            ? true
            : defaults.bool(forKey: Self.loudnessKey)
        showsWelcome = !defaults.bool(forKey: Self.welcomeKey)
        #if MUSIC_APP_SOURCE
        playerControlEnabled = defaults.bool(forKey: Self.playerControlKey)
        #endif
        // Reads two stored properties, so it can only run once they all are.
        firstRunDemoPending = showsWelcome && sourceKind == .demo
        fileURL = resolveBookmarkedFile()
        systemCapture.onExternalStop = { [weak self] in self?.handleSystemCaptureStopped() }
        // didSet doesn't fire during init, so push the stored values once.
        analyzer.setAutoGainEnabled(loudnessNormalizationEnabled)
        defaults.set(sourceKind.rawValue, forKey: Self.sourceKindKey)
    }

    /// Rewrites a stored source kind that no longer exists.
    ///
    /// `musicApp` was retired: now-playing is a layer over system audio rather
    /// than a source of its own, and system audio is what that source was
    /// really listening to all along (Music.app exposes no audio stream, so it
    /// went through the same ScreenCaptureKit tap). Anyone whose last session
    /// used it lands on the source that still behaves identically.
    private static func migrated(_ stored: String) -> String {
        stored == "musicApp" ? AudioSourceKind.systemAudio.rawValue : stored
    }

    /// The SCK stream died without us stopping it (permission revoked, display
    /// reconfigured). Without this the app would keep the display awake and
    /// render at full rate while showing a frozen, silent canvas.
    private func handleSystemCaptureStopped() {
        guard isCapturing else { return }
        isCapturing = false
        refreshPermissions()
        if screenAudioGranted {
            setStatus("Stopped listening to system audio. Press ⌘L to start again.")
        } else {
            blockedPermission = .screenAndSystemAudio
        }
    }

    func onAppear() {
        inputDevices = AudioInputDeviceList.all()
        // Detection runs regardless of source and costs nothing — no
        // permission, no polling, one callback per track change.
        nowPlayingObserver.onTrackChange = { [weak self] player, track in
            self?.handleTrackChange(player: player, track: track)
        }
        nowPlayingObserver.start()
        seedConnectedPlayers()
        // First run: the canvas stays quiet until the welcome sheet is
        // answered. Starting the demo underneath it means the app makes noise
        // before the user has been told anything, and a source that needs a
        // permission would raise the system prompt before its pitch has been
        // read — which is the whole reason the sheet exists. `completeWelcome`
        // and `selectSource` pick this up again.
        guard !showsWelcome else { return }
        switch sourceKind {
        case .demo:
            startDemo()
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
        case .systemAudio:
            // Once transport is on screen the buttons drive the *player*, so
            // they have to show the player's state, not ours.
            showsTransport ? (detectedTrack?.isPlaying ?? false) : isCapturing
        case .inputDevice: isCapturing
        case .audioFile: isFilePlaying
        }
    }

    /// Whether audio is currently flowing into the analyzer.
    var isCaptureActive: Bool {
        switch sourceKind {
        case .demo: isDemoPlaying
        case .systemAudio, .inputDevice: isCapturing
        case .audioFile: isFilePlaying
        }
    }

    /// The player Synesthia can see, if any. Scoped to the system-audio source
    /// on purpose: that is the only source that is actually *hearing* the
    /// player, and a Spotify badge over a live microphone feed would be a lie.
    var detectedPlayer: MediaPlayer? {
        guard sourceKind == .systemAudio else { return nil }
        return nowPlayingObserver.current?.player
    }

    private var detectedTrack: NowPlayingTrack? {
        guard sourceKind == .systemAudio else { return nil }
        return nowPlayingObserver.current?.track
    }

    /// Whether prev/play/next are on offer — i.e. we found a player we know how
    /// to drive *and* the user has opted into letting us drive it.
    var showsTransport: Bool {
        #if MUSIC_APP_SOURCE
        playerControlEnabled && detectedPlayer?.isScriptable == true
        #else
        false
        #endif
    }

    /// The player to offer control of, when there is one and the user hasn't
    /// taken us up on it yet. Nil in the App Store build, which sends no Apple
    /// Events at all, so the offer never appears there.
    var playerControlOffer: MediaPlayer? {
        #if MUSIC_APP_SOURCE
        guard !playerControlEnabled, let player = detectedPlayer, player.isScriptable else {
            return nil
        }
        return player
        #else
        nil
        #endif
    }

    var windowTitle: String {
        if let track = detectedTrack, !track.title.isEmpty {
            return track.artist.isEmpty ? track.title : "\(track.title) — \(track.artist)"
        }
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
        if let player = detectedPlayer, let track = detectedTrack {
            return NowPlayingInfo(
                title: track.title, artist: track.artist, album: track.album,
                artwork: artwork(for: track), player: player,
                playerIcon: nowPlayingObserver.playerIcon,
                isPlaying: track.isPlaying, symbol: "music.note",
                seed: track.paletteSeed)
        }
        if sourceKind == .demo {
            return NowPlayingInfo(
                title: DemoTrack.title, artist: DemoTrack.subtitle, album: "",
                artwork: nil, player: nil, playerIcon: nil,
                isPlaying: isDemoPlaying, symbol: "music.quarternote.3",
                seed: DemoTrack.title)
        }
        return nil
    }

    /// Cover art for a track, when the opt-in Apple Events layer managed to
    /// fetch some *and* it belongs to this track rather than the last one.
    private func artwork(for track: NowPlayingTrack) -> NSImage? {
        #if MUSIC_APP_SOURCE
        guard remote.artworkIdentity == track.artworkKey else { return nil }
        return remote.artwork
        #else
        return nil
        #endif
    }

    // MARK: - Transport

    /// Play/pause the *source*. Only drivable sources respond; for live
    /// sources this is the same thing as toggling capture.
    func togglePlay() {
        Task { await handlePlay() }
    }

    private func handlePlay() async {
        #if MUSIC_APP_SOURCE
        if showsTransport, let player = detectedPlayer {
            // Starting playback with no capture attached would leave the canvas
            // dead, so latch on first. Deliberately only when the player is
            // *not* playing: if it is, the user may just be re-attaching
            // capture after granting the permission, and toggling would pause
            // their music.
            if !(detectedTrack?.isPlaying ?? false), !isCapturing {
                await startSystemCapture()
            }
            remote.togglePlayPause(player)
            reportAutomationRefusal(for: player)
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
                    blockedPermission = nil
                } catch {
                    refreshPermissions()
                    if case AudioSourceError.microphoneDenied = error {
                        blockedPermission = .microphone
                    } else {
                        setStatus(error.localizedDescription)
                    }
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
        if showsTransport, let player = detectedPlayer {
            remote.nextTrack(player)
            reportAutomationRefusal(for: player)
            return
        }
        #endif
        restartCurrentPlayer()
    }

    func previousTrack() {
        #if MUSIC_APP_SOURCE
        if showsTransport, let player = detectedPlayer {
            remote.previousTrack(player)
            reportAutomationRefusal(for: player)
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

    // MARK: - Player control (opt-in Apple Events)

    /// Turns on the Apple Events layer for the detected player.
    ///
    /// This is the *only* thing that can send a first Apple Event, and it runs
    /// solely from an explicit menu command. That ordering is the whole point:
    /// macOS raises its Automation prompt on that first event, and a prompt the
    /// user asked for one click earlier is a very different experience from one
    /// that ambushes them at launch. Everything up to here — title, artist,
    /// album, play state — already worked with no permission at all.
    func connectPlayerControl() {
        #if MUSIC_APP_SOURCE
        guard let player = playerControlOffer else { return }
        setPlayerControlEnabled(true)
        // The seed doubles as the permission probe: it either comes back with
        // what's playing, or trips `automationDenied`.
        if let update = remote.seed(player) {
            nowPlayingObserver.ingest(update, from: player)
        }
        if remote.automationDenied {
            // Roll the opt-in back so the menu offers it again rather than
            // leaving the app in a state that claims control it doesn't have.
            setPlayerControlEnabled(false)
            setStatus(
                "Synesthia isn't allowed to control \(player.name). Enable it in System Settings › Privacy & Security › Automation."
            )
        } else if let track = nowPlayingObserver.current?.track {
            handleTrackChange(player: player, track: track)
        }
        #endif
    }

    #if MUSIC_APP_SOURCE
    private func setPlayerControlEnabled(_ enabled: Bool) {
        playerControlEnabled = enabled
        defaults.set(enabled, forKey: Self.playerControlKey)
        if !enabled { remote.clearArtwork() }
    }

    /// Surfaces a refused Apple Event once, as a banner. Deliberately *not* a
    /// `blockedPermission` card: control is an enhancement, and the canvas is
    /// still perfectly alive without it.
    private func reportAutomationRefusal(for player: MediaPlayer) {
        guard remote.automationDenied else { return }
        setStatus(
            "Synesthia isn't allowed to control \(player.name). Enable it in System Settings › Privacy & Security › Automation."
        )
    }

    /// Asks every running scriptable player what it's playing. Only runs when
    /// the user already opted in, so it never triggers the prompt itself; it
    /// exists to close the "launched into already-playing music" gap that a
    /// broadcast-only route cannot close on its own.
    private func seedConnectedPlayers() {
        guard playerControlEnabled else { return }
        for player in MediaPlayer.all where player.isScriptable && player.isRunning {
            if let update = remote.seed(player) {
                nowPlayingObserver.ingest(update, from: player)
            }
        }
    }

    /// A new track arrived, so chase its cover art. Artwork lags a track change
    /// — noticeably so when streaming — hence the couple of retries on top of
    /// the immediate attempt.
    private func handleTrackChange(player: MediaPlayer, track: NowPlayingTrack) {
        guard playerControlEnabled, player.isScriptable else { return }
        let key = track.artworkKey
        remote.beginArtwork(for: player, identity: key)
        Task { [weak self] in
            for delay in [0.7, 1.6] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self else { return }
                self.remote.refreshArtwork(for: player, identity: key)
            }
        }
    }
    #else
    private func seedConnectedPlayers() {}

    private func handleTrackChange(player: MediaPlayer, track: NowPlayingTrack) {}
    #endif

    // MARK: - First run

    /// Switches to a source from the welcome sheet. Call this *before*
    /// `completeWelcome` — an explicit choice is what retires the demo that
    /// Continue would otherwise start.
    func selectSource(_ kind: AudioSourceKind) {
        firstRunDemoPending = false
        guard kind == sourceKind else {
            sourceKind = kind
            return
        }
        // Same source as the one already selected. On first run nothing was
        // ever started (see `onAppear`), so `didSet` won't fire and the sheet
        // would dismiss onto a dead canvas; bring the source up by hand.
        if !isCaptureActive { handleSourceChange() }
    }

    /// Dismisses the welcome sheet for good. On first run, reaching here with
    /// no source chosen means the user clicked Continue without granting
    /// anything — the demo is the answer to that, and the only thing that
    /// starts audio on a fresh install.
    func completeWelcome() {
        defaults.set(true, forKey: Self.welcomeKey)
        showsWelcome = false
        guard firstRunDemoPending else { return }
        firstRunDemoPending = false
        startDemo()
    }

    /// Reopens the explainer from the Help menu.
    func showWelcome() {
        showsWelcome = true
    }

    func openPermissionSettings(_ permission: PrivacyPermission) {
        guard let url = permission.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Permissions

    func refreshPermissions() {
        screenAudioGranted = CGPreflightScreenCaptureAccess()
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Whether a source could produce audio right now, permission-wise.
    /// Locked sources appear disabled in the source picker; the welcome
    /// sheet — which explains what each permission buys *before* macOS asks —
    /// is the granting path.
    func isSourceAvailable(_ kind: AudioSourceKind) -> Bool {
        switch kind {
        case .demo, .audioFile:
            true
        case .systemAudio:
            screenAudioGranted
        case .inputDevice:
            // .notDetermined stays available: selecting the source is what
            // triggers the system prompt.
            microphoneStatus != .denied && microphoneStatus != .restricted
        }
    }

    /// The app came back to the foreground — which is the moment a user
    /// returns from System Settings. Re-read TCC state and, if the active
    /// source was blocked and is now allowed, retry capture unprompted.
    func handleAppActivation() {
        refreshPermissions()
        guard let blocked = blockedPermission,
            sourceKind.requiredPermission == blocked,
            isSourceAvailable(sourceKind),
            !isCaptureActive
        else { return }
        toggleCapture()
    }

    /// "Try Again" on the permission card.
    func retryBlockedSource() {
        refreshPermissions()
        guard blockedPermission != nil, !isCaptureActive else { return }
        toggleCapture()
    }

    // MARK: - Demo

    /// Switches to (or resumes) the bundled demo. The source picker doesn't
    /// list the demo; the welcome sheet and the Help menu call this instead.
    func playDemo() {
        firstRunDemoPending = false
        if sourceKind == .demo {
            if !isDemoPlaying { startDemo() }
        } else {
            sourceKind = .demo
        }
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
            defaults.set(data, forKey: Self.bookmarkKey)
        } catch {
            // Not fatal: the file still plays this session, it just won't come
            // back on next launch.
            defaults.removeObject(forKey: Self.bookmarkKey)
        }
    }

    /// Resolves the stored bookmark at launch and opens security-scoped access
    /// to it. Returns nil when there is no bookmark or the file has moved.
    private func resolveBookmarkedFile() -> URL? {
        guard let data = defaults.data(forKey: Self.bookmarkKey) else { return nil }
        var isStale = false
        guard
            let url = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale),
            url.startAccessingSecurityScopedResource()
        else {
            defaults.removeObject(forKey: Self.bookmarkKey)
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
            defaults.set(fresh, forKey: Self.bookmarkKey)
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
            blockedPermission = nil

            switch sourceKind {
            case .demo:
                startDemo()
            case .systemAudio:
                // Detection keeps running across source changes, but a player
                // that has been sitting paused since before the switch will not
                // re-announce itself, so ask.
                seedConnectedPlayers()
                await startSystemCapture()
            case .inputDevice:
                inputDevices = AudioInputDeviceList.all()
            case .audioFile:
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

    private func startSystemCapture(isRetry: Bool = false) async {
        guard !isCapturing else { return }
        do {
            try await systemCapture.start()
            isCapturing = true
            statusMessage = nil
            blockedPermission = nil
            refreshPermissions()
        } catch {
            refreshPermissions()
            if !screenAudioGranted {
                // Missing permission isn't a transient error: show the
                // explainer card instead of a banner.
                blockedPermission = .screenAndSystemAudio
            } else if !isRetry {
                // A freshly granted permission can fail its first attempt
                // (see CLAUDE.md); retry once, quietly, before surfacing.
                try? await Task.sleep(for: .milliseconds(350))
                await startSystemCapture(isRetry: true)
            } else {
                setStatus("Couldn't start listening to system audio: \(error.localizedDescription)")
            }
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
