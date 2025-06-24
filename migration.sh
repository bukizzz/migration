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
# UTILITY FUNCTIONS
# ======================

# Function to check if a subvolume should be skipped
should_skip_subvolume() {
    local subvol="$1"
    
    # Check each skip pattern
    if [[ "$subvol" == *"swap"* ]] || [[ "$subvol" == "@swap" ]] || \
       [[ "$subvol" == *"snapshots"* ]] || [[ "$subvol" == "@snapshots" ]] || \
       [[ "$subvol" == "@.snapshots" ]]; then
        return 0  # Should skip
    fi
    return 1  # Should not skip
}

# Function to log with timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# ======================
# INITIALIZATION
# ======================

log "=== Migration Script Start ==="
log "Source: $SRC_PART → $SRC_MOUNT"
log "Destination: $DEST_PART → $DEST_MOUNT"
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
        if lsblk -no MOUNTPOINTS "/dev/mapper/${mappers[$i]}" 2>/dev/null | grep -q .; then
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
log "[…] Checking for available devices..."

# Check if source partition is already mounted directly
if mount | grep -q "$SRC_PART"; then
    log "[✖] ERROR: $SRC_PART appears to be mounted directly. Cannot proceed."
    exit 1
fi

# Let user select which device to use
SELECTED_DEVICE=$(select_mapper)
if [ $? -ne 0 ]; then
    # No mappers available, check if we can use source directly or unlock it
    if lsblk -no FSTYPE "$SRC_PART" | grep -q "crypto_LUKS"; then
        log "[…] No mappers available. Unlocking encrypted partition $SRC_PART as $MAPPER_NAME"
        cryptsetup open "$SRC_PART" "$MAPPER_NAME"
        log "[✔] Unlocked successfully"
        DEVICE_TO_MOUNT="/dev/mapper/$MAPPER_NAME"
    else
        log "[…] No mappers available. Using unencrypted partition $SRC_PART directly"
        DEVICE_TO_MOUNT="$SRC_PART"
    fi
elif [ "$SELECTED_DEVICE" = "direct" ]; then
    DEVICE_TO_MOUNT="$SRC_PART"
    log "[…] Using $SRC_PART directly"
else
    DEVICE_TO_MOUNT="/dev/mapper/$SELECTED_DEVICE"
    log "[✔] Using existing mapper: $DEVICE_TO_MOUNT"
fi

# Verify device exists
if [ ! -b "$DEVICE_TO_MOUNT" ]; then
    log "[✖] ERROR: No device at $DEVICE_TO_MOUNT"
    exit 1
fi

# Mount the device
mkdir -p "$SRC_MOUNT"
if ! mountpoint -q "$SRC_MOUNT"; then
    mount "$DEVICE_TO_MOUNT" "$SRC_MOUNT"
    log "[✔] Mounted $DEVICE_TO_MOUNT at $SRC_MOUNT"
else
    log "[✔] Source already mounted at $SRC_MOUNT"
fi

# ======================
# PREPARE AND MOUNT DESTINATION
# ======================

echo
log "=== Preparing Destination Drive ==="

# Check if destination is encrypted and needs unlocking
DEST_MAPPER_NAME="migration_target"
DEST_DEVICE=""

if [ -e "/dev/mapper/$DEST_MAPPER_NAME" ]; then
    log "[✔] Destination already mapped as /dev/mapper/$DEST_MAPPER_NAME"
    DEST_DEVICE="/dev/mapper/$DEST_MAPPER_NAME"
else
    # Check if it's encrypted
    if lsblk -no FSTYPE "$DEST_PART" | grep -q "crypto_LUKS"; then
        log "[…] Unlocking encrypted destination $DEST_PART as $DEST_MAPPER_NAME"
        cryptsetup open "$DEST_PART" "$DEST_MAPPER_NAME"
        log "[✔] Destination unlocked successfully"
        DEST_DEVICE="/dev/mapper/$DEST_MAPPER_NAME"
    else
        log "[…] Using unencrypted destination $DEST_PART directly"
        DEST_DEVICE="$DEST_PART"
    fi
fi

# Format destination as Btrfs (this wipes it clean every time)
log "[…] Formatting destination as Btrfs (this will erase all data)"
mkfs.btrfs -f "$DEST_DEVICE"
log "[✔] Destination formatted as Btrfs"

# Mount destination
mkdir -p "$DEST_MOUNT"
if ! mountpoint -q "$DEST_MOUNT"; then
    mount "$DEST_DEVICE" "$DEST_MOUNT"
    log "[✔] Mounted destination at $DEST_MOUNT"
else
    log "[✔] Destination already mounted at $DEST_MOUNT"
fi

# ======================
# MIGRATION BEGINS
# ======================

echo
log "=== Beginning Btrfs Subvolume Migration ==="

# Discover source subvolumes
mapfile -t SUBVOLUMES < <(btrfs subvolume list -o "$SRC_MOUNT" | awk '{print $9}')

if [ "${#SUBVOLUMES[@]}" -eq 0 ]; then
    log "[✖] ERROR: No subvolumes found in $SRC_MOUNT"
    exit 1
fi

log "[…] Found ${#SUBVOLUMES[@]} subvolumes total"

# Count subvolumes that will be migrated
MIGRATE_COUNT=0
SKIP_COUNT=0

log "[…] Analyzing subvolumes..."
for SUBVOL in "${SUBVOLUMES[@]}"; do
    if should_skip_subvolume "$SUBVOL"; then
        SKIP_COUNT=$((SKIP_COUNT + 1))
        log "[DEBUG] Will skip: $SUBVOL"
    else
        MIGRATE_COUNT=$((MIGRATE_COUNT + 1))
        log "[DEBUG] Will migrate: $SUBVOL"
    fi
done

log "[…] Will migrate $MIGRATE_COUNT subvolumes, skipping $SKIP_COUNT"
echo

# Migration counters
MIGRATED=0
FAILED=0

for SUBVOL in "${SUBVOLUMES[@]}"; do
    log "[→] Processing subvolume: $SUBVOL"

    # Check if this subvolume should be skipped
    if should_skip_subvolume "$SUBVOL"; then
        log "[!] Skipping subvolume: $SUBVOL (matches skip pattern)"
        echo
        continue
    fi

    SRC_PATH="$SRC_MOUNT/$SUBVOL"
    SNAPSHOT_NAME="${SUBVOL}_snapshot_$(date +%s)"
    SNAPSHOT_PATH="$SRC_MOUNT/$SNAPSHOT_NAME"

    # Verify source subvolume exists
    if [ ! -d "$SRC_PATH" ]; then
        log "[!] WARNING: Source path $SRC_PATH does not exist - skipping"
        FAILED=$((FAILED + 1))
        echo
        continue
    fi

    # Create read-only snapshot with error handling
    log "[…] Creating read-only snapshot: $SNAPSHOT_NAME"
    if ! btrfs subvolume snapshot -r "$SRC_PATH" "$SNAPSHOT_PATH" 2>/dev/null; then
        log "[!] WARNING: Failed to create snapshot of $SUBVOL (likely in use or inaccessible)"
        FAILED=$((FAILED + 1))
        echo
        continue
    fi
    
    # Send snapshot to destination with error handling
    log "[…] Sending snapshot to destination"
    if ! btrfs send "$SNAPSHOT_PATH" 2>/dev/null | btrfs receive "$DEST_MOUNT" 2>/dev/null; then
        log "[!] WARNING: Failed to send $SUBVOL to destination"
        # Clean up the temporary snapshot
        if [ -d "$SNAPSHOT_PATH" ]; then
            btrfs subvolume delete "$SNAPSHOT_PATH" 2>/dev/null || true
        fi
        FAILED=$((FAILED + 1))
        echo
        continue
    fi
    
    # Rename received snapshot to original name
    if [ -d "$DEST_MOUNT/$SNAPSHOT_NAME" ]; then
        log "[…] Renaming received snapshot to $SUBVOL"
        if ! mv "$DEST_MOUNT/$SNAPSHOT_NAME" "$DEST_MOUNT/$SUBVOL" 2>/dev/null; then
            log "[!] WARNING: Failed to rename snapshot for $SUBVOL"
            # Try to clean up
            btrfs subvolume delete "$DEST_MOUNT/$SNAPSHOT_NAME" 2>/dev/null || true
            btrfs subvolume delete "$SNAPSHOT_PATH" 2>/dev/null || true
            FAILED=$((FAILED + 1))
            echo
            continue
        fi
    else
        log "[!] WARNING: Expected snapshot $SNAPSHOT_NAME not found at destination"
        # Clean up source snapshot
        btrfs subvolume delete "$SNAPSHOT_PATH" 2>/dev/null || true
        FAILED=$((FAILED + 1))
        echo
        continue
    fi
    
    # Clean up the temporary snapshot
    log "[…] Cleaning up temporary snapshot"
    if ! btrfs subvolume delete "$SNAPSHOT_PATH" 2>/dev/null; then
        log "[!] WARNING: Failed to clean up temporary snapshot $SNAPSHOT_PATH"
        # Non-fatal, continue
    fi
    
    log "[✔] Successfully migrated $SUBVOL"
    MIGRATED=$((MIGRATED + 1))
    echo
done

echo
log "=== Btrfs Migration Complete ==="
log "Successfully migrated: $MIGRATED subvolumes"
log "Failed migrations: $FAILED subvolumes"
log "Skipped: $SKIP_COUNT subvolumes"

# ======================
# BOOTLOADER CONFIGURATION
# ======================

if [ $MIGRATED -gt 0 ] && [ $FAILED -eq 0 ]; then
    echo
    log "=== Configuring Bootloader ==="
    
    # Find the root subvolume (usually @ or root)
    ROOT_SUBVOL=""
    if [ -d "$DEST_MOUNT/@" ]; then
        ROOT_SUBVOL="@"
    elif [ -d "$DEST_MOUNT/root" ]; then
        ROOT_SUBVOL="root"
    else
        # Try to find any subvolume that looks like root
        for subvol in "$DEST_MOUNT"/*; do
            if [ -d "$subvol" ] && [ -d "$subvol/etc" ] && [ -d "$subvol/usr" ]; then
                ROOT_SUBVOL=$(basename "$subvol")
                break
            fi
        done
    fi
    
    if [ -z "$ROOT_SUBVOL" ]; then
        log "[!] WARNING: Could not identify root subvolume. Skipping bootloader configuration."
        log "[!] You will need to manually configure GRUB and initramfs."
    else
        log "[…] Found root subvolume: $ROOT_SUBVOL"
        
        # Create temporary mount point for chroot
        CHROOT_MOUNT="/mnt/migration_chroot"
        mkdir -p "$CHROOT_MOUNT"
        
        # Mount root subvolume for chroot
        log "[…] Mounting root subvolume for chroot"
        if mount -o subvol="$ROOT_SUBVOL" "$DEST_DEVICE" "$CHROOT_MOUNT"; then
            log "[✔] Root subvolume mounted at $CHROOT_MOUNT"
            
            # Mount essential filesystems for chroot
            log "[…] Mounting essential filesystems for chroot"
            mount --bind /dev "$CHROOT_MOUNT/dev" || true
            mount --bind /proc "$CHROOT_MOUNT/proc" || true
            mount --bind /sys "$CHROOT_MOUNT/sys" || true
            mount --bind /run "$CHROOT_MOUNT/run" || true
            
            # Mount EFI partition if it exists
            EFI_PART=""
            if [ -d "/boot/efi" ] && mountpoint -q "/boot/efi"; then
                EFI_PART=$(findmnt -n -o SOURCE /boot/efi 2>/dev/null || true)
                if [ -n "$EFI_PART" ]; then
                    mkdir -p "$CHROOT_MOUNT/boot/efi"
                    mount "$EFI_PART" "$CHROOT_MOUNT/boot/efi" || true
                    log "[✔] EFI partition mounted"
                fi
            fi
            
            # Update initramfs
            log "[…] Updating initramfs in chroot environment"
            if chroot "$CHROOT_MOUNT" /bin/bash -c "update-initramfs -u -k all" 2>/dev/null; then
                log "[✔] Initramfs updated successfully"
            else
                log "[!] WARNING: Failed to update initramfs"
            fi
            
            # Update GRUB configuration
            log "[…] Updating GRUB configuration"
            if chroot "$CHROOT_MOUNT" /bin/bash -c "update-grub" 2>/dev/null; then
                log "[✔] GRUB configuration updated"
            else
                log "[!] WARNING: Failed to update GRUB configuration"
            fi
            
            # Install GRUB to the target disk (get disk from partition)
            TARGET_DISK=$(lsblk -no PKNAME "$DEST_PART" 2>/dev/null | head -1)
            if [ -n "$TARGET_DISK" ]; then
                log "[…] Installing GRUB to /dev/$TARGET_DISK"
                if chroot "$CHROOT_MOUNT" /bin/bash -c "grub-install /dev/$TARGET_DISK" 2>/dev/null; then
                    log "[✔] GRUB installed successfully"
                else
                    log "[!] WARNING: Failed to install GRUB"
                fi
            else
                log "[!] WARNING: Could not determine target disk for GRUB installation"
            fi
            
            # Update fstab if necessary
            log "[…] Checking and updating fstab"
            FSTAB_PATH="$CHROOT_MOUNT/etc/fstab"
            if [ -f "$FSTAB_PATH" ]; then
                # Backup original fstab
                cp "$FSTAB_PATH" "$FSTAB_PATH.backup.$(date +%s)"
                
                # Update fstab with new device UUID
                DEST_UUID=$(blkid -s UUID -o value "$DEST_DEVICE" 2>/dev/null || true)
                if [ -n "$DEST_UUID" ]; then
                    log "[…] Updating fstab with new UUID: $DEST_UUID"
                    # This is a basic update - you may need to customize based on your fstab format
                    sed -i.bak "s|UUID=[a-f0-9-]*|UUID=$DEST_UUID|g" "$FSTAB_PATH"
                    log "[✔] fstab updated"
                else
                    log "[!] WARNING: Could not get UUID for destination device"
                fi
            else
                log "[!] WARNING: No fstab found at $FSTAB_PATH"
            fi
            
            # Cleanup chroot mounts
            log "[…] Cleaning up chroot mounts"
            umount "$CHROOT_MOUNT/boot/efi" 2>/dev/null || true
            umount "$CHROOT_MOUNT/run" 2>/dev/null || true
            umount "$CHROOT_MOUNT/sys" 2>/dev/null || true
            umount "$CHROOT_MOUNT/proc" 2>/dev/null || true
            umount "$CHROOT_MOUNT/dev" 2>/dev/null || true
            umount "$CHROOT_MOUNT" 2>/dev/null || true
            
            log "[✔] Bootloader configuration completed"
        else
            log "[!] WARNING: Failed to mount root subvolume for chroot"
            log "[!] You will need to manually configure GRUB and initramfs"
        fi
    fi
else
    log "[!] Skipping bootloader configuration due to migration failures"
fi

# ======================
# OPTIONAL CLEANUP
# ======================

# Uncomment these lines if you want automatic cleanup
# log "[…] Cleaning up mounts and mappings"
# umount "$SRC_MOUNT" 2>/dev/null || true
# umount "$DEST_MOUNT" 2>/dev/null || true
# cryptsetup close "$MAPPER_NAME" 2>/dev/null || true
cryptsetup close "$DEST_MAPPER_NAME" 2>/dev/null || true

# ======================
# SUMMARY
# ======================

echo
log "=== Migration Summary ==="
log "Total subvolumes found: ${#SUBVOLUMES[@]}"
log "Successfully migrated: $MIGRATED"
log "Failed migrations: $FAILED"
log "Skipped (swap/snapshots): $SKIP_COUNT"

if [ $FAILED -gt 0 ]; then
    log "[!] Some migrations failed. Check the log above for details."
    exit 1
else
    log "[✔] All eligible subvolumes migrated successfully!"
fi

log "=== Migration Script Completed ==="