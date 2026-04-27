#!/usr/bin/env bats
# Unit tests for installer/lib/config.sh

setup() {
    # shellcheck disable=SC1091
    source "${BATS_TEST_DIRNAME}/../../installer/lib/common.sh"
    # shellcheck disable=SC1091
    source "${BATS_TEST_DIRNAME}/../../installer/lib/config.sh"
}

@test "parse_args stores --config-file path" {
    parse_args --config-file /tmp/foo.conf
    [ "$CONFIG_FILE" = "/tmp/foo.conf" ]
}

@test "parse_args rejects --config-file with no argument" {
    run parse_args --config-file
    [ "$status" -eq 1 ]
    [[ "$output" == *"requires a path"* ]]
}

@test "parse_args rejects --config-file when value looks like a flag" {
    run parse_args --config-file --help
    [ "$status" -eq 1 ]
    [[ "$output" == *"requires a path"* ]]
}

@test "parse_args --color enables color vars" {
    [ -z "$RED" ]
    parse_args --color
    [ -n "$RED" ]
}

@test "parse_args --help shows usage and exits 0" {
    run parse_args --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
    [[ "$output" == *"--config-file"* ]]
}

@test "parse_args rejects unknown option" {
    run parse_args --not-a-real-flag
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown option"* ]]
}

@test "load_config errors on missing file" {
    run load_config /nonexistent/path/archangel.conf
    [ "$status" -eq 1 ]
    [[ "$output" == *"Config file not found"* ]]
}

@test "load_config parses a minimal config and sets UNATTENDED" {
    local tmp
    tmp=$(mktemp)
    cat >"$tmp" <<'EOF'
HOSTNAME=testhost
TIMEZONE=UTC
DISKS=/dev/sda,/dev/sdb
ROOT_PASSWORD=secret
EOF
    load_config "$tmp"
    [ "$HOSTNAME" = "testhost" ]
    [ "$TIMEZONE" = "UTC" ]
    [ "$ROOT_PASSWORD" = "secret" ]
    [ "${SELECTED_DISKS[0]}" = "/dev/sda" ]
    [ "${SELECTED_DISKS[1]}" = "/dev/sdb" ]
    [ "$UNATTENDED" = "true" ]
    rm -f "$tmp"
}

@test "load_config parses a single-disk config into 1-element array" {
    local tmp
    tmp=$(mktemp)
    echo "DISKS=/dev/nvme0n1" >"$tmp"
    load_config "$tmp"
    [ "${#SELECTED_DISKS[@]}" -eq 1 ]
    [ "${SELECTED_DISKS[0]}" = "/dev/nvme0n1" ]
    rm -f "$tmp"
}

@test "validate_config fails and lists every missing required field" {
    HOSTNAME=""
    TIMEZONE=""
    SELECTED_DISKS=()
    ROOT_PASSWORD=""
    run validate_config
    [ "$status" -eq 1 ]
    [[ "$output" == *"HOSTNAME not set"* ]]
    [[ "$output" == *"TIMEZONE not set"* ]]
    [[ "$output" == *"No disks selected"* ]]
    [[ "$output" == *"ROOT_PASSWORD not set"* ]]
    [[ "$output" == *"4 error"* ]]
}

@test "validate_config rejects an invalid timezone" {
    HOSTNAME="h"
    TIMEZONE="Not/A_Real_Zone_xyz"
    SELECTED_DISKS=()
    ROOT_PASSWORD="x"
    run validate_config
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid timezone"* ]]
}

@test "check_config is a no-op when CONFIG_FILE is unset" {
    CONFIG_FILE=""
    run check_config
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "check_config loads the config file when CONFIG_FILE is set" {
    local tmp
    tmp=$(mktemp)
    cat >"$tmp" <<'EOF'
HOSTNAME=fromcheckconfig
TIMEZONE=UTC
EOF
    CONFIG_FILE="$tmp"
    check_config
    [ "$HOSTNAME" = "fromcheckconfig" ]
    [ "$TIMEZONE" = "UTC" ]
    [ "$UNATTENDED" = "true" ]
    rm -f "$tmp"
}

@test "validate_config flags an existing-but-not-block path in SELECTED_DISKS" {
    HOSTNAME=h
    TIMEZONE=UTC
    ROOT_PASSWORD=x
    SELECTED_DISKS=(/dev/null)
    run validate_config
    [ "$status" -eq 1 ]
    [[ "$output" == *"Disk not found: /dev/null"* ]]
}

@test "validate_config flags a missing path in SELECTED_DISKS" {
    HOSTNAME=h
    TIMEZONE=UTC
    ROOT_PASSWORD=x
    SELECTED_DISKS=(/nonexistent/disk-xyz-42)
    run validate_config
    [ "$status" -eq 1 ]
    [[ "$output" == *"Disk not found"* ]]
}

@test "parse_args accepts --color and --config-file together (color first)" {
    parse_args --color --config-file /tmp/foo.conf
    [ "$CONFIG_FILE" = "/tmp/foo.conf" ]
    [ -n "$RED" ]
}

@test "parse_args accepts --config-file and --color together (config first)" {
    parse_args --config-file /tmp/foo.conf --color
    [ "$CONFIG_FILE" = "/tmp/foo.conf" ]
    [ -n "$RED" ]
}

#############################
# Default values sourced from config.sh
#############################
# config.sh is the single source of truth for installer defaults. The
# monolith no longer re-applies them in gather_input. These tests pin
# the values so a regression that drops a default surfaces here, not
# halfway through an unattended install.

@test "config.sh sets defaults for FILESYSTEM, LOCALE, KEYMAP, ENABLE_SSH, NO_ENCRYPT" {
    [ "$FILESYSTEM" = "zfs" ]
    [ "$LOCALE" = "en_US.UTF-8" ]
    [ "$KEYMAP" = "us" ]
    [ "$ENABLE_SSH" = "yes" ]
    [ "$NO_ENCRYPT" = "no" ]
}

#############################
# validate_filesystem
#############################
# Called from main() between check_config and gather_input. Catches a
# typo in FILESYSTEM= from a config file before the install starts.

@test "validate_filesystem accepts zfs" {
    FILESYSTEM=zfs
    run validate_filesystem
    [ "$status" -eq 0 ]
}

@test "validate_filesystem accepts btrfs" {
    FILESYSTEM=btrfs
    run validate_filesystem
    [ "$status" -eq 0 ]
}

@test "validate_filesystem rejects an unknown filesystem" {
    FILESYSTEM=ext4
    run validate_filesystem
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid FILESYSTEM"* ]]
    [[ "$output" == *"ext4"* ]]
}

@test "validate_filesystem rejects an empty FILESYSTEM" {
    FILESYSTEM=""
    run validate_filesystem
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid FILESYSTEM"* ]]
}
