import AppKit
import Observation

// MARK: - Player catalog

/// A media player Synesthia can read now-playing metadata from.
///
/// The table below is the whole integration surface: adding a player is one
/// row, because every field here is data. `notificationNames` are the
/// distributed notifications the player broadcasts; `isScriptable` says
/// whether `PlayerRemote` also has an AppleScript dialect for it (transport
/// and cover art), which only exists in builds defining `MUSIC_APP_SOURCE`.
///
/// **Verifying a new player** before adding a row: run a tiny listener that
/// registers for `nil`-named distributed notifications (or the candidate name)
/// and dumps `userInfo`, then play/pause in the app. Players that follow the
/// iTunes convention — `Name`, `Artist`, `Album`, `Player State` — need
/// nothing but the row. A player whose keys don't match simply never produces
/// a parseable report, so a wrong guess is inert rather than harmful; it is
/// still not worth shipping one unverified.
struct MediaPlayer: Identifiable, Hashable, Sendable {
    let id: String
    /// Shown in the UI ("Playing in Spotify"), so it is the player's own name.
    let name: String
    let bundleID: String
    let notificationNames: [String]
    let isScriptable: Bool

    /// Music.app posts the same payload under two names — the `Music` one and
    /// an `iTunes` alias kept for compatibility. Both are registered because
    /// `NowPlayingObserver.ingest` is idempotent, so the duplicate costs
    /// nothing and neither name has to be trusted on its own.
    static let music = MediaPlayer(
        id: "music",
        name: "Music",
        bundleID: "com.apple.Music",
        notificationNames: ["com.apple.Music.playerInfo", "com.apple.iTunes.playerInfo"],
        isScriptable: true)

    static let spotify = MediaPlayer(
        id: "spotify",
        name: "Spotify",
        bundleID: "com.spotify.client",
        notificationNames: ["com.spotify.client.PlaybackStateChanged"],
        isScriptable: true)

    static let all: [MediaPlayer] = [.music, .spotify]

    static func player(id: String) -> MediaPlayer? {
        all.first { $0.id == id }
    }

    /// Whether the player is running right now. Checked before scripting it so
    /// we never *launch* a player just by asking it something, and used to
    /// evict metadata for a player that has quit.
    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// The player's Dock icon, for the corner badge on the artwork tile.
    /// `NSRunningApplication.icon` reads the icon of an already-running process
    /// and needs no file access, so it works inside the sandbox — unlike
    /// `NSWorkspace.icon(forFile:)` against a path in /Applications.
    var icon: NSImage? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.icon
    }
}

// MARK: - Track

/// One player's report of what it is playing.
struct NowPlayingTrack: Equatable, Sendable {
    var title: String
    var artist: String
    var album: String
    /// The player's own stable id for the track (`PersistentID` in Music, a
    /// `spotify:track:…` URI in Spotify), when it sends one. Only used to tell
    /// two tracks apart that share a title, so an empty value is fine.
    var identity: String
    var isPlaying: Bool

    /// What cover art is filed under, so a slow fetch can't land on the next
    /// song. Prefers the player's own id and falls back to the metadata, which
    /// changes for exactly the same reason a track id would.
    var artworkKey: String {
        identity.isEmpty ? "\(title)|\(artist)|\(album)" : identity
    }

    /// What the badge's gradient tile is derived from — the album, so every
    /// track on one record shares a colour and the badge stops flickering
    /// through a hue per song. Falls back to the title for singles and for
    /// players that send no album.
    var paletteSeed: String {
        album.isEmpty ? "\(artist)|\(title)" : "\(artist)|\(album)"
    }
}

/// What a single notification told us. `.stopped` is deliberately distinct
/// from a paused track: a player posts it with no metadata when playback ends
/// altogether, and it means "there is nothing playing" — the badge should go
/// away rather than freeze on the last song.
enum PlayerUpdate: Equatable, Sendable {
    case track(NowPlayingTrack)
    case stopped
}

// MARK: - Observer

/// Watches every player in `MediaPlayer.all` and publishes whatever is playing.
///
/// This is the App-Store-safe half of the now-playing story, and it asks for
/// **nothing**. Media players broadcast their state as *distributed
/// notifications* — the ancient system-wide `NSNotification` bus — and the
/// payload includes title, artist, album and player state. No Apple Events, no
/// Automation permission, no TCC prompt, no entitlement, and (verified on
/// macOS 26.5) the `userInfo` dictionary survives delivery into a sandboxed
/// receiver. The frequently repeated claim that the sandbox strips `userInfo`
/// applies to sandboxed *senders*, which is a different rule.
///
/// Two things it cannot do, both by construction — a broadcast is all we get:
///
/// - **No cover art.** Nobody puts image bytes in a distributed notification.
///   The badge draws a palette-derived tile instead (see `ArtworkTile`), and
///   builds with `MUSIC_APP_SOURCE` fetch the real thing over Apple Events.
/// - **No state until something changes.** A player only posts on a
///   transition, so launching Synesthia into already-playing music shows no
///   badge until the next track or play/pause. `PlayerRemote.seed` closes that
///   gap where it exists; in the App Store build the badge simply arrives a
///   song late, which is why nothing else in the UI depends on it.
@Observable
final class NowPlayingObserver {
    /// The track to show: the player that most recently said it was playing,
    /// falling back to the most recent report of any kind so a paused song
    /// still reads. `nil` when nothing has reported, or everything stopped.
    private(set) var current: (player: MediaPlayer, track: NowPlayingTrack)?
    /// The current player's Dock icon, resolved once per player rather than
    /// per SwiftUI render — `NSRunningApplication` lookups are cheap but not
    /// free, and the badge's body runs far more often than the player changes.
    private(set) var playerIcon: NSImage?

    /// Per-player latest report, with the arrival order that ranks them.
    private var reports: [String: (track: NowPlayingTrack, sequence: Int)] = [:]
    private var sequence = 0
    private var relays: [NotificationRelay] = []
    /// Called after `current` changes, so the owner can chase cover art for
    /// the newly-detected track. Never fires for a no-op notification.
    var onTrackChange: ((MediaPlayer, NowPlayingTrack) -> Void)?

    /// Registers for every known player's notifications. Idempotent.
    ///
    /// `suspensionBehavior: .deliverImmediately` is the important argument.
    /// The default coalesces notifications while the app is inactive, and
    /// inactive is the *normal* case here — the user is in Spotify choosing
    /// the next song while Synesthia renders behind it. Immediate delivery is
    /// also why this uses the selector-based API: the block-based
    /// `addObserver(forName:object:queue:using:)` has no suspension argument.
    func start() {
        guard relays.isEmpty else { return }
        let center = DistributedNotificationCenter.default()
        for player in MediaPlayer.all {
            for name in player.notificationNames {
                let relay = NotificationRelay { [weak self] userInfo in
                    // Parsed off the main actor into a Sendable value, so only
                    // that crosses the hop — `userInfo` itself never does.
                    let update = Self.update(from: userInfo)
                    Task { @MainActor in self?.ingest(update, from: player) }
                }
                center.addObserver(
                    relay, selector: #selector(NotificationRelay.receive(_:)),
                    name: Notification.Name(name), object: nil,
                    suspensionBehavior: .deliverImmediately)
                relays.append(relay)
            }
        }
        // A player that quits keeps no state worth showing.
        let workspace = NSWorkspace.shared.notificationCenter
        let terminated = NotificationRelay { [weak self] userInfo in
            let app = userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            Task { @MainActor in self?.evict(bundleID: bundleID) }
        }
        workspace.addObserver(
            terminated, selector: #selector(NotificationRelay.receive(_:)),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        relays.append(terminated)
    }

    // MARK: - Ingest

    /// Folds one player's update into the published state. Idempotent: an
    /// update that says nothing new leaves `sequence` and `current` alone, so
    /// Music's duplicate `iTunes`-aliased notification is free and a repeated
    /// poll can't reshuffle which player is winning.
    func ingest(_ update: PlayerUpdate?, from player: MediaPlayer) {
        switch update {
        case .none:
            return
        case .stopped:
            guard reports.removeValue(forKey: player.id) != nil else { return }
        case .track(let track):
            if reports[player.id]?.track == track { return }
            sequence += 1
            reports[player.id] = (track, sequence)
        }
        republish()
    }

    /// Drops a player's report when its app quits. A `nil` bundle id (the
    /// notification arrived without one) is ignored rather than treated as a
    /// wildcard — clearing every player would be worse than doing nothing.
    func evict(bundleID: String?) {
        guard let bundleID,
            let player = MediaPlayer.all.first(where: { $0.bundleID == bundleID }),
            reports.removeValue(forKey: player.id) != nil
        else { return }
        republish()
    }

    /// Ranks the reports and publishes the winner: whoever most recently said
    /// "playing", else whoever reported most recently at all. Two players
    /// running at once (Music paused, Spotify playing) is the case this
    /// exists for, and the one making sound should win regardless of order.
    private func republish() {
        let ranked = reports.sorted { $0.value.sequence > $1.value.sequence }
        let winner = ranked.first { $0.value.track.isPlaying } ?? ranked.first
        guard let winner, let player = MediaPlayer.player(id: winner.key) else {
            current = nil
            playerIcon = nil
            return
        }
        let track = winner.value.track
        let changed = current?.player != player || current?.track != track
        if current?.player != player { playerIcon = player.icon }
        current = (player, track)
        if changed { onTrackChange?(player, track) }
    }

    // MARK: - Parsing

    /// Reads one notification's `userInfo` into an update.
    ///
    /// The key spellings are a small dialect problem: Music and Spotify agree
    /// on `Name`/`Artist`/`Album`/`Player State` but disagree elsewhere
    /// (`PersistentID` vs `Track ID`), and other players in the iTunes
    /// tradition vary again. Rather than a per-player key map, each field
    /// takes the first key that is present — which is also what lets a new
    /// row in `MediaPlayer.all` work with no parsing changes.
    ///
    /// `nonisolated` because it runs on whichever thread delivered the
    /// notification, before the hop to the main actor.
    nonisolated static func update(from userInfo: [AnyHashable: Any]?) -> PlayerUpdate? {
        guard let userInfo else { return nil }
        let state = string(userInfo, ["Player State", "playerState"]).lowercased()
        // A stopped player sends no metadata worth keeping.
        if state == "stopped" { return .stopped }
        let title = string(userInfo, ["Name", "Track Name", "title"])
        // Without a title there is nothing to show, and an unrecognized
        // dialect lands here — which is how an unverified player row stays
        // harmless instead of publishing an empty badge.
        guard !title.isEmpty else { return nil }
        return .track(
            NowPlayingTrack(
                title: title,
                artist: string(userInfo, ["Artist", "artist"]),
                album: string(userInfo, ["Album", "album"]),
                identity: string(userInfo, ["Track ID", "PersistentID", "Persistent ID"]),
                // Anything that isn't "playing" (paused, or a state we don't
                // recognize) is treated as not playing: the badge stays, dimmed.
                isPlaying: state == "playing"))
    }

    /// First present, non-empty value among `keys`, as a trimmed string.
    /// Numbers are stringified because track identities arrive as `NSNumber`
    /// from Music and as a URI string from Spotify.
    private nonisolated static func string(_ userInfo: [AnyHashable: Any], _ keys: [String]) -> String {
        for key in keys {
            switch userInfo[key] {
            case let text as String:
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            case let number as NSNumber:
                return number.stringValue
            default:
                continue
            }
        }
        return ""
    }
}

// MARK: - Notification relay

/// Forwards a distributed notification to a closure.
///
/// Two reasons this exists rather than a block observer. The suspension
/// behaviour Synesthia needs is only available on the selector-based
/// `addObserver`, which wants an ObjC target; and keeping that target separate
/// from `NowPlayingObserver` leaves the latter a plain `@Observable` class.
///
/// `nonisolated` on purpose. The project sets
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so this method would otherwise
/// be main-actor isolated and Swift 6 would insert an isolation check on a
/// call arriving straight from ObjC — the same trap that makes AVFAudio
/// callbacks crash if they're built in a main-actor context (see CLAUDE.md).
/// Distributed notifications do land on the main run loop in practice, so the
/// check would pass today; not depending on that costs one hop.
private final class NotificationRelay: NSObject {
    private let handler: @Sendable ([AnyHashable: Any]?) -> Void

    init(handler: @escaping @Sendable ([AnyHashable: Any]?) -> Void) {
        self.handler = handler
        super.init()
    }

    @objc nonisolated func receive(_ notification: Notification) {
        handler(notification.userInfo)
    }
}
