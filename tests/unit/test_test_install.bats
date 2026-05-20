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
