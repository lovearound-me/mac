import AppKit
import Sparkle

/// Sparkle: checks `SUFeedURL` every hour (`SUScheduledCheckInterval`),
/// downloads a new build in the background and installs it on its own.
/// A menu bar app is rarely quit, so the install doesn't wait for a quit:
/// it relaunches as soon as the person isn't using the app.
@MainActor
final class Updates: NSObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController!
    private var pendingInstall: (() -> Void)?
    private var resignObserver: NSObjectProtocol?

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }

    /// "Проверить обновления…": shows Sparkle's own window with the result.
    func checkNow() {
        controller.checkForUpdates(nil)
    }

    nonisolated func updater(_ updater: SPUUpdater,
                             willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        Task { @MainActor in self.installWhenIdle(immediateInstallHandler) }
        return true
    }

    /// Not while the popover or a window is in use: the relaunch would close
    /// it under the cursor. Signals that arrive during the second of the
    /// relaunch are missed, like any time the app is offline.
    private func installWhenIdle(_ install: @escaping () -> Void) {
        if !NSApp.isActive {
            install()
            return
        }
        pendingInstall = install
        guard resignObserver == nil else { return }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, let install = self.pendingInstall else { return }
                self.pendingInstall = nil
                install()
            }
        }
    }
}
