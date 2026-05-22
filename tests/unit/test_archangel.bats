#!/usr/bin/env bats
# Unit tests for the installer/archangel monolith.
#
# Coverage scope: gather_input() in unattended mode — defaulting of
# optional values, preservation of explicit ones, and the
# filesystem-specific encryption checks. Required-field, disk, and
# timezone validation moved to validate_config (called from main
# before gather_input); its coverage lives in test_config.bats.
# The interactive branch (everything reachable via
# `if [[ "$UNATTENDED" != true ]]`) is not unit-tested per the
# project's testing-strategy.org policy on fzf / arch-chroot /
# mkfs / cryptsetup wrappers.
#
# Sourcing archangel relies on the source-guard at the bottom of
# the script: when sourced, function definitions load but main is
# not called, init_logging is not run (so /tmp/archangel-*.log is
# not created), and the banner is not printed.

setup() {
    # shellcheck disable=SC1091
    source "${BATS_TEST_DIRNAME}/../../installer/archangel"
    UNATTENDED=true
}

#############################
# Optional-field defaults
#############################
# Default values themselves are pinned in test_config.bats (config.sh
# is the single source of truth). The remaining test here covers the
# adjacent guarantee: gather_input doesn't clobber values the user set.

@test "gather_input unattended preserves explicit non-default values" {
    HOSTNAME=h
    TIMEZONE=UTC
    ROOT_PASSWORD=x
    SELECTED_DISKS=(/dev/sda)
    FILESYSTEM=btrfs
    NO_ENCRYPT=yes
    LOCALE="en_GB.UTF-8"
    KEYMAP="dvorak"
    ENABLE_SSH="no"
    gather_input >/dev/null
    [ "$FILESYSTEM" = "btrfs" ]
    [ "$LOCALE" = "en_GB.UTF-8" ]
    [ "$KEYMAP" = "dvorak" ]
    [ "$ENABLE_SSH" = "no" ]
}

#############################
# Filesystem-specific encryption validation
#############################

@test "gather_input unattended errors when ZFS without ZFS_PASSPHRASE and encryption on" {
    HOSTNAME=h
    TIMEZONE=UTC
    ROOT_PASSWORD=x
    SELECTED_DISKS=(/dev/sda)
    FILESYSTEM=zfs
    NO_ENCRYPT=no
    ZFS_PASSPHRASE=""
    run gather_input
    [ "$status" -eq 1 ]
    [[ "$output" == *"ZFS_PASSPHRASE"* ]]
}

@test "gather_input unattended errors when Btrfs without LUKS_PASSPHRASE and encryption on" {
    HOSTNAME=h
    TIMEZONE=UTC
    ROOT_PASSWORD=x
    SELECTED_DISKS=(/dev/sda)
    FILESYSTEM=btrfs
    NO_ENCRYPT=no
    LUKS_PASSPHRASE=""
    run gather_input
    [ "$status" -eq 1 ]
    [[ "$output" == *"LUKS_PASSPHRASE"* ]]
}

@test "gather_input unattended accepts ZFS with NO_ENCRYPT=yes and no passphrase" {
    HOSTNAME=h
    TIMEZONE=UTC
    ROOT_PASSWORD=x
    SELECTED_DISKS=(/dev/sda)
    FILESYSTEM=zfs
    NO_ENCRYPT=yes
    ZFS_PASSPHRASE=""
    run gather_input
    [ "$status" -eq 0 ]
}

#############################
# Filesystem validity
#############################
# Validation moved to validate_filesystem in lib/config.sh — covered
# by test_config.bats. main() calls it between check_config and
# gather_input so a bad FILESYSTEM= never reaches install time.

#############################
# RAID-level defaulting
#############################

@test "gather_input unattended defaults RAID_LEVEL to mirror for multi-disk install" {
    HOSTNAME=h
    TIMEZONE=UTC
    ROOT_PASSWORD=x
    SELECTED_DISKS=(/dev/sda /dev/sdb)
    FILESYSTEM=zfs
    NO_ENCRYPT=yes
    RAID_LEVEL=""
    gather_input >/dev/null
    [ "$RAID_LEVEL" = "mirror" ]
}

@test "gather_input unattended preserves an explicit RAID_LEVEL on multi-disk install" {
    HOSTNAME=h
    TIMEZONE=UTC
    ROOT_PASSWORD=x
    SELECTED_DISKS=(/dev/sda /dev/sdb /dev/sdc)
    FILESYSTEM=zfs
    NO_ENCRYPT=yes
    RAID_LEVEL="raidz1"
    gather_input >/dev/null
    [ "$RAID_LEVEL" = "raidz1" ]
}

@test "gather_input unattended leaves RAID_LEVEL empty for single-disk install" {
    HOSTNAME=h
    TIMEZONE=UTC
    ROOT_PASSWORD=x
    SELECTED_DISKS=(/dev/sda)
    FILESYSTEM=zfs
    NO_ENCRYPT=yes
    RAID_LEVEL=""
    gather_input >/dev/null
    [ -z "$RAID_LEVEL" ]
}

#############################
# install_failure_cleanup
#############################
# install_failure_cleanup is the trap target for ERR / INT / TERM
# during install_zfs and install_btrfs. It clears sensitive vars,
# dispatches on FILESYSTEM, and exits non-zero. Tests use function
# overrides to capture which system tools the cleanup invokes; the
# tools themselves (umount, zpool, btrfs_cleanup,
# btrfs_close_encryption) are deliberately VM-tested per
# testing-strategy.org.

@test "install_failure_cleanup clears sensitive variables before exiting" {
    FILESYSTEM=zfs
    POOL_NAME=zroot
    ROOT_PASSWORD="topsecret"
    ZFS_PASSPHRASE="anothersecret"
    LUKS_PASSPHRASE="thirdsecret"

    # Mocks: silent no-ops for system tools; error returns non-zero
    # so the function returns instead of exiting the test process.
    umount() { :; }
    zpool() { return 1; }
    btrfs_cleanup() { :; }
    btrfs_close_encryption() { :; }
    warn() { :; }
    error() { return 1; }

    install_failure_cleanup || true

    [ -z "$ROOT_PASSWORD" ]
    [ -z "$ZFS_PASSPHRASE" ]
    [ -z "$LUKS_PASSPHRASE" ]
}

@test "install_failure_cleanup dispatches to ZFS path when FILESYSTEM=zfs" {
    FILESYSTEM=zfs
    POOL_NAME=zroot
    CALLS=()

    # Mocks track invocations via CALLS array. Array assignment is not
    # affected by the production code's >/dev/null 2>&1 redirects on
    # the zpool list check, so we capture the call regardless of where
    # the mock's stdout would have gone.
    umount() { CALLS+=("umount $*"); return 0; }
    zpool() {
        CALLS+=("zpool $*")
        [[ "$1" == "list" ]] && return 0
        return 0
    }
    btrfs_cleanup() { CALLS+=("btrfs_cleanup"); }
    btrfs_close_encryption() { CALLS+=("btrfs_close_encryption"); }
    warn() { :; }
    error() { CALLS+=("error"); return 1; }

    install_failure_cleanup || true

    [[ " ${CALLS[*]} " == *" umount /mnt/efi "* ]]
    [[ " ${CALLS[*]} " == *" umount -R /mnt "* ]]
    [[ " ${CALLS[*]} " == *" zpool list zroot "* ]]
    [[ " ${CALLS[*]} " == *" zpool export zroot "* ]]
    [[ " ${CALLS[*]} " != *" btrfs_cleanup "* ]]
    [[ " ${CALLS[*]} " != *" btrfs_close_encryption "* ]]
}

@test "install_failure_cleanup dispatches to Btrfs path when FILESYSTEM=btrfs" {
    FILESYSTEM=btrfs
    CALLS=()

    umount() { CALLS+=("umount $*"); return 0; }
    zpool() { CALLS+=("zpool $*"); return 0; }
    btrfs_cleanup() { CALLS+=("btrfs_cleanup"); }
    btrfs_close_encryption() { CALLS+=("btrfs_close_encryption"); }
    warn() { :; }
    error() { CALLS+=("error"); return 1; }

    install_failure_cleanup || true

    [[ " ${CALLS[*]} " == *" umount /mnt/efi "* ]]
    [[ " ${CALLS[*]} " == *" btrfs_cleanup "* ]]
    [[ " ${CALLS[*]} " == *" btrfs_close_encryption "* ]]
    [[ " ${CALLS[*]} " != *" zpool"* ]]
}

@test "install_failure_cleanup ZFS path skips zpool export when pool not imported" {
    FILESYSTEM=zfs
    POOL_NAME=zroot
    CALLS=()

    umount() { CALLS+=("umount $*"); return 0; }
    zpool() {
        CALLS+=("zpool $*")
        [[ "$1" == "list" ]] && return 1  # pool NOT imported
        return 0
    }
    btrfs_cleanup() { :; }
    btrfs_close_encryption() { :; }
    warn() { :; }
    error() { return 1; }

    install_failure_cleanup || true

    [[ " ${CALLS[*]} " == *" zpool list zroot "* ]]
    [[ " ${CALLS[*]} " != *" zpool export"* ]]
}

@test "install_failure_cleanup ZFS path falls back to lazy unmount when a mount is busy" {
    FILESYSTEM=zfs
    POOL_NAME=zroot
    CALLS=()

    # A pacstrap-interrupted target can leave busy mounts that a plain
    # umount can't release; cleanup must retry lazily so the retry sees a
    # clean disk. Non-lazy umount fails here; the -l fallback succeeds.
    umount() {
        CALLS+=("umount $*")
        [[ "$*" == *"-l"* ]] && return 0
        return 1
    }
    zpool() { CALLS+=("zpool $*"); return 0; }
    warn() { :; }
    error() { return 1; }

    install_failure_cleanup || true

    [[ " ${CALLS[*]} " == *" umount -l /mnt/efi "* ]]
    [[ " ${CALLS[*]} " == *" umount -R -l /mnt "* ]]
    # The pool still gets exported after the lazy unmount.
    [[ " ${CALLS[*]} " == *" zpool export zroot "* ]]
}

@test "install_failure_cleanup Btrfs path falls back to lazy unmount when EFI is busy" {
    FILESYSTEM=btrfs
    CALLS=()

    umount() {
        CALLS+=("umount $*")
        [[ "$*" == *"-l"* ]] && return 0
        return 1
    }
    btrfs_cleanup() { CALLS+=("btrfs_cleanup"); }
    btrfs_close_encryption() { CALLS+=("btrfs_close_encryption"); }
    warn() { :; }
    error() { return 1; }

    install_failure_cleanup || true

    [[ " ${CALLS[*]} " == *" umount -l /mnt/efi "* ]]
}

#############################
# validate_environment
#############################
# Boundary wrappers (is_uefi_boot, required_commands) are stubbed so the
# composition's fail-fast wiring is exercised without depending on the
# host's firmware mode or installed tools. The real command list lives in
# test_common.bats; the real UEFI/network probes run in the VM harness.

@test "validate_environment errors when not booted in UEFI mode" {
    is_uefi_boot() { return 1; }
    required_commands() { return 0; }
    FILESYSTEM=zfs
    run validate_environment
    [ "$status" -eq 1 ]
    [[ "$output" == *"UEFI"* ]]
}

@test "validate_environment errors when a required command is missing" {
    is_uefi_boot() { return 0; }
    required_commands() { echo "definitely-not-a-real-cmd-xyz"; }
    FILESYSTEM=zfs
    run validate_environment
    [ "$status" -eq 1 ]
    [[ "$output" == *"definitely-not-a-real-cmd-xyz"* ]]
}

@test "validate_environment passes when UEFI present and commands resolve" {
    is_uefi_boot() { return 0; }
    required_commands() { echo "bash"; }
    FILESYSTEM=zfs
    run validate_environment
    [ "$status" -eq 0 ]
}

#############################
# validate_install_targets
#############################
# disk_in_use / disk_size_bytes / network_available are the system-boundary
# wrappers; stubbing them drives the real composition + real
# disk_meets_min_size. Live probes run in the VM harness on the happy path.

@test "validate_install_targets errors when a disk is in use" {
    SELECTED_DISKS=(/dev/sda)
    disk_in_use() { return 0; }
    disk_size_bytes() { echo 500107862016; }
    network_available() { return 0; }
    run validate_install_targets
    [ "$status" -eq 1 ]
    [[ "$output" == *"in use"* ]]
}

@test "validate_install_targets errors when a disk is too small" {
    SELECTED_DISKS=(/dev/sda)
    disk_in_use() { return 1; }
    disk_size_bytes() { echo 1000000; }
    network_available() { return 0; }
    run validate_install_targets
    [ "$status" -eq 1 ]
    [[ "$output" == *"too small"* ]]
}

@test "validate_install_targets errors when disk size is unreadable" {
    SELECTED_DISKS=(/dev/sda)
    disk_in_use() { return 1; }
    disk_size_bytes() { echo ""; }
    network_available() { return 0; }
    run validate_install_targets
    [ "$status" -eq 1 ]
}

@test "validate_install_targets errors when the network is unreachable" {
    SELECTED_DISKS=(/dev/sda)
    disk_in_use() { return 1; }
    disk_size_bytes() { echo 500107862016; }
    network_available() { return 1; }
    run validate_install_targets
    [ "$status" -eq 1 ]
    [[ "$output" == *"network"* || "$output" == *"connectivity"* ]]
}

@test "validate_install_targets passes when disks idle, large enough, network up" {
    SELECTED_DISKS=(/dev/sda /dev/sdb)
    disk_in_use() { return 1; }
    disk_size_bytes() { echo 500107862016; }
    network_available() { return 0; }
    run validate_install_targets
    [ "$status" -eq 0 ]
}
