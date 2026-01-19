# Session Context - 2026-01-19

## Summary
Major session: Added ZFS snapshot scripts, fixed grub-zfs-snap, created fully automated build-release workflow with sanity testing.

## Key Accomplishments

### 1. ZFS Snapshot Management Scripts
- Copied `zfssnapshot` and `zfsrollback` from archsetup to archzfs ISO
- Scripts now installed to `/usr/local/bin/` on live ISO and target systems
- Added `fzf` to `install-archzfs` pacstrap (required by zfsrollback)
- Fixed zfsrollback fzf height (40% → 70%)
- Fixed zfsrollback to sort datasets by depth (children before parents) for proper rollback order
- Created task in archsetup inbox to remove duplicate scripts

### 2. Fixed grub-zfs-snap Syntax Error
- **Bug:** `\$(grub-probe ...)` wrote literal string to grub.cfg
- **Fix:** Removed backslash so command executes at config generation time
- **File:** `custom/grub-zfs-snap` line 106
- GRUB doesn't support bash-style `$()` command substitution

### 3. Automated Sanity Test (`scripts/sanity-test.sh`)
- Boots ISO in headless QEMU (no display)
- Waits for SSH availability (port 2223, timeout 180s)
- Runs 13 automated tests via SSH:
  - ZFS module loaded
  - ZFS/zpool commands work
  - Custom scripts present (zfsrollback, zfssnapshot, grub-zfs-snap, etc.)
  - fzf installed
  - LTS kernel running
  - archsetup directory present
- Reports pass/fail summary
- Fully automated - no human input required

### 4. Build-Release Workflow (`scripts/build-release`)
Complete automated workflow for ISO build and distribution:

**Usage:**
```bash
sudo ./scripts/build-release              # Full: build, test, distribute
sudo ./scripts/build-release --yes        # Full with auto-confirm dd
sudo ./scripts/build-release --skip-build --skip-test --yes  # Just distribute
```

**Options:**
- `--skip-build` - Skip ISO build, use existing
- `--skip-test` - Skip sanity test
- `--yes, -y` - Auto-confirm dd to ARCHZFS drive

**Distribution Targets:**
1. `~/Downloads/isos/` (always)
2. `truenas.local:/mnt/vault/isos/` (via cjennings@, checks reachable)
3. ARCHZFS labeled drive (detected via `blkid -L ARCHZFS`, writes via dd)
4. Ventoy drive (detected by label "Ventoy" or ventoy/ directory)

**Key Fixes:**
- Uses `SUDO_USER` to get real user's home (not /root)
- SSH/SCP runs as real user to use their SSH keys
- Uses `cjennings@truenas.local` (not root)
- No removable check for ARCHZFS (Framework expansion cards show as internal)
- Graceful handling of failures (warns and continues)

### 5. Added eBPF Tracing Tools
- Added to ISO: `bpftrace`, `bcc-tools`, `perf`, `w3m`
- Updated RESCUE-GUIDE.txt with sections 9 (System Tracing) and 10 (Terminal Web Browsing)

## Technical Notes

### os-prober Warning
```
Warning: os-prober will not be executed to detect other bootable partitions.
```
- Disabled by default since GRUB 2.06 for security
- Not needed for single-OS ZFS systems
- To enable: Add `GRUB_DISABLE_OS_PROBER=false` to `/etc/default/grub`

### Genesis Snapshot Best Practice
Scripts must be part of genesis snapshot to survive rollback:
1. `install-archzfs` installs zfssnapshot, zfsrollback, fzf
2. These exist before genesis snapshot is taken
3. Future rollbacks preserve the tools

### Framework Laptop Note
Expansion card drives show as internal (RM=0) but are hot-swappable.
Don't check for removable flag when detecting ARCHZFS drives.

### Ratio Machine
- Host: ratio (192.168.86.48)
- Login: root / cmjdase1n
- Scripts deployed: zfssnapshot, zfsrollback, grub-zfs-snap, fzf

### Cogito Machine (Build Host)
- Framework Desktop ML with AMD Ryzen AI MAX+ 395
- Specs in `assets/cogito-hardware-specs.txt`

## Files Modified/Created This Session

**New Files:**
- `scripts/sanity-test.sh` - Automated ISO testing
- `scripts/build-release` - Build and distribution workflow
- `custom/zfssnapshot` - ZFS snapshot creation
- `custom/zfsrollback` - Interactive ZFS rollback
- `assets/cogito-hardware-specs.txt` - Build machine specs
- `/home/cjennings/code/archsetup/inbox/remove-zfs-scripts.md` - Task for archsetup

**Modified Files:**
- `custom/grub-zfs-snap` - Fixed syntax error
- `custom/install-archzfs` - Added fzf to pacstrap
- `custom/RESCUE-GUIDE.txt` - Added tracing/browser sections
- `build.sh` - Added bpftrace, bcc-tools, perf, w3m, zfs script copies
- `TODO.org` - Updated tasks

## Commits This Session
```
d0e76f0 Add --yes flag for fully automated distribution
2c261bc Update build-release for TrueNAS and Framework drives
c68e550 Fix build-release for running with sudo
d3eaaff Add automated sanity test for ISO verification
5eba633 Fix zfsrollback to process children before parents
4e7e3fe Fix grub-zfs-snap command substitution syntax error
ee668df Increase fzf height in zfsrollback to 70%
7c0d655 Add fzf to target system packages
156dde5 Add zfssnapshot and zfsrollback scripts to ISO
e924c53 Add TODO for zfsrollback and zfssnapshot scripts
d2c2cca Add eBPF tracing tools and w3m terminal browser
66c92a2 Add session context for 2026-01-19
c719d45 Add build-release script for ISO build and distribution
```

## Final Distribution (This Session)
```
ISO: archzfs-vmlinuz-6.12.66-lts-2026-01-19-x86_64.iso (5.2GB)

Distributed to:
  ✓ /home/cjennings/Downloads/isos/
  ✓ truenas.local:/mnt/vault/isos/
  ✓ /dev/sda (ARCHZFS boot drive)
  ✓ /dev/sdb1 (Ventoy)
```

## Pending/Future Work
- User should run archsetup on ratio after genesis rollback
- archsetup inbox task: remove duplicate zfssnapshot/zfsrollback scripts

## Session 2026-01-19 (continued)

### Added --full-test to build-release

Created comprehensive installation test framework:

**New File: `scripts/full-test.sh`**
- Automated installation testing for all disk configurations
- Tests: single-disk, mirror (2 disks), raidz1 (3 disks)
- Each test: boots ISO, runs unattended install, reboots, verifies ZFS health
- Options: `--quick` (single-disk only), `--verbose`
- Runs sanity-test.sh first, then install tests

**Modified: `scripts/build-release`**
- Added `--full-test` option
- When specified, runs full-test.sh instead of sanity-test.sh
- Usage: `sudo ./scripts/build-release --full-test`

**Usage:**
```bash
sudo ./scripts/build-release              # Sanity test only (fast)
sudo ./scripts/build-release --full-test  # All install tests (~30-45 min)
sudo ./scripts/build-release --skip-test  # No testing
```
