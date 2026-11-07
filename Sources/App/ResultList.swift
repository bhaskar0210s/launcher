// The rows under the search line: apps (with the typed letters in bold) and the calculator's answer. In Settings
// the same list shows a check mark on each app that Pounce looks through. Drawn on the CPU, scrolled by Pounce.

import AppKit
import CoreText

struct ResultRow {
    enum Kind {
        case app(String)           // path
        case calc(Double, String)  // the value, and how it's shown
    }
    var kind: Kind
    var name = ""
    var bold: [Int] = []
    var checked: Bool?             // Settings: whether the app is added
    var line: CTLine?              // built on first draw

    var path: String? {
        if case .app(let path) = kind { return path }
        return nil
    }
}

@MainActor
protocol ResultListDelegate: AnyObject {
    /// A click on a row; `onCheck` when it landed on the row's circle (Settings).
    func listDidClick(_ row: Int, onCheck: Bool)
    func icon(for path: String, points: CGFloat, scale: CGFloat) -> CGImage?
}

let gutter: CGFloat = 6        // between the window's edge and a row's highlight
private let inset: CGFloat = 10  // between a highlight's edge and its contents

final class ResultList: CanvasView {
    weak var delegate: ResultListDelegate?
    var rowHeight: CGFloat = 44
    var iconSize: CGFloat = 28
    var font = NSFont.systemFont(ofSize: 15)
    var boldFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
    var emptyText = ""
    var accessibilityName = "Results"
    private(set) var rows: [ResultRow] = []
    private var offset: CGFloat = 0
    private var pressed = -1
    private var elements: [NSAccessibilityElement]?  // the rows for VoiceOver, made when it first asks
    /// The row under the pointer, lightly highlighted. It is not the selection: only the keyboard and clicks move
    /// that, so a nudge of the mouse never changes what Return opens or what Remove removes.
    private var hovered = -1 { didSet { if hovered != oldValue { needsDisplay = true } } }

    var onSelectionChange: (() -> Void)?
    var selected = -1 {
        didSet {
            guard selected != oldValue else { return }
            needsDisplay = true
            selectionChangedForAccessibility()
            onSelectionChange?()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.masksToBounds = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var contentHeight: CGFloat { rows.isEmpty ? 0 : CGFloat(rows.count) * rowHeight + 2 * gutter }

    /// New rows, with the first one selected (`select`) or none until an arrow key or the pointer picks one.
    func setRows(_ rows: [ResultRow], select: Bool = true) {
        self.rows = rows
        elements = nil
        offset = 0
        hovered = -1
        selected = rows.isEmpty || !select ? -1 : 0
        needsDisplay = true
    }

    func setChecked(_ checked: Bool, at index: Int) {
        guard rows.indices.contains(index) else { return }
        rows[index].checked = checked
        elements = nil
        needsDisplay = true
        onSelectionChange?()
    }

    func clear() {
        rows = []
        elements = nil
        selected = -1
        hovered = -1
        offset = 0
    }

    func rect(ofRow index: Int) -> NSRect {
        NSRect(x: gutter, y: gutter + CGFloat(index) * rowHeight - offset, width: bounds.width - 2 * gutter, height: rowHeight)
    }

    private func row(at point: NSPoint) -> Int {
        guard point.x >= gutter, point.x <= bounds.width - gutter, point.y >= 0, point.y <= bounds.height else { return -1 }
        let index = Int(((point.y + offset - gutter) / rowHeight).rounded(.down))
        return point.y + offset - gutter >= 0 && index < rows.count ? index : -1
    }

    func move(to index: Int) {
        guard !rows.isEmpty else { return }
        selected = min(max(index, 0), rows.count - 1)
        scrollToSelection()
    }

    func scrollToSelection() {
        guard selected >= 0 else { return }
        let top = gutter + CGFloat(selected) * rowHeight
        if top - gutter < offset {
            scroll(to: top - gutter)
        } else if top + rowHeight + gutter > offset + bounds.height {
            scroll(to: top + rowHeight + gutter - bounds.height)
        }
    }

    private func scroll(to target: CGFloat) {
        let target = min(max(target, 0), max(0, contentHeight - bounds.height))
        if target == offset { return }
        offset = target
        if let elements {
            for (index, element) in elements.enumerated() { element.setAccessibilityFrameInParentSpace(rect(ofRow: index)) }
        }
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let width = bounds.width
        if rows.isEmpty {
            if !emptyText.isEmpty {
                let size = textWidth(emptyText, size: 13)
                drawText(emptyText, x: ((width - size) / 2).rounded(), midY: bounds.midY, size: 13, color: .secondaryLabelColor)
            }
            return
        }
        let scale = window?.backingScaleFactor ?? 2
        let label = resolved(.labelColor), selectedText = white.cgColor
        let secondary = resolved(.secondaryLabelColor), selectedSecondary = white.withAlphaComponent(0.8).cgColor
        let first = max(0, Int(((dirtyRect.minY + offset - gutter) / rowHeight).rounded(.down)))
        let last = min(rows.count - 1, Int(((dirtyRect.maxY + offset - gutter) / rowHeight).rounded(.down)))
        guard first <= last else { return }

        for index in first...last {
            let isSelected = index == selected
            let box = rect(ofRow: index)
            if isSelected {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
            } else if index == hovered {
                NSColor.labelColor.withAlphaComponent(0.07).setFill()
                NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
            }
            let iconBox = NSRect(x: box.minX + inset, y: (box.midY - iconSize / 2).rounded(), width: iconSize, height: iconSize)
            var right = box.maxX - inset
            let x = iconBox.maxX + 10

            switch rows[index].kind {
            case .calc(_, let shown):
                // A tile with an equals sign, where an app has its icon.
                let tile = iconBox.insetBy(dx: iconSize * 0.06, dy: iconSize * 0.06)
                (isSelected ? white.withAlphaComponent(0.22) : NSColor.labelColor.withAlphaComponent(0.1)).setFill()
                NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.24, yRadius: tile.width * 0.24).fill()
                drawGlyph(.equals, in: tile.insetBy(dx: tile.width * 0.2, dy: tile.width * 0.2), color: isSelected ? white : .labelColor)
                let hint = makeLine("↩ Copy", font: NSFont.systemFont(ofSize: 12))
                let hintWidth = lineWidth(hint)
                drawLine(context, hint, x: right - hintWidth, top: box.minY, height: box.height, font: NSFont.systemFont(ofSize: 12),
                         color: isSelected ? selectedSecondary : secondary)
                right -= hintWidth + 12
                let resultFont = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize + 2, weight: .medium)
                let line = rows[index].line ?? makeLine(shown, font: resultFont, bold: resultFont, emphasized: [], width: right - x)
                rows[index].line = line
                drawLine(context, line, x: x, top: box.minY, height: box.height, font: resultFont, color: isSelected ? selectedText : label)

            case .app(let path):
                if let icon = delegate?.icon(for: path, points: iconSize, scale: scale) {
                    context.saveGState()
                    context.interpolationQuality = .high
                    // The view is flipped; a CGImage is drawn upright by flipping it back within its box.
                    context.translateBy(x: iconBox.minX, y: iconBox.maxY)
                    context.scaleBy(x: 1, y: -1)
                    context.draw(icon, in: CGRect(x: 0, y: 0, width: iconBox.width, height: iconBox.height))
                    context.restoreGState()
                }
                if let checked = rows[index].checked {
                    let circle = NSRect(x: right - 20, y: (box.midY - 10).rounded(), width: 20, height: 20)
                    drawCheck(checked, in: circle, onAccent: isSelected)
                    right = circle.minX - 12
                }
                let line = rows[index].line ?? makeLine(rows[index].name, font: font, bold: boldFont, emphasized: rows[index].bold, width: right - x)
                rows[index].line = line
                drawLine(context, line, x: x, top: box.minY, height: box.height, font: font, color: isSelected ? selectedText : label)
            }
        }

        // A slim scroll indicator when there are more rows than fit.
        let height = bounds.height
        if contentHeight > height + 0.5 {
            let knob = max(24, height * height / contentHeight)
            let y = (height - knob) * offset / (contentHeight - height)
            NSColor.tertiaryLabelColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: width - 5, y: y + 2, width: 3, height: knob - 4), xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    /// A filled circle with a check mark for an added app, an empty ring for the others.
    private func drawCheck(_ checked: Bool, in circle: NSRect, onAccent: Bool) {
        if checked {
            (onAccent ? white : NSColor.controlAccentColor).setFill()
            NSBezierPath(ovalIn: circle).fill()
            drawGlyph(.check, in: circle.insetBy(dx: 3, dy: 3), color: onAccent ? .controlAccentColor : white)
        } else {
            let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            (onAccent ? white.withAlphaComponent(0.85) : NSColor.tertiaryLabelColor).setStroke()
            ring.stroke()
        }
    }

    // MARK: Mouse

    private func row(for event: NSEvent) -> Int {
        row(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        hovered = row(for: event)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = -1
    }

    override func mouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        pressed = row(for: event)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        if row >= 0 && row == pressed {
            // The circle sits at the right end of a Settings row; the area around it counts, for easy clicking.
            let onCheck = rows[row].checked != nil && point.x >= rect(ofRow: row).maxX - inset - 36
            delegate?.listDidClick(row, onCheck: onCheck)
        }
        pressed = -1
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * rowHeight
        scroll(to: offset - delta)
        hovered = row(for: event)  // the rows moved under the pointer
    }

    // MARK: VoiceOver

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .list }
    override func accessibilityLabel() -> String? { accessibilityName }

    override func accessibilityChildren() -> [Any]? {
        if let elements { return elements }
        let made = rows.indices.map { index in
            let row = rows[index]
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(row.checked == nil ? .staticText : .checkBox)
            element.setAccessibilityParent(self)
            switch row.kind {
            case .calc(_, let shown): element.setAccessibilityLabel("Result \(shown). Press Return to copy it.")
            case .app: element.setAccessibilityLabel(row.name)
            }
            if let checked = row.checked { element.setAccessibilityValue(NSNumber(value: checked)) }
            element.setAccessibilityFrameInParentSpace(rect(ofRow: index))
            element.setAccessibilitySelected(index == selected)
            return element
        }
        elements = made
        return made
    }

    override func accessibilitySelectedChildren() -> [Any]? {
        guard let elements = accessibilityChildren() as? [NSAccessibilityElement], elements.indices.contains(selected) else { return [] }
        return [elements[selected]]
    }

    /// Keeps VoiceOver with the selection: the keyboard stays in the search line while the arrows move it.
    private func selectionChangedForAccessibility() {
        guard let elements else { return }
        for (index, element) in elements.enumerated() { element.setAccessibilitySelected(index == selected) }
        NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
        if NSWorkspace.shared.isVoiceOverEnabled, elements.indices.contains(selected), let label = elements[selected].accessibilityLabel() {
            NSAccessibility.post(element: self, notification: .announcementRequested,
                                 userInfo: [.announcement: label, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }
}
