# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Synesthia is a macOS-only SwiftUI + Metal music visualizer (`SDKROOT = macosx`, no iOS/Catalyst target). It captures audio (system audio via ScreenCaptureKit, mic/line-in via AVAudioEngine, or a local file), runs an FFT, and renders pluggable Metal visualizers. See README.md for the user-facing feature description and roadmap, and `docs/` for developer documentation (architecture, audio pipeline, rendering, plugin system, macOS integration).

Built with Xcode 26.6 / Swift 6.3 toolchain. Deployment target is macOS 26.0, so
macOS 26 APIs (including `glassEffect`) are available without availability
guards. Going below 26.0 requires guarding the five `glassEffect` call sites in
`ContentView.swift` — that is the _only_ thing pinning the floor at 26.

## Architecture

```
Synesthia/
├── SynesthiaApp.swift            @main; WindowGroup + Help/Playback/Visualizer menu commands
├── AppState.swift                @Observable hub: source switching, transport, permissions status
├── ContentView.swift             Canvas + auto-hiding ControlsBar + NowPlayingBadge + OptionsPanel
├── WelcomeView.swift             First-run explainer: sources, permissions, System Settings links
├── Updater.swift                 Sparkle glue, `#if canImport(Sparkle)`; direct build only
├── Resources/DemoLoop.m4a        Generated demo track (scripts/make_demo_loop.py)
├── Audio/
│   ├── AudioAnalyzer.swift       nonisolated, lock-guarded vDSP FFT → AudioSnapshot (64 bands,
│   │                             waveform, bass/mid/treble/level, beat envelope)
│   └── AudioSources.swift        AudioSourceKind, SystemAudioCapture (SCK), InputDeviceCapture,
│                                 FilePlayer, CoreAudio input-device enumeration
├── Music/MusicController.swift   Apple Events to Music.app: transport, poll loop, artwork
└── Visualizers/
    ├── VisualizerCore.swift      Visualizer protocol, VisualizerDescriptor/Option, registry,
    │                             VizUniforms, palettes, persisted VisualizerSettings
    ├── Shaders.metal             ALL shader functions, compiled at build time (see below)
    ├── MetalVisualizerView.swift MetalRenderContext (optional), MTKView host, uniforms per
    │                             frame, occlusion pausing, Reduce Motion damping
    └── {Nebula,Tunnel,Aurora}Visualizer.swift

SynesthiaTests/                   Swift Testing bundle; AudioAnalyzer DSP coverage
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

Data flow: audio threads → `AudioAnalyzer.appendMono` (NSLock) → render loop pulls `analyzer.latest()` each frame. Audio never publishes into SwiftUI; only `MusicController`/`AppState` are observable.

**Plugin contract**: a visualizer = class conforming to `Visualizer` + static `VisualizerDescriptor` (≤4 options, surfaced automatically in the UI and delivered as `VizUniforms.p0…p3`) + shader functions in `Shaders.metal`. Register in `VisualizerRegistry`.

`VizUniforms` in VisualizerCore.swift and the struct in Shaders.metal must stay byte-identical (currently 24 floats / 96 bytes).

## Commands

**The `Makefile` is the single entry point — prefer it over raw `xcodebuild`.** `make` with no target prints the list. Every target is a thin wrapper (the scripts stay runnable directly), so adding a script means adding a target next to it.

```bash
make build            # xcodebuild build; CONFIGURATION=Debug (also Direct, Release)
make build-direct     # …the `Synesthia Direct` target (the one that links Sparkle)
make run              # build, then open the built .app
make test             # xcodebuild test -destination 'platform=macOS'
make clean            # xcodebuild clean + rm -rf build/
make app-path         # print the built .app path for CONFIGURATION

make install          # npm ci at the root (Prettier) and in web/
make lint             # prettier --check + astro check + Functions tsc — everything non-Swift
make format           # prettier --write across the repo

make demo-track       # python3 scripts/make_demo_loop.py
make screenshots      # scripts/take-screenshots.sh → web/src/assets/screenshots
make check-metadata   # scripts/check-metadata.py

make appstore         # archive + assert + export for the Mac App Store
make appstore-upload  # …and upload to App Store Connect
make direct           # archive + Developer ID + notarize + staple + DMG
make direct-fast      # …--skip-notarize
make sparkle-keys     # one-time: create the EdDSA signing key (back it up!)
make appcast          # regenerate the signed Sparkle appcast into build/releases
make publish-release  # upload DMGs + appcast + latest.json to R2 (publish-dry-run first)

make web-install web-dev web-build web-preview web-assets   # the Astro site in web/
make web-typecheck web-cf-types                             # the Pages Functions in web/functions/
```

`ARGS=` forwards flags to the wrapped script (`make screenshots ARGS="--only nebula --1x"`). `BUILT_PRODUCTS_DIR` is resolved from `xcodebuild -showBuildSettings`, not globbed out of DerivedData, so `run`/`app-path` are correct for any configuration.

`SynesthiaTests` is a **Swift Testing** bundle (`import Testing`, `@Test`, `#expect`), hosted by the app target, covering `AudioAnalyzer`.

### Screenshots

`make screenshots` (`scripts/take-screenshots.sh` + `scripts/shotkit.swift`, a Swift helper compiled on demand) relaunches the app once per registered visualizer, sizes the window, captures it, then repeats fullscreen. Notes for changing it:

- **Every run writes under a unique prefix** (`<UTC stamp to the second>-<id>-<windowed|fullscreen>.png`), so nothing is overwritten and two takes can be compared side by side. `--prefix` overrides it; `--prefix ''` gives bare `<id>-<mode>.png` names. Note the generator can't use `tr -dc … </dev/urandom | head -c 4`: `head` closing the pipe kills `tr`, and `set -o pipefail` turns that into a failed run.
- **Visualizers are discovered from source**, not hardcoded: the registry order is parsed out of `VisualizerCore.swift` and each id out of its own `*Visualizer.swift`. A new visualizer is picked up for free.
- **State is injected through the argument domain**, not `defaults write`: `open -a … --args -visualizerID nebula -sourceKind musicApp -hasSeenWelcome YES`. `NSUserDefaults` reads `-key value` pairs out of `argv` at highest priority, which works for a _sandboxed_ app (whose prefs live in its container, so `defaults write com.jonjaques.Synesthia` would go to the wrong plist) and leaves nothing behind in the user's real preferences.
- **The bottom chrome auto-hides after 3 s of pointer stillness**, so every capture is preceded by a synthetic two-step pointer move inside the window plus 0.6 s for the 0.35 s fade-in. One warp is not enough — `onContinuousHover` only reacts to a _change_ in position.
- **It needs Accessibility and Screen & System Audio Recording on the invoking terminal**, and preflights both. Nothing in the app was changed to support it; it drives the shipping UI.
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

**AppleScript constants don't coerce to text.** `player state as text` throws; `player state is playing` compares fine. Map constants to strings via comparisons inside the script (see `MusicController.poll()`). This bug is invisible from Swift — the script just returns nil.

**Music artwork**: prefer `raw data of artwork 1` (original JPEG/PNG), fall back to `data`; artwork lags track changes so the poll retries up to 3× per track.

**TCC flow**: system-audio capture needs Screen & System Audio Recording; the first `startCapture` after a fresh grant can require a second attempt. `AppState.handlePlay` deliberately avoids toggling Music into pause when the user clicks play merely to re-attach capture.

## Build configurations

Three configurations, two app targets. **`Synesthia`/`Release` is the Mac App Store build and `Synesthia Direct`/`Direct` is the notarized direct download** — they differ in whether the Music.app integration and the updater exist at all.

|                           | `Release` (App Store)    | `Direct`                        | `Debug`                         |
| ------------------------- | ------------------------ | ------------------------------- | ------------------------------- |
| Target                    | `Synesthia`              | `Synesthia Direct`              | either                          |
| `MUSIC_APP_SOURCE`        | off                      | on                              | on                              |
| Sparkle                   | never                    | linked                          | Direct target only              |
| Entitlements              | `Synesthia.entitlements` | `Synesthia-Direct.entitlements` | `Synesthia-Direct.entitlements` |
| Apple Events entitlements | none                     | automation + Music exception    | same                            |
| `network.client`          | no                       | yes (Sparkle)                   | yes                             |

`#if MUSIC_APP_SOURCE` removes the `.musicApp` source case, the whole of `MusicController.swift`, and every Apple Event with it, so the App Store build needs neither `automation.apple-events` nor the `temporary-exception.apple-events` for `com.apple.Music` — the single largest review risk this project had. Likewise `#if canImport(Sparkle)` empties `Updater.swift` in the target that doesn't link it, so `SynesthiaApp.swift` needs no conditional at the call site. `scripts/build-appstore.sh` asserts against the built archive that neither leaked (no Apple Events entitlement, no `tell application "Music"` string, no Sparkle framework/link/`SUFeedURL`). Full rationale in `docs/distribution.md`.

Adding a _new_ configuration means cloning the `XCBuildConfiguration` objects at both project and target level and registering both in their `XCConfigurationList`s.

**Two app targets.** `Synesthia` is the App Store build; **`Synesthia Direct`** is the direct download and is the only target that links Sparkle — SPM attaches a package to a target, not a configuration, so keeping Sparkle out of `Release` requires a second target. Both reference the same `PBXFileSystemSynchronizedRootGroup`, so a new `.swift` file under `Synesthia/` compiles into both for free; **build settings are not shared** and must be changed in both places (including `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` on every release). Both produce `Synesthia.app`, so building both in the same configuration means the last one wins in `Build/Products/<config>/` — schemes and archive configurations keep them apart in practice. Full rationale in `docs/distribution.md`.

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
