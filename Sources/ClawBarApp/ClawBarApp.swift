import Foundation
import SwiftUI

@main
struct ClawBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") {
            exit(ClawBarSmoke.run())
        }
    }

    var body: some Scene {
        // Menu-bar-only app — no main window.
        Settings {
            EmptyView()
        }
    }
}
