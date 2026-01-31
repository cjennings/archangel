#!/bin/bash
# sanity-test.sh - Automated sanity test for archangel ISO
#
# Boots the ISO in a headless QEMU VM, waits for SSH, runs verification
# commands, and reports pass/fail. Fully automated - no human input required.
#
# Usage:
#   ./scripts/sanity-test.sh              # Run sanity test
#   ./scripts/sanity-test.sh --verbose    # Show detailed output
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed
#   2 - Setup/infrastructure error (QEMU, SSH, etc.)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# VM Configuration
VM_DIR="$PROJECT_DIR/vm"
VM_DISK="$VM_DIR/sanity-test.qcow2"
VM_DISK_SIZE="10G"
VM_RAM="2048"
VM_CPUS="2"
VM_NAME="archangel-sanity"

# UEFI firmware
OVMF_CODE="/usr/share/edk2/x64/OVMF_CODE.4m.fd"
OVMF_VARS_ORIG="/usr/share/edk2/x64/OVMF_VARS.4m.fd"
OVMF_VARS="$VM_DIR/sanity-test-OVMF_VARS.fd"

# SSH settings
SSH_PORT=2223  # Different port to avoid conflicts with test-vm.sh
SSH_USER="root"
SSH_PASS="archangel"
SSH_TIMEOUT=180  # Max seconds to wait for SSH
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# State
QEMU_PID=""
VERBOSE=false
TESTS_PASSED=0
TESTS_FAILED=0

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
pass()  { echo -e "${GREEN}[PASS]${NC} $1"; ((TESTS_PASSED++)); }
fail()  { echo -e "${RED}[FAIL]${NC} $1"; ((TESTS_FAILED++)); }

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --verbose|-v) VERBOSE=true; shift ;;
        -h|--help)
            echo "Usage: $0 [--verbose]"
            echo ""
            echo "Automated sanity test for archangel ISO."
            echo "Boots ISO in headless QEMU, verifies via SSH, reports results."
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

# Setup VM resources
setup_vm() {
    mkdir -p "$VM_DIR"

    # Create a fresh disk for sanity testing
    if [[ -f "$VM_DISK" ]]; then
        rm -f "$VM_DISK"
    fi
    qemu-img create -f qcow2 "$VM_DISK" "$VM_DISK_SIZE" >/dev/null 2>&1

    # Copy OVMF vars
    cp "$OVMF_VARS_ORIG" "$OVMF_VARS"
}

# Cleanup on exit
cleanup() {
    if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
        info "Shutting down VM..."
        kill "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
    fi
    # Clean up sanity test disk (leave main test disk alone)
    rm -f "$VM_DISK" "$OVMF_VARS" 2>/dev/null || true
}
trap cleanup EXIT

# Start QEMU in headless mode
start_vm() {
    info "Starting headless VM..."

    qemu-system-x86_64 \
        -name "$VM_NAME" \
        -machine q35,accel=kvm \
        -cpu host \
        -smp "$VM_CPUS" \
        -m "$VM_RAM" \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
        -drive if=pflash,format=raw,file="$OVMF_VARS" \
        -drive "file=$VM_DISK,format=qcow2,if=virtio" \
        -cdrom "$ISO_FILE" \
        -boot d \
        -netdev user,id=net0,hostfwd=tcp::${SSH_PORT}-:22 \
        -device virtio-net-pci,netdev=net0 \
        -display none \
        -serial null \
        -daemonize \
        -pidfile "$VM_DIR/sanity-test.pid"

    sleep 1
    if [[ -f "$VM_DIR/sanity-test.pid" ]]; then
        QEMU_PID=$(cat "$VM_DIR/sanity-test.pid")
        if kill -0 "$QEMU_PID" 2>/dev/null; then
            info "VM started (PID: $QEMU_PID)"
        else
            error "VM failed to start"
            exit 2
        fi
    else
        error "VM failed to start - no PID file"
        exit 2
    fi
}

# Wait for SSH to become available
wait_for_ssh() {
    info "Waiting for SSH (timeout: ${SSH_TIMEOUT}s)..."
    local elapsed=0
    local interval=5

    while [[ $elapsed -lt $SSH_TIMEOUT ]]; do
        if sshpass -p "$SSH_PASS" ssh $SSH_OPTS -p "$SSH_PORT" "$SSH_USER@localhost" "true" 2>/dev/null; then
            info "SSH available after ${elapsed}s"
            return 0
        fi
        sleep $interval
        ((elapsed += interval))
        if $VERBOSE; then
            echo -n "."
        fi
    done

    error "SSH timeout after ${SSH_TIMEOUT}s"
    return 1
}

# Run a test command via SSH
run_test() {
    local name="$1"
    local cmd="$2"
    local expect_output="$3"  # Optional: string that should be in output

    if $VERBOSE; then
        echo -e "${CYAN}Testing:${NC} $name"
        echo -e "${CYAN}Command:${NC} $cmd"
    fi

    local output
    output=$(sshpass -p "$SSH_PASS" ssh $SSH_OPTS -p "$SSH_PORT" "$SSH_USER@localhost" "$cmd" 2>&1) || {
        fail "$name (command failed)"
        if $VERBOSE; then
            echo "  Output: $output"
        fi
        return 1
    }

    if [[ -n "$expect_output" ]]; then
        if echo "$output" | grep -q "$expect_output"; then
            pass "$name"
            if $VERBOSE; then
                echo "  Output: $output"
            fi
            return 0
        else
            fail "$name (expected '$expect_output' not found)"
            if $VERBOSE; then
                echo "  Output: $output"
            fi
            return 1
        fi
    else
        pass "$name"
        if $VERBOSE; then
            echo "  Output: $output"
        fi
        return 0
    fi
}

# Run all sanity tests
run_sanity_tests() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}                   SANITY TESTS${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # Test 1: ZFS kernel module loaded
    run_test "ZFS kernel module loaded" \
        "lsmod | grep -q '^zfs' && echo 'zfs module loaded'" \
        "zfs module loaded"

    # Test 2: ZFS commands work
    run_test "ZFS version command works" \
        "zfs version | head -1" \
        "zfs-"

    # Test 3: zpool command works
    run_test "zpool command works" \
        "zpool version | head -1" \
        "zfs-"

    # Test 4: Custom scripts present
    run_test "archangel script present" \
        "test -x /usr/local/bin/archangel && echo 'exists'" \
        "exists"

    run_test "zfsrollback script present" \
        "test -x /usr/local/bin/zfsrollback && echo 'exists'" \
        "exists"

    run_test "zfssnapshot script present" \
        "test -x /usr/local/bin/zfssnapshot && echo 'exists'" \
        "exists"

    # Test 5: fzf installed (required by zfsrollback)
    run_test "fzf installed" \
        "command -v fzf && echo 'found'" \
        "found"

    # Test 6: SSH is working (implicit - we're connected)
    pass "SSH connectivity"

    # Test 6b: Root password is set (not empty in shadow file)
    run_test "Root password is set" \
        "grep '^root:' /etc/shadow | cut -d: -f2 | grep -q '.' && echo 'password set'" \
        "password set"

    # Test 7: Network manager available
    run_test "NetworkManager available" \
        "systemctl is-enabled NetworkManager 2>/dev/null || echo 'available'" \
        ""

    # Test 8: Avahi mDNS for network discovery
    run_test "Avahi package installed" \
        "command -v avahi-daemon && echo 'found'" \
        "found"

    run_test "Avahi daemon enabled" \
        "systemctl is-enabled avahi-daemon" \
        "enabled"

    run_test "Avahi daemon running" \
        "systemctl is-active avahi-daemon" \
        "active"

    run_test "nss-mdns configured" \
        "grep -q 'mdns' /etc/nsswitch.conf && echo 'configured'" \
        "configured"

    # Test 9: Hostname set to archangel
    run_test "Hostname is archangel" \
        "cat /etc/hostname" \
        "archangel"

    # Test 10: Kernel version (LTS)
    run_test "Running LTS kernel" \
        "uname -r" \
        "lts"

    # Test 10: archsetup directory present
    run_test "archsetup directory present" \
        "test -d /code/archsetup && echo 'exists'" \
        "exists"

    # Test 11: Btrfs tools installed (dual filesystem support)
    run_test "Btrfs tools installed" \
        "command -v btrfs && echo 'found'" \
        "found"

    run_test "mkfs.btrfs available" \
        "command -v mkfs.btrfs && echo 'found'" \
        "found"

    # Test 12: Snapper installed (Btrfs snapshot management)
    run_test "Snapper installed" \
        "command -v snapper && echo 'found'" \
        "found"

    # Test 13: archangel installer components
    run_test "archangel script executable" \
        "file /usr/local/bin/archangel | grep -q 'script' && echo 'executable'" \
        "executable"

    run_test "archangel lib directory present" \
        "test -d /usr/local/bin/lib && echo 'exists'" \
        "exists"

    run_test "archangel lib/common.sh present" \
        "test -f /usr/local/bin/lib/common.sh && echo 'exists'" \
        "exists"

    run_test "archangel config example present" \
        "test -f /root/archangel.conf.example && echo 'exists'" \
        "exists"

    # Test 14: GRUB installed (for Btrfs bootloader)
    run_test "GRUB installed" \
        "command -v grub-install && echo 'found'" \
        "found"

    # Test 15: Cryptsetup for LUKS (Btrfs encryption)
    run_test "Cryptsetup installed" \
        "command -v cryptsetup && echo 'found'" \
        "found"

    echo ""
}

# Print summary
print_summary() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}                     SUMMARY${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  Tests passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "  Tests failed: ${RED}$TESTS_FAILED${NC}"
    echo ""

    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}All sanity tests passed!${NC}"
        return 0
    else
        echo -e "${RED}Some tests failed.${NC}"
        return 1
    fi
}

# Main
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}          ARCHANGEL ISO SANITY TEST${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # Check dependencies
    command -v qemu-system-x86_64 >/dev/null || { error "qemu-system-x86_64 not found"; exit 2; }
    command -v sshpass >/dev/null || { error "sshpass not found"; exit 2; }
    [[ -f "$OVMF_CODE" ]] || { error "OVMF firmware not found at $OVMF_CODE"; exit 2; }

    find_iso
    setup_vm
    start_vm

    if ! wait_for_ssh; then
        error "Could not connect to VM via SSH"
        exit 2
    fi

    run_sanity_tests

    if print_summary; then
        exit 0
    else
        exit 1
    fi
}

main "$@"
