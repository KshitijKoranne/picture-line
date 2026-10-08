// Picture-Line — the string: physics, drawing, mouse, drag and drop.
import AppKit
import UniformTypeIdentifiers

extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: CGPoint, k: CGFloat) -> CGPoint { CGPoint(x: a.x * k, y: a.y * k) }
    var len: CGFloat { hypot(x, y) }
}

extension Notification.Name {
    static let removeNails = Notification.Name("PL.removeNails")
    static let resetString = Notification.Name("PL.resetString")
}

struct Particle {
    enum Kind { case confetti, snow, puff }
    var p: CGPoint, v: CGPoint, rot: CGFloat = 0, vr: CGFloat = 0, age: CGFloat = 0
    var life: CGFloat, kind: Kind, color: CGColor, size: CGFloat, seed = CGFloat.random(in: 0...100)
}

@MainActor final class StringView: NSView {
    let n = 60
    var pts: [CGPoint] = [], old: [CGPoint] = [], seg: CGFloat = 10
    var pins: [Int: CGPoint] = [:]
    var photos: [Photo] = []
    var particles: [Particle] = []
    lazy var snow = [CGFloat](repeating: 0, count: n)
    var grabbed: Int?, grabOffset = CGPoint.zero, dragged: Photo?, pressed: Photo?
    var pressTime = 0.0, downAt = CGPoint.zero, moved: CGFloat = 0
    var mouse = CGPoint(x: -999, y: -999), lastMouse = CGPoint(x: -999, y: -999)
    var time = 0.0, lastClock = 0.0, lastDevStep = -1
    var lightLevel: CGFloat = 0, breeze: CGFloat = 0, night = false, idle = false
    var festival: Festival?, todayMD = ""
    var toast: (text: String, until: Double)?
    var lastDirty = CGRect.zero, burst: [UUID: Double] = [:], nextPuff = 0.0
    let lift = LiftController()
    var pendingSave = false
    var backdrop = false // snapshots only: paint a wallpaper behind the string

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }

    func setup() {
        photos = Library.load().compactMap { Photo($0) }
        registerForDraggedTypes(NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
                                + [.fileURL, .tiff, .png])
        layoutRope()
        refreshClock()
        for name in [Notification.Name.removeNails, .resetString] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pins = self.pins.filter { $0.key == 0 || $0.key == self.n - 1 }
                    if note.name == .resetString { self.pins = [:] }
                    self.savePins(); self.layoutRope()
                }
            }
        }
    }

    func save() { if !demo { Library.save(photos.map(\.r)) } }

    // MARK: demo (the live string in the welcome window)

    var demo = false
    var ownTimer: Timer?

    static func demo(size: CGSize) -> StringView {
        let v = StringView(frame: NSRect(origin: .zero, size: size))
        v.demo = true
        v.layoutRope()
        v.photos = samplePhotos().prefix(5).enumerated().compactMap { k, s in
            var r = PhotoRecord(file: s.url.path, at: [11, 21, 30, 39, 49][k])
            r.caption = s.caption; r.scale = 0.52
            let p = Photo(r); p?.angle = .random(in: -0.25...0.25); return p
        }
        return v
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard demo else { return }
        ownTimer?.invalidate(); ownTimer = nil
        if window != nil {
            let t = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { _ = self?.tick(hz: 60) } }
            RunLoop.main.add(t, forMode: .common); ownTimer = t
        }
    }

    // MARK: rope and nails

    func loadPins() {
        if demo { pins = [0: CGPoint(x: 14, y: 22), n - 1: CGPoint(x: bounds.width - 14, y: 22)]; return }
        let saved = UserDefaults.standard.dictionary(forKey: "pins") as? [String: [Double]] ?? [:]
        pins = [:]
        for (k, v) in saved where v.count == 2 {
            if let i = Int(k) { pins[i] = CGPoint(x: v[0] * bounds.width, y: v[1] * bounds.height) }
        }
        if pins[0] == nil { pins[0] = CGPoint(x: bounds.width * 0.04, y: 46) }
        if pins[n - 1] == nil { pins[n - 1] = CGPoint(x: bounds.width * 0.96, y: 46) }
    }

    func savePins() {
        if demo { return }
        let d = Dictionary(uniqueKeysWithValues: pins.map {
            (String($0.key), [Double($0.value.x / bounds.width), Double($0.value.y / bounds.height)])
        })
        UserDefaults.standard.set(d, forKey: "pins")
    }

    func layoutRope() {
        loadPins()
        let keys = pins.keys.sorted()
        pts = (0..<n).map { i in
            let a = keys.last { $0 <= i }!, b = keys.first { $0 >= i }!
            return a == b ? pins[a]! : pins[a]! + (pins[b]! - pins[a]!) * (CGFloat(i - a) / CGFloat(b - a))
        }
        old = pts
        for p in photos where pins[p.r.at] != nil { p.r.at = freeIndex(near: pts[p.r.at]) }
        updateLength()
        needsDisplay = true
    }

    /// The string keeps one length; nails only decide where it hangs.
    func updateLength() { seg = (pins[n - 1]! - pins[0]!).len * (1 + CGFloat(demo ? 0.025 : cfg.sag)) / CGFloat(n - 1) }

    func clampPin(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(bounds.width - 8, max(8, p.x)), y: min(bounds.height * 0.55, max(8, p.y)))
    }

    func nearestPoint(_ m: CGPoint, within d: CGFloat) -> Int? {
        let i = (0..<n).min { (pts[$0] - m).len < (pts[$1] - m).len }!
        return (pts[i] - m).len <= d ? i : nil
    }

    func pinNear(_ m: CGPoint, _ d: CGFloat) -> Int? { pins.filter { ($0.value - m).len <= d }.min { $0.key < $1.key }?.key }

    func toggleNail() {
        guard dragged == nil, pressed == nil, let i = grabbed ?? nearestPoint(mouse, within: 30) else { return }
        if pins[i] != nil { removeNail(i) } else { addNail(i) }
    }

    func addNail(_ i: Int) {
        guard i > 0, i < n - 1 else { return }
        guard !pins.keys.contains(where: { abs($0 - i) < 3 }) else { showToast("Too close to another nail"); return }
        pins[i] = clampPin(pts[i])
        for p in photos where abs(p.r.at - i) < 1 { p.r.at = freeIndex(near: pts[i]) }
        savePins(); save(); Sound.snap(0.5)
    }

    func removeNail(_ i: Int) {
        guard i > 0, i < n - 1, pins[i] != nil else { return }
        pins[i] = nil; if grabbed == i { grabbed = nil }
        savePins(); Sound.rustle(0.4)
    }

    /// Nearest free spot for a new photo, kept apart from nails and other photos when there is room.
    func freeIndex(near q: CGPoint) -> Int {
        let free = (2..<n - 2).filter { i in pins.keys.allSatisfy { abs($0 - i) > 1 } }
        let spaced = free.filter { i in photos.allSatisfy { abs($0.r.at - i) >= 4 } }
        return (spaced.isEmpty ? free : spaced).min { (pts[$0] - q).len < (pts[$1] - q).len } ?? n / 2
    }

    func index(near q: CGPoint) -> Int {
        (1..<n - 1).filter { pins[$0] == nil }.min { (pts[$0] - q).len < (pts[$1] - q).len } ?? n / 2
    }

    // MARK: photo geometry (photo space: origin at the clip, y down, rotated by -angle)

    func cardRect(_ p: Photo) -> CGRect {
        let s = p.layout.size
        return CGRect(x: -s.width / 2, y: 6, width: s.width, height: s.height)
    }

    func cardCenter(_ p: Photo) -> CGPoint {
        let d = 6 + p.layout.size.height / 2
        return pts[p.r.at] + CGPoint(x: sin(p.angle) * d, y: cos(p.angle) * d)
    }

    func hits(_ p: Photo, _ m: CGPoint) -> Bool {
        let d = m - pts[p.r.at], c = cos(p.angle), s = sin(p.angle)
        return cardRect(p).insetBy(dx: -2, dy: -4).contains(CGPoint(x: d.x * c - d.y * s, y: d.x * s + d.y * c))
    }

    func photo(at m: CGPoint) -> Photo? { photos.last { !$0.lifted && hits($0, m) } }

    // MARK: clock (once a second)

    func refreshClock() {
        if pendingSave { pendingSave = false; save() }
        night = Sky.isNight()
        festival = currentFestival(cfg.festival)
        todayMD = dayKey(Date(), "MM-dd")
        idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!) > 40
        for p in photos where isBirthday(p) && time - (burst[p.r.id] ?? -9999) > 1800 {
            burst[p.r.id] = time; confetti(at: cardCenter(p) - CGPoint(x: 0, y: p.layout.size.height / 2))
        }
    }

    func isBirthday(_ p: Photo) -> Bool { cfg.birthdays && p.r.birthday == todayMD }

    // MARK: frame

    /// One timer tick at `hz` frames a second: runs the physics at a steady 60 steps a second, redraws only what changed,
    /// and returns the rate it wants next. 60 while anything moves or the pointer is close, 30 for snow, flames and breeze,
    /// 15 for twinkling lights, 15 with no drawing at all when the string is still. Keeps a resting Mac cool.
    func tick(hz: Double) -> Double {
        if let w = window { mouse = convert(w.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil) }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastClock > 1 { lastClock = now; refreshClock() }
        for _ in 0..<max(1, Int((60 / hz).rounded())) { step() }
        lift.tick()

        let box = contentBox()
        let motion = zip(pts, old).reduce(CGFloat(0)) { max($0, ($1.0 - $1.1).len) }
        let busy = grabbed != nil || pressed != nil || dragged != nil || lift.active || motion > 0.03
            || box.insetBy(dx: -30, dy: -30).contains(mouse)
            || photos.contains { abs($0.spin) > 0.01 || abs($0.flip - $0.flipTarget) > 0.001 }
        let lightsTarget: CGFloat = (cfg.lights == "always" || (cfg.lights == "sunset" && night)) ? 1 : 0
        let lively = !particles.isEmpty || breeze > 0.01 || toast != nil || abs(lightLevel - lightsTarget) > 0.001
            || festival == .diwali || festival == .christmas || festival == .holi || photos.contains { isBirthday($0) }
        let devStep = photos.reduce(0) { $0 + Int($1.developed * 40) }
        let twinkle = lightLevel > 0.01 && cfg.lights != "off"

        if busy || lively || twinkle || devStep != lastDevStep {
            setNeedsDisplay(box.union(lastDirty))
            lastDirty = box; lastDevStep = devStep
        }
        return busy ? 60 : lively ? 30 : 15
    }

    /// Hidden or fully covered: keep the clock going, skip physics and drawing.
    func idleTick() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastClock > 1 { time += now - lastClock; lastClock = now; refreshClock() }
    }

    func contentBox() -> CGRect {
        var r = CGRect(origin: pts[0], size: .zero)
        for p in pts { r = r.union(CGRect(origin: p, size: .zero)) }
        let card = (photos.map(\.width).max() ?? cfg.cardWidth) * 1.45
        r = CGRect(x: r.minX - card - 40, y: r.minY - 50, width: r.width + 2 * card + 80, height: r.height + card * 1.7 + 90)
        for p in particles { r = r.union(CGRect(x: p.p.x - 90, y: p.p.y - 90, width: 180, height: 180)) }
        if toast != nil || photos.isEmpty { r = r.union(CGRect(x: pts[n / 2].x - 260, y: pts[n / 2].y, width: 520, height: 140)) }
        return r.intersection(bounds)
    }

    func step() {
        let dt: CGFloat = 1 / 60, g: CGFloat = 1400
        time += 1 / 60
        let mv = mouse - lastMouse; lastMouse = mouse
        let hover = mv.len < 250
        let target = (cfg.lights == "always" || (cfg.lights == "sunset" && night)) ? CGFloat(1) : 0
        lightLevel += max(-0.006, min(0.006, target - lightLevel))
        breeze += max(-0.004, min(0.004, (cfg.breeze && idle ? 1 : 0) - breeze))
        let wind = breeze * CGFloat(cfg.breezeStrength) * 260
            * CGFloat(sin(time * 0.55) * 0.55 + sin(time * 1.33 + 1.2) * 0.3 + sin(time * 0.21 + 2) * 0.35)

        if let p = pressed, !p.lifted, moved <= 5, time - pressTime > 0.32 { startLift(p) }
        if let p = dragged { p.r.at = index(near: mouse + grabOffset); grabbed = p.r.at }

        var weight = [Int: CGFloat]()
        for p in photos where !p.lifted { let s = p.layout.size; weight[p.r.at, default: 0] += s.width * s.height / (140 * 175) }

        for i in 0..<n where pins[i] == nil && i != grabbed {
            let v = (pts[i] - old[i]) * 0.985
            old[i] = pts[i]
            pts[i] = pts[i] + v
            pts[i].y += (g + (weight[i] ?? 0) * 900 + snow[i] * 30) * dt * dt
            pts[i].x += wind * CGFloat(0.75 + 0.25 * sin(time * 1.1 + Double(i) * 0.25)) * dt * dt
            if grabbed == nil, hover, (pts[i] - mouse).len < 36 { pts[i] = pts[i] + mv * 0.22 } // the pointer brushes it
        }
        if let k = grabbed {
            let t = mouse + grabOffset
            if pins[k] != nil { pins[k] = clampPin(t); if k == 0 || k == n - 1 { updateLength() } }
            else { old[k] = pts[k]; pts[k] = t } // old keeps the hand's speed, so a flick carries on after release
        }
        for (i, p) in pins { pts[i] = p; old[i] = p }

        let fixed = (0..<n).map { pins[$0] != nil || $0 == grabbed }
        for _ in 0..<30 {
            for i in 0..<n - 1 where !(fixed[i] && fixed[i + 1]) {
                let d = pts[i + 1] - pts[i], l = max(d.len, 0.001)
                let c = d * ((l - seg) / l * (fixed[i] || fixed[i + 1] ? 1 : 0.5))
                if !fixed[i] { pts[i] = pts[i] + c }
                if !fixed[i + 1] { pts[i + 1] = pts[i + 1] - c }
            }
        }

        for p in photos where !p.lifted { // each photo is a pendulum driven by its clip
            let v = (pts[p.r.at] - old[p.r.at]) * 60
            var a = (v - p.lastV) * 60; p.lastV = v
            a.x = max(-5000, min(5000, a.x)); a.y = max(-5000, min(5000, a.y))
            let l = 6 + p.layout.size.height / 2
            p.spin += -((g - a.y) * sin(p.angle) + (a.x - wind * 0.7) * cos(p.angle)) / l * dt
            if dragged == nil, hover, hits(p, mouse) { p.spin += mv.x * 0.012 }
            p.spin *= 0.986
            p.angle = max(-1.4, min(1.4, p.angle + p.spin * dt))
            if abs(p.spin) > 2.4, time - p.lastRustle > 1.2 { p.lastRustle = time; Sound.rustle(min(1, Double(abs(p.spin)) / 6)) }
            p.flip += max(-1 / 27, min(1 / 27, p.flipTarget - p.flip))
        }
        updateParticles(dt)
        if let t = toast, time > t.until { toast = nil }
    }

    // MARK: particles

    func updateParticles(_ dt: CGFloat) {
        let snowing = festival == .christmas || festival == .winter
        if snowing, particles.count < 170, Double.random(in: 0...1) < 0.5 {
            particles.append(Particle(p: CGPoint(x: .random(in: 0...bounds.width), y: -6),
                                      v: CGPoint(x: .random(in: -8...8), y: .random(in: 22...40)),
                                      life: 40, kind: .snow, color: .white, size: .random(in: 1.3...3.2)))
        }
        if festival == .holi, time > nextPuff, let i = (2..<n - 2).randomElement() {
            nextPuff = time + .random(in: 0.8...1.8); puff(at: pts[i])
        }
        for i in 0..<n { // snow settles on the string, melts slowly, falls off when shaken
            if snow[i] > 0.4, (pts[i] - old[i]).len > 1.4 {
                snow[i] *= 0.65
                particles.append(Particle(p: pts[i], v: CGPoint(x: .random(in: -10...10), y: .random(in: 30...60)),
                                          life: 30, kind: .snow, color: .white, size: .random(in: 1.5...2.8)))
            }
            snow[i] = max(0, snow[i] - (snowing ? 0.0005 : 0.01))
        }
        particles = particles.compactMap { q in
            var q = q
            q.age += dt
            switch q.kind {
            case .confetti:
                q.v.y += 260 * dt; q.v = q.v * 0.985
                q.p = q.p + q.v * dt; q.p.x += CGFloat(sin(time * 7 + Double(q.seed))) * 25 * dt; q.rot += q.vr * dt
            case .puff:
                q.p = q.p + q.v * dt; q.size += 14 * dt
            case .snow:
                q.p.x += (q.v.x + CGFloat(sin(time * 1.3 + Double(q.seed))) * 10) * dt; q.p.y += q.v.y * dt
                for i in 0..<n - 1 {
                    let a = pts[i], b = pts[i + 1]
                    guard q.p.x >= min(a.x, b.x), q.p.x <= max(a.x, b.x), abs(b.x - a.x) > 0.1 else { continue }
                    let y = a.y + (b.y - a.y) * (q.p.x - a.x) / (b.x - a.x)
                    if abs(q.p.y - y) < 2, Bool.random() { snow[i] = min(6, snow[i] + 0.35); return nil }
                }
            }
            return q.age > q.life || q.p.y > bounds.height + 10 ? nil : q
        }
    }

    func confetti(at c: CGPoint) {
        for _ in 0..<70 {
            let a = CGFloat.random(in: -CGFloat.pi * 0.95 ... -CGFloat.pi * 0.05), s = CGFloat.random(in: 120...330)
            particles.append(Particle(p: c, v: CGPoint(x: cos(a) * s, y: sin(a) * s), rot: .random(in: 0...6), vr: .random(in: -9...9),
                                      life: 4.5, kind: .confetti, color: (lightColors + [rgb(0.95, 0.78, 0.3)]).randomElement()!,
                                      size: .random(in: 0.8...1.3)))
        }
    }

    func puff(at c: CGPoint) {
        particles.append(Particle(p: c, v: CGPoint(x: .random(in: -14...14), y: .random(in: -22 ... -6)),
                                  life: 5, kind: .puff, color: holiColors.randomElement()!, size: 10))
    }

    func showToast(_ s: String) { toast = (s, time + 2.8) }

    // MARK: drawing

    func ropePath() -> CGPath {
        let path = CGMutablePath(); path.move(to: pts[0])
        for i in 1..<n - 1 {
            if pins[i] != nil { path.addLine(to: pts[i]) } // sharp turn at a nail
            path.addQuadCurve(to: (pts[i] + pts[i + 1]) * 0.5, control: pts[i])
        }
        path.addLine(to: pts[n - 1])
        return path
    }

    func lightPoints() -> [CGPoint] {
        var out: [CGPoint] = [], carry: CGFloat = 20
        for i in 0..<n - 1 {
            let d = pts[i + 1] - pts[i], l = d.len
            var s = carry
            while s < l { out.append(pts[i] + d * (s / l)); s += 42 }
            carry = s - l
        }
        return out
    }

    func decorationSpots(from: Int, every: Int) -> [Int] {
        stride(from: from, to: n - 3, by: every).filter { i in
            pins[i] == nil && photos.allSatisfy { $0.lifted || abs($0.r.at - i) > 3 }
        }
    }

    override func draw(_ dirty: NSRect) {
        guard let c = NSGraphicsContext.current?.cgContext, !pts.isEmpty else { return }
        if backdrop {
            let g = CGGradient(colorsSpace: nil, colors: [rgb(0.18, 0.28, 0.44), rgb(0.52, 0.42, 0.48)] as CFArray, locations: [0, 1])!
            c.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: bounds.height), options: [])
        }
        let rope = ropePath(), th = CGFloat(cfg.thickness)
        c.setLineCap(.round); c.setLineJoin(.round)

        // ponytail: near-invisible wide band so clicks and drops land on the string; the rest of the window clicks through
        c.addPath(rope); c.setLineWidth(40); c.setStrokeColor(rgb(1, 1, 1, 0.005)); c.strokePath()

        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: -3), blur: 4, color: rgb(0, 0, 0, 0.35))
        if festival == .holi {
            for i in 0..<n - 1 {
                c.move(to: pts[i]); c.addLine(to: pts[i + 1]); c.setLineWidth(th)
                c.setStrokeColor(holiColors[(i / 4) % holiColors.count]); c.strokePath()
            }
        } else {
            c.addPath(rope); c.setLineWidth(th); c.setStrokeColor(stringColors[cfg.stringColor] ?? stringColors["twine"]!); c.strokePath()
        }
        c.restoreGState()
        c.saveGState(); c.translateBy(x: 0, y: -th * 0.22) // soft highlight gives the cord some roundness
        c.addPath(rope); c.setLineWidth(th * 0.3); c.setStrokeColor(rgb(1, 1, 1, 0.2)); c.strokePath()
        c.restoreGState()

        for i in 0..<n - 1 where snow[i] + snow[i + 1] > 0.5 {
            let d = max(snow[i], snow[i + 1])
            c.move(to: pts[i] - CGPoint(x: 0, y: snow[i] / 2 + th / 2)); c.addLine(to: pts[i + 1] - CGPoint(x: 0, y: snow[i + 1] / 2 + th / 2))
            c.setLineWidth(d); c.setStrokeColor(rgb(0.97, 0.98, 1, 0.95)); c.strokePath()
        }
        for (_, p) in pins { drawNail(c, p) }

        if cfg.lights != "off" { // fairy lights
            for (k, p) in lightPoints().enumerated() {
                let col = cfg.lightColor == "multi" ? lightColors[k % lightColors.count] : warmLight
                let lit = lightLevel * CGFloat(0.78 + 0.22 * sin(time * 1.7 + Double(k) * 2.3))
                let b = p + CGPoint(x: 0, y: 5)
                glow(c, b, col, 20, 0.55 * lit)
                c.setFillColor(rgb(0.12, 0.25, 0.14)); c.fill(CGRect(x: p.x - 1.6, y: p.y, width: 3.2, height: 2.6))
                let bulb = CGRect(x: b.x - 2.4, y: b.y - 2, width: 4.8, height: 6.4)
                c.setFillColor(rgb(0.93, 0.93, 0.88, 0.75)); c.fillEllipse(in: bulb)
                c.setFillColor(col.copy(alpha: lit)!); c.fillEllipse(in: bulb)
                c.setFillColor(rgb(1, 1, 0.95, 0.85 * lit)); c.fillEllipse(in: bulb.insetBy(dx: 1.2, dy: 1.6))
            }
        }

        switch festival {
        case .diwali:
            for i in decorationSpots(from: 6, every: 9) {
                c.saveGState(); c.translateBy(x: pts[i].x, y: pts[i].y); c.scaleBy(x: 1.3, y: 1.3)
                drawDiya(c, .zero, time: time, seed: Double(i)); c.restoreGState()
            }
        case .christmas: for i in decorationSpots(from: 4, every: 8) { drawStar(c, pts[i], time: time, seed: Double(i), night: lightLevel) }
        default: break
        }

        let holi = festival == .holi
        for p in photos where !p.lifted {
            let bday = isBirthday(p)
            if bday {
                let s = p.layout.size
                glow(c, cardCenter(p), rgb(1, 0.82, 0.35), hypot(s.width, s.height) * 0.8, 0.38 + 0.14 * CGFloat(sin(time * 2)))
            }
            let L = p.layout, rect = cardRect(p)
            c.saveGState()
            c.translateBy(x: pts[p.r.at].x, y: pts[p.r.at].y); c.rotate(by: -p.angle)
            if let img = p.card(back: p.showsBack, holi: holi) {
                c.saveGState()
                c.translateBy(x: 0, y: rect.midY); c.scaleBy(x: max(0.02, abs(cos(p.flip * .pi))), y: 1); c.translateBy(x: 0, y: -rect.midY)
                put(c, img, CGRect(origin: rect.origin, size: L.size).insetBy(dx: -cardPad, dy: -cardPad))
                c.restoreGState()
            }
            drawClip(c)
            c.restoreGState()
            if bday {
                let ctr = cardCenter(p), s = L.size
                for k in 0..<6 {
                    let a = time * 0.5 + Double(k) * 1.047
                    let q = ctr + CGPoint(x: CGFloat(cos(a)) * s.width * 0.62, y: CGFloat(sin(a)) * s.height * 0.6)
                    drawSparkle(c, q, 3.5 + 2 * CGFloat(sin(time * 3 + Double(k))), 0.9)
                }
            }
        }

        for q in particles {
            let fade = min(1, max(0, (bounds.height - q.p.y) / 140)) * min(1, (q.life - q.age) / 1.2)
            switch q.kind {
            case .snow:
                c.setFillColor(rgb(1, 1, 1, 0.9 * fade))
                c.fillEllipse(in: CGRect(x: q.p.x - q.size, y: q.p.y - q.size, width: q.size * 2, height: q.size * 2))
            case .confetti:
                c.saveGState(); c.translateBy(x: q.p.x, y: q.p.y); c.rotate(by: q.rot)
                c.setFillColor(q.color.copy(alpha: fade)!)
                let w = 3.5 * q.size * max(0.15, abs(cos(q.rot * 1.7)))
                c.fill(CGRect(x: -w / 2, y: -4 * q.size, width: w, height: 8 * q.size)); c.restoreGState()
            case .puff:
                glow(c, q.p, q.color, q.size * 2.6, 0.34 * fade * min(1, q.age * 2))
            }
        }

        if photos.isEmpty || toast != nil { // hint and toast text sit under the middle of the string
            let mid = pts[n / 2]
            let shadow = NSShadow(); shadow.shadowBlurRadius = 4; shadow.shadowColor = NSColor(white: 0, alpha: 0.6)
            let lines: [(String, NSFont)] = toast.map { [($0.text, NSFont.systemFont(ofSize: 15, weight: .medium))] }
                ?? [("Drag a photo here", wordmark(26)),
                    ("Someone you'd like to see every day.", NSFont.systemFont(ofSize: 13, weight: .medium))]
            var y = mid.y + 26
            for (text, font) in lines {
                let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(white: 1, alpha: 0.92), .shadow: shadow])
                s.draw(at: CGPoint(x: mid.x - s.size().width / 2, y: y)); y += s.size().height + 4
            }
        }
    }

    // MARK: share (a picture of the string over the wallpaper)

    func snapshotPNG() -> Data? {
        let box = contentBox().integral
        guard box.width > 10, let w = window, let screen = w.screen else { return nil }
        let onScreen = w.convertToScreen(convert(box, to: nil))
        let wall = NSWorkspace.shared.desktopImageURL(for: screen).flatMap { NSImage(contentsOf: $0) }
        let out = NSImage(size: box.size, flipped: true) { r in
            if let wall, wall.size.width > 0 { // the slice of wallpaper behind this part of the screen
                let f = screen.frame, s = max(f.width / wall.size.width, f.height / wall.size.height)
                let drawn = NSRect(x: f.midX - wall.size.width * s / 2, y: f.midY - wall.size.height * s / 2,
                                   width: wall.size.width * s, height: wall.size.height * s)
                let local = NSRect(x: drawn.minX - onScreen.minX, y: onScreen.maxY - drawn.maxY, width: drawn.width, height: drawn.height)
                wall.draw(in: local, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            } else {
                NSGradient(colors: [NSColor(srgbRed: 0.2, green: 0.3, blue: 0.46, alpha: 1), NSColor(srgbRed: 0.5, green: 0.42, blue: 0.5, alpha: 1)])!
                    .draw(in: r, angle: 90)
            }
            NSGraphicsContext.current?.cgContext.translateBy(x: -box.minX, y: -box.minY)
            self.draw(box)
            return true
        }
        guard let cg = out.cgImage(forProposedRect: nil, context: nil, hints: [.ctm: AffineTransform(scale: screen.backingScaleFactor)]) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    // MARK: lift (hold a photo to see it large)

    func screenPoint(_ p: CGPoint) -> CGPoint { window?.convertPoint(toScreen: convert(p, to: nil)) ?? p }

    func startLift(_ p: Photo) {
        guard let screen = window?.screen else { return }
        let image = loadImage(photoURL(p.r.file), max: 2400) ?? p.thumb
        p.lifted = true; p.spin = 0
        Sound.rustle(0.5)
        lift.show(p, image: image, back: p.flipTarget > 0.5, holi: festival == .holi, screen: screen,
                  from: screenPoint(cardCenter(p)), size: p.layout.size, angle: p.angle) { [weak self] in
            p.lifted = false; p.lastV = .zero; p.spin = .random(in: -2...2)
            Sound.snap(); self?.needsDisplay = true
        }
    }

    // MARK: mouse

    override func mouseDown(with e: NSEvent) {
        let m = convert(e.locationInWindow, from: nil)
        downAt = m; moved = 0
        if let k = pinNear(m, 12) { grabbed = k; grabOffset = pins[k]! - m; return }
        if let p = photo(at: m) {
            if e.clickCount == 2 { p.flipTarget = p.flipTarget > 0.5 ? 0 : 1; Sound.rustle(0.6); return }
            pressed = p; pressTime = time; grabOffset = pts[p.r.at] - m
            return
        }
        if let i = nearestPoint(m, within: 25) { grabbed = i; grabOffset = .zero }
    }

    override func mouseDragged(with e: NSEvent) {
        moved = max(moved, (convert(e.locationInWindow, from: nil) - downAt).len)
        if let p = pressed, !p.lifted, moved > 5 { dragged = p; pressed = nil }
    }

    override func mouseUp(with e: NSEvent) {
        if let p = pressed {
            if p.lifted {
                lift.release(to: screenPoint(cardCenter(p)), angle: p.angle)
            } else { // a click: give it a swing, and a little celebration on special days
                p.spin += downAt.x < pts[p.r.at].x ? 3.5 : -3.5
                if isBirthday(p) { confetti(at: cardCenter(p)) }
                if festival == .holi { puff(at: cardCenter(p)) }
            }
        }
        if dragged != nil { Sound.snap(0.8); save() }
        if let k = grabbed, pins[k] != nil { savePins() }
        pressed = nil; dragged = nil; grabbed = nil
    }

    // MARK: size (scroll or pinch over a photo, or right-click → Size)

    override func scrollWheel(with e: NSEvent) {
        guard let p = photo(at: convert(e.locationInWindow, from: nil)) else { return super.scrollWheel(with: e) }
        let dy = e.isDirectionInvertedFromDevice ? -e.scrollingDeltaY : e.scrollingDeltaY
        resize(p, to: CGFloat(p.r.scale ?? 1) * (1 + dy * (e.hasPreciseScrollingDeltas ? 0.004 : 0.06)))
    }

    override func magnify(with e: NSEvent) {
        guard let p = photo(at: convert(e.locationInWindow, from: nil)) else { return super.magnify(with: e) }
        resize(p, to: CGFloat(p.r.scale ?? 1) * (1 + e.magnification))
    }

    static let sizes: [(String, Double)] = [("Small", 0.75), ("Medium", 1), ("Large", 1.3), ("Extra Large", 1.6)]

    func resize(_ p: Photo, to s: CGFloat) {
        let s = min(1.7, max(0.6, s))
        guard abs(s - CGFloat(p.r.scale ?? 1)) > 0.001 else { return }
        p.r.scale = Double(s); pendingSave = true
    }

    @objc func sizePhoto(_ s: NSMenuItem) {
        guard let v = s.representedObject as? (Photo, Double) else { return }
        let (p, k) = v
        resize(p, to: CGFloat(k)); p.spin += 1.2; save()
    }

    override func rightMouseDown(with e: NSEvent) {
        if demo { return }
        let m = convert(e.locationInWindow, from: nil)
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector, _ obj: Any? = nil, target: AnyObject? = nil) {
            let i = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            i.target = target ?? self; i.representedObject = obj
        }
        if let p = photo(at: m) {
            item("Edit Caption & Note…", #selector(editPhoto(_:)), p)
            item(p.flipTarget > 0.5 ? "Show Front" : "Show Back", #selector(flipPhoto(_:)), p)
            let sizeMenu = NSMenu(), current = p.r.scale ?? 1
            let nearest = Self.sizes.min { abs($0.1 - current) < abs($1.1 - current) }!.1
            for (name, k) in Self.sizes {
                let i = sizeMenu.addItem(withTitle: name, action: #selector(sizePhoto(_:)), keyEquivalent: "")
                i.target = self; i.representedObject = (p, k); i.state = k == nearest ? .on : .off
            }
            menu.addItem(withTitle: "Size", action: nil, keyEquivalent: "").submenu = sizeMenu
            if p.r.onThisDay { item("Keep on String", #selector(keepPhoto(_:)), p) }
            menu.addItem(.separator())
            item("Remove Photo", #selector(removePhoto(_:)), p)
        } else if let i = nearestPoint(m, within: 30) {
            if let k = pinNear(m, 14), k != 0, k != n - 1 { item("Remove Nail", #selector(removeNailItem(_:)), k) }
            else if i != 0, i != n - 1 { item("Add Nail Here", #selector(addNailItem(_:)), i) }
            menu.addItem(.separator())
            item("Add Photos…", #selector(App.addPhotos), target: NSApp.delegate as AnyObject)
            item("Settings…", #selector(App.openSettings), target: NSApp.delegate as AnyObject)
        } else { return }
        NSMenu.popUpContextMenu(menu, with: e, for: self)
    }

    @objc func editPhoto(_ s: NSMenuItem) { if let p = s.representedObject as? Photo { (NSApp.delegate as? App)?.edit(p) } }
    @objc func flipPhoto(_ s: NSMenuItem) { if let p = s.representedObject as? Photo { p.flipTarget = 1 - p.flipTarget; Sound.rustle(0.6) } }
    @objc func keepPhoto(_ s: NSMenuItem) { if let p = s.representedObject as? Photo { p.r.onThisDay = false; save() } }
    @objc func removePhoto(_ s: NSMenuItem) { if let p = s.representedObject as? Photo { remove(p) } }
    @objc func addNailItem(_ s: NSMenuItem) { if let i = s.representedObject as? Int { addNail(i) } }
    @objc func removeNailItem(_ s: NSMenuItem) { if let i = s.representedObject as? Int { removeNail(i) } }

    func remove(_ p: Photo) {
        photos.removeAll { $0 === p }
        if !p.r.file.hasPrefix("/") { try? FileManager.default.removeItem(at: store.appendingPathComponent(p.r.file)) }
        save(); Sound.rustle(0.5)
    }

    // MARK: adding photos

    @discardableResult
    func add(_ img: CGImage, date: Date?, near q: CGPoint, onThisDay: Bool = false, edit: (inout PhotoRecord) -> Void = { _ in }) -> Bool {
        if !onThisDay, photos.filter({ !$0.r.onThisDay }).count >= maxPhotos {
            showToast("The string is full — \(maxPhotos) photos at most"); NSSound.beep(); return false
        }
        guard let file = saveJPEG(img) else { return false }
        var r = PhotoRecord(file: file, at: freeIndex(near: q))
        r.date = date; r.added = Date(); r.onThisDay = onThisDay
        edit(&r)
        guard let p = Photo(r) else { return false }
        p.spin = .random(in: -3...3)
        photos.append(p); save(); Sound.snap()
        return true
    }

    func addFile(_ url: URL, near q: CGPoint) {
        guard let img = loadImage(url, max: 1600) else { showToast("That file is not a photo"); return }
        add(img, date: photoDate(url), near: q)
    }

    func addOnThisDay(_ img: CGImage, date: Date?, years: Int) {
        add(img, date: date, near: pts[n / 2], onThisDay: true) { r in
            r.caption = date.map { dayKey($0, "d MMM yyyy") } ?? ""
            r.note = years == 1 ? "On this day, one year ago." : "On this day, \(years) years ago."
        }
    }

    /// First run: five sample photos go up one by one, developing quickly, so the string never starts empty.
    func hangSamples() {
        for (k, s) in samplePhotos().prefix(5).enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6 + Double(k) * 0.45) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let img = loadImage(s.url, max: 1600) else { return }
                    self.add(img, date: nil, near: self.pts[[12, 22, 31, 40, 49][k]]) { r in
                        r.caption = s.caption
                        r.added = Date() - max(0, cfg.developSeconds - 6) // develops in the last few seconds
                    }
                }
            }
        }
        showToast("Sample photos. Right-click one to remove it.")
    }

    func removeOnThisDay() { for p in photos where p.r.onThisDay { remove(p) } }

    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        let pb = s.draggingPasteboard, at = convert(s.draggingLocation, from: nil)
        func spot(_ k: Int) -> CGPoint { at + CGPoint(x: CGFloat(k) * 150, y: 0) }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true, .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]) as? [URL], !urls.isEmpty {
            for (k, u) in urls.enumerated() { addFile(u, near: spot(k)) }
            return true
        }
        if let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver], !promises.isEmpty {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (k, promise) in promises.enumerated() { // e.g. dragged from the Photos app
                promise.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: .main) { url, error in
                    MainActor.assumeIsolated { if error == nil { self.addFile(url, near: spot(k)) } }
                }
            }
            return true
        }
        if let img = NSImage(pasteboard: pb)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return add(img, date: nil, near: at)
        }
        return false
    }
}

// MARK: lifted photo, shown large above everything

@MainActor final class LiftController {
    var win: NSWindow?
    let view = LiftView()
    var t: CGFloat = 0, target: CGFloat = 0, done: (() -> Void)?
    var active: Bool { win?.isVisible == true }

    func show(_ p: Photo, image: CGImage, back: Bool, holi: Bool, screen: NSScreen, from: CGPoint, size: CGSize,
              angle: CGFloat, done: @escaping () -> Void) {
        let f = screen.frame, aspect = size.width / size.height
        let w = min(f.width * 0.55, f.height * 0.74 * aspect)
        guard let card = renderCard(p, width: w, image: image, back: back, develop: p.developed, holi: holi,
                                    scale: screen.backingScaleFactor) else { return done() }
        if win == nil {
            let w = NSWindow(contentRect: f, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false; w.ignoresMouseEvents = true
            w.level = .floating; w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.contentView = view; win = w
        }
        win!.setFrame(f, display: false)
        view.card = card; view.fromSize = size; view.toSize = CGSize(width: w, height: w / aspect)
        view.from = local(from, f); view.angle = angle
        view.date = p.r.date.map { dayKey($0, "d MMMM yyyy") }
        t = 0; target = 1; self.done = done
        view.t = 0; win!.orderFrontRegardless()
    }

    func local(_ p: CGPoint, _ f: CGRect) -> CGPoint { CGPoint(x: p.x - f.minX, y: f.maxY - p.y) }

    func release(to point: CGPoint, angle: CGFloat) {
        if let f = win?.frame { view.from = local(point, f) }
        view.angle = angle; target = 0
    }

    func tick() {
        guard let w = win, w.isVisible else { return }
        t += (target - t) * 0.2
        view.t = t; view.needsDisplay = true
        if target == 0, t < 0.015 { w.orderOut(nil); view.card = nil; let d = done; done = nil; d?() }
    }
}

final class LiftView: NSView {
    var card: CGImage?, date: String?
    var from = CGPoint.zero, fromSize = CGSize.zero, toSize = CGSize.zero, angle: CGFloat = 0, t: CGFloat = 0
    override var isFlipped: Bool { true }

    override func draw(_ r: NSRect) {
        guard let c = NSGraphicsContext.current?.cgContext, let card else { return }
        c.setFillColor(rgb(0.03, 0.03, 0.05, 0.55 * t)); c.fill(bounds)
        let to = CGPoint(x: bounds.midX, y: bounds.midY - 14)
        let center = from + (to - from) * t
        let size = CGSize(width: fromSize.width + (toSize.width - fromSize.width) * t,
                          height: fromSize.height + (toSize.height - fromSize.height) * t)
        c.saveGState()
        c.translateBy(x: center.x, y: center.y); c.rotate(by: -angle * (1 - t))
        c.setShadow(offset: CGSize(width: 0, height: -(6 + 22 * t)), blur: 12 + 36 * t, color: rgb(0, 0, 0, 0.5))
        c.interpolationQuality = .high
        put(c, card, CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
        c.restoreGState()
        if let date, t > 0.6 {
            let s = NSAttributedString(string: date, attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor(white: 1, alpha: (t - 0.6) * 2.2),
            ])
            s.draw(at: CGPoint(x: center.x - s.size().width / 2, y: center.y + size.height / 2 + 18))
        }
    }
}
