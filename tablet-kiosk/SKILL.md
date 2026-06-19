# Tablet Kiosk Setup (Samsung Galaxy Tab) — Bifrost wall-mount fixture

Goal: take a Samsung tablet and turn it into a locked-down, always-on Bifrost
dashboard kiosk, driven over ADB from this WSL (Arch) box, with the tablet's USB
forwarded into WSL via **usbipd-win**.

The kiosk is the native **[bifrost-kiosk](https://github.com/others-git/bifrost-kiosk)**
app — a single device-owner Android app that is the display kiosk **and** the
always-on wake-word voice satellite **and** its own OTA updater. (Earlier drafts
of this runbook used a third-party browser kiosk — WallPanel/Fully — with voice
as a separate future app; that was superseded when the two were consolidated into
one device-owner app on 2026-06-14. The old approach is kept as an appendix.)

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

> **Keep `cmd package install-existing` handy** — if the keyboard, launcher, or
> Settings misbehaves after a strip, reinstall the offending package for user 0.
> A removed overlay/idmap package can crash the keyboard; reinstall to recover.

---

## Phase 3 — Install & pair the kiosk app (native `bifrost-kiosk`)

The kiosk is the native app `live.theundead.bifrost.kiosk` — WebView dashboard +
wake-word voice + OTA self-updater, in one device-owner package. Most setups are
just: install the APK, scan the pairing QR, (optionally) lock it down.

### 3a. Sideload the APK
Grab the latest APK from the **bifrost-kiosk** repo's Releases (or build it:
`./gradlew assembleRelease`). On Samsung/Android 15 the install is blocked by
**Play Protect** (`INSTALL_FAILED_VERIFICATION_FAILURE`, a
`PlayProtectDialogsActivity` waits on screen). With user authorization, make
sideloads non-interactive:
```bash
adb shell settings put global verifier_verify_adb_installs 0
adb shell settings put global package_verifier_enable 0
adb install -r -t bifrost-kiosk.apk        # pkg = live.theundead.bifrost.kiosk
```
The APK is large (~85 MB — it bundles the on-device Vosk wake-word model), and
bulk transfers drop the **usbip** link repeatedly. Install over Wi-Fi adb
instead: `adb tcpip 5555 && adb connect <tablet-ip>:5555`, then `adb -s
<ip>:5555 install …`. Wi-Fi adb does **not** survive a reboot (adbd reverts to
USB; `persist.adb.tcp.port` is SELinux-blocked for the shell user), so re-do
USB→tcpip after any reboot.

### 3b. Pair to the hub (QR — no keys typed on the tablet)
Pairing redeems a short-lived enrollment token for the kiosk's own `bfr_` API key,
so nothing is typed on the touchscreen:
1. In an authenticated Bifrost dashboard session, generate a **pairing QR**
   (Settings → Clients/enrollment; `POST /api/enrollment`, TTL ~5 min).
2. Launch the app on the tablet and **scan the QR** (its `ScanActivity` redeems
   the token via `POST /api/enrollment/redeem`). The key then appears under
   **Settings → API keys** and is revocable like any other.
3. The kiosk now checks in with the hub and is manageable from **Clients**
   (sleep / wake / lock the screen, de-authorize, see the app version). **On-device
   voice works out of the box** once paired.

For a wall tablet you can't touch, drive the scan over `scrcpy` (or open the app
via `adb shell monkey -p live.theundead.bifrost.kiosk 1` and point the camera at
the QR on another screen).

### 3c. Hard lock (device owner) — optional but recommended for a fixture
A permanent wall fixture should be unexitable. The app *is* a device-admin DPC
(`.AdminReceiver`); promoting it to **device owner** lets it call `startLockTask`
(lock-task pinning), hide the status/nav bars, and apply user restrictions.

Device-owner can only be set when the device has **no accounts** (verify
`adb shell dumpsys account` is empty — debloat/first-boot-skip keeps it so):
```bash
adb shell dpm set-device-owner live.theundead.bifrost.kiosk/.AdminReceiver
```
The app then pins itself into lock-task on launch and on boot (its
`.BootReceiver` brings the kiosk up after a reboot), so Home/Recents/notification
shade can't escape it. (This is the **hard** lock — the earlier WallPanel "soft
kiosk" couldn't do this because a plain browser kiosk has no DPC.)

To undo for re-provisioning: `adb shell dpm remove-active-admin
live.theundead.bifrost.kiosk/.AdminReceiver` (device-owner can't be removed once
accounts exist; a factory reset is the fallback).

### 3d. App-agnostic device settings (still wanted, reversible)

**Keep the screen on while powered** (so the wall panel never sleeps on AC; the
normal timeout still applies on battery):
```bash
adb shell settings put global stay_on_while_plugged_in 7   # AC|USB|Wireless
```

**Lock orientation** to the wall mount (landscape here; use `3` if mounted the
other way). For any adb GUI automation, temporarily switch to portrait
(`user_rotation 0`) so screencap and `input` coords match, then restore:
```bash
adb shell settings put system accelerometer_rotation 0
adb shell settings put system user_rotation 1             # 1=landscape
```

**Mute notifications** so the kiosk never beeps or pops — layered, reversible,
and **media stream left untouched** so voice TTS still plays:
```bash
A="adb shell"
$A settings put global heads_up_notifications_enabled 0   # no banner popups over dashboard
$A settings put system notification_light_pulse 0         # no notification LED
$A settings put secure lock_screen_show_notifications 0   # none on lock screen
$A settings put system sound_effects_enabled 0            # no UI touch sounds
$A cmd notification set_dnd priority                      # Do Not Disturb on (zen_mode=1)
$A cmd media_session volume --stream 5 --set 0            # STREAM_NOTIFICATION = 0
$A cmd media_session volume --stream 2 --set 0            # STREAM_RING = 0
# DO NOT touch --stream 3 (STREAM_MUSIC) — that's where voice TTS plays.
```
Verify: `adb shell dumpsys audio | grep 'ringer mode muted streams'` lists
RING/NOTIFICATION/SYSTEM/DTMF but NOT music. Lock-task already hides the status
bar, so notification icons don't show either.

---

## Voice (built into the kiosk app)

Voice is **not** a separate app any more — the same device-owner kiosk runs an
always-on **wake-word** listener (on-device Vosk) plus **push-to-talk**, captures
the command, posts it to Bifrost's voice API, and **plays the spoken reply**.
Talk-back uses the hub's configured TTS voice (e.g. a cloned voice served by
vocals-mcp) via `POST /api/voice/speak`, falling back to the device's built-in
Android TTS if the hub has no TTS configured.

- **No extra setup**: device-owner auto-grants `RECORD_AUDIO`, so the mic works
  once paired (no per-permission tap on a locked screen).
- **Wake word / endpoints** are configured hub-side (Settings → Voice & AI:
  transcription / chat / tts model endpoints — all optional, all degrade
  gracefully). With nothing configured, the deterministic grammar still works
  over text; STT/TTS light up as you add endpoints.
- The WebView dashboard's own push-to-talk button hands off to this native
  pipeline (a WebView mic can't run over plain-HTTP LAN).

---

## Phase 4 — Verify

- **Reboot** the tablet: it boots straight into the locked kiosk dashboard
  (`.BootReceiver` → lock-task), no launcher flash, status/nav bars gone.
- **Try to escape**: Home, Recents, and the notification shade should all be
  blocked (device-owner lock-task). If you can still pull the shade, device-owner
  wasn't set (re-check `dumpsys device_policy` / Phase 3c).
- **Dashboard loads** over local DNS and shows live device state.
- **Voice**: say the wake word (or hold push-to-talk) → a command runs → you hear
  the spoken reply (hub TTS voice, or on-device fallback).
- **Remote management**: the tablet appears under the hub's **Clients** tab; sleep
  / wake / lock / revoke all work from there.

---

## Phase 5 — Persistence across reboots (host side)

- `vhci-hcd` + `usbipd attach` both reset on `wsl --shutdown` / PC reboot.
- Options: a Windows Task Scheduler job running `usbipd attach --wsl --busid <id>`
  at logon, and/or `/etc/modules-load.d/vhci.conf` containing `vhci-hcd` in WSL.
- The tablet itself, once provisioned + paired, holds its config independent of
  WSL — WSL is only needed for (re)configuration, not runtime. Bifrost updates
  reach the kiosk via its OTA self-updater (managed from the hub), not adb.

---

## Quick reference

| Thing | Value |
|---|---|
| Device | Galaxy Tab A9+ 5G |
| USB id | `04e8:6860` |
| usbipd busid | `2-1` (verify with `usbipd list`) |
| WSL distro used by usbipd | Arch |
| Modem (NOT android) | `/dev/ttyACM0` — cellular modem, ignore for kiosk |
| Kiosk package | `live.theundead.bifrost.kiosk` |
| Device-owner cmd | `dpm set-device-owner live.theundead.bifrost.kiosk/.AdminReceiver` |

---

## Appendix — superseded display-kiosk approaches (Fully / WallPanel)

Before the native app, the display was a third-party browser kiosk with voice
planned as a separate satellite. Recorded here only because a few **techniques
carry over** (Play-Protect sideload bypass, adb GUI automation via
`screencap` + `uiautomator dump`, keep-screen-on, notification mute). The
browser-kiosk apps themselves are **no longer used**:

- **Fully Kiosk Browser** (`de.ozerov.fully`): Start URL set via its GUI; true
  fullscreen/Kiosk-Mode lock is PLUS-licensed. Dropped.
- **WallPanel** (`xyz.wallpanel.app`): FOSS, no nag; set Dashboard URL + Open On
  Boot + Fullscreen, made Home via `cmd package set-home-activity`, optional
  front-camera motion-detection screen-wake. But it has **no device-admin
  component**, so it could only be a *soft* kiosk (Home/shade could still escape)
  — which is exactly why the native device-owner app replaced it.

adb GUI automation tip that still applies: lock orientation to **portrait first**
(`user_rotation 0`) so a landscape screencap (1920×1200) and `input` coords line
up, get exact tap targets from `uiautomator dump` (not by eyeballing), then
restore landscape.
