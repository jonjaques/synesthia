# Synesthia developer documentation

Synesthia is a macOS music visualizer: it listens to audio (the Music app,
anything the Mac is playing, a microphone, or a local file), analyzes it in
real time, and renders GPU visuals that react to what it hears.

These documents explain how the app works for a developer who is comfortable
with object-oriented programming but not necessarily with audio processing,
GPU graphics, or the macOS/Swift/Metal ecosystem. Domain concepts (FFT,
shaders, Apple Events, sandboxing…) are introduced where they're used.

## Reading order

1. **[Architecture](architecture.md)** — the big picture: the components,
   how data flows between them, and the threading model. Start here.
2. **[Audio pipeline](audio-pipeline.md)** — where audio comes from and how
   raw samples become the `AudioSnapshot` that drives every visual.
3. **[Rendering](rendering.md)** — how frames get drawn: Metal in a nutshell,
   the 60 fps render loop, and the CPU→GPU data contract.
4. **[Visualizers](visualizers.md)** — the plugin system, how the three
   built-in visualizers work, and a step-by-step guide to writing a new one.
5. **[macOS integration](macos-integration.md)** — permissions, sandboxing,
   controlling the Music app, window chrome, and the Xcode project's
   non-obvious configuration choices.

## Source map

```
Synesthia/
├── SynesthiaApp.swift            App entry point; window + menu commands
├── AppState.swift                Central state hub and composition root
├── ContentView.swift             The window's UI: canvas + floating chrome
├── WindowChrome.swift            Strips the title bar off the AppKit window
├── Audio/
│   ├── AudioAnalyzer.swift       FFT analysis; produces AudioSnapshot
│   └── AudioSources.swift        The four audio capture/playback engines
├── Music/
│   └── MusicController.swift     Remote-controls Music.app via Apple Events
└── Visualizers/
    ├── VisualizerCore.swift      Plugin protocol, registry, palettes, settings
    ├── ShaderSource.swift        All GPU shader code, as a string
    ├── MetalVisualizerView.swift The render loop host
    ├── NebulaVisualizer.swift    Particle-cloud visualizer
    ├── TunnelVisualizer.swift    Spectrum-tunnel visualizer
    └── AuroraVisualizer.swift    Waveform-ribbon visualizer
```

`CLAUDE.md` (repo root) records build commands and hard-won gotchas;
`README.md` covers the user-facing feature set.
