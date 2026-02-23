#!/usr/bin/env bash
# build.sh - Build the custom Arch ZFS installation ISO
# Must be run as root
#
# Uses linux-lts kernel with zfs-dkms from archzfs.com repository.
# DKMS builds ZFS from source, ensuring it always matches the kernel version.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_DIR="$SCRIPT_DIR/profile"
WORK_DIR="$SCRIPT_DIR/work"
OUT_DIR="$SCRIPT_DIR/out"
CUSTOM_DIR="$SCRIPT_DIR/custom"

# Live ISO root password (for SSH access during testing/emergencies)
LIVE_ROOT_PASSWORD="archangel"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Safe cleanup function - unmounts bind mounts before removing work directory
# This prevents damage to host /dev, /sys, /proc if build is interrupted
safe_cleanup_work_dir() {
    local airootfs="$WORK_DIR/x86_64/airootfs"

    if [[ -d "$airootfs" ]]; then
        # Unmount in reverse order of typical mount hierarchy
        # Use lazy unmount (-l) to handle busy filesystems
        for mount_point in \
            "$airootfs/dev/pts" \
            "$airootfs/dev/shm" \
            "$airootfs/dev/mqueue" \
            "$airootfs/dev/hugepages" \
            "$airootfs/dev" \
            "$airootfs/sys" \
            "$airootfs/proc" \
            "$airootfs/run"; do
            if mountpoint -q "$mount_point" 2>/dev/null; then
                umount -l "$mount_point" 2>/dev/null || true
            fi
        done

        # Also catch any other mounts we might have missed
        if findmnt --list -o TARGET 2>/dev/null | grep -q "$airootfs"; then
            findmnt --list -o TARGET 2>/dev/null | grep "$airootfs" | sort -r | while read -r mp; do
                umount -l "$mp" 2>/dev/null || true
            done
        fi

        # Small delay to let lazy unmounts complete
        sleep 1
    fi

    # Now safe to remove
    rm -rf "$WORK_DIR"
}

# Trap to ensure cleanup on interruption (Ctrl+C, errors, etc.)
# This prevents host /dev damage from interrupted builds
cleanup_on_exit() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]] && [[ -d "$WORK_DIR" ]]; then
        warn "Build interrupted or failed - cleaning up safely..."
        safe_cleanup_work_dir
    fi
}
trap cleanup_on_exit EXIT INT TERM

# Check root
[[ $EUID -ne 0 ]] && error "This script must be run as root"

# Check dependencies
command -v mkarchiso >/dev/null 2>&1 || {
    info "Installing archiso..."
    pacman -Sy --noconfirm archiso
}

# Clean previous builds (using safe cleanup to handle any leftover mounts)
if [[ -d "$WORK_DIR" ]]; then
    warn "Removing previous work directory..."
    safe_cleanup_work_dir
fi

# Always start fresh from releng profile
info "Copying base releng profile..."
rm -rf "$PROFILE_DIR"
cp -r /usr/share/archiso/configs/releng "$PROFILE_DIR"

# Switch from linux to linux-lts
info "Switching to linux-lts kernel..."
sed -i 's/^linux$/linux-lts/' "$PROFILE_DIR/packages.x86_64"
sed -i 's/^linux-headers$/linux-lts-headers/' "$PROFILE_DIR/packages.x86_64"
# broadcom-wl depends on linux, use DKMS version instead
sed -i 's/^broadcom-wl$/broadcom-wl-dkms/' "$PROFILE_DIR/packages.x86_64"

# Update bootloader configs to use linux-lts kernel
info "Updating bootloader configurations for linux-lts..."

# UEFI systemd-boot entries
for entry in "$PROFILE_DIR"/efiboot/loader/entries/*.conf; do
    if [[ -f "$entry" ]]; then
        sed -i 's/vmlinuz-linux/vmlinuz-linux-lts/g' "$entry"
        sed -i 's/initramfs-linux\.img/initramfs-linux-lts.img/g' "$entry"
    fi
done

# BIOS syslinux entries
for cfg in "$PROFILE_DIR"/syslinux/*.cfg; do
    if [[ -f "$cfg" ]]; then
        sed -i 's/vmlinuz-linux/vmlinuz-linux-lts/g' "$cfg"
        sed -i 's/initramfs-linux\.img/initramfs-linux-lts.img/g' "$cfg"
    fi
done

# GRUB config
if [[ -f "$PROFILE_DIR/grub/grub.cfg" ]]; then
    sed -i 's/vmlinuz-linux/vmlinuz-linux-lts/g' "$PROFILE_DIR/grub/grub.cfg"
    sed -i 's/initramfs-linux\.img/initramfs-linux-lts.img/g' "$PROFILE_DIR/grub/grub.cfg"
fi

# Update mkinitcpio preset for linux-lts (archiso uses custom preset)
if [[ -f "$PROFILE_DIR/airootfs/etc/mkinitcpio.d/linux.preset" ]]; then
    # Rename to linux-lts.preset and update paths
    mv "$PROFILE_DIR/airootfs/etc/mkinitcpio.d/linux.preset" \
       "$PROFILE_DIR/airootfs/etc/mkinitcpio.d/linux-lts.preset"
    sed -i 's/vmlinuz-linux/vmlinuz-linux-lts/g' \
        "$PROFILE_DIR/airootfs/etc/mkinitcpio.d/linux-lts.preset"
    sed -i 's/initramfs-linux/initramfs-linux-lts/g' \
        "$PROFILE_DIR/airootfs/etc/mkinitcpio.d/linux-lts.preset"
    sed -i "s/'linux' package/'linux-lts' package/g" \
        "$PROFILE_DIR/airootfs/etc/mkinitcpio.d/linux-lts.preset"
fi

# Add archzfs repository to pacman.conf
# SigLevel=Never: archzfs GPG key import is unreliable in clean build environments;
# repo is explicitly added and served over HTTPS, GPG adds no real value here
info "Adding archzfs repository..."
cat >> "$PROFILE_DIR/pacman.conf" << 'EOF'

[archzfs]
Server = https://archzfs.com/$repo/$arch
SigLevel = Never
EOF

# Add ZFS and our custom packages
info "Adding ZFS and custom packages..."
cat >> "$PROFILE_DIR/packages.x86_64" << 'EOF'

# ZFS support (DKMS builds from source - always matches kernel)
zfs-dkms
zfs-utils
linux-lts-headers

# Additional networking
wget
networkmanager

# mDNS for network discovery (ssh root@archangel.local)
avahi
nss-mdns

# Development tools for Claude Code
nodejs
npm
jq

# Additional utilities
inetutils
zsh
htop
ripgrep
eza
fd
fzf
emacs

# For installation scripts
dialog

# Rescue/Recovery tools
tealdeer
pv
rsync
mbuffer
lsof

# Data recovery
ddrescue
testdisk
foremost
sleuthkit
smartmontools

# Boot repair
os-prober
syslinux

# Windows recovery
chntpw
ntfs-3g
hivex

# Hardware diagnostics
memtester
stress-ng
lm_sensors
lshw
dmidecode
nvme-cli
hdparm
iotop

# Disk operations
partclone
fsarchiver
partimage
xfsprogs
btrfs-progs
snapper
f2fs-tools
exfatprogs
ncdu
tree

# Network diagnostics
mtr
iperf3
iftop
nethogs
ethtool
tcpdump
bind
nmap
wireshark-cli
speedtest-cli
mosh
aria2
tmate
sshuttle

# Security
pass

# System tracing and profiling (eBPF/DTrace-like)
bpftrace
bcc-tools
perf

# Terminal web browsers
w3m

EOF

# Get kernel version for ISO naming
info "Querying kernel version..."
KERNEL_VER=$(pacman -Si linux-lts 2>/dev/null | grep "^Version" | awk '{print $3}' | cut -d- -f1)
if [[ -z "$KERNEL_VER" ]]; then
    KERNEL_VER="unknown"
    warn "Could not determine kernel version, using 'unknown'"
fi
info "LTS Kernel version: $KERNEL_VER"

# Update profiledef.sh with our ISO name
info "Updating ISO metadata..."
# Format: archangel-vmlinuz-6.12.65-lts-2026-01-18-x86_64.iso
ISO_DATE=$(date +%Y-%m-%d)
sed -i "s/^iso_name=.*/iso_name=\"archangel-vmlinuz-${KERNEL_VER}-lts\"/" "$PROFILE_DIR/profiledef.sh"
sed -i "s/^iso_version=.*/iso_version=\"${ISO_DATE}\"/" "$PROFILE_DIR/profiledef.sh"
# Fixed label for stable GRUB boot entry (default is date-based ARCH_YYYYMM)
sed -i "s/^iso_label=.*/iso_label=\"ARCHANGEL\"/" "$PROFILE_DIR/profiledef.sh"

# Create airootfs directories
mkdir -p "$PROFILE_DIR/airootfs/usr/local/bin"
mkdir -p "$PROFILE_DIR/airootfs/code"
mkdir -p "$PROFILE_DIR/airootfs/etc/systemd/system/multi-user.target.wants"

# Enable SSH on live ISO
info "Enabling SSH on live ISO..."
ln -sf /usr/lib/systemd/system/sshd.service \
    "$PROFILE_DIR/airootfs/etc/systemd/system/multi-user.target.wants/sshd.service"

# Enable Avahi mDNS for network discovery (ssh root@archangel.local)
info "Enabling Avahi mDNS..."
ln -sf /usr/lib/systemd/system/avahi-daemon.service \
    "$PROFILE_DIR/airootfs/etc/systemd/system/multi-user.target.wants/avahi-daemon.service"

# Set hostname to "archangel" for mDNS discovery
info "Setting hostname to archangel..."
echo "archangel" > "$PROFILE_DIR/airootfs/etc/hostname"

# Create /etc/hosts with proper hostname entries
cat > "$PROFILE_DIR/airootfs/etc/hosts" << 'EOF'
127.0.0.1   localhost
::1         localhost
127.0.1.1   archangel.localdomain archangel
EOF

# Configure nsswitch.conf for mDNS resolution
# Add mdns_minimal before dns in hosts line
info "Configuring nss-mdns..."
mkdir -p "$PROFILE_DIR/airootfs/etc"
cat > "$PROFILE_DIR/airootfs/etc/nsswitch.conf" << 'EOF'
# Name Service Switch configuration file.
# See nsswitch.conf(5) for details.

passwd: files systemd
group: files [SUCCESS=merge] systemd
shadow: files systemd
gshadow: files systemd

publickey: files

hosts: mymachines mdns_minimal [NOTFOUND=return] resolve [!UNAVAIL=return] files dns
networks: files

protocols: files
services: files
ethers: files
rpc: files

netgroup: files
EOF

# Set root password for live ISO
info "Setting root password for live ISO..."
# Generate password hash
PASS_HASH=$(openssl passwd -6 "$LIVE_ROOT_PASSWORD")
# Modify the existing shadow file's root entry (don't replace entire file)
# The releng template has multiple accounts; replacing breaks the file
if [[ -f "$PROFILE_DIR/airootfs/etc/shadow" ]]; then
    sed -i "s|^root:[^:]*:|root:${PASS_HASH}:|" "$PROFILE_DIR/airootfs/etc/shadow"
else
    # Fallback: create complete shadow file if it doesn't exist
    cat > "$PROFILE_DIR/airootfs/etc/shadow" << EOF
root:${PASS_HASH}:19000:0:99999:7:::
bin:!*:19000::::::
daemon:!*:19000::::::
mail:!*:19000::::::
ftp:!*:19000::::::
http:!*:19000::::::
nobody:!*:19000::::::
dbus:!*:19000::::::
systemd-coredump:!*:19000::::::
systemd-network:!*:19000::::::
systemd-oom:!*:19000::::::
systemd-journal-remote:!*:19000::::::
systemd-resolve:!*:19000::::::
systemd-timesync:!*:19000::::::
tss:!*:19000::::::
uuidd:!*:19000::::::
polkitd:!*:19000::::::
avahi:!*:19000::::::
EOF
fi
chmod 400 "$PROFILE_DIR/airootfs/etc/shadow"

# Allow root SSH login with password (for testing)
mkdir -p "$PROFILE_DIR/airootfs/etc/ssh/sshd_config.d"
cat > "$PROFILE_DIR/airootfs/etc/ssh/sshd_config.d/allow-root.conf" << 'EOF'
PermitRootLogin yes
PasswordAuthentication yes
EOF

# Copy our custom scripts
info "Copying custom scripts..."
cp "$CUSTOM_DIR/archangel" "$PROFILE_DIR/airootfs/usr/local/bin/"
cp -r "$CUSTOM_DIR/lib" "$PROFILE_DIR/airootfs/usr/local/bin/"
cp "$CUSTOM_DIR/install-claude" "$PROFILE_DIR/airootfs/usr/local/bin/"
# Copy zfssnapshot and zfsrollback for ZFS management
info "Copying zfssnapshot and zfsrollback..."
cp "$CUSTOM_DIR/zfssnapshot" "$PROFILE_DIR/airootfs/usr/local/bin/"
cp "$CUSTOM_DIR/zfsrollback" "$PROFILE_DIR/airootfs/usr/local/bin/"

# Copy example config for unattended installs
mkdir -p "$PROFILE_DIR/airootfs/root"
cp "$CUSTOM_DIR/archangel.conf.example" "$PROFILE_DIR/airootfs/root/"

# Copy rescue guide
info "Copying rescue guide..."
cp "$CUSTOM_DIR/RESCUE-GUIDE.txt" "$PROFILE_DIR/airootfs/root/"

# Set permissions in profiledef.sh
info "Setting file permissions..."
if grep -q "file_permissions=" "$PROFILE_DIR/profiledef.sh"; then
    sed -i '/^file_permissions=(/,/)/ {
        /)/ i\  ["/usr/local/bin/archangel"]="0:0:755"
    }' "$PROFILE_DIR/profiledef.sh"
    sed -i '/^file_permissions=(/,/)/ {
        /)/ i\  ["/usr/local/bin/install-claude"]="0:0:755"
    }' "$PROFILE_DIR/profiledef.sh"
    sed -i '/^file_permissions=(/,/)/ {
        /)/ i\  ["/usr/local/bin/zfssnapshot"]="0:0:755"
    }' "$PROFILE_DIR/profiledef.sh"
    sed -i '/^file_permissions=(/,/)/ {
        /)/ i\  ["/usr/local/bin/zfsrollback"]="0:0:755"
    }' "$PROFILE_DIR/profiledef.sh"
    sed -i '/^file_permissions=(/,/)/ {
        /)/ i\  ["/usr/local/bin/lib/common.sh"]="0:0:755"
    }' "$PROFILE_DIR/profiledef.sh"
    sed -i '/^file_permissions=(/,/)/ {
        /)/ i\  ["/usr/local/bin/lib/config.sh"]="0:0:755"
    }' "$PROFILE_DIR/profiledef.sh"
    sed -i '/^file_permissions=(/,/)/ {
        /)/ i\  ["/usr/local/bin/lib/disk.sh"]="0:0:755"
    }' "$PROFILE_DIR/profiledef.sh"
    sed -i '/^file_permissions=(/,/)/ {
        /)/ i\  ["/usr/local/bin/lib/zfs.sh"]="0:0:755"
    }' "$PROFILE_DIR/profiledef.sh"
    sed -i '/^file_permissions=(/,/)/ {
        /)/ i\  ["/usr/local/bin/lib/btrfs.sh"]="0:0:755"
    }' "$PROFILE_DIR/profiledef.sh"
    sed -i '/^file_permissions=(/,/)/ {
        /)/ i\  ["/etc/shadow"]="0:0:400"
    }' "$PROFILE_DIR/profiledef.sh"
fi

# Copy archsetup into airootfs (exclude large/unnecessary directories)
ARCHSETUP_DIR="${ARCHSETUP_DIR:-$HOME/code/archsetup}"
if [[ -d "$ARCHSETUP_DIR" ]]; then
    info "Copying archsetup into ISO..."
    mkdir -p "$PROFILE_DIR/airootfs/code"
    rsync -a --exclude='.git' \
             --exclude='.claude' \
             --exclude='vm-images' \
             --exclude='test-results' \
             --exclude='*.qcow2' \
             --exclude='*.iso' \
             "$ARCHSETUP_DIR" "$PROFILE_DIR/airootfs/code/"
fi

# Pre-populate tealdeer (tldr) cache for offline use
info "Pre-populating tealdeer cache..."
if command -v tldr &>/dev/null; then
    tldr --update 2>/dev/null || true
    if [[ -d "$HOME/.cache/tealdeer" ]]; then
        mkdir -p "$PROFILE_DIR/airootfs/root/.cache"
        cp -r "$HOME/.cache/tealdeer" "$PROFILE_DIR/airootfs/root/.cache/"
        info "Tealdeer cache copied (~27MB)"
    fi
else
    warn "tealdeer not installed on build host, skipping cache pre-population"
    warn "Install with: pacman -S tealdeer && tldr --update"
fi

# Ensure scripts are executable in the profile
chmod +x "$PROFILE_DIR/airootfs/usr/local/bin/"*

# Build the ISO
info "Building ISO (this will take a while)..."
mkarchiso -v -w "$WORK_DIR" -o "$OUT_DIR" "$PROFILE_DIR"

# Restore ownership to the user who invoked sudo
# mkarchiso runs as root and creates root-owned files
if [[ -n "$SUDO_USER" ]]; then
    info "Restoring ownership to $SUDO_USER..."
    chown -R "$SUDO_USER:$SUDO_USER" "$OUT_DIR" "$WORK_DIR" "$PROFILE_DIR" 2>/dev/null || true
fi

# Report results
ISO_FILE=$(ls -t "$OUT_DIR"/*.iso 2>/dev/null | head -1)
if [[ -f "$ISO_FILE" ]]; then
    echo ""
    info "Build complete!"
    info "ISO location: $ISO_FILE"
    info "ISO size: $(du -h "$ISO_FILE" | cut -f1)"
    echo ""
    info "To test: ./scripts/test-vm.sh"
    echo ""
    info "After booting:"
    echo "  - ZFS is pre-loaded (no setup needed)"
    echo "  - SSH is enabled (root password: $LIVE_ROOT_PASSWORD)"
    echo "  - Run 'archangel' to start installation"
    echo ""
    info "SSH access (from host):"
    echo "  ssh -p 2222 root@localhost"
else
    error "Build failed - no ISO file found"
fi
