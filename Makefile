# Makefile for archangel ISO build and testing
#
# Usage:
#   make test         - Run lint
#   make test-install - Run install tests in VM (slow)
#   make build        - Build the ISO
#   make release      - Full test + build + deploy
#   make clean        - Clean build artifacts
#   make lint         - Run shellcheck on all scripts
#
# Test configurations are in scripts/test-configs/

.PHONY: test test-install build release clean lint

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
