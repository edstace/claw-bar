import Cocoa
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private let model = ClawBarViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        ErrorReporter.configureIfPossible()

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
