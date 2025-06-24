#!/bin/bash
set -euo pipefail

# ======================
# CONFIGURATION
# ======================

SRC_PART="/dev/sdd3"
MAPPER_NAME="migration_source"
SRC_MOUNT="/mnt/migration_source"

DEST_PART="/dev/nvme0n1p3"
DEST_MOUNT="/mnt/migration_target"

# ======================
# INITIALIZATION
# ======================

echo "=== Migration Script Start ==="
echo "Source: $SRC_PART → $SRC_MOUNT"
echo "Destination: $DEST_PART → $DEST_MOUNT"
echo

# ======================
# UNLOCK AND MOUNT SOURCE
# ======================

if [ -e "/dev/mapper/$MAPPER_NAME" ]; then
    echo "[✔] Encrypted partition already mapped as /dev/mapper/$MAPPER_NAME"
else
    if mount | grep -q "$SRC_PART"; then
        echo "[✖] ERROR: $SRC_PART appears mounted. Cannot proceed."
        exit 1
    fi

    if lsblk -no TYPE "$SRC_PART" | grep -q "crypt"; then
        echo "[✖] ERROR: $SRC_PART is already a crypt volume."
        exit 1
    fi

    echo "[…] Unlocking $SRC_PART as $MAPPER_NAME"
    cryptsetup open "$SRC_PART" "$MAPPER_NAME"
    echo "[✔] Unlocked successfully"
fi

MAPPED_DEV="/dev/mapper/$MAPPER_NAME"
if [ ! -b "$MAPPED_DEV" ]; then
    echo "[✖] ERROR: No mapped device at $MAPPED_DEV"
    exit 1
fi

mkdir -p "$SRC_MOUNT"
if ! mountpoint -q "$SRC_MOUNT"; then
    mount "$MAPPED_DEV" "$SRC_MOUNT"
    echo "[✔] Mounted $MAPPED_DEV at $SRC_MOUNT"
else
    echo "[✔] Source already mounted at $SRC_MOUNT"
fi

# ======================
# MOUNT DESTINATION
# ======================

mkdir -p "$DEST_MOUNT"
if ! mountpoint -q "$DEST_MOUNT"; then
    mount "$DEST_PART" "$DEST_MOUNT"
    echo "[✔] Mounted destination at $DEST_MOUNT"
else
    echo "[✔] Destination already mounted at $DEST_MOUNT"
fi

# ======================
# MIGRATION BEGINS
# ======================

echo
echo "=== Beginning Btrfs Subvolume Migration ==="

# Discover source subvolumes
mapfile -t SUBVOLUMES < <(btrfs subvolume list -o "$SRC_MOUNT" | awk '{print $9}')

if [ "${#SUBVOLUMES[@]}" -eq 0 ]; then
    echo "[✖] ERROR: No subvolumes found in $SRC_MOUNT"
    exit 1
fi

for SUBVOL in "${SUBVOLUMES[@]}"; do
    echo "[→] Migrating subvolume: $SUBVOL"

    SRC_PATH="$SRC_MOUNT/$SUBVOL"
    DEST_PATH="$DEST_MOUNT/$SUBVOL"

    mkdir -p "$(dirname "$DEST_PATH")"

    btrfs send "$SRC_PATH" | btrfs receive "$DEST_MOUNT"
    echo "[✔] Sent $SUBVOL"
done

echo
echo "=== Btrfs Migration Complete ==="

# ======================
# OPTIONAL CLEANUP
# ======================

# umount "$SRC_MOUNT"
# cryptsetup close "$MAPPER_NAME"
# umount "$DEST_MOUNT"

# ======================
# END
# ======================

echo "=== Migration Script Completed ==="
