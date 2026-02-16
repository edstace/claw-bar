import SwiftUI

@main
struct ClawBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Menu-bar-only app — no main window.
        Settings {
            EmptyView()
        }
    }
}
