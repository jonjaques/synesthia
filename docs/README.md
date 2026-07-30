# Synesthia developer documentation

Synesthia is a macOS music visualizer: it listens to audio (anything your Mac plays,
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
4. **[Visualizers](visualizers.md)** — the plugin system, how the four
   built-in visualizers work, and a step-by-step guide to writing a new one.
5. **[macOS integration](macos-integration.md)** — permissions, sandboxing,
   reading and driving other apps' playback, window chrome, and the Xcode project's
   non-obvious configuration choices.

## Source map

```
Synesthia/
├── SynesthiaApp.swift            App entry point; window + menu commands
├── AppState.swift                Central state hub and composition root
├── ContentView.swift             The window's UI: canvas + floating chrome
├── WelcomeView.swift             First-run explainer: sources and permissions
├── WindowChrome.swift            Strips the title bar off the AppKit window
├── Updater.swift                 Sparkle glue; direct-download build only
├── Resources/DemoLoop.m4a        Bundled demo track (needs no permissions)
├── Audio/
│   ├── AudioAnalyzer.swift       FFT analysis; produces AudioSnapshot
│   └── AudioSources.swift        The audio capture/playback engines
├── Music/
│   ├── NowPlayingObserver.swift  Reads what Music/Spotify are playing from their
│   │                             distributed notifications — no permission at all
│   └── PlayerRemote.swift        Transport + cover art via Apple Events, opt-in
│                                 (compiled out of the App Store build)
└── Visualizers/
    ├── VisualizerCore.swift      Plugin protocol, registry, palettes, settings
    ├── ParticleSystem.swift      GPU-resident particle simulation scaffolding
    ├── Shaders.metal             All GPU shader code (build-time compiled)
    ├── MetalVisualizerView.swift The render loop host
    ├── NebulaVisualizer.swift    GPU-compute particle-cloud visualizer
    ├── TunnelVisualizer.swift    Spectrum-tunnel visualizer
    ├── AuroraVisualizer.swift    Waveform-ribbon visualizer
    └── BarsVisualizer.swift      Studio-console visualizer

SynesthiaTests/                   Swift Testing bundle; AudioAnalyzer + uniforms-layout coverage
Makefile                          Every build/asset/release command in one place
scripts/                          Demo-track generator, screenshot capture, release pipelines
web/                              Astro marketing site
```

Run `make` for the list of tasks; `CLAUDE.md` at the repo root documents each
one and the constraints behind them.

## What's next

**[Roadmap assessment](roadmap.md)** — every idea on the README's roadmap
list, assessed: feasibility in the current code, rough cost, and the
platform research (dated) behind the ones that depend on Apple's rules.

## Shipping

1. **[Launch plan](app-store-launch-plan.md)** — the single working document:
   what has shipped, what is still blocked, what needs a human, the decisions
   behind the shape of it all, and the verification evidence. **Read this first
   if you're picking the release back up.** The direct download is live; the
   App Store submission is not.
2. **[Distribution](distribution.md)** — how two targets produce two different
   binaries, why player control and Sparkle exist in only one of them,
   versioning, and the build/notarize/publish pipelines.
3. **[App Store metadata](app-store-metadata.md)** — drafts of every listing
   field plus the review notes. Length-checked by `scripts/check-metadata.py`.

---

`CLAUDE.md` (repo root) records build commands and hard-won gotchas;
`README.md` covers the user-facing feature set.
