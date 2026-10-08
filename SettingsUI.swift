// Picture-Line — Settings, photo editor, welcome.
import SwiftUI
import ServiceManagement

struct Swatch: Identifiable { let id: String; let color: CGColor }

struct Swatches: View {
    @Binding var selection: String
    let options: [Swatch]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(options) { s in
                Circle().fill(Color(cgColor: s.color)).frame(width: 18, height: 18)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 1))
                    .padding(3)
                    .overlay(Circle().stroke(Color.accentColor, lineWidth: 2).opacity(selection == s.id ? 1 : 0))
                    .contentShape(Circle())
                    .onTapGesture { selection = s.id }
                    .help(s.id.capitalized)
            }
        }
    }
}


/// Small rounded-square icon, as in System Settings.
struct Badge: View {
    let icon: String, color: Color
    var size: CGFloat = 22
    init(_ icon: String, _ color: Color, size: CGFloat = 22) { self.icon = icon; self.color = color; self.size = size }
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay(Image(systemName: icon).font(.system(size: size * 0.52, weight: .semibold)).foregroundStyle(.white))
    }
}

struct Pane { let title, icon: String; let color: Color; let blurb: String }

/// The Settings window: a sidebar of sections and a grouped form, laid out like System Settings.
struct SettingsRoot: View {
    @AppStorage("settingsTab") var tab = 0
    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { tab }, set: { tab = $0 ?? tab })) {
                ForEach(SettingsView.panes.indices, id: \.self) { k in
                    let p = SettingsView.panes[k]
                    Label { Text(p.title) } icon: { Badge(p.icon, p.color, size: 20) }.tag(k)
                }
            }
            .navigationSplitViewColumnWidth(196)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            SettingsView(pane: tab).id(tab)
        }
        .frame(width: 720, height: 560)
    }
}

struct SettingsView: View {
    let pane: Int
    @AppStorage("stringColor") var stringColor = "twine"
    @AppStorage("thickness") var thickness = 2.2
    @AppStorage("sag") var sag = 0.06
    @AppStorage("lights") var lights = "sunset"
    @AppStorage("lightColor") var lightColor = "warm"
    @AppStorage("frame") var frame = "polaroid"
    @AppStorage("size") var size = "medium"
    @AppStorage("clip") var clip = "wood"
    @AppStorage("develop") var develop = "natural"
    @AppStorage("font") var font = "Kalam-Regular"
    @AppStorage("breeze") var breeze = true
    @AppStorage("breezeStrength") var breezeStrength = 0.5
    @AppStorage("onThisDay") var onThisDay = true
    @AppStorage("birthdays") var birthdays = true
    @AppStorage("festival") var festival = "auto"
    @AppStorage("sounds") var sounds = true
    @AppStorage("volume") var volume = 0.6
    @AppStorage("peek") var peek = "ctrlopt"
    @State var login = SMAppService.mainApp.status == .enabled

    static let panes = [
        Pane(title: "General", icon: "gearshape.fill", color: .gray, blurb: "How Picture-Line starts, sounds and stays out of your way."),
        Pane(title: "String", icon: "point.topleft.down.to.point.bottomright.curvepath.fill", color: .orange, blurb: "The cord itself, its nails and its fairy lights."),
        Pane(title: "Photos", icon: "photo.fill.on.rectangle.fill", color: .blue, blurb: "Frames, clips and the handwriting on them."),
        Pane(title: "Moments", icon: "sparkles", color: .pink, blurb: "Small surprises through the day and the year."),
        Pane(title: "About", icon: "heart.fill", color: .red, blurb: "Made with care in Vadodara, India."),
    ]

    var body: some View {
        let p = Self.panes[pane]
        Form {
            Section {
                VStack(spacing: 8) {
                    Badge(p.icon, p.color, size: 52)
                    Text(p.title).font(.title2.weight(.semibold))
                    Text(p.blurb).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            switch pane {
            case 0: general
            case 1: string
            case 2: photos
            case 3: moments
            default: about
            }
        }
        .formStyle(.grouped)
    }

    func row(_ title: String, _ icon: String, _ color: Color) -> some View {
        Label { Text(title) } icon: { Badge(icon, color) }
    }

    @ViewBuilder var general: some View {
        Section {
            Toggle(isOn: $login) { row("Open at login", "power", .green) }
                .onChange(of: login) { _, on in
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                    catch { login = SMAppService.mainApp.status == .enabled }
                }
            Picker(selection: $peek) {
                Text("⌃ ⌥").tag("ctrlopt"); Text("⌥ ⌘").tag("optcmd"); Text("⌃ ⇧").tag("ctrlshift")
            } label: { row("Hold to bring to front", "square.3.layers.3d.top.filled", .indigo) }
        } footer: {
            Text("The string sits on your desktop, behind your windows. Hold these keys to see it in front.")
        }
        Section {
            Toggle(isOn: $sounds) { row("Sounds", "speaker.wave.2.fill", .red) }
            LabeledContent {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary).font(.caption)
                    Slider(value: $volume, in: 0...1).frame(width: 160)
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary).font(.caption)
                }
            } label: { row("Volume", "dial.medium.fill", .red.opacity(0.75)) }
            .disabled(!sounds)
        } footer: { Text("A soft clip snap when a photo goes up, and a paper rustle when one swings.") }
    }

    @ViewBuilder var string: some View {
        Section {
            LabeledContent {
                Swatches(selection: $stringColor, options: ["twine", "red", "white", "black", "gold"].map { Swatch(id: $0, color: stringColors[$0]!) })
            } label: { row("Colour", "paintpalette.fill", .orange) }
            LabeledContent {
                Slider(value: $thickness, in: 1.2...4) { EmptyView() } minimumValueLabel: { Text("Thin") } maximumValueLabel: { Text("Thick") }
                    .frame(width: 230)
            } label: { row("Thickness", "lineweight", .brown) }
            LabeledContent {
                Slider(value: $sag, in: 0.01...0.2) { EmptyView() } minimumValueLabel: { Text("Taut") } maximumValueLabel: { Text("Loose") }
                    .frame(width: 230)
            } label: { row("Slack", "water.waves", .teal) }
        }
        Section {
            Picker(selection: $lights) {
                Text("Off").tag("off"); Text("On at sunset").tag("sunset"); Text("Always on").tag("always")
            } label: { row("Fairy lights", "lightbulb.fill", .yellow) }
            Picker(selection: $lightColor) {
                Text("Warm white").tag("warm"); Text("Colourful").tag("multi")
            } label: { row("Light colour", "circle.hexagongrid.fill", .purple) }
            .disabled(lights == "off")
        } footer: { Text("“On at sunset” uses your rough location once, to know when the sun goes down where you are.") }
        Section {
            LabeledContent { Text("Pull the string, double-tap ⌥").foregroundStyle(.secondary) } label: { row("Add a nail", "pin.fill", .gray) }
            LabeledContent {
                HStack {
                    Button("Remove All Nails") { NotificationCenter.default.post(name: .removeNails, object: nil) }
                    Button("Reset String") { NotificationCenter.default.post(name: .resetString, object: nil) }
                }
            } label: { row("Start over", "arrow.counterclockwise", .gray) }
        } footer: { Text("Drag a nail, or either end of the string, to move it. Right-click a nail to take it out.") }
    }

    @ViewBuilder var photos: some View {
        Section {
            Picker(selection: $frame) {
                Text("Instant").tag("polaroid"); Text("Classic").tag("classic"); Text("Borderless").tag("bare")
            } label: { row("Frame", "rectangle.portrait.fill", .blue) }
            Picker(selection: $size) {
                Text("Small").tag("small"); Text("Medium").tag("medium"); Text("Large").tag("large")
            } label: { row("Default size", "arrow.up.left.and.arrow.down.right", .cyan) }
            LabeledContent {
                Swatches(selection: $clip, options: ["wood", "red", "blue", "mint", "pink", "black"].map { Swatch(id: $0, color: clipColors[$0]!.0) })
            } label: { row("Clips", "paperclip", .brown) }
        } footer: { Text("To resize one photo, scroll over it, pinch on the trackpad, or right-click it and choose Size.") }
        Section {
            Picker(selection: $font) { ForEach(handwritingFonts, id: \.1) { Text($0.0).tag($0.1) } }
                label: { row("Handwriting", "pencil.and.scribble", .indigo) }
            Text("Summer at Grandma's")
                .font(Font(handwriting(24, font: font))).foregroundStyle(Color(nsColor: ink))
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(red: 0.985, green: 0.98, blue: 0.965)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.black.opacity(0.08)))
        }
        Section {
            Picker(selection: $develop) {
                Text("Appear at once").tag("off"); Text("Develop quickly").tag("quick"); Text("Develop like film").tag("natural")
            } label: { row("New photos", "camera.aperture", .mint) }
        } footer: { Text("A new photo starts white and slowly comes up, like a real instant print.") }
    }

    @ViewBuilder var moments: some View {
        Section {
            Toggle(isOn: $breeze) { row("Breeze when the Mac is idle", "wind", .teal) }
            LabeledContent {
                Slider(value: $breezeStrength, in: 0.15...1) { EmptyView() } minimumValueLabel: { Text("Still") } maximumValueLabel: { Text("Breezy") }
                    .frame(width: 230)
            } label: { row("Strength", "gauge.with.dots.needle.33percent", .teal.opacity(0.75)) }
            .disabled(!breeze)
        }
        Section {
            Toggle(isOn: $onThisDay) { row("On this day", "calendar", .red) }
        } footer: { Text("Each morning, a photo taken on this date in an earlier year is clipped on from your Photos library. It goes the next day, unless you choose Keep on String.") }
        Section {
            Toggle(isOn: $birthdays) { row("Birthday sparkle", "birthday.cake.fill", .pink) }
        } footer: { Text("Right-click a photo and choose Edit Caption & Note to add a birthday. On the day, the photo glows and confetti falls.") }
        Section {
            Picker(selection: $festival) {
                Text("Automatic").tag("auto"); Text("Off").tag("off"); Divider()
                Text("Diwali diyas").tag("diwali"); Text("Christmas stars and snow").tag("christmas")
                Text("Holi colours").tag("holi"); Text("Winter snow").tag("winter")
            } label: { row("Festivals", "party.popper.fill", .orange) }
        } footer: { Text("Automatic decorates the string for Diwali, Holi and Christmas on their dates.") }
    }

    @ViewBuilder var about: some View {
        Section {
            LabeledContent { Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") }
                label: { row("Version", "info.circle.fill", .gray) }
            LabeledContent {
                Button("Share…") { (NSApp.delegate as? App)?.shareString() }
            } label: { row("Share a picture of your string", "square.and.arrow.up.fill", .blue) }
        } footer: { Text("Your photos stay on this Mac. Picture-Line has no account and uploads nothing.") }
        Section("Fonts") {
            Text("Fraunces, Kalam, Patrick Hand, Caveat and Farsan are used under the SIL Open Font Licence. The licence texts are inside the app.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

// MARK: caption & note editor

final class EditModel: ObservableObject {
    @Published var caption: String
    @Published var note: String
    @Published var hasDate: Bool
    @Published var date: Date
    @Published var hasBirthday: Bool
    @Published var birthday: Date

    init(_ r: PhotoRecord) {
        caption = r.caption; note = r.note
        hasDate = r.date != nil; date = r.date ?? Date()
        hasBirthday = r.birthday != nil
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        birthday = r.birthday.flatMap { f.date(from: "2000-" + $0) } ?? Date()
    }

    func apply(to r: inout PhotoRecord) {
        r.caption = String(caption.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        r.note = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
        r.date = hasDate ? date : nil
        r.birthday = hasBirthday ? dayKey(birthday, "MM-dd") : nil
    }
}

struct EditView: View {
    @ObservedObject var m: EditModel
    let image: NSImage, font: String
    var done: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 0) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).frame(width: 112, height: 112).clipped()
                    Text(m.caption.isEmpty ? " " : m.caption).font(Font(handwriting(16, font: font))).foregroundStyle(Color(nsColor: ink))
                        .lineLimit(1).minimumScaleFactor(0.5).frame(width: 112, height: 30)
                }
                .padding([.top, .horizontal], 7).background(Color(white: 0.985))
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Caption, like a name or a place", text: $m.caption).textFieldStyle(.roundedBorder)
                    Text("Note on the back").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $m.note).font(Font(handwriting(17, font: font))).foregroundStyle(Color(nsColor: ink))
                        .scrollContentBackground(.hidden).padding(6).frame(height: 92)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(red: 0.96, green: 0.945, blue: 0.905)))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12)))
                }
            }
            Divider()
            Grid(alignment: .leading, verticalSpacing: 10) {
                GridRow {
                    Toggle("Date taken", isOn: $m.hasDate)
                    DatePicker("", selection: $m.date, displayedComponents: .date).labelsHidden().disabled(!m.hasDate)
                }
                GridRow {
                    Toggle("Birthday", isOn: $m.hasBirthday)
                    DatePicker("", selection: $m.birthday, displayedComponents: .date).labelsHidden().disabled(!m.hasBirthday)
                }
            }
            Text("On the birthday, the photo shines and confetti falls. The year is not used.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { done(false) }.keyboardShortcut(.cancelAction)
                Button("Save") { done(true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 500)
    }
}

// MARK: first launch

/// A small live string for the welcome window. Brush it with the pointer, hold a photo, double-click one.
struct DemoString: NSViewRepresentable {
    func makeNSView(context: Context) -> StringView { StringView.demo(size: CGSize(width: 470, height: 200)) }
    func updateNSView(_ v: StringView, context: Context) {}
}

struct WelcomeView: View {
    @State var lights = false
    @State var otd = false
    @State var login = false
    @State var samples = true
    var start: (Bool, Bool, Bool, Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            DemoString().frame(width: 470, height: 200).padding(.horizontal, -34).padding(.top, -30)
            Text(appName).font(Font(wordmark(40))).tracking(-0.5).padding(.top, 2)
            Text("Your people, on a string across your desktop.")
                .font(.title3).foregroundStyle(.secondary).padding(.top, 4)

            VStack(alignment: .leading, spacing: 12) {
                tip("hand.draw", "Drag a photo", "from Finder or Photos onto the string.")
                tip("hand.tap", "Press and hold", "a photo to see it large.")
                tip("arrow.left.arrow.right", "Double-click", "to turn it over and read the note.")
                tip("pin", "Pull the string down", "and double-tap ⌥ to add a nail.")
                tip("arrow.up.left.and.arrow.down.right", "Scroll over a photo", "to make it bigger or smaller.")
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 22)

            VStack(alignment: .leading, spacing: 12) {
                option($lights, "Turn on fairy lights at sunset", "Uses your rough location, once, to know when the sun goes down.")
                option($otd, "Clip a photo from this day each morning", "Looks through your Photos library, on this Mac only.")
                option($samples, "Hang a few sample photos to start", "Swap them for your own whenever you like.")
                option($login, "Open \(appName) when I log in", "So your string is there every time.")
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            .padding(.top, 20)

            Button { start(lights, otd, login, samples) } label: { Text("Start hanging photos").frame(minWidth: 180) }
                .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction).padding(.top, 22)
            Label("Your photos stay on this Mac. Nothing is uploaded.", systemImage: "lock.fill")
                .font(.footnote).foregroundStyle(.secondary).padding(.top, 12)
        }
        .padding(.horizontal, 34).padding(.top, 30).padding(.bottom, 22).frame(width: 470)
    }

    func tip(_ icon: String, _ lead: String, _ rest: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon).foregroundStyle(.tint).frame(width: 20)
            (Text(lead).fontWeight(.semibold) + Text(" " + rest)).fixedSize(horizontal: false, vertical: true)
        }
    }

    func option(_ on: Binding<Bool>, _ title: String, _ detail: String) -> some View {
        Toggle(isOn: on) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
    }
}
