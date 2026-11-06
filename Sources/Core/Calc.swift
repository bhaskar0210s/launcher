// The calculator: what macOS Calculator does, typed into the search line. Arithmetic in the usual order (brackets,
// powers, × ÷, + −), percentages, powers and roots, factorials, logarithms, and trigonometry in degrees like
// Calculator (radians when the angle is written with π, or with "rad").

import Darwin

enum Calc {
    /// The value of `text` when it is a calculation. Nil for anything else: words, a lone number, numbers side by side
    /// (an address like 192.168.1.1), a mistake, or a result that isn't a finite number (1/0, tan 90). `decimal` is
    /// the decimal separator where the user lives; "." works everywhere.
    static func evaluate(_ text: String, decimal: Character = ".") -> Double? {
        var parser = Parser(text, decimal: decimal.unicodeScalars.first?.value ?? 0x2E)
        guard let value = parser.run(), value.isFinite else { return nil }
        return value == 0 ? 0 : value  // no "-0"
    }

    /// The result as plain digits: "." as the decimal point, no grouping, at most ten decimals and about fifteen
    /// significant digits. Very large and small numbers use an exponent (1.5e20, 1.862645149e-9), so that small
    /// results keep their digits.
    static func format(_ value: Double) -> String {
        if value == 0 || !value.isFinite { return value.isNaN ? "NaN" : value == 0 ? "0" : value > 0 ? "∞" : "-∞" }
        let magnitude = abs(value)
        if magnitude >= 1e15 || magnitude < 1e-4 {
            let text = printf("%.9e", value)  // like 1.234500000e+20
            guard let e = text.firstIndex(of: "e") else { return text }
            var mantissa = String(text[..<e])
            trimZeros(&mantissa)
            var exponent = String(text[text.index(after: e)...])
            let negative = exponent.hasPrefix("-")
            exponent = String(exponent.drop { $0 == "+" || $0 == "-" || $0 == "0" })
            return mantissa + "e" + (negative ? "-" : "") + (exponent.isEmpty ? "0" : exponent)
        }
        let digitsBeforePoint = Int(floor(log10(magnitude))) + 1
        let decimals = max(0, min(10, 15 - digitsBeforePoint))
        var text = printf("%.\(decimals)f", value)
        trimZeros(&text)
        return text == "-0" ? "0" : text
    }

    /// Splits a formatted result into its whole part and the rest, for showing it with digit grouping.
    static func parts(_ formatted: String) -> (sign: String, whole: String, rest: String) {
        var text = Substring(formatted)
        var sign = ""
        if text.hasPrefix("-") {
            sign = "-"
            text = text.dropFirst()
        }
        let end = text.firstIndex { $0 == "." || $0 == "e" } ?? text.endIndex
        return (sign, String(text[..<end]), String(text[end...]))
    }

    private static func trimZeros(_ text: inout String) {
        guard text.contains(".") else { return }
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
    }

    private static func printf(_ format: String, _ value: Double) -> String {
        var buffer = [CChar](repeating: 0, count: 64)
        _ = withVaList([value]) { vsnprintf(&buffer, buffer.count, format, $0) }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

private enum Token: Equatable {
    case number(Double)
    case name(String)          // functions, constants and the words mod, of, rad, deg
    case op(UInt32)            // + - * / ^ ( ) % ! ° √ ,
    case superscript(Double)   // ² ³ ⁻¹ …: a power written up high
    case end
}

private let degree = Double.pi / 180

/// A sine or cosine this close to zero is rounding error in the angle itself (π can't be stored exactly), so it is
/// zero: cos 90° is 0, not 6e-17, while sin(1e-13 rad) stays 1e-13.
private func isZero(_ value: Double, angle: Double) -> Bool {
    abs(value) <= abs(angle) * 8 * Double.ulpOfOne
}

private func trig(_ value: Double, _ angle: Double) -> Double { isZero(value, angle: angle) ? 0 : value }

private func superscriptDigit(_ c: UInt32) -> Int? {
    switch c {
    case 0x2070: return 0
    case 0xB9: return 1
    case 0xB2: return 2
    case 0xB3: return 3
    case 0x2074...0x2079: return Int(c - 0x2070)
    default: return nil
    }
}

private struct Parser {
    private var scalars: [UInt32]
    private var i = 0
    private let decimal: UInt32    // the local decimal separator ("." works too)
    private var token = Token.end
    private var operations = 0     // operators, functions and constants seen: a lone number is not a calculation
    private var digits = false
    private var calls = 0          // functions applied: cos(pi) is a calculation even without digits
    private var piUses = 0         // π and τ seen so far: an angle written with them is in radians
    private var unitMarks = 0      // °, deg and rad seen so far: an angle that says its own unit
    private var argumentDepth = 0  // inside a function's brackets, commas separate arguments

    init(_ text: String, decimal: UInt32) {
        scalars = decodeUTF8(Array(text.utf8))
        self.decimal = decimal
    }

    private var commaDecimal: Bool { decimal == 0x2C }

    private func isPoint(_ c: UInt32?) -> Bool { c == 0x2E || (c != nil && c == decimal) }

    mutating func run() -> Double? {
        guard scalars.count <= 500 else { return nil }
        guard advance() else { return nil }
        guard let value = expression(depth: 0), token == .end, digits || calls > 0, operations > 0 else { return nil }
        return value
    }

    // MARK: Tokens

    private func peek(_ offset: Int = 0) -> UInt32? {
        i + offset < scalars.count ? scalars[i + offset] : nil
    }

    private static func isDigit(_ c: UInt32?) -> Bool { c.map { $0 >= 0x30 && $0 <= 0x39 } ?? false }
    private static func hexValue(_ c: UInt32) -> Int? {
        switch c {
        case 0x30...0x39: return Int(c - 0x30)
        case 0x61...0x66: return Int(c - 0x61 + 10)
        case 0x41...0x46: return Int(c - 0x41 + 10)
        default: return nil
        }
    }
    private static func isLetter(_ c: UInt32?) -> Bool {
        guard let c else { return false }
        return (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || c == 0x3C0 || c == 0x3C4  // π τ
    }

    /// Whether a token can end an operand, so that an "x" after it means times (3x4, (1+2) x 5).
    private static func endsOperand(_ token: Token) -> Bool {
        switch token {
        case .number, .superscript: return true
        case .name(let name): return constants[name] != nil
        case .op(let c): return c == 0x29 || c == 0x25 || c == 0x21 || c == 0xB0
        case .end: return false
        }
    }

    /// Reads the next token. False on a character that has no place in a calculation.
    private mutating func advance() -> Bool {
        let previous = token
        while let c = peek(), isSpace(c) { i += 1 }
        guard let c = peek() else {
            token = .end
            return true
        }
        if Self.isDigit(c) || (isPoint(c) && Self.isDigit(peek(1))) {
            return readNumber()
        }
        if superscriptDigit(c) != nil || c == 0x207B || c == 0x207A {  // ⁻ ⁺
            var negative = false
            var value = 0.0
            var any = false
            while let c = peek(), superscriptDigit(c) != nil || ((c == 0x207B || c == 0x207A) && !any) {
                if let digit = superscriptDigit(c) {
                    value = value * 10 + Double(digit)
                    any = true
                } else if c == 0x207B {
                    negative.toggle()
                }
                i += 1
            }
            guard any else { return false }
            token = .superscript(negative ? -value : value)
            return true
        }
        if Self.isLetter(c) {
            if (c == 0x78 || c == 0x58) && Self.endsOperand(previous) && !Self.isLetter(peek(1)) {  // 3x4: times
                i += 1
                token = .op(0x2A)
                return true
            }
            var name = ""
            while let c = peek(), Self.isLetter(c) {
                name.unicodeScalars.append(Unicode.Scalar(fold(c))!)
                i += 1
            }
            // log2 8 and log10(100) name their base; otherwise digits after a name are its number (sin30, log100).
            if name == "log" {
                if peek() == 0x32 && !Self.isDigit(peek(1)) && !isPoint(peek(1)) {
                    name = "log2"
                    i += 1
                } else if peek() == 0x31 && peek(1) == 0x30 && !Self.isDigit(peek(2)) && !isPoint(peek(2)) {
                    name = "log10"
                    i += 2
                }
            }
            token = .name(name)
            return true
        }
        i += 1
        switch c {
        case 0x2B: token = .op(0x2B)                                    // +
        case 0x2D, 0x2212, 0x2013: token = .op(0x2D)                    // - − –
        case 0x2A:                                                      // * or **
            if peek() == 0x2A {
                i += 1
                token = .op(0x5E)
            } else {
                token = .op(0x2A)
            }
        case 0xD7, 0x22C5, 0xB7, 0x2219: token = .op(0x2A)              // × ⋅ · ∙
        case 0x2F, 0xF7, 0x2215, 0x2236: token = .op(0x2F)              // / ÷ ∕ ∶
        case 0x5E: token = .op(0x5E)                                    // ^
        case 0x28, 0x29, 0x25, 0x21, 0xB0, 0x221A: token = .op(c)       // ( ) % ! ° √
        case 0x5B: token = .op(0x28)                                    // [ as (
        case 0x5D: token = .op(0x29)                                    // ] as )
        case 0x2C where argumentDepth > 0, 0x3B where argumentDepth > 0:  // , ; between a function's arguments
            token = .op(0x2C)
        default: return false
        }
        return true
    }

    /// Digits with an optional decimal part and exponent. In "2e" or "2e+x" the e is Euler's number, not an exponent.
    /// Thousands are grouped with "," ("1,000") where "." is the decimal point, and with "." ("1.234,5") where "," is,
    /// when exactly three digits follow; between a function's arguments a comma separates them instead. 0x1F is
    /// hexadecimal.
    private mutating func readNumber() -> Bool {
        if peek() == 0x30, peek(1) == 0x78 || peek(1) == 0x58, let first = peek(2), Self.hexValue(first) != nil {
            i += 2
            var value = 0.0
            while let c = peek(), let digit = Self.hexValue(c) {
                value = value * 16 + Double(digit)
                i += 1
            }
            digits = true
            token = .number(value)
            return true
        }
        var text = ""
        var sawPoint = false
        let grouping: UInt32 = commaDecimal ? 0x2E : 0x2C
        while let c = peek() {
            let threeDigitsFollow = Self.isDigit(peek(1)) && Self.isDigit(peek(2)) && Self.isDigit(peek(3)) && !Self.isDigit(peek(4))
            if Self.isDigit(c) {
                text.unicodeScalars.append(Unicode.Scalar(c)!)
                i += 1
            } else if c == grouping && !sawPoint && !text.isEmpty && threeDigitsFollow && (commaDecimal || argumentDepth == 0) {
                i += 1  // a thousands separator
            } else if isPoint(c) && !sawPoint && Self.isDigit(peek(1)) && !(c == 0x2C && argumentDepth > 0 && !commaDecimal) {
                sawPoint = true
                text += "."
                i += 1
            } else if isPoint(c) && !sawPoint && !Self.isDigit(peek(1)) && c != 0x2C {
                i += 1  // "5." is 5
                sawPoint = true
            } else {
                break
            }
        }
        if (peek() == 0x65 || peek() == 0x45),
           Self.isDigit(peek(1)) || ((peek(1) == 0x2B || peek(1) == 0x2D) && Self.isDigit(peek(2))) {
            text += "e"
            i += 1
            if peek() == 0x2B || peek() == 0x2D {
                text.unicodeScalars.append(Unicode.Scalar(peek()!)!)
                i += 1
            }
            while let c = peek(), Self.isDigit(c) {
                text.unicodeScalars.append(Unicode.Scalar(c)!)
                i += 1
            }
        }
        guard let value = Double(text) else { return false }
        digits = true
        token = .number(value)
        return true
    }

    // MARK: Grammar
    //   expression := term (("+" | "-") term)*                      a + b% means a + a·b/100, as on a calculator
    //   term       := signed (("*" | "/" | "mod" | "of" | nothing) signed)*    "2pi" and "3(1+2)" multiply
    //   signed     := ("+" | "-") signed | power
    //   power      := postfix ("^" signed)?                          right-associative; -2^2 is -4
    //   postfix    := primary ("%" | "!" | "°" | "deg" | "rad" | ² ³ …)*
    //   primary    := number | constant | function | "(" expression ")" | "√" postfix
    //   function   := name "(" expression ("," expression)? ")" | name power

    private mutating func expression(depth: Int) -> Double? {
        guard depth < 64, var (value, _) = term(depth: depth) else { return nil }
        while case .op(let c) = token, c == 0x2B || c == 0x2D {
            operations += 1
            guard advance(), let (right, percent) = term(depth: depth) else { return nil }
            let amount = percent ? value * right : right
            value = c == 0x2B ? value + amount : value - amount
        }
        return value
    }

    /// The term's value, and whether it was a lone percentage (such as 10%), for a + b%.
    private mutating func term(depth: Int) -> (Double, Bool)? {
        guard var (value, percent) = signed(depth: depth) else { return nil }
        while true {
            if case .op(let c) = token, c == 0x2A || c == 0x2F {
                operations += 1
                guard advance(), let (right, _) = signed(depth: depth) else { return nil }
                value = c == 0x2A ? value * right : value / right
            } else if token == .name("mod") {
                operations += 1
                guard advance(), let (right, _) = signed(depth: depth) else { return nil }
                value = value - right * floor(value / right)  // the remainder takes the divisor's sign
            } else if token == .name("of") {  // 20% of 150
                operations += 1
                guard advance(), let (right, _) = signed(depth: depth) else { return nil }
                value *= right
            } else if startsOperand {
                operations += 1  // implicit multiplication
                guard let (right, _) = signed(depth: depth) else { return nil }
                value *= right
            } else {
                return (value, percent)
            }
            percent = false
        }
    }

    /// What can follow an operand to multiply it without a sign: 2pi, 3(1+2), 2√9, 2 sin 30. Not another number:
    /// numbers side by side are an address, a phone number or a typo (192.168.1.1, 555 1234), not a product.
    private var startsOperand: Bool {
        switch token {
        case .number: return false
        case .name(let name): return !["mod", "of", "rad", "deg", "degrees", "radians"].contains(name)
        case .op(let c): return c == 0x28 || c == 0x221A
        case .superscript, .end: return false
        }
    }

    private mutating func signed(depth: Int) -> (Double, Bool)? {
        if case .op(let c) = token, c == 0x2B || c == 0x2D {
            guard depth < 64, advance(), let (value, percent) = signed(depth: depth + 1) else { return nil }
            return (c == 0x2D ? -value : value, percent)
        }
        return power(depth: depth)
    }

    private mutating func power(depth: Int) -> (Double, Bool)? {
        guard let (base, percent) = postfix(depth: depth) else { return nil }
        guard case .op(0x5E) = token else { return (base, percent) }
        operations += 1
        guard depth < 64, advance(), let (exponent, _) = signed(depth: depth + 1) else { return nil }
        return (pow(base, exponent), false)
    }

    private mutating func postfix(depth: Int) -> (Double, Bool)? {
        guard var value = primary(depth: depth) else { return nil }
        var percent = false
        while true {
            switch token {
            case .op(0x25):
                value /= 100
                percent = true
            case .op(0x21):
                guard let f = factorial(value) else { return nil }
                value = f
                percent = false
            case .op(0xB0), .name("deg"), .name("degrees"):
                value *= degree
                unitMarks += 1
                percent = false
            case .name("rad"), .name("radians"):
                unitMarks += 1
            case .superscript(let exponent):
                value = pow(value, exponent)
                percent = false
            default:
                return (value, percent)
            }
            operations += 1
            guard advance() else { return nil }
        }
    }

    private mutating func primary(depth: Int) -> Double? {
        guard depth < 64 else { return nil }
        switch token {
        case .number(let value):
            guard advance() else { return nil }
            return value
        case .op(0x28):
            // A missing ")" at the very end is fine: "(2+3" is already 5 while it is being typed.
            guard advance(), let value = expression(depth: depth + 1) else { return nil }
            if token == .op(0x29) {
                guard advance() else { return nil }
            } else if token != .end {
                return nil
            }
            return value
        case .op(0x221A):
            operations += 1
            guard advance(), let (value, _) = postfix(depth: depth + 1) else { return nil }
            return sqrt(value)
        case .name(let name):
            if let constant = constants[name] {
                operations += 1
                if name == "pi" || name == "π" || name == "tau" || name == "τ" { piUses += 1 }
                guard advance() else { return nil }
                return constant
            }
            guard let kind = functions[name] else { return nil }
            operations += 1
            let (piBefore, unitsBefore) = (piUses, unitMarks)
            guard advance(), let arguments = operands(depth: depth + 1) else { return nil }
            calls += 1
            // An angle is in degrees, as in Calculator, unless it is written with π or says its unit (30°, 1 rad).
            let radians = piUses > piBefore || unitMarks > unitsBefore
            return apply(kind, arguments, angleInRadians: radians)
        default:
            return nil
        }
    }

    /// A function's operands: everything in the brackets right after its name, sin(30) or log(8, 2), so that a
    /// power after them applies to the result (sin(30)^2); or, without brackets, the operand that follows, where
    /// powers bind tighter (sqrt 2^2 is 2, sin30 is sin 30).
    private mutating func operands(depth: Int) -> [Double]? {
        guard depth < 64 else { return nil }
        guard token == .op(0x28) else {
            // sin 2pi is the sine of 2π: a constant right after the number belongs to the operand.
            guard var (value, _) = power(depth: depth) else { return nil }
            while case .name(let name) = token, constants[name] != nil {
                operations += 1
                guard let (factor, _) = power(depth: depth) else { return nil }
                value *= factor
            }
            return [value]
        }
        argumentDepth += 1
        var values: [Double] = []
        guard advance() else { return nil }
        while true {
            guard let value = expression(depth: depth + 1) else { return nil }
            values.append(value)
            guard token == .op(0x2C), values.count < 2 else { break }
            guard advance() else { return nil }
        }
        argumentDepth -= 1
        if token == .op(0x29) {
            guard advance() else { return nil }
        } else if token != .end {
            return nil
        }
        return values
    }

    private func apply(_ kind: Function, _ arguments: [Double], angleInRadians: Bool) -> Double? {
        let x = arguments[0]
        if arguments.count == 2 {
            let y = arguments[1]
            switch kind {
            case .log:                                             // log(8, 2): the logarithm of 8 to base 2
                guard x > 0, y > 0, y != 1 else { return nil }
                return log(x) / log(y)
            case .root: return nthRoot(x, y)                       // root(27, 3): the cube root of 27
            default: return nil
            }
        }
        let angle = angleInRadians ? x : x * degree
        switch kind {
        case .sin: return trig(sin(angle), angle)
        case .cos: return trig(cos(angle), angle)
        case .tan:
            let c = trig(cos(angle), angle)
            return c == 0 ? nil : trig(sin(angle), angle) / c
        case .sec:
            let c = trig(cos(angle), angle)
            return c == 0 ? nil : 1 / c
        case .csc:
            let s = trig(sin(angle), angle)
            return s == 0 ? nil : 1 / s
        case .cot:
            let s = trig(sin(angle), angle)
            return s == 0 ? nil : trig(cos(angle), angle) / s
        case .asin: return asin(x) / degree                        // angles come back in degrees, as in Calculator
        case .acos: return acos(x) / degree
        case .atan: return atan(x) / degree
        case .sinh: return sinh(x)
        case .cosh: return cosh(x)
        case .tanh: return tanh(x)
        case .asinh: return asinh(x)
        case .acosh: return acosh(x)
        case .atanh: return atanh(x)
        case .sqrt: return sqrt(x)
        case .cbrt: return cbrt(x)
        case .root: return sqrt(x)
        case .ln: return log(x)
        case .log: return log10(x)
        case .log2: return log2(x)
        case .exp: return exp(x)
        case .abs: return abs(x)
        case .floor: return floor(x)
        case .ceil: return ceil(x)
        case .round: return x.rounded()
        }
    }

    private func nthRoot(_ x: Double, _ n: Double) -> Double? {
        guard n != 0 else { return nil }
        // An odd root of a negative number is real: root(-8, 3) is -2.
        if x < 0, n == n.rounded(), abs(n.truncatingRemainder(dividingBy: 2)) == 1 { return -pow(-x, 1 / n) }
        return pow(x, 1 / n)
    }

    /// n! for whole numbers, and the gamma function for the rest (2.5! is about 3.32), as in Calculator.
    private func factorial(_ value: Double) -> Double? {
        if value == value.rounded() {
            guard value >= 0, value <= 170 else { return nil }
            var result = 1.0
            var k = 2.0
            while k <= value {
                result *= k
                k += 1
            }
            return result
        }
        return tgamma(value + 1)
    }
}

private enum Function {
    case sin, cos, tan, sec, csc, cot, asin, acos, atan, sinh, cosh, tanh, asinh, acosh, atanh
    case sqrt, cbrt, root, ln, log, log2, exp, abs, floor, ceil, round
}

private let constants: [String: Double] = [
    "pi": Double.pi, "π": Double.pi, "tau": 2 * Double.pi, "τ": 2 * Double.pi, "e": M_E,
]

private let functions: [String: Function] = [
    "sin": .sin, "cos": .cos, "tan": .tan, "sec": .sec, "csc": .csc, "cosec": .csc, "cot": .cot,
    "asin": .asin, "acos": .acos, "atan": .atan, "arcsin": .asin, "arccos": .acos, "arctan": .atan,
    "sinh": .sinh, "cosh": .cosh, "tanh": .tanh, "asinh": .asinh, "acosh": .acosh, "atanh": .atanh,
    "arsinh": .asinh, "arcosh": .acosh, "artanh": .atanh,
    "sqrt": .sqrt, "cbrt": .cbrt, "root": .root, "nthroot": .root,
    "ln": .ln, "log": .log, "log10": .log, "log2": .log2,
    "exp": .exp, "abs": .abs, "floor": .floor, "ceil": .ceil, "round": .round,
]
