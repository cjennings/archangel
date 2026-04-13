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

#############################
# pacstrap_packages
#############################

@test "pacstrap_packages zfs includes zfs-dkms and zfs-utils" {
    run pacstrap_packages zfs
    [ "$status" -eq 0 ]
    [[ "$output" == *"zfs-dkms"* ]]
    [[ "$output" == *"zfs-utils"* ]]
}

@test "pacstrap_packages btrfs includes btrfs-progs, grub, grub-btrfs, snapper, snap-pac" {
    run pacstrap_packages btrfs
    [ "$status" -eq 0 ]
    [[ "$output" == *"btrfs-progs"* ]]
    [[ "$output" == *"grub"* ]]
    [[ "$output" == *"grub-btrfs"* ]]
    [[ "$output" == *"snapper"* ]]
    [[ "$output" == *"snap-pac"* ]]
}

@test "pacstrap_packages zfs excludes Btrfs-specific packages" {
    run pacstrap_packages zfs
    [ "$status" -eq 0 ]
    [[ "$output" != *"btrfs-progs"* ]]
    [[ "$output" != *"grub-btrfs"* ]]
    [[ "$output" != *"snapper"* ]]
}

@test "pacstrap_packages btrfs excludes ZFS-specific packages" {
    run pacstrap_packages btrfs
    [ "$status" -eq 0 ]
    [[ "$output" != *"zfs-dkms"* ]]
    [[ "$output" != *"zfs-utils"* ]]
}

@test "pacstrap_packages includes common packages for both filesystems" {
    for fs in zfs btrfs; do
        run pacstrap_packages "$fs"
        [ "$status" -eq 0 ]
        [[ "$output" == *"base"* ]]
        [[ "$output" == *"linux-lts"* ]]
        [[ "$output" == *"efibootmgr"* ]]
        [[ "$output" == *"networkmanager"* ]]
        [[ "$output" == *"openssh"* ]]
        [[ "$output" == *"inetutils"* ]]
    done
}

@test "pacstrap_packages unknown filesystem returns status 1" {
    run pacstrap_packages reiserfs
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "pacstrap_packages emits one package per line" {
    run pacstrap_packages zfs
    [ "$status" -eq 0 ]
    local expected_lines
    expected_lines=$(echo "$output" | wc -l)
    [ "$expected_lines" -ge 20 ]
}

#############################
# prompt_password
#############################

@test "prompt_password accepts matching value meeting min length" {
    prompt_password PASS "label" 4 < <(printf 'hello\nhello\n') >/dev/null
    [ "$PASS" = "hello" ]
}

@test "prompt_password enforces min length by looping until met" {
    prompt_password PASS "label" 4 < <(printf 'ab\nab\nlongenough\nlongenough\n') >/dev/null
    [ "$PASS" = "longenough" ]
}

@test "prompt_password retries on mismatch" {
    prompt_password PASS "label" 4 < <(printf 'aaaa\nbbbb\nfinal1234\nfinal1234\n') >/dev/null
    [ "$PASS" = "final1234" ]
}

@test "prompt_password with min_len=0 skips length check" {
    prompt_password PASS "label" 0 < <(printf 'x\nx\n') >/dev/null
    [ "$PASS" = "x" ]
}

@test "prompt_password accepts empty passphrase when min_len=0" {
    prompt_password PASS "label" 0 < <(printf '\n\n') >/dev/null
    [ -z "$PASS" ]
}
