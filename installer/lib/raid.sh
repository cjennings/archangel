#!/usr/bin/env bash
# raid.sh - Pure RAID-level logic (testable, no I/O).
# Source after common.sh.

#############################
# Valid-level enumeration
#############################

# Print valid RAID levels for a given disk count, one per line.
# Count <2: nothing printed (single disk = no RAID).
# Count 2:  mirror, stripe
# Count 3+: + raidz1
# Count 4+: + raidz2
# Count 5+: + raidz3
raid_valid_levels_for_count() {
    local count=$1
    [[ $count -lt 2 ]] && return 0
    echo mirror
    echo stripe
    [[ $count -ge 3 ]] && echo raidz1
    [[ $count -ge 4 ]] && echo raidz2
    [[ $count -ge 5 ]] && echo raidz3
    return 0
}

# Return 0 if level is valid for the given disk count, 1 otherwise.
# Empty level with count 1 is valid (no RAID).
raid_is_valid() {
    local level=$1 count=$2
    if [[ $count -le 1 ]]; then
        [[ -z "$level" ]]
        return
    fi
    raid_valid_levels_for_count "$count" | grep -qxF "$level"
}

#############################
# Usable-space computation
#############################

# Print usable bytes for a level given disk count, smallest-disk bytes,
# and total bytes across all disks. Writes nothing and returns 1 for
# unknown levels.
#
# Usage: raid_usable_bytes LEVEL COUNT SMALLEST_BYTES TOTAL_BYTES
raid_usable_bytes() {
    local level=$1 count=$2 smallest=$3 total=$4
    case "$level" in
        mirror)  echo "$smallest" ;;
        stripe)  echo "$total" ;;
        raidz1)  echo $(( (count - 1) * smallest )) ;;
        raidz2)  echo $(( (count - 2) * smallest )) ;;
        raidz3)  echo $(( (count - 3) * smallest )) ;;
        *)       return 1 ;;
    esac
}

# Print fault-tolerance (max number of disks that can fail) for a level
# at the given disk count. Unknown level → return 1.
raid_fault_tolerance() {
    local level=$1 count=$2
    case "$level" in
        mirror)  echo $(( count - 1 )) ;;
        stripe)  echo 0 ;;
        raidz1)  echo 1 ;;
        raidz2)  echo 2 ;;
        raidz3)  echo 3 ;;
        *)       return 1 ;;
    esac
}

#############################
# Preview text
#############################

# Print preview text for a single RAID level. Used by get_raid_level()
# in the fzf preview pane. Calls raid_fault_tolerance and
# raid_usable_bytes for the data lines so the math stays in one place.
# Numeric arguments are unit-agnostic — pass GB if you want GB out.
#
# Usage: raid_preview LEVEL DISK_COUNT TOTAL_GB SMALLEST_GB
# Returns 1 for unknown level (no output).
raid_preview() {
    local level=$1 count=$2 total=$3 small=$4
    local tol usable

    tol=$(raid_fault_tolerance "$level" "$count") || return 1
    usable=$(raid_usable_bytes "$level" "$count" "$small" "$total") || return 1

    case "$level" in
        mirror)
            cat <<EOF
MIRROR
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

All disks contain identical copies of data.
Maximum redundancy. Can survive loss of all
disks except one.

Redundancy:    Can lose $tol of $count disks
Usable space:  ~${usable}GB (smallest disk)
Read speed:    Fast (parallel reads)
Write speed:   Normal

Best for:
  - Boot drives
  - Critical data
  - Maximum safety
EOF
            ;;
        stripe)
            cat <<EOF
STRIPE (RAID0)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

WARNING: NO REDUNDANCY!
Data is striped across all disks.
ANY disk failure = ALL data lost!

Redundancy:    NONE
Usable space:  ~${usable}GB (all disks)
Read speed:    Very fast
Write speed:   Very fast

Best for:
  - Scratch/temp space
  - Replaceable data
  - Maximum performance
EOF
            ;;
        raidz1)
            cat <<EOF
RAIDZ1 (Single Parity)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

One disk worth of parity distributed
across all disks.

Redundancy:    Can lose $tol of $count disks
Usable space:  ~${usable}GB ($((count - 1)) of $count disks)
Read speed:    Fast
Write speed:   Good

Best for:
  - General storage
  - Good balance of space/safety
EOF
            ;;
        raidz2)
            cat <<EOF
RAIDZ2 (Double Parity)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Two disks worth of parity distributed
across all disks.

Redundancy:    Can lose $tol of $count disks
Usable space:  ~${usable}GB ($((count - 2)) of $count disks)
Read speed:    Fast
Write speed:   Good

Best for:
  - Large arrays (5+ disks)
  - Important data
EOF
            ;;
        raidz3)
            cat <<EOF
RAIDZ3 (Triple Parity)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Three disks worth of parity distributed
across all disks.

Redundancy:    Can lose $tol of $count disks
Usable space:  ~${usable}GB ($((count - 3)) of $count disks)
Read speed:    Fast
Write speed:   Moderate

Best for:
  - Very large arrays (8+ disks)
  - Archival storage
EOF
            ;;
        *)
            return 1
            ;;
    esac
}
