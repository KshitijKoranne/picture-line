// Picture-Line — data, settings, sun times, festivals, sounds.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let appName = "Picture-Line"
let maxPhotos = 12 // ponytail: one cap until the paid tier exists (then free 7 / paid 12)

let store: URL = {
    let fm = FileManager.default
    let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let url = base.appendingPathComponent(appName)
    let old = base.appendingPathComponent("Memories") // MVP name
    if !fm.fileExists(atPath: url.path), fm.fileExists(atPath: old.path) { try? fm.moveItem(at: old, to: url) }
    try? fm.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}()

// MARK: settings

let defaultSettings: [String: Any] = [
    "stringColor": "twine", "thickness": 2.2, "sag": 0.06,
    "lights": "sunset", "lightColor": "warm",
    "frame": "polaroid", "size": "medium", "clip": "wood",
    "develop": "natural", "font": "Kalam-Regular",
    "breeze": true, "breezeStrength": 0.5,
    "onThisDay": true, "birthdays": true, "festival": "auto",
    "sounds": true, "volume": 0.6, "peek": "ctrlopt",
]

struct Config {
    var stringColor, lights, lightColor, frame, size, clip, develop, font, festival, peek: String
    var thickness, sag, breezeStrength, volume: Double
    var breeze, onThisDay, birthdays, sounds: Bool

    static func load() -> Config {
        let d = UserDefaults.standard
        return Config(stringColor: d.string(forKey: "stringColor")!, lights: d.string(forKey: "lights")!,
                      lightColor: d.string(forKey: "lightColor")!, frame: d.string(forKey: "frame")!,
                      size: d.string(forKey: "size")!, clip: d.string(forKey: "clip")!,
                      develop: d.string(forKey: "develop")!,
                      font: handwritingFonts.contains { $0.1 == d.string(forKey: "font") } ? d.string(forKey: "font")! : "Kalam-Regular",
                      festival: d.string(forKey: "festival")!, peek: d.string(forKey: "peek")!,
                      thickness: d.double(forKey: "thickness"), sag: d.double(forKey: "sag"),
                      breezeStrength: d.double(forKey: "breezeStrength"), volume: d.double(forKey: "volume"),
                      breeze: d.bool(forKey: "breeze"), onThisDay: d.bool(forKey: "onThisDay"),
                      birthdays: d.bool(forKey: "birthdays"), sounds: d.bool(forKey: "sounds"))
    }

    var cardWidth: CGFloat { ["small": 116, "large": 176][size] ?? 144 }
    var developSeconds: Double { ["off": 0, "quick": 25][develop] ?? 150 }
}

@MainActor var cfg: Config = {
    UserDefaults.standard.register(defaults: defaultSettings)
    return Config.load()
}()

// MARK: photos

struct PhotoRecord: Codable {
    var id = UUID()
    var file: String
    var at: Int
    var caption = "", note = ""
    var date: Date?
    var birthday: String? // "MM-dd"
    var added = Date.distantPast
    var onThisDay = false
    var scale: Double? // this photo's size relative to the default (scroll over it to change)
}

enum Library {
    static let file = store.appendingPathComponent("photos.json")

    static func load() -> [PhotoRecord] {
        if let data = try? Data(contentsOf: file), let r = try? JSONDecoder().decode([PhotoRecord].self, from: data) { return r }
        // MVP stored [file, at] in the old app's defaults, on a 36-point string.
        let old = UserDefaults(suiteName: "in.kjrlabs.memories")?.array(forKey: "photos") as? [[String: Any]] ?? []
        return old.compactMap { d in
            (d["file"] as? String).map { PhotoRecord(file: $0, at: (d["at"] as? Int ?? 18) * 60 / 36) }
        }
    }

    static func save(_ r: [PhotoRecord]) { try? JSONEncoder().encode(r).write(to: file, options: .atomic) }
}

/// A photo's file: a name inside Application Support, or a full path for the bundled samples.
func photoURL(_ file: String) -> URL { file.hasPrefix("/") ? URL(fileURLWithPath: file) : store.appendingPathComponent(file) }

/// The sample photos that ship with the app, with captions, for the welcome window and a first string.
func samplePhotos() -> [(url: URL, caption: String)] {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    let dir = [Bundle.main.resourceURL?.appendingPathComponent("Samples"), exe.appendingPathComponent("Samples"),
               URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Samples")]
        .compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    guard let dir else { return [] }
    return [(3, "Bruno"), (2, "Road trip"), (6, "By Mira, age 6"), (4, "Chai o'clock"), (7, "Sunday ride"),
            (5, "Up north"), (8, "Night market")]
        .map { (dir.appendingPathComponent("sample-\($0.0).jpg"), $0.1) }
        .filter { FileManager.default.fileExists(atPath: $0.0.path) }
}

/// Oriented, downsized image straight from the file (handles HEIC and EXIF rotation).
func loadImage(_ url: URL, max: Int) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateThumbnailAtIndex(src, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: max,
    ] as CFDictionary)
}

func photoDate(_ url: URL) -> Date? {
    if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
       let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
       let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any],
       let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        if let d = f.date(from: s) { return d }
    }
    return (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
}

func scaled(_ img: CGImage, max m: Int) -> CGImage {
    let s = CGFloat(m) / CGFloat(max(img.width, img.height))
    guard s < 1 else { return img }
    let w = Int(CGFloat(img.width) * s), h = Int(CGFloat(img.height) * s)
    guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return img }
    c.interpolationQuality = .high
    c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return c.makeImage() ?? img
}

func grayscale(_ img: CGImage) -> CGImage? {
    let c = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
    c?.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    return c?.makeImage()
}

/// Saves a copy in Application Support so the original can move or be deleted.
func saveJPEG(_ img: CGImage) -> String? {
    let name = UUID().uuidString + ".jpg"
    guard let dst = CGImageDestinationCreateWithURL(store.appendingPathComponent(name) as CFURL,
                                                    UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dst, scaled(img, max: 1600), [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
    return CGImageDestinationFinalize(dst) ? name : nil
}

func dayKey(_ d: Date, _ format: String = "yyyy-MM-dd") -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = format
    return f.string(from: d)
}

// MARK: sun

enum Sky {
    /// Sunrise or sunset on the local calendar day of `date` (NOAA almanac method, about ±2 min).
    static func sun(_ date: Date, lat: Double, lon: Double, rising: Bool) -> Date? {
        let r = Double.pi / 180, local = Calendar.current
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let n = Double(local.ordinality(of: .day, in: .year, for: date)!)
        let lngHour = lon / 15
        let t = n + ((rising ? 6 : 18) - lngHour) / 24
        let m = 0.9856 * t - 3.289
        var l = m + 1.916 * sin(m * r) + 0.020 * sin(2 * m * r) + 282.634
        l = (l.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        var ra = atan(0.91764 * tan(l * r)) / r
        ra = (ra.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        ra = (ra + floor(l / 90) * 90 - floor(ra / 90) * 90) / 15
        let sinDec = 0.39782 * sin(l * r), cosDec = cos(asin(sinDec))
        let cosH = (cos(90.833 * r) - sinDec * sin(lat * r)) / (cosDec * cos(lat * r))
        guard abs(cosH) <= 1 else { return nil } // polar day or night
        let h = (rising ? 360 - acos(cosH) / r : acos(cosH) / r) / 15
        let ut = ((h + ra - 0.06571 * t - 6.622 - lngHour).truncatingRemainder(dividingBy: 24) + 24)
            .truncatingRemainder(dividingBy: 24)
        let start = local.startOfDay(for: date)
        var d = utc.date(from: local.dateComponents([.year, .month, .day], from: date))!.addingTimeInterval(ut * 3600)
        if d < start { d += 86400 } else if d >= start + 86400 { d -= 86400 }
        return d
    }

    static func isNight(_ now: Date = Date()) -> Bool {
        let d = UserDefaults.standard
        if d.object(forKey: "lat") != nil,
           let rise = sun(now, lat: d.double(forKey: "lat"), lon: d.double(forKey: "lon"), rising: true),
           let set = sun(now, lat: d.double(forKey: "lat"), lon: d.double(forKey: "lon"), rising: false) {
            return now < rise || now >= set - 600 // lights come on 10 min before sunset
        }
        let h = Calendar.current.component(.hour, from: now), m = Calendar.current.component(.minute, from: now)
        return h * 60 + m >= 18 * 60 + 20 || h * 60 + m < 6 * 60 + 30 // no location: evening fallback
    }
}

// MARK: festivals

enum Festival: String { case diwali, christmas, holi, winter }

func currentFestival(_ setting: String, _ now: Date = Date()) -> Festival? {
    if setting == "off" { return nil }
    if setting != "auto" { return Festival(rawValue: setting) }
    let cal = Calendar.current, today = cal.startOfDay(for: now)
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
    func near(_ days: [String], _ before: Int, _ after: Int) -> Bool {
        days.contains { s in
            guard let d = f.date(from: s), let n = cal.dateComponents([.day], from: d, to: today).day else { return false }
            return n >= -before && n <= after
        }
    }
    // ponytail: lunar dates listed to 2030 (Lakshmi Puja / Holi colour day); extend the lists after that
    if near(["2026-11-08", "2027-10-29", "2028-10-17", "2029-11-05", "2030-10-26"], 4, 2) { return .diwali }
    if near(["2026-03-03", "2027-03-22", "2028-03-11", "2029-03-01", "2030-03-20"], 1, 1) { return .holi }
    let c = cal.dateComponents([.month, .day], from: now)
    if (c.month == 12 && c.day! >= 18) || (c.month == 1 && c.day == 1) { return .christmas }
    return nil
}

// MARK: sounds (synthesised, so the app ships no audio files)

@MainActor enum Sound {
    static var snapSound: NSSound?, rustles: [NSSound] = []

    static func load() {
        snapSound = NSSound(data: wav(snapSamples()))
        rustles = (0..<3).compactMap { NSSound(data: wav(rustleSamples(seed: UInt64($0 + 1)))) }
    }

    static func play(_ s: NSSound?, _ v: Double) {
        guard cfg.sounds, let s = s?.copy() as? NSSound else { return }
        s.volume = Float(v * cfg.volume); s.play()
    }

    static func snap(_ v: Double = 1) { play(snapSound, v) }
    static func rustle(_ v: Double) { play(rustles.randomElement(), v * 0.5) }

    static func wav(_ x: [Float], rate: Int = 44100) -> Data {
        var d = Data()
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + x.count * 2).littleEndian)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16).littleEndian); put(UInt16(1).littleEndian)
        put(UInt16(1).littleEndian); put(UInt32(rate).littleEndian); put(UInt32(rate * 2).littleEndian)
        put(UInt16(2).littleEndian); put(UInt16(16).littleEndian)
        d.append(contentsOf: Array("data".utf8)); put(UInt32(x.count * 2).littleEndian)
        for s in x { put(Int16(max(-1, min(1, s)) * 32000).littleEndian) }
        return d
    }

    /// Two quick clicks and a short woody ring: a clothes-peg closing.
    static func snapSamples() -> [Float] {
        var g = SystemRandomNumberGenerator()
        return (0..<Int(44100 * 0.09)).map { i in
            let t = Float(i) / 44100, two = 2 * Float.pi
            let noise = Float.random(in: -1...1, using: &g)
            var s = noise * exp(-t * 900) * 0.8
            s += sin(two * 1850 * t) * exp(-t * 70) * 0.30 + sin(two * 3700 * t + 0.3) * exp(-t * 110) * 0.16
            s += sin(two * 640 * t) * exp(-t * 50) * 0.22
            let t2 = t - 0.011
            if t2 > 0 { s += noise * exp(-t2 * 1300) * 0.45 + sin(two * 2600 * t2) * exp(-t2 * 160) * 0.2 }
            return s * min(1, t * 2000) * 0.75
        }
    }

    /// Sparse crackles through a band-pass: paper moving against paper.
    static func rustleSamples(seed: UInt64) -> [Float] {
        var r = seed &* 6364136223846793005 &+ 1442695040888963407
        func rnd() -> Float { r = r &* 6364136223846793005 &+ 1442695040888963407; return Float(r >> 40) / Float(1 << 24) }
        let n = Int(44100 * 0.42)
        var crack: Float = 0, prev: Float = 0, hp: Float = 0, lp: Float = 0
        return (0..<n).map { i in
            let t = Float(i) / Float(n)
            if rnd() < 0.012 { crack += (rnd() * 2 - 1) * (0.4 + rnd()) }
            crack *= 0.94
            let x = crack + (rnd() * 2 - 1) * 0.18
            hp = 0.96 * (hp + x - prev); prev = x
            lp += (hp - lp) * 0.5
            return lp * pow(sin(Float.pi * t), 1.5) * 0.9
        }
    }
}
