#!/bin/sh
# Builds the release artifacts for a GitHub release into ./dist (gitignored):
#   Workbench-<version>-macOS-universal.dmg   drag-to-Applications disk image
#   Workbench-<version>-macOS-universal.zip   same app, zipped (for Homebrew casks / scripts)
#   SHA256SUMS.txt                            checksums for both
#
# Usage:
#   ./scripts/package-release.sh             sign + notarize if a Developer ID is installed
#   NOTARIZE=0 ./scripts/package-release.sh  sign but skip Apple's notary service
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" ./scripts/package-release.sh
#
# Signing: uses the first "Developer ID Application" identity in the keychain (or
# $SIGN_IDENTITY). With none installed it falls back to ad-hoc signing, and downloads get
# Gatekeeper's "can't be opened" prompt. Apple Development / Apple Distribution certificates
# can't be used here: they are for devices and the App Store, not direct downloads.
#
# Notarization: needs a stored notarytool profile, created once with
#   xcrun notarytool store-credentials workbench-notary --apple-id <id> --team-id <TEAMID>
# ($NOTARY_PROFILE overrides the name). Notarizing the DMG also covers the app inside it, so the
# app ticket is stapled too before the zip is made.
#
# Hardened runtime needs no extra entitlements: dlopen of Xcode's SimulatorKit/CoreSimulator
# passes library validation because they are Apple-signed (verified with a team-signed probe).
#
# macOS only. Workbench is AppKit/SwiftUI + Xcode's simulator, so there is no .deb or .exe build.
set -eu
cd "$(dirname "$0")/.."

version=$(tr -d '[:space:]' < VERSION)
name="Workbench-$version-macOS-universal"
dist="$PWD/dist"
app="$PWD/Workbench.app"
profile="${NOTARY_PROFILE:-workbench-notary}"
identity="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

./scripts/build-app.sh --arch arm64 --arch x86_64 >/dev/null
lipo -archs "$app/Contents/MacOS/Workbench" | grep -q x86_64
lipo -archs "$app/Contents/MacOS/Workbench" | grep -q arm64

notarize=0
if [ -n "$identity" ]; then
  echo "==> signing with: $identity"
  codesign --force --options runtime --timestamp --sign "$identity" "$app"
  codesign --verify --strict --verbose=2 "$app"
  if [ "${NOTARIZE:-1}" = 1 ]; then
    xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1 && notarize=1 \
      || echo "!! no notarytool profile '$profile'; skipping notarization (see header)"
  fi
else
  echo "!! no Developer ID Application certificate; app stays ad-hoc signed (see header)"
fi

rm -rf "$dist" && mkdir -p "$dist"

# dmg: the app plus an /Applications shortcut so users can drag-install.
mkdir -p "$stage/Workbench"
ditto "$app" "$stage/Workbench/Workbench.app"
ln -s /Applications "$stage/Workbench/Applications"
cp LICENSE "$stage/Workbench/LICENSE.txt"
hdiutil create -quiet -volname "Workbench $version" -srcfolder "$stage/Workbench" \
  -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$dist/$name.dmg"
[ -n "$identity" ] && codesign --force --timestamp --sign "$identity" "$dist/$name.dmg"

if [ "$notarize" = 1 ]; then
  echo "==> notarizing (usually 1-5 minutes)"
  xcrun notarytool submit "$dist/$name.dmg" --keychain-profile "$profile" --wait
  xcrun stapler staple "$dist/$name.dmg"
  xcrun stapler staple "$app"
  spctl --assess --type open --context context:primary-signature -v "$dist/$name.dmg"
  spctl --assess --type execute -v "$app"
fi
hdiutil verify -quiet "$dist/$name.dmg"

# zip after stapling so the offline ticket travels with the app. ditto keeps the bundle's
# symlinks, xattrs and signature intact (plain zip doesn't).
ditto -c -k --keepParent "$app" "$dist/$name.zip"

(cd "$dist" && shasum -a 256 "$name.dmg" "$name.zip" > SHA256SUMS.txt)
ls -lh "$dist"
cat "$dist/SHA256SUMS.txt"
if [ "$notarize" = 1 ]; then echo "signed + notarized"
elif [ -n "$identity" ]; then echo "signed, NOT notarized"
else echo "ad-hoc signed, NOT notarized"; fi
