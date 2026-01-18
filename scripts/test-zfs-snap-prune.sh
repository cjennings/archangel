#!/bin/bash
# test-zfs-snap-prune.sh - Comprehensive test suite for zfs-snap-prune
#
# Runs various scenarios with mock data to verify the pruning logic.
# No root or ZFS required - uses --test mode with mock data.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRUNE_SCRIPT="$SCRIPT_DIR/../custom/zfs-snap-prune"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test counters - use temp files to avoid subshell issues with pipes
COUNTER_FILE=$(mktemp)
echo "0 0 0" > "$COUNTER_FILE"  # run passed failed
trap "rm -f $COUNTER_FILE" EXIT

# Time constants for generating test data
DAY=$((24 * 60 * 60))
NOW=$(date +%s)

# Generate a snapshot line for mock data
# Args: snapshot_name days_ago
# Output: zroot/ROOT/default@name<TAB>epoch_timestamp
make_snap() {
    local name="$1"
    local days_ago="$2"
    local timestamp=$((NOW - (days_ago * DAY)))
    echo -e "zroot/ROOT/default@${name}\t${timestamp}"
}

# Generate N snapshots with given prefix and starting age
# Args: prefix count start_days_ago
# NOTE: Outputs oldest first (like ZFS with -s creation), so start_age is the OLDEST
make_snaps() {
    local prefix="$1"
    local count="$2"
    local start_age="$3"
    # Generate from oldest to newest (ZFS order with -s creation)
    for ((i=count; i>=1; i--)); do
        make_snap "${prefix}_${i}" $((start_age + i - 1))
    done
}

# Increment counter in temp file
# Args: position (1=run, 2=passed, 3=failed)
inc_counter() {
    local pos="$1"
    local counters
    read -r run passed failed < "$COUNTER_FILE"
    case "$pos" in
        1) run=$((run + 1)) ;;
        2) passed=$((passed + 1)) ;;
        3) failed=$((failed + 1)) ;;
    esac
    echo "$run $passed $failed" > "$COUNTER_FILE"
}

# Get counter values
get_counters() {
    cat "$COUNTER_FILE"
}

# Run a test case
# Args: test_name expected_kept expected_deleted env_vars
# Reads mock snapshot data from stdin
run_test() {
    local test_name="$1"
    local expected_kept="$2"
    local expected_deleted="$3"
    shift 3
    local env_vars="$*"

    inc_counter 1  # TESTS_RUN++
    echo -e "${BLUE}TEST:${NC} $test_name"

    # Capture stdin (mock data) and pass to prune script
    local mock_data
    mock_data=$(cat)

    # Run prune script with mock data on stdin
    local output
    output=$(echo "$mock_data" | env NOW_OVERRIDE="$NOW" $env_vars "$PRUNE_SCRIPT" --test --quiet 2>&1)

    # Extract results
    local result_line
    result_line=$(echo "$output" | grep "^RESULT:" || echo "RESULT:kept=0,deleted=0")
    local actual_kept
    actual_kept=$(echo "$result_line" | sed 's/.*kept=\([0-9]*\).*/\1/')
    local actual_deleted
    actual_deleted=$(echo "$result_line" | sed 's/.*deleted=\([0-9]*\).*/\1/')

    # Compare
    if [[ "$actual_kept" == "$expected_kept" ]] && [[ "$actual_deleted" == "$expected_deleted" ]]; then
        echo -e "  ${GREEN}PASS${NC} (kept=$actual_kept, deleted=$actual_deleted)"
        inc_counter 2  # TESTS_PASSED++
        return 0
    else
        echo -e "  ${RED}FAIL${NC}"
        echo -e "    Expected: kept=$expected_kept, deleted=$expected_deleted"
        echo -e "    Actual:   kept=$actual_kept, deleted=$actual_deleted"
        inc_counter 3  # TESTS_FAILED++
        return 1
    fi
}

# Print section header
section() {
    echo ""
    echo -e "${YELLOW}=== $1 ===${NC}"
}

# Verify prune script exists
if [[ ! -x "$PRUNE_SCRIPT" ]]; then
    chmod +x "$PRUNE_SCRIPT"
fi

echo -e "${GREEN}zfs-snap-prune Test Suite${NC}"
echo "========================="
echo "Using NOW=$NOW ($(date -d "@$NOW" '+%Y-%m-%d %H:%M:%S'))"
echo "Default policy: KEEP_COUNT=20, MAX_AGE_DAYS=180"

###############################################################################
section "Basic Cases"
###############################################################################

# Test 1: Empty list
echo -n "" | run_test "Empty snapshot list" 0 0

# Test 2: Single snapshot
make_snap "test1" 5 | run_test "Single snapshot (recent)" 1 0

# Test 3: Under keep count - all recent
make_snaps "recent" 10 1 | run_test "10 snapshots, all recent" 10 0

# Test 4: Exactly at keep count
make_snaps "exact" 20 1 | run_test "Exactly 20 snapshots" 20 0

###############################################################################
section "Over Keep Count - Age Matters"
###############################################################################

# Test 5: 25 snapshots, all recent (within 180 days)
# Should keep all - none old enough to delete
make_snaps "recent" 25 1 | run_test "25 snapshots, all recent (<180 days)" 25 0

# Test 6: 25 snapshots, 5 are old (>180 days)
# First 20 (most recent) kept by count, 5 oldest are >180 days old, so deleted
{
    make_snaps "old" 5 200      # oldest first (200-204 days ago)
    make_snaps "recent" 20 1    # newest last (1-20 days ago)
} | run_test "25 snapshots, 5 old (>180 days) - delete 5" 20 5

# Test 7: 30 snapshots, 10 beyond limit but only 5 old enough
{
    make_snaps "old" 5 200      # 200-204 days old - delete these
    make_snaps "medium" 5 100   # 100-104 days old - not old enough
    make_snaps "recent" 20 1    # 1-20 days old
} | run_test "30 snapshots, 5 medium age, 5 old - delete 5" 25 5

###############################################################################
section "Genesis Protection"
###############################################################################

# Test 8: Genesis at position 21, old - should NOT be deleted
{
    make_snap "genesis" 365    # oldest: 1 year old
    make_snaps "recent" 20 1   # newest: 1-20 days ago
} | run_test "Genesis at position 21 (old) - protected" 21 0

# Test 9: Genesis at position 25, with other old snapshots
{
    make_snap "genesis" 365    # oldest: protected
    make_snaps "old" 4 200     # 200-203 days old - should be deleted
    make_snaps "recent" 20 1   # 1-20 days old
} | run_test "Genesis at position 25 with 4 old - delete 4, keep genesis" 21 4

# Test 10: Genesis within keep count (20 total snapshots)
{
    make_snap "genesis" 365     # oldest
    make_snaps "more" 9 15      # 15-23 days ago
    make_snaps "recent" 10 1    # 1-10 days ago
} | run_test "Genesis at position 11 (within keep count)" 20 0

###############################################################################
section "Custom Configuration"
###############################################################################

# Test 11: Custom KEEP_COUNT=5
make_snaps "test" 10 200 | \
    run_test "KEEP_COUNT=5, 10 old snapshots - delete 5" 5 5 KEEP_COUNT=5

# Test 12: Custom MAX_AGE_DAYS=30
{
    make_snaps "medium" 5 50   # 50-54 days old - now considered old with MAX_AGE=30
    make_snaps "recent" 20 1   # 1-20 days ago
} | run_test "MAX_AGE_DAYS=30, 5 snapshots >30 days - delete 5" 20 5 MAX_AGE_DAYS=30

# Test 13: Very short retention
make_snaps "test" 15 10 | \
    run_test "KEEP_COUNT=3, MAX_AGE=7, 15 snaps (10+ days old) - delete 12" 3 12 KEEP_COUNT=3 MAX_AGE_DAYS=7

# Test 14: Relaxed retention - nothing deleted
make_snaps "test" 50 1 | \
    run_test "KEEP_COUNT=100 - keep all 50" 50 0 KEEP_COUNT=100

###############################################################################
section "Edge Cases"
###############################################################################

# Test 15: Snapshot exactly at MAX_AGE boundary (180 days) - should be kept
{
    make_snap "boundary" 180     # Exactly 180 days - >= cutoff, kept
    make_snaps "recent" 20 1     # 1-20 days ago
} | run_test "1 snapshot exactly at 180 day boundary - keep" 21 0

# Test 16: Snapshot just over MAX_AGE boundary (181 days) - should be deleted
{
    make_snap "over" 181        # 181 days - just over, should be deleted
    make_snaps "recent" 20 1    # 1-20 days ago
} | run_test "1 snapshot at 181 days - delete" 20 1

# Test 17: Mixed boundary - some at 180, some at 181
{
    make_snap "over2" 182       # deleted
    make_snap "over1" 181       # deleted
    make_snap "boundary" 180    # kept (exactly at cutoff)
    make_snaps "recent" 20 1    # 1-20 days ago
} | run_test "2 over boundary, 1 at boundary - delete 2" 21 2

# Test 18: Mixed naming patterns (ordered oldest to newest)
{
    make_snap "genesis" 365
    make_snap "before-upgrade" 20
    make_snap "manual_backup" 15
    make_snap "pre-pacman_2025-01-10" 10
    make_snap "pre-pacman_2025-01-15" 5
} | run_test "Mixed snapshot names (5 total)" 5 0

# Test 19: Large number of snapshots
{
    make_snaps "old" 100 200   # 200-299 days old
    make_snaps "recent" 20 1   # 1-20 days ago
} | run_test "120 snapshots, 100 old - delete 100" 20 100

###############################################################################
section "Realistic Scenarios"
###############################################################################

# Test 20: One year of weekly pacman updates + genesis
# 52 snapshots (one per week) + genesis
# Ordered oldest first: genesis (365 days), then week_51 (357 days), ..., week_0 (0 days)
{
    make_snap "genesis" 365
    for ((week=51; week>=0; week--)); do
        make_snap "pre-pacman_week_${week}" $((week * 7))
    done
} | run_test "1 year of weekly updates (52) + genesis" 27 26
# Analysis (after tac, newest first):
# Position 1-20: week_0 through week_19 (0-133 days) - kept by count
# Position 21-26: week_20 through week_25 (140-175 days) - kept by age (<180)
# Position 27-52: week_26 through week_51 (182-357 days) - deleted (>180)
# Position 53: genesis (365 days) - protected
# Kept: 20 + 6 + 1 = 27, Deleted: 26

# Test 21: Fresh install with only genesis
make_snap "genesis" 1 | run_test "Fresh install - only genesis" 1 0

# Test 22: Burst of manual snapshots before big change
{
    make_snap "genesis" 30
    make_snap "before-nvidia" 20
    make_snap "before-DE-change" 19
    make_snaps "pre-pacman" 18 1
} | run_test "20 snaps + genesis (30 days old)" 21 0

###############################################################################
section "Results"
###############################################################################

# Read final counters
read -r TESTS_RUN TESTS_PASSED TESTS_FAILED < "$COUNTER_FILE"

echo ""
echo "========================="
echo -e "Tests run:    $TESTS_RUN"
echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"
echo ""

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed.${NC}"
    exit 1
fi
