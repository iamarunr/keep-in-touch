import Foundation

/// A backup file from the web app: `{app, format: 1, exportedAt, settings, contacts}`.
/// A bare array of contacts, or `{contacts: [...]}`, is accepted too, as the web app's Restore does.
public struct WebBackup: Sendable {
    public struct Entry: Sendable, Equatable {
        public var date: Day
        public var channel: String
        public var note: String
    }

    public struct Contact: Sendable {
        public var name: String
        public var tier: Tier
        public var email: String
        public var phone: String
        public var city: String
        public var tags: [String]
        public var notes: String
        public var lastContact: Day?
        public var nextContact: Day?
        public var metOn: Day?
        public var log: [Entry]
    }

    public var contacts: [Contact]
    public var cadences: Cadences?
    public var goal: Int?

    public enum ReadError: Error { case notABackup }

    public init(data: Data) throws {
        let json = try JSONSerialization.jsonObject(with: data)
        let root = json as? [String: Any]
        guard let rows = (json as? [Any]) ?? (root?["contacts"] as? [Any]) else { throw ReadError.notABackup }

        func str(_ v: Any?) -> String { (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        func day(_ v: Any?) -> Day? { (v as? String).flatMap { Day($0) } }

        contacts = rows.compactMap { row in
            guard let r = row as? [String: Any] else { return nil }
            let name = str(r["name"])
            guard !name.isEmpty else { return nil }
            let log: [Entry] = (r["log"] as? [Any] ?? []).compactMap { e in
                guard let e = e as? [String: Any], let d = day(e["date"]) else { return nil }
                return Entry(date: d, channel: str(e["channel"]), note: str(e["note"]))
            }
            return Contact(
                name: name, tier: Tier(rawValue: str(r["tier"])) ?? .c,
                email: str(r["email"]), phone: str(r["phone"]), city: str(r["city"]),
                tags: (r["tags"] as? [Any] ?? []).map { str($0) }.filter { !$0.isEmpty },
                notes: str(r["notes"]),
                lastContact: day(r["lastContact"]), nextContact: day(r["nextContact"]), metOn: day(r["metOn"]),
                log: log)
        }

        let settings = root?["settings"] as? [String: Any]
        if let cad = settings?["cad"] as? [String: Any] {
            func n(_ k: String, _ fallback: Int) -> Int { (cad[k] as? NSNumber)?.intValue ?? Int(str(cad[k])) ?? fallback }
            let s = Cadences.standard
            cadences = Cadences(a: n("A", s.a), b: n("B", s.b), c: n("C", s.c), d: n("D", s.d))
        }
        goal = (settings?["goal"] as? NSNumber)?.intValue
    }
}
