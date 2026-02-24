# Makefile for archangel ISO build and testing
#
# Usage:
#   make build          - Build the ISO
#   make lint           - Run shellcheck on all scripts
#   make test           - Run lint
#   make test-install   - Run all automated install tests in VMs (slow)
#   make release        - Full test + build + deploy
#
# Manual VM testing:
#   make test-vm        - Boot ISO in a single-disk VM
#   make test-multi     - Boot ISO in a 2-disk VM (mirror/RAID)
#   make test-multi3    - Boot ISO in a 3-disk VM (raidz1)
#   make test-boot      - Boot from installed disk (after install)
#   make test-clean     - Remove VM disks and OVMF vars
#
#   make clean          - Clean build artifacts
#   make distclean      - Clean everything including releases
#
# Test configurations are in scripts/test-configs/

.PHONY: test test-install test-vm test-multi test-multi3 test-boot test-clean build release clean distclean lint

# Lint all bash scripts
lint:
	@echo "==> Running shellcheck..."
	@shellcheck -x build.sh scripts/*.sh installer/archangel installer/zfsrollback installer/zfssnapshot installer/lib/*.sh
	@echo "==> Shellcheck complete"

# Build the ISO (requires sudo)
build:
	@echo "==> Building ISO..."
	sudo ./build.sh

# Integration tests (runs VMs, slow)
test-install: build
	@echo "==> Running install tests..."
	./scripts/test-install.sh

# All tests (lint only - VM tests via test-install)
test: lint

# Full release: test everything, build, deploy
release: test test-install
	@echo "==> Deploying ISO..."
	@# Move old ISOs to archive
	@mkdir -p archive
	@mv -f archangel-*.iso archive/ 2>/dev/null || true
	@# Copy new ISO to project root
	@cp out/archangel-*.iso .
	@echo "==> Release complete:"
	@ls -lh archangel-*.iso

# --- Manual VM testing ---

# Boot ISO in a single-disk VM
test-vm:
	./scripts/test-vm.sh

# Boot ISO in a 2-disk VM (for mirror/RAID testing)
test-multi:
	./scripts/test-vm.sh --multi-disk

# Boot ISO in a 3-disk VM (for raidz1 testing)
test-multi3:
	./scripts/test-vm.sh --multi-disk=3

# Boot from installed disk (after running install in VM)
test-boot:
	./scripts/test-vm.sh --boot-disk

# Remove VM disks and start fresh
test-clean:
	./scripts/test-vm.sh --clean

# --- Cleanup ---

# Clean build artifacts
clean:
	@echo "==> Cleaning..."
	sudo rm -rf work out profile
	rm -rf vm/*.qcow2
	@echo "==> Clean complete"

# Clean everything including releases
distclean: clean
	rm -rf archive
	rm -f archangel-*.iso
