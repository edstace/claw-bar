import Cocoa
import Sparkle
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private let model = ClawBarViewModel()
    private var sparkleUpdaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        ErrorReporter.configureIfPossible()

        // Sparkle is optional at runtime and requires a valid appcast + Sparkle signing setup.
        sparkleUpdaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        model.configureSparkleUpdateCheck { [weak sparkleUpdaterController] in
            sparkleUpdaterController?.checkForUpdates(nil)
        }

        // Hide dock icon — menu-bar-only app
        NSApp.setActivationPolicy(.accessory)
        UserDefaults.standard.set(MenuBarIconStyle.paw.rawValue, forKey: MenuBarIconStyle.defaultsKey)

        let view = ClawBarView(model: model)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 360, height: 420)
        popover.contentViewController = NSHostingController(rootView: view)

        statusBarController = StatusBarController(popover: popover)
        statusBarController?.start()
    }
}
