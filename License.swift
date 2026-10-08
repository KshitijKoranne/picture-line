// Picture-Line — the unlock for the direct-download build.
// A licence is base64url(JSON) + "." + base64url(Ed25519 signature), issued by the website after a Razorpay payment
// and checked here offline. The Mac App Store build will use StoreKit instead (compile with -D APPSTORE).
import AppKit
import CryptoKit

#if !APPSTORE
@MainActor enum License {
    private static let publicKey = try! Curve25519.Signing.PublicKey(
        rawRepresentation: Data(base64Encoded: "MM4elBoyLsaUFnSZmk7tDarmphbh5gV/w2KoYJJqrg4=")!)
    private static let revoked: Set<String> = [] // payment IDs of refunds, added in app updates

    struct Info: Decodable { let email: String?; let payment_id: String; let product: String }

    static private(set) var isPro = info(UserDefaults.standard.string(forKey: "licenseKey") ?? "") != nil

    static var owner: String? { info(UserDefaults.standard.string(forKey: "licenseKey") ?? "")?.email }

    static func info(_ key: String) -> Info? {
        let parts = key.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        guard parts.count == 2, let payload = Data(base64URL: parts[0]), let sig = Data(base64URL: parts[1]),
              publicKey.isValidSignature(sig, for: Data(parts[0].utf8)),
              let i = try? JSONDecoder().decode(Info.self, from: payload),
              i.product == "picture-line", !revoked.contains(i.payment_id) else { return nil }
        return i
    }

    @discardableResult static func activate(_ key: String) -> Bool {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard info(key) != nil else { return false }
        UserDefaults.standard.set(key, forKey: "licenseKey") // signed, not secret: defaults is enough
        isPro = true
        NotificationCenter.default.post(name: .licenseChanged, object: nil)
        return true
    }

    /// picture-line://activate?key=…  (the "Open in Picture-Line" button on the thank-you page)
    static func handle(_ url: URL) {
        guard url.scheme == "picture-line", url.host == "activate",
              let key = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "key" })?.value
        else { return }
        let ok = activate(key)
        NSApp.activate()
        let a = NSAlert()
        a.messageText = ok ? "Thank you. Picture-Line is unlocked." : "That licence key didn't work."
        a.informativeText = ok ? "Your string now holds up to 12 photos, and every style is yours."
                               : "Copy the whole key from the thank-you page, or write to \(supportEmail)."
        a.runModal()
    }

    static func buy(inr: Bool) { NSWorkspace.shared.open(siteURL.appendingPathComponent("api/license").appending(queryItems: [URLQueryItem(name: "buy", value: inr ? "INR" : "USD")])) }
}

private extension Data {
    init?(base64URL s: Substring) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b += String(repeating: "=", count: (4 - b.count % 4) % 4)
        self.init(base64Encoded: b)
    }
}
#endif

extension Notification.Name { static let licenseChanged = Notification.Name("PL.licenseChanged") }
