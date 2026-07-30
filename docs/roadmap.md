# Roadmap assessment

The README's [roadmap list](../README.md#roadmap--ideas) says _what_ we might
build; this document records an assessment of each item — how feasible it is
in the current codebase, roughly what it costs, and which ones depend on
platform realities outside our control. The codebase claims come from reading
the source at `0e0f185`; the platform claims were researched in July 2026 and
are dated because they will drift (Apple changes TCC and private-framework
policy between point releases). Sources at the bottom.

The short version: **beat-synced scene changes** is now the best
effort-to-payoff bet, and it inherited most of its groundwork from the three
items that have since shipped (loudness normalization, GPU-compute particles,
and multi-player now-playing). The screen saver target should wait — the
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
- **Now-playing for Spotify and other players** — shipped, and the assessment
  below it was wrong in the most useful direction. It concluded that
  AppleScript was the only viable route and that the App Store build therefore
  could not have the feature. Both halves turned out to be false, because it
  only considered the two routes it already knew about (MediaRemote, dead since
  15.4; Apple Events, entitlement-bound) and never asked what the players
  themselves volunteer.

  They volunteer everything that matters. Music and Spotify both broadcast
  title, artist, album and play state as **distributed notifications**, which
  cost no entitlement, no TCC prompt, no private API and no polling. The
  blocker in the way of that answer was a widely repeated claim that the App
  Sandbox strips `userInfo` from distributed notifications; it does not — the
  real rule constrains sandboxed _senders_. Verified on macOS 26.5 with an
  ad-hoc-signed sandboxed binary before a line of the feature was written, and
  again end-to-end in the shipping app with both players.

  What that changed, beyond one roadmap item:

  - **The Mac App Store build gained the feature outright**, rather than
    shipping without it. `MUSIC_APP_SOURCE` now gates only transport control
    and cover art. No new entitlement was needed anywhere; the store build
    still contains zero Apple Events, and `build-appstore.sh` still proves it
    (the assertion was widened from `tell application "Music"` to any player).
  - **A source disappeared instead of one being added.** `.musicApp` was never
    a distinct audio path — Music exposes no stream, so it already went through
    the same ScreenCaptureKit tap as System Audio — which meant the picker
    offered two options that sounded identical and differed only in metadata.
    Now-playing became a _layer_ over System Audio, and the roadmap's
    `NowPlayingSource` protocol was unnecessary: `MediaPlayer` is a table row.
  - **The remaining Apple Events became genuinely optional and opt-in.** The
    1 Hz poll is gone. Nothing sends an event until the user picks
    "Control Spotify…" from a menu, so the Automation prompt lands one click
    after they asked for exactly that, instead of at launch.
  - **Two things a broadcast can't carry**, both anticipated poorly. Cover art
    isn't in the payload, so the badge draws a palette-derived gradient tile
    with the player's icon instead of a grey square — which reads as
    intentional and costs no network request. And a player only posts on a
    _transition_, so launching into already-playing music shows no badge until
    the next song; `PlayerRemote.seed` closes that where Apple Events exist,
    and the store build picks the badge up a song late.
  - **Spotify's AppleScript flakiness never came up.** The retry tolerance the
    assessment recommended is in `seed` (an empty title is discarded rather
    than published), but the notification path made it nearly moot.

  Still open, and deliberately: only Music and Spotify are in the table. Both
  were verified against real payloads. Players in the iTunes tradition (VOX,
  Swinsian, Doppler) are one row each and need no parsing changes, but shipping
  rows nobody has watched a payload from is guesswork — and an unverified row
  is inert rather than harmful, which makes it tempting.

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

### Apple Events in the Mac App Store build

**Not currently planned, recorded because it is the obvious next question.**
The store build shows what is playing but cannot pause it or show real cover
art, because it ships no Apple Events at all. Closing that gap means asking
App Review for `com.apple.security.automation.apple-events` plus a
`temporary-exception.apple-events` array for `com.apple.Music` and
`com.spotify.client`.

That is a real, granted-in-practice request — apps do ship it — but it is
deliberately declined for now, on two grounds. It reintroduces the single
largest review risk the project spent effort removing (see
[app-store-launch-plan.md](app-store-launch-plan.md) §B5), and it weakens the
`build-appstore.sh` leak assertions from "no `tell application` string may
exist" to something conditional, which is a much worse invariant to hold.
Neither of those is a permanent objection.

The argument for revisiting it gets stronger with time, not weaker: an app with
a clean review history asking for a scoped exception, whose whole
now-playing feature demonstrably works _without_ it, is a far easier
conversation than a first submission asking for the same thing as a
prerequisite. The order matters — ship layer 2, then ask for layer 3.

If it is ever taken up, the code side is nearly free. `PlayerRemote` is already
a separate file behind one flag, the scripts are already per-player literals,
and `AppState.connectPlayerControl` is already the single opt-in gate. The work
is entirely in the entitlements, the review notes, and rewriting the
assertions — not in the app.

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
