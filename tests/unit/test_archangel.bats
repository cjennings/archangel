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
