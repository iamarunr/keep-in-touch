import SwiftData
import SwiftUI
import KeepInTouchCore

@main
struct KeepInTouchApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(for: [Person.self, CheckIn.self])
    }
}

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Query private var people: [Person]
    @AppStorage(Keys.reminderOn) private var reminderOn = false
    @AppStorage(Keys.reminderMinutes) private var reminderMinutes = Keys.defaultReminderMinutes

    var body: some View {
        let today = Day.today().iso
        TabView {
            Tab("Today", systemImage: "sun.max") { TodayView() }
                .badge(people.filter { $0.nextContact <= today }.count)
            Tab("Upcoming", systemImage: "calendar") { UpcomingView() }
            Tab("People", systemImage: "person.2") { PeopleView() }
            Tab("Settings", systemImage: "gearshape") { SettingsView() }
        }
        .task(id: refreshKey) {
            #if DEBUG
            DemoData.seedIfAsked(context: context, existing: people)
            #endif
            await Reminders.refresh(people: people)
        }
    }

    // Reminders are rebuilt whenever anything they depend on changes, and each time the app comes forward.
    private var refreshKey: [String] {
        people.map { $0.name + $0.tierRaw + $0.nextContact }.sorted()
            + ["\(reminderOn)", "\(reminderMinutes)", "\(scenePhase == .active)"]
    }
}
