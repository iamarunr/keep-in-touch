#!/usr/bin/env bash
# Runs every end-to-end test against a local server that behaves like Cloudflare Pages.
# Needs: python3, node, and Playwright with Chromium (npm install && npx playwright install chromium).
set -euo pipefail
cd "$(dirname "$0")"
python3 serve.py & SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT
sleep 1
for t in e2e install-button iphone-import update; do
  echo "== $t"
  node "$t.test.js"
done
