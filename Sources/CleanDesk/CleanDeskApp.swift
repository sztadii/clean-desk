import AppKit
import Combine
import CleanDeskCore
import SwiftUI

@main
enum CleanDeskMain {
    static var reopenNotification: Notification.Name {
        Notification.Name((Bundle.main.bundleIdentifier ?? "pl.local.cleandesk") + ".showPanel")
    }

    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let lockURL = support
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "pl.local.cleandesk", isDirectory: true)
                .appendingPathComponent("instance.lock")
            // All installed/build/DMG copies share the same per-user lock. Check
            // it before creating the store, touching preferences or adding UI.
            guard let lock = try SingleInstanceLock.acquire(at: lockURL) else {
                DistributedNotificationCenter.default().postNotificationName(
                    reopenNotification, object: nil, userInfo: nil, deliverImmediately: true
                )
                return
            }
            // This setting belongs to Clean Desk's preferences, not the global domain.
            UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
            let delegate = AppDelegate()
            app.delegate = delegate
            withExtendedLifetime((lock, delegate)) { app.run() }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Could not start Clean Desk"
            alert.informativeText = "Clean Desk could not access its local session file. Please try again."
            alert.addButton(withTitle: "Quit")
            alert.runModal()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let store = AppStore()
    private var reportObserver: AnyCancellable?
    private var desktopAccessObserver: AnyCancellable?
    private var contextMenuVisible = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(showExistingInstance), name: CleanDeskMain.reopenNotification,
            object: nil, suspensionBehavior: .deliverImmediately
        )
        installMenus()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = CleanDeskIcon.image()
            button.target = self
            button.action = #selector(handleStatusItemClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: PanelLayout.width, height: PanelLayout.height)
        popover.contentViewController = NSHostingController(rootView: DeskView(
            store: store,
            quit: { NSApp.terminate(nil) }
        ))
        observeCleanupReports()
        observeDesktopAccess()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.showPopover() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func showExistingInstance(_ notification: Notification) {
        if store.isGrantingDesktopAccess {
            NSApp.activate(ignoringOtherApps: true)
        } else {
            showPopover()
        }
    }

    @objc private func handleStatusItemClick() {
        if let event = NSApp.currentEvent,
           event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showContextMenu()
            return
        }
        if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }

    private func showPopover() {
        guard !store.isGrantingDesktopAccess, let button = statusItem?.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidShow(_ notification: Notification) {
        store.setPanelVisible(true)
    }

    func popoverDidClose(_ notification: Notification) {
        store.setPanelVisible(contextMenuVisible)
    }

    private func showContextMenu() {
        guard let button = statusItem?.button else { return }
        contextMenuVisible = true
        popover.performClose(nil)
        let menu = NSMenu()
        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quitItem.target = NSApp
        menu.addItem(quitItem)
        button.highlight(true)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
        button.highlight(false)
        contextMenuVisible = false
        store.setPanelVisible(popover.isShown)
    }

    private func observeDesktopAccess() {
        desktopAccessObserver = store.$isGrantingDesktopAccess
            .removeDuplicates()
            .dropFirst()
            // The system folder picker closes the transient popover. Bring the
            // current step back after either approval or cancellation, once all
            // permission state has been updated.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isGranting in
                guard let self else { return }
                if isGranting {
                    self.popover.performClose(nil)
                } else {
                    self.showPopover()
                }
            }
    }

    private func observeCleanupReports() {
        reportObserver = store.$report
            .removeDuplicates { previous, current in
                previous?.isSuccess == current?.isSuccess
                    && previous?.detail == current?.detail
                    && previous?.remaining.map(\.id) == current?.remaining.map(\.id)
                    && previous?.launchFailures == current?.launchFailures
                    && previous?.hideFailures == current?.hideFailures
                    && previous?.showFailures == current?.showFailures
                    && previous?.desktopFailures == current?.desktopFailures
            }
            // @Published emits before assignment. Defer presentation so refreshing
            // the popover cannot re-enter report reconciliation with the old value.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] report in
                guard let self, let report, !report.isSuccess,
                      !self.store.isCleaning, !self.popover.isShown else { return }
                self.showPopover()
            }
    }

    private func installMenus() {
        let menu = NSMenu()
        let application = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        application.submenu = appMenu
        menu.addItem(application)
        let edit = NSMenuItem()
        edit.title = "Edit"
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = editMenu
        menu.addItem(edit)
        NSApp.mainMenu = menu
    }
}
