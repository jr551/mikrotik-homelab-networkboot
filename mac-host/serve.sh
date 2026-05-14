#!/usr/bin/env bash
# serve.sh - run a complete netboot environment from your Mac.
#
# Use case: you don't have a Mikrotik (or it's busy). Plug a target PC
# directly into the Mac's ethernet (USB-C adapter, Thunderbolt dock,
# crossover cable, or a small switch) and boot it from the WIMs built
# by `windows/scripts/build.sh`.
#
# The Mac acts as: DHCP server (dnsmasq), TFTP server (dnsmasq), and
# HTTP server (python3) on an isolated /24 subnet on the chosen
# ethernet interface.
#
# Prerequisites:
#   brew install dnsmasq
#   (Optional) brew install ipxe  # or downloaded automatically
#
# Run:
#   sudo ./serve.sh                # auto-detect first non-Wi-Fi interface
#   sudo ./serve.sh -i en7         # pick a specific interface
#   sudo ./serve.sh -i en7 -s 10.50.50.0/24
#
# Stop with Ctrl-C: networksetup is reverted and dnsmasq is killed.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="${WORK_DIR:-$HOME/win11-netboot}"
TFTP_ROOT="$REPO_DIR/mac-host/tftproot"
HTTP_ROOT="$WORK_DIR/upload"
SUBNET="10.42.42.0/24"
SERVER_IP="10.42.42.1"
DHCP_RANGE_START="10.42.42.50"
DHCP_RANGE_END="10.42.42.99"
HTTP_PORT="8080"
IFACE=""

usage() {
  cat <<EOF
Usage: sudo $0 [-i IFACE] [-s SUBNET] [-w WORK_DIR]
  -i IFACE     ethernet interface (e.g. en7). Default: first non-Wi-Fi link.
  -s SUBNET    CIDR for the isolated network. Default: $SUBNET
  -w WORK_DIR  build output dir from build.sh. Default: \$HOME/win11-netboot
EOF
  exit 1
}

while getopts ":i:s:w:h" opt; do
  case "$opt" in
    i) IFACE="$OPTARG" ;;
    s) SUBNET="$OPTARG"; SERVER_IP="${SUBNET%.0/24}.1" ;;
    w) WORK_DIR="$OPTARG"; HTTP_ROOT="$WORK_DIR/upload" ;;
    *) usage ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo "Must run as root (sudo)."; exit 1; }
command -v dnsmasq >/dev/null || { echo "dnsmasq not found. Run: brew install dnsmasq"; exit 1; }
[ -d "$HTTP_ROOT/windows" ] || { echo "Build output missing at $HTTP_ROOT/windows. Run build.sh first."; exit 1; }

# Pick ethernet interface if not specified.
if [ -z "$IFACE" ]; then
  IFACE="$(networksetup -listallhardwareports | awk '
    /Hardware Port: (USB|Thunderbolt|Belkin|Ethernet|10|2.5)/ {p=1; next}
    p && /Device:/ {print $2; exit}
    /Hardware Port: Wi-Fi/ {p=0}
  ')"
  [ -n "$IFACE" ] || { echo "No ethernet interface detected; pass -i en7"; exit 1; }
  echo "Using interface: $IFACE"
fi

# Locate boot artefacts.
mkdir -p "$TFTP_ROOT"
IPXE_EFI="$TFTP_ROOT/ipxe.efi"
WIMBOOT="$HTTP_ROOT/windows/wimboot"

if [ ! -f "$IPXE_EFI" ]; then
  echo "Downloading iPXE EFI..."
  curl -fsSL -o "$IPXE_EFI" https://boot.ipxe.org/ipxe.efi
fi
if [ ! -f "$WIMBOOT" ]; then
  echo "Downloading wimboot..."
  curl -fsSL -o "$WIMBOOT" \
    https://github.com/ipxe/wimboot/releases/latest/download/wimboot
fi

# Stage the iPXE auto-boot script (TFTP-served alongside ipxe.efi).
cat > "$TFTP_ROOT/autoexec.ipxe" <<EOF
#!ipxe
echo Local netboot from Mac host
dhcp || goto fail
chain http://${SERVER_IP}:${HTTP_PORT}/windows/windows.ipxe || goto fail
:fail
echo Boot failed - dropping to shell
shell
EOF

# Stage the Windows menu (different paths from the Mikrotik version
# because there's no netbootxyz here — we serve directly).
cat > "$HTTP_ROOT/windows/windows.ipxe" <<EOF
#!ipxe
echo Loading Windows 11 Pro setup...
imgfree
kernel http://${SERVER_IP}:${HTTP_PORT}/windows/wimboot
imgfetch http://${SERVER_IP}:${HTTP_PORT}/windows/bootmgr           bootmgr
imgfetch http://${SERVER_IP}:${HTTP_PORT}/windows/boot/bcd          BCD
imgfetch http://${SERVER_IP}:${HTTP_PORT}/windows/boot/boot.sdi     boot.sdi
imgfetch http://${SERVER_IP}:${HTTP_PORT}/windows/sources/boot.wim  boot.wim
boot
EOF

# Configure interface with static IP.
echo "Configuring $IFACE with $SERVER_IP..."
ORIG_DHCP="$(ipconfig getoption "$IFACE" 1 || true)"
ifconfig "$IFACE" inet "$SERVER_IP" netmask 255.255.255.0 up

# Build dnsmasq config in /tmp.
DNSMASQ_CONF="$(mktemp -t mac-host-dnsmasq.XXXXXX.conf)"
DNSMASQ_LEASES="$(mktemp -t mac-host-dnsmasq.XXXXXX.leases)"
cat > "$DNSMASQ_CONF" <<EOF
interface=$IFACE
bind-interfaces
except-interface=lo
listen-address=$SERVER_IP

# DHCP
dhcp-range=$DHCP_RANGE_START,$DHCP_RANGE_END,12h
dhcp-leasefile=$DNSMASQ_LEASES
dhcp-authoritative

# PXE / iPXE chainloading
enable-tftp
tftp-root=$TFTP_ROOT

# UEFI clients (x64) get ipxe.efi; legacy BIOS get undionly.kpxe (you can
# add it later if you need BIOS boot).
dhcp-match=set:efi-x86_64,option:client-arch,7
dhcp-match=set:efi-x86_64,option:client-arch,9
dhcp-boot=tag:efi-x86_64,ipxe.efi
# Already-iPXE clients chain to the autoexec script:
dhcp-match=set:ipxe,175
dhcp-boot=tag:ipxe,autoexec.ipxe

log-dhcp
log-queries
EOF

cleanup() {
  echo
  echo "Cleaning up..."
  kill "${HTTP_PID:-0}" 2>/dev/null || true
  kill "${DNSMASQ_PID:-0}" 2>/dev/null || true
  ifconfig "$IFACE" down up 2>/dev/null || true
  rm -f "$DNSMASQ_CONF" "$DNSMASQ_LEASES"
  echo "Done."
}
trap cleanup EXIT INT TERM

echo "Starting dnsmasq on $IFACE..."
dnsmasq --no-daemon --conf-file="$DNSMASQ_CONF" &
DNSMASQ_PID=$!

echo "Starting HTTP server on :$HTTP_PORT (root: $HTTP_ROOT)..."
( cd "$HTTP_ROOT" && python3 -m http.server "$HTTP_PORT" --bind "$SERVER_IP" ) &
HTTP_PID=$!

cat <<EOF

================================================================
Netboot host running.
  Interface : $IFACE
  Server IP : $SERVER_IP
  DHCP pool : $DHCP_RANGE_START - $DHCP_RANGE_END
  TFTP root : $TFTP_ROOT
  HTTP root : $HTTP_ROOT  (port $HTTP_PORT)

Now PXE-boot the target machine on this network. UEFI clients
will pull ipxe.efi via TFTP, chain to HTTP, and load Windows.

Press Ctrl-C to stop.
================================================================
EOF

wait
