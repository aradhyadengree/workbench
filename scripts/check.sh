#!/bin/sh
# The one pre-push gate: everything CI runs, in the same order.
#   ./scripts/check.sh
# 1. debug build with warnings surfaced  2. release .app bundle (icon, plist, signature)
# 3. invariants that a compile can't catch (see AGENTS.md → Landmines).
set -eu
cd "$(dirname "$0")/.."

echo "==> swift build (debug)"
swift build

echo "==> scripts/build-app.sh"
./scripts/build-app.sh >/dev/null

echo "==> invariants"
fail=0
# The chat terminal's xterm.js is vendored; its MIT notice must ship with it.
[ -f Sources/Workbench/ChatTerminal/LICENSE ] || { echo "missing xterm.js LICENSE"; fail=1; }
# Build products must never be committed.
if git rev-parse --git-dir >/dev/null 2>&1 && git ls-files --error-unmatch Workbench.app >/dev/null 2>&1; then
  echo "Workbench.app is tracked by git"; fail=1
fi
# Bypass permissions must stay opt-in per launch (never written to UserDefaults).
grep -q 'if permission != .bypass' Sources/Workbench/ClaudeAgentPane.swift \
  || { echo "agent pane persists bypass mode"; fail=1; }
codesign --verify Workbench.app || fail=1
[ "$fail" -eq 0 ] && echo "OK"
exit "$fail"
