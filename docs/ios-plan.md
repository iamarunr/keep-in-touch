# Been a While (Keep in Touch for iOS): plan

Status: **the core loop runs on a phone.** Written 2026-11-09, updated 2026-11-10.

The iOS app is called **Been a While**. The folder, Xcode project, Swift package and bundle ID keep the KeepInTouch name, and the web app is still Keep in Touch. Read `HANDOFF.md` for how the project got here.

## Why native

The web app can't do the three things that matter most on an iPhone:

| Want | Web app on iPhone | Native app |
|---|---|---|
| Use the contacts already on the phone | Export a vCard and upload it; a one-time copy | Pick people straight from Contacts |
| A reminder when someone is due | Not possible without a server | Local notifications, no server |
| Reach out in one tap | "Copy" buttons only | Opens Messages, WhatsApp or Mail with the person filled in |

The web app stays live and unchanged at its current address. It's still the version for Android and for anyone without a Mac to build with.

## What carries over from the web app

- The method: four groups with check-ins every 21, 60, 182 and 365 days, all adjustable. The code still calls them tiers A to D; the app shows the frequency ("Every 3 weeks") and never the letter.
- The rules: a check-in sets the next date from the tier; a tier change recalculates from the last check-in, never earlier than today; new people either start today or have their first reminder scattered across their interval ("Start today", on by default for one or two people).
- The data model, including dates as `YYYY-MM-DD` strings, which sort correctly and don't shift with time zones.
- The JSON backup format (`{app, format: 1, settings, contacts}`), so the iOS app can import a web backup.

What doesn't: the service worker, the install button, the share target, the preview banner, and `docs/sync-plan.md` (see Sync below).

## Layout

```
ios/
  KeepInTouch.xcodeproj     hand-written, uses Xcode's folder-synced groups: new files in KeepInTouch/ are picked up automatically
  Config.xcconfig           committed defaults (placeholder bundle ID, no team)
  Local.xcconfig            yours, gitignored: DEVELOPMENT_TEAM and PRODUCT_BUNDLE_IDENTIFIER
  KeepInTouch/              the SwiftUI app
  KeepInTouchCore/          Swift package: tiers, dates, scheduling, reach-out links, web-backup decoding. No UI.
                            Tested with `swift test`, which runs on the Mac in seconds with no simulator.
```

- **UI:** SwiftUI, iOS 18 or later. Tabs: Today, Upcoming, People, Settings.
- **Storage:** SwiftData (`Person`, `CheckIn`). The models already follow CloudKit's rules (every property has a default, relationships are optional, no unique constraints), so turning on iCloud sync later needs no data migration.
- **No third-party dependencies**, matching the web app's rule.

## Slices

1. **Core loop (done).**
   - Add people from a searchable contact list or by hand. The list needs Contacts permission (asked on first use); if it's declined, the list explains why and offers Settings or Apple's picker, which needs no permission but has no search when picking several people. With limited access the list shows only the shared contacts, with the same two options.
   - Today and Upcoming lists, People with search.
   - Log a check-in, snooze a week, change how often, edit, delete.
   - Message, WhatsApp, Email and Call buttons; after one is tapped, the check-in sheet is waiting when you come back.
   - A daily reminder at a time you choose, listing who's due, with the app badge showing the count.
   - Import a backup from the web app.
2. **Run on your phone (done for one phone, by cable).** Set your team and a bundle ID in `Local.xcconfig`, plug in the phone, build. Then TestFlight if you want it on other devices without a cable.
3. **iCloud sync (working between an iPhone and a Mac).** `Storage.makeContainer()` in `Sync.swift` opens the store with `cloudKitDatabase: .automatic` when the Settings switch is on and the device is signed in to iCloud, and falls back to the same store without CloudKit otherwise. The container is `iCloud.<bundle ID>`, set in `ios/KeepInTouch.entitlements`. `SettingsSync` mirrors the how-often settings, weekly goal and country code through iCloud key-value storage; reminder settings stay per device. Still to check: that people already on the phone upload on first sync, and that a second device receives them. The CloudKit schema is created in the development environment on first run; it has to be deployed to production in the CloudKit console before any TestFlight or App Store build.
3a. **Mac version with a menu bar item (working; people added on the phone appear on the Mac).** The same target builds for macOS 15 (`SUPPORTED_PLATFORMS` includes `macosx`, entitlements in `ios/KeepInTouchMac.entitlements`). `Platform.swift` holds the few iPhone/Mac differences; `MenuBar.swift` is the menu bar icon with the due count and a panel listing who's due, with reach-out, Checked in and Snooze buttons. The Mac uses the same bundle ID, so it shares the phone's iCloud container. Not done: a Mac-shaped layout (it's the phone layout in a window), open at login, and a way to install it outside a development build.
4. **Stay linked to Contacts.** Today the picker copies name, phone, email and city at the moment you pick. The app now asks for Contacts permission for the searchable list, so it can refresh those fields when a contact changes. The contact's identifier is already saved for this. Note that the identifier can differ between devices, so matching needs a fallback on phone or email.
5. **Nicer reminders.** Notification actions (Message, Snooze) and a Home Screen widget showing who's due.
6. **Backup and export** from the iOS app (JSON in the same format, plus CSV).
7. **Publish.** MIT license (already decided), README section on building the iOS app, optionally the App Store. An app called "Been a While - Remember time" is already on the App Store (checked 2026-11-10), so a listing would need a distinguishing name such as "Been a While: Keep in Touch".

## Sync

`docs/sync-plan.md` planned a Cloudflare D1 server with a passphrase. For the iOS app, **iCloud replaces it**: the data syncs through your own iCloud account between iPhone, iPad and Mac, with no server to run and nothing for you to host for anyone else. Every user's data stays in their own iCloud.

The D1 plan is only worth building if the web app needs sync too (Android or Windows). It's shelved, not deleted.

## Look

- **Icon:** two people inside a returning arrow, on black. Source drawing in `ios/design/icon.svg`; there is a greyscale copy for the tinted Home Screen style.
- **Accent:** the purple of the icon's second person, darker in light mode and lighter in dark mode.

## Limits to know

- **Check-ins are logged by you.** iOS doesn't let apps read message history. Messages reports back when you send from the in-app sheet (a possible later improvement); WhatsApp and Mail don't.
- **WhatsApp needs a country code.** Numbers saved without one get the default code from Settings.
- **Local reminders are scheduled ahead** for the next 14 days and refreshed every time the app opens or data changes. If the app isn't opened for two weeks, reminders stop until it is.
- **Apple only.** iCloud sync doesn't reach Android or Windows.

## Running it

```bash
cd ios/KeepInTouchCore && swift test           # logic tests
open ios/KeepInTouch.xcodeproj                 # then Run in Xcode
```
