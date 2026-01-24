#!/usr/bin/env bash
# btrfs.sh - Btrfs-specific functions for archangel installer
# Source this file after common.sh, config.sh, disk.sh

#############################
# Btrfs/LUKS Constants
#############################

# LUKS settings
LUKS_MAPPER_NAME="cryptroot"

# Mount options for btrfs subvolumes
BTRFS_OPTS="noatime,compress=zstd,space_cache=v2,discard=async"

# Subvolume layout (matches ZFS dataset structure)
# Format: "name:mountpoint:extra_opts"
BTRFS_SUBVOLS=(
    "@:/::"
    "@home:/home::"
    "@snapshots:/.snapshots::"
    "@var_log:/var/log::"
    "@var_cache:/var/cache::"
    "@tmp:/tmp::nosuid,nodev"
    "@var_tmp:/var/tmp::nosuid,nodev"
    "@media:/media::compress=no"
    "@vms:/vms::nodatacow,compress=no"
    "@var_lib_docker:/var/lib/docker::"
)

#############################
# LUKS Functions
#############################

create_luks_container() {
    local partition="$1"
    local passphrase="$2"

    step "Creating LUKS Encrypted Container"

    info "Setting up LUKS encryption on $partition..."

    # Create LUKS container
    echo -n "$passphrase" | cryptsetup luksFormat --type luks2 \
        --cipher aes-xts-plain64 --key-size 512 --hash sha512 \
        --iter-time 2000 --pbkdf argon2id \
        "$partition" - \
        || error "Failed to create LUKS container"

    info "LUKS container created."
}

open_luks_container() {
    local partition="$1"
    local passphrase="$2"
    local name="${3:-$LUKS_MAPPER_NAME}"

    info "Opening LUKS container..."

    echo -n "$passphrase" | cryptsetup open "$partition" "$name" - \
        || error "Failed to open LUKS container"

    info "LUKS container opened as /dev/mapper/$name"
}

close_luks_container() {
    local name="${1:-$LUKS_MAPPER_NAME}"

    cryptsetup close "$name" 2>/dev/null || true
}

configure_crypttab() {
    local partition="$1"

    step "Configuring crypttab"

    local uuid
    uuid=$(blkid -s UUID -o value "$partition")

    # Create crypttab entry
    echo "# LUKS encrypted root" > /mnt/etc/crypttab
    echo "$LUKS_MAPPER_NAME  UUID=$uuid  none  luks,discard" >> /mnt/etc/crypttab

    info "crypttab configured for $LUKS_MAPPER_NAME"
}

configure_luks_initramfs() {
    step "Configuring Initramfs for LUKS"

    # Backup original
    cp /mnt/etc/mkinitcpio.conf /mnt/etc/mkinitcpio.conf.bak

    # Add encrypt hook before filesystems
    # Hooks: base udev ... keyboard keymap ... encrypt filesystems ...
    sed -i 's/^HOOKS=.*/HOOKS=(base udev microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck)/' \
        /mnt/etc/mkinitcpio.conf

    info "Added encrypt hook to initramfs."
}

configure_luks_grub() {
    local partition="$1"

    step "Configuring GRUB for LUKS"

    local uuid
    uuid=$(blkid -s UUID -o value "$partition")

    # Enable GRUB cryptodisk support (required for encrypted /boot)
    echo "GRUB_ENABLE_CRYPTODISK=y" >> /mnt/etc/default/grub

    # Add cryptdevice to GRUB cmdline
    sed -i "s|^GRUB_CMDLINE_LINUX=\"|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=$uuid:$LUKS_MAPPER_NAME:allow-discards |" \
        /mnt/etc/default/grub

    info "GRUB configured with cryptdevice parameter and cryptodisk enabled."
}

#############################
# Btrfs Pre-flight
#############################

btrfs_preflight() {
    step "Checking Btrfs Requirements"

    # Check for btrfs-progs
    if ! command_exists mkfs.btrfs; then
        error "btrfs-progs not installed. Cannot create btrfs filesystem."
    fi
    info "btrfs-progs available."

    # Check for required tools
    require_command btrfs
    require_command grub-install

    info "Btrfs preflight checks passed."
}

#############################
# Btrfs Volume Creation
#############################

create_btrfs_volume() {
    local partition="$1"

    step "Creating Btrfs Filesystem"

    info "Formatting $partition as btrfs..."
    mkfs.btrfs -f -L "archroot" "$partition" || error "Failed to create btrfs filesystem"

    info "Btrfs filesystem created on $partition"
}

#############################
# Subvolume Creation
#############################

create_btrfs_subvolumes() {
    local partition="$1"

    step "Creating Btrfs Subvolumes"

    # Mount the raw btrfs volume temporarily
    mount "$partition" /mnt || error "Failed to mount btrfs volume"

    # Create each subvolume
    for subvol_spec in "${BTRFS_SUBVOLS[@]}"; do
        IFS=':' read -r name mountpoint extra <<< "$subvol_spec"
        info "Creating subvolume: $name -> $mountpoint"
        btrfs subvolume create "/mnt/$name" || error "Failed to create subvolume $name"
    done

    # Unmount raw volume
    umount /mnt

    info "Created ${#BTRFS_SUBVOLS[@]} subvolumes."
}

#############################
# Btrfs Mount Functions
#############################

mount_btrfs_subvolumes() {
    local partition="$1"

    step "Mounting Btrfs Subvolumes"

    # Mount root subvolume first
    info "Mounting @ -> /mnt"
    mount -o "subvol=@,$BTRFS_OPTS" "$partition" /mnt || error "Failed to mount root subvolume"

    # Create mount points and mount remaining subvolumes
    for subvol_spec in "${BTRFS_SUBVOLS[@]}"; do
        IFS=':' read -r name mountpoint extra <<< "$subvol_spec"

        # Skip root, already mounted
        [[ "$name" == "@" ]] && continue

        # Build mount options
        local opts="subvol=$name,$BTRFS_OPTS"

        # Apply extra options (override defaults where specified)
        if [[ -n "$extra" ]]; then
            # Handle compress=no by removing compress from opts and not adding it
            if [[ "$extra" == *"compress=no"* ]]; then
                opts=$(echo "$opts" | sed 's/,compress=zstd//')
            fi
            # Handle nodatacow
            if [[ "$extra" == *"nodatacow"* ]]; then
                opts="$opts,nodatacow"
                opts=$(echo "$opts" | sed 's/,compress=zstd//')
            fi
            # Handle nosuid,nodev for tmp
            if [[ "$extra" == *"nosuid"* ]]; then
                opts="$opts,nosuid,nodev"
            fi
        fi

        info "Mounting $name -> /mnt$mountpoint"
        mkdir -p "/mnt$mountpoint"
        mount -o "$opts" "$partition" "/mnt$mountpoint" || error "Failed to mount $name"
    done

    # Set permissions on tmp directories
    chmod 1777 /mnt/tmp /mnt/var/tmp

    info "All subvolumes mounted."
}

#############################
# Fstab Generation
#############################

generate_btrfs_fstab() {
    local partition="$1"
    local efi_partition="$2"

    step "Generating fstab"

    local uuid
    uuid=$(blkid -s UUID -o value "$partition")

    # Start with header
    cat > /mnt/etc/fstab << EOF
# /etc/fstab - Btrfs subvolume mounts
# IMPORTANT: Using subvol= NOT subvolid= for snapshot compatibility
# Generated by archangel installer

EOF

    # Add each subvolume
    for subvol_spec in "${BTRFS_SUBVOLS[@]}"; do
        IFS=':' read -r name mountpoint extra <<< "$subvol_spec"

        # Build mount options
        local opts="subvol=$name,$BTRFS_OPTS"

        # Apply extra options
        if [[ -n "$extra" ]]; then
            if [[ "$extra" == *"compress=no"* ]]; then
                opts=$(echo "$opts" | sed 's/,compress=zstd//')
            fi
            if [[ "$extra" == *"nodatacow"* ]]; then
                opts="$opts,nodatacow"
                opts=$(echo "$opts" | sed 's/,compress=zstd//')
            fi
            if [[ "$extra" == *"nosuid"* ]]; then
                opts="$opts,nosuid,nodev"
            fi
        fi

        echo "UUID=$uuid  $mountpoint  btrfs  $opts  0 0" >> /mnt/etc/fstab
    done

    # Add EFI partition
    local efi_uuid
    efi_uuid=$(blkid -s UUID -o value "$efi_partition")
    echo "" >> /mnt/etc/fstab
    echo "# EFI System Partition" >> /mnt/etc/fstab
    echo "UUID=$efi_uuid  /efi  vfat  defaults,noatime  0 2" >> /mnt/etc/fstab

    info "fstab generated with ${#BTRFS_SUBVOLS[@]} btrfs mounts + EFI"
}

#############################
# Snapper Configuration
#############################

configure_snapper() {
    step "Configuring Snapper"

    # Snapper needs D-Bus which isn't available in chroot
    # Create a firstboot service to properly initialize snapper

    info "Creating snapper firstboot configuration..."

    # Create the firstboot script using echo (more reliable than HEREDOC)
    {
        echo '#!/bin/bash'
        echo '# Snapper firstboot configuration'
        echo 'set -e'
        echo ''
        echo '# Check if snapper is already configured'
        echo 'if snapper list-configs 2>/dev/null | grep -q "^root"; then'
        echo '    exit 0'
        echo 'fi'
        echo ''
        echo 'echo "Configuring snapper for btrfs root..."'
        echo ''
        echo '# Unmount the pre-created @snapshots'
        echo 'umount /.snapshots 2>/dev/null || true'
        echo 'rmdir /.snapshots 2>/dev/null || true'
        echo ''
        echo '# Let snapper create its config'
        echo 'snapper -c root create-config /'
        echo ''
        echo '# Replace snapper .snapshots with our @snapshots'
        echo 'btrfs subvolume delete /.snapshots'
        echo 'mkdir /.snapshots'
        echo 'ROOT_DEV=$(findmnt -n -o SOURCE / | sed "s/\[.*\]//")'
        echo 'mount -o subvol=@snapshots "$ROOT_DEV" /.snapshots'
        echo 'chmod 750 /.snapshots'
        echo ''
        echo '# Configure timeline'
        echo 'snapper -c root set-config "TIMELINE_CREATE=yes"'
        echo 'snapper -c root set-config "TIMELINE_CLEANUP=yes"'
        echo 'snapper -c root set-config "TIMELINE_LIMIT_HOURLY=6"'
        echo 'snapper -c root set-config "TIMELINE_LIMIT_DAILY=7"'
        echo 'snapper -c root set-config "TIMELINE_LIMIT_WEEKLY=2"'
        echo 'snapper -c root set-config "TIMELINE_LIMIT_MONTHLY=1"'
        echo 'snapper -c root set-config "NUMBER_LIMIT=50"'
        echo ''
        echo '# Create genesis snapshot'
        echo 'snapper -c root create -d "genesis"'
        echo ''
        echo '# Update GRUB'
        echo 'grub-mkconfig -o /boot/grub/grub.cfg'
        echo ''
        echo 'echo "Snapper configuration complete!"'
    } > /mnt/usr/local/bin/snapper-firstboot
    chmod +x /mnt/usr/local/bin/snapper-firstboot

    # Create systemd service for firstboot
    {
        echo '[Unit]'
        echo 'Description=Snapper First Boot Configuration'
        echo 'After=local-fs.target dbus.service'
        echo 'Wants=dbus.service'
        echo 'ConditionPathExists=!/etc/snapper/.firstboot-done'
        echo ''
        echo '[Service]'
        echo 'Type=oneshot'
        echo 'ExecStart=/usr/local/bin/snapper-firstboot'
        echo 'ExecStartPost=/usr/bin/touch /etc/snapper/.firstboot-done'
        echo 'RemainAfterExit=yes'
        echo ''
        echo '[Install]'
        echo 'WantedBy=multi-user.target'
    } > /mnt/etc/systemd/system/snapper-firstboot.service

    # Enable the firstboot service
    arch-chroot /mnt systemctl enable snapper-firstboot.service

    # Enable snapper timers
    arch-chroot /mnt systemctl enable snapper-timeline.timer
    arch-chroot /mnt systemctl enable snapper-cleanup.timer

    info "Snapper firstboot service configured."
    info "Snapper will be fully configured on first boot."
}

#############################
# GRUB Configuration
#############################

configure_grub() {
    local efi_partition="$1"

    step "Configuring GRUB Bootloader"

    # Mount EFI partition
    mkdir -p /mnt/efi
    mount "$efi_partition" /mnt/efi

    # Configure GRUB defaults for btrfs
    info "Setting GRUB configuration..."
    cat > /mnt/etc/default/grub << 'EOF'
# GRUB configuration for btrfs root with snapshots
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="Arch"
GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3"
GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200"

# Serial console support (for headless/VM testing)
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"

# Disable os-prober (single-boot system)
GRUB_DISABLE_OS_PROBER=true

# Btrfs: tell GRUB where to find /boot within subvolume
GRUB_BTRFS_OVERRIDE_BOOT_PARTITION_DETECTION=true
EOF

    # Add LUKS encryption settings if enabled
    if [[ "$NO_ENCRYPT" != "yes" && -n "$LUKS_PASSPHRASE" ]]; then
        echo "" >> /mnt/etc/default/grub
        echo "# LUKS encryption support" >> /mnt/etc/default/grub
        echo "GRUB_ENABLE_CRYPTODISK=y" >> /mnt/etc/default/grub

        # Get UUID of encrypted partition and add cryptdevice to cmdline
        # Find the LUKS partition (partition 2 of the first disk)
        local luks_part
        luks_part=$(echo "$DISKS" | cut -d',' -f1)2
        if [[ -b "$luks_part" ]]; then
            local uuid
            uuid=$(blkid -s UUID -o value "$luks_part")
            sed -i "s|^GRUB_CMDLINE_LINUX=\"|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=$uuid:$LUKS_MAPPER_NAME:allow-discards |" \
                /mnt/etc/default/grub
            info "Added cryptdevice parameter for LUKS partition."
        fi
    fi

    # Create /boot/grub directory
    mkdir -p /mnt/boot/grub

    # Install GRUB to EFI with btrfs support
    # Use --boot-directory to ensure modules are found correctly
    info "Installing GRUB to EFI partition..."
    arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/efi \
        --bootloader-id=GRUB --boot-directory=/boot \
        || error "GRUB installation failed"

    # Generate GRUB config
    info "Generating GRUB configuration..."
    arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg \
        || error "Failed to generate GRUB config"

    # Enable grub-btrfsd for automatic snapshot menu updates
    info "Enabling grub-btrfs daemon..."
    arch-chroot /mnt systemctl enable grub-btrfsd

    info "GRUB configured with btrfs snapshot support."
}

#############################
# Pacman Snapshot Hook
#############################

configure_btrfs_pacman_hook() {
    step "Configuring Pacman Snapshot Hook"

    # snap-pac handles this automatically when installed
    # Just verify it's set up
    info "snap-pac will create pre/post snapshots for pacman transactions."
    info "Snapshots visible in GRUB menu via grub-btrfs."
}

#############################
# Genesis Snapshot
#############################

create_btrfs_genesis_snapshot() {
    step "Creating Genesis Snapshot"

    # Genesis snapshot will be created by snapper-firstboot service on first boot
    # This ensures snapper is properly configured before creating snapshots

    info "Genesis snapshot will be created on first boot."
    info "The snapper-firstboot service handles this automatically."
}

#############################
# Btrfs Services
#############################

configure_btrfs_services() {
    step "Configuring System Services"

    # Enable standard services
    arch-chroot /mnt systemctl enable NetworkManager
    arch-chroot /mnt systemctl enable avahi-daemon

    # Snapper timers (already enabled in configure_snapper)

    # grub-btrfsd (already enabled in configure_grub)

    info "System services configured."
}

#############################
# Btrfs Initramfs
#############################

configure_btrfs_initramfs() {
    step "Configuring Initramfs for Btrfs"

    # Backup original
    cp /mnt/etc/mkinitcpio.conf /mnt/etc/mkinitcpio.conf.bak

    # Remove archiso drop-in if present
    if [[ -f /mnt/etc/mkinitcpio.conf.d/archiso.conf ]]; then
        info "Removing archiso drop-in config..."
        rm -f /mnt/etc/mkinitcpio.conf.d/archiso.conf
    fi

    # Create proper linux-lts preset
    info "Creating linux-lts preset..."
    cat > /mnt/etc/mkinitcpio.d/linux-lts.preset << 'EOF'
# mkinitcpio preset file for linux-lts

PRESETS=(default fallback)

ALL_kver="/boot/vmlinuz-linux-lts"

default_image="/boot/initramfs-linux-lts.img"

fallback_image="/boot/initramfs-linux-lts-fallback.img"
fallback_options="-S autodetect"
EOF

    # Configure hooks for btrfs
    # btrfs module is built into kernel, but we need the btrfs hook for multi-device
    sed -i 's/^HOOKS=.*/HOOKS=(base udev microcode modconf kms keyboard keymap consolefont block filesystems fsck)/' \
        /mnt/etc/mkinitcpio.conf

    # Regenerate initramfs
    info "Regenerating initramfs..."
    arch-chroot /mnt mkinitcpio -P

    info "Initramfs configured for btrfs."
}

#############################
# Btrfs Cleanup
#############################

btrfs_cleanup() {
    step "Cleaning Up Btrfs"

    # Unmount in reverse order
    info "Unmounting subvolumes..."

    # Unmount EFI first
    umount /mnt/efi 2>/dev/null || true

    # Unmount all btrfs subvolumes (reverse order)
    for ((i=${#BTRFS_SUBVOLS[@]}-1; i>=0; i--)); do
        IFS=':' read -r name mountpoint extra <<< "${BTRFS_SUBVOLS[$i]}"
        [[ "$name" == "@" ]] && continue
        umount "/mnt$mountpoint" 2>/dev/null || true
    done

    # Unmount root last
    umount /mnt 2>/dev/null || true

    info "Btrfs cleanup complete."
}
