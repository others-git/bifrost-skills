# bifrost-skills

Reusable runbooks ("skills") for setting up hardware around
[Bifrost](https://github.com/) — a self-hosted smart-home control hub.

Each skill is a self-contained directory with a `SKILL.md` runbook plus any
helper scripts, written so the next device is mostly a script-run.

## Skills

### [`tablet-kiosk/`](tablet-kiosk/SKILL.md)
Turn a Samsung Galaxy tablet into a locked-down, always-on wall-mounted
dashboard kiosk, driven over ADB from a WSL (Arch) box with the tablet's USB
forwarded in via usbipd-win. Covers:
- USB→WSL bridging (`vhci_hcd`, usbipd), getting the tablet into ADB mode,
  Play-Protect sideload gotchas, adb-over-Wi-Fi
- Reversible debloat of Samsung/Google bloatware (`debloat.txt`,
  `debloat-google.txt`) — including the overlay-idmap pitfall that crashes the
  keyboard
- WallPanel as a free FOSS display kiosk: dashboard URL, fullscreen, start-on-
  boot, set-as-Home, camera motion-detection screen wake, hide settings button
- Keep-screen-on while powered, orientation lock
- Notes on hard-lock options (device-owner / lock-task) and their limits

`helpers.sh` wraps the repetitive adb/usbipd commands (`setup`, `attach`,
`reattach`, `fixperm`, `debloat`, `interfaces`, …).

> Dashboard URLs, IPs, and device serials in the docs are placeholders /
> examples — substitute your own.
