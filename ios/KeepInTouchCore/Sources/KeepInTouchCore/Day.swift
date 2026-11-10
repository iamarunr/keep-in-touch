import Foundation

/// A calendar day stored as "YYYY-MM-DD", the same format the web app uses.
/// Strings in this format sort in date order and don't shift with time zones.
public struct Day: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let iso: String

    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    public init?(_ iso: String) {
        let parts = iso.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              let date = Day.utc.date(from: DateComponents(year: y, month: m, day: d)),
              Day.utc.dateComponents([.year, .month, .day], from: date) == DateComponents(year: y, month: m, day: d)
        else { return nil }
        self.iso = iso
    }

    /// The day that `date` falls on in `calendar`'s time zone.
    public init(_ date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.iso = String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }

    public static func today(calendar: Calendar = .current) -> Day { Day(Date(), calendar: calendar) }

    private var utcDate: Date {
        let p = iso.split(separator: "-").compactMap { Int($0) }
        return Day.utc.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))!
    }

    /// Midnight at the start of this day in `calendar`'s time zone.
    public func date(calendar: Calendar = .current) -> Date {
        let p = iso.split(separator: "-").compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2])) ?? utcDate
    }

    public func adding(days n: Int) -> Day {
        Day(Day.utc.date(byAdding: .day, value: n, to: utcDate)!, calendar: Day.utc)
    }

    /// Whole days from this day to `other`; negative when `other` is earlier.
    public func days(until other: Day) -> Int {
        Day.utc.dateComponents([.day], from: utcDate, to: other.utcDate).day ?? 0
    }

    public static func < (l: Day, r: Day) -> Bool { l.iso < r.iso }
    public var description: String { iso }

    /// "today", "in 3 weeks", "5 days ago". `n` is days from today; negative is the past.
    public static func relative(_ n: Int) -> String {
        if n == 0 { return "today" }
        if n == 1 { return "tomorrow" }
        if n == -1 { return "yesterday" }
        let a = abs(n)
        let t: String
        if a < 14 { t = "\(a) days" }
        else if a < 60 { t = "\(Int((Double(a) / 7).rounded())) weeks" }
        else if a < 365 { t = "\(Int((Double(a) / 30.4).rounded())) months" }
        else { t = "\((Double(a) / 36.5).rounded() / 10) years" }
        return n < 0 ? "\(t) ago" : "in \(t)"
    }
}
