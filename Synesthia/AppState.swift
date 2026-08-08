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
    private let fileSource: FileSource
    /// Separate from `fileSource` so switching between the demo and a chosen
    /// file doesn't make them fight over one engine's loaded file.
    private let demoSource: FileSource

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
            // The engine reads its device id at `start` only, so keeping the
            // two in step here is what makes "restart the source" enough.
            inputCapture.deviceID = selectedInputDeviceID
            guard selectedInputDeviceID != oldValue, sourceKind == .inputDevice, isLive
            else { return }
            Task {
                inputCapture.stop()
                await startCapture()
            }
        }
    }
    private(set) var fileURL: URL?
    /// Whether audio is flowing into the analyzer right now — true both for the
    /// sources the app plays itself and the ones it listens to (see CONTEXT.md,
    /// "Live"). Mirrors `activeSource.isRunning` for SwiftUI: the engines are
    /// not `@Observable` — `SystemAudioCapture` is an `NSObject` SCK delegate,
    /// and the macro on an NSObject subclass is a fight not worth having — so
    /// the single fact the UI needs is republished here, from one place instead
    /// of three properties synced at eight call sites.
    private(set) var isLive = false { didSet { refreshPowerAssertion() } }
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
        fileSource = FileSource(analyzer: AudioAnalyzer.shared)
        demoSource = FileSource(analyzer: AudioAnalyzer.shared)
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
        for kind in AudioSourceKind.allCases {
            source(for: kind).onStopped = { [weak self] in self?.handleSourceStopped(kind) }
        }
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
    ///
    /// Internal rather than private only so it can be tested: it is the one
    /// piece of this class that runs before anything else exists, and it runs
    /// exactly once per install.
    static func migrated(_ stored: String) -> String {
        stored == "musicApp" ? AudioSourceKind.systemAudio.rawValue : stored
    }

    /// The decisions this class makes, as a value that can be asked about them
    /// without performing any of them. Rebuilt on every read — it is a
    /// snapshot of right now, and a stale one would be a bug.
    private var policy: PlaybackPolicy {
        PlaybackPolicy(
            sourceKind: sourceKind,
            isLive: isLive,
            screenAudioGranted: screenAudioGranted,
            microphoneStatus: microphoneStatus,
            blockedPermission: blockedPermission,
            hasFile: fileURL != nil,
            showsWelcome: showsWelcome,
            firstRunDemoPending: firstRunDemoPending)
    }

    // MARK: - The four sources

    /// The one remaining place the source taxonomy is spelled out.
    private func source(for kind: AudioSourceKind) -> any AudioSource {
        switch kind {
        case .demo: demoSource
        case .systemAudio: systemCapture
        case .inputDevice: inputCapture
        case .audioFile: fileSource
        }
    }

    private var activeSource: any AudioSource { source(for: sourceKind) }

    private var allSources: [any AudioSource] { AudioSourceKind.allCases.map(source(for:)) }

    /// Republishes the active source's own answer for SwiftUI. Every start and
    /// stop is followed by one of these; nothing else writes `isLive`.
    private func syncLiveState() {
        isLive = activeSource.isRunning
    }

    /// A source died without us stopping it: the SCK stream torn down
    /// (permission revoked, display reconfigured), or an input device
    /// unplugged. Without this the app would keep the display awake and render
    /// at full rate while showing a frozen, silent canvas.
    ///
    /// A source that isn't the active one has nothing to resync — it was
    /// already stopped when the source changed.
    private func handleSourceStopped(_ kind: AudioSourceKind) {
        guard kind == sourceKind, isLive else { return }
        syncLiveState()
        refreshPermissions()
        if let permission = kind.requiredPermission, !transport.isAvailable(kind) {
            blockedPermission = permission
        } else {
            // Lower-cased source label, so this reads "…to system audio." and
            // "…to audio input." off the same vocabulary the menu uses.
            setStatus("Stopped listening to \(kind.label.lowercased()). Press ⌘L to start again.")
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
        // answered (`.waitForWelcome`). `completeWelcome` and `selectSource`
        // pick this up again.
        switch policy.startupAction() {
        case .start: Task { await startActiveSource() }
        case .waitForWelcome, .doNothing: break
        }
    }

    // MARK: - Derived UI state

    /// Transport state — only meaningful for sources we can actually drive.
    ///
    /// Two senses used to be tangled together in a four-case switch. Now there
    /// is exactly one place they differ: wherever transport is on screen this
    /// is the *Player's* state, and everywhere else it is ours.
    var isPlaying: Bool {
        // Once transport is on screen the buttons drive the *Player*, so they
        // have to show the Player's state, not ours.
        if sourceKind == .systemAudio, showsTransport { return detectedTrack?.isPlaying ?? false }
        return isLive
    }

    /// Everything the menu bar and the canvas chrome need to *say* about the
    /// current source and which sources are offerable, in one pure value.
    ///
    /// Built fresh on every read rather than stored: reading it from inside a
    /// view `body` touches `sourceKind`, `isLive` and the permission flags
    /// through the `@Observable` accessors, so SwiftUI registers exactly the
    /// dependencies the old scattered switches did. A cached copy would freeze
    /// them.
    var transport: TransportPresentation {
        TransportPresentation(
            sourceKind: sourceKind,
            isLive: isLive,
            screenAudioGranted: screenAudioGranted,
            microphoneStatus: microphoneStatus,
            visualizerID: visualizerID)
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
                isPlaying: isLive, symbol: "music.quarternote.3",
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
            if !(detectedTrack?.isPlaying ?? false), !isLive {
                await startCapture()
            }
            report(remote.togglePlayPause(player))
            return
        }
        #endif
        await handleSourceToggle()
    }

    /// Start/stop the audio feeding the analyzer, independent of transport.
    func toggleSource() {
        Task { await handleSourceToggle() }
    }

    /// Stopping is the same act for every source, so it goes through the
    /// interface. Starting still isn't — each one has its own preparation and
    /// its own way of failing.
    private func handleSourceToggle() async {
        guard !activeSource.isRunning else {
            await activeSource.stop()
            syncLiveState()
            return
        }
        await startActiveSource()
    }

    /// Brings the active source up, whichever it is.
    private func startActiveSource() async {
        switch sourceKind {
        case .demo: startDemo()
        case .systemAudio, .inputDevice: await startCapture()
        case .audioFile: startFileSource()
        }
    }

    func nextTrack() {
        #if MUSIC_APP_SOURCE
        if showsTransport, let player = detectedPlayer {
            report(remote.nextTrack(player))
            return
        }
        #endif
        restartCurrentSource()
    }

    func previousTrack() {
        #if MUSIC_APP_SOURCE
        if showsTransport, let player = detectedPlayer {
            report(remote.previousTrack(player))
            return
        }
        #endif
        restartCurrentSource()
    }

    /// Sends the active source back to the top, when it is the kind of source
    /// that has a top. A microphone isn't.
    private func restartCurrentSource() {
        try? (activeSource as? any RestartableSource)?.restart()
        syncLiveState()
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
        // what's playing, or tells us why it couldn't.
        switch remote.seed(player) {
        case .success(let update):
            if let update { nowPlayingObserver.ingest(update, from: player) }
            if let track = nowPlayingObserver.current?.track {
                handleTrackChange(player: player, track: track)
            }
        case .failure(let error):
            // Any failure rolls the opt-in back — the menu should offer it
            // again rather than leave the app claiming control it doesn't
            // have — but only the message says *why*, so "Music isn't running"
            // no longer sends the user to a permission they already granted.
            setPlayerControlEnabled(false)
            setStatus(error.message)
        }
        #endif
    }

    #if MUSIC_APP_SOURCE
    private func setPlayerControlEnabled(_ enabled: Bool) {
        playerControlEnabled = enabled
        defaults.set(enabled, forKey: Self.playerControlKey)
        if !enabled { remote.clearArtwork() }
    }

    /// Surfaces a failed Apple Event once, as a banner. Deliberately *not* a
    /// `blockedPermission` card: control is an enhancement, and the canvas is
    /// still perfectly alive without it.
    ///
    /// Replaces the call-then-check convention, where every transport call had
    /// to be followed by a second line nothing enforced — forget it and the
    /// failure was silent. The result carries the answer, so there is no
    /// second line to forget.
    private func report(_ result: Result<some Any, PlayerRemoteError>) {
        guard case .failure(let error) = result else { return }
        setStatus(error.message)
        // Only a real refusal rolls the opt-in back. A player that isn't
        // running, or a script that threw, leaves the grant alone.
        if error.revokesPlayerControl { setPlayerControlEnabled(false) }
    }

    /// Asks every running scriptable player what it's playing. Only runs when
    /// the user already opted in, so it never triggers the prompt itself; it
    /// exists to close the "launched into already-playing music" gap that a
    /// broadcast-only route cannot close on its own.
    private func seedConnectedPlayers() {
        guard playerControlEnabled else { return }
        for player in MediaPlayer.all where player.isScriptable && player.isRunning {
            // Best-effort: a player that has since quit, or one we were
            // refused, shouldn't raise a banner during a background sweep the
            // user didn't ask for.
            if case .success(let update) = remote.seed(player), let update {
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
        let resolution = policy.welcomeResolution(chose: kind)
        firstRunDemoPending = false
        apply(resolution)
    }

    /// Dismisses the welcome sheet for good. On first run, reaching here with
    /// no source chosen means the user clicked Continue without granting
    /// anything — the demo is the answer to that, and the only thing that
    /// starts audio on a fresh install.
    func completeWelcome() {
        defaults.set(true, forKey: Self.welcomeKey)
        showsWelcome = false
        let resolution = policy.welcomeResolution(chose: nil)
        firstRunDemoPending = false
        apply(resolution)
    }

    private func apply(_ resolution: PlaybackPolicy.WelcomeResolution) {
        switch resolution {
        case .startDemo:
            startDemo()
        case .switchSource(let kind):
            sourceKind = kind
        case .bringUpCurrent:
            // On first run nothing was ever started (see `onAppear`), so
            // `sourceKind`'s `didSet` won't fire and the sheet would dismiss
            // onto a dead canvas.
            handleSourceChange()
        case .doNothing:
            break
        }
    }

    /// Reopens the explainer from the Help menu.
    func showWelcome() {
        showsWelcome = true
    }

    func openPermissionSettings(_ permission: PrivacyPermission) {
        openExternal(permission.settingsURL)
    }

    // MARK: - Permissions

    func refreshPermissions() {
        screenAudioGranted = CGPreflightScreenCaptureAccess()
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// The app came back to the foreground — which is the moment a user
    /// returns from System Settings. Re-read TCC state and, if the active
    /// source was blocked and is now allowed, retry capture unprompted.
    func handleAppActivation() {
        refreshPermissions()
        if case .retryCapture = policy.activationAction() { toggleSource() }
    }

    /// "Try Again" on the permission card.
    func retryBlockedSource() {
        refreshPermissions()
        guard blockedPermission != nil, !isLive else { return }
        toggleSource()
    }

    // MARK: - Demo

    /// Switches to (or resumes) the bundled demo. The source picker doesn't
    /// list the demo; the welcome sheet and the Help menu call this instead.
    func playDemo() {
        firstRunDemoPending = false
        if sourceKind == .demo {
            if !isLive { startDemo() }
        } else {
            sourceKind = .demo
        }
    }

    // MARK: - Bringing a source up

    private func startDemo() {
        guard let url = DemoTrack.url else {
            setStatus("The bundled demo track is missing from this build.")
            return
        }
        do {
            if demoSource.currentURL != url {
                try demoSource.load(url: url)
            }
            try demoSource.play()
            statusMessage = nil
        } catch {
            setStatus("Couldn't play the demo track: \(error.localizedDescription)")
        }
        syncLiveState()
    }

    /// Starts one of the two sources the app *listens* to. They fail in the
    /// same three ways — a permission the user has to grant, a first attempt
    /// that a freshly granted permission loses, and everything else — so the
    /// reading of a failure lives in `PlaybackPolicy` and this performs it.
    private func startCapture(isRetry: Bool = false) async {
        guard !activeSource.isRunning else { return }
        do {
            try await activeSource.start()
            statusMessage = nil
            blockedPermission = nil
            refreshPermissions()
        } catch {
            // Before asking: the answer turns on whether the permission is in
            // hand *now*, which is exactly what a failed start casts doubt on.
            refreshPermissions()
            switch policy.startFailure(for: error, isRetry: isRetry) {
            case .blocked(let permission):
                blockedPermission = permission
            case .retryQuietly:
                try? await Task.sleep(for: .milliseconds(350))
                await startCapture(isRetry: true)
            case .banner(let message):
                setStatus(message)
            }
        }
        syncLiveState()
    }

    /// Plays the chosen file, or asks for one if there isn't one yet.
    private func startFileSource() {
        guard let fileURL else {
            openFilePanel()
            return
        }
        do {
            // After a relaunch the bookmark restored fileURL, but the source
            // has nothing loaded yet.
            if fileSource.currentURL != fileURL {
                try fileSource.load(url: fileURL)
            }
            try fileSource.play()
        } catch {
            setStatus(error.localizedDescription)
        }
        syncLiveState()
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
            try fileSource.load(url: url)
            adoptFile(url)
            sourceKind = .audioFile
            try fileSource.play()
            statusMessage = nil
        } catch {
            setStatus("Couldn't open \(url.lastPathComponent): \(error.localizedDescription)")
        }
        syncLiveState()
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

    /// Tears everything down (all sources stopped, analyzer cleared so the
    /// old source's tail doesn't linger) and brings up whatever the new
    /// source needs. Stopping every source unconditionally is still simpler
    /// than tracking which one was running, and now it is one line.
    private func handleSourceChange() {
        Task {
            for source in allSources { await source.stop() }
            syncLiveState()
            analyzer.reset()
            statusMessage = nil
            blockedPermission = nil

            switch policy.bringUpAction() {
            case .start:
                if sourceKind == .systemAudio {
                    // Detection keeps running across source changes, but a
                    // Player that has been sitting paused since before the
                    // switch will not re-announce itself, so ask. Scoped to
                    // this source because asking means an Apple Event.
                    seedConnectedPlayers()
                }
                await startActiveSource()
            case .refreshDevices:
                inputDevices = AudioInputDeviceList.all()
            case .loadAndPlayFile:
                startFileSource()
            case .doNothing:
                break
            }
        }
    }

    // MARK: - Power

    /// Holds an activity assertion while audio is flowing, so a fullscreen
    /// visualizer doesn't get interrupted by the display going to sleep — and,
    /// just as importantly, releases it the moment nothing is playing so an
    /// idle window isn't holding the machine awake.
    private func refreshPowerAssertion() {
        let shouldHold = isLive
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

/// Hands a URL to the system — a web page from the Help menu, or an
/// `x-apple.systempreferences:` deep link into the pane a permission lives in.
///
/// One wrapper because there were two: `AppState.openPermissionSettings` and a
/// private `SynesthiaApp.open(_:)` that did the same thing for the Help menu's
/// five links.
func openExternal(_ url: URL?) {
    guard let url else { return }
    NSWorkspace.shared.open(url)
}

func openExternal(_ urlString: String) {
    openExternal(URL(string: urlString))
}
