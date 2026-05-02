#!/bin/bash
set -euo pipefail

# Shrink iOptron's stock DD image (~30 GB raw) to a minimal compressed image.
# The stock image is a full eMMC dump with mostly empty space. This script
# shrinks the ext4 filesystem and partition, then compresses the result.
#
# Usage: sudo scripts/build/shrink-stock-image.sh <stock-image.img>
# Output: images/imate-stock-restore.img.gz (~6.6 GB compressed)

REPODIR="$(cd "$(dirname "$0")/../.." && pwd)"
OUTPUT="$REPODIR/images/imate-stock-restore.img.gz"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

if [ $# -lt 1 ]; then
    echo "Usage: $0 <stock-image.img>"
    echo ""
    echo "Provide the raw DD image from iOptron's stock eMMC dump."
    exit 1
fi

INPUT="$1"

if [ ! -f "$INPUT" ]; then
    echo "ERROR: $INPUT not found."
    exit 1
fi

for cmd in e2fsck resize2fs parted; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: $cmd not found."
        exit 1
    fi
done

echo ""
echo "========================================"
echo "  Shrink Stock iMate Image"
echo "========================================"
echo ""

INPUT_SIZE=$(du -h "$INPUT" | cut -f1)
echo "Input: $INPUT ($INPUT_SIZE)"

# Work on a copy so the original is preserved
WORKDIR="$(mktemp -d)"
WORK_IMG="$WORKDIR/stock.img"

cleanup() {
    losetup -j "$WORK_IMG" 2>/dev/null | cut -d: -f1 | while read -r dev; do
        losetup -d "$dev" 2>/dev/null || true
    done
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

echo "Copying image to working directory..."
cp "$INPUT" "$WORK_IMG"

# Set up loop device with partition scanning
LOOP=$(losetup -fP --show "$WORK_IMG")
PART="${LOOP}p1"

echo "Loop device: $LOOP"
echo "Partition:   $PART"

# Wait for partition device to appear
sleep 1
if [ ! -b "$PART" ]; then
    echo "ERROR: Partition $PART not found. Is this a valid disk image with a partition table?"
    exit 1
fi

# Check and repair filesystem
echo ""
echo "Checking filesystem..."
e2fsck -fy "$PART" || true

# Get current filesystem size
BLOCK_SIZE=$(dumpe2fs -h "$PART" 2>/dev/null | awk '/Block size:/{print $3}')
BLOCK_COUNT=$(dumpe2fs -h "$PART" 2>/dev/null | awk '/Block count:/{print $3}')
FS_SIZE_MB=$(( (BLOCK_COUNT * BLOCK_SIZE) / 1048576 ))
echo "Current filesystem: ${FS_SIZE_MB} MB (${BLOCK_COUNT} blocks of ${BLOCK_SIZE} bytes)"

# Shrink filesystem to minimum
echo ""
echo "Shrinking filesystem to minimum size..."
resize2fs -M "$PART"

# Get new size
NEW_BLOCK_COUNT=$(dumpe2fs -h "$PART" 2>/dev/null | awk '/Block count:/{print $3}')
NEW_FS_SIZE_MB=$(( (NEW_BLOCK_COUNT * BLOCK_SIZE) / 1048576 ))
echo "Shrunk filesystem: ${NEW_FS_SIZE_MB} MB (${NEW_BLOCK_COUNT} blocks)"

# Add 64 MB of headroom
HEADROOM_BLOCKS=$(( 67108864 / BLOCK_SIZE ))
FINAL_BLOCKS=$(( NEW_BLOCK_COUNT + HEADROOM_BLOCKS ))
echo "Adding 64 MB headroom: ${FINAL_BLOCKS} blocks"
resize2fs "$PART" "${FINAL_BLOCKS}"

FINAL_FS_BYTES=$(( FINAL_BLOCKS * BLOCK_SIZE ))

# Detach loop device
losetup -d "$LOOP"

# Get partition start offset
PART_START=$(parted -m "$WORK_IMG" unit B print 2>/dev/null | awk -F: '/^1:/{gsub("B","",$2); print $2}')
echo "Partition start: ${PART_START} bytes"

# Calculate new partition end and truncate
PART_END=$(( PART_START + FINAL_FS_BYTES ))
TRUNC_SIZE=$(( PART_END + 1048576 ))  # 1 MB trailing space for GPT backup / alignment

echo "Truncating image to $(( TRUNC_SIZE / 1048576 )) MB..."
truncate -s "$TRUNC_SIZE" "$WORK_IMG"

# Fix partition table
parted -s "$WORK_IMG" resizepart 1 "${PART_END}B"

# Final filesystem check
LOOP2=$(losetup -fP --show "$WORK_IMG")
e2fsck -fy "${LOOP2}p1" || true
losetup -d "$LOOP2"

# Compress
echo ""
echo "Compressing..."
mkdir -p "$REPODIR/images"
gzip -c "$WORK_IMG" > "$OUTPUT"

OUTPUT_SIZE=$(du -h "$OUTPUT" | cut -f1)
echo ""
echo "Done: $OUTPUT ($OUTPUT_SIZE)"
echo "  Original: $INPUT_SIZE"
echo "  Shrunk:   $(du -h "$WORK_IMG" | cut -f1) (uncompressed)"
echo "  Final:    $OUTPUT_SIZE (gzip)"
