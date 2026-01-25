#!/usr/bin/env bash
# common.sh - Shared functions for archangel installer
# Source this file: source "$(dirname "$0")/lib/common.sh"

#############################
# Output Functions
#############################

# Colors (optional, gracefully degrade if not supported)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    BOLD=''
    NC=''
fi

info()   { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step()   { echo ""; echo -e "${BOLD}==> $1${NC}"; }
prompt() { echo -e "${BLUE}$1${NC}"; }

# Log to file if LOG_FILE is set
log() {
    local msg="[$(date +'%Y-%m-%d %H:%M:%S')] $1"
    if [[ -n "$LOG_FILE" ]]; then
        echo "$msg" >> "$LOG_FILE"
    fi
}

#############################
# Validation Functions
#############################

require_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
    fi
}

command_exists() {
    command -v "$1" &>/dev/null
}

require_command() {
    command_exists "$1" || error "Required command not found: $1"
}

#############################
# FZF Prompts
#############################

# Check if fzf is available
has_fzf() {
    command_exists fzf
}

# Generic fzf selection
# Usage: result=$(fzf_select "prompt" "option1" "option2" ...)
fzf_select() {
    local prompt="$1"
    shift
    local options=("$@")

    if has_fzf; then
        printf '%s\n' "${options[@]}" | fzf --prompt="$prompt " --height=15 --reverse
    else
        # Fallback to simple select
        PS3="$prompt "
        select opt in "${options[@]}"; do
            if [[ -n "$opt" ]]; then
                echo "$opt"
                break
            fi
        done
    fi
}

# Multi-select with fzf
# Usage: readarray -t results < <(fzf_multi "prompt" "opt1" "opt2" ...)
fzf_multi() {
    local prompt="$1"
    shift
    local options=("$@")

    if has_fzf; then
        printf '%s\n' "${options[@]}" | fzf --prompt="$prompt " --height=20 --reverse --multi
    else
        # Fallback: just return all options (user must edit)
        printf '%s\n' "${options[@]}"
    fi
}

#############################
# Filesystem Selection
#############################

# Select filesystem type (ZFS or Btrfs)
# Sets global FILESYSTEM variable
select_filesystem() {
    step "Select Filesystem"

    local options=(
        "ZFS - Built-in encryption, best data integrity (recommended)"
        "Btrfs - Copy-on-write, LUKS encryption, GRUB snapshot boot"
    )

    local selected
    selected=$(fzf_select "Filesystem:" "${options[@]}")

    case "$selected" in
        ZFS*)
            FILESYSTEM="zfs"
            info "Selected: ZFS"
            ;;
        Btrfs*)
            FILESYSTEM="btrfs"
            info "Selected: Btrfs"
            ;;
        *)
            error "No filesystem selected"
            ;;
    esac
}

#############################
# Disk Utilities
#############################

# Get disk size in human-readable format
get_disk_size() {
    local disk="$1"
    lsblk -dno SIZE "$disk" 2>/dev/null | tr -d ' '
}

# Get disk model
get_disk_model() {
    local disk="$1"
    lsblk -dno MODEL "$disk" 2>/dev/null | tr -d ' ' | head -c 20
}

# Check if disk is in use (mounted or has holders)
disk_in_use() {
    local disk="$1"
    [[ -n "$(lsblk -no MOUNTPOINT "$disk" 2>/dev/null | grep -v '^$')" ]] && return 0
    [[ -n "$(ls /sys/block/"$(basename "$disk")"/holders/ 2>/dev/null)" ]] && return 0
    return 1
}

# List available disks (not in use)
list_available_disks() {
    local disks=()
    for disk in /dev/nvme[0-9]n[0-9] /dev/sd[a-z] /dev/vd[a-z]; do
        [[ -b "$disk" ]] || continue
        disk_in_use "$disk" && continue
        local size=$(get_disk_size "$disk")
        local model=$(get_disk_model "$disk")
        disks+=("$disk ($size, $model)")
    done
    printf '%s\n' "${disks[@]}"
}
