#if os(macOS)
import AppKit
import SwiftData
import SwiftUI
import KeepInTouchCore

/// The icon in the Mac menu bar, with the number of people due beside it.
struct MenuBarLabel: View {
    @Query private var people: [Person]

    var body: some View {
        let due = people.filter { $0.nextContact <= Day.today().iso }.count
        Image(systemName: "person.2.fill")
        if due > 0 { Text("\(due)") }
    }
}

/// The panel under the menu bar icon: who's due, with the same actions as the Today list.
struct MenuBarView: View {
    @Query private var people: [Person]
    @Environment(\.modelContext) private var context
    @Environment(\.openWindow) private var openWindow
    /// The way each person was last reached from this panel, used when "Checked in" is pressed.
    @State private var channels: [PersistentIdentifier: String] = [:]

    var body: some View {
        let today = Day.today()
        let due = people.filter { $0.nextContact <= today.iso }.byTierThenDue()
        VStack(alignment: .leading, spacing: 0) {
            Text(due.isEmpty ? "All caught up" : "\(due.count) due to contact")
                .font(.headline)
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            if due.isEmpty {
                Text(nextUp(today: today))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.bottom, 12)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(due) { person in row(person, today: today) }
                    }
                    .padding(.horizontal, 10).padding(.bottom, 10)
                }
                .frame(maxHeight: 440)
            }
            Divider()
            HStack {
                Button("Open Been a While") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .padding(10)
        }
        .frame(width: 340)
        .environment(\.cadences, Keys.cadences())
    }

    private func row(_ person: Person, today: Day) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TierBadge(tier: person.tier)
                Text(person.name).font(.body.weight(.semibold)).lineLimit(1)
                Spacer()
                Text(dueText(person, today: today))
                    .font(.footnote)
                    .foregroundStyle(person.nextDay < today ? Color.accentColor : .secondary)
            }
            ReachOutRow(person: person) { channels[person.persistentModelID] = $0 }
            HStack(spacing: 8) {
                Button("Checked in", systemImage: "checkmark") {
                    person.logCheckIn(channel: channels[person.persistentModelID] ?? "Message", note: "", context: context)
                }
                .buttonStyle(.borderedProminent)
                Button("Snooze a week") { person.snooze(days: 7) }
            }
            .font(.subheadline)
        }
        .padding(10)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 10))
    }

    private func nextUp(today: Day) -> String {
        guard let next = people.min(by: { $0.nextContact < $1.nextContact }) else {
            return "No one here yet. Open Been a While to add people."
        }
        return "Next up: \(next.name), \(Day.relative(today.days(until: next.nextDay)))."
    }
}
#endif
