import Foundation
import SwiftData
import KeepInTouchCore

// Both models follow CloudKit's rules (every property has a default, relationships are optional,
// no unique constraints), so iCloud sync can be turned on later without migrating data.
// Dates are "YYYY-MM-DD" strings, as in the web app. See `Day`.

@Model
final class Person {
    var name: String = ""
    var tierRaw: String = Tier.c.rawValue
    var email: String = ""
    var phone: String = ""
    var city: String = ""
    var tags: [String] = []
    var notes: String = ""
    var lastContact: String?
    var nextContact: String = ""
    var metOn: String?
    var createdAt: Date = Date()
    /// The phone contact this person was picked from. It can differ between devices.
    var contactIdentifier: String?
    @Relationship(deleteRule: .cascade, inverse: \CheckIn.person) var checkIns: [CheckIn]? = []

    init(name: String, tier: Tier, email: String = "", phone: String = "", city: String = "",
         tags: [String] = [], notes: String = "", lastContact: Day? = nil, nextContact: Day,
         metOn: Day? = nil, contactIdentifier: String? = nil) {
        self.name = name
        self.tierRaw = tier.rawValue
        self.email = email
        self.phone = phone
        self.city = city
        self.tags = tags
        self.notes = notes
        self.lastContact = lastContact?.iso
        self.nextContact = nextContact.iso
        self.metOn = metOn?.iso
        self.contactIdentifier = contactIdentifier
    }

    var tier: Tier {
        get { Tier(rawValue: tierRaw) ?? .c }
        set { tierRaw = newValue.rawValue }
    }
    var nextDay: Day { Day(nextContact) ?? .today() }
    var lastDay: Day? { lastContact.flatMap { Day($0) } }

    /// Newest first.
    var history: [CheckIn] {
        (checkIns ?? []).sorted { ($0.date, $0.createdAt) > ($1.date, $1.createdAt) }
    }
}

@Model
final class CheckIn {
    var date: String = ""
    var channel: String = ""
    var note: String = ""
    var createdAt: Date = Date()
    var person: Person?

    init(date: Day, channel: String, note: String = "") {
        self.date = date.iso
        self.channel = channel
        self.note = note
    }
}

enum Channel {
    static let all = ["Message", "WhatsApp", "Call", "Email", "In person", "Other"]
}

extension Person {
    func logCheckIn(channel: String, note: String, context: ModelContext, today: Day = .today()) {
        let entry = CheckIn(date: today, channel: channel, note: note.trimmingCharacters(in: .whitespacesAndNewlines))
        context.insert(entry)
        entry.person = self
        lastContact = today.iso
        nextContact = Schedule.afterCheckIn(on: today, tier: tier, cadences: Keys.cadences()).iso
    }

    func snooze(days: Int, today: Day = .today()) {
        nextContact = today.adding(days: days).iso
    }

    func changeTier(to newTier: Tier, today: Day = .today()) {
        tier = newTier
        nextContact = Schedule.next(lastContact: lastDay, tier: newTier, cadences: Keys.cadences(), today: today).iso
    }
}

extension Array where Element == Person {
    /// The order of the Today list: tier first, then whoever has waited longest.
    func byTierThenDue() -> [Person] {
        sorted { ($0.tierRaw, $0.nextContact, $0.name) < ($1.tierRaw, $1.nextContact, $1.name) }
    }

    /// Matches the web app's import rule: email first, then exact name.
    func firstMatching(email: String, name: String, contactIdentifier: String? = nil) -> Person? {
        let e = email.lowercased()
        if let id = contactIdentifier, let hit = first(where: { $0.contactIdentifier == id }) { return hit }
        if !e.isEmpty, let hit = first(where: { $0.email.lowercased() == e }) { return hit }
        return first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}
