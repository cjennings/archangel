#!/usr/bin/env bash
# full-test.sh - Comprehensive installation testing for archangel ISO
#
# Runs automated installation tests for all disk configurations:
#   - Single disk
#   - Mirror (2 disks)
#   - RAIDZ1 (3 disks)
#
# Each test:
#   1. Boots ISO in headless QEMU
#   2. Runs unattended archangel
#   3. Reboots into installed system
#   4. Verifies ZFS pool is healthy
#
# Usage:
#   ./scripts/full-test.sh              # Run all install tests
#   ./scripts/full-test.sh --quick      # Single disk only (faster)
#   ./scripts/full-test.sh --verbose    # Show detailed output
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed
#   2 - Setup/infrastructure error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# VM Configuration
VM_DIR="$PROJECT_DIR/vm"
VM_DISK_SIZE="20G"
VM_RAM="4096"
VM_CPUS="4"

# UEFI firmware (override via environment for non-Arch distros)
OVMF_CODE="${OVMF_CODE:-/usr/share/edk2/x64/OVMF_CODE.4m.fd}"
OVMF_VARS_ORIG="${OVMF_VARS_ORIG:-/usr/share/edk2/x64/OVMF_VARS.4m.fd}"

# SSH settings
SSH_PORT=2224  # Different port to avoid conflicts
SSH_USER="root"
SSH_PASS_LIVE="archangel"         # Live ISO password
SSH_PASS_INSTALLED="testroot123"  # Installed system password (from config)
SSH_PASS="$SSH_PASS_LIVE"         # Current password (switches after install)
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5"

# Timeouts
SSH_TIMEOUT=180       # Wait for SSH on live ISO
INSTALL_TIMEOUT=1800  # 30 minutes for installation (DKMS builds ZFS from source)
BOOT_TIMEOUT=120      # Wait for installed system to boot

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# State
QEMU_PID=""
VERBOSE=false
QUICK_MODE=false
ISO_FILE=""
CURRENT_TEST=""
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_TESTS=()

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
pass()  { echo -e "${GREEN}[PASS]${NC} $1"; ((++TESTS_PASSED)); }
fail()  { echo -e "${RED}[FAIL]${NC} $1"; ((TESTS_FAILED++)); FAILED_TESTS+=("$1"); }

banner() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}${BOLD}  $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --verbose|-v) VERBOSE=true; shift ;;
        --quick|-q)   QUICK_MODE=true; shift ;;
        -h|--help)
            echo "Usage: $0 [--quick] [--verbose]"
            echo ""
            echo "Comprehensive installation testing for archangel ISO."
            echo ""
            echo "Options:"
            echo "  --quick, -q     Run single-disk test only (faster)"
            echo "  --verbose, -v   Show detailed output"
            echo ""
            echo "Tests performed:"
            echo "  1. Single disk installation"
            echo "  2. Mirror (2 disks) installation"
            echo "  3. RAIDZ1 (3 disks) installation"
            exit 0
            ;;
        *) error "Unknown option: $1"; exit 2 ;;
    esac
done

# Find the ISO
find_iso() {
    ISO_FILE=$(ls -t "$PROJECT_DIR/out/"*.iso 2>/dev/null | head -1)
    if [[ -z "$ISO_FILE" ]]; then
        error "No ISO found in $PROJECT_DIR/out/"
        exit 2
    fi
    info "Testing ISO: $(basename "$ISO_FILE")"
}

# Check dependencies
check_deps() {
    local missing=()
    command -v qemu-system-x86_64 >/dev/null || missing+=("qemu")
    command -v sshpass >/dev/null || missing+=("sshpass")
    [[ -f "$OVMF_CODE" ]] || missing+=("edk2-ovmf")

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing dependencies: ${missing[*]}"
        exit 2
    fi
}

# Cleanup on exit
cleanup() {
    if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
        $VERBOSE && info "Shutting down VM..."
        kill "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
    fi
    QEMU_PID=""
}
trap cleanup EXIT

# Create VM disks for a test
create_vm_disks() {
    local test_name="$1"
    local num_disks="$2"

    rm -f "$VM_DIR/fulltest-"*.qcow2 "$VM_DIR/fulltest-OVMF_VARS.fd" 2>/dev/null

    for i in $(seq 1 "$num_disks"); do
        local disk="$VM_DIR/fulltest-disk${i}.qcow2"
        qemu-img create -f qcow2 "$disk" "$VM_DISK_SIZE" >/dev/null 2>&1
        $VERBOSE && info "Created disk: $disk"
    done

    cp "$OVMF_VARS_ORIG" "$VM_DIR/fulltest-OVMF_VARS.fd"
}

# Start VM booting from ISO
start_vm_iso() {
    local num_disks="$1"

    # Build disk arguments
    local disk_args=""
    for i in $(seq 1 "$num_disks"); do
        disk_args+=" -drive file=$VM_DIR/fulltest-disk${i}.qcow2,format=qcow2,if=virtio"
    done

    qemu-system-x86_64 \
        -name "archangel-fulltest" \
        -machine q35,accel=kvm \
        -cpu host \
        -smp "$VM_CPUS" \
        -m "$VM_RAM" \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
        -drive if=pflash,format=raw,file="$VM_DIR/fulltest-OVMF_VARS.fd" \
        $disk_args \
        -cdrom "$ISO_FILE" \
        -boot d \
        -netdev user,id=net0,hostfwd=tcp::${SSH_PORT}-:22 \
        -device virtio-net-pci,netdev=net0 \
        -display none \
        -serial null \
        -daemonize \
        -pidfile "$VM_DIR/fulltest.pid"

    sleep 1
    if [[ -f "$VM_DIR/fulltest.pid" ]]; then
        QEMU_PID=$(cat "$VM_DIR/fulltest.pid")
        if kill -0 "$QEMU_PID" 2>/dev/null; then
            $VERBOSE && info "VM started (PID: $QEMU_PID)"
            return 0
        fi
    fi
    error "VM failed to start"
    return 1
}

# Start VM booting from installed disk
start_vm_disk() {
    local num_disks="$1"

    # Build disk arguments
    local disk_args=""
    for i in $(seq 1 "$num_disks"); do
        disk_args+=" -drive file=$VM_DIR/fulltest-disk${i}.qcow2,format=qcow2,if=virtio"
    done

    qemu-system-x86_64 \
        -name "archangel-fulltest" \
        -machine q35,accel=kvm \
        -cpu host \
        -smp "$VM_CPUS" \
        -m "$VM_RAM" \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
        -drive if=pflash,format=raw,file="$VM_DIR/fulltest-OVMF_VARS.fd" \
        $disk_args \
        -boot c \
        -netdev user,id=net0,hostfwd=tcp::${SSH_PORT}-:22 \
        -device virtio-net-pci,netdev=net0 \
        -display none \
        -serial null \
        -daemonize \
        -pidfile "$VM_DIR/fulltest.pid"

    sleep 1
    if [[ -f "$VM_DIR/fulltest.pid" ]]; then
        QEMU_PID=$(cat "$VM_DIR/fulltest.pid")
        if kill -0 "$QEMU_PID" 2>/dev/null; then
            $VERBOSE && info "VM started from disk (PID: $QEMU_PID)"
            return 0
        fi
    fi
    error "VM failed to start from disk"
    return 1
}

# Wait for SSH to become available
wait_for_ssh() {
    local timeout="$1"
    local elapsed=0
    local interval=5

    $VERBOSE && info "Waiting for SSH (timeout: ${timeout}s)..."

    while [[ $elapsed -lt $timeout ]]; do
        if sshpass -p "$SSH_PASS" ssh $SSH_OPTS -p "$SSH_PORT" "$SSH_USER@localhost" "true" 2>/dev/null; then
            $VERBOSE && info "SSH available after ${elapsed}s"
            return 0
        fi
        sleep $interval
        ((elapsed += interval))
        $VERBOSE && echo -n "."
    done

    $VERBOSE && echo ""
    return 1
}

# Run command via SSH
ssh_cmd() {
    sshpass -p "$SSH_PASS" ssh $SSH_OPTS -p "$SSH_PORT" "$SSH_USER@localhost" "$@" 2>&1
}

# Generate install config for a test
generate_config() {
    local num_disks="$1"
    local raid_level="$2"

    # Build disk list
    local disks=""
    for i in $(seq 1 "$num_disks"); do
        [[ -n "$disks" ]] && disks+=","
        disks+="/dev/vda"
        # vda, vdb, vdc for virtio disks
        local letter=$(printf "\\x$(printf '%02x' $((96 + i)))")
        disks="/dev/vd${letter}"
        if [[ $i -eq 1 ]]; then
            disks="/dev/vda"
        elif [[ $i -eq 2 ]]; then
            disks="/dev/vda,/dev/vdb"
        elif [[ $i -eq 3 ]]; then
            disks="/dev/vda,/dev/vdb,/dev/vdc"
        fi
    done

    cat << EOF
# Unattended install config for testing
HOSTNAME=fulltest-vm
TIMEZONE=America/Chicago
LOCALE=en_US.UTF-8
KEYMAP=us
ROOT_PASSWORD=testroot123
ZFS_PASSPHRASE=testpass123
NO_ENCRYPT=yes
ENABLE_SSH=yes
DISKS=$disks
RAID_LEVEL=$raid_level
EOF
}

# Run a single installation test
run_install_test() {
    local test_name="$1"
    local num_disks="$2"
    local raid_level="$3"

    CURRENT_TEST="$test_name"
    banner "INSTALL TEST: $test_name"

    info "Configuration: $num_disks disk(s), RAID: ${raid_level:-none}"

    # Reset SSH password to live ISO password
    SSH_PASS="$SSH_PASS_LIVE"

    # Create fresh disks
    info "Creating VM disks..."
    create_vm_disks "$test_name" "$num_disks"

    # Start VM from ISO
    info "Booting from ISO..."
    if ! start_vm_iso "$num_disks"; then
        fail "$test_name: VM failed to start"
        return 1
    fi

    # Wait for SSH
    info "Waiting for live environment..."
    if ! wait_for_ssh "$SSH_TIMEOUT"; then
        fail "$test_name: SSH timeout on live ISO"
        cleanup
        return 1
    fi

    # Create config file on VM
    info "Creating install configuration..."
    local config=$(generate_config "$num_disks" "$raid_level")
    ssh_cmd "cat > /tmp/install.conf << 'CONF'
$config
CONF"

    # Run installation
    info "Running archangel (this takes several minutes)..."
    local install_start=$(date +%s)

    # Run install in background and monitor
    ssh_cmd "nohup archangel --config-file /tmp/install.conf > /tmp/install.log 2>&1 &"

    # Wait for installation to complete
    local elapsed=0
    local check_interval=15
    while [[ $elapsed -lt $INSTALL_TIMEOUT ]]; do
        sleep $check_interval
        ((elapsed += check_interval))

        # Check if install process is still running
        # Match full path to avoid false positive from avahi-daemon's
        # "running [archangel.local]" status string
        if ! ssh_cmd "pgrep -f '/usr/local/bin/archangel' > /dev/null" 2>/dev/null; then
            # Process finished - check result by looking for success indicators
            local exit_check=$(ssh_cmd "tail -30 /tmp/install.log" 2>/dev/null)
            # Check for various success indicators
            if echo "$exit_check" | grep -qE "(Installation Complete|Pool status:|Genesis snapshot)"; then
                local install_end=$(date +%s)
                local install_time=$((install_end - install_start))
                info "Installation completed in ${install_time}s"
                break
            else
                warn "Install process ended unexpectedly"
                if $VERBOSE; then
                    echo "Last lines of install log:"
                    ssh_cmd "tail -20 /tmp/install.log" 2>/dev/null || true
                fi
                fail "$test_name: Installation failed"
                cleanup
                return 1
            fi
        fi

        $VERBOSE && info "Still installing... (${elapsed}s elapsed)"
    done

    if [[ $elapsed -ge $INSTALL_TIMEOUT ]]; then
        fail "$test_name: Installation timeout"
        cleanup
        return 1
    fi

    # Shutdown VM
    info "Shutting down live environment..."
    ssh_cmd "poweroff" 2>/dev/null || true
    sleep 5
    cleanup

    # Switch to installed system password
    SSH_PASS="$SSH_PASS_INSTALLED"

    # Boot from installed disk
    info "Booting installed system..."
    if ! start_vm_disk "$num_disks"; then
        fail "$test_name: Failed to boot installed system"
        return 1
    fi

    # Wait for installed system to come up
    info "Waiting for installed system..."
    if ! wait_for_ssh "$BOOT_TIMEOUT"; then
        fail "$test_name: Installed system failed to boot (SSH timeout)"
        cleanup
        return 1
    fi

    # Verify installation
    info "Verifying installation..."

    # Check ZFS pool status
    local pool_status=$(ssh_cmd "zpool status -x zroot" 2>/dev/null)
    if [[ "$pool_status" != *"healthy"* && "$pool_status" != *"all pools are healthy"* ]]; then
        warn "Pool status: $pool_status"
        fail "$test_name: ZFS pool not healthy"
        cleanup
        return 1
    fi
    $VERBOSE && info "ZFS pool is healthy"

    # Check pool configuration matches expected RAID
    local pool_config=$(ssh_cmd "zpool status zroot" 2>/dev/null)
    if [[ -n "$raid_level" ]]; then
        if ! echo "$pool_config" | grep -q "$raid_level"; then
            warn "Expected RAID level '$raid_level' not found in pool config"
            $VERBOSE && echo "$pool_config"
        fi
    fi

    # Check root dataset is mounted
    local root_mount=$(ssh_cmd "zfs get -H -o value mounted zroot/ROOT/default" 2>/dev/null)
    if [[ "$root_mount" != "yes" ]]; then
        fail "$test_name: Root dataset not mounted"
        cleanup
        return 1
    fi
    $VERBOSE && info "Root dataset mounted"

    # Check genesis snapshot exists
    local genesis=$(ssh_cmd "zfs list -t snapshot zroot@genesis" 2>/dev/null)
    if [[ -z "$genesis" ]]; then
        fail "$test_name: Genesis snapshot missing"
        cleanup
        return 1
    fi
    $VERBOSE && info "Genesis snapshot exists"

    # Check zfs-import-scan is enabled (our preferred import method - no cachefile needed)
    local import_scan=$(ssh_cmd "systemctl is-enabled zfs-import-scan" 2>/dev/null)
    if [[ "$import_scan" != "enabled" ]]; then
        warn "$test_name: zfs-import-scan not enabled (was: '$import_scan')"
    fi
    $VERBOSE && info "zfs-import-scan service: $import_scan"

    # Check kernel
    local kernel=$(ssh_cmd "uname -r" 2>/dev/null)
    if [[ "$kernel" != *"lts"* ]]; then
        warn "Kernel is not LTS: $kernel"
    fi
    $VERBOSE && info "Kernel: $kernel"

    # Reboot test - verify system comes back up cleanly
    info "Testing reboot..."
    ssh_cmd "reboot" 2>/dev/null || true

    # Wait for SSH to go down (system is rebooting)
    local down_timeout=30
    local down_start=$(date +%s)
    while ssh_cmd "echo up" &>/dev/null; do
        sleep 1
        local elapsed=$(($(date +%s) - down_start))
        if [[ $elapsed -gt $down_timeout ]]; then
            warn "System didn't go down for reboot within ${down_timeout}s"
            break
        fi
    done
    $VERBOSE && info "System went down for reboot"

    # Wait for SSH to come back up
    local reboot_timeout=120
    local reboot_start=$(date +%s)
    while ! ssh_cmd "echo up" &>/dev/null; do
        sleep 2
        local elapsed=$(($(date +%s) - reboot_start))
        if [[ $elapsed -gt $reboot_timeout ]]; then
            fail "$test_name: System failed to come back after reboot (timeout ${reboot_timeout}s)"
            cleanup
            return 1
        fi
        $VERBOSE && printf "."
    done
    $VERBOSE && echo ""
    local reboot_elapsed=$(($(date +%s) - reboot_start))
    info "System rebooted successfully (${reboot_elapsed}s)"

    # Verify ZFS pool is healthy after reboot
    local post_reboot_status=$(ssh_cmd "zpool status -x zroot" 2>/dev/null)
    if [[ "$post_reboot_status" != *"healthy"* && "$post_reboot_status" != *"all pools are healthy"* ]]; then
        fail "$test_name: ZFS pool not healthy after reboot: $post_reboot_status"
        cleanup
        return 1
    fi
    $VERBOSE && info "ZFS pool healthy after reboot"

    # Shutdown
    ssh_cmd "poweroff" 2>/dev/null || true
    sleep 3
    cleanup

    pass "$test_name"
    return 0
}

# Print summary
print_summary() {
    banner "TEST SUMMARY"

    echo -e "  Tests passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "  Tests failed: ${RED}$TESTS_FAILED${NC}"
    echo ""

    if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
        echo "Failed tests:"
        for test in "${FAILED_TESTS[@]}"; do
            echo -e "  ${RED}-${NC} $test"
        done
        echo ""
    fi

    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}${BOLD}All installation tests passed!${NC}"
        return 0
    else
        echo -e "${RED}${BOLD}Some tests failed.${NC}"
        return 1
    fi
}

# Main
main() {
    banner "ARCHANGEL FULL INSTALLATION TEST"

    check_deps
    find_iso
    mkdir -p "$VM_DIR"

    # Run sanity test first
    info "Running sanity test first..."
    if ! "$SCRIPT_DIR/sanity-test.sh" ${VERBOSE:+--verbose}; then
        error "Sanity test failed - aborting full test"
        exit 1
    fi
    echo ""

    # Run installation tests
    run_install_test "single-disk" 1 ""

    if ! $QUICK_MODE; then
        run_install_test "mirror" 2 "mirror"
        run_install_test "raidz1" 3 "raidz1"
    fi

    # Cleanup test disks
    rm -f "$VM_DIR/fulltest-"*.qcow2 "$VM_DIR/fulltest-OVMF_VARS.fd" "$VM_DIR/fulltest.pid" 2>/dev/null

    print_summary
}

main "$@"
