# Notes

Working notes — things that surprised us during the initial build.

## VirtIO/QEMU agent — auto-detect logic

`autounattend.xml` runs this PowerShell at first logon to detect a hypervisor
and decide whether to install the guest agent:

```powershell
$m = (Get-CimInstance Win32_ComputerSystem).Manufacturer
if ($m -match 'QEMU|Red Hat') {
  # Install qemu-ga and virtio-win-guest-tools
}
```

- On Proxmox/QEMU/KVM, `Manufacturer` reports `QEMU` (or `Red Hat` for some
  builds). Detection fires, agents install silently.
- On bare metal, manufacturer is the OEM (Dell, ASUS, etc.) — detection
  skips and no agent is installed.

## Drivers in boot.wim vs install.wim

We bake drivers into both WIMs but for different reasons:

- **`boot.wim` image 2** gets the full `/drivers/` tree (NetKVM, vioscsi,
  viostor, Balloon, etc). `DriverPaths` in `autounattend.xml` points at
  `X:\drivers`. This is **critical** during setup — without `viostor`,
  WinPE can't see the QEMU virtual disk and setup fails immediately.
- **`install.wim` image 1** only gets `/drivers/guest-agent/` (qemu-ga.msi
  + virtio-win-guest-tools.exe). These end up at `C:\drivers` after the OS
  is deployed, where `FirstLogonCommands` can find them.

The `specialize` pass loses access to `X:\` (WinPE is gone by then), so
post-install agent install has to read from `C:\drivers`.

## SMB vs SCP on the Mikrotik

SMB share `\\192.168.69.1\samsungssd2tb` is enabled but requires the SMB
password. SSH key auth means we can SCP via `ssh-key` user `jr551` without
prompting — that's what `build.sh` documents.

SCP on the L009 (ARMv7) hits ~5-10 MB/s due to CPU-bound SSH encryption.
A 7 GB upload takes 15-25 minutes.

## Debloat profile

`bloat-paths.txt` removes 84 AppX package folders. We deleted by file path
rather than DISM `/Remove-ProvisionedAppxPackage` because DISM isn't
available on macOS. The deletes leave `AppxProvisioning.xml` entries in
place — they fail silently at registration and CTT WinUtil cleans up the
leftover registry state on first login.

Final install.wim ≈ 6.3 GB (from 6.6 GB) — small saving in raw bytes
because of WIM single-instance storage, but the deployed system is
substantially leaner (no Xbox, Bing, Teams consumer, Phone Link, etc).

## iPXE wimboot quirks

For network-booting Windows you need a `wimboot` binary served alongside
the boot files. netboot.xyz v3.x ships its own `wimboot` at the container
root. v2.x doesn't.

If you switch container versions, double-check that:

- `http://${next-server}/wimboot` resolves.
- `boot.wim` is reachable at the path `windows.ipxe` references.

## Local-vars.ipxe + MAC-*.ipxe lookups

When booting from `boot.netboot.xyz/ipxe/netboot.xyz-snponly.efi`, the
iPXE script tries `tftp://${next-server}/local-vars.ipxe` and
`tftp://${next-server}/MAC-*.ipxe`. These timeouts are harmless — they're
optional per-host customisation hooks. Only set up if you want a specific
MAC to skip the menu and boot a fixed entry.
