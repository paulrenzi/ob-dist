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
INSTALL_DIR="/userdata/system/outbreak"
LEGACY_DIR="/userdata/system/netplay-arcade"
TMP_DIR=$(mktemp -d)
LOG="/tmp/outbreak-install.log"
MASTER_PID_FILE="/tmp/outbreak_master.pid"

log() { echo "[$(date '+%H:%M:%S')] $1" | tee -a "$LOG"; }

# Catch unexpected failures so the user always sees an error message
trap '_rc=$?; if [ $_rc -ne 0 ]; then echo ""; echo "ERROR: Installer failed (exit code $_rc)"; echo "Check /tmp/outbreak-install.log for details"; echo "Common fixes: verify WiFi is connected, then try again"; fi' EXIT

log ""
log "=== Outbreak installer ==="
log ""

# ── Batocera version check ─────────────────────────────────────────────────────
_BATOCERA_VER_FILE="/usr/share/batocera/batocera.version"
if [ -f "$_BATOCERA_VER_FILE" ]; then
    _BATOCERA_VER=$(sed 's/[^0-9].*//' "$_BATOCERA_VER_FILE")
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

# ── Migrate legacy install path ──────────────────────────────────────────────
# Versions prior to v2.8 installed to /userdata/system/netplay-arcade/.
# Move everything to the new canonical path.
if [ -d "$LEGACY_DIR" ] && [ ! -d "$INSTALL_DIR" ]; then
    log "Migrating $LEGACY_DIR → $INSTALL_DIR ..."
    mv "$LEGACY_DIR" "$INSTALL_DIR"
elif [ -d "$LEGACY_DIR" ] && [ -d "$INSTALL_DIR" ]; then
    log "Cleaning up legacy $LEGACY_DIR (new path already exists)..."
    rm -rf "$LEGACY_DIR"
fi
# Update custom.sh boot hook to use new path
if [ -f /userdata/system/custom.sh ] && grep -q "netplay-arcade" /userdata/system/custom.sh 2>/dev/null; then
    sed -i 's|netplay-arcade|outbreak|g' /userdata/system/custom.sh
    log "  Updated custom.sh boot hook"
fi

# ── Resolve latest VERSIONED release from ob-dist ─────────────────────────────
# Only match v* tags — prevents picking up non-version releases like
# "standalone-x86_64" or "core-channel-x86_64" which are asset-only.
LATEST_TAG=$(curl -sf "https://api.github.com/repos/$DIST_REPO/releases" \
    | python3 -c "
import json, sys
releases = json.load(sys.stdin)
for r in releases:
    tag = r.get('tag_name', '')
    if tag.startswith('v') and not r.get('draft', False):
        print(tag)
        break
" 2>/dev/null)

if [ -z "$LATEST_TAG" ]; then
    # Fallback to /releases/latest if python3 parsing fails
    LATEST_TAG=$(curl -sf "https://api.github.com/repos/$DIST_REPO/releases/latest" \
        | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
fi

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

# ── Strip CRLF from all text files (Windows git protection) ──────────────────
# This is the CRITICAL fix: Windows git autocrlf commits \r\n which makes
# every .sh and .py file fail on Batocera with "$'\r': command not found".
# Strip unconditionally — it's idempotent and costs <1 second.
log "Fixing line endings..."
find "$EXTRACTED" -type f \( -name "*.sh" -o -name "*.py" -o -name "*.json" \
    -o -name "*.cfg" -o -name "*.xml" -o -name "*.html" -o -name "VERSION" \) \
    -exec sed -i 's/\r$//' {} + 2>/dev/null || true

# ── Stop running server — kill CHILDREN FIRST, then parent ────────────────────
# Critical fix: the old installer killed the parent first, which blocked on
# subprocess.run() calls (wget, rom-checker) that could take minutes to finish.
# Kill children first so the parent's subprocess.run() returns immediately.
log "Stopping any existing Outbreak processes..."

# Step 1: Kill child processes FIRST (wget, rom-checker, scraper, etc.)
for _pat in "wget.*archive.org" "wget.*github" rom-checker.sh media-scraper.py \
            cabinet-ui.py netplay-cores.sh gopher64; do
    pkill -9 -f "$_pat" 2>/dev/null || true
done
sleep 0.5

# Step 2: Now kill the master daemon (subprocess.run calls will have returned)
if [ -f "$MASTER_PID_FILE" ]; then
    _old_pid=$(cat "$MASTER_PID_FILE" 2>/dev/null)
    if [ -n "$_old_pid" ] && kill -0 "$_old_pid" 2>/dev/null; then
        log "  Killing master daemon (PID $_old_pid)..."
        kill "$_old_pid" 2>/dev/null
        _wait=0
        while kill -0 "$_old_pid" 2>/dev/null && [ $_wait -lt 6 ]; do
            sleep 0.5; _wait=$((_wait + 1))
        done
        if kill -0 "$_old_pid" 2>/dev/null; then
            kill -9 "$_old_pid" 2>/dev/null
            sleep 1
        fi
        if kill -0 "$_old_pid" 2>/dev/null; then
            log "  WARNING: PID $_old_pid still alive after SIGKILL"
        else
            log "  Master daemon stopped"
        fi
    else
        log "  No running daemon found"
    fi
    rm -f "$MASTER_PID_FILE"
fi

# Step 3: Final sweep — kill any remaining Python server processes
pkill -9 -f netplay-server.py 2>/dev/null || true
sleep 0.5

# Clear ALL lock files
rm -f /tmp/netplay_bootscan.lock /tmp/outbreak_boot.lock \
      /tmp/outbreak-media-scrape.lock /tmp/outbreak-media-scraper.lock \
      /tmp/outbreak-retroarch.lock /tmp/outbreak_download.lock \
      /tmp/outbreak_joining.flag \
      "$MASTER_PID_FILE" 2>/dev/null || true

# Step 4: Resume ES if it was suspended for Gopher64.
# Killing gopher64 above without resuming ES leaves the display dead —
# the wrapper is alive but ES binary is gone and won't restart without
# a resume signal.
if [ -p /tmp/es-resume.fifo ]; then
    log "  ES was suspended — resuming"
    # Restart triggerhappy first (Gopher64 kills it for SDL3 input)
    /etc/init.d/S292triggerhappy start 2>/dev/null || \
        /usr/sbin/thd --daemon --triggers /etc/triggerhappy/triggers.d/multimedia_keys.conf \
            --socket /var/run/thd.socket --pidfile /var/run/thd.pid /dev/input/event* 2>/dev/null
    # Clear suspend flag if present
    rm -f /tmp/suspend.please 2>/dev/null || true
    # Write to FIFO to unblock the wrapper (timeout prevents hang on stale FIFO)
    timeout 2 bash -c 'echo "resume" > /tmp/es-resume.fifo' 2>/dev/null || {
        log "  FIFO write timed out (stale) — removing"
        rm -f /tmp/es-resume.fifo 2>/dev/null || true
    }
    sleep 2
fi

log "Previous processes stopped."

# ── Force fresh ROM scan on version change (preserves ROM files) ──────────────
_PREV_VER=""
[ -f "$INSTALL_DIR/.version" ] && _PREV_VER=$(cat "$INSTALL_DIR/.version" 2>/dev/null)
if [ "$_PREV_VER" != "${LATEST_TAG:-}" ]; then
    log "  Version change ($_PREV_VER -> $LATEST_TAG) — clearing scan cache"
    rm -f /tmp/rom_scan_last_run 2>/dev/null || true
    # Gopher64 binary updates are now handled by timestamp-based cache
    # validation in netplay-cores.sh — no pin clearing needed here.
    # NOTE: .mame_blacklist and .console_blacklist are NOT cleared — they
    # represent persistent IA unavailability, not version-specific state.
    # NOTE: ROM files and pack markers are NEVER touched by the installer.
fi

# ── Backup current install for rollback ───────────────────────────────────────
BACKUP_DIR="/tmp/outbreak-rollback"
if [ -d "$INSTALL_DIR/scripts" ]; then
    rm -rf "$BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
    cp -r "$INSTALL_DIR/scripts" "$BACKUP_DIR/scripts" 2>/dev/null || true
    cp "$INSTALL_DIR/.version" "$BACKUP_DIR/.version" 2>/dev/null || true
    log "  Backup saved for rollback"
fi

# ── Copy ALL tarball contents — preserve existing config ─────────────────────
log "Copying files..."

# Backup user config
cp "$INSTALL_DIR/config.cfg" /tmp/outbreak-config-backup.cfg 2>/dev/null || true

# Copy everything from the tarball
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
    # Fallback if rsync unavailable
    log "  rsync not available — using cp fallback"
    cp -r "$EXTRACTED/." "$INSTALL_DIR/"
    # Restore config
    [ -f /tmp/outbreak-config-backup.cfg ] && \
        cp /tmp/outbreak-config-backup.cfg "$INSTALL_DIR/config.cfg"
    # Remove dev-only files
    rm -f "$INSTALL_DIR/Dockerfile" "$INSTALL_DIR/docker-compose.yml" \
          "$INSTALL_DIR/pyproject.toml" 2>/dev/null
    rm -rf "$INSTALL_DIR/.github" "$INSTALL_DIR/tests" \
           "$INSTALL_DIR/relay" "$INSTALL_DIR/patches" 2>/dev/null
    rm -f "$INSTALL_DIR/"*.md 2>/dev/null
}

chmod +x "$INSTALL_DIR/scripts/"*.sh "$INSTALL_DIR/scripts/service" 2>/dev/null || true

# ── Post-copy verification — FAIL if critical files are missing ───────────────
_install_ok=true
for _check_file in scripts/netplay-server.py scripts/boot.sh scripts/setup.sh \
                   scripts/netplay-broadcast.sh scripts/rom-checker.sh ui/index.html; do
    if [ ! -f "$INSTALL_DIR/$_check_file" ]; then
        log "ERROR: Critical file $_check_file missing after copy!"
        _install_ok=false
    fi
done

if [ "$_install_ok" != "true" ]; then
    log "FATAL: Install verification failed. Rolling back..."
    if [ -d "$BACKUP_DIR/scripts" ]; then
        cp -r "$BACKUP_DIR/scripts/." "$INSTALL_DIR/scripts/"
        [ -f "$BACKUP_DIR/.version" ] && cp "$BACKUP_DIR/.version" "$INSTALL_DIR/.version"
        log "  Rollback complete — previous version restored"
    fi
    rm -rf "$TMP_DIR" "$BACKUP_DIR"
    exit 1
fi

# Verify optional new files (warn but don't fail)
for _opt_file in scripts/gopher64-launch.sh n64_compat.json; do
    [ -f "$EXTRACTED/$_opt_file" ] && [ ! -f "$INSTALL_DIR/$_opt_file" ] && \
        log "WARNING: Optional file $_opt_file missing after copy"
done

log "All critical files verified."
rm -rf "$TMP_DIR" "$BACKUP_DIR"

# ── Write version stamp ──────────────────────────────────────────────────────
echo "$LATEST_TAG" > "$INSTALL_DIR/VERSION"
echo "$LATEST_TAG" > "$INSTALL_DIR/.version"
log "Version stamped: $LATEST_TAG"

# ── Start the server ─────────────────────────────────────────────────────────
log "Starting boot.sh install..."
bash "$INSTALL_DIR/scripts/boot.sh" install "${LATEST_TAG:-}"

# ── Health check — verify the server is actually responding ──────────────────
log "Running health check..."
_healthy=false
for _attempt in 1 2 3 4 5 6; do
    sleep 2
    if curl -sf http://localhost:8765/status >/dev/null 2>&1; then
        _healthy=true
        break
    fi
done

if [ "$_healthy" = "true" ]; then
    _running_ver=$(curl -sf http://localhost:8765/status 2>/dev/null \
        | python3 -c "import json,sys; print(json.load(sys.stdin).get('version','?'))" 2>/dev/null || echo "?")
    log "Outbreak $_running_ver is running and healthy."
else
    log "WARNING: Server not responding after 12 seconds."
    log "  Attempting direct boot..."
    rm -f /tmp/outbreak_boot.lock "$MASTER_PID_FILE"
    nohup bash "$INSTALL_DIR/scripts/boot.sh" boot >> /tmp/outbreak.log 2>&1 </dev/null &
    sleep 5
    if curl -sf http://localhost:8765/status >/dev/null 2>&1; then
        log "Outbreak running after retry."
    else
        log "ERROR: Server failed to start. Check /tmp/outbreak.log"
    fi
fi

log ""
log "Install complete. Log saved to $LOG"
