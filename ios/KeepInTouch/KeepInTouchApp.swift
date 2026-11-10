import SwiftData
import SwiftUI
import KeepInTouchCore

@main
struct KeepInTouchApp: App {
    private let container: ModelContainer

    init() {
        // Before the store opens, so the first sync events aren't missed.
        container = Storage.makeContainer()
        SyncMonitor.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .task { SettingsSync.start() }
        }
        .modelContainer(container)
    }
}

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Query private var people: [Person]
    @AppStorage(Keys.reminderOn) private var reminderOn = false
    @AppStorage(Keys.reminderMinutes) private var reminderMinutes = Keys.defaultReminderMinutes
    @AppStorage(Keys.cadA) private var cadA = Cadences.standard.a
    @AppStorage(Keys.cadB) private var cadB = Cadences.standard.b
    @AppStorage(Keys.cadC) private var cadC = Cadences.standard.c
    @AppStorage(Keys.cadD) private var cadD = Cadences.standard.d

    var body: some View {
        let today = Day.today().iso
        TabView {
            Tab("Today", systemImage: "sun.max") { TodayView() }
                .badge(people.filter { $0.nextContact <= today }.count)
            Tab("Upcoming", systemImage: "calendar") { UpcomingView() }
            Tab("People", systemImage: "person.2") { PeopleView() }
            Tab("Settings", systemImage: "gearshape") { SettingsView() }
        }
        .environment(\.cadences, Cadences(a: cadA, b: cadB, c: cadC, d: cadD))
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
