#!/bin/sh
# Host tests for the UIKit-free iOSLegacy9 core + device-build assertions.
# Builds and runs framing/demux/hello/Annex B/VideoToolbox tests, then
# asserts the device build is Mach-O armv7 with LC_VERSION_MIN_IPHONEOS 9.0.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
TMP="$HERE/build/host-test"
mkdir -p "$TMP"

echo "=== device build ==="
"$HERE/build.sh"

BIN="$HERE/build/OpenDisplayLegacy9.app/OpenDisplayLegacy9"
FILE_OUT=$(file "$BIN")
echo "$FILE_OUT"
case "$FILE_OUT" in
    *"Mach-O executable arm_v7"*) echo "PASS device arch arm_v7" ;;
    *) echo "FAIL device arch is not arm_v7"; exit 1 ;;
esac
MIN_OS=$(otool -l "$BIN" | grep -A2 LC_VERSION_MIN_IPHONEOS | grep version | awk '{print $2}')
echo "min iOS version: $MIN_OS"
[ "$MIN_OS" = "9.0" ] || { echo "FAIL min version is not 9.0"; exit 1; }
echo "PASS min version 9.0"

echo "=== host tests ==="
clang -fobjc-arc -Os -Wall -Wno-deprecated-declarations -I"$HERE" \
    "$HERE/ODWire.m" "$HERE/ODHello.m" "$HERE/ODAnnexB.m" "$HERE/ODDecoder.m" \
    "$HERE/ODSession.m" "$HERE/tests/ODHostTests.m" \
    -framework Foundation -framework VideoToolbox -framework CoreMedia -framework CoreVideo \
    -o "$TMP/od-host-tests"

SAMPLE="$TMP/sample.h264"
SAMPLE_ARG=""
if command -v ffmpeg >/dev/null 2>&1; then
    if ffmpeg -hide_banner -loglevel error -y \
        -f lavfi -i testsrc=size=320x180:rate=10:duration=2 \
        -pix_fmt yuv420p -c:v libx264 -tune zerolatency -x264-params keyint=10 \
        -f h264 "$SAMPLE" && [ -s "$SAMPLE" ]; then
        SAMPLE_ARG="$SAMPLE"
    else
        echo "SKIP decode smoke: ffmpeg could not produce an H.264 sample"
    fi
else
    echo "SKIP decode smoke: ffmpeg not available, sample cannot be produced"
fi

if [ -n "$SAMPLE_ARG" ]; then
    "$TMP/od-host-tests" "$SAMPLE_ARG"
else
    "$TMP/od-host-tests"
fi
