# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Synesthia is a macOS-only SwiftUI + Metal music visualizer (`SDKROOT = macosx`, no iOS/Catalyst target). It captures audio (system audio via ScreenCaptureKit, mic/line-in via AVAudioEngine, or a local file), runs an FFT, and renders pluggable Metal visualizers. See README.md for the user-facing feature description and roadmap, and `docs/` for developer documentation (architecture, audio pipeline, rendering, plugin system, macOS integration).

Built with Xcode 26.6 / Swift 6.3 toolchain. Deployment target is macOS 26.5, so newer platform APIs are available without availability guards.

## Architecture

```
Synesthia/
├── SynesthiaApp.swift            @main; WindowGroup + Playback/Visualizer menu commands
├── AppState.swift                @Observable hub: source switching, transport, permissions status
├── ContentView.swift             Canvas + auto-hiding ControlsBar + NowPlayingBadge + OptionsPanel
├── Audio/
│   ├── AudioAnalyzer.swift       nonisolated, lock-guarded vDSP FFT → AudioSnapshot (64 bands,
│   │                             waveform, bass/mid/treble/level, beat envelope)
│   └── AudioSources.swift        AudioSourceKind, SystemAudioCapture (SCK), InputDeviceCapture,
│                                 FilePlayer, CoreAudio input-device enumeration
├── Music/MusicController.swift   Apple Events to Music.app: transport, poll loop, artwork
└── Visualizers/
    ├── VisualizerCore.swift      Visualizer protocol, VisualizerDescriptor/Option, registry,
    │                             VizUniforms, palettes, persisted VisualizerSettings
    ├── ShaderSource.swift        ALL Metal shader source as an MSL string (see below)
    ├── MetalVisualizerView.swift NSViewRepresentable MTKView host; builds uniforms per frame
    └── {Nebula,Tunnel,Aurora}Visualizer.swift
```

Data flow: audio threads → `AudioAnalyzer.appendMono` (NSLock) → render loop pulls `analyzer.latest()` each frame. Audio never publishes into SwiftUI; only `MusicController`/`AppState` are observable.

**Plugin contract**: a visualizer = class conforming to `Visualizer` + static `VisualizerDescriptor` (≤4 options, surfaced automatically in the UI and delivered as `VizUniforms.p0…p3`) + shader functions compiled at runtime. Register in `VisualizerRegistry`.

`VizUniforms` in VisualizerCore.swift and the struct in ShaderSource.swift must stay byte-identical (currently 24 floats / 96 bytes).

## Commands

```bash
# Build (Debug)
xcodebuild -project Synesthia.xcodeproj -scheme Synesthia -configuration Debug build

# Build and run
xcodebuild -project Synesthia.xcodeproj -scheme Synesthia -configuration Debug build && \
  open ~/Library/Developer/Xcode/DerivedData/Synesthia-*/Build/Products/Debug/Synesthia.app

# Clean
xcodebuild -project Synesthia.xcodeproj -scheme Synesthia clean
```

There is **no test target**. Adding one (Xcode → File → New → Target → Unit Testing Bundle) is the prerequisite for any test work; `AudioAnalyzer` (band mapping, beat detection) is the natural first unit-test subject. After adding:

```bash
xcodebuild test -project Synesthia.xcodeproj -scheme Synesthia -destination 'platform=macOS'
```

## Hard-won gotchas (violating these caused real bugs)

**No offline Metal toolchain on this machine.** Any `.metal` file in the target fails the build with "cannot execute tool 'metal' due to missing Metal Toolchain" (fix would be a multi-GB `xcodebuild -downloadComponent MetalToolchain`). Therefore ALL shader source lives in `ShaderSource.swift` as a raw string, compiled at launch with `device.makeLibrary(source:)`. Do not add `.metal` files; append MSL to that string.

**ScreenCaptureKit audio extraction.** Use `sampleBuffer.withAudioBufferList` + `AVAudioPCMBuffer(pcmFormat:bufferListNoCopy:)` (the current code). Do NOT use `CMSampleBufferCopyPCMDataIntoAudioBufferList` into a fresh `AVAudioPCMBuffer` — its buffer list advertises `frameLength` (0) bytes, every copy fails with `err=-12731`, and the analyzer silently receives nothing. Also: even when only capturing audio, register a `.screen` stream output too, or SCK logs "stream output NOT found. Dropping frame" continuously.

**AppleScript constants don't coerce to text.** `player state as text` throws; `player state is playing` compares fine. Map constants to strings via comparisons inside the script (see `MusicController.poll()`). This bug is invisible from Swift — the script just returns nil.

**Music artwork**: prefer `raw data of artwork 1` (original JPEG/PNG), fall back to `data`; artwork lags track changes so the poll retries up to 3× per track.

**TCC flow**: system-audio capture needs Screen & System Audio Recording; the first `startCapture` after a fresh grant can require a second attempt. `AppState.handlePlay` deliberately avoids toggling Music into pause when the user clicks play merely to re-attach capture.

## Project configuration constraints

**Adding files: do not edit `project.pbxproj`.** The project uses `objectVersion = 77` with a `PBXFileSystemSynchronizedRootGroup` for `Synesthia/`. Any `.swift` file created anywhere under `Synesthia/` is compiled automatically. Hand-adding file references will corrupt the sync group. (Editing *build settings* in project.pbxproj is fine and is how the `INFOPLIST_KEY_*` and `CODE_SIGN_ENTITLEMENTS` values were added.)

**`@MainActor` is the default.** `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and `SWIFT_APPROACHABLE_CONCURRENCY = YES` are set project-wide: every unannotated type, function, and closure is main-actor isolated. Background work must be opted out explicitly — see `nonisolated final class AudioAnalyzer` and the `nonisolated` SCStreamOutput callbacks. Don't add `@MainActor` annotations; they're redundant. `SWIFT_VERSION = 5.0`, so strict concurrency is not fully enforced at compile time even though the isolation default applies.

**No `Info.plist` file.** `GENERATE_INFOPLIST_FILE = YES`; plist keys go in as `INFOPLIST_KEY_*` build settings in project.pbxproj. Currently set: `NSAppleEventsUsageDescription`, `NSMicrophoneUsageDescription`.

**Entitlements**: `Synesthia.entitlements` at the repo root (deliberately outside the synced `Synesthia/` folder so it isn't treated as a source/resource), wired via `CODE_SIGN_ENTITLEMENTS`. Contains sandbox, audio-input, user-selected read-only files, music-library read, `automation.apple-events`, and a `temporary-exception.apple-events` for `com.apple.Music` (required — Music defines no scripting-targets groups; note this exception would need review for App Store distribution). Build-setting entitlements (`ENABLE_APP_SANDBOX` etc.) are merged with the file at signing time. Sandbox is the usual cause of silent failures when reading files outside the container.

`ENABLE_USER_SCRIPT_SANDBOXING = YES` — build phase scripts cannot freely touch the filesystem; declare inputs/outputs if you add one.

## Localization

`LOCALIZATION_PREFERS_STRING_CATALOGS` and `STRING_CATALOG_GENERATE_SYMBOLS` are enabled, but the current UI uses SwiftUI string literals (they are `LocalizedStringKey`s, so they're catalog-ready). Migrating to a `.xcstrings` catalog with generated symbols is an open roadmap item; new user-facing strings should at minimum remain literal `Text("…")` keys, not computed strings.
