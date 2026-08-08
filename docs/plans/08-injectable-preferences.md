# Plan 8 — Hand the preference store in

**Deepening:** persistence stops being reached globally, so the migration and round-trip logic get a test surface.
**Strength:** speculative on its own; a prerequisite for plan 2.
**Branch:** one PR, independent — but land it _before_ plan 2 if you can.

## Why

Two modules reach `UserDefaults.standard` directly and neither can be pointed anywhere else.

`VisualizerSettings` (VisualizerCore.swift:321–408) reads it in `init` (:331), writes it in
`save()` (:384), and reads it again in `migratedLegacyTunings()` (:390). Everything
interesting about that module is consequently untested — the suite has **zero** references
to `VisualizerSettings`, `VisualizerTuning` or `Palettes`:

- the `"VisualizerSettings"` → `"VisualizerTunings"` legacy migration (:389–407), including
  the de-namespacing of `"\(descriptor.id).\(option.id)"` keys;
- the JSON decode fallback (:331–337) — a corrupt blob silently reverts every visualizer to
  defaults, and nothing says whether that's intended;
- the `isDefault` round-trip (:378–380), which only works because `normalized(for:)` fills
  in unset options first — `tuning(for:)` returns an _empty_ tuning for an unknown id (:341)
  while `reset` writes a fully populated one (:375);
- the silent `try?` in `save()` (:383) — an encode failure loses the write with no trace.

`AppState` is the second store: six keys, three of them inline string literals
(`"sourceKind"` at :67, :156, :177; `"visualizerID"` at :74, :158) against four that have
constants (:144–147).

This is the cheapest candidate in the set: a defaulted init parameter, so no call site
changes.

## Scope

```
Synesthia/Visualizers/VisualizerCore.swift    VisualizerSettings.init(defaults:)
Synesthia/AppState.swift                      private init(defaults:); key constants
SynesthiaTests/VisualizerSettingsTests.swift  new
```

## Target design

```swift
@Observable
final class VisualizerSettings {
    private let defaults: UserDefaults
    private var tunings: [String: VisualizerTuning] { didSet { save() } }

    /// The store is a parameter so tests can hand in a throwaway suite. The
    /// app always passes `.standard`, which is also what keeps the
    /// screenshots pipeline working: it injects state through the argument
    /// domain (`open -a … --args -visualizerID nebula`), and `NSArgumentDomain`
    /// exists only on `.standard`.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
            let decoded = try? JSONDecoder().decode([String: VisualizerTuning].self, from: data)
        {
            tunings = decoded
        } else {
            tunings = Self.migratedLegacyTunings(from: defaults)
        }
    }
}
```

`migratedLegacyTunings` becomes `static func migratedLegacyTunings(from: UserDefaults)`, and
`save()` writes to `defaults` instead of `.standard`.

`AppState` takes the same parameter, and the two inline key literals become constants beside
the four that already exist:

```swift
private static let sourceKindKey = "sourceKind"
private static let visualizerIDKey = "visualizerID"

private let defaults: UserDefaults

private init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    …
    settings = VisualizerSettings(defaults: defaults)
    …
}
```

Note `settings` is currently `let settings = VisualizerSettings()` at the property
declaration (AppState.swift:53); it has to move into `init` to receive the store. That is
the only structural change in `AppState`.

`AppState.shared` and `private init` **stay as they are.** Making `AppState` constructible is
plan 2's job; this plan only removes the global reach so plan 2 doesn't have to do both at
once.

## Steps

1. Add the parameter to `VisualizerSettings.init`; thread `defaults` through `save()` and
   `migratedLegacyTunings`.
2. Add the parameter to `AppState.init`; move `settings` into the initializer; replace the
   ~12 `UserDefaults.standard` references with `defaults`.
3. Extract the two inline key literals into `private static let` constants.
4. Write the tests.

## Tests

New `SynesthiaTests/VisualizerSettingsTests.swift`. Each test gets a throwaway suite and
tears it down — a leaked suite would make the next run non-deterministic:

```swift
private func makeStore(_ name: String = #function) -> UserDefaults {
    let suite = "SynesthiaTests.\(name)"
    UserDefaults.standard.removePersistentDomain(forName: suite)
    return UserDefaults(suiteName: suite)!
}
```

Cover what has never been covered:

```swift
@Test func tuningsRoundTripThroughTheStore() {
    let store = makeStore()
    let a = VisualizerSettings(defaults: store)
    a.update("nebula") { $0.sensitivity = 2.5; $0.paletteIndex = 3 }
    let b = VisualizerSettings(defaults: store)
    #expect(b.tuning(for: "nebula").sensitivity == 2.5)
    #expect(b.tuning(for: "nebula").paletteIndex == 3)
}

@Test func aCorruptBlobFallsBackToDefaultsRatherThanCrashing() {
    let store = makeStore()
    store.set(Data("not json".utf8), forKey: "VisualizerTunings")
    let settings = VisualizerSettings(defaults: store)
    #expect(settings.tuning(for: "nebula") == VisualizerTuning())
}

@Test func legacySettingsCarryOntoEveryVisualizer() {
    let store = makeStore()
    store.set(
        [
            "sensitivity": 1.8, "speed": 0.5, "paletteIndex": 2,
            "options": ["bars.columns": 52.0, "tunnel.twist": 2.5],
        ] as [String: Any],
        forKey: "VisualizerSettings")

    let settings = VisualizerSettings(defaults: store)
    for descriptor in VisualizerRegistry.all {
        #expect(settings.tuning(for: descriptor.id).sensitivity == 1.8)
        #expect(settings.tuning(for: descriptor.id).paletteIndex == 2)
    }
    #expect(settings.tuning(for: "bars").options["columns"] == 52.0)
    #expect(settings.tuning(for: "tunnel").options["twist"] == 2.5)
    // De-namespacing must not leak the old key through.
    #expect(settings.tuning(for: "bars").options["bars.columns"] == nil)
}

@Test func theNewKeyWinsOverTheLegacyOne() {
    let store = makeStore()
    store.set(["sensitivity": 1.8] as [String: Any], forKey: "VisualizerSettings")
    let first = VisualizerSettings(defaults: store)
    first.update("nebula") { $0.sensitivity = 3.0 }
    #expect(VisualizerSettings(defaults: store).tuning(for: "nebula").sensitivity == 3.0)
}

@Test(arguments: VisualizerRegistry.all.map(\.id))
func resetReturnsToDefault(_ id: String) {
    let store = makeStore("\(#function).\(id)")
    let settings = VisualizerSettings(defaults: store)
    guard let descriptor = VisualizerRegistry.descriptor(id: id) else { return }

    #expect(settings.isDefault(descriptor), "a fresh store should read as default")
    settings.update(id) { $0.speed = 2.2 }
    #expect(!settings.isDefault(descriptor))
    settings.reset(descriptor)
    #expect(settings.isDefault(descriptor))
}

@Test func anUnsetOptionReadsAsItsDeclaredDefault() {
    let store = makeStore()
    let settings = VisualizerSettings(defaults: store)
    guard let bars = VisualizerRegistry.descriptor(id: "bars"),
        let columns = bars.options.first(where: { $0.id == "columns" })
    else { return }
    #expect(settings.tuning(for: "bars").value(for: columns) == columns.defaultValue)
}
```

`resetReturnsToDefault`'s first assertion is the one that pins the asymmetry described
above — `tuning(for:)` returning an empty tuning and `reset` writing a populated one only
agree because `isDefault` normalizes first. If someone "simplifies" `normalized(for:)` away,
that line fails.

## Known bug this exposes (do not fix here)

`migratedLegacyTunings` iterates `VisualizerRegistry.all` at `AppState.init` time, so a
visualizer registered later via `VisualizerRegistry.register` (VisualizerCore.swift:235)
never receives the legacy carry-over. Harmless today — nothing registers at runtime — but
worth a line in the PR description, or an `// FIXME` referencing the plugin roadmap item.
Fixing it means migrating lazily in `tuning(for:)`, which is a behaviour change and belongs
in its own PR.

## Risks

- **Don't switch the app to a named suite.** A sandboxed app's `.standard` already lives in
  its container, and the screenshots pipeline injects through `NSArgumentDomain`, which only
  `.standard` consults (`CLAUDE.md` §Screenshots). The default argument keeps that intact.
- `UserDefaults(suiteName:)` returns an optional and returns `nil` for a name equal to the
  main bundle id — the `SynesthiaTests.` prefix avoids that.
- Test suites persist in the test host's container between runs; the `removePersistentDomain`
  in `makeStore` is not optional politeness.
- `VisualizerTuning` is already `Equatable` (VisualizerCore.swift:292), so the comparisons
  above compile as written.

## Verification

```
make format && make healthcheck
```

Then `make run` twice: change a slider, quit, relaunch, confirm it stuck. And run
`make screenshots ARGS="--only bars --1x"` once — that is the path that depends on the
argument domain still reaching `.standard`.
