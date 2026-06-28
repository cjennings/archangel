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

@test "MNTPOINT is defined and equals /mnt" {
    [ "$MNTPOINT" = "/mnt" ]
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

#############################
# prepend_grub_cmdline_linux
#############################
# prepend_grub_cmdline_linux prepends a string to GRUB_CMDLINE_LINUX
# in /etc/default/grub. Errors loudly if the line isn't present, since
# silently doing nothing would leave the kernel without the parameter
# (e.g. cryptdevice= for LUKS — a missing prefix means the system
# can't unlock the root partition at boot).

@test "prepend_grub_cmdline_linux prepends to an empty GRUB_CMDLINE_LINUX" {
    local f
    f=$(mktemp)
    printf '%s\n' 'GRUB_CMDLINE_LINUX=""' > "$f"

    prepend_grub_cmdline_linux "cryptdevice=UUID=abc123:root " "$f"

    grep -qF 'GRUB_CMDLINE_LINUX="cryptdevice=UUID=abc123:root "' "$f"
    rm -f "$f"
}

@test "prepend_grub_cmdline_linux preserves text already inside GRUB_CMDLINE_LINUX" {
    local f
    f=$(mktemp)
    printf '%s\n' 'GRUB_CMDLINE_LINUX="quiet splash"' > "$f"

    prepend_grub_cmdline_linux "cryptdevice=UUID=abc:root " "$f"

    grep -qF 'GRUB_CMDLINE_LINUX="cryptdevice=UUID=abc:root quiet splash"' "$f"
    rm -f "$f"
}

@test "prepend_grub_cmdline_linux preserves other lines in /etc/default/grub" {
    local f
    f=$(mktemp)
    printf '%s\n' \
        'GRUB_DEFAULT=0' \
        'GRUB_TIMEOUT=5' \
        'GRUB_CMDLINE_LINUX=""' \
        'GRUB_DISABLE_RECOVERY=true' > "$f"

    prepend_grub_cmdline_linux "cryptdevice=UUID=abc:root " "$f"

    grep -qF 'GRUB_DEFAULT=0' "$f"
    grep -qF 'GRUB_TIMEOUT=5' "$f"
    grep -qF 'GRUB_CMDLINE_LINUX="cryptdevice=UUID=abc:root "' "$f"
    grep -qF 'GRUB_DISABLE_RECOVERY=true' "$f"
    rm -f "$f"
}

@test "prepend_grub_cmdline_linux errors when GRUB_CMDLINE_LINUX line is absent" {
    local f
    f=$(mktemp)
    printf '%s\n' \
        'GRUB_DEFAULT=0' \
        'GRUB_TIMEOUT=5' > "$f"

    error() { echo "ERROR: $*" >&2; return 1; }
    run prepend_grub_cmdline_linux "cryptdevice=UUID=abc:root " "$f"
    [ "$status" -ne 0 ]
    [[ "$output" == *"GRUB_CMDLINE_LINUX"* ]]
    ! grep -q 'cryptdevice' "$f"
    rm -f "$f"
}

#############################
# ensure_initramfs_files
#############################
# ensure_initramfs_files sets mkinitcpio.conf's FILES= line to the
# given value, replacing an existing line or appending one if absent.
# Self-healing rather than error-on-miss: FILES= is optional, so a
# missing line means "no extra files," not a broken config.

@test "ensure_initramfs_files replaces an empty FILES= line" {
    local f
    f=$(mktemp)
    printf '%s\n' 'FILES=()' > "$f"

    ensure_initramfs_files "/etc/luks.key" "$f"

    grep -qF 'FILES=(/etc/luks.key)' "$f"
    rm -f "$f"
}

@test "ensure_initramfs_files replaces a FILES= line that lists a different value" {
    local f
    f=$(mktemp)
    printf '%s\n' 'FILES=(/etc/old-key)' > "$f"

    ensure_initramfs_files "/etc/luks.key" "$f"

    grep -qF 'FILES=(/etc/luks.key)' "$f"
    ! grep -qF '/etc/old-key' "$f"
    rm -f "$f"
}

@test "ensure_initramfs_files appends FILES= when the line is absent" {
    local f
    f=$(mktemp)
    printf '%s\n' \
        'MODULES=()' \
        'BINARIES=()' \
        'HOOKS=(base udev)' > "$f"

    ensure_initramfs_files "/etc/luks.key" "$f"

    grep -qF 'FILES=(/etc/luks.key)' "$f"
    grep -qF 'MODULES=()' "$f"
    grep -qF 'HOOKS=(base udev)' "$f"
    rm -f "$f"
}

#############################
# required_commands
#############################

@test "required_commands zfs includes zpool and zfs" {
    run required_commands zfs
    [ "$status" -eq 0 ]
    [[ "$output" == *"zpool"* ]]
    [[ "$output" == *"zfs"* ]]
}

@test "required_commands btrfs includes mkfs.btrfs and grub-install" {
    run required_commands btrfs
    [ "$status" -eq 0 ]
    [[ "$output" == *"mkfs.btrfs"* ]]
    [[ "$output" == *"grub-install"* ]]
}

@test "required_commands zfs excludes Btrfs-specific commands" {
    run required_commands zfs
    [ "$status" -eq 0 ]
    [[ "$output" != *"mkfs.btrfs"* ]]
    [[ "$output" != *"grub-install"* ]]
}

@test "required_commands btrfs excludes the zpool command" {
    run required_commands btrfs
    [ "$status" -eq 0 ]
    [[ "$output" != *"zpool"* ]]
}

@test "required_commands includes partitioning + pacstrap commands for both filesystems" {
    for fs in zfs btrfs; do
        run required_commands "$fs"
        [ "$status" -eq 0 ]
        [[ "$output" == *"sgdisk"* ]]
        [[ "$output" == *"wipefs"* ]]
        [[ "$output" == *"partprobe"* ]]
        [[ "$output" == *"mkfs.fat"* ]]
        [[ "$output" == *"pacstrap"* ]]
    done
}

@test "required_commands unknown filesystem returns 1" {
    run required_commands ext4
    [ "$status" -eq 1 ]
}

#############################
# append_aur_repo
#############################
# Appends an [aur] stanza to a pacman.conf for the baked local repo, the
# same shape as the [archzfs] handling. Idempotent: a second call is a
# no-op so re-running the installer doesn't stack duplicate stanzas.

@test "append_aur_repo adds the stanza with the given Server" {
    local f
    f=$(mktemp)
    printf '%s\n' '[options]' '[core]' > "$f"
    append_aur_repo "$f" "file:///usr/share/aur-packages"
    grep -q '^\[aur\]$' "$f"
    grep -q '^SigLevel = Optional TrustAll$' "$f"
    grep -q '^Server = file:///usr/share/aur-packages$' "$f"
    rm -f "$f"
}

@test "append_aur_repo preserves existing repos" {
    local f
    f=$(mktemp)
    printf '%s\n' '[core]' 'Include = /etc/pacman.d/mirrorlist' > "$f"
    append_aur_repo "$f" "file:///usr/share/aur-packages"
    grep -q '^\[core\]$' "$f"
    grep -q '^Include = /etc/pacman.d/mirrorlist$' "$f"
    rm -f "$f"
}

@test "append_aur_repo is idempotent — no duplicate [aur] on a second call" {
    local f
    f=$(mktemp)
    printf '%s\n' '[core]' > "$f"
    append_aur_repo "$f" "file:///usr/share/aur-packages"
    append_aur_repo "$f" "file:///usr/share/aur-packages"
    [ "$(grep -c '^\[aur\]$' "$f")" -eq 1 ]
    rm -f "$f"
}

#############################
# strip_repo_stanza
#############################
# Removes a named repo stanza (header + its config lines up to the next
# section) so the installed target's pacman.conf never references the baked
# [aur] repo path, which won't exist on the target.

@test "strip_repo_stanza removes the [aur] stanza and its config lines" {
    local f
    f=$(mktemp)
    printf '%s\n' \
        '[core]' 'Include = /etc/pacman.d/mirrorlist' \
        '' '[aur]' 'SigLevel = Optional TrustAll' \
        'Server = file:///usr/share/aur-packages' \
        '' '[extra]' 'Include = /etc/pacman.d/mirrorlist' > "$f"
    strip_repo_stanza aur "$f"
    ! grep -q '^\[aur\]$' "$f"
    ! grep -q 'aur-packages' "$f"
    rm -f "$f"
}

@test "strip_repo_stanza preserves sections before and after [aur]" {
    local f
    f=$(mktemp)
    printf '%s\n' \
        '[core]' 'Include = /etc/pacman.d/mirrorlist' \
        '[aur]' 'Server = file:///usr/share/aur-packages' \
        '[extra]' 'Include = /etc/pacman.d/mirrorlist' > "$f"
    strip_repo_stanza aur "$f"
    grep -q '^\[core\]$' "$f"
    grep -q '^\[extra\]$' "$f"
    rm -f "$f"
}

@test "strip_repo_stanza handles a stanza at end of file" {
    local f
    f=$(mktemp)
    printf '%s\n' \
        '[core]' 'Include = /etc/pacman.d/mirrorlist' \
        '[aur]' 'SigLevel = Optional TrustAll' \
        'Server = file:///usr/share/aur-packages' > "$f"
    strip_repo_stanza aur "$f"
    grep -q '^\[core\]$' "$f"
    ! grep -q '^\[aur\]$' "$f"
    ! grep -q 'aur-packages' "$f"
    rm -f "$f"
}

@test "strip_repo_stanza is a no-op when the stanza is absent" {
    local f before after
    f=$(mktemp)
    printf '%s\n' '[core]' '[extra]' > "$f"
    before=$(cat "$f")
    strip_repo_stanza aur "$f"
    after=$(cat "$f")
    [ "$before" = "$after" ]
    rm -f "$f"
}

@test "strip_repo_stanza preserves the target file mode (no 0600 clobber)" {
    local f
    f=$(mktemp)
    printf '%s\n' '[core]' '[aur]' 'Server = file:///usr/share/aur-packages' '[extra]' > "$f"
    chmod 644 "$f"
    strip_repo_stanza aur "$f"
    [ "$(stat -c %a "$f")" = "644" ]
    rm -f "$f"
}

@test "strip_repo_stanza preserves a non-default file mode" {
    local f
    f=$(mktemp)
    printf '%s\n' '[core]' '[aur]' 'Server = x' '[extra]' > "$f"
    chmod 640 "$f"
    strip_repo_stanza aur "$f"
    [ "$(stat -c %a "$f")" = "640" ]
    rm -f "$f"
}

#############################
# aur_repo_available
#############################

@test "aur_repo_available is true when aur.db is present" {
    local d
    d=$(mktemp -d)
    touch "$d/aur.db"
    run aur_repo_available "$d"
    [ "$status" -eq 0 ]
    rm -rf "$d"
}

@test "aur_repo_available is true when only the aur.db.tar.gz is present" {
    local d
    d=$(mktemp -d)
    touch "$d/aur.db.tar.gz"
    run aur_repo_available "$d"
    [ "$status" -eq 0 ]
    rm -rf "$d"
}

@test "aur_repo_available is false when the repo db is missing" {
    local d
    d=$(mktemp -d)
    run aur_repo_available "$d"
    [ "$status" -ne 0 ]
    rm -rf "$d"
}

#############################
# aur_manifest_names
#############################

@test "aur_manifest_names prints package names, skipping the header" {
    local f
    f=$(mktemp)
    printf 'name\tpkgbase\tfilename\n' > "$f"
    printf 'yay\tyay\tyay-12.0-1-x86_64.pkg.tar.zst\n' >> "$f"
    printf 'zrepl\tzrepl\tzrepl-0.6-1-x86_64.pkg.tar.zst\n' >> "$f"
    run aur_manifest_names "$f"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | wc -l)" -eq 2 ]
    [[ "$output" == *"yay"* ]]
    [[ "$output" == *"zrepl"* ]]
    [[ "$output" != *"name"* ]]
    rm -f "$f"
}

@test "aur_manifest_names emits nothing for a missing manifest" {
    run aur_manifest_names /nonexistent/manifest.tsv
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

#############################
# aur_zfs_only_packages / filter_aur_for_fs
#############################

@test "aur_zfs_only_packages lists zfs-auto-snapshot and zrepl" {
    run aur_zfs_only_packages
    [ "$status" -eq 0 ]
    [[ "$output" == *"zfs-auto-snapshot"* ]]
    [[ "$output" == *"zrepl"* ]]
}

@test "filter_aur_for_fs zfs keeps every package including zfs-only tooling" {
    run filter_aur_for_fs zfs downgrade yay zrepl zfs-auto-snapshot topgrade
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 5 ]
    [[ "$output" == *"zfs-auto-snapshot"* ]]
    [[ "$output" == *"zrepl"* ]]
    [[ "$output" == *"yay"* ]]
}

@test "filter_aur_for_fs btrfs drops zfs-only tooling, keeps the rest" {
    run filter_aur_for_fs btrfs downgrade yay zrepl zfs-auto-snapshot topgrade
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 3 ]
    [[ "$output" != *"zfs-auto-snapshot"* ]]
    [[ "$output" != *"zrepl"* ]]
    [[ "$output" == *"downgrade"* ]]
    [[ "$output" == *"yay"* ]]
    [[ "$output" == *"topgrade"* ]]
}

@test "filter_aur_for_fs btrfs with only zfs-only tooling prints nothing" {
    run filter_aur_for_fs btrfs zfs-auto-snapshot zrepl
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "filter_aur_for_fs with no package arguments prints nothing" {
    run filter_aur_for_fs btrfs
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "filter_aur_for_fs preserves input order" {
    run filter_aur_for_fs zfs yay downgrade topgrade
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "yay" ]
    [ "${lines[2]}" = "topgrade" ]
}
