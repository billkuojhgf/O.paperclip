# O.Paperclip

**A macOS GPS spoofing tool built specifically for Mac users, allowing you to inject simulated coordinates into an iPhone or iPad over USB or Wi-Fi.**

Chinese version: [README.md](./README.md)

**Before using this app: your iPhone / iPad must have Developer Mode enabled.**  
**If this project helps you, you can support its development here: Ko-fi: https://ko-fi.com/agocia**

---

## Requirements

| Item | Requirement |
|------|-------------|
| macOS | macOS 14 Sonoma or later |
| iPhone / iPad | iOS 16 or later, with Developer Mode enabled |
| Connection | USB or Wi-Fi (same network) |
| Other | No need to install Python, Homebrew, or any extra packages |

---

## Installation

### Option 1: Download the DMG (Recommended)

1. Go to the [Releases](../../releases) page and download the latest `O.Paperclip.dmg`
2. Open the DMG and drag `O.Paperclip.app` into the `Applications` folder
3. When launching it for the first time, right-click the app, choose `Open`, and confirm to bypass Gatekeeper

### Option 2: Build from Source

```bash
git clone https://github.com/agocia/O.Paperclip.git
cd O.Paperclip
uv python install 3.13
uv venv --managed-python --python 3.13 build/python-bundle
uv pip sync --python build/python-bundle/bin/python --require-hashes scripts/requirements-bundled.txt
zsh scripts/build-bundled-pymobiledevice3.sh
bash scripts/build-dvt-stream.sh
xcodebuild -project O.Paperclip.xcodeproj -scheme O.Paperclip -configuration Release build
```

Both tools use `pymobiledevice3 11.49.2` and the same hashed dependency lock. Python is only needed to rebuild the tools. Use managed Python with OpenSSL PSK support and verify every embedded library's deployment floor against macOS 14; successful builds do not certify physical-device, Intel or universal2 compatibility.

---

## Before You Start

### iPhone / iPad Setup

1. **Enable Developer Mode** (iOS 16+)  
   Go to `Settings` → `Privacy & Security` → `Developer Mode` → turn it on → restart the device

2. **Trust this Mac** (first USB connection)  
   After connecting via USB, your iPhone will ask whether to trust this computer. Tap `Trust` and enter your passcode.

3. **Extra step for Wi-Fi connection**  
   You must complete the trust pairing once over USB before switching to Wi-Fi mode.

---

## How to Use

### Step 1: Connect Your Device

Up to three distinct devices share GPS position, route, connection mode, and start/stop actions. Start/Add performs one discovery and connects devices sequentially; one connected device is ready for GPS. Adding does not rebuild existing connections. Disconnect one slot or all slots. Restart clears session identifiers/manual RSD fields; stale identities are not retried.

Run full automated acceptance with `python3 O.PaperclipTests/SimulatorEvidence/prepare.py` after installing Xcode and an iOS 27.0 Simulator runtime (`PAPERCLIP_SIMULATOR_RUNTIME` selects another installed runtime). The harness creates and cleans up three Simulators; GUI tests temporarily select and restore the keyboard layout. Its transport fixtures do not prove physical USB/Wi-Fi pairing or tunnel compatibility.

**USB connection (default):**
1. Connect your iPhone / iPad with a USB cable
2. Open O.Paperclip
3. In the sidebar, make sure `USB` is selected in the connection mode switcher
4. Click `Start Connection`
5. Keep the device unlocked while developer services are prepared. No Mac administrator authorization is requested.

**Wi-Fi connection:**
1. Make sure your iPhone and Mac are on the same Wi-Fi network
2. Open O.Paperclip
3. Switch the connection mode in the sidebar to `Wi-Fi`
4. Click `Start Connection`

> If your device is already connected over USB, you can switch directly to Wi-Fi. The app will automatically disconnect the current session and rebuild the tunnel over Wi-Fi.

> After a successful connection, the sidebar will show `Connected` along with the device name.  
> If the USB cable is unplugged or the Wi-Fi tunnel is interrupted, the app will automatically switch to a disconnected state and stop continuous movement until you reconnect.

---

### Step 2: Choose an Operation Mode

Use the segmented control at the top of the sidebar to switch between three modes:

| Mode | Description |
|------|-------------|
| **A-B** | Click a start point A and an end point B on the map, and the app will calculate a route and move along it automatically |
| **Pin** | Stay fixed at a single selected coordinate on the map |
| **Multi-Point** | Select multiple route points in order and move through them one by one |

---

### Step 3: Set the Location

**A-B Route Mode:**
1. Click the map to set point A, then click `Confirm A`
2. Click the map to set point B, then click `Confirm B`
3. Choose a route and click `Start Moving`
4. Adjust speed (km/h) and whether the route should loop

**Pin Mode:**
1. Click the target location on the map
2. Click `Pin This Location`
3. GPS will stay fixed at that point

**Multi-Point Mode:**
1. Click multiple route points on the map in order
2. Click `Start Moving`

> You can also type an address or place name in the search bar to jump directly to a location.

The map saves its camera center, distance, heading, and pitch after gestures, and restores them across relaunches and startup window resizing.

---

### Step 4: Stop Spoofing

Click `Stop` or `Clear Route` to stop GPS spoofing and return the device to its real location.

---

## PurePoint Overlay

You can import KML geographic data and display custom markers on the map:

1. Click `Import KML` in the right-hand `匯入與收藏` panel
2. Select a `.kml` file
3. The overlay will appear on the map, and you can filter markers by category

### Imports and saved locations

The right-hand panel remains separate from the three-device controls. Collapse it with the header button; reopen it from the map's right edge. Visibility and sort order persist across launches.

Import or drop a `.gpx`, name it, then choose `使用` to load its exact track as a ready multi-point draft without directions recalculation. Save a completed point/route locally; apply, focus, rename, delete, or sort it from the same panel. Existing upstream v1.2.1 GPX and favorite snapshots remain compatible. Applying a draft does not disconnect devices.

For a ready imported track, enabling `閉圈` adds a straight closing segment from the last point to the first and recomputes geometry and cumulative distance. Disabling it restores the original track; neither action requests road directions.

This restores the [upstream v1.2.1 panel](https://github.com/agocia/O.Paperclip/tree/dc10107c3b474d90c19b6a1c48e0d2c2f3e84a45) omitted when multi-device support was integrated on the v1.04 baseline. Regression coverage: `ImportedAndSavedLocationTests.swift` and the right-panel scenarios in `O_PaperclipUITests.swift`.

---

## Troubleshooting

**Q: The app keeps loading after I click "Start Connection".**  
A: Make sure the iPhone is unlocked and the Mac is trusted. For Wi-Fi mode, confirm both devices are on the same network.

**Q: Does connection require my Mac administrator password or Touch ID?**
A: No. Each normal-user worker owns one device's userspace tunnel and location service. Only USB devices explicitly missing CoreDeviceProxy may use Apple's native tunnel, which can compete with Xcode/remoted. No sudo/root-helper fallback exists. iPhone trust, passcode, Developer Mode and pairing remain required. Physical GPS stability, Wi-Fi pairing and macOS 14 operation need separate device acceptance; automated fixtures do not prove them.

**Q: Wi-Fi connection failed and it switched back to USB.**  
A: Only Wi-Fi-unavailable/unsupported errors allow USB fallback for the same UDID. Pairing, locked-device and protocol errors do not switch transports. Missing RemotePairing/altIRK data requires a trusted USB connection; existing pairing records are never automatically deleted or force-refreshed.

**Q: I am already connected over USB. Can I switch directly to Wi-Fi?**  
A: Yes. Just change the connection mode in the sidebar to `Wi-Fi`, and the app will automatically disconnect the current USB session and rebuild the tunnel over Wi-Fi.

**Q: Why does the app stop moving after I unplug the phone?**  
A: This is normal behavior. When the tunnel or device connection is interrupted, the app immediately marks the device as disconnected and stops the simulation to avoid fake movement continuing in the background.

**Q: GPS did not return to normal after stopping.**  
A: Click `Clear Location Points` or restart location services on the iPhone.

**Q: Connection fails on iOS 17 or later.**  
A: Make sure Developer Mode is enabled and that the device has already been trusted in Xcode or Finder.

---

## Disclaimer

This tool is intended only for legitimate use cases such as development testing and privacy protection. Do not use it for fraud, game cheating, or any activity that violates terms of service. Users are solely responsible for their actions.

---

## License

MIT License - see [LICENSE](LICENSE)
