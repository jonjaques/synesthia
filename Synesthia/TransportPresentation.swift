import AVFoundation

/// Everything the menu bar and the canvas chrome need to *say* about the
/// current source, derived once.
///
/// This exists because there were two of everything. The menu computed the
/// capture item's title from `sourceKind` and the chrome computed the capture
/// button's tooltip from `sourceKind`, and they drifted — not in casing, which
/// is correct and deliberate (menu items are Title Case, tooltips are sentence
/// case), but in the fact that adding a source meant finding both switches and
/// nothing failed if you found only one.
///
/// Availability was worse: three independent derivations of "can this source
/// produce audio". `AppState.isSourceAvailable` decided, `ControlsPod`
/// re-partitioned the list around it, and `WelcomeView.footnote` ignored both
/// and read the TCC flags directly — so the welcome sheet could promise a
/// source the picker had greyed out.
///
/// Pure on purpose — no `AppState`, no AppKit, no `UserDefaults` — so every
/// string and every availability rule is assertable. `AppState.transport`
/// builds it.
struct TransportPresentation {
    let sourceKind: AudioSourceKind
    /// Whether audio is flowing into the analyzer right now. Fed from
    /// `AppState.isCaptureActive`.
    let isLive: Bool
    let screenAudioGranted: Bool
    let microphoneStatus: AVAuthorizationStatus
    /// The selected visualizer's descriptor id.
    let visualizerID: String

    // MARK: - Visualizer

    /// The selected visualizer's display name, for the menu's "Reset …" item
    /// and the trailing pod's label — which computed it separately.
    ///
    /// The fallback matters: `visualizerID` is restored from `UserDefaults`
    /// and can name a visualizer that no longer exists.
    var visualizerName: String {
        VisualizerRegistry.descriptor(id: visualizerID)?.name ?? "Visualizer"
    }

    // MARK: - Capture control

    /// Title Case, for the Playback menu — the macOS convention for menu items.
    var captureMenuTitle: String {
        switch sourceKind {
        case .demo: isLive ? "Pause Demo Track" : "Play Demo Track"
        case .audioFile: isLive ? "Pause File" : "Play File"
        case .systemAudio, .inputDevice: isLive ? "Stop Listening" : "Start Listening"
        }
    }

    /// Sentence case, for tooltips and accessibility labels. Deliberately the
    /// same *words* as `captureMenuTitle` in different case — `menuTitleAndHelpDifferOnlyInCase`
    /// pins that, so the pair can be reworded but not allowed to diverge.
    var captureHelp: String {
        switch sourceKind {
        case .demo: isLive ? "Pause demo track" : "Play demo track"
        case .audioFile: isLive ? "Pause file" : "Play file"
        case .systemAudio, .inputDevice: isLive ? "Stop listening" : "Start listening"
        }
    }

    /// Sources this app is playing itself get transport glyphs; sources it is
    /// listening to get the capture waveform. Reaching for a waveform to
    /// silence the demo track is not an obvious move.
    var captureSymbol: String {
        switch sourceKind {
        case .demo, .audioFile:
            isLive ? "pause.circle.fill" : "play.circle.fill"
        case .systemAudio, .inputDevice:
            isLive ? "waveform.circle.fill" : "waveform.circle"
        }
    }

    // MARK: - Availability

    /// Whether a source could produce audio right now, permission-wise.
    /// Locked sources appear disabled in the source picker; the welcome
    /// sheet — which explains what each permission buys *before* macOS asks —
    /// is the granting path.
    func isAvailable(_ kind: AudioSourceKind) -> Bool {
        switch kind {
        case .demo, .audioFile:
            true
        case .systemAudio:
            screenAudioGranted
        case .inputDevice:
            // .notDetermined stays available: selecting the source is what
            // triggers the system prompt.
            microphoneStatus != .denied && microphoneStatus != .restricted
        }
    }

    /// The selectable sources whose permission is granted (or unneeded), plus
    /// whatever is active right now — the demo, or a source whose permission
    /// was just revoked — so the checkmark always has a row.
    var pickerSources: [AudioSourceKind] {
        var kinds = AudioSourceKind.selectable.filter(isAvailable)
        if !kinds.contains(sourceKind) { kinds.insert(sourceKind, at: 0) }
        return kinds
    }

    /// Sources that need a permission the user hasn't granted, shown disabled.
    var lockedSources: [AudioSourceKind] {
        AudioSourceKind.selectable.filter { !isAvailable($0) && $0 != sourceKind }
    }

    /// The permission line under a welcome-sheet source row: the cost before
    /// it's paid, the green seal after.
    ///
    /// `ready` is not the same question as `isAvailable`, and the difference is
    /// load-bearing for the microphone: an undetermined mic is *available*
    /// (choosing it is what raises the prompt) but not *ready* (nothing has
    /// been granted yet), so the row still has to say what it will ask for.
    /// Where a permission can only be granted or refused — system audio — the
    /// two must agree, and `footnoteAgreesWithAvailability` asserts it.
    func footnote(for kind: AudioSourceKind) -> PermissionFootnote? {
        switch kind {
        case .demo:
            nil
        case .systemAudio:
            screenAudioGranted
                ? PermissionFootnote(
                    text: "Ready — access granted", symbol: "checkmark.seal.fill", ready: true)
                : PermissionFootnote(
                    text: "Asks for Screen & System Audio Recording",
                    symbol: "lock.fill", ready: false)
        case .inputDevice:
            switch microphoneStatus {
            case .authorized:
                PermissionFootnote(
                    text: "Ready — access granted", symbol: "checkmark.seal.fill", ready: true)
            case .denied, .restricted:
                PermissionFootnote(
                    text: "Microphone access is turned off in System Settings",
                    symbol: "lock.fill", ready: false)
            default:
                PermissionFootnote(
                    text: "Asks for Microphone access", symbol: "lock.fill", ready: false)
            }
        case .audioFile:
            PermissionFootnote(
                text: "No permission needed — you choose the file",
                symbol: "checkmark.seal.fill", ready: true)
        }
    }
}

/// The permission line under a welcome-sheet source row: the cost before it's
/// paid, the green seal after.
///
/// Lives here rather than in `WelcomeView` so it sits beside the availability
/// rule it has to agree with — the sheet reading TCC on its own is what let
/// the two disagree in the first place.
struct PermissionFootnote {
    let text: String
    let symbol: String
    let ready: Bool
}
