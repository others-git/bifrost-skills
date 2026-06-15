#!/usr/bin/env bash
# Helpers for forwarding a Samsung tablet into WSL and prepping it for ADB.
# Usage: ./helpers.sh <command>
#
# Commands:
#   setup       modprobe vhci-hcd + install android-tools/scrcpy
#   bind        (prints the Windows admin command to bind the device)
#   attach      usbipd attach --wsl --busid $BUSID
#   detach      usbipd detach --busid $BUSID
#   reattach    detach + attach (use after changing the tablet USB mode)
#   state       usbipd list (Windows view) + adb devices (WSL view)
#   interfaces  dump the tablet's USB descriptor / interface classes
#   adb         start adb server + adb devices -l
set -euo pipefail

BUSID="${BUSID:-2-1}"                       # override: BUSID=x-y ./helpers.sh ...
USBIPD='/mnt/c/Program Files/usbipd-win/usbipd.exe'

cmd="${1:-state}"
case "$cmd" in
  setup)
    sudo modprobe vhci-hcd
    sudo pacman -Syu --needed --noconfirm android-tools scrcpy
    ;;
  bind)
    echo "Run this in an ELEVATED Windows PowerShell:"
    echo "    usbipd bind --busid $BUSID"
    ;;
  attach)   "$USBIPD" attach --wsl --busid "$BUSID" ;;
  detach)   "$USBIPD" detach --busid "$BUSID" ;;
  reattach)
    "$USBIPD" detach --busid "$BUSID" || true
    sleep 1
    "$USBIPD" attach --wsl --busid "$BUSID"
    sleep 2
    dmesg | tail -6
    ;;
  state)
    echo "=== usbipd (Windows) ==="; "$USBIPD" list | grep -E "BUSID|$BUSID" || true
    echo "=== adb (WSL) ===";       adb devices -l 2>&1 || true
    ;;
  interfaces)
    # Find the tablet's sysfs node (Samsung idVendor 04e8) and list interfaces.
    for d in /sys/bus/usb/devices/*; do
      [ -f "$d/idVendor" ] || continue
      [ "$(cat "$d/idVendor")" = "04e8" ] || continue
      echo "Device $d  ($(cat "$d/product" 2>/dev/null)), $(cat "$d/bNumInterfaces") interfaces:"
      for i in "$d"/*:*; do
        [ -d "$i" ] || continue
        echo "  $(basename "$i"): class=$(cat "$i/bInterfaceClass" 2>/dev/null)" \
             "sub=$(cat "$i/bInterfaceSubClass" 2>/dev/null)" \
             "proto=$(cat "$i/bInterfaceProtocol" 2>/dev/null)" \
             "driver=$(basename "$(readlink "$i/driver" 2>/dev/null)" 2>/dev/null)"
      done
      echo "  (ADB = a class=ff interface; class=06 is PTP, cdc_acm is the modem)"
    done
    ;;
  debloat)
    # Uninstall every package listed in debloat.txt for user 0 (reversible).
    # NOTE the </dev/null on the adb call: without it, adb shell consumes the
    # while-loop's stdin and only the first package is processed.
    here="$(dirname "$0")"
    grep -vE '^\s*#|^\s*$' "$here/debloat.txt" | awk '{print $1}' | while read -r pkg; do
      res=$(adb ${SERIAL:+-s $SERIAL} shell pm uninstall --user 0 "$pkg" </dev/null 2>&1)
      printf "%-45s %s\n" "$pkg" "$res"
    done
    ;;
  restore-bloat)
    here="$(dirname "$0")"
    grep -vE '^\s*#|^\s*$' "$here/debloat.txt" | awk '{print $1}' | while read -r pkg; do
      res=$(adb ${SERIAL:+-s $SERIAL} shell cmd package install-existing "$pkg" </dev/null 2>&1)
      printf "%-45s %s\n" "$pkg" "$res"
    done
    ;;
  fixperm)
    # adb runs as your user but the /dev/bus/usb node is root-owned; chmod it.
    for d in /sys/bus/usb/devices/*; do
      [ -f "$d/idVendor" ] || continue
      [ "$(cat "$d/idVendor")" = "04e8" ] || continue
      node=$(printf "/dev/bus/usb/%03d/%03d" "$(cat "$d/busnum")" "$(cat "$d/devnum")")
      echo "chmod 666 $node"; sudo chmod 666 "$node"
    done
    adb kill-server; adb start-server; adb devices -l
    ;;
  adb)
    adb start-server
    adb devices -l
    ;;
  *)
    echo "unknown command: $cmd" >&2
    grep -E '^#   ' "$0" >&2
    exit 1
    ;;
esac
