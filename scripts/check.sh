#!/bin/sh
# Full local gate before pushing: fast lint (same as CI) + debug build + .app bundle.
#   ./scripts/check.sh
# CI only runs scripts/lint.sh; the build steps need macOS + Xcode and run here.
set -eu
cd "$(dirname "$0")/.."

echo "==> lint"
./scripts/lint.sh

echo "==> swift build (debug)"
swift build

echo "==> scripts/build-app.sh"
./scripts/build-app.sh >/dev/null
codesign --verify Workbench.app
echo "check OK"
