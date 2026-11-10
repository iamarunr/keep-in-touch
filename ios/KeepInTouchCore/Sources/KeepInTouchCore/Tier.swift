import Foundation

/// Derek Sivers' four lists: how important someone is decides how often to check in.
public enum Tier: String, CaseIterable, Codable, Sendable, Identifiable {
    case a = "A", b = "B", c = "C", d = "D"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .a: "Very important"
        case .b: "Important"
        case .c: "Most people"
        case .d: "Demoted"
        }
    }
}

/// Days between check-ins for each tier.
public struct Cadences: Equatable, Sendable {
    public var a: Int, b: Int, c: Int, d: Int

    public static let standard = Cadences(a: 21, b: 60, c: 182, d: 365)

    public init(a: Int, b: Int, c: Int, d: Int) {
        self.a = a; self.b = b; self.c = c; self.d = d
    }

    public func days(for tier: Tier) -> Int {
        let n: Int
        switch tier {
        case .a: n = a
        case .b: n = b
        case .c: n = c
        case .d: n = d
        }
        return max(1, n)
    }

    /// "3 weeks", "2 months", "year": the same wording the web app uses.
    public static func text(days n: Int) -> String {
        if n % 7 == 0 && n < 70 { return "\(n / 7) weeks" }
        if (360...366).contains(n) { return "year" }
        if n >= 58 { return "\(Int((Double(n) / 30.4).rounded())) months" }
        return "\(n) days"
    }
}
