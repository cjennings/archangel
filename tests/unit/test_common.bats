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

#############################
# install_dropin
#############################

setup_dropin_tmp() {
    DROPIN_ROOT=$(mktemp -d)
}

teardown_dropin_tmp() {
    [ -n "${DROPIN_ROOT:-}" ] && rm -rf "$DROPIN_ROOT"
}

@test "install_dropin writes conf file at expected path" {
    setup_dropin_tmp
    install_dropin foo bar "$DROPIN_ROOT" <<< "[Service]"
    [ -f "$DROPIN_ROOT/etc/systemd/system/foo.service.d/bar.conf" ]
    teardown_dropin_tmp
}

@test "install_dropin writes stdin content verbatim" {
    setup_dropin_tmp
    install_dropin foo bar "$DROPIN_ROOT" <<< "[Service]
PrivateTmp=yes"
    run cat "$DROPIN_ROOT/etc/systemd/system/foo.service.d/bar.conf"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[Service]"* ]]
    [[ "$output" == *"PrivateTmp=yes"* ]]
    teardown_dropin_tmp
}

@test "install_dropin creates dropin dir with 755 perms" {
    setup_dropin_tmp
    install_dropin foo bar "$DROPIN_ROOT" <<< "x"
    local perms
    perms=$(stat -c '%a' "$DROPIN_ROOT/etc/systemd/system/foo.service.d")
    [ "$perms" = "755" ]
    teardown_dropin_tmp
}

@test "install_dropin is idempotent — second call overwrites content" {
    setup_dropin_tmp
    install_dropin foo bar "$DROPIN_ROOT" <<< "first"
    install_dropin foo bar "$DROPIN_ROOT" <<< "second"
    run cat "$DROPIN_ROOT/etc/systemd/system/foo.service.d/bar.conf"
    [ "$output" = "second" ]
    teardown_dropin_tmp
}

@test "install_dropin accepts empty content" {
    setup_dropin_tmp
    install_dropin foo bar "$DROPIN_ROOT" < /dev/null
    [ -f "$DROPIN_ROOT/etc/systemd/system/foo.service.d/bar.conf" ]
    [ ! -s "$DROPIN_ROOT/etc/systemd/system/foo.service.d/bar.conf" ]
    teardown_dropin_tmp
}

@test "install_dropin preserves special characters in content" {
    setup_dropin_tmp
    install_dropin foo bar "$DROPIN_ROOT" <<< '# comment with $var and `backtick`
[Service]
Environment="FOO=bar baz"'
    run cat "$DROPIN_ROOT/etc/systemd/system/foo.service.d/bar.conf"
    [[ "$output" == *'$var'* ]]
    [[ "$output" == *'`backtick`'* ]]
    [[ "$output" == *'"FOO=bar baz"'* ]]
    teardown_dropin_tmp
}

#############################
# parse_efibootmgr_entry
#############################

@test "parse_efibootmgr_entry returns boot number for matching label" {
    local sample="BootCurrent: 0001
Boot0000* Windows Boot Manager
Boot0001* ZFSBootMenu
Boot0002* PXE Boot"
    run parse_efibootmgr_entry "ZFSBootMenu" <<< "$sample"
    [ "$status" -eq 0 ]
    [ "$output" = "0001" ]
}

@test "parse_efibootmgr_entry returns first match when multiple labels match" {
    local sample="Boot0001* ZFSBootMenu
Boot0002* ZFSBootMenu-disk2"
    run parse_efibootmgr_entry "ZFSBootMenu" <<< "$sample"
    [ "$status" -eq 0 ]
    [ "$output" = "0001" ]
}

@test "parse_efibootmgr_entry handles hex characters in boot number" {
    local sample="Boot00FE* ZFSBootMenu"
    run parse_efibootmgr_entry "ZFSBootMenu" <<< "$sample"
    [ "$status" -eq 0 ]
    [ "$output" = "00FE" ]
}

@test "parse_efibootmgr_entry returns 1 with empty output when label absent" {
    local sample="Boot0001* Windows Boot Manager"
    run parse_efibootmgr_entry "ZFSBootMenu" <<< "$sample"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "parse_efibootmgr_entry returns 1 with empty output for empty input" {
    run parse_efibootmgr_entry "ZFSBootMenu" < /dev/null
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "parse_efibootmgr_entry returns 1 for empty label without false-matching BootCurrent" {
    local sample="BootCurrent: 0001
Boot0001* ZFSBootMenu"
    run parse_efibootmgr_entry "" <<< "$sample"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

#############################
# parse_efibootmgr_bootorder
#############################

@test "parse_efibootmgr_bootorder extracts comma-separated boot numbers" {
    local sample="BootCurrent: 0001
BootOrder: 0001,0002,0003
Boot0001* ZFSBootMenu"
    run parse_efibootmgr_bootorder <<< "$sample"
    [ "$status" -eq 0 ]
    [ "$output" = "0001,0002,0003" ]
}

@test "parse_efibootmgr_bootorder strips whitespace from boot order" {
    local sample="BootOrder: 0001, 0002 , 0003"
    run parse_efibootmgr_bootorder <<< "$sample"
    [ "$status" -eq 0 ]
    [ "$output" = "0001,0002,0003" ]
}

@test "parse_efibootmgr_bootorder returns 1 when BootOrder line absent" {
    local sample="BootCurrent: 0001
Boot0001* ZFSBootMenu"
    run parse_efibootmgr_bootorder <<< "$sample"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

#############################
# Path constants
#############################

@test "EFI_DIR is defined and equals /mnt/efi" {
    [ "$EFI_DIR" = "/mnt/efi" ]
}

#############################
# enable_sshd_root_login
#############################
# enable_sshd_root_login takes an sshd_config path and ensures the
# file ends up with `PermitRootLogin yes`. It must error loudly if
# neither the commented (#PermitRootLogin) nor uncommented
# (PermitRootLogin) form is present, since silently appending would
# mask a corrupted starting file.

@test "enable_sshd_root_login uncomments stock Arch sshd_config line" {
    local f
    f=$(mktemp)
    printf '%s\n' '#PermitRootLogin prohibit-password' > "$f"

    enable_sshd_root_login "$f"

    grep -q '^PermitRootLogin yes$' "$f"
    rm -f "$f"
}

@test "enable_sshd_root_login flips PermitRootLogin no to yes" {
    local f
    f=$(mktemp)
    printf '%s\n' 'PermitRootLogin no' > "$f"

    enable_sshd_root_login "$f"

    grep -q '^PermitRootLogin yes$' "$f"
    ! grep -q '^PermitRootLogin no$' "$f"
    rm -f "$f"
}

@test "enable_sshd_root_login is idempotent on PermitRootLogin yes" {
    local f
    f=$(mktemp)
    printf '%s\n' 'PermitRootLogin yes' > "$f"

    enable_sshd_root_login "$f"

    [ "$(grep -c '^PermitRootLogin yes$' "$f")" -eq 1 ]
    rm -f "$f"
}

@test "enable_sshd_root_login replaces all matching lines (mixed commented + uncommented)" {
    local f
    f=$(mktemp)
    printf '%s\n' \
        '#PermitRootLogin prohibit-password' \
        'PermitRootLogin no' \
        'OtherOption value' \
        '#PermitRootLogin without-password' > "$f"

    enable_sshd_root_login "$f"

    [ "$(grep -c '^PermitRootLogin yes$' "$f")" -eq 3 ]
    ! grep -q '^PermitRootLogin no$' "$f"
    grep -q '^OtherOption value$' "$f"
    rm -f "$f"
}

@test "enable_sshd_root_login errors when no PermitRootLogin line is present" {
    local f
    f=$(mktemp)
    printf '%s\n' 'OnlyOtherOptions yes' > "$f"

    error() { echo "ERROR: $*" >&2; return 1; }
    run enable_sshd_root_login "$f"
    [ "$status" -ne 0 ]
    [[ "$output" == *"PermitRootLogin"* ]]
    ! grep -q 'PermitRootLogin' "$f"
    rm -f "$f"
}
