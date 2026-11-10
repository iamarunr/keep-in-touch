import Foundation
import UserNotifications
import KeepInTouchCore

/// One local notification a day, at the time chosen in Settings, on days when someone is due.
/// Local notifications can't be computed at delivery time, so they're scheduled ahead for
/// `horizonDays` and rebuilt whenever the data changes or the app comes forward.
@MainActor
enum Reminders {
    static let horizonDays = 14

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])) ?? false
    }

    static func refresh(people: [Person]) async {
        let center = UNUserNotificationCenter.current()
        let defaults = UserDefaults.standard
        let today = Day.today()
        let entries = people.map { (name: $0.name, tier: $0.tierRaw, next: $0.nextContact) }

        center.removeAllPendingNotificationRequests()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }
        try? await center.setBadgeCount(entries.filter { $0.next <= today.iso }.count)
        guard defaults.bool(forKey: Keys.reminderOn) else { return }

        let minutes = defaults.object(forKey: Keys.reminderMinutes) as? Int ?? Keys.defaultReminderMinutes
        let calendar = Calendar.current
        for offset in 0..<horizonDays {
            let day = today.adding(days: offset)
            guard let fire = calendar.date(byAdding: .minute, value: minutes, to: day.date(calendar: calendar)),
                  fire > Date() else { continue }
            // Assumes nobody is checked in with before then; the next refresh corrects it.
            let due = entries.filter { $0.next <= day.iso }.sorted { ($0.tier, $0.next) < ($1.tier, $1.next) }
            guard !due.isEmpty else { continue }

            let content = UNMutableNotificationContent()
            content.title = due.count == 1 ? "1 person to check in with" : "\(due.count) people to check in with"
            content.body = summary(due.map(\.name))
            content.sound = .default
            content.badge = NSNumber(value: due.count)
            let when = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            let request = UNNotificationRequest(identifier: "due-\(day.iso)", content: content,
                                                trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false))
            try? await center.add(request)
        }
        #if DEBUG
        let pending = await center.pendingNotificationRequests()
        print("Reminders scheduled:", pending.map { "\($0.identifier) \($0.content.title): \($0.content.body)" }.sorted())
        #endif
    }

    static func summary(_ names: [String]) -> String {
        let shown = names.prefix(3).joined(separator: ", ")
        return names.count > 3 ? "\(shown) and \(names.count - 3) more" : shown
    }
}
