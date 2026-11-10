import Foundation
import KeepInTouchCore

/// Names of the values kept in UserDefaults. Views read and write them with @AppStorage.
enum Keys {
    static let cadA = "cadence.A", cadB = "cadence.B", cadC = "cadence.C", cadD = "cadence.D"
    static let goal = "weeklyGoal"
    static let reminderOn = "reminder.on"
    static let reminderMinutes = "reminder.minutes"   // minutes after midnight
    static let countryCode = "whatsapp.countryCode"
    static let iCloudSync = "icloud.sync"             // read once at launch; see Storage

    static let defaultReminderMinutes = 9 * 60
    static let defaultGoal = 3

    static func cadences(_ defaults: UserDefaults = .standard) -> Cadences {
        func n(_ key: String, _ fallback: Int) -> Int { defaults.object(forKey: key) as? Int ?? fallback }
        let s = Cadences.standard
        return Cadences(a: n(cadA, s.a), b: n(cadB, s.b), c: n(cadC, s.c), d: n(cadD, s.d))
    }

    static func set(_ c: Cadences, _ defaults: UserDefaults = .standard) {
        defaults.set(c.a, forKey: cadA); defaults.set(c.b, forKey: cadB)
        defaults.set(c.c, forKey: cadC); defaults.set(c.d, forKey: cadD)
    }
}
