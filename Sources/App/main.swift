// Launcher: a small, fast app launcher for macOS. Press ⌘Space, type a few letters of an app you added, press Return.

import AppKit
import Carbon
import ServiceManagement

enum Defaults {
    static let apps = "apps"
    static let recents = "recents"  // the apps opened, most recent first
    static let picks = "picks"      // what versions before 1.2 remembered instead
    static let hotKeyCode = "hotKeyCode"
    static let hotKeyModifiers = "hotKeyModifiers"
    static let launchedBefore = "launchedBefore"
    static let launchAtLogin = "launchAtLogin"
}

private func installedInApplications() -> Bool {
    let path = Bundle.main.bundlePath
    return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var popup: Popup?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [Defaults.launchAtLogin: true])

        let catalog = Catalog()
        catalog.load()
        let popup = Popup(catalog: catalog)
        self.popup = popup
        HotKey.action = { [weak popup] in popup?.toggle() }

        #if HARNESS
        startHarness(popup)
        return
        #else
        let shortcut = HotKey.saved
        HotKey.register(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers)

        // Launch at login is on unless it was turned off in Settings. A new version can lose its login item (macOS
        // ties it to the app's signature and then reports it as not found), so Launcher asks again when it's missing.
        let status = SMAppService.mainApp.status
        if installedInApplications(), defaults.bool(forKey: Defaults.launchAtLogin), status == .notRegistered || status == .notFound {
            try? SMAppService.mainApp.register()
        }
        if !defaults.bool(forKey: Defaults.launchedBefore) || catalog.apps.isEmpty || !HotKey.isRegistered {
            defaults.set(true, forKey: Defaults.launchedBefore)
            popup.showSettings()  // there is no menu bar icon: show how to add apps
        }
        // The icons are drawn ahead of time, so the first search is as quick as any other.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                catalog.prepareIcons(points: iconPoints, scale: NSScreen.screens.map(\.backingScaleFactor).max() ?? 2)
            }
        }
        #endif
    }

    // Opening Launcher again (from Finder, for example) shows its settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        popup?.showSettings()
        return false
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
