import Foundation
import Testing
@testable import KeepInTouchCore

@Suite struct DayTests {
    @Test func parsesOnlyRealDays() {
        #expect(Day("2026-11-09") != nil)
        #expect(Day("2026-02-30") == nil)
        #expect(Day("2026-2-3") == nil)
        #expect(Day("") == nil)
    }

    @Test func addsAcrossMonthsYearsAndLeapDays() {
        #expect(Day("2026-10-29")!.adding(days: 21).iso == "2026-11-19")
        #expect(Day("2026-12-31")!.adding(days: 1).iso == "2027-01-01")
        #expect(Day("2028-02-28")!.adding(days: 1).iso == "2028-02-29")
        #expect(Day("2026-03-01")!.adding(days: -1).iso == "2026-02-28")
    }

    @Test func countsDaysAcrossDaylightSaving() {
        // US clocks change on 2026-11-01; the count must still be whole days.
        #expect(Day("2026-10-31")!.days(until: Day("2026-11-02")!) == 2)
        #expect(Day("2026-11-09")!.days(until: Day("2026-11-01")!) == -8)
    }

    @Test func usesTheCalendarsTimeZone() {
        var tokyo = Calendar(identifier: .gregorian); tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        var la = Calendar(identifier: .gregorian); la.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let instant = Date(timeIntervalSince1970: 1_794_182_400) // 2026-11-09 00:00 UTC
        #expect(Day(instant, calendar: tokyo).iso == "2026-11-09")
        #expect(Day(instant, calendar: la).iso == "2026-11-08")
        #expect(Day(Day("2026-11-09")!.date(calendar: la), calendar: la).iso == "2026-11-09")
    }

    @Test func relativeWordingMatchesTheWebApp() {
        #expect(Day.relative(0) == "today")
        #expect(Day.relative(1) == "tomorrow")
        #expect(Day.relative(-1) == "yesterday")
        #expect(Day.relative(-5) == "5 days ago")
        #expect(Day.relative(21) == "in 3 weeks")
        #expect(Day.relative(182) == "in 6 months")
        #expect(Day.relative(365) == "in 1.0 years")
    }
}

@Suite struct ScheduleTests {
    let today = Day("2026-11-09")!
    let cad = Cadences.standard

    @Test func checkInMovesAFullCadence() {
        #expect(Schedule.afterCheckIn(on: today, tier: .a, cadences: cad).iso == "2026-11-30")
        #expect(Schedule.afterCheckIn(on: today, tier: .d, cadences: cad).iso == "2027-11-09")
    }

    @Test func nextIsNeverBeforeToday() {
        #expect(Schedule.next(lastContact: nil, tier: .b, cadences: cad, today: today) == today)
        #expect(Schedule.next(lastContact: Day("2026-01-01"), tier: .a, cadences: cad, today: today) == today)
        #expect(Schedule.next(lastContact: Day("2026-11-01"), tier: .a, cadences: cad, today: today).iso == "2026-11-22")
    }

    @Test func spreadStaysInsideTheCycle() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let d = Schedule.spread(tier: .a, cadences: cad, today: today, using: &rng)
            #expect((0..<21).contains(today.days(until: d)))
        }
    }

    @Test func cadenceWording() {
        let s = Cadences.standard
        #expect(Tier.allCases.map(s.title) == ["Every 3 weeks", "Every 2 months", "Every 6 months", "Once a year"])
        #expect(Tier.allCases.map(s.short) == ["3w", "2mo", "6mo", "1y"])
        #expect(Cadences.every(days: 7) == "Every week")
        #expect(Cadences.every(days: 1) == "Every day")
        #expect(Cadences.every(days: 30) == "Every 30 days")
        #expect(Cadences.every(days: 730) == "Every 2 years")
        #expect(Cadences.short(days: 45) == "45d")
        #expect(Cadences(a: 0, b: 60, c: 182, d: 365).days(for: .a) == 1)
    }
}

@Suite struct ReachOutTests {
    @Test func messageAndCallKeepTheCountryCode() {
        #expect(ReachOut.message(phone: "+1 (555) 123-4567")?.absoluteString == "sms:+15551234567")
        #expect(ReachOut.call(phone: "(555) 123-4567")?.absoluteString == "tel:5551234567")
        #expect(ReachOut.message(phone: "n/a") == nil)
    }

    @Test func whatsAppAlwaysGetsAnInternationalNumber() {
        #expect(ReachOut.whatsApp(phone: "+44 7700 900123", defaultCountryCode: "1")?.absoluteString == "https://wa.me/447700900123")
        #expect(ReachOut.whatsApp(phone: "(555) 123-4567", defaultCountryCode: "1")?.absoluteString == "https://wa.me/15551234567")
        #expect(ReachOut.whatsApp(phone: "07700 900123", defaultCountryCode: "+44")?.absoluteString == "https://wa.me/447700900123")
        #expect(ReachOut.whatsApp(phone: "0044 7700 900123", defaultCountryCode: "1")?.absoluteString == "https://wa.me/447700900123")
    }

    @Test func emailLinks() {
        #expect(ReachOut.email(" laura@x.com ")?.absoluteString == "mailto:laura@x.com")
        #expect(ReachOut.email("not an email") == nil)
    }
}

@Suite struct WebBackupTests {
    @Test func readsAWebAppBackup() throws {
        let json = """
        {"app":"keep-in-touch","format":1,"exportedAt":"2026-10-29T05:00:00.000Z",
         "settings":{"cad":{"A":14,"B":60,"C":182,"D":365},"goal":5},
         "contacts":[
           {"id":"abc","name":" Laura Ortiz ","tier":"A","email":"laura@x.com","phone":"+1 555 123 4567","city":"Chicago",
            "tags":["runner","client"],"notes":"Met at the marathon","lastContact":"2026-10-20","nextContact":"2026-11-10",
            "metOn":null,"log":[{"date":"2026-10-20","channel":"Call","note":"New job"},{"date":"bad","channel":"x","note":""}],
            "createdAt":"2026-09-01"},
           {"name":"","tier":"B"},
           {"name":"No Tier","tier":"Z"}
         ]}
        """
        let b = try WebBackup(data: Data(json.utf8))
        #expect(b.cadences == Cadences(a: 14, b: 60, c: 182, d: 365))
        #expect(b.goal == 5)
        #expect(b.contacts.count == 2)
        let laura = b.contacts[0]
        #expect(laura.name == "Laura Ortiz")
        #expect(laura.tier == .a)
        #expect(laura.tags == ["runner", "client"])
        #expect(laura.lastContact?.iso == "2026-10-20")
        #expect(laura.nextContact?.iso == "2026-11-10")
        #expect(laura.metOn == nil)
        #expect(laura.log == [WebBackup.Entry(date: Day("2026-10-20")!, channel: "Call", note: "New job")])
        #expect(b.contacts[1].tier == .c)
    }

    @Test func acceptsABareArrayAndRejectsOtherFiles() throws {
        #expect(try WebBackup(data: Data(#"[{"name":"Sam"}]"#.utf8)).contacts.count == 1)
        #expect(throws: (any Error).self) { try WebBackup(data: Data(#"{"hello":1}"#.utf8)) }
        #expect(throws: (any Error).self) { try WebBackup(data: Data("not json".utf8)) }
    }
}
