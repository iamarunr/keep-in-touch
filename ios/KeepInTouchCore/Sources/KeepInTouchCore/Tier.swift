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

    /// The amount and unit a number of days reads best as: 21 is 3 weeks, 60 is 2 months, 365 is 1 year.
    private static func parts(days n: Int) -> (count: Int, unit: String, short: String) {
        if n % 7 == 0 && n < 70 { return (n / 7, "week", "w") }
        if (360...366).contains(n) { return (1, "year", "y") }
        if n % 365 == 0 { return (n / 365, "year", "y") }
        if n >= 58 { return (Int((Double(n) / 30.4).rounded()), "month", "mo") }
        return (n, "day", "d")
    }

    /// "Every 3 weeks", "Every 2 months", "Once a year".
    public static func every(days n: Int) -> String {
        let p = parts(days: n)
        if p.count == 1 { return p.unit == "year" ? "Once a year" : "Every \(p.unit)" }
        return "Every \(p.count) \(p.unit)s"
    }

    /// "3w", "2mo", "1y": short enough for a badge.
    public static func short(days n: Int) -> String {
        let p = parts(days: n)
        return "\(p.count)\(p.short)"
    }

    public func title(for tier: Tier) -> String { Cadences.every(days: days(for: tier)) }
    public func short(for tier: Tier) -> String { Cadences.short(days: days(for: tier)) }
}
