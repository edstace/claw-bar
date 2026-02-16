import Cocoa
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private let model = ClawBarViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isSecondaryInstance() else {
            NSApp.terminate(nil)
            return
        }

        ErrorReporter.configureIfPossible()
        registerLifecycleObservers()

        // Hide dock icon — menu-bar-only app
        NSApp.setActivationPolicy(.accessory)
        UserDefaults.standard.set(MenuBarIconStyle.claw.rawValue, forKey: MenuBarIconStyle.defaultsKey)

        let view = ClawBarView(model: model)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 360, height: 420)
        popover.contentViewController = NSHostingController(rootView: view)

        statusBarController = StatusBarController(popover: popover)
        statusBarController?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.handleAppWillTerminate()
        unregisterLifecycleObservers()
    }

    private func registerLifecycleObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            self,
            selector: #selector(handleWorkspaceWillSleep(_:)),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(handleWorkspaceDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(handleScreensDidSleep(_:)),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(handleScreensDidWake(_:)),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(handleSessionDidResignActive(_:)),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(handleSessionDidBecomeActive(_:)),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
    }

    private func unregisterLifecycleObservers() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func handleWorkspaceWillSleep(_ notification: Notification) {
        model.handleLifecyclePause(reason: "Live voice paused while Mac is sleeping")
    }

    @objc private func handleWorkspaceDidWake(_ notification: Notification) {
        model.handleLifecycleResume()
    }

    @objc private func handleScreensDidSleep(_ notification: Notification) {
        model.handleLifecyclePause(reason: "Live voice paused while screen is locked")
    }

    @objc private func handleScreensDidWake(_ notification: Notification) {
        model.handleLifecycleResume()
    }

    @objc private func handleSessionDidResignActive(_ notification: Notification) {
        model.handleLifecyclePause(reason: "Live voice paused while session is inactive")
    }

    @objc private func handleSessionDidBecomeActive(_ notification: Notification) {
        model.handleLifecycleResume()
    }

    private func isSecondaryInstance() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .contains(where: { $0.processIdentifier != currentPID && !$0.isTerminated })
    }
}
