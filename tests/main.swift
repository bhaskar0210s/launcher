// Unit tests for the core: `make test` (built with AddressSanitizer and UndefinedBehaviorSanitizer).

import Darwin

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0

func check(_ condition: @autoclosure () -> Bool, _ what: @autoclosure () -> String = "", file: StaticString = #fileID, line: UInt = #line) {
    checks += 1
    if !condition() {
        failures += 1
        fputs("\(file):\(line): FAILED \(what())\n", stderr)
    }
}

func calc(_ text: String, decimal: Character = ".") -> String? {
    Calc.evaluate(text, decimal: decimal).map(Calc.format)
}

func expect(_ text: String, _ result: String?, decimal: Character = ".", line: UInt = #line) {
    let got = calc(text, decimal: decimal)
    check(got == result, "\(text) = \(got ?? "nil"), expected \(result ?? "nil")", line: line)
}

// MARK: Calculator: arithmetic

expect("1+1", "2")
expect("2+3*4", "14")
expect("(2+3)*4", "20")
expect("10/4", "2.5")
expect("10 / 4", "2.5")
expect("7-10", "-3")
expect("2^10", "1024")
expect("2**10", "1024")
expect("2^3^2", "512")          // right-associative
expect("-2^2", "-4")            // the power binds tighter than the sign
expect("(-2)^2", "4")
expect("2^-1", "0.5")
expect("--3+1", "4")
expect("3×4", "12")
expect("12÷4", "3")
expect("5−2", "3")              // U+2212 minus
expect("2·3", "6")
expect("0.1+0.2", "0.3")
expect(".5+.25", "0.75")
expect("5.+1", "6")
expect("1/3", "0.3333333333")
expect("2/3", "0.6666666667")
expect("100*1.1", "110")
expect("123456789.123456789*1", "123456789.123457")
expect("1,000+1", "1001")       // grouping commas
expect("1,234,567*2", "2469134")
expect("1,5+1", nil)            // a comma that isn't grouping, with "." as the decimal point
expect("1,5+1", "2.5", decimal: ",")
expect("1.5+1", "2.5", decimal: ",")
expect("[2+3]*2", "10")
expect("(2+3", "5")             // still being typed
expect("((1+2)*(3", "9")
expect("2+3)", nil)

// MARK: Calculator: percent, factorial, powers of ten, implicit multiplication

expect("50%", "0.5")
expect("200+10%", "220")
expect("200-10%", "180")
expect("200*10%", "20")
expect("50%*2", "1")
expect("5!", "120")
expect("0!", "1")
expect("3!!", "720")
expect("2.5!", "3.3233509704")   // the gamma function, as in Calculator
expect("171!", nil)             // too large
expect("1e3+1", "1001")
expect("2.5e-3*2", "0.005")
expect("1E2+1", "101")
expect("2pi", "6.2831853072")
expect("2 pi", "6.2831853072")
expect("3(1+2)", "9")
expect("(1+2)(3+4)", "21")
expect("2e", "5.4365636569")     // e is Euler's number when no digits follow
expect("2e+1*1", "20")           // but an exponent when they do
expect("2e+1", nil)               // which alone is just a number

// MARK: Calculator: functions and constants

expect("sqrt(16)", "4")
expect("sqrt 16", "4")
expect("√16", "4")
expect("√(9)+1", "4")
expect("sqrt 2^2", "2")
expect("sqrt(2)*sqrt(2)", "2")
expect("cbrt(27)", "3")
expect("sin(0)", "0")
expect("sin 30°", "0.5")
// Angles in degrees, as in Calculator; written with π, or with "rad", they are radians.
expect("sin 30", "0.5")
expect("sin(30)", "0.5")
expect("sin30", "0.5")
expect("2sin30", "1")
expect("sin(30)^2", "0.25")
expect("sin(30)²", "0.25")
expect("cos 60", "0.5")
expect("cos 90", "0")           // exactly, not 6e-17
expect("tan 45", "1")
expect("tan 90", nil)           // undefined
expect("sin 180", "0")
expect("sin(pi/6)", "0.5")
expect("sin(π/2)", "1")
expect("cos(pi)", "-1")
expect("tan(pi/4)", "1")
expect("sin(1 rad)", "0.8414709848")
expect("sin 90 deg", "1")
expect("asin(1)", "90")
expect("acos(0.5)", "60")
expect("atan(1)", "45")
expect("asin(2)", nil)
expect("sec(60)", "2")
expect("csc(30)", "2")
expect("cosec 30", "2")
expect("cot(45)", "1")
expect("cot 0", nil)
expect("sinh(0)+1", "1")
expect("cosh(0)", "1")
expect("asinh(0)+1", "1")
expect("atanh(0.5)", "0.5493061443")
// Powers written up high, logarithms to any base, roots of any degree.
expect("5²", "25")
expect("2³", "8")
expect("2¹⁰", "1024")
expect("10⁻¹", "0.1")
expect("(1+2)²", "9")
expect("log(8, 2)", "3")
expect("log(8,2)", "3")
expect("log(81; 3)", "4")
expect("log2(8)", "3")
expect("log10(1000)", "3")
expect("log100", "2")
expect("ln2", "0.6931471806")
expect("root(27, 3)", "3")
expect("root(-8, 3)", "-2")
expect("root(16)", "4")
expect("root(16, 0)", nil)
expect("sqrt16", "4")
expect("sqrt(1,000)", nil)      // between a function's arguments a comma separates them
expect("(1,000)*2", "2000")
expect("sin(1, 2)", nil)
expect("log(1, 2, 3)", nil)
// mod, "of" and "x" for times.
expect("10 mod 3", "1")
expect("-7 mod 3", "2")
expect("10 mod 0", nil)
expect("20% of 150", "30")
expect("3x4", "12")
expect("3 x 4", "12")
expect("(2+3)x4", "20")
expect("2x", nil)
expect("x2", nil)
expect("xyz", nil)
// Numbers side by side are not a product: addresses, phone numbers, versions, typos.
expect("2 3", nil)
expect("1.000.000", nil)
expect("1.000.000+1", nil)
expect("1 000+1", nil)
expect("192.168.1.1", nil)
expect("10.15.7", nil)
expect("555 1234", nil)
expect("e2", nil)
expect("(2)3", nil)
// Where "," is the decimal separator, "." groups thousands, as Launcher shows them there.
expect("1.234,56*2", "2469.12", decimal: ",")
expect("1.234,5+1", "1235.5", decimal: ",")
expect("1.000.000+1", "1000001", decimal: ",")
expect("1,5*2", "3", decimal: ",")
expect("log(8;2)", "3", decimal: ",")
expect("1,5+1", nil, decimal: "٫")          // another separator: "." still works, "," doesn't
expect("1.5+1", "2.5", decimal: "٫")
expect("1٫5+1", "2.5", decimal: "٫")
// The base of a logarithm, written with a space; bases that don't work.
expect("log2 8", "3")
expect("log10 100", "2")
expect("log 2", "0.3010299957")
expect("log(8, 0)", nil)
expect("log(1, 0)", nil)
expect("log(8, 1)", nil)
expect("log(-8, 2)", nil)
expect("log(1,000)", nil)
// π right after a number belongs to the angle.
expect("cos 2pi", "1")
expect("sin 2pi", "0")
expect("sin 2pi + 1", "1")
expect("2 sin 30 cos 60", "0.5")
// Small results keep their digits; tiny angles stay tiny.
expect("2^-29", "1.862645149e-9")
expect("1/123456789", "8.100000074e-9")
expect("sin(1e-13 rad)", "1e-13")
expect("sin 270", "-1")
expect("cos 270", "0")
expect("tan 270", nil)
expect("csc 180", nil)
// Hexadecimal.
expect("0x1F+1", "32")
expect("0xff*2", "510")
expect("0x10", nil)            // a lone number
expect("0x+1", "0")             // 0 × +1
for name in ["LG 27", "lb 8"] { check(Calc.evaluate(name) == nil, "\(name) is not a calculation") }
for name in ["Round", "Log", "Exp", "Sin", "Max", "Pages", "Notion", "Mod", "Of", "Rad", "Deg", "Root", "Floor Plan", "e", "pi", "π"] {
    check(Calc.evaluate(name) == nil, "\(name) is not a calculation")
}
expect("cos(0)+1", "2")
expect("tan(45°)", "1")
expect("log(1000)", "3")
expect("ln(e)", "1")             // a function makes it a calculation, digits or not
expect("ln(e^2)", "2")
expect("log2(8)", "3")
expect("exp(0)", "1")
expect("abs(-5)", "5")
expect("round(2.5)", "3")
expect("floor(2.7)+ceil(2.1)", "5")
expect("pi*2", "6.2831853072")
expect("π*1", "3.1415926536")
expect("tau/2", "3.1415926536")
expect("SQRT(16)", "4")         // any case

// MARK: Calculator: things that aren't calculations

expect("", nil)
expect("   ", nil)
expect("42", nil)               // a lone number
expect("-5", nil)
expect("3.14", nil)
expect("pi", nil)
expect("e", nil)
expect("safari", nil)
expect("1Password", nil)
expect("7-Zip", nil)
expect("Things 3", nil)
expect("2048", nil)
expect("1/0", nil)              // not finite
expect("0/0", nil)
expect("sqrt(-1)", nil)
expect("log(0)", nil)
expect("10^400", nil)
expect("2+", nil)
expect("*2", nil)
expect("2**", nil)
expect("()", nil)
expect("2 $ 3", nil)
expect("sin", nil)
expect("foo(2)", nil)
expect(String(repeating: "(", count: 200) + "1+1", nil)   // too deep
expect(String(repeating: "-", count: 300) + "1+1", nil)
expect(String(repeating: "1+", count: 300) + "1", nil)    // too long
expect("1+1" + String(repeating: " ", count: 400), "2")

// MARK: Formatting

check(Calc.format(0) == "0")
check(Calc.format(-0.0) == "0")
check(Calc.format(1e15) == "1e15")
check(Calc.format(1.5e20) == "1.5e20")
check(Calc.format(-2.5e-12) == "-2.5e-12")
check(Calc.format(1e-9) == "1e-9")
check(Calc.format(0.0001) == "0.0001")
check(Calc.format(0.00005) == "5e-5")
check(Calc.format(5e-10) == "5e-10")
check(Calc.format(999999999999999) == "999999999999999")
check(Calc.format(-1234.5) == "-1234.5")
check(Calc.parts("-1234.5") == ("-", "1234", ".5"), "\(Calc.parts("-1234.5"))")
check(Calc.parts("1.5e20") == ("", "1", ".5e20"))
check(Calc.parts("1e15") == ("", "1", "e15"))
check(Calc.parts("42") == ("", "42", ""))

// MARK: Matching and ranking

/// `recent` lists names in the order they were last opened, most recent first.
func ranked(_ query: String, _ names: [String], recent: [String] = [], limit: Int = .max) -> [String] {
    let recency = names.map { recent.firstIndex(of: $0) }
    return rank(query, names: names, haystacks: names.map(prepare), recency: recency, limit: limit).map { names[$0.index] }
}

let apps = ["Safari", "Calculator", "Calendar", "Google Chrome", "Visual Studio Code", "System Settings", "Zed", "Notes",
            "Notion", "Activity Monitor", "App Store", "Messages", "Mail", "Maps", "Music", "Xcode", "Chess", "Zoom"]
check(ranked("saf", apps) == ["Safari"])
check(ranked("", apps).isEmpty)
check(ranked("   ", apps).isEmpty)
check(ranked("zz", apps).isEmpty)
check(ranked("ze", apps).first == "Zed")
check(ranked("cal", apps) == ["Calendar", "Calculator"], "\(ranked("cal", apps))")  // same score: shorter first
check(ranked("calc", apps) == ["Calculator"])
check(ranked("vsc", apps).first == "Visual Studio Code", "\(ranked("vsc", apps))")
check(ranked("chrome", apps) == ["Google Chrome"])
check(ranked("gc", apps).first == "Google Chrome", "\(ranked("gc", apps))")
check(ranked("ss", apps).first == "System Settings", "\(ranked("ss", apps))")
check(ranked("set", apps).first == "System Settings")
check(ranked("no", apps).prefix(2) == ["Notes", "Notion"], "\(ranked("no", apps))")
check(ranked("m", apps).prefix(3) == ["Mail", "Maps", "Music"], "\(ranked("m", apps))")
check(ranked("ma", apps) == ["Mail", "Maps"], "\(ranked("ma", apps))")   // not Messages or Terminal
check(ranked("no", apps) == ["Notes", "Notion"], "\(ranked("no", apps))")
check(ranked("ter", ["Terminal", "Center"]) == ["Terminal"])
check(ranked("ms", ["Messages Store", "Mail"]) == ["Messages Store"])  // the s of Store, found after the s of Messages
check(ranked("gram", ["Telegram", "Grammarly"]) == ["Grammarly"])
check(ranked("gram", ["Telegram"]) == ["Telegram"])                  // looser matches when nothing matches at words
check(ranked("tube", ["YouTube"]) == ["YouTube"])                    // capitals inside a name start words too
check(ranked("1p", ["1Password", "Pages"]) == ["1Password"])
check(ranked("pass", ["Passwords", "1Password"]) == ["Passwords", "1Password"], "\(ranked("pass", ["Passwords", "1Password"]))")
check(ranked("pass", ["Passwords", "1Password"], recent: ["1Password"]) == ["1Password", "Passwords"])
check(ranked("edit", ["TextEdit", "BBEdit"]).sorted() == ["BBEdit", "TextEdit"], "\(ranked("edit", ["TextEdit", "BBEdit"]))")
check(ranked("do", ["2Do", "Docker"]).sorted() == ["2Do", "Docker"])
check(ranked("cap", ["CapCut", "4KCapture"]).sorted() == ["4KCapture", "CapCut"])
check(ranked("ma", ["Mail", "Terminal"], recent: ["Terminal"]) == ["Mail"])   // a loose match doesn't jump in
var wordScore = 0, wordPositions: [Int] = []
check(Query("gc").match(prepare("Google Chrome"), score: &wordScore, positions: &wordPositions, atWords: true) && wordPositions == [0, 7])
check(Query("ms").match(prepare("Messages Store"), score: &wordScore, positions: &wordPositions, atWords: true) && wordPositions == [0, 9],
      "\(wordPositions)")
check(!Query("ma").match(prepare("Terminal"), score: &wordScore, positions: &wordPositions, atWords: true))
check(ranked("app st", apps) == ["App Store"])
check(ranked("store app", apps) == ["App Store"])      // terms in any order
check(ranked("MUSIC", apps) == ["Music"])
check(ranked("c", apps, limit: 2).count == 2)
check(ranked("c", apps, limit: 0).isEmpty)
// The app opened last time for these letters comes first.
let calculator = apps.firstIndex(of: "Calculator")!
check(ranked("cal", apps, recent: ["Calculator"]) == ["Calculator", "Calendar"])
check(ranked("saf", apps, recent: ["Calculator"]) == ["Safari"])   // only if it matches
// The previous selection wins, whatever the letters: the app opened last comes first wherever it matches, even when
// another one matches better.
let both = ["Notes", "Notion"]
check(ranked("no", both) == ["Notes", "Notion"])
check(ranked("no", both, recent: ["Notion"]) == ["Notion", "Notes"])
check(ranked("n", both, recent: ["Notion"]) == ["Notion", "Notes"])
check(ranked("not", both, recent: ["Notion"]) == ["Notion", "Notes"])
check(ranked("no", both, recent: ["Notes", "Notion"]) == ["Notes", "Notion"])   // a newer pick takes the top
check(ranked("note", both, recent: ["Notion"]) == ["Notes"])                    // Notion doesn't match "note"
let s3 = ["Safari", "Slack", "System Settings"]
check(ranked("s", s3) == ["Slack", "Safari", "System Settings"])                // equal matches: the shorter name first
check(ranked("s", s3, recent: ["Safari"]) == ["Safari", "Slack", "System Settings"])
check(ranked("s", s3, recent: ["System Settings", "Safari"]) == ["System Settings", "Safari", "Slack"])
check(ranked("sa", s3, recent: ["Slack"]) == ["Safari"])                        // only apps that match
check(ranked("s", s3, recent: ["Zed"]) == ["Slack", "Safari", "System Settings"])  // history of other apps changes nothing
check(ranked("s", s3, recent: ["Safari"], limit: 1) == ["Safari"])
// Even a worse match comes first once it was opened last.
check(ranked("no", ["Notes", "Sticky Notes"]) == ["Notes", "Sticky Notes"])
check(ranked("no", ["Notes", "Sticky Notes"], recent: ["Sticky Notes"]) == ["Sticky Notes", "Notes"])
// Accents and other scripts.
check(ranked("e", ["Éditeur"]) == ["Éditeur"])
check(ranked("cafe", ["Café Notes", "Code"]) == ["Café Notes"])
check(ranked("тест", ["Тестер"]) == ["Тестер"])
check(ranked("日本", ["日本語アプリ"]) == ["日本語アプリ"])
// Matched characters, for bold.
var score = 0
var positions: [Int] = []
check(Query("gc").match(prepare("Google Chrome"), score: &score, positions: &positions) && positions == [0, 7], "\(positions)")
check(Query("ze").match(prepare("Zed"), score: &score, positions: &positions) && positions == [0, 1])
check(!Query("x").match(prepare(""), score: &score, positions: &positions))
// A long name with many candidate starts.
let long = String(repeating: "a", count: 300) + "b"
check(ranked("ab", [long]) == [long])
check(ranked("ab", [String(repeating: "a", count: 100_000)]).isEmpty)

// MARK: Recents

var recents = Recents(capacity: 3)
check(recents.place(of: "/Applications/Safari.app") == nil)
recents.record("/Applications/Safari.app")
recents.record("/Applications/Slack.app")
check(recents.paths == ["/Applications/Slack.app", "/Applications/Safari.app"])
check(recents.place(of: "/Applications/Slack.app") == 0 && recents.place(of: "/Applications/Safari.app") == 1)
recents.record("/Applications/Safari.app")      // opened again: back to the front, once
check(recents.paths == ["/Applications/Safari.app", "/Applications/Slack.app"])
recents.record("/Applications/Zed.app")
recents.record("/Applications/Notes.app")        // over capacity: the oldest goes
check(recents.paths == ["/Applications/Notes.app", "/Applications/Zed.app", "/Applications/Safari.app"])
recents.record("")
check(recents.paths.count == 3)
recents.forget("/Applications/Zed.app")
check(recents.paths == ["/Applications/Notes.app", "/Applications/Safari.app"])
check(Recents(paths: recents.paths, capacity: 3) == recents)
check(Recents(paths: ["/a.app", "", "/b.app", "/a.app"]).paths == ["/a.app", "/b.app"])
// The memory of earlier versions (letters → app, newest first) becomes the order apps were last opened in.
let earlier = ["bra\u{1F}/Applications/Brave Browser.app", "br\u{1F}/Applications/Brave Browser.app", "zed\u{1F}/Applications/Zed.app",
               "sl\u{1F}/Applications/Slack.app", "gh\u{1F}/Applications/Ghostty.app", "broken", "x\u{1F}"]
check(Recents(picks: earlier).paths == ["/Applications/Brave Browser.app", "/Applications/Zed.app", "/Applications/Slack.app",
                                        "/Applications/Ghostty.app"], "\(Recents(picks: earlier).paths)")

// MARK: The search line's editing

var line = LineEditor("hello world")
check(line.caret == 11 && !line.hasSelection)
line.moveLeft(); line.moveLeft()
check(line.caret == 9)
line.insert("X")
check(line.text == "hello worXld" && line.caret == 10)
line.moveToStart()
check(line.caret == 0)
line.moveToEnd()
check(line.caret == 12)
line = LineEditor("hello world")
line.moveWordLeft()
check(line.caret == 6, "⌥← to the start of world: \(line.caret)")
line.moveWordLeft()
check(line.caret == 0)
line.moveWordLeft()
check(line.caret == 0)                       // stays at the start
line.moveWordRight()
check(line.caret == 5, "⌥→ to the end of hello: \(line.caret)")
line.moveWordRight()
check(line.caret == 11)
line.moveWordRight()
check(line.caret == 11)                      // stays at the end
line = LineEditor("12.5+3")
line.moveWordLeft()
check(line.caret == 5)
line.moveWordLeft()
check(line.caret == 0, "12.5 is one word: \(line.caret)")
line = LineEditor("sin(30) + 2")
line.moveWordLeft(); line.moveWordLeft()
check(line.caret == 4, "\(line.caret)")
// Selecting.
line = LineEditor("abcdef")
line.moveLeft(extending: true); line.moveLeft(extending: true); line.moveLeft(extending: true)
check(line.selection == 3..<6 && line.selectedText == "def")
line.insert("X")
check(line.text == "abcX" && line.caret == 4 && !line.hasSelection)
line = LineEditor("abcdef")
line.moveWordLeft(extending: true)
check(line.selectedText == "abcdef")
line.moveLeft()
check(line.caret == 0 && !line.hasSelection)  // ← collapses a selection to its start
line.moveToEnd(extending: true)
line.moveRight()
check(line.caret == 6 && !line.hasSelection)  // → collapses it to its end
line.selectAll()
check(line.selectedText == "abcdef")
line.deleteBackward()
check(line.text == "" && line.caret == 0)
line = LineEditor("abcdef")
line.move(to: 2)
line.moveToEnd(extending: true)
check(line.selection == 2..<6)
line.moveToStart(extending: true)
check(line.selection == 0..<2 && line.anchor == 2)
// Deleting.
line = LineEditor("open safari")
line.deleteWordBackward()
check(line.text == "open ", "\(line.text)")
line.deleteWordBackward()
check(line.text == "", "\(line.text)")
line = LineEditor("abcdef")
line.move(to: 3)
line.deleteToStart()
check(line.text == "def" && line.caret == 0)
line = LineEditor("abcdef")
line.move(to: 3)
line.deleteToEnd()
check(line.text == "abc" && line.caret == 3)
line = LineEditor("abc")
line.move(to: 0)
line.deleteForward()
check(line.text == "bc" && line.caret == 0)
line.deleteBackward()
check(line.text == "bc")                     // nothing before the caret
line.moveToEnd()
line.deleteForward()
check(line.text == "bc")                     // nothing after it
line = LineEditor("one two three")
line.move(to: 4)
line.deleteWordForward()
check(line.text == "one  three", "\(line.text)")
line = LineEditor("one two")
line.move(to: 1)
line.moveWordRight(extending: true)
line.deleteWordBackward()                    // a selection goes first
check(line.text == "o two", "\(line.text)")
// Characters as people see them, and UTF-16 for Core Text.
line = LineEditor("a👍🏽b")
check(line.count == 3)
line.moveLeft()
line.deleteBackward()
check(line.text == "ab" && line.caret == 1)
line = LineEditor("a👍🏽b")
check(line.utf16Offset(0) == 0 && line.utf16Offset(1) == 1 && line.utf16Offset(2) == 5 && line.utf16Offset(3) == 6)
check(line.position(utf16Offset: 5) == 2 && line.position(utf16Offset: 3) == 2 && line.position(utf16Offset: 99) == 3)
line.replace(1..<2, with: "é")
check(line.text == "aéb" && line.caret == 2)
line.replace(5..<9, with: "!")              // clamped
check(line.text == "aéb!")
line.move(to: -5)
check(line.caret == 0)
line.move(to: 99)
check(line.caret == 4)

// MARK: Text

check(decodeUTF8(Array("aé€😀".utf8)) == [0x61, 0xE9, 0x20AC, 0x1F600])
check(decodeUTF8([0xFF, 0x41, 0xC3]) == [0xFFFD, 0x41, 0xFFFD])
check(decodeUTF8([0xC0, 0x80]) == [0xFFFD, 0xFFFD])     // overlong
check(decodeUTF8([0xED, 0xA0, 0x80]) == [0xFFFD, 0xFFFD, 0xFFFD])  // surrogate
check(fold(0x41) == 0x61 && fold(0xC9) == 0x65 && fold(0xD7) == 0xD7 && fold(0x391) == 0x3B1)

print(failures == 0 ? "All \(checks) checks passed" : "\(failures) of \(checks) checks failed")
exit(failures == 0 ? 0 : 1)
