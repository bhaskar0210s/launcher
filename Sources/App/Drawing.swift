// Drawing shared by every view: CPU rendering into IOSurfaces, text lines, and the few glyphs (drawn with paths:
// system symbol images would load the whole symbol catalog for four glyphs).

import AppKit
import CoreText
import IOSurface

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

// White and black in sRGB: NSColor.white and .black are gray-space colors, and drawing one into an sRGB surface goes
// through a ColorSync conversion that leaves a lookup table behind.
let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
let black = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

/// An 8-bit BGRA IOSurface drawn on the CPU and tagged with its color space. As a layer's contents the window
/// server composites straight from this memory, so the pixels exist only once.
func makeSurface(width: Int, height: Int, draw: (CGContext) -> Void) -> IOSurface? {
    guard width > 0, height > 0,
          let surface = IOSurface(properties: [.width: width, .height: height, .bytesPerElement: 4, .pixelFormat: 0x4247_5241])  // 'BGRA'
    else { return nil }
    if let description = sRGB.copyPropertyList() { IOSurfaceSetValue(surface, kIOSurfaceColorSpace, description) }
    surface.lock(options: [], seed: nil)
    defer { surface.unlock(options: [], seed: nil) }
    guard let context = CGContext(data: surface.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: surface.bytesPerRow, space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    draw(context)
    return surface
}

/// Renders a view's drawing on the CPU into its layer's contents. The system's own drawing path moves larger views
/// onto the GPU, which loads a couple of megabytes of shaders for good.
@MainActor
func renderIntoLayer(_ view: NSView, _ draw: (NSRect) -> Void) {
    let size = view.bounds.size
    let scale = view.window?.backingScaleFactor ?? 2
    let width = Int((size.width * scale).rounded(.up)), height = Int((size.height * scale).rounded(.up))
    let surface = makeSurface(width: width, height: height) { context in
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
    }
    view.layer?.contentsScale = scale
    view.layer?.contents = surface
}

/// A flipped view drawn through renderIntoLayer: subclasses just implement draw(_:).
class CanvasView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        renderIntoLayer(self) { draw($0) }
    }

    // Light or dark mode switched while the window is open.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A hairline between the parts of the window.
final class Rule: CanvasView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        bounds.fill()
    }
}

extension NSView {
    /// A color resolved for this view's appearance (light or dark), for Core Graphics.
    func resolved(_ color: NSColor) -> CGColor {
        var cg = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { cg = color.cgColor }
        return cg
    }
}

// MARK: Text

/// A line whose color comes from the context, so one line serves selected and unselected rows.
func makeLine(_ string: String, font: NSFont) -> CTLine {
    let text = NSAttributedString(string: string, attributes: [.font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true])
    return CTLineCreateWithAttributedString(text)
}

/// A line with some characters (indices into its Unicode scalars) in a bolder font, cut to `width` with an ellipsis.
func makeLine(_ string: String, font: NSFont, bold: NSFont, emphasized: [Int], width: CGFloat) -> CTLine {
    let text = NSMutableAttributedString(string: string, attributes: [
        .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
    ])
    if !emphasized.isEmpty {
        // Scalar indices to UTF-16 ranges.
        var offsets: [Int] = []
        var offset = 0
        for scalar in string.unicodeScalars {
            offsets.append(offset)
            offset += scalar.utf16.count
        }
        offsets.append(offset)
        for i in emphasized where i + 1 < offsets.count {
            text.addAttribute(.font, value: bold, range: NSRange(location: offsets[i], length: offsets[i + 1] - offsets[i]))
        }
    }
    let line = CTLineCreateWithAttributedString(text)
    guard lineWidth(line) > width else { return line }
    return CTLineCreateTruncatedLine(line, width, .end, makeLine("…", font: font)) ?? line
}

func lineWidth(_ line: CTLine?) -> CGFloat {
    line.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) } ?? 0
}

/// Draws a line centered vertically in a band of a flipped view.
func drawLine(_ context: CGContext, _ line: CTLine, x: CGFloat, top: CGFloat, height: CGFloat, font: NSFont, color: CGColor) {
    let baseline = (top + (height - font.ascender + font.descender) / 2 + font.ascender).rounded()
    context.saveGState()
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)  // the view is flipped
    context.textPosition = CGPoint(x: x, y: baseline)
    context.setFillColor(color)
    CTLineDraw(line, context)
    context.restoreGState()
}

func drawText(_ text: String, x: CGFloat, midY: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) {
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
    let measured = text.size(withAttributes: attributes)
    text.draw(at: NSPoint(x: x, y: (midY - measured.height / 2).rounded()), withAttributes: attributes)
}

func textWidth(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
    text.size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width.rounded(.up)
}

// MARK: Glyphs

enum Glyph {
    case search, equals, check, power, plus, minus
}

/// Draws one of Pounce's glyphs into a square of a flipped view.
func drawGlyph(_ glyph: Glyph, in box: NSRect, color: NSColor) {
    let s = min(box.width, box.height)
    let x0 = box.minX + (box.width - s) / 2, y0 = box.minY + (box.height - s) / 2
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x0 + x * s, y: y0 + y * s) }
    let path = NSBezierPath()
    path.lineWidth = max(1.5, s * 0.1)
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    color.setStroke()

    switch glyph {
    case .search:
        path.appendOval(in: NSRect(x: x0 + 0.1 * s, y: y0 + 0.1 * s, width: 0.6 * s, height: 0.6 * s))
        path.move(to: p(0.64, 0.64))
        path.line(to: p(0.9, 0.9))
    case .equals:
        path.move(to: p(0.2, 0.38))
        path.line(to: p(0.8, 0.38))
        path.move(to: p(0.2, 0.62))
        path.line(to: p(0.8, 0.62))
    case .check:
        path.move(to: p(0.22, 0.52))
        path.line(to: p(0.42, 0.72))
        path.line(to: p(0.78, 0.3))
    case .plus:
        path.move(to: p(0.5, 0.18))
        path.line(to: p(0.5, 0.82))
        path.move(to: p(0.18, 0.5))
        path.line(to: p(0.82, 0.5))
    case .minus:
        path.move(to: p(0.18, 0.5))
        path.line(to: p(0.82, 0.5))
    case .power:
        // An open ring with a bar through the gap (the views are flipped: angles run clockwise).
        path.appendArc(withCenter: p(0.5, 0.54), radius: 0.34 * s, startAngle: -58, endAngle: 238, clockwise: false)
        path.move(to: p(0.5, 0.1))
        path.line(to: p(0.5, 0.5))
    }
    path.stroke()
}
