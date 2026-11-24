#!/bin/sh
# Builds Workbench.app from the Swift package and ad-hoc signs it for local use.
#
# Usage: ./scripts/build-app.sh [extra `swift build` flags]
# Output: ./Workbench.app (gitignored — a build product, never commit it)
#
# Version comes from ./VERSION (the only place to bump it). CFBundleVersion is the commit
# count when built from a git checkout, so every build from a new commit sorts higher.
set -eu
cd "$(dirname "$0")/.."

version=$(tr -d '[:space:]' < VERSION)
build=$(git rev-list --count HEAD 2>/dev/null || echo 1)

swift build -c release "$@"
bin=$(swift build -c release --show-bin-path "$@")
app="$PWD/Workbench.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
ditto "$bin/Workbench_Workbench.bundle" "$app/Contents/Resources/Workbench_Workbench.bundle"
cp assets/Workbench.icns "$app/Contents/Resources/Workbench.icns"
cp LICENSE "$app/Contents/Resources/Workbench-LICENSE.txt"
cp "$bin/Workbench" "$app/Contents/MacOS/Workbench"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Workbench</string>
<key>CFBundleIdentifier</key><string>io.github.aradhyadengree.workbench</string>
<key>CFBundleIconFile</key><string>Workbench.icns</string>
<key>CFBundleName</key><string>Workbench</string>
<key>CFBundleDisplayName</key><string>Workbench</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$build</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 Workbench contributors. MIT License.</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
plutil -lint "$app/Contents/Info.plist" >/dev/null
codesign --force --sign - "$app"
echo "$app"
