#!/usr/bin/env bats
# Unit tests for installer/lib/raid.sh

setup() {
    # shellcheck disable=SC1091
    source "${BATS_TEST_DIRNAME}/../../installer/lib/raid.sh"
}

#############################
# raid_valid_levels_for_count
#############################

@test "raid_valid_levels_for_count: 0 disks → empty output" {
    run raid_valid_levels_for_count 0
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "raid_valid_levels_for_count: 1 disk → empty output" {
    run raid_valid_levels_for_count 1
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "raid_valid_levels_for_count: 2 disks → mirror + stripe" {
    run raid_valid_levels_for_count 2
    [ "$status" -eq 0 ]
    [ "$output" = "mirror
stripe" ]
}

@test "raid_valid_levels_for_count: 3 disks → + raidz1" {
    run raid_valid_levels_for_count 3
    [ "$status" -eq 0 ]
    [ "$output" = "mirror
stripe
raidz1" ]
}

@test "raid_valid_levels_for_count: 4 disks → + raidz2" {
    run raid_valid_levels_for_count 4
    [ "$status" -eq 0 ]
    [ "$output" = "mirror
stripe
raidz1
raidz2" ]
}

@test "raid_valid_levels_for_count: 5 disks → + raidz3" {
    run raid_valid_levels_for_count 5
    [ "$status" -eq 0 ]
    [ "$output" = "mirror
stripe
raidz1
raidz2
raidz3" ]
}

@test "raid_valid_levels_for_count: 8 disks → same as 5 (no new levels)" {
    levels_5=$(raid_valid_levels_for_count 5)
    levels_8=$(raid_valid_levels_for_count 8)
    [ "$levels_5" = "$levels_8" ]
}

#############################
# raid_is_valid
#############################

@test "raid_is_valid: empty level + 1 disk = valid (no RAID)" {
    run raid_is_valid "" 1
    [ "$status" -eq 0 ]
}

@test "raid_is_valid: any level + 1 disk = invalid" {
    run raid_is_valid mirror 1
    [ "$status" -eq 1 ]
}

@test "raid_is_valid: mirror + 2 disks = valid" {
    run raid_is_valid mirror 2
    [ "$status" -eq 0 ]
}

@test "raid_is_valid: stripe + 2 disks = valid" {
    run raid_is_valid stripe 2
    [ "$status" -eq 0 ]
}

@test "raid_is_valid: raidz1 + 2 disks = invalid (need 3)" {
    run raid_is_valid raidz1 2
    [ "$status" -eq 1 ]
}

@test "raid_is_valid: raidz1 + 3 disks = valid" {
    run raid_is_valid raidz1 3
    [ "$status" -eq 0 ]
}

@test "raid_is_valid: raidz2 + 3 disks = invalid (need 4)" {
    run raid_is_valid raidz2 3
    [ "$status" -eq 1 ]
}

@test "raid_is_valid: raidz2 + 4 disks = valid" {
    run raid_is_valid raidz2 4
    [ "$status" -eq 0 ]
}

@test "raid_is_valid: raidz3 + 4 disks = invalid (need 5)" {
    run raid_is_valid raidz3 4
    [ "$status" -eq 1 ]
}

@test "raid_is_valid: raidz3 + 5 disks = valid" {
    run raid_is_valid raidz3 5
    [ "$status" -eq 0 ]
}

@test "raid_is_valid: unknown level = invalid" {
    run raid_is_valid raidz99 5
    [ "$status" -eq 1 ]
}

#############################
# raid_usable_bytes
#############################

@test "raid_usable_bytes: mirror returns smallest disk's bytes" {
    run raid_usable_bytes mirror 3 100 300
    [ "$status" -eq 0 ]
    [ "$output" = "100" ]
}

@test "raid_usable_bytes: stripe returns total bytes" {
    run raid_usable_bytes stripe 3 100 300
    [ "$status" -eq 0 ]
    [ "$output" = "300" ]
}

@test "raid_usable_bytes: raidz1 = (n-1) * smallest" {
    run raid_usable_bytes raidz1 3 100 300
    [ "$status" -eq 0 ]
    [ "$output" = "200" ]
}

@test "raid_usable_bytes: raidz2 = (n-2) * smallest" {
    run raid_usable_bytes raidz2 4 100 400
    [ "$status" -eq 0 ]
    [ "$output" = "200" ]
}

@test "raid_usable_bytes: raidz3 = (n-3) * smallest" {
    run raid_usable_bytes raidz3 5 100 500
    [ "$status" -eq 0 ]
    [ "$output" = "200" ]
}

@test "raid_usable_bytes: mixed-size mirror honors smallest (not average)" {
    run raid_usable_bytes mirror 3 80 300
    [ "$status" -eq 0 ]
    [ "$output" = "80" ]
}

@test "raid_usable_bytes: unknown level returns status 1" {
    run raid_usable_bytes bogus 3 100 300
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

#############################
# raid_fault_tolerance
#############################

@test "raid_fault_tolerance: mirror of 3 = can lose 2" {
    run raid_fault_tolerance mirror 3
    [ "$output" = "2" ]
}

@test "raid_fault_tolerance: mirror of 5 = can lose 4" {
    run raid_fault_tolerance mirror 5
    [ "$output" = "4" ]
}

@test "raid_fault_tolerance: stripe = 0" {
    run raid_fault_tolerance stripe 4
    [ "$output" = "0" ]
}

@test "raid_fault_tolerance: raidz1/2/3 = 1/2/3 regardless of disk count" {
    [ "$(raid_fault_tolerance raidz1 3)" = "1" ]
    [ "$(raid_fault_tolerance raidz1 8)" = "1" ]
    [ "$(raid_fault_tolerance raidz2 4)" = "2" ]
    [ "$(raid_fault_tolerance raidz3 5)" = "3" ]
}

@test "raid_fault_tolerance: unknown level returns status 1" {
    run raid_fault_tolerance bogus 3
    [ "$status" -eq 1 ]
}
