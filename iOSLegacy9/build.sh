#!/bin/sh
# Build the iPad 2 (armv7, iOS 9) receiver app.
#
# Modern clang still emits armv7; the installed iPhoneOS SDK only lacks the
# target entries, so this script copies the SDK to a private cache dir and
# adds armv7-ios to every regular .tbd target list. The installed Xcode is
# never modified. Idempotent: skips the copy when the SDK is unchanged.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$HERE/build/OpenDisplayLegacy9.app"
CACHE="${OD_SDK_CACHE:-$HOME/.cache/opendisplay-legacy9}"
PATCHED="$CACHE/patched-sdk"
MARKER="$CACHE/patched-sdk.version"

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
SDK=$(cd "$SDK" && pwd -P) # resolve the versioned-sdk symlink
IBTOOL="$DEVELOPER_DIR/usr/bin/ibtool"

SDK_VERSION=$(md5 < "$SDK/SDKSettings.plist" 2>/dev/null || md5sum "$SDK/SDKSettings.plist" | cut -d' ' -f1)
SDK_VERSION="rev2 $SDK_VERSION"

if [ ! -f "$MARKER" ] || [ "$(cat "$MARKER")" != "$SDK_VERSION" ]; then
    echo "Preparing patched SDK copy in $PATCHED ..."
    rm -rf "$PATCHED"
    mkdir -p "$CACHE"
    cp -R "$SDK" "$PATCHED"
    chmod -R u+w "$PATCHED"
    # Symlinked .tbd files resolve to patched regular files; touch those only.
    find "$PATCHED" -type f -name '*.tbd' \
        -exec sed -i '' 's/\(targets: *\[ \)/\1armv7-ios, /g' {} \;
    # armv7-only runtime symbols Apple dropped from the modern .tbd files
    # (present in the on-device iOS 9 libobjc; arm64 code never needs them).
    sed -i '' 's/_objc_msgSend, /_objc_msgSend, _objc_msgSend_stret, /' \
        "$PATCHED/usr/lib/libobjc.A.tbd"
    echo "$SDK_VERSION" > "$MARKER"
else
    echo "Reusing patched SDK in $PATCHED"
fi

rm -rf "$OUT"
mkdir -p "$OUT"

echo "Compiling armv7 ..."
clang -target armv7-apple-ios9.0 -isysroot "$PATCHED" \
    -miphoneos-version-min=9.0 -fobjc-arc -fno-objc-exceptions -Os \
    -Wall -Wno-deprecated-declarations \
    "$HERE/main.m" \
    "$HERE/ODAppDelegate.m" \
    "$HERE/ODReceiverViewController.m" \
    "$HERE/ODSession.m" \
    "$HERE/ODHello.m" \
    "$HERE/ODWire.m" \
    "$HERE/ODAnnexB.m" \
    "$HERE/ODDecoder.m" \
    -framework UIKit -framework Foundation \
    -framework CoreMedia -framework CoreVideo -framework VideoToolbox \
    -framework QuartzCore -framework CoreGraphics -framework AVFoundation \
    -o "$OUT/OpenDisplayLegacy9"

echo "Compiling launch storyboard ..."
if "$IBTOOL" --compile "$OUT/Launch.storyboardc" "$HERE/Launch.storyboard" \
    >"$CACHE/ibtool.log" 2>&1; then
    echo "Launch storyboard compiled."
else
    # This Mac has the iOS SDK but no installed iOS platform/runtime for
    # ibtool ("iOS 26.5 Platform Not Installed"). The app runs without the
    # compiled launch screen (launch falls back to black, which matches
    # the launch view); rebuild on a Mac with an iOS platform installed
    # to get Launch.storyboardc. Never ship a half-written bundle.
    echo "WARNING: ibtool could not compile the launch storyboard:"
    grep -o '<string>[^<]*</string>' "$CACHE/ibtool.log" | head -3
    echo "WARNING: continuing without Launch.storyboardc (see README)."
    rm -rf "$OUT/Launch.storyboardc"
fi

cp "$HERE/Info.plist" "$OUT/Info.plist"

# Ad-hoc sign so the bundle installs; jailbroken iPads re-sign with ldid,
# sideloaders re-sign with a personal certificate.
codesign -s - -f "$OUT/OpenDisplayLegacy9" 2>/dev/null || true

echo "Verifying ..."
file "$OUT/OpenDisplayLegacy9"
otool -l "$OUT/OpenDisplayLegacy9" | grep -A2 LC_VERSION_MIN_IPHONEOS
echo "Built $OUT"
