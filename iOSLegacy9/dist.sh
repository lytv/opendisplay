#!/bin/sh
# Package the captain's install artifacts. Not committed (see .gitignore).
#   iOSLegacy9/dist/OpenDisplayLegacy9.app  (unsigned armv7 build)
#   iOSLegacy9/dist/OpenDisplayLegacy9.ipa  (Payload zip for Sideloadly)
#   iOSLegacy9/dist/SHA256SUMS
#   iOSLegacy9/dist/README.txt
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
BUILD_APP="$HERE/build/OpenDisplayLegacy9.app"
DIST="$HERE/dist"

[ -x "$BUILD_APP/OpenDisplayLegacy9" ] || "$HERE/build.sh"

rm -rf "$DIST"
mkdir -p "$DIST/Payload"
cp -R "$BUILD_APP" "$DIST/Payload/OpenDisplayLegacy9.app"

# Ship unsigned: both install routes re-sign (Sideloadly with a personal
# certificate, jailbreak with ldid on device).
codesign --remove-signature "$DIST/Payload/OpenDisplayLegacy9.app/OpenDisplayLegacy9" 2>/dev/null || true
rm -rf "$DIST/Payload/OpenDisplayLegacy9.app/_CodeSignature"

mv "$DIST/Payload/OpenDisplayLegacy9.app" "$DIST/OpenDisplayLegacy9.app"
cp -R "$DIST/OpenDisplayLegacy9.app" "$DIST/Payload/OpenDisplayLegacy9.app"

(cd "$DIST" && zip -qr OpenDisplayLegacy9.ipa Payload)

cat > "$DIST/README.txt" <<'EOF'
OpenDisplay Legacy 9 — iPad 2 receiver (armv7, iOS 9.0+)

Files:
  OpenDisplayLegacy9.app  unsigned app bundle for the jailbreak route
  OpenDisplayLegacy9.ipa  Payload zip for Sideloadly (free Apple ID)
  SHA256SUMS              checksums; verify with: shasum -c SHA256SUMS

Sideloadly (free Apple ID): drag the .ipa into Sideloadly with the iPad
connected, install, then trust the profile in Settings > General >
Profiles & Device Management. Reinstall weekly (7-day expiry).

Jailbroken iPad 2 (Phoenix, iOS 9.3.5): copy the .app to /Applications
(scp -r OpenDisplayLegacy9.app root@<ipad>:/Applications/), sign with
ldid -S when available, run uicache -p ... plus respring/reboot.

Mac side: official sender v1.28.0+ (protocol v3) or a repo build; grant
Screen Recording and Accessibility; connect over USB or Wi-Fi.
Full steps: iOSLegacy9/install.md in the source tree.
EOF

(cd "$DIST" && shasum -a 256 OpenDisplayLegacy9.ipa \
    Payload/OpenDisplayLegacy9.app/OpenDisplayLegacy9 > SHA256SUMS)
# Checksum the whole unsigned bundle for completeness.
(cd "$DIST" && find OpenDisplayLegacy9.app -type f -exec shasum -a 256 {} + \
    | sort >> SHA256SUMS)

echo "Dist ready in $DIST:"
ls -la "$DIST"
unzip -l "$DIST/OpenDisplayLegacy9.ipa"
