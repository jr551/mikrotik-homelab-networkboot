# Mac-hosted netboot

Run the whole netboot stack from your Mac without a Mikrotik. Plug a
target machine into your Mac's ethernet (USB-C/Thunderbolt adapter,
dock, crossover cable, or a small dumb switch) and boot it from the
artefacts produced by `windows/scripts/build.sh`.

## How it works

`serve.sh` configures the chosen ethernet interface with a static IP
and runs three things on it:

1. **dnsmasq DHCP** hands out leases on `10.42.42.0/24` and tells UEFI
   PXE clients to fetch `ipxe.efi` via TFTP.
2. **dnsmasq TFTP** serves `ipxe.efi` and a small `autoexec.ipxe` that
   chains to HTTP.
3. **python3 http.server** serves the `upload/windows/` tree (boot.wim,
   install.wim, bootmgr, BCD, etc.) and `wimboot`.

There is **no netboot.xyz container in this path** — the Mac serves
the Windows menu directly.

## One-time setup

```
brew install dnsmasq
windows/scripts/build.sh         # build the WIMs first
```

## Run

```
sudo mac-host/serve.sh              # auto-detects first ethernet port
sudo mac-host/serve.sh -i en7       # or pick the interface manually
sudo mac-host/serve.sh -s 10.50.50.0/24   # different subnet
```

`networksetup -listallhardwareports` lists the ethernet device names
on your Mac (e.g. `en6`, `en7`).

Stop with Ctrl-C — the script tears down its config on exit.

## Target machine

- UEFI firmware with PXE/network boot enabled.
- Set boot order to network-first, or hit the one-shot boot menu key
  (F12/F8/Esc depending on vendor).
- The target will pull `ipxe.efi` over TFTP, chain to HTTP, and load
  Windows setup automatically.

For a **crossover cable** straight from Mac to target, modern Macs and
NICs auto-MDIX so a regular ethernet cable works fine — no special
crossover needed.

For a **switch**, use a dumb unmanaged switch or make sure DHCP from
your upstream router can't reach this segment, otherwise the target
will get the wrong DHCP lease.

## Troubleshooting

- **No DHCP lease on target**: the Mac might still be trying to share
  Internet on that interface. Toggle Internet Sharing off in System
  Settings → General → Sharing.
- **Permission errors on port 67**: dnsmasq needs root for the DHCP
  socket — that's why `serve.sh` checks for `sudo`.
- **Target boots but iPXE shell instead of Windows menu**: the
  `autoexec.ipxe` chain failed. From the iPXE shell run
  `chain http://10.42.42.1:8080/windows/windows.ipxe` to see the real
  error.
