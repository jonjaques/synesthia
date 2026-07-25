# Distribution

Synesthia ships two different binaries from one target, separated by build
configuration. Understanding that split is the key to everything else here.

| | `Release` | `Direct` | `Debug` |
|---|---|---|---|
| Goes to | Mac App Store | synesthia.app download | your Mac |
| `MUSIC_APP_SOURCE` | **off** | on | on |
| Music.app source in the UI | absent | present | present |
| Apple Events code compiled in | **none** | yes | yes |
| Entitlements file | `Synesthia.entitlements` | `Synesthia-Direct.entitlements` | `Synesthia-Direct.entitlements` |
| `automation.apple-events` | **no** | yes | yes |
| `temporary-exception.apple-events` | **no** | yes | yes |
| `NSAppleEventsUsageDescription` | absent | present | present |
| Sparkle updater | never | yes (once linked) | yes (once linked) |
| Build script | `scripts/build-appstore.sh` | `scripts/build-direct.sh` | Xcode |

The reason for the split is `com.apple.security.temporary-exception.apple-events`
→ `com.apple.Music`. Music.app publishes no scripting-targets group, so that
exception is the only way to drive it, and it is the single largest Mac App
Store review risk this project has. Outside the store it carries no risk at
all. Rather than choose, the App Store build simply doesn't contain the
feature — `#if MUSIC_APP_SOURCE` removes the source case, the `MusicController`
class, and every Apple Event with it. `scripts/build-appstore.sh` asserts all
of this against the built archive and refuses to continue if any of it leaks.

Users of the App Store build lose the now-playing badge and transport buttons,
not the ability to visualize Apple Music — "System audio" captures Music.app
perfectly well.

---

## Mac App Store

```bash
./scripts/build-appstore.sh            # archive, verify, export
./scripts/build-appstore.sh --upload   # …and upload
```

The script archives the `Release` configuration and then asserts, against the
actual archive:

- the binary is universal (`arm64` + `x86_64` — macOS 26 Tahoe is the last
  release supporting Intel Macs)
- `com.apple.security.get-task-allow` did not survive
- no `apple-events` entitlement is present
- no `tell application "Music"` string is compiled in
- `PrivacyInfo.xcprivacy` is in `Contents/Resources`
- `DemoLoop.m4a` is in `Contents/Resources` — without it the zero-permission
  path is dead and a reviewer sees a black canvas
- `ITSAppUsesNonExemptEncryption` is set, so uploads don't prompt

Uploading needs an App Store Connect API key:

```bash
export ASC_KEY_ID=XXXXXXXXXX
export ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
# with the .p8 in ~/.appstoreconnect/private_keys/
```

## Direct download

```bash
./scripts/build-direct.sh --skip-notarize   # build + sign + DMG
./scripts/build-direct.sh                   # …plus notarize and staple
```

Archives `Direct`, exports with Developer ID, verifies the signature and
hardened runtime, builds a compressed DMG with an `/Applications` symlink,
submits it to Apple's notary service, staples the ticket to **both** the app
and the DMG, then confirms Gatekeeper accepts it.

One-time credential setup:

```bash
xcrun notarytool store-credentials "SYNESTHIA_NOTARY" \
    --apple-id you@example.com --team-id 43Z6G73JW8 \
    --password <app-specific-password>
```

App-specific passwords come from account.apple.com → Sign-In and Security. A
normal Apple password will not work.

---

## Blocked: signing assets do not exist yet

As of 2026-07-25 the only certificate on this machine is **Apple Development**.
Both scripts archive successfully and then stop at export:

```
error: exportArchive No signing certificate "Mac Installer Distribution" found
error: exportArchive No profiles for 'com.jonjaques.Synesthia' were found
error: exportArchive No signing certificate "Developer ID Application" found
```

This is launch-plan blocker **B2**, and it can only be cleared in the Apple
Developer portal:

1. Register the App ID `com.jonjaques.Synesthia`.
2. Create an **Apple Distribution** certificate and a **Mac App Store**
   provisioning profile for it.
3. Create a **Developer ID Application** certificate (direct download) and a
   **Mac Installer Distribution** certificate (App Store `.pkg`).
4. Do a throwaway upload immediately, to flush out validation errors while
   there is still time to react to them.

---

## Sparkle

Sparkle is **written but not yet linked**. `Synesthia/Updater.swift` is guarded
on `#if canImport(Sparkle)`, so today it compiles to nothing and the Help menu
has no "Check for Updates…" item. It lights up the moment the package is added.

This last step is deliberately manual, because adding Sparkle via Swift Package
Manager attaches it to *every* configuration — including the App Store one.
Mac App Store apps must not bundle their own updater, so Sparkle has to be kept
out of `Release`. There is no per-configuration switch for an SPM product, so
this needs a decision rather than a script:

- **Recommended:** duplicate the app target (Xcode → right-click the target →
  Duplicate), link Sparkle to the copy only, and build the direct download from
  it. Costs one extra target to keep in sync.
- **Alternative:** link Sparkle to the single target and accept that the App
  Store build embeds an unused updater framework. Simpler, and a rejection risk
  that is not worth taking.

Once linked:

1. Generate the signing key — `"$SPARKLE_BIN/generate_keys"`. The private half
   goes into your login keychain; **back it up**. Losing it means never being
   able to update existing installs again.
2. Put the printed public key in the `Direct` configuration as
   `INFOPLIST_KEY_SUPublicEDKey`. (`INFOPLIST_KEY_SUFeedURL` is already set to
   `https://synesthia.app/appcast.xml`, on `Direct` only.)
3. Publish updates with `./scripts/make-appcast.sh`, which verifies every DMG
   is stapled before writing `web/public/appcast.xml` and
   `web/public/downloads/`.

Sparkle in a sandboxed app additionally needs its installer XPC services
bundled and the matching temporary-exception entitlements — see Sparkle's
sandboxing guide before the first release.
