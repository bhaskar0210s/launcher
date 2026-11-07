// Pounce: a small, fast app launcher for macOS. Press ⌘Space, type a few letters of an app you added, press Return.

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
    static let tookOver = "tookOverFromLauncher"  // Launcher's settings were copied (once)
}

/// Pounce was called Launcher before version 1.3; this was its bundle id.
let formerIdentifier = "app.launcher.Launcher"

/// Brings Launcher's settings along, once: the apps, the order they were chosen in, the shortcut and launch at login.
/// Only when Pounce has no list of its own yet. Returns whether anything was copied.
@discardableResult
func takeOverSettings(from domain: String, into defaults: UserDefaults) -> Bool {
    guard defaults.object(forKey: Defaults.apps) == nil, !defaults.bool(forKey: Defaults.tookOver),
          let old = defaults.persistentDomain(forName: domain), old[Defaults.apps] != nil else { return false }
    for key in [Defaults.apps, Defaults.recents, Defaults.picks, Defaults.hotKeyCode, Defaults.hotKeyModifiers,
                Defaults.launchAtLogin, Defaults.launchedBefore] {
        if let value = old[key] { defaults.set(value, forKey: key) }
    }
    defaults.set(true, forKey: Defaults.tookOver)
    return true
}

/// A copy of Launcher that is still running (its login item starts it) would keep the shortcut: it is asked to quit.
private func quitFormerApp() -> Bool {
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: formerIdentifier)
    for app in running { app.terminate() }
    return !running.isEmpty
}

/// Registers the saved shortcut; while a quitting Launcher still holds it, tries again for a few seconds.
@MainActor
private func registerShortcut(attempts: Int) {
    let shortcut = HotKey.saved
    if HotKey.register(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) || attempts <= 1 { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        MainActor.assumeIsolated { registerShortcut(attempts: attempts - 1) }
    }
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
        #if !HARNESS
        takeOverSettings(from: formerIdentifier, into: defaults)
        let launcherWasRunning = quitFormerApp()
        #endif

        let catalog = Catalog()
        catalog.load()
        let popup = Popup(catalog: catalog)
        self.popup = popup
        HotKey.action = { [weak popup] in popup?.toggle() }

        #if HARNESS
        startHarness(popup)
        return
        #else
        registerShortcut(attempts: launcherWasRunning ? 5 : 1)

        // Launch at login is on unless it was turned off in Settings. A new version can lose its login item (macOS
        // ties it to the app's signature and then reports it as not found), so Pounce asks again when it's missing.
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

    // Opening Pounce again (from Finder, for example) shows its settings.
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
