# mikrotik-homelab-networkboot

Network-boot setup for a Mikrotik L009 running the netboot.xyz container.
Builds an unattended Windows 11 Pro installer with VirtIO drivers, QEMU
guest agent auto-install, OOBE/Microsoft-account bypass, mild AppX debloat,
and Chris Titus Tech WinUtil on first login.

The router serves images and the iPXE menu over HTTP from a USB drive
mounted at `/samsungssd2tb`.

## Layout

```
ipxe/                       iPXE menus served by the netbootxyz container
  nbxyz.ipxe                top-level menu (replaces upstream default)
  windows.ipxe              custom Windows installers submenu

windows/
  autounattend/
    autounattend.xml        injected into boot.wim image 2
  scripts/
    build.sh                end-to-end build (macOS, needs `brew install wimlib`)
    inject-boot-wim.wimcmd  wimupdate input: adds autounattend.xml + drivers
  debloat/
    bloat-paths.txt         AppX packages to remove (mild profile)
    delete-bloat.wimcmd     wimupdate input: 84 recursive deletes

docs/                       wiring notes
```

## Build flow

On macOS with `wimlib` installed:

```
brew install wimlib
cd windows/scripts
./build.sh
```

The script:

1. Mounts the Win11 ISO and virtio-win.iso (downloads virtio if missing).
2. Exports just Win11 Pro from the multi-edition `install.wim` (~6.6 GB).
3. Stages VirtIO Win11/amd64 drivers + qemu-ga MSI + virtio-win-guest-tools.exe.
4. Copies `boot.wim` locally and injects `autounattend.xml` + `/drivers/`.
5. Adds `/drivers/guest-agent/` to `install.wim` so it lands at `C:\drivers`.
6. Runs the mild debloat (84 AppX packages: Bing*, Xbox*, OutlookForWindows,
   Clipchamp, Solitaire, MSTeams, YourPhone, ZuneMusic, WebExperience, etc.).
7. Optimises (`wimoptimize --recompress`) to actually shrink the WIM.
8. Assembles an `upload/` directory ready to SCP to the router.

## Deploying to the Mikrotik

The router needs:

- A USB drive shared via SMB at `/samsungssd2tb`.
- netboot.xyz container at `/samsungssd2tb/container-root/netbootxyz`.
- Container needs to be on **netboot.xyz v3.x** (v2 has poor Windows support).
  Rebuild via the GH Actions workflow for `ghcr.io/jr551/docker-netbootxyz:armv7`.

Then:

```
# Files
scp -r upload/windows/. jr551@192.168.69.1:samsungssd2tb/netbootxyz/assets/windows/

# iPXE menu
scp ipxe/nbxyz.ipxe   jr551@192.168.69.1:samsungssd2tb/netbootxyz/config/menus/nbxyz.ipxe
scp ipxe/windows.ipxe jr551@192.168.69.1:samsungssd2tb/netbootxyz/assets/windows/windows.ipxe
```

The container picks up the new `nbxyz.ipxe` and `assets/windows/*` immediately
(no restart needed).

## What `autounattend.xml` does

- **windowsPE** pass: TPM/SecureBoot/RAM/CPU/Storage check bypasses
  (`HKLM\SYSTEM\Setup\LabConfig`), Pro edition auto-selected, generic Win11
  Pro KMS key, en-GB locale, GPT partitioning, `DriverPaths: X:\drivers`.
- **oobeSystem** pass: local `Admin` account (no password), all OOBE pages
  skipped, no Microsoft account prompt, AutoLogon once.
- **FirstLogonCommands** (run as Admin on first login):
  1. If `Manufacturer -match 'QEMU|Red Hat'` → install `qemu-ga-x86_64.msi`
     silently.
  2. Same condition → install `virtio-win-guest-tools.exe /S` silently.
  3. Launch CTT WinUtil interactively for any further debloat:
     `irm christitus.com/win | iex`.

## What's NOT in this repo

- ISO files (Win11, virtio-win) — fetched at build time.
- Built WIM artefacts — produced by `build.sh`.
- Vendor NVMe driver INFs (Intel RST/VMD, Samsung, AMD RAID) — download
  from the respective vendor sites and drop into `drivers/{intel-rst,samsung-nvme,amd-nvme}/`
  before running `build.sh`.

## Status

- ✅ Build pipeline working on macOS.
- ✅ Mild debloat tested.
- 🟡 Windows boot via iPXE wimboot — menu wired up, full end-to-end netboot
  not yet validated.
- 🟡 Container still on v2.x — needs rebuild to v3.x.
