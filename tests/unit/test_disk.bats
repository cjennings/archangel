#!/usr/bin/env bats
# Unit tests for installer/lib/disk.sh
#
# Coverage scope: pure partition-path helpers only. Side-effecting
# functions (partition_disk, partition_disks, format_efi,
# format_efi_partitions, select_disks) wrap sgdisk / mkfs.fat /
# partprobe / fzf and are validated by VM integration per the
# project's testing-strategy.org policy.

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
# get_efi_partitions
#############################

@test "get_efi_partitions: two SATA disks emit two suffixed partitions" {
    run get_efi_partitions /dev/sda /dev/sdb
    [ "$status" -eq 0 ]
    [ "$output" = "/dev/sda1
/dev/sdb1" ]
}

@test "get_efi_partitions: mixed SATA + NVMe gets correct per-disk suffix" {
    run get_efi_partitions /dev/sda /dev/nvme0n1
    [ "$status" -eq 0 ]
    [ "$output" = "/dev/sda1
/dev/nvme0n1p1" ]
}

@test "get_efi_partitions: single NVMe disk emits one p1 partition" {
    run get_efi_partitions /dev/nvme0n1
    [ "$status" -eq 0 ]
    [ "$output" = "/dev/nvme0n1p1" ]
}

@test "get_efi_partitions: three disks emit three lines in order" {
    run get_efi_partitions /dev/sda /dev/sdb /dev/sdc
    [ "$status" -eq 0 ]
    local lines
    lines=$(echo "$output" | wc -l)
    [ "$lines" -eq 3 ]
}

#############################
# get_root_partitions
#############################

@test "get_root_partitions: two SATA disks emit two suffix-2 partitions" {
    run get_root_partitions /dev/sda /dev/sdb
    [ "$status" -eq 0 ]
    [ "$output" = "/dev/sda2
/dev/sdb2" ]
}

@test "get_root_partitions: mixed SATA + NVMe applies correct suffix per disk" {
    run get_root_partitions /dev/sda /dev/nvme0n1
    [ "$status" -eq 0 ]
    [ "$output" = "/dev/sda2
/dev/nvme0n1p2" ]
}

@test "get_root_partitions: NVMe array gets p2 suffix on each entry" {
    run get_root_partitions /dev/nvme0n1 /dev/nvme1n1
    [ "$status" -eq 0 ]
    [ "$output" = "/dev/nvme0n1p2
/dev/nvme1n1p2" ]
}
