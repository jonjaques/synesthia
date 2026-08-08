# Plan 1–3 — The audio seam, the playback policy, and the frame composer

One session, one branch, three checkpoint commits. These are grouped because 2 depends on 1
and both rewrite the same regions of `AppState.swift`; 3 shares no files with either and is
the escape hatch if the session runs long.

| Part | Deepening                                        | Files                                              |
| ---- | ------------------------------------------------ | -------------------------------------------------- |
| 1    | One `AudioSource` interface over four engines    | `Audio/AudioSources.swift`, `AppState.swift`       |
| 2    | `PlaybackPolicy` — the decisions, extracted pure | `AppState.swift`, new `PlaybackPolicy.swift`       |
| 3    | `FrameComposer` + `RenderScaleLadder`            | `Visualizers/MetalVisualizerView.swift`, new files |

**Recommended order: 1 → 2 → 3.** Commit after each. Part 3 touches only the render loop, so
it can be pulled forward, deferred, or split into its own PR at any point without conflict.

---

## Before you start

**The Debug bundle-merge trap will bite you in this session.** `make test` builds the
`Synesthia` scheme and `make build-direct` builds `Synesthia Direct`, both into
`Build/Products/Debug/Synesthia.app`. Alternating them merges the two bundles and produces
an app that dyld kills at launch with `Library not loaded: @rpath/Sparkle.framework` — no
source change causes it and none can fix it (`CLAUDE.md` §Build configurations). `make
healthcheck` runs exactly that alternation. So:

```
make healthcheck        # fine
make clean && make run  # ← always clean before launching, after a healthcheck
```

Other session notes:

- There are **no formatting hooks in this repo** (no `.claude/settings.json`), so run
  `make format` yourself before every commit; `make lint` uses `--strict`, where plain
  indentation is an error.
- New `.swift` files anywhere under `Synesthia/` compile into both targets automatically —
  **never hand-edit `project.pbxproj`** to add a file.
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and `SWIFT_VERSION = 6.0`: every new type is
  main-actor isolated unless marked `nonisolated`, and violations are errors. All three new
  modules here are main-actor, which is correct — they are driven from `AppState` and the
  render loop. Do not add `@MainActor`; it is redundant.

---

# Part 1 — One interface over the four capture engines

## Why

`SystemAudioCapture`, `InputDeviceCapture` and `FilePlayer` (AudioSources.swift:163, :354,
:414) share only "takes an `AudioAnalyzer` in `init`". Three `start` shapes, three `stop`
shapes, two names for "running", and only one of them can report that it died.

So `AppState` doesn't read their state — it maintains three shadow copies and syncs them by
hand at eight sites (:406, :451, :651, :672, :744–746, :770, :780). The file says why:

```swift
// AppState.swift:107
/// Mirrors `FilePlayer.isPlaying`; the player isn't observable on its own.
private(set) var isFilePlaying = false { didSet { refreshPowerAssertion() } }
```

Consequences visible in the code today:

- `isCaptureActive` (:247–253) re-implements a fact each engine already owns.
- `handleSourceChange` (:738) stops **every** engine unconditionally, with a comment saying
  that's "simpler and safer than tracking which one was running" — which it is, given there
  is no way to ask.
- `InputDeviceCapture` has no equivalent of `SystemAudioCapture.onExternalStop` (:173), so
  unplugging a USB interface leaves `isCapturing == true` forever, the power assertion held,
  and the canvas frozen. That is a live bug, and the interface is where it gets fixed.

## Target design

Add to `AudioSources.swift`, above `SystemAudioCapture`:

```swift
/// One place audio can come from, as the app drives it.
///
/// The three engines underneath are genuinely different — ScreenCaptureKit,
/// AVAudioEngine's input node, an AVAudioPlayerNode graph — but `AppState`
/// only ever needs to start one, stop it, ask whether it is running, and hear
/// about it dying on its own. Before this existed, "is it running" was
/// answered by three booleans on `AppState` that were kept in step by hand,
/// and only one engine could report an external stop at all.
protocol AudioSource: AnyObject {
    var isRunning: Bool { get }
    /// Fired when the source stopped without being asked to — permission
    /// revoked, display reconfigured, interface unplugged. Never for a normal
    /// `stop()`.
    var onStopped: (() -> Void)? { get set }

    func start() async throws
    func stop() async
}

/// Sources this app plays itself, which can therefore be sent back to the top.
/// Separate from `AudioSource` because "previous track" means nothing to a
/// microphone.
protocol RestartableSource: AudioSource {
    func restart() throws
}
```

A synchronous method satisfies an `async` requirement in Swift, so `InputDeviceCapture.stop()`
and the file source's conformance need no signature churn.

**Per-engine changes:**

`SystemAudioCapture` — rename `onExternalStop` → `onStopped`, declare conformance. Nothing
else; it already has the exact shape.

`InputDeviceCapture` — the device id moves from the call to the engine, which matches the
comment already at AppState.swift:88–89 ("the engine itself only reads the ID at start"):

```swift
final class InputDeviceCapture: AudioSource {
    /// Which device to open. Read at `start`; changing it while running has no
    /// effect until the next start, which is why `AppState` restarts.
    var deviceID: AudioDeviceID?
    var onStopped: (() -> Void)?

    func start() async throws { … existing body, reading self.deviceID … }
}
```

and it gains the external-stop detection it never had:

```swift
// in start(), after engine.start():
configurationObserver = NotificationCenter.default.addObserver(
    forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
) { [weak self] _ in
    // The device went away (unplugged, or switched by the system). The engine
    // stays nominally alive but no buffers arrive, so without this the app
    // holds the display awake and renders a frozen canvas forever.
    guard let self, self.isRunning else { return }
    self.stop()
    self.onStopped?()
}
```

Remove the observer in `stop()`. This is the **one behaviour change in part 1** — call it out
in the PR description.

`FilePlayer` → **`FileSource`** — two renames, and the second one is easy to get wrong.

The type rename comes from `CONTEXT.md`: **Player** means an external media app (Music,
Spotify) and nothing else, so the app's own playback of a file is a Source. `demoPlayer` →
`demoSource`, `filePlayer` → `fileSource`, `restartCurrentPlayer` → `restartCurrentSource`.
That is cosmetic and the compiler finds every site.

The method rename is not cosmetic. `FilePlayer.stop()` (:474) clears the scheduled queue;
`AppState` uses `pause()` (:742) when switching sources so the position survives. If the type
conforms to `AudioSource` as-is, its existing `stop()` silently becomes the protocol witness
and every source switch starts discarding the queue — no compile error, no test failure. So:

```swift
/// Was `stop()`. Renamed when `AudioSource` arrived: the interface's `stop()`
/// means "stop producing audio", which for a file source is `pause()` — the
/// queue-clearing behaviour is a different thing and only `load` and `restart`
/// want it.
private func clearQueue() { … }   // was stop(); internal callers: load(url:) :439, restart() :488

extension FileSource: RestartableSource {
    var isRunning: Bool { isPlaying }
    func start() async throws { try play() }
    func stop() async { pause() }
}
```

`onStopped` needs storage, so declare `var onStopped: (() -> Void)?` on each class body
rather than in an extension.

**`AppState` changes:**

```swift
/// The one remaining place the source taxonomy is spelled out.
private func source(for kind: AudioSourceKind) -> any AudioSource {
    switch kind {
    case .demo: demoSource
    case .systemAudio: systemCapture
    case .inputDevice: inputCapture
    case .audioFile: fileSource
    }
}

private var activeSource: any AudioSource { source(for: sourceKind) }
private var allSources: [any AudioSource] { AudioSourceKind.allCases.map(source(for:)) }
```

The three shadow booleans collapse to one republished mirror:

```swift
/// Whether audio is flowing into the analyzer right now — true both for the
/// sources the app plays itself and the ones it listens to (see CONTEXT.md,
/// "Live"). Mirrors `activeSource.isRunning` for SwiftUI: the engines are not
/// `@Observable` — `SystemAudioCapture` is an `NSObject` SCK delegate, and the
/// macro on an NSObject subclass is a fight not worth having — so the single
/// fact the UI needs is republished here, from exactly one place instead of
/// three properties synced at eight call sites.
private(set) var isLive = false { didSet { refreshPowerAssertion() } }

private func syncLiveState() { isLive = activeSource.isRunning }
```

`isCaptureActive` → `isLive` and `toggleCapture()` → `toggleSource()` come from `CONTEXT.md`:
"capture" describes only half of what the four Sources do, and reads wrong for the Demo
Track. The user-facing wording is unaffected — it was already per-source ("Play Demo Track",
"Start Listening") and plan 6 owns it.

Wire `onStopped` for all four in `init`, replacing the single `systemCapture.onExternalStop`
line at :174:

```swift
for kind in AudioSourceKind.allCases {
    source(for: kind).onStopped = { [weak self] in self?.handleSourceStopped(kind) }
}
```

## What this actually removes

Be precise about the win — three of the six `switch sourceKind` blocks go in part 1:

| Site                            | Fate in part 1                                                           |
| ------------------------------- | ------------------------------------------------------------------------ |
| `isCaptureActive` :247–253      | **deleted** — replaced by the `isLive` mirror                            |
| `isPlaying` :234–244            | **collapses** to one condition (below)                                   |
| `restartCurrentPlayer` :447–458 | **deleted** — `(activeSource as? any RestartableSource)?.restart()`      |
| `handleCaptureToggle` :368–414  | **mostly collapses**; the per-source failure handling stays until part 2 |
| `onAppear` :221–228             | stays → part 2                                                           |
| `handleSourceChange` :751–772   | stays → part 2                                                           |
| —                               | one new `source(for:)` switch, which is the point                        |

```swift
var isPlaying: Bool {
    // Once transport is on screen the buttons drive the *Player*, so they have
    // to show the Player's state, not ours.
    if sourceKind == .systemAudio, showsTransport { return detectedTrack?.isPlaying ?? false }
    return isLive
}
```

Note `isPlaying` now means exactly one thing — the external Player's state — everywhere
transport is on screen, and `isLive` covers the rest. Those were the two senses tangled
together in the old four-case switch.

## Steps

1. Add both protocols to `AudioSources.swift`.
2. Conform `SystemAudioCapture` (rename `onExternalStop` → `onStopped`).
3. Conform `InputDeviceCapture`: add `deviceID` and `onStopped`, drop the `start` parameter,
   add the configuration-change observer.
4. Rename the type `FilePlayer` → `FileSource` and its properties `filePlayer`/`demoPlayer`
   → `fileSource`/`demoSource` (compiler-guided, cosmetic).
5. Rename `FileSource.stop()` → `clearQueue()`, fix its two internal callers, add the
   `RestartableSource` conformance. **Grep for `filePlayer.stop`/`demoPlayer.stop` first** —
   there should be none in `AppState` today, and if there is, it wanted `pause`.
6. In `AppState`: add `source(for:)`, `activeSource`, `allSources`, `isLive`,
   `syncLiveState()`; delete `isCapturing`, `isFilePlaying`, `isDemoPlaying`; rename
   `toggleCapture()` → `toggleSource()` and `restartCurrentPlayer()` →
   `restartCurrentSource()`.
7. Rewrite the four sites in the table. Route every start/stop through `activeSource` and
   follow each with `syncLiveState()`.
8. Fix the external readers: `ContentView.swift:727` (`isDemoPlaying`), `AppState.nowPlaying`
   :319, `selectedInputDeviceID.didSet` :92, `handlePlay` :352.
9. `make clean && make run`. Exercise all four sources, switch between them, pause and resume
   the file source and confirm the position survives the switch.

## Tests

Part 1's payoff is the second adapter, which part 2 consumes. Add the fake now:

```swift
// SynesthiaTests/FakeAudioSource.swift
final class FakeAudioSource: RestartableSource {
    var isRunning = false
    var onStopped: (() -> Void)?
    var startError: Error?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var restartCount = 0

    func start() async throws {
        startCount += 1
        if let startError { throw startError }
        isRunning = true
    }
    func stop() async { stopCount += 1; isRunning = false }
    func restart() throws { restartCount += 1 }
    /// Simulates the interface being unplugged / the permission being revoked.
    func die() { isRunning = false; onStopped?() }
}
```

Two adapters justify the seam: the real engines in the app, this one in the suite.

---

# Part 2 — Extract the decisions into `PlaybackPolicy`

## Why

`AppState` is 829 lines and ten concerns, and every decision worth testing is welded to an
effect. `handleAppActivation` (:609–617) is four lines of policy wrapped around
`CGPreflightScreenCaptureAccess()`. The 350 ms retry (:790–794) is three lines of policy
inside a `catch` that also calls ScreenCaptureKit. `private init()` plus `static let shared`
means no test can build a second instance to try any of it. **Zero tests reference
`AppState`.**

## Approach: six extractions, not one state machine

Do **not** rewrite this as an event/effect state machine in one sitting — it is the highest-risk
change in the repo and the first-run path is App Review-critical. Extract the decisions one at
a time into a pure value type, each with its test, each independently revertable.

New file `Synesthia/PlaybackPolicy.swift`:

```swift
/// The decisions `AppState` makes, without the effects it makes them for.
///
/// Everything here is a function of the values passed in — no UserDefaults, no
/// TCC query, no AppKit, no engine. `AppState` builds one, asks it, and
/// performs the answer. That split is the whole point: the retry rule, the
/// first-run sequence and the permission gating are the parts that break, and
/// before this they could only be exercised by running the app and revoking a
/// permission by hand.
struct PlaybackPolicy {
    let sourceKind: AudioSourceKind
    let isLive: Bool
    let screenAudioGranted: Bool
    let microphoneStatus: AVAuthorizationStatus
    let blockedPermission: PrivacyPermission?
    let hasFile: Bool
}
```

Extract in this order — each row is a commit-sized change:

| #   | Decision                     | Moves from            | Returns                                                                 |
| --- | ---------------------------- | --------------------- | ----------------------------------------------------------------------- |
| 1   | `migrated(_:)`               | :187–189              | already pure — just make it internal and test it                        |
| 2   | `startFailure(for:isRetry:)` | :784–798 and :388–395 | `.blocked(PrivacyPermission)` / `.retryQuietly` / `.banner(String)`     |
| 3   | `activationAction()`         | :609–617, :620–624    | `.retryCapture` / `.doNothing`                                          |
| 4   | `startupAction()`            | :220–228              | `.start` / `.waitForWelcome` / `.doNothing`                             |
| 5   | `bringUpAction()`            | :751–772              | `.start` / `.refreshDevices` / `.loadAndPlayFile` / `.doNothing`        |
| 6   | `welcomeResolution(chose:)`  | :548–558, :564–570    | `.startDemo` / `.switchSource(kind)` / `.bringUpCurrent` / `.doNothing` |

`#2` is the highest-value one:

```swift
enum StartFailure {
    /// Missing permission isn't transient: the explainer card, not a banner.
    case blocked(PrivacyPermission)
    /// A freshly granted permission can fail its first attempt (see CLAUDE.md).
    case retryQuietly
    case banner(String)
}

func startFailure(for error: Error, isRetry: Bool) -> StartFailure {
    if case AudioSourceError.microphoneDenied = error { return .blocked(.microphone) }
    if sourceKind == .systemAudio, !screenAudioGranted { return .blocked(.screenAndSystemAudio) }
    if sourceKind == .systemAudio, !isRetry { return .retryQuietly }
    return .banner(error.localizedDescription)
}
```

`#6` is the App Review one. `CLAUDE.md` states the contract — _"the App Review path is
Continue, not launch"_, and `WelcomeView.SourceRow` must call `selectSource` **before**
`completeWelcome` or the demo starts and is immediately torn down. That rule has never had a
test and `docs/app-store-metadata.md` depends on it staying true.

Callers become, e.g.:

```swift
func handleAppActivation() {
    refreshPermissions()
    if case .retryCapture = policy.activationAction() { toggleSource() }
}
```

`AppState.shared` and `private init` **stay**. Part 2 does not make `AppState` constructible —
it makes `AppState` thin enough that not constructing it stops mattering. (Plan 8 removes the
`UserDefaults.standard` reach; land that first if you can.)

## Tests

New `SynesthiaTests/PlaybackPolicyTests.swift`, one section per extraction:

```swift
@Test func retiredMusicAppSourceLandsOnSystemAudio() {
    #expect(AppState.migrated("musicApp") == AudioSourceKind.systemAudio.rawValue)
    #expect(AppState.migrated("inputDevice") == "inputDevice")
}

@Test func aMissingScreenPermissionBlocksRatherThanRetrying() {
    let policy = PlaybackPolicy(sourceKind: .systemAudio, screenAudioGranted: false, …)
    guard case .blocked(.screenAndSystemAudio) = policy.startFailure(for: SomeError(), isRetry: false)
    else { return #expect(Bool(false), "should block") }
}

@Test func aGrantedPermissionRetriesExactlyOnce() {
    let policy = PlaybackPolicy(sourceKind: .systemAudio, screenAudioGranted: true, …)
    guard case .retryQuietly = policy.startFailure(for: SomeError(), isRetry: false) else { … }
    guard case .banner = policy.startFailure(for: SomeError(), isRetry: true) else { … }
}

@Test func continueWithoutChoosingASourceStartsTheDemo() {
    // The App Review path: grants nothing, must still see it work.
    // docs/app-store-metadata.md depends on this staying true.
    let policy = PlaybackPolicy(sourceKind: .demo, …)
    #expect(policy.welcomeResolution(chose: nil) == .startDemo)
}

@Test func choosingASourceRetiresTheDemo() {
    #expect(policy.welcomeResolution(chose: .systemAudio) == .switchSource(.systemAudio))
}

@Test func activationRetriesOnlyTheBlockedSourceOnceItIsAllowed() {
    let stillBlocked = PlaybackPolicy(sourceKind: .systemAudio, screenAudioGranted: false,
        blockedPermission: .screenAndSystemAudio, isLive: false, …)
    #expect(stillBlocked.activationAction() == .doNothing)

    let nowAllowed = PlaybackPolicy(sourceKind: .systemAudio, screenAudioGranted: true,
        blockedPermission: .screenAndSystemAudio, isLive: false, …)
    #expect(nowAllowed.activationAction() == .retryCapture)

    // A microphone denial must not make the system-audio source retry.
    let wrongPermission = PlaybackPolicy(sourceKind: .systemAudio, screenAudioGranted: true,
        blockedPermission: .microphone, isLive: false, …)
    #expect(wrongPermission.activationAction() == .doNothing)
}
```

Make the result enums `Equatable` so `#expect(==)` works; that is the whole reason to prefer
enums over closures here.

## Risks

- **The first-run sequence is the one that must not regress.** After part 2, manually verify:
  delete the app container (`~/Library/Containers/com.jonjaques.Synesthia.debug`), launch,
  click **Continue** without choosing anything, confirm the demo starts. Then repeat and click
  a source row instead, confirming the demo does _not_ start and then get torn down.
- `blockedPermission` is both an input to the policy and an output of applying it. Keep it a
  stored property on `AppState` that the policy only reads.
- Don't let `PlaybackPolicy` grow a reference to `AppState`. If a decision needs a value, add
  a field.

---

# Part 3 — `FrameComposer` and `RenderScaleLadder`

Fully independent of parts 1 and 2 — different files, no shared symbols.

## Why

`applyFrameState` (MetalVisualizerView.swift:329–354), `applyReduceMotionIfNeeded` (:367–385)
and `adaptResolution` (:283–298) are arithmetic over scalars. All three are `private` methods
on a `Coordinator` whose only initializer is `init(appState:context:)` (:118) — so reaching
them costs a live `MTLDevice` _and_ the `AppState` singleton, which builds four engines and
starts the notification observers. `GPUFrameTimer` (:394) is file-private, so `@testable
import` can't reach it either.

Nothing in the suite mentions `Coordinator`, `MetalVisualizerView` or `GPUFrameTimer`.
`VizUniformsTests` pins the byte _layout_; nothing pins the _values_.

## Target design

New `Synesthia/Visualizers/FrameComposer.swift`:

```swift
/// Turns one `AudioSnapshot` plus one `VisualizerTuning` into the
/// `VizUniforms` a visualizer is handed, and owns the small amount of state
/// that takes: last frame's envelopes, the beat and frame counters, and the
/// Reduce Motion smoother.
///
/// Takes `time`, `dt` and `sinceBuild` as values rather than reading a clock,
/// so it is deterministic and the `CACurrentMediaTime()` calls stay in the
/// coordinator where the frame loop is.
struct FrameComposer {
    private var previousBeat: Float = 0
    private var previousTrebleBeat: Float = 0
    private var beatCount: Float = 0
    private var frameCount: Float = 0
    private var smoothed = SIMD4<Float>(repeating: 0)

    static let introDuration: Float = 0.7

    /// Called when the visualizer is rebuilt: counters keep running, the
    /// smoother restarts so a new visualizer doesn't inherit the old one's
    /// level.
    mutating func visualizerChanged() { smoothed = .zero }

    mutating func compose(
        snapshot: AudioSnapshot,
        tuning: VisualizerTuning,
        descriptor: VisualizerDescriptor,
        resolution: SIMD2<Float>,
        time: Float,
        dt: Float,
        sinceBuild: Float,
        reduceMotion: Bool
    ) -> VizUniforms
}
```

The body is the existing :206–232 assignment block, then `applyFrameState`'s content, then
`applyReduceMotionIfNeeded`'s — moved verbatim. While moving, add the comment that is missing
today:

```swift
// `components[1]`, `[3]` and `[6]` have no uniform of their own; the eight
// analyzer bands are deliberately narrowed to the five the shaders use.
// Changing this mapping changes every visualizer, so it is written out rather
// than looped.
uniforms.subBass = snapshot.components[0]
uniforms.lowMid = snapshot.components[2]
…
```

New `Synesthia/Visualizers/RenderScaleLadder.swift`:

```swift
/// The adaptive-resolution decision, on its own. Discrete rungs with
/// hysteresis: over 85% of the frame budget steps down, a *predicted* cost
/// under 60% steps back up. The 85/60 gap is what keeps the scale from
/// ping-ponging at a boundary.
struct RenderScaleLadder {
    static let scales: [CGFloat] = [0.5, 0.625, 0.75, 0.875, 1.0]
    private(set) var index = scales.count - 1
    var scale: CGFloat { Self.scales[index] }

    mutating func reset() { index = Self.scales.count - 1 }

    mutating func adjust(averageGPUTime average: Double, budget: Double) {
        if average > budget * 0.85, index > 0 {
            index -= 1
        } else if index < Self.scales.count - 1 {
            let growth = Self.scales[index + 1] / Self.scales[index]
            if average * Double(growth * growth) < budget * 0.6 { index += 1 }
        }
    }
}
```

`GPUFrameTimer` moves to the same file and loses `private` at file scope so tests can reach
it. Keep it `nonisolated final class … @unchecked Sendable` with the `NSLock` — it is written
from Metal's completion thread.

The `Coordinator` keeps `attach`, `updatePauseState`, `updateFrameRate`, `updateDrawableSize`,
the visualizer rebuild, and the command-buffer plumbing. Its `draw` shrinks to roughly:

```swift
let now = CACurrentMediaTime()
let dt = Float(min(max(now - lastFrameTime, 0), 0.1))
lastFrameTime = now

if let average = gpuTimer.drain(minimumSamples: 10), now - lastScaleCheck >= 0.5 {
    lastScaleCheck = now
    ladder.adjust(averageGPUTime: average, budget: 1.0 / Double(max(view.preferredFramesPerSecond, 1)))
}

let uniforms = composer.compose(
    snapshot: appState.analyzer.latest(),
    tuning: appState.settings.tuning(for: wantedID),
    descriptor: descriptor,
    resolution: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
    time: Float(now - startTime), dt: dt,
    sinceBuild: Float(now - visualizerBuiltAt),
    reduceMotion: reduceMotion)
```

## Steps

1. Add `RenderScaleLadder.swift`, move `GPUFrameTimer` into it, replace `adaptResolution` and
   `renderScaleIndex`. Verify `updateDrawableSize` now reads `ladder.scale`.
2. Add `FrameComposer.swift`, move the three blocks verbatim, replace the call sites.
3. Confirm the guard order in `draw` is unchanged — `adaptResolution` runs _before_
   `updateDrawableSize`, and both before the `drawableSize > 0` check.
4. `make clean && make run`; watch all four visualizers; toggle System Settings ▸ Accessibility
   ▸ Display ▸ Reduce Motion while running.

## Tests

New `SynesthiaTests/FrameComposerTests.swift`:

```swift
@Test func aSustainedEnvelopeFiresExactlyOneBeatHit() {
    var composer = FrameComposer()
    var hits = 0
    // Envelope jumps to 0.9 and then decays slowly — one kick, not thirty.
    for value in [Float(0.0)] + stride(from: 0.9, to: 0.3, by: -0.02).map(Float.init) {
        if compose(&composer, beat: value).beatHit == 1 { hits += 1 }
    }
    #expect(hits == 1)
}

@Test func wobbleBelowTheThresholdDoesNotFire() {
    // The envelopes wobble while decaying; the +0.25 threshold exists for this.
    var composer = FrameComposer()
    _ = compose(&composer, beat: 0.5)
    #expect(compose(&composer, beat: 0.6).beatHit == 0)
}

@Test func beatCountWrapsInsideExactFloatIntegers() { … 1_048_576 … }

@Test func reduceMotionDampsTheTransientsAndHalvesSpeed() {
    let plain = compose(reduceMotion: false, speed: 1.0, beat: 0.8)
    let calm = compose(reduceMotion: true, speed: 1.0, beat: 0.8)
    #expect(calm.speed == plain.speed * 0.5)
    #expect(calm.beat == plain.beat * 0.25)
    #expect(calm.reduceMotion == 1)
}

@Test func reduceMotionSmoothingIsFrameRateIndependent() {
    // One-pole smoothing over the same wall time must land in the same place
    // at 60 and 120 fps — the reason it is written as 1 - exp(-dt/0.4).
    var slow = FrameComposer(), fast = FrameComposer()
    for _ in 0..<60 { _ = compose(&slow, dt: 1.0 / 60, level: 1.0, reduceMotion: true) }
    for _ in 0..<120 { _ = compose(&fast, dt: 1.0 / 120, level: 1.0, reduceMotion: true) }
    #expect(abs(lastLevel(slow) - lastLevel(fast)) < 0.01)
}

@Test func introRampsZeroToOneAcrossTheBuildWindow() { … }

@Test func optionSlotsReachTheUniforms() {
    // Guards the descriptor→p[] mapping VizUniformsTests can only pin
    // structurally.
    let u = compose(descriptor: BarsVisualizer.descriptor, tuning: tuningWithColumns(52))
    #expect(u.p0 == 52)
}
```

and `SynesthiaTests/RenderScaleLadderTests.swift`:

```swift
@Test func overBudgetStepsDown() {
    var ladder = RenderScaleLadder()
    ladder.adjust(averageGPUTime: 0.9 * budget, budget: budget)
    #expect(ladder.scale < 1.0)
}

@Test func theHysteresisGapHoldsTheCurrentRung() {
    // Between 60% and 85% nothing moves — that gap is why the scale doesn't
    // ping-pong at a boundary.
    var ladder = RenderScaleLadder()
    ladder.adjust(averageGPUTime: 0.9 * budget, budget: budget)
    let held = ladder.scale
    ladder.adjust(averageGPUTime: 0.7 * budget, budget: budget)
    #expect(ladder.scale == held)
}

@Test func itClampsAtBothEnds() { … 20 iterations each way … }

@Test func theTimerIgnoresZeroSamplesAndHonoursTheMinimum() {
    let timer = GPUFrameTimer()
    timer.record(0)                       // a failed command buffer reports zero
    #expect(timer.drain(minimumSamples: 1) == nil)
}
```

## Risks

- **Moving code, not changing it.** Every constant (0.25, 0.30, 0.85, 0.60, 0.4 s, 0.7 s,
  1_048_576) must survive verbatim. Diff the moved blocks against the original before
  committing.
- `applyReduceMotionIfNeeded` currently mutates `uniforms.speed` and `sensitivity` _after_
  they were set from the tuning and _after_ `applyFrameState`. Preserve that order — Bars
  reads `u.sensitivity` in its CPU simulation (BarsVisualizer.swift:149) and depends on
  getting the damped copy.
- `smoothed` is currently never reset on a visualizer switch. `visualizerChanged()` above
  **adds** that reset; if you'd rather keep behaviour byte-identical, drop the method and
  note it. Either is defensible — just don't do it by accident.

---

## Session checklist

```
# after part 1
make format && make test && make clean && make run

# after part 2  — and delete the container to test first run
rm -rf ~/Library/Containers/com.jonjaques.Synesthia.debug
make clean && make run

# after part 3
make format && make healthcheck
make clean && make run
```

PR description should name, explicitly: the `InputDeviceCapture` external-stop detection
(new behaviour), the `FileSource.stop()` → `clearQueue()` rename (silent-breakage risk if
reviewed carelessly), and whether `smoothed` now resets on a visualizer switch.
