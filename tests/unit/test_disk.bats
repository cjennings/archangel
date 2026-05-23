#!/usr/bin/env bats
# Unit tests for installer/lib/disk.sh
#
# Coverage scope: pure partition-path helpers (get_efi_partition,
# get_root_partition) plus the partition_disks orchestration shape
# (which globals get populated, which destructive tools get invoked,
# how often). The destructive tools themselves (sgdisk, wipefs,
# partprobe, mkfs.fat) and the interactive select_disks (fzf) are
# validated by VM integration per the project's testing-strategy.org
# policy.

setup() {
    # shellcheck disable=SC1091
    source "${BATS_TEST_DIRNAME}/../../installer/lib/common.sh"
    # shellcheck disable=SC1091
    source "${BATS_TEST_DIRNAME}/../../installer/lib/disk.sh"
}

#############################
# get_efi_partition
#############################

@test "get_efi_partition: SATA disk gets numeric suffix 1" {
    run get_efi_partition /dev/sda
    [ "$status" -eq 0 ]
    [ "$output" = "/dev/sda1" ]
}

@test "get_efi_partition: virtio disk gets numeric suffix 1" {
    run get_efi_partition /dev/vda
    [ "$status" -eq 0 ]
    [ "$output" = "/dev/vda1" ]
}

@test "get_efi_partition: NVMe disk gets p1 suffix" {
    run get_efi_partition /dev/nvme0n1
    [ "$status" -eq 0 ]
    [ "$output" = "/dev/nvme0n1p1" ]
}

@test "get_efi_partition: NVMe with multi-namespace disk gets p1 suffix" {
    run get_efi_partition /dev/nvme1n2
    [ "$status" -eq 0 ]
    [ "$output" = "/dev/nvme1n2p1" ]
}

@test "get_efi_partition: empty input documents current behavior" {
    # Empty input misses the nvme regex so the bare-suffix branch fires,
    # producing just "1". This pins the existing behavior; the function
    # is never called with empty in production but pinning catches a
    # change in suffix-rule logic.
    run get_efi_partition ""
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

#############################
# get_root_partition
#############################

@test "get_root_partition: SATA disk gets numeric suffix 2" {
    run get_root_partition /dev/sda
    [ "$status" -eq 0 ]
    [ "$output" = "/dev/sda2" ]
}

@test "get_root_partition: NVMe disk gets p2 suffix" {
    run get_root_partition /dev/nvme0n1
    [ "$status" -eq 0 ]
    [ "$output" = "/dev/nvme0n1p2" ]
}

@test "get_root_partition: virtio disk gets numeric suffix 2" {
    run get_root_partition /dev/vdb
    [ "$status" -eq 0 ]
    [ "$output" = "/dev/vdb2" ]
}

#############################
# partition_disks (orchestration)
#############################
# partition_disks reads SELECTED_DISKS, dispatches the per-disk
# layout (sgdisk + wipefs + mkfs.fat) on FILESYSTEM, and populates
# EFI_PARTS + ROOT_PARTS for downstream callers (create_zfs_pool,
# btrfs_open_encryption, sync_efi_partitions, fstab generation).
#
# The destructive system tools (sgdisk, wipefs, partprobe, mkfs.fat)
# are mocked to capture invocation shape only — actual partition
# behavior is validated by VM integration per testing-strategy.org.

partition_disks_setup() {
    SELECTED_DISKS=()
    EFI_PARTS=()
    ROOT_PARTS=()
    CALLS=()
    sgdisk()    { CALLS+=("sgdisk $*");   return 0; }
    wipefs()    { CALLS+=("wipefs $*");   return 0; }
    partprobe() { CALLS+=("partprobe $*"); return 0; }
    mkfs.fat()  { CALLS+=("mkfs.fat $*");  return 0; }
    sleep()     { :; }
    info()      { :; }
    step()      { :; }
    error()     { CALLS+=("error $*"); return 1; }
}

@test "partition_disks: populates EFI_PARTS and ROOT_PARTS for single SATA disk" {
    partition_disks_setup
    SELECTED_DISKS=(/dev/sda)
    FILESYSTEM=zfs

    partition_disks

    [ "${#EFI_PARTS[@]}" -eq 1 ]
    [ "${#ROOT_PARTS[@]}" -eq 1 ]
    [ "${EFI_PARTS[0]}" = "/dev/sda1" ]
    [ "${ROOT_PARTS[0]}" = "/dev/sda2" ]
}

@test "partition_disks: NVMe disk gets p1/p2 suffixes in globals" {
    partition_disks_setup
    SELECTED_DISKS=(/dev/nvme0n1)
    FILESYSTEM=zfs

    partition_disks

    [ "${EFI_PARTS[0]}" = "/dev/nvme0n1p1" ]
    [ "${ROOT_PARTS[0]}" = "/dev/nvme0n1p2" ]
}

@test "partition_disks: multi-disk SATA populates both arrays in order" {
    partition_disks_setup
    SELECTED_DISKS=(/dev/sda /dev/sdb /dev/sdc)
    FILESYSTEM=zfs

    partition_disks

    [ "${#EFI_PARTS[@]}" -eq 3 ]
    [ "${#ROOT_PARTS[@]}" -eq 3 ]
    [ "${EFI_PARTS[0]}" = "/dev/sda1" ]
    [ "${EFI_PARTS[1]}" = "/dev/sdb1" ]
    [ "${EFI_PARTS[2]}" = "/dev/sdc1" ]
    [ "${ROOT_PARTS[0]}" = "/dev/sda2" ]
    [ "${ROOT_PARTS[1]}" = "/dev/sdb2" ]
    [ "${ROOT_PARTS[2]}" = "/dev/sdc2" ]
}

@test "partition_disks: mixed SATA + NVMe applies correct suffix per disk" {
    partition_disks_setup
    SELECTED_DISKS=(/dev/sda /dev/nvme0n1)
    FILESYSTEM=zfs

    partition_disks

    [ "${EFI_PARTS[0]}" = "/dev/sda1" ]
    [ "${EFI_PARTS[1]}" = "/dev/nvme0n1p1" ]
    [ "${ROOT_PARTS[0]}" = "/dev/sda2" ]
    [ "${ROOT_PARTS[1]}" = "/dev/nvme0n1p2" ]
}

@test "partition_disks: ZFS dispatch passes BF00 root type to sgdisk" {
    partition_disks_setup
    SELECTED_DISKS=(/dev/sda)
    FILESYSTEM=zfs

    partition_disks

    [[ " ${CALLS[*]} " == *"sgdisk -n 2:0:0 -t 2:BF00"* ]]
}

@test "partition_disks: Btrfs dispatch passes 8300 root type to sgdisk" {
    partition_disks_setup
    SELECTED_DISKS=(/dev/sda)
    FILESYSTEM=btrfs

    partition_disks

    [[ " ${CALLS[*]} " == *"sgdisk -n 2:0:0 -t 2:8300"* ]]
}

@test "partition_disks: invokes wipefs -af on each disk" {
    partition_disks_setup
    SELECTED_DISKS=(/dev/sda /dev/sdb)
    FILESYSTEM=zfs

    partition_disks

    local count
    count=$(printf '%s\n' "${CALLS[@]}" | grep -c '^wipefs -af ')
    [ "$count" -eq 2 ]
    [[ " ${CALLS[*]} " == *"wipefs -af /dev/sda"* ]]
    [[ " ${CALLS[*]} " == *"wipefs -af /dev/sdb"* ]]
}

@test "partition_disks: invokes mkfs.fat once per EFI partition with EFI<i> label" {
    partition_disks_setup
    SELECTED_DISKS=(/dev/sda /dev/sdb)
    FILESYSTEM=zfs

    partition_disks

    local count
    count=$(printf '%s\n' "${CALLS[@]}" | grep -c '^mkfs.fat ')
    [ "$count" -eq 2 ]
    [[ " ${CALLS[*]} " == *"mkfs.fat -F32 -n EFI0 /dev/sda1"* ]]
    [[ " ${CALLS[*]} " == *"mkfs.fat -F32 -n EFI1 /dev/sdb1"* ]]
}

@test "partition_disks: re-initializes globals on second call" {
    partition_disks_setup
    SELECTED_DISKS=(/dev/sda /dev/sdb)
    FILESYSTEM=zfs

    partition_disks
    [ "${#EFI_PARTS[@]}" -eq 2 ]

    SELECTED_DISKS=(/dev/sdc)
    partition_disks

    [ "${#EFI_PARTS[@]}" -eq 1 ]
    [ "${#ROOT_PARTS[@]}" -eq 1 ]
    [ "${EFI_PARTS[0]}" = "/dev/sdc1" ]
}

@test "partition_disks: empty SELECTED_DISKS calls error and skips work" {
    partition_disks_setup
    SELECTED_DISKS=()
    FILESYSTEM=zfs

    partition_disks || true

    [[ " ${CALLS[*]} " == *"error partition_disks: SELECTED_DISKS is empty"* ]]
    [[ " ${CALLS[*]} " != *"sgdisk"* ]]
    [[ " ${CALLS[*]} " != *"wipefs"* ]]
}

#############################
# disk_meets_min_size / MIN_DISK_BYTES
#############################

@test "MIN_DISK_BYTES is 20 GB (decimal)" {
    [ "$MIN_DISK_BYTES" -eq 20000000000 ]
}

@test "disk_meets_min_size: exactly the minimum passes" {
    run disk_meets_min_size 20000000000
    [ "$status" -eq 0 ]
}

@test "disk_meets_min_size: one byte under the minimum fails" {
    run disk_meets_min_size 19999999999
    [ "$status" -eq 1 ]
}

@test "disk_meets_min_size: a 20 GiB disk image clears the 20 GB floor" {
    run disk_meets_min_size 21474836480
    [ "$status" -eq 0 ]
}

@test "disk_meets_min_size: a large disk passes" {
    run disk_meets_min_size 500107862016
    [ "$status" -eq 0 ]
}

@test "disk_meets_min_size: zero fails" {
    run disk_meets_min_size 0
    [ "$status" -eq 1 ]
}

@test "disk_meets_min_size: non-numeric input fails" {
    run disk_meets_min_size notanumber
    [ "$status" -eq 1 ]
}

@test "disk_meets_min_size: empty input fails" {
    run disk_meets_min_size ""
    [ "$status" -eq 1 ]
}

# disk_in_use
#
# The safety gate validate_install_targets leans on to refuse wiping a disk
# that's already in use. Each branch (mount, swap, imported zpool, idle) is
# driven by mocking the system-boundary commands it queries — lsblk, swapon,
# command_exists, zpool. The /proc/mdstat branch's positive case can't be
# unit-driven without writing to /proc, so it stays VM-harness territory; the
# idle case below pins the negative for a name guaranteed absent from mdstat.
# This is the error path for the "installing onto an already-mounted disk"
# case: in_use returns 0, and the orchestrator turns that into a hard fail.

@test "disk_in_use: returns 0 when a mountpoint is present" {
    lsblk() { echo "/boot"; }
    run disk_in_use /dev/sda
    [ "$status" -eq 0 ]
}

@test "disk_in_use: returns 0 when active swap sits on the disk" {
    lsblk() { :; }
    swapon() { echo "/dev/sda2"; }
    run disk_in_use /dev/sda
    [ "$status" -eq 0 ]
}

@test "disk_in_use: returns 0 when the disk is a member of an imported zpool" {
    lsblk() { :; }
    swapon() { :; }
    command_exists() { return 0; }
    # -P prints full paths; a partition member (/dev/sda2) must still match
    # the bare disk path via fixed-string search.
    zpool() { echo "  /dev/sda2  ONLINE       0     0     0"; }
    run disk_in_use /dev/sda
    [ "$status" -eq 0 ]
}

@test "disk_in_use: returns 1 when the disk is idle" {
    lsblk() { :; }
    swapon() { :; }
    command_exists() { return 1; }
    # A name that won't appear in the host's /proc/mdstat keeps the final
    # branch deterministic.
    run disk_in_use /dev/zzz999
    [ "$status" -eq 1 ]
}
