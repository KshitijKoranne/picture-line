// Picture-Line — app shell: windows, menu bar, keys, permissions, On this day.
import AppKit
import SwiftUI
import CoreLocation
import Photos
import ServiceManagement

let desktopLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)

@MainActor final class App: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, CLLocationManagerDelegate {
    var win: NSWindow!, view: StringView!, item: NSStatusItem!
    var settingsWin: NSWindow?, editWin: NSWindow?, welcomeWin: NSWindow?
    var onTopItem: NSMenuItem!, hideItem: NSMenuItem!, hintItem: NSMenuItem!
    let loc = CLLocationManager()
    var optDown = false, lastOptTap = 0.0
    var timer: Timer?, hz = 0.0
    var peekKeys: NSEvent.ModifierFlags = [.control, .option], keepInFront = false, frontUntil = 0.0
    var paywallWin: NSWindow?
    var unlockItem: NSMenuItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        registerFonts()
        _ = cfg
        Sound.load()
        // A non-activating panel: clicking a photo never pulls focus from the app you are working in.
        let panel = NSPanel(contentRect: stringFrame(), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.hidesOnDeactivate = false; panel.becomesKeyOnlyIfNeeded = true
        win = panel
        win.isOpaque = false; win.backgroundColor = .clear; win.hasShadow = false
        win.level = desktopLevel // on the wallpaper, under every app window
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        view = StringView(frame: NSRect(origin: .zero, size: win.frame.size))
        win.contentView = view
        view.setup()
        buildMenu()
        buildMainMenu()
        readKeys()
        applyVisibility()

        setRate(60)
        RunLoop.main.add(Timer(timeInterval: 300, target: self, selector: #selector(onThisDay), userInfo: nil, repeats: true), forMode: .common)
        let nc = NotificationCenter.default
        nc.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
        nc.addObserver(forName: .licenseChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged(); self?.paywallWin?.close() }
        }
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.win.setFrame(self.stringFrame(), display: false); self.view.layoutRope()
            }
        }

        if UserDefaults.standard.bool(forKey: "welcomed") {
            requestLocationIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in MainActor.assumeIsolated { self?.onThisDay() } }
        } else {
            showWelcome()
        }
    }

    func applicationWillTerminate(_ n: Notification) { if view.pendingSave { view.save() } }

    /// picture-line://activate?key=… from the website's thank-you page.
    func application(_ application: NSApplication, open urls: [URL]) {
        #if !APPSTORE
        urls.forEach(License.handle)
        #endif
    }

    /// Opening the app again (Finder, Spotlight, Launchpad) shows Settings, as menu bar apps usually do.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings(); return false
    }

    func stringFrame() -> NSRect {
        // The built-in or primary display (the first screen), not whichever screen has focus right now.
        let s = NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(x: s.minX, y: s.maxY - min(660, s.height), width: s.width, height: min(660, s.height))
    }

    func settingsChanged() {
        let old = cfg
        cfg = Config.load()
        if old.sag != cfg.sag { view.updateLength() }
        if old.lights != cfg.lights { requestLocationIfNeeded() }
        if old.festival != cfg.festival || old.lights != cfg.lights { view.refreshClock(force: true) }
        readKeys()
        if !old.onThisDay, cfg.onThisDay { onThisDay() }
        view.needsDisplay = true
    }

    @objc func tick() {
        let flags = NSEvent.modifierFlags.intersection([.shift, .control, .option, .command])
        let front = keepInFront || flags == peekKeys || ProcessInfo.processInfo.systemUptime < frontUntil
        let level: NSWindow.Level = front ? .floating : desktopLevel
        if win.level != level { win.level = level }

        let opt = flags == .option // double-tap ⌥ adds or removes a nail
        if opt, !optDown {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastOptTap < 0.4 { view.toggleNail(); lastOptTap = 0 } else { lastOptTap = now }
        }
        optDown = opt

        if win.isVisible, win.occlusionState.contains(.visible) || view.lift.active || view.grabbed != nil {
            setRate(view.tick(hz: hz))
        } else {
            view.idleTick(); setRate(2) // hidden, covered by a full-screen app, or the display is asleep
        }
    }

    /// One timer, retuned to what the string needs right now. Tolerance lets macOS group wake-ups to save power.
    func setRate(_ r: Double) {
        guard r != hz else { return }
        hz = r; timer?.invalidate()
        let t = Timer(timeInterval: 1 / r, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        t.tolerance = r >= 60 ? 0.002 : 0.25 / r
        RunLoop.main.add(t, forMode: .common); timer = t
    }

    func readKeys() {
        peekKeys = ["optcmd": [.option, .command], "ctrlshift": [.control, .shift]][cfg.peek] ?? [.control, .option]
        keepInFront = UserDefaults.standard.bool(forKey: "onTop")
    }

    /// Copy, paste and close work in the caption editor and Settings (a menu bar app has no visible main menu).
    func buildMainMenu() {
        let edit = NSMenu(title: "Edit")
        for (t, a, k) in [("Undo", Selector(("undo:")), "z"), ("Redo", Selector(("redo:")), "Z"), ("Cut", #selector(NSText.cut(_:)), "x"),
                          ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"),
                          ("Select All", #selector(NSText.selectAll(_:)), "a"), ("Close", #selector(NSWindow.performClose(_:)), "w")] {
            edit.addItem(withTitle: t, action: a, keyEquivalent: k)
        }
        let main = NSMenu(); main.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = edit
        NSApp.mainMenu = main
    }

    /// Brings the string out from behind your windows for a few seconds and gives it a gentle pluck.
    @objc func findString() {
        if UserDefaults.standard.bool(forKey: "hidden") { UserDefaults.standard.set(false, forKey: "hidden"); applyVisibility() }
        frontUntil = ProcessInfo.processInfo.systemUptime + 8
        view.pluck()
    }

    /// Closed windows are let go, so SwiftUI does not hold their memory.
    func windowWillClose(_ n: Notification) {
        let w = n.object as? NSWindow
        if w === settingsWin { settingsWin = nil }
        if w === editWin { editWin = nil }
        if w === welcomeWin { welcomeWin = nil }
        if w === paywallWin { paywallWin = nil }
    }

    // MARK: menu bar

    func buildMenu() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = statusIcon(); item.button?.toolTip = appName
        let m = NSMenu(); m.delegate = self
        func add(_ title: String, _ action: Selector?, _ key: String = "") -> NSMenuItem {
            let i = m.addItem(withTitle: title, action: action, keyEquivalent: key); i.target = self; return i
        }
        _ = add("Find My String", #selector(findString), "f")
        _ = add("Add Photos…", #selector(addPhotos), "o")
        m.addItem(.separator())
        onTopItem = add("Keep String in Front of Windows", #selector(toggleOnTop))
        hideItem = add("Hide String", #selector(toggleHidden))
        hintItem = add("", nil); hintItem.isEnabled = false
        m.addItem(.separator())
        // Share My String… comes in a later update (shareString below is ready).
        unlockItem = add("Unlock Picture-Line…", #selector(showPaywall))
        _ = add("Settings…", #selector(openSettings), ",")
        _ = add("About \(appName)", #selector(about))
        m.addItem(.separator())
        m.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = m
    }

    func menuWillOpen(_ menu: NSMenu) {
        let d = UserDefaults.standard
        onTopItem.state = d.bool(forKey: "onTop") ? .on : .off
        hideItem.title = d.bool(forKey: "hidden") ? "Show String" : "Hide String"
        hintItem.title = "Hold \(["optcmd": "⌥⌘", "ctrlshift": "⌃⇧"][cfg.peek] ?? "⌃⌥") to peek at your string"
        unlockItem.isHidden = License.isPro
    }

    @objc func toggleOnTop() { UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "onTop"), forKey: "onTop"); readKeys() }

    @objc func showPaywall() {
        if paywallWin == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: PaywallView { [weak self] in self?.paywallWin?.close() }))
            w.styleMask = [.titled, .closable, .fullSizeContentView]; w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false; w.delegate = self; w.level = .floating
            paywallWin = w; w.center()
        }
        NSApp.activate(); paywallWin!.makeKeyAndOrderFront(nil)
    }
    @objc func toggleHidden() { UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "hidden"), forKey: "hidden"); applyVisibility() }

    func applyVisibility() {
        UserDefaults.standard.bool(forKey: "hidden") ? win.orderOut(nil) : win.orderFrontRegardless()
    }

    @objc func addPhotos() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true; p.allowedContentTypes = [.image]; p.message = "Choose photos to hang on the string"
        NSApp.activate()
        guard p.runModal() == .OK else { return }
        if UserDefaults.standard.bool(forKey: "hidden") { UserDefaults.standard.set(false, forKey: "hidden"); applyVisibility() }
        for (k, u) in p.urls.enumerated() { view.addFile(u, near: view.pts[view.n / 2] + CGPoint(x: CGFloat(k) * 150, y: 0)) }
    }

    @objc func openSettings() {
        if settingsWin == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsRoot()))
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true; w.title = "\(appName) Settings"; w.titleVisibility = .hidden
            w.toolbar = NSToolbar(); w.toolbarStyle = .unified // gives the sidebar its full-height glass look
            w.isReleasedWhenClosed = false; w.delegate = self
            settingsWin = w; w.center()
        }
        NSApp.activate(); settingsWin!.makeKeyAndOrderFront(nil)
    }

    /// A picture of the string over your wallpaper, for Messages, Mail, AirDrop or saving.
    @objc func shareString() {
        guard let png = view.snapshotPNG() else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("My \(appName).png")
        try? png.write(to: url)
        let picker = NSSharingServicePicker(items: [url])
        if let w = settingsWin, w.isVisible, let v = w.contentView {
            picker.show(relativeTo: CGRect(x: v.bounds.midX, y: v.bounds.midY, width: 1, height: 1), of: v, preferredEdge: .minY)
        } else if let b = item.button {
            picker.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        }
    }

    @objc func about() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: appName,
            .credits: NSAttributedString(string: "Your favourite photos, on a string across your desktop.", attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
            ]),
        ])
    }

    func edit(_ p: Photo) {
        editWin?.close()
        let model = EditModel(p.r)
        let v = EditView(m: model, image: NSImage(cgImage: p.thumb, size: .zero), font: cfg.font) { [weak self] saveIt in
            if saveIt { model.apply(to: &p.r); p.version += 1; self?.view.save(); self?.view.needsDisplay = true }
            self?.editWin?.close()
        }
        let w = NSWindow(contentViewController: NSHostingController(rootView: v))
        w.title = "Caption & Note"; w.styleMask = [.titled, .closable]; w.isReleasedWhenClosed = false; w.level = .floating; w.delegate = self
        editWin = w; w.center(); NSApp.activate(); w.makeKeyAndOrderFront(nil)
    }

    func showWelcome() {
        let v = WelcomeView { [weak self] lights, otd, login, samples in
            let d = UserDefaults.standard
            d.set(lights ? "sunset" : "off", forKey: "lights"); d.set(otd, forKey: "onThisDay"); d.set(true, forKey: "welcomed")
            if login { try? SMAppService.mainApp.register() }
            if samples, let view = self?.view, view.photos.isEmpty { view.hangSamples() }
            self?.welcomeWin?.close()
            self?.requestLocationIfNeeded(); self?.onThisDay()
            self?.findString() // show them where it lives
        }
        let w = NSWindow(contentViewController: NSHostingController(rootView: v))
        w.styleMask = [.titled, .closable, .fullSizeContentView]; w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false; w.delegate = self; welcomeWin = w
        w.level = .floating // at login the app is not active, so float the welcome above other windows
        w.center(); NSApp.activate(); w.orderFrontRegardless(); w.makeKey()
    }

    // MARK: location (for sunset)

    func requestLocationIfNeeded() {
        guard cfg.lights == "sunset", UserDefaults.standard.object(forKey: "lat") == nil else { return }
        loc.delegate = self; loc.desiredAccuracy = kCLLocationAccuracyReduced
        loc.requestWhenInUseAuthorization()
        loc.requestLocation()
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations l: [CLLocation]) {
        guard let c = l.last?.coordinate else { return }
        UserDefaults.standard.set(c.latitude, forKey: "lat"); UserDefaults.standard.set(c.longitude, forKey: "lon")
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError e: any Error) {} // falls back to an evening clock

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        if m.authorizationStatus == .authorizedAlways { m.requestLocation() }
    }

    // MARK: On this day

    @objc func onThisDay() {
        guard onThisDayReady, cfg.onThisDay, UserDefaults.standard.bool(forKey: "welcomed") else { return }
        let today = dayKey(Date())
        guard UserDefaults.standard.string(forKey: "otdDay") != today, Calendar.current.component(.hour, from: Date()) >= 6 else { return }
        let view = self.view!
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            Task { @MainActor in
                guard status == .authorized || status == .limited else { return }
                UserDefaults.standard.set(today, forKey: "otdDay")
                view.removeOnThisDay()
                guard let pick = Self.pickOnThisDay() else { return }
                let (asset, years) = pick
                let o = PHImageRequestOptions()
                o.deliveryMode = .highQualityFormat; o.isNetworkAccessAllowed = true; o.isSynchronous = false
                PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 1600, height: 1600),
                                                      contentMode: .aspectFit, options: o) { img, _ in
                    guard let cg = img?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
                    Task { @MainActor in view.addOnThisDay(cg, date: asset.creationDate, years: years) }
                }
            }
        }
    }

    /// A random photo from this date in an earlier year; favourites first, never screenshots.
    static func pickOnThisDay() -> (PHAsset, Int)? {
        let cal = Calendar.current
        var found: [(PHAsset, Int)] = []
        for y in 1...30 {
            guard let d = cal.date(byAdding: .year, value: -y, to: Date()) else { continue }
            let s = cal.startOfDay(for: d), e = cal.date(byAdding: .day, value: 1, to: s)!
            let o = PHFetchOptions()
            o.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate < %@", s as NSDate, e as NSDate)
            PHAsset.fetchAssets(with: .image, options: o).enumerateObjects { a, _, _ in
                if !a.mediaSubtypes.contains(.photoScreenshot) { found.append((a, y)) }
            }
        }
        let favourites = found.filter { $0.0.isFavorite }
        return (favourites.isEmpty ? found : favourites).randomElement()
    }
}
