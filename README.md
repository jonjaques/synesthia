# Synesthia

A Metal-powered music visualizer for macOS, in the spirit of the classic
iTunes/Music visualizer — but tone-reactive: a 64-band log-spaced FFT drives
every visual, so bass, mids, and treble each shape the picture differently.

## Using it

1. Launch the app and click **▶** in the control bar (move the mouse to reveal it).
   With the default **Music app** source, this starts playback in Music (a random
   library track if nothing is queued) and attaches a system-audio tap.
2. On first run macOS will ask for two permissions:
   - **Automation → Music** (to play/pause and read track info)
   - **Screen & System Audio Recording** (to hear what's playing — audio only;
     the video leg is never read). If visuals don't react, grant this in
     System Settings › Privacy & Security, then click play again.
3. `Space` play/pause · `⌘1/2/3` switch visualizer · `⌘→/←` next/previous track ·
   `⌘O` open an audio file · standard green-button/⌃⌘F for fullscreen.

### Audio sources (control bar, left menu)

- **Music app** — controls Music.app, shows track title/artist/album/artwork,
  visualizes via the system-audio tap.
- **System audio** — visualizes anything the Mac is playing (Spotify, browser…).
- **Audio input** — microphone, line-in, or any input device (pick one in the menu).
- **Audio file** — plays a local file in-app and visualizes its exact output.

### Visualizers

| Name | Idea | Options |
|---|---|---|
| **Nebula** | 3D orbiting particle cloud; each particle is bound to a frequency band and flares when its band hits | Density, Glow, Swirl |
| **Spectrum Tunnel** | Flight through a tube whose angular slices are the live spectrum | Twist, Glow |
| **Aurora** | Layered ribbons riding the waveform, each glowing with its slice of the spectrum | Ribbons, Wave height |

All visualizers share global **Sensitivity**, **Speed**, and five color
**palettes** (Prism, Ember, Ocean, Violet, Mono) — see the slider icon in the
control bar. Settings persist across launches.

## Plugin architecture

Visualizers are plugins (`Synesthia/Visualizers/VisualizerCore.swift`):

1. Conform a class to `Visualizer` and give it a static `VisualizerDescriptor`
   (id, display name, up to four `VisualizerOption` sliders).
2. Ship shader source as an MSL string compiled at runtime with
   `MTLDevice.makeLibrary(source:)` (see `ShaderSource.swift`) — no offline
   Metal toolchain needed.
3. Add the descriptor to `VisualizerRegistry.builtIn`, or call
   `VisualizerRegistry.register(_:)` at startup (the hook external bundles
   would use).

Declared options automatically appear in the Options popover and arrive in the
shader as `VizUniforms.p0…p3`. Audio data arrives as a 64-float band array, a
256-float waveform, plus derived scalars (bass/mid/treble/level/beat) — see
`AudioAnalyzer.swift`.
