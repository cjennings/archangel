#!/bin/bash
# boot-vm.sh - Boot the VM from disk if installed, otherwise from ISO
#
# This is a simple wrapper that does the right thing:
# - If VM disk exists and has data, boot from disk
# - Otherwise, boot from ISO

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM_DISK="$SCRIPT_DIR/../vm/archzfs-test.qcow2"

if [[ -f "$VM_DISK" ]] && [[ $(stat -c%s "$VM_DISK") -gt 200000 ]]; then
    # Disk exists and is larger than ~200KB (has been written to)
    exec "$SCRIPT_DIR/test-vm.sh" --boot-disk "$@"
else
    # No disk or empty disk - boot from ISO
    exec "$SCRIPT_DIR/test-vm.sh" "$@"
fi
