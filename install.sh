#!/bin/bash
# =============================================================================
# Outbreak (Batocera NetPlay Arcade) — one-line installer
#
# Paste into a Batocera terminal or SSH session:
#
#   curl -sL https://tinyurl.com/2ck7b59j | bash
#
# =============================================================================

set -e

DIST_REPO="paulrenzi/ob-dist"
INSTALL_DIR="/userdata/system/netplay-arcade"
TMP_DIR=$(mktemp -d)
LOG="/tmp/outbreak-install.log"
MASTER_PID_FILE="/tmp/outbreak_master.pid"

log() { echo "[$(date '+%H:%M:%S')] $1" | tee -a "$LOG"; }

log ""
log "=== Outbreak installer ==="
log ""

# ── Batocera version check ─────────────────────────────────────────────────────
_BATOCERA_VER_FILE="/usr/share/batocera/batocera.version"
if [ -f "$_BATOCERA_VER_FILE" ]; then
    _BATOCERA_VER=$(cat "$_BATOCERA_VER_FILE" | tr -d '[:alpha:][:space:]' | cut -d'.' -f1)
    if [ -n "$_BATOCERA_VER" ] && [ "$_BATOCERA_VER" -lt 38 ] 2>/dev/null; then
        log "ERROR: Outbreak requires Batocera v38 or later."
        log "       Detected: $(cat "$_BATOCERA_VER_FILE")"
        log "       Please update Batocera first: batocera-upgrade"
        rm -rf "$TMP_DIR"
        exit 1
    fi
elif [ ! -d "/userdata" ]; then
    log "WARNING: This doesn't look like a Batocera system (/userdata not found)."
    log "         Continuing anyway — some features may not work."
fi

# ── Resolve latest release from ob-dist ───────────────────────────────────────
LATEST_TAG=$(curl -sf "https://api.github.com/repos/$DIST_REPO/releases/latest" \
    | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')

if [ -z "$LATEST_TAG" ]; then
    log "ERROR: Could not find latest release."
    rm -rf "$TMP_DIR"
    exit 1
fi
log "Installing Outbreak $LATEST_TAG"

# ── Download tarball from release assets ──────────────────────────────────────
TARBALL_URL="https://github.com/$DIST_REPO/releases/download/$LATEST_TAG/outbreak-${LATEST_TAG}.tar.gz"
log "Downloading from $TARBALL_URL ..."
curl -sfL "$TARBALL_URL" -o "$TMP_DIR/outbreak.tar.gz" || {
    log "ERROR: Download failed. Check your internet connection."
    rm -rf "$TMP_DIR"
    exit 1
}
log "Download complete ($(du -h "$TMP_DIR/outbreak.tar.gz" | cut -f1))"

# ── Extract ───────────────────────────────────────────────────────────────────
log "Extracting..."
mkdir -p "$INSTALL_DIR"
tar xzf "$TMP_DIR/outbreak.tar.gz" -C "$TMP_DIR"

EXTRACTED=$(find "$TMP_DIR" -maxdepth 1 -type d -name "*Outbreak*" | head -1)
if [ -z "$EXTRACTED" ]; then
    log "ERROR: Could not find extracted directory."
    rm -rf "$TMP_DIR"
    exit 1
fi

# ── Stop running server and clear stale state ─────────────────────────────────
log "Stopping any existing Outbreak processes..."

# Kill the master daemon properly via PID file (matches boot.sh _kill_master)
if [ -f "$MASTER_PID_FILE" ]; then
    _old_pid=$(cat "$MASTER_PID_FILE" 2>/dev/null)
    if [ -n "$_old_pid" ] && kill -0 "$_old_pid" 2>/dev/null; then
        log "  Sending SIGTERM to master daemon (PID $_old_pid)..."
        kill "$_old_pid" 2>/dev/null
        _wait=0
        while kill -0 "$_old_pid" 2>/dev/null && [ $_wait -lt 6 ]; do
            sleep 0.5; ((_wait++))
        done
        if kill -0 "$_old_pid" 2>/dev/null; then
            log "  SIGTERM didn't stop it — sending SIGKILL..."
            kill -9 "$_old_pid" 2>/dev/null
            sleep 1
        fi
        if kill -0 "$_old_pid" 2>/dev/null; then
            log "  WARNING: PID $_old_pid still alive after SIGKILL"
        else
            log "  Master daemon stopped"
        fi
    else
        log "  PID file exists but process $_old_pid not running"
    fi
    rm -f "$MASTER_PID_FILE"
fi

# Mop up any stragglers not covered by the PID file
for _pat in rom-checker.sh media-scraper.py cabinet-ui.py netplay-cores.sh; do
    pkill -f "$_pat" 2>/dev/null || true
done
sleep 1

# Verify no old server is still running (no pgrep on Batocera, use pkill -0)
if pkill -0 -f netplay-server.py 2>/dev/null; then
    log "  WARNING: old server still alive after kill — sending SIGKILL to all..."
    pkill -9 -f netplay-server.py 2>/dev/null || true
    sleep 1
fi

# Clear lock files and PID file
rm -f /tmp/netplay_bootscan.lock /tmp/outbreak_boot.lock \
      /tmp/outbreak-media-scrape.lock /tmp/outbreak-media-scraper.lock \
      /tmp/outbreak-retroarch.lock /tmp/outbreak_download.lock \
      "$MASTER_PID_FILE" 2>/dev/null || true

# Force a fresh ROM scan when the version changes
_PREV_VER=""
[ -f "$INSTALL_DIR/.version" ] && _PREV_VER=$(cat "$INSTALL_DIR/.version" 2>/dev/null)
if [ "$_PREV_VER" != "${LATEST_TAG:-}" ]; then
    log "  Version change ($_PREV_VER → $LATEST_TAG) — clearing scan cache and blacklist"
    rm -f /tmp/rom_scan_last_run 2>/dev/null || true
    rm -f "$INSTALL_DIR/.mame_blacklist" 2>/dev/null || true
fi
log "Previous processes stopped and state cleared."

# ── Copy ALL tarball contents — preserve existing config ─────────────────────
# Future-proof: any new file in the tarball automatically lands on the console.
# Only config.cfg and dev-only files are excluded.
log "Copying files..."
rsync -a \
    --exclude="config.cfg" \
    --exclude=".git" \
    --exclude="tests/" \
    --exclude="relay/" \
    --exclude="*.md" \
    --exclude="Dockerfile" \
    --exclude="docker-compose.yml" \
    --exclude="pyproject.toml" \
    --exclude=".github/" \
    --exclude="patches/" \
    "$EXTRACTED/" "$INSTALL_DIR/" 2>/dev/null || {
    # Fallback if rsync unavailable: backup config, copy all, restore config
    log "  rsync not available — using cp fallback"
    [ -f "$INSTALL_DIR/config.cfg" ] && cp "$INSTALL_DIR/config.cfg" /tmp/outbreak-config-backup.cfg
    cp -r "$EXTRACTED/." "$INSTALL_DIR/"
    [ -f /tmp/outbreak-config-backup.cfg ] && cp /tmp/outbreak-config-backup.cfg "$INSTALL_DIR/config.cfg"
    # Remove dev-only files that shouldn't be on consoles
    rm -f "$INSTALL_DIR/Dockerfile" "$INSTALL_DIR/docker-compose.yml" "$INSTALL_DIR/pyproject.toml" 2>/dev/null
    rm -rf "$INSTALL_DIR/.github" "$INSTALL_DIR/tests" "$INSTALL_DIR/relay" "$INSTALL_DIR/patches" 2>/dev/null
    rm -f "$INSTALL_DIR/"*.md 2>/dev/null
}

chmod +x "$INSTALL_DIR/scripts/"*.sh "$INSTALL_DIR/scripts/service" 2>/dev/null || true

# Post-copy verification — warn if expected files are missing
for _check_file in scripts/netplay-server.py scripts/boot.sh ui/index.html; do
    [ ! -f "$INSTALL_DIR/$_check_file" ] && log "WARNING: $_check_file missing after install"
done
[ -f "$EXTRACTED/n64_compat.json" ] && [ ! -f "$INSTALL_DIR/n64_compat.json" ] && \
    log "WARNING: n64_compat.json missing after install"

rm -rf "$TMP_DIR"

# ── Write version stamp and start server ─────────────────────────────────────
echo "$LATEST_TAG" > "$INSTALL_DIR/VERSION"
echo "$LATEST_TAG" > "$INSTALL_DIR/.version"
log "Version stamped: $LATEST_TAG"

# Run setup (per-core overrides, ES system entries, etc.) then boot the daemon
log "Starting boot.sh install..."
bash "$INSTALL_DIR/scripts/boot.sh" install "${LATEST_TAG:-}"

# Verify the new daemon is running
sleep 3
if [ -f "$MASTER_PID_FILE" ]; then
    _new_pid=$(cat "$MASTER_PID_FILE" 2>/dev/null)
    if [ -n "$_new_pid" ] && kill -0 "$_new_pid" 2>/dev/null; then
        log "Outbreak $LATEST_TAG running (PID $_new_pid)"
    else
        log "WARNING: PID file exists but process not running. Retrying boot..."
        rm -f "$MASTER_PID_FILE" /tmp/outbreak_boot.lock
        bash "$INSTALL_DIR/scripts/boot.sh" boot >> "$INSTALL_DIR/logs/server.log" 2>&1 </dev/null &
        sleep 3
        if [ -f "$MASTER_PID_FILE" ] && kill -0 "$(cat "$MASTER_PID_FILE")" 2>/dev/null; then
            log "Outbreak $LATEST_TAG running (PID $(cat "$MASTER_PID_FILE"))"
        else
            log "ERROR: Server failed to start. Check $INSTALL_DIR/logs/server.log"
        fi
    fi
else
    log "WARNING: No PID file after install. Retrying boot..."
    rm -f /tmp/outbreak_boot.lock
    bash "$INSTALL_DIR/scripts/boot.sh" boot >> "$INSTALL_DIR/logs/server.log" 2>&1 </dev/null &
    sleep 3
    if [ -f "$MASTER_PID_FILE" ] && kill -0 "$(cat "$MASTER_PID_FILE")" 2>/dev/null; then
        log "Outbreak $LATEST_TAG running (PID $(cat "$MASTER_PID_FILE"))"
    else
        log "ERROR: Server failed to start. Check $INSTALL_DIR/logs/server.log"
    fi
fi

log "Install log saved to $LOG"
