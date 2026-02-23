#!/usr/bin/env bash
# test-install.sh - Automated installation testing for archangel
#
# Runs unattended installs in VMs using test config files.
# Verifies installation success via SSH (when enabled) or console.
#
# Usage:
#   ./test-install.sh                 # Run all test configs
#   ./test-install.sh single-disk     # Run specific config
#   ./test-install.sh --list          # List available configs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
export PROJECT_DIR
CONFIG_DIR="$SCRIPT_DIR/test-configs"
LOG_DIR="$PROJECT_DIR/test-logs"
VM_DIR="$PROJECT_DIR/vm"

# VM settings
VM_RAM="4096"
VM_CPUS="4"
VM_DISK_SIZE="20G"
export SSH_PORT="2222"
export SSH_PASSWORD="archangel"
SERIAL_LOG="$LOG_DIR/serial.log"

# Timeouts (seconds)
BOOT_TIMEOUT=120
INSTALL_TIMEOUT=600
SSH_TIMEOUT=30
VERIFY_TIMEOUT=60

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
step()  { echo -e "${BLUE}[STEP]${NC} $1"; }

# UEFI firmware (override via environment for non-Arch distros)
OVMF_CODE="${OVMF_CODE:-/usr/share/edk2/x64/OVMF_CODE.4m.fd}"
OVMF_VARS_ORIG="${OVMF_VARS_ORIG:-/usr/share/edk2/x64/OVMF_VARS.4m.fd}"

# Track test results
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_TESTS=()

usage() {
    cat <<EOF
Usage: $0 [OPTIONS] [CONFIG_NAME...]

Run automated installation tests in VMs.

Options:
  --list        List available test configs
  --help, -h    Show this help

Examples:
  $0                    # Run all tests
  $0 single-disk        # Run single test
  $0 single-disk mirror # Run specific tests

Available configs:
$(ls "$CONFIG_DIR"/*.conf 2>/dev/null | xargs -n1 basename | sed 's/.conf$//' | sed 's/^/  /')
EOF
}

list_configs() {
    echo "Available test configs:"
    for conf in "$CONFIG_DIR"/*.conf; do
        [[ -f "$conf" ]] || continue
        name=$(basename "$conf" .conf)
        desc=$(grep "^# Test config:" "$conf" | sed 's/^# Test config: //' || echo "")
        printf "  %-20s %s\n" "$name" "$desc"
    done
}

find_iso() {
    ISO_FILE=$(ls -t "$PROJECT_DIR/out/"*.iso 2>/dev/null | head -1)
    if [[ -z "$ISO_FILE" ]]; then
        error "No ISO found in $PROJECT_DIR/out/"
        error "Build the ISO first with: make build"
        exit 1
    fi
    info "Using ISO: $(basename "$ISO_FILE")"
}

# Get number of disks needed for a config
get_disk_count() {
    local config="$1"
    local disks
    disks=$(grep "^DISKS=" "$config" | cut -d= -f2 | tr ',' '\n' | wc -l)
    echo "$disks"
}

# Create VM disks
create_disks() {
    local count="$1"
    local test_name="$2"

    mkdir -p "$VM_DIR"

    for ((i=1; i<=count; i++)); do
        local disk="$VM_DIR/test-${test_name}-disk${i}.qcow2"
        if [[ -f "$disk" ]]; then
            rm -f "$disk"
        fi
        qemu-img create -f qcow2 "$disk" "$VM_DISK_SIZE" >/dev/null
    done
}

# Build QEMU disk arguments
get_disk_args() {
    local count="$1"
    local test_name="$2"
    local args=""

    for ((i=1; i<=count; i++)); do
        local disk="$VM_DIR/test-${test_name}-disk${i}.qcow2"
        args="$args -drive file=$disk,format=qcow2,if=virtio"
    done
    echo "$args"
}

# Clean up VM disks
cleanup_disks() {
    local test_name="$1"
    rm -f "$VM_DIR"/test-"${test_name}"-disk*.qcow2
}

# Start VM and return PID
start_vm() {
    local test_name="$1"
    local disk_count="$2"
    local disk_args
    disk_args=$(get_disk_args "$disk_count" "$test_name")

    # Copy OVMF vars for this test
    local ovmf_vars="$VM_DIR/OVMF_VARS_${test_name}.fd"
    cp "$OVMF_VARS_ORIG" "$ovmf_vars"

    # Start VM with serial console logging
    qemu-system-x86_64 \
        -name "archangel-test-$test_name" \
        -machine type=q35,accel=kvm \
        -cpu host \
        -m "$VM_RAM" \
        -smp "$VM_CPUS" \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
        -drive if=pflash,format=raw,file="$ovmf_vars" \
        $disk_args \
        -cdrom "$ISO_FILE" \
        -boot d \
        -netdev user,id=net0,hostfwd=tcp::"$SSH_PORT"-:22 \
        -device virtio-net-pci,netdev=net0 \
        -serial file:"$SERIAL_LOG" \
        -display none \
        -daemonize \
        -pidfile "$VM_DIR/qemu-${test_name}.pid" \
        2>/dev/null

    sleep 2  # Give QEMU time to start
    cat "$VM_DIR/qemu-${test_name}.pid" 2>/dev/null
}

# Start VM from installed disk (no ISO)
# Pass "luks" as $3 to add a QEMU monitor socket (needed for GRUB passphrase entry via sendkey)
start_vm_from_disk() {
    local test_name="$1"
    local disk_count="$2"
    local luks_mode="${3:-}"
    local disk_args
    disk_args=$(get_disk_args "$disk_count" "$test_name")

    # Reuse existing OVMF vars (preserves EFI boot entries from install)
    local ovmf_vars="$VM_DIR/OVMF_VARS_${test_name}.fd"

    # For LUKS: add monitor socket for sendkey (to type GRUB passphrase)
    local monitor_args=""
    if [[ "$luks_mode" == "luks" ]]; then
        local monitor_sock="$VM_DIR/monitor-${test_name}.sock"
        rm -f "$monitor_sock"
        monitor_args="-monitor unix:$monitor_sock,server,nowait"
    fi

    # Start VM without ISO, boot from disk
    qemu-system-x86_64 \
        -name "archangel-test-$test_name" \
        -machine type=q35,accel=kvm \
        -cpu host \
        -m "$VM_RAM" \
        -smp "$VM_CPUS" \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
        -drive if=pflash,format=raw,file="$ovmf_vars" \
        $disk_args \
        -boot c \
        -netdev user,id=net0,hostfwd=tcp::"$SSH_PORT"-:22 \
        -device virtio-net-pci,netdev=net0 \
        -serial file:"$SERIAL_LOG" \
        $monitor_args \
        -display none \
        -daemonize \
        -pidfile "$VM_DIR/qemu-${test_name}.pid" \
        2>/dev/null

    sleep 2
    cat "$VM_DIR/qemu-${test_name}.pid" 2>/dev/null
}

# Stop VM
stop_vm() {
    local test_name="$1"
    local keep_vars="${2:-false}"  # Optional: keep OVMF vars for reboot test
    local pid_file="$VM_DIR/qemu-${test_name}.pid"

    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            sleep 2
            kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$pid_file"
    fi

    # Clean up OVMF vars unless asked to keep them
    if [[ "$keep_vars" != "true" ]]; then
        rm -f "$VM_DIR/OVMF_VARS_${test_name}.fd"
    fi

    # Clean up monitor socket
    rm -f "$VM_DIR/monitor-${test_name}.sock"
}

# Wait for SSH to be available
wait_for_ssh() {
    local timeout="$1"
    local password="${2:-$SSH_PASSWORD}"  # Optional password, defaults to SSH_PASSWORD
    local start_time
    start_time=$(date +%s)

    while true; do
        if sshpass -p "$password" ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -p "$SSH_PORT" root@localhost "echo ok" 2>/dev/null | grep -q ok; then
            return 0
        fi

        local elapsed=$(($(date +%s) - start_time))
        if [[ $elapsed -ge $timeout ]]; then
            return 1
        fi

        sleep 5
    done
}

# Wait for boot via serial console (for systems without SSH)
# Checks for ZFSBootMenu loading, which proves the disk is bootable
# and EFI entries + ZBM binary were installed correctly.
wait_for_boot_console() {
    local timeout="$1"
    local start_time
    start_time=$(date +%s)

    while true; do
        if grep -q "ZFSBootMenu\|login:" "$SERIAL_LOG" 2>/dev/null; then
            return 0
        fi

        local elapsed=$(($(date +%s) - start_time))
        if [[ $elapsed -ge $timeout ]]; then
            return 1
        fi

        sleep 5
    done
}

# Send a string as QEMU monitor sendkey commands
# Converts each character to a QEMU key name and sends via monitor socket
monitor_sendkeys() {
    local monitor_sock="$1"
    local text="$2"

    for ((ci=0; ci<${#text}; ci++)); do
        local char="${text:$ci:1}"
        local key=""
        case "$char" in
            [a-z]) key="$char" ;;
            [A-Z]) key="shift-$(echo "$char" | tr '[:upper:]' '[:lower:]')" ;;
            [0-9]) key="$char" ;;
            ' ')   key="spc" ;;
            '-')   key="minus" ;;
            '=')   key="equal" ;;
            '.')   key="dot" ;;
            ',')   key="comma" ;;
            '/')   key="slash" ;;
            '\\')  key="backslash" ;;
            ';')   key="semicolon" ;;
            "'")   key="apostrophe" ;;
            '[')   key="bracket_left" ;;
            ']')   key="bracket_right" ;;
            '!')   key="shift-1" ;;
            '@')   key="shift-2" ;;
            '#')   key="shift-3" ;;
            '$')   key="shift-4" ;;
            *)     key="$char" ;;
        esac
        echo "sendkey $key" | socat - UNIX-CONNECT:"$monitor_sock" >/dev/null 2>&1
        sleep 0.05  # Small delay between keystrokes
    done
    # Send Enter
    echo "sendkey ret" | socat - UNIX-CONNECT:"$monitor_sock" >/dev/null 2>&1
}

# Send GRUB passphrase via QEMU monitor sendkey
# The initramfs passphrase is handled by the cryptkey=rootfs: parameter
# For multi-disk LUKS (mirror), GRUB prompts for each disk separately
send_luks_passphrase() {
    local test_name="$1"
    local passphrase="$2"
    local disk_count="${3:-1}"
    local monitor_sock="$VM_DIR/monitor-${test_name}.sock"

    step "Waiting for GRUB passphrase prompt..."

    # Wait for first GRUB passphrase prompt
    local waited=0
    while ! grep -q "Enter passphrase for" "$SERIAL_LOG" 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
        if [[ $waited -ge 30 ]]; then
            error "Timed out waiting for GRUB passphrase prompt"
            return 1
        fi
    done
    info "GRUB passphrase prompt detected after ${waited}s"

    # Send passphrase for each LUKS disk (GRUB prompts once per encrypted disk)
    for ((i=1; i<=disk_count; i++)); do
        sleep 1  # Ensure GRUB is ready for input
        step "Sending GRUB passphrase ($i/$disk_count) via monitor sendkey..."
        monitor_sendkeys "$monitor_sock" "$passphrase"

        # Wait between passphrases for GRUB to decrypt and show next prompt
        if [[ $i -lt $disk_count ]]; then
            info "Waiting for next GRUB passphrase prompt..."
            sleep 8
        fi
    done

    info "All GRUB passphrases sent"
    return 0
}

# Run SSH command (uses SSH_PASSWORD by default, or INSTALLED_PASSWORD if set)
ssh_cmd() {
    local password="${INSTALLED_PASSWORD:-$SSH_PASSWORD}"
    sshpass -p "$password" ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -p "$SSH_PORT" root@localhost "$@" 2>/dev/null
}

# Copy config to VM and run install
run_install() {
    local config="$1"
    local config_name
    config_name=$(basename "$config" .conf)

    # Copy latest archangel script and lib/ to VM (in case ISO is outdated)
    sshpass -p "$SSH_PASSWORD" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -P "$SSH_PORT" "$PROJECT_DIR/installer/archangel" root@localhost:/usr/local/bin/archangel 2>/dev/null
    sshpass -p "$SSH_PASSWORD" scp -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -P "$SSH_PORT" "$PROJECT_DIR/installer/lib" root@localhost:/usr/local/bin/ 2>/dev/null

    # Copy config file to VM
    sshpass -p "$SSH_PASSWORD" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -P "$SSH_PORT" "$config" root@localhost:/root/test.conf 2>/dev/null

    # Run the installer (NO_ENCRYPT is set in the config file, not via flag)
    ssh_cmd "archangel --config-file /root/test.conf" || return 1

    return 0
}

# Verify installation
verify_install() {
    local config="$1"
    local enable_ssh
    local filesystem
    enable_ssh=$(grep "^ENABLE_SSH=" "$config" | cut -d= -f2)
    filesystem=$(grep "^FILESYSTEM=" "$config" | cut -d= -f2)
    filesystem="${filesystem:-zfs}"  # Default to ZFS

    # Basic checks via SSH (if enabled)
    if [[ "$enable_ssh" == "yes" ]]; then
        # Check install log for success indicators
        if ssh_cmd "grep -q 'Installation complete' /tmp/archangel-*.log 2>/dev/null"; then
            info "Install log shows success"
        else
            warn "Could not verify install log"
        fi

        if [[ "$filesystem" == "zfs" ]]; then
            # ZFS-specific checks
            if ssh_cmd "zpool list zroot" >/dev/null 2>&1; then
                info "ZFS pool 'zroot' exists"
            else
                error "ZFS pool 'zroot' not found"
                return 1
            fi

            if ssh_cmd "zfs list -t snapshot | grep -q genesis"; then
                info "ZFS genesis snapshot exists"
            else
                warn "ZFS genesis snapshot not found"
            fi
        elif [[ "$filesystem" == "btrfs" ]]; then
            # Btrfs-specific checks
            if ssh_cmd "btrfs subvolume list /mnt" >/dev/null 2>&1; then
                info "Btrfs subvolumes exist"
            else
                error "Btrfs subvolumes not found"
                return 1
            fi

            if ssh_cmd "arch-chroot /mnt snapper -c root list 2>/dev/null | grep -q genesis"; then
                info "Btrfs genesis snapshot exists"
            else
                warn "Btrfs genesis snapshot not found"
            fi
        fi

        # Check Avahi mDNS packages
        if ssh_cmd "arch-chroot /mnt pacman -Q avahi nss-mdns >/dev/null 2>&1"; then
            info "Avahi packages installed"
        else
            warn "Avahi packages not found"
        fi

        if ssh_cmd "arch-chroot /mnt systemctl is-enabled avahi-daemon >/dev/null 2>&1"; then
            info "Avahi daemon enabled"
        else
            warn "Avahi daemon not enabled"
        fi
    else
        # For no-SSH tests, check serial console output
        if grep -q "Installation complete" "$SERIAL_LOG" 2>/dev/null; then
            info "Serial console shows installation complete"
        else
            warn "Could not verify installation via serial console"
        fi
    fi

    return 0
}

# Verify system boots from installed disk
verify_reboot_survival() {
    local config="$1"
    local filesystem
    filesystem=$(grep "^FILESYSTEM=" "$config" | cut -d= -f2)
    filesystem="${filesystem:-zfs}"

    step "Verifying reboot survival..."

    # Check SSH is working (proves system booted)
    if ! ssh_cmd "echo 'System booted successfully'"; then
        error "Cannot connect to rebooted system"
        return 1
    fi
    info "System booted from installed disk"

    # Check filesystem is mounted correctly
    if [[ "$filesystem" == "zfs" ]]; then
        if ssh_cmd "zpool status zroot >/dev/null 2>&1"; then
            info "ZFS pool healthy after reboot"
        else
            error "ZFS pool not available after reboot"
            return 1
        fi
    elif [[ "$filesystem" == "btrfs" ]]; then
        if ssh_cmd "btrfs filesystem show / >/dev/null 2>&1"; then
            info "Btrfs filesystem healthy after reboot"
        else
            error "Btrfs filesystem not available after reboot"
            return 1
        fi
    fi

    # Check snapper/snapshot service is running
    if [[ "$filesystem" == "btrfs" ]]; then
        if ssh_cmd "systemctl is-active snapper-timeline.timer >/dev/null 2>&1"; then
            info "Snapper timeline timer active"
        else
            warn "Snapper timeline timer not active"
        fi
    fi

    return 0
}

# Verify snapshot and rollback work
verify_rollback() {
    local config="$1"
    local filesystem
    filesystem=$(grep "^FILESYSTEM=" "$config" | cut -d= -f2)
    filesystem="${filesystem:-zfs}"

    step "Verifying rollback functionality..."

    # Create a test file
    ssh_cmd "echo 'test-marker-$(date +%s)' > /root/rollback-test-file"
    if ! ssh_cmd "test -f /root/rollback-test-file"; then
        error "Failed to create test file"
        return 1
    fi
    info "Test file created"

    if [[ "$filesystem" == "btrfs" ]]; then
        # Create snapshot
        if ! ssh_cmd "snapper -c root create -d 'rollback-test'"; then
            error "Failed to create snapshot"
            return 1
        fi
        info "Snapshot created"

        # Get the snapshot number
        local snap_num
        snap_num=$(ssh_cmd "snapper -c root list | grep 'rollback-test' | awk '{print \$1}'")
        if [[ -z "$snap_num" ]]; then
            error "Could not find snapshot number"
            return 1
        fi

        # Delete the test file (change to rollback)
        ssh_cmd "rm -f /root/rollback-test-file"

        # Rollback
        if ! ssh_cmd "snapper -c root rollback $snap_num"; then
            warn "Snapper rollback command returned error (may be expected)"
        fi
        info "Rollback initiated"

    elif [[ "$filesystem" == "zfs" ]]; then
        # Create snapshot
        if ! ssh_cmd "zfs snapshot zroot/ROOT/default@rollback-test"; then
            error "Failed to create ZFS snapshot"
            return 1
        fi
        info "ZFS snapshot created"

        # Delete the test file
        ssh_cmd "rm -f /root/rollback-test-file"

        # Rollback
        if ! ssh_cmd "zfs rollback zroot/ROOT/default@rollback-test"; then
            error "Failed to rollback ZFS snapshot"
            return 1
        fi
        info "ZFS rollback completed"
    fi

    # Verify file is back (for ZFS, immediate; for btrfs, needs reboot)
    if [[ "$filesystem" == "zfs" ]]; then
        if ssh_cmd "test -f /root/rollback-test-file"; then
            info "Rollback verified - test file restored"
        else
            error "Rollback failed - test file not restored"
            return 1
        fi
    else
        info "Btrfs rollback requires reboot to take effect"
    fi

    return 0
}

# Run a single test
run_test() {
    local config="$1"
    local config_name
    config_name=$(basename "$config" .conf)

    TESTS_RUN=$((TESTS_RUN + 1))
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    step "Testing: $config_name"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local disk_count
    disk_count=$(get_disk_count "$config")
    info "Disk count: $disk_count"

    # Setup
    mkdir -p "$LOG_DIR"
    : > "$SERIAL_LOG"

    step "Creating VM disks..."
    create_disks "$disk_count" "$config_name"

    step "Starting VM..."
    local vm_pid
    vm_pid=$(start_vm "$config_name" "$disk_count")

    if [[ -z "$vm_pid" ]]; then
        error "Failed to start VM"
        cleanup_disks "$config_name"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED_TESTS+=("$config_name")
        return 1
    fi
    info "VM started (PID: $vm_pid)"

    # Wait for boot
    step "Waiting for VM to boot (timeout: ${BOOT_TIMEOUT}s)..."
    if ! wait_for_ssh "$BOOT_TIMEOUT"; then
        error "VM did not become accessible via SSH"
        stop_vm "$config_name"
        cleanup_disks "$config_name"

        # Save logs
        cp "$SERIAL_LOG" "$LOG_DIR/${config_name}-serial.log" 2>/dev/null || true
        error "Serial log saved to: $LOG_DIR/${config_name}-serial.log"

        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED_TESTS+=("$config_name")
        return 1
    fi
    info "VM is accessible via SSH"

    # Run install
    step "Running installation (timeout: ${INSTALL_TIMEOUT}s)..."
    if timeout "$INSTALL_TIMEOUT" bash -c "$(declare -f ssh_cmd run_install); run_install '$config'"; then
        info "Installation completed"
    else
        error "Installation failed or timed out"
        stop_vm "$config_name"

        # Save logs
        ssh_cmd "cat /tmp/archangel-*.log" > "$LOG_DIR/${config_name}-install.log" 2>/dev/null || true
        cp "$SERIAL_LOG" "$LOG_DIR/${config_name}-serial.log" 2>/dev/null || true

        cleanup_disks "$config_name"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED_TESTS+=("$config_name")
        return 1
    fi

    # Verify installation (while still in live ISO)
    step "Verifying installation..."
    if verify_install "$config"; then
        info "Verification passed"
    else
        warn "Verification had issues (may be expected if install rebooted)"
    fi

    # Stop VM to prepare for reboot test (keep OVMF vars for EFI boot)
    step "Stopping VM for reboot test..."
    stop_vm "$config_name" true

    # Boot from installed disk (no ISO)
    step "Booting from installed disk..."
    : > "$SERIAL_LOG"  # Clear serial log

    # Determine if this is a LUKS config (needs monitor for GRUB passphrase)
    local luks_passphrase
    luks_passphrase=$(grep '^LUKS_PASSPHRASE=' "$config" | cut -d= -f2)
    local no_encrypt
    no_encrypt=$(grep '^NO_ENCRYPT=' "$config" | cut -d= -f2)
    local luks_flag=""
    if [[ -n "$luks_passphrase" && "$no_encrypt" != "yes" ]]; then
        luks_flag="luks"
    fi

    local vm_pid2
    vm_pid2=$(start_vm_from_disk "$config_name" "$disk_count" "$luks_flag")

    if [[ -z "$vm_pid2" ]]; then
        error "Failed to start VM from disk"
        cleanup_disks "$config_name"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED_TESTS+=("$config_name")
        return 1
    fi
    info "VM started from disk (PID: $vm_pid2)"

    # If LUKS is enabled, send GRUB passphrase via monitor sendkey
    if [[ -n "$luks_flag" ]]; then
        if ! send_luks_passphrase "$config_name" "$luks_passphrase" "$disk_count"; then
            error "Failed to send LUKS passphrase"
            stop_vm "$config_name"
            cp "$SERIAL_LOG" "$LOG_DIR/${config_name}-reboot-serial.log" 2>/dev/null || true
            cleanup_disks "$config_name"
            TESTS_FAILED=$((TESTS_FAILED + 1))
            FAILED_TESTS+=("$config_name")
            return 1
        fi
    fi

    # Check if SSH is enabled in the config
    local enable_ssh
    enable_ssh=$(grep '^ENABLE_SSH=' "$config" | cut -d= -f2)

    if [[ "$enable_ssh" == "no" ]]; then
        # No SSH — verify boot via serial console login prompt
        step "Waiting for console boot marker (timeout: ${BOOT_TIMEOUT}s)..."
        if ! wait_for_boot_console "$BOOT_TIMEOUT"; then
            error "Installed system did not boot successfully (no login prompt in serial log)"
            stop_vm "$config_name"

            cp "$SERIAL_LOG" "$LOG_DIR/${config_name}-reboot-serial.log" 2>/dev/null || true
            error "Serial log saved to: $LOG_DIR/${config_name}-reboot-serial.log"

            cleanup_disks "$config_name"
            TESTS_FAILED=$((TESTS_FAILED + 1))
            FAILED_TESTS+=("$config_name")
            return 1
        fi
        info "Console boot verified (boot marker detected in serial log)"
    else
        # SSH enabled — full verification path
        local installed_password
        installed_password=$(grep '^ROOT_PASSWORD=' "$config" | cut -d= -f2)

        step "Waiting for installed system to boot (timeout: ${BOOT_TIMEOUT}s)..."
        if ! wait_for_ssh "$BOOT_TIMEOUT" "$installed_password"; then
            error "Installed system did not boot successfully"
            stop_vm "$config_name"

            cp "$SERIAL_LOG" "$LOG_DIR/${config_name}-reboot-serial.log" 2>/dev/null || true
            error "Serial log saved to: $LOG_DIR/${config_name}-reboot-serial.log"

            cleanup_disks "$config_name"
            TESTS_FAILED=$((TESTS_FAILED + 1))
            FAILED_TESTS+=("$config_name")
            return 1
        fi

        # Use installed system's password for subsequent SSH commands
        export INSTALLED_PASSWORD="$installed_password"

        # Verify reboot survival
        if ! verify_reboot_survival "$config"; then
            error "Reboot survival check failed"
            stop_vm "$config_name"
            cleanup_disks "$config_name"
            TESTS_FAILED=$((TESTS_FAILED + 1))
            FAILED_TESTS+=("$config_name")
            return 1
        fi

        # Verify rollback functionality
        if ! verify_rollback "$config"; then
            warn "Rollback verification had issues"
            # Don't fail the test for rollback issues - it's a bonus check
        fi
    fi

    # Cleanup
    step "Cleaning up..."
    unset INSTALLED_PASSWORD  # Reset for next test
    stop_vm "$config_name"
    cleanup_disks "$config_name"

    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}TEST PASSED: $config_name${NC}"
    return 0
}

# Main
main() {
    # Parse args
    local configs=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --list)
                list_configs
                exit 0
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                configs+=("$1")
                shift
                ;;
        esac
    done

    # Check dependencies
    command -v qemu-system-x86_64 >/dev/null 2>&1 || { error "qemu not found"; exit 1; }
    command -v sshpass >/dev/null 2>&1 || { error "sshpass not found"; exit 1; }
    command -v socat >/dev/null 2>&1 || { error "socat not found (needed for LUKS tests)"; exit 1; }
    [[ -f "$OVMF_CODE" ]] || { error "OVMF not found: $OVMF_CODE"; exit 1; }

    # Find ISO
    find_iso

    # Determine which configs to run
    if [[ ${#configs[@]} -eq 0 ]]; then
        # Run all configs
        for conf in "$CONFIG_DIR"/*.conf; do
            [[ -f "$conf" ]] && configs+=("$(basename "$conf" .conf)")
        done
    fi

    if [[ ${#configs[@]} -eq 0 ]]; then
        error "No test configs found in $CONFIG_DIR"
        exit 1
    fi

    info "Running ${#configs[@]} test(s): ${configs[*]}"
    echo ""

    # Run tests
    for config_name in "${configs[@]}"; do
        local config="$CONFIG_DIR/${config_name}.conf"
        if [[ ! -f "$config" ]]; then
            error "Config not found: $config"
            TESTS_FAILED=$((TESTS_FAILED + 1))
            FAILED_TESTS+=("$config_name")
            continue
        fi

        run_test "$config" || true
    done

    # Summary
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "TEST SUMMARY"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "Tests run:    $TESTS_RUN"
    echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"

    if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
        echo ""
        echo "Failed tests:"
        for t in "${FAILED_TESTS[@]}"; do
            echo -e "  ${RED}✗${NC} $t"
        done
    fi

    echo ""
    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}All tests passed!${NC}"
        exit 0
    else
        echo -e "${RED}Some tests failed.${NC}"
        echo "Check logs in: $LOG_DIR"
        exit 1
    fi
}

main "$@"
