import Foundation
import Testing

@testable import Synesthia

/// Tests for the persisted per-visualizer tuning store.
///
/// Everything here was untestable until `VisualizerSettings` took its
/// `UserDefaults` as a parameter, and it is the part of the app most likely to
/// fail *silently*: a decode that falls back, a legacy migration that
/// de-namespaces a key wrongly, a round-trip that only agrees because
/// `isDefault` normalizes first. None of those produce an error — they produce
/// a user whose look quietly reverted.
@MainActor
struct VisualizerSettingsTests {

    /// A throwaway suite per test, wiped on the way in.
    ///
    /// Suites persist in the test host's container between runs, so without the
    /// `removePersistentDomain` a test would read the *previous* run's writes
    /// and pass or fail depending on history. The `SynesthiaTests.` prefix also
    /// keeps the name away from the main bundle id, for which
    /// `UserDefaults(suiteName:)` returns nil.
    private func makeStore(_ name: String = #function) -> UserDefaults {
        let suite = "SynesthiaTests.\(name)"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)!
    }

    @Test func tuningsRoundTripThroughTheStore() {
        let store = makeStore()
        let a = VisualizerSettings(defaults: store)
        a.update("nebula") {
            $0.sensitivity = 2.5
            $0.paletteIndex = 3
        }

        let b = VisualizerSettings(defaults: store)
        #expect(b.tuning(for: "nebula").sensitivity == 2.5)
        #expect(b.tuning(for: "nebula").paletteIndex == 3)
    }

    /// A corrupt blob reverts every visualizer to defaults rather than
    /// crashing. That is the intended trade — the payload is cosmetic, and
    /// losing it beats refusing to launch.
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
            #expect(settings.tuning(for: descriptor.id).speed == 0.5)
            #expect(settings.tuning(for: descriptor.id).paletteIndex == 2)
        }
        #expect(settings.tuning(for: "bars").options["columns"] == 52.0)
        #expect(settings.tuning(for: "tunnel").options["twist"] == 2.5)
        // De-namespacing must not leak the old key through.
        #expect(settings.tuning(for: "bars").options["bars.columns"] == nil)
    }

    /// The migration is a fallback, not a merge: once anything has been saved
    /// under the current key, the legacy blob must never be consulted again.
    @Test func theNewKeyWinsOverTheLegacyOne() {
        let store = makeStore()
        store.set(["sensitivity": 1.8] as [String: Any], forKey: "VisualizerSettings")

        let first = VisualizerSettings(defaults: store)
        first.update("nebula") { $0.sensitivity = 3.0 }

        #expect(VisualizerSettings(defaults: store).tuning(for: "nebula").sensitivity == 3.0)
    }

    /// The first assertion is the load-bearing one. `tuning(for:)` returns an
    /// *empty* tuning for an unknown id while `reset` writes a fully populated
    /// one, and those only compare equal because `isDefault` normalizes first.
    /// Simplify `normalized(for:)` away and this line fails.
    ///
    /// The registry is iterated *inside* the test rather than through
    /// `@Test(arguments:)`, so a new visualizer is covered for free. The
    /// parameterized form can't be used: the arguments expression is evaluated
    /// outside the test's isolation, and `VisualizerRegistry.all` is
    /// main-actor isolated like everything else here.
    @Test func resetReturnsToDefaultForEveryVisualizer() {
        for descriptor in VisualizerRegistry.all {
            let id = descriptor.id
            let store = makeStore("\(#function).\(id)")
            let settings = VisualizerSettings(defaults: store)

            #expect(settings.isDefault(descriptor), "\(id): a fresh store should read as default")
            settings.update(id) { $0.speed = 2.2 }
            #expect(!settings.isDefault(descriptor), "\(id): a changed speed is not default")
            settings.reset(descriptor)
            #expect(settings.isDefault(descriptor), "\(id): reset should return to default")
        }
    }

    @Test func anUnsetOptionReadsAsItsDeclaredDefault() {
        let store = makeStore()
        let settings = VisualizerSettings(defaults: store)
        guard let bars = VisualizerRegistry.descriptor(id: "bars"),
            let columns = bars.options.first(where: { $0.id == "columns" })
        else {
            Issue.record("bars/columns is the fixture these tests are written against")
            return
        }

        #expect(settings.tuning(for: "bars").value(for: columns) == columns.defaultValue)
    }
}
