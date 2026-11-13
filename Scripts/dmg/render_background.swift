// Renders the DMG window background in the style of the website.
// usage: swift render_background.swift <website-assets-dir> <out-dir> <version-label>
import AppKit

let args = CommandLine.arguments
guard args.count == 4 else {
    FileHandle.standardError.write("usage: render_background.swift <assets> <out> <version>\n".data(using: .utf8)!)
    exit(2)
}
let assets = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])
let version = args[3]

// Window content size in points. Keep in sync with make_dmg.sh.
let W: CGFloat = 660, H: CGFloat = 440
// Icon centres in Finder coordinates (top-left origin). Keep in sync with make_dmg.sh.
let appCenter = CGPoint(x: 180, y: 250)
let linkCenter = CGPoint(x: 480, y: 250)

let page = NSColor(srgbRed: 0xf2/255, green: 0xf2/255, blue: 0xef/255, alpha: 1)
let ink = NSColor(srgbRed: 0x17/255, green: 0x17/255, blue: 0x17/255, alpha: 1)
let muted = NSColor(srgbRed: 0x5d/255, green: 0x5d/255, blue: 0x5a/255, alpha: 1)
let quiet = NSColor(srgbRed: 0x85/255, green: 0x85/255, blue: 0x81/255, alpha: 1)
let rule = NSColor(srgbRed: 0xdc/255, green: 0xdc/255, blue: 0xd8/255, alpha: 1)
let accent = NSColor(srgbRed: 0xff/255, green: 0xc9/255, blue: 0x28/255, alpha: 1)
let underline = NSColor(srgbRed: 0xe3/255, green: 0xb0/255, blue: 0x00/255, alpha: 1)

func font(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont { .systemFont(ofSize: size, weight: weight) }
func serifItalic(_ size: CGFloat) -> NSFont {
    for name in ["IowanOldStyle-Italic", "Palatino-Italic", "Georgia-Italic"] {
        if let f = NSFont(name: name, size: size) { return f }
    }
    return NSFontManager.shared.convert(.systemFont(ofSize: size), toHaveTrait: .italicFontMask)
}
func mono(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont { .monospacedSystemFont(ofSize: size, weight: weight) }

func attr(_ s: String, _ f: NSFont, _ c: NSColor, kern: CGFloat = 0) -> NSAttributedString {
    NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: c, .kern: kern])
}

/// Draws with a top-left origin so coordinates match Finder's icon positions.
func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    cg.translateBy(x: 0, y: H)
    cg.scaleBy(x: 1, y: -1)
    let flipped = NSGraphicsContext(cgContext: cg, flipped: true)
    NSGraphicsContext.current = flipped

    page.setFill()
    NSRect(x: 0, y: 0, width: W, height: H).fill()

    // Dial rings radiating from the app icon, like the hero's sound source.
    for (i, r) in [70.0, 120.0, 175.0, 235.0, 300.0].enumerated() {
        let ring = NSBezierPath(ovalIn: NSRect(x: appCenter.x - r, y: appCenter.y - r, width: r * 2, height: r * 2))
        ring.lineWidth = 1.5
        (i == 0 ? underline.withAlphaComponent(0.55) : rule).setStroke()
        if i > 1 { ring.setLineDash([2, 7], count: 2, phase: 0) }
        ring.stroke()
    }
    // Ticks around the inner ring.
    for k in 0..<24 {
        let a = CGFloat(k) / 24 * 2 * .pi
        let major = k % 6 == 0
        let r0: CGFloat = 120, r1: CGFloat = major ? 132 : 127
        let p = NSBezierPath()
        p.move(to: NSPoint(x: appCenter.x + cos(a) * r0, y: appCenter.y + sin(a) * r0))
        p.line(to: NSPoint(x: appCenter.x + cos(a) * r1, y: appCenter.y + sin(a) * r1))
        p.lineWidth = major ? 2 : 1.2
        (major ? ink.withAlphaComponent(0.55) : quiet.withAlphaComponent(0.6)).setStroke()
        p.stroke()
    }

    // Headline with a tilted highlighter behind the last word.
    let line1 = attr("Drag the ear", font(40, .heavy), ink, kern: -2.2)
    let line2a = attr("to ", font(40, .heavy), ink, kern: -2.2)
    let line2b = attr("Applications.", serifItalic(40), ink, kern: -0.6)
    line1.draw(at: NSPoint(x: 38, y: 34))
    line2a.draw(at: NSPoint(x: 38, y: 78))
    let bx = 38 + line2a.size().width + 4
    let bsz = line2b.size()
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform()
    t.translateX(by: bx + bsz.width / 2, yBy: 78 + bsz.height / 2)
    t.rotate(byDegrees: -1.2)
    t.concat()
    accent.setFill()
    NSBezierPath(roundedRect: NSRect(x: -bsz.width / 2 - 6, y: -bsz.height / 2 + 7, width: bsz.width + 12, height: bsz.height - 6),
                 xRadius: 6, yRadius: 6).fill()
    NSGraphicsContext.restoreGraphicsState()
    line2b.draw(at: NSPoint(x: bx, y: 78))

    // Version chip, styled like the primary button.
    let chipText = attr(version.uppercased(), mono(12, .bold), ink, kern: 0.6)
    let cs = chipText.size()
    let chip = NSRect(x: W - 38 - cs.width - 24, y: 40, width: cs.width + 24, height: 28)
    NSColor(srgbRed: 0xd3/255, green: 0x9f/255, blue: 0, alpha: 1).setFill()
    NSBezierPath(roundedRect: chip.offsetBy(dx: 0, dy: 3), xRadius: 14, yRadius: 14).fill()
    accent.setFill()
    NSBezierPath(roundedRect: chip, xRadius: 14, yRadius: 14).fill()
    chipText.draw(at: NSPoint(x: chip.minX + 12, y: chip.minY + (28 - cs.height) / 2))

    // Dashed sound ray from the app to Applications, with an arrowhead.
    let ray = NSBezierPath()
    let start = NSPoint(x: appCenter.x + 78, y: appCenter.y - 4)
    let end = NSPoint(x: linkCenter.x - 82, y: linkCenter.y - 4)
    ray.move(to: start)
    ray.curve(to: end, controlPoint1: NSPoint(x: start.x + 50, y: start.y - 52), controlPoint2: NSPoint(x: end.x - 50, y: end.y - 52))
    ray.lineWidth = 3
    ray.lineCapStyle = .round
    ray.setLineDash([2, 9], count: 2, phase: 0)
    ink.setStroke()
    ray.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: end.x - 12, y: end.y - 13))
    head.line(to: NSPoint(x: end.x + 1, y: end.y + 1))
    head.line(to: NSPoint(x: end.x - 16, y: end.y + 5))
    head.lineWidth = 3.5
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()
    // Little yellow source dot riding the ray.
    let mid = NSPoint(x: (start.x + end.x) / 2, y: start.y - 39)
    for (r, a) in [(22.0, 0.18), (14.0, 0.35)] {
        underline.withAlphaComponent(a).setStroke()
        let p = NSBezierPath(ovalIn: NSRect(x: mid.x - r, y: mid.y - r, width: r * 2, height: r * 2))
        p.lineWidth = 2
        p.stroke()
    }
    accent.setFill()
    let dot = NSBezierPath(ovalIn: NSRect(x: mid.x - 8, y: mid.y - 8, width: 16, height: 16))
    dot.fill()
    ink.setStroke()
    dot.lineWidth = 2.5
    dot.stroke()

    // Stickers.
    func sticker(_ name: String, center: CGPoint, width: CGFloat, degrees: CGFloat) {
        guard let img = NSImage(contentsOf: assets.appendingPathComponent(name)) else {
            FileHandle.standardError.write("missing sticker \(name)\n".data(using: .utf8)!)
            return
        }
        let h = width * img.size.height / img.size.width
        NSGraphicsContext.saveGraphicsState()
        let tr = NSAffineTransform()
        tr.translateX(by: center.x, yBy: center.y)
        tr.rotate(byDegrees: degrees)
        tr.concat()
        let shadow = NSShadow()
        shadow.shadowColor = ink.withAlphaComponent(0.22)
        shadow.shadowOffset = NSSize(width: 0, height: -5)
        shadow.shadowBlurRadius = 7
        shadow.set()
        img.draw(in: NSRect(x: -width / 2, y: -h / 2, width: width, height: h), from: .zero, operation: .sourceOver,
                 fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()
    }
    sticker("sticker-hrtf.svg", center: CGPoint(x: 600, y: 150), width: 92, degrees: 8)
    sticker("sticker-wave.svg", center: CGPoint(x: 606, y: 312), width: 80, degrees: -7)

    // Rotated ticker band along the bottom.
    NSGraphicsContext.saveGraphicsState()
    let bt = NSAffineTransform()
    bt.translateX(by: W / 2, yBy: H - 30)
    bt.rotate(byDegrees: -1.4)
    bt.concat()
    accent.setFill()
    NSRect(x: -W, y: -19, width: W * 2, height: 38).fill()
    let tick = attr(String(repeating: "Scan it ✦ SOFA it ✦ Slay ✦ Mesh in ✦ HRTF out ✦ ", count: 4).uppercased(),
                    font(17, .heavy), ink, kern: -0.3)
    tick.draw(at: NSPoint(x: -W / 2 - 40, y: -tick.size().height / 2))
    NSGraphicsContext.restoreGraphicsState()

    // Gatekeeper hint for the ad-hoc signed beta.
    let hint = attr("Beta, not notarized. If macOS blocks the first launch: System Settings › Privacy & Security › Open Anyway.",
                    font(10.5, .medium), muted)
    hint.draw(at: NSPoint(x: (W - hint.size().width) / 2, y: H - 80))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
for (scale, name) in [(1.0, "background.png"), (2.0, "background@2x.png")] {
    let data = render(scale: scale).representation(using: .png, properties: [:])!
    try data.write(to: outDir.appendingPathComponent(name))
}
