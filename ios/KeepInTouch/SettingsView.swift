import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import KeepInTouchCore

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Query private var people: [Person]
    @AppStorage(Keys.reminderOn) private var reminderOn = false
    @AppStorage(Keys.reminderMinutes) private var reminderMinutes = Keys.defaultReminderMinutes
    @AppStorage(Keys.cadA) private var cadA = Cadences.standard.a
    @AppStorage(Keys.cadB) private var cadB = Cadences.standard.b
    @AppStorage(Keys.cadC) private var cadC = Cadences.standard.c
    @AppStorage(Keys.cadD) private var cadD = Cadences.standard.d
    @AppStorage(Keys.goal) private var goal = Keys.defaultGoal
    @AppStorage(Keys.countryCode) private var countryCode = "1"
    @State private var importing = false
    @State private var message: String?
    @State private var remindersBlocked = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Daily reminder", isOn: $reminderOn)
                        .onChange(of: reminderOn) { _, on in
                            guard on else { return }
                            Task {
                                if await Reminders.requestPermission() { return }
                                reminderOn = false
                                remindersBlocked = true
                            }
                        }
                    if reminderOn {
                        DatePicker("Time", selection: reminderTime, displayedComponents: .hourAndMinute)
                    }
                } header: {
                    Text("Reminders")
                } footer: {
                    Text(remindersBlocked
                         ? "Notifications are turned off for Keep in Touch. Turn them on in the Settings app, then try again."
                         : "A notification on days when someone is due, listing who.")
                }

                Section {
                    cadence(.a, $cadA)
                    cadence(.b, $cadB)
                    cadence(.c, $cadC)
                    cadence(.d, $cadD)
                } header: {
                    Text("Check in every")
                } footer: {
                    Text("Changes apply from each person's next check-in.")
                }

                Section {
                    Stepper("Meet \(goal) new \(goal == 1 ? "person" : "people") a week", value: $goal, in: 1...20)
                }

                Section {
                    LabeledContent("Default country code") {
                        TextField("1", text: $countryCode).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("WhatsApp")
                } footer: {
                    Text("Used for phone numbers saved without a country code. Digits only, for example 1 for the US or 44 for the UK.")
                }

                Section {
                    Button("Import a web app backup", systemImage: "square.and.arrow.down") { importing = true }
                } header: {
                    Text("Move from the web app")
                } footer: {
                    Text(message ?? "In the web app, go to Settings → Download backup, then choose that file here. People already in this app are left as they are.")
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                    Link("The method: Derek Sivers on staying in touch", destination: URL(string: "https://sive.rs/hundreds")!)
                }
            }
            .navigationTitle("Settings")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                message = importBackup(result)
            }
        }
    }

    private func cadence(_ tier: Tier, _ days: Binding<Int>) -> some View {
        Stepper(value: days, in: 1...730) {
            HStack {
                TierBadge(tier: tier)
                VStack(alignment: .leading) {
                    Text(tier.label)
                    Text("\(days.wrappedValue) days").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var reminderTime: Binding<Date> {
        Binding {
            Calendar.current.date(byAdding: .minute, value: reminderMinutes, to: Calendar.current.startOfDay(for: Date())) ?? Date()
        } set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            reminderMinutes = (c.hour ?? 9) * 60 + (c.minute ?? 0)
        }
    }

    private func importBackup(_ result: Result<URL, Error>) -> String {
        guard case .success(let url) = result else { return "Couldn't open that file." }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let backup = try? WebBackup(data: data) else {
            return "That file isn't a Keep in Touch backup."
        }
        let (added, skipped) = WebImport.run(backup, into: context, existing: people)
        let skippedText = skipped > 0 ? " \(skipped) already here, left as they are." : ""
        return "Imported \(added) \(added == 1 ? "person" : "people").\(skippedText)"
    }
}

enum WebImport {
    /// Adds everyone in the backup who isn't here yet. Returns how many were added and skipped.
    @MainActor
    static func run(_ backup: WebBackup, into context: ModelContext, existing: [Person]) -> (added: Int, skipped: Int) {
        // On a fresh install, take the web app's cadences and goal too.
        if existing.isEmpty {
            if let c = backup.cadences { Keys.set(c) }
            if let g = backup.goal { UserDefaults.standard.set(g, forKey: Keys.goal) }
        }
        let today = Day.today(), cadences = Keys.cadences()
        var known = existing
        var added = 0
        for c in backup.contacts where known.firstMatching(email: c.email, name: c.name) == nil {
            let person = Person(
                name: c.name, tier: c.tier, email: c.email, phone: c.phone, city: c.city, tags: c.tags, notes: c.notes,
                lastContact: c.lastContact,
                nextContact: c.nextContact ?? Schedule.next(lastContact: c.lastContact, tier: c.tier, cadences: cadences, today: today),
                metOn: c.metOn)
            context.insert(person)
            for e in c.log {
                let entry = CheckIn(date: e.date, channel: e.channel, note: e.note)
                context.insert(entry)
                entry.person = person
            }
            known.append(person)
            added += 1
        }
        return (added, backup.contacts.count - added)
    }
}
