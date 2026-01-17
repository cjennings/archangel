#!/bin/bash
# download-archzfs-iso.sh - Download the official archzfs ISO and add our scripts
#
# The archzfs project maintains ISOs with matched kernel+ZFS versions.
# This script downloads their ISO and creates a script bundle to use with it.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/out"
CUSTOM_DIR="$SCRIPT_DIR/custom"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

mkdir -p "$OUT_DIR"

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo "  ArchZFS ISO Setup"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check for existing archzfs ISO
EXISTING_ISO=$(ls "$OUT_DIR"/archlinux-*-zfs-*.iso 2>/dev/null | head -1)

if [[ -n "$EXISTING_ISO" ]]; then
    info "Found existing archzfs ISO: $(basename "$EXISTING_ISO")"
    read -p "Use this ISO? [Y/n]: " use_existing
    if [[ "$use_existing" != "n" && "$use_existing" != "N" ]]; then
        ISO_FILE="$EXISTING_ISO"
    fi
fi

if [[ -z "$ISO_FILE" ]]; then
    info "Fetching latest archzfs ISO URL..."

    # Get the latest ISO from archzfs releases
    RELEASE_URL="https://github.com/archzfs/archzfs/releases"

    echo ""
    echo "Please download the latest archzfs ISO from:"
    echo -e "  ${CYAN}$RELEASE_URL${NC}"
    echo ""
    echo "Look for: archlinux-YYYY.MM.DD-zfs-linux-lts-x86_64.iso"
    echo "Save it to: $OUT_DIR/"
    echo ""
    read -p "Press Enter once downloaded, or Ctrl+C to abort..."

    ISO_FILE=$(ls "$OUT_DIR"/archlinux-*-zfs-*.iso 2>/dev/null | head -1)

    if [[ -z "$ISO_FILE" ]]; then
        echo "No archzfs ISO found in $OUT_DIR/"
        exit 1
    fi
fi

info "Using ISO: $ISO_FILE"

# Create a tarball of our custom scripts
info "Creating script bundle..."

BUNDLE_DIR=$(mktemp -d)
mkdir -p "$BUNDLE_DIR/archzfs-scripts"

# Copy our scripts
cp "$CUSTOM_DIR/install-archzfs" "$BUNDLE_DIR/archzfs-scripts/"
cp "$CUSTOM_DIR/install-claude" "$BUNDLE_DIR/archzfs-scripts/"
cp "$CUSTOM_DIR/archsetup-zfs" "$BUNDLE_DIR/archzfs-scripts/"

# Copy archsetup if available
if [[ -d /home/cjennings/code/archsetup ]]; then
    info "Including archsetup..."
    cp -r /home/cjennings/code/archsetup "$BUNDLE_DIR/archzfs-scripts/"
    rm -rf "$BUNDLE_DIR/archzfs-scripts/archsetup/.git"
    rm -rf "$BUNDLE_DIR/archzfs-scripts/archsetup/.claude"
fi

# Create setup script
cat > "$BUNDLE_DIR/archzfs-scripts/setup.sh" << 'SETUP'
#!/bin/bash
# Run this after booting the archzfs ISO
# It copies the installation scripts to the right places

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Setting up archzfs installation scripts..."

# Copy scripts to /usr/local/bin
cp "$SCRIPT_DIR/install-archzfs" /usr/local/bin/
cp "$SCRIPT_DIR/install-claude" /usr/local/bin/
cp "$SCRIPT_DIR/archsetup-zfs" /usr/local/bin/
chmod +x /usr/local/bin/install-archzfs
chmod +x /usr/local/bin/install-claude
chmod +x /usr/local/bin/archsetup-zfs

# Copy archsetup to /code
if [[ -d "$SCRIPT_DIR/archsetup" ]]; then
    mkdir -p /code
    cp -r "$SCRIPT_DIR/archsetup" /code/
    echo "archsetup copied to /code/archsetup"
fi

echo ""
echo "Setup complete! You can now run:"
echo "  install-archzfs"
echo ""
SETUP
chmod +x "$BUNDLE_DIR/archzfs-scripts/setup.sh"

# Create the tarball
BUNDLE_FILE="$OUT_DIR/archzfs-scripts.tar.gz"
tar -czf "$BUNDLE_FILE" -C "$BUNDLE_DIR" archzfs-scripts
rm -rf "$BUNDLE_DIR"

info "Script bundle created: $BUNDLE_FILE"

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Setup Complete!${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "To install Arch on ZFS:"
echo ""
echo "1. Boot from the archzfs ISO:"
echo "   $(basename "$ISO_FILE")"
echo ""
echo "2. Connect to network, then download and extract scripts:"
echo "   # If you have a web server or USB drive with the bundle:"
echo "   tar -xzf archzfs-scripts.tar.gz"
echo "   cd archzfs-scripts && ./setup.sh"
echo ""
echo "3. Run the installer:"
echo "   install-archzfs"
echo ""
echo "Alternative: Copy scripts via SSH from another machine"
echo ""
