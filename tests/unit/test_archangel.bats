#!/usr/bin/env bats
# Unit tests for the installer/archangel monolith.
#
# Coverage scope: gather_input() in unattended mode — the validation
# of required config values, defaulting of optional ones, and the
# filesystem-specific encryption checks. The interactive branch
# (everything reachable via `if [[ "$UNATTENDED" != true ]]`) is not
# unit-tested per the project's testing-strategy.org policy on
# fzf / arch-chroot / mkfs / cryptsetup wrappers.
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
# Required-field validation
#############################

@test "gather_input unattended errors when HOSTNAME is missing" {
    HOSTNAME=""
    TIMEZONE=UTC
    ROOT_PASSWORD=secret
    SELECTED_DISKS=(/dev/sda)
    NO_ENCRYPT=yes
    run gather_input
    [ "$status" -eq 1 ]
    [[ "$output" == *"HOSTNAME"* ]]
}

@test "gather_input unattended errors when TIMEZONE is missing" {
    HOSTNAME=h
    TIMEZONE=""
    ROOT_PASSWORD=secret
    SELECTED_DISKS=(/dev/sda)
    NO_ENCRYPT=yes
    run gather_input
    [ "$status" -eq 1 ]
    [[ "$output" == *"TIMEZONE"* ]]
}

@test "gather_input unattended errors when ROOT_PASSWORD is missing" {
    HOSTNAME=h
    TIMEZONE=UTC
    ROOT_PASSWORD=""
    SELECTED_DISKS=(/dev/sda)
    NO_ENCRYPT=yes
    run gather_input
    [ "$status" -eq 1 ]
    [[ "$output" == *"ROOT_PASSWORD"* ]]
}

@test "gather_input unattended errors when SELECTED_DISKS is empty" {
    HOSTNAME=h
    TIMEZONE=UTC
    ROOT_PASSWORD=secret
    SELECTED_DISKS=()
    NO_ENCRYPT=yes
    run gather_input
    [ "$status" -eq 1 ]
    [[ "$output" == *"DISKS"* ]]
}

#############################
# Optional-field defaults
#############################

@test "gather_input unattended defaults FILESYSTEM to zfs when empty" {
    HOSTNAME=h
    TIMEZONE=UTC
    ROOT_PASSWORD=x
    SELECTED_DISKS=(/dev/sda)
    FILESYSTEM=""
    NO_ENCRYPT=yes
    gather_input >/dev/null
    [ "$FILESYSTEM" = "zfs" ]
}

@test "gather_input unattended defaults LOCALE, KEYMAP, ENABLE_SSH when empty" {
    HOSTNAME=h
    TIMEZONE=UTC
    ROOT_PASSWORD=x
    SELECTED_DISKS=(/dev/sda)
    FILESYSTEM=zfs
    NO_ENCRYPT=yes
    LOCALE=""
    KEYMAP=""
    ENABLE_SSH=""
    gather_input >/dev/null
    [ "$LOCALE" = "en_US.UTF-8" ]
    [ "$KEYMAP" = "us" ]
    [ "$ENABLE_SSH" = "yes" ]
}

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

@test "gather_input unattended errors when FILESYSTEM is neither zfs nor btrfs" {
    HOSTNAME=h
    TIMEZONE=UTC
    ROOT_PASSWORD=x
    SELECTED_DISKS=(/dev/sda)
    FILESYSTEM=ext4
    NO_ENCRYPT=yes
    run gather_input
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid FILESYSTEM"* ]]
}

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
