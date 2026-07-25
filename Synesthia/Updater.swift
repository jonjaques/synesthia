import SwiftUI

// Sparkle powers in-app updates for the **direct download only**. Apps
// distributed through the Mac App Store must not ship their own updater —
// the store does that job, and bundling one invites rejection.
//
// This whole file is therefore guarded on `canImport(Sparkle)`: it compiles to
// nothing until the Sparkle package is linked, and it must only ever be linked
// into the `Direct` configuration. See docs/distribution.md for the (manual,
// one-time) Xcode steps and why they can't be scripted here.

#if canImport(Sparkle)
import Sparkle

/// Owns the Sparkle updater for the app's lifetime.
///
/// `SPUStandardUpdaterController` is Sparkle's batteries-included entry point:
/// it builds the updater, its scheduler, and the standard update UI. Creating
/// it with `startingUpdater: true` starts the background check schedule, which
/// is what makes "check automatically" work without any further wiring.
@Observable
final class UpdaterController {
    static let shared = UpdaterController()

    @ObservationIgnored private let controller: SPUStandardUpdaterController

    /// Mirrors the updater's own readiness so the menu item can dim while a
    /// check is already in flight.
    private(set) var canCheckForUpdates = false

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        withObservationTracking {
            _ = controller.updater.canCheckForUpdates
        } onChange: { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    private func refresh() {
        canCheckForUpdates = controller.updater.canCheckForUpdates
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
        refresh()
    }
}
#endif

/// The Help-menu "Check for Updates…" item.
///
/// Present only in builds that link Sparkle, so the Mac App Store build simply
/// has no such command — which is the correct behaviour there anyway.
struct CheckForUpdatesCommand: View {
    var body: some View {
        #if canImport(Sparkle)
        let updater = UpdaterController.shared
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)
        Divider()
        #else
        EmptyView()
        #endif
    }
}
