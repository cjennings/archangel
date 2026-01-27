# Makefile for archzfs ISO build and testing
#
# Usage:
#   make              - Run all tests and build
#   make test         - Run all tests (unit + integration)
#   make test-unit    - Run unit tests only (fast)
#   make test-install - Run install tests in VM (slow)
#   make build        - Build the ISO
#   make release      - Full test + build + deploy
#   make clean        - Clean build artifacts
#   make lint         - Run shellcheck on all scripts
#
# Test configurations are in scripts/test-configs/

.PHONY: all test test-unit test-install build release clean lint

# Default target
all: test build

# Unit tests (fast, no VM needed)
test-unit:
	@echo "==> Running unit tests..."
	./scripts/test-zfs-snap-prune.sh

# Lint all bash scripts
lint:
	@echo "==> Running shellcheck..."
	@shellcheck -x build.sh scripts/*.sh custom/install-archzfs custom/grub-zfs-snap custom/zfs-snap-prune || true
	@echo "==> Shellcheck complete"

# Build the ISO (requires sudo)
build:
	@echo "==> Building ISO..."
	sudo ./build.sh

# Integration tests (runs VMs, slow)
test-install: build
	@echo "==> Running install tests..."
	./scripts/test-install.sh

# All tests
test: lint test-unit

# Full release: test everything, build, deploy
release: test test-install
	@echo "==> Deploying ISO..."
	@# Move old ISOs to archive
	@mkdir -p archive
	@mv -f archzfs-*.iso archive/ 2>/dev/null || true
	@# Copy new ISO to project root
	@cp out/archzfs-*.iso .
	@echo "==> Release complete:"
	@ls -lh archzfs-*.iso

# Clean build artifacts
clean:
	@echo "==> Cleaning..."
	sudo rm -rf work out profile
	rm -rf vm/*.qcow2
	@echo "==> Clean complete"

# Clean everything including releases
distclean: clean
	rm -rf archive
	rm -f archzfs-*.iso
