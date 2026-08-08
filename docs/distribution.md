# Distribution

Synesthia ships two different binaries, from **two targets over three build
configurations**. Understanding that split is the key to everything else here.

|                                    | App Store                   | Direct download                           | Debug                           |
| ---------------------------------- | --------------------------- | ----------------------------------------- | ------------------------------- |
| Target                             | `Synesthia`                 | `Synesthia Direct`                        | either                          |
| Scheme                             | `Synesthia`                 | `Synesthia Direct`                        | both                            |
| Configuration                      | `Release`                   | `Direct`                                  | `Debug`                         |
| Goes to                            | Mac App Store               | synesthia.app                             | your Mac                        |
| Bundle ID                          | `com.jonjaques.Synesthia`   | `com.jonjaques.Synesthia`                 | **`…Synesthia.debug`**          |
| App icon                           | `Icon.icon`                 | `Icon.icon`                               | **`IconDebug.icon`** (orange)   |
| `MUSIC_APP_SOURCE`                 | **off**                     | on                                        | on                              |
| Now-playing badge                  | yes (no permission)         | yes                                       | yes                             |
| Transport control + cover art      | absent                      | opt-in                                    | opt-in                          |
| Apple Events code compiled in      | **none**                    | yes                                       | yes                             |
| Sparkle linked                     | **never**                   | yes                                       | Direct target only              |
| Entitlements file                  | `Synesthia.entitlements`    | `Synesthia-Direct.entitlements`           | `Synesthia-Direct.entitlements` |
| `automation.apple-events`          | **no**                      | yes                                       | yes                             |
| `temporary-exception.apple-events` | **no**                      | yes                                       | yes                             |
| `network.client`                   | **no**                      | yes (Sparkle)                             | yes                             |
| `Info.plist` file                  | none (generated)            | `Synesthia-Direct-Info.plist` + generated | same                            |
| Build script                       | `scripts/build-appstore.sh` | `scripts/build-direct.sh`                 | Xcode                           |

Two separate reasons drive the split, and they cut the same way.

**Apple Events.** `com.apple.security.temporary-exception.apple-events` →
`com.apple.Music` / `com.spotify.client` is the single largest Mac App Store
review risk this project has; neither app publishes a scripting-targets group,
so that exception is the only way to drive them. Outside the store it carries
no risk at all. Rather than choose, the App Store build simply doesn't contain
the feature — `#if MUSIC_APP_SOURCE` removes `PlayerRemote` and every Apple
Event with it.

What that costs is much less than it used to. Knowing _what is playing_ needs
no permission at all — players broadcast it as distributed notifications — so
the flag now gates only transport control and cover art, and the store build
shows the same now-playing badge as the direct one. See
[macOS integration](macos-integration.md#now-playing-three-layers) for the
three layers, and [the roadmap](roadmap.md#apple-events-in-the-mac-app-store-build)
for why asking review for the exception later is a better bet than asking now.

**Sparkle.** Mac App Store apps must not ship their own updater — the store
does that job, and bundling one (along with an XPC service whose whole purpose
is installing code) invites rejection under guideline 2.4.5. Sparkle is
therefore linked by the `Synesthia Direct` target and nothing else.

Users of the App Store build lose the transport buttons, real cover art, and
self-updating. They keep the now-playing badge — title, artist, album, play
state, for Music and Spotify alike — and the ability to visualize anything the
Mac plays.

Both build scripts assert all of this against the _built archive_ and refuse to
continue if any of it leaks in either direction.

---

## Why two targets rather than one

Swift Package Manager attaches a package to a **target**, not a configuration.
There is no per-configuration switch for an SPM product, so a single target
linking Sparkle would link it into `Release` too. Duplicating the target is the
supported way out, and it is what the project does.

The cost is one wart worth knowing about: **both targets produce
`Synesthia.app`**, so building both in the _same_ configuration means the second
overwrites the first in `Build/Products/<config>/`. In practice they don't
collide, because each scheme builds one target and they archive from different
configurations (`Release` vs `Direct`). If you build `make build` and `make
build-direct` back to back at `CONFIGURATION=Debug`, though, the app on disk is
whichever ran last. `make app-path` has the same ambiguity.

Anything added to one target's build settings must be added to the other's.
`Synesthia/` is a `PBXFileSystemSynchronizedRootGroup` referenced by both
targets, so _source files_ need no such care — a new `.swift` file anywhere
under `Synesthia/` compiles into both automatically.

---

## Why Debug has its own bundle identifier

**`Debug` builds are `com.jonjaques.Synesthia.debug`. `Release` and `Direct`
are both `com.jonjaques.Synesthia`.**

TCC identifies an app by **bundle identifier plus code-signing identity**, and
the three configurations sign with three different certificates — Apple
Development for `Debug`, Developer ID for `Direct`, Mac App Store for
`Release`. Sharing one bundle ID across them means one TCC record that every
build fights over: granting Screen & System Audio Recording to a locally built
app and then launching a shipping copy (or the reverse) leaves the grant
pointing at the wrong binary, and the app that lost is denied with no prompt
and no error — the toggle in System Settings simply doesn't apply to it. It
looks exactly like a capture bug in the app.

Suffixing `Debug` splits the record. The development build gets its own row in
each System Settings privacy pane, its own Automation grant, and — because the
sandbox container is named after the bundle ID — its own
`~/Library/Containers/com.jonjaques.Synesthia.debug`, so dev preferences
(`hasSeenWelcome`, the chosen visualizer, the file bookmark) no longer bleed
into an installed release copy. Authorize each one once; they stay
independent.

Consequences worth knowing:

- **A `Debug` build needs its own permission grants.** The first system-audio
  capture after this change prompts again. That is the point, not a
  regression — and it applies to `make screenshots`, which builds `Debug` by
  default (pass `--configuration Direct` to shoot the shipping build).
- **Signing still works automatically.** Nothing in the entitlements requires
  an explicit App ID, so Xcode provisions `…Synesthia.debug` for development
  on its own.
- **Sparkle follows along.** Its mach-lookup exceptions are written
  `$(PRODUCT_BUNDLE_IDENTIFIER)-spks` / `-spki` and expand at build time, so
  the XPC service names track the suffixed ID. Never hardcode them.
- **`Release` and `Direct` deliberately still match.** They are the same
  product on two channels; changing `Direct`'s ID would break Sparkle updates
  for everyone already running it. The cost is that testing those two against
  each other on one Mac has the collision described above — install one at a
  time.

**The icon follows the same split.** `Synesthia/IconDebug.icon` is a copy of
`Icon.icon` with one value changed — the `automatic-gradient` fill, indigo →
orange — so a development build is unmistakable in the Dock and in ⌘-Tab.
`ASSETCATALOG_COMPILER_APPICON_NAME` selects it per configuration
(`IconDebug` in `Debug`, `Icon` elsewhere), and the four non-`Debug` app
configurations carry `EXCLUDED_SOURCE_FILE_NAMES = "IconDebug.icon"` so the
extra ~660 KB never reaches a shipping bundle. Both `.icon` files are picked up
by the synchronized group automatically; to recolor, edit `fill` in
`IconDebug.icon/icon.json` and nothing else.

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
verifies the signature, hardened runtime and Sparkle wiring, then:

1. notarizes the **app** and staples its ticket
2. builds a compressed DMG with an `/Applications` symlink, from the now-stapled app
3. **signs the DMG** with the same Developer ID identity
4. notarizes the **DMG** and staples its ticket
5. asserts Gatekeeper accepts both (`--type open` for the image, `--type exec`
   for the app)

Two non-obvious things are load-bearing in that order, and both produced real
failures before they were fixed:

**`hdiutil` produces an unsigned disk image, and notarizing it is not a
substitute for signing it.** A stapled but unsigned DMG fails
`spctl --assess --context context:primary-signature` with
`source=no usable signature` — Gatekeeper's primary-signature path looks for a
signature and there isn't one. Signing it changes the reason to
`Unnotarized Developer ID` and then, once notarized, to `Notarized Developer ID`.
Sign _before_ notarizing: signing rewrites the file, which would invalidate a
ticket already stapled to it.

**The app has to be notarized and stapled before the DMG is built**, because the
DMG is made from a copy. Stapling the app afterwards leaves the copy inside the
DMG without a ticket, so the app the user actually drags to `/Applications` can
only be validated online — and Sparkle, which extracts that app out of the DMG
and installs it, inherits the same problem. This is why there are two trips to
the notary service rather than one; they are separate files with separate
hashes and each needs its own submission.

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

- **Xcode** (easier): Xcode → Settings → Accounts → select the team → _Manage
  Certificates…_ → **+** → **Developer ID Application**.
- **Portal**: Certificates → **+** → Developer ID Application, upload a CSR from
  Keychain Access → Certificate Assistant → _Request a Certificate From a
  Certificate Authority_ (choose "Saved to disk").

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
  _not_ the "3rd Party Mac Developer Application" certificate already present —
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

|                                                                      | Where                                 |
| -------------------------------------------------------------------- | ------------------------------------- |
| `SUEnableInstallerLauncherService` = true                            | `Synesthia-Direct-Info.plist`         |
| `$(PRODUCT_BUNDLE_IDENTIFIER)-spks` / `-spki` mach-lookup exceptions | `Synesthia-Direct.entitlements`       |
| `Installer.xpc` embedded and hardened                                | inside `Sparkle.framework`, automatic |

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

| Route                          | Serves                                    | Cache             |
| ------------------------------ | ----------------------------------------- | ----------------- |
| `/appcast.xml`                 | `appcast.xml`                             | 5 minutes         |
| `/download`                    | 302 → the current DMG, from `latest.json` | 5 minutes         |
| `/downloads/Synesthia-<v>.dmg` | `downloads/<name>`                        | immutable, 1 year |

`/download?json` returns the version, build, filename and size as JSON.

This shape is deliberate:

- **The appcast has to be publishable without a deploy.** A DMG must be
  notarized _before_ the feed can mention it, and notarization is an
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

### Cloudflare setup (one-time — done 2026-07-25)

```bash
npx wrangler r2 bucket create synesthia-releases
```

**That is the whole setup. Do not add the binding in the dashboard.** Because
`web/wrangler.jsonc` exists, it is the source of truth for the Pages project and
those fields are read-only in the dashboard; the `RELEASES` binding is applied
from the config file's `env.production` / `env.preview` blocks on every build.

This is not a subtle distinction — it is how the first deploy of the Functions
failed:

```
Error: Failed to publish your Function. Got error: R2 bucket
'synesthia-releases' not found.
```

The binding was already being applied _from the config file_; the bucket just
didn't exist yet. A dashboard binding would not have helped, and adding one now
would be ignored.

Verify the wiring at any time with:

```bash
npx wrangler pages project list                  # `name` must match wrangler.jsonc
npx wrangler pages download config synesthia     # writes wrangler.toml — DELETE IT
```

Beware that second command: it writes a `wrangler.toml` into `web/`, and having
both a `.toml` and a `.jsonc` there is an error. Read it, then delete it.

The bucket stays private. It is reached only through the Functions' binding —
there is no public r2.dev URL and no custom domain on it. Nothing needs a secret
or an environment variable: an R2 binding is a capability handed to the Worker,
not a credential it presents.

### Which download the site offers

Two independent switches in `web/src/consts.ts`, because the two channels go
live at different times and either can be the only one available:

|                             | Current     | Turn on when                                                     |
| --------------------------- | ----------- | ---------------------------------------------------------------- |
| `DIRECT_DOWNLOAD_AVAILABLE` | **`true`**  | —                                                                |
| `APP_STORE_AVAILABLE`       | **`false`** | the app passes review and `APP_STORE_URL` is a real product page |

`DownloadOptions.astro` reads both and renders whichever are on — the header
takes the primary one, the hero and the closing call to action take all of them.
When both are on the App Store is the filled button and the direct download the
outlined one. Two pieces of copy follow the same flags: the closing heading
("Free on the Mac App Store." vs "Free for your Mac.") and the Sources note that
contrasts the two builds, which reads as a broken promise when only one exists.

All four combinations render, including neither-enabled, which produces a page
with no download button — the honest state before either channel exists.

**`/download` answers 503 until `make publish-release` has put a DMG and a
`latest.json` in the bucket.** The buttons are live now regardless, by choice;
the 503 carries a plain-text explanation. Nothing else needs changing when the
first release lands — that is the point of serving the artifacts from R2.

### Local testing

```bash
cd web && npm run build
npx wrangler pages dev ./dist
# seed the local (simulated) bucket:
npx wrangler r2 object put synesthia-releases/appcast.xml --file … --local
```

`npm run typecheck` (in `web/`) checks the Functions against the Workers runtime.
`web/tsconfig.functions.json` exists because the DOM lib and the Workers globals
disagree — with DOM loaded, `caches.default` doesn't type-check.

---

## Versioning

Two settings, duplicated across every target × configuration — **nine copies of
each** — in `Synesthia.xcodeproj/project.pbxproj`:

| Build setting             | Info.plist key               | What it does                                                                 |
| ------------------------- | ---------------------------- | ---------------------------------------------------------------------------- |
| `CURRENT_PROJECT_VERSION` | `CFBundleVersion`            | the build number; what Sparkle (`sparkle:version`) and the App Store compare |
| `MARKETING_VERSION`       | `CFBundleShortVersionString` | the display version; also **names the DMG**                                  |

There is no `Info.plist` to edit, and `agvtool` cannot help — it needs
`VERSIONING_SYSTEM = apple-generic`, which this project does not set. Editing by
hand in Xcode only touches the selected target, which is how `Synesthia Direct`
(the one that actually ships) ends up on a stale number.

```bash
make bump                 # patch: 1.0 -> 1.0.1
make bump BUMP=minor      #        1.0.1 -> 1.1
make bump BUMP=major      #        1.1 -> 2.0
make bump BUMP=2.5        # explicit
make bump ARGS=--dry-run  # preview
```

The build number is always incremented by one, whatever the level. A trailing
`.0` is dropped, so a minor bump renders `1.1`, not `1.1.0`. The script refuses
to run if the nine copies have drifted apart, and updates `RELEASE.version` in
`web/src/consts.ts` too. `RELEASE.size` is _not_ updated — the DMG's size is
only known after `make direct`.

`make bump` is the whole cut, not just the numbers:

1. **Preflight.** The worktree must be clean and HEAD must be on a branch (not
   `main`, not detached). A dirty tree would sweep unrelated edits into the
   release commit; a detached HEAD would leave the release reachable only from
   the tag. `--allow-dirty` and `--allow-main` override, `--dry-run` stops
   before anything is written.
2. **Release notes**, drafted by Claude Code from `<base>..HEAD` — the previous
   `v*` tag if there is one, otherwise the fork point from `main`; `--since`
   overrides. The draft is printed and the script waits: `a` accepts, `e` opens
   `$EDITOR`, `r` redrafts, `q` aborts. `--notes <file>` supplies your own and
   `--no-notes` skips the step. If `claude` isn't on `PATH` you get a stub built
   from the commit log instead.
3. **Confirmation.** Everything above happens before a single file changes; the
   script then lists what it is about to write and asks. `--yes` skips the
   prompts (and is _required_ when stdin isn't a terminal — it will not write
   unattended by accident).
4. **Write, verify, commit, tag.** `project.pbxproj`, `VERSION`,
   `web/src/consts.ts`, `docs/releases/<version>.md`; then one commit staging
   only those paths and an annotated `v<version>` tag whose message is the
   notes. The tag is local until `git push --follow-tags`.

`VERSION` at the repo root is a one-line mirror — `1.2 (5)` — so the current
version is readable without opening Xcode or grepping a 2000-line pbxproj
(`make version`). Nothing builds from it; the bump script rewrites it and then
asserts it agrees with `project.pbxproj`, which is what keeps it honest.

### Release notes and the appcast

Notes live in `docs/releases/<version>.md`, one file per release, in git.
`make appcast` renders each one into `build/releases/Synesthia-<version>.html`
(`scripts/release-notes.py`) and `generate_appcast` inlines that file into the
item's `<description>` as CDATA — Sparkle matches release-note files to archives
by basename.

Markdown would seem simpler, since `generate_appcast` accepts `.md` too, but it
is **not embedded**: it becomes a `<sparkle:releaseNotesLink>`, which means a
second artifact uploaded per release and a Pages Function that serves something
other than a `.dmg` (`isSafeDmgName` rejects everything else). Embedding keeps a
release a single upload. There is no markdown library in the toolchain and no
pandoc, so `release-notes.py` converts the subset the notes use and escapes
anything else rather than mangling it.

One sharp edge: `generate_appcast` only writes a description for items it
**adds**. An item already in the feed is left exactly as it was, so notes
written _after_ a version's first `make appcast` are silently ignored. The
script checks the newest item afterwards and says so; the fix is to delete that
`<item>` from `build/releases/appcast.xml` and regenerate.

### Always bump the marketing version, not just the build

`build-direct.sh` names the DMG `Synesthia-<MARKETING_VERSION>.dmg`, so two
releases sharing a marketing version collide on one filename in R2. Left
unchecked that is silent corruption: `make appcast` would sign the _new_ bytes
while the bucket kept serving the _old_ ones, and every client would fail EdDSA
verification and simply never update.

`publish-release.sh` compares SHA-256 against the published object and **hard
fails** rather than skipping when they differ. Skipping on filename alone is
what would have hidden it.

## Shipping a release, end to end

```bash
git switch -c release/1.3.0       # bump-version.sh refuses to run on main
make bump BUMP=minor              # bump + notes + commit + tag (BUMP=patch by default)
git push -u origin release/1.3.0 --follow-tags     # the tag is local until you do
gh pr create --label area:release --label risk:high

# …review the notes and the diff, wait for green CI, then:
gh pr merge --merge --delete-branch                # --merge, NEVER --squash

git switch main && git pull
make direct                       # archive, sign, notarize, staple, DMG
make appcast                      # fetch live feed, add the new version, sign
make publish-dry-run              # see exactly what would be uploaded
make publish-release              # DMGs first, then latest.json, then appcast
```

Order matters and the script enforces it. The appcast is the _announcement_: the
moment it lists a version, installed copies start fetching that URL, so the DMG
has to be in the bucket first.

### The merge back to main is not optional, and not `--squash`

`bump-version.sh` refuses to run on `main` — a release commit and its notes should
be reviewable like anything else — so every release is cut on a branch and has to
be merged back. Nothing used to check that it was, and the checklist above didn't
even mention it.

**Squash-merging a release branch orphans its tag.** Squashing rewrites the commit,
so `v<version>` is left pointing at the original, which is now reachable only from
the release branch — and `--delete-branch` then removes the last ref that could
reach it. The consequences are quiet and cumulative:

- `git describe` on `main` can't see the release.
- `bump-version.sh`'s `resolve_base` can't find `refs/tags/v$CUR_MV`, so the next
  release's notes are drafted against the wrong range.
- The DMG in R2 corresponds to a commit that is in no branch's history, so "what
  shipped as 1.2?" has no answer you can `git show`.

`v1.2` is permanently in that state. It can't be repaired without force-pushing a
tag, which is worse than leaving it, so it is named in the legacy allowlist in
`.github/workflows/release-integrity.yml` and nothing new belongs on that list.

Two guards now make it structural rather than remembered:

- **`publish-release.sh` refuses to publish** a version whose `v<version>` tag is
  not an ancestor of `origin/main`. Publishing is the last irreversible step, so
  it is the right place to insist the release reached mainline. `--allow-unmerged`
  overrides it for a genuine emergency.
- **`.github/workflows/release-integrity.yml`** checks, on every push to `main`,
  on every tag, and weekly: every `v*` tag is an ancestor of `main`, `VERSION`
  names the newest tag `main` can see, the published appcast lists that version,
  and every enclosure URL in the feed answers 200 — deltas included. On failure it
  opens a `needs:human` issue instead of only going red.

Releases are always targeted and approved by a human; agents never cut, tag, build
or publish one. See `docs/autonomy.md`.

`make appcast` pulls the published `appcast.xml` down before regenerating.
`generate_appcast` only ever _adds_ to a feed it finds in the archives
directory — regenerating from a directory holding only the newest DMG would
silently produce a one-item feed and drop the entries users are updating _from_.
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
- [x] R2 bucket `synesthia-releases` created (2026-07-25)
- [x] `name` in `web/wrangler.jsonc` matches the real Pages project (`synesthia`)
- [ ] `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` bumped on **both** targets

### After the first successful publish

- [ ] confirm `curl -sI https://synesthia.app/download` returns 302 (it 503s until then)
- [ ] confirm `https://synesthia.app/appcast.xml` returns the signed feed
- [ ] flip `APP_STORE_AVAILABLE` to `true` only once review has actually passed
