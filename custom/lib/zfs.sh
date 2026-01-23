#!/usr/bin/env bash
# zfs.sh - ZFS-specific functions for archangel installer
# Source this file after common.sh, config.sh, disk.sh

#############################
# ZFS Constants
#############################

POOL_NAME="${POOL_NAME:-zroot}"
ASHIFT="${ASHIFT:-12}"
COMPRESSION="${COMPRESSION:-zstd}"

#############################
# ZFS Pre-flight
#############################

zfs_preflight() {
    # Check ZFS module
    if ! lsmod | grep -q zfs; then
        info "Loading ZFS module..."
        modprobe zfs || error "Failed to load ZFS module. Is zfs-linux-lts installed?"
    fi
    info "ZFS module loaded successfully."
}

#############################
# ZFS Pool Creation
#############################

create_zfs_pool() {
    local encryption="${1:-true}"
    local passphrase="$2"

    step "Creating ZFS Pool"

    # Destroy existing pool if present
    if zpool list "$POOL_NAME" &>/dev/null; then
        warn "Pool $POOL_NAME already exists. Destroying..."
        zpool destroy -f "$POOL_NAME"
    fi

    # Get root partitions
    local zfs_parts=()
    for disk in "${SELECTED_DISKS[@]}"; do
        zfs_parts+=("$(get_root_partition "$disk")")
    done

    # Build pool configuration based on RAID level
    local pool_config
    if [[ "$RAID_LEVEL" == "stripe" ]]; then
        pool_config="${zfs_parts[*]}"
        info "Creating striped pool with ${#zfs_parts[@]} disks (NO redundancy)..."
        warn "Data loss will occur if ANY disk fails!"
    elif [[ -n "$RAID_LEVEL" ]]; then
        pool_config="$RAID_LEVEL ${zfs_parts[*]}"
        info "Creating $RAID_LEVEL pool with ${#zfs_parts[@]} disks..."
    else
        pool_config="${zfs_parts[0]}"
        info "Creating single-disk pool..."
    fi

    # Base pool options
    local pool_opts=(
        -f
        -o ashift="$ASHIFT"
        -o autotrim=on
        -O acltype=posixacl
        -O atime=off
        -O canmount=off
        -O compression="$COMPRESSION"
        -O dnodesize=auto
        -O normalization=formD
        -O relatime=on
        -O xattr=sa
        -O mountpoint=none
        -R /mnt
    )

    # Create pool (with or without encryption)
    if [[ "$encryption" == "false" ]]; then
        warn "Creating pool WITHOUT encryption"
        zpool create "${pool_opts[@]}" "$POOL_NAME" $pool_config
    else
        info "Creating encrypted pool..."
        echo "$passphrase" | zpool create "${pool_opts[@]}" \
            -O encryption=aes-256-gcm \
            -O keyformat=passphrase \
            -O keylocation=prompt \
            "$POOL_NAME" $pool_config
    fi

    info "ZFS pool created successfully."
    zpool status "$POOL_NAME"
}

#############################
# ZFS Dataset Creation
#############################

create_zfs_datasets() {
    step "Creating ZFS Datasets"

    # Root dataset container
    zfs create -o mountpoint=none -o canmount=off "$POOL_NAME/ROOT"

    # Calculate reservation (20% of pool, capped 5-20G)
    local pool_size_bytes=$(zpool get -Hp size "$POOL_NAME" | awk '{print $3}')
    local pool_size_gb=$((pool_size_bytes / 1024 / 1024 / 1024))
    local reserve_gb=$((pool_size_gb / 5))
    [[ $reserve_gb -gt 20 ]] && reserve_gb=20
    [[ $reserve_gb -lt 5 ]] && reserve_gb=5

    # Main root filesystem
    zfs create -o mountpoint=/ -o canmount=noauto -o reservation=${reserve_gb}G "$POOL_NAME/ROOT/default"
    zfs mount "$POOL_NAME/ROOT/default"

    # Home
    zfs create -o mountpoint=/home "$POOL_NAME/home"
    zfs create -o mountpoint=/root "$POOL_NAME/home/root"

    # Media - compression off for already-compressed files
    zfs create -o mountpoint=/media -o compression=off "$POOL_NAME/media"

    # VMs - 64K recordsize for VM disk images
    zfs create -o mountpoint=/vms -o recordsize=64K "$POOL_NAME/vms"

    # Var datasets
    zfs create -o mountpoint=/var -o canmount=off "$POOL_NAME/var"
    zfs create -o mountpoint=/var/log "$POOL_NAME/var/log"
    zfs create -o mountpoint=/var/cache "$POOL_NAME/var/cache"
    zfs create -o mountpoint=/var/lib -o canmount=off "$POOL_NAME/var/lib"
    zfs create -o mountpoint=/var/lib/pacman "$POOL_NAME/var/lib/pacman"
    zfs create -o mountpoint=/var/lib/docker "$POOL_NAME/var/lib/docker"

    # Temp directories - excluded from snapshots
    zfs create -o mountpoint=/var/tmp -o com.sun:auto-snapshot=false "$POOL_NAME/var/tmp"
    zfs create -o mountpoint=/tmp -o com.sun:auto-snapshot=false "$POOL_NAME/tmp"
    chmod 1777 /mnt/tmp /mnt/var/tmp

    info "Datasets created:"
    zfs list -r "$POOL_NAME" -o name,mountpoint,compression
}

#############################
# ZFSBootMenu Configuration
#############################

configure_zfsbootmenu() {
    step "Configuring ZFSBootMenu"

    # Ensure hostid exists
    if [[ ! -f /etc/hostid ]]; then
        zgenhostid
    fi
    local host_id=$(hostid)

    # Copy hostid to installed system
    cp /etc/hostid /mnt/etc/hostid

    # Create ZFSBootMenu directory on EFI
    mkdir -p /mnt/efi/EFI/ZBM

    # Download ZFSBootMenu release EFI binary
    info "Downloading ZFSBootMenu..."
    local zbm_url="https://get.zfsbootmenu.org/efi"
    if ! curl -fsSL -o /mnt/efi/EFI/ZBM/zfsbootmenu.efi "$zbm_url"; then
        error "Failed to download ZFSBootMenu"
    fi
    info "ZFSBootMenu binary installed."

    # Set kernel command line on the ROOT PARENT dataset
    local cmdline="rw loglevel=3"

    # Add AMD GPU workarounds if needed
    if lspci | grep -qi "amd.*display\|amd.*vga"; then
        info "AMD GPU detected - adding workaround parameters"
        cmdline="$cmdline amdgpu.pg_mask=0 amdgpu.cwsr_enable=0"
    fi

    zfs set org.zfsbootmenu:commandline="$cmdline" "$POOL_NAME/ROOT"
    info "Kernel command line set on $POOL_NAME/ROOT"

    # Set bootfs property
    zpool set bootfs="$POOL_NAME/ROOT/default" "$POOL_NAME"
    info "Default boot filesystem set to $POOL_NAME/ROOT/default"

    # Create EFI boot entries for each disk
    local zbm_cmdline="spl_hostid=0x${host_id} zbm.timeout=3 zbm.prefer=${POOL_NAME} zbm.import_policy=hostid"

    for i in "${!SELECTED_DISKS[@]}"; do
        local disk="${SELECTED_DISKS[$i]}"
        local label="ZFSBootMenu"
        if [[ ${#SELECTED_DISKS[@]} -gt 1 ]]; then
            label="ZFSBootMenu-disk$((i+1))"
        fi

        info "Creating EFI boot entry: $label on $disk"
        efibootmgr --create \
            --disk "$disk" \
            --part 1 \
            --label "$label" \
            --loader '\EFI\ZBM\zfsbootmenu.efi' \
            --unicode "$zbm_cmdline" \
            --quiet
    done

    # Set as primary boot option
    local bootnum=$(efibootmgr | grep "ZFSBootMenu" | head -1 | grep -oP 'Boot\K[0-9A-F]+')
    if [[ -n "$bootnum" ]]; then
        local current_order=$(efibootmgr | grep "BootOrder" | cut -d: -f2 | tr -d ' ')
        efibootmgr --bootorder "$bootnum,$current_order" --quiet
        info "ZFSBootMenu set as primary boot option"
    fi

    info "ZFSBootMenu configuration complete."
}

#############################
# ZFS Services
#############################

configure_zfs_services() {
    step "Configuring ZFS Services"

    arch-chroot /mnt systemctl enable zfs.target
    arch-chroot /mnt systemctl disable zfs-import-cache.service
    arch-chroot /mnt systemctl enable zfs-import-scan.service
    arch-chroot /mnt systemctl enable zfs-mount.service
    arch-chroot /mnt systemctl enable zfs-import.target

    # Disable cachefile - we use zfs-import-scan
    zpool set cachefile=none "$POOL_NAME"
    rm -f /mnt/etc/zfs/zpool.cache

    info "ZFS services configured."
}

#############################
# Pacman Snapshot Hook
#############################

configure_zfs_pacman_hook() {
    step "Configuring Pacman Snapshot Hook"

    mkdir -p /mnt/etc/pacman.d/hooks

    cat > /mnt/etc/pacman.d/hooks/zfs-snapshot.hook << EOF
[Trigger]
Operation = Upgrade
Operation = Install
Operation = Remove
Type = Package
Target = *

[Action]
Description = Creating ZFS snapshot before pacman transaction...
When = PreTransaction
Exec = /usr/local/bin/zfs-pre-snapshot
EOF

    cat > /mnt/usr/local/bin/zfs-pre-snapshot << 'EOF'
#!/bin/bash
POOL="zroot"
DATASET="$POOL/ROOT/default"
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
SNAPSHOT_NAME="pre-pacman_$TIMESTAMP"

if zfs snapshot "$DATASET@$SNAPSHOT_NAME"; then
    echo "Created snapshot: $DATASET@$SNAPSHOT_NAME"
else
    echo "Warning: Failed to create snapshot" >&2
fi
EOF

    chmod +x /mnt/usr/local/bin/zfs-pre-snapshot
    info "Pacman hook configured."
}

#############################
# ZFS Tools
#############################

install_zfs_tools() {
    step "Installing ZFS Management Tools"

    # Copy ZFS management scripts
    cp /usr/local/bin/zfssnapshot /mnt/usr/local/bin/zfssnapshot
    cp /usr/local/bin/zfsrollback /mnt/usr/local/bin/zfsrollback
    chmod +x /mnt/usr/local/bin/zfssnapshot
    chmod +x /mnt/usr/local/bin/zfsrollback

    info "ZFS management scripts installed: zfssnapshot, zfsrollback"
}

#############################
# EFI Sync (Multi-disk)
#############################

sync_zfs_efi_partitions() {
    local efi_parts=()
    for disk in "${SELECTED_DISKS[@]}"; do
        efi_parts+=("$(get_efi_partition "$disk")")
    done

    # Skip if only one disk
    [[ ${#efi_parts[@]} -le 1 ]] && return

    step "Syncing EFI partitions for redundancy"

    local primary="${efi_parts[0]}"
    for ((i=1; i<${#efi_parts[@]}; i++)); do
        local secondary="${efi_parts[$i]}"
        local tmp_mount="/tmp/efi_sync_$$"

        mkdir -p "$tmp_mount"
        mount "$secondary" "$tmp_mount"
        rsync -a /mnt/efi/ "$tmp_mount/"
        umount "$tmp_mount"
        rmdir "$tmp_mount"

        info "Synced EFI to $secondary"
    done
}

#############################
# Genesis Snapshot
#############################

create_zfs_genesis_snapshot() {
    step "Creating Genesis Snapshot"

    local snapshot_name="genesis"
    zfs snapshot -r "$POOL_NAME@$snapshot_name"

    info "Genesis snapshot created: $POOL_NAME@$snapshot_name"
    info "You can restore to this point anytime with: zfsrollback $snapshot_name"
}

#############################
# ZFS Cleanup
#############################

zfs_cleanup() {
    step "Cleaning up ZFS"

    # Unmount all ZFS datasets
    zfs unmount -a 2>/dev/null || true

    # Unmount EFI
    umount /mnt/efi 2>/dev/null || true

    # Export pool (important for clean import on boot)
    zpool export "$POOL_NAME"

    info "ZFS pool exported cleanly."
}
