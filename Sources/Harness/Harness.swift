// Test harness (built only by `make harness`): LauncherTest reads commands from standard input and answers on
// standard output. Its window never takes the keyboard and opens only on a Mac's built-in display, so testing can't
// catch what someone types in other apps or cover the screens they work on.
//
//   apps <path>|<path>…   the added apps          open | settings | close   show or hide the window
//   type <text>           typing                  key <name> [cmd|shift|opt|ctrl…]   return, escape, up, down…
//   state                 window, rows, selection snap <file.png>        a picture of the window
//   appearance light|dark|system                  footprint              memory in use (bytes)
//   bench <n>             open + type + close n times, with timings     wait <ms>   quit
//   offscreen on|off      keep the window out of sight (long runs)

import AppKit
import Carbon

@MainActor private var harnessPopup: Popup?

private func reply(_ text: String) {
    print(text)
    fflush(stdout)
}

private func builtInScreen() -> NSScreen? {
    NSScreen.screens.first { screen in
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
        return CGDisplayIsBuiltin(number.uint32Value) != 0
    }
}

private func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
}

private let keyCodes: [String: Int] = [
    "return": kVK_Return, "enter": kVK_ANSI_KeypadEnter, "escape": kVK_Escape, "up": kVK_UpArrow, "down": kVK_DownArrow,
    "pageup": kVK_PageUp, "pagedown": kVK_PageDown, "home": kVK_Home, "end": kVK_End, "delete": kVK_Delete, "tab": kVK_Tab,
    "space": kVK_Space, ",": kVK_ANSI_Comma, "q": kVK_ANSI_Q, "w": kVK_ANSI_W, "v": kVK_ANSI_V, "c": kVK_ANSI_C, "n": kVK_ANSI_N,
    "p": kVK_ANSI_P, "left": kVK_LeftArrow, "right": kVK_RightArrow, "fdelete": kVK_ForwardDelete, "a": kVK_ANSI_A, "e": kVK_ANSI_E,
    "b": kVK_ANSI_B, "f": kVK_ANSI_F, "k": kVK_ANSI_K, "d": kVK_ANSI_D, "h": kVK_ANSI_H, "x": kVK_ANSI_X,
]

@MainActor
private func send(keyCode: Int, characters: String, flags: NSEvent.ModifierFlags) {
    guard let popup = harnessPopup, let panel = popup.panel,
          let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: panel.windowNumber, context: nil, characters: characters,
                                       charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(keyCode))
    else { return }
    // As AppKit routes it: key equivalents first, then the first responder.
    if flags.contains(.command) && panel.performKeyEquivalent(with: event) { return }
    panel.firstResponder?.keyDown(with: event)
}

@MainActor
private func state() -> String {
    guard let popup = harnessPopup else { return "no popup" }
    var lines = ["open=\(popup.isOpen) settings=\(popup.settingsMode) query=[\(popup.field?.query ?? "")] selected=\(popup.selectedForTesting)"]
    if let editor = popup.field?.editorForTesting {
        lines.append("caret=\(editor.caret) selection=\(editor.selection.lowerBound)..<\(editor.selection.upperBound) [\(editor.selectedText)]")
    }
    if let panel = popup.panel, popup.isOpen {
        let f = panel.frame
        lines.append("frame=\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width))x\(Int(f.height)) key=\(panel.isKeyWindow) window=\(panel.windowNumber)")
    }
    for (index, row) in popup.rowsForTesting.enumerated() {
        switch row.kind {
        case .calc(_, let shown): lines.append("  \(index): = \(shown)")
        case .app(let path): lines.append("  \(index): \(row.name)\(row.checked.map { $0 ? " [x]" : " [ ]" } ?? "") (\(path)) bold=\(row.bold)")
        }
    }
    return lines.joined(separator: "\n")
}

@MainActor
private func run(_ line: String) {
    guard let popup = harnessPopup else { return }
    let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
    guard let command = parts.first else { return }
    let argument = parts.count > 1 ? parts[1] : ""
    switch command {
    case "apps":
        UserDefaults.standard.set(argument.split(separator: "|").map(String.init), forKey: Defaults.apps)
        popup.catalog.load()
        reply("ok \(popup.catalog.apps.count) apps")
    case "open", "settings":
        guard builtInScreen() != nil else {
            reply("error: no built-in display, not opening a window")
            return
        }
        if command == "open" { popup.show(settings: false) } else { popup.showSettings() }
        reply("ok")
    case "close":
        popup.close()
        reply("ok")
    case "type":
        for character in argument { send(keyCode: kVK_ANSI_A, characters: String(character), flags: []) }
        reply("ok")
    case "key":
        let words = argument.split(separator: " ").map(String.init)
        guard let name = words.first, let code = keyCodes[name] else {
            reply("error: unknown key")
            return
        }
        var flags: NSEvent.ModifierFlags = []
        for word in words.dropFirst() {
            switch word {
            case "cmd": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "opt": flags.insert(.option)
            case "ctrl": flags.insert(.control)
            default: break
            }
        }
        let characters = name.count == 1 ? name : name == "return" ? "\r" : name == "escape" ? "\u{1B}" : name == "tab" ? "\t" : name == "space" ? " " : ""
        send(keyCode: code, characters: characters, flags: flags)
        reply("ok")
    case "state":
        reply(state())
    case "snap":
        guard let panel = popup.panel, popup.isOpen else {
            reply("error: not open")
            return
        }
        // Let Core Animation put the newest drawing on screen first.
        let number = panel.windowNumber
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-x", "-o", "-l\(number)", argument]
            try? task.run()
            task.waitUntilExit()
            reply("ok")
        }
    case "appearance":
        NSApp.appearance = argument == "dark" ? NSAppearance(named: .darkAqua) : argument == "light" ? NSAppearance(named: .aqua) : nil
        reply("ok")
    case "press":
        // A button by its title, as VoiceOver presses it.
        guard let root = popup.panel?.contentView else {
            reply("error: not pressable")
            return
        }
        func find(_ view: NSView) -> FlatButton? {
            if let button = view as? FlatButton, button.title == argument { return button }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        guard let button = find(root) else {
            reply("error: no button \(argument)")
            return
        }
        reply(button.isEnabled ? "pressed" : "disabled")
        _ = button.accessibilityPerformPress()
    case "offscreen":
        popup.offscreenForTesting = argument != "off"
        reply("ok")
    case "footprint":
        reply("\(footprint())")
    case "bench":
        guard builtInScreen() != nil else {
            reply("error: no built-in display, not opening a window")
            return
        }
        let rounds = max(1, Int(argument) ?? 20)
        var openTimes: [Double] = [], typeTimes: [Double] = [], closeTimes: [Double] = []
        for _ in 0..<rounds {
            var start = CACurrentMediaTime()
            popup.show(settings: false)
            popup.panel?.displayIfNeeded()
            openTimes.append((CACurrentMediaTime() - start) * 1000)
            start = CACurrentMediaTime()
            for character in "ca" { send(keyCode: kVK_ANSI_A, characters: String(character), flags: []) }
            popup.panel?.displayIfNeeded()
            typeTimes.append((CACurrentMediaTime() - start) * 1000 / 2)
            start = CACurrentMediaTime()
            popup.close()
            closeTimes.append((CACurrentMediaTime() - start) * 1000)
        }
        func summary(_ values: [Double]) -> String {
            let sorted = values.sorted()
            return String(format: "median %.2f ms, max %.2f ms", sorted[sorted.count / 2], sorted.last ?? 0)
        }
        reply("open: \(summary(openTimes)); per keystroke: \(summary(typeTimes)); close: \(summary(closeTimes))")
    case "click":  // a click on a row, as the pointer would make it
        popup.listDidClick(Int(argument) ?? 0, onCheck: false)
        reply("ok")
    case "recents":
        reply(UserDefaults.standard.stringArray(forKey: Defaults.recents)?.joined(separator: " | ") ?? "(none)")
    case "pasteboard":
        reply(popup.pasteboard.string(forType: .string) ?? "(empty)")
    case "quit":
        popup.close()
        popup.pasteboard.releaseGlobally()
        reply("ok")
        exit(0)
    default:
        reply("error: unknown command \(command)")
    }
}

@MainActor
func startHarness(_ popup: Popup) {
    harnessPopup = popup
    Panel.takesKeyboard = false
    popup.screenChooser = builtInScreen
    // Never a real app: Return and clicks only report what they would open.
    popup.openForTesting = { path in reply("would open \(path)") }
    // Never the real clipboard: tests copy results and paste text.
    popup.pasteboard = NSPasteboard(name: NSPasteboard.Name("app.launcher.test.\(getpid())"))
    HotKey.testing = true  // the test copy never registers the real shortcut
    let input = FileHandle.standardInput
    Thread.detachNewThread {
        while let line = readLine() {
            let command = line.trimmingCharacters(in: .whitespaces)
            if command.isEmpty { continue }
            if command.hasPrefix("wait ") {  // pauses the commands that follow, not the app
                usleep(UInt32(max(0, min(60_000, Int(command.dropFirst(5)) ?? 0))) * 1000)
                continue
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { run(command) } }
        }
        DispatchQueue.main.async { exit(0) }  // the pipe closed
    }
    _ = input
    reply("ready")
}
