import Foundation
import Testing

@testable import Synesthia

/// Tests for the now-playing layer, which is pure data handling and so is the
/// half of this feature with correct answers rather than judgement calls.
///
/// The parsing side matters because the *input is not ours*: media players
/// broadcast whatever `userInfo` they feel like, the key spellings differ
/// between them, and the payloads arrive from outside the app. The
/// dictionaries in `Payloads` below are transcribed verbatim from real
/// notifications (Music.app captured on macOS 26.5; Spotify from its
/// documented broadcast), so a regression here means the badge is wrong for
/// somebody's actual player rather than for a hypothetical one.
@MainActor
struct NowPlayingTests {

    // MARK: - Fixtures

    /// Real notification payloads. Note the deliberate type mixture: Music
    /// sends its track id as an `NSNumber` and Spotify sends a URI string, and
    /// both spell almost — but not quite — the same keys.
    private enum Payloads {
        static let musicPlaying: [AnyHashable: Any] = [
            "Name": "heart pt. 6",
            "Artist": "Kendrick Lamar",
            "Album": "GNX",
            "Genre": "Hip-Hop/Rap",
            "Player State": "Playing",
            "Total Time": NSNumber(value: 292_504),
            "PersistentID": NSNumber(value: 4_434_885_207_211_638_351),
            "Library PersistentID": NSNumber(value: -6_057_206_176_339_051_187),
        ]

        static let musicPaused: [AnyHashable: Any] = {
            var info = musicPlaying
            info["Player State"] = "Paused"
            return info
        }()

        static let spotifyPlaying: [AnyHashable: Any] = [
            "Name": "Sorry",
            "Artist": "Justin Bieber",
            "Album": "Purpose (Deluxe)",
            "Album Artist": "Justin Bieber",
            "Player State": "Playing",
            "Duration": NSNumber(value: 200_786),
            "Track ID": "spotify:track:69bp2EbF7Q2rqc5N3ylezZ",
            "Playback Position": NSNumber(value: 70.335),
            "Has Artwork": NSNumber(value: true),
            "Track Number": NSNumber(value: 4),
        ]
    }

    private func track(_ update: PlayerUpdate?) -> NowPlayingTrack? {
        guard case .track(let track) = update else { return nil }
        return track
    }

    // MARK: - Parsing

    @Test func parsesMusicPayload() {
        let track = track(NowPlayingObserver.update(from: Payloads.musicPlaying))
        #expect(track?.title == "heart pt. 6")
        #expect(track?.artist == "Kendrick Lamar")
        #expect(track?.album == "GNX")
        #expect(track?.isPlaying == true)
        // Music's id arrives as a number; it has to survive as a string or
        // artwork gets filed under the wrong key.
        #expect(track?.identity == "4434885207211638351")
    }

    @Test func parsesSpotifyPayload() {
        // The dialect difference that matters: `Track ID` instead of
        // `PersistentID`. Everything else lines up with Music.
        let track = track(NowPlayingObserver.update(from: Payloads.spotifyPlaying))
        #expect(track?.title == "Sorry")
        #expect(track?.artist == "Justin Bieber")
        #expect(track?.album == "Purpose (Deluxe)")
        #expect(track?.isPlaying == true)
        #expect(track?.identity == "spotify:track:69bp2EbF7Q2rqc5N3ylezZ")
    }

    @Test func pausedIsATrackNotAStop() {
        // A paused player keeps its badge — dimmed — so this must parse as a
        // track that isn't playing, not as `.stopped`.
        let update = NowPlayingObserver.update(from: Payloads.musicPaused)
        #expect(track(update)?.isPlaying == false)
        #expect(update != .stopped)
    }

    @Test func stoppedClearsRegardlessOfMetadata() {
        // Players post "Stopped" both bare and with the last track's metadata
        // still attached. Either way it means "nothing is playing".
        #expect(NowPlayingObserver.update(from: ["Player State": "Stopped"]) == .stopped)
        var withMetadata = Payloads.musicPlaying
        withMetadata["Player State"] = "Stopped"
        #expect(NowPlayingObserver.update(from: withMetadata) == .stopped)
    }

    @Test func unparseablePayloadsAreIgnored() {
        // This is what keeps an unverified player row in `MediaPlayer.all`
        // inert rather than harmful: a dialect we can't read produces nothing
        // at all, never an empty badge.
        #expect(NowPlayingObserver.update(from: nil) == nil)
        #expect(NowPlayingObserver.update(from: [:]) == nil)
        #expect(NowPlayingObserver.update(from: ["Player State": "Playing"]) == nil)
        #expect(NowPlayingObserver.update(from: ["trackTitle": "Unknown Dialect"]) == nil)
        // Present but blank counts as absent, or a whitespace title would
        // publish a badge with nothing in it.
        #expect(NowPlayingObserver.update(from: ["Name": "   ", "Artist": "X"]) == nil)
    }

    @Test func unknownStateIsTreatedAsNotPlaying() {
        // Never assume playing: a badge that claims to be playing while the
        // canvas is silent is worse than one that reads as paused.
        var info = Payloads.musicPlaying
        info["Player State"] = "Buffering"
        #expect(track(NowPlayingObserver.update(from: info))?.isPlaying == false)
        info.removeValue(forKey: "Player State")
        #expect(track(NowPlayingObserver.update(from: info))?.isPlaying == false)
    }

    // MARK: - Arbitration

    @Test func mostRecentReportWins() {
        let observer = NowPlayingObserver()
        observer.ingest(NowPlayingObserver.update(from: Payloads.musicPlaying), from: .music)
        #expect(observer.current?.player == .music)
        observer.ingest(NowPlayingObserver.update(from: Payloads.spotifyPlaying), from: .spotify)
        #expect(observer.current?.player == .spotify)
        #expect(observer.current?.track.title == "Sorry")
    }

    @Test func playingBeatsPausedRegardlessOfOrder() {
        // The case this exists for: Music left paused, Spotify actually making
        // the sound. Whoever is playing owns the badge even if they reported
        // first.
        let observer = NowPlayingObserver()
        observer.ingest(NowPlayingObserver.update(from: Payloads.spotifyPlaying), from: .spotify)
        observer.ingest(NowPlayingObserver.update(from: Payloads.musicPaused), from: .music)
        #expect(observer.current?.player == .spotify)
    }

    @Test func pausedTrackSurvivesWhenNothingIsPlaying() {
        let observer = NowPlayingObserver()
        observer.ingest(NowPlayingObserver.update(from: Payloads.musicPaused), from: .music)
        #expect(observer.current?.player == .music)
        #expect(observer.current?.track.isPlaying == false)
    }

    @Test func stopRemovesOnlyThatPlayer() {
        let observer = NowPlayingObserver()
        observer.ingest(NowPlayingObserver.update(from: Payloads.musicPaused), from: .music)
        observer.ingest(NowPlayingObserver.update(from: Payloads.spotifyPlaying), from: .spotify)
        observer.ingest(.stopped, from: .spotify)
        #expect(observer.current?.player == .music)
        observer.ingest(.stopped, from: .music)
        #expect(observer.current == nil)
    }

    @Test func duplicateReportsAreIdempotent() {
        // Music posts the same payload under both `com.apple.Music.playerInfo`
        // and its `iTunes` alias, and both names are registered. If the second
        // one re-ranked the reports, the alias alone could steal the badge from
        // a player that is actually playing.
        let observer = NowPlayingObserver()
        observer.ingest(NowPlayingObserver.update(from: Payloads.spotifyPlaying), from: .spotify)
        observer.ingest(NowPlayingObserver.update(from: Payloads.musicPaused), from: .music)
        observer.ingest(NowPlayingObserver.update(from: Payloads.musicPaused), from: .music)
        observer.ingest(NowPlayingObserver.update(from: Payloads.musicPaused), from: .music)
        #expect(observer.current?.player == .spotify)
    }

    @Test func trackChangeFiresOnceForRealChangesOnly() {
        let observer = NowPlayingObserver()
        var changes = 0
        observer.onTrackChange = { _, _ in changes += 1 }
        observer.ingest(NowPlayingObserver.update(from: Payloads.musicPlaying), from: .music)
        observer.ingest(NowPlayingObserver.update(from: Payloads.musicPlaying), from: .music)
        #expect(changes == 1)
        // A play/pause transition is a change worth republishing, but the
        // artwork chase it triggers is keyed on `artworkKey`, which is stable
        // across it — so no refetch happens.
        observer.ingest(NowPlayingObserver.update(from: Payloads.musicPaused), from: .music)
        #expect(changes == 2)
    }

    @Test func evictionIgnoresNilAndUnknownBundles() {
        let observer = NowPlayingObserver()
        observer.ingest(NowPlayingObserver.update(from: Payloads.musicPlaying), from: .music)
        // A terminate notification with no bundle id must not be read as a
        // wildcard — clearing every player would be worse than doing nothing.
        observer.evict(bundleID: nil)
        observer.evict(bundleID: "com.example.SomethingElse")
        #expect(observer.current?.player == .music)
        observer.evict(bundleID: MediaPlayer.music.bundleID)
        #expect(observer.current == nil)
    }

    // MARK: - Derived values

    @Test func artworkKeyPrefersTheIdentity() {
        let track = NowPlayingTrack(
            title: "A", artist: "B", album: "C", identity: "id-1", isPlaying: true)
        #expect(track.artworkKey == "id-1")
        // Without one it has to fall back to something that still changes per
        // track, or slow-arriving art lands on the wrong song.
        var anonymous = track
        anonymous.identity = ""
        #expect(anonymous.artworkKey == "A|B|C")
        var nextSong = anonymous
        nextSong.title = "D"
        #expect(nextSong.artworkKey != anonymous.artworkKey)
    }

    @Test func paletteSeedIsPerAlbumNotPerTrack() {
        // The tile's colour should belong to the record, so playing straight
        // through an album doesn't strobe through hues.
        let first = NowPlayingTrack(
            title: "wacced out murals", artist: "Kendrick Lamar", album: "GNX",
            identity: "1", isPlaying: true)
        let second = NowPlayingTrack(
            title: "heart pt. 6", artist: "Kendrick Lamar", album: "GNX",
            identity: "2", isPlaying: true)
        #expect(first.paletteSeed == second.paletteSeed)
        // A single with no album still needs a seed of its own.
        var single = first
        single.album = ""
        #expect(single.paletteSeed != first.paletteSeed)
        #expect(!single.paletteSeed.isEmpty)
    }

    @Test func paletteOffsetIsStableAndSpread() {
        // Stability across launches is the whole point of hand-rolling FNV-1a
        // instead of using `hashValue`, whose seed changes per process. This
        // test can only prove determinism within a run; the pinned literals
        // are what would catch the hash being swapped out.
        #expect(ArtworkTile.paletteOffset(for: "Kendrick Lamar|GNX") == 0.154)
        #expect(ArtworkTile.paletteOffset(for: "Justin Bieber|Purpose (Deluxe)") == 0.443)
        #expect(ArtworkTile.paletteOffset(for: "") == 0.037)

        for seed in ["a", "b", "Radiohead|Kid A", "", "🎵"] {
            let t = ArtworkTile.paletteOffset(for: seed)
            #expect(t >= 0 && t < 1)
            #expect(t == ArtworkTile.paletteOffset(for: seed))
        }
    }
}
