#!/bin/bash
# build.sh - Build the custom Arch ZFS installation ISO
# Must be run as root

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_DIR="$SCRIPT_DIR/profile"
WORK_DIR="$SCRIPT_DIR/work"
OUT_DIR="$SCRIPT_DIR/out"
CUSTOM_DIR="$SCRIPT_DIR/custom"
ZFS_PKG_DIR="$SCRIPT_DIR/zfs-packages"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Check root
[[ $EUID -ne 0 ]] && error "This script must be run as root"

# Check dependencies
command -v mkarchiso >/dev/null 2>&1 || {
    info "Installing archiso..."
    pacman -Sy --noconfirm archiso
}

# Get current kernel version
KERNEL_VER=$(pacman -Si linux | grep Version | awk '{print $3}')
info "Current Arch kernel version: $KERNEL_VER"

# Download ZFS packages from GitHub releases
info "Downloading ZFS packages for kernel $KERNEL_VER..."
mkdir -p "$ZFS_PKG_DIR"

# Find matching ZFS packages from experimental release
ZFS_LINUX_URL=$(curl -s https://api.github.com/repos/archzfs/archzfs/releases/tags/experimental | \
    jq -r ".assets[] | select(.name | contains(\"zfs-linux-\") and contains(\"${KERNEL_VER}\") and (contains(\"-headers\") | not) and contains(\".pkg.tar.zst\") and (contains(\".sig\") | not)) | .browser_download_url" | head -1)

ZFS_UTILS_URL=$(curl -s https://api.github.com/repos/archzfs/archzfs/releases/tags/experimental | \
    jq -r '.assets[] | select(.name | contains("zfs-utils-") and contains(".pkg.tar.zst") and (contains(".sig") | not) and (contains("debug") | not)) | .browser_download_url' | head -1)

if [[ -z "$ZFS_LINUX_URL" ]]; then
    warn "No ZFS package found for kernel $KERNEL_VER in experimental"
    warn "Checking other releases..."

    # Try to find any recent zfs-linux package
    ZFS_LINUX_URL=$(curl -s https://api.github.com/repos/archzfs/archzfs/releases | \
        jq -r ".[].assets[] | select(.name | contains(\"zfs-linux-\") and contains(\"6.18\") and (contains(\"-headers\") | not) and contains(\".pkg.tar.zst\") and (contains(\".sig\") | not)) | .browser_download_url" | head -1)
fi

if [[ -z "$ZFS_LINUX_URL" || -z "$ZFS_UTILS_URL" ]]; then
    error "Could not find matching ZFS packages. The archzfs repo may not have packages for kernel $KERNEL_VER yet."
fi

info "Downloading: $(basename "$ZFS_LINUX_URL")"
wget -q -N -P "$ZFS_PKG_DIR" "$ZFS_LINUX_URL" || error "Failed to download zfs-linux"

info "Downloading: $(basename "$ZFS_UTILS_URL")"
wget -q -N -P "$ZFS_PKG_DIR" "$ZFS_UTILS_URL" || error "Failed to download zfs-utils"

# Clean previous builds
if [[ -d "$WORK_DIR" ]]; then
    warn "Removing previous work directory..."
    rm -rf "$WORK_DIR"
fi

# Always start fresh from releng profile
info "Copying base releng profile..."
rm -rf "$PROFILE_DIR"
cp -r /usr/share/archiso/configs/releng "$PROFILE_DIR"

# Add our custom packages (NOT zfs - we'll install that separately)
info "Adding custom packages..."
cat >> "$PROFILE_DIR/packages.x86_64" << 'EOF'

# Additional networking
wget

# Development tools for Claude Code
nodejs
npm
jq

# Additional utilities
zsh
htop
ripgrep
eza
fd
fzf

# For installation scripts
dialog
EOF

# Update profiledef.sh with our ISO name
info "Updating ISO metadata..."
sed -i 's/^iso_name=.*/iso_name="archzfs-claude"/' "$PROFILE_DIR/profiledef.sh"

# Create airootfs directories
mkdir -p "$PROFILE_DIR/airootfs/usr/local/bin"
mkdir -p "$PROFILE_DIR/airootfs/code"
mkdir -p "$PROFILE_DIR/airootfs/var/cache/zfs-packages"

# Copy ZFS packages to airootfs for installation during boot
info "Copying ZFS packages to ISO..."
cp "$ZFS_PKG_DIR"/*.pkg.tar.zst "$PROFILE_DIR/airootfs/var/cache/zfs-packages/"

# Copy our custom scripts
info "Copying custom scripts..."
cp "$CUSTOM_DIR/install-archzfs" "$PROFILE_DIR/airootfs/usr/local/bin/"
cp "$CUSTOM_DIR/install-claude" "$PROFILE_DIR/airootfs/usr/local/bin/"
cp "$CUSTOM_DIR/archsetup-zfs" "$PROFILE_DIR/airootfs/usr/local/bin/"

# Create ZFS setup script that runs on boot
cat > "$PROFILE_DIR/airootfs/usr/local/bin/zfs-setup" << 'ZFSSETUP'
#!/bin/bash
# Install ZFS packages and load module
# Run this first after booting the ISO

set -e

echo "Installing ZFS packages..."
pacman -U --noconfirm /var/cache/zfs-packages/*.pkg.tar.zst

echo "Loading ZFS module..."
modprobe zfs

echo ""
echo "ZFS is ready! You can now run:"
echo "  install-archzfs"
echo ""
ZFSSETUP

# Set permissions in profiledef.sh
info "Setting file permissions..."
if grep -q "file_permissions=" "$PROFILE_DIR/profiledef.sh"; then
    sed -i '/^file_permissions=(/,/)/ {
        /)/ i\  ["/usr/local/bin/install-archzfs"]="0:0:755"
    }' "$PROFILE_DIR/profiledef.sh"
    sed -i '/^file_permissions=(/,/)/ {
        /)/ i\  ["/usr/local/bin/install-claude"]="0:0:755"
    }' "$PROFILE_DIR/profiledef.sh"
    sed -i '/^file_permissions=(/,/)/ {
        /)/ i\  ["/usr/local/bin/archsetup-zfs"]="0:0:755"
    }' "$PROFILE_DIR/profiledef.sh"
    sed -i '/^file_permissions=(/,/)/ {
        /)/ i\  ["/usr/local/bin/zfs-setup"]="0:0:755"
    }' "$PROFILE_DIR/profiledef.sh"
fi

# Copy archsetup into airootfs
if [[ -d /home/cjennings/code/archsetup ]]; then
    info "Copying archsetup into ISO..."
    cp -r /home/cjennings/code/archsetup "$PROFILE_DIR/airootfs/code/"
    rm -rf "$PROFILE_DIR/airootfs/code/archsetup/.git"
    rm -rf "$PROFILE_DIR/airootfs/code/archsetup/.claude"
fi

# Ensure scripts are executable in the profile
chmod +x "$PROFILE_DIR/airootfs/usr/local/bin/"*

# Build the ISO
info "Building ISO (this will take a while)..."
mkarchiso -v -w "$WORK_DIR" -o "$OUT_DIR" "$PROFILE_DIR"

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
    info "After booting, run:"
    echo "  zfs-setup        # Install ZFS and load module"
    echo "  install-archzfs  # Run the installer"
else
    error "Build failed - no ISO file found"
fi
