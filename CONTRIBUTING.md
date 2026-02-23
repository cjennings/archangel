# Contributing to Archangel

## Development Setup

Archangel builds on Arch Linux. You'll need:

- **archiso** — ISO build framework (`pacman -S archiso`)
- **qemu** + **edk2-ovmf** — VM testing (`pacman -S qemu-full edk2-ovmf`)
- **shellcheck** — linting (`pacman -S shellcheck`)
- **sshpass** + **socat** — test automation (`pacman -S sshpass socat`)

## Project Structure

```
build.sh              # ISO build script (runs as root)
Makefile              # Build, lint, test targets
installer/            # Scripts that ship on the ISO
  archangel           # Main installer
  lib/                # Installer libraries (btrfs, zfs, disk, config, common)
scripts/              # Host-side build/test tooling
  test-install.sh     # Automated VM install tests (10 configs)
  test-configs/       # Test configuration files
```

## Building

```bash
make build            # Build the ISO (requires sudo)
```

## Testing

```bash
make lint             # Run shellcheck on all scripts
make test-install     # Run full VM test suite (10 configs, ~45 min)
./scripts/test-install.sh single-disk   # Run a single test
./scripts/test-install.sh --list        # List available test configs
```

All 10 test configurations must pass before merging.

## Code Style

- Shell scripts use `#!/usr/bin/env bash` and `set -euo pipefail`
- Follow existing patterns in the codebase
- Run `make lint` before submitting — shellcheck must pass

## Submitting Changes

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Run `make lint` and `make test-install`
5. Submit a pull request

## License

By contributing, you agree that your contributions will be licensed under the GPL-3.0 license.
