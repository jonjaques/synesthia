# Plan 5 — Name the option slots instead of counting them

**Deepening:** the descriptor→shader contract moves inside the option, where it can be checked.
**Strength:** worth exploring. **Branch:** one PR, independent of every other plan.

## Why

An option reaches the shader by array position. `MetalVisualizerView.swift:228`:

```swift
for (index, option) in descriptor.options.prefix(VizUniforms.parameterCount).enumerated() {
    uniforms.setParameter(index, to: Float(tuning.value(for: option)))
}
```

So `"columns"` becomes `p0` only because it is written first in `BarsVisualizer.descriptor`.
The same contract is then written a **second** time, by hand, in MSL:

```
Shaders.metal:1228   constant int kBarsOptColumns  = 0;
Shaders.metal:1234   constant int kBarsOptChannels = 6;
```

and a **third** time in Swift where the CPU-side simulation reads the same slots:

```swift
BarsVisualizer.swift:119   min(max(Int(u.p0.rounded()), 8), AudioSnapshot.bandCount)   // columns
BarsVisualizer.swift:123   min(max(Int(u.p6.rounded()), 4), maxChannels)               // channels
BarsVisualizer.swift:156   let holdAmount = min(max(u.p2, 0), 2)                       // peaks
```

Nothing checks the three agree. Reordering a descriptor's `options` array — the natural
thing to do when you want a slider to sit higher in the popover — silently remaps every
shader constant for that visualizer, with no build error and no test failure. The UI order
is load-bearing and nothing says so.

`CLAUDE.md` already mandates the `constant int k…` convention over inline `u.p[6]`. This
plan makes that convention enforceable rather than a habit.

All four visualizers currently agree (verified: aurora 0–2, tunnel 0–5, nebula 0–9, bars
0–7 all match their `k…` constants), so this lands as a pure safety net with no behaviour
change.

## Scope

```
Synesthia/Visualizers/VisualizerCore.swift        VisualizerOption gains `slot`; host reads it
Synesthia/Visualizers/MetalVisualizerView.swift   the .enumerated() loop
Synesthia/Visualizers/BarsVisualizer.swift        p0/p2/p6 reads become named
SynesthiaTests/VizUniformsTests.swift             new slot-contract tests
```

`Shaders.metal` is untouched — its `k…` constants become the thing the Swift side is pinned
against, not something to change.

## Target design

`VisualizerOption` carries its slot (VisualizerCore.swift:150–179):

```swift
struct VisualizerOption: Identifiable {
    enum Kind { case slider, toggle }

    let id: String
    let name: String
    let range: ClosedRange<Double>
    let defaultValue: Double
    let kind: Kind
    /// Which of the shader's `p[16]` slots this option lands in. Declared
    /// rather than inferred from array position, because the shader names the
    /// same number in its own `constant int k…` table and nothing else
    /// connects the two — reordering this array to change the popover's layout
    /// used to remap every shader constant silently.
    let slot: Int

    init(
        id: String, name: String, range: ClosedRange<Double>, defaultValue: Double,
        kind: Kind = .slider, slot: Int
    ) { … }

    static func toggle(id: String, name: String, defaultOn: Bool, slot: Int) -> VisualizerOption { … }
}
```

`VisualizerDescriptor.init` already asserts the option cap (VisualizerCore.swift:203–205);
extend that assert to cover the slots:

```swift
assert(
    options.allSatisfy { (0..<VizUniforms.parameterCount).contains($0.slot) },
    "\(id) declares an option outside the \(VizUniforms.parameterCount) shader slots")
assert(
    Set(options.map(\.slot)).count == options.count,
    "\(id) declares two options in the same shader slot")
```

The host stops counting (MetalVisualizerView.swift:228–230):

```swift
for option in descriptor.options {
    uniforms.setParameter(option.slot, to: Float(tuning.value(for: option)))
}
```

`setParameter` is already bounds-checked (VisualizerCore.swift:125–128), so a bad slot in a
runtime-registered plugin is dropped rather than trapping — the release-build behaviour
stays exactly as it is today.

`BarsVisualizer` names its slots the way the shader does:

```swift
/// Shader slots for this visualizer's options. Mirrored by the `kBarsOpt…`
/// constants in Shaders.metal; the test suite pins the two together.
private enum Opt {
    static let columns = 0
    static let segments = 1
    static let peakHold = 2
    static let glow = 3
    static let showDesk = 4
    static let desk = 5
    static let channels = 6
    static let meters = 7
}

static func columns(_ u: VizUniforms) -> Int {
    min(max(Int(u[parameter: Opt.columns].rounded()), 8), AudioSnapshot.bandCount)
}
```

This mirrors the `Slot` enum Bars already uses for its `state` buffer
(BarsVisualizer.swift:47–61) — same idea, applied to the option block.

## Steps

1. Add `slot` to `VisualizerOption` with **no default value**, so the compiler lists every
   declaration site that needs one. There are 27 across the four visualizers.
2. Fill them in from the existing array order — they must not change, or user tunings
   silently move to different controls.
3. Extend the two asserts in `VisualizerDescriptor.init`.
4. Replace the `.enumerated()` loop in `MetalVisualizerView`.
5. Replace `u.p0` / `u.p2` / `u.p6` in `BarsVisualizer` with the named `Opt` slots.
6. Add the tests below, then `make run` and move every slider on every visualizer.

## Tests

Add to `SynesthiaTests/VizUniformsTests.swift`, beside the existing registry-contract tests:

```swift
@Test func everyOptionSlotIsUniqueAndInRange() {
    for descriptor in VisualizerRegistry.all {
        let slots = descriptor.options.map(\.slot)
        #expect(Set(slots).count == slots.count, "\(descriptor.id) reuses a slot")
        #expect(slots.allSatisfy { (0..<VizUniforms.parameterCount).contains($0) })
    }
}

/// Pins the Swift side against the `constant int k…` table in Shaders.metal.
/// If a descriptor is reordered or a shader constant is renumbered, exactly
/// one of the two moves and this fails — which is the whole point.
@Test func optionSlotsMatchTheShaderConstants() {
    let expected: [String: [String: Int]] = [
        "aurora": ["layers": 0, "height": 1, "stars": 2],
        "tunnel": ["twist": 0, "glow": 1, "bend": 2, "pulse": 3, "ripple": 4, "fog": 5],
        "nebula": [
            "density": 0, "glow": 1, "trails": 2, "turbulence": 3, "swirl": 4,
            "orbits": 5, "spread": 6, "halos": 7, "impact": 8, "form": 9,
        ],
        "bars": [
            "columns": 0, "segments": 1, "peaks": 2, "glow": 3,
            "deskPanel": 4, "desk": 5, "channels": 6, "meters": 7,
        ],
    ]
    for (id, table) in expected {
        let descriptor = VisualizerRegistry.descriptor(id: id)
        #expect(descriptor != nil, "\(id) is no longer registered")
        for option in descriptor?.options ?? [] {
            #expect(option.slot == table[option.id], "\(id).\(option.id) moved slot")
        }
        #expect(descriptor?.options.count == table.count, "\(id) gained or lost an option")
    }
}
```

The literal table is deliberate — it is a transcription of `Shaders.metal:193–197`,
`417–419`, `578–587` and `1228–1235`. Keeping it hand-written is what makes it a check on
the MSL side rather than a restatement of the Swift side. Note this in a comment so nobody
"simplifies" it into `descriptor.options.enumerated()`, which would assert nothing.

## Risks

- **Adding `slot` without a default is a deliberate compile break.** That is the point —
  a defaulted `slot: Int = 0` would let a new option silently collide with an existing one.
- **Do not renumber anything while doing this.** A changed slot moves a user's stored
  option value onto a different shader constant on next launch. The tunings are keyed by
  option _id_ (VisualizerTuning.options, VisualizerCore.swift:297) so persistence itself is
  safe, but the shader reads by slot.
- The plugin path (`VisualizerRegistry.register`, VisualizerCore.swift:235) now requires
  external descriptors to declare slots. That is a source break for a plugin API that has
  no external users yet — the right time to make it.

## Verification

```
make format && make healthcheck
```

Then `make run`, and on each visualizer move every slider and watch the right thing change.
The tests catch renumbering; only your eyes catch a slot that was wrong from the start.
