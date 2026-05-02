# OpenAstro Linux — Debian 13 Trixie for the iOptron iMate

<img src="https://www.openastro.net/wp-content/uploads/2026/04/OpenAstro_logo.png" alt="OpenAstro logo" width="420">

Replace the stock OS on your iOptron iMate with **Debian 13 (Trixie)** while keeping full hardware support — WiFi, ethernet, DC power ports, GPIO, and USB. Restore to stock at any time with a single command.

## Supported Hardware

| Device | SoC | Storage | Status |
|--------|-----|---------|--------|
| iOptron iMate | Allwinner H6 (OrangePi 3 LTS) | 29 GB eMMC | Fully supported |

## How It Works

OpenAstro Linux uses the **stock iMate bootloader and kernel** — only the root filesystem contents are replaced with Debian Trixie over SSH. This means:

- Stock boot chain is untouched (U-Boot, kernel, device tree)
- All hardware works out of the box (same drivers as stock)
- Restore to stock firmware at any time with `./scripts/restore`
- No repartitioning — stock single-partition layout is preserved
- No physical access required — everything happens over the network

## Install

### 1. Setup and run instsaller

```bash
sudo apt install sshpass wget pv
git clone https://github.com/open-astro/aw-flashtool.git
cd aw-flashtool
./scripts/install
```

The installer handles everything automatically:

1. **Connects** to your iMate via SSH using the stock credentials
2. **Backs up** the stock rootfs to `images/` for future restore
3. **Preserves** the stock kernel, modules, firmware, and hardware tools
4. **Downloads** the OpenAstro Linux image from GitHub Releases (or uses a local copy)
5. **Replaces** the root filesystem with Debian Trixie
6. **Reboots** into OpenAstro Linux

### 3. First Boot

The iMate reboots automatically after installation. Wait about 60 seconds.

```
ssh astro@<imate-ip>
```

| Setting | Value |
|---------|-------|
| Hostname | `astro` |
| User | `astro` |
| Password | `astro` |
| SSH | Enabled |
| WiFi | Configure via `nmcli` |
| DC Ports | Enabled at boot |

**Change the default password immediately:** `passwd`

### WiFi Configuration

Connect to an existing network:

```bash
nmcli dev wifi list
nmcli dev wifi connect <SSID> password <pass>
```

Create a hotspot:

```bash
nmcli device wifi hotspot ssid astro password <pass>
```

### DC Power Ports

| Port | Command On | Command Off |
|------|-----------|-------------|
| DC1 | `gpio write 2 1` | `gpio write 2 0` |
| DC2 | `gpio write 6 1` | `gpio write 6 0` |
| DC3 | Always on (passthrough) | — |

Both DC1 and DC2 are enabled automatically at boot via `dc-power-ports.service`.

## Restore Stock Firmware

To go back to the original iOptron firmware at any time:

```bash
./scripts/restore
```

Or pass the IP directly:

```bash
./scripts/restore 192.168.1.x
```

The restore script mirrors the install process in reverse:

1. **Connects** to the iMate running OpenAstro Linux
2. **Uploads** the stock rootfs backup (created automatically during install)
3. **Replaces** the root filesystem with the stock backup
4. **Reboots** into stock firmware

The boot chain is never modified — only the rootfs contents are swapped, just like the install. After restoring, connect to the iMate WiFi (password: `12345678`) and verify everything works.

| Setting | Value |
|---------|-------|
| User | `imate` |
| Password | `imate` |

> **Note:** The stock rootfs backup (`images/imate-stock-rootfs.tar.gz`) is created automatically the first time you run `./scripts/install`. You must install at least once before you can restore.

## Build Your Own

If you'd prefer to build a custom rootfs instead of using the pre-built image:

### 1. Create a Debian Trixie rootfs

```bash
sudo apt install debootstrap qemu-user-static
sudo scripts/build/rootfs-setup.sh
```

This runs debootstrap, configures users, networking, SSH, GPIO services, and packages the result into `images/astrolinux-trixie-h6.tar.gz`.

### 2. Flash

```bash
./scripts/install
```

The installer will detect the local image in `images/` and use it instead of downloading.

### Shrink a stock DD image

If you have a raw eMMC dump from iOptron (typically ~30 GB), you can shrink it to a compressed image:

```bash
sudo apt install e2fsprogs parted
sudo scripts/build/shrink-stock-image.sh /path/to/stock-image.dd
```

This shrinks the ext4 filesystem to its minimum size, truncates the unused space, and compresses the result to `images/imate-stock-restore.img.gz` (~6.6 GB). The original image is not modified.

## Scripts Reference

| Script | Description |
|--------|-------------|
| `scripts/install` | **Full installer** — connect, back up stock rootfs, preserve stock files, download/upload image, replace OS, reboot |
| `scripts/restore` | **Stock restore** — connect, upload stock rootfs backup, replace OS, reboot |
| `scripts/build/rootfs-setup.sh` | Build a Debian Trixie rootfs tarball for the iMate (requires root, debootstrap, qemu-user-static) |
| `scripts/build/shrink-stock-image.sh` | Shrink iOptron's ~30 GB stock DD image to ~6.6 GB compressed |

## Hardware Documentation

Detailed hardware reference is in [`hardware/imate-h6/`](hardware/imate-h6/):

- [`inventory.md`](hardware/imate-h6/inventory.md) — Full hardware inventory, GPIO map, WiFi/BT details, partition layout, stock services

## Troubleshooting

### Can't find iMate on the network

- Make sure the iMate is powered on and connected via ethernet
- The installer tries hostnames (`iMate`, `iMate.local`) then scans the local subnet
- If auto-detection fails, pass the IP directly: `./scripts/install 192.168.1.x`
- Check your router's DHCP leases for the iMate's IP

### SSH connection refused

- Stock credentials are `imate` / `imate` — if these don't work, the device may already be flashed
- After flashing, credentials change to `astro` / `astro`
- Wait 30–60 seconds after power-on for SSH to be ready

### Installation or restore failed mid-way

The stock boot chain is never modified, so the device will always boot. If the rootfs replacement was interrupted:

- The device may still be accessible via SSH — try connecting and re-running the script
- If the device won't boot to SSH, use iOptron's SD card recovery image: [Restore/Update iMate IMG File](https://www.ioptron.com/Articles.asp?ID=366)

### WiFi not working after install

The Unisoc UWE5622 WiFi driver (`sprdwl_ng`) only works with the stock Allwinner BSP kernel. The installer preserves this kernel and its modules automatically. If WiFi isn't working:

- Check that the `sprdwl_ng` module is loaded: `lsmod | grep sprdwl`
- Load it manually: `sudo modprobe sprdwl_ng`
- Verify firmware files exist: `ls /lib/firmware/wcnmodem.bin`

## License

See [LICENSE.md](LICENSE.md).
