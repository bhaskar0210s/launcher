// The text of the search line, the caret and the selection, with the editing and movement of the standard macOS
// text keys. Positions count characters as people see them (Swift Characters), so an emoji is one step.

struct LineEditor: Equatable {
    private(set) var characters: [Character] = []
    private(set) var caret = 0   // 0...characters.count
    private(set) var anchor = 0  // the other end of the selection: equal to the caret when nothing is selected

    init(_ text: String = "") {
        characters = Array(text)
        caret = characters.count
        anchor = caret
    }

    var text: String { String(characters) }
    var count: Int { characters.count }
    var isEmpty: Bool { characters.isEmpty }
    var selection: Range<Int> { min(anchor, caret)..<max(anchor, caret) }
    var hasSelection: Bool { anchor != caret }
    var selectedText: String { String(characters[selection]) }

    // MARK: Editing

    mutating func clear() {
        self = LineEditor()
    }

    /// Typing and pasting: the text replaces the selection, and the caret goes after it.
    mutating func insert(_ text: String) {
        replace(selection, with: text)
    }

    /// Replaces a range (clamped to the text) and puts the caret after the new text.
    mutating func replace(_ range: Range<Int>, with text: String) {
        let lower = min(max(range.lowerBound, 0), count), upper = min(max(range.upperBound, lower), count)
        let inserted = Array(text)
        characters.replaceSubrange(lower..<upper, with: inserted)
        caret = lower + inserted.count
        anchor = caret
    }

    /// ⌫: the selection, or the character before the caret.
    mutating func deleteBackward() {
        if hasSelection { return replace(selection, with: "") }
        if caret > 0 { replace(caret - 1..<caret, with: "") }
    }

    /// ⌦, ⌃D: the selection, or the character after the caret.
    mutating func deleteForward() {
        if hasSelection { return replace(selection, with: "") }
        if caret < count { replace(caret..<caret + 1, with: "") }
    }

    /// ⌥⌫: the selection, or back to the start of the word before the caret.
    mutating func deleteWordBackward() {
        if hasSelection { return replace(selection, with: "") }
        replace(wordStart(before: caret)..<caret, with: "")
    }

    /// ⌥⌦: the selection, or on to the end of the word after the caret.
    mutating func deleteWordForward() {
        if hasSelection { return replace(selection, with: "") }
        replace(caret..<wordEnd(after: caret), with: "")
    }

    /// ⌘⌫: the selection, or everything before the caret.
    mutating func deleteToStart() {
        if hasSelection { return replace(selection, with: "") }
        replace(0..<caret, with: "")
    }

    /// ⌃K: the selection, or everything after the caret.
    mutating func deleteToEnd() {
        if hasSelection { return replace(selection, with: "") }
        replace(caret..<count, with: "")
    }

    // MARK: Moving

    /// Puts the caret at `position`; `extending` keeps the other end of the selection where it is.
    mutating func move(to position: Int, extending: Bool = false) {
        caret = min(max(position, 0), count)
        if !extending { anchor = caret }
    }

    /// ← and ⌃B. Without ⇧, a selection collapses to its start.
    mutating func moveLeft(extending: Bool = false) {
        if hasSelection && !extending { return move(to: selection.lowerBound) }
        move(to: caret - 1, extending: extending)
    }

    /// → and ⌃F. Without ⇧, a selection collapses to its end.
    mutating func moveRight(extending: Bool = false) {
        if hasSelection && !extending { return move(to: selection.upperBound) }
        move(to: caret + 1, extending: extending)
    }

    /// ⌥←: to the start of this word or the one before.
    mutating func moveWordLeft(extending: Bool = false) {
        let from = hasSelection && !extending ? selection.lowerBound : caret
        move(to: wordStart(before: from), extending: extending)
    }

    /// ⌥→: to the end of this word or the one after.
    mutating func moveWordRight(extending: Bool = false) {
        let from = hasSelection && !extending ? selection.upperBound : caret
        move(to: wordEnd(after: from), extending: extending)
    }

    /// ⌘←, ⌃A.
    mutating func moveToStart(extending: Bool = false) {
        move(to: 0, extending: extending)
    }

    /// ⌘→, ⌃E.
    mutating func moveToEnd(extending: Bool = false) {
        move(to: count, extending: extending)
    }

    /// ⌘A.
    mutating func selectAll() {
        anchor = 0
        caret = count
    }

    /// Selects a range (clamped to the text), with the caret at its end.
    mutating func select(_ range: Range<Int>) {
        anchor = min(max(range.lowerBound, 0), count)
        caret = min(max(range.upperBound, anchor), count)
    }

    /// The word at a position, for a double-click: the word the position is in or right after, or the single
    /// character there when it isn't part of a word.
    func word(at position: Int) -> Range<Int> {
        let p = min(max(position, 0), count)
        let inside = p < count && isWord(p) ? p : p > 0 && isWord(p - 1) ? p - 1 : -1
        guard inside >= 0 else { return p..<min(p + 1, count) }
        var lower = inside, upper = inside + 1
        while lower > 0 && isWord(lower - 1) { lower -= 1 }
        while upper < count && isWord(upper) { upper += 1 }
        return lower..<upper
    }

    // MARK: Words

    /// Letters, digits and _ make words; so does a point or comma between digits, so 12.5 is one word.
    private func isWord(_ i: Int) -> Bool {
        let c = characters[i]
        if c.isLetter || c.isNumber || c == "_" { return true }
        return (c == "." || c == ",") && i > 0 && i + 1 < count && characters[i - 1].isNumber && characters[i + 1].isNumber
    }

    func wordStart(before position: Int) -> Int {
        var i = min(max(position, 0), count)
        while i > 0 && !isWord(i - 1) { i -= 1 }
        while i > 0 && isWord(i - 1) { i -= 1 }
        return i
    }

    func wordEnd(after position: Int) -> Int {
        var i = min(max(position, 0), count)
        while i < count && !isWord(i) { i += 1 }
        while i < count && isWord(i) { i += 1 }
        return i
    }

    // MARK: UTF-16, for Core Text and input methods

    func utf16Offset(_ position: Int) -> Int {
        characters[..<min(max(position, 0), count)].reduce(0) { $0 + $1.utf16.count }
    }

    /// The character position at or after a UTF-16 offset.
    func position(utf16Offset offset: Int) -> Int {
        var total = 0
        for (i, c) in characters.enumerated() {
            if total >= offset { return i }
            total += c.utf16.count
        }
        return count
    }
}
