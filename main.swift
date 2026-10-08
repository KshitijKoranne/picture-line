// Picture-Line — entry point. Build: ./build.sh   Self-test: ./build.sh test
import AppKit
import SwiftUI

#if DEBUG
@MainActor func selfTest() {
    var ist = Calendar(identifier: .gregorian); ist.timeZone = TimeZone(identifier: "Asia/Kolkata")!
    func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        ist.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }
    // Vadodara, 8 Oct 2026: sunrise about 06:31, sunset about 18:16 IST
    let set = Sky.sun(at(2026, 10, 8), lat: 22.31, lon: 73.18, rising: false)!
    let rise = Sky.sun(at(2026, 10, 8), lat: 22.31, lon: 73.18, rising: true)!
    precondition(abs(set.timeIntervalSince(at(2026, 10, 8, 18, 16))) < 900, "sunset \(set)")
    precondition(abs(rise.timeIntervalSince(at(2026, 10, 8, 6, 31))) < 900, "sunrise \(rise)")
    precondition(Sky.sun(at(2026, 6, 21), lat: 78.2, lon: 15.6, rising: false) == nil, "midnight sun")

    precondition(currentFestival("auto", at(2026, 11, 8)) == .diwali)
    precondition(currentFestival("auto", at(2026, 11, 12)) == nil)
    precondition(currentFestival("auto", at(2026, 3, 3)) == .holi)
    precondition(currentFestival("auto", at(2026, 12, 24)) == .christmas)
    precondition(currentFestival("auto", at(2026, 10, 8)) == nil)
    precondition(currentFestival("winter", at(2026, 10, 8)) == .winter)

    let v = StringView(frame: NSRect(x: 0, y: 0, width: 1440, height: 620))
    v.layoutRope()
    for _ in 0..<600 { v.step() }
    precondition(v.pts.allSatisfy { $0.x.isFinite && $0.y.isFinite }, "rope blew up")
    precondition(v.pts[v.n / 2].y > v.pts[0].y + 20, "rope should sag")
    let length = zip(v.pts, v.pts.dropFirst()).reduce(CGFloat(0)) { $0 + ($1.1 - $1.0).len }
    precondition(abs(length - v.seg * CGFloat(v.n - 1)) / length < 0.03, "rope should keep its length")

    precondition(Sound.wav(Sound.snapSamples()).count > 1000)
    print("Self-test passed")
}

/// Dev tool: the real string with the sample photos over the dusk backdrop, for the website (2x).
@MainActor func promo(to dir: String, size: CGSize, name: String) {
    cfg.lights = "always"; cfg.lightColor = "warm"
    let v = StringView(frame: NSRect(origin: .zero, size: size))
    v.backdrop = true
    v.backdropImage = backdropImage?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    UserDefaults.standard.removeObject(forKey: "pins")
    v.layoutRope()
    v.photos = samplePhotos().enumerated().compactMap { k, s in
        var r = PhotoRecord(file: s.url.path, at: [9, 16, 23, 30, 37, 44, 51][k])
        r.caption = s.caption; r.scale = Double(size.height / 560); r.added = .distantPast
        let p = Photo(r); p?.angle = [0.08, -0.06, 0.1, -0.04, 0.07, -0.09, 0.05][k]; return p
    }
    v.refreshClock(force: true); v.lightLevel = 1
    for _ in 0..<1200 { v.step() }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    v.cacheDisplay(in: v.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    cfg = Config.load()
}

/// Dev tool: renders the string offscreen in a few scenes, for checking the look without touching the desktop.
@MainActor func snapshots(to dir: String) {
    let recs = Library.load()
    let scenes: [(String, (StringView) -> Void)] = [
        ("day", { _ in }),
        ("night-diwali", { _ in cfg.lights = "always"; cfg.festival = "diwali" }),
        ("christmas", { v in cfg.lights = "always"; cfg.lightColor = "multi"; cfg.festival = "christmas"; v.pins[25] = CGPoint(x: 600, y: 60) }),
        ("holi-birthday-back", { v in cfg.lights = "off"; cfg.festival = "holi"; cfg.frame = "classic"
            v.photos[0].r.birthday = dayKey(Date(), "MM-dd"); v.photos[1].flip = 1; v.photos[1].flipTarget = 1 }),
    ]
    for (name, setup) in scenes {
        let v = StringView(frame: NSRect(x: 0, y: 0, width: 1440, height: 620))
        v.layoutRope(); v.backdrop = true
        v.photos = (0..<4).compactMap { k in
            guard var r = recs.isEmpty ? nil : recs[k % recs.count] else { return nil }
            r.at = [14, 24, 36, 46][k]; r.caption = ["Goa, 2019", "Aai & Baba", "First day", ""][k]
            r.note = "The day it rained all afternoon and we stayed in."; r.date = Date(); r.added = .distantPast
            return Photo(r)
        }
        setup(v); v.refreshClock()
        for _ in 0..<900 { v.step() }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1440, pixelsHigh: 620, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        v.cacheDisplay(in: v.bounds, to: rep)
        let img = NSImage(size: v.bounds.size, flipped: false) { r in
            NSGradient(colors: [NSColor(srgbRed: 0.20, green: 0.32, blue: 0.48, alpha: 1), NSColor(srgbRed: 0.55, green: 0.45, blue: 0.50, alpha: 1)])!
                .draw(in: r, angle: -90)
            rep.draw(in: r); return true
        }
        let out = NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        try? out.write(to: URL(fileURLWithPath: dir).appendingPathComponent("snap-\(name).png"))
        cfg = Config.load()
    }
    for k in 0..<6 { // the five Settings sections, then the welcome window
        if k < 5 { UserDefaults.standard.set(k, forKey: "settingsTab") }
        let v = NSHostingView(rootView: k < 5 ? AnyView(SettingsRoot()) : AnyView(WelcomeView { _, _, _, _ in }))
        v.frame = NSRect(origin: .zero, size: v.fittingSize)
        let w = NSWindow(contentRect: v.frame, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.contentView = v; w.orderFrontRegardless()
        RunLoop.main.run(until: Date() + 0.6)
        let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent("settings-\(k).png"))
        w.orderOut(nil)
    }
    // the Share picture, from a real desktop-level window
    let sv = StringView(frame: NSRect(x: 0, y: 0, width: 1440, height: 620))
    let sw = NSWindow(contentRect: sv.frame, styleMask: .borderless, backing: .buffered, defer: false)
    sw.isOpaque = false; sw.backgroundColor = .clear; sw.level = desktopLevel; sw.contentView = sv
    sv.layoutRope(); sv.photos = recs.prefix(1).compactMap { Photo($0) }
    sw.orderFrontRegardless(); for _ in 0..<600 { sv.step() }
    try? sv.snapshotPNG()?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("share.png"))
    sw.orderOut(nil)
}

#endif

MainActor.assumeIsolated {
    registerFonts()
    #if DEBUG // dev-only tools, left out of release builds
    if CommandLine.arguments.contains("--selftest") { selfTest(); exit(0) }
    if let i = CommandLine.arguments.firstIndex(of: "--snapshot") { snapshots(to: CommandLine.arguments[i + 1]); exit(0) }
    if let i = CommandLine.arguments.firstIndex(of: "--promo") {
        promo(to: CommandLine.arguments[i + 1], size: CGSize(width: 1200, height: 500), name: "app-shot")
        promo(to: CommandLine.arguments[i + 1], size: CGSize(width: 1200, height: 630), name: "og")
        exit(0)
    }
    #endif
    let delegate = App()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.setActivationPolicy(.accessory) // menu bar only, no Dock icon
    withExtendedLifetime(delegate) { NSApplication.shared.run() }
}
