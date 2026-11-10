import SwiftData
import SwiftUI
import KeepInTouchCore

struct UpcomingView: View {
    @Query(sort: \Person.nextContact) private var people: [Person]

    var body: some View {
        let today = Day.today()
        let end = today.adding(days: 30).iso
        let upcoming = people.filter { $0.nextContact > today.iso && $0.nextContact <= end }
        let days = Dictionary(grouping: upcoming, by: \.nextContact).sorted { $0.key < $1.key }
        NavigationStack {
            List {
                ForEach(days, id: \.key) { iso, group in
                    Section(header(iso, today: today)) {
                        ForEach(group.byTierThenDue()) { person in
                            NavigationLink(value: person) { PersonRow(person: person, today: today) }
                        }
                    }
                }
            }
            .overlay {
                if upcoming.isEmpty {
                    ContentUnavailableView("Nothing in the next 30 days", systemImage: "calendar",
                                           description: Text("Your calendar of check-ins is clear."))
                }
            }
            .navigationTitle("Next 30 days")
            .toolbar { ToolbarItem(placement: .primaryAction) { AddButton() } }
            .navigationDestination(for: Person.self) { PersonDetailView(person: $0) }
        }
    }

    private func header(_ iso: String, today: Day) -> String {
        guard let day = Day(iso) else { return iso }
        let date = day.date().formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        return "\(date) · \(Day.relative(today.days(until: day)))"
    }
}

struct PeopleView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Person.name) private var people: [Person]
    @State private var search = ""
    @State private var tier: Tier?
    @Environment(\.cadences) private var cadences

    var body: some View {
        let today = Day.today()
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let rows = people.filter { p in
            (tier == nil || p.tier == tier) &&
            (q.isEmpty || ([p.name, p.email, p.phone, p.city, p.notes] + p.tags).joined(separator: " ").lowercased().contains(q))
        }
        NavigationStack {
            List {
                ForEach(rows) { person in
                    NavigationLink(value: person) { PersonRow(person: person, today: today) }
                }
                .onDelete { offsets in offsets.map { rows[$0] }.forEach(context.delete) }
            }
            .overlay {
                if people.isEmpty {
                    ContentUnavailableView("No people yet", systemImage: "person.2",
                                           description: Text("Tap + to add people from your contacts."))
                } else if rows.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .searchable(text: $search, prompt: "Name, notes, place, tag")
            .navigationTitle("People")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Picker("How often", selection: $tier) {
                        Text("Everyone").tag(Tier?.none)
                        ForEach(Tier.allCases) { Text(cadences.title(for: $0)).tag(Tier?.some($0)) }
                    }
                }
                ToolbarItem(placement: .primaryAction) { AddButton() }
            }
            .navigationDestination(for: Person.self) { PersonDetailView(person: $0) }
        }
    }
}
