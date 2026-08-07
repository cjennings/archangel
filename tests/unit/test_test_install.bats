#!/usr/bin/env bats
# Unit tests for scripts/test-install.sh
#
# Coverage scope: pure-logic helpers. The VM lifecycle (start_vm,
# run_install, verify_install, run_test) shells out to qemu / ssh /
# archangel and is exercised by the integration run itself, not bats.
#
# Sourcing test-install.sh relies on the source-guard at the bottom of
# the script: when sourced, function definitions load but main is not
# called.

setup() {
    # shellcheck disable=SC1091
    source "${BATS_TEST_DIRNAME}/../../scripts/test-install.sh"
}

#############################
# is_transient_install_failure
#############################

# Normal: a flaky-mirror failure (pacstrap marker + download error) retries.
@test "is_transient_install_failure matches a mirror download flake" {
    local log="==> Installing base system
error: failed retrieving file 'core.db' from mirror.example.org : Operation too slow
error: failed to synchronize all databases
==> ERROR: Failed to install packages to new root"
    run is_transient_install_failure "$log"
    [ "$status" -eq 0 ]
}

@test "is_transient_install_failure matches a name-resolution flake" {
    local log="error: could not resolve host: mirror.archlinux.org
==> ERROR: Failed to install packages to new root"
    run is_transient_install_failure "$log"
    [ "$status" -eq 0 ]
}

@test "is_transient_install_failure matches a connection timeout" {
    local log="error: failed retrieving file: Connection timed out
==> ERROR: Failed to install packages to new root"
    run is_transient_install_failure "$log"
    [ "$status" -eq 0 ]
}

# Error/deterministic: a real regression must NOT retry.
@test "is_transient_install_failure does not match a missing-package failure" {
    local log="error: target not found: bogus-package
==> ERROR: Failed to install packages to new root"
    run is_transient_install_failure "$log"
    [ "$status" -ne 0 ]
}

@test "is_transient_install_failure does not match a network error without the pacstrap marker" {
    # A transient blip somewhere other than base install (e.g. a later
    # pacman step) should not be treated as a pacstrap flake.
    local log="error: failed retrieving file 'extra.db' : Connection timed out
==> Configuring system"
    run is_transient_install_failure "$log"
    [ "$status" -ne 0 ]
}

@test "is_transient_install_failure does not match a clean log" {
    local log="==> Installing base system
info: Base system installed.
==> Installation complete"
    run is_transient_install_failure "$log"
    [ "$status" -ne 0 ]
}

# Boundary: empty input must not match (a timeout can leave an empty log).
@test "is_transient_install_failure does not match empty input" {
    run is_transient_install_failure ""
    [ "$status" -ne 0 ]
}

# Boundary: matching is case-insensitive on the transient indicator.
@test "is_transient_install_failure matches indicator regardless of case" {
    local log="ERROR: Failed Retrieving File from mirror : CONNECTION REFUSED
==> ERROR: Failed to install packages to new root"
    run is_transient_install_failure "$log"
    [ "$status" -eq 0 ]
}

#############################
# char_to_qemu_key
#############################

# Normal: alphanumerics map to themselves; uppercase gains a shift- prefix.
@test "char_to_qemu_key passes lowercase letters through unchanged" {
    [ "$(char_to_qemu_key a)" = "a" ]
    [ "$(char_to_qemu_key z)" = "z" ]
}

@test "char_to_qemu_key prefixes uppercase letters with shift-" {
    [ "$(char_to_qemu_key A)" = "shift-a" ]
    [ "$(char_to_qemu_key Z)" = "shift-z" ]
}

@test "char_to_qemu_key passes digits through unchanged" {
    [ "$(char_to_qemu_key 0)" = "0" ]
    [ "$(char_to_qemu_key 9)" = "9" ]
}

# Boundary: every special character in the mapping table.
@test "char_to_qemu_key maps each special character to its QEMU name" {
    while IFS='|' read -r ch want; do
        run char_to_qemu_key "$ch"
        [ "$status" -eq 0 ]
        [ "$output" = "$want" ] || {
            echo "char '$ch' => '$output', want '$want'"
            false
        }
    done <<'EOF'
 |spc
-|minus
=|equal
.|dot
,|comma
/|slash
\|backslash
;|semicolon
'|apostrophe
[|bracket_left
]|bracket_right
!|shift-1
@|shift-2
#|shift-3
$|shift-4
EOF
}

# Error/passthrough: an unmapped character comes back verbatim.
@test "char_to_qemu_key passes unmapped characters through unchanged" {
    [ "$(char_to_qemu_key '%')" = "%" ]
    [ "$(char_to_qemu_key '*')" = "*" ]
}

@test "char_to_qemu_key returns empty for empty input" {
    run char_to_qemu_key ""
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

#############################
# get_disk_count
#############################

@test "get_disk_count returns 1 for a single-disk config" {
    local cfg="$BATS_TEST_TMPDIR/single.conf"
    printf 'DISKS=/dev/vda\n' > "$cfg"
    run get_disk_count "$cfg"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

@test "get_disk_count returns 2 for a two-disk config" {
    local cfg="$BATS_TEST_TMPDIR/mirror.conf"
    printf 'DISKS=/dev/vda,/dev/vdb\n' > "$cfg"
    run get_disk_count "$cfg"
    [ "$status" -eq 0 ]
    [ "$output" = "2" ]
}

@test "get_disk_count returns 3 for a three-disk config" {
    local cfg="$BATS_TEST_TMPDIR/raidz1.conf"
    printf 'DISKS=/dev/vda,/dev/vdb,/dev/vdc\n' > "$cfg"
    run get_disk_count "$cfg"
    [ "$status" -eq 0 ]
    [ "$output" = "3" ]
}

# Boundary: the ^DISKS= anchor must not match a decoy line.
@test "get_disk_count ignores a non-anchored decoy line" {
    local cfg="$BATS_TEST_TMPDIR/decoy.conf"
    printf 'ROOT_DISKS=/dev/sda,/dev/sdb,/dev/sdc\nDISKS=/dev/vda\n' > "$cfg"
    run get_disk_count "$cfg"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

# Error/characterization: a config with no DISKS= line counts as 0.
@test "get_disk_count returns 0 when no DISKS line is present" {
    local cfg="$BATS_TEST_TMPDIR/nodisks.conf"
    printf 'HOSTNAME=test\nFILESYSTEM=zfs\n' > "$cfg"
    run get_disk_count "$cfg"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

#############################
# get_disk_args
#############################

@test "get_disk_args builds one -drive block for a single disk" {
    run get_disk_args 1 single
    [ "$status" -eq 0 ]
    [ "$(grep -o -- '-drive' <<<"$output" | wc -l)" -eq 1 ]
    [[ "$output" == *"test-single-disk1.qcow2"* ]]
    [[ "$output" == *"format=qcow2"* ]]
    [[ "$output" == *"if=virtio"* ]]
}

@test "get_disk_args builds one -drive block per disk for multiple disks" {
    run get_disk_args 2 mirror
    [ "$status" -eq 0 ]
    [ "$(grep -o -- '-drive' <<<"$output" | wc -l)" -eq 2 ]
    [[ "$output" == *"test-mirror-disk1.qcow2"* ]]
    [[ "$output" == *"test-mirror-disk2.qcow2"* ]]
}

# Boundary: zero disks yields no arguments.
@test "get_disk_args returns empty for a zero count" {
    run get_disk_args 0 empty
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

#############################
# SSH_PORT override
#############################
# The hostfwd port must be overridable so a test VM can coexist with
# another VM already holding 2222 (re-sourcing applies the top-level
# assignment with the env value in scope).

@test "SSH_PORT honors a preset value" {
    SSH_PORT=3333
    # shellcheck disable=SC1091
    source "${BATS_TEST_DIRNAME}/../../scripts/test-install.sh"
    [ "$SSH_PORT" = "3333" ]
}

@test "SSH_PORT defaults to 2222 when unset" {
    unset SSH_PORT
    # shellcheck disable=SC1091
    source "${BATS_TEST_DIRNAME}/../../scripts/test-install.sh"
    [ "$SSH_PORT" = "2222" ]
}

#############################
# port_listening_in (pure half of the port-in-use guard)
#############################
# The live ss query lives in port_in_use; this pure predicate takes an
# `ss -tln` snapshot as a string so it's testable with fixtures.

@test "port_listening_in detects a port present in ss output" {
    run port_listening_in 2222 "LISTEN 0 4096 0.0.0.0:2222 0.0.0.0:*"
    [ "$status" -eq 0 ]
}

@test "port_listening_in returns 1 when the port is absent" {
    run port_listening_in 2222 "LISTEN 0 4096 0.0.0.0:22 0.0.0.0:*"
    [ "$status" -eq 1 ]
}

@test "port_listening_in does not match a port that is only a substring" {
    run port_listening_in 2222 "LISTEN 0 4096 0.0.0.0:12222 0.0.0.0:*"
    [ "$status" -eq 1 ]
}

@test "port_listening_in matches an IPv6 listener" {
    run port_listening_in 2222 "LISTEN 0 4096 [::]:2222 [::]:*"
    [ "$status" -eq 0 ]
}

@test "port_listening_in returns 1 on empty ss output" {
    run port_listening_in 2222 ""
    [ "$status" -eq 1 ]
}

#############################
# is_archzfs_cache_corruption
#############################
# Recognizes the stale-archzfs-in-pacoloco failure (not transient — a retry
# hits the same cached file), so the caller prints a cache-clear hint.

@test "is_archzfs_cache_corruption matches an archzfs checksum corruption" {
    local log="==> Installing base system
:: File /mnt/var/cache/pacman/pkg/zfs-utils-2.4.2-2-x86_64.pkg.tar.zst is corrupted (invalid or corrupted package (checksum)).
error: failed to commit transaction (invalid or corrupted package (checksum))
==> ERROR: Failed to install packages to new root"
    run is_archzfs_cache_corruption "$log"
    [ "$status" -eq 0 ]
}

@test "is_archzfs_cache_corruption ignores a transient mirror flake" {
    local log="error: failed retrieving file 'core.db' : Operation too slow
==> ERROR: Failed to install packages to new root"
    run is_archzfs_cache_corruption "$log"
    [ "$status" -eq 1 ]
}

@test "is_archzfs_cache_corruption ignores corruption of a non-archzfs package" {
    local log="==> ERROR: Failed to install packages to new root
:: File /mnt/var/cache/pacman/pkg/glibc-2.43-1-x86_64.pkg.tar.zst is corrupted (invalid or corrupted package (checksum))."
    run is_archzfs_cache_corruption "$log"
    [ "$status" -eq 1 ]
}

@test "is_archzfs_cache_corruption returns 1 on a clean log" {
    run is_archzfs_cache_corruption ""
    [ "$status" -eq 1 ]
}

#############################
# INSTALLED_PASSWORD scoping
#############################
# After the reboot step, run_test switches ssh_cmd over to the installed
# system's root password. That value must not outlive the test. When it leaks
# into the next scenario, ssh_cmd presents the installed password to the *live
# ISO* — whose password is different — so every SSH call fails instantly and
# the install dies with no output and no package requests.
#
# That is exactly what happened on 2026-08-01: the reset was a single `unset`
# on the success path, three failure paths returned early past it, and one
# flaky check cascaded into six silent ZFS install failures. The fix declares
# it `local` in run_test so bash clears it on every return path.

@test "ssh_cmd picks up a caller-scoped INSTALLED_PASSWORD" {
    # Proves local-instead-of-export still reaches ssh_cmd: bash's dynamic
    # scoping exposes a caller's local to the functions it calls.
    #
    # timeout is stubbed as a pass-through because the real one is an external
    # binary: it would exec the real sshpass and never see these stubs.
    timeout() { shift; "$@"; }
    sshpass() { echo "$2"; }
    ssh() { :; }
    caller_with_local() {
        local INSTALLED_PASSWORD="installed-secret"
        ssh_cmd true
    }
    run caller_with_local
    [[ "$output" == *"installed-secret"* ]]
}

@test "a caller-scoped INSTALLED_PASSWORD does not leak past a failed return" {
    timeout() { shift; "$@"; }
    sshpass() { echo "$2"; }
    ssh() { :; }
    SSH_PASSWORD="live-iso-password"
    failing_caller() {
        local INSTALLED_PASSWORD="installed-secret"
        return 1
    }
    failing_caller || true
    run ssh_cmd true
    [[ "$output" == *"live-iso-password"* ]]
    [[ "$output" != *"installed-secret"* ]]
}

@test "run_test declares INSTALLED_PASSWORD local and never exports it" {
    # Structural guard: run_test itself drives qemu and ssh, so this file
    # can't exercise it directly. An export here would silently restore the
    # cascade, so pin the shape that prevents it.
    local src="${BATS_TEST_DIRNAME}/../../scripts/test-install.sh"
    grep -qE '^[[:space:]]*local INSTALLED_PASSWORD=' "$src"
    ! grep -qE '^[[:space:]]*export INSTALLED_PASSWORD' "$src"
}

#############################
# config_encrypt_flag
#############################
# Decides which passphrase-entry path a reboot needs. It's the one pure piece
# of the boot-from-disk sequence, which is otherwise qemu orchestration, so it
# carries the precedence rules the rest of that sequence depends on.

mkcfg() {
    local f
    f=$(mktemp)
    printf '%s\n' "$@" > "$f"
    echo "$f"
}

@test "config_encrypt_flag reports luks for a LUKS config" {
    local f; f=$(mkcfg 'LUKS_PASSPHRASE=secret' 'DISKS=/dev/vda')
    [ "$(config_encrypt_flag "$f")" = "luks" ]
    rm -f "$f"
}

@test "config_encrypt_flag reports zfs for a ZFS-passphrase config" {
    local f; f=$(mkcfg 'ZFS_PASSPHRASE=secret' 'DISKS=/dev/vda')
    [ "$(config_encrypt_flag "$f")" = "zfs" ]
    rm -f "$f"
}

@test "config_encrypt_flag prefers luks when a config carries both" {
    # Preserves the precedence the inline block had: LUKS is checked first,
    # and a config with both is a misconfiguration rather than a real mode.
    local f; f=$(mkcfg 'LUKS_PASSPHRASE=a' 'ZFS_PASSPHRASE=b')
    [ "$(config_encrypt_flag "$f")" = "luks" ]
    rm -f "$f"
}

@test "config_encrypt_flag reports nothing when NO_ENCRYPT overrides a passphrase" {
    # The test configs set a passphrase *and* NO_ENCRYPT=yes; sending a
    # passphrase to an unencrypted boot would type it at a login prompt.
    #
    # Asserted through `run` on purpose. A bare [ -z "$(...)" ] also passes
    # when the function doesn't exist, so it can't fail for the reason the
    # test exists — checking status too makes absence register as 127.
    local f; f=$(mkcfg 'ZFS_PASSPHRASE=testpass' 'NO_ENCRYPT=yes')
    run config_encrypt_flag "$f"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    rm -f "$f"
}

@test "config_encrypt_flag reports nothing for an unencrypted config" {
    local f; f=$(mkcfg 'DISKS=/dev/vda' 'HOSTNAME=x')
    run config_encrypt_flag "$f"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    rm -f "$f"
}

#############################
# ssh_cmd timeout bound
#############################
# ConnectTimeout bounds the connection, not execution. On 2026-08-03 a remote
# `zfs destroy` blocked behind an uninterruptible txg_quiesce with the
# connection healthy, and the suite sat dead for 40 minutes. A wedged guest
# should cost one scenario, not the run.

@test "ssh_cmd bounds the remote command with the default timeout" {
    timeout() { echo "bound=$1"; }
    run ssh_cmd true
    [[ "$output" == "bound=$SSH_CMD_TIMEOUT" ]]
}

@test "ssh_cmd honors a per-call timeout override" {
    # run_install's installer call legitimately runs for many minutes and
    # raises this; every other call keeps the short default.
    timeout() { echo "bound=$1"; }
    SSH_CMD_TIMEOUT=1800 run ssh_cmd true
    [[ "$output" == "bound=1800" ]]
}
