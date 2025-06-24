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

# Function to select mapper
select_mapper() {
    local mappers=()
    
    # Get all available mappers (excluding control)
    for mapper in /dev/mapper/*; do
        mapper_name=$(basename "$mapper")
        if [[ "$mapper_name" != "control" ]]; then
            mappers+=("$mapper_name")
        fi
    done
    
    if [ ${#mappers[@]} -eq 0 ]; then
        printf "[!] No mapped devices found.\n" >&2
        return 1
    fi
    
    printf "Available mapped devices:\n" >&2
    for i in "${!mappers[@]}"; do
        # Show mount status for each mapper
        if mount | grep -q "/dev/mapper/${mappers[$i]}" 2>/dev/null; then
            mount_info=" (mounted)"
        else
            mount_info=" (not mounted)"
        fi
        printf "  %d. %s%s\n" "$((i+1))" "${mappers[$i]}" "$mount_info" >&2
    done
    printf "  %d. Don't use a mapper (unlock %s or use directly)\n" "$((${#mappers[@]}+1))" "$SRC_PART" >&2
    printf "\n" >&2
    
    while true; do
        printf "Select device to use (1-%d): " "$((${#mappers[@]}+1))" >&2
        read choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le $((${#mappers[@]}+1)) ]; then
            if [ "$choice" -eq $((${#mappers[@]}+1)) ]; then
                # User chose to use source partition directly or unlock it
                echo "direct"
                return 0
            else
                # User chose a mapper
                echo "${mappers[$((choice-1))]}"
                return 0
            fi
        else
            printf "Invalid choice. Please enter a number between 1 and %d.\n" "$((${#mappers[@]}+1))" >&2
        fi
    done
}

# Determine which device to use for mounting
echo "[…] Checking for available devices..."

# Check if source partition is already mounted directly
if mount | grep -q "$SRC_PART"; then
    echo "[✖] ERROR: $SRC_PART appears to be mounted directly. Cannot proceed."
    exit 1
fi

# Let user select which device to use
SELECTED_DEVICE=$(select_mapper)
if [ $? -ne 0 ]; then
    # No mappers available, check if we can use source directly or unlock it
    if lsblk -no FSTYPE "$SRC_PART" | grep -q "crypto_LUKS"; then
        echo "[…] No mappers available. Unlocking encrypted partition $SRC_PART as $MAPPER_NAME"
        cryptsetup open "$SRC_PART" "$MAPPER_NAME"
        echo "[✔] Unlocked successfully"
        DEVICE_TO_MOUNT="/dev/mapper/$MAPPER_NAME"
    else
        echo "[…] No mappers available. Using unencrypted partition $SRC_PART directly"
        DEVICE_TO_MOUNT="$SRC_PART"
    fi
elif [ "$SELECTED_DEVICE" = "direct" ]; then
    DEVICE_TO_MOUNT="$SRC_PART"
    echo "[…] Using $SRC_PART directly"
else
    DEVICE_TO_MOUNT="/dev/mapper/$SELECTED_DEVICE"
    echo "[✔] Using existing mapper: $DEVICE_TO_MOUNT"
fi

# Verify device exists
if [ ! -b "$DEVICE_TO_MOUNT" ]; then
    echo "[✖] ERROR: No device at $DEVICE_TO_MOUNT"
    exit 1
fi

# Mount the device
mkdir -p "$SRC_MOUNT"
if ! mountpoint -q "$SRC_MOUNT"; then
    mount "$DEVICE_TO_MOUNT" "$SRC_MOUNT"
    echo "[✔] Mounted $DEVICE_TO_MOUNT at $SRC_MOUNT"
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