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
    if [ -n "$_BATOCERA_VER" ] && [ "$_BATOCERA_VER" -lt 41 ] 2>/dev/null; then
        echo ""
        echo "============================================"
        echo "  Outbreak requires Batocera v41 or newer"
        echo "============================================"
        echo ""
        echo "  Your version:  Batocera $(cat "$_BATOCERA_VER_FILE")"
        echo "  Required:      Batocera 41+"
        echo ""
        echo "  How to update:"
        echo "    1. Go to Main Menu > System Settings > Update"
        echo "    2. Or run: batocera-upgrade"
        echo "    3. Reboot, then run this installer again"
        echo ""
        echo "  Download latest: https://batocera.org/download"
        echo "============================================"
        echo ""
        log "ERROR: Batocera $(cat "$_BATOCERA_VER_FILE") is too old. Need v41+."
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

# ── Verify SHA-256 checksum (if available) ───────────────────────────────────
CHECKSUM_URL="https://github.com/$DIST_REPO/releases/download/$LATEST_TAG/outbreak-${LATEST_TAG}.tar.gz.sha256"
if curl -sfL --max-time 15 "$CHECKSUM_URL" -o "$TMP_DIR/outbreak.tar.gz.sha256" 2>/dev/null; then
    _expected_hash=$(awk '{print $1}' "$TMP_DIR/outbreak.tar.gz.sha256")
    _actual_hash=$(sha256sum "$TMP_DIR/outbreak.tar.gz" | awk '{print $1}')
    if [ "$_expected_hash" != "$_actual_hash" ]; then
        log "ERROR: Checksum mismatch! Download may be corrupted."
        log "  Expected: $_expected_hash"
        log "  Got:      $_actual_hash"
        rm -rf "$TMP_DIR"
        exit 1
    fi
    log "Checksum verified ✓"
else
    log "No checksum file available — skipping verification"
fi

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

# Guard: kill active pack download (will restart on next boot scan) but wait
# for extraction (killing mid-extract corrupts ROM files).
_SCAN_STATE="$INSTALL_DIR/rom_scan_state.json"
if [ -f "$_SCAN_STATE" ]; then
    _dl_phase=$(python3 -c "import json,sys; d=json.load(open('$_SCAN_STATE')); print(d.get('phase',''))" 2>/dev/null)
    if [ "$_dl_phase" = "downloading" ]; then
        _dl_pid=$(python3 -c "import json,sys; d=json.load(open('$_SCAN_STATE')); print(d.get('pid',0))" 2>/dev/null)
        if [ -n "$_dl_pid" ] && [ "$_dl_pid" != "0" ] && kill -0 "$_dl_pid" 2>/dev/null; then
            log "  Killing active pack download (PID $_dl_pid) — will resume after update"
            kill "$_dl_pid" 2>/dev/null
            sleep 1
            kill -9 "$_dl_pid" 2>/dev/null
            rm -f /userdata/fbneo_pack.zip.part  # remove partial download (never touch final .zip)
        fi
    fi
    # Wait for extraction — killing mid-extract corrupts ROM files
    _dl_phase=$(python3 -c "import json,sys; d=json.load(open('$_SCAN_STATE')); print(d.get('phase',''))" 2>/dev/null)
    if [ "$_dl_phase" = "extracting" ]; then
        log "  Pack extraction in progress — waiting..."
        while true; do
            sleep 5
            _dl_phase=$(python3 -c "import json,sys; d=json.load(open('$_SCAN_STATE')); print(d.get('phase',''))" 2>/dev/null)
            [ "$_dl_phase" = "extracting" ] || break
        done
        log "  Extraction finished — continuing install"
    fi
fi

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
    # Restart triggerhappy only if not already running (prevents duplicate daemon)
    if ! pidof thd >/dev/null 2>&1; then
        /etc/init.d/S292triggerhappy start 2>/dev/null || \
            /usr/sbin/thd --daemon --triggers /etc/triggerhappy/triggers.d/multimedia_keys.conf \
                --socket /var/run/thd.socket --pidfile /var/run/thd.pid /dev/input/event* 2>/dev/null
    fi
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

# ── Atomic install via apply_update() ────────────────────────────────────────
# Uses the same atomic mv-swap that regular updates use.  On first install,
# there's no existing INSTALL_DIR so nothing to preserve — apply_update
# handles this gracefully.  On reinstall/upgrade, config and cores are
# automatically preserved.
log "Applying update (atomic swap)..."
bash "$EXTRACTED/scripts/setup.sh" apply-update "$EXTRACTED" "$LATEST_TAG"
if [ $? -ne 0 ]; then
    log "FATAL: apply-update failed."
    rm -rf "$TMP_DIR"
    exit 1
fi
rm -rf "$TMP_DIR"
log "Files installed: $LATEST_TAG"

# ── Start the server ─────────────────────────────────────────────────────────
log "Starting boot.sh install..."
bash "$INSTALL_DIR/scripts/boot.sh" install "${LATEST_TAG:-}"

# ── Health check — verify the server is actually responding ──────────────────
log "Running health check..."
_healthy=false
for _attempt in 1 2 3 4 5 6; do
    sleep 2
    printf "\r  Waiting for server... %d/6" "$_attempt" >&2
    if curl -sf http://localhost:8765/status >/dev/null 2>&1; then
        _healthy=true
        printf "\r                              \r" >&2
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
    nohup bash "$INSTALL_DIR/scripts/boot.sh" boot install >> /tmp/outbreak.log 2>&1 </dev/null &
    sleep 5
    if curl -sf http://localhost:8765/status >/dev/null 2>&1; then
        log "Outbreak running after retry."
    else
        log "ERROR: Server failed to start. Check /tmp/outbreak.log"
    fi
fi

# ── Report install to registry (single attempt, fail-silent) ──────────────────
# Foreground so it completes before the script exits (background curl gets
# killed when the parent shell terminates). Short timeouts prevent hanging.
# No retries, no background processes, no persistent network activity.
_bato_ver=""
[ -f "$_BATOCERA_VER_FILE" ] && _bato_ver=$(cat "$_BATOCERA_VER_FILE" 2>/dev/null)
curl -sf -X POST "https://relay.outbreakarcade.com/api/installs" \
    -H "Content-Type: application/json" \
    -d "{\"version\":\"${LATEST_TAG}\",\"batocera\":\"${_bato_ver}\",\"event\":\"install\"}" \
    --connect-timeout 3 --max-time 5 >/dev/null 2>&1 || true

log ""
log "Install complete. Log saved to $LOG"
