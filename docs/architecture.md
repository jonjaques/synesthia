# Architecture

## The one-paragraph version

Audio arrives from one of four sources on background audio threads and is
funneled into a single analyzer, which continuously distills it into a small
value-type summary (`AudioSnapshot`). Sixty times a second, the render loop
_pulls_ the latest snapshot and hands it to the currently selected
visualizer, which draws a frame on the GPU. A thin SwiftUI layer floats on
top for controls, coordinated by one observable `AppState` object. The two
halves — audio→graphics and UI — touch only at well-defined points.

## Component map

```mermaid
flowchart LR
    subgraph sources["Audio sources (background threads)"]
        SCK["SystemAudioCapture<br>(ScreenCaptureKit)"]
        MIC["InputDeviceCapture<br>(AVAudioEngine tap)"]
        FILE["FilePlayer<br>(AVAudioEngine + tap)"]
    end

    subgraph analysis["Analysis (lock-guarded, any thread)"]
        AN["AudioAnalyzer<br>FFT + feature extraction"]
        SNAP[("AudioSnapshot<br>(value type)")]
    end

    subgraph render["Render loop (main thread, 60 fps)"]
        MVV["MetalVisualizerView<br>(MTKView host)"]
        VIZ["Active Visualizer<br>(Nebula / Tunnel / Aurora / Bars)"]
        GPU[["GPU"]]
    end

    subgraph ui["UI (main thread, event-driven)"]
        AS["AppState"]
        CV["ContentView<br>(controls chrome)"]
        MC["MusicController<br>(Apple Events → Music.app)"]
    end

    SCK --> AN
    MIC --> AN
    FILE --> AN
    AN --> SNAP
    SNAP -- "pulled once per frame" --> MVV
    MVV --> VIZ --> GPU
    AS -- "start/stop" --> sources
    AS --- MC
    CV --- AS
    CV -- selects visualizer --> MVV
```

The key asymmetry: **control flows down** (AppState starts and stops
engines), but **audio data is never pushed up**. The analyzer doesn't notify
anyone when new audio arrives; consumers come and get it. This is what keeps
the audio threads cheap and the UI free of 90-times-a-second updates.

## The main data types

| Type                                      | Role                                                                           | Mutability model                   |
| ----------------------------------------- | ------------------------------------------------------------------------------ | ---------------------------------- |
| `AudioSnapshot`                           | One frame of analyzed audio (spectrum bands, waveform, loudness, beat…)        | Immutable value copy per frame     |
| `VizUniforms`                             | The per-frame constants sent to the GPU (audio features + clock + user tuning) | Built fresh each frame             |
| `AppState`                                | Which source/visualizer is active; transport state; error banners              | `@Observable`, main actor          |
| `VisualizerDescriptor`                    | Static identity + options + factory for one visualizer                         | Immutable                          |
| `VisualizerTuning` / `VisualizerSettings` | Per-visualizer user settings, persisted to `UserDefaults`                      | `@Observable` store of value types |

## Threading model

macOS audio APIs deliver buffers on their own high-priority threads, and
those callbacks must do minimal work — no allocation, no UI. Synesthia's
answer is a single synchronization point:

```mermaid
flowchart TD
    subgraph audioThreads["Audio callback threads (real-time-ish)"]
        CB["Capture callbacks<br>appendMono(...)"]
    end
    subgraph mainThread["Main thread"]
        DRAW["MTKView draw callback<br>latest()"]
        UI2["SwiftUI + AppState + MusicController"]
    end
    LOCK{{"NSLock inside AudioAnalyzer"}}
    CB -- "append samples,<br>run FFT every 1024" --> LOCK
    DRAW -- "copy newest snapshot" --> LOCK
```

- **`AudioAnalyzer`** is the only object shared across threads. It is
  `nonisolated` (excluded from the project's main-actor default) and guards
  all its state with one `NSLock`. Both sides hold the lock only briefly;
  the FFT itself (~a few hundred microseconds) runs under it, which is fine
  at these sizes.
- **Everything else is main-actor.** The Xcode project sets
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so every type that doesn't
  opt out runs on the main thread. Background work has to opt out explicitly
  (`nonisolated`), which the capture callbacks in `AudioSources.swift` do.
- **The render loop is also on the main thread**: `MTKView` invokes its
  delegate's `draw(in:)` on the main run loop at display cadence. Drawing is
  cheap for the CPU — it just encodes commands; the GPU does the pixel work
  asynchronously.

## Why "pull", not "publish"?

A naïve design would make the analyzer `@Observable` and let SwiftUI react
to audio changes. That would invalidate SwiftUI views ~47 times per second
(every FFT hop) for data the _GPU_, not the view hierarchy, consumes. By
keeping audio data out of the observation system entirely:

- SwiftUI only re-renders for actual UI state changes (a track title, a
  button state).
- The render loop gets exactly one coherent `AudioSnapshot` per frame — no
  tearing, no partial updates — because the snapshot is copied under the
  lock as a plain value.
- The audio thread never blocks on anything slower than a short lock.

Only `AppState`, `MusicController`, and `VisualizerSettings` are
`@Observable`, and they hold _control_ state, which changes at human speed.

## Startup sequence

```mermaid
sequenceDiagram
    participant App as SynesthiaApp (@main)
    participant CV as ContentView
    participant AS as AppState
    participant MC as MusicController
    participant SC as SystemAudioCapture

    App->>CV: WindowGroup shows ContentView
    CV->>AS: onAppear()
    AS->>AS: enumerate input devices
    alt source == Music app (default)
        AS->>MC: startPolling()  (1 Hz Apple Events)
        AS->>AS: autoStartCaptureIfMusicPlaying()
        Note over AS,SC: after ~1.5 s, if Music is playing,<br>attach the system-audio tap automatically
    else source == System audio
        AS->>SC: start()  (may trigger permission prompt)
    end
    Note over CV: MetalVisualizerView is already drawing —<br>black/quiet until audio flows
```

The visualizer never waits for audio: it renders from frame one, and the
analyzer's snapshot simply stays near zero (and decays toward silence)
until samples arrive.

## Where to go next

- How samples become a snapshot: [Audio pipeline](audio-pipeline.md)
- How a snapshot becomes pixels: [Rendering](rendering.md)
- The plugin contract: [Visualizers](visualizers.md)
- Permissions and platform glue: [macOS integration](macos-integration.md)
