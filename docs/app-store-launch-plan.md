# Shipping Synesthia: production & Mac App Store plan

Status of this document: written 2026-07-25 against commit `b83330a`. It is a
working plan, not a record — check items off, and delete sections as they stop
being true.

Scope: the macOS app and its App Store submission. The marketing site in `web/`
is tracked separately, except for the two pages the App Store *requires* (see
[External dependencies](#external-dependencies)).

---

## 1. Already done

These changes are in the tree and were each verified by a clean Release build
(plus an `xcodebuild archive` and a launch smoke test where noted).

| Change | Rationale |
|---|---|
| `MACOSX_DEPLOYMENT_TARGET` 26.5 → **26.0** | The only API pinning the floor above 26 is `glassEffect` (5 call sites in `ContentView.swift`), which is a **26.0** API — 26.5 was excluding nearly every macOS 26 user for no reason. |
| `SWIFT_VERSION` 5.0 → **6.0** | Compiles with zero errors once `AudioSnapshot` was fixed. Isolation violations reachable from the audio thread are now errors, not warnings. Release build launches and stays up. |
| `nonisolated struct AudioSnapshot` | Removed **48 of 50** build warnings. `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` was making `bandCount`/`init()` main-actor-isolated while the audio thread and the Metal draw callback read them — latent data-race diagnostics, not cosmetic noise. |
| `ITSAppUsesNonExemptEncryption = NO` | Pre-answers the export-compliance prompt on every App Store Connect upload. Confirmed present in the built `Info.plist`. |
| `NSHumanReadableCopyright` filled in | Was empty; surfaces in the About panel and Finder Get Info. |
| Added `Synesthia/PrivacyInfo.xcprivacy` | Declares no tracking, no collected data, one `UserDefaults` access reason. Confirmed it lands in `Contents/Resources`. |
| Added `xcshareddata/xcschemes/Synesthia.xcscheme` | There was **no shared scheme** — `xcodebuild -list` returned nothing on a clean checkout. Prerequisite for CI. |
| `CLAUDE.md` updated | Records the Swift 6 constraint, the new plist keys, the privacy manifest, and the shared scheme. |

### Verified as already correct

- Release builds a universal binary (`x86_64 arm64`). This matters — macOS 26
  Tahoe is the last release supporting Intel Macs.
- Hardened runtime on, App Sandbox on.
- `com.apple.security.get-task-allow` is correctly stripped from the archive.
- The asset catalog contains a genuine 1024×1024 icon rendition. The generated
  `Icon.icns` tops out at 256px, but that is normal for Icon Composer icons —
  `CFBundleIconName` resolves through `Assets.car`. Not a blocker.

---

## 2. Hard blockers

Nothing ships until every one of these is closed.

### B1 — Bundle identifier is a throwaway, and it is permanent

Currently `jonjaques.Synesthia`: not reverse-DNS, doesn't match `synesthia.app`,
and **cannot be changed after the first submission**. Decide before anything
else, then register the App ID.

- [ ] Choose (`app.synesthia.Synesthia` or `com.jonjaques.Synesthia`)
- [ ] Update `PRODUCT_BUNDLE_IDENTIFIER` in both build configurations
- [ ] Register the App ID in the developer portal

### B2 — Distribution signing does not exist yet

The archive signed with *Apple Development*. Nothing about the current setup
proves distribution signing works.

- [ ] Apple Distribution certificate
- [ ] Mac App Store provisioning profile
- [ ] App record created in App Store Connect
- [ ] **Do a throwaway upload immediately** — flush out validation errors while
      there is still time to react to them

### B3 — `fatalError` on launch if Metal is unavailable

`MetalVisualizerView.Coordinator.init` hard-crashes when
`MTLCreateSystemDefaultDevice()` or `makeDefaultLibrary()` returns nil. App
Review sometimes runs virtualized. A launch crash is an automatic rejection with
no diagnostic attached.

- [ ] Replace with a graceful "Metal unavailable on this Mac" view

### B4 — The app is dead-on-arrival for a reviewer

The default source is Music app, which needs *both* Automation → Music and
Screen & System Audio Recording. A reviewer who grants nothing sees a black
canvas and rejects under guideline 2.1, "app does not function."

- [ ] First-run explainer naming both permissions, with deep links into System
      Settings
- [ ] A path that works with **zero** permissions. Cleanest fix: bundle a short
      royalty-free clip behind a "See a demo" button, so the visuals are
      provably alive before any TCC prompt fires.

### B5 — `temporary-exception.apple-events` → `com.apple.Music`

The single largest review risk. Approvable, but it requires explicit
justification. Options, in preference order:

1. Ship it with a clear justification: Music.app publishes no
   scripting-targets group, and the entitlement is used only for transport
   control and now-playing metadata the user can see on screen.
2. **Cut Music.app control from the v1 App Store build.** System audio already
   visualizes Apple Music perfectly; the only loss is the metadata badge, and it
   drops two entitlements and one permission prompt.
3. Spike whether MusicKit on macOS can supply now-playing metadata without
   Apple Events. Unverified — check what's actually available on the platform
   before betting on it.

- [ ] Decision made and, if shipping the exception, review notes drafted

### B6 — Unused `com.apple.security.assets.music.read-only` entitlement

Nothing in the code reads music-library files: artwork arrives over Apple
Events, and `FilePlayer` only opens user-selected files. Unrequired entitlements
invite review questions.

- [ ] Remove, then regression-test the Music path with Music.app running
      (this could not be verified headlessly, so verify it by hand)

### B7 — Trademark

"Synesthia" is one letter from **Synesthesia**, an established music-software
product in the same category. Confusingly similar mark.

- [ ] Clear this before the name goes on an App Store listing and a domain

---

## 3. Quality gaps

Not submission blockers. They are what one-star reviews are made of.

- [ ] **Renders 60fps forever.** No occlusion or background handling — the
      MTKView never pauses when the window is hidden or the app is inactive. A
      fan-spinning battery complaint on any laptop. Pause on
      `NSApplication.occlusionState` and when capture is idle.
- [ ] **Screen sleeps mid-song.** No idle-sleep assertion. The first thing users
      will report about a fullscreen visualizer. Take an activity assertion with
      `.idleDisplaySleepDisabled` while capturing.
- [ ] **No Reduce Motion / photosensitivity handling.** A beat-reactive flashing
      visualizer carries a real seizure-risk profile. Honor
      `accessibilityReduceMotion` and cap flash intensity. Accessibility *and*
      liability.
- [ ] **VoiceOver.** 14 icon-only buttons have `.help()` tooltips and no
      `accessibilityLabel` — tooltips are not accessibility labels. Compounded
      by the controls bar auto-hiding on mouse idle, which is hostile to
      keyboard and switch users.
- [ ] **No Help menu and no in-app support affordance.** Expected of App Store
      apps, and it's where the Support URL belongs.
- [ ] **File source doesn't survive relaunch.** No security-scoped bookmark, so
      the chosen file is forgotten every launch.
- [ ] **Fixed `preferredFramesPerSecond = 60`** on ProMotion hardware capable
      of 120.
- [ ] **No test target.** Shipping a DSP pipeline with zero regression coverage.
      `AudioAnalyzer` band mapping and beat detection are the obvious first
      subjects; see `CLAUDE.md` for the setup command.
- [ ] **English only.** Fine for v1. The string-catalog migration is already
      tracked in `CLAUDE.md`.
- [ ] Minor: `Accent color 'AccentColor' is not present in any asset catalogs`
      is the only remaining build warning. Either add the colorset — which
      changes control tint app-wide, so it's a design call — or clear
      `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME`.

---

## 4. App Store Connect checklist

### External dependencies

Both mandatory, both on `synesthia.app`. Submission is impossible without them.

- [ ] Privacy Policy page
- [ ] Support page

### Assets

- [ ] Screenshots: 1–10, at 1280×800, 1440×900, 2560×1600, or 2880×1800
- [ ] **App preview video — the high-leverage asset.** A static screenshot of a
      visualizer sells nothing. Up to 3, 15–30s, 16:9 at 1080p or 4K. Recording
      the app needs Screen Recording permission, which is already plumbed.
- [ ] Icon: already correct in the binary, nothing to do

### Metadata

- [ ] Subtitle (30 chars), promotional text (170), description
- [ ] Keywords (100 chars)
- [ ] Category: Music (already set as `LSApplicationCategoryType`)
- [ ] Copyright, age rating questionnaire, price

### Privacy & review

- [ ] App Privacy answers: "Data Not Collected" — must match
      `Synesthia/PrivacyInfo.xcprivacy`
- [ ] **Review notes.** Write these carefully: explain both permissions, why
      ScreenCaptureKit is the only sanctioned system-audio API on macOS, that
      the video leg is captured at 2×2px and discarded, and give a literal
      repro path that does not depend on Music.app having content.

---

## 5. Suggested order

1. B1 + B2 — bundle ID, App ID, ASC record, distribution cert. Throwaway upload
   straight away.
2. B7 — trademark clearance. Blocks the name, so resolve it early.
3. B3–B6 — Metal fallback, first-run permission UX and demo clip, resolve the
   Apple Events question, drop the unused music entitlement.
4. Power / sleep / accessibility pass (§3).
5. Test target + CI. The shared scheme is already in place as the prerequisite.
6. Privacy and Support pages, screenshots, preview video, metadata.
7. Submit.

---

## 6. Strategic note: ship direct first

Worth doing in parallel: a **notarized direct download** from `synesthia.app`.

The `temporary-exception.apple-events` problem is purely a Mac App Store review
concern. Outside the store the same app can ship today — no review queue, and no
risk that a reviewer never sees it work. That means real users and real crash
data before the store submission, arriving from a hardened position rather than a
speculative one.

Blockers **B1**, **B5**, and **B6** largely evaporate on that path. The domain
and the landing page are already in progress, so the incremental cost is
notarization plumbing plus an update mechanism (Sparkle).
