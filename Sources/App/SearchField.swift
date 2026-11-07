// The search line at the top of the window: text with a caret and a selection, edited with the standard macOS keys
// (arrows, ⌥ for words, ⌘ and ⌃A/⌃E for the ends, ⇧ to select). Pounce reads the keyboard here itself (with input
// method support) instead of using a system text field: those bring the whole text system along, plus an AutoFill
// helper process.

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
private let textX: CGFloat = 48  // where the text starts, after the magnifying glass

final class SearchField: CanvasView, @preconcurrency NSTextInputClient {
    weak var delegate: SearchFieldDelegate?
    private var editor = LineEditor()
    private var marked = ""           // an input method's composition, shown at the caret, not part of the text yet
    private var caretX: CGFloat = 0   // where the caret was drawn, for input method windows
    private var scrollX: CGFloat = 0  // how far long text is scrolled to keep the caret in view
    private var line: CTLine?         // the text as last drawn, for clicks
    private var shownWidth: CGFloat = 0  // the width of the text as last drawn

    var placeholder = "Search" { didSet { needsDisplay = true } }
    var badge = "" { didSet { needsDisplay = true } }  // a word at the right end, such as "Settings"
    var pasteboard = NSPasteboard.general              // the test harness uses one of its own

    var query: String { editor.text }

    override var acceptsFirstResponder: Bool { true }

    // With an ordinary keyboard layout Pounce reads keys itself and has no input context: a text input context
    // makes macOS start an AutoFill helper process (about 13 MB). Input methods (Chinese, Japanese, Korean…) need one
    // to compose text, so it exists only while one of them is the current input source.
    override var inputContext: NSTextInputContext? {
        usingInputMethod() ? super.inputContext : nil
    }

    func clear() {
        editor.clear()
        marked = ""
        scrollX = 0
        inputContext?.discardMarkedText()
        needsDisplay = true
    }

    /// The text changed: the results follow.
    private func edited() {
        needsDisplay = true
        delegate?.queryChanged()
    }

    /// Only the caret or the selection moved.
    private func moved() {
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .selectedTextChanged)
    }

    // MARK: Clipboard

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
        editor.insert(singleLine(text))
        edited()
    }

    /// ⌘C and ⌘X: the selected text. False when nothing is selected.
    func copySelection(cut: Bool) -> Bool {
        guard editor.hasSelection, marked.isEmpty else { return false }
        pasteboard.clearContents()
        pasteboard.setString(editor.selectedText, forType: .string)
        if cut {
            editor.deleteBackward()
            edited()
        }
        return true
    }

    func selectAllText() {
        guard marked.isEmpty else { return }
        editor.selectAll()
        moved()
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        if inputContext != nil {
            interpretKeyEvents([event])
            return
        }
        let flags = event.modifierFlags
        let option = flags.contains(.option), command = flags.contains(.command), control = flags.contains(.control)
        let shift = flags.contains(.shift)
        func pick(_ plain: Selector, _ extending: Selector) -> Selector { shift ? extending : plain }
        var selector: Selector?
        switch Int(event.keyCode) {
        case kVK_UpArrow: selector = #selector(moveUp(_:))
        case kVK_DownArrow: selector = #selector(moveDown(_:))
        case kVK_LeftArrow:
            selector = command ? pick(#selector(moveToBeginningOfLine(_:)), #selector(moveToBeginningOfLineAndModifySelection(_:)))
                : option ? pick(#selector(moveWordLeft(_:)), #selector(moveWordLeftAndModifySelection(_:)))
                : pick(#selector(moveLeft(_:)), #selector(moveLeftAndModifySelection(_:)))
        case kVK_RightArrow:
            selector = command ? pick(#selector(moveToEndOfLine(_:)), #selector(moveToEndOfLineAndModifySelection(_:)))
                : option ? pick(#selector(moveWordRight(_:)), #selector(moveWordRightAndModifySelection(_:)))
                : pick(#selector(moveRight(_:)), #selector(moveRightAndModifySelection(_:)))
        case kVK_PageUp: selector = #selector(pageUp(_:))
        case kVK_PageDown: selector = #selector(pageDown(_:))
        case kVK_Home: selector = #selector(moveToBeginningOfDocument(_:))
        case kVK_End: selector = #selector(moveToEndOfDocument(_:))
        case kVK_Return, kVK_ANSI_KeypadEnter: selector = #selector(insertNewline(_:))
        case kVK_Escape: selector = #selector(cancelOperation(_:))
        case kVK_Tab: selector = shift ? #selector(moveUp(_:)) : #selector(moveDown(_:))
        case kVK_Delete:
            selector = option ? #selector(deleteWordBackward(_:)) : command ? #selector(deleteToBeginningOfLine(_:)) : #selector(deleteBackward(_:))
        case kVK_ForwardDelete:
            selector = option ? #selector(deleteWordForward(_:)) : #selector(deleteForward(_:))
        // The Emacs keys that every macOS text field understands.
        case kVK_ANSI_A where control: selector = pick(#selector(moveToBeginningOfParagraph(_:)), #selector(moveToBeginningOfParagraphAndModifySelection(_:)))
        case kVK_ANSI_E where control: selector = pick(#selector(moveToEndOfParagraph(_:)), #selector(moveToEndOfParagraphAndModifySelection(_:)))
        case kVK_ANSI_B where control: selector = pick(#selector(moveBackward(_:)), #selector(moveBackwardAndModifySelection(_:)))
        case kVK_ANSI_F where control: selector = pick(#selector(moveForward(_:)), #selector(moveForwardAndModifySelection(_:)))
        case kVK_ANSI_K where control: selector = #selector(deleteToEndOfParagraph(_:))
        case kVK_ANSI_D where control: selector = #selector(deleteForward(_:))
        case kVK_ANSI_H where control: selector = #selector(deleteBackward(_:))
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

    /// The standard text commands, from the keys above or from an input method; the rest go to the window (↑ ↓,
    /// Return, Esc…).
    override func doCommand(by selector: Selector) {
        let before = editor
        switch selector {
        case #selector(moveLeft(_:)), #selector(moveBackward(_:)): editor.moveLeft()
        case #selector(moveRight(_:)), #selector(moveForward(_:)): editor.moveRight()
        case #selector(moveLeftAndModifySelection(_:)), #selector(moveBackwardAndModifySelection(_:)): editor.moveLeft(extending: true)
        case #selector(moveRightAndModifySelection(_:)), #selector(moveForwardAndModifySelection(_:)): editor.moveRight(extending: true)
        case #selector(moveWordLeft(_:)), #selector(moveWordBackward(_:)): editor.moveWordLeft()
        case #selector(moveWordRight(_:)), #selector(moveWordForward(_:)): editor.moveWordRight()
        case #selector(moveWordLeftAndModifySelection(_:)), #selector(moveWordBackwardAndModifySelection(_:)): editor.moveWordLeft(extending: true)
        case #selector(moveWordRightAndModifySelection(_:)), #selector(moveWordForwardAndModifySelection(_:)): editor.moveWordRight(extending: true)
        case #selector(moveToBeginningOfLine(_:)), #selector(moveToBeginningOfParagraph(_:)), #selector(moveToLeftEndOfLine(_:)):
            editor.moveToStart()
        case #selector(moveToEndOfLine(_:)), #selector(moveToEndOfParagraph(_:)), #selector(moveToRightEndOfLine(_:)):
            editor.moveToEnd()
        case #selector(moveToBeginningOfLineAndModifySelection(_:)), #selector(moveToBeginningOfParagraphAndModifySelection(_:)),
             #selector(moveToLeftEndOfLineAndModifySelection(_:)):
            editor.moveToStart(extending: true)
        case #selector(moveToEndOfLineAndModifySelection(_:)), #selector(moveToEndOfParagraphAndModifySelection(_:)),
             #selector(moveToRightEndOfLineAndModifySelection(_:)):
            editor.moveToEnd(extending: true)
        case #selector(selectAll(_:)): editor.selectAll()
        case #selector(deleteBackward(_:)), #selector(deleteBackwardByDecomposingPreviousCharacter(_:)): editor.deleteBackward()
        case #selector(deleteForward(_:)): editor.deleteForward()
        case #selector(deleteWordBackward(_:)): editor.deleteWordBackward()
        case #selector(deleteWordForward(_:)): editor.deleteWordForward()
        case #selector(deleteToBeginningOfLine(_:)), #selector(deleteToBeginningOfParagraph(_:)): editor.deleteToStart()
        case #selector(deleteToEndOfLine(_:)), #selector(deleteToEndOfParagraph(_:)): editor.deleteToEnd()
        default:
            delegate?.runCommand(selector)
            return
        }
        if editor.characters != before.characters { edited() } else if editor != before { moved() }
    }

    // MARK: Mouse

    // A click puts the caret there, ⇧-click selects up to it, a double-click selects a word, a triple-click all of it,
    // and dragging selects.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard marked.isEmpty, let position = position(of: event) else { return }
        switch event.clickCount {
        case 2: editor.select(editor.word(at: position))
        case 3...: editor.selectAll()
        default: editor.move(to: position, extending: event.modifierFlags.contains(.shift))
        }
        moved()
    }

    override func mouseDragged(with event: NSEvent) {
        guard marked.isEmpty, event.clickCount <= 1, let position = position(of: event) else { return }
        editor.move(to: position, extending: true)
        moved()
    }

    private func position(of event: NSEvent) -> Int? {
        guard let line else { return 0 }
        let x = convert(event.locationInWindow, from: nil).x - textX + scrollX
        let offset = CTLineGetStringIndexForPosition(line, CGPoint(x: min(max(x, 0), shownWidth), y: 0))
        return offset == kCFNotFound ? nil : editor.position(utf16Offset: offset)
    }

    override func resetCursorRects() {
        addCursorRect(NSRect(x: textX - 4, y: 0, width: max(0, bounds.width - textX), height: bounds.height), cursor: .iBeam)
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = singleLine(string)
        let hadComposition = !marked.isEmpty
        marked = ""
        if replacementRange.location != NSNotFound {
            let lower = editor.position(utf16Offset: replacementRange.location)
            let upper = editor.position(utf16Offset: replacementRange.location + replacementRange.length)
            editor.replace(lower..<upper, with: text)
        } else if !text.isEmpty {
            editor.insert(text)
        } else {
            if hadComposition { needsDisplay = true }
            return
        }
        edited()
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if editor.hasSelection {  // a composition replaces the selection, as typing does
            editor.deleteBackward()
            delegate?.queryChanged()
        }
        marked = singleLine(string)
        needsDisplay = true
    }

    func unmarkText() {
        guard !marked.isEmpty else { return }
        editor.insert(marked)
        marked = ""
        edited()
    }

    func selectedRange() -> NSRange {
        if !marked.isEmpty {
            return NSRange(location: editor.utf16Offset(editor.caret) + (marked as NSString).length, length: 0)
        }
        let lower = editor.utf16Offset(editor.selection.lowerBound)
        return NSRange(location: lower, length: editor.utf16Offset(editor.selection.upperBound) - lower)
    }

    func markedRange() -> NSRange {
        marked.isEmpty ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: editor.utf16Offset(editor.caret), length: (marked as NSString).length)
    }

    func hasMarkedText() -> Bool { !marked.isEmpty }

    /// The text as shown: the composition sits at the caret.
    private var shown: (text: String, before: Int) {
        let before = String(editor.characters[..<editor.caret])
        return (before + marked + String(editor.characters[editor.caret...]), (before as NSString).length)
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        let all = shown.text as NSString
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

    func characterIndex(for point: NSPoint) -> Int {
        guard let line, let window else { return NSNotFound }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        let offset = CTLineGetStringIndexForPosition(line, CGPoint(x: local.x - textX + scrollX, y: 0))
        return offset == kCFNotFound ? NSNotFound : offset
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let height = bounds.height
        drawGlyph(.search, in: NSRect(x: 18, y: ((height - 18) / 2).rounded(), width: 18, height: 18), color: .secondaryLabelColor)
        var right = bounds.width - 18
        if !badge.isEmpty {
            let width = textWidth(badge, size: 12, weight: .medium) + 16
            let pill = NSRect(x: right - width, y: ((height - 22) / 2).rounded(), width: width, height: 22)
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 11, yRadius: 11).fill()
            drawText(badge, x: pill.minX + 8, midY: pill.midY, size: 12, weight: .medium, color: .secondaryLabelColor)
            right = pill.minX - 10
        }
        let available = right - textX
        let caretHeight: CGFloat = 24, caretTop = ((height - caretHeight) / 2).rounded()

        if editor.isEmpty && marked.isEmpty {
            // The caret stands just before the placeholder, not over its first letter.
            let placeholderLine = makeLine(placeholder, font: fieldFont, bold: fieldFont, emphasized: [], width: available - 4)
            drawLine(context, placeholderLine, x: textX + 4, top: 0, height: height, font: fieldFont, color: resolved(.tertiaryLabelColor))
            (line, shownWidth, scrollX, caretX) = (nil, 0, 0, textX)
            NSColor.controlAccentColor.setFill()
            NSRect(x: textX, y: caretTop, width: 2, height: caretHeight).fill()
            return
        }

        let (text, before) = shown
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: fieldFont, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ])
        let markedLength = (marked as NSString).length
        if markedLength > 0 {
            attributed.addAttribute(NSAttributedString.Key(kCTUnderlineStyleAttributeName as String), value: CTUnderlineStyle.single.rawValue,
                                    range: NSRange(location: before, length: markedLength))
        }
        let line = CTLineCreateWithAttributedString(attributed)
        let width = lineWidth(line)
        let caretOffset = CTLineGetOffsetForStringIndex(line, before + markedLength, nil)
        (self.line, shownWidth) = (line, width)

        // Long text scrolls so that the caret stays in view.
        let room = available - 3
        if width <= room {
            scrollX = 0
        } else {
            if caretOffset - scrollX > room { scrollX = caretOffset - room }
            if caretOffset - scrollX < 0 { scrollX = caretOffset }
            scrollX = min(max(scrollX, 0), width - room)
        }

        context.saveGState()
        context.clip(to: CGRect(x: textX - 2, y: 0, width: available + 4, height: height))
        if editor.hasSelection && markedLength == 0 {
            let lower = CTLineGetOffsetForStringIndex(line, editor.utf16Offset(editor.selection.lowerBound), nil)
            let upper = CTLineGetOffsetForStringIndex(line, editor.utf16Offset(editor.selection.upperBound), nil)
            (window?.isKeyWindow == true ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor).setFill()
            NSRect(x: textX + lower - scrollX, y: caretTop - 1, width: upper - lower, height: caretHeight + 2).fill()
        }
        drawLine(context, line, x: textX - scrollX, top: 0, height: height, font: fieldFont, color: resolved(.labelColor))
        context.restoreGState()

        caretX = textX + caretOffset - scrollX
        if !editor.hasSelection || markedLength > 0 {
            NSColor.controlAccentColor.setFill()
            NSRect(x: caretX.rounded(), y: caretTop, width: 2, height: caretHeight).fill()
        }
    }

    // MARK: VoiceOver

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textField }
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .searchField }
    override func accessibilityLabel() -> String? { placeholder }
    override func accessibilityValue() -> Any? { query }
    override func accessibilityNumberOfCharacters() -> Int { (query as NSString).length }
    override func accessibilitySelectedTextRange() -> NSRange { selectedRange() }
    override func accessibilitySelectedText() -> String? { editor.selectedText }

    // MARK: For the test harness

    var editorForTesting: LineEditor { editor }
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
