# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Synesthia is a macOS-only SwiftUI app (`SDKROOT = macosx`, no iOS/Catalyst target). It is currently the Xcode app template — `SynesthiaApp.swift` (the `@main` `App` with a single `WindowGroup`) and `ContentView.swift` are the entire source. There is no architecture to preserve yet; the constraints below come from the project configuration and are what will bite you.

Built with Xcode 26.6 / Swift 6.3 toolchain. Deployment target is macOS 26.5, so newer platform APIs are available without availability guards.

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

There is **no test target** in the project. Adding one (Xcode → File → New → Target → Unit Testing Bundle) is the prerequisite for any test work; after that:

```bash
xcodebuild test -project Synesthia.xcodeproj -scheme Synesthia -destination 'platform=macOS'

# Single test / suite (Swift Testing or XCTest)
xcodebuild test -project Synesthia.xcodeproj -scheme Synesthia -destination 'platform=macOS' \
  -only-testing:SynesthiaTests/SomeSuite/someTest
```

## Project configuration constraints

**Adding files: do not edit `project.pbxproj`.** The project uses `objectVersion = 77` with a `PBXFileSystemSynchronizedRootGroup` for `Synesthia/`. Any `.swift` file created anywhere under `Synesthia/` is compiled automatically. Hand-adding file references will corrupt the sync group.

**`@MainActor` is the default.** `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and `SWIFT_APPROACHABLE_CONCURRENCY = YES` are set project-wide: every unannotated type, function, and closure is main-actor isolated. Background work must be opted out explicitly with `nonisolated`, `@concurrent`, or a dedicated `actor` — don't add `@MainActor` annotations, they're redundant. Note `SWIFT_VERSION = 5.0` despite the Swift 6.3 toolchain, so strict concurrency is not fully enforced at compile time even though the isolation default is applied.

**No `Info.plist` file exists.** `GENERATE_INFOPLIST_FILE = YES`; add plist keys as `INFOPLIST_KEY_*` build settings in `project.pbxproj` (e.g. `INFOPLIST_KEY_NSMicrophoneUsageDescription`), not by creating a plist.

**No `.entitlements` file exists.** App Sandbox and Hardened Runtime are both on via build settings (`ENABLE_APP_SANDBOX`, `ENABLE_HARDENED_RUNTIME`), with entitlements synthesized at build time. Simple capabilities have build-setting equivalents (`ENABLE_INCOMING_NETWORK_CONNECTIONS`, `ENABLE_OUTGOING_NETWORK_CONNECTIONS`, file-access settings); anything beyond those requires creating an entitlements file and wiring `CODE_SIGN_ENTITLEMENTS`. Sandbox is the usual cause of silent failures when reading files outside the container or opening sockets.

`ENABLE_USER_SCRIPT_SANDBOXING = YES` — build phase scripts cannot freely touch the filesystem; declare inputs/outputs if you add one.

## Localization

`LOCALIZATION_PREFERS_STRING_CATALOGS` and `STRING_CATALOG_GENERATE_SYMBOLS` are enabled. User-facing strings should go through a `.xcstrings` String Catalog and be referenced via the generated symbols rather than raw string literals.
