// Text as Unicode scalar values (UTF-32), the way names are searched.

/// Decodes UTF-8 without ever failing: each malformed byte becomes U+FFFD.
func decodeUTF8(_ bytes: [UInt8]) -> [UInt32] {
    var out: [UInt32] = []
    out.reserveCapacity(bytes.count)
    var i = 0
    let n = bytes.count
    while i < n {
        let c = bytes[i]
        if c < 0x80 {
            out.append(UInt32(c))
            i += 1
            continue
        }
        var cp: UInt32
        let length: Int
        if c & 0xE0 == 0xC0 {
            cp = UInt32(c & 0x1F)
            length = 2
        } else if c & 0xF0 == 0xE0 {
            cp = UInt32(c & 0x0F)
            length = 3
        } else if c & 0xF8 == 0xF0 {
            cp = UInt32(c & 0x07)
            length = 4
        } else {
            out.append(0xFFFD)
            i += 1
            continue
        }
        var ok = n - i >= length
        var k = 1
        while ok && k < length {
            ok = bytes[i + k] & 0xC0 == 0x80
            cp = cp << 6 | UInt32(bytes[i + k] & 0x3F)
            k += 1
        }
        let overlong = (length == 2 && cp < 0x80) || (length == 3 && cp < 0x800) || (length == 4 && cp < 0x10000)
        if !ok || overlong || cp > 0x10FFFF || (0xD800...0xDFFF).contains(cp) {
            out.append(0xFFFD)
            i += 1
            continue
        }
        out.append(cp)
        i += length
    }
    return out
}

/// Folds case (Latin, Greek, Cyrillic) and Latin-1 accents, so a search for "e" finds "É".
func fold(_ c: UInt32) -> UInt32 {
    if c < 0x80 { return c >= 0x41 && c <= 0x5A ? c + 32 : c }
    if c >= 0xC0 && c <= 0xFF {
        // Base letters for U+00C0…U+00FF; "*" keeps × and ÷ as they are.
        let base = latinBase[Int(c - 0xC0)]
        return base == 0x2A ? c : UInt32(base)
    }
    if c >= 0x391 && c <= 0x3A9 { return c + 32 }  // Greek capitals
    if c >= 0x410 && c <= 0x42F { return c + 32 }  // Cyrillic capitals
    if c >= 0x400 && c <= 0x40F { return c + 80 }  // Cyrillic Ѐ…Џ
    return c
}

private let latinBase = Array("aaaaaaaceeeeiiiidnooooo*ouuuuytsaaaaaaaceeeeiiiidnooooo*ouuuuyty".utf8)

/// The text folded and with spaces at either end removed: the form in which queries are remembered.
func normalizedQuery(_ text: String) -> String {
    var scalars = decodeUTF8(Array(text.utf8)).map(fold)
    while let last = scalars.last, isSpace(last) { scalars.removeLast() }
    var start = 0
    while start < scalars.count && isSpace(scalars[start]) { start += 1 }
    var out = ""
    for c in scalars[start...] {
        if let scalar = Unicode.Scalar(c) { out.unicodeScalars.append(scalar) }
    }
    return out
}

func isSpace(_ c: UInt32) -> Bool {
    c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0xA0 || c == 0x3000
}
