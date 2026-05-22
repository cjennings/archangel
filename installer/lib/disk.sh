#!/usr/bin/env bash
# disk.sh - Disk partitioning functions for archangel installer
# Source this file after common.sh

#############################
# Partition Disks
#############################

# Partition a single disk for ZFS or Btrfs installation. Wipes
# non-GPT signatures (LVM, mdadm, ext) with wipefs, zaps the GPT
# with sgdisk, then lays down a 512M EFI partition plus a root
# partition that fills the rest. Root partition type code is
# selected from FILESYSTEM (BF00 for ZFS, 8300 for Btrfs).
partition_disk() {
    local disk="$1"
    local efi_size="${2:-512M}"

    local root_type="BF00"
    if [[ "$FILESYSTEM" == "btrfs" ]]; then
        root_type="8300"
    fi

    info "Partitioning $disk..."

    wipefs -af "$disk" || error "Failed to wipe signatures on $disk"
    sgdisk --zap-all "$disk" || error "Failed to zap GPT on $disk"
    sgdisk -n 1:0:+${efi_size} -t 1:EF00 -c 1:"EFI" "$disk" || error "Failed to create EFI partition on $disk"
    sgdisk -n 2:0:0 -t 2:$root_type -c 2:"ROOT" "$disk" || error "Failed to create root partition on $disk"

    partprobe "$disk" 2>/dev/null || true
    sleep 1

    info "Partitioned $disk: EFI=${efi_size}, ROOT=remainder"
}

# Partition every disk in SELECTED_DISKS, format each EFI partition,
# and populate the EFI_PARTS + ROOT_PARTS arrays for downstream
# callers (create_zfs_pool, btrfs_open_encryption,
# sync_efi_partitions, fstab generation).
#
# EFI labels are EFI0, EFI1, ... in selection order so multi-disk
# layouts get a stable, distinguishable scheme that lsblk -f can
# show. Errors out if SELECTED_DISKS is empty so a misconfigured
# install can't silently skip partitioning.
partition_disks() {
    if [[ ${#SELECTED_DISKS[@]} -eq 0 ]]; then
        error "partition_disks: SELECTED_DISKS is empty"
    fi

    step "Partitioning ${#SELECTED_DISKS[@]} disk(s)"

    EFI_PARTS=()
    ROOT_PARTS=()

    for disk in "${SELECTED_DISKS[@]}"; do
        partition_disk "$disk"
        EFI_PARTS+=("$(get_efi_partition "$disk")")
        ROOT_PARTS+=("$(get_root_partition "$disk")")
    done

    sleep 2

    for i in "${!EFI_PARTS[@]}"; do
        info "Formatting EFI partition ${EFI_PARTS[$i]}..."
        mkfs.fat -F32 -n "EFI$i" "${EFI_PARTS[$i]}" || error "Failed to format ${EFI_PARTS[$i]}"
    done

    info "Partitioning complete. Created ${#EFI_PARTS[@]} EFI and ${#ROOT_PARTS[@]} ROOT partitions."
}

#############################
# Partition Helpers
#############################

# Get EFI partition path for a disk
get_efi_partition() {
    local disk="$1"
    if [[ "$disk" =~ nvme ]]; then
        echo "${disk}p1"
    else
        echo "${disk}1"
    fi
}

# Get root partition path for a disk
get_root_partition() {
    local disk="$1"
    if [[ "$disk" =~ nvme ]]; then
        echo "${disk}p2"
    else
        echo "${disk}2"
    fi
}

#############################
# Disk Selection (Interactive)
#############################

# Interactive disk selection using fzf
select_disks() {
    local available
    available=$(list_available_disks)

    if [[ -z "$available" ]]; then
        error "No available disks found"
    fi

    step "Select installation disk(s)"
    prompt "Use Tab to select multiple disks for RAID, Enter to confirm"

    local selected
    if has_fzf; then
        selected=$(echo "$available" | fzf --multi --prompt="Select disk(s): " --height=15 --reverse)
    else
        echo "$available"
        read -rp "Enter disk path(s) separated by space: " selected
    fi

    if [[ -z "$selected" ]]; then
        error "No disk selected"
    fi

    # Extract just the device paths (remove size/model info)
    SELECTED_DISKS=()
    while IFS= read -r line; do
        local disk
        disk=$(echo "$line" | cut -d' ' -f1)
        SELECTED_DISKS+=("$disk")
    done <<< "$selected"

    info "Selected disks: ${SELECTED_DISKS[*]}"
}

#############################
# Pre-flight: Disk Safety
#############################

# Minimum usable install disk. Root plus the 50G reservation, packages, and
# snapshots needs real headroom; below this the install fails partway
# through. 20 GB is a hard floor (validate_install_targets errors out).
# Decimal GB (disk-vendor sizing) on purpose: it reads as the natural "20GB"
# minimum and clears a 20 GiB disk image with headroom rather than sitting
# exactly on the boundary.
MIN_DISK_BYTES=20000000000   # 20 * 10^9 (20 GB)

# Pure size predicate: succeed only when <bytes> is a non-negative integer
# meeting MIN_DISK_BYTES. Non-numeric or empty input fails (treated as an
# unknown size, which is itself a reason not to proceed).
disk_meets_min_size() {
    local bytes="$1"
    [[ "$bytes" =~ ^[0-9]+$ ]] || return 1
    (( bytes >= MIN_DISK_BYTES ))
}

# Size of a block device in bytes (live query). Thin wrapper over blockdev;
# exercised by the VM integration harness rather than unit tests.
disk_size_bytes() {
    blockdev --getsize64 "$1" 2>/dev/null
}

# Succeed (return 0) when <disk> is in active use and must NOT be wiped:
# any partition mounted, active swap on it, or membership in an imported
# zpool or assembled md array. Over-detection errs on the safe side
# (refuse). Live-state predicate — validated in the VM harness, where the
# install disks are deliberately idle so the happy path returns 1.
disk_in_use() {
    local disk="$1"
    local base
    base=$(basename "$disk")

    # Any mountpoint on the disk or its children.
    if lsblk -nro MOUNTPOINT "$disk" 2>/dev/null | grep -q .; then
        return 0
    fi
    # Active swap on the disk or a partition of it.
    if swapon --show=NAME --noheadings 2>/dev/null | grep -q "^${disk}"; then
        return 0
    fi
    # Member of an imported zpool. -P prints full device paths (/dev/vda2),
    # so a fixed-string match on the disk path catches partition members too
    # — a plain word match on the bare name would miss "vda2".
    if command_exists zpool && zpool status -LP 2>/dev/null | grep -qF "$disk"; then
        return 0
    fi
    # Member of an assembled md array. /proc/mdstat lists bare partition names
    # (vda1[0]); substring-match the disk name (over-match errs toward refuse).
    if grep -qsF "$base" /proc/mdstat 2>/dev/null; then
        return 0
    fi
    return 1
}

