# Keep in Touch: notes for Claude Code

Read `HANDOFF.md` for history, architecture, data model, gotchas and open items.

## Ground rules for this repo

- **Plain stack:** vanilla HTML/CSS/JS, no framework, no build step, no runtime dependencies. Keep it that way unless asked.
- **Storage:** everything is on-device via `store.js` (IndexedDB). Don't add a server or third-party service without asking.
- **Every release:** bump `APP_VERSION` in `index.html` **and** `VERSION` in `sw.js` together. That's how installed copies pick up the update and how the user confirms which build is running.
- **Tests:** run `npm test` before pushing (it starts `tests/serve.py`, which mimics Cloudflare Pages' `/index.html` → `/` redirect). Add a Playwright test for any bug fixed from real-device feedback.
- **Deploy:** push to `main`, and Cloudflare Pages auto-deploys to https://keep-in-touch-d58.pages.dev/
- **Shell vs. page:** the service worker serves the shell for navigations under the key `./`, never `./index.html`. A redirected response can't answer a navigation.
- **DOM:** build it with the `h()` helper (it sets text with textContent). Don't use `innerHTML` with user data.
