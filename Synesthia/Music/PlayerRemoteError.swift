/// Why an Apple Event to a media player didn't work.
///
/// Deliberately **outside** `#if MUSIC_APP_SOURCE`, for two reasons. It is a
/// mapping from an OSA error number to a meaning — it contains no AppleScript,
/// so nothing here can reach the App Store binary that `build-appstore.sh`
/// greps for. And the test bundle does not define `MUSIC_APP_SOURCE`: a test
/// file wrapped in that condition compiles to nothing and passes silently, so
/// anything worth asserting has to live where the tests can see it.
///
/// Not `Equatable`: `MediaPlayer`'s synthesized conformance is main-actor
/// isolated under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so a synthesized
/// `==` here fails to build. Match on the cases instead.
enum PlayerRemoteError: Error {
    /// -1743, `errAEEventNotPermitted`: the user refused the Automation
    /// prompt, or revoked it in System Settings. The only case that should roll
    /// the opt-in back.
    case notPermitted(MediaPlayer)
    /// -600, `procNotFound`: the player isn't running. Not a permission
    /// problem, and sending the user to System Settings for it is a wild goose
    /// chase — which is exactly what the old single `automationDenied` flag did,
    /// because it treated this code and -1743 identically.
    case notRunning(MediaPlayer)
    /// Anything else: a dialect that changed under us, a coercion that threw, a
    /// script that wouldn't compile. Worth a banner, never worth revoking the
    /// opt-in.
    case scriptFailed(MediaPlayer, code: Int?)

    init(errorNumber: Int?, player: MediaPlayer) {
        switch errorNumber {
        case -1743: self = .notPermitted(player)
        case -600: self = .notRunning(player)
        case let code: self = .scriptFailed(player, code: code)
        }
    }

    /// True only for the case the Automation opt-in should be rolled back for.
    var revokesPlayerControl: Bool {
        if case .notPermitted = self { return true }
        return false
    }

    var message: String {
        switch self {
        case .notPermitted(let player):
            "Synesthia isn't allowed to control \(player.name). Enable it in System Settings › Privacy & Security › Automation."
        case .notRunning(let player):
            "\(player.name) isn't running."
        case .scriptFailed(let player, _):
            "Synesthia couldn't talk to \(player.name)."
        }
    }
}

/// Which players have refused us.
///
/// One `PlayerRemote` serves every player, so a single `Bool` had two ways to
/// lie: a success against Music cleared a denial recorded against Spotify, and
/// *any* unrelated script failure cleared a genuine refusal recorded a moment
/// earlier. Keyed by player, and only `notPermitted` writes to it.
struct PlayerDenials {
    private var denied: Set<String> = []

    mutating func record(_ error: PlayerRemoteError, for player: MediaPlayer) {
        if error.revokesPlayerControl { denied.insert(player.id) }
    }

    mutating func clear(_ player: MediaPlayer) { denied.remove(player.id) }

    func isDenied(_ player: MediaPlayer) -> Bool { denied.contains(player.id) }
}
