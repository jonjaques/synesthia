import Foundation
import Testing

@testable import Synesthia

/// Tests for the meaning of an Apple Event failure, and for the ledger that
/// remembers which player refused us.
///
/// `PlayerRemote` itself has never had a test and still doesn't: its logic is
/// private, entangled with `NSAppleScript`, and inside `#if MUSIC_APP_SOURCE`,
/// which the test bundle does not define — a test file wrapped in that
/// condition compiles to nothing and passes silently. `PlayerRemoteError` and
/// `PlayerDenials` are deliberately outside it, which is the whole reason any
/// of this is assertable.
@MainActor
struct PlayerRemoteErrorTests {

    @Test func minusSeventeenFortyThreeIsARefusal() {
        let error = PlayerRemoteError(errorNumber: -1743, player: .music)
        guard case .notPermitted(let player) = error else {
            Issue.record("-1743 should map to .notPermitted, got \(error)")
            return
        }
        #expect(player.id == MediaPlayer.music.id)
        #expect(error.revokesPlayerControl)
        #expect(error.message.contains("System Settings"))
    }

    /// The regression this exists to prevent. The old single flag set itself
    /// for -1743 and -600 alike, so "Music isn't running" told the user to go
    /// turn on a permission they had already granted.
    @Test func minusSixHundredIsNotARefusal() {
        let error = PlayerRemoteError(errorNumber: -600, player: .music)
        guard case .notRunning = error else {
            Issue.record("-600 should map to .notRunning, got \(error)")
            return
        }
        #expect(!error.revokesPlayerControl)
        #expect(!error.message.contains("System Settings"))
    }

    @Test func anUnrelatedCodeIsNeitherRefusalNorSilent() {
        let error = PlayerRemoteError(errorNumber: -2740, player: .music)
        #expect(!error.revokesPlayerControl)
        #expect(!error.message.isEmpty)
    }

    @Test func aMissingErrorNumberStillProducesAnError() {
        let error = PlayerRemoteError(errorNumber: nil, player: .music)
        guard case .scriptFailed(_, let code) = error else {
            Issue.record("a nil error number should map to .scriptFailed, got \(error)")
            return
        }
        #expect(code == nil)
        #expect(!error.revokesPlayerControl)
    }

    /// The second regression. Every non-refusal code used to assign `false` to
    /// the one flag, so an unrelated script error erased a genuine denial
    /// recorded a moment earlier.
    @Test func aDenialSurvivesAnUnrelatedFailure() {
        var denials = PlayerDenials()
        denials.record(PlayerRemoteError(errorNumber: -1743, player: .music), for: .music)
        denials.record(PlayerRemoteError(errorNumber: -2740, player: .music), for: .music)
        #expect(denials.isDenied(.music))
    }

    /// One `PlayerRemote` serves every player, so a single `Bool` meant a
    /// success against Music cleared a refusal recorded against Spotify.
    @Test func onePlayersSuccessDoesNotClearAnothersDenial() {
        var denials = PlayerDenials()
        denials.record(PlayerRemoteError(errorNumber: -1743, player: .spotify), for: .spotify)
        denials.clear(.music)
        #expect(denials.isDenied(.spotify))
        #expect(!denials.isDenied(.music))
    }

    @Test func clearingTheRightPlayerDoesLiftTheDenial() {
        var denials = PlayerDenials()
        denials.record(PlayerRemoteError(errorNumber: -1743, player: .spotify), for: .spotify)
        denials.clear(.spotify)
        #expect(!denials.isDenied(.spotify))
    }

    /// A banner that doesn't name the player is useless when two are running.
    @Test func everyMessageNamesThePlayer() {
        for code in [-1743, -600, -2740, nil] {
            let error = PlayerRemoteError(errorNumber: code, player: .spotify)
            #expect(error.message.contains("Spotify"), "code \(String(describing: code))")
        }
    }
}
