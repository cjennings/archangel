#!/usr/bin/env bats
# Unit tests for installer/lib/btrfs.sh
#
# Coverage scope: pure helpers only. Most of btrfs.sh wraps cryptsetup,
# mkfs.btrfs, snapper, grub-install, and arch-chroot — all deliberately
# VM-tested per the project's testing-strategy.org policy. Only
# get_luks_devices is covered here.

setup() {
    # shellcheck disable=SC1091
    source "${BATS_TEST_DIRNAME}/../../installer/lib/common.sh"
    # shellcheck disable=SC1091
    source "${BATS_TEST_DIRNAME}/../../installer/lib/btrfs.sh"
}

#############################
# get_luks_devices
#############################
# Asymmetric naming: index 0 uses the bare LUKS_MAPPER_NAME (no
# suffix), subsequent indices append the index. Tests pin both the
# bare-first behavior and the suffix-on-rest behavior.

@test "get_luks_devices: count=1 emits the bare-named mapper device" {
    LUKS_MAPPER_NAME="cryptroot"
    run get_luks_devices 1
    [ "$status" -eq 0 ]
    [ "$output" = "/dev/mapper/cryptroot" ]
}

@test "get_luks_devices: count=3 emits bare name + suffixed entries" {
    LUKS_MAPPER_NAME="cryptroot"
    run get_luks_devices 3
    [ "$status" -eq 0 ]
    [ "$output" = "/dev/mapper/cryptroot /dev/mapper/cryptroot1 /dev/mapper/cryptroot2" ]
}

@test "get_luks_devices: count=0 emits empty output" {
    LUKS_MAPPER_NAME="cryptroot"
    run get_luks_devices 0
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "get_luks_devices: count=5 emits five entries with correct suffix progression" {
    LUKS_MAPPER_NAME="cryptroot"
    run get_luks_devices 5
    [ "$status" -eq 0 ]
    [ "$output" = "/dev/mapper/cryptroot /dev/mapper/cryptroot1 /dev/mapper/cryptroot2 /dev/mapper/cryptroot3 /dev/mapper/cryptroot4" ]
}

@test "get_luks_devices: non-numeric count is treated as zero (no crash)" {
    LUKS_MAPPER_NAME="cryptroot"
    run get_luks_devices abc
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

#############################
# parse_btrfs_subvol_opts
#############################
# Composes the mount-option string for one subvolume from the shared
# BTRFS_OPTS plus the per-subvol extra flags. Pure string transform,
# shared by mount_btrfs_subvolumes and generate_btrfs_fstab. BTRFS_OPTS
# is set at the top of btrfs.sh (sourced in setup), so these pin behavior
# against the real default option string.

@test "parse_btrfs_subvol_opts: no extra flags keeps the default opts" {
    run parse_btrfs_subvol_opts "@home" ""
    [ "$status" -eq 0 ]
    [ "$output" = "subvol=@home,noatime,compress=zstd,space_cache=v2,discard=async" ]
}

@test "parse_btrfs_subvol_opts: compress=no drops compress=zstd" {
    run parse_btrfs_subvol_opts "@media" "compress=no"
    [ "$output" = "subvol=@media,noatime,space_cache=v2,discard=async" ]
}

@test "parse_btrfs_subvol_opts: nodatacow adds nodatacow and drops compress=zstd" {
    run parse_btrfs_subvol_opts "@vms" "nodatacow"
    [ "$output" = "subvol=@vms,noatime,space_cache=v2,discard=async,nodatacow" ]
}

@test "parse_btrfs_subvol_opts: nosuid adds nosuid,nodev and keeps compression" {
    run parse_btrfs_subvol_opts "@tmp" "nosuid"
    [ "$output" = "subvol=@tmp,noatime,compress=zstd,space_cache=v2,discard=async,nosuid,nodev" ]
}

@test "parse_btrfs_subvol_opts: nodatacow and nosuid combine" {
    run parse_btrfs_subvol_opts "@x" "nodatacow,nosuid"
    [ "$output" = "subvol=@x,noatime,space_cache=v2,discard=async,nodatacow,nosuid,nodev" ]
}
