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

#############################
# raid_preview
#############################
# Signature: raid_preview LEVEL DISK_COUNT TOTAL_GB SMALLEST_GB
# Returns 1 for unknown level. Output is preview text — assertions
# focus on structural pieces (headlines, computed numbers, key
# labels), not exact prose.

@test "raid_preview mirror: headline + fault tolerance + smallest disk size" {
    run raid_preview mirror 3 300 100
    [ "$status" -eq 0 ]
    [[ "$output" == *"MIRROR"* ]]
    [[ "$output" == *"Can lose 2 of 3 disks"* ]]
    [[ "$output" == *"100"* ]]
}

@test "raid_preview stripe: headline + no-redundancy warning + total size" {
    run raid_preview stripe 2 200 100
    [ "$status" -eq 0 ]
    [[ "$output" == *"STRIPE"* ]]
    [[ "$output" == *"NO REDUNDANCY"* ]]
    [[ "$output" == *"200"* ]]
}

@test "raid_preview raidz1: headline + can-lose-1 + (n-1)*smallest size" {
    run raid_preview raidz1 4 400 100
    [ "$status" -eq 0 ]
    [[ "$output" == *"RAIDZ1"* ]]
    [[ "$output" == *"Can lose 1 of 4 disks"* ]]
    [[ "$output" == *"300"* ]]
}

@test "raid_preview raidz2: headline + can-lose-2 + (n-2)*smallest size" {
    run raid_preview raidz2 5 500 100
    [ "$status" -eq 0 ]
    [[ "$output" == *"RAIDZ2"* ]]
    [[ "$output" == *"Can lose 2 of 5 disks"* ]]
    [[ "$output" == *"300"* ]]
}

@test "raid_preview raidz3: headline + can-lose-3 + (n-3)*smallest size" {
    run raid_preview raidz3 6 600 100
    [ "$status" -eq 0 ]
    [[ "$output" == *"RAIDZ3"* ]]
    [[ "$output" == *"Can lose 3 of 6 disks"* ]]
    [[ "$output" == *"300"* ]]
}

@test "raid_preview mirror with mixed-size disks honors smallest, not average" {
    run raid_preview mirror 3 300 80
    [ "$status" -eq 0 ]
    [[ "$output" == *"80"* ]]
    [[ "$output" != *"100"* ]]
}

@test "raid_preview unknown level returns 1 with empty output" {
    run raid_preview bogus 3 300 100
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "raid_preview every valid level produces non-empty output" {
    for level in mirror stripe raidz1 raidz2 raidz3; do
        run raid_preview "$level" 5 500 100
        [ "$status" -eq 0 ]
        [ -n "$output" ]
    done
}
