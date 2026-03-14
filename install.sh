#!/bin/bash
# =============================================================================
# Outbreak (Batocera NetPlay Arcade) — one-line installer
#
# Paste into a Batocera terminal or SSH session:
#
#   curl -sL https://raw.githubusercontent.com/paulrenzi/ob-dist/main/install.sh | bash
#
# =============================================================================

set -e

DIST_REPO="paulrenzi/ob-dist"
INSTALL_DIR="/userdata/system/netplay-arcade"
TMP_DIR=$(mktemp -d)

echo ""
echo "=== Outbreak installer ==="
echo ""

# ── Batocera version check ─────────────────────────────────────────────────────
_BATOCERA_VER_FILE="/usr/share/batocera/batocera.version"
if [ -f "$_BATOCERA_VER_FILE" ]; then
    _BATOCERA_VER=$(cat "$_BATOCERA_VER_FILE" | tr -d '[:alpha:][:space:]' | cut -d'.' -f1)
    if [ -n "$_BATOCERA_VER" ] && [ "$_BATOCERA_VER" -lt 38 ] 2>/dev/null; then
        echo "ERROR: Outbreak requires Batocera v38 or later."
        echo "       Detected: $(cat "$_BATOCERA_VER_FILE")"
        echo "       Please update Batocera first: batocera-upgrade"
        rm -rf "$TMP_DIR"
        exit 1
    fi
elif [ ! -d "/userdata" ]; then
    echo "WARNING: This doesn't look like a Batocera system (/userdata not found)."
    echo "         Continuing anyway — some features may not work."
fi

# ── Resolve latest release from ob-dist ───────────────────────────────────────
LATEST_TAG=$(curl -sf "https://api.github.com/repos/$DIST_REPO/releases/latest" \
    | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')

if [ -z "$LATEST_TAG" ]; then
    echo "ERROR: Could not find latest release."
    rm -rf "$TMP_DIR"
    exit 1
fi
echo "Installing Outbreak $LATEST_TAG"

# ── Download tarball from release assets ──────────────────────────────────────
TARBALL_URL="https://github.com/$DIST_REPO/releases/download/$LATEST_TAG/outbreak-${LATEST_TAG}.tar.gz"
echo "Downloading..."
curl -sfL "$TARBALL_URL" -o "$TMP_DIR/outbreak.tar.gz" || {
    echo "ERROR: Download failed. Check your internet connection."
    rm -rf "$TMP_DIR"
    exit 1
}

# ── Extract ───────────────────────────────────────────────────────────────────
echo "Extracting..."
mkdir -p "$INSTALL_DIR"
tar xzf "$TMP_DIR/outbreak.tar.gz" -C "$TMP_DIR"

EXTRACTED=$(find "$TMP_DIR" -maxdepth 1 -type d -name "*Outbreak*" | head -1)
if [ -z "$EXTRACTED" ]; then
    echo "ERROR: Could not find extracted directory."
    rm -rf "$TMP_DIR"
    exit 1
fi

# ── Stop running server and clear stale state ─────────────────────────────────
echo "Stopping any existing Outbreak processes..."
pkill -f netplay-server.py 2>/dev/null || true
pkill -f rom-checker.sh 2>/dev/null || true
pkill -f media-scraper.py 2>/dev/null || true
pkill -f cabinet-ui.py 2>/dev/null || true
sleep 2
rm -f /tmp/netplay_bootscan.lock \
      /tmp/outbreak-media-scrape.lock /tmp/outbreak-media-scraper.lock \
      /tmp/outbreak-retroarch.lock 2>/dev/null || true
# Force a fresh ROM scan when the version changes
_PREV_VER=""
[ -f "$INSTALL_DIR/.version" ] && _PREV_VER=$(cat "$INSTALL_DIR/.version" 2>/dev/null)
if [ "$_PREV_VER" != "${LATEST_TAG:-}" ]; then
    rm -f /tmp/rom_scan_last_run 2>/dev/null || true
fi
echo "Previous processes stopped and temporary files cleared."

# Copy scripts and UI — preserve existing config
rsync -a --exclude="config.cfg" "$EXTRACTED/scripts/" "$INSTALL_DIR/scripts/" 2>/dev/null || \
    cp -r "$EXTRACTED/scripts/." "$INSTALL_DIR/scripts/"
rsync -a "$EXTRACTED/ui/"       "$INSTALL_DIR/ui/"     2>/dev/null || \
    cp -r "$EXTRACTED/ui/."     "$INSTALL_DIR/ui/"

chmod +x "$INSTALL_DIR/scripts/"*.sh "$INSTALL_DIR/scripts/service" 2>/dev/null || true

rm -rf "$TMP_DIR"

# ── Run installer ─────────────────────────────────────────────────────────────
bash "$INSTALL_DIR/scripts/boot.sh" install "${LATEST_TAG:-}"
