// Picture-Line — photo cards and decorations.
import AppKit
import ImageIO

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

let stringColors: [String: CGColor] = [
    "twine": rgb(0.58, 0.44, 0.31), "red": rgb(0.74, 0.16, 0.17), "white": rgb(0.95, 0.94, 0.91),
    "black": rgb(0.13, 0.13, 0.14), "gold": rgb(0.84, 0.67, 0.30),
]
let clipColors: [String: (CGColor, CGColor)] = [
    "wood": (rgb(0.85, 0.69, 0.48), rgb(0.55, 0.41, 0.27)), "red": (rgb(0.86, 0.25, 0.24), rgb(0.55, 0.12, 0.12)),
    "blue": (rgb(0.36, 0.60, 0.88), rgb(0.18, 0.35, 0.58)), "mint": (rgb(0.55, 0.85, 0.72), rgb(0.27, 0.55, 0.43)),
    "pink": (rgb(0.96, 0.62, 0.76), rgb(0.70, 0.35, 0.50)), "black": (rgb(0.18, 0.18, 0.19), rgb(0.05, 0.05, 0.05)),
]
let lightColors = [rgb(1, 0.38, 0.32), rgb(1, 0.80, 0.30), rgb(0.42, 0.90, 0.45), rgb(0.38, 0.62, 1), rgb(1, 0.48, 0.80)]
let warmLight = rgb(1, 0.82, 0.52)
let holiColors = [rgb(1, 0.18, 0.55), rgb(1, 0.85, 0.10), rgb(0.15, 0.80, 0.35), rgb(0.20, 0.50, 1), rgb(1, 0.50, 0.10)]
let ink = NSColor(srgbRed: 0.13, green: 0.17, blue: 0.36, alpha: 1)

// MARK: photo

@MainActor final class Photo {
    var r: PhotoRecord
    let thumb: CGImage
    lazy var gray: CGImage? = grayscale(thumb)
    var angle: CGFloat = 0, spin: CGFloat = 0, lastV = CGPoint.zero
    var flip: CGFloat = 0, flipTarget: CGFloat = 0
    var lifted = false, lastRustle = 0.0, version = 0
    var cache: [Bool: (key: String, img: CGImage)] = [:]

    init?(_ r: PhotoRecord) {
        guard let t = loadImage(photoURL(r.file), max: 420) else { return nil }
        self.r = r; thumb = t
    }

    var aspect: CGFloat { CGFloat(thumb.width) / CGFloat(thumb.height) }
    var width: CGFloat { (cfg.cardWidth * CGFloat(r.scale ?? 1)).rounded() }
    var layout: CardLayout { cardLayout(width: width, aspect: aspect, caption: !r.caption.isEmpty) }
    var showsBack: Bool { flip > 0.5 }

    var developed: CGFloat {
        let s = cfg.developSeconds
        return s == 0 ? 1 : CGFloat(min(1, max(0, Date().timeIntervalSince(r.added) / s)))
    }

    func card(back: Bool, holi: Bool) -> CGImage? {
        let dev = developed
        let key = "\(cfg.frame)|\(width)|\(cfg.font)|\(version)|\(Int(dev * 40))|\(holi)"
        if let c = cache[back], c.key == key { return c.img }
        guard let flat = renderCard(self, width: width, image: thumb, back: back, develop: dev, holi: holi),
              let img = withShadow(flat) else { return nil }
        if dev >= 1 { gray = nil } // fully developed: the grey copy is no longer needed
        cache[back] = (key, img)
        return img
    }
}

// MARK: card layout and rendering (y-down points)

struct CardLayout { var size: CGSize; var image: CGRect; var strip: CGRect? }

@MainActor func cardLayout(width w: CGFloat, aspect: CGFloat, caption: Bool) -> CardLayout {
    let a = min(1.6, max(0.62, aspect))
    switch cfg.frame {
    case "classic":
        let b = (w * 0.055).rounded(), ih = (w - 2 * b) / a, bottom = caption ? w * 0.18 : b
        return CardLayout(size: CGSize(width: w, height: b + ih + bottom),
                          image: CGRect(x: b, y: b, width: w - 2 * b, height: ih),
                          strip: caption ? CGRect(x: b, y: b + ih, width: w - 2 * b, height: bottom) : nil)
    case "bare":
        return CardLayout(size: CGSize(width: w, height: w / a), image: CGRect(x: 0, y: 0, width: w, height: w / a), strip: nil)
    default: // Polaroid: square picture, deep bottom strip
        let b = w * 0.06, iw = w - 2 * b
        return CardLayout(size: CGSize(width: w, height: b + iw + w * 0.25), image: CGRect(x: b, y: b, width: iw, height: iw),
                          strip: CGRect(x: b, y: b + iw, width: iw, height: w * 0.25))
    }
}

/// Draws a CGImage upright into a y-down context.
func put(_ c: CGContext, _ img: CGImage, _ r: CGRect) {
    c.saveGState()
    c.translateBy(x: 0, y: r.maxY + r.minY); c.scaleBy(x: 1, y: -1)
    c.draw(img, in: r)
    c.restoreGState()
}

func putFill(_ c: CGContext, _ img: CGImage, _ r: CGRect, alpha: CGFloat = 1) {
    let a = CGFloat(img.width) / CGFloat(img.height)
    var d = r
    if a > r.width / r.height { d.size.width = r.height * a; d.origin.x = r.midX - d.width / 2 }
    else { d.size.height = r.width / a; d.origin.y = r.midY - d.height / 2 }
    c.saveGState(); c.clip(to: r); c.setAlpha(alpha); put(c, img, d); c.restoreGState()
}

func smooth(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat { let t = min(1, max(0, (x - a) / (b - a))); return t * t * (3 - 2 * t) }

// MARK: fonts (bundled ones are SIL Open Font Licence; licences ship in Resources/Fonts)

let handwritingFonts = [("Kalam", "Kalam-Regular"), ("Patrick Hand", "PatrickHand-Regular"), ("Caveat", "Caveat-Regular"),
                        ("Noteworthy", "Noteworthy-Light"), ("Bradley Hand", "BradleyHandITCTT-Bold")]

func registerFonts() {
    var dirs = [Bundle.main.resourceURL?.appendingPathComponent("Fonts")]
    #if DEBUG // dev builds run from the source folder
    dirs.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Fonts"))
    #endif
    for dir in dirs.compactMap({ $0 }) {
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
        }
    }
}

/// Handwriting for captions and notes. Hindi and Marathi fall back to Kalam, Gujarati to Farsan, so names keep a hand-drawn look.
@MainActor func handwriting(_ size: CGFloat, font name: String? = nil) -> NSFont {
    let name = name ?? cfg.font
    let k: CGFloat = ["Caveat-Regular": 1.2, "BradleyHandITCTT-Bold": 1.04, "PatrickHand-Regular": 1.05][name] ?? 1
    let base = NSFont(name: name, size: size * k) ?? NSFont(name: "Kalam-Regular", size: size) ?? .systemFont(ofSize: size)
    let fallbacks = ["Kalam-Regular", "Farsan-Regular"].filter { $0 != name }.map { NSFontDescriptor(name: $0, size: 0) }
    return NSFont(descriptor: base.fontDescriptor.addingAttributes([.cascadeList: fallbacks]), size: 0) ?? base
}

/// The Picture-Line wordmark: Fraunces, a soft serif, at a display optical size.
func wordmark(_ size: CGFloat) -> NSFont {
    func tag(_ s: String) -> Int { s.utf8.reduce(0) { $0 << 8 | Int($1) } }
    let d = NSFontDescriptor(fontAttributes: [.family: "Fraunces",
                                              .variation: [tag("wght"): 580, tag("opsz"): 72, tag("SOFT"): 50, tag("WONK"): 0]])
    return NSFont(descriptor: d, size: size) ?? .systemFont(ofSize: size, weight: .semibold)
}

@MainActor func renderCard(_ p: Photo, width w: CGFloat, image: CGImage, back: Bool, develop t: CGFloat,
                           holi: Bool, scale: CGFloat = 2) -> CGImage? {
    let L = cardLayout(width: w, aspect: p.aspect, caption: !p.r.caption.isEmpty)
    let pw = Int(L.size.width * scale), ph = Int(L.size.height * scale)
    guard let c = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    c.translateBy(x: 0, y: CGFloat(ph)); c.scaleBy(x: scale, y: -scale)
    c.interpolationQuality = .high
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: true)
    defer { NSGraphicsContext.restoreGraphicsState() }
    let full = CGRect(origin: .zero, size: L.size)

    if back {
        c.setFillColor(rgb(0.96, 0.945, 0.905)); c.fill(full)
        c.setStrokeColor(rgb(0, 0, 0, 0.07)); c.setLineWidth(0.6); c.stroke(full.insetBy(dx: 0.3, dy: 0.3))
        let m = w * 0.1
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byWordWrapping
        let empty = p.r.note.isEmpty
        let note = NSAttributedString(string: empty ? "Right-click to write a note" : p.r.note, attributes: [
            .font: empty ? NSFont.systemFont(ofSize: w * 0.06) : handwriting(w * 0.095),
            .foregroundColor: empty ? NSColor(white: 0, alpha: 0.3) : ink, .paragraphStyle: style,
        ])
        note.draw(with: CGRect(x: m, y: m, width: w - 2 * m, height: L.size.height - 2 * m - w * 0.12),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if let d = p.r.date {
            let s = NSAttributedString(string: dayKey(d, "d MMMM yyyy"), attributes: [.font: handwriting(w * 0.075), .foregroundColor: ink])
            let sz = s.size()
            s.draw(at: CGPoint(x: w - m - sz.width, y: L.size.height - m - sz.height))
        }
        return c.makeImage()
    }

    if cfg.frame != "bare" {
        c.setFillColor(rgb(0.985, 0.98, 0.965)); c.fill(full)
        c.setStrokeColor(rgb(0, 0, 0, 0.06)); c.setLineWidth(0.5); c.stroke(full.insetBy(dx: 0.25, dy: 0.25))
    }
    if t >= 1 {
        putFill(c, image, L.image)
    } else { // develops from milky white: grey shapes first, then colour
        c.setFillColor(rgb(0.93, 0.935, 0.915)); c.fill(L.image)
        if let g = p.gray { putFill(c, g, L.image, alpha: smooth(0.05, 0.55, t)) }
        putFill(c, image, L.image, alpha: smooth(0.3, 1, t))
        c.setFillColor(rgb(0.94, 0.945, 0.925, 0.85 * (1 - smooth(0, 0.8, t)))); c.fill(L.image)
    }
    if cfg.frame != "bare" { c.setStrokeColor(rgb(0, 0, 0, 0.09)); c.setLineWidth(0.5); c.stroke(L.image) }

    if holi { // a few smudges of gulal on the frame, same spots every time
        let u = p.r.id.uuid, seeds = [u.0, u.1, u.2, u.3, u.4, u.5]
        for k in 0..<3 {
            let x = CGFloat(seeds[k]) / 255 * w, y = CGFloat(seeds[k + 3]) / 255 * L.size.height
            let col = holiColors[Int(seeds[k]) % holiColors.count]
            let g = CGGradient(colorsSpace: nil, colors: [col.copy(alpha: 0.45)!, col.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
            c.drawRadialGradient(g, startCenter: CGPoint(x: x, y: y), startRadius: 0, endCenter: CGPoint(x: x, y: y), endRadius: w * 0.16, options: [])
        }
    }

    if let s = L.strip, !p.r.caption.isEmpty { // handwritten caption, shrinks to fit
        var size = s.height * 0.5
        var text = NSAttributedString()
        repeat {
            text = NSAttributedString(string: p.r.caption, attributes: [.font: handwriting(size), .foregroundColor: ink])
            size -= 0.5
        } while text.size().width > s.width * 0.94 && size > 7
        let sz = text.size()
        text.draw(at: CGPoint(x: s.midX - sz.width / 2, y: s.midY - sz.height / 2))
    }
    return c.makeImage()
}

// MARK: small drawings (y-down, origin at the anchor point)

@MainActor func drawClip(_ c: CGContext) {
    let (fill, edge) = clipColors[cfg.clip] ?? clipColors["wood"]!
    let body = CGPath(roundedRect: CGRect(x: -4.5, y: -9, width: 9, height: 25), cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)
    c.saveGState(); c.translateBy(x: 0.6, y: 1.6) // offset shadow, no blur
    c.setFillColor(rgb(0, 0, 0, 0.22)); c.addPath(body); c.fillPath()
    c.restoreGState()
    c.setFillColor(fill); c.addPath(body); c.fillPath()
    c.setStrokeColor(edge); c.setLineWidth(0.8); c.addPath(body); c.strokePath()
    c.setLineWidth(0.6); c.move(to: CGPoint(x: 0, y: -8)); c.addLine(to: CGPoint(x: 0, y: 15)); c.strokePath()
    c.setFillColor(rgb(0.74, 0.75, 0.77)); c.fill(CGRect(x: -5.5, y: 1, width: 11, height: 2.4)) // steel spring
    c.setFillColor(rgb(1, 1, 1, 0.25)); c.fill(CGRect(x: -3.5, y: -8, width: 1.4, height: 22)) // highlight
}

func drawNail(_ c: CGContext, _ p: CGPoint) {
    c.saveGState()
    c.setShadow(offset: CGSize(width: 1, height: -2), blur: 3, color: rgb(0, 0, 0, 0.45))
    c.setFillColor(rgb(0.45, 0.46, 0.48)); c.fillEllipse(in: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
    c.restoreGState()
    let g = CGGradient(colorsSpace: nil, colors: [rgb(0.93, 0.94, 0.95), rgb(0.50, 0.51, 0.54)] as CFArray, locations: [0, 1])!
    c.saveGState()
    c.addEllipse(in: CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9)); c.clip()
    c.drawRadialGradient(g, startCenter: CGPoint(x: p.x - 1.5, y: p.y - 1.8), startRadius: 0,
                         endCenter: p, endRadius: 5.5, options: [.drawsAfterEndLocation])
    c.restoreGState()
}

/// Space around a cached card for its baked-in shadow. Shadows are drawn once per card, not every frame.
let cardPad: CGFloat = 16

func withShadow(_ img: CGImage, scale: CGFloat = 2) -> CGImage? {
    let p = Int(cardPad * scale)
    guard let c = CGContext(data: nil, width: img.width + 2 * p, height: img.height + 2 * p, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    c.setShadow(offset: CGSize(width: 0, height: -5 * scale), blur: 11 * scale, color: rgb(0, 0, 0, 0.36))
    c.draw(img, in: CGRect(x: p, y: p, width: img.width, height: img.height))
    return c.makeImage()
}

/// Soft light, drawn from a cached sprite per colour (far cheaper than a gradient every frame).
@MainActor var glowSprites: [String: CGImage] = [:]

@MainActor func glow(_ c: CGContext, _ p: CGPoint, _ color: CGColor, _ radius: CGFloat, _ alpha: CGFloat) {
    guard alpha > 0.01 else { return }
    let key = "\(color.components ?? [])"
    if glowSprites[key] == nil, let s = CGContext(data: nil, width: 96, height: 96, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
        let g = CGGradient(colorsSpace: nil, colors: [color.copy(alpha: 1)!, color.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
        s.drawRadialGradient(g, startCenter: CGPoint(x: 48, y: 48), startRadius: 0, endCenter: CGPoint(x: 48, y: 48), endRadius: 48, options: [])
        glowSprites[key] = s.makeImage()
    }
    guard let sprite = glowSprites[key] else { return }
    c.saveGState(); c.setAlpha(min(1, alpha))
    c.draw(sprite, in: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
    c.restoreGState()
}

// Festival sprites (Resources/Deco), decoded once at the size they are drawn.
private var decoCache: [String: CGImage] = [:]
@MainActor func deco(_ name: String, px: Int) -> CGImage? {
    let key = "\(name)@\(px)"
    if let i = decoCache[key] { return i }
    var url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Deco")
    #if DEBUG
    if url == nil { url = URL(fileURLWithPath: "Deco/\(name).png") }
    #endif
    guard let u = url, let src = CGImageSourceCreateWithURL(u as CFURL, nil),
          let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                               kCGImageSourceThumbnailMaxPixelSize: px] as CFDictionary) else { return nil }
    decoCache[key] = img
    return img
}

/// A clay diya hung on three threads, with a flame that breathes.
@MainActor func drawDiya(_ c: CGContext, _ hang: CGPoint, time: Double, seed: Double) {
    guard let img = deco("diya", px: 120) else { return }
    let w: CGFloat = 50, h = w * CGFloat(img.height) / CGFloat(img.width), drop: CGFloat = 20
    let sway = CGFloat(sin(time * 0.9 + seed) * 0.06)
    let f = CGFloat(1 + 0.12 * sin(time * 11 + seed) + 0.07 * sin(time * 23 + seed * 3))
    c.saveGState(); c.translateBy(x: hang.x, y: hang.y); c.rotate(by: sway)
    c.setStrokeColor(rgb(0.94, 0.75, 0.35, 0.75)); c.setLineWidth(0.8)
    for fx: CGFloat in [-0.42, 0, 0.42] { c.move(to: .zero); c.addLine(to: CGPoint(x: fx * w, y: drop + h * 0.28)) }
    c.strokePath()
    let r = CGRect(x: -w / 2, y: drop, width: w, height: h)
    glow(c, CGPoint(x: r.minX + w * 0.78, y: r.minY + h * 0.18), rgb(1, 0.62, 0.15), w * 1.1 * f, 0.5)
    put(c, img, r)
    glow(c, CGPoint(x: r.minX + w * 0.8, y: r.minY + h * 0.14), rgb(1, 0.95, 0.75), w * 0.22 * f, 0.55)
    c.restoreGState()
}

/// A red bauble on its thread, or a candy cane hooked over the string.
@MainActor func drawOrnament(_ c: CGContext, _ hang: CGPoint, cane: Bool, time: Double, seed: Double) {
    guard let img = deco(cane ? "cane" : "bauble", px: 140) else { return }
    let h: CGFloat = cane ? 62 : 52, w = h * CGFloat(img.width) / CGFloat(img.height)
    let sway = CGFloat(sin(time * 0.9 + seed) * 0.1) + (cane ? 0.12 : 0)
    c.saveGState(); c.translateBy(x: hang.x, y: hang.y); c.rotate(by: sway)
    c.setShadow(offset: CGSize(width: 0, height: 2), blur: 3, color: rgb(0, 0, 0, 0.35))
    put(c, img, cane ? CGRect(x: -w * 0.53, y: -h * 0.07, width: w, height: h) : CGRect(x: -w / 2, y: -1, width: w, height: h))
    c.restoreGState()
}

func starPath(_ center: CGPoint, _ r: CGFloat, points: Int = 5, inner: CGFloat = 0.45, angle: CGFloat = 0) -> CGPath {
    let p = CGMutablePath()
    for k in 0..<points * 2 {
        let a = angle - .pi / 2 + CGFloat(k) * .pi / CGFloat(points), rr = k % 2 == 0 ? r : r * inner
        let q = CGPoint(x: center.x + cos(a) * rr, y: center.y + sin(a) * rr)
        k == 0 ? p.move(to: q) : p.addLine(to: q)
    }
    p.closeSubpath(); return p
}

@MainActor func drawStar(_ c: CGContext, _ hang: CGPoint, time: Double, seed: Double, night: CGFloat) {
    let sway = CGFloat(sin(time * 0.9 + seed) * 0.12)
    let center = CGPoint(x: hang.x + sin(sway) * 24, y: hang.y + cos(sway) * 24)
    c.setStrokeColor(rgb(0.85, 0.7, 0.3, 0.8)); c.setLineWidth(0.7)
    c.move(to: hang); c.addLine(to: center); c.strokePath()
    glow(c, center, rgb(1, 0.85, 0.4), 26, 0.12 + 0.3 * night)
    let star = starPath(center, 11, angle: sway)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 2.5, color: rgb(0, 0, 0, 0.35))
    c.setFillColor(rgb(0.95, 0.76, 0.25)); c.addPath(star); c.fillPath()
    c.restoreGState()
    c.saveGState(); c.addPath(star); c.clip()
    let g = CGGradient(colorsSpace: nil, colors: [rgb(1, 0.95, 0.7), rgb(0.85, 0.6, 0.15)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(g, start: CGPoint(x: center.x - 6, y: center.y - 8), end: CGPoint(x: center.x + 6, y: center.y + 8), options: [])
    c.restoreGState()
}

@MainActor func drawSparkle(_ c: CGContext, _ p: CGPoint, _ r: CGFloat, _ alpha: CGFloat) {
    glow(c, p, rgb(1, 0.9, 0.5), r * 2.6, alpha * 0.5)
    c.setFillColor(rgb(1, 0.97, 0.82, alpha)); c.addPath(starPath(p, r, points: 4, inner: 0.25)); c.fillPath()
}

func statusIcon() -> NSImage {
    let img = NSImage(size: NSSize(width: 20, height: 18), flipped: true) { _ in
        guard let c = NSGraphicsContext.current?.cgContext else { return false }
        c.setStrokeColor(.black); c.setFillColor(.black); c.setLineWidth(1.3); c.setLineCap(.round)
        c.move(to: CGPoint(x: 1.5, y: 3)); c.addQuadCurve(to: CGPoint(x: 18.5, y: 3), control: CGPoint(x: 10, y: 10)); c.strokePath()
        for (x, y, a) in [(5.5, 5.2, 0.12), (12.5, 6.2, -0.1)] as [(CGFloat, CGFloat, CGFloat)] {
            c.saveGState(); c.translateBy(x: x, y: y); c.rotate(by: a)
            c.stroke(CGRect(x: -2.6, y: 0.8, width: 5.2, height: 7.6)); c.fill(CGRect(x: -1.8, y: 1.6, width: 3.6, height: 4.4))
            c.restoreGState()
        }
        return true
    }
    img.isTemplate = true
    return img
}
