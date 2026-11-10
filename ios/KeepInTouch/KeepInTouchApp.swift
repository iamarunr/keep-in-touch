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
        #if os(macOS)
        Window("Been a While", id: "main") {
            RootView()
                .formStyle(.grouped)
                .task { SettingsSync.start() }
        }
        .defaultSize(width: 480, height: 760)
        .modelContainer(container)

        MenuBarExtra {
            MenuBarView().modelContainer(container)
        } label: {
            MenuBarLabel().modelContainer(container)
        }
        .menuBarExtraStyle(.window)
        #else
        WindowGroup {
            RootView()
                .task { SettingsSync.start() }
        }
        .modelContainer(container)
        #endif
    }
}

enum AppTab: Hashable { case today, upcoming, people, settings }

struct RootView: View {
    @State private var tab = AppTab.today
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
        TabView(selection: $tab) {
            Tab("Today", systemImage: "sun.max", value: AppTab.today) { TodayView() }
                .badge(people.filter { $0.nextContact <= today }.count)
            Tab("Upcoming", systemImage: "calendar", value: AppTab.upcoming) { UpcomingView() }
            Tab("People", systemImage: "person.2", value: AppTab.people) { PeopleView() }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) { SettingsView() }
        }
        .environment(\.currentTab, $tab)
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
