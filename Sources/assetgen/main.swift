import AppKit

// Renders every raster asset for AltTab from code, so the artwork is
// reproducible and versioned. The cup shape mirrors the runtime menu bar icon
// in Sources/AltTab/StatusIcons.swift — keep the two in sync.
//
// Usage:
//   assetgen icon <out.png>            1024x1024 app icon
//   assetgen dmg-background <out.png>  1320x800 px (660x400 pt @2x)
//   assetgen web <outdir>              alttab@2x/alttab/apple-touch-icon/favicon

let markColor = NSColor(calibratedRed: 0.30, green: 0.58, blue: 0.98, alpha: 1.0)
let markLight = NSColor(calibratedRed: 0.50, green: 0.74, blue: 1.00, alpha: 1.0)

// MARK: - PNG rendering harness

func renderPNG(pixelsWide: Int, pixelsHigh: Int, pointSize: NSSize? = nil,
               draw: (NSRect) -> Void) -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { fatalError("could not create bitmap rep") }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
    NSGraphicsContext.current?.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    // Setting a smaller point size after drawing stamps the PNG with the
    // matching DPI (e.g. 144), so Finder shows the DMG background at point size.
    if let pt = pointSize { rep.size = pt }
    guard let data = rep.representation(using: .png, properties: [:])
    else { fatalError("could not encode png") }
    return data
}

func write(_ data: Data, to path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    do {
        try data.write(to: url)
        print("wrote \(path)")
    } catch {
        FileHandle.standardError.write("failed to write \(path): \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

// MARK: - The mark (mirror of StatusIcons.draw, 18-unit design space)

/// Two overlapping windows: the one behind as an outline, the one in front
/// filled. It reads as "switch" at 18 points and still at 1024.
func drawMark(in rect: NSRect, color: NSColor,
              bodyGradient: NSGradient? = nil, lineScale: CGFloat = 1.0) {
    let s = min(rect.width, rect.height) / 18.0
    let t = NSAffineTransform()
    t.translateX(by: rect.minX, yBy: rect.minY)
    t.scale(by: s)

    color.setStroke()
    color.setFill()

    let back = NSBezierPath(
        roundedRect: NSRect(x: 6.2, y: 7.2, width: 9.4, height: 7.2),
        xRadius: 1.6, yRadius: 1.6)
    back.transform(using: t as AffineTransform)
    back.lineWidth = 1.3 * s * lineScale
    back.stroke()

    let front = NSBezierPath(
        roundedRect: NSRect(x: 2.4, y: 3.6, width: 10.4, height: 8.2),
        xRadius: 1.9, yRadius: 1.9)
    front.transform(using: t as AffineTransform)
    if let g = bodyGradient {
        g.draw(in: front, angle: -90)
    } else {
        front.fill()
    }

    // A title bar on the front window, punched out of the fill.
    let bar = NSBezierPath(
        roundedRect: NSRect(x: 2.4, y: 9.6, width: 10.4, height: 2.2),
        xRadius: 1.0, yRadius: 1.0)
    bar.transform(using: t as AffineTransform)
    NSColor.black.withAlphaComponent(0.28).setFill()
    bar.fill()
    color.setFill()
}

// MARK: - App icon

func drawIcon(_ canvas: NSRect) {
    let px = canvas.width
    let u = px / 1024.0 // design units

    // Standard macOS icon grid: 824x824 squircle centered on a 1024 canvas.
    let squircle = NSBezierPath(
        roundedRect: NSRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u),
        xRadius: 186 * u, yRadius: 186 * u)

    let bg = NSGradient(
        starting: NSColor(calibratedRed: 0.14, green: 0.13, blue: 0.12, alpha: 1),
        ending: NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.05, alpha: 1))
    bg?.draw(in: squircle, angle: -90)

    // Soft warm glow behind the cup.
    NSGraphicsContext.current?.saveGraphicsState()
    squircle.addClip()
    let glow = NSGradient(colors: [
        markColor.withAlphaComponent(0.22),
        markColor.withAlphaComponent(0.0),
    ])
    glow?.draw(
        fromCenter: NSPoint(x: 512 * u, y: 470 * u), radius: 0,
        toCenter: NSPoint(x: 512 * u, y: 470 * u), radius: 420 * u,
        options: [])
    NSGraphicsContext.current?.restoreGraphicsState()

    // Hairline inner border for definition on pure-black backgrounds.
    NSColor.white.withAlphaComponent(0.07).setStroke()
    squircle.lineWidth = 2 * u
    squircle.stroke()

    // The cup, warm gradient fill, gently oversized. Nudged +20u right so the
    // glyph (whose handle extends right) sits on the optical center.
    let cupRect = NSRect(x: 252 * u, y: 210 * u, width: 560 * u, height: 560 * u)
    let bodyGradient = NSGradient(starting: markLight, ending: markColor)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * u)
    shadow.shadowBlurRadius = 28 * u
    shadow.set()
    drawMark(in: cupRect, color: markColor, bodyGradient: bodyGradient)
    NSGraphicsContext.current?.restoreGraphicsState()
}

// MARK: - DMG background (drawn in pixels @2x; point size stamped afterwards)

func drawDMGBackground(_ canvas: NSRect) {
    // 1320x800 px = 660x400 pt. Finder icon slots (top-left origin, points):
    // AltTab.app at (165, 228), Applications at (495, 228), icon size 128.
    //
    // Two zones, and the reason is not decoration: a Finder window that has a
    // background picture is always rendered in the LIGHT appearance, so item
    // labels are black for every user regardless of their system setting.
    // The brand lives in the dark hero band (text we draw ourselves, in white);
    // the icons and their black labels sit on a light shelf below it.
    let u = canvas.width / 1320.0
    func pt(_ x: CGFloat, _ yFromTop: CGFloat) -> NSPoint {
        NSPoint(x: x * 2 * u, y: canvas.height - yFromTop * 2 * u)
    }

    let shelfTop = pt(0, 150).y

    NSColor(calibratedRed: 0.04, green: 0.04, blue: 0.04, alpha: 1).setFill()
    canvas.fill()

    // Warm ivory shelf — ~18:1 against black labels.
    NSColor(calibratedRed: 0.945, green: 0.933, blue: 0.910, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: canvas.width, height: shelfTop).fill()

    // Hairline where the two zones meet.
    NSColor(calibratedWhite: 0.0, alpha: 0.35).setFill()
    NSRect(x: 0, y: shelfTop, width: canvas.width, height: 1 * 2 * u).fill()

    // Warm glow behind the wordmark, clipped to the hero band.
    NSGraphicsContext.current?.saveGraphicsState()
    NSBezierPath(rect: NSRect(x: 0, y: shelfTop, width: canvas.width,
                              height: canvas.height - shelfTop)).addClip()
    let glow = NSGradient(colors: [
        markColor.withAlphaComponent(0.16),
        markColor.withAlphaComponent(0.0),
    ])
    glow?.draw(fromCenter: NSPoint(x: canvas.width / 2, y: pt(0, 78).y), radius: 0,
               toCenter: NSPoint(x: canvas.width / 2, y: pt(0, 78).y),
               radius: canvas.width * 0.30, options: [])
    NSGraphicsContext.current?.restoreGraphicsState()

    // Wordmark with a small colored cup to its left.
    let title = "AltTab" as NSString
    let titleFont = NSFont.systemFont(ofSize: 30 * 2 * u, weight: .semibold)
    let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: titleFont,
        .foregroundColor: NSColor(calibratedWhite: 0.96, alpha: 1),
        .kern: -0.5 * 2 * u,
    ]
    let titleSize = title.size(withAttributes: titleAttrs)
    let cupSide = 40.0 * 2 * u
    let groupWidth = cupSide + 14 * 2 * u + titleSize.width
    let groupLeft = (canvas.width - groupWidth) / 2
    let titleBaseline = pt(0, 88).y
    drawMark(in: NSRect(x: groupLeft, y: titleBaseline - 6 * 2 * u,
                       width: cupSide, height: cupSide),
             color: markColor,
             bodyGradient: NSGradient(starting: markLight, ending: markColor))
    title.draw(at: NSPoint(x: groupLeft + cupSide + 14 * 2 * u, y: titleBaseline),
               withAttributes: titleAttrs)

    // Arrow between the two icon slots, on the light shelf.
    let arrowY = pt(0, 228).y
    let arrowStart = pt(258, 0).x
    let arrowEnd = pt(402, 0).x
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: arrowStart, y: arrowY))
    arrow.line(to: NSPoint(x: arrowEnd, y: arrowY))
    let head = 13.0 * 2 * u
    arrow.move(to: NSPoint(x: arrowEnd - head, y: arrowY + head * 0.72))
    arrow.line(to: NSPoint(x: arrowEnd, y: arrowY))
    arrow.line(to: NSPoint(x: arrowEnd - head, y: arrowY - head * 0.72))
    NSColor(calibratedWhite: 0.45, alpha: 1).setStroke()
    arrow.lineWidth = 2.5 * 2 * u
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.stroke()

    // Bilingual caption below the labels (the DMG cannot detect language).
    let caption = "Arraste para Aplicativos  ·  Drag to Applications" as NSString
    let captionAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12 * 2 * u, weight: .regular),
        .foregroundColor: NSColor(calibratedWhite: 0.42, alpha: 1),
    ]
    let captionSize = caption.size(withAttributes: captionAttrs)
    caption.draw(at: NSPoint(x: (canvas.width - captionSize.width) / 2, y: pt(0, 368).y),
                 withAttributes: captionAttrs)
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(
        "usage: assetgen icon|dmg-background <out.png> | assetgen web <outdir>\n"
            .data(using: .utf8)!)
    exit(64)
}

switch args[1] {
case "icon":
    write(renderPNG(pixelsWide: 1024, pixelsHigh: 1024, draw: drawIcon), to: args[2])

case "dmg-background":
    write(renderPNG(pixelsWide: 1320, pixelsHigh: 800,
                    pointSize: NSSize(width: 660, height: 400),
                    draw: drawDMGBackground),
          to: args[2])

case "web":
    let dir = args[2]
    // Re-rendered per size (vector), not resampled.
    write(renderPNG(pixelsWide: 1024, pixelsHigh: 1024, draw: drawIcon),
          to: dir + "/alttab@2x.png")
    write(renderPNG(pixelsWide: 512, pixelsHigh: 512, draw: drawIcon),
          to: dir + "/alttab.png")
    write(renderPNG(pixelsWide: 180, pixelsHigh: 180, draw: drawIcon),
          to: dir + "/apple-touch-icon.png")
    write(renderPNG(pixelsWide: 64, pixelsHigh: 64, draw: drawIcon),
          to: dir + "/favicon.png")

default:
    FileHandle.standardError.write("unknown command \(args[1])\n".data(using: .utf8)!)
    exit(64)
}
