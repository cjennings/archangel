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

    # Create LUKS container (-q for batch mode, -d - to read key from stdin)
    echo -n "$passphrase" | cryptsetup -q luksFormat --type luks2 \
        --cipher aes-xts-plain64 --key-size 512 --hash sha512 \
        --iter-time 2000 --pbkdf argon2id \
        -d - "$partition" \
        || error "Failed to create LUKS container"

    info "LUKS container created."
}

open_luks_container() {
    local partition="$1"
    local passphrase="$2"
    local name="${3:-$LUKS_MAPPER_NAME}"

    info "Opening LUKS container..."

    echo -n "$passphrase" | cryptsetup open "$partition" "$name" -d - \
        || error "Failed to open LUKS container"

    info "LUKS container opened as /dev/mapper/$name"
}

close_luks_container() {
    local name="${1:-$LUKS_MAPPER_NAME}"

    cryptsetup close "$name" 2>/dev/null || true
}

# Testing keyfile for automated LUKS testing
# When TESTING=yes, we embed a keyfile in initramfs to allow unattended boot
LUKS_KEYFILE="/etc/cryptroot.key"

setup_luks_testing_keyfile() {
    local passphrase="$1"
    shift
    local partitions=("$@")

    [[ "${TESTING:-}" != "yes" ]] && return 0

    step "Setting Up Testing Keyfile (TESTING MODE)"
    warn "Adding keyfile to initramfs for automated testing."
    warn "This reduces security - for testing only!"

    # Generate random keyfile
    dd if=/dev/urandom of="/mnt${LUKS_KEYFILE}" bs=512 count=4 status=none \
        || error "Failed to generate keyfile"
    chmod 000 "/mnt${LUKS_KEYFILE}"

    # Add keyfile to each LUKS partition (slot 1, passphrase stays in slot 0)
    for partition in "${partitions[@]}"; do
        info "Adding keyfile to $partition..."
        echo -n "$passphrase" | cryptsetup luksAddKey "$partition" "/mnt${LUKS_KEYFILE}" -d - \
            || error "Failed to add keyfile to $partition"
    done

    info "Testing keyfile configured for ${#partitions[@]} partition(s)."
}

# Multi-disk LUKS functions
create_luks_containers() {
    local passphrase="$1"
    shift
    local partitions=("$@")

    step "Creating LUKS Encrypted Containers"

    local i=0
    for partition in "${partitions[@]}"; do
        info "Setting up LUKS encryption on $partition..."
        echo -n "$passphrase" | cryptsetup -q luksFormat --type luks2 \
            --cipher aes-xts-plain64 --key-size 512 --hash sha512 \
            --iter-time 2000 --pbkdf argon2id \
            -d - "$partition" \
            || error "Failed to create LUKS container on $partition"
        ((++i))
    done

    info "Created $i LUKS containers."
}

open_luks_containers() {
    local passphrase="$1"
    shift
    local partitions=("$@")

    step "Opening LUKS Containers"

    local i=0
    for partition in "${partitions[@]}"; do
        local name="${LUKS_MAPPER_NAME}${i}"
        [[ $i -eq 0 ]] && name="$LUKS_MAPPER_NAME"  # First one has no suffix
        info "Opening LUKS container: $partition -> /dev/mapper/$name"
        echo -n "$passphrase" | cryptsetup open "$partition" "$name" -d - \
            || error "Failed to open LUKS container: $partition"
        ((++i))
    done

    info "Opened ${#partitions[@]} LUKS containers."
}

close_luks_containers() {
    local count="${1:-1}"

    for ((i=0; i<count; i++)); do
        local name="${LUKS_MAPPER_NAME}${i}"
        [[ $i -eq 0 ]] && name="$LUKS_MAPPER_NAME"
        cryptsetup close "$name" 2>/dev/null || true
    done
}

# Get list of opened LUKS mapper devices
get_luks_devices() {
    local count="$1"
    local devices=()

    for ((i=0; i<count; i++)); do
        local name="${LUKS_MAPPER_NAME}${i}"
        [[ $i -eq 0 ]] && name="$LUKS_MAPPER_NAME"
        devices+=("/dev/mapper/$name")
    done

    echo "${devices[@]}"
}

configure_crypttab() {
    local partitions=("$@")

    step "Configuring crypttab"

    echo "# LUKS encrypted root partitions" > /mnt/etc/crypttab

    # Use keyfile if in testing mode, otherwise prompt for passphrase
    local key_source="none"
    if [[ "${TESTING:-}" == "yes" ]]; then
        key_source="$LUKS_KEYFILE"
        info "Testing mode: using keyfile for automatic unlock"
    fi

    local i=0
    for partition in "${partitions[@]}"; do
        local uuid
        uuid=$(blkid -s UUID -o value "$partition")
        local name="${LUKS_MAPPER_NAME}${i}"
        [[ $i -eq 0 ]] && name="$LUKS_MAPPER_NAME"

        echo "$name  UUID=$uuid  $key_source  luks,discard" >> /mnt/etc/crypttab
        info "crypttab: $name -> UUID=$uuid"
        ((++i))
    done

    info "crypttab configured for $i partition(s)"
}

configure_luks_initramfs() {
    step "Configuring Initramfs for LUKS"

    # Backup original
    cp /mnt/etc/mkinitcpio.conf /mnt/etc/mkinitcpio.conf.bak

    # Add encrypt hook before filesystems
    # Hooks: base udev ... keyboard keymap ... encrypt filesystems ...
    sed -i 's/^HOOKS=.*/HOOKS=(base udev microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck)/' \
        /mnt/etc/mkinitcpio.conf

    # Include keyfile in initramfs for testing mode (unattended boot)
    if [[ "${TESTING:-}" == "yes" ]]; then
        info "Testing mode: embedding keyfile in initramfs"
        sed -i "s|^FILES=.*|FILES=($LUKS_KEYFILE)|" /mnt/etc/mkinitcpio.conf
        # If FILES line doesn't exist, add it
        if ! grep -q "^FILES=" /mnt/etc/mkinitcpio.conf; then
            echo "FILES=($LUKS_KEYFILE)" >> /mnt/etc/mkinitcpio.conf
        fi
    fi

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
    # For testing mode, also add cryptkey parameter for automated unlock
    local cryptkey_param=""
    if [[ "${TESTING:-}" == "yes" ]]; then
        # cryptkey path is relative to initramfs root (no device prefix needed)
        cryptkey_param="cryptkey=$LUKS_KEYFILE "
        info "Testing mode: adding cryptkey parameter for automated unlock"
    fi

    sed -i "s|^GRUB_CMDLINE_LINUX=\"|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=$uuid:$LUKS_MAPPER_NAME:allow-discards ${cryptkey_param}|" \
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

# Create btrfs filesystem (single or multi-device)
# Usage: create_btrfs_volume device1 [device2 ...] [--raid-level level]
create_btrfs_volume() {
    local devices=()
    local raid_level=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --raid-level)
                raid_level="$2"
                shift 2
                ;;
            *)
                devices+=("$1")
                shift
                ;;
        esac
    done

    step "Creating Btrfs Filesystem"

    local num_devices=${#devices[@]}

    if [[ $num_devices -eq 1 ]]; then
        # Single device
        info "Formatting ${devices[0]} as btrfs..."
        mkfs.btrfs -f -L "archroot" "${devices[0]}" || error "Failed to create btrfs filesystem"
        info "Btrfs filesystem created on ${devices[0]}"
    else
        # Multi-device RAID
        local data_profile="raid1"
        local meta_profile="raid1"

        case "$raid_level" in
            stripe)
                data_profile="raid0"
                meta_profile="raid1"  # Always mirror metadata for safety
                info "Creating striped btrfs (RAID0 data, RAID1 metadata) with $num_devices devices..."
                ;;
            mirror)
                data_profile="raid1"
                meta_profile="raid1"
                info "Creating mirrored btrfs (RAID1) with $num_devices devices..."
                ;;
            *)
                # Default to mirror for safety
                data_profile="raid1"
                meta_profile="raid1"
                info "Creating mirrored btrfs (RAID1) with $num_devices devices..."
                ;;
        esac

        mkfs.btrfs -f -L "archroot" \
            -d "$data_profile" \
            -m "$meta_profile" \
            "${devices[@]}" || error "Failed to create btrfs filesystem"

        info "Btrfs $raid_level filesystem created on ${devices[*]}"
    fi
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
        echo '# Update GRUB (config on EFI partition)'
        echo 'grub-mkconfig -o /efi/grub/grub.cfg'
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

    # Create grub directory on EFI partition
    # GRUB modules on FAT32 EFI partition avoid btrfs subvolume path issues
    mkdir -p /mnt/efi/grub

    # Install GRUB with boot-directory on EFI partition
    info "Installing GRUB to EFI partition..."
    arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/efi \
        --bootloader-id=GRUB --boot-directory=/efi \
        || error "GRUB installation failed"

    # Create symlink BEFORE grub-mkconfig (grub-btrfs expects /boot/grub)
    rm -rf /mnt/boot/grub 2>/dev/null || true
    arch-chroot /mnt ln -sfn /efi/grub /boot/grub

    # Generate GRUB config (uses /boot/grub symlink -> /efi/grub)
    info "Generating GRUB configuration..."
    arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg \
        || error "Failed to generate GRUB config"

    # Sync to ensure grub.cfg is written to FAT32 EFI partition
    sync

    # Enable grub-btrfsd for automatic snapshot menu updates
    info "Enabling grub-btrfs daemon..."
    arch-chroot /mnt systemctl enable grub-btrfsd

    info "GRUB configured with btrfs snapshot support."
}

#############################
# EFI Redundancy (Multi-disk)
#############################

# Install GRUB to all EFI partitions for redundancy
install_grub_all_efi() {
    local efi_partitions=("$@")

    step "Installing GRUB to All EFI Partitions"

    local i=1
    for efi_part in "${efi_partitions[@]}"; do
        # First EFI at /efi (already mounted), subsequent at /efi2, /efi3, etc.
        local chroot_efi_dir="/efi"
        local mount_point="/mnt/efi"
        local bootloader_id="GRUB"

        if [[ $i -gt 1 ]]; then
            chroot_efi_dir="/efi${i}"
            mount_point="/mnt/efi${i}"
            bootloader_id="GRUB-disk${i}"

            # Mount secondary EFI partitions
            if ! mountpoint -q "$mount_point" 2>/dev/null; then
                mkdir -p "$mount_point"
                mount "$efi_part" "$mount_point" || { warn "Failed to mount $efi_part"; ((++i)); continue; }
                # Also create the directory in chroot for grub-install
                mkdir -p "/mnt${chroot_efi_dir}"
                mount --bind "$mount_point" "/mnt${chroot_efi_dir}"
            fi
        fi

        info "Installing GRUB to $efi_part ($bootloader_id)..."
        arch-chroot /mnt grub-install --target=x86_64-efi \
            --efi-directory="$chroot_efi_dir" \
            --bootloader-id="$bootloader_id" \
            --boot-directory=/efi \
            || warn "GRUB install to $efi_part may have failed (continuing)"

        ((++i))
    done

    info "GRUB installed to ${#efi_partitions[@]} EFI partition(s)."
}

# Create pacman hook to sync GRUB across all EFI partitions
create_grub_sync_hook() {
    local efi_partitions=("$@")

    step "Creating GRUB Sync Hook"

    # Only needed for multi-disk
    if [[ ${#efi_partitions[@]} -lt 2 ]]; then
        info "Single disk - no sync hook needed."
        return
    fi

    # Create sync script
    local script_content='#!/bin/bash
# Sync GRUB to all EFI partitions after grub package update
# Generated by archangel installer

set -e

EFI_PARTITIONS=('
    for part in "${efi_partitions[@]}"; do
        script_content+="\"$part\" "
    done
    script_content+=')

PRIMARY_EFI="/efi"

sync_grub() {
    local i=0
    for part in "${EFI_PARTITIONS[@]}"; do
        if [[ $i -eq 0 ]]; then
            # Primary - just reinstall GRUB
            grub-install --target=x86_64-efi --efi-directory="$PRIMARY_EFI" \
                --bootloader-id=GRUB --boot-directory=/efi 2>/dev/null || true
        else
            # Secondary - mount, install, unmount
            local mount_point="/tmp/efi-sync-$i"
            mkdir -p "$mount_point"
            mount "$part" "$mount_point" 2>/dev/null || continue
            grub-install --target=x86_64-efi --efi-directory="$mount_point" \
                --bootloader-id="GRUB-disk$((i+1))" --boot-directory=/efi 2>/dev/null || true
            umount "$mount_point" 2>/dev/null || true
            rmdir "$mount_point" 2>/dev/null || true
        fi
        ((++i))
    done
}

sync_grub
'
    echo "$script_content" > /mnt/usr/local/bin/grub-sync-efi
    chmod +x /mnt/usr/local/bin/grub-sync-efi

    # Create pacman hook
    mkdir -p /mnt/etc/pacman.d/hooks
    cat > /mnt/etc/pacman.d/hooks/99-grub-sync-efi.hook << 'HOOKEOF'
[Trigger]
Type = Package
Operation = Upgrade
Target = grub

[Action]
Description = Syncing GRUB to all EFI partitions...
When = PostTransaction
Exec = /usr/local/bin/grub-sync-efi
HOOKEOF

    info "GRUB sync hook created for ${#efi_partitions[@]} EFI partitions."
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
    # Include encrypt hook if LUKS is enabled, btrfs hook if multi-device
    local num_disks=${#SELECTED_DISKS[@]}
    local encrypt_hook=""
    [[ "$NO_ENCRYPT" != "yes" && -n "$LUKS_PASSPHRASE" ]] && encrypt_hook="encrypt "

    if [[ $num_disks -gt 1 ]]; then
        info "Multi-device btrfs: adding btrfs hook for device assembly"
        sed -i "s/^HOOKS=.*/HOOKS=(base udev microcode modconf kms keyboard keymap consolefont block ${encrypt_hook}btrfs filesystems fsck)/" \
            /mnt/etc/mkinitcpio.conf
    else
        sed -i "s/^HOOKS=.*/HOOKS=(base udev microcode modconf kms keyboard keymap consolefont block ${encrypt_hook}filesystems fsck)/" \
            /mnt/etc/mkinitcpio.conf
    fi

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

    # Sync all filesystems before unmounting (important for FAT32 EFI partition)
    sync

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
