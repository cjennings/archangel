#!/usr/bin/env bash
# disk.sh - Disk partitioning functions for archangel installer
# Source this file after common.sh

#############################
# Partition Disks
#############################

# Partition a single disk for ZFS/Btrfs installation
# Creates: EFI partition (512M) + root partition (rest)
partition_disk() {
    local disk="$1"
    local efi_size="${2:-512M}"

    info "Partitioning $disk..."

    # Wipe existing partition table
    sgdisk --zap-all "$disk" || error "Failed to wipe $disk"

    # Create EFI partition (512M, type EF00)
    sgdisk -n 1:0:+${efi_size} -t 1:EF00 -c 1:"EFI" "$disk" || error "Failed to create EFI partition on $disk"

    # Create root partition (rest of disk, type BF00 for ZFS or 8300 for Linux)
    sgdisk -n 2:0:0 -t 2:BF00 -c 2:"ROOT" "$disk" || error "Failed to create root partition on $disk"

    # Notify kernel of partition changes
    partprobe "$disk" 2>/dev/null || true
    sleep 1

    info "Partitioned $disk: EFI=${efi_size}, ROOT=remainder"
}

# Partition multiple disks (for RAID configurations)
partition_disks() {
    local efi_size="${1:-512M}"
    shift
    local disks=("$@")

    for disk in "${disks[@]}"; do
        partition_disk "$disk" "$efi_size"
    done
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

# Get all root partitions from disk array
get_root_partitions() {
    local disks=("$@")
    local parts=()
    for disk in "${disks[@]}"; do
        parts+=("$(get_root_partition "$disk")")
    done
    printf '%s\n' "${parts[@]}"
}

# Get all EFI partitions from disk array
get_efi_partitions() {
    local disks=("$@")
    local parts=()
    for disk in "${disks[@]}"; do
        parts+=("$(get_efi_partition "$disk")")
    done
    printf '%s\n' "${parts[@]}"
}

#############################
# EFI Partition Management
#############################

# Format EFI partition
format_efi() {
    local partition="$1"
    local label="${2:-EFI}"

    info "Formatting EFI partition: $partition"
    mkfs.fat -F32 -n "$label" "$partition" || error "Failed to format EFI: $partition"
}

# Format all EFI partitions
format_efi_partitions() {
    local disks=("$@")
    local first=true

    for disk in "${disks[@]}"; do
        local efi=$(get_efi_partition "$disk")
        if $first; then
            format_efi "$efi" "EFI"
            first=false
        else
            format_efi "$efi" "EFI2"
        fi
    done
}

# Mount EFI partition
mount_efi() {
    local partition="$1"
    local mount_point="${2:-/mnt/efi}"

    mkdir -p "$mount_point"
    mount "$partition" "$mount_point" || error "Failed to mount EFI at $mount_point"
    info "Mounted EFI: $partition -> $mount_point"
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
        local disk=$(echo "$line" | cut -d' ' -f1)
        SELECTED_DISKS+=("$disk")
    done <<< "$selected"

    info "Selected disks: ${SELECTED_DISKS[*]}"
}

#############################
# RAID Level Selection
#############################

select_raid_level() {
    local num_disks=${#SELECTED_DISKS[@]}

    if [[ $num_disks -eq 1 ]]; then
        RAID_LEVEL=""
        info "Single disk - no RAID"
        return
    fi

    step "Select RAID level"

    local options=()
    options+=("mirror - Mirror data across disks (recommended)")

    if [[ $num_disks -ge 3 ]]; then
        options+=("raidz1 - Single parity, lose 1 disk capacity")
    fi
    if [[ $num_disks -ge 4 ]]; then
        options+=("raidz2 - Double parity, lose 2 disks capacity")
    fi

    local selected
    selected=$(fzf_select "RAID level:" "${options[@]}")
    RAID_LEVEL=$(echo "$selected" | cut -d' ' -f1)

    info "Selected RAID level: $RAID_LEVEL"
}
