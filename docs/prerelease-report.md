# Prerelease report — 2026-07-25

Execution of `docs/app-store-launch-plan.md`, landed as **`377f02b`**
("Prelaunch refinement") on `main` — 27 files, +2631/−111, on top of `39fb7aa`.
The `docs/` changes described here, including this report, are not in that
commit.

Everything in the plan that does not require an Apple Developer portal login is
implemented and verified. One hard blocker remains (**B2**, distribution
signing), plus a legal question (**B7**, trademark) and a short list of things
that need a human in front of the running app.

---

## 1. Decisions taken

Four questions gated materially different work. Answers, and what followed:

| Question          | Decision                           | Consequence                                                                                |
| ----------------- | ---------------------------------- | ------------------------------------------------------------------------------------------ |
| B5 — Apple Events | **Feature-flag it**                | New `Direct` build configuration; App Store build contains no Music.app integration at all |
| B4 — demo audio   | **Synthesize and bundle a clip**   | `scripts/make_demo_loop.py` generates a 32 s loop; no licensing question                   |
| B7 — trademark    | **Proceed under the current name** | Research recorded below; left open                                                         |
| §6 — distribution | **Both App Store and direct**      | Full notarization pipeline built; Sparkle written but not linked                           |

One research finding closed off a third option for B5: **MusicKit cannot
replace Apple Events on macOS.** `SystemMusicPlayer` is unavailable on the
platform, and `ApplicationMusicPlayer` reports only what your own app plays,
not what Music.app is playing. B5 was therefore a straight choice between
shipping the entitlement and cutting the feature.

---

## 2. Blockers closed

### B1 — bundle identifier

`jonjaques.Synesthia` → **`com.jonjaques.Synesthia`** across every
configuration. Registering the App ID remains portal work (see §6).

### B3 — `fatalError` on missing Metal

Replaced with an optional `MetalRenderContext.shared` and a
`MetalUnavailableView`. No launch path can now crash on a Mac (or VM) without a
Metal device.

### B4 — dead on arrival for a reviewer

New `.demo` audio source, **default on first launch**, playing a loop bundled
with the app. It needs no permission of any kind, so the canvas is alive before
anything can be denied. A first-run `WelcomeView` names each permission, says
plainly what it buys, and deep-links into the correct System Settings pane.

The track is generated rather than licensed, which sidesteps having to prove
rights to third-party audio in a submission. It is also tuned for the job — the
arrangement keeps energy in every band the analyzer reports.

### B5 — `temporary-exception.apple-events`

Feature-flagged behind `MUSIC_APP_SOURCE`, which is **off** in `Release` and on
in `Direct` and `Debug`.

|                                    | `Release` (App Store)    | `Direct`                        | `Debug`                         |
| ---------------------------------- | ------------------------ | ------------------------------- | ------------------------------- |
| `MUSIC_APP_SOURCE`                 | off                      | on                              | on                              |
| Entitlements file                  | `Synesthia.entitlements` | `Synesthia-Direct.entitlements` | `Synesthia-Direct.entitlements` |
| `automation.apple-events`          | **no**                   | yes                             | yes                             |
| `temporary-exception.apple-events` | **no**                   | yes                             | yes                             |
| `NSAppleEventsUsageDescription`    | absent                   | present                         | present                         |

`scripts/build-appstore.sh` asserts against the _built archive_ that none of it
leaked — no Apple Events entitlement, and no `tell application "Music"` string
compiled into the binary.

### B6 — unused music-library entitlement

`com.apple.security.assets.music.read-only` removed. Hand regression-testing of
the Music path is outstanding (§6).

### §3 — quality gaps

All actionable items done:

- **Power** — MTKView pauses entirely on occlusion/miniaturize; drops to 30 fps
  when the app is inactive or nothing is playing; runs at the display's full
  rate, including 120 Hz ProMotion, only while audio flows.
- **Sleep** — `beginActivity(.idleDisplaySleepDisabled)` held only while audio
  is flowing, released the moment it stops.
- **Photosensitivity** — Reduce Motion honored: clock slowed, transients damped
  to 25%, level features smoothed with a 0.4 s time constant. Implemented
  CPU-side to preserve the 96-byte `VizUniforms` contract shared with
  `Shaders.metal`.
- **VoiceOver** — `accessibilityLabel` on all 14 icon-only buttons; the chrome
  no longer auto-hides while VoiceOver is running, which previously made the
  app hostile to keyboard and switch users.
- **Help menu** — replaces the dead default; opens the explainer, the Support
  URL, and the Privacy URL.
- **File persistence** — security-scoped bookmark, refreshed when stale.
- **Build warning** — accent-color warning cleared. All three configurations
  build with **zero warnings**.

Deliberately deferred: localization (English-only is fine for v1) and test
coverage of the Metal visualizers.

---

## 3. Two real bugs, found by running the app

The most valuable outcome of the session, and neither was in the plan.

### Every `FilePlayer` launch crashed

`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` means a closure written inline
inside a main-actor method is itself inferred main-actor. AVAudioEngine invokes
tap blocks on a realtime audio thread, so Swift 6's isolation check trapped —
`EXC_BREAKPOINT` in `swift_task_checkIsolatedSwift`, on the first buffer, with
a stack that blames AVFAudio rather than the closure.

Latent before this pass because nothing started a `FilePlayer` at launch. The
demo source does, so it fired every time.

### The same bug in the loop-completion handler

`scheduleFile`'s completion block had the identical defect and would have
killed the app 32 s in, at the first loop point. The existing
`Task { @MainActor … }` hop did **not** help: the trap happens on entry, before
the `Task` is ever reached.

Both fixed with `nonisolated` block factories (`makeAnalyzerTap`,
`FilePlayer.loopCompletion()`), and written up as a gotcha in `CLAUDE.md`.

**Diagnosis note:** the missing power assertion was the tell. The app was up
and the window drawn, but `pmset -g assertions` showed nothing held, which
meant `isCaptureActive` was false and the demo was not playing. That pointed
straight at the audio path rather than the UI.

---

## 4. Test target

`SynesthiaTests` — a Swift Testing bundle hosted by the app target, covering
`AudioAnalyzer`. **19 tests, all passing.**

Coverage: band mapping against an independently derived formula, sample-rate
dependence, bass/mid/treble separation, level normalization, spectral centroid,
beat and treble-transient detection, flux decay, `reset()`, and arbitrary
capture buffer sizes (1 to 4096 samples).

Three of my own tests failed on the first run and were corrected rather than
the code. They asserted ideal geometric band spacing across the whole spectrum,
but `rebuildBandEdges` deliberately forces each band to own a distinct FFT bin
— and with 23.4 Hz bins at 48 kHz that rule binds for every band below ~844 Hz,
making the bottom third effectively linear. That is a physical limit of a
2048-point FFT, not a defect. The tests now cover both regimes explicitly, and
a fourth test was rewritten to drive the treble detector with broadband noise
instead of a pure sine — averaging across ten bands, it correctly ignores a
single high tone, because a sine is not a cymbal.

One test was also found to be vacuous (it compared my helper formula against
itself) and was replaced with one that measures the analyzer's actual output.

---

## 5. Verification evidence

| Check                                  | Result                                                      |
| -------------------------------------- | ----------------------------------------------------------- |
| `Release` / `Direct` / `Debug` builds  | succeed, **zero warnings**                                  |
| `xcodebuild test`                      | 19/19 pass                                                  |
| Archive is universal                   | `x86_64 arm64`                                              |
| `get-task-allow` in archive            | absent                                                      |
| Apple Events entitlements in `Release` | absent                                                      |
| AppleScript string in `Release` binary | absent                                                      |
| `PrivacyInfo.xcprivacy` in bundle      | present                                                     |
| `DemoLoop.m4a` in bundle               | present                                                     |
| `ITSAppUsesNonExemptEncryption`        | present                                                     |
| App launches and stays up              | yes                                                         |
| Demo plays / assertion held            | 2 assertions held while playing                             |
| Survives loop restarts                 | 95 s, 3 loop points, no crash reports                       |
| Demo track spectral content            | energy in all three bands, 0 silent windows, −18.3 dBFS RMS |
| Web site builds                        | 3 pages, both new ones in the sitemap                       |
| Metadata field lengths                 | all within Apple's limits                                   |

**What was _not_ verified: anything visual.** There is no screen-recording
permission in this environment, so not a single pixel of the UI was seen. See
§6.5.

---

## 6. Outstanding — needs a human

### 6.1 B2 — distribution signing (**the one hard blocker**)

The only certificate on this machine is _Apple Development_. Both release
scripts archive successfully and stop at export:

```
error: exportArchive No signing certificate "Mac Installer Distribution" found
error: exportArchive No profiles for 'com.jonjaques.Synesthia' were found
error: exportArchive No signing certificate "Developer ID Application" found
```

Needed: App ID registration, Apple Distribution + Mac Installer Distribution +
Developer ID Application certificates, a Mac App Store provisioning profile,
notary credentials (`xcrun notarytool store-credentials`), and an App Store
Connect record. Then a throwaway upload, to flush out validation errors while
there is still time to react.

### 6.2 B7 — trademark

A USPTO search turns up no registered mark for "Synesthesia" in the software
class. That is **not clearance**: the product demonstrably exists and sells, so
common-law rights are likely, and confusing similarity is judged on overall
impression rather than letter count. A legal call, not a technical one.

Nothing in the repo is name-dependent except listing copy and the domain, so a
rename stays cheap right up until submission.

### 6.3 Mail routing

`support@synesthia.app` and `privacy@synesthia.app` are now published on both
required pages and **neither has mail routing**. Apple checks that the support
URL resolves; a dead support address is a review risk as well as a bad look.

### 6.4 Screenshots and preview video

Not possible here. The plan is right that the preview video is the
high-leverage asset — a static screenshot of a visualizer sells nothing.

### 6.5 Look at the app

Everything above was verified structurally. Unverified by eye or ear:

- the first-run welcome sheet's layout and wording
- whether the demo track _sounds_ good, as opposed to measuring well
- whether Reduce Motion actually looks calmer
- whether VoiceOver actually reads the new labels

### 6.6 Sparkle's final step

`Synesthia/Updater.swift` is written and guarded on `canImport(Sparkle)`, so it
compiles to nothing today and lights up when the package is linked. Linking is
left deliberately undone: SPM attaches a package to _every_ configuration, and
Sparkle must stay out of the App Store build. That needs a target decision, not
a script — both options are laid out in `docs/distribution.md`.

### 6.7 Regression-test the Music path

B6's follow-up: with Music.app running, in the `Direct` configuration, by hand.

---

## 7. Corrections made along the way

Two factual errors in `web/src/consts.ts` that would have flowed into the App
Store listing:

- claimed **macOS 26.5 or later**; the deployment target is 26.0
- claimed **Apple silicon**; release archives are universal, and macOS 26 Tahoe
  is the last release supporting Intel Macs

---

## 8. Artifacts added

| Path                               | Purpose                                       |
| ---------------------------------- | --------------------------------------------- |
| `Synesthia-Direct.entitlements`    | Direct/Debug entitlements, incl. Apple Events |
| `Synesthia/WelcomeView.swift`      | First-run permission explainer                |
| `Synesthia/Updater.swift`          | Sparkle glue, guarded                         |
| `Synesthia/Resources/DemoLoop.m4a` | Generated 32 s demo loop (512 KB)             |
| `SynesthiaTests/`                  | Swift Testing bundle                          |
| `scripts/make_demo_loop.py`        | Deterministic demo-track synthesizer          |
| `scripts/build-appstore.sh`        | Archive, assert, export, validate, upload     |
| `scripts/build-direct.sh`          | Archive, Developer ID, DMG, notarize, staple  |
| `scripts/make-appcast.sh`          | Sparkle appcast generation                    |
| `scripts/check-metadata.py`        | App Store field length checker                |
| `scripts/ExportOptions-*.plist`    | Export configurations                         |
| `docs/distribution.md`             | The two-configuration split, end to end       |
| `docs/app-store-metadata.md`       | Every listing field + review notes            |
| `web/src/pages/privacy.astro`      | Required App Store page                       |
| `web/src/pages/support.astro`      | Required App Store page                       |
| `web/src/layouts/Legal.astro`      | Prose layout for both                         |

`CLAUDE.md` and `docs/app-store-launch-plan.md` were updated to match.
