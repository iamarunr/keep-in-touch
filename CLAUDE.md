# Keep in Touch: notes for Claude Code

Read `HANDOFF.md` for history, architecture, data model, gotchas and open items.

**Direction (2026-11-09):** the project is moving to a native iOS app in `ios/`; see `docs/ios-plan.md`. The web app stays live but is frozen unless asked. The "Ground rules" below apply to the web app.

## Ground rules for this repo

- **Plain stack:** vanilla HTML/CSS/JS, no framework, no build step, no runtime dependencies. Keep it that way unless asked.
- **Storage:** everything is on-device via `store.js` (IndexedDB). Don't add a server or third-party service without asking.
- **Every release:** bump `APP_VERSION` in `index.html` **and** `VERSION` in `sw.js` together. That's how installed copies pick up the update and how the user confirms which build is running.
- **Tests:** run `npm test` before pushing (it starts `tests/serve.py`, which mimics Cloudflare Pages' `/index.html` → `/` redirect). Add a Playwright test for any bug fixed from real-device feedback.
- **Deploy:** push to `main`, and Cloudflare Pages auto-deploys to https://keep-in-touch-d58.pages.dev/
- **Shell vs. page:** the service worker serves the shell for navigations under the key `./`, never `./index.html`. A redirected response can't answer a navigation.
- **DOM:** build it with the `h()` helper (it sets text with textContent). Don't use `innerHTML` with user data.

## iOS app (`ios/`)

- **Stack:** SwiftUI + SwiftData, iOS 18+, no third-party dependencies. Logic with no UI lives in the `KeepInTouchCore` Swift package.
- **Tests:** `cd ios/KeepInTouchCore && swift test` (runs on the Mac, no simulator). Add a test for any rule you change in the package.
- **Project file:** `KeepInTouch.xcodeproj` uses folder-synced groups, so new files in `ios/KeepInTouch/` need no project edits.
- **Models stay CloudKit-ready:** every property has a default, relationships are optional, no unique constraints.
- **Personal values** (team ID, bundle ID) go in `ios/Local.xcconfig`, which is gitignored. Never put them in the project file.
- **Dates** are `YYYY-MM-DD` strings via `Day`, the same as the web app's backup format.
