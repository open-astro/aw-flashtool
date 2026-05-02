#!/bin/bash
set -euo pipefail

# Build a Debian 13 (Trixie) arm64 rootfs tarball for the iOptron iMate.
# Requires: debootstrap, qemu-user-static
# Usage: sudo scripts/build/rootfs-setup.sh

REPODIR="$(cd "$(dirname "$0")/../.." && pwd)"
WORKDIR="$(mktemp -d)"
ROOTFS="$WORKDIR/rootfs"
OUTPUT="$REPODIR/images/astrolinux-trixie-h6.tar.gz"

HOSTNAME="astro"
USERNAME="astro"
PASSWORD="astro"

cleanup() {
    echo "Cleaning up..."
    umount "$ROOTFS/proc" 2>/dev/null || true
    umount "$ROOTFS/sys" 2>/dev/null || true
    umount "$ROOTFS/dev/pts" 2>/dev/null || true
    umount "$ROOTFS/dev" 2>/dev/null || true
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

for cmd in debootstrap qemu-aarch64-static; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: $cmd not found. Install debootstrap and qemu-user-static."
        exit 1
    fi
done

# --- Bootstrap ---

echo ""
echo "========================================"
echo "  Building OpenAstro Linux rootfs"
echo "========================================"
echo ""

echo "Running debootstrap (trixie, arm64)..."
debootstrap --arch=arm64 --foreign trixie "$ROOTFS" http://deb.debian.org/debian

cp "$(which qemu-aarch64-static)" "$ROOTFS/usr/bin/"
chroot "$ROOTFS" /debootstrap/debootstrap --second-stage

# --- Mount virtual filesystems ---

mount -t proc proc "$ROOTFS/proc"
mount -t sysfs sys "$ROOTFS/sys"
mount -o bind /dev "$ROOTFS/dev"
mount -t devpts devpts "$ROOTFS/dev/pts"

# --- Configure ---

echo "Configuring rootfs..."

cat > "$ROOTFS/etc/hostname" << EOF
$HOSTNAME
EOF

cat > "$ROOTFS/etc/hosts" << EOF
127.0.0.1	localhost
127.0.1.1	$HOSTNAME

::1		localhost ip6-localhost ip6-loopback
ff02::1		ip6-allnodes
ff02::2		ip6-allrouters
EOF

cat > "$ROOTFS/etc/apt/sources.list" << 'EOF'
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
EOF

# --- Install packages ---

echo "Installing packages..."
chroot "$ROOTFS" bash -c "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq \
        systemd systemd-sysv \
        openssh-server \
        network-manager \
        sudo \
        bash-completion \
        curl wget \
        htop nano \
        usbutils pciutils \
        i2c-tools \
        zram-tools \
        busybox-static \
        ca-certificates \
        locales \
        dbus
    apt-get clean
"

# --- Locale ---

chroot "$ROOTFS" bash -c "
    sed -i 's/# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
    locale-gen
"

# --- User setup ---

echo "Creating user $USERNAME..."
chroot "$ROOTFS" bash -c "
    useradd -m -s /bin/bash -G sudo,dialout,i2c,gpio $USERNAME 2>/dev/null || \
    useradd -m -s /bin/bash -G sudo,dialout $USERNAME
    echo '${USERNAME}:${PASSWORD}' | chpasswd
    echo '${USERNAME} ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/$USERNAME
    chmod 440 /etc/sudoers.d/$USERNAME
"

# Lock root account
chroot "$ROOTFS" passwd -l root

# --- SSH ---

chroot "$ROOTFS" bash -c "
    systemctl enable ssh
    sed -i 's/#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
"

# --- Networking ---

chroot "$ROOTFS" systemctl enable NetworkManager

cat > "$ROOTFS/etc/NetworkManager/conf.d/10-manage-all.conf" << 'EOF'
[device]
wifi.scan-rand-mac-address=no

[main]
plugins=keyfile

[keyfile]
unmanaged-devices=none
EOF

# --- DC power ports service ---

cat > "$ROOTFS/etc/systemd/system/dc-power-ports.service" << 'EOF'
[Unit]
Description=Enable DC power ports (DC1 and DC2)
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/gpio mode 2 out
ExecStart=/usr/local/bin/gpio write 2 1
ExecStart=/usr/local/bin/gpio mode 6 out
ExecStart=/usr/local/bin/gpio write 6 1
ExecStop=/usr/local/bin/gpio write 2 0
ExecStop=/usr/local/bin/gpio write 6 0

[Install]
WantedBy=multi-user.target
EOF

chroot "$ROOTFS" systemctl enable dc-power-ports.service

# --- zram swap ---

cat > "$ROOTFS/etc/default/zramswap" << 'EOF'
ALGO=lz4
PERCENT=50
EOF

chroot "$ROOTFS" systemctl enable zramswap

# --- Serial console ---

chroot "$ROOTFS" systemctl enable serial-getty@ttyS0.service

# --- fstab ---

cat > "$ROOTFS/etc/fstab" << 'EOF'
# OpenAstro Linux — stock partition layout (single ext4 on eMMC)
# The actual root UUID is set by the kernel command line (orangepiEnv.txt)
/dev/mmcblk2p1	/	ext4	defaults,noatime,commit=600,errors=remount-ro	0	1
tmpfs		/tmp	tmpfs	defaults,nosuid,nodev,size=256M			0	0
EOF

# --- Cleanup ---

echo "Cleaning up rootfs..."
rm -f "$ROOTFS/usr/bin/qemu-aarch64-static"
rm -rf "$ROOTFS/var/cache/apt/archives"/*.deb
rm -rf "$ROOTFS/var/lib/apt/lists"/*
rm -f "$ROOTFS/etc/machine-id"
touch "$ROOTFS/etc/machine-id"

# --- Pack ---

echo "Packing rootfs..."
mkdir -p "$REPODIR/images"
tar czf "$OUTPUT" -C "$ROOTFS" .

SIZE=$(du -h "$OUTPUT" | cut -f1)
echo ""
echo "Done: $OUTPUT ($SIZE)"
