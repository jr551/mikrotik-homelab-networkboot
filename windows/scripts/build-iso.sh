#!/usr/bin/env bash
# build-iso.sh - assemble a bootable Win11 install ISO from the modified
# boot.wim and install.wim produced by build.sh.
#
# Produces a hybrid UEFI + BIOS ISO that can be:
#   - written to a USB stick with `dd` (UEFI USB boot)
#   - burned to DVD (BIOS El Torito)
#   - mounted directly as a virtual CD
#
# Output: $OUT_DIR/Win11_Pro_Custom.iso
#
# Requires:
#   brew install xorriso

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
[ -f "$REPO_DIR/local.env" ] && . "$REPO_DIR/local.env"

OUT_DIR="${OUT_DIR:-$HOME/win11-netboot}"
STAGE="$OUT_DIR/iso-stage"
ISO_OUT="$OUT_DIR/Win11_Pro_Custom.iso"
LABEL="${ISO_LABEL:-WIN11_PRO_CUSTOM}"

command -v xorriso >/dev/null || { echo "xorriso not found. Run: brew install xorriso"; exit 1; }
[ -d "$STAGE" ] || { echo "Stage dir missing: $STAGE"; exit 1; }
[ -f "$STAGE/boot/etfsboot.com" ] || { echo "Missing $STAGE/boot/etfsboot.com (BIOS boot image)"; exit 1; }
[ -f "$STAGE/efi/microsoft/boot/efisys.bin" ] || { echo "Missing $STAGE/efi/microsoft/boot/efisys.bin (UEFI boot image)"; exit 1; }

echo "Building $ISO_OUT from $STAGE..."

xorriso -as mkisofs \
  -iso-level 4 \
  -V "$LABEL" \
  -no-emul-boot \
  -b boot/etfsboot.com \
  -boot-load-size 8 \
  -boot-info-table \
  -eltorito-alt-boot \
  -e efi/microsoft/boot/efisys.bin \
  -no-emul-boot \
  -isohybrid-gpt-basdat \
  -o "$ISO_OUT" \
  "$STAGE"

echo
echo "Done. ISO: $ISO_OUT"
ls -lh "$ISO_OUT"

cat <<EOF

To write to a USB (UEFI machines, single-partition exFAT/FAT32):
  diskutil list                      # find the USB disk identifier (e.g. disk6)
  diskutil unmountDisk /dev/diskN
  sudo dd if=$ISO_OUT of=/dev/rdiskN bs=4m status=progress
  # or use Balena Etcher: https://etcher.balena.io/

EOF
