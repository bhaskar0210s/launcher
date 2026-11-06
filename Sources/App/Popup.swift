// The window: opens in the middle of the main display, finds the added apps as you type, works out arithmetic, and
// opens the selected app with Return. Settings (⌘,) open inside the same window.

import AppKit
import Carbon
import QuartzCore

private let width: CGFloat = 600
private let radius: CGFloat = 16
private let fieldHeight: CGFloat = 56
private let rowHeight: CGFloat = 44
private let maxRows = 8
private let settingsRowHeight: CGFloat = 38
private let settingsVisibleRows = 8
private let footerHeight: CGFloat = 40
let iconPoints: CGFloat = 28

let tracing = getenv("LAUNCHER_TRACE") != nil

/// Drawn once into an sRGB bitmap: a mask drawn on demand would be converted by Core Animation for every window.
@MainActor
private func roundedMask(_ radius: CGFloat) -> NSImage {
    let side = radius * 2 + 1, scale: CGFloat = 2
    let pixels = Int(side * scale)
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(black.cgColor)
    context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: pixels, height: pixels), cornerWidth: radius * scale,
                           cornerHeight: radius * scale, transform: nil))
    context.fillPath()
    let mask = NSImage(cgImage: context.makeImage()!, size: NSSize(width: side, height: side))
    mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    mask.resizingMode = .stretch
    return mask
}

final class Panel: NSPanel {
    weak var popup: Popup?
    nonisolated(unsafe) static var takesKeyboard = true  // false in the test harness

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        // A fixed depth and color space. Left to the screen's, AppKit and Core Animation convert through a fresh
        // ColorSync transform for each new window and keep its lookup table. Launcher draws in 8-bit sRGB anyway.
        setDynamicDepthLimit(false)
        depthLimit = .twentyfourBitRGB
        colorSpace = .sRGB
        title = "Launcher"
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none  // appear and vanish instantly
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle, .transient]
    }

    override var canBecomeKey: Bool { Panel.takesKeyboard }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if popup?.recording == true { return super.performKeyEquivalent(with: event) }  // the shortcut field takes every key
        return popup?.handleKeyEquivalent(event) == true || super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class Popup: NSObject, NSWindowDelegate, SearchFieldDelegate, ResultListDelegate {
    let catalog: Catalog
    private var picks: Picks
    private let defaults: UserDefaults

    // The window is built only when it opens and torn down when it closes, so a closed Launcher holds no views.
    private(set) var panel: Panel?
    private var content: FlippedView?
    private(set) var field: SearchField?
    private var topRule: Rule?
    private var bottomRule: Rule?
    private(set) var list: ResultList?
    private(set) var page: SettingsPage?
    private var footer: SettingsFooter?
    private(set) var isOpen = false
    private(set) var settingsMode = false
    private var removedHere: [String] = []  // unchecked in Settings this time: kept in the list to check again
    private var adding = false               // Settings list every installed app, to add some
    private var left: CGFloat = 0, top: CGFloat = 0  // the window's top-left corner while it is open
    private var visible = NSRect.zero                // the part of its screen the window may use
    var screenChooser: (() -> NSScreen?)?           // the test harness picks the screen itself
    var offscreenForTesting = false                 // and can keep the window out of sight during long runs
    var pasteboard = NSPasteboard.general           // and copies to a pasteboard of its own
    private var numbers: (locale: String, grouping: NumberFormatter, decimal: String)?

    init(catalog: Catalog, defaults: UserDefaults = .standard) {
        self.catalog = catalog
        self.defaults = defaults
        picks = Picks(serialized: defaults.stringArray(forKey: Defaults.picks) ?? [])
    }

    var recording: Bool { page?.recording == true }

    private func build() {
        guard panel == nil else { return }
        let panel = Panel(frame: NSRect(x: 0, y: 0, width: width, height: fieldHeight))
        panel.popup = self
        panel.delegate = self
        let content = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: fieldHeight))
        let field = SearchField(frame: .zero)
        field.delegate = self
        field.pasteboard = pasteboard
        content.addSubview(field)
        let topRule = Rule(frame: .zero), bottomRule = Rule(frame: .zero)
        content.addSubview(topRule)
        content.addSubview(bottomRule)
        let list = ResultList(frame: .zero)
        list.delegate = self
        content.addSubview(list)

        let effect = NSVisualEffectView(frame: content.frame)
        effect.material = .menu
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.maskImage = roundedMask(radius)
        content.autoresizingMask = [.width, .height]
        effect.addSubview(content)
        panel.contentView = effect
        (self.panel, self.content, self.field, self.topRule, self.bottomRule, self.list) = (panel, content, field, topRule, bottomRule, list)
    }

    private func releaseWindow() {
        guard !isOpen, let panel else { return }
        panel.delegate = nil
        panel.contentView = nil
        self.panel = nil
        (content, field, topRule, bottomRule, list, page, footer) = (nil, nil, nil, nil, nil, nil, nil)
    }

    // MARK: Showing

    func toggle() {
        if isOpen { close() } else { show(settings: false) }
    }

    func showSettings() {
        if isOpen {
            if !settingsMode { setSettings(true) }
            return
        }
        show(settings: true)
    }

    func show(settings: Bool) {
        let start = CACurrentMediaTime()
        // The test harness picks the screen itself, and nothing opens when it finds none.
        guard let screen = screenChooser.map({ $0() }) ?? mainScreen() else { return }
        build()
        guard let panel else { return }
        catalog.refreshIfChanged()
        field?.clear()
        removedHere = []
        adding = false
        settingsMode = settings
        applyMode()
        refresh()

        // The search line sits in the middle of the display, both ways; results and settings extend below it, so it
        // never moves while you type. It stays clear of the menu bar and the Dock.
        visible = screen.visibleFrame
        let middle = screen.frame
        left = min(max((middle.midX - width / 2).rounded(), visible.minX), visible.maxX - width)
        top = min((middle.midY + fieldHeight / 2).rounded(), visible.maxY)
        if offscreenForTesting { (left, top) = (-30_000, 30_000) }
        layout()

        isOpen = true
        panel.orderFrontRegardless()
        if Panel.takesKeyboard { panel.makeKey() }
        panel.makeFirstResponder(field)
        if tracing { NSLog("open %.2f ms", (CACurrentMediaTime() - start) * 1000) }
    }

    /// The display with the menu bar (the main display in System Settings › Displays), whatever has the pointer or
    /// the focus.
    private func mainScreen() -> NSScreen? {
        let main = CGMainDisplayID()
        return NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == main }
            ?? NSScreen.screens.first
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        // Launcher becomes the active app only when it is opened from Finder: hand the keyboard back to the app that
        // had it.
        if NSApp.isActive { NSApp.hide(nil) }
        if recording { panel?.makeFirstResponder(field) }  // ends the recording and registers the shortcut again
        panel?.close()
        list?.clear()
        if settingsMode {
            catalog.trimIcons()
            catalog.forgetInstalled()
        }
        // The window goes once AppKit is done with it, then the freed memory goes back to the system.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.releaseWindow() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                if let self, !self.isOpen { malloc_zone_pressure_relief(nil, 0) }
            }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    private func setSettings(_ on: Bool) {
        if !on {
            catalog.trimIcons()
            catalog.forgetInstalled()
        }
        settingsMode = on
        adding = false
        removedHere = []
        field?.clear()
        applyMode()
        refresh()
        layout()
        panel?.makeFirstResponder(field)
    }

    private func applyMode() {
        guard let content, let field, let list else { return }
        if settingsMode && page == nil {
            let page = SettingsPage(frame: .zero)
            page.returnResponder = field
            page.onLayoutChange = { [weak self] in self?.layout() }
            content.addSubview(page)
            let footer = SettingsFooter(frame: .zero)
            footer.onAdd = { [weak self] in self?.toggleAdding() }
            footer.onRemove = { [weak self] in self?.removeSelected() }
            content.addSubview(footer)
            (self.page, self.footer) = (page, footer)
            list.onSelectionChange = { [weak self] in self?.updateFooter() }
        }
        if settingsMode { page?.refresh() }
        page?.isHidden = !settingsMode
        footer?.isHidden = !settingsMode
        bottomRule?.isHidden = !settingsMode
        field.badge = settingsMode ? "Settings" : ""
        applyAddingLabels()
        list.rowHeight = settingsMode ? settingsRowHeight : rowHeight
        list.iconSize = settingsMode ? 22 : iconPoints
        list.font = NSFont.systemFont(ofSize: settingsMode ? 13 : 15)
        list.boldFont = NSFont.systemFont(ofSize: settingsMode ? 13 : 15, weight: .semibold)
        list.accessibilityName = settingsMode ? "Apps" : "Results"
    }

    private func layout() {
        guard let panel, let content, let field, let list else { return }
        var height = fieldHeight
        field.frame = NSRect(x: 0, y: 0, width: width, height: fieldHeight)
        var listHeight: CGFloat = 0
        if settingsMode {
            listHeight = list.rows.isEmpty ? 64 : min(list.contentHeight, CGFloat(settingsVisibleRows) * settingsRowHeight + 2 * gutter)
        } else if !list.rows.isEmpty {
            listHeight = list.contentHeight
        } else if !(field.query.isEmpty) {
            listHeight = 44  // room for "No match"
        }
        topRule?.isHidden = listHeight == 0 && !settingsMode
        topRule?.frame = NSRect(x: 0, y: fieldHeight - 0.5, width: width, height: 1)
        if settingsMode, let page, let footer, let bottomRule {
            page.frame = NSRect(x: 0, y: height, width: width, height: page.preferredHeight)
            height += page.preferredHeight
            list.frame = NSRect(x: 0, y: height, width: width, height: listHeight)
            height += listHeight
            bottomRule.frame = NSRect(x: 0, y: height, width: width, height: 1)
            footer.frame = NSRect(x: 0, y: height + 1, width: width, height: footerHeight)
            height += 1 + footerHeight
        } else {
            list.frame = NSRect(x: 0, y: height, width: width, height: listHeight)
            height += listHeight
        }
        // On a short screen the list gives up rows, and the window moves up, so its bottom (with Add Apps, Remove and
        // Quit in Settings) stays on screen.
        if !offscreenForTesting && visible.height > 0 {
            let room = visible.height - 16
            if height > room {
                let cut = min(height - room, max(0, list.frame.height - (settingsMode ? settingsRowHeight : rowHeight) - 2 * gutter))
                height -= cut
                list.frame.size.height -= cut
                if settingsMode, let footer, let bottomRule {
                    bottomRule.frame.origin.y -= cut
                    footer.frame.origin.y -= cut
                }
            }
            top = min(max(top, visible.minY + 8 + height), visible.maxY)
        }
        panel.setFrame(NSRect(x: left, y: top - height, width: width, height: height), display: false, animate: false)
        content.frame = NSRect(x: 0, y: 0, width: width, height: height)
        list.scrollToSelection()
        panel.invalidateShadow()
    }

    // MARK: Searching

    /// How numbers are written where the user lives, always with the digits 0–9 (some regions use other digits,
    /// which would be mixed with these). Made again when the region changes.
    private var numberStyle: (grouping: NumberFormatter, decimal: String) {
        let current = Locale.current
        if let numbers, numbers.locale == current.identifier { return (numbers.grouping, numbers.decimal) }
        var components = Locale.Components(locale: current)
        components.numberingSystem = Locale.NumberingSystem("latn")
        let latin = Locale(components: components)
        let formatter = NumberFormatter()
        formatter.locale = latin
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        var decimal = latin.decimalSeparator ?? "."
        if decimal != "." && decimal != "," { decimal = "." }
        if formatter.groupingSeparator == decimal || formatter.groupingSeparator.isEmpty { formatter.groupingSeparator = decimal == "," ? "." : "," }
        numbers = (current.identifier, formatter, decimal)
        return (formatter, decimal)
    }

    private var decimalSeparator: Character {
        numberStyle.decimal.first ?? "."
    }

    private func refresh() {
        guard let list, let field else { return }
        let start = CACurrentMediaTime()
        let query = field.query
        var rows: [ResultRow] = []
        if settingsMode {
            if !adding && !Query(query).isEmpty {  // typing a name starts adding
                adding = true
                applyAddingLabels()
            }
            if !adding {
                var shown = catalog.apps.map { ResultRow(kind: .app($0.path), name: $0.name, checked: true) }
                for path in removedHere where !catalog.contains(path) {
                    shown.append(ResultRow(kind: .app(path), name: Catalog.displayName(path), checked: false))
                }
                rows = shown.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                list.emptyText = "No apps yet. Type a name above to add one."
            } else if Query(query).isEmpty {
                rows = catalog.installed().map { ResultRow(kind: .app($0.path), name: $0.name, checked: catalog.contains($0.path)) }
                list.emptyText = "No apps found"
            } else {
                let installed = catalog.installed()
                rows = rank(query, names: installed.map(\.name), haystacks: installed.map(\.haystack), limit: 60).map {
                    let app = installed[$0.index]
                    return ResultRow(kind: .app(app.path), name: app.name, bold: $0.positions, checked: catalog.contains(app.path))
                }
                list.emptyText = "No app named “\(query.trimmingCharacters(in: .whitespaces))”"
            }
            page?.appCount = catalog.apps.count
        } else {
            if let value = Calc.evaluate(query, decimal: decimalSeparator) {
                rows.append(ResultRow(kind: .calc(value, display(value)), name: ""))
            }
            let apps = catalog.apps
            let preferred = picks.key(for: query).flatMap { key in apps.firstIndex { $0.path == key } }
            rows += rank(query, names: apps.map(\.name), haystacks: apps.map(\.haystack), preferred: preferred, limit: maxRows - rows.count).map {
                ResultRow(kind: .app(apps[$0.index].path), name: apps[$0.index].name, bold: $0.positions)
            }
            list.emptyText = apps.isEmpty ? "No apps added yet. Press ⌘, to add some." : "No match. Press ⌘, to add apps."
        }
        // In Settings nothing is selected until there is something to look for: the list is for reading first.
        list.setRows(rows, select: !settingsMode || !Query(query).isEmpty)
        updateFooter()
        if tracing { NSLog("query [%@] %ld rows %.3f ms", query, rows.count, (CACurrentMediaTime() - start) * 1000) }
    }

    /// The result as people write numbers where they live: grouped digits and their decimal separator.
    private func display(_ value: Double) -> String {
        let plain = Calc.format(value)
        let (sign, whole, rest) = Calc.parts(plain)
        let style = numberStyle
        var grouped = whole
        if !rest.contains("e"), let number = Int64(whole), let text = style.grouping.string(from: NSNumber(value: number)) {
            grouped = text
        }
        return sign + grouped + (rest.hasPrefix(".") ? style.decimal + rest.dropFirst() : rest)
    }

    /// The result for pasting elsewhere: no grouping, the local decimal separator.
    private func plain(_ value: Double) -> String {
        let text = Calc.format(value)
        let decimal = numberStyle.decimal
        return decimal == "." ? text : text.replacingOccurrences(of: ".", with: decimal)
    }

    func queryChanged() {
        refresh()
        layout()
    }

    // MARK: Keys

    func runCommand(_ command: Selector) {
        guard let list else { return }
        switch command {
        case #selector(NSResponder.cancelOperation(_:)):
            if settingsMode {
                if field?.query.isEmpty == false {
                    field?.clear()
                    queryChanged()
                } else if adding {
                    toggleAdding()
                } else {
                    setSettings(false)
                }
            } else {
                close()
            }
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.insertBacktab(_:)): list.move(to: list.selected - 1)
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)): list.move(to: list.selected + 1)
        case #selector(NSResponder.moveToBeginningOfDocument(_:)), #selector(NSResponder.scrollToBeginningOfDocument(_:)): list.move(to: 0)
        case #selector(NSResponder.moveToEndOfDocument(_:)), #selector(NSResponder.scrollToEndOfDocument(_:)): list.move(to: list.rows.count - 1)
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)): list.move(to: list.selected - 8)
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)): list.move(to: list.selected + 8)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)): activate(list.selected)
        default: break
        }
    }

    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags == .command else { return false }
        switch keyCharacter(event) {
        case ",": setSettings(!settingsMode)
        case "q": NSApp.terminate(nil)
        case "w": close()
        case "v": field?.paste()
        case "c":
            if let row = list?.rows.first, case .calc(let value, _) = row.kind { copy(plain(value)) }
        default: return false
        }
        return true
    }

    // MARK: Actions

    /// In Settings a click on a row's circle adds or removes the app, and a click elsewhere selects it (for Remove);
    /// in the results a click opens the app.
    func listDidClick(_ row: Int, onCheck: Bool) {
        if settingsMode && !onCheck {
            list?.selected = row
            return
        }
        activate(row)
    }

    /// Icons are drawn once, at the size of the results, and scaled down for the smaller rows of Settings.
    func icon(for path: String, points: CGFloat, scale: CGFloat) -> CGImage? {
        catalog.icon(path, points: iconPoints, scale: scale)
    }

    private func activate(_ index: Int) {
        guard let list, let field, list.rows.indices.contains(index) else { return }
        let row = list.rows[index]
        if settingsMode {
            guard let path = row.path else { return }
            if catalog.contains(path) {
                catalog.remove(path)
                removedHere.append(path)
                picks.forget(key: path)
                defaults.set(picks.serialized, forKey: Defaults.picks)
            } else {
                catalog.add(path)
                removedHere.removeAll { $0 == path }
            }
            list.setChecked(catalog.contains(path), at: index)
            page?.appCount = catalog.apps.count
            updateFooter()
            return
        }
        switch row.kind {
        case .calc(let value, _):
            copy(plain(value))
            close()
        case .app(let path):
            picks.remember(query: field.query, key: path)
            defaults.set(picks.serialized, forKey: Defaults.picks)
            close()
            open(path)
        }
    }

    /// Add Apps: the list shows every installed app and the search line looks through them; Done (or Esc) goes back to
    /// the added apps.
    private func toggleAdding() {
        guard settingsMode else { return }
        adding.toggle()
        field?.clear()
        applyAddingLabels()
        refresh()
        layout()
        panel?.makeFirstResponder(field)
    }

    private func applyAddingLabels() {
        field?.placeholder = !settingsMode ? "Search" : adding ? "Search apps to add" : "Type an app’s name to add it"
        page?.adding = adding
        footer?.adding = adding
    }

    private func updateFooter() {
        guard let list, let footer else { return }
        footer.canRemove = settingsMode && list.rows.indices.contains(list.selected) && list.rows[list.selected].checked == true
    }

    /// Takes the selected app out of the list. It stays on screen, unchecked, until Settings close, so a click puts
    /// it back.
    private func removeSelected() {
        guard settingsMode, let list, list.rows.indices.contains(list.selected), list.rows[list.selected].checked == true else { return }
        activate(list.selected)
    }

    private func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Opens the app, or brings it to the front with its windows if it is already running.
    private func open(_ path: String) {
        let start = CACurrentMediaTime()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: configuration) { [weak self] _, error in
            guard let error else { return }
            NSLog("Launcher couldn't open %@: %@", path, error.localizedDescription)
            // The app was deleted or moved since the list was made: say so with the alert sound, and drop it.
            Task { @MainActor in
                NSSound.beep()
                self?.catalog.refreshIfChanged()
            }
        }
        if tracing { NSLog("open app %.2f ms", (CACurrentMediaTime() - start) * 1000) }
    }

    // MARK: For the test harness

    var rowsForTesting: [ResultRow] { list?.rows ?? [] }
    var selectedForTesting: Int { list?.selected ?? -1 }
}
