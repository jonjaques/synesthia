# Shipping Synesthia: production & Mac App Store plan

Status of this document: written 2026-07-25 against commit `b83330a`, executed
the same day in `377f02b`. It is a working plan, not a record — check items
off, and delete sections as they stop being true. See
[prerelease-report.md](prerelease-report.md) for what that execution covered
and what it left open.

Scope: the macOS app and its App Store submission. The marketing site in `web/`
is tracked separately, except for the two pages the App Store *requires* (now
built — see [App Store Connect checklist](#4-app-store-connect-checklist)).

**Everything that can be done without an Apple Developer portal login is
done.** What remains is in [§2](#2-hard-blockers) and
[§6](#6-what-needs-a-human), and almost all of it needs either an Apple account
or a pair of eyes on the running app.

---

## 1. Done

Each change below was verified by a clean build of all three configurations,
an `xcodebuild archive` with automated assertions against the built bundle, and
a launch smoke test.

### Earlier pass

| Change | Rationale |
|---|---|
| `MACOSX_DEPLOYMENT_TARGET` 26.5 → **26.0** | `glassEffect` is a 26.0 API; 26.5 excluded nearly every macOS 26 user for no reason. |
| `SWIFT_VERSION` 5.0 → **6.0** | Isolation violations reachable from the audio thread are now errors. |
| `nonisolated struct AudioSnapshot` | Removed 48 of 50 build warnings; latent data-race diagnostics. |
| `ITSAppUsesNonExemptEncryption = NO` | Pre-answers export compliance on every upload. |
| `NSHumanReadableCopyright` filled in | Surfaces in About and Get Info. |
| Added `Synesthia/PrivacyInfo.xcprivacy` | No tracking, no collected data, one `UserDefaults` reason. |
| Added a shared scheme | `xcodebuild -list` returned nothing on a clean checkout. |

### This pass

| Blocker | What was done |
|---|---|
| **B1** bundle ID | `jonjaques.Synesthia` → **`com.jonjaques.Synesthia`** in every configuration. |
| **B3** Metal `fatalError` | Replaced with `MetalRenderContext.shared` (optional) and a `MetalUnavailableView`. No launch path can crash on a missing GPU. |
| **B4** dead on arrival | New **`.demo` source**, default on first launch, playing a 32 s loop bundled with the app. Zero permissions. Plus a first-run `WelcomeView` naming every permission with deep links into the right System Settings pane. |
| **B5** Apple Events | **Feature-flagged.** `MUSIC_APP_SOURCE` is off in `Release`, so the App Store build contains no `MusicController`, no AppleScript, and neither Apple Events entitlement. `Direct` keeps the feature. |
| **B6** unused entitlement | `com.apple.security.assets.music.read-only` removed. |
| Quality: power | MTKView pauses on occlusion/miniaturize; drops to 30 fps when inactive or idle; runs at the display's full rate (incl. 120 Hz ProMotion) only while audio flows. |
| Quality: sleep | `beginActivity(.idleDisplaySleepDisabled)` held **only** while audio is flowing, released the moment it stops. |
| Quality: photosensitivity | Reduce Motion honored — clock slowed, transients damped to 25%, level features smoothed with a 0.4 s time constant. Done CPU-side to preserve the 96-byte `VizUniforms` contract. |
| Quality: VoiceOver | `accessibilityLabel` on all 14 icon-only buttons; chrome no longer auto-hides while VoiceOver is running. |
| Quality: Help menu | Replaces the dead default; opens the explainer, the Support URL, and the Privacy URL. |
| Quality: file persistence | Security-scoped bookmark, refreshed when stale. |
| Quality: build warning | `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME` cleared. **All three configurations now build with zero warnings.** |
| Test target | **`SynesthiaTests`** (Swift Testing), 19 tests over `AudioAnalyzer`, all passing. |
| Distribution | `build-appstore.sh`, `build-direct.sh`, `make-appcast.sh`, both export plists, and `docs/distribution.md`. |
| Metadata | `docs/app-store-metadata.md` — every listing field plus review notes, length-checked by `scripts/check-metadata.py`. |
| Web | `/privacy` and `/support` built and linked from the footer. |

### Two real bugs found while testing

- **Every `FilePlayer` launch crashed.** AVAudioEngine tap blocks were being
  created inside main-actor methods (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
  infers that), and AVFAudio calls them on a realtime thread — Swift 6's
  isolation check trapped on the first buffer. Latent until the demo source
  started a `FilePlayer` at launch. Fixed with `nonisolated` block factories.
- **The same bug in `scheduleFile`'s completion handler**, which would have
  killed the app 32 s in, at the first loop point. The existing
  `Task { @MainActor … }` hop did not help — the trap precedes it.

Both are now covered by a note in `CLAUDE.md`, and the app has been verified
running past three consecutive loop points with no crash reports.

### Verified as already correct

- Release **archives** build a universal binary (`x86_64 arm64`) — asserted by
  `build-appstore.sh`. (A plain `xcodebuild build` produces arm64 only; that is
  the build action, not a misconfiguration.)
- Hardened runtime on, App Sandbox on.
- `com.apple.security.get-task-allow` is stripped from the archive — asserted.
- The asset catalog contains a genuine 1024×1024 icon rendition.

---

## 2. Hard blockers

### B2 — Distribution signing does not exist yet

**The only remaining hard blocker, and it needs an Apple Developer login.**
The only certificate on this machine is *Apple Development*. Both release
scripts archive successfully and stop at export:

```
error: exportArchive No signing certificate "Mac Installer Distribution" found
error: exportArchive No profiles for 'com.jonjaques.Synesthia' were found
error: exportArchive No signing certificate "Developer ID Application" found
```

- [ ] Register the App ID `com.jonjaques.Synesthia`
- [ ] Apple Distribution certificate + Mac App Store provisioning profile
- [ ] Mac Installer Distribution certificate (App Store `.pkg`)
- [ ] Developer ID Application certificate (direct download)
- [ ] `xcrun notarytool store-credentials SYNESTHIA_NOTARY …`
- [ ] Create the App Store Connect record
- [ ] **Throwaway upload immediately** — flush out validation errors early

### B7 — Trademark

"Synesthia" is one letter from **Synesthesia**, an established music-software
product in the same category.

A USPTO search turns up no registered mark for "Synesthesia" in the software
class, but that is not clearance: the product demonstrably exists and sells, so
common-law rights are likely, and confusing similarity is judged on the overall
impression rather than the letter count. This is a legal call, not a technical
one.

- [ ] Clear this before the name goes on a listing and a domain

Nothing else in the repo is name-dependent except listing copy and the domain,
so a rename stays cheap right up until submission.

---

## 3. Quality gaps

Everything actionable here is done (see §1). Deliberately deferred:

- [ ] **English only.** Fine for v1; the string-catalog migration is tracked in
      `CLAUDE.md`.
- [ ] **Visualizer test coverage.** The new test target covers `AudioAnalyzer`;
      the Metal visualizers have no coverage and are much harder to assert on.

---

## 4. App Store Connect checklist

### External dependencies — **done**

- [x] Privacy Policy — `web/src/pages/privacy.astro` → `/privacy`
- [x] Support page — `web/src/pages/support.astro` → `/support`

Both build, are in the sitemap, and are linked from the landing-page footer.
The privacy page's claims match `PrivacyInfo.xcprivacy`, and it discloses the
website's Google Analytics separately from the app (which collects nothing).

### Assets — **needs a human**

- [ ] Screenshots: 1–10, at 1280×800, 1440×900, 2560×1600, or 2880×1800
- [ ] **App preview video — the high-leverage asset.** A static screenshot of a
      visualizer sells nothing. Up to 3, 15–30 s, 16:9 at 1080p or 4K.
- [x] Icon: already correct in the binary

### Metadata — **drafted**

- [x] Subtitle, promotional text, description, keywords — all within limits
- [x] Category: Music
- [x] Copyright, age rating answers, App Privacy answers
- [ ] Price: undecided. The site's structured data currently advertises free;
      if it ships paid, update `web/src/layouts/Base.astro`.

All in `docs/app-store-metadata.md`. Re-check limits with
`python3 scripts/check-metadata.py`.

### Review notes — **drafted**

- [x] Written, in `docs/app-store-metadata.md`. Leads with the
      zero-permission repro path, then explains why a music visualizer needs
      the screen-recording permission and that the video leg is 2×2 px and
      discarded.

---

## 5. Contact addresses are placeholders

`web/src/consts.ts` publishes `support@synesthia.app` and
`privacy@synesthia.app`. **Neither has mail routing yet.** Apple checks that
the support URL resolves, and a dead support address is a genuine review risk
as well as a bad look.

- [ ] Set up mail routing for both, or change them to a real address

---

## 6. What needs a human

Ordered by what blocks the most.

1. **B2 — Apple Developer portal.** Certificates, App ID, profiles, ASC
   record, notary credentials. Then a throwaway upload.
2. **B7 — trademark clearance.** Blocks the name; cheapest to resolve now.
3. **Mail routing** for the two published addresses (§5).
4. **Screenshots and the preview video.** Requires driving the app by hand and
   recording it; I have no screen-recording permission in this environment, so
   I could not capture, or even visually check, a single frame of the UI I
   changed.
5. **Look at the app.** Everything below was verified only structurally —
   builds, assertions against the built bundle, power assertions, crash
   reports, and unit tests:
   - the first-run welcome sheet's layout and wording
   - the demo track's *sound* (verified only as levels and per-band energy)
   - Reduce Motion actually looking calmer
   - VoiceOver actually reading the new labels
6. **Sparkle's final step.** The code is written and guarded on
   `canImport(Sparkle)`; linking the package needs a decision about keeping it
   out of the App Store build. See `docs/distribution.md`.
7. **Regression-test the Music path by hand** (B6's follow-up) with Music.app
   running, in the `Direct` configuration.

---

## 7. Strategic note: ship direct first

Still worth doing, and now cheaper than when this plan was written.

A **notarized direct download** from `synesthia.app` avoids the review queue
entirely, and `scripts/build-direct.sh` already implements the whole pipeline —
archive, Developer ID export, signature and hardened-runtime verification, DMG,
notarize, staple, Gatekeeper check. It needs only the Developer ID certificate
from B2.

The `temporary-exception.apple-events` problem is now purely an App Store
concern by construction: the `Direct` configuration ships the Music.app feature
and the App Store one does not contain it at all. That means real users and
real crash data can arrive before the store submission — from a hardened
position rather than a speculative one.

Remaining incremental cost: the Developer ID certificate, notary credentials,
and the Sparkle linking decision.
