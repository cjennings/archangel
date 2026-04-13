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
