import CloudKit
import CoreData
import Foundation
import Observation
import SwiftData

/// Where people and check-ins are kept: on this device only, or on this device and in the
/// person's own iCloud account (their private CloudKit database), which syncs their devices.
enum Storage {
    /// Whether this launch opened the store with iCloud sync. Fixed until the app restarts.
    private(set) static var syncing = false

    /// Why the synced store couldn't be opened at launch, if it couldn't.
    private(set) static var failure: String?

    /// Asks iCloud itself whether this device has a usable account.
    static func accountStatus() async -> CKAccountStatus {
        do {
            let status = try await CKContainer.default().accountStatus()
            print("iCloud account status: \(status.rawValue)")
            return status
        } catch {
            print("iCloud account status failed: \(error)")
            return .couldNotDetermine
        }
    }

    static func makeContainer() -> ModelContainer {
        let schema = Schema([Person.self, CheckIn.self])
        let wanted = UserDefaults.standard.object(forKey: Keys.iCloudSync) as? Bool ?? true
        if wanted {
            do {
                let synced = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, cloudKitDatabase: .automatic))
                syncing = true
                return synced
            } catch {
                failure = String(describing: error)
                print("iCloud store failed to open: \(error)")
            }
        }
        // The same store file either way, so turning sync off or on never loses what's on the device.
        do {
            return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, cloudKitDatabase: .none))
        } catch {
            fatalError("Couldn't open the data store: \(error)")
        }
    }
}

/// Copies the settings that should match on every device (how often, weekly goal, country code)
/// to and from iCloud's key-value store. Reminder settings stay per device.
@MainActor
enum SettingsSync {
    private static let keys = [Keys.cadA, Keys.cadB, Keys.cadC, Keys.cadD, Keys.goal, Keys.countryCode]
    private static var started = false

    static func start() {
        guard Storage.syncing, !started else { return }
        started = true
        let center = NotificationCenter.default
        center.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                           object: NSUbiquitousKeyValueStore.default, queue: .main) { _ in
            MainActor.assumeIsolated { pull() }
        }
        center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { push() }
        }
        NSUbiquitousKeyValueStore.default.synchronize()
        // iCloud wins on first run, so a new device picks up the settings already in use.
        pull()
        push()
    }

    private static func pull() {
        for key in keys {
            guard let value = NSUbiquitousKeyValueStore.default.object(forKey: key) else { continue }
            if !same(value, UserDefaults.standard.object(forKey: key)) { UserDefaults.standard.set(value, forKey: key) }
        }
    }

    private static func push() {
        for key in keys {
            guard let value = UserDefaults.standard.object(forKey: key) else { continue }
            if !same(value, NSUbiquitousKeyValueStore.default.object(forKey: key)) {
                NSUbiquitousKeyValueStore.default.set(value, forKey: key)
            }
        }
    }

    private static func same(_ a: Any, _ b: Any?) -> Bool {
        guard let a = a as? NSObject, let b = b as? NSObject else { return false }
        return a == b
    }
}

/// Listens to what the sync engine reports, so Settings can show whether syncing really works.
@MainActor @Observable
final class SyncMonitor {
    static let shared = SyncMonitor()
    /// When data last went to or came from iCloud without an error.
    private(set) var lastSuccess: Date?
    /// The most recent error, cleared by the next success.
    private(set) var lastError: String?

    private var started = false

    func start() {
        guard Storage.syncing, !started else { return }
        started = true
        NotificationCenter.default.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification,
                                               object: nil, queue: .main) { note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event, event.endDate != nil else { return }
            let kind = ["setup", "import", "export"][min(event.type.rawValue, 2)]
            let error = event.error.map { String(describing: $0) }
            print("iCloud sync \(kind): \(error ?? "ok")")
            MainActor.assumeIsolated {
                if let error {
                    SyncMonitor.shared.lastError = "\(kind): \(error)"
                } else {
                    SyncMonitor.shared.lastError = nil
                    if kind != "setup" { SyncMonitor.shared.lastSuccess = event.endDate }
                }
            }
        }
    }
}
