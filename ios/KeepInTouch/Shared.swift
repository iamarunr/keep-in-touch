import Contacts
import SwiftUI
import KeepInTouchCore

extension Tier {
    var color: Color {
        switch self {
        case .a: Color(red: 0.71, green: 0.28, blue: 0.11)
        case .b: Color(red: 0.72, green: 0.48, blue: 0.04)
        case .c: Color(red: 0.18, green: 0.49, blue: 0.45)
        case .d: Color(red: 0.47, green: 0.44, blue: 0.40)
        }
    }
}

extension EnvironmentValues {
    /// The current check-in frequencies, set at the root from Settings so every label stays up to date.
    @Entry var cadences = Cadences.standard
}

extension EnvironmentValues {
    /// The selected tab, so a screen can switch to another one. Set by `RootView`.
    @Entry var currentTab: Binding<AppTab> = .constant(.today)
}

struct TierBadge: View {
    let tier: Tier
    @Environment(\.cadences) private var cadences

    var body: some View {
        Text(cadences.short(for: tier))
            .font(.caption.weight(.semibold))
            .lineLimit(1).minimumScaleFactor(0.7)
            .foregroundStyle(.white)
            .frame(width: 38, height: 26)
            .background(tier.color, in: RoundedRectangle(cornerRadius: 7))
            .accessibilityLabel(cadences.title(for: tier))
    }
}

/// "due today", "3 days overdue", "in 2 weeks".
func dueText(_ person: Person, today: Day) -> String {
    let n = today.days(until: person.nextDay)
    if n == 0 { return "due today" }
    if n < 0 { return "\(-n) \(n == -1 ? "day" : "days") overdue" }
    return Day.relative(n)
}

struct PersonRow: View {
    let person: Person
    let today: Day

    var body: some View {
        HStack(spacing: 12) {
            TierBadge(tier: person.tier)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name).font(.body.weight(.semibold))
                let sub = ([person.city] + person.tags).filter { !$0.isEmpty }.joined(separator: " · ")
                if !sub.isEmpty { Text(sub).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            Text(dueText(person, today: today))
                .font(.footnote)
                .foregroundStyle(person.nextDay < today ? Color.accentColor : .secondary)
        }
    }
}

/// Buttons that open Messages, WhatsApp, Mail or Phone with this person filled in.
/// `onOpened` gets the channel, so the caller can offer to log the check-in.
struct ReachOutRow: View {
    let person: Person
    var onOpened: (String) -> Void

    @Environment(\.openURL) private var openURL
    @AppStorage(Keys.countryCode) private var countryCode = "1"

    private struct Link: Identifiable {
        let id: String, icon: String, channel: String, url: URL
    }

    private var links: [Link] {
        var out: [Link] = []
        if let u = ReachOut.message(phone: person.phone) { out.append(Link(id: "Message", icon: "message.fill", channel: "Message", url: u)) }
        if let u = ReachOut.whatsApp(phone: person.phone, defaultCountryCode: countryCode) {
            out.append(Link(id: "WhatsApp", icon: "bubble.left.and.bubble.right.fill", channel: "WhatsApp", url: u))
        }
        if let u = ReachOut.email(person.email) { out.append(Link(id: "Email", icon: "envelope.fill", channel: "Email", url: u)) }
        if let u = ReachOut.call(phone: person.phone) { out.append(Link(id: "Call", icon: "phone.fill", channel: "Call", url: u)) }
        return out
    }

    var body: some View {
        if links.isEmpty {
            Text("Add a phone number or email to reach out from here.")
                .font(.footnote).foregroundStyle(.secondary)
        } else {
            HStack(spacing: 8) {
                ForEach(links) { link in
                    Button {
                        openURL(link.url)
                        onOpened(link.channel)
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: link.icon)
                            Text(link.id).font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("\(link.id) \(person.name)")
                }
            }
        }
    }
}

struct CheckInDraft: Identifiable {
    let id = UUID()
    let person: Person
    var channel: String
}

/// The choices in every "how often" picker.
struct FrequencyOptions: View {
    @Environment(\.cadences) private var cadences

    var body: some View {
        ForEach(Tier.allCases) { Text(cadences.title(for: $0)).tag($0) }
    }
}

/// The "+" in each tab's toolbar.
struct AddButton: View {
    @State private var addingByHand = false
    @State private var picked: PickedBatch?
    @State private var searching = false

    var body: some View {
        Menu {
            Button("From Contacts", systemImage: "person.crop.circle.badge.plus") {
                searching = true
            }
            Button("Add by hand", systemImage: "square.and.pencil") { addingByHand = true }
        } label: {
            Image(systemName: "plus")
        }
        .accessibilityLabel("Add people")
        .sheet(isPresented: $addingByHand) { AddPersonView().sheetSize() }
        .sheet(isPresented: $searching) {
            ContactSearchPicker { show($0) } onUseSystemPicker: {
                #if os(iOS)
                // Wait for this sheet to finish closing before Apple's picker opens.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    ContactPicker.shared.present { show($0) }
                }
                #endif
            }
            .sheetSize()
        }
        .sheet(item: $picked) { AddPickedView(batch: $0).sheetSize() }
    }

    private func show(_ contacts: [CNContact]) {
        guard !contacts.isEmpty else { return }
        // Wait for the picker to finish closing before showing the next sheet.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { picked = PickedBatch(contacts: contacts) }
    }
}
