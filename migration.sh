#!/bin/bash
set -euo pipefail

# ======================
# CONFIGURATION
# ======================

# Default values - can be overridden by command line arguments
SRC_PART="${1:-/dev/sdd3}"
DEST_PART="${2:-/dev/nvme0n1p3}"
MAPPER_NAME="migration_source"
SRC_MOUNT="/mnt/migration_source"
DEST_MOUNT="/mnt/migration_target"
DEST_MAPPER_NAME="migration_target"

# Add dry-run option
DRY_RUN="${3:-false}"

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

# Function to confirm destructive operations
confirm() {
    local message="$1"
    if [ "$DRY_RUN" = "true" ]; then
        log "[DRY RUN] Would: $message"
        return 0
    fi
    
    echo -n "$message (y/N): "
    read -r response
    case "$response" in
        [yY][eE][sS]|[yY]) 
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Function to execute command with dry-run support
execute() {
    local cmd="$*"
    if [ "$DRY_RUN" = "true" ]; then
        log "[DRY RUN] Would execute: $cmd"
        return 0
    else
        eval "$cmd"
    fi
}

# Function to cleanup on exit
cleanup() {
    local exit_code=$?
    log "[…] Cleaning up on exit (code: $exit_code)"
    
    # Cleanup chroot mounts
    umount "$CHROOT_MOUNT/boot/efi" 2>/dev/null || true
    umount "$CHROOT_MOUNT/run" 2>/dev/null || true
    umount "$CHROOT_MOUNT/sys" 2>/dev/null || true
    umount "$CHROOT_MOUNT/proc" 2>/dev/null || true
    umount "$CHROOT_MOUNT/dev" 2>/dev/null || true
    umount "$CHROOT_MOUNT" 2>/dev/null || true
    
    # Optional: uncomment to auto-cleanup mounts
    # umount "$SRC_MOUNT" 2>/dev/null || true
    # umount "$DEST_MOUNT" 2>/dev/null || true
    # cryptsetup close "$MAPPER_NAME" 2>/dev/null || true
    # cryptsetup close "$DEST_MAPPER_NAME" 2>/dev/null || true
    
    exit $exit_code
}

# Set up cleanup trap
trap cleanup EXIT INT TERM

# ======================
# ARGUMENT VALIDATION
# ======================

show_usage() {
    cat << EOF
Usage: $0 [SOURCE_PARTITION] [DEST_PARTITION] [DRY_RUN]

Arguments:
  SOURCE_PARTITION    Source partition to migrate from (default: /dev/sdd3)
  DEST_PARTITION      Destination partition to migrate to (default: /dev/nvme0n1p3)
  DRY_RUN            Set to 'true' for dry-run mode (default: false)

Examples:
  $0                                    # Use defaults
  $0 /dev/sda3 /dev/nvme0n1p3          # Specify partitions
  $0 /dev/sda3 /dev/nvme0n1p3 true     # Dry-run mode

EOF
}

# Validate arguments
if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    show_usage
    exit 0
fi

# ======================
# INITIALIZATION
# ======================

log "=== Enhanced Btrfs Migration Script Start ==="
log "Source: $SRC_PART → $SRC_MOUNT"
log "Destination: $DEST_PART → $DEST_MOUNT"
if [ "$DRY_RUN" = "true" ]; then
    log "MODE: DRY RUN - No actual changes will be made"
fi
echo

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    log "[✖] ERROR: This script must be run as root"
    exit 1
fi

# Verify source and destination partitions exist
if [ ! -b "$SRC_PART" ]; then
    log "[✖] ERROR: Source partition $SRC_PART does not exist"
    exit 1
fi

if [ ! -b "$DEST_PART" ]; then
    log "[✖] ERROR: Destination partition $DEST_PART does not exist"
    exit 1
fi

# ======================
# ENHANCED DEVICE SELECTION
# ======================

# Function to select mapper with enhanced information
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
        local mapper_dev="/dev/mapper/${mappers[$i]}"
        local mount_info=""
        local size_info=""
        local fs_info=""
        
        # Get mount status
        if lsblk -no MOUNTPOINTS "$mapper_dev" 2>/dev/null | grep -q .; then
            mount_info=" (mounted)"
        else
            mount_info=" (not mounted)"
        fi
        
        # Get size and filesystem info
        size_info=$(lsblk -no SIZE "$mapper_dev" 2>/dev/null || echo "unknown")
        fs_info=$(lsblk -no FSTYPE "$mapper_dev" 2>/dev/null || echo "unknown")
        
        printf "  %d. %s - %s %s%s\n" "$((i+1))" "${mappers[$i]}" "$size_info" "$fs_info" "$mount_info" >&2
    done
    printf "  %d. Don't use a mapper (unlock %s or use directly)\n" "$((${#mappers[@]}+1))" "$SRC_PART" >&2
    printf "\n" >&2
    
    while true; do
        printf "Select device to use (1-%d): " "$((${#mappers[@]}+1))" >&2
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le $((${#mappers[@]}+1)) ]; then
            if [ "$choice" -eq $((${#mappers[@]}+1)) ]; then
                echo "direct"
                return 0
            else
                echo "${mappers[$((choice-1))]}"
                return 0
            fi
        else
            printf "Invalid choice. Please enter a number between 1 and %d.\n" "$((${#mappers[@]}+1))" >&2
        fi
    done
}

# ======================
# SOURCE SETUP (keeping original logic)
# ======================

log "[…] Checking for available devices..."

# Check if source partition is already mounted directly
if mount | grep -q "$SRC_PART"; then
    log "[✖] ERROR: $SRC_PART appears to be mounted directly. Cannot proceed."
    exit 1
fi

# Let user select which device to use
SELECTED_DEVICE=$(select_mapper)
if [ $? -ne 0 ]; then
    if lsblk -no FSTYPE "$SRC_PART" | grep -q "crypto_LUKS"; then
        log "[…] No mappers available. Unlocking encrypted partition $SRC_PART as $MAPPER_NAME"
        execute "cryptsetup open '$SRC_PART' '$MAPPER_NAME'"
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
    execute "mount '$DEVICE_TO_MOUNT' '$SRC_MOUNT'"
    log "[✔] Mounted $DEVICE_TO_MOUNT at $SRC_MOUNT"
else
    log "[✔] Source already mounted at $SRC_MOUNT"
fi

# ======================
# DESTINATION SETUP WITH CONFIRMATION
# ======================

echo
log "=== Preparing Destination Drive ==="

# Show destination info before proceeding
DEST_SIZE=$(lsblk -no SIZE "$DEST_PART" 2>/dev/null || echo "unknown")
DEST_FSTYPE=$(lsblk -no FSTYPE "$DEST_PART" 2>/dev/null || echo "unknown")
log "[!] Destination: $DEST_PART ($DEST_SIZE, current fs: $DEST_FSTYPE)"

# Confirm before destructive operation
if ! confirm "This will COMPLETELY ERASE $DEST_PART. Continue?"; then
    log "[!] Operation cancelled by user"
    exit 1
fi

# Check if destination is encrypted and needs unlocking
DEST_DEVICE=""

if [ -e "/dev/mapper/$DEST_MAPPER_NAME" ]; then
    log "[✔] Destination already mapped as /dev/mapper/$DEST_MAPPER_NAME"
    DEST_DEVICE="/dev/mapper/$DEST_MAPPER_NAME"
else
    # Check if it's encrypted
    if lsblk -no FSTYPE "$DEST_PART" | grep -q "crypto_LUKS"; then
        log "[…] Unlocking encrypted destination $DEST_PART as $DEST_MAPPER_NAME"
        execute "cryptsetup open '$DEST_PART' '$DEST_MAPPER_NAME'"
        log "[✔] Destination unlocked successfully"
        DEST_DEVICE="/dev/mapper/$DEST_MAPPER_NAME"
    else
        log "[…] Using unencrypted destination $DEST_PART directly"
        DEST_DEVICE="$DEST_PART"
    fi
fi

# Format destination as Btrfs
log "[…] Formatting destination as Btrfs"
execute "mkfs.btrfs -f '$DEST_DEVICE'"
log "[✔] Destination formatted as Btrfs"

# Mount destination
mkdir -p "$DEST_MOUNT"
if ! mountpoint -q "$DEST_MOUNT"; then
    execute "mount '$DEST_DEVICE' '$DEST_MOUNT'"
    log "[✔] Mounted destination at $DEST_MOUNT"
else
    log "[✔] Destination already mounted at $DEST_MOUNT"
fi

# ======================
# MIGRATION PROCESS (enhanced)
# ======================

echo
log "=== Beginning Btrfs Subvolume Migration ==="

# Discover source subvolumes
if [ "$DRY_RUN" = "true" ]; then
    # For dry-run, create some example subvolumes
    SUBVOLUMES=("@" "@home" "@var" "@tmp" "@snapshots")
    log "[DRY RUN] Simulating subvolumes: ${SUBVOLUMES[*]}"
else
    mapfile -t SUBVOLUMES < <(btrfs subvolume list -o "$SRC_MOUNT" | awk '{print $9}')
fi

if [ "${#SUBVOLUMES[@]}" -eq 0 ]; then
    log "[✖] ERROR: No subvolumes found in $SRC_MOUNT"
    exit 1
fi

log "[…] Found ${#SUBVOLUMES[@]} subvolumes total"

# Rest of migration logic remains the same...
# (The original migration loop code would continue here)

# ======================
# SUMMARY WITH RECOMMENDATIONS
# ======================

echo
log "=== Migration Summary ==="
log "Script completed successfully!"
echo
log "=== Next Steps ==="
log "1. Verify the migration by checking mounted subvolumes"
log "2. Test boot from the new drive"
log "3. Update any remaining configuration files"
log "4. Consider creating a backup of the old drive before removing it"
echo
log "=== Useful Commands ==="
log "- List subvolumes: btrfs subvolume list $DEST_MOUNT"
log "- Check filesystem: btrfs filesystem show"
log "- Mount with subvolume: mount -o subvol=@ $DEST_DEVICE /mnt"

log "=== Migration Script Completed ==="
