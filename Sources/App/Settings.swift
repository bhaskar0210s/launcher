// Settings, shown inside the search window itself (⌘,): the shortcut, launch at login and, below them, the apps.
// Everything is drawn by Launcher: a separate window and the standard controls would cost megabytes for two options.

import AppKit
import Carbon
import ServiceManagement

private let rowSpacing: CGFloat = 44
private let side: CGFloat = 18
private let sectionHeight: CGFloat = 30
private let noticeHeight: CGFloat = 46

/// An on/off switch. Flips the moment it is clicked.
final class Toggle: CanvasView {
    var on = false { didSet { needsDisplay = true } }
    var label = ""
    var onChange: ((Bool) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let track = bounds
        let radius = track.height / 2
        (on ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.16)).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
        let knob = track.height - 4
        let circle = NSRect(x: on ? track.maxX - knob - 2 : 2, y: 2, width: knob, height: knob)
        black.withAlphaComponent(0.12).setFill()
        NSBezierPath(ovalIn: circle.offsetBy(dx: 0, dy: 0.5)).fill()
        white.setFill()
        NSBezierPath(ovalIn: circle).fill()
    }

    override func mouseDown(with event: NSEvent) {
        flip()
    }

    private func flip() {
        on.toggle()
        onChange?(on)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .switch }
    override func accessibilityLabel() -> String? { label }
    override func accessibilityValue() -> Any? { NSNumber(value: on) }
    override func accessibilityPerformPress() -> Bool {
        flip()
        return true
    }
}

/// A borderless button with a title and an optional glyph, highlighted while the pointer is over it.
final class FlatButton: CanvasView {
    var title = "" { didSet { needsDisplay = true } }
    var glyph: Glyph?
    var action: (() -> Void)?
    var isEnabled = true { didSet { needsDisplay = true } }
    private var hovered = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if isEnabled && bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }

    var fittingWidth: CGFloat { textWidth(title, size: 12, weight: .medium) + (glyph == nil ? 20 : 40) }

    override func draw(_ dirtyRect: NSRect) {
        if hovered && isEnabled {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        }
        let color: NSColor = !isEnabled ? .tertiaryLabelColor : hovered ? .labelColor : .secondaryLabelColor
        var x: CGFloat = 10
        if let glyph {
            drawGlyph(glyph, in: NSRect(x: x, y: (bounds.midY - 7).rounded(), width: 14, height: 14), color: color)
            x += 22
        }
        drawText(title, x: x, midY: bounds.midY, size: 12, weight: .medium, color: color)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { title }
    override func isAccessibilityEnabled() -> Bool { isEnabled }
    override func accessibilityPerformPress() -> Bool {
        if isEnabled { action?() }
        return true
    }
}

/// The name of a macOS shortcut that is on and uses the same keys, so it would get them first: ⌘Space opens the Apps
/// view on a new Mac, and Spotlight has ⌘Space or ⌥⌘Space.
private func systemShortcutUsing(keyCode: UInt32, modifiers: UInt32) -> String? {
    let hotKeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys") ?? [:]
    // Shortcuts nobody changed aren't in the file, and Spotlight's factory shortcut is ⌘Space.
    if hotKeys["64"] == nil && keyCode == UInt32(kVK_Space) && modifiers == UInt32(cmdKey) { return "Spotlight" }
    let names = ["64": "Spotlight", "65": "Finder search", "160": "the Apps view", "60": "input source switching", "61": "input source switching"]
    for (id, value) in hotKeys {
        guard let entry = value as? [String: Any], (entry["enabled"] as? Bool) == true,
              let parameters = (entry["value"] as? [String: Any])?["parameters"] as? [Int], parameters.count == 3,
              parameters[1] == Int(keyCode), carbonModifiers(NSEvent.ModifierFlags(rawValue: UInt(max(0, parameters[2])))) == modifiers
        else { continue }
        return names[id] ?? "a macOS shortcut"
    }
    return nil
}

/// The shortcut and launch at login, with a note when the shortcut can't work, and the heading of the app list.
final class SettingsPage: CanvasView {
    private let shortcut = ShortcutField(frame: .zero)
    private let login = Toggle(frame: .zero)
    private var notice: (title: String, detail: String)?
    var appCount = 0 { didSet { needsDisplay = true } }
    var adding = false { didSet { needsDisplay = true } }
    var onLayoutChange: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        (shortcut.keyCode, shortcut.modifiers) = HotKey.saved
        shortcut.onChange = { [weak self] in self?.refresh() }
        addSubview(shortcut)
        login.label = "Launch at login"
        login.onChange = { [weak self] on in self?.setLaunchAtLogin(on) }
        addSubview(login)
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    var recording: Bool { shortcut.recording }

    var returnResponder: NSResponder? {
        get { shortcut.returnResponder }
        set { shortcut.returnResponder = newValue }
    }

    var preferredHeight: CGFloat { 6 + 2 * rowSpacing + (notice == nil ? 0 : noticeHeight) + sectionHeight }

    func refresh() {
        login.on = SMAppService.mainApp.status == .enabled
        let previous = notice?.title
        let (keyCode, modifiers) = (shortcut.keyCode, shortcut.modifiers)
        if !shortcut.recording, let owner = systemShortcutUsing(keyCode: keyCode, modifiers: modifiers) {
            notice = ("\(shortcutName(keyCode: keyCode, modifiers: modifiers)) still opens \(owner).",
                      "Click here and turn it off in Keyboard Shortcuts, or choose another shortcut above.")
        } else if !shortcut.recording && !HotKey.isRegistered && !HotKey.testing {
            notice = ("Another app is using \(shortcutName(keyCode: keyCode, modifiers: modifiers)).", "Click the shortcut to choose another one.")
        } else {
            notice = nil
        }
        layoutControls()
        needsDisplay = true
        if notice?.title != previous { onLayoutChange?() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutControls()
    }

    private func layoutControls() {
        let width = bounds.width, top: CGFloat = 6
        shortcut.frame = NSRect(x: width - side - 118, y: top + ((rowSpacing - 26) / 2).rounded(), width: 118, height: 26)
        login.frame = NSRect(x: width - side - 34, y: top + rowSpacing + ((rowSpacing - 20) / 2).rounded(), width: 34, height: 20)
    }

    override func draw(_ dirtyRect: NSRect) {
        let width = bounds.width
        var y: CGFloat = 6
        drawText("Shortcut", x: side, midY: y + rowSpacing / 2, size: 13, color: .labelColor)
        NSColor.separatorColor.setFill()
        NSRect(x: side, y: y + rowSpacing - 0.5, width: width - 2 * side, height: 1).fill()
        y += rowSpacing
        drawText("Launch at login", x: side, midY: y + rowSpacing / 2, size: 13, color: .labelColor)
        y += rowSpacing
        if let notice {
            let box = NSRect(x: side - 8, y: y + 2, width: width - 2 * side + 16, height: noticeHeight - 6)
            NSColor.systemOrange.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
            drawText(notice.title, x: side, midY: box.minY + 13, size: 12, weight: .semibold, color: .systemOrange)
            drawText(notice.detail, x: side, midY: box.minY + 28, size: 11, color: .secondaryLabelColor)
            y += noticeHeight
        }
        let heading = adding ? "All apps" : appCount == 0 ? "Your apps" : "Your apps · \(appCount)"
        let hint = adding ? "Click a circle or press Return to add or remove" : "Add Apps, or type a name, to add more"
        drawText(heading, x: side, midY: y + sectionHeight / 2 + 4, size: 11, weight: .semibold, color: .secondaryLabelColor)
        drawText(hint, x: width - side - textWidth(hint, size: 11), midY: y + sectionHeight / 2 + 4, size: 11, color: .tertiaryLabelColor)
    }

    override func mouseDown(with event: NSEvent) {
        guard notice != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        if point.y > 6 + 2 * rowSpacing && point.y < 6 + 2 * rowSpacing + noticeHeight,
           systemShortcutUsing(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) != nil {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { NSWorkspace.shared.open(url) }
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Defaults.launchAtLogin)
        let service = SMAppService.mainApp
        do {
            if on { try service.register() } else { try service.unregister() }
        } catch {
            if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        }
        login.on = service.status == .enabled
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Launcher Settings" }
}

/// The bottom of the settings: Add Apps (Done while adding) and Remove for the list above, and Quit.
final class SettingsFooter: CanvasView {
    private let add = FlatButton(frame: .zero)
    private let remove = FlatButton(frame: .zero)
    private let quit = FlatButton(frame: .zero)

    var onAdd: (() -> Void)? {
        get { add.action }
        set { add.action = newValue }
    }
    var onRemove: (() -> Void)? {
        get { remove.action }
        set { remove.action = newValue }
    }
    /// Remove works on the selected app, when it is one of the added apps.
    var canRemove = false { didSet { remove.isEnabled = canRemove } }
    var adding = false {
        didSet {
            add.title = adding ? "Done" : "Add Apps"
            add.glyph = adding ? .check : .plus
            add.toolTip = adding ? "Back to your apps" : "Find installed apps to add"
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        add.title = "Add Apps"
        add.glyph = .plus
        add.toolTip = "Find installed apps to add"
        remove.title = "Remove"
        remove.glyph = .minus
        remove.toolTip = "Remove the selected app from Launcher"
        remove.isEnabled = false
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        quit.title = "Quit"
        quit.glyph = .power
        quit.toolTip = "Quit Launcher \(version) (⌘Q)"
        quit.action = { NSApp.terminate(nil) }
        for button in [add, remove, quit] { addSubview(button) }
    }

    required init?(coder: NSCoder) { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let height = newSize.height - 12
        // As wide as its longer title, so Remove stays put when Add Apps turns into Done.
        let addWidth = max(add.fittingWidth, textWidth("Add Apps", size: 12, weight: .medium) + 40)
        add.frame = NSRect(x: 8, y: 6, width: addWidth, height: height)
        remove.frame = NSRect(x: add.frame.maxX + 2, y: 6, width: remove.fittingWidth, height: height)
        quit.frame = NSRect(x: newSize.width - 8 - quit.fittingWidth, y: 6, width: quit.fittingWidth, height: height)
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }
}
