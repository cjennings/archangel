#!/usr/bin/env bats
# Unit tests for installer/lib/common.sh

setup() {
    # shellcheck disable=SC1091
    source "${BATS_TEST_DIRNAME}/../../installer/lib/common.sh"
}

@test "command_exists returns 0 for an existing command" {
    run command_exists bash
    [ "$status" -eq 0 ]
}

@test "command_exists returns 1 for a missing command" {
    run command_exists this_does_not_exist_xyz_42
    [ "$status" -eq 1 ]
}

@test "require_command succeeds for an existing command" {
    run require_command bash
    [ "$status" -eq 0 ]
}

@test "require_command fails and reports missing command" {
    run require_command this_does_not_exist_xyz_42
    [ "$status" -eq 1 ]
    [[ "$output" == *"Required command not found"* ]]
    [[ "$output" == *"this_does_not_exist_xyz_42"* ]]
}

@test "enable_color populates color variables" {
    [ -z "$RED" ]
    [ -z "$GREEN" ]
    [ -z "$NC" ]
    enable_color
    [ -n "$RED" ]
    [ -n "$GREEN" ]
    [ -n "$YELLOW" ]
    [ -n "$BLUE" ]
    [ -n "$BOLD" ]
    [ -n "$NC" ]
}

@test "info prints [INFO] prefix and message" {
    run info "hello world"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[INFO]"* ]]
    [[ "$output" == *"hello world"* ]]
}

@test "warn prints [WARN] prefix and message" {
    run warn "heads up"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[WARN]"* ]]
    [[ "$output" == *"heads up"* ]]
}

@test "error prints [ERROR] and exits with status 1" {
    run error "something broke"
    [ "$status" -eq 1 ]
    [[ "$output" == *"[ERROR]"* ]]
    [[ "$output" == *"something broke"* ]]
}

@test "require_root fails for non-root user" {
    [ "$EUID" -ne 0 ] || skip "running as root"
    run require_root
    [ "$status" -eq 1 ]
    [[ "$output" == *"must be run as root"* ]]
}

@test "log writes timestamped line when LOG_FILE set" {
    local tmp
    tmp=$(mktemp)
    LOG_FILE="$tmp" log "test entry"
    run cat "$tmp"
    [ "$status" -eq 0 ]
    [[ "$output" == *"test entry"* ]]
    [[ "$output" =~ \[[0-9]{4}-[0-9]{2}-[0-9]{2} ]]
    rm -f "$tmp"
}

@test "log is a no-op when LOG_FILE unset" {
    unset LOG_FILE
    run log "should not crash"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
