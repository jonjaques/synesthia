# Apple Events are compiled out of the App Store build

The App Store build contains no AppleScript, sends no Apple Events, and ships neither the
automation entitlement nor the Music exception. Player Control and real cover art exist only
in the Direct build, behind `MUSIC_APP_SOURCE`. Requesting automation access for a
visualizer was the single largest review risk this project had, and the feature it buys is an
enhancement — the canvas is fully alive without it.

## Considered options

Shipping one binary carrying the entitlements and letting review decide was the obvious
alternative, and it was rejected as an unbounded risk on a feature that is not the product.
Gating at runtime instead of at compile time was rejected too: an entitlement in the bundle
is a claim reviewers can ask about whether or not the code path runs, and a `strings` check
on the archive is a much stronger assertion than a code review.

## Consequences

Two app targets, both producing `Synesthia.app`, because SPM attaches a package to a target
rather than a configuration — so keeping Sparkle out of the store build requires a second
target, and it carries the Apple Events split with it. Build settings are not shared between
them and must be changed in both places. `scripts/build-appstore.sh` asserts against the
built archive that neither leaked.

**Now Playing is deliberately not gated by this.** Title, artist, album and play state arrive
on distributed notifications and cost no permission at all, so the store build shows the
badge too. This contradicts the widely repeated claim that the App Sandbox strips `userInfo`
from distributed notifications — that restriction applies to _posting_, not receiving,
verified on macOS 26.5 with a sandboxed binary. Do not "fix" the badge by reaching for an
entitlement; there isn't one.

See `docs/distribution.md` for the full target and configuration matrix.
