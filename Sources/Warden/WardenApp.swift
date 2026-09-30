import AppKit
import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = WardenStore()
    private var statusMenu: StatusMenuController?
    private var settingsWindow: NSWindow?
    private var tutorialWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var plannerWindow: NSWindow?

    static func main() {
        // Helper processes may exit before reading their input; a write must fail instead of ending Warden.
        signal(SIGPIPE, SIG_IGN)
        #if DEBUG
        if CodexWatch.runIfRequested() { return }
        #endif
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if DebugSupport.scanOnceIfRequested() || DebugSupport.historyOnceIfRequested() || DebugSupport.quotaOnceIfRequested() { return }
        if DebugSupport.trainGuardOnceIfRequested() { return }
        if DebugSupport.renderTutorialIfRequested(store: store) { return }
        if DebugSupport.renderSettingsIfRequested(store: store) { store.refresh(); return }
        if DebugSupport.renderHistoryIfRequested() { return }
        if DebugSupport.renderPlannerIfRequested() { return }
        if DebugSupport.renderLimitsIfRequested() || DebugSupport.renderActivityIfRequested() { return }
        #endif
        configureMainMenu()
        statusMenu = StatusMenuController(store: store, openSettings: { [weak self] in self?.showSettings() },
                                          openHistory: { [weak self] in self?.showHistory() },
                                          openPlanner: { [weak self] in self?.showPlanner() },
                                          openTutorial: { [weak self] in self?.showTutorial() })
        store.openTutorial = { [weak self] in self?.showTutorial() }
        store.openMenu = { [weak self] in self?.statusMenu?.open() }
        store.start()
        showInitialSetupIfNeeded()
        #if DEBUG
        switch ProcessInfo.processInfo.environment["WARDEN_SHOW"] {
        case "history": showHistory()
        case "planner": showPlanner()
        case "settings": showSettings()
        case "tutorial": showTutorial()
        default: break
        }
        DebugSupport.captureWindowsLater()
        DebugSupport.openPhonePairingIfRequested(store.phone)
        DebugSupport.confirmTrainGuardIfRequested(store)
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.shutdown()
    }

    private func showInitialSetupIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "didShowSetup") else { return }
        defaults.set(true, forKey: "didShowSetup")
        // Earlier releases registered login at startup. Do not interrupt an existing installation.
        guard !defaults.bool(forKey: "didConfigureLogin") else { return }
        showTutorial()
    }

    /// Links from the widgets: `warden://open` opens the menu, `warden://session/<id>` brings a session forward. A
    /// link can only show things; answering a prompt always takes a click in Warden or on a paired phone.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "warden" || url.scheme == "warden-preview" {
            let id = url.host == "session" ? url.pathComponents.dropFirst().first : nil
            if let id, store.sessions.contains(where: { $0.id == id }) {
                store.open(sessionID: id)
            } else {
                statusMenu?.open()
            }
        }
    }

    private func configureMainMenu() {
        // Report windows need the usual keyboard commands even in an accessory app.
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Warden")
        let settings = NSMenuItem(title: "Warden Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        let tutorial = NSMenuItem(title: "Interactive Guide…", action: #selector(showTutorial), keyEquivalent: "")
        tutorial.target = self
        appMenu.addItem(tutorial)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Warden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        let history = NSMenuItem(title: "History", action: #selector(showHistory), keyEquivalent: "")
        history.target = self
        windowMenu.addItem(history)
        let planner = NSMenuItem(title: "Work Planner", action: #selector(showPlanner), keyEquivalent: "")
        planner.target = self
        windowMenu.addItem(planner)
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    @objc private func showTutorial() {
        if tutorialWindow == nil {
            let view = TutorialView(store: store, openSettings: { [weak self] tab in
                UserDefaults.standard.set(tab, forKey: "settingsTab")
                self?.showSettings()
            }, openHistory: { [weak self] in self?.showHistory() }, openPlanner: { [weak self] in self?.showPlanner() },
               close: { [weak self] in self?.tutorialWindow?.close() })
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Warden Guide"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.setContentSize(NSSize(width: 900, height: 640))
            window.contentMinSize = NSSize(width: 840, height: 600)
            window.isReleasedWhenClosed = false
            window.center()
            tutorialWindow = window
        }
        showWindow(tutorialWindow)
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: WardenSettings(store: store)))
            window.title = "Warden Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        showWindow(settingsWindow)
    }

    @objc private func showHistory() {
        if historyWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: UsageHistoryView(store: store)))
            window.title = "Warden History"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 800, height: 760))
            window.contentMinSize = NSSize(width: 660, height: 540)
            window.center()
            historyWindow = window
        }
        store.refreshHistory(soon: true)
        showWindow(historyWindow)
    }

    @objc private func showPlanner() {
        if plannerWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: WorkPlannerView(store: store, openPowerSettings: { [weak self] in
                UserDefaults.standard.set("power", forKey: "settingsTab")
                self?.showSettings()
            })))
            window.title = "Warden Work Planner"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 740, height: 640))
            window.contentMinSize = NSSize(width: 640, height: 480)
            window.center()
            plannerWindow = window
        }
        store.refresh(usage: true)
        showWindow(plannerWindow)
    }

    private func showWindow(_ window: NSWindow?) {
        guard let window else { return }
        // Let menu tracking finish before taking focus from the previously active app.
        RunLoop.main.perform(inModes: [.default]) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            // Activation is asynchronous and may be declined; the requested window must still be visible.
            window.orderFrontRegardless()
        }
    }
}
