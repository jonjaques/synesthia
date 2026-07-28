# Roadmap assessment

The README's [roadmap list](../README.md#roadmap--ideas) says _what_ we might
build; this document records an assessment of each item — how feasible it is
in the current codebase, roughly what it costs, and which ones depend on
platform realities outside our control. The codebase claims come from reading
the source at `0e0f185`; the platform claims were researched in July 2026 and
are dated because they will drift (Apple changes TCC and private-framework
policy between point releases). Sources at the bottom.

The short version: **beat-synced scene changes and GPU-compute particles**
are the best effort-to-payoff bets, in that order (loudness normalization,
formerly the top pick, has shipped). Spotify now-playing is viable but only
via the AppleScript route. The screen saver target should wait — the
third-party screen saver story on macOS 26 is in bad shape.

## Already shipped (the README list was stale)

- **Classic bar spectrum** — shipped as the Bars visualizer.
- **Per-visualizer palettes** — shipped: `VisualizerTuning` stores
  `paletteIndex` per visualizer id and `VisualizerSettings` persists tunings
  keyed by id, so every visualizer already remembers its own palette. Only
  the _user-defined_ palettes half of that roadmap entry remains open (see
  below).
- **Loudness normalization** — shipped: `AudioAnalyzer` runs a slow AGC (a
  gated peak tracker on the program level, primed on the first audible pass)
  that shifts both dB mappings, clamped to −12…+24 dB. On by default,
  toggleable via **Normalize Loudness** in the Settings window (⌘,;
  `AppState.loudnessNormalizationEnabled`). As predicted it needed zero
  shader changes; the analyzer tests that asserted the fixed mapping now pin
  it with auto-gain disabled, and a new test section covers convergence,
  the silence gate, and the disable ramp. Sensitivity is now purely a
  visual-response control — worth the release note.

## High-leverage next steps

### 1. Beat-synced scene changes

Switching visualizers is already safe to automate: the render loop polls
`AppState.visualizerID` every frame and hot-swaps the instance, so
auto-rotate is one string assignment from the main actor. What does _not_
exist is any tempo, BPM, or bar tracking — `AudioAnalyzer` publishes
edge-triggered onset envelopes (`beat`, `trebleBeat`), nothing periodic. So
"every N bars" needs a tempo estimator first (the analyzer's ~47 Hz pass
cadence is the natural clock, but `AudioSnapshot` carries no timestamp or
pass counter today).

The pragmatic v1 skips tempo entirely: count `beat` rising edges (Nebula
already does rising-edge detection on this signal for its shockwave) and
rotate every N beats with a minimum-interval floor. Three caveats from the
code:

- A switch builds the new visualizer's pipelines **on the render thread
  inside `draw`** — a one-frame hitch. There is no crossfade/transition
  infrastructure; adding one is the polish half of this feature.
- `AppState.visualizerID` persists to `UserDefaults` in its `didSet`, so a
  rotate churns the stored value on every scene change.
- Reduce Motion must gate the whole feature. `MetalVisualizerView` documents
  a photosensitivity rationale for its existing damping; auto-rotating on
  beats is exactly the kind of flashing behavior that rationale covers.

### 2. GPU-compute particle systems

No compute pipeline exists anywhere in the project yet — `MetalRenderContext`
builds only render pipelines — but the plumbing is friendly. Nebula's
simulation is a serial CPU loop over up to 4,096 particles running on the
render thread, writing straight into triple-buffered `.storageModeShared`
`MTLBuffer`s. `Visualizer.draw` receives the `MTLCommandBuffer` directly,
and Nebula already encodes multiple passes (HDR offscreen + tonemap), so a
compute kernel is just one more encoder in the same command buffer: port the
per-particle math (quaternion orbit, radius spring, comet kicks, shockwave)
to a kernel, keep the same buffers, and the ~8k CPU ceiling becomes 100k+
with the render thread freed.

This is the highest-_ceiling_ item for what the app fundamentally is: it
unlocks visualizer categories (flocking, fluid-ish sims, million-point
fields) that a CPU sim cannot reach.

### 3. Now-playing for Spotify and other players

The general approach is dead: since macOS 15.4, `mediaremoted` verifies an
entitlement and denies now-playing information to non-Apple clients, so the
private MediaRemote framework returns nothing useful to us. The community
workaround (`mediaremote-adapter`) launches `/usr/bin/perl` — a system
binary that _is_ entitled — with a helper framework injected. Clever, but
Synesthia is sandboxed in **both** distributions, a spawned process inherits
the sandbox, and none of it would survive App Store review. Do not build on
MediaRemote.

What is viable: mirror the existing Music.app pattern for Spotify —
AppleScript over Apple Events, an `automation.apple-events` +
`temporary-exception.apple-events` entitlement for `com.spotify.client`,
compiled into the Direct build only behind the same `#if MUSIC_APP_SOURCE`
discipline (this is the exact review risk the App Store build already
strips). The code has the right seam: views consume only
`AppState.NowPlayingInfo`, which already merges two sources (Music.app and
the demo track), so a `NowPlayingSource` protocol drops in cleanly. One
flag: Spotify's AppleScript interface has recurring reports (through 2025)
of intermittently empty title/artist, so build in the same retry tolerance
`MusicController` already applies to artwork.

## Feasible, but wait for a reason

### User-defined color palettes

The five palettes are Inigo Quilez cosine palettes whose coefficient vectors
are hardcoded **twice** — `Palettes.color` in `VisualizerCore.swift` and
`cosPalette` in `Shaders.metal` — and the shader selects one by the single
float `VizUniforms.palette`. User palettes mean shipping four `float3`
coefficient vectors to the GPU instead of an index: either extend the
112-byte `VizUniforms` contract (touch both struct declarations; shader
bodies only call `cosPalette`, so they survive) or bind a separate buffer.
The UI is already data-driven — both palette pickers iterate
`Palettes.names` and render swatches by sampling `Palettes.color` — so a
palette editor is the real work, not the plumbing.

### True external plugins

More ready than the roadmap implies: `VisualizerRegistry.register(_:)`
already exists (nothing calls it), the `Visualizer` protocol is a single
`draw` method, and shipping MSL source compiled at load with
`MTLDevice.makeLibrary(source:)` is the documented intent in
`Shaders.metal` and [rendering.md](rendering.md). The practical flavor is
**data-only** plugins: a manifest (id, name, options, entry points) plus MSL
fragment source, executed by a generic host visualizer doing the standard
fullscreen-triangle encode — three of the four built-ins already share that
exact encode, so the host is ~30 lines. Data-only plugins are sandbox- and
App-Store-safe. Loading native `.bundle`s (the README's original phrasing)
is not: library validation, code-signing, and review risk. Ranked below the
items above only because demand is unproven until there's an audience asking
for it.

## Deprioritized

### Screen saver target

Researched July 2026, and the platform story is bad. Third-party screen
savers must ship as `.saver` plugins loaded by `legacyScreenSaver.appex` —
Apple's new screensaver engine is private — and macOS 26 made the legacy
host worse: it no longer sends `stopAnimation` or destroys instances,
third-party savers break multi-display setups, and the settings UI launches
duplicate instances (see the Aerial project's tracking issue). The killer
for Synesthia specifically: the renderer needs live audio, a saver runs
inside Apple's host process, so the Screen & System Audio Recording grant
would belong to `legacyScreenSaver`, not to us — a permissions story
somewhere between confusing and broken.

The same itch is better scratched by an in-app **ambient mode** (fullscreen

- idle detection), which reuses the render stack with none of this.
  Re-evaluate only if Apple opens the new engine to third parties.

## Housekeeping (worthwhile, not exciting)

- **String Catalog localization** — UI strings are literal
  `LocalizedStringKey`s and `STRING_CATALOG_GENERATE_SYMBOLS` is already
  enabled, so migration is mechanical. Blocks actual localization; nothing
  else.
- **Visualizer test coverage** — the cheap, high-value slice is asserting
  the CPU sides without touching Metal: the `VizUniforms` 112-byte layout
  contract (`MemoryLayout` assertions), Bars' fader-desk simulation, and
  Nebula's band-to-particle mapping. Rendering itself stays untested; that's
  fine.

## Sources (July 2026)

- [ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)
  — the perl-host workaround, and a good summary of the 15.4 lockdown
- [LyricFever #94](https://github.com/aviwad/LyricFever/issues/94) —
  `MRMediaRemoteGetNowPlayingInfo` returning nil on 15.4+
- [BetterTouchTool forum](https://community.folivora.ai/t/now-playing-is-no-longer-working-on-macos-15-4/42802)
  — Now Playing breakage on 15.4 as it hit shipping apps
- [Apple Developer Forums: macOS 26 Tahoe screen saver issues](https://developer.apple.com/forums/thread/787444)
- [Aerial #1396](https://github.com/JohnCoates/Aerial/issues/1396) —
  legacyScreenSaver breakage on macOS 26 tracked by the largest third-party
  saver
- [Wade Tregaskis: How to make a macOS screen saver](https://wadetregaskis.com/how-to-make-a-macos-screen-saver/)
  — the `.saver`/`legacyScreenSaver` architecture explained
- [Spotify community: "You broke AppleScript (Again)"](https://community.spotify.com/t5/Desktop-Mac/You-broke-AppleScript-Again/td-p/4937134)
  — AppleScript metadata flakiness reports
