#!/bin/bash

# LUKS + Btrfs Migration Script: 500GB SSD -> 1TB NVMe
# Source: /dev/sdd (500GB) -> Target: /dev/nvme0n1 (1TB)
# 
# WARNING: This script will DESTROY all data on the target drive!
# Make sure you have backups before running this script.

set -euo pipefail

# Configuration
SOURCE_DRIVE="/dev/sdd"
TARGET_DRIVE="/dev/nvme0n1"
TEMP_MOUNT_SOURCE="/mnt/migration_source"
TEMP_MOUNT_TARGET="/mnt/migration_target"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}"
    exit 1
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (use sudo)"
    fi
}

# Verify drives exist
verify_drives() {
    log "Verifying source and target drives..."
    
    if [[ ! -b "$SOURCE_DRIVE" ]]; then
        error "Source drive $SOURCE_DRIVE not found"
    fi
    
    if [[ ! -b "$TARGET_DRIVE" ]]; then
        error "Target drive $TARGET_DRIVE not found"
    fi
    
    # Get drive sizes
    SOURCE_SIZE=$(lsblk -b -d -o SIZE -n "$SOURCE_DRIVE")
    TARGET_SIZE=$(lsblk -b -d -o SIZE -n "$TARGET_DRIVE")
    
    log "Source drive size: $(numfmt --to=iec $SOURCE_SIZE)"
    log "Target drive size: $(numfmt --to=iec $TARGET_SIZE)"
    
    if [[ $TARGET_SIZE -le $SOURCE_SIZE ]]; then
        error "Target drive must be larger than source drive"
    fi
}

# Safety confirmation
confirm_operation() {
    warn "This operation will COMPLETELY WIPE the target drive: $TARGET_DRIVE"
    warn "All existing data on $TARGET_DRIVE will be PERMANENTLY LOST!"
    echo
    echo "Source drive layout:"
    lsblk -f "$SOURCE_DRIVE"
    echo
    echo "Target drive layout (WILL BE DESTROYED):"
    lsblk -f "$TARGET_DRIVE"
    echo
    
    read -p "Type 'YES I UNDERSTAND' to continue: " confirmation
    if [[ "$confirmation" != "YES I UNDERSTAND" ]]; then
        log "Operation cancelled by user"
        exit 0
    fi
}

# Unmount any existing mounts
cleanup_mounts() {
    log "Cleaning up any existing mounts..."
    
    # Unmount target drive partitions if mounted
    for mount_point in $(mount | grep "$TARGET_DRIVE" | awk '{print $3}' | sort -r); do
        warn "Unmounting $mount_point"
        umount "$mount_point" || true
    done
    
    # Close any open LUKS containers on target
    TARGET_PART3="${TARGET_DRIVE}p3"
    if cryptsetup status "$TARGET_PART3" &>/dev/null; then
        warn "Closing existing LUKS container on target"
        cryptsetup close "$TARGET_PART3" || true
    fi
    
    # Create temporary mount points
    mkdir -p "$TEMP_MOUNT_SOURCE" "$TEMP_MOUNT_TARGET"
}

# Create partition table on target drive
create_partitions() {
    log "Creating partition table on target drive..."
    
    # Wipe the target drive
    wipefs -af "$TARGET_DRIVE"
    
    # Create GPT partition table and partitions
    sgdisk -Z "$TARGET_DRIVE"
    sgdisk -n 1:2048:1955839 -t 1:8300 -c 1:"Linux filesystem" "$TARGET_DRIVE"
    sgdisk -n 2:1955840:4157439 -t 2:ef00 -c 2:"EFI System" "$TARGET_DRIVE"
    sgdisk -n 3:4157440:0 -t 3:8300 -c 3:"Linux filesystem" "$TARGET_DRIVE"
    
    # Set the same disk GUID if possible
    DISK_GUID=$(sgdisk -i "$SOURCE_DRIVE" | grep "Disk identifier" | awk '{print $3}')
    if [[ -n "$DISK_GUID" ]]; then
        sgdisk -U "$DISK_GUID" "$TARGET_DRIVE" || warn "Could not set disk GUID"
    fi
    
    # Wait for partitions to be created
    sleep 2
    partprobe "$TARGET_DRIVE"
    sleep 2
}

# Copy boot and EFI partitions
copy_boot_partitions() {
    log "Copying boot partition..."
    dd if="${SOURCE_DRIVE}1" of="${TARGET_DRIVE}p1" bs=1M status=progress
    
    log "Copying EFI partition..."
    dd if="${SOURCE_DRIVE}2" of="${TARGET_DRIVE}p2" bs=1M status=progress
    
    # Update filesystem UUIDs to avoid conflicts
    log "Generating new UUIDs for boot partitions..."
    tune2fs -U random "${TARGET_DRIVE}p1"
    
    # For FAT32, we need to use different method
    NEW_EFI_UUID=$(od -x /dev/urandom | head -1 | awk '{OFS="-"; print $2$3,$4,$5,$6,$7$8$9}' | tr '[:lower:]' '[:upper:]')
    mlabel -i "${TARGET_DRIVE}p2" -s ::${NEW_EFI_UUID:0:8} || warn "Could not change EFI UUID"
}

# Setup LUKS encryption on target
setup_luks() {
    log "Setting up LUKS encryption on target partition..."
    
    # Prompt for passphrase
    echo "Enter the LUKS passphrase for the source drive:"
    read -s SOURCE_PASSPHRASE
    echo
    
    # Test the passphrase on source
    if ! echo "$SOURCE_PASSPHRASE" | cryptsetup open --test-passphrase "${SOURCE_DRIVE}3"; then
        error "Invalid passphrase for source drive"
    fi
    
    # Create LUKS container on target with same parameters as source
    log "Creating LUKS container (this may take a few minutes)..."
    echo "$SOURCE_PASSPHRASE" | cryptsetup luksFormat \
        --type luks2 \
        --cipher aes-xts-plain64 \
        --key-size 512 \
        --hash sha256 \
        --pbkdf argon2id \
        --pbkdf-memory 1048576 \
        --pbkdf-parallel 4 \
        --pbkdf-force-iterations 5 \
        "${TARGET_DRIVE}p3"
    
    # Open both LUKS containers
    log "Opening LUKS containers..."
    echo "$SOURCE_PASSPHRASE" | cryptsetup open "${SOURCE_DRIVE}3" migration_source
    echo "$SOURCE_PASSPHRASE" | cryptsetup open "${TARGET_DRIVE}p3" migration_target
}

# Clone Btrfs filesystem
clone_btrfs() {
    log "Cloning Btrfs filesystem..."
    
    # Create Btrfs filesystem on target
    mkfs.btrfs -f /dev/mapper/migration_target
    
    # Mount both filesystems
    mount -o compress=zstd:1,noatime /dev/mapper/migration_source "$TEMP_MOUNT_SOURCE"
    mount -o compress=zstd:1,noatime /dev/mapper/migration_target "$TEMP_MOUNT_TARGET"
    
    # Get list of subvolumes from source
    log "Discovering Btrfs subvolumes..."
    btrfs subvolume list "$TEMP_MOUNT_SOURCE" > /tmp/subvolumes.txt
    
    # Create all subvolumes on target
    while IFS= read -r line; do
        if [[ $line == *"path "* ]]; then
            subvol_path=$(echo "$line" | sed 's/.*path //')
            log "Creating subvolume: $subvol_path"
            btrfs subvolume create "$TEMP_MOUNT_TARGET/$subvol_path"
        fi
    done < /tmp/subvolumes.txt
    
    # Copy data using rsync for each subvolume
    log "Copying subvolume data (this will take a while)..."
    
    # First, copy the default subvolume
    rsync -aHAXxv --numeric-ids --info=progress2 \
        --exclude="$subvol_path" \
        "$TEMP_MOUNT_SOURCE/" "$TEMP_MOUNT_TARGET/"
    
    # Then copy each subvolume
    while IFS= read -r line; do
        if [[ $line == *"path "* ]]; then
            subvol_path=$(echo "$line" | sed 's/.*path //')
            log "Copying subvolume data: $subvol_path"
            rsync -aHAXxv --numeric-ids --info=progress2 \
                "$TEMP_MOUNT_SOURCE/$subvol_path/" "$TEMP_MOUNT_TARGET/$subvol_path/"
        fi
    done < /tmp/subvolumes.txt
    
    # Set default subvolume if needed
    DEFAULT_SUBVOL=$(btrfs subvolume get-default "$TEMP_MOUNT_SOURCE" | awk '{print $2}')
    if [[ "$DEFAULT_SUBVOL" != "5" ]]; then
        btrfs subvolume set-default "$DEFAULT_SUBVOL" "$TEMP_MOUNT_TARGET"
    fi
}

# Resize Btrfs filesystem
resize_btrfs() {
    log "Resizing Btrfs filesystem to use full space..."
    btrfs filesystem resize max "$TEMP_MOUNT_TARGET"
    
    # Show new filesystem size
    log "New filesystem size:"
    btrfs filesystem show /dev/mapper/migration_target
}

# Update UUIDs and system configuration  
update_system_config() {
    log "Updating system configuration..."
    
    # Get UUIDs from both drives
    NEW_LUKS_UUID=$(cryptsetup luksUUID "${TARGET_DRIVE}p3")
    OLD_LUKS_UUID="f870024d-954c-4f90-9b99-2a97504959ad"
    
    NEW_BTRFS_UUID=$(btrfs filesystem show /dev/mapper/migration_target | grep uuid: | awk '{print $4}')
    OLD_BTRFS_UUID="2ae45103-bf20-493b-bf0f-9dca55dac51b"
    
    # Get new boot and EFI partition UUIDs
    NEW_BOOT_UUID=$(blkid -s UUID -o value "${TARGET_DRIVE}p1")
    OLD_BOOT_UUID="8688eff0-0b08-4bab-ac21-c53946969523"
    
    NEW_EFI_UUID=$(blkid -s UUID -o value "${TARGET_DRIVE}p2")
    OLD_EFI_UUID="2216-221D"
    
    log "Old LUKS UUID: $OLD_LUKS_UUID -> New: $NEW_LUKS_UUID"
    log "Old Btrfs UUID: $OLD_BTRFS_UUID -> New: $NEW_BTRFS_UUID"  
    log "Old Boot UUID: $OLD_BOOT_UUID -> New: $NEW_BOOT_UUID"
    log "Old EFI UUID: $OLD_EFI_UUID -> New: $NEW_EFI_UUID"
    
    # Update /etc/fstab with all new UUIDs
    if [[ -f "$TEMP_MOUNT_TARGET/etc/fstab" ]]; then
        log "Updating /etc/fstab with new UUIDs..."
        sed -i "s/$OLD_BTRFS_UUID/$NEW_BTRFS_UUID/g" "$TEMP_MOUNT_TARGET/etc/fstab"
        sed -i "s/$OLD_BOOT_UUID/$NEW_BOOT_UUID/g" "$TEMP_MOUNT_TARGET/etc/fstab"
        sed -i "s/$OLD_EFI_UUID/$NEW_EFI_UUID/g" "$TEMP_MOUNT_TARGET/etc/fstab"
    fi
    
    # Update /etc/crypttab if it exists
    if [[ -f "$TEMP_MOUNT_TARGET/etc/crypttab" ]]; then
        log "Updating /etc/crypttab..."
        sed -i "s/$OLD_LUKS_UUID/$NEW_LUKS_UUID/g" "$TEMP_MOUNT_TARGET/etc/crypttab"
    fi
    
    # Update GRUB configuration
    if [[ -f "$TEMP_MOUNT_TARGET/etc/default/grub" ]]; then
        log "Updating GRUB configuration..."
        sed -i "s/$OLD_LUKS_UUID/$NEW_LUKS_UUID/g" "$TEMP_MOUNT_TARGET/etc/default/grub"
    fi
    
    # Find and update any other config files with old UUIDs
    find "$TEMP_MOUNT_TARGET/etc" -type f \( -name "*.conf" -o -name "*.cfg" \) -exec grep -l "$OLD_LUKS_UUID" {} \; 2>/dev/null | \
        while read -r file; do
            log "Updating LUKS UUID in $file..."
            sed -i "s/$OLD_LUKS_UUID/$NEW_LUKS_UUID/g" "$file"
        done
}

# Update bootloader configuration
update_bootloader() {
    log "Updating bootloader configuration..."
    
    # Mount boot and EFI partitions on target filesystem
    mkdir -p "$TEMP_MOUNT_TARGET/boot" "$TEMP_MOUNT_TARGET/boot/efi"
    mount "${TARGET_DRIVE}p1" "$TEMP_MOUNT_TARGET/boot"
    mount "${TARGET_DRIVE}p2" "$TEMP_MOUNT_TARGET/boot/efi"
    
    # Bind mount necessary directories for chroot
    mount --bind /dev "$TEMP_MOUNT_TARGET/dev"
    mount --bind /proc "$TEMP_MOUNT_TARGET/proc"
    mount --bind /sys "$TEMP_MOUNT_TARGET/sys"
    mount --bind /run "$TEMP_MOUNT_TARGET/run"
    
    # Detect distribution and update accordingly
    if [[ -f "$TEMP_MOUNT_TARGET/etc/arch-release" ]]; then
        log "Detected Arch Linux - updating initramfs and GRUB..."
        chroot "$TEMP_MOUNT_TARGET" mkinitcpio -P
        chroot "$TEMP_MOUNT_TARGET" grub-mkconfig -o /boot/grub/grub.cfg
        chroot "$TEMP_MOUNT_TARGET" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB "${TARGET_DRIVE}"
        
    elif [[ -f "$TEMP_MOUNT_TARGET/etc/debian_version" ]]; then
        log "Detected Debian/Ubuntu - updating initramfs and GRUB..."
        chroot "$TEMP_MOUNT_TARGET" update-initramfs -u -k all
        chroot "$TEMP_MOUNT_TARGET" update-grub
        chroot "$TEMP_MOUNT_TARGET" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB "${TARGET_DRIVE}"
        
    elif [[ -f "$TEMP_MOUNT_TARGET/etc/fedora-release" ]] || [[ -f "$TEMP_MOUNT_TARGET/etc/redhat-release" ]]; then
        log "Detected Red Hat/Fedora - updating initramfs and GRUB..."
        chroot "$TEMP_MOUNT_TARGET" dracut --regenerate-all --force
        chroot "$TEMP_MOUNT_TARGET" grub2-mkconfig -o /boot/grub2/grub.cfg
        chroot "$TEMP_MOUNT_TARGET" grub2-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB "${TARGET_DRIVE}"
        
    else
        warn "Unknown distribution - you may need to manually update initramfs and GRUB"
        log "Commands to run after reboot:"
        log "  sudo mkinitcpio -P  (Arch)"
        log "  sudo update-initramfs -u  (Debian/Ubuntu)"
        log "  sudo dracut --regenerate-all --force  (RHEL/Fedora)"
        log "  sudo grub-mkconfig -o /boot/grub/grub.cfg"
        log "  sudo grub-install ${TARGET_DRIVE}"
    fi
    
    # Unmount chroot directories
    umount "$TEMP_MOUNT_TARGET/run" 2>/dev/null || true
    umount "$TEMP_MOUNT_TARGET/sys" 2>/dev/null || true  
    umount "$TEMP_MOUNT_TARGET/proc" 2>/dev/null || true
    umount "$TEMP_MOUNT_TARGET/dev" 2>/dev/null || true
    umount "$TEMP_MOUNT_TARGET/boot/efi" 2>/dev/null || true
    umount "$TEMP_MOUNT_TARGET/boot" 2>/dev/null || true
}
    log "Cleaning up..."
    
    # Unmount filesystems
    umount "$TEMP_MOUNT_SOURCE" 2>/dev/null || true
    umount "$TEMP_MOUNT_TARGET" 2>/dev/null || true
    
    # Close LUKS containers
    cryptsetup close migration_source 2>/dev/null || true
    cryptsetup close migration_target 2>/dev/null || true
    
    # Remove temporary directories
    rmdir "$TEMP_MOUNT_SOURCE" 2>/dev/null || true
    rmdir "$TEMP_MOUNT_TARGET" 2>/dev/null || true
    
    # Clean up temporary files
    rm -f /tmp/subvolumes.txt
}

# Main execution
main() {
    log "Starting LUKS + Btrfs migration from $SOURCE_DRIVE to $TARGET_DRIVE"
    
    check_root
    verify_drives
    confirm_operation
    
    # Set up cleanup trap
    trap cleanup EXIT
    
    cleanup_mounts
    create_partitions
    copy_boot_partitions
    setup_luks
    clone_btrfs
    resize_btrfs
    update_system_config
    update_bootloader
    
    log "Migration completed successfully!"
    echo
    log "The system is now ready to boot from ${TARGET_DRIVE}!"
    echo
    warn "IMPORTANT FINAL STEPS:"
    echo "1. Reboot and enter BIOS/UEFI settings"
    echo "2. Change boot order to prioritize ${TARGET_DRIVE}"
    echo "3. Save and exit BIOS"
    echo "4. Test that system boots correctly from new drive"
    echo "5. Once confirmed working, you can safely remove or repurpose the old drive"
    echo
    log "If boot fails, you can always boot from the original drive ${SOURCE_DRIVE}"
}

# Run main function
main "$@"
