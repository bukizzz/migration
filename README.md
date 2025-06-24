# LUKS + Btrfs Drive Migration Script

A comprehensive bash script for migrating an encrypted Btrfs system from a smaller drive to a larger one while preserving all data, subvolumes, and configurations.

## Overview

This script safely clones a LUKS-encrypted Btrfs filesystem from one drive to another, automatically expanding the filesystem to use the full capacity of the target drive. It's designed for system migrations where you want to upgrade to a larger drive without reinstalling.

## Features

- ✅ **Safe migration** - Source drive is never modified (read-only operations)
- ✅ **Complete preservation** - All Btrfs subvolumes, data, and configurations preserved
- ✅ **Automatic expansion** - Filesystem automatically resized to use full target drive capacity
- ✅ **Bootloader handling** - Automatically updates GRUB, initramfs, and all boot configurations
- ✅ **Multi-distro support** - Detects and handles Arch, Debian/Ubuntu, RHEL/Fedora
- ✅ **UUID management** - Automatically updates all configuration files with new UUIDs
- ✅ **Error handling** - Comprehensive error checking and cleanup on failure

## Use Case

Perfect for scenarios like:
- Upgrading from 500GB to 1TB drive
- Moving system from SATA SSD to NVMe
- Migrating to faster/newer storage while preserving entire system setup
- Expanding encrypted system partitions

## Prerequisites

### Required Tools
```bash
# Arch Linux
sudo pacman -S rsync cryptsetup btrfs-progs gptfdisk dosfstools

# Debian/Ubuntu  
sudo apt install rsync cryptsetup-bin btrfs-progs gdisk dosfstools

# RHEL/Fedora
sudo dnf install rsync cryptsetup btrfs-progs gdisk dosfstools
```

### System Requirements
- Root access (script must run with sudo)
- Source drive: LUKS-encrypted with Btrfs filesystem
- Target drive: Must be larger than source drive
- Sufficient free space for temporary operations

## Supported Configurations

### Partition Layout
- GPT partition table
- Separate boot partition (ext4)
- EFI system partition (FAT32)  
- LUKS2-encrypted main partition containing Btrfs

### Filesystem Features
- Btrfs with multiple subvolumes
- Compression (zstd, lzo, etc.)
- Any Btrfs mount options and features
- Custom GRUB themes and backgrounds (preserved)

## Usage

### 1. Backup Your Data
```bash
# THIS IS CRITICAL - ALWAYS BACKUP FIRST
# The script is designed to be safe, but hardware can fail
```

### 2. Identify Your Drives
```bash
lsblk -f
# Identify source drive (e.g., /dev/sdd) and target drive (e.g., /dev/nvme0n1)
```

### 3. Run the Migration
```bash
# Download the script
wget https://raw.githubusercontent.com/yourusername/luks-btrfs-migration/main/migrate.sh

# Make executable
chmod +x migrate.sh

# Run with sudo
sudo ./migrate.sh
```

### 4. Follow Post-Migration Steps
1. Reboot system
2. Enter BIOS/UEFI settings
3. Change boot order to prioritize new drive
4. Save and exit
5. Verify system boots correctly

## Script Configuration

Edit these variables at the top of the script if needed:

```bash
SOURCE_DRIVE="/dev/sdd"        # Your current drive
TARGET_DRIVE="/dev/nvme0n1"    # Your new drive
```

## What the Script Does

### Phase 1: Preparation
- Verifies drives exist and target is larger
- Asks for confirmation before proceeding
- Creates temporary mount points

### Phase 2: Partitioning
- Wipes target drive (⚠️ **destructive**)
- Creates identical partition layout on target
- Preserves partition sizes and types

### Phase 3: Boot Partitions
- Copies boot partition (ext4) via `dd`
- Copies EFI partition (FAT32) via `dd`
- Generates new UUIDs to avoid conflicts

### Phase 4: Encryption Setup
- Prompts for LUKS passphrase
- Creates LUKS2 container with identical parameters
- Opens both source and target encrypted containers

### Phase 5: Filesystem Migration
- Creates Btrfs filesystem on target
- Discovers and recreates all subvolumes
- Copies all data using `rsync` with full preservation
- Maintains all file attributes, permissions, and extended attributes

### Phase 6: Expansion
- Resizes Btrfs filesystem to use full target drive space
- Verifies new filesystem size

### Phase 7: Configuration Updates
- Updates `/etc/fstab` with new UUIDs
- Updates `/etc/crypttab` with new LUKS UUID
- Updates GRUB configuration files
- Scans for and updates any other config files with old UUIDs

### Phase 8: Bootloader
- Detects Linux distribution
- Regenerates initramfs/initrd
- Updates GRUB configuration
- Reinstalls GRUB bootloader on target drive

## Safety Features

- **Read-only source operations** - Original drive never modified
- **Confirmation prompts** - Multiple confirmations before destructive operations
- **Drive verification** - Ensures target is larger than source
- **Error handling** - Script stops on any error
- **Cleanup on exit** - Automatically unmounts and closes containers
- **Passphrase validation** - Tests passphrase before proceeding

## Troubleshooting

### Boot Fails After Migration
1. Boot from original drive
2. Check BIOS boot order settings
3. Verify GRUB was installed correctly:
   ```bash
   sudo grub-install /dev/nvme0n1
   sudo grub-mkconfig -o /boot/grub/grub.cfg
   ```

### LUKS Container Won't Open
- Verify passphrase is correct
- Check if LUKS headers were copied properly:
  ```bash
  sudo cryptsetup luksDump /dev/nvme0n1p3
  ```

### Filesystem Issues
- Check filesystem integrity:
  ```bash
  sudo btrfs check /dev/mapper/your_luks_name
  ```

### Space Not Expanded
- Manually resize if needed:
  ```bash
  sudo btrfs filesystem resize max /mount/point
  ```

## Distribution-Specific Notes

### Arch Linux
- Uses `mkinitcpio -P` for initramfs
- GRUB config at `/boot/grub/grub.cfg`

### Debian/Ubuntu
- Uses `update-initramfs -u` 
- Uses `update-grub` for config generation

### RHEL/Fedora
- Uses `dracut --regenerate-all --force`
- GRUB config at `/boot/grub2/grub.cfg`

## Example Output

```
[2024-06-24 15:45:01] Starting LUKS + Btrfs migration from /dev/sdd to /dev/nvme0n1
[2024-06-24 15:45:02] Source drive size: 465G
[2024-06-24 15:45:02] Target drive size: 954G
[2024-06-24 15:45:15] Creating partition table on target drive...
[2024-06-24 15:45:20] Copying boot partition...
[2024-06-24 15:45:45] Setting up LUKS encryption on target partition...
[2024-06-24 15:48:12] Cloning Btrfs filesystem...
[2024-06-24 16:23:45] Resizing Btrfs filesystem to use full space...
[2024-06-24 16:23:50] Updating system configuration...
[2024-06-24 16:24:15] Updating bootloader configuration...
[2024-06-24 16:25:30] Migration completed successfully!
```

## Contributing

Contributions welcome! Please:
1. Test thoroughly before submitting PRs
2. Update documentation for new features
3. Follow existing code style
4. Add error handling for new operations

## License

MIT License - see LICENSE file for details

## Disclaimer

This script performs low-level disk operations. While designed to be safe:
- ⚠️ **Always backup your data first**
- ⚠️ **Test in a virtual machine if possible**
- ⚠️ **Verify your backup before running**
- ⚠️ **The authors are not responsible for data loss**

## Support

- 🐛 **Issues**: Report bugs via GitHub Issues
- 💬 **Discussions**: Use GitHub Discussions for questions
- 📖 **Wiki**: Check the wiki for additional documentation

---

**Remember**: The best backup is the one you have before you need it! 🛡️