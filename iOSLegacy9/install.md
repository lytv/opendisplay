# Installing OpenDisplay Legacy 9 on the iPad 2

Get the files first: on the Mac, run `./iOSLegacy9/dist.sh` (runs the
build when needed). It writes `iOSLegacy9/dist/`:

- `OpenDisplayLegacy9.app` — unsigned armv7 build, MinimumOSVersion 9.0
- `OpenDisplayLegacy9.ipa` — zip with `Payload/OpenDisplayLegacy9.app`,
  for Sideloadly
- `SHA256SUMS` — checksums for both
- `README.txt` — file list and install steps

`dist/` is a local artifact and is not committed. Verify before you
install: `cd iOSLegacy9/dist && shasum -c SHA256SUMS`.

## Route A — Sideloadly with a free Apple ID

1. Connect the iPad 2 to the Mac over USB and open Sideloadly.
2. Drag `OpenDisplayLegacy9.ipa` into Sideloadly, enter the free Apple ID,
   and install.
3. On the iPad, open Settings > General > Profiles & Device Management
   (on iOS 9.3.5: Settings > General > Device Management), trust the
   Apple ID profile, and open the app.

Free Apple IDs expire every 7 days: after expiry the app stops launching
until it is reinstalled through Sideloadly and re-trusted. A paid
developer account signs for a year instead.

## Route B — jailbroken iPad 2 (Phoenix, iOS 9.3.5)

1. Copy the `.app` to the iPad, e.g. over SSH:
   `scp -r OpenDisplayLegacy9.app root@<ipad>:/Applications/`
2. On the iPad, sign the binary when `ldid` is available:
   `ldid -S /Applications/OpenDisplayLegacy9.app/OpenDisplayLegacy9`
3. Register the app and respring:
   `uicache -p /Applications/OpenDisplayLegacy9.app && killall backboardd`
   (or reboot). The app icon then appears on the home screen.

No expiry: a system app stays installed until removed.

## Mac side

1. Use the official sender release v1.28.0 or newer (protocol v3), or
   build the Mac sender from this repo.
2. Grant the sender Screen Recording and Accessibility when macOS asks
   (System Settings > Privacy & Security); without both, there is no
   picture and no input.
3. Connect over USB (recommended: lowest latency, charges the iPad) or
   Wi-Fi on the same network. The sender discovers the iPad through
   Bonjour (`_opensidecar._tcp`); over USB the sender tunnels through
   `usbmuxd` to the same port 9000 listener.

## First connection checklist

- The iPad shows "Connected (USB)" or "Connected (Wi-Fi)" and the fps
  overlay starts counting.
- If it stays on "Waiting for sender", check: same Wi-Fi network (or USB
  cable + sender USB support), Mac firewall allowing the sender, and no
  VPN splitting the LAN.
- If the picture freezes while touches still work, the decoder lost its
  reference frames; the app requests a keyframe itself (`kf` on connect,
  on decoder creation and after decode failure). Reconnect if it persists.
