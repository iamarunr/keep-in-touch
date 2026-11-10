import Contacts
import ContactsUI
import SwiftData
import SwiftUI
import KeepInTouchCore

/// Shows the system contact picker. It runs outside the app, so the app needs no Contacts
/// permission and only ever sees the people you pick.
@MainActor
final class ContactPicker: NSObject, CNContactPickerDelegate {
    static let shared = ContactPicker()
    private var onPick: (([CNContact]) -> Void)?

    func present(onPick: @escaping ([CNContact]) -> Void) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard var top = scene?.keyWindow?.rootViewController else { return }
        while let next = top.presentedViewController { top = next }
        self.onPick = onPick
        let picker = CNContactPickerViewController()
        picker.delegate = self
        top.present(picker, animated: true)
    }

    // Implementing the plural method is what makes the picker multi-select.
    nonisolated func contactPicker(_ picker: CNContactPickerViewController, didSelect contacts: [CNContact]) {
        MainActor.assumeIsolated {
            onPick?(contacts)
            onPick = nil
        }
    }

    nonisolated func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
        MainActor.assumeIsolated { onPick = nil }
    }
}

struct PickedBatch: Identifiable {
    struct Row: Identifiable {
        let id: String
        var name: String, email: String, phone: String, city: String
    }

    let id = UUID()
    let rows: [Row]

    init(contacts: [CNContact]) {
        rows = contacts.compactMap { c in
            let email = c.emailAddresses.first.map { $0.value as String } ?? ""
            let phone = c.phoneNumbers.first?.value.stringValue ?? ""
            let name = CNContactFormatter.string(from: c, style: .fullName)
                ?? [c.organizationName, email, phone].first { !$0.isEmpty } ?? ""
            guard !name.isEmpty else { return nil }
            return Row(id: c.identifier, name: name, email: email, phone: phone,
                       city: c.postalAddresses.first?.value.city ?? "")
        }
    }
}

/// After the picker: choose a tier for each person, then add them.
struct AddPickedView: View {
    let batch: PickedBatch
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var people: [Person]
    @State private var tiers: [String: Tier] = [:]
    @Environment(\.cadences) private var cadences
    /// Off scatters first reminders across each person's interval, which suits a big batch.
    @State private var startToday: Bool

    init(batch: PickedBatch) {
        self.batch = batch
        _startToday = State(initialValue: batch.rows.count <= 2)
    }

    private var fresh: [PickedBatch.Row] {
        batch.rows.filter { people.firstMatching(email: $0.email, name: $0.name, contactIdentifier: $0.id) == nil }
    }

    var body: some View {
        let new = fresh
        let already = batch.rows.count - new.count
        NavigationStack {
            Form {
                if new.isEmpty {
                    Text("Everyone you picked is already in Been a While.").foregroundStyle(.secondary)
                } else {
                    Section {
                        ForEach(new) { row in
                            Picker(row.name, selection: Binding(get: { tiers[row.id] ?? .c }, set: { tiers[row.id] = $0 })) {
                                FrequencyOptions()
                            }
                        }
                    } header: {
                        Text("How often to check in")
                    } footer: {
                        if already > 0 { Text("\(already) already added, so \(already == 1 ? "it's" : "they're") left out.") }
                    }
                    Section {
                        if new.count > 1 {
                            Menu("Set everyone to") {
                                ForEach(Tier.allCases) { tier in
                                    Button(cadences.title(for: tier)) { for row in new { tiers[row.id] = tier } }
                                }
                            }
                        }
                        Toggle("Start today", isOn: $startToday)
                    } footer: {
                        Text(startToday
                             ? (new.count == 1 ? "\(new[0].name) goes on your Today list right away."
                                               : "Everyone goes on your Today list right away.")
                             : "First reminders are scattered over the coming weeks and months, so they don't all arrive at once.")
                    }
                }
            }
            .navigationTitle(new.count == 1 ? "Add 1 person" : "Add \(new.count) people")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add(new); dismiss() }.disabled(new.isEmpty)
                }
            }
        }
    }

    private func add(_ rows: [PickedBatch.Row]) {
        let today = Day.today(), cadences = Keys.cadences()
        var rng = SystemRandomNumberGenerator()
        for row in rows {
            let tier = tiers[row.id] ?? .c
            let next = startToday ? today : Schedule.spread(tier: tier, cadences: cadences, today: today, using: &rng)
            context.insert(Person(name: row.name, tier: tier, email: row.email, phone: row.phone, city: row.city,
                                  nextContact: next, contactIdentifier: row.id))
        }
    }
}

struct AddPersonView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var tier = Tier.b
    @State private var email = ""
    @State private var phone = ""
    @State private var city = ""
    @State private var tags = ""
    @State private var notes = ""
    @State private var talkedBefore = true
    @State private var lastTalked = Date()
    @State private var isNew = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Full name", text: $name).textContentType(.name)
                    Picker("Check in", selection: $tier) {
                        FrequencyOptions()
                    }
                }
                Section {
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Phone", text: $phone).keyboardType(.phonePad)
                    TextField("City or place", text: $city)
                    TextField("Tags, comma separated", text: $tags).textInputAutocapitalization(.never)
                    TextField("Notes: how you met, what they care about", text: $notes, axis: .vertical).lineLimit(3...6)
                }
                Section {
                    Toggle("We've talked before", isOn: $talkedBefore)
                    if talkedBefore {
                        DatePicker("Last talked", selection: $lastTalked, in: ...Date(), displayedComponents: .date)
                    }
                    Toggle("New person", isOn: $isNew)
                } footer: {
                    Text(talkedBefore ? "New people count toward this week's goal of meeting new people."
                                      : "They'll go on today's list.")
                }
            }
            .navigationTitle("Add someone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { save(); dismiss() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        let today = Day.today()
        let last = talkedBefore ? Day(lastTalked) : nil
        let person = Person(
            name: name.trimmingCharacters(in: .whitespaces), tier: tier,
            email: email.trimmingCharacters(in: .whitespaces), phone: phone.trimmingCharacters(in: .whitespaces),
            city: city.trimmingCharacters(in: .whitespaces), tags: splitTags(tags),
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines), lastContact: last,
            nextContact: Schedule.next(lastContact: last, tier: tier, cadences: Keys.cadences(), today: today),
            metOn: isNew ? today : nil)
        context.insert(person)
        if let last {
            let entry = CheckIn(date: last, channel: isNew ? "In person" : "Other", note: isNew ? "First met" : "")
            context.insert(entry)
            entry.person = person
        }
    }
}
