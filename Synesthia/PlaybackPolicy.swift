import AVFoundation

/// The decisions `AppState` makes, without the effects it makes them for.
///
/// Everything here is a function of the values passed in — no `UserDefaults`,
/// no TCC query, no AppKit, no engine. `AppState` builds one, asks it, and
/// performs the answer. That split is the whole point: the retry rule, the
/// first-run sequence and the permission gating are the parts that break, and
/// before this they could only be exercised by running the app and revoking a
/// permission by hand. `AppState` is a `private init` singleton, so no test
/// could build a second one to try any of it, and none did.
///
/// The result types are enums rather than closures for one reason: `==` works
/// on them, so a test can say what the answer should be instead of watching
/// for a side effect.
struct PlaybackPolicy {
    let sourceKind: AudioSourceKind
    /// Audio is flowing into the analyzer right now (see CONTEXT.md, "Live").
    let isLive: Bool
    let screenAudioGranted: Bool
    let microphoneStatus: AVAuthorizationStatus
    /// The permission the active source is stuck behind, if it is stuck. Both
    /// an input here and an output of applying the answer — `AppState` owns
    /// it, this only reads it.
    let blockedPermission: PrivacyPermission?
    /// Whether a file has been chosen (or restored from its bookmark).
    let hasFile: Bool
    /// The welcome sheet is up, so nothing may start on its own.
    let showsWelcome: Bool
    /// First run, and the user hasn't chosen a source yet — i.e. Continue
    /// still means "just show me something".
    let firstRunDemoPending: Bool

    // MARK: - Starting failed

    /// What a failed start earns the user.
    enum StartFailure: Equatable {
        /// A missing permission isn't transient: the explainer card, not a
        /// banner that clears itself.
        case blocked(PrivacyPermission)
        /// A freshly granted permission can fail its first attempt (see
        /// CLAUDE.md), so the first failure is swallowed and retried.
        case retryQuietly
        case banner(String)
    }

    /// Reads a start failure. The three outcomes are genuinely different — a
    /// card that stays until the permission is granted, a silent second
    /// attempt, and a banner that clears itself — and picking the wrong one is
    /// the difference between "Synesthia is broken" and "here is the switch to
    /// flip".
    func startFailure(for error: Error, isRetry: Bool) -> StartFailure {
        // A denial is a denial whichever source asked for it.
        if case AudioSourceError.microphoneDenied = error { return .blocked(.microphone) }
        guard sourceKind == .systemAudio else { return .banner(error.localizedDescription) }
        if !screenAudioGranted { return .blocked(.screenAndSystemAudio) }
        if !isRetry { return .retryQuietly }
        return .banner("Couldn't start listening to system audio: \(error.localizedDescription)")
    }

    // MARK: - Coming back to the foreground

    enum ActivationAction: Equatable {
        case retryCapture
        case doNothing
    }

    /// The app came back to the foreground, which is the moment a user returns
    /// from System Settings. Retry only when the permission that was in the
    /// way is the one that just arrived: a granted microphone must not make a
    /// system-audio source try again, and a source that is already live has
    /// nothing to retry.
    func activationAction() -> ActivationAction {
        guard let blocked = blockedPermission,
            sourceKind.requiredPermission == blocked,
            TransportPresentation.isAvailable(
                sourceKind, screenAudioGranted: screenAudioGranted,
                microphoneStatus: microphoneStatus),
            !isLive
        else { return .doNothing }
        return .retryCapture
    }

    // MARK: - Launch

    enum StartupAction: Equatable {
        case start
        case waitForWelcome
        case doNothing
    }

    /// What launching should set going.
    ///
    /// `waitForWelcome` is the App Review-critical one: nothing plays on a
    /// fresh install until the sheet is answered, because starting a source
    /// underneath it would raise a system permission prompt before its pitch
    /// has been read — which is the whole reason the sheet exists.
    ///
    /// Of the rest, only the two sources that can come up without asking the
    /// user anything do: the demo needs no permission at all, and system audio
    /// either has its grant already or fails straight into the explainer card.
    /// A microphone that starts listening the moment the app opens, and a file
    /// that starts playing, both wait to be asked.
    func startupAction() -> StartupAction {
        if showsWelcome { return .waitForWelcome }
        switch sourceKind {
        case .demo, .systemAudio: return .start
        case .inputDevice, .audioFile: return .doNothing
        }
    }

    // MARK: - Switching source

    enum BringUpAction: Equatable {
        case start
        /// Listing the devices *is* the bring-up for an input source; the user
        /// picks one, and choosing is what starts it.
        case refreshDevices
        case loadAndPlayFile
        case doNothing
    }

    /// What the newly selected source needs before it can make a sound.
    func bringUpAction() -> BringUpAction {
        switch sourceKind {
        case .demo, .systemAudio: .start
        case .inputDevice: .refreshDevices
        // Without a file there is nothing to play, and raising the open panel
        // off a source switch would be an ambush.
        case .audioFile: hasFile ? .loadAndPlayFile : .doNothing
        }
    }

    // MARK: - First run

    enum WelcomeResolution: Equatable {
        case startDemo
        case switchSource(AudioSourceKind)
        /// The chosen source is already the selected one but nothing is
        /// playing — first run never started it — so it has to be brought up
        /// by hand or the sheet dismisses onto a dead canvas.
        case bringUpCurrent
        case doNothing
    }

    /// How the welcome sheet ends: `chose` is the source row the user clicked,
    /// or nil for Continue.
    ///
    /// Continue-without-choosing is the App Review path — it grants nothing
    /// and must still show the app working — and the demo is the answer to it.
    /// `docs/app-store-metadata.md` describes that path and depends on this
    /// staying true. The ordering matters just as much: an explicit choice
    /// retires the pending demo, so `WelcomeView.SourceRow` calls
    /// `selectSource` *before* `completeWelcome`, and the reverse order would
    /// start the demo and immediately tear it down to switch sources.
    func welcomeResolution(chose kind: AudioSourceKind?) -> WelcomeResolution {
        guard let kind else {
            return firstRunDemoPending ? .startDemo : .doNothing
        }
        if kind != sourceKind { return .switchSource(kind) }
        return isLive ? .doNothing : .bringUpCurrent
    }
}
