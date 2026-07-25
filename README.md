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

| Source | What it does | Metadata shown |
|---|---|---|
| **Music app** | Controls Music.app, taps system audio | Title, artist, album, artwork |
| **System audio** | Visualizes anything the Mac plays (Spotify, browser…) | — |
| **Audio input** | Mic, line-in, or any input device (picker in menu) | Device name |
| **Audio file** | Plays a local file in-app, loops it | Filename |

Capture auto-attaches on launch for the System audio source, and auto-latches
onto Music if it's already playing when the app opens. Track metadata and
artwork only appear in **Music app** mode — the other sources have no way to
know what's playing.

### Visualizers

| Name | Idea | Options |
|---|---|---|
| **Nebula** | 3D orbiting particle cloud; each particle is bound to a frequency band and flares when its band hits | Density, Glow, Swirl |
| **Spectrum Tunnel** | Flight through a tube whose angular slices are the live spectrum | Twist, Glow |
| **Aurora** | Layered ribbons riding the waveform, each glowing with its slice of the spectrum | Ribbons, Wave height |

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
2. Ship shader source as an MSL string compiled at runtime with
   `MTLDevice.makeLibrary(source:)` (see `ShaderSource.swift`) — no offline
   Metal toolchain needed, and a future external bundle can carry its own
   shader source the same way.
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
- **Tests**: the analyzer (band mapping, beat detection) is pure enough to unit
  test once a test target exists.
