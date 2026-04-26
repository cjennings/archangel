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
