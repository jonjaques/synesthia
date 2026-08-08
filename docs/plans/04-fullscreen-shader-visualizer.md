# Plan 4 — Collapse the fullscreen-shader visualizers

**Deepening:** two shallow modules become descriptors over one deep module.
**Strength:** worth exploring. **Branch:** one PR, no dependencies on any other plan.

## Why

`AuroraVisualizer.draw` (AuroraVisualizer.swift:37–57) and `TunnelVisualizer.draw`
(TunnelVisualizer.swift:47–67) are character-identical. So are their inits, apart from
the fragment-function name. Aurora is 58 lines of which three declare options and one
names a shader.

The `Visualizer` interface takes the `MTKView` rather than a render-pass descriptor
(VisualizerCore.swift:218–224), so every conformer independently pulls
`currentRenderPassDescriptor` and independently obeys the "simulate before touching the
drawable" rule — which exists today only as a comment, repeated in BarsVisualizer.swift:94
and NebulaVisualizer.swift:151.

Deletion test: deleting `AuroraVisualizer` moves nothing to a call site. It moves into a
shared implementation where the next fullscreen shader gets it for free. That's a
concentration, so the refactor is worth doing.

## Scope

```
Synesthia/Visualizers/FullscreenShaderVisualizer.swift   new
Synesthia/Visualizers/AuroraVisualizer.swift             class → descriptor namespace
Synesthia/Visualizers/TunnelVisualizer.swift             class → descriptor namespace
```

`VisualizerRegistry` (VisualizerCore.swift:227–232) does **not** change — the descriptor
names stay the same. Nothing in `Shaders.metal` changes.

Out of scope: `BarsVisualizer` and `NebulaVisualizer`. Bars runs `update()` before
acquiring the drawable and binds `state` at index 3 while skipping index 1; Nebula encodes
compute passes and an HDR chain. They are exactly what the `Visualizer` interface is for —
leave them as classes.

## Target design

New file, `Synesthia/Visualizers/FullscreenShaderVisualizer.swift`:

```swift
import Metal
import MetalKit

/// A visualizer that is nothing but one fullscreen fragment shader fed the
/// standard three bindings: uniforms at 0, the 64-band array at 1, the
/// waveform at 2.
///
/// Every fullscreen visualizer encoded exactly these ten lines, so the
/// ordering rule they all depended on — acquire the drawable as late as
/// possible, because `currentRenderPassDescriptor` blocks until Core
/// Animation hands one over — was a comment each of them had to remember.
/// Here it is structure: there is one encode path and it is correct.
final class FullscreenShaderVisualizer: Visualizer {
    private let pipeline: MTLRenderPipelineState

    init(
        fragment: String,
        device: MTLDevice,
        library: MTLLibrary,
        pixelFormat: MTLPixelFormat
    ) throws {
        pipeline = try makeRenderPipeline(
            device: device, library: library,
            vertex: "fullscreenVertex", fragment: fragment,
            pixelFormat: pixelFormat)
    }

    func draw(
        in view: MTKView,
        commandBuffer: MTLCommandBuffer,
        uniforms: VizUniforms,
        snapshot: AudioSnapshot
    ) {
        guard let pass = view.currentRenderPassDescriptor,
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)
        else { return }
        var u = uniforms
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&u, length: MemoryLayout<VizUniforms>.stride, index: 0)
        snapshot.bands.withUnsafeBytes {
            encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1)
        }
        snapshot.waveform.withUnsafeBytes {
            encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 2)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }
}
```

`AuroraVisualizer.swift` keeps its file name and its (long, good) doc comment, and the type
becomes a namespace holding the descriptor:

```swift
enum AuroraVisualizer {
    static let descriptor = VisualizerDescriptor(
        id: "aurora",
        name: "Aurora",
        tagline: "One ribbon per instrument, under a sky that flashes with the drums",
        options: [
            VisualizerOption(id: "layers", name: "Ribbons", range: 2...8, defaultValue: 8),
            VisualizerOption(id: "height", name: "Wave height", range: 0.05...0.6, defaultValue: 0.28),
            VisualizerOption(id: "stars", name: "Stars", range: 0.0...2.0, defaultValue: 1.0),
        ],
        make: {
            try FullscreenShaderVisualizer(
                fragment: "auroraFragment", device: $0, library: $1, pixelFormat: $2)
        })
}
```

`TunnelVisualizer` the same, with `"tunnelFragment"` and its six options.

Because `VisualizerRegistry.all` still says `AuroraVisualizer.descriptor` /
`TunnelVisualizer.descriptor`, the registry, the menu, the options panel and the persisted
tunings all keep working untouched. Nothing user-visible changes.

## Steps

1. Add `FullscreenShaderVisualizer.swift`. It compiles into both app targets automatically
   — `Synesthia/` is a `PBXFileSystemSynchronizedRootGroup`, so **do not touch
   `project.pbxproj`**.
2. Convert `AuroraVisualizer` from `final class … : Visualizer` to `enum`, deleting
   `pipeline`, `init` and `draw`. Keep the doc comment; adjust its last paragraph, which
   currently says "Like Spectrum Tunnel this is a fullscreen-shader visualizer", to point at
   `FullscreenShaderVisualizer`.
3. Same for `TunnelVisualizer`. Its doc comment's "The Swift side is a thin shell" paragraph
   describes the encode in detail — trim it to a pointer rather than leaving a description
   of code that no longer lives in that file.
4. `make build && make run`, switch to Aurora and Tunnel, confirm both render.

## Tests

There is no cheap unit test here — the value is deletion and an enforced ordering rule, and
constructing a pipeline needs a real `MTLDevice`. The existing registry contract test in
`VizUniformsTests` (registry ids, option counts) already guards the descriptors and will
catch a mistyped id. Verification is `make run` plus one screenshot pass:

```
make screenshots ARGS="--only aurora --only tunnel --1x"
```

Do **not** add a test that calls `descriptor.make(...)` — CI runs on `macos-26` where a
usable Metal device is not guaranteed, and `MetalRenderContext.shared` is deliberately
optional for exactly that reason (MetalVisualizerView.swift:19–25).

## Risks

- **Fragment name typos are runtime failures, not build failures.** `makeRenderPipeline`
  throws `VisualizerError.missingFunction`, and the host swallows it with `try?`
  (MetalVisualizerView.swift:184) — the canvas just stays black. Check both visualizers by
  eye before merging.
- `Shaders.metal` is not touched, so the `static_assert` and `VizUniformsTests` byte-layout
  contract are unaffected.

## Verification

```
make format && make lint && make test && make build-direct
```

`make healthcheck` runs those last three in that order and is the PR gate.

## Follow-on (not this PR)

Once this lands, `BarsVisualizer` could be expressed as `FullscreenShaderVisualizer` plus a
pre-pass hook and an extra binding. Worth revisiting only if a third visualizer wants the
same shape — one adapter is a hypothetical seam, two are a real one.
