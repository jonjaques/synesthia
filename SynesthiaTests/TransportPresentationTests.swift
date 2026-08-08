import AVFoundation
import Foundation
import Testing

@testable import Synesthia

/// Tests for the user-facing vocabulary the menu bar and the canvas chrome
/// share.
///
/// This is the first UI-adjacent behaviour in the suite that can be asserted at
/// all, and the reason it can is that `TransportPresentation` is pure. The
/// assertions worth having are the *agreements* — that the menu and the tooltip
/// say the same words, that the picker and the welcome sheet agree on what a
/// source can do — because those are exactly what three independent switches
/// could never guarantee.
@MainActor
struct TransportPresentationTests {

    private func presentation(
        _ kind: AudioSourceKind,
        live: Bool = false,
        screen: Bool = true,
        mic: AVAuthorizationStatus = .authorized
    ) -> TransportPresentation {
        TransportPresentation(
            sourceKind: kind,
            isLive: live,
            screenAudioGranted: screen,
            microphoneStatus: mic,
            visualizerID: VisualizerRegistry.all[0].id)
    }

    // MARK: - Wording

    @Test func menuIsTitleCaseAndHelpIsSentenceCase() {
        let p = presentation(.audioFile, live: true)
        #expect(p.captureMenuTitle == "Pause File")
        #expect(p.captureHelp == "Pause file")
    }

    /// The casing difference is the macOS convention and must stay; the *words*
    /// must not diverge. Pinning it this way lets either string be reworded, so
    /// long as both are.
    @Test func menuTitleAndHelpDifferOnlyInCase() {
        for kind in AudioSourceKind.allCases {
            for live in [true, false] {
                let p = presentation(kind, live: live)
                #expect(!p.captureMenuTitle.isEmpty, "\(kind) live=\(live)")
                #expect(!p.captureHelp.isEmpty, "\(kind) live=\(live)")
                #expect(
                    p.captureMenuTitle.lowercased() == p.captureHelp.lowercased(),
                    "\(kind) live=\(live): \"\(p.captureMenuTitle)\" vs \"\(p.captureHelp)\"")
            }
        }
    }

    /// Sources the app plays get transport glyphs; sources it listens to get
    /// the waveform. Every state has to name a symbol — an empty one is an
    /// invisible button, not a build error.
    @Test func everyStateNamesACaptureSymbol() {
        for kind in AudioSourceKind.allCases {
            for live in [true, false] {
                let p = presentation(kind, live: live)
                #expect(!p.captureSymbol.isEmpty, "\(kind) live=\(live)")
                let played = kind == .demo || kind == .audioFile
                #expect(
                    p.captureSymbol.hasPrefix(played ? (live ? "pause" : "play") : "waveform"),
                    "\(kind) live=\(live) got \(p.captureSymbol)")
            }
        }
    }

    @Test func anUnknownVisualizerIDStillNamesSomething() {
        let p = TransportPresentation(
            sourceKind: .demo, isLive: false, screenAudioGranted: true,
            microphoneStatus: .authorized, visualizerID: "retired-in-a-past-version")
        #expect(p.visualizerName == "Visualizer")
    }

    // MARK: - Availability

    @Test func deniedMicrophoneLocksTheInputSource() {
        let p = presentation(.systemAudio, mic: .denied)
        #expect(!p.isAvailable(.inputDevice))
        #expect(p.lockedSources.contains(.inputDevice))
        #expect(!p.pickerSources.contains(.inputDevice))
    }

    /// Selecting the source is what raises the system prompt, so an
    /// undetermined mic must stay pickable — locking it would make the
    /// permission unreachable from the picker.
    @Test func undeterminedMicrophoneStaysSelectable() {
        #expect(presentation(.systemAudio, mic: .notDetermined).isAvailable(.inputDevice))
    }

    /// Revoking a permission while its source is active must not remove the
    /// row, or the picker would show a checkmark against nothing.
    @Test func theActiveSourceAlwaysHasARowEvenWhenRevoked() {
        let p = presentation(.systemAudio, screen: false)
        #expect(p.pickerSources.first == .systemAudio)
        #expect(!p.lockedSources.contains(.systemAudio))
    }

    /// `.demo` is deliberately not in `.selectable` (it lives in the welcome
    /// sheet and the Help menu), so the partition is asserted over
    /// `.selectable` and the active source may add one extra row on top.
    @Test func pickerAndLockedPartitionTheSelectableSources() {
        for screen in [true, false] {
            for mic in [AVAuthorizationStatus.authorized, .denied, .notDetermined] {
                let p = presentation(.demo, screen: screen, mic: mic)
                let all = Set(p.pickerSources).union(p.lockedSources)
                #expect(all.isSuperset(of: AudioSourceKind.selectable), "screen=\(screen) mic=\(mic)")
                #expect(
                    Set(p.pickerSources).isDisjoint(with: p.lockedSources),
                    "screen=\(screen) mic=\(mic)")
            }
        }
    }

    /// The assertion the three independent derivations could never make: the
    /// welcome sheet's promise and the picker's availability are the same
    /// answer. Scoped to system audio, where the permission is binary — see
    /// `footnote(for:)` on why an undetermined mic is available but not ready.
    @Test func footnoteAgreesWithAvailability() {
        for screen in [true, false] {
            let p = presentation(.demo, screen: screen)
            #expect(p.footnote(for: .systemAudio)?.ready == p.isAvailable(.systemAudio))
        }
    }

    @Test func everySelectableSourceExplainsItsCost() {
        let p = presentation(.demo)
        for kind in AudioSourceKind.selectable {
            let footnote = p.footnote(for: kind)
            #expect(footnote != nil, "\(kind) has no footnote")
            #expect(!(footnote?.text.isEmpty ?? true), "\(kind) has an empty footnote")
        }
        // The demo isn't offered as a source, so it has nothing to disclose.
        #expect(p.footnote(for: .demo) == nil)
    }
}
