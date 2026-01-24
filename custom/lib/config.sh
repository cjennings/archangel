#!/usr/bin/env bash
# config.sh - Configuration and argument handling for archangel installer
# Source this file after common.sh

#############################
# Global Config Variables
#############################

CONFIG_FILE=""
UNATTENDED=false

# These get populated by config file or interactive prompts
FILESYSTEM=""           # "zfs" or "btrfs"
HOSTNAME=""
TIMEZONE=""
LOCALE=""
KEYMAP=""
SELECTED_DISKS=()
RAID_LEVEL=""
WIFI_SSID=""
WIFI_PASSWORD=""
ENCRYPTION_ENABLED=false
ZFS_PASSPHRASE=""
ROOT_PASSWORD=""
SSH_ENABLED=false
SSH_KEY=""

#############################
# Argument Parsing
#############################

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config-file)
                if [[ -n "$2" && ! "$2" =~ ^- ]]; then
                    CONFIG_FILE="$2"
                    shift 2
                else
                    error "--config-file requires a path argument"
                fi
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            *)
                error "Unknown option: $1 (use --help for usage)"
                ;;
        esac
    done
}

show_usage() {
    cat <<EOF
Usage: archangel [OPTIONS]

Arch Linux installer with ZFS/Btrfs support and snapshot management.

Options:
  --config-file PATH  Use config file for unattended installation
  --help, -h          Show this help message

Without --config-file, runs in interactive mode.
See /root/archangel.conf.example for a config template.
EOF
}

#############################
# Config File Loading
#############################

load_config() {
    local config_path="$1"

    if [[ ! -f "$config_path" ]]; then
        error "Config file not found: $config_path"
    fi

    info "Loading config from: $config_path"

    # Source the config file (it's just key=value pairs)
    # shellcheck disable=SC1090
    source "$config_path"

    # Convert DISKS from comma-separated string to array
    if [[ -n "$DISKS" ]]; then
        IFS=',' read -ra SELECTED_DISKS <<< "$DISKS"
    fi

    UNATTENDED=true
    info "Running in unattended mode"
}

check_config() {
    # Only use config when explicitly specified with --config-file
    # This prevents accidental disk destruction from an unnoticed config file
    if [[ -n "$CONFIG_FILE" ]]; then
        load_config "$CONFIG_FILE"
    fi
}

#############################
# Config Validation
#############################

validate_config() {
    local errors=0

    [[ -z "$HOSTNAME" ]] && { warn "HOSTNAME not set"; ((errors++)); }
    [[ -z "$TIMEZONE" ]] && { warn "TIMEZONE not set"; ((errors++)); }
    [[ ${#SELECTED_DISKS[@]} -eq 0 ]] && { warn "No disks selected"; ((errors++)); }
    [[ -z "$ROOT_PASSWORD" ]] && { warn "ROOT_PASSWORD not set"; ((errors++)); }

    # Validate disks exist
    for disk in "${SELECTED_DISKS[@]}"; do
        [[ -b "$disk" ]] || { warn "Disk not found: $disk"; ((errors++)); }
    done

    # Validate timezone
    if [[ -n "$TIMEZONE" && ! -f "/usr/share/zoneinfo/$TIMEZONE" ]]; then
        warn "Invalid timezone: $TIMEZONE"
        ((errors++))
    fi

    if [[ $errors -gt 0 ]]; then
        error "Config validation failed with $errors error(s)"
    fi
    info "Config validation passed"
}
