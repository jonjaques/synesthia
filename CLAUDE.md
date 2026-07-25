# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Synesthia is a macOS-only SwiftUI + Metal music visualizer (`SDKROOT = macosx`, no iOS/Catalyst target). It captures audio (system audio via ScreenCaptureKit, mic/line-in via AVAudioEngine, or a local file), runs an FFT, and renders pluggable Metal visualizers. See README.md for the user-facing feature description and roadmap, and `docs/` for developer documentation (architecture, audio pipeline, rendering, plugin system, macOS integration).

Built with Xcode 26.6 / Swift 6.3 toolchain. Deployment target is macOS 26.0, so
macOS 26 APIs (including `glassEffect`) are available without availability
guards. Going below 26.0 requires guarding the five `glassEffect` call sites in
`ContentView.swift` — that is the *only* thing pinning the floor at 26.

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
scripts/                          make_demo_loop.py, build-appstore.sh, build-direct.sh,
                                  make-appcast.sh, check-metadata.py
```

Data flow: audio threads → `AudioAnalyzer.appendMono` (NSLock) → render loop pulls `analyzer.latest()` each frame. Audio never publishes into SwiftUI; only `MusicController`/`AppState` are observable.

**Plugin contract**: a visualizer = class conforming to `Visualizer` + static `VisualizerDescriptor` (≤4 options, surfaced automatically in the UI and delivered as `VizUniforms.p0…p3`) + shader functions in `Shaders.metal`. Register in `VisualizerRegistry`.

`VizUniforms` in VisualizerCore.swift and the struct in Shaders.metal must stay byte-identical (currently 24 floats / 96 bytes).

## Commands

```bash
# Build (Debug)
xcodebuild -project Synesthia.xcodeproj -scheme Synesthia -configuration Debug build

# Build and run
xcodebuild -project Synesthia.xcodeproj -scheme Synesthia -configuration Debug build && \
  open ~/Library/Developer/Xcode/DerivedData/Synesthia-*/Build/Products/Debug/Synesthia.app

# Test
xcodebuild test -project Synesthia.xcodeproj -scheme Synesthia -destination 'platform=macOS'

# Clean
xcodebuild -project Synesthia.xcodeproj -scheme Synesthia clean

# Release pipelines (see docs/distribution.md)
./scripts/build-appstore.sh              # archive + assert + export for the Mac App Store
./scripts/build-direct.sh                # archive + Developer ID + notarize + staple + DMG
```

`SynesthiaTests` is a **Swift Testing** bundle (`import Testing`, `@Test`, `#expect`), hosted by the app target, covering `AudioAnalyzer`. Regenerate the demo track with `python3 scripts/make_demo_loop.py` (deterministic; needs only the stdlib and `afconvert`).

## Hard-won gotchas (violating these caused real bugs)

**Shaders compile at build time.** The Metal Toolchain component (26.6) is installed as of 2026-07, so `.metal` files build normally. All shader source lives in `Synesthia/Visualizers/Shaders.metal`, compiled into the app's default library and loaded via `device.makeDefaultLibrary()`. (Historical: the toolchain used to be missing, so shaders lived in a `ShaderSource.swift` string compiled at launch — don't resurrect that for built-ins; `makeLibrary(source:)` remains the intended path only for future external plugin bundles.)

**ScreenCaptureKit audio extraction.** Use `sampleBuffer.withAudioBufferList` + `AVAudioPCMBuffer(pcmFormat:bufferListNoCopy:)` (the current code). Do NOT use `CMSampleBufferCopyPCMDataIntoAudioBufferList` into a fresh `AVAudioPCMBuffer` — its buffer list advertises `frameLength` (0) bytes, every copy fails with `err=-12731`, and the analyzer silently receives nothing. Also: even when only capturing audio, register a `.screen` stream output too, or SCK logs "stream output NOT found. Dropping frame" continuously.

**AVFAudio callbacks must be built in a `nonisolated` context, or they trap.** `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` means a closure written inline inside a main-actor method is *itself* inferred main-actor. AVAudioEngine calls tap blocks and `scheduleFile` completion handlers on a realtime audio thread, so Swift 6's isolation check fires and the app dies with `EXC_BREAKPOINT` in `swift_task_checkIsolatedSwift` — on the very first buffer, with a stack that blames AVFAudio rather than the closure. Build these blocks from a `nonisolated` factory (`makeAnalyzerTap`, `FilePlayer.loopCompletion()`), never inline. Wrapping the body in `Task { @MainActor in … }` does **not** help: the trap happens on entry, before the `Task` is ever reached. Spell the return type `@Sendable () -> Void`; the `AVAudioNodeCompletionHandler` typealias isn't marked `@Sendable` and the call site warns.

**AppleScript constants don't coerce to text.** `player state as text` throws; `player state is playing` compares fine. Map constants to strings via comparisons inside the script (see `MusicController.poll()`). This bug is invisible from Swift — the script just returns nil.

**Music artwork**: prefer `raw data of artwork 1` (original JPEG/PNG), fall back to `data`; artwork lags track changes so the poll retries up to 3× per track.

**TCC flow**: system-audio capture needs Screen & System Audio Recording; the first `startCapture` after a fresh grant can require a second attempt. `AppState.handlePlay` deliberately avoids toggling Music into pause when the user clicks play merely to re-attach capture.

## Build configurations

Three configurations, one target. **`Release` is the Mac App Store build and `Direct` is the notarized direct download** — they differ in whether the Music.app integration exists at all.

| | `Release` (App Store) | `Direct` | `Debug` |
|---|---|---|---|
| `MUSIC_APP_SOURCE` | off | on | on |
| Entitlements | `Synesthia.entitlements` | `Synesthia-Direct.entitlements` | `Synesthia-Direct.entitlements` |
| Apple Events entitlements | none | automation + Music exception | same |

`#if MUSIC_APP_SOURCE` removes the `.musicApp` source case, the whole of `MusicController.swift`, and every Apple Event with it, so the App Store build needs neither `automation.apple-events` nor the `temporary-exception.apple-events` for `com.apple.Music` — the single largest review risk this project had. `scripts/build-appstore.sh` asserts against the built archive that none of it leaked. Full rationale in `docs/distribution.md`.

Adding a *new* configuration means cloning the `XCBuildConfiguration` objects at both project and target level and registering both in their `XCConfigurationList`s.

## Project configuration constraints

**Adding files: do not edit `project.pbxproj`.** The project uses `objectVersion = 77` with a `PBXFileSystemSynchronizedRootGroup` for `Synesthia/`. Any `.swift` file created anywhere under `Synesthia/` is compiled automatically. Hand-adding file references will corrupt the sync group. (Editing *build settings* in project.pbxproj is fine and is how the `INFOPLIST_KEY_*` and `CODE_SIGN_ENTITLEMENTS` values were added.)

**`@MainActor` is the default.** `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and `SWIFT_APPROACHABLE_CONCURRENCY = YES` are set project-wide: every unannotated type, function, and closure is main-actor isolated. Background work must be opted out explicitly — see `nonisolated final class AudioAnalyzer`, `nonisolated struct AudioSnapshot`, and the `nonisolated` SCStreamOutput callbacks. Don't add `@MainActor` annotations; they're redundant. `SWIFT_VERSION = 6.0`, so isolation violations are **errors**, not warnings: anything reachable from the audio thread or the Metal draw callback must be explicitly `nonisolated`. Marking the *type* `nonisolated` (rather than each member) is the cheap fix — that is why `AudioSnapshot` carries the annotation even though its members look inert.

**No `Info.plist` file.** `GENERATE_INFOPLIST_FILE = YES`; plist keys go in as `INFOPLIST_KEY_*` build settings in project.pbxproj (the suffix becomes the key verbatim, so arbitrary keys work). Currently set: `NSAppleEventsUsageDescription`, `NSMicrophoneUsageDescription`, `NSHumanReadableCopyright`, `LSApplicationCategoryType`, and `ITSAppUsesNonExemptEncryption = NO` (the last one pre-answers App Store Connect's export-compliance prompt on every upload).

**Privacy manifest**: `Synesthia/PrivacyInfo.xcprivacy` declares no tracking, no collected data, and one `UserDefaults` access reason. It is picked up automatically by the synchronized group. Its contents must stay in sync with the App Store Connect privacy answers.

**Shared scheme**: `Synesthia.xcodeproj/xcshareddata/xcschemes/Synesthia.xcscheme` is checked in so `xcodebuild -scheme Synesthia` works on a clean clone / in CI without relying on Xcode's implicit scheme autocreation.

**Entitlements**: two files at the repo root (deliberately outside the synced `Synesthia/` folder so they aren't treated as sources/resources), selected per configuration via `CODE_SIGN_ENTITLEMENTS`. Both carry sandbox, audio-input, user-selected read-only files, and app-scope bookmarks (the file source persists across launches via a security-scoped bookmark). `Synesthia-Direct.entitlements` adds `automation.apple-events` and a `temporary-exception.apple-events` for `com.apple.Music` — required because Music defines no scripting-targets group. `Synesthia.entitlements` (App Store) has neither. The unused `assets.music.read-only` was removed: nothing reads the music library. Build-setting entitlements (`ENABLE_APP_SANDBOX` etc.) are merged with the file at signing time. Sandbox is the usual cause of silent failures when reading files outside the container.

`ENABLE_USER_SCRIPT_SANDBOXING = YES` — build phase scripts cannot freely touch the filesystem; declare inputs/outputs if you add one.

## Localization

`LOCALIZATION_PREFERS_STRING_CATALOGS` and `STRING_CATALOG_GENERATE_SYMBOLS` are enabled, but the current UI uses SwiftUI string literals (they are `LocalizedStringKey`s, so they're catalog-ready). Migrating to a `.xcstrings` catalog with generated symbols is an open roadmap item; new user-facing strings should at minimum remain literal `Text("…")` keys, not computed strings.
