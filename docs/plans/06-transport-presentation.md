# Plan 6 — One source of truth for the transport vocabulary

**Deepening:** the menu and the chrome stop each deriving the same answers; both read one pure module.
**Strength:** worth exploring. **Branch:** one PR, independent of every other plan.

## Why

The menu bar and the on-canvas chrome are two consumers of the same state, and each computes
the user-facing answers itself. They have already drifted.

| Answer                  | Menu                                         | Chrome                                     | Third copy                      |
| ----------------------- | -------------------------------------------- | ------------------------------------------ | ------------------------------- |
| Capture button wording  | `SynesthiaApp.captureMenuTitle` :33–39       | `CaptureButton.helpText` :823–832          | `ControlsPod` demo item :727    |
| Current visualizer name | `SynesthiaApp` :22–24                        | `VisualizerPod` :907–909                   | —                               |
| "Control X…" offer      | `SynesthiaApp` :120–126                      | `ControlsPod` :704–707                     | —                               |
| Palette list            | `SynesthiaApp` :156–158                      | `PalettePicker` :1033                      | —                               |
| Reset-to-defaults       | `SynesthiaApp` :161–166                      | `OptionsPanel.header` :991–1000            | —                               |
| Source availability     | —                                            | `pickerSources`/`lockedSources` :659–672   | `WelcomeView.footnote` :146–173 |
| Permission naming       | `PrivacyPermission.title` (AudioSources :81) | `PermissionCard.title` :457–463            | —                               |
| `NSWorkspace.open`      | `SynesthiaApp.open` :26–29                   | `AppState.openPermissionSettings` :577–580 | —                               |

The drift is live: `"Pause File"` vs `"Pause file"`, `"Stop Listening"` vs
`"Stop listening"`. **That particular difference is correct and should stay** — macOS menu
items are Title Case, tooltips and accessibility labels are sentence case. The defect is
that the two are computed from independent switches, so a new source or a reworded state
has to be found in both places, and nothing fails if it isn't.

The same shape, worse, in availability: `AppState.isSourceAvailable` decides whether a
source can run, `ControlsPod` re-partitions the list around it, and `WelcomeView.footnote`
ignores both and reads `screenAudioGranted` / `microphoneStatus` directly. Three answers to
"can this source produce audio", one of which can disagree with the other two.

This is also the blocker for the string-catalog migration named in `CLAUDE.md` §Localization:
right now the user-facing wording lives in four files.

## Scope

```
Synesthia/TransportPresentation.swift    new — pure value type
Synesthia/AppState.swift                 exposes it; isSourceAvailable moves behind it
Synesthia/SynesthiaApp.swift             captureMenuTitle, currentVisualizerName → read it
Synesthia/ContentView.swift              CaptureButton, ControlsPod, VisualizerPod, PermissionCard
Synesthia/WelcomeView.swift              footnote(for:) moves out
Synesthia/Audio/AudioSources.swift       PrivacyPermission gains the card's action title
```

Out of scope: the Palette and Reset duplications. Those are two call sites of
`VisualizerSettings`, which is already a module with a fine interface — the "duplication" is
just two places choosing to offer the same command, which is normal for a menu plus a
popover. Leave them.

## Target design

One pure value type, built fresh wherever it's read. New file
`Synesthia/TransportPresentation.swift`:

```swift
import AVFoundation

/// Everything the menu bar and the canvas chrome need to *say* about the
/// current source, derived once.
///
/// This exists because there were two of everything. The menu computed the
/// capture item's title from `sourceKind` and the chrome computed the capture
/// button's tooltip from `sourceKind`, and they drifted — not in casing, which
/// is correct and deliberate (menu items are Title Case, tooltips are sentence
/// case), but in the fact that adding a source meant finding both switches.
/// Availability was worse: three independent derivations of "can this source
/// produce audio", one of which read the TCC flags directly and could disagree
/// with the other two.
///
/// Pure on purpose — no AppState, no AppKit, no UserDefaults — so every string
/// and every availability rule is assertable. `AppState.transport` builds it.
struct TransportPresentation {
    let sourceKind: AudioSourceKind
    /// Whether audio is flowing into the analyzer right now — CONTEXT.md, "Live".
    /// Fed from `AppState.isCaptureActive` today; plan 1 renames that property
    /// to `isLive`, so this field's name is correct whichever lands first.
    let isLive: Bool
    let screenAudioGranted: Bool
    let microphoneStatus: AVAuthorizationStatus

    // MARK: Capture control

    /// Title Case, for the Playback menu.
    var captureMenuTitle: String {
        switch sourceKind {
        case .demo: isLive ? "Pause Demo Track" : "Play Demo Track"
        case .audioFile: isLive ? "Pause File" : "Play File"
        case .systemAudio, .inputDevice: isLive ? "Stop Listening" : "Start Listening"
        }
    }

    /// Sentence case, for tooltips and accessibility labels.
    var captureHelp: String {
        switch sourceKind {
        case .demo: isLive ? "Pause demo track" : "Play demo track"
        case .audioFile: isLive ? "Pause file" : "Play file"
        case .systemAudio, .inputDevice: isLive ? "Stop listening" : "Start listening"
        }
    }

    /// Sources this app plays itself get transport glyphs; sources it listens
    /// to get the capture waveform.
    var captureSymbol: String {
        switch sourceKind {
        case .demo, .audioFile:
            isLive ? "pause.circle.fill" : "play.circle.fill"
        case .systemAudio, .inputDevice:
            isLive ? "waveform.circle.fill" : "waveform.circle"
        }
    }

    // MARK: Availability

    func isAvailable(_ kind: AudioSourceKind) -> Bool {
        switch kind {
        case .demo, .audioFile: true
        case .systemAudio: screenAudioGranted
        // .notDetermined stays available: selecting the source is what
        // triggers the system prompt.
        case .inputDevice: microphoneStatus != .denied && microphoneStatus != .restricted
        }
    }

    /// Selectable sources whose permission is granted or unneeded, plus
    /// whatever is active right now, so the checkmark always has a row.
    var pickerSources: [AudioSourceKind] {
        var kinds = AudioSourceKind.selectable.filter(isAvailable)
        if !kinds.contains(sourceKind) { kinds.insert(sourceKind, at: 0) }
        return kinds
    }

    var lockedSources: [AudioSourceKind] {
        AudioSourceKind.selectable.filter { !isAvailable($0) && $0 != sourceKind }
    }

    /// The permission line under a welcome-sheet source row: the cost before
    /// it's paid, the green seal after.
    func footnote(for kind: AudioSourceKind) -> PermissionFootnote? { … }
}

/// Moved out of WelcomeView so `footnote(for:)` can live beside the
/// availability rule it has to agree with.
struct PermissionFootnote {
    let text: String
    let symbol: String
    let ready: Bool
}
```

`AppState` gains one computed property and loses `isSourceAvailable`:

```swift
var transport: TransportPresentation {
    TransportPresentation(
        sourceKind: sourceKind,
        isLive: isLive,
        screenAudioGranted: screenAudioGranted,
        microphoneStatus: microphoneStatus)
}
```

Observation still works: a view body that reads `appState.transport.captureHelp` touches
`sourceKind`, `isDemoPlaying` and friends through the `@Observable` accessors while building
the value, so SwiftUI registers the same dependencies it does today.

`AppState.handleAppActivation` :609–617 currently calls `isSourceAvailable(sourceKind)` —
it becomes `transport.isAvailable(sourceKind)`. Same for `retryBlockedSource`.

Finally, `PrivacyPermission` (AudioSources.swift:74–118) absorbs the card's heading, which
`PermissionCard.title` hardcodes today:

```swift
/// The imperative form, for the explainer card's heading. `title` names the
/// permission as System Settings does; this asks for it.
var actionTitle: String {
    switch self {
    case .screenAndSystemAudio: "Allow System Audio Recording"
    case .automation: "Allow Control of Music"
    case .microphone: "Allow Microphone Access"
    }
}
```

## Steps

1. Add `TransportPresentation.swift` with the capture wording and availability, moving the
   bodies verbatim from `SynesthiaApp.captureMenuTitle`, `CaptureButton.helpText`,
   `CaptureButton.symbol`, `AppState.isSourceAvailable` and `ControlsPod.pickerSources` /
   `lockedSources`.
2. Move `PermissionFootnote` and `WelcomeView.footnote(for:)` across. `PermissionFootnote`
   is `private` in WelcomeView today, so it becomes internal.
3. Add `AppState.transport`; delete `AppState.isSourceAvailable` and update its two internal
   callers.
4. Point the six view sites at it. `ControlsPod` loses both computed properties;
   `CaptureButton` loses both.
5. Add `PrivacyPermission.actionTitle`; delete `PermissionCard.title` :457–463.
6. Fold the demo item in `ControlsPod` :727 into `captureMenuTitle` — it is the `.demo`
   case of the same switch, already written twice with identical strings.
7. Collapse the two `NSWorkspace.shared.open` wrappers: keep
   `AppState.openPermissionSettings` and have `SynesthiaApp` call a single small helper
   rather than its own private `open(_:)`. Cosmetic, but it is on the same list.

## Tests

New file `SynesthiaTests/TransportPresentationTests.swift`. This is the first UI-adjacent
behaviour in the suite that can be tested at all, so cover it properly:

```swift
private func presentation(
    _ kind: AudioSourceKind,
    active: Bool = false,
    screen: Bool = true,
    mic: AVAuthorizationStatus = .authorized
) -> TransportPresentation { … }

@Test func menuTitlesAreTitleCaseAndHelpIsSentenceCase() {
    let p = presentation(.audioFile, active: true)
    #expect(p.captureMenuTitle == "Pause File")
    #expect(p.captureHelp == "Pause file")
}

@Test(arguments: AudioSourceKind.allCases)
func everySourceHasWordingInBothStates(_ kind: AudioSourceKind) {
    for active in [true, false] {
        let p = presentation(kind, active: active)
        #expect(!p.captureMenuTitle.isEmpty)
        #expect(!p.captureHelp.isEmpty)
        #expect(p.captureMenuTitle.lowercased() == p.captureHelp.lowercased())
    }
}

@Test func deniedMicrophoneLocksTheInputSource() {
    let p = presentation(.systemAudio, mic: .denied)
    #expect(!p.isAvailable(.inputDevice))
    #expect(p.lockedSources.contains(.inputDevice))
    #expect(!p.pickerSources.contains(.inputDevice))
}

@Test func undeterminedMicrophoneStaysSelectable() {
    #expect(presentation(.systemAudio, mic: .notDetermined).isAvailable(.inputDevice))
}

@Test func theActiveSourceAlwaysHasARowEvenWhenRevoked() {
    let p = presentation(.systemAudio, screen: false)
    #expect(p.pickerSources.first == .systemAudio)
    #expect(!p.lockedSources.contains(.systemAudio))
}

@Test func pickerAndLockedArePartitions() {
    for screen in [true, false] {
        for mic in [AVAuthorizationStatus.authorized, .denied, .notDetermined] {
            let p = presentation(.demo, screen: screen, mic: mic)
            let all = Set(p.pickerSources).union(p.lockedSources)
            #expect(all.isSuperset(of: AudioSourceKind.selectable))
            #expect(Set(p.pickerSources).isDisjoint(with: p.lockedSources))
        }
    }
}

@Test func footnoteAgreesWithAvailability() {
    for screen in [true, false] {
        let p = presentation(.demo, screen: screen)
        #expect(p.footnote(for: .systemAudio)?.ready == p.isAvailable(.systemAudio))
    }
}
```

The last one is the test that matters — it is the assertion the three independent
derivations could never make.

`captureMenuTitle.lowercased() == captureHelp.lowercased()` pins the casing convention
without freezing the wording: the two may differ in case and must not differ in words.

## Risks

- **Do not "fix" the casing to match.** Title Case in menus is the macOS convention and
  changing it is a visible regression. The test above encodes the rule.
- `AudioSourceKind.allCases` includes `.demo`, which is deliberately not in `.selectable`
  (AudioSources.swift:36–38). Keep the partition test scoped to `.selectable`.
- Views must build `appState.transport` _inside_ `body`, not cache it in a `let` outside —
  a stored copy would freeze the observation dependencies.
- `PermissionFootnote` becoming internal makes it visible to `@testable import`; that's the
  point, but check `make lint --strict` doesn't complain about the access level.

## Verification

```
make format && make healthcheck
```

Then `make run` and walk: the Playback menu's capture item in all four sources, the capture
button tooltip, the source picker with a revoked permission, and the welcome sheet's
footnotes. `make screenshots` exercises the chrome but not the menus.
