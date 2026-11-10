import Contacts
import ContactsUI
import SwiftData
import SwiftUI
import KeepInTouchCore

/// Shows the system contact picker. It runs outside the app, so the app needs no Contacts
/// permission and only ever sees the people you pick. It has no search when picking several
/// people, so it's only offered inside `ContactSearchPicker` when the app can't read all of Contacts.
@MainActor
final class ContactPicker: NSObject, CNContactPickerDelegate {
    static let shared = ContactPicker()
    private var onPick: (([CNContact]) -> Void)?

    /// Asks for Contacts access the first time, then reports where it stands.
    static func contactsAccess() async -> CNAuthorizationStatus {
        if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
            _ = try? await CNContactStore().requestAccess(for: .contacts)
        }
        return CNContactStore.authorizationStatus(for: .contacts)
    }

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

/// The app's own contact list: search, tick several people, then Add.
struct ContactSearchPicker: View {
    let onDone: ([CNContact]) -> Void
    /// Called when the person would rather use Apple's picker, which needs no permission.
    let onUseSystemPicker: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var access: CNAuthorizationStatus = .notDetermined
    @State private var entries: [Entry] = []
    @State private var selected: Set<String> = []
    @State private var query = ""
    @State private var loading = true

    struct Entry: Identifiable, @unchecked Sendable {
        let id: String
        let name: String, detail: String
        let contact: CNContact
    }

    private var shown: [Entry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.detail.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            List(shown) { entry in
                let isOn = selected.contains(entry.id)
                Button {
                    if isOn { selected.remove(entry.id) } else { selected.insert(entry.id) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                            .imageScale(.large)
                            .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name).foregroundStyle(.primary)
                            if !entry.detail.isEmpty {
                                Text(entry.detail).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
            .listStyle(.plain)
            .safeAreaInset(edge: .top) {
                if access == .limited && !loading {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Been a While can only see the contacts you shared with it.")
                            .font(.subheadline)
                        HStack(spacing: 16) {
                            Button("Allow all in Settings") { openSettings() }
                            Button("Use Apple's list") { useSystemPicker() }
                        }
                        .font(.subheadline.weight(.medium))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal).padding(.vertical, 10)
                    .background(.bar)
                }
            }
            // The toolbar is hidden while the search field is active, so Add also sits here.
            .safeAreaInset(edge: .bottom) {
                if !selected.isEmpty {
                    Button(selected.count == 1 ? "Add 1 person" : "Add \(selected.count) people") { finish() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(.bar)
                }
            }
            .overlay {
                if loading {
                    ProgressView()
                } else if access == .denied || access == .restricted {
                    ContentUnavailableView {
                        Label("Search needs your contacts", systemImage: "person.crop.circle.badge.questionmark")
                    } description: {
                        Text("Been a While isn't allowed to read Contacts, so it can't search them. Turn on Contacts for Been a While in Settings, or pick from Apple's list, which has no search.")
                    } actions: {
                        Button("Open Settings") { openSettings() }.buttonStyle(.borderedProminent)
                        Button("Use Apple's list") { useSystemPicker() }
                    }
                } else if entries.isEmpty {
                    ContentUnavailableView("No contacts", systemImage: "person.crop.circle")
                } else if shown.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search contacts")
            .autocorrectionDisabled()
            .navigationTitle(selected.isEmpty ? "Contacts" : "\(selected.count) selected")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { finish() }.disabled(selected.isEmpty)
                }
            }
            .task {
                access = await ContactPicker.contactsAccess()
                if access == .authorized || access == .limited { entries = await Self.load() }
                loading = false
            }
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }

    private func useSystemPicker() {
        dismiss()
        onUseSystemPicker()
    }

    private func finish() {
        onDone(entries.filter { selected.contains($0.id) }.map(\.contact))
        dismiss()
    }

    private static func load() async -> [Entry] {
        await Task.detached(priority: .userInitiated) {
            let keys: [CNKeyDescriptor] = [
                CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                CNContactOrganizationNameKey as CNKeyDescriptor,
                CNContactEmailAddressesKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor,
                CNContactPostalAddressesKey as CNKeyDescriptor,
            ]
            var out: [Entry] = []
            try? CNContactStore().enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { c, _ in
                let email = c.emailAddresses.first.map { $0.value as String } ?? ""
                let phone = c.phoneNumbers.first?.value.stringValue ?? ""
                let name = CNContactFormatter.string(from: c, style: .fullName)
                    ?? [c.organizationName, email, phone].first { !$0.isEmpty } ?? ""
                guard !name.isEmpty else { return }
                let detail = [c.organizationName, phone, email].first { !$0.isEmpty && $0 != name } ?? ""
                out.append(Entry(id: c.identifier, name: name, detail: detail, contact: c))
            }
            return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }.value
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
