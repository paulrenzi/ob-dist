#!/bin/bash
# =============================================================================
# Outbreak — TARGETED link-repair installer (NOT the public channel)
#
#   curl -sL https://raw.githubusercontent.com/paulrenzi/ob-dist/main/install-linkfix.sh | bash
#
# WHO THIS IS FOR
# One console whose WiFi keeps dropping because of two things, BOTH of which
# were applied by hand at the machine on 2026-07-22 and BOTH of which die at the
# next reboot:
#   1. The uplink blackholes large frames (AT&T) -> needs `mtu 1280`.
#   2. ConnMan background scanning steers the radio between mesh BSSIDs, and each
#      roam can MCU-timeout the binary MT7902 driver into a firmware reset.
# Neither had a home in the shipped tree. The MTU clamp existed only inside
# `tailscale-service`, which is DISABLED on customer clones (Model C) -- so on
# the exact consoles that need it, nothing applied it.
#
# WHY IT IS A SEPARATE SCRIPT FROM install.sh
# This installs a PRERELEASE, pinned by exact tag. It must reach the one console
# that needs it and NOTHING else. Three independent things keep it contained,
# and it only takes one of them to hold:
#   1. This script pins OUTBREAK_PIN_TAG -- no "latest" resolution happens.
#   2. The public install.sh skips prereleases when resolving a tag.
#   3. The console auto-updater polls /releases/latest, which by definition
#      excludes prereleases.
# Do NOT promote this tag to `latest` and do NOT fold this script into
# install.sh. The containment IS the feature.
#
# ORDERING IS LOAD-BEARING
# A fix that ships inside the payload cannot be applied until the payload
# arrives -- over the very link that is broken. So the repair runs FIRST, costs
# zero network, and holds until reboot even if every download below fails. The
# payload's only job is making the repair survive reboots (see link-policy.sh,
# which boot.sh runs on every boot).
# =============================================================================

set -u

PIN_TAG="v2.27.12-rc10-linkfix"
DIST_REPO="paulrenzi/ob-dist"
INSTALL_DIR="/userdata/system/outbreak"
LINKCONF="/userdata/system/link.conf"
LOG="/tmp/outbreak-linkfix.log"

# Values for this console. Kept explicit rather than auto-detected: an MTU guess
# on a healthy console is a great way to break a console that was fine.
LINK_MTU="1280"
LINK_BGSCAN="false"

log() { echo "[$(date '+%H:%M:%S')] $1" | tee -a "$LOG"; }

log ""
log "=== Outbreak link-repair installer ($PIN_TAG) ==="
log ""

# ── PHASE 1: repair the link. No network. Must not fail the script. ──────────
log "Phase 1/2: repairing the link (no network needed)"

mkdir -p /userdata/system
[ -f "$LINKCONF" ] || : > "$LINKCONF"
sed -i '/^uplink_mtu=/d;/^wifi_bgscan=/d' "$LINKCONF" 2>/dev/null || true
printf 'uplink_mtu=%s\nwifi_bgscan=%s\n' "$LINK_MTU" "$LINK_BGSCAN" >> "$LINKCONF"
log "  wrote $LINKCONF (uplink_mtu=$LINK_MTU wifi_bgscan=$LINK_BGSCAN)"

# Stop OUR load on the radio before anything else. The tunnel watchdog is not
# reliably the master's child, so killing the master later can reparent it to
# init and leave a reconnect loop running for the whole download -- competing
# for the exact radio the download needs.
for _pat in tunnel-watchdog.sh dbclient; do
    if pkill -9 -f "$_pat" 2>/dev/null; then
        log "  stopped $_pat (was competing for the radio)"
    fi
done

# Prefer the installed script if this console already has one; otherwise inline
# the same two operations, because on a console that has never taken this update
# there is no link-policy.sh yet and the link still has to come up.
if [ -x "$INSTALL_DIR/scripts/link-policy.sh" ]; then
    bash "$INSTALL_DIR/scripts/link-policy.sh" apply --restart-connman || true
else
    _if=$(ip route 2>/dev/null | awk '/^default/{print $5; exit}')
    if [ -n "$_if" ]; then
        ip link set "$_if" mtu "$LINK_MTU" 2>/dev/null \
            && log "  uplink $_if mtu -> $LINK_MTU" \
            || log "  WARN: could not set $_if mtu $LINK_MTU"
    else
        log "  WARN: no default route -- MTU clamp deferred to next boot"
    fi
    if [ -f /etc/connman/main.conf ] \
       && [ "$(grep -m1 '^BackgroundScanning' /etc/connman/main.conf 2>/dev/null | cut -d= -f2- | tr -d ' ')" != "false" ]; then
        grep -q '^\[General\]' /etc/connman/main.conf || printf '[General]\n' >> /etc/connman/main.conf
        sed -i '/^BackgroundScanning/d' /etc/connman/main.conf
        sed -i "/^\[General\]/a BackgroundScanning=false" /etc/connman/main.conf
        log "  connman BackgroundScanning -> false (roam trigger disabled)"
        # /etc is overlay-backed; without this the edit dies at reboot, which is
        # the exact failure mode this whole exercise exists to end.
        if command -v batocera-save-overlay >/dev/null 2>&1; then
            log "  saving overlay (takes a moment)..."
            batocera-save-overlay >/dev/null 2>&1 \
                && log "  overlay saved" || log "  WARN: batocera-save-overlay failed"
        fi
    fi
fi

log "Link repaired. This holds until reboot even if Phase 2 fails completely."
# Let the radio settle after a connman restart before pulling anything.
sleep 5

# ── PHASE 2: make it durable. Needs network; safe to fail and retry. ─────────
log ""
log "Phase 2/2: installing $PIN_TAG so the repair survives reboots"

_TMP=$(mktemp -d)
_INSTALLER="$_TMP/install.sh"
if ! curl -fL --connect-timeout 20 --retry 5 --retry-delay 3 --retry-all-errors \
        "https://github.com/$DIST_REPO/releases/download/$PIN_TAG/install.sh" \
        -o "$_INSTALLER"; then
    log ""
    log "Could not download the installer for $PIN_TAG."
    log "The link repair from Phase 1 IS STILL ACTIVE -- your WiFi should be usable now."
    log "It will be lost on the next reboot. Re-run this same command to try again."
    rm -rf "$_TMP"
    exit 1
fi

# The pinned installer does the rest: resumable download of the (small, no-cores)
# tarball, checksum, atomic apply-update, boot. OUTBREAK_PIN_TAG stops it from
# resolving a tag of its own.
OUTBREAK_PIN_TAG="$PIN_TAG" bash "$_INSTALLER"
_rc=$?
rm -rf "$_TMP"

if [ "$_rc" -ne 0 ]; then
    log ""
    log "Install did not complete (exit $_rc), but the Phase 1 link repair is still active."
    log "Re-running this command resumes the download where it stopped."
    exit "$_rc"
fi

log ""
log "Done. The link settings are now in $LINKCONF and are re-applied on every boot."
