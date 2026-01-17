#!/bin/bash
# test-vm.sh - Test the archzfs ISO in a QEMU virtual machine
#
# Usage:
#   ./test-vm.sh              # Create new VM and boot ISO
#   ./test-vm.sh --boot-disk  # Boot from existing virtual disk (after install)
#   ./test-vm.sh --clean      # Remove VM disk and start fresh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# VM Configuration
VM_NAME="archzfs-test"
VM_DIR="$PROJECT_DIR/vm"
VM_DISK="$VM_DIR/$VM_NAME.qcow2"
VM_DISK_SIZE="50G"
VM_RAM="4096"
VM_CPUS="4"

# UEFI firmware (adjust path for your system)
OVMF_CODE="/usr/share/edk2/x64/OVMF_CODE.4m.fd"
OVMF_VARS_ORIG="/usr/share/edk2/x64/OVMF_VARS.4m.fd"
OVMF_VARS="$VM_DIR/OVMF_VARS.fd"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Find the ISO
find_iso() {
    ISO_FILE=$(ls -t "$PROJECT_DIR/out/"*.iso 2>/dev/null | head -1)
    if [[ -z "$ISO_FILE" ]]; then
        error "No ISO found in $PROJECT_DIR/out/"
        echo "Build the ISO first with: sudo ./build.sh"
        exit 1
    fi
    info "Using ISO: $ISO_FILE"
}

# Check dependencies
check_deps() {
    local missing=()

    command -v qemu-system-x86_64 >/dev/null 2>&1 || missing+=("qemu")

    if [[ ! -f "$OVMF_CODE" ]]; then
        missing+=("edk2-ovmf")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing dependencies: ${missing[*]}"
        echo "Install with: sudo pacman -S ${missing[*]}"
        exit 1
    fi
}

# Create VM directory and disk
setup_vm() {
    mkdir -p "$VM_DIR"

    if [[ ! -f "$VM_DISK" ]]; then
        info "Creating virtual disk: $VM_DISK ($VM_DISK_SIZE)"
        qemu-img create -f qcow2 "$VM_DISK" "$VM_DISK_SIZE"
    else
        info "Using existing disk: $VM_DISK"
    fi

    # Copy OVMF vars if needed
    if [[ ! -f "$OVMF_VARS" ]]; then
        info "Setting up UEFI variables"
        cp "$OVMF_VARS_ORIG" "$OVMF_VARS"
    fi
}

# Clean up VM files
clean_vm() {
    warn "Removing VM files..."
    rm -f "$VM_DISK"
    rm -f "$OVMF_VARS"
    info "VM files removed. Ready for fresh install."
}

# Boot VM from ISO
boot_iso() {
    find_iso
    setup_vm

    info "Starting VM with ISO..."
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo "  VM: $VM_NAME"
    echo "  RAM: ${VM_RAM}MB | CPUs: $VM_CPUS"
    echo "  Disk: $VM_DISK_SIZE"
    echo "  ISO: $(basename "$ISO_FILE")"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "Tips:"
    echo "  - Press Ctrl+Alt+G to release mouse grab"
    echo "  - Press Ctrl+Alt+F to toggle fullscreen"
    echo "  - Run 'install-archzfs' to start installation"
    echo ""

    qemu-system-x86_64 \
        -name "$VM_NAME" \
        -machine q35,accel=kvm \
        -cpu host \
        -smp "$VM_CPUS" \
        -m "$VM_RAM" \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
        -drive if=pflash,format=raw,file="$OVMF_VARS" \
        -drive file="$VM_DISK",format=qcow2,if=virtio \
        -cdrom "$ISO_FILE" \
        -boot d \
        -netdev user,id=net0,hostfwd=tcp::2222-:22 \
        -device virtio-net-pci,netdev=net0 \
        -device virtio-vga-gl \
        -display gtk,gl=on \
        -audiodev pipewire,id=audio0 \
        -device ich9-intel-hda \
        -device hda-duplex,audiodev=audio0 \
        -usb \
        -device usb-tablet
}

# Boot VM from disk (after installation)
boot_disk() {
    setup_vm

    if [[ ! -f "$VM_DISK" ]]; then
        error "No disk found. Run without --boot-disk first to install."
    fi

    info "Booting from installed disk..."
    echo ""
    echo "SSH access: ssh -p 2222 localhost"
    echo ""

    qemu-system-x86_64 \
        -name "$VM_NAME" \
        -machine q35,accel=kvm \
        -cpu host \
        -smp "$VM_CPUS" \
        -m "$VM_RAM" \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
        -drive if=pflash,format=raw,file="$OVMF_VARS" \
        -drive file="$VM_DISK",format=qcow2,if=virtio \
        -boot c \
        -netdev user,id=net0,hostfwd=tcp::2222-:22 \
        -device virtio-net-pci,netdev=net0 \
        -device virtio-vga-gl \
        -display gtk,gl=on \
        -audiodev pipewire,id=audio0 \
        -device ich9-intel-hda \
        -device hda-duplex,audiodev=audio0 \
        -usb \
        -device usb-tablet
}

# Show help
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  (none)        Create VM and boot from ISO for installation"
    echo "  --boot-disk   Boot from existing virtual disk (after install)"
    echo "  --clean       Remove VM disk and start fresh"
    echo "  --help        Show this help message"
    echo ""
    echo "VM Configuration (edit this script to change):"
    echo "  Disk size: $VM_DISK_SIZE"
    echo "  RAM: ${VM_RAM}MB"
    echo "  CPUs: $VM_CPUS"
    echo ""
    echo "SSH into running VM:"
    echo "  ssh -p 2222 localhost"
}

# Main
check_deps

case "${1:-}" in
    --boot-disk)
        boot_disk
        ;;
    --clean)
        clean_vm
        ;;
    --help|-h)
        show_help
        ;;
    "")
        boot_iso
        ;;
    *)
        error "Unknown option: $1"
        show_help
        exit 1
        ;;
esac
