import AVFoundation
import Foundation
import Testing

@testable import Synesthia

/// Tests for the decisions `AppState` used to make in the middle of making
/// their effects.
///
/// None of this was reachable before. `handleAppActivation` was four lines of
/// policy wrapped around `CGPreflightScreenCaptureAccess()`; the 350 ms retry
/// was three lines inside a `catch` that also called ScreenCaptureKit; and
/// `private init` plus `static let shared` meant no test could build a second
/// `AppState` to try any of it. Checking the retry rule meant running the app
/// and revoking a permission by hand.
@MainActor
struct PlaybackPolicyTests {

    private func policy(
        _ kind: AudioSourceKind,
        live: Bool = false,
        screen: Bool = true,
        mic: AVAuthorizationStatus = .authorized,
        blocked: PrivacyPermission? = nil,
        hasFile: Bool = false,
        welcome: Bool = false,
        demoPending: Bool = false
    ) -> PlaybackPolicy {
        PlaybackPolicy(
            sourceKind: kind,
            isLive: live,
            screenAudioGranted: screen,
            microphoneStatus: mic,
            blockedPermission: blocked,
            hasFile: hasFile,
            showsWelcome: welcome,
            firstRunDemoPending: demoPending)
    }

    /// Stands in for whatever the engine threw. Which error it is only matters
    /// for `microphoneDenied`, which is the one the policy reads.
    private let failure = AudioSourceError.noDisplay

    // MARK: - Migration

    @Test func retiredMusicAppSourceLandsOnSystemAudio() {
        #expect(AppState.migrated("musicApp") == AudioSourceKind.systemAudio.rawValue)
        #expect(AppState.migrated("inputDevice") == "inputDevice")
        #expect(AppState.migrated("") == "")
    }

    // MARK: - A start that failed

    /// A permission that was never granted is not a transient error, and a
    /// banner that clears itself after eight seconds is the wrong answer to it.
    @Test func aMissingScreenPermissionBlocksRatherThanRetrying() {
        let p = policy(.systemAudio, screen: false)
        #expect(p.startFailure(for: failure, isRetry: false) == .blocked(.screenAndSystemAudio))
        #expect(p.startFailure(for: failure, isRetry: true) == .blocked(.screenAndSystemAudio))
    }

    /// The rule from CLAUDE.md: the first `startCapture` after a fresh grant
    /// can fail, so it is swallowed once. Exactly once — a permission that is
    /// granted and still failing has something else wrong with it, and the
    /// user should be told.
    @Test func aGrantedPermissionRetriesExactlyOnce() {
        let p = policy(.systemAudio, screen: true)
        #expect(p.startFailure(for: failure, isRetry: false) == .retryQuietly)
        guard case .banner(let message) = p.startFailure(for: failure, isRetry: true) else {
            Issue.record("a retried failure should surface")
            return
        }
        #expect(message.hasPrefix("Couldn't start listening to system audio: "))
    }

    /// Only system audio gets the quiet retry; nothing else has a permission
    /// that behaves that way, so a microphone failure is reported at once.
    @Test func onlySystemAudioSwallowsTheFirstFailure() {
        let p = policy(.inputDevice)
        #expect(p.startFailure(for: failure, isRetry: false) == .banner(failure.localizedDescription))
    }

    @Test func aDeniedMicrophoneBlocksWhicheverSourceAskedForIt() {
        for kind in AudioSourceKind.allCases {
            #expect(
                policy(kind).startFailure(for: AudioSourceError.microphoneDenied, isRetry: false)
                    == .blocked(.microphone),
                "\(kind)")
        }
    }

    // MARK: - Returning from System Settings

    @Test func activationRetriesOnlyTheBlockedSourceOnceItIsAllowed() {
        let stillBlocked = policy(
            .systemAudio, screen: false, blocked: .screenAndSystemAudio)
        #expect(stillBlocked.activationAction() == .doNothing)

        let nowAllowed = policy(.systemAudio, screen: true, blocked: .screenAndSystemAudio)
        #expect(nowAllowed.activationAction() == .retryCapture)

        // A microphone grant must not make the system-audio source retry.
        let wrongPermission = policy(.systemAudio, screen: true, blocked: .microphone)
        #expect(wrongPermission.activationAction() == .doNothing)

        // Nothing was ever blocked; coming back to the foreground is not a
        // reason to start anything.
        #expect(policy(.systemAudio).activationAction() == .doNothing)

        // Already running — whatever was blocked has been dealt with.
        let alreadyLive = policy(
            .systemAudio, live: true, screen: true, blocked: .screenAndSystemAudio)
        #expect(alreadyLive.activationAction() == .doNothing)
    }

    // MARK: - Launch

    /// Nothing plays on a fresh install until the welcome sheet is answered —
    /// including the demo, which is what Continue starts. `docs/`
    /// `app-store-metadata.md` describes that path to App Review.
    @Test func nothingStartsWhileTheWelcomeSheetIsUp() {
        for kind in AudioSourceKind.allCases {
            #expect(policy(kind, welcome: true).startupAction() == .waitForWelcome, "\(kind)")
        }
    }

    /// Only the sources that ask the user for nothing come up on their own. A
    /// microphone that starts listening the moment the app opens is exactly
    /// the behaviour the permission exists to prevent.
    @Test func launchStartsOnlyTheSourcesThatNeedNoAsking() {
        #expect(policy(.demo).startupAction() == .start)
        #expect(policy(.systemAudio).startupAction() == .start)
        #expect(policy(.inputDevice).startupAction() == .doNothing)
        #expect(policy(.audioFile, hasFile: true).startupAction() == .doNothing)
    }

    // MARK: - Switching source

    @Test func switchingToAnInputListsDevicesRatherThanStarting() {
        #expect(policy(.inputDevice).bringUpAction() == .refreshDevices)
    }

    /// Switching to the file source with nothing chosen must not raise the
    /// open panel: the user switched sources, they didn't ask to be
    /// interrupted by a modal.
    @Test func switchingToAnEmptyFileSourceDoesNothing() {
        #expect(policy(.audioFile, hasFile: false).bringUpAction() == .doNothing)
        #expect(policy(.audioFile, hasFile: true).bringUpAction() == .loadAndPlayFile)
    }

    @Test func switchingToASourceThatPlaysItselfStartsIt() {
        #expect(policy(.demo).bringUpAction() == .start)
        #expect(policy(.systemAudio).bringUpAction() == .start)
    }

    // MARK: - The welcome sheet

    /// The App Review path: grants nothing, must still see it work.
    /// `docs/app-store-metadata.md` depends on this staying true.
    @Test func continueWithoutChoosingASourceStartsTheDemo() {
        #expect(policy(.demo, demoPending: true).welcomeResolution(chose: nil) == .startDemo)
    }

    /// Reopened from the Help menu rather than shown at first run: there is no
    /// pending demo, so Continue just dismisses.
    @Test func continueOnAReopenedSheetStartsNothing() {
        #expect(policy(.systemAudio, live: true).welcomeResolution(chose: nil) == .doNothing)
        #expect(policy(.demo).welcomeResolution(chose: nil) == .doNothing)
    }

    @Test func choosingASourceRetiresTheDemo() {
        let p = policy(.demo, demoPending: true)
        #expect(p.welcomeResolution(chose: .systemAudio) == .switchSource(.systemAudio))
    }

    /// Choosing the source that is already selected changes nothing, so
    /// `sourceKind`'s `didSet` never fires — and on first run nothing was ever
    /// started, so the sheet would dismiss onto a dead canvas.
    @Test func choosingTheAlreadySelectedSourceBringsItUpByHand() {
        #expect(policy(.systemAudio).welcomeResolution(chose: .systemAudio) == .bringUpCurrent)
        #expect(
            policy(.systemAudio, live: true).welcomeResolution(chose: .systemAudio) == .doNothing)
    }
}
