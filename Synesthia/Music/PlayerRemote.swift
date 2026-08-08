import AppKit
import Observation

// Apple Events are compiled out of the Mac App Store configuration entirely.
// Only builds that define MUSIC_APP_SOURCE (Debug and Direct) contain any
// AppleScript, and only those ship the matching entitlements — see
// Synesthia-Direct.entitlements and docs/app-store-launch-plan.md §B5.
//
// Nothing else in the app depends on this file existing: `NowPlayingObserver`
// already knows the title, artist and album of whatever is playing without
// sending a single Apple Event. What this adds is the two things a broadcast
// cannot carry — transport control and real cover art — as an opt-in layer on
// top. See docs/macos-integration.md for the three-layer picture.
#if MUSIC_APP_SOURCE

/// Drives a scriptable media player over Apple Events, and pulls its cover art.
///
/// The first event sent triggers macOS's Automation consent prompt, so nothing
/// here runs on its own: `AppState` calls `connect(to:)` only when the user
/// asks for playback control, and only re-seeds automatically on later launches
/// once that has succeeded. A user who never opts in never sees the prompt and
/// still gets the now-playing badge.
///
/// Every script below is a **complete literal** per player rather than a
/// template with the app name interpolated in. That is deliberate:
/// `scripts/build-appstore.sh` asserts that no `tell application "…"` string
/// survives into the App Store binary, and building the scripts by
/// interpolation would delete the very string that assertion looks for.
@Observable
final class PlayerRemote {
    /// Cover art for `artworkIdentity`, or nil when we have none.
    private(set) var artwork: NSImage?
    /// Which track `artwork` belongs to, so a stale image is never shown
    /// against a new song.
    private(set) var artworkIdentity: String?
    /// Which players have refused us, keyed by player. Written only by a real
    /// refusal (-1743) — see `PlayerDenials`.
    private var denials = PlayerDenials()

    /// Artwork can lag a track change, especially when streaming, so a few
    /// attempts are allowed per track before giving up.
    private var artworkAttempts = 0
    /// `NSAppleScript` compiles its source on first execution; caching the
    /// compiled object per source string keeps repeat calls cheap.
    private var compiledScripts = [String: NSAppleScript]()

    // MARK: - Transport

    /// Resume or pause. Unlike the old Music-only path this never tries to
    /// *start* a stopped player: transport is only offered once a track has
    /// been detected, so there is always something to resume.
    ///
    /// The three transport calls return the outcome rather than setting a flag
    /// for the caller to remember to read afterwards. `@discardableResult` only
    /// so a future best-effort caller can opt out deliberately; every call site
    /// in `AppState` passes the result through `report(_:)`.
    @discardableResult
    func togglePlayPause(_ player: MediaPlayer) -> Result<Void, PlayerRemoteError> {
        run(Scripts.togglePlayPause(player), on: player).map { _ in () }
    }

    @discardableResult
    func nextTrack(_ player: MediaPlayer) -> Result<Void, PlayerRemoteError> {
        run(Scripts.nextTrack(player), on: player).map { _ in () }
    }

    @discardableResult
    func previousTrack(_ player: MediaPlayer) -> Result<Void, PlayerRemoteError> {
        run(Scripts.previousTrack(player), on: player).map { _ in () }
    }

    /// Whether this specific player has refused an Apple Event.
    func isDenied(_ player: MediaPlayer) -> Bool { denials.isDenied(player) }

    // MARK: - Seeding

    /// Asks a player what it is playing right now.
    ///
    /// This is the fix for the one real gap in the notification route: a player
    /// broadcasts only on a *transition*, so launching Synesthia into
    /// already-playing music otherwise shows no badge until the next song.
    ///
    /// The three ways this used to return `nil` are now three different
    /// answers: `.failure(.notRunning)`, `.failure(.notPermitted)`, and
    /// `.success(nil)` for a blank reply. That last one is not a failure —
    /// Spotify's scripting interface has a long history of intermittently
    /// returning an empty title, and publishing it would replace a good badge
    /// with an empty one, but it says nothing about our permissions.
    func seed(_ player: MediaPlayer) -> Result<PlayerUpdate?, PlayerRemoteError> {
        guard player.isScriptable, player.isRunning else {
            return .failure(.notRunning(player))
        }
        guard let source = Scripts.nowPlaying(player) else {
            return .failure(.scriptFailed(player, code: nil))
        }
        switch run(source, on: player) {
        case .failure(let error):
            return .failure(error)
        case .success(let descriptor):
            guard let text = descriptor.stringValue else { return .success(nil) }
            let parts = text.components(separatedBy: "\n")
            guard let state = parts.first else { return .success(nil) }
            if state == "stopped" { return .success(.stopped) }
            guard parts.count >= 5, !parts[1].isEmpty else { return .success(nil) }
            return .success(
                .track(
                    NowPlayingTrack(
                        title: parts[1], artist: parts[2], album: parts[3],
                        identity: parts[4], isPlaying: state == "playing")))
        }
    }

    // MARK: - Artwork

    /// Starts fetching cover art for a newly detected track, discarding
    /// whatever was on screen for the previous one.
    func beginArtwork(for player: MediaPlayer, identity: String) {
        artwork = nil
        artworkIdentity = identity
        artworkAttempts = 0
        refreshArtwork(for: player, identity: identity)
    }

    /// One artwork attempt. Safe to call repeatedly; it stops once the image
    /// has arrived, the track has moved on, or three tries have failed.
    ///
    /// Only players that hand over image *bytes* locally are supported.
    /// Spotify's dictionary exposes an `artwork url` on its CDN instead, and
    /// fetching that would mean a network request per track — a privacy cost
    /// the palette tile avoids entirely, so Spotify keeps the tile.
    func refreshArtwork(for player: MediaPlayer, identity: String) {
        guard artwork == nil, artworkIdentity == identity, artworkAttempts < 3,
            player.isRunning, let source = Scripts.artwork(player)
        else { return }
        artworkAttempts += 1
        // Artwork is best-effort and already capped at three attempts, so a
        // failure here is dropped on purpose rather than banner-ed — but taken
        // explicitly, so "we ignore this" is visible instead of implied.
        guard case .success(let descriptor) = run(source, on: player),
            !descriptor.data.isEmpty,
            let image = NSImage(data: descriptor.data)
        else { return }
        artwork = image
    }

    func clearArtwork() {
        artwork = nil
        artworkIdentity = nil
        artworkAttempts = 0
    }

    // MARK: - Scripting

    /// Compiles (once) and runs a snippet, handing the outcome back rather
    /// than interpreting it. What an error *means* is `PlayerRemoteError`'s
    /// job, and what to do about it is the caller's; this only records a real
    /// refusal against the player it came from.
    private func run(
        _ source: String?, on player: MediaPlayer
    ) -> Result<NSAppleEventDescriptor, PlayerRemoteError> {
        guard let source else { return .failure(.scriptFailed(player, code: nil)) }
        let script: NSAppleScript
        if let cached = compiledScripts[source] {
            script = cached
        } else {
            guard let fresh = NSAppleScript(source: source) else {
                return .failure(.scriptFailed(player, code: nil))
            }
            compiledScripts[source] = fresh
            script = fresh
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let failure = PlayerRemoteError(
                errorNumber: error[NSAppleScript.errorNumber] as? Int, player: player)
            denials.record(failure, for: player)
            return .failure(failure)
        }
        denials.clear(player)
        return .success(result)
    }
}

// MARK: - Scripts

/// The AppleScript dialect for each scriptable player, one complete literal per
/// (player, command) pair. Adding a player means adding its four scripts here
/// and flipping `isScriptable` on its `MediaPlayer` row.
///
/// The shared trap, and the reason the state scripts look repetitive: **an
/// AppleScript constant cannot be coerced to text.** `player state as text`
/// throws, so the state is mapped to a string with comparisons instead. The
/// failure is invisible from Swift — the script simply returns nil.
private enum Scripts {
    static func togglePlayPause(_ player: MediaPlayer) -> String? {
        switch player.id {
        case MediaPlayer.music.id: "tell application \"Music\" to playpause"
        case MediaPlayer.spotify.id: "tell application \"Spotify\" to playpause"
        default: nil
        }
    }

    static func nextTrack(_ player: MediaPlayer) -> String? {
        switch player.id {
        case MediaPlayer.music.id: "tell application \"Music\" to next track"
        case MediaPlayer.spotify.id: "tell application \"Spotify\" to next track"
        default: nil
        }
    }

    static func previousTrack(_ player: MediaPlayer) -> String? {
        switch player.id {
        case MediaPlayer.music.id: "tell application \"Music\" to previous track"
        case MediaPlayer.spotify.id: "tell application \"Spotify\" to previous track"
        default: nil
        }
    }

    /// Player state and current-track metadata in one round-trip, returned as
    /// a linefeed-separated string because AppleScript's structured return
    /// types are painful to unpack from Swift. Parsed by `PlayerRemote.seed`,
    /// which expects `state, title, artist, album, identity`.
    static func nowPlaying(_ player: MediaPlayer) -> String? {
        switch player.id {
        case MediaPlayer.music.id:
            """
            tell application "Music"
                set stateText to "stopped"
                if player state is playing then
                    set stateText to "playing"
                else if player state is paused then
                    set stateText to "paused"
                end if
                if stateText is not "stopped" then
                    try
                        set t to current track
                        return stateText & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & ((database ID of t) as text)
                    end try
                end if
                return stateText
            end tell
            """
        case MediaPlayer.spotify.id:
            """
            tell application "Spotify"
                set stateText to "stopped"
                if player state is playing then
                    set stateText to "playing"
                else if player state is paused then
                    set stateText to "paused"
                end if
                if stateText is not "stopped" then
                    try
                        set t to current track
                        return stateText & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & (id of t)
                    end try
                end if
                return stateText
            end tell
            """
        default:
            nil
        }
    }

    /// Raw cover-art bytes. `raw data` is the original JPEG/PNG and is
    /// preferred; `data` (a PICT-flavored fallback) still decodes via NSImage
    /// when `raw data` is missing. Spotify is absent on purpose — it offers
    /// only a remote `artwork url`, see `PlayerRemote.refreshArtwork`.
    static func artwork(_ player: MediaPlayer) -> String? {
        switch player.id {
        case MediaPlayer.music.id:
            """
            tell application "Music"
                try
                    return raw data of artwork 1 of current track
                on error
                    try
                        return data of artwork 1 of current track
                    on error
                        return ""
                    end try
                end try
            end tell
            """
        default:
            nil
        }
    }
}

#endif
