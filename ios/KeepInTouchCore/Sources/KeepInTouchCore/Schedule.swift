import Foundation

/// When the next check-in falls. These are the same rules as the web app.
public enum Schedule {
    /// Logging a check-in today puts the next one a full cadence away.
    public static func afterCheckIn(on today: Day, tier: Tier, cadences: Cadences) -> Day {
        today.adding(days: cadences.days(for: tier))
    }

    /// For a new person or a tier change: one cadence after the last check-in, never earlier than today.
    /// Someone with no check-in yet is due today.
    public static func next(lastContact: Day?, tier: Tier, cadences: Cadences, today: Day) -> Day {
        guard let lastContact else { return today }
        return max(today, lastContact.adding(days: cadences.days(for: tier)))
    }

    /// A random day within the tier's cycle, so a big import doesn't all come due at once.
    public static func spread<G: RandomNumberGenerator>(tier: Tier, cadences: Cadences, today: Day, using rng: inout G) -> Day {
        today.adding(days: Int.random(in: 0..<cadences.days(for: tier), using: &rng))
    }
}
