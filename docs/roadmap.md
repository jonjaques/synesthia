# Roadmap assessment

The README's [roadmap list](../README.md#roadmap--ideas) says _what_ we might
build; this document records an assessment of each item — how feasible it is
in the current codebase, roughly what it costs, and which ones depend on
platform realities outside our control. The codebase claims come from reading
the source at `0e0f185`; the platform claims were researched in July 2026 and
are dated because they will drift (Apple changes TCC and private-framework
policy between point releases). Sources at the bottom.

The short version: **beat-synced scene changes** is now the best
effort-to-payoff bet, and it inherited most of its groundwork from the two
items that have since shipped (loudness normalization and GPU-compute
particles). Spotify now-playing is viable but only via the AppleScript route.
The screen saver target should wait — the third-party screen saver story on
macOS 26 is in bad shape.

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
- **GPU-compute particle systems** — shipped, and Nebula was rewritten onto
  it. The assessment below was right that the plumbing was friendly: the kernel
  is one more encoder in the same command buffer, and the ~4k CPU ceiling became
  ~131k particles. Five things it did not anticipate:

  - **The reusable half is worth separating.** `GPUParticleSystem`
    (`ParticleSystem.swift`) owns the device-private ping-pong buffers, the
    seed/step dispatch, the fixed buffer-binding convention, and the instanced
    sprite draw; a visualizer supplies only its state layout and its two
    kernels. A flocking or fluid visualizer starts from there — which is the
    actual point of this item.
  - **Porting the math verbatim would have wasted it.** The kinematic CPU model
    (rotate a direction, ease a radius) ports cleanly and looks identical, which
    is no use at a hundred thousand particles. Nebula now integrates real
    velocity toward a target position, so divergence-free turbulence, comet
    impulses and the shockwave can push particles _off_ the shape: the bodies
    stay legible while the motion between them becomes weather.
  - **Two CPU/GPU mirrors disappeared** instead of being maintained. The
    body-orbit function exists only in MSL now, and the shockwave front is
    derived from the decaying `beat` envelope rather than integrated, so the
    particles and the background ring are literally the same wave.
  - **The contract needed three additions**, all cheap, all documented in
    [rendering.md](rendering.md): a `makeComputePipeline` helper; host-derived
    `beatHit`/`trebleHit` rising edges, because a kernel has no memory of the
    previous frame's envelope and so cannot detect an event itself; and 16
    option slots instead of 8, declared in MSL as an indexable `float p[16]` —
    which is also what the data-only plugin host below will need. Both structs
    now assert their own size, so the byte-identical invariant is checked
    rather than remembered.
  - **Tuning does not survive a 20× count change.** Sprite sizes and
    intensities both have to scale down with density or a dense cloud is a
    white disc; point sprites had to become instanced quads (orientable, so a
    particle stretches along its own velocity); and bloom had to be done
    properly — two cheaper approximations off the mip chain both read as
    blocks.

  Measured on an M5 at 2560×1600 with ~81k particles: 60 fps, 11.7 ms of GPU
  time, at full render scale — cheaper per pixel than the tunnel.

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

The pragmatic v1 skips tempo entirely: rotate every N beats with a
minimum-interval floor. Half of that is already done — the render host now
detects the `beat` rising edge itself and publishes a running `beatCount` in
`VizUniforms` (it had to, so a GPU kernel could fire impulses on the exact
frame of a hit), so "every N beats" is a subtraction. Three caveats from the
code:

- A switch builds the new visualizer's pipelines **on the render thread
  inside `draw`** — a one-frame hitch. There is still no crossfade, but the
  entrance half now exists: `VizUniforms.intro` ramps 0 → 1 over 0.7 s after a
  visualizer is built, and Nebula fades the whole frame up with it. A true
  crossfade means keeping two visualizers alive at once and blending their
  targets, which is the polish half of this feature.
- `AppState.visualizerID` persists to `UserDefaults` in its `didSet`, so a
  rotate churns the stored value on every scene change.
- Reduce Motion must gate the whole feature. `MetalVisualizerView` documents
  a photosensitivity rationale for its existing damping; auto-rotating on
  beats is exactly the kind of flashing behavior that rationale covers.

### 2. Now-playing for Spotify and other players

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
168-byte `VizUniforms` contract (touch both struct declarations; shader
bodies only call `cosPalette`, so they survive) or bind a separate buffer.
Extending it is now a beaten path — the option block went 8 → 16 slots the
same way, and both sides assert their size, so the edit either matches or
fails the build.
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
exact encode, so the host is ~30 lines. One piece of that landed with the
compute work: options reach the shader as an indexable `float p[16]`, so a host
can map a manifest's declared options onto slots without knowing their names,
which is exactly what it could not do against named `p0…p7` fields. Data-only plugins are sandbox- and
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
- **Visualizer test coverage** — the layout half of this shipped with the
  compute work: `VizUniformsTests` pins the 168-byte contract field by field,
  the contiguity of the option block, the parameter mapping, and that every
  registered descriptor fits the slot count (with a `static_assert` doing the
  same on the MSL side). What is left is Bars' fader-desk simulation, the one
  remaining CPU-side visualizer state machine — Nebula's band-to-particle
  mapping moved into a kernel and is no longer reachable from a test. Rendering
  itself stays untested; that's fine.

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
