import Foundation

/// Links that open another app with the person already filled in.
public enum ReachOut {
    /// Digits with a leading "+" when the number has a country code, e.g. "+15551234567".
    public static func dialable(_ phone: String) -> String? {
        let digits = phone.filter(\.isWholeNumber).map(String.init).joined()
        guard digits.count >= 3 else { return nil }
        return (phone.trimmingCharacters(in: .whitespaces).hasPrefix("+") ? "+" : "") + digits
    }

    /// Opens Messages, which sends as iMessage when the other person has it.
    public static func message(phone: String) -> URL? {
        dialable(phone).flatMap { URL(string: "sms:\($0)") }
    }

    public static func call(phone: String) -> URL? {
        dialable(phone).flatMap { URL(string: "tel:\($0)") }
    }

    /// WhatsApp needs the full international number with no "+".
    /// A number saved without a country code gets `defaultCountryCode` (digits only, e.g. "1").
    public static func whatsApp(phone: String, defaultCountryCode: String) -> URL? {
        guard let d = dialable(phone) else { return nil }
        let code = defaultCountryCode.filter(\.isWholeNumber)
        let full: String
        if d.hasPrefix("+") { full = String(d.dropFirst()) }
        else if d.hasPrefix("00") { full = String(d.dropFirst(2)) }
        else { full = code + String(d.drop(while: { $0 == "0" })) }
        return URL(string: "https://wa.me/\(full)")
    }

    public static func email(_ address: String) -> URL? {
        let a = address.trimmingCharacters(in: .whitespaces)
        guard a.contains("@") else { return nil }
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = a
        return c.url
    }
}
