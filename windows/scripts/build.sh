#!/usr/bin/env bash
# build.sh - assemble a Win11 Pro netboot image with VirtIO drivers, qemu-ga
# auto-install, OOBE bypass, mild AppX debloat, and CTT WinUtil on first login.
#
# Runs on macOS with: brew install wimlib
#
# Inputs (env vars or arguments):
#   WIN_ISO       - path to Windows 11 ISO (multi-edition)
#   VIRTIO_ISO    - path to virtio-win.iso (auto-downloaded if missing)
#   OUT_DIR       - working dir (default: ~/win11-netboot)
#   EDITION_INDEX - WIM index of the edition to keep (default: 6 = Win11 Pro)
#   SKIP_DEBLOAT  - if set, skip the AppX bloat removal pass

set -euo pipefail

WIN_ISO="${WIN_ISO:-$HOME/Downloads/Win11_25H2_EnglishInternational_x64_v2.iso}"
OUT_DIR="${OUT_DIR:-$HOME/win11-netboot}"
EDITION_INDEX="${EDITION_INDEX:-6}"
VIRTIO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

mkdir -p "$OUT_DIR"
cd "$OUT_DIR"

# 1. Mount Win11 ISO
if [ ! -d /Volumes/CCCOMA* ] 2>/dev/null; then
  hdiutil attach "$WIN_ISO" >/dev/null
fi
WIN_VOL="$(ls -d /Volumes/CCCOMA* | head -1)"
echo "Windows ISO mounted: $WIN_VOL"

# 2. Mount virtio-win.iso (download if missing)
VIRTIO_ISO="${VIRTIO_ISO:-$OUT_DIR/virtio-win.iso}"
[ -f "$VIRTIO_ISO" ] || curl -L -o "$VIRTIO_ISO" "$VIRTIO_URL"
VIRTIO_VOL="$(hdiutil attach "$VIRTIO_ISO" | awk '/\/Volumes/ {print $NF; exit}')"
echo "VirtIO ISO mounted: $VIRTIO_VOL"

# 3. Export single edition from install.wim
echo "Exporting edition $EDITION_INDEX from install.wim..."
wimlib-imagex export "$WIN_VOL/sources/install.wim" "$EDITION_INDEX" install.wim --compress=LZX

# 4. Stage VirtIO drivers (Windows 11 / amd64 only)
mkdir -p drivers/virtio
for d in NetKVM viostor vioscsi Balloon vioserial vioinput viorng qxldod \
         viogpudo viofs pvpanic qemufwcfg qemupciserial smbus sriov fwcfg; do
  [ -d "$VIRTIO_VOL/$d/w11/amd64" ] || continue
  mkdir -p "drivers/virtio/$d"
  cp -R "$VIRTIO_VOL/$d/w11/amd64/." "drivers/virtio/$d/"
done
mkdir -p drivers/virtio/guest-agent
cp "$VIRTIO_VOL/guest-agent/qemu-ga-x86_64.msi" drivers/virtio/guest-agent/
cp "$VIRTIO_VOL/virtio-win-guest-tools.exe" drivers/virtio/guest-agent/

# 5. Vendor NVMe driver folders (user drops INFs here manually)
mkdir -p drivers/intel-rst drivers/samsung-nvme drivers/amd-nvme

# 6. Local boot.wim copy + inject autounattend.xml and drivers folder
cp "$WIN_VOL/sources/boot.wim" boot.wim
chmod +w boot.wim
cp "$REPO_DIR/windows/autounattend/autounattend.xml" autounattend.xml
wimlib-imagex update boot.wim 2 <"$REPO_DIR/windows/scripts/inject-boot-wim.wimcmd"

# 7. Stage qemu-ga + virtio-tools into install.wim (so C:\drivers exists at first login)
mkdir -p stage/drivers
cp -R drivers/virtio/guest-agent stage/drivers/
echo 'add stage/drivers /drivers' | wimlib-imagex update install.wim 1

# 8. Mild AppX debloat
if [ -z "${SKIP_DEBLOAT:-}" ]; then
  wimlib-imagex update install.wim 1 <"$REPO_DIR/windows/debloat/delete-bloat.wimcmd"
  wimlib-imagex optimize install.wim --recompress
fi

# 9. Assemble upload directory (boot loader files + WIMs)
mkdir -p upload/windows/sources
cp boot.wim install.wim upload/windows/sources/
cp -R "$WIN_VOL/boot" "$WIN_VOL/efi" upload/windows/
cp "$WIN_VOL/bootmgr" "$WIN_VOL/bootmgr.efi" upload/windows/

echo
echo "Build complete. Upload contents:"
du -sh upload/
echo
echo "Next: copy upload/windows to /samsungssd2tb/netbootxyz/assets/windows on the Mikrotik."
echo "  scp -r upload/windows/. jr551@192.168.69.1:samsungssd2tb/netbootxyz/assets/windows/"
