# Synesthia

A Metal-powered music visualizer for macOS, in the spirit of the classic
iTunes/Music visualizer — but tone-reactive: a 64-band log-spaced FFT drives
every visual, so bass, mids, and treble each shape the picture differently.

![status](https://img.shields.io/badge/status-working%20v1-brightgreen)

## Using it

1. Launch the app and click **▶** in the control bar (move the mouse to reveal
   it). With the default **Music app** source, this starts playback in Music (a
   random library track if nothing is queued) and attaches a system-audio tap.
2. On first run macOS asks for two permissions:
   - **Automation → Music** — play/pause control and track metadata
   - **Screen & System Audio Recording** — to hear what's playing (audio only;
     the video leg is never read). If you grant it after the first attempt,
     just click play again; the app re-attaches without pausing Music.
3. Shortcuts: `Space` play/pause · `⌘1/2/3` switch visualizer · `⌘→/←`
   next/previous track · `⌘O` open an audio file · green button / `⌃⌘F`
   fullscreen.

### Audio sources (control bar, left menu)

| Source           | What it does                                          | Metadata shown                |
| ---------------- | ----------------------------------------------------- | ----------------------------- |
| **Music app**    | Controls Music.app, taps system audio                 | Title, artist, album, artwork |
| **System audio** | Visualizes anything the Mac plays (Spotify, browser…) | —                             |
| **Audio input**  | Mic, line-in, or any input device (picker in menu)    | Device name                   |
| **Audio file**   | Plays a local file in-app, loops it                   | Filename                      |

Capture auto-attaches on launch for the System audio source, and auto-latches
onto Music if it's already playing when the app opens. Track metadata and
artwork only appear in **Music app** mode — the other sources have no way to
know what's playing.

### Visualizers

| Name                | Idea                                                                                                 | Options              |
| ------------------- | ---------------------------------------------------------------------------------------------------- | -------------------- |
| **Nebula**          | 3D orbiting particle cloud; each particle is bound to a frequency band and flares when its band hits | Density, Glow, Swirl |
| **Spectrum Tunnel** | Flight through a tube whose angular slices are the live spectrum                                     | Twist, Glow          |
| **Aurora**          | Layered ribbons riding the waveform, each glowing with its slice of the spectrum                     | Ribbons, Wave height |

All visualizers share global **Sensitivity**, **Speed**, and five color
**palettes** (Prism, Ember, Ocean, Violet, Mono) — see the slider icon in the
control bar. Settings persist across launches.

### Troubleshooting

- **Visuals don't react** — check System Settings › Privacy & Security ›
  Screen & System Audio Recording, then click play again. If they react but
  weakly, raise **Sensitivity** in the options popover.
- **No track info / artwork** — source must be **Music app**, and Automation
  permission must be granted (System Settings › Privacy & Security ›
  Automation › Synesthia › Music).

## Contributing

### What you need

Everything below is either bundled with macOS/Xcode or one command away. There
is no dependency you have to hunt down.

|                               | Why                                                      | How                                            |
| ----------------------------- | -------------------------------------------------------- | ---------------------------------------------- |
| **macOS 26** (Tahoe) or later | the deployment target is 26.0                            | —                                              |
| **Xcode 26.6+**               | Swift 6.3 toolchain, `SDKROOT = macosx`                  | Mac App Store, or `brew install --cask xcodes` |
| Command line tools            | `xcodebuild`, `codesign`, `hdiutil`, `sips`, `afconvert` | `xcode-select --install`                       |
| **Metal Toolchain**           | compiles `Shaders.metal` at build time                   | `xcodebuild -downloadComponent MetalToolchain` |
| **Node ≥ 22.12**              | the website and the Cloudflare tooling                   | `brew install node`                            |
| Python 3                      | `make demo-track`, `make check-metadata`                 | ships with macOS; stdlib only, no pip installs |

Sparkle's command line tools (`generate_appcast`, `sign_update`) are **not**
installed separately — they arrive with the Swift Package Manager artifact the
moment you build the `Synesthia Direct` target, and the scripts find them there.

Only if you are cutting a release you also need an Apple Developer Program
membership, the certificates in [docs/distribution.md](docs/distribution.md),
and `npx wrangler login` for the Cloudflare side.

### First run

```bash
git clone git@github.com:jonjaques/synesthia.git && cd synesthia
make install     # npm deps for the root: Prettier
make build       # Debug build of the App Store target
make test        # 19 Swift Testing cases over AudioAnalyzer
```

The website is a separate project with its own lockfile — `cd web && npm ci`,
then `npm run dev`. See [web/README.md](web/README.md).

Xcode works normally too — open `Synesthia.xcodeproj` and pick a scheme.
**Any `.swift` file you add anywhere under `Synesthia/` is compiled
automatically**; the project uses a synchronized file group, so never add file
references by hand.

### Everyday workflow

```bash
make run                  # build, then launch the app
make build-direct         # the Sparkle-enabled build, for updater work
make lint                 # check formatting
make format               # fix what lint complains about
make healthcheck          # run this before pushing: lint + test + build-direct
```

`make lint` is formatting only: Prettier across everything outside `web/`, then
`swift format lint --strict` over the app, the tests and `scripts/shotkit.swift`
— under `--strict` any diagnostic, down to indentation, is an error. `make
format` fixes both in place. swift-format ships inside the Xcode toolchain, so
there is nothing to install, and Xcode's own **Editor ▸ Structure ▸ Format File
with swift-format** reads the same `.swift-format` at the repo root. On top of
formatting, the build is a gate too: every configuration is expected to compile
with **zero warnings**.

`make healthcheck` is the whole PR gate in one target — lint, the test suite,
then the Direct build — and is exactly what CI runs.

### CI

[`.github/workflows/healthcheck.yml`](.github/workflows/healthcheck.yml) runs on
every pull request push, as two independent jobs matching the two projects in
the repo:

| Job     | Runner          | What it does                                                           |
| ------- | --------------- | ---------------------------------------------------------------------- |
| `web`   | `ubuntu-latest` | Everything from inside `web/`: `npm ci`, `check`, `typecheck`, `build` |
| `apple` | `macos-26`      | `make install && make healthcheck`                                     |

The runner has no signing identity, so the Makefile ad-hoc signs whenever `CI`
is set — enough for the sandbox, and the real releases are signed by
`scripts/build-direct.sh` on a machine that has the certificates.

### Every target

`make` on its own lists them. Each is a thin wrapper around `xcodebuild` or a
script in `scripts/`, and every script stays runnable directly with `--help`.

| Target                                | What it does                                                              |
| ------------------------------------- | ------------------------------------------------------------------------- |
| `build`                               | Build the App Store target. `CONFIGURATION=Debug` by default              |
| `build-direct`                        | Build `Synesthia Direct` — the only target that links Sparkle             |
| `run`                                 | Build, then open the resulting `.app`                                     |
| `test`                                | The `SynesthiaTests` Swift Testing suite                                  |
| `clean`                               | `xcodebuild clean` plus `rm -rf build/`                                   |
| `app-path`                            | Print where the built `.app` actually landed for this `CONFIGURATION`     |
| `install`                             | `npm install` at the root — Prettier, nothing else                        |
| `healthcheck`                         | The PR gate: `lint`, `test`, `build-direct`                               |
| `lint` · `format`                     | Check / fix formatting: Prettier, then swift-format                       |
| `demo-track`                          | Regenerate the bundled 32 s demo loop, deterministically                  |
| `screenshots`                         | Drive the real UI and capture every visualizer (see below)                |
| `check-metadata`                      | Check the App Store listing drafts against Apple's field limits           |
| `bump`                                | Raise the version everywhere it is recorded — see [Releasing](#releasing) |
| `direct` · `direct-fast`              | Notarized direct-download build; `-fast` skips the notary round trip      |
| `appstore` · `appstore-upload`        | Archive and validate the store build, optionally upload it                |
| `sparkle-keys`                        | One-time: create the EdDSA update-signing key                             |
| `appcast`                             | Regenerate the signed Sparkle feed into `build/releases`                  |
| `publish-release` · `publish-dry-run` | Upload the release to R2, or show what would go                           |

Variables: **`CONFIGURATION`** (`Debug` default, then `Direct` and `Release` —
[docs/distribution.md](docs/distribution.md) explains why the store and direct
builds differ), **`BUMP`** for `make bump`, **`DESTINATION`** for `make test`,
and **`ARGS`** to forward flags to the wrapped script, e.g.
`make screenshots ARGS="--only nebula"`.

### Screenshots

`make screenshots` relaunches the app once per registered visualizer with
`-visualizerID` in its argument domain, sizes the window, captures it, then
repeats in fullscreen. Each run writes under its own prefix
(`20260725-174312Z-nebula-windowed.png`) so takes accumulate rather than
overwrite; `ARGS="--prefix hero"` names one yourself, `--prefix ''` drops it.
It assumes **Music.app is already playing** so the
now-playing badge and artwork are populated. Because it drives another app's
window, the terminal you run it from needs two grants in System Settings ›
Privacy & Security: **Accessibility** (resize the window, move the pointer so
the auto-hiding chrome reappears) and **Screen & System Audio Recording**
(`screencapture` itself). The script checks both up front and tells you what's
missing. `./scripts/take-screenshots.sh --help` lists the options.

## Releasing

Synesthia ships through two independent channels, built from **two targets over
three configurations**. The short version: `Synesthia Direct` / `Direct` is the
notarized download from synesthia.app and is the only one with Sparkle and the
Music.app integration; `Synesthia` / `Release` is the Mac App Store build and
contains neither. [docs/distribution.md](docs/distribution.md) has the full
rationale; [docs/app-store-launch-plan.md](docs/app-store-launch-plan.md) tracks
what is still outstanding.

### 1. Cut a version

```bash
make bump                 # patch: 1.0 -> 1.0.1
make bump BUMP=minor      #        1.0.1 -> 1.1
make bump BUMP=major      #        1.1 -> 2.0
make bump BUMP=2.5        # or set it explicitly
```

The version lives in `project.pbxproj` as build settings, duplicated across
every target and configuration — **nine copies of each**. `make bump` writes
them all, always increments the build number, refuses to run if they have
drifted apart, and updates the website's `RELEASE.version` too.

> **Always let the marketing version move, not just the build number.** The DMG
> is named `Synesthia-<version>.dmg`, so two releases sharing a version collide
> on one filename in R2. `publish-release` hard-fails on that rather than
> silently serving old bytes under a new signature.

### 2. Release the direct download

```bash
make test                 # nothing ships that hasn't passed
make direct               # archive, sign, notarize app + DMG, staple, verify
make appcast              # add it to the signed Sparkle feed
make publish-dry-run      # confirm what is about to be uploaded
make publish-release      # DMGs first, then latest.json, then the appcast
```

Order is not cosmetic. `make direct` notarizes twice — the app before the disk
image is built, so the copy users drag out of the DMG carries its own ticket,
then the signed DMG itself. `publish-release` uploads artifacts **before** the
appcast, because the appcast is the announcement: the moment it lists a
version, installed copies start fetching that URL.

Afterwards, update `RELEASE.size` in `web/src/consts.ts` from the byte count
`make direct` printed, then commit and push — Cloudflare Pages deploys the site
from git, while the release artifacts themselves live in R2 and need no rebuild.

### 3. Release to the Mac App Store

```bash
make check-metadata       # listing copy against Apple's field limits
make appstore             # archive, assert, export
make appstore-upload      # …and send it to App Store Connect
```

`make appstore` refuses to continue unless the archive is universal, carries no
`get-task-allow`, no Apple Events entitlement, no `tell application "Music"`
string, and **no Sparkle** — the store build must not ship an updater. Flip
`APP_STORE_AVAILABLE` in `web/src/consts.ts` once review actually passes.

## How it works

> Developer documentation lives in [`docs/`](docs/README.md) — architecture,
> the audio pipeline, rendering, the visualizer plugin system, and macOS
> integration, written for developers new to audio/graphics/macOS.

```
SystemAudioCapture (ScreenCaptureKit)  ─┐
InputDeviceCapture (AVAudioEngine tap) ─┼─▶ AudioAnalyzer ──▶ AudioSnapshot ──▶ MetalVisualizerView ──▶ active Visualizer
FilePlayer (AVAudioEngine + tap)       ─┘    (vDSP FFT)       (lock-guarded)      (MTKView, 60 fps)      (Metal pipelines)

MusicController (Apple Events) ──▶ transport + now-playing metadata/artwork
```

- `AudioAnalyzer` ingests mono samples from any audio thread, runs a
  Hann-windowed 2048-point FFT (Accelerate/vDSP), and publishes a snapshot: 64
  log-spaced bands (30 Hz–16 kHz), a 256-sample waveform, bass/mid/treble/level
  scalars, and a beat envelope from bass-transient detection. Visuals decay
  gracefully when the source goes silent.
- The render loop pulls the latest snapshot each frame — no audio→UI
  publishing, no allocation churn on the audio thread.

## Plugin architecture

Visualizers are plugins (`Synesthia/Visualizers/VisualizerCore.swift`):

1. Conform a class to `Visualizer` and give it a static `VisualizerDescriptor`
   (id, display name, tagline, up to four `VisualizerOption` sliders).
2. Add shader functions to `Shaders.metal` (compiled at build time into the
   app's default library). A future external bundle would instead ship MSL
   source and compile it at load time with `MTLDevice.makeLibrary(source:)`.
3. Add the descriptor to `VisualizerRegistry.all`'s initial list, or call
   `VisualizerRegistry.register(_:)` at startup (the hook external bundles
   would use).

Declared options automatically appear in the Options popover and arrive in the
shader as `VizUniforms.p0…p3`. Audio data arrives as a 64-float band array, a
256-float waveform, plus derived scalars — see `AudioAnalyzer.swift`.

## Roadmap / ideas

- **True external plugins**: load `VisualizerDescriptor`s from `.bundle`s in
  `~/Library/Application Support/Synesthia/Plugins` via `register(_:)`.
- **More visualizers**: raymarched geometry, GPU-compute particle systems
  (the CPU sim tops out around ~8k particles), classic bar spectrum.
- **Per-visualizer palettes** and user-defined color palettes.
- **Beat-synced scene changes** (auto-rotate visualizers every N bars).
- **Loudness normalization** so Sensitivity doesn't need retuning per source.
- **Now-playing via MediaRemote alternatives** for Spotify and other players
  (currently only Music.app exposes metadata to us).
- **Screen saver target** reusing the same render stack.
- **String Catalog localization** — UI strings are currently literals; the
  project has `STRING_CATALOG_GENERATE_SYMBOLS` enabled and should migrate.
- **Visualizer test coverage** — `SynesthiaTests` covers `AudioAnalyzer`
  thoroughly; the Metal visualizers have none and are much harder to assert on.
