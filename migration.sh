#!/bin/bash

# LUKS + Btrfs Migration Script: Source -> Target Drive
# WARNING: Destroys all data on target

set -euxo pipefail
trap 'echo "FAILURE on line $LINENO"; exit 1' ERR

SOURCE_DRIVE="/dev/sdd"
TARGET_DRIVE="/dev/nvme0n1"
TEMP_MOUNT_SOURCE="/mnt/migration_source"
TEMP_MOUNT_TARGET="/mnt/migration_target"

if [[ $EUID -ne 0 ]]; then echo "Must be run as root" >&2; exit 1; fi
read -p "Type 'YES I UNDERSTAND' to continue: " confirm
[[ "$confirm" == "YES I UNDERSTAND" ]] || exit 1

umount -R "$TEMP_MOUNT_SOURCE" 2>/dev/null || true
umount -R "$TEMP_MOUNT_TARGET" 2>/dev/null || true
cryptsetup close migration_source 2>/dev/null || true
cryptsetup close migration_target 2>/dev/null || true
rm -rf "$TEMP_MOUNT_SOURCE" "$TEMP_MOUNT_TARGET"
mkdir -p "$TEMP_MOUNT_SOURCE" "$TEMP_MOUNT_TARGET"

wipefs -af "$TARGET_DRIVE"
sgdisk -Z "$TARGET_DRIVE"
sgdisk -n 1:2048:1955839 -t 1:8300 -c 1:"Linux FS" "$TARGET_DRIVE"
sgdisk -n 2:1955840:4157439 -t 2:ef00 -c 2:"EFI System" "$TARGET_DRIVE"
sgdisk -n 3:4157440:0       -t 3:8300 -c 3:"Encrypted" "$TARGET_DRIVE"
partprobe "$TARGET_DRIVE"
sleep 2

dd if="${SOURCE_DRIVE}1" of="${TARGET_DRIVE}p1" bs=1M status=progress
dd if="${SOURCE_DRIVE}2" of="${TARGET_DRIVE}p2" bs=1M status=progress

read -s -p "Enter LUKS passphrase: " PASSPHRASE; echo

echo "$PASSPHRASE" | cryptsetup open "${SOURCE_DRIVE}3" migration_source
echo "$PASSPHRASE" | cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 \
    --hash sha256 --pbkdf argon2id --pbkdf-memory 1048576 --pbkdf-parallel 4 --pbkdf-force-iterations 5 \
    "${TARGET_DRIVE}p3"
echo "$PASSPHRASE" | cryptsetup open "${TARGET_DRIVE}p3" migration_target

mkfs.btrfs -f /dev/mapper/migration_target
mount -o subvolid=5,noatime /dev/mapper/migration_source "$TEMP_MOUNT_SOURCE"
mount -o subvolid=5,noatime /dev/mapper/migration_target "$TEMP_MOUNT_TARGET"

btrfs subvolume list -o "$TEMP_MOUNT_SOURCE" > /tmp/subvols.txt
while IFS= read -r line; do
    subvol=$(echo "$line" | sed 's/.*path //')
    mkdir -p "$TEMP_MOUNT_TARGET/$(dirname "$subvol")"
    btrfs subvolume create "$TEMP_MOUNT_TARGET/$subvol"
    rsync -aHAXx --numeric-ids --info=progress2 \
        "$TEMP_MOUNT_SOURCE/$subvol/" "$TEMP_MOUNT_TARGET/$subvol/"
done < /tmp/subvols.txt

DEF_ID=$(btrfs subvolume get-default "$TEMP_MOUNT_SOURCE" | awk '{print $2}')
btrfs subvolume set-default "$DEF_ID" "$TEMP_MOUNT_TARGET"
btrfs filesystem resize max "$TEMP_MOUNT_TARGET"

# === SYSTEM CONFIG UPDATE ===
NEW_LUKS_UUID=$(cryptsetup luksUUID "${TARGET_DRIVE}p3")
NEW_BTRFS_UUID=$(btrfs filesystem show /dev/mapper/migration_target | grep uuid: | awk '{print $4}')
NEW_BOOT_UUID=$(blkid -s UUID -o value "${TARGET_DRIVE}p1")
NEW_EFI_UUID=$(blkid -s UUID -o value "${TARGET_DRIVE}p2")

# Replace these manually if known or parse them from original config
OLD_LUKS_UUID="f870024d-954c-4f90-9b99-2a97504959ad"
OLD_BTRFS_UUID="2ae45103-bf20-493b-bf0f-9dca55dac51b"
OLD_BOOT_UUID="8688eff0-0b08-4bab-ac21-c53946969523"
OLD_EFI_UUID="2216-221D"

if [[ -f "$TEMP_MOUNT_TARGET/etc/fstab" ]]; then
    sed -i "s/$OLD_BTRFS_UUID/$NEW_BTRFS_UUID/g" "$TEMP_MOUNT_TARGET/etc/fstab"
    sed -i "s/$OLD_BOOT_UUID/$NEW_BOOT_UUID/g" "$TEMP_MOUNT_TARGET/etc/fstab"
    sed -i "s/$OLD_EFI_UUID/$NEW_EFI_UUID/g" "$TEMP_MOUNT_TARGET/etc/fstab"
fi

if [[ -f "$TEMP_MOUNT_TARGET/etc/crypttab" ]]; then
    sed -i "s/$OLD_LUKS_UUID/$NEW_LUKS_UUID/g" "$TEMP_MOUNT_TARGET/etc/crypttab"
fi

if [[ -f "$TEMP_MOUNT_TARGET/etc/default/grub" ]]; then
    sed -i "s/$OLD_LUKS_UUID/$NEW_LUKS_UUID/g" "$TEMP_MOUNT_TARGET/etc/default/grub"
fi

find "$TEMP_MOUNT_TARGET/etc" -type f \( -name "*.conf" -o -name "*.cfg" \) -exec grep -l "$OLD_LUKS_UUID" {} \; 2>/dev/null | \
    while read -r file; do
        sed -i "s/$OLD_LUKS_UUID/$NEW_LUKS_UUID/g" "$file"
    done

# === BOOTLOADER ===
mkdir -p "$TEMP_MOUNT_TARGET/boot" "$TEMP_MOUNT_TARGET/boot/efi"
mount "${TARGET_DRIVE}p1" "$TEMP_MOUNT_TARGET/boot"
mount "${TARGET_DRIVE}p2" "$TEMP_MOUNT_TARGET/boot/efi"

mount --bind /dev "$TEMP_MOUNT_TARGET/dev"
mount --bind /proc "$TEMP_MOUNT_TARGET/proc"
mount --bind /sys "$TEMP_MOUNT_TARGET/sys"
mount --bind /run "$TEMP_MOUNT_TARGET/run"

if [[ -f "$TEMP_MOUNT_TARGET/etc/arch-release" ]]; then
    chroot "$TEMP_MOUNT_TARGET" mkinitcpio -P
    chroot "$TEMP_MOUNT_TARGET" grub-mkconfig -o /boot/grub/grub.cfg
    chroot "$TEMP_MOUNT_TARGET" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB "$TARGET_DRIVE"
elif [[ -f "$TEMP_MOUNT_TARGET/etc/debian_version" ]]; then
    chroot "$TEMP_MOUNT_TARGET" update-initramfs -u -k all
    chroot "$TEMP_MOUNT_TARGET" update-grub
    chroot "$TEMP_MOUNT_TARGET" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB "$TARGET_DRIVE"
elif [[ -f "$TEMP_MOUNT_TARGET/etc/fedora-release" ]] || [[ -f "$TEMP_MOUNT_TARGET/etc/redhat-release" ]]; then
    chroot "$TEMP_MOUNT_TARGET" dracut --regenerate-all --force
    chroot "$TEMP_MOUNT_TARGET" grub2-mkconfig -o /boot/grub2/grub.cfg
    chroot "$TEMP_MOUNT_TARGET" grub2-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB "$TARGET_DRIVE"
else
    echo "Unknown distribution - manual GRUB update may be required"
fi

umount "$TEMP_MOUNT_TARGET/run" || true
umount "$TEMP_MOUNT_TARGET/sys" || true
umount "$TEMP_MOUNT_TARGET/proc" || true
umount "$TEMP_MOUNT_TARGET/dev" || true
umount "$TEMP_MOUNT_TARGET/boot/efi" || true
umount "$TEMP_MOUNT_TARGET/boot" || true
umount "$TEMP_MOUNT_SOURCE" || true
umount "$TEMP_MOUNT_TARGET" || true
cryptsetup close migration_source || true
cryptsetup close migration_target || true
rm -rf "$TEMP_MOUNT_SOURCE" "$TEMP_MOUNT_TARGET"

echo "Migration complete. System ready to boot from target."
exit 0
