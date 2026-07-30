# Shipping Synesthia — launch plan

Working plan, not a record. Check items off; delete sections as they stop being
true. Last reconciled against the repo and against Apple/Cloudflare on
**2026-07-25**, after the direct download went live.

This absorbed the former `docs/prerelease-report.md` — its decisions, findings
and verification evidence are §2, §6 and §8 below, brought up to date. That file
is gone; `git log -- docs/prerelease-report.md` still has it if the dated
snapshot is ever wanted. See `docs/distribution.md` for how the release pipeline
works and `docs/app-store-metadata.md` for every listing field.

---

## Where things stand

**The direct download has shipped.** `synesthia.app/download` serves a
notarized, stapled, Gatekeeper-accepted 1.0, and Sparkle is wired end to end.
The Mac App Store submission has not been made.

|                        | Direct download                       | Mac App Store                             |
| ---------------------- | ------------------------------------- | ----------------------------------------- |
| Target / configuration | `Synesthia Direct` / `Direct`         | `Synesthia` / `Release`                   |
| Signing                | ✅ Developer ID Application           | ⚠️ missing **Mac Installer Distribution** |
| Notarization           | ✅ 3 accepted submissions             | n/a                                       |
| Self-update            | ✅ Sparkle 2.9.4, signed appcast      | n/a (the store updates it)                |
| Hosting                | ✅ R2 + Pages Functions               | App Store Connect                         |
| Advertised on the site | ✅ `DIRECT_DOWNLOAD_AVAILABLE = true` | ❌ `APP_STORE_AVAILABLE = false`          |
| **Status**             | **live**                              | blocked on §3 B2                          |

Strategically this is where we wanted to be: real users and real crash data can
arrive before the review queue is ever joined, and the
`temporary-exception.apple-events` question is now purely an App Store concern
by construction — the store build does not contain the feature at all.

---

## 1. Done

### Direct download — shipped

- [x] **Developer ID Application certificate** created and in use
- [x] **Notary credentials** stored (`SYNESTHIA_NOTARY`); 3 accepted submissions
- [x] **Sparkle linked** — 2.9.4, via a second app target so it cannot reach `Release`
- [x] **EdDSA signing key** generated; public half in `Synesthia-Direct-Info.plist`
- [x] Sandboxed-Sparkle wiring: `Installer.xpc`, `-spks`/`-spki` mach-lookup exceptions, `network.client`
- [x] **App and DMG both notarized and stapled**; the app _inside_ the DMG carries its own ticket
- [x] DMG signed with Developer ID (not just notarized — see §6)
- [x] **R2 bucket + Pages Functions**: `/appcast.xml`, `/download`, `/downloads/*`
- [x] `make bump` — semver + build number across all 9 pbxproj copies
- [x] Publish guard: refuses to overwrite a published DMG whose contents differ
- [x] **1.0 published and verified live**

### Blockers closed earlier

| Blocker                   | Resolution                                                                                                                                                                                                                                         |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **B1** bundle ID          | `jonjaques.Synesthia` → `com.jonjaques.Synesthia`, every configuration                                                                                                                                                                             |
| **B3** Metal `fatalError` | Optional `MetalRenderContext.shared` + `MetalUnavailableView`; no launch path can crash without a GPU                                                                                                                                              |
| **B4** dead on arrival    | `.demo` source, default on first launch, 32 s bundled loop, zero permissions; plus first-run `WelcomeView` with System Settings deep links                                                                                                         |
| **B5** Apple Events       | Feature-flagged behind `MUSIC_APP_SOURCE`; the store build contains no `PlayerRemote`, no AppleScript, neither entitlement — and, since now-playing moved to distributed notifications, no longer loses the feature that motivated the entitlement |
| **B6** unused entitlement | `com.apple.security.assets.music.read-only` removed                                                                                                                                                                                                |

### App hardening and quality

- [x] `MACOSX_DEPLOYMENT_TARGET` 26.5 → **26.0** (`glassEffect` is a 26.0 API)
- [x] …then 26.0 → **15.0**, once `glassEffect` moved behind `chromeGlass`'s `#available` guard. Post-1.0.1: the App Store listing's minimum OS and the site's `RELEASE.requires` both need to follow the binary down to macOS 15
- [x] `SWIFT_VERSION` 5.0 → **6.0**; `nonisolated struct AudioSnapshot`
- [x] **Power** — MTKView pauses on occlusion/miniaturize; 30 fps when inactive or idle; full display rate (incl. 120 Hz ProMotion) only while audio flows
- [x] **Sleep** — `beginActivity(.idleDisplaySleepDisabled)` held only while audio flows
- [x] **Photosensitivity** — Reduce Motion honored; done CPU-side to preserve the 96-byte `VizUniforms` contract
- [x] **VoiceOver** — labels on all 14 icon-only buttons; chrome stops auto-hiding while VoiceOver runs
- [x] Help menu, security-scoped file bookmarks, `PrivacyInfo.xcprivacy`, `ITSAppUsesNonExemptEncryption`, `NSHumanReadableCopyright`, shared schemes
- [x] **Zero build warnings** in every configuration

### Tests

- [x] `SynesthiaTests` — Swift Testing, **19 tests over `AudioAnalyzer`, all passing**

Coverage: band mapping against an independently derived formula, sample-rate
dependence, bass/mid/treble separation, level normalization, spectral centroid,
beat and treble-transient detection, flux decay, `reset()`, and buffer sizes from
1 to 4096 samples. Three tests failed on first run and were corrected rather than
the code: they assumed ideal geometric band spacing, but `rebuildBandEdges`
forces each band to own a distinct FFT bin, which makes the bottom third
effectively linear at 23.4 Hz bins — a physical limit of a 2048-point FFT, not a
defect. A fourth was rewritten to drive the treble detector with broadband noise
rather than a sine, because a sine is not a cymbal. One test was found vacuous
(it compared a helper formula against itself) and replaced.

### Website

- [x] `/privacy` and `/support` — the two pages the App Store requires
- [x] Landing page rebuilt around real screenshots
- [x] Download channels independently switchable (`DIRECT_DOWNLOAD_AVAILABLE`, `APP_STORE_AVAILABLE`)
- [x] Deployed on Cloudflare Pages with git integration

### Verified as already correct

- Release archives are universal (`x86_64 arm64`) — asserted by the build script
- Hardened runtime on, App Sandbox on, `get-task-allow` stripped
- Genuine 1024×1024 icon rendition in the asset catalog

---

## 2. Decisions taken

| Question          | Decision                         | Consequence                                                                                                                   |
| ----------------- | -------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| B5 — Apple Events | **Feature-flag it**              | `Direct` configuration; store build sends no Apple Events at all — but keeps the now-playing badge, which needs no permission |
| B4 — demo audio   | **Synthesize and bundle a clip** | `scripts/make_demo_loop.py`; no licensing question                                                                            |
| Distribution      | **Both channels, direct first**  | Full notarization pipeline; direct shipped first                                                                              |
| Sparkle isolation | **Duplicate the app target**     | SPM attaches packages per-target, not per-configuration; one extra target to keep in sync                                     |
| Release hosting   | **R2 + Pages Functions**         | Publishing is an upload, not a site rebuild — which matters because notarization must finish before the feed can name the DMG |

**MusicKit cannot replace Apple Events on macOS.** `SystemMusicPlayer` is
unavailable on the platform and `ApplicationMusicPlayer` reports only what your
own app plays. B5 looked like a straight choice between shipping the entitlement
and cutting the feature.

**It wasn't, and the third option was better than either.** Media players
broadcast title, artist, album and play state as **distributed notifications**,
which cost no entitlement, no TCC prompt and no private API — and, contrary to
a widely repeated claim, the App Sandbox does not strip the `userInfo` payload
from notifications an app _receives_ (the rule constrains sandboxed _senders_;
verified on macOS 26.5 against an ad-hoc-signed sandboxed binary). So the store
build now shows the now-playing badge for both Music and Spotify while still
sending zero Apple Events. `MUSIC_APP_SOURCE` gates only transport control and
cover art, which is a much smaller thing to give up.

The lesson worth keeping: B5 was framed as a permissions problem for months
because the search stopped at the two mechanisms already known (MediaRemote,
dead since 15.4; Apple Events, entitlement-bound). Neither was the one the
players themselves volunteer. Whether to go back and ask review for the
exception anyway — to add transport to the store build — is assessed in
[the roadmap](roadmap.md#apple-events-in-the-mac-app-store-build); the current
answer is no, and later is a better time to ask than now.

---

## 3. Remaining blockers

### B2 — App Store distribution signing (**mostly closed**)

Direct-download signing is fully working. What is left is App Store only:

- [x] Register the App ID `com.jonjaques.Synesthia`
- [x] App distribution certificate (_3rd Party Mac Developer Application_)
- [x] Mac App Store provisioning profile (present, expires 2027-07-25)
- [x] Developer ID Application certificate
- [x] `xcrun notarytool store-credentials SYNESTHIA_NOTARY`
- [ ] **Mac Installer Distribution certificate** — signs the `.pkg`; the one thing still failing the export
- [ ] Create the App Store Connect record
- [ ] **Throwaway upload immediately** — flush out validation errors early

`make appstore` archives cleanly and passes all eight preflight assertions, then
stops at:

```
error: exportArchive No signing certificate "Mac Installer Distribution" found
error: exportArchive No profiles for 'com.jonjaques.Synesthia' were found
```

Note the second line may well clear itself once the certificate exists — a
profile for that App ID _is_ on this machine. Don't chase it until the installer
certificate is in place.

---

## 4. App Store Connect checklist

### External dependencies — done

- [x] Privacy Policy → `/privacy`; claims match `PrivacyInfo.xcprivacy`, and it discloses the website's Google Analytics separately from the app (which collects nothing)
- [x] Support page → `/support`

### Assets

- [x] Icon — correct in the binary
- [x] Screenshot tooling — `make screenshots`, driving the real shipping UI
- [x] Screenshots captured for the website (3 visualizers × windowed/fullscreen)
- [x] **Screenshots at an App Store size.** `make screenshots` now writes an `app-store/` copy of every shot beside the raw one: exactly 2880×1800 (`--appstore-size` picks any of Apple's four), no alpha channel — the window capture has one, from the rounded corners, and it is a rejection — and asserted as such per file. The window defaults to 1440×900 points so the windowed shot is 2880×1800 natively, with no rescaling. Music.app is advanced a track per visualizer so the set isn't one song eight times.
- [ ] **Choose and upload the set.** 4 visualizers × windowed/fullscreen is 8 files against a limit of 10, so it fits as-is — but pick deliberately, and prefer a run taken from the `Release` build so the badge shown is the one store users get.
- [ ] **App preview video — the high-leverage asset.** A static frame of a visualizer sells nothing. Up to 3, 15–30 s, 16:9 at 1080p or 4K.

### Metadata — drafted, length-checked

- [x] Subtitle, promotional text, description, keywords — all within limits
- [x] Category: Music; copyright, age rating, App Privacy answers
- [x] Review notes — lead with the zero-permission repro path, then explain why a music visualizer needs screen recording and that the video leg is 2×2 px and discarded
- [ ] **Price: undecided.** The site's structured data advertises free; if it ships paid, update `web/src/layouts/Base.astro`

All in `docs/app-store-metadata.md`; re-check with `make check-metadata`.

---

## 5. What needs a human

Ordered by what blocks the most.

1. **Mac Installer Distribution certificate** (§3 B2), then the ASC record and a
   throwaway upload. The only thing between here and a submission.
2. **Pick the screenshot set and shoot the preview video** (§4). `make screenshots
--configuration Release` produces conforming files; choosing which 8 to upload,
   and the video, are judgement calls.
3. **Look at and listen to the app.** Verified structurally, never by eye or ear:
   - the first-run welcome sheet's layout and wording
   - whether the demo track _sounds_ good, as opposed to measuring well
   - whether Reduce Motion actually looks calmer
   - whether VoiceOver actually reads the new labels
4. **Regression-test the Music path by hand** — Music.app running, `Direct`
   configuration. B6's outstanding follow-up.
5. **Install the shipped DMG on a second Mac** and take one update end to end,
   to watch Sparkle do it for real rather than by assertion.
6. **Flip `APP_STORE_AVAILABLE` to `true`** once, and only once, review passes.

---

## 6. Notable findings

Kept because each cost real time and each is the kind of thing that recurs. The
durable rules live in `CLAUDE.md`; this is the index.

- **Every `FilePlayer` launch crashed.** `SWIFT_DEFAULT_ACTOR_ISOLATION =
MainActor` makes an inline closure main-actor isolated; AVAudioEngine calls tap
  blocks on a realtime thread, so Swift 6's check trapped on the first buffer.
  The same defect sat in `scheduleFile`'s completion handler and would have
  killed the app at the first loop point. `Task { @MainActor … }` does not help —
  the trap precedes it. Fixed with `nonisolated` block factories.
- **`INFOPLIST_KEY_*` only accepts Apple's known keys.** `INFOPLIST_KEY_SUFeedURL`
  sat in the project doing nothing, silently. Third-party keys need a real
  `INFOPLIST_FILE` merged with the generated one.
- **Never pipe into `grep -q` under `set -o pipefail`.** `grep -q` exits on match,
  SIGPIPEs the producer, and the pipeline "fails". The `if producer | grep -q
LEAK` form fails _open_ — the `MUSIC_APP_SOURCE` leak assertion was silently
  passing on a binary that contained the string.
- **A notarized DMG is not a signed DMG.** `hdiutil` output is unsigned;
  Gatekeeper's primary-signature check reports `no usable signature` regardless of
  the stapled ticket. Sign before notarizing.
- **Staple the app before building the DMG.** Stapling it afterwards leaves the
  copy inside the image without a ticket — which is the copy users run, and the
  one Sparkle installs.
- **Two factual errors were caught before they reached the listing**: the site
  claimed macOS 26.5 (target is 26.0) and Apple silicon only (archives are
  universal; Tahoe is the last Intel release).

---

## 7. Deliberately deferred

- [ ] **English only.** Fine for v1; the string-catalog migration is noted in `CLAUDE.md`
- [ ] **Visualizer test coverage.** `AudioAnalyzer` is covered; the Metal visualizers are much harder to assert on
- [ ] **`RELEASE.size` is hand-maintained.** Only known after `make direct` prints it; `/download?json` reports it live if the site ever wants to read it

---

## 8. Verification evidence

Everything below was re-checked on 2026-07-25 against the shipped 1.0.

| Check                                             | Result                                                                                           |
| ------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| `Release` / `Direct` / `Debug` builds             | succeed, zero warnings                                                                           |
| `make test`                                       | 19/19 pass                                                                                       |
| Archive is universal                              | `x86_64 arm64`                                                                                   |
| `get-task-allow` in archive                       | absent                                                                                           |
| Apple Events entitlements in `Release`            | absent                                                                                           |
| AppleScript string in `Release` binary            | absent                                                                                           |
| **Sparkle in `Release`**                          | absent — framework, link and Info.plist keys                                                     |
| **Sparkle in `Direct`**                           | framework, `Installer.xpc`, EdDSA key, HTTPS feed, entitlements                                  |
| Nested Sparkle executables hardened               | `Installer.xpc`, `Downloader.xpc`, `Updater.app`, `Autoupdate`                                   |
| Notarization                                      | 3 submissions, all `Accepted`                                                                    |
| Gatekeeper — DMG                                  | `accepted, source=Notarized Developer ID`                                                        |
| Gatekeeper — app, and app inside the DMG          | `accepted, source=Notarized Developer ID`                                                        |
| Published DMG vs. notarized DMG                   | byte-identical (SHA-256)                                                                         |
| Appcast signature vs. published DMG               | verifies; a 1-byte change is rejected                                                            |
| App's `SUFeedURL` vs. live feed                   | match                                                                                            |
| Pages Functions                                   | `/appcast.xml`, `/download` (302 + `?json`), `/downloads/*` incl. 206/416/304, traversal blocked |
| `PrivacyInfo.xcprivacy`, `DemoLoop.m4a` in bundle | present                                                                                          |
| Metadata field lengths                            | all within limits                                                                                |

**Still not verified: anything visual or audible.** No pixel of the UI and no
second of the demo track has been assessed by a human in this workstream — see
§5.3.
