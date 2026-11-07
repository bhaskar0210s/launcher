// Renders Pounce's app icon into an .icns file (see `make icon`): a grid of nine app tiles on a graphite
// tile, the middle one lifted and lit with an arrow pointing up, the app being launched.

import CoreGraphics
import Foundation
import ImageIO

func color(_ rgb: Int, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: alpha)
}

/// A rectangle with continuous ("squircle") corners, the shape of macOS app icons.
func squircle(_ r: CGRect, _ k: CGFloat) -> CGPath {
    let x = r.minX, y = r.minY, w = r.width, h = r.height
    let p = CGMutablePath()
    p.move(to: CGPoint(x: x + 1.52866483 * k, y: y))
    // From the end of one edge to the start of the next, around the corner (cx, cy). (dx1, dy1) points back along the
    // incoming edge, (dx2, dy2) along the outgoing one.
    func corner(_ cx: CGFloat, _ cy: CGFloat, _ dx1: CGFloat, _ dy1: CGFloat, _ dx2: CGFloat, _ dy2: CGFloat) {
        func pt(_ a: CGFloat, _ b: CGFloat) -> CGPoint { CGPoint(x: cx + dx1 * a * k + dx2 * b * k, y: cy + dy1 * a * k + dy2 * b * k) }
        p.addLine(to: pt(1.52866483, 0))
        p.addCurve(to: pt(0.63149399, 0.07491100), control1: pt(1.08849296, 0), control2: pt(0.86840694, 0))
        p.addCurve(to: pt(0.07491100, 0.63149399), control1: pt(0.37282383, 0.16906599), control2: pt(0.16906599, 0.37282383))
        p.addCurve(to: pt(0, 1.52866483), control1: pt(0, 0.86840694), control2: pt(0, 1.08849296))
    }
    corner(x + w, y, -1, 0, 0, 1)       // bottom right (y grows upward)
    corner(x + w, y + h, 0, -1, -1, 0)  // top right
    corner(x, y + h, 1, 0, 0, -1)       // top left
    corner(x, y, 0, 1, 1, 0)            // bottom left
    p.closeSubpath()
    return p
}

func fill(_ g: CGContext, _ path: CGPath, _ rgb: Int, _ alpha: CGFloat = 1) {
    g.addPath(path)
    g.setFillColor(color(rgb, alpha))
    g.fillPath()
}

func gradientFill(_ g: CGContext, _ path: CGPath, top: Int, bottom: Int, _ y0: CGFloat, _ y1: CGFloat) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(top), color(bottom)] as CFArray, locations: nil)!
    g.saveGState()
    g.addPath(path)
    g.clip()
    g.drawLinearGradient(gradient, start: CGPoint(x: 0, y: y1), end: CGPoint(x: 0, y: y0), options: [])
    g.restoreGState()
}

func render(_ pixels: Int) -> Data {
    let g = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    g.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    // The tile: the macOS icon grid's 824-point square, with a soft shadow below it.
    let tile = squircle(CGRect(x: 100, y: 100, width: 824, height: 824), 120)
    g.saveGState()
    g.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: color(0x000000, 0.32))
    fill(g, tile, 0x1C1C1E)
    g.restoreGState()
    gradientFill(g, tile, top: 0x4A4A4F, bottom: 0x1D1D20, 100, 924)

    // Nine app tiles, quiet greys, brighter towards the top as if lit from above.
    let size: CGFloat = 168, gap: CGFloat = 46
    let origin = 512 - (3 * size + 2 * gap) / 2
    for row in 0..<3 {
        for column in 0..<3 where !(row == 1 && column == 1) {
            let x = origin + CGFloat(column) * (size + gap), y = origin + CGFloat(row) * (size + gap)
            let small = squircle(CGRect(x: x, y: y, width: size, height: size), 25)
            let lift = CGFloat(row) * 0x08
            gradientFill(g, small, top: 0x6A6A70 + Int(lift) * 0x010101, bottom: 0x4E4E54 + Int(lift) * 0x010101, y, y + size)
        }
    }

    // The middle tile, launching: larger, raised, blue, with an arrow pointing up.
    let big: CGFloat = 236
    let bx = 512 - big / 2, by = 512 - big / 2 + 14
    let launched = squircle(CGRect(x: bx, y: by, width: big, height: big), 35)
    g.saveGState()
    g.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: color(0x000000, 0.5))
    fill(g, launched, 0x1F6FEB)
    g.restoreGState()
    gradientFill(g, launched, top: 0x5AC8FA, bottom: 0x1A5FE0, by, by + big)

    let arrow = CGMutablePath()
    let cx: CGFloat = 512, top = by + big * 0.76, bottom = by + big * 0.24, wing = big * 0.2
    arrow.move(to: CGPoint(x: cx, y: bottom))
    arrow.addLine(to: CGPoint(x: cx, y: top))
    arrow.move(to: CGPoint(x: cx - wing, y: top - wing))
    arrow.addLine(to: CGPoint(x: cx, y: top))
    arrow.addLine(to: CGPoint(x: cx + wing, y: top - wing))
    g.addPath(arrow)
    g.setStrokeColor(color(0xFFFFFF))
    g.setLineWidth(big * 0.105)
    g.setLineCap(.round)
    g.setLineJoin(.round)
    g.strokePath()

    let image = g.makeImage()!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

/// The .icns container, written directly: iconutil re-encodes the pictures about twice as large.
func icns(_ entries: [(type: String, png: Data)]) -> Data {
    func bigEndian(_ value: Int) -> Data { withUnsafeBytes(of: UInt32(value).bigEndian) { Data($0) } }
    var body = Data()
    for entry in entries {
        body += Data(entry.type.utf8) + bigEndian(entry.png.count + 8) + entry.png
    }
    return Data("icns".utf8) + bigEndian(body.count + 8) + body
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: icon <out.icns> [preview.png]\n".utf8))
    exit(1)
}
// Sizes above 256pt@2x are left out on purpose: Finder scales up, and the app stays small.
let sizes: [(type: String, pixels: Int)] = [("icp4", 16), ("ic11", 32), ("icp5", 32), ("ic12", 64), ("ic07", 128), ("ic13", 256),
                                            ("ic08", 256), ("ic14", 512)]
try! icns(sizes.map { ($0.type, render($0.pixels)) }).write(to: URL(fileURLWithPath: arguments[1]))
if arguments.count > 2 { try! render(512).write(to: URL(fileURLWithPath: arguments[2])) }
