# OpenDisplay Legacy 9 — iPad 2 receiver (armv7, iOS 9)

A self-contained Objective-C receiver that turns a 2011 iPad 2
(`iPad2,x`, iOS 9.3.5, armv7 A5, 1024x768 1x panel, no Metal) into an
OpenDisplay second display for the unmodified Mac sender at protocol
version 3. The existing Swift apps are untouched: Xcode 26 ships no
armv7 Swift standard library, so this app is Objective-C.

## Build

```
./iOSLegacy9/build.sh
```

Output: `iOSLegacy9/build/OpenDisplayLegacy9.app` — a `Mach-O executable
arm_v7` with `LC_VERSION_MIN_IPHONEOS 9.0`, ad-hoc signed.

How it works: modern clang still emits armv7. The installed iPhoneOS SDK
only lacks the target entries, so `build.sh` copies the SDK (about
70 MB) to `${OD_SDK_CACHE:-$HOME/.cache}/opendisplay-legacy9/patched-sdk`,
adds `armv7-ios` to every regular `.tbd` target list plus the armv7-only
`_objc_msgSend_stret` symbol the modern `libobjc` table dropped, then
compiles with `clang -target armv7-apple-ios9.0 -isysroot <patched-sdk>
-fobjc-arc -fno-objc-exceptions`. The installed Xcode SDK is never
modified. The SDK location comes from `DEVELOPER_DIR`
(`/Applications/Xcode.app/...`) because `xcode-select` on this machine
points at CommandLineTools. The script is idempotent: it reuses the
patched copy while the SDK is unchanged.

`build.sh` also compiles `Launch.storyboard` with `ibtool`. That step
needs an installed iOS platform for Interface Builder; this Mac has the
SDK but no IB platform (`iOS 26.5 Platform Not Installed`), so the script
warns and ships the app without `Launch.storyboardc`. The app runs fine
without it (launch falls back to black, which matches the launch view).
Re-run `build.sh` on a Mac with a full Xcode install to get the compiled
launch screen.

## Test

```
./iOSLegacy9/test.sh
./iOSLegacy9/dist.sh   # captain install artifacts (not committed)
```

Runs the device build, asserts it is `Mach-O arm_v7` with min iOS 9.0,
then builds and runs macOS host tests for the UIKit-free core
(`ODWire`, `ODHello`, `ODAnnexB`, `ODDecoder`, `ODSession`):

- framing round-trip and big-endian lengths
- section 4 demux, including telemetry-prefixed video and the 32768
  ceiling
- exact `hello` JSON, landscape and portrait
- Annex B splitting, SPS/PPS capture and change detection
- VideoToolbox decode smoke test on an `ffmpeg`-generated 320x180 H.264
  sample (skipped with a clear message only when the sample cannot be
  produced)
- session loopback: hello-first, kf-on-connect, video delivery, sender
  ping tolerance, 2 s ping cadence, touch/scroll frames, updateRequired,
  listener survival across disconnects, idle close after ~5 s silence

## What it does

- Listens on TCP 9000 on `0.0.0.0` (BSD sockets, no Network.framework).
  `usbmuxd` reaches the same listener over USB; a loopback peer is shown
  as USB in the status line.
- Bonjour `_opensidecar._tcp` with TXT `id=<stable uuid>` (`NSUserDefaults`)
  and `pv=3`.
- `hello` first on every connection (1024x768 1x panel, `displayMaxFrameRate`
  30, H.264 cap 1024x768@30 = 23592960 px/s), re-sent swapped on rotation.
- H.264 Annex B decode via `VTDecompressionSession` into an
  `AVSampleBufferDisplayLayer`; `kf` on connect, decoder creation and
  decode failure; decoder rebuild on SPS/PPS change.
- `ping` every 2 s; drops the session after 5 s with no bytes.
- Single-finger tap/drag to `touch` (video-rect normalized, letterbox
  aware); two-finger pan to `scroll` in video pixels, natural sign.
- One sender at a time; status text plus fps overlay; idle timer disabled.

## Known A5 limits

- 1024x768 H.264 at 30 fps is the ceiling the app advertises and sustains.
  Past two outstanding decodes, non-keyframes are dropped so the queue
  cannot grow.
- No HEVC (no A5 decoder; a non-H.264 `streamConfig` pauses video), no cursor
  rendering (`cursor`/`cursorImg` ignored), no Apple Pencil (single touch
  only), no audio, portrait is a re-`hello` with swapped dimensions.
- `-fno-objc-exceptions`: armv7 uses SjLj unwinding, whose symbols the
  modern SDK no longer exports. `@synchronized` still synchronizes; there
  is no ObjC exception handling. The app never throws.

See `install.md` for the iPad install routes.
