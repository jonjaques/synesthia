# Distribution

Synesthia ships two different binaries, from **two targets over three build
configurations**. Understanding that split is the key to everything else here.

| | App Store | Direct download | Debug |
|---|---|---|---|
| Target | `Synesthia` | `Synesthia Direct` | either |
| Scheme | `Synesthia` | `Synesthia Direct` | both |
| Configuration | `Release` | `Direct` | `Debug` |
| Goes to | Mac App Store | synesthia.app | your Mac |
| `MUSIC_APP_SOURCE` | **off** | on | on |
| Music.app source in the UI | absent | present | present |
| Apple Events code compiled in | **none** | yes | yes |
| Sparkle linked | **never** | yes | Direct target only |
| Entitlements file | `Synesthia.entitlements` | `Synesthia-Direct.entitlements` | `Synesthia-Direct.entitlements` |
| `automation.apple-events` | **no** | yes | yes |
| `temporary-exception.apple-events` | **no** | yes | yes |
| `network.client` | **no** | yes (Sparkle) | yes |
| `Info.plist` file | none (generated) | `Synesthia-Direct-Info.plist` + generated | same |
| Build script | `scripts/build-appstore.sh` | `scripts/build-direct.sh` | Xcode |

Two separate reasons drive the split, and they cut the same way.

**Apple Events.** `com.apple.security.temporary-exception.apple-events` →
`com.apple.Music` is the single largest Mac App Store review risk this project
has; Music.app publishes no scripting-targets group, so that exception is the
only way to drive it. Outside the store it carries no risk at all. Rather than
choose, the App Store build simply doesn't contain the feature — `#if
MUSIC_APP_SOURCE` removes the source case, the `MusicController` class, and
every Apple Event with it.

**Sparkle.** Mac App Store apps must not ship their own updater — the store
does that job, and bundling one (along with an XPC service whose whole purpose
is installing code) invites rejection under guideline 2.4.5. Sparkle is
therefore linked by the `Synesthia Direct` target and nothing else.

Users of the App Store build lose the now-playing badge, the transport buttons,
and self-updating — not the ability to visualize Apple Music. "System audio"
captures Music.app perfectly well.

Both build scripts assert all of this against the *built archive* and refuse to
continue if any of it leaks in either direction.

---

## Why two targets rather than one

Swift Package Manager attaches a package to a **target**, not a configuration.
There is no per-configuration switch for an SPM product, so a single target
linking Sparkle would link it into `Release` too. Duplicating the target is the
supported way out, and it is what the project does.

The cost is one wart worth knowing about: **both targets produce
`Synesthia.app`**, so building both in the *same* configuration means the second
overwrites the first in `Build/Products/<config>/`. In practice they don't
collide, because each scheme builds one target and they archive from different
configurations (`Release` vs `Direct`). If you build `make build` and `make
build-direct` back to back at `CONFIGURATION=Debug`, though, the app on disk is
whichever ran last. `make app-path` has the same ambiguity.

Anything added to one target's build settings must be added to the other's.
`Synesthia/` is a `PBXFileSystemSynchronizedRootGroup` referenced by both
targets, so *source files* need no such care — a new `.swift` file anywhere
under `Synesthia/` compiles into both automatically.

---

## Mac App Store

```bash
make appstore          # archive, verify, export
make appstore-upload   # …and upload
```

The script archives the `Synesthia` target in `Release` and then asserts,
against the actual archive:

- the binary is universal (`arm64` + `x86_64` — macOS 26 Tahoe is the last
  release supporting Intel Macs)
- `com.apple.security.get-task-allow` did not survive
- no `apple-events` entitlement is present
- no `tell application "Music"` string is compiled in
- **no Sparkle** — not the framework, not the link, not `SUFeedURL`
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
make direct-fast   # build + sign + DMG, no notarization
make direct        # …plus notarize and staple
```

Archives the `Synesthia Direct` target in `Direct`, exports with Developer ID,
verifies the signature and hardened runtime, checks the Sparkle wiring (see
below), builds a compressed DMG with an `/Applications` symlink, submits it to
Apple's notary service, staples the ticket to **both** the app and the DMG, then
confirms Gatekeeper accepts it.

---

## What you need from Apple

Everything below is portal work. As of 2026-07-25 this machine has **Apple
Development** and **3rd Party Mac Developer Application**; the missing piece for
the direct download is **Developer ID Application**.

### 1. Register the App ID

developer.apple.com → Certificates, Identifiers & Profiles → Identifiers → **+**
→ App IDs → App → Bundle ID **explicit**, `com.jonjaques.Synesthia`.

No capabilities need enabling. App Sandbox and the temporary exceptions are not
capabilities — they are entitlements you assert at signing time, which is why
the direct build needs no provisioning profile at all.

### 2. Developer ID Application certificate — the actual blocker

This is the certificate that signs software distributed outside the store, and
it is the only one you cannot create as a team member: **you must be the Account
Holder.** Two ways:

- **Xcode** (easier): Xcode → Settings → Accounts → select the team → *Manage
  Certificates…* → **+** → **Developer ID Application**.
- **Portal**: Certificates → **+** → Developer ID Application, upload a CSR from
  Keychain Access → Certificate Assistant → *Request a Certificate From a
  Certificate Authority* (choose "Saved to disk").

Two things to know before you click:

- You get a **limited number** of Developer ID Application certificates per
  account (currently five), and they cannot be deleted, only revoked. Don't
  generate one per machine — generate one, then export it as a `.p12` and carry
  that to any other machine.
- **Back the `.p12` up**, with its private key, somewhere that is not this
  laptop. Losing it doesn't strand existing users the way losing the Sparkle key
  does, but it does burn one of your five slots.

Confirm it landed:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

You also need the **Developer ID Certification Authority (G2)** intermediate in
your keychain. Xcode installs it; if signing complains about an untrusted
issuer, fetch it from https://www.apple.com/certificateauthority/.

### 3. Notarization credentials

Notarization is a separate service from signing and needs its own credentials.
Use an **app-specific password**, not your Apple password:

1. account.apple.com → Sign-In and Security → App-Specific Passwords → generate.
2. Store it in the keychain under the profile name the script expects:

```bash
xcrun notarytool store-credentials "SYNESTHIA_NOTARY" \
    --apple-id you@example.com --team-id 43Z6G73JW8 \
    --password <app-specific-password>
```

Verify before you need it:

```bash
xcrun notarytool history --keychain-profile SYNESTHIA_NOTARY
```

### 4. For the App Store side as well

- **Apple Distribution** certificate and a **Mac App Store** provisioning
  profile for `com.jonjaques.Synesthia`.
- **Mac Installer Distribution** certificate (signs the `.pkg`). Note this is
  *not* the "3rd Party Mac Developer Application" certificate already present —
  that one signs the app inside the package; the installer one signs the package
  itself, and `exportArchive` needs both.
- An App Store Connect app record.

Do a throwaway upload as soon as these exist, to flush out validation errors
while there is still time to react to them.

---

## Sparkle

Sparkle 2.9.4, linked to `Synesthia Direct` via SPM. `Synesthia/Updater.swift`
is guarded on `#if canImport(Sparkle)`, so the same source file compiles to an
empty `EmptyView()` in the App Store target and to a real updater in the direct
one, with no `#if` at the call site in `SynesthiaApp.swift`.

### One-time setup

```bash
make sparkle-keys
```

This creates an ed25519 keypair, stores the private half in your login keychain,
and prints the public half. Paste that public key into
**`Synesthia-Direct-Info.plist`** as `SUPublicEDKey`, replacing
`REPLACE_WITH_SPARKLE_PUBLIC_KEY`. `build-direct.sh` refuses to build while the
placeholder is still there.

**Back the private key up before you ship anything.** It is the only thing that
can sign an update your users' copies will accept. If it is lost, every
installed copy is stranded on its current version permanently, and the only
remedy is asking people to re-download by hand:

```bash
"$(./scripts/sparkle-keys.sh --path)/generate_keys" -x sparkle-private-key.txt
# put that file somewhere safe, then delete the local copy
```

### Why there is an Info.plist file

`Synesthia-Direct-Info.plist` exists for one reason: **`INFOPLIST_KEY_*` only
accepts Apple's known key list.** Arbitrary suffixes are dropped silently, with
no warning and no build failure — which is why `INFOPLIST_KEY_SUFeedURL` sat in
this project's build settings doing nothing at all. Setting both `INFOPLIST_FILE`
and `GENERATE_INFOPLIST_FILE = YES` is the supported way out: the file is the
base, and the generated keys are merged on top. Only the three Sparkle keys live
there; everything else is still a build setting.

### Sandboxing

A sandboxed app cannot install its own update, so Sparkle ships XPC services
that do it from outside the sandbox. Three things have to agree:

| | Where |
|---|---|
| `SUEnableInstallerLauncherService` = true | `Synesthia-Direct-Info.plist` |
| `$(PRODUCT_BUNDLE_IDENTIFIER)-spks` / `-spki` mach-lookup exceptions | `Synesthia-Direct.entitlements` |
| `Installer.xpc` embedded and hardened | inside `Sparkle.framework`, automatic |

The app also holds `com.apple.security.network.client`, so Sparkle's optional
`Downloader.xpc` is **not** enabled — that service exists for apps that lack the
network entitlement, and Sparkle warns against having both.

If these disagree, the failure is silent in the worst way: the update downloads
successfully and then nothing happens. `build-direct.sh` checks all of it.

---

## Hosting: R2 + Pages Functions

The DMGs and the appcast are **not in git** and the website is **not rebuilt to
publish a release**. They live in an R2 bucket, and three Pages Functions in
`web/functions/` serve them:

| Route | Serves | Cache |
|---|---|---|
| `/appcast.xml` | `appcast.xml` | 5 minutes |
| `/download` | 302 → the current DMG, from `latest.json` | 5 minutes |
| `/downloads/Synesthia-<v>.dmg` | `downloads/<name>` | immutable, 1 year |

`/download?json` returns the version, build, filename and size as JSON.

This shape is deliberate:

- **The appcast has to be publishable without a deploy.** A DMG must be
  notarized *before* the feed can mention it, and notarization is an
  unpredictable wait. Coupling that to a site build means either a stale feed or
  a rebuild at an awkward moment.
- **`/download` is a redirect, not a proxy**, so the bytes are served by the
  immutable route and cached hard at the edge. A link printed anywhere keeps
  working across releases.
- **Everything is on the apex domain**, so Sparkle's feed and its enclosure URLs
  share an origin — no CORS, no cross-host redirect surprises.
- Range requests are supported on `/downloads/*`, for resuming an interrupted
  browser download. Sparkle doesn't need it; hotel Wi-Fi does.

Security rests on the EdDSA signature, not on the transport: every appcast entry
is signed with the key only you hold, and Sparkle checks it against the
`SUPublicEDKey` in the bundle. Someone who took over the bucket still could not
ship code to an installed copy.

### Cloudflare setup (one-time)

```bash
npx wrangler r2 bucket create synesthia-releases
```

Then, in the Cloudflare dashboard, attach the binding to the **Pages** project —
Workers & Pages → your project → Settings → Bindings → R2 bucket, variable name
`RELEASES`, bucket `synesthia-releases`. Add it for **both** Production and
Preview.

Two things to check before the first deploy:

1. **`name` in `web/wrangler.jsonc` must match the existing Pages project.**
   Confirm with `npx wrangler pages project list`. If it doesn't match, the
   git-integrated build deploys to a project that isn't the one serving
   synesthia.app.
2. **Once a Pages project has a Wrangler config file, that file becomes the
   source of truth** and the same fields go read-only in the dashboard. Bindings
   added by hand there stop being applied.

The bucket stays private. It is reached only through the Functions' binding —
there is no public r2.dev URL and no custom domain on it.

### Local testing

```bash
make web-build
cd web && npx wrangler pages dev ./dist
# seed the local (simulated) bucket:
npx wrangler r2 object put synesthia-releases/appcast.xml --file … --local
```

`make web-typecheck` checks the Functions against the Workers runtime.
`web/tsconfig.functions.json` exists because the DOM lib and the Workers globals
disagree — with DOM loaded, `caches.default` doesn't type-check.

---

## Shipping a release, end to end

```bash
make direct                       # archive, sign, notarize, staple, DMG
make appcast                      # fetch live feed, add the new version, sign
make publish-dry-run              # see exactly what would be uploaded
make publish-release              # DMGs first, then latest.json, then appcast
```

Order matters and the script enforces it. The appcast is the *announcement*: the
moment it lists a version, installed copies start fetching that URL, so the DMG
has to be in the bucket first.

`make appcast` pulls the published `appcast.xml` down before regenerating.
`generate_appcast` only ever *adds* to a feed it finds in the archives
directory — regenerating from a directory holding only the newest DMG would
silently produce a one-item feed and drop the entries users are updating *from*.
If that fetch fails, the script says so loudly rather than quietly truncating.

Sparkle prunes older versions out of the feed and moves their files to
`build/releases/old_updates/`. Delta updates are only generated for versions
whose archives are still present locally; at ~4 MB per full download that is a
deliberate trade rather than an oversight.

### Before the first release

- [ ] Developer ID Application certificate exists (§2 above)
- [ ] `xcrun notarytool history --keychain-profile SYNESTHIA_NOTARY` works
- [ ] `make sparkle-keys` run, public key pasted into `Synesthia-Direct-Info.plist`
- [ ] private Sparkle key exported and backed up off this machine
- [ ] R2 bucket created and bound to the Pages project as `RELEASES`
- [ ] `name` in `web/wrangler.jsonc` matches the real Pages project
- [ ] `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` bumped on **both** targets
