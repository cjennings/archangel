#!/usr/bin/env bash
# common.sh - Shared functions for archangel installer
# Source this file: source "$(dirname "$0")/lib/common.sh"

#############################
# Path Constants
#############################

# Mount point for the install chroot's root. Sub-paths compose with
# $MNTPOINT/etc/... (the host paths the installer writes into during
# pacstrap and config). Bare $MNTPOINT works since `/` isn't an
# identifier character; use ${MNTPOINT}${chroot_efi_dir} when the
# next character would otherwise be parsed as part of the variable
# name.
MNTPOINT="/mnt"

# Mount point for the primary EFI partition during install. Sub-paths
# compose with ${EFI_DIR}/...; secondary EFI partitions in multi-disk
# layouts use ${EFI_DIR}${i} (no trailing slash, so the index appends
# cleanly).
EFI_DIR="$MNTPOINT/efi"

#############################
# Output Functions
#############################

# No color by default — use --color flag to enable
RED=''
GREEN=''
YELLOW=''
BLUE=''
BOLD=''
NC=''

enable_color() {
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    NC='\033[0m'
}

info()   { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step()   { echo ""; echo -e "${BOLD}==> $1${NC}"; }
prompt() { echo -e "${BLUE}$1${NC}"; }

# Log to file if LOG_FILE is set
log() {
    local msg
    msg="[$(date +'%Y-%m-%d %H:%M:%S')] $1"
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
# Package Selection
#############################

# Print the pacstrap package list for the given filesystem, one per line.
# Common packages first, then filesystem-specific ones.
# Returns 1 for unknown filesystem.
#
# Usage: mapfile -t pkgs < <(pacstrap_packages zfs)
pacstrap_packages() {
    local fs="$1"
    local common=(
        base base-devel
        linux-lts linux-lts-headers linux-firmware
        efibootmgr
        networkmanager avahi nss-mdns openssh
        git vim sudo zsh nodejs npm
        ttf-dejavu fzf wget inetutils wireless-regdb
    )
    local fs_specific
    case "$fs" in
        zfs)   fs_specific=(zfs-dkms zfs-utils) ;;
        btrfs) fs_specific=(btrfs-progs grub grub-btrfs snapper snap-pac) ;;
        *)     return 1 ;;
    esac
    printf '%s\n' "${common[@]}" "${fs_specific[@]}"
}

# Print the external commands the installer needs for the given filesystem,
# one per line: common partitioning/bootstrap tools first, then
# filesystem-specific ones. validate_environment loops over these and
# require_command's each, so a missing tool fails fast on the live ISO
# instead of mid-install. Returns 1 for unknown filesystem.
#
# Usage: mapfile -t cmds < <(required_commands zfs)
required_commands() {
    local fs="$1"
    local common=(
        sgdisk wipefs partprobe mkfs.fat pacstrap
    )
    local fs_specific
    case "$fs" in
        zfs)   fs_specific=(zpool zfs) ;;
        btrfs) fs_specific=(mkfs.btrfs grub-install) ;;
        *)     return 1 ;;
    esac
    printf '%s\n' "${common[@]}" "${fs_specific[@]}"
}

#############################
# Password / Passphrase Input
#############################

# Prompt for a secret, require confirmation, enforce min length, loop
# until valid. Sets the named variable by nameref so UI output stays
# on the terminal and the caller doesn't command-substitute.
#
# Usage: prompt_password VAR_NAME "label for prompts" MIN_LEN
#   min_len of 0 disables the length check.
prompt_password() {
    local -n _out="$1"
    local label="$2"
    local min_len="${3:-0}"
    local confirm

    while true; do
        prompt "Enter $label:"
        read -rs _out
        echo ""

        prompt "Confirm $label:"
        read -rs confirm
        echo ""

        if [[ "$_out" != "$confirm" ]]; then
            warn "Passphrases do not match. Try again."
            continue
        fi
        if [[ $min_len -gt 0 && ${#_out} -lt $min_len ]]; then
            warn "Passphrase must be at least $min_len characters. Try again."
            continue
        fi
        break
    done
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

# Install a systemd drop-in for $service under $root, reading its body
# from stdin. Creates $root/etc/systemd/system/$service.service.d/ at
# mode 755 (idempotent) and writes $dropin_name.conf there. Intended
# for post-pacstrap customization — pass "/mnt" as root at install
# time; tests pass a tempdir.
install_dropin() {
    local service="$1"
    local dropin_name="$2"
    local root="$3"
    local dir="${root}/etc/systemd/system/${service}.service.d"
    install -d -m 755 "$dir"
    cat > "${dir}/${dropin_name}.conf"
}

# Read efibootmgr output from stdin and echo the boot number of the
# first entry whose label contains $1. Returns 1 (with empty output)
# if the label is empty, no entry matches, or the matched line has no
# Boot[0-9A-F]+ prefix. The empty-label guard is important: an empty
# string would match every line, and a line like "BootCurrent: 0001"
# would falsely satisfy the Boot[hex]+ regex (capturing "C").
parse_efibootmgr_entry() {
    local label="$1"
    [[ -z "$label" ]] && return 1
    local line
    line=$(grep -F -m 1 "$label") || return 1
    [[ "$line" =~ Boot([0-9A-Fa-f]+) ]] || return 1
    echo "${BASH_REMATCH[1]}"
}

# Read efibootmgr output from stdin and echo the comma-separated boot
# numbers from the BootOrder line, with whitespace stripped. Returns 1
# (with empty output) if no BootOrder line is present.
parse_efibootmgr_bootorder() {
    local line
    line=$(grep "^BootOrder:") || return 1
    echo "${line#BootOrder:}" | tr -d ' '
}

# List available disks (not in use)
list_available_disks() {
    local disks=()
    for disk in /dev/nvme[0-9]n[0-9] /dev/sd[a-z] /dev/vd[a-z]; do
        [[ -b "$disk" ]] || continue
        disk_in_use "$disk" && continue
        local size
        size=$(get_disk_size "$disk")
        local model
        model=$(get_disk_model "$disk")
        disks+=("$disk ($size, $model)")
    done
    printf '%s\n' "${disks[@]}"
}

#############################
# SSH Configuration
#############################

# Ensure the given sshd_config file ends up with `PermitRootLogin yes`.
# Combines the commented (#PermitRootLogin) and uncommented
# (PermitRootLogin) replacements into one sed invocation, then verifies
# the directive is present. Errors out if neither pattern matched, since
# silently appending would mask a corrupted starting file.
enable_sshd_root_login() {
    local config_file="$1"
    sed -i -e 's/^#PermitRootLogin.*/PermitRootLogin yes/' \
           -e 's/^PermitRootLogin.*/PermitRootLogin yes/' \
           "$config_file"
    grep -q '^PermitRootLogin yes$' "$config_file" \
        || error "PermitRootLogin not set in $config_file (no matching line to replace)"
}

#############################
# GRUB Configuration
#############################

# Prepend a string just inside the GRUB_CMDLINE_LINUX="..." quotes in
# /etc/default/grub. Errors if the line isn't present in the file.
# Silently doing nothing here would leave the kernel without the
# parameter — for cryptdevice= that means the system can't unlock the
# root partition at boot, so we want a loud failure during install
# rather than an unbootable system after first reboot.
prepend_grub_cmdline_linux() {
    local addition="$1"
    local config_file="$2"
    sed -i "s|^GRUB_CMDLINE_LINUX=\"|GRUB_CMDLINE_LINUX=\"${addition}|" "$config_file"
    grep -qF "GRUB_CMDLINE_LINUX=\"${addition}" "$config_file" \
        || error "GRUB_CMDLINE_LINUX not modified in $config_file (line missing or pattern unmatched)"
}

#############################
# Initramfs Configuration
#############################

# Ensure mkinitcpio.conf's FILES= line lists the given value. Replaces
# an existing FILES= line, or appends one if absent. Self-healing
# rather than error-on-miss: FILES= is optional in mkinitcpio.conf, so
# a missing line means "no extra files," not a broken config.
ensure_initramfs_files() {
    local value="$1"
    local config_file="$2"
    sed -i "s|^FILES=.*|FILES=(${value})|" "$config_file"
    if ! grep -q "^FILES=" "$config_file"; then
        echo "FILES=(${value})" >> "$config_file"
    fi
}
