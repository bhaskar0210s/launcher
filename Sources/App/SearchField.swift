// The search line at the top of the window. Launcher reads the keyboard here itself (with input method support)
// instead of using a system text field: those bring the whole text system along, plus an AutoFill helper process.

import AppKit
import Carbon
import CoreText

@MainActor
protocol SearchFieldDelegate: AnyObject {
    func queryChanged()
    func runCommand(_ command: Selector)
}

private func usingInputMethod() -> Bool {
    guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
          let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceType)
    else { return false }
    let type = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    return [kTISTypeKeyboardInputMode, kTISTypeKeyboardInputMethodModeEnabled, kTISTypeKeyboardInputMethodWithoutModes]
        .contains { $0 as String == type }
}

/// One line: line breaks and tabs become spaces.
private func singleLine(_ string: Any) -> String {
    let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    return text.components(separatedBy: .newlines).joined(separator: " ").replacingOccurrences(of: "\t", with: " ")
}

@MainActor let fieldFont = NSFont.systemFont(ofSize: 20)

final class SearchField: CanvasView, @preconcurrency NSTextInputClient {
    weak var delegate: SearchFieldDelegate?
    private(set) var query = ""
    private var marked = ""  // an input method's composition, not part of the query yet
    private var caretX: CGFloat = 0

    var placeholder = "Search" { didSet { needsDisplay = true } }
    var badge = "" { didSet { needsDisplay = true } }  // a word at the right end, such as "Settings"

    override var acceptsFirstResponder: Bool { true }

    // With an ordinary keyboard layout Launcher reads keys itself and has no input context: a text input context
    // makes macOS start an AutoFill helper process (about 13 MB). Input methods (Chinese, Japanese, Korean…) need one
    // to compose text, so it exists only while one of them is the current input source.
    override var inputContext: NSTextInputContext? {
        usingInputMethod() ? super.inputContext : nil
    }

    func clear() {
        query = ""
        marked = ""
        inputContext?.discardMarkedText()
        needsDisplay = true
    }

    private func changed() {
        needsDisplay = true
        delegate?.queryChanged()
    }

    var pasteboard = NSPasteboard.general  // the test harness uses one of its own

    func paste() {
        guard var text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        if text.utf16.count > 500 {
            let ns = text as NSString
            text = ns.substring(to: ns.rangeOfComposedCharacterSequence(at: 500).location)
        }
        if !marked.isEmpty {  // an input method's unfinished text gives way to what is pasted
            inputContext?.discardMarkedText()
            marked = ""
        }
        query += singleLine(text)
        changed()
    }

    override func keyDown(with event: NSEvent) {
        if inputContext != nil {
            interpretKeyEvents([event])
            return
        }
        let flags = event.modifierFlags
        let option = flags.contains(.option), command = flags.contains(.command), control = flags.contains(.control)
        var selector: Selector?
        switch Int(event.keyCode) {
        case kVK_UpArrow: selector = #selector(moveUp(_:))
        case kVK_DownArrow: selector = #selector(moveDown(_:))
        case kVK_PageUp: selector = #selector(pageUp(_:))
        case kVK_PageDown: selector = #selector(pageDown(_:))
        case kVK_Home: selector = #selector(moveToBeginningOfDocument(_:))
        case kVK_End: selector = #selector(moveToEndOfDocument(_:))
        case kVK_Return, kVK_ANSI_KeypadEnter: selector = #selector(insertNewline(_:))
        case kVK_Escape: selector = #selector(cancelOperation(_:))
        case kVK_Tab: selector = flags.contains(.shift) ? #selector(moveUp(_:)) : #selector(moveDown(_:))
        case kVK_Delete:
            selector = option ? #selector(deleteWordBackward(_:)) : command ? #selector(deleteToBeginningOfLine(_:)) : #selector(deleteBackward(_:))
        case kVK_ANSI_N where control: selector = #selector(moveDown(_:))
        case kVK_ANSI_P where control: selector = #selector(moveUp(_:))
        default: break
        }
        if let selector {
            doCommand(by: selector)
            return
        }
        if command || control { return }
        // Printable characters only (the keyboard layout has already applied dead keys such as ⌥E E → é).
        let text = String(String.UnicodeScalarView((event.characters ?? "").unicodeScalars.filter {
            $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value)
        }))
        if !text.isEmpty { insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0)) }
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = singleLine(string)
        marked = ""
        guard !text.isEmpty else {
            needsDisplay = true
            return
        }
        query += text
        changed()
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(deleteBackward(_:)):
            if query.isEmpty { return }
            query.removeLast()  // one character, as people see it
        case #selector(deleteWordBackward(_:)):
            if query.isEmpty { return }
            while query.last == " " { query.removeLast() }
            while let last = query.last, last != " " { query.removeLast() }
        case #selector(deleteToBeginningOfLine(_:)), #selector(deleteToBeginningOfParagraph(_:)):
            if query.isEmpty { return }
            query = ""
        default:
            delegate?.runCommand(selector)
            return
        }
        changed()
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = singleLine(string)
        needsDisplay = true
    }

    func unmarkText() {
        guard !marked.isEmpty else { return }
        query += marked
        marked = ""
        changed()
    }

    func selectedRange() -> NSRange {
        NSRange(location: (query as NSString).length + (marked as NSString).length, length: 0)
    }

    func markedRange() -> NSRange {
        marked.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: (query as NSString).length, length: (marked as NSString).length)
    }

    func hasMarkedText() -> Bool { !marked.isEmpty }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        let all = (query + marked) as NSString
        let clipped = NSIntersectionRange(range, NSRange(location: 0, length: all.length))
        actualRange?.pointee = clipped
        return NSAttributedString(string: all.substring(with: clipped))
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    // Input methods put their candidate window at the caret.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        let local = NSRect(x: caretX, y: 0, width: 1, height: bounds.height)
        return window?.convertToScreen(convert(local, to: nil)) ?? .zero
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let height = bounds.height
        drawGlyph(.search, in: NSRect(x: 18, y: ((height - 18) / 2).rounded(), width: 18, height: 18), color: .secondaryLabelColor)
        let x: CGFloat = 48
        var right = bounds.width - 18
        if !badge.isEmpty {
            let width = textWidth(badge, size: 12, weight: .medium) + 16
            let pill = NSRect(x: right - width, y: ((height - 22) / 2).rounded(), width: width, height: 22)
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 11, yRadius: 11).fill()
            drawText(badge, x: pill.minX + 8, midY: pill.midY, size: 12, weight: .medium, color: .secondaryLabelColor)
            right = pill.minX - 10
        }
        let available = right - x
        if query.isEmpty && marked.isEmpty {
            // The caret stands just before the placeholder, not over its first letter.
            let line = makeLine(placeholder, font: fieldFont, bold: fieldFont, emphasized: [], width: available - 4)
            drawLine(context, line, x: x + 4, top: 0, height: height, font: fieldFont, color: resolved(.tertiaryLabelColor))
            caretX = x
        } else {
            let text = NSMutableAttributedString(string: query + marked, attributes: [
                .font: fieldFont, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ])
            if !marked.isEmpty {
                text.addAttribute(NSAttributedString.Key(kCTUnderlineStyleAttributeName as String), value: CTUnderlineStyle.single.rawValue,
                                  range: NSRange(location: (query as NSString).length, length: (marked as NSString).length))
            }
            var line = CTLineCreateWithAttributedString(text)
            if lineWidth(line) > available {  // keep the end of a long query in view
                if let cut = CTLineCreateTruncatedLine(line, available, .start, makeLine("…", font: fieldFont)) { line = cut }
            }
            drawLine(context, line, x: x, top: 0, height: height, font: fieldFont, color: resolved(.labelColor))
            caretX = x + lineWidth(line) + 1
        }
        NSColor.controlAccentColor.setFill()
        NSRect(x: caretX.rounded(), y: ((height - 24) / 2).rounded(), width: 2, height: 24).fill()
    }

    // MARK: VoiceOver

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textField }
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .searchField }
    override func accessibilityLabel() -> String? { placeholder }
    override func accessibilityValue() -> Any? { query }
}

// A search box wants none of the system's text services.
extension SearchField: @preconcurrency NSTextInputTraits {
    var autocorrectionType: NSTextInputTraitType { get { .no } set {} }
    var spellCheckingType: NSTextInputTraitType { get { .no } set {} }
    var grammarCheckingType: NSTextInputTraitType { get { .no } set {} }
    var smartQuotesType: NSTextInputTraitType { get { .no } set {} }
    var smartDashesType: NSTextInputTraitType { get { .no } set {} }
    var smartInsertDeleteType: NSTextInputTraitType { get { .no } set {} }
    var textReplacementType: NSTextInputTraitType { get { .no } set {} }
    var dataDetectionType: NSTextInputTraitType { get { .no } set {} }
    var linkDetectionType: NSTextInputTraitType { get { .no } set {} }
    var textCompletionType: NSTextInputTraitType { get { .no } set {} }
    var inlinePredictionType: NSTextInputTraitType { get { .no } set {} }
    var mathExpressionCompletionType: NSTextInputTraitType { get { .no } set {} }
    var writingToolsBehavior: NSWritingToolsBehavior { get { .none } set {} }
}
