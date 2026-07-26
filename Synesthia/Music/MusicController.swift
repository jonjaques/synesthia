import AppKit
import Observation

// The entire Music.app integration is compiled out of the Mac App Store
// configuration. Only builds that define MUSIC_APP_SOURCE (Debug and Direct)
// contain any Apple Events code, and only those ship the matching
// entitlements — see Synesthia-Direct.entitlements and
// docs/app-store-launch-plan.md §B5.
#if MUSIC_APP_SOURCE

/// Controls the Music app over Apple Events and mirrors its now-playing state.
/// The first command triggers macOS's automation consent prompt.
///
/// Apple Events are macOS's ancient (but still canonical) inter-app scripting
/// mechanism; the practical way to speak them from Swift is to run small
/// AppleScript snippets via `NSAppleScript`. Music.app pushes no
/// notifications to third parties, so this class *polls* it once a second
/// while the Music source is active and republishes the results as
/// `@Observable` properties for SwiftUI.
@Observable
final class MusicController {
    struct TrackInfo: Equatable {
        var title = ""
        var artist = ""
        var album = ""
        /// Music's stable per-library track ID; used to detect track changes
        /// even between tracks with identical titles.
        var databaseID = ""
    }

    private(set) var isRunning = false
    private(set) var isPlaying = false
    private(set) var track: TrackInfo?
    private(set) var artwork: NSImage?
    /// Set when macOS refused automation of Music (error -1743) so the UI can hint at a fix.
    private(set) var automationDenied = false

    private var pollTask: Task<Void, Never>?
    private var artworkAttempts = 0
    /// `NSAppleScript` compiles its source on first execution; caching the
    /// compiled object per source string makes the 1 Hz poll cheap.
    private var compiledScripts = [String: NSAppleScript]()

    /// Checked before polling so we never *launch* Music just by asking it
    /// questions (sending any Apple Event to a closed app would start it).
    var isMusicAppRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.Music" }
    }

    /// Begins the 1-second poll loop; idempotent.
    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Transport

    /// Play/pause toggle. If Music is stopped or freshly launched, kicks off a
    /// random track from the library so "play" always produces sound.
    func togglePlayPause() {
        run(
            """
            tell application "Music"
                if player state is stopped then
                    try
                        play (some track of playlist 1)
                    on error
                        play
                    end try
                else
                    playpause
                end if
            end tell
            """)
        poll()
    }

    func nextTrack() {
        run("tell application \"Music\" to next track")
        poll()
    }

    func previousTrack() {
        run("tell application \"Music\" to previous track")
        poll()
    }

    // MARK: - Polling

    /// One poll: read player state and current-track metadata in a single
    /// script (one Apple Event round-trip), returned as a linefeed-separated
    /// string because AppleScript's structured return types are painful to
    /// unpack from Swift.
    private func poll() {
        guard isMusicAppRunning else {
            isRunning = false
            isPlaying = false
            track = nil
            artwork = nil
            return
        }
        isRunning = true
        // Note: AppleScript cannot coerce the `player state` constant to text
        // ("playing as text" throws), so map it with comparisons instead.
        let result = run(
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
            """)
        guard let text = result?.stringValue else { return }
        let parts = text.components(separatedBy: "\n")
        isPlaying = parts.first == "playing"
        if parts.count >= 5 {
            let info = TrackInfo(title: parts[1], artist: parts[2], album: parts[3], databaseID: parts[4])
            if info != track {
                track = info
                artwork = nil
                artworkAttempts = 0
            }
            // Artwork can lag behind track changes (especially streaming),
            // so retry a few polls before giving up.
            if artwork == nil, artworkAttempts < 3 {
                artworkAttempts += 1
                fetchArtwork()
            }
        } else {
            track = nil
            artwork = nil
        }
    }

    /// Pulls the current track's artwork bytes. `raw data` is the original
    /// JPEG/PNG and is preferred; `data` (a PICT-flavored fallback) still
    /// decodes via NSImage when `raw data` is missing.
    private func fetchArtwork() {
        let result = run(
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
            """)
        if let data = result?.data, !data.isEmpty, let image = NSImage(data: data) {
            artwork = image
        }
    }

    // MARK: - Scripting

    /// Compiles (once) and runs an AppleScript snippet, translating the two
    /// interesting failure codes into `automationDenied`:
    /// -1743 = user denied the Automation permission (errAEEventNotPermitted),
    /// -600  = target app not running (procNotFound).
    @discardableResult
    private func run(_ source: String) -> NSAppleEventDescriptor? {
        let script: NSAppleScript
        if let cached = compiledScripts[source] {
            script = cached
        } else {
            guard let fresh = NSAppleScript(source: source) else { return nil }
            compiledScripts[source] = fresh
            script = fresh
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int
            automationDenied = (code == -1743 || code == -600)
            return nil
        }
        automationDenied = false
        return result
    }
}

#endif
