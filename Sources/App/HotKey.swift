// The global shortcut (a Carbon hot key, which needs no special permission) and the field that records a new one.

import AppKit
import Carbon

@MainActor
enum HotKey {
    private static var hotKey: EventHotKeyRef?
    private static var handler: EventHandlerRef?
    static var action: (() -> Void)?
    private(set) static var isRegistered = false
    static var testing = false  // the test harness never registers the shortcut, on purpose

    @discardableResult
    static func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                MainActor.assumeIsolated { HotKey.action?() }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        unregister()
        let id = EventHotKeyID(signature: 0x6C6E_6368, id: 1)  // 'lnch'
        isRegistered = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKey) == noErr
        if tracing { NSLog("shortcut %@ %@", shortcutName(keyCode: keyCode, modifiers: modifiers), isRegistered ? "registered" : "not registered") }
        return isRegistered
    }

    static func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        isRegistered = false
    }

    static let defaultKey = (keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey))

    /// The shortcut in the settings, or ⌘Space when what is saved there isn't one Launcher understands.
    static var saved: (keyCode: UInt32, modifiers: UInt32) {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Defaults.hotKeyCode) != nil else { return defaultKey }
        let keyCode = defaults.integer(forKey: Defaults.hotKeyCode), modifiers = defaults.integer(forKey: Defaults.hotKeyModifiers)
        let known = cmdKey | shiftKey | optionKey | controlKey
        guard (0...0x7F).contains(keyCode), modifiers & ~known == 0,
              allowed(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers)) else { return defaultKey }
        return (UInt32(keyCode), UInt32(modifiers))
    }

    /// Whether a shortcut may become the global one. It must not take over typing or other apps' shortcuts: a key
    /// needs ⌘ with another modifier (⌥⌘L, ⇧⌘L) or ⌃⌥ (⌃⌥L), because ⌘L belongs to apps, ⌥L types a character and
    /// ⌃L is a text-editing key. Space only needs one: ⌘Space, ⌥Space and ⌃Space are the usual ways to open a
    /// launcher, except ⌃⌘Space, which opens Emoji & Symbols. Function keys need none.
    static func allowed(keyCode: UInt32, modifiers: UInt32) -> Bool {
        if functionKeys.contains(Int(keyCode)) { return true }
        let command = modifiers & UInt32(cmdKey) != 0, control = modifiers & UInt32(controlKey) != 0
        let option = modifiers & UInt32(optionKey) != 0, shift = modifiers & UInt32(shiftKey) != 0
        if keyCode == UInt32(kVK_Space) {
            return (command || control || option) && !(command && control && !option && !shift)
        }
        return (command && (control || option || shift)) || (control && option)
    }
}

private let functionKeys: Set<Int> = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                                      kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]

private func keyName(_ keyCode: UInt32) -> String {
    let code = Int(keyCode)
    switch code {
    case kVK_Return: return "↩"
    case kVK_ANSI_KeypadEnter: return "⌤"
    case kVK_Tab: return "⇥"
    case kVK_Space: return "Space"
    case kVK_Delete: return "⌫"
    case kVK_ForwardDelete: return "⌦"
    case kVK_Escape: return "⎋"
    case kVK_LeftArrow: return "←"
    case kVK_RightArrow: return "→"
    case kVK_UpArrow: return "↑"
    case kVK_DownArrow: return "↓"
    case kVK_Home: return "↖"
    case kVK_End: return "↘"
    case kVK_PageUp: return "⇞"
    case kVK_PageDown: return "⇟"
    default: break
    }
    if functionKeys.contains(code) {
        let f = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
                 kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        return "F" + String(f.firstIndex(of: code)! + 1)
    }
    // Everything else: ask the keyboard layout which character the key types.
    var name = ""
    if let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
       let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData),
       let bytes = CFDataGetBytePtr(Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()) {
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            _ = UCKeyTranslate(layout, UInt16(truncatingIfNeeded: keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                               OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, 4, &length, &chars)
        }
        if length > 0 { name = String(utf16CodeUnits: chars, count: length).uppercased() }
    }
    return name.isEmpty ? "Key \(keyCode)" : name
}

private func modifierNames(_ modifiers: UInt32) -> String {
    var s = ""
    if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
    if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
    if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
    if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
    return s
}

func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
    var modifiers: UInt32 = 0
    if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
    if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
    if flags.contains(.option) { modifiers |= UInt32(optionKey) }
    if flags.contains(.control) { modifiers |= UInt32(controlKey) }
    return modifiers
}

/// The key an event's shortcut refers to, such as "c" for ⌘C, also on non-Latin keyboard layouts.
func keyCharacter(_ event: NSEvent) -> String {
    if let characters = event.charactersIgnoringModifiers?.lowercased(), characters.unicodeScalars.count == 1,
       characters.unicodeScalars.first!.isASCII {
        return characters
    }
    // Non-Latin layouts: use the key's letter in the ASCII-capable layout, as menus do.
    return keyName(UInt32(event.keyCode)).lowercased()
}

func shortcutName(keyCode: UInt32, modifiers: UInt32) -> String {
    modifierNames(modifiers) + (keyCode == UInt32(kVK_Space) && modifiers != 0 ? "Space" : keyName(keyCode))
}

/// A field that records a new shortcut when clicked.
final class ShortcutField: CanvasView {
    var keyCode: UInt32 = 0 { didSet { needsDisplay = true } }
    var modifiers: UInt32 = 0 { didSet { needsDisplay = true } }
    private(set) var recording = false
    weak var returnResponder: NSResponder?  // gets the keyboard back after recording
    var onChange: (() -> Void)?
    private var live: UInt32 = 0            // modifiers held while recording

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.14) : NSColor.labelColor.withAlphaComponent(0.08)).setFill()
        path.fill()
        if recording {
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        let text = recording ? (live != 0 ? modifierNames(live) : "Type shortcut") : shortcutName(keyCode: keyCode, modifiers: modifiers)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: recording ? .regular : .medium),
            .foregroundColor: recording ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: (bounds.midX - size.width / 2).rounded(), y: (bounds.midY - size.height / 2).rounded()), withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        if recording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        window?.makeFirstResponder(self)
        recording = true
        live = 0
        HotKey.unregister()  // so pressing the current shortcut records it instead of closing Launcher
        needsDisplay = true
    }

    private func stopRecording() {
        guard recording else { return }
        recording = false
        live = 0
        HotKey.register(keyCode: keyCode, modifiers: modifiers)
        needsDisplay = true
        onChange?()
        handBack()
    }

    private func handBack() {
        if window?.firstResponder === self { window?.makeFirstResponder(returnResponder) }
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        guard recording else { return super.flagsChanged(with: event) }
        live = carbonModifiers(event.modifierFlags)
        needsDisplay = true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        record(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { return super.keyDown(with: event) }
        record(event)
    }

    private func record(_ event: NSEvent) {
        let modifiers = carbonModifiers(event.modifierFlags)
        let keyCode = UInt32(event.keyCode)
        if modifiers == 0 && (keyCode == UInt32(kVK_Escape) || keyCode == UInt32(kVK_Delete)) {
            stopRecording()
            return
        }
        guard HotKey.allowed(keyCode: keyCode, modifiers: modifiers) else {
            NSSound.beep()
            return
        }
        guard HotKey.register(keyCode: keyCode, modifiers: modifiers) else {
            NSSound.beep()
            stopRecording()
            return
        }
        recording = false
        live = 0
        self.keyCode = keyCode
        self.modifiers = modifiers
        UserDefaults.standard.set(Int(keyCode), forKey: Defaults.hotKeyCode)
        UserDefaults.standard.set(Int(modifiers), forKey: Defaults.hotKeyModifiers)
        needsDisplay = true
        onChange?()
        handBack()
    }

    // VoiceOver: a button that starts recording.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "Shortcut to open Launcher" }
    override func accessibilityValue() -> Any? { recording ? "Type shortcut" : shortcutName(keyCode: keyCode, modifiers: modifiers) }
    override func accessibilityPerformPress() -> Bool {
        if !recording { startRecording() }
        return true
    }
}
