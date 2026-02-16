import AppKit
import SwiftUI

@MainActor
final class StatusBarController {
    private let popover: NSPopover
    private var statusItem: NSStatusItem?

    init(popover: NSPopover) {
        self.popover = popover
    }

    func start() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            setButtonImage(button)
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        observeIconStyleChanges()
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.becomeKey()
        }
    }

    private func observeIconStyleChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDefaultsDidChange),
            name: UserDefaults.didChangeNotification,
            object: UserDefaults.standard
        )
    }

    @objc private func handleDefaultsDidChange() {
        guard let button = statusItem?.button else { return }
        setButtonImage(button)
    }

    private func setButtonImage(_ button: NSStatusBarButton) {
        let style = MenuBarIconStyle.current
        let icon = NSImage(named: style.imageName)
            ?? Bundle.main.url(forResource: "\(style.imageName)@1x", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
            ?? Bundle.main.url(forResource: "ClawBarTemplatePaw@1x", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
        if let icon {
            icon.isTemplate = true
            button.image = icon
        } else {
            button.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "ClawBar")
        }
    }
}
