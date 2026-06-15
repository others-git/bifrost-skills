# Tablet Kiosk Setup (Samsung Galaxy Tab) — Bifrost wall-mount fixture

Goal: take a Samsung tablet and turn it into a locked-down, always-on Bifrost
dashboard kiosk, driven over ADB from this WSL (Arch) box, with the tablet's USB
forwarded into WSL via **usbipd-win**.

Reference device used to write this: **Galaxy Tab A9+ 5G**, USB id `04e8:6860`,
usbipd busid `2-1`. Adjust the busid per machine (`usbipd list`).

> Conventions
> - `usbipd` lives on the **Windows** side. From WSL call it as
>   `'/mnt/c/Program Files/usbipd-win/usbipd.exe'`.
> - Commands marked **(Windows admin)** must run in an **elevated** PowerShell on
>   Windows — `bind` needs admin; `attach`/`detach`/`list` do not.
> - `helpers.sh` in this dir wraps the repetitive bits.

---

## Phase 0 — One-time host setup (per PC)

1. **(Windows admin)** Install usbipd-win (once): `winget install usbipd`.
2. **(WSL)** Make sure the USB/IP virtual host controller driver is loadable and
   loaded — without it WSL has *no* USB subsystem at all
   (`/sys/bus/usb/devices/` won't exist):
   ```bash
   sudo modprobe vhci-hcd
   ```
   The module ships with the stock WSL2 kernel
   (`/lib/modules/$(uname -r)/kernel/drivers/usb/usbip/vhci-hcd.ko`).
   **NOTE: this does NOT persist across `wsl --shutdown`.** Re-run after reboot,
   or load it automatically (see Phase 5).
3. **(WSL)** Install the Android tooling (Arch). Use `-Syu`, not a bare `-S`, to
   avoid a partial-upgrade 404 when the local DB is stale:
   ```bash
   sudo pacman -Syu --needed --noconfirm android-tools scrcpy
   ```
   - `android-tools` → `adb` + `fastboot` (essential)
   - `scrcpy` → mirror/control the tablet screen from the desktop (needed to
     drive a wall-mounted tablet you can't easily touch)

---

## Phase 1 — Forward the tablet's USB into WSL

1. **(Windows admin)** Bind the device so it can be shared (once per device;
   survives reboots as "Shared"):
   ```powershell
   usbipd bind --busid 2-1
   ```
   `usbipd list` should then show the device as **Shared**.
2. **(Windows or WSL)** Attach it into WSL (NOT persistent — re-run each boot):
   ```powershell
   usbipd attach --wsl --busid 2-1
   ```
   Now `usbipd list` shows **Attached**.
3. **(WSL)** Confirm it enumerated:
   ```bash
   ls /sys/bus/usb/devices/      # expect usb1, usb2, and 1-1*
   dmesg | tail
   ```

---

## Phase 2 — Get the tablet into ADB mode  ← the gotcha

Forwarding the USB is **not** enough. The tablet must expose its **ADB USB
interface**, which only appears in the right USB mode *and* with debugging on.

Diagnose what the tablet is currently presenting:
```bash
./helpers.sh interfaces      # lists USB interfaces + drivers
```
- ADB present  → a `class=ff` interface (vendor-specific). Good.
- Only `class=06` (PTP image) + `cdc_acm` (modem) → **no ADB**. This is the
  default state of the A9+ 5G out of the box (PTP + cellular modem).

On the **tablet**:
1. Settings → About tablet → tap **Build number** 7× → enables Developer options.
2. Settings → Developer options → enable **USB debugging**.
3. Settings → Developer options → **Default USB Configuration → File Transfer**.
4. Pull down the notification shade → tap the **USB** notification → choose
   **"File transfer / Android Auto" (MTP)** (not PTP, not "No data transfer").

Changing the USB mode re-enumerates the device, so the stale WSL attachment must
be refreshed:
```bash
./helpers.sh reattach        # detach + attach so WSL re-reads the descriptor
./helpers.sh interfaces      # should now show a class=ff interface
adb devices                  # device shows as 'unauthorized' first
```
### WSL permissions: `failed to open device: Access denied`

Once the `class=ff` interface appears, adb may fail with
`usb_libusb.cpp: failed to open device: Access denied (insufficient
permissions)`. The raw USB node under `/dev/bus/usb` is root-owned and adb runs
as your user. WSL usually has no running udevd to fix this automatically. Quick
fix (the node's bus/dev number changes on every replug, so derive it):
```bash
D=/sys/bus/usb/devices/1-1
NODE=$(printf "/dev/bus/usb/%03d/%03d" "$(cat $D/busnum)" "$(cat $D/devnum)")
sudo chmod 666 "$NODE"
adb kill-server && adb start-server
```
`./helpers.sh fixperm` does this. (Persistent option: a udev rule
`SUBSYSTEM=="usb", ATTR{idVendor}=="04e8", MODE="0666"` if udevd runs, else just
re-run after each attach.)

On the tablet, accept **"Allow USB debugging?"** → check **Always allow from this
computer** → OK. `adb devices` should now show **device**.

### Troubleshooting: descriptor never changes / no `class=ff`

If `./helpers.sh interfaces` keeps showing the **same 3 interfaces**
(PTP `class=06` + two `cdc_acm`) no matter how many times you `reattach`, the
tablet is genuinely not advertising an ADB function — it is NOT a WSL/usbipd
problem (WSL re-enumerates fresh every attach: watch dmesg for "new high-speed
USB device number N" incrementing). Causes, in order:

1. **USB debugging is actually OFF.** This is *the* switch that adds the
   `class=ff` adb function to the USB composite — independent of MTP/PTP.
   "Developer options unlocked" ≠ "USB debugging on". Verify the toggle is green.
2. **Screen is locked.** Samsung exposes data USB modes (MTP + adb) only when the
   tablet is unlocked. Unlock it and keep it awake while plugged in.
3. The composite is single-config (`bNumConfigurations=1`), so there's no
   alternate config to select — the function set is driven entirely by the two
   settings above.

When fixed, `bNumInterfaces` increases and a `class=ff` interface appears.

---

## Phase 2.5 — Debloat (strip Samsung/Google junk)

Reversible, no root, no bootloader unlock: `pm uninstall --user 0 <pkg>` removes
an app for the current user while leaving the system APK in place. Undo with
`cmd package install-existing <pkg>`; a factory reset restores everything. This
reversibility is the safety net — **this tablet (SM-X218U) has a permanently
locked bootloader and CANNOT be reflashed**, so a factory reset is the only
recovery from a bad strip. Never remove the launcher, Play Store/Services,
keyboard, SystemUI, or Settings.

The curated list lives in `debloat.txt` (one package per line, `#` comments).
Run it:
```bash
./helpers.sh debloat          # uninstalls every pkg in debloat.txt for user 0
```
**Gotcha:** `adb shell` inside a `while read` loop eats the loop's stdin and only
the first line runs — always redirect `adb ... </dev/null` inside the loop
(helpers.sh does this).

Lists: `debloat.txt` (Samsung/Google apps) → `debloat-google.txt` (safe Play
layer, keeps GMS/WebView/mainline) → `debloat-extra.txt` (second pass: DeX,
Samsung Internet, Chrome, Gallery, AR junk, Smart View, carrier **ironSource
Aura** adware, etc.). Run each with `./helpers.sh debloat` after pointing it at
the list, or loop `pm uninstall --user 0` over the file (remember `</dev/null`).
Result on the reference tablet: 371 → ~307 packages. (`themecenter` may refuse
with DELETE_FAILED_INTERNAL_ERROR — it's the active theme engine; skip it.)

## Phase 3 — Kiosk provisioning (Fully Kiosk Browser)

### 3a. Install Fully Kiosk
Download the official APK (latest was v1.57.1) and install. On Samsung/Android 15
the install is blocked by **Play Protect** (`INSTALL_FAILED_VERIFICATION_FAILURE`,
a `PlayProtectDialogsActivity` waits on screen). With user authorization, make
sideloads non-interactive:
```bash
adb shell settings put global verifier_verify_adb_installs 0
adb shell settings put global package_verifier_enable 0
adb install -r -t fully.apk        # pkg = de.ozerov.fully
```
Bulk transfers (the 6 MB APK) drop the **usbip** link repeatedly — switch adb to
Wi-Fi first and install over that (`adb tcpip 5555 && adb connect <ip>:5555`).
Wi-Fi adb does NOT survive a reboot (adbd reverts to USB; `persist.adb.tcp.port`
is SELinux-blocked for the shell user), so re-do USB→tcpip after any reboot.

### 3b. Set the Start URL (GUI automation over adb)
Fully's Start URL is set in its GUI; no root/PLUS needed. Drive it with
screencap + `input`, and get exact tap coords from `uiautomator dump` instead of
eyeballing (a tap just past a button's `bounds` silently misses):
```bash
# Lock orientation FIRST so screenshot coords == input coords (landscape makes
# the screencap 1920x1200 while `wm size` stays 1200x1920 -> taps land wrong).
adb shell settings put system accelerometer_rotation 0
adb shell settings put system user_rotation 0       # 0=portrait

# Open Fully menu: swipe from the LEFT edge -> Settings -> Web Content Settings
#   -> Start URL -> clear (MOVE_END then ~60x keyevent 67) -> input text <url>
adb shell input text "https://<your-bifrost-url>"
# Find the OK button precisely:
adb shell uiautomator dump /sdcard/ui.xml && adb pull /sdcard/ui.xml
#   grep text="OK" ... bounds="[941,730][1037,811]" -> tap center (989,770)
```
Verify: Fully menu -> **Goto Start URL** reloads it. Confirmed Bifrost login
renders over local DNS.

### 3b-alt. WallPanel (chosen — FOSS, no license, no nag)

Since voice is a separate native satellite, the display kiosk can be free.
**WallPanel** (xyz.wallpanel.app, GitHub TheTimeWalker/wallpanel-android) chosen
over unlicensed Fully (no nag, true fullscreen). Install + configure via adb GUI
automation (same screencap + `uiautomator dump` technique):
- APK: GitHub releases `WallPanelApp-prod-universal-vX.Y.Z.apk` (~9.6 MB).
- Settings (FAB bottom-right → gear): **Dashboard URL** = the Bifrost URL,
  **Open On Device Boot** = ON, **Fullscreen** = ON (already default).
- Make it the launcher: `cmd package set-home-activity
  xyz.wallpanel.app/.ui.activities.BrowserActivityNative`. Home button + boot now
  go to WallPanel/Bifrost full-screen (no status/nav bar).
- Removed Fully: `pm uninstall de.ozerov.fully`.
- Keep screen on while powered (app-agnostic, survives reboot):
  `adb shell settings put global stay_on_while_plugged_in 7` (AC|USB|Wireless).
  The normal screen-off timeout then only applies on battery.

#### Camera motion-detection screen wake (WallPanel)

Wall-panel favourite: panel dims when idle, the **front camera** wakes it when
someone approaches. All on-device (no Google services).
```bash
adb shell pm grant xyz.wallpanel.app android.permission.CAMERA
adb shell appops set xyz.wallpanel.app WRITE_SETTINGS allow   # for dim/brightness
```
Then in WallPanel settings (FAB → gear; drive via screencap + `uiautomator dump`):
- **Camera Settings → Camera Enabled = ON**, **Selected Camera = Front** (the
  room-facing one on a wall mount; default is Back/0, Front is usually id 1).
- **Camera Settings → Motion Detection → Motion Detection Enabled = ON** and
  **Wakes Screen = ON**. (Tune Maximum Leniency 1–20 = sensitivity, Motion Reset
  Time, Minimum Luma for low light.)
- Main settings → **Dim Screen Saver = ON**, **Start screensaver after… = 30s**
  (default) — gives the panel a dim state to wake FROM (since the OS keeps it on
  while powered, without a screensaver it'd just stay full-bright).

Verify: `adb shell dumpsys media.camera | grep wallpanel` shows it as an active
camera client on the chosen camera id. The `Camera3-Stream getBuffer` /
`CHIUSECASE` log spam is normal pipeline noise, not errors.

Privacy note: this leaves the front camera **always on**, watching the room.
WallPanel can also publish motion/face events over MQTT/HTTP — a possible
*presence* feed into Bifrost later.

#### Mute/disable notifications (kiosk should never beep or pop)

Layered, all reversible, and **media stream left untouched** so future voice TTS
still plays:
```bash
A="adb shell"
$A settings put global heads_up_notifications_enabled 0   # no banner popups over dashboard
$A settings put system notification_light_pulse 0         # no notification LED
$A settings put secure lock_screen_show_notifications 0   # none on lock screen
$A settings put system sound_effects_enabled 0            # no UI touch sounds
$A cmd notification set_dnd priority                      # Do Not Disturb on (zen_mode=1)
$A cmd media_session volume --stream 5 --set 0            # STREAM_NOTIFICATION = 0
$A cmd media_session volume --stream 2 --set 0            # STREAM_RING = 0
# DO NOT touch --stream 3 (STREAM_MUSIC) — that's where TTS/media plays.
```
Verify: `dumpsys audio | grep 'ringer mode muted streams'` should list
RING/NOTIFICATION/SYSTEM/DTMF (e.g. `0x126`) but NOT music. WallPanel fullscreen
already hides the status bar, so notification icons don't show either.

#### Hide the WallPanel settings button (and how to get it back)

Settings → (Application Settings) → **Settings Button**:
- **Settings Transparent = ON** → the gear/FAB is invisible but **still
  clickable** in its corner (default bottom-right). Chosen: hidden yet
  retrievable. (vs **Settings Disabled** = fully removed, then settings reopen
  ONLY via the MQTT `settings` command — don't use unless MQTT is set up.)

Retrieve settings later, any of:
1. Tap the invisible **bottom-right corner**.
2. **adb backstop (always works):**
   `adb shell am start -n xyz.wallpanel.app/.ui.activities.SettingsActivity`
3. MQTT `settings` command (only if MQTT configured).
Note: if a **Security Code** is set in WallPanel, opening settings prompts for it.

**Lock model:** WallPanel has **no device-admin component**, so it can't be
`dpm set-device-owner`'d. As-Home + Boot + Fullscreen = a **soft kiosk** (Home
returns to it; boots into it) — escape via notification shade / recents still
possible. For a HARD lock you need a separate **device-owner DPC** (it can
`setStatusBarDisabled`, add `DISALLOW_*` user restrictions, lock-task allowlist)
since the dashboard app itself isn't a DPC. A device-owner DPC would also be
handy later to keep the voice satellite alive + grant it RECORD_AUDIO.

### 3c. Remaining (not yet done)
- **Device owner:** `adb shell dpm set-device-owner de.ozerov.fully/.MyDeviceAdmin`
  (possible here — device has NO accounts; `dumpsys account` was empty).
- Fully settings: **Start on Boot**, **Kiosk Mode** lock (PLUS), hide system
  bars, keep screen on, disable status/nav bar. (Kiosk Mode + many locks are
  PLUS-licensed.)
- Final wall orientation locked **landscape**: `settings put system
  accelerometer_rotation 0` + `settings put system user_rotation 1` (use 3 if
  mounted the other way). For GUI automation, temporarily switch to portrait
  (`user_rotation 0`) so screencap and `input` coords match, then restore 1.

---

## Voice (separate concern — decoupled by design)

Always-on wake-word voice is a **native voice-satellite app**, NOT the display
kiosk (decided 2026-06-14). The kiosk browser only shows the dashboard; a
separate background mic foreground-service does wake-word + capture + posts to
Bifrost's voice API + plays TTS. So the display kiosk stays **free** (Fully
unlicensed or WallPanel) — no Fully PLUS needed. (WallPanel can't do webview mic;
Fully's mic-grant is PLUS — both irrelevant once voice is native.) Satellite is a
future build; grant it RECORD_AUDIO via `adb shell pm grant` and run it as a
`foregroundServiceType="microphone"` service alongside the locked kiosk.

## Phase 4 — Verify

> TODO — record the checks (reboots into kiosk, nav bar gone, can't escape, etc.)

---

## Phase 5 — Persistence across reboots (optional)

- `vhci-hcd` + `usbipd attach` both reset on `wsl --shutdown` / PC reboot.
- Options: a Windows Task Scheduler job running `usbipd attach --wsl --busid <id>`
  at logon, and/or `/etc/modules-load.d/vhci.conf` containing `vhci-hcd` in WSL.
- The tablet itself, once provisioned, holds its kiosk config independent of WSL —
  WSL is only needed for (re)configuration, not runtime.

---

## Quick reference

| Thing | Value |
|---|---|
| Device | Galaxy Tab A9+ 5G |
| USB id | `04e8:6860` |
| usbipd busid | `2-1` (verify with `usbipd list`) |
| WSL distro used by usbipd | Arch |
| Modem (NOT android) | `/dev/ttyACM0` — cellular modem, ignore for kiosk |
