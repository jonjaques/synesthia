# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Synesthia is a macOS-only SwiftUI + Metal music visualizer (`SDKROOT = macosx`, no iOS/Catalyst target). It captures audio (system audio via ScreenCaptureKit, mic/line-in via AVAudioEngine, or a local file), runs an FFT, and renders pluggable Metal visualizers. See README.md for the user-facing feature description and roadmap, and `docs/` for developer documentation (architecture, audio pipeline, rendering, plugin system, macOS integration).

Built with Xcode 26.6 / Swift 6.3 toolchain against the macOS 26 SDK, but the
**deployment target is macOS 15.0** (Sequoia). One binary serves both: the only
macOS 26 API in the app is Liquid Glass, and it lives behind a single
`#available` check in the `chromeGlass` modifier (`ContentView.swift`), which
degrades to `.ultraThinMaterial` + hairline border + drop shadow on 15. **Never
call a 26-only API without a guard, and route all new chrome backgrounds through
`chromeGlass` rather than `glassEffect` directly** — the compiler catches the
first mistake, nothing catches the second. Raising the floor back to 26 means
deleting the fallback branch, nothing else.

## Architecture

```
Synesthia/
├── SynesthiaApp.swift            @main; Settings scene (⌘,) + WindowGroup + Help/Playback/Visualizer
│                                 menu commands
├── AppState.swift                @Observable hub: source switching, transport, permissions status,
│                                 now-playing merge + the opt-in player-control gate
├── ContentView.swift             Canvas + auto-hiding ControlsBar + NowPlayingBadge/ArtworkTile
│                                 + OptionsPanel
├── SettingsView.swift            App-wide Settings window: Normalize Loudness toggle
├── WelcomeView.swift             First-run explainer: sources, permissions, System Settings links
├── Updater.swift                 Sparkle glue, `#if canImport(Sparkle)`; direct build only
├── Resources/DemoLoop.m4a        Generated demo track (scripts/make_demo_loop.py)
├── Audio/
│   ├── AudioAnalyzer.swift       nonisolated, lock-guarded vDSP FFT → AudioSnapshot (64 bands,
│   │                             waveform, bass/mid/treble/level, beat envelope); slow auto-gain
│   │                             normalizes source loudness (Normalize Loudness toggle)
│   └── AudioSources.swift        AudioSourceKind, SystemAudioCapture (SCK), InputDeviceCapture,
│                                 FilePlayer, CoreAudio input-device enumeration
├── Music/
│   ├── NowPlayingObserver.swift  MediaPlayer catalog (Music, Spotify), distributed-notification
│   │                             observers, userInfo dialect parsing, multi-player arbitration.
│   │                             ZERO permissions; in both targets
│   └── PlayerRemote.swift        `#if MUSIC_APP_SOURCE`: Apple Events for transport + cover art,
│                                 one complete AppleScript literal per player
└── Visualizers/
    ├── VisualizerCore.swift      Visualizer protocol, VisualizerDescriptor/Option, registry,
    │                             VizUniforms, palettes, persisted VisualizerSettings,
    │                             makeRenderPipeline/makeComputePipeline
    ├── ParticleSystem.swift      GPUParticleSystem: device-private ping-pong particle
    │                             buffers, GPU seed/step kernels, instanced sprite draw
    ├── Shaders.metal             ALL shader functions incl. compute kernels, compiled at
    │                             build time (see below)
    ├── MetalVisualizerView.swift MetalRenderContext (optional), MTKView host, uniforms per
    │                             frame incl. derived frame state, occlusion pausing,
    │                             adaptive render scale, Reduce Motion damping
    └── {Nebula,Tunnel,Aurora,Bars}Visualizer.swift

SynesthiaTests/                   Swift Testing bundle; AudioAnalyzer DSP, VizUniforms layout,
                                  now-playing parsing/arbitration
Makefile                          Single entry point for every command (see below)
scripts/                          make_demo_loop.py, build-appstore.sh, build-direct.sh,
                                  make-appcast.sh, publish-release.sh, sparkle-keys.sh,
                                  release.env (shared), check-metadata.py,
                                  take-screenshots.sh + shotkit.swift
Synesthia-Direct-Info.plist       Sparkle's 3 Info.plist keys (Direct target only)
web/                              Astro marketing site (own package.json; see web/AGENTS.md)
web/functions/                    Pages Functions: /appcast.xml, /download, /downloads/*
                                  — serve the release artifacts out of R2, so shipping a
                                  version is an upload, not a site rebuild
```

Data flow: audio threads → `AudioAnalyzer.appendMono` (NSLock) → render loop pulls `analyzer.latest()` each frame. Audio never publishes into SwiftUI; only `NowPlayingObserver`/`PlayerRemote`/`AppState` are observable.

**Plugin contract**: a visualizer = class conforming to `Visualizer` + static `VisualizerDescriptor` (≤16 options, surfaced automatically in the UI and delivered as the shader's `p` array in declaration order) + shader functions in `Shaders.metal`. Register in `VisualizerRegistry`. A visualizer may encode compute passes as well as render passes — `GPUParticleSystem` is the reusable scaffolding for GPU-resident simulations (Nebula runs ~100k particles on it).

`VizUniforms` in VisualizerCore.swift and the struct in Shaders.metal must stay
byte-identical (currently 42 floats / 168 bytes). **Both sides now assert it** —
`static_assert(sizeof(VizUniforms) == 168)` in Shaders.metal and
`VizUniformsTests` on the Swift side — so a one-sided edit fails the build or the
test suite instead of silently shifting every later field into the wrong shader
variable. Append new fields at the end; the option block is the exception, and
must stay contiguous because MSL declares it as `float p[16]` and indexes it.
Options are capped at `VizUniforms.parameterCount` (16), and each visualizer
names its slots with `constant int k…` in Shaders.metal rather than writing
`u.p[6]` inline.

## Commands

**The `Makefile` is the single entry point — prefer it over raw `xcodebuild`.** `make` with no target prints the list. Every target is a thin wrapper (the scripts stay runnable directly), so adding a script means adding a target next to it.

```bash
make build            # xcodebuild build; CONFIGURATION=Debug (also Direct, Release)
make build-direct     # …the `Synesthia Direct` target (the one that links Sparkle)
make run              # build, then open the built .app
make test             # xcodebuild test -destination 'platform=macOS'
make clean            # xcodebuild clean + rm -rf build/
make app-path         # print the built .app path for CONFIGURATION

make install          # npm install at the root (Prettier only; web/ installs itself)
make healthcheck      # the PR gate: lint + test + build-direct, in that order
make lint             # prettier --check, then `swift format lint --strict`
make format           # prettier --write, then `swift format --in-place`

make demo-track       # python3 scripts/make_demo_loop.py
make screenshots      # scripts/take-screenshots.sh → web/src/assets/screenshots/<run>
make check-metadata   # scripts/check-metadata.py

make appstore         # archive + assert + export for the Mac App Store
make appstore-upload  # …and upload to App Store Connect
make direct           # archive + Developer ID + notarize + staple + DMG
make direct-fast      # …--skip-notarize
make sparkle-keys     # one-time: create the EdDSA signing key (back it up!)
make appcast          # regenerate the signed Sparkle appcast into build/releases
make publish-release  # upload DMGs + appcast + latest.json to R2 (publish-dry-run first)

```

**`web/` is not driven from the Makefile.** It is a self-contained project with its own `package.json`, lockfile and Prettier config (the root `.prettierignore` ignores it), so run its scripts from inside it: `cd web && npm ci`, then `npm run dev|build|check|typecheck|assets|cf-types`. See `web/AGENTS.md`.

`ARGS=` forwards flags to the wrapped script (`make screenshots ARGS="--only nebula --1x"`). `BUILT_PRODUCTS_DIR` is resolved from `xcodebuild -showBuildSettings`, not globbed out of DerivedData, so `run`/`app-path` are correct for any configuration.

`SynesthiaTests` is a **Swift Testing** bundle (`import Testing`, `@Test`, `#expect`), hosted by the app target, covering `AudioAnalyzer` and the `VizUniforms` byte layout / option-slot contract.

### Formatting

Swift is formatted by **swift-format**, which ships inside the Xcode toolchain (`swift format`) — nothing to install, no SPM dependency, no `Package.swift`. `make format` runs Prettier and then rewrites `Synesthia/`, `SynesthiaTests/` and `scripts/shotkit.swift` in place; `make lint` is the read-only half and passes `--strict`, so **any** diagnostic (including plain indentation) is an error.

`.swift-format` at the repo root is the config, and Xcode's own _Editor ▸ Structure ▸ Format File with swift-format_ picks up the same file. Where it deviates from swift-format's defaults, it does so to match the code that was already here:

- **4-space indentation** (the default is 2) and a **110-column line length** (default 100).
- **`DoNotUseSemicolons` and `OneVariableDeclarationPerLine` are off.** Both are on by default and both would explode the tabular literal blocks — `a = […]; b = […]; c = […]` in `Palette.color`, `let a: SIMD3<Float>, b: …` — into one statement per line, which is strictly worse to read for a lookup table. Turn them back on only if you also want that rewrite.
- **`UseSynthesizedInitializer` is off** (memberwise initializers here are written out deliberately) and `reflowMultilineStringLiterals` stays at `never`, so the embedded AppleScript in `PlayerRemote.swift` is never rewrapped. swift-format does still re-indent multiline string _literals_ and hoist them onto their own argument line; that is expected and harmless.

`Shaders.metal` is not Swift and no formatter touches it — keep it tidy by hand.

### CI

`.github/workflows/healthcheck.yml` is the only workflow and runs on every pull request push, as two jobs mirroring the two projects in the repo: **`web`** on `ubuntu-latest` runs `npm ci && npm run check && npm run typecheck && npm run build` from inside `web/`, and **`apple`** on `macos-26` runs `make install && make healthcheck`. Keep `make healthcheck` as the single macOS entry point — new checks belong inside it, not as extra workflow steps, so that what CI runs is what a developer can run locally.

Two things the runner needs that a developer's machine already has:

- **No signing identity.** `CODE_SIGN_STYLE=Automatic` + `DEVELOPMENT_TEAM` fails on a runner with no certificate or profile, so the Makefile appends `$(SIGNING)` — ad-hoc signing (`CODE_SIGN_IDENTITY=-`) — to `build`, `build-direct` and `test` whenever `CI` is set, which Actions does. Ad-hoc is enough for the sandbox to launch the test host; it disables the hardened runtime, which is why the real releases still go through `scripts/build-direct.sh` on a machine with the certificates.
- **The Metal toolchain**, since `Shaders.metal` compiles at build time. The workflow runs `xcodebuild -downloadComponent MetalToolchain` before building; drop that step if the runner images start shipping it.

### Screenshots

`make screenshots` (`scripts/take-screenshots.sh` + `scripts/shotkit.swift`, a Swift helper compiled on demand) relaunches the app once per registered visualizer, sizes the window, captures it, then repeats fullscreen. Notes for changing it:

- **Every run writes into its own folder** — `web/src/assets/screenshots/<UTC stamp to the second>/<id>-<windowed|fullscreen>.png` — so nothing is overwritten and two takes can be compared side by side, and the names inside stay clean. `--run NAME` overrides the folder; `--run ''` writes bare `<id>-<mode>.png` names into the output directory itself, which is what the site imports and therefore how those committed assets get refreshed. A `manifest.txt` beside the images records the window size, the App Store canvas, and which track is in each shot. Note the stamp can't be generated with `tr -dc … </dev/urandom | head -c 4`: `head` closing the pipe kills `tr`, and `set -o pipefail` turns that into a failed run.
- **App Store Connect takes a Mac screenshot only at 1280×800, 1440×900, 2560×1600 or 2880×1800, and rejects any alpha channel** — which a window capture has, because `screencapture -o` leaves the rounded corners transparent. Every shot therefore also gets an `app-store/` copy, redrawn by `shotkit compose` onto an opaque canvas of exactly the target size (scaled to fit, never cropped, so no chrome is lost) with the result asserted alpha-free by `sips -g hasAlpha`; nothing else in the pipeline would notice a stray alpha channel, and the upload is where you'd find out. `compose` keeps the capture's Display P3 profile rather than flattening to sRGB, so the shaders' saturated output isn't clipped. The default window size is the largest 16:10 box that fits the display capped at **1440×900 points — 2880×1800 at 2x**, so the windowed shot lands on the largest accepted size with no rescaling at all; the fullscreen shot comes off a display that isn't exactly 16:10 and picks up a few pixels of letterboxing, which the log reports rather than hides.
- **Music.app is driven over Apple Events** (`--music next|play|off`, `--playlist`) so a run isn't eight shots of the same song: playback starts before the first capture and advances one track per visualizer. The advance happens _after_ the app is up, so the badge fills from the distributed notification rather than a launch-time poll — the only path the App Store build has, since `#if MUSIC_APP_SOURCE` strips `PlayerRemote` out of it. This adds a third permission the invoking terminal needs (Automation › Music, alongside Accessibility and Screen Recording); all three are preflighted, and a refused Apple Event is detected by matching `-1743` against a captured variable rather than piping into `grep -q`.
- **Visualizers are discovered from source**, not hardcoded: the registry order is parsed out of `VisualizerCore.swift` and each id out of its own `*Visualizer.swift`. A new visualizer is picked up for free.
- **State is injected through the argument domain**, not `defaults write`: `open -a … --args -visualizerID nebula -sourceKind systemAudio -hasSeenWelcome YES`. `NSUserDefaults` reads `-key value` pairs out of `argv` at highest priority, which works for a _sandboxed_ app (whose prefs live in its container, so `defaults write com.jonjaques.Synesthia` would go to the wrong plist) and leaves nothing behind in the user's real preferences.
- **The bottom chrome auto-hides after 3 s of pointer stillness**, so every capture is preceded by a synthetic two-step pointer move inside the window plus 0.6 s for the 0.35 s fade-in. One warp is not enough — `onContinuousHover` only reacts to a _change_ in position.
- **It needs Accessibility, Screen & System Audio Recording and Automation › Music on the invoking terminal**, and preflights all three. Nothing in the app was changed to support it; it drives the shipping UI.
- Window capture (`screencapture -o -l <id>`) keeps the rounded corners on transparency; `--mode region` is the fallback if a Metal window ever composites black.
- **`CFTypeRef as? [AXUIElement]` silently yields an _empty_ array**, so reading `kAXWindows` that way reports "no windows" on a perfectly healthy app — with no error to go on. `shotkit.swift` asks for `kAXMainWindow`/`kAXFocusedWindow` (single elements) and type-checks with `CFGetTypeID` + `unsafeBitCast` instead. Same trap for `CFBoolean` → `Bool`.
- **`CGWindowListCopyWindowInfo` marks every window off-screen while the display is asleep**, so `.optionOnScreenOnly` makes the whole thing look windowless when run headless. `cgWindow` uses `.optionAll` and merely _prefers_ on-screen matches.

## Hard-won gotchas (violating these caused real bugs)

**Shaders compile at build time.** The Metal Toolchain component (26.6) is installed as of 2026-07, so `.metal` files build normally. All shader source lives in `Synesthia/Visualizers/Shaders.metal`, compiled into the app's default library and loaded via `device.makeDefaultLibrary()`. (Historical: the toolchain used to be missing, so shaders lived in a `ShaderSource.swift` string compiled at launch — don't resurrect that for built-ins; `makeLibrary(source:)` remains the intended path only for future external plugin bundles.)

**ScreenCaptureKit audio extraction.** Use `sampleBuffer.withAudioBufferList` + `AVAudioPCMBuffer(pcmFormat:bufferListNoCopy:)` (the current code). Do NOT use `CMSampleBufferCopyPCMDataIntoAudioBufferList` into a fresh `AVAudioPCMBuffer` — its buffer list advertises `frameLength` (0) bytes, every copy fails with `err=-12731`, and the analyzer silently receives nothing. Also: even when only capturing audio, register a `.screen` stream output too, or SCK logs "stream output NOT found. Dropping frame" continuously.

**AVFAudio callbacks must be built in a `nonisolated` context, or they trap.** `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` means a closure written inline inside a main-actor method is _itself_ inferred main-actor. AVAudioEngine calls tap blocks and `scheduleFile` completion handlers on a realtime audio thread, so Swift 6's isolation check fires and the app dies with `EXC_BREAKPOINT` in `swift_task_checkIsolatedSwift` — on the very first buffer, with a stack that blames AVFAudio rather than the closure. Build these blocks from a `nonisolated` factory (`makeAnalyzerTap`, `FilePlayer.loopCompletion()`), never inline. Wrapping the body in `Task { @MainActor in … }` does **not** help: the trap happens on entry, before the `Task` is ever reached. Spell the return type `@Sendable () -> Void`; the `AVAudioNodeCompletionHandler` typealias isn't marked `@Sendable` and the call site warns.

**Never pipe into `grep -q` in a `set -o pipefail` script.** `grep -q` exits the instant it matches, which closes the pipe, kills the producer with SIGPIPE (exit 141), and — because every release script sets `pipefail` — turns a _successful_ match into a failed pipeline. This has bitten twice, and the second time was worse than the first:

- `codesign -d --verbose=2 "$APP" 2>&1 | grep -q "flags=.*runtime"` reported "hardened runtime is not enabled" on an app that had it. (Note `codesign -d` writes everything to **stderr**, hence the `2>&1`.)
- The `if producer | grep -q LEAK; then fail; fi` form fails **open**: the leak makes grep match, SIGPIPE makes the pipeline non-zero, `if` reads that as "clean", and the guard silently doesn't fire. `strings $BINARY | grep -q 'tell application "Music"'` — the most important App Store assertion in the project — was silently passing on a binary that _did_ contain the string. Whether it bites depends on whether the producer's output exceeds the 64 KB pipe buffer, so small-output checks race benignly and look fine.

Capture first, match against the variable: `OUT=$(producer 2>&1 || true)` then `grep -q PATTERN <<<"$OUT"`. A herestring is not a pipe, so there is nothing to SIGPIPE. Same root cause as the `tr … | head -c 4` note in the screenshots section.

**The App Sandbox does not strip `userInfo` from distributed notifications you _receive_.** The widely repeated claim that it does describes the opposite direction: a sandboxed app may not _post_ a `userInfo` dictionary. Receiving one is fine — verified on macOS 26.5 with an ad-hoc-signed sandboxed binary (its container was created, so the sandbox was live) watching full `com.apple.Music.playerInfo` payloads arrive. This is the entire foundation of the App Store build's now-playing badge, so don't "fix" it by reaching for an entitlement; there isn't one. And use `suspensionBehavior: .deliverImmediately` — the default coalesces while the app is inactive, which is the normal case when the user is in Spotify and Synesthia is rendering behind it. That argument only exists on the selector-based `addObserver`, which is why `NotificationRelay` exists.

**AppleScript constants don't coerce to text.** `player state as text` throws; `player state is playing` compares fine. Map constants to strings via comparisons inside the script (see `Scripts.nowPlaying` in `PlayerRemote.swift`). This bug is invisible from Swift — the script just returns nil.

**Music artwork**: prefer `raw data of artwork 1` (original JPEG/PNG), fall back to `data`; artwork lags track changes so the poll retries up to 3× per track.

**TCC flow**: system-audio capture needs Screen & System Audio Recording; the first `startCapture` after a fresh grant can require a second attempt. `AppState.handlePlay` deliberately avoids toggling Music into pause when the user clicks play merely to re-attach capture.

## Build configurations

Three configurations, two app targets. **`Synesthia`/`Release` is the Mac App Store build and `Synesthia Direct`/`Direct` is the notarized direct download** — they differ in whether the Music.app integration and the updater exist at all.

|                           | `Release` (App Store)    | `Direct`                        | `Debug`                         |
| ------------------------- | ------------------------ | ------------------------------- | ------------------------------- |
| Target                    | `Synesthia`              | `Synesthia Direct`              | either                          |
| `MUSIC_APP_SOURCE`        | off                      | on                              | on                              |
| Now-playing badge         | yes (no permission)      | yes                             | yes                             |
| Transport + cover art     | no                       | opt-in                          | opt-in                          |
| Sparkle                   | never                    | linked                          | Direct target only              |
| Entitlements              | `Synesthia.entitlements` | `Synesthia-Direct.entitlements` | `Synesthia-Direct.entitlements` |
| Apple Events entitlements | none                     | automation + Music exception    | same                            |
| `network.client`          | no                       | yes (Sparkle)                   | yes                             |

`#if MUSIC_APP_SOURCE` removes the whole of `PlayerRemote.swift` and every Apple Event with it, so the App Store build needs neither `automation.apple-events` nor any `temporary-exception.apple-events` — the single largest review risk this project had. **What it no longer removes is now-playing:** `NowPlayingObserver` reads distributed notifications, which cost no permission, so the store build shows the badge too. The flag now gates only transport control and cover art. Despite the name, there is no longer a `.musicApp` audio source. Likewise `#if canImport(Sparkle)` empties `Updater.swift` in the target that doesn't link it, so `SynesthiaApp.swift` needs no conditional at the call site. `scripts/build-appstore.sh` asserts against the built archive that neither leaked (no Apple Events entitlement, no `tell application "` string for any player, no Sparkle framework/link/`SUFeedURL`). Full rationale in `docs/distribution.md`.

Adding a _new_ configuration means cloning the `XCBuildConfiguration` objects at both project and target level and registering both in their `XCConfigurationList`s.

**Two app targets.** `Synesthia` is the App Store build; **`Synesthia Direct`** is the direct download and is the only target that links Sparkle — SPM attaches a package to a target, not a configuration, so keeping Sparkle out of `Release` requires a second target. Both reference the same `PBXFileSystemSynchronizedRootGroup`, so a new `.swift` file under `Synesthia/` compiles into both for free; **build settings are not shared** and must be changed in both places (including `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` on every release). Both produce `Synesthia.app`, so building both in the same configuration means the last one wins in `Build/Products/<config>/` — schemes and archive configurations keep them apart in practice. Full rationale in `docs/distribution.md`.

**"Last one wins" undersells it: alternating the two targets in one configuration produces a bundle that crashes at launch.** `make build`/`make run` build the `Synesthia` scheme and `make build-direct` builds `Synesthia Direct`, but both default to `CONFIGURATION=Debug` and therefore the same output directory. Xcode's incremental build then merges them: you get `Synesthia.debug.dylib` from the Direct target — which links Sparkle — inside a bundle whose `Contents/Frameworks` came from the App Store target and has no `Sparkle.framework`. dyld kills it before `main`:

```
Termination Reason: Namespace DYLD, Code 1, Library missing
Library not loaded: @rpath/Sparkle.framework/Versions/B/Sparkle
  Referenced from: …/Debug/Synesthia.app/Contents/MacOS/Synesthia.debug.dylib
(terminated at launch; ignore backtrace)
```

Nothing in the app is wrong and no source change can fix it, which is what makes it expensive — the obvious reading is "my last commit broke launch". `rm -rf` the bundle (or `make clean`) and rebuild a single target. It only bites in Debug, because the release paths use distinct configurations.

## Project configuration constraints

**Adding files: do not edit `project.pbxproj`.** The project uses `objectVersion = 77` with a `PBXFileSystemSynchronizedRootGroup` for `Synesthia/`. Any `.swift` file created anywhere under `Synesthia/` is compiled automatically. Hand-adding file references will corrupt the sync group. (Editing _build settings_ in project.pbxproj is fine and is how the `INFOPLIST_KEY_*` and `CODE_SIGN_ENTITLEMENTS` values were added.)

**`@MainActor` is the default.** `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and `SWIFT_APPROACHABLE_CONCURRENCY = YES` are set project-wide: every unannotated type, function, and closure is main-actor isolated. Background work must be opted out explicitly — see `nonisolated final class AudioAnalyzer`, `nonisolated struct AudioSnapshot`, and the `nonisolated` SCStreamOutput callbacks. Don't add `@MainActor` annotations; they're redundant. `SWIFT_VERSION = 6.0`, so isolation violations are **errors**, not warnings: anything reachable from the audio thread or the Metal draw callback must be explicitly `nonisolated`. Marking the _type_ `nonisolated` (rather than each member) is the cheap fix — that is why `AudioSnapshot` carries the annotation even though its members look inert.

**`INFOPLIST_KEY_*` only accepts Apple's known keys — arbitrary suffixes are silently dropped.** `GENERATE_INFOPLIST_FILE = YES` and most plist keys go in as `INFOPLIST_KEY_*` build settings: `NSAppleEventsUsageDescription`, `NSMicrophoneUsageDescription`, `NSHumanReadableCopyright`, `LSApplicationCategoryType`, `ITSAppUsesNonExemptEncryption = NO` (that last one pre-answers App Store Connect's export-compliance prompt on every upload). But a _third-party_ key like `SUFeedURL` never reaches the built Info.plist — no warning, no build failure, and `INFOPLIST_KEY_SUFeedURL` sat in this project doing nothing until it was caught by inspecting a built bundle. For those, set **both** `INFOPLIST_FILE` and `GENERATE_INFOPLIST_FILE = YES`: the file is the base and the generated keys merge on top. That is what `Synesthia-Direct-Info.plist` is (Sparkle's three keys only); the App Store target still has no Info.plist file at all.

**Privacy manifest**: `Synesthia/PrivacyInfo.xcprivacy` declares no tracking, no collected data, and one `UserDefaults` access reason. It is picked up automatically by the synchronized group. Its contents must stay in sync with the App Store Connect privacy answers.

**Shared scheme**: `Synesthia.xcodeproj/xcshareddata/xcschemes/Synesthia.xcscheme` is checked in so `xcodebuild -scheme Synesthia` works on a clean clone / in CI without relying on Xcode's implicit scheme autocreation.

**Entitlements**: two files at the repo root (deliberately outside the synced `Synesthia/` folder so they aren't treated as sources/resources), selected per configuration via `CODE_SIGN_ENTITLEMENTS`. Both carry sandbox, audio-input, user-selected read-only files, and app-scope bookmarks (the file source persists across launches via a security-scoped bookmark). `Synesthia-Direct.entitlements` adds `automation.apple-events` and a `temporary-exception.apple-events` for `com.apple.Music` — required because Music defines no scripting-targets group. `Synesthia.entitlements` (App Store) has neither. The unused `assets.music.read-only` was removed: nothing reads the music library. Build-setting entitlements (`ENABLE_APP_SANDBOX` etc.) are merged with the file at signing time. Sandbox is the usual cause of silent failures when reading files outside the container.

`ENABLE_USER_SCRIPT_SANDBOXING = YES` — build phase scripts cannot freely touch the filesystem; declare inputs/outputs if you add one.

## Localization

`LOCALIZATION_PREFERS_STRING_CATALOGS` and `STRING_CATALOG_GENERATE_SYMBOLS` are enabled, but the current UI uses SwiftUI string literals (they are `LocalizedStringKey`s, so they're catalog-ready). Migrating to a `.xcstrings` catalog with generated symbols is an open roadmap item; new user-facing strings should at minimum remain literal `Text("…")` keys, not computed strings.
