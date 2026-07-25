import AppKit
import Observation

/// Controls the Music app over Apple Events and mirrors its now-playing state.
/// The first command triggers macOS's automation consent prompt.
@Observable
final class MusicController {
    struct TrackInfo: Equatable {
        var title = ""
        var artist = ""
        var album = ""
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
    private var compiledScripts = [String: NSAppleScript]()

    var isMusicAppRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.Music" }
    }

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
        run("""
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
        let result = run("""
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

    private func fetchArtwork() {
        let result = run("""
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
