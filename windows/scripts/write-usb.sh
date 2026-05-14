#!/usr/bin/env bash
# write-usb.sh - format a USB stick as exFAT and copy the modified
# Windows install media to it. UEFI-bootable on any modern machine.
#
# Usage:
#   sudo ./write-usb.sh /dev/diskN
#
# Find the disk identifier with `diskutil list external`. BE CAREFUL —
# this WILL destroy any existing data on the target disk. The script
# refuses to touch internal disks (disk0).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="${OUT_DIR:-$HOME/win11-netboot}"
STAGE="$OUT_DIR/iso-stage"
LABEL="${USB_LABEL:-WIN11PRO}"

usage() {
  echo "Usage: sudo $0 /dev/diskN"
  echo "Find the target with: diskutil list external"
  exit 1
}

[ $# -eq 1 ] || usage
TARGET="$1"

[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo)."; exit 1; }
[ -d "$STAGE" ] || { echo "Stage dir missing: $STAGE"; exit 1; }

# Safety: refuse internal/boot disks.
case "$TARGET" in
  /dev/disk0|/dev/disk1|/dev/disk2|/dev/disk3)
    echo "Refusing to write to $TARGET (looks like an internal disk)."
    exit 1
    ;;
esac

diskutil info "$TARGET" >/dev/null 2>&1 || { echo "$TARGET not found."; exit 1; }

echo "Target: $TARGET"
diskutil info "$TARGET" | grep -E "Device / Media Name|Disk Size|Removable Media|Protocol"
echo
read -rp "This will ERASE $TARGET. Type 'yes' to continue: " ack
[ "$ack" = "yes" ] || { echo "Aborted."; exit 1; }

echo "Unmounting..."
diskutil unmountDisk "$TARGET"

echo "Formatting as exFAT (GPT)..."
diskutil eraseDisk ExFAT "$LABEL" GPT "$TARGET"

# diskutil mounts it for us; find the volume.
sleep 2
MOUNT_POINT="$(diskutil info "${TARGET}s2" | awk -F': +' '/Mount Point/ {print $2}')"
[ -d "$MOUNT_POINT" ] || { echo "Volume didn't mount."; exit 1; }
echo "Volume mounted at: $MOUNT_POINT"

echo "Copying installer contents (this takes a while)..."
# macOS ships an older rsync without --info=progress2; --progress works fine.
rsync -a --progress "$STAGE/" "$MOUNT_POINT/"

echo "Syncing..."
sync

echo
echo "Done. Ejecting..."
diskutil eject "$TARGET" || true
echo "USB is ready. Boot the target machine, hit the one-shot boot menu, pick the USB."
