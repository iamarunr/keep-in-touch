import SwiftData
import SwiftUI
import KeepInTouchCore

struct PersonDetailView: View {
    @Bindable var person: Person
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CheckInDraft?
    @State private var confirmingDelete = false
    @State private var tagsText = ""

    var body: some View {
        let today = Day.today()
        Form {
            Section {
                ReachOutRow(person: person) { draft = CheckInDraft(person: person, channel: $0) }
                LabeledContent("Next check-in", value: dueText(person, today: today))
                LabeledContent("Last talked", value: person.lastDay.map { Day.relative(today.days(until: $0)) } ?? "not yet")
                Button("Log a check-in", systemImage: "checkmark") { draft = CheckInDraft(person: person, channel: "Message") }
                Button("Snooze a week", systemImage: "moon.zzz") { person.snooze(days: 7) }
            }

            Section("Details") {
                TextField("Name", text: $person.name)
                Picker("Check in", selection: Binding(get: { person.tier }, set: { person.changeTier(to: $0) })) {
                    FrequencyOptions()
                }
                TextField("Email", text: $person.email)
                    .emailEntry()
                TextField("Phone", text: $person.phone).phoneEntry()
                TextField("City or place", text: $person.city)
                TextField("Tags, comma separated", text: $tagsText)
                    .noCapitals()
                    .onChange(of: tagsText) { person.tags = splitTags(tagsText) }
                TextField("Notes: how you met, what they care about", text: $person.notes, axis: .vertical)
                    .lineLimit(3...8)
            }

            Section("History") {
                if person.history.isEmpty {
                    Text("No check-ins logged yet").foregroundStyle(.secondary)
                }
                ForEach(person.history) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Day(entry.date).map { $0.date().formatted(date: .abbreviated, time: .omitted) } ?? entry.date) · \(entry.channel)")
                            .font(.subheadline.weight(.medium))
                        if !entry.note.isEmpty { Text(entry.note).font(.footnote).foregroundStyle(.secondary) }
                    }
                }
                .onDelete { offsets in
                    let entries = person.history
                    offsets.map { entries[$0] }.forEach(context.delete)
                }
            }

            Section {
                Button("Delete \(person.name)", role: .destructive) { confirmingDelete = true }
            }
        }
        .navigationTitle(person.name)
        .inlineTitle()
        .onAppear { tagsText = person.tags.joined(separator: ", ") }
        .sheet(item: $draft) { CheckInSheet(person: $0.person, channel: $0.channel) }
        .confirmationDialog("Delete \(person.name) and their check-in history?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                context.delete(person)
                dismiss()
            }
        }
    }
}

func splitTags(_ text: String) -> [String] {
    text.split(whereSeparator: { $0 == "," || $0 == ";" })
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}
