#if DEBUG
import Foundation
import SwiftData
import KeepInTouchCore

/// Made-up people for trying the app in the simulator: launch with the `-seedDemo` argument.
@MainActor
enum DemoData {
    static func seedIfAsked(context: ModelContext, existing: [Person]) {
        guard existing.isEmpty, ProcessInfo.processInfo.arguments.contains("-seedDemo") else { return }
        let today = Day.today()
        let rows: [(String, Tier, String, String, String, Int, Int?, String)] = [
            ("Laura Ortiz", .a, "+1 (555) 010-0101", "laura@example.com", "Chicago", -3, -24, "Training for the spring marathon"),
            ("Sam Whitfield", .b, "(555) 010-0102", "", "Austin", 0, -60, ""),
            ("Priya Raman", .a, "+44 7700 900123", "priya@example.com", "London", -1, -22, "Starting a new job in January"),
            ("Diego Alvarez", .c, "", "diego@example.com", "", 5, -177, ""),
            ("Mina Park", .b, "+1 (555) 010-0105", "mina@example.com", "Seattle", 12, -48, ""),
            ("Tom Becker", .d, "", "", "Berlin", 0, nil, "Met at the design meetup"),
        ]
        for (name, tier, phone, email, city, dueIn, lastAgo, notes) in rows {
            let last = lastAgo.map { today.adding(days: $0) }
            let person = Person(name: name, tier: tier, email: email, phone: phone, city: city, notes: notes,
                                lastContact: last, nextContact: today.adding(days: dueIn),
                                metOn: lastAgo == nil ? today : nil)
            context.insert(person)
            if let last {
                let entry = CheckIn(date: last, channel: "Call", note: name == "Laura Ortiz" ? "Knee is better" : "")
                context.insert(entry)
                entry.person = person
            }
        }
    }
}
#endif
