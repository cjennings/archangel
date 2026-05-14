#!/usr/bin/env bats
# Unit tests for installer/zfssnapshot
#
# Coverage scope: pure-logic helpers and subcommand dispatch. The
# subcommand bodies that shell out to zfs / fzf / arch-chroot are VM-
# tested per testing-strategy.org.
#
# Sourcing zfssnapshot relies on the source-guard at the bottom of the
# script: when sourced, function definitions load but main is not
# called.

setup() {
    # shellcheck disable=SC1091
    source "${BATS_TEST_DIRNAME}/../../installer/zfssnapshot"
}

#############################
# sanitize_description
#############################

@test "sanitize_description lowercases mixed case" {
    [ "$(sanitize_description 'Before Upgrade')" = "before_upgrade" ]
}

@test "sanitize_description converts spaces to underscores" {
    [ "$(sanitize_description 'pre system update')" = "pre_system_update" ]
}

@test "sanitize_description leaves valid input unchanged" {
    [ "$(sanitize_description 'before-upgrade')" = "before-upgrade" ]
}

@test "sanitize_description handles a single word" {
    [ "$(sanitize_description 'experiment')" = "experiment" ]
}

#############################
# validate_description
#############################

@test "validate_description accepts alphanumeric" {
    run validate_description "abc123"
    [ "$status" -eq 0 ]
}

@test "validate_description accepts hyphens" {
    run validate_description "before-upgrade"
    [ "$status" -eq 0 ]
}

@test "validate_description accepts underscores" {
    run validate_description "pre_system_update"
    [ "$status" -eq 0 ]
}

@test "validate_description rejects slashes" {
    run validate_description "bad/name"
    [ "$status" -ne 0 ]
}

@test "validate_description rejects spaces" {
    run validate_description "two words"
    [ "$status" -ne 0 ]
}

@test "validate_description rejects shell metacharacters" {
    run validate_description "name; rm -rf"
    [ "$status" -ne 0 ]
}

@test "validate_description rejects an empty string" {
    run validate_description ""
    [ "$status" -ne 0 ]
}

#############################
# format_snapshot_name
#############################
# format_snapshot_name uses an injected timestamp (callers pass it in)
# rather than calling date() inside the helper, so the test doesn't
# need to mock the clock.

@test "format_snapshot_name composes timestamp + description" {
    [ "$(format_snapshot_name '2026-04-27_13-22-00' 'before-upgrade')" \
        = "2026-04-27_13-22-00_before-upgrade" ]
}

#############################
# main dispatch
#############################
# main routes the first positional arg to a cmd_* function. Tests
# replace the cmd_* functions with mocks that record invocation, so
# this layer's behavior (which subcommand for which arg) is what's
# pinned, not the bodies.

@test "main with no args shows help and exits 0" {
    run main
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "main --help shows help and exits 0" {
    run main --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "main -h shows help and exits 0" {
    run main -h
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "main help shows help and exits 0" {
    run main help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "main list dispatches to cmd_list" {
    cmd_list() { echo "called list with: $*"; }
    run main list
    [ "$status" -eq 0 ]
    [[ "$output" == "called list with: " ]]
}

@test "main create dispatches to cmd_create with remaining args" {
    cmd_create() { echo "called create with: $*"; }
    run main create "before upgrade"
    [ "$status" -eq 0 ]
    [[ "$output" == "called create with: before upgrade" ]]
}

@test "main rollback dispatches to cmd_rollback with remaining args" {
    cmd_rollback() { echo "called rollback with: $*"; }
    run main rollback -s
    [ "$status" -eq 0 ]
    [[ "$output" == "called rollback with: -s" ]]
}

@test "main delete dispatches to cmd_delete" {
    cmd_delete() { echo "called delete with: $*"; }
    run main delete
    [ "$status" -eq 0 ]
    [[ "$output" == "called delete with: " ]]
}

@test "main rejects an unknown subcommand and exits non-zero" {
    run main not-a-subcommand
    [ "$status" -ne 0 ]
    [[ "$output" == *"not-a-subcommand"* ]]
    [[ "$output" == *"Usage:"* ]]
}

#############################
# show_help — flag documentation
#############################

@test "show_help documents --name for rollback" {
    run show_help
    [ "$status" -eq 0 ]
    [[ "$output" == *"rollback"* ]]
    [[ "$output" == *"--name NAME"* ]]
}

@test "show_help documents --name for delete" {
    run show_help
    [ "$status" -eq 0 ]
    [[ "$output" == *"delete"* ]]
    [[ "$output" == *"--name NAME[,NAME...]"* ]]
}

#############################
# cmd_rollback --name
#############################
# These tests mock require_*, fzf, and zfs to exercise the arg-parse +
# fzf-bypass path without needing a real ZFS system. The destructive
# tail (zfs rollback) is exercised in scripts/test-install.sh against a
# real VM. Confirmation always answered "no" so the test stops at the
# gate without reaching the rollback step.

@test "cmd_rollback --name bypasses fzf and reaches the confirmation gate" {
    require_root() { :; }
    require_zfs() { :; }
    require_fzf() { echo "FZF REQUIRED" >&2; return 1; }
    fzf() { echo "FZF INVOKED" >&2; return 1; }
    zfs() {
        case "$1" in
            list) printf 'zroot/ROOT/default@target\nzroot/home@target\n' ;;
            *) echo "zfs $*" ;;
        esac
    }

    run cmd_rollback --name target <<< "no"

    [ "$status" -eq 0 ]
    [[ "$output" != *"FZF REQUIRED"* ]]
    [[ "$output" != *"FZF INVOKED"* ]]
    [[ "$output" == *"@target"* ]]
    [[ "$output" == *"cancelled"* ]]
}

@test "cmd_rollback --name without a value errors out" {
    require_root() { :; }
    require_zfs() { :; }
    run cmd_rollback --name
    [ "$status" -ne 0 ]
    [[ "$output" == *"requires an argument"* ]]
}

@test "cmd_rollback --name combined with -s errors out" {
    require_root() { :; }
    require_zfs() { :; }
    run cmd_rollback --name foo -s
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot be combined"* ]]
}

@test "cmd_rollback rejects an unknown flag" {
    require_root() { :; }
    require_zfs() { :; }
    run cmd_rollback --bogus
    [ "$status" -ne 0 ]
    [[ "$output" == *"Invalid option"* ]]
}

#############################
# cmd_delete --name
#############################

@test "cmd_delete --name bypasses fzf and reaches the confirmation gate" {
    require_root() { :; }
    require_zfs() { :; }
    require_fzf() { echo "FZF REQUIRED" >&2; return 1; }
    fzf() { echo "FZF INVOKED" >&2; return 1; }
    zfs() {
        case "$1" in
            list) printf 'zroot/ROOT/default@target\nzroot/home@target\n' ;;
            *) echo "zfs $*" ;;
        esac
    }

    run cmd_delete --name target <<< "no"

    [ "$status" -eq 0 ]
    [[ "$output" != *"FZF REQUIRED"* ]]
    [[ "$output" != *"FZF INVOKED"* ]]
    [[ "$output" == *"@target"* ]]
    [[ "$output" == *"cancelled"* ]]
}

@test "cmd_delete --name expands comma-separated names to multiple targets" {
    require_root() { :; }
    require_zfs() { :; }
    require_fzf() { :; }
    zfs() {
        case "$1" in
            list) printf 'zroot/ROOT/default@a\nzroot/home@a\nzroot/ROOT/default@b\n' ;;
            *) echo "zfs $*" ;;
        esac
    }

    run cmd_delete --name a,b <<< "no"

    [ "$status" -eq 0 ]
    [[ "$output" == *"zroot/ROOT/default@a"* ]]
    [[ "$output" == *"zroot/home@a"* ]]
    [[ "$output" == *"zroot/ROOT/default@b"* ]]
    [[ "$output" == *"3 snapshot(s) will be destroyed"* ]]
}

@test "cmd_delete --name without a value errors out" {
    require_root() { :; }
    require_zfs() { :; }
    run cmd_delete --name
    [ "$status" -ne 0 ]
    [[ "$output" == *"requires an argument"* ]]
}

@test "cmd_delete rejects an unknown flag" {
    require_root() { :; }
    require_zfs() { :; }
    run cmd_delete --bogus
    [ "$status" -ne 0 ]
    [[ "$output" == *"Invalid option"* ]]
}
