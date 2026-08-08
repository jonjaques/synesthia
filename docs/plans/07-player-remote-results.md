# Plan 7 — Typed failures from PlayerRemote

**Deepening:** the answer comes back with the call; the sticky flag becomes derived state with a test surface.
**Strength:** worth exploring. **Branch:** one PR, independent of every other plan.
**Direct/Debug only** — this is all inside `#if MUSIC_APP_SOURCE`.

## Why

Every Apple Event result collapses into one `Bool` (PlayerRemote.swift:134–153):

```swift
var error: NSDictionary?
let result = script.executeAndReturnError(&error)
if let error {
    let code = error[NSAppleScript.errorNumber] as? Int
    automationDenied = (code == -1743 || code == -600)
    return nil
}
automationDenied = false
return result
```

Four defects fall out of that one line:

1. **-1743 and -600 are the same thing to the UI.** "The user refused Automation" and "the
   player isn't running" produce the identical banner, which tells a user to go turn on a
   permission they may already have granted (AppState.swift:483–485, :504–506 — the same
   string, written twice).
2. **An unrelated failure clears a real denial.** A script error with any other code assigns
   `false`, so a genuine refusal recorded a moment ago is erased.
3. **The flag is not per player.** One instance serves Music and Spotify; a success against
   one clears a denial recorded against the other.
4. **Callers must poll it.** The convention is call-then-check, at three sites:

   ```swift
   // AppState.swift:355-356, and again at :428-429 and :439-440
   remote.togglePlayPause(player)
   reportAutomationRefusal(for: player)
   ```

   Nothing enforces the second line. Forget it and the failure is silent.

`seed` (:76–90) returns `nil` for three different reasons — not running, refused, blank
answer — and `connectPlayerControl` (AppState.swift:470–490) disambiguates by reading
`remote.automationDenied` afterwards.

`PlayerRemote` has **zero tests**, and the reason is structural: the interesting logic is
private, entangled with `NSAppleScript`, and inside a compilation condition.

## Scope

```
Synesthia/Music/PlayerRemoteError.swift   new — pure, deliberately OUTSIDE the #if
Synesthia/Music/PlayerRemote.swift        run() returns Result; per-player denials
Synesthia/AppState.swift                  call-then-check → handle the Result
SynesthiaTests/PlayerRemoteErrorTests.swift  new
```

## The compilation-condition trap

`SynesthiaTests` does **not** define `MUSIC_APP_SOURCE`. Checked: the three test-target
build configurations (`project.pbxproj` :673–727) set only `TEST_HOST` / `BUNDLE_LOADER`;
`SWIFT_ACTIVE_COMPILATION_CONDITIONS` with `MUSIC_APP_SOURCE` appears on the two app targets
(:410, :542, :580, :620, :660) and nowhere else. A test file wrapped in
`#if MUSIC_APP_SOURCE` therefore compiles to nothing and passes silently.

So: **put the pure parts outside the `#if`.** An error enum and a denial ledger contain no
`tell application "` string, so they are safe in the App Store binary — `build-appstore.sh`
greps for that literal and nothing else changes. This is also better design: the mapping
from an OSA error number to a meaning has nothing to do with entitlements.

Only if you later want to test `PlayerRemote` _itself_ would you add
`SWIFT_ACTIVE_COMPILATION_CONDITIONS = "$(inherited) MUSIC_APP_SOURCE"` to the test target's
Debug and Direct configurations. Editing build settings in `project.pbxproj` is allowed
(`CLAUDE.md` §Project configuration constraints) — it is adding _file references_ that
corrupts the synchronized group. Don't do it in this PR; it isn't needed.

## Target design

New file `Synesthia/Music/PlayerRemoteError.swift`, unconditional:

```swift
/// Why an Apple Event to a media player didn't work.
///
/// Deliberately outside `#if MUSIC_APP_SOURCE`: this is a mapping from an OSA
/// error number to a meaning, it contains no AppleScript, and keeping it
/// unconditional is what lets the test target see it at all (the test bundle
/// does not define that flag — see docs/plans/07).
enum PlayerRemoteError: Error {
    /// -1743, errAEEventNotPermitted: the user refused the Automation prompt,
    /// or revoked it in System Settings.
    case notPermitted(MediaPlayer)
    /// -600, procNotFound: the player isn't running. Not a permission problem,
    /// and telling the user to visit System Settings for it is a wild goose
    /// chase — which is what the single `automationDenied` flag used to do.
    case notRunning(MediaPlayer)
    /// Anything else: a dialect that changed under us, a coercion that threw.
    /// Worth a banner, never worth revoking the opt-in.
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

/// Which players have refused us, so one player's success can't clear
/// another's denial — and an unrelated script failure can't clear either.
struct PlayerDenials {
    private var denied: Set<String> = []

    mutating func record(_ error: PlayerRemoteError, for player: MediaPlayer) {
        if error.revokesPlayerControl { denied.insert(player.id) }
    }

    mutating func clear(_ player: MediaPlayer) { denied.remove(player.id) }

    func isDenied(_ player: MediaPlayer) -> Bool { denied.contains(player.id) }
}
```

`PlayerRemote.run` returns a `Result` and stops owning the interpretation:

```swift
private func run(
    _ source: String?, on player: MediaPlayer
) -> Result<NSAppleEventDescriptor, PlayerRemoteError> {
    guard let source, let script = compiled(source) else {
        return .failure(.scriptFailed(player, code: nil))
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
```

The public surface becomes:

```swift
@discardableResult func togglePlayPause(_ player: MediaPlayer) -> Result<Void, PlayerRemoteError>
@discardableResult func nextTrack(_ player: MediaPlayer)      -> Result<Void, PlayerRemoteError>
@discardableResult func previousTrack(_ player: MediaPlayer)  -> Result<Void, PlayerRemoteError>
func seed(_ player: MediaPlayer) -> Result<PlayerUpdate?, PlayerRemoteError>   // .success(nil) == blank answer
func isDenied(_ player: MediaPlayer) -> Bool
```

Note `seed`'s three-way `nil` finally separates: `.failure(.notRunning)`,
`.failure(.notPermitted)`, and `.success(nil)` for the blank answer Spotify's scripting
interface intermittently returns (the case the doc comment at :71–75 describes).

`AppState` replaces call-then-check with one handler, deleting the duplicated banner string:

```swift
private func report(_ result: Result<some Any, PlayerRemoteError>) {
    guard case .failure(let error) = result else { return }
    setStatus(error.message)
    if error.revokesPlayerControl { setPlayerControlEnabled(false) }
}
```

so `nextTrack()` becomes `report(remote.nextTrack(player))` and `connectPlayerControl`
(:470–490) stops reading a flag after the fact:

```swift
switch remote.seed(player) {
case .success(let update):
    if let update { nowPlayingObserver.ingest(update, from: player) }
    if let track = nowPlayingObserver.current?.track {
        handleTrackChange(player: player, track: track)
    }
case .failure(let error):
    setPlayerControlEnabled(false)   // roll the opt-in back
    setStatus(error.message)
}
```

`reportAutomationRefusal` (:502–507) and the duplicated string at :483–485 both go away.

## Steps

1. Add `PlayerRemoteError.swift` — outside the `#if`. It compiles into both targets (the
   synchronized group takes care of it; no `project.pbxproj` edit).
2. Change `run` to return `Result`; add the `PlayerDenials` field; replace `automationDenied`
   with `isDenied(_:)`.
3. Convert the three transport methods and `seed`.
4. Convert `refreshArtwork` / `beginArtwork` — they can keep ignoring failures (artwork is
   best-effort and already caps at three attempts, :111), but take the `Result` explicitly
   with a comment saying so, rather than silently dropping it.
5. Rewrite the five `AppState` call sites; delete `reportAutomationRefusal`.
6. Check the `#else` stubs (AppState.swift:537–541) still cover everything the App Store
   build needs.

## Tests

New `SynesthiaTests/PlayerRemoteErrorTests.swift` — pure, compiles in every configuration:

```swift
@Test func minusSeventeenFortyThreeIsARefusal() {
    let error = PlayerRemoteError(errorNumber: -1743, player: .music)
    #expect(error.revokesPlayerControl)
}

@Test func minusSixHundredIsNotARefusal() {
    // The old single flag treated these two identically, so "Music isn't
    // running" told the user to go fix a permission that was already granted.
    let error = PlayerRemoteError(errorNumber: -600, player: .music)
    #expect(!error.revokesPlayerControl)
    #expect(!error.message.contains("System Settings"))
}

@Test func anUnrelatedCodeIsNeitherRefusalNorSilent() {
    let error = PlayerRemoteError(errorNumber: -2740, player: .music)
    #expect(!error.revokesPlayerControl)
    #expect(!error.message.isEmpty)
}

@Test func aDenialSurvivesAnUnrelatedFailure() {
    var denials = PlayerDenials()
    denials.record(PlayerRemoteError(errorNumber: -1743, player: .music), for: .music)
    denials.record(PlayerRemoteError(errorNumber: -2740, player: .music), for: .music)
    #expect(denials.isDenied(.music))
}

@Test func oneplayersSuccessDoesNotClearAnothersDenial() {
    var denials = PlayerDenials()
    denials.record(PlayerRemoteError(errorNumber: -1743, player: .spotify), for: .spotify)
    denials.clear(.music)
    #expect(denials.isDenied(.spotify))
}

@Test func everyMessageNamesThePlayer() {
    for code in [-1743, -600, -2740, nil] {
        #expect(PlayerRemoteError(errorNumber: code, player: .spotify).message.contains("Spotify"))
    }
}
```

The middle two are the regressions this plan exists to prevent — neither could be written
against the current code at all.

While here, add the cheap dialect completeness check the current code has no guard for
(`Scripts` returns `nil` per player and a missing entry fails silently at runtime). It needs
`PlayerRemote`'s private `Scripts` enum, so it belongs in a later PR alongside the test-target
flag — note it in the PR description as a known gap rather than skipping it silently.

## Risks

- **`MediaPlayer` must be usable in the error payload from the App Store build.**
  `NowPlayingObserver.swift` defines it unconditionally, so this is fine — but confirm
  `MediaPlayer` is not itself behind any `#if` before relying on it.
- **`build-appstore.sh` asserts no `tell application "` string reaches the store binary.**
  Nothing in the new file contains one. Run `make appstore` (or at minimum re-read the
  assertion at `scripts/build-appstore.sh:82–88`) before merging, and remember the
  `grep -q` pipeline hazard documented in `CLAUDE.md` — the assertion captures to a variable
  first, so leave that shape alone.
- `@discardableResult` on the transport methods keeps a caller that ignores the result
  compiling. That is deliberate for artwork; for transport, make sure all three call sites
  actually pass through `report(_:)`.

## Verification

```
make format && make healthcheck        # lint + test + build-direct
```

Then, with Music running: `make run`, opt into control, use prev/play/next. Quit Music and
press play — the banner must now say "Music isn't running", not the Automation sentence.
Deny Automation in System Settings for Synesthia and confirm the opt-in rolls back exactly
once.
