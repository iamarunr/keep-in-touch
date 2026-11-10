import SwiftData
import SwiftUI
import KeepInTouchCore

struct TodayView: View {
    @Query private var people: [Person]
    @Query private var checkIns: [CheckIn]
    @AppStorage(Keys.goal) private var goal = Keys.defaultGoal
    @State private var draft: CheckInDraft?

    var body: some View {
        let today = Day.today()
        let weekAgo = today.adding(days: -6).iso
        let due = people.filter { $0.nextContact <= today.iso }.byTierThenDue()
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        Stat(value: "\(due.count)", label: "due now")
                        Stat(value: "\(checkIns.filter { $0.date >= weekAgo }.count)", label: "check-ins, last 7 days")
                        Stat(value: "\(people.filter { ($0.metOn ?? "") >= weekAgo }.count) / \(goal)", label: "new people this week")
                        Stat(value: "\(people.count)", label: "people")
                    }
                    Text("Due to contact").font(.title2.weight(.semibold)).padding(.top, 6)
                    if people.isEmpty {
                        ContentUnavailableView("No one here yet", systemImage: "person.crop.circle.badge.plus",
                                               description: Text("Start with the people who matter most. Tap + to add them from your contacts."))
                    } else if due.isEmpty {
                        ContentUnavailableView("All caught up", systemImage: "checkmark.circle",
                                               description: Text(nextUp(today: today)))
                    } else {
                        ForEach(due) { person in
                            DueCard(person: person, today: today) { channel in
                                draft = CheckInDraft(person: person, channel: channel)
                            }
                        }
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Today")
            .toolbar { ToolbarItem(placement: .primaryAction) { AddButton() } }
            .navigationDestination(for: Person.self) { PersonDetailView(person: $0) }
            .sheet(item: $draft) { CheckInSheet(person: $0.person, channel: $0.channel) }
        }
    }

    private func nextUp(today: Day) -> String {
        guard let next = people.min(by: { $0.nextContact < $1.nextContact }) else { return "" }
        return "Next up: \(next.name), \(Day.relative(today.days(until: next.nextDay)))."
    }
}

private struct Stat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.weight(.semibold))
            Text(label).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}

struct DueCard: View {
    let person: Person
    let today: Day
    var onLog: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink(value: person) {
                HStack(spacing: 10) {
                    TierBadge(tier: person.tier)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(person.name).font(.headline).foregroundStyle(.primary)
                        if !person.city.isEmpty { Text(person.city).font(.footnote).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Text(dueText(person, today: today))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(person.nextDay < today ? Color.accentColor : .secondary)
                    Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            Text(lastLine).font(.footnote).foregroundStyle(.secondary)
            if !person.notes.isEmpty {
                Text(person.notes).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
            }

            ReachOutRow(person: person, onOpened: onLog)

            HStack(spacing: 8) {
                Button("Checked in", systemImage: "checkmark") { onLog("Message") }
                    .buttonStyle(.borderedProminent)
                Button("Snooze a week") { person.snooze(days: 7) }
                    .buttonStyle(.bordered)
            }
            .font(.subheadline)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var lastLine: String {
        if let last = person.history.first, let day = Day(last.date) {
            let note = last.note.isEmpty ? "" : " — “\(last.note)”"
            return "Last: \(Day.relative(today.days(until: day))) · \(last.channel)\(note)"
        }
        if let last = person.lastDay { return "Last talked \(Day.relative(today.days(until: last)))" }
        return "No check-ins logged yet"
    }
}

struct CheckInSheet: View {
    let person: Person
    @State var channel: String
    @State private var note = ""
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("How", selection: $channel) {
                        ForEach(Channel.all, id: \.self) { Text($0) }
                    }
                    TextField("How are they doing? Anything to follow up on?", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                } footer: {
                    let days = Keys.cadences().days(for: person.tier)
                    Text("Next check-in will be \(Day.relative(days)).")
                }
            }
            .navigationTitle(person.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Not yet") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        person.logCheckIn(channel: channel, note: note, context: context)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
