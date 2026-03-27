#!/usr/bin/env bash
#
# jetclaw-update.sh — Update OpenClaw and jetclaw tools on a running instance
#
# Run ON the target machine as the admin user with sudo access.
# Part of the jetclaw toolkit.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m'
    BLUE='\033[0;34m' BOLD='\033[1m' NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
fi

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
fatal()   { error "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<'EOF'
Usage: jetclaw-update.sh [options]

Updates OpenClaw CLI and optionally restarts the gateway.

Options:
  --user <name>          Service user (auto-detected if only one openclaw-* service exists)
  --skip-restart         Update CLI but don't restart the gateway
  --check                Just check for updates, don't install
  --help                 Show this help
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
SERVICE_USER=""
SKIP_RESTART=false
CHECK_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)
            [[ $# -ge 2 ]] || fatal "--user requires a value"
            SERVICE_USER="$2"; shift 2 ;;
        --skip-restart) SKIP_RESTART=true; shift ;;
        --check)        CHECK_ONLY=true; shift ;;
        --help)         usage ;;
        *) fatal "Unknown argument: $1" ;;
    esac
done

# ---------------------------------------------------------------------------
# Auto-detect service user from systemd
# ---------------------------------------------------------------------------
if [[ -z "$SERVICE_USER" ]]; then
    SERVICES=$(systemctl list-unit-files 'openclaw-*.service' --no-legend 2>/dev/null | awk '{print $1}' | sed 's/openclaw-//;s/\.service//')
    SERVICE_COUNT=$(echo "$SERVICES" | grep -c . 2>/dev/null || echo 0)

    if [[ "$SERVICE_COUNT" -eq 1 ]]; then
        SERVICE_USER="$SERVICES"
        info "Auto-detected service user: $SERVICE_USER"
    elif [[ "$SERVICE_COUNT" -gt 1 ]]; then
        echo "Multiple OpenClaw services found:"
        echo "$SERVICES" | while read -r s; do echo "  - $s"; done
        echo ""
        fatal "Specify which one with --user <name>"
    else
        fatal "No OpenClaw services found. Specify --user <name>"
    fi
fi

SYSTEMD_SERVICE="openclaw-${SERVICE_USER}.service"
USER_HOME="/var/lib/$SERVICE_USER"

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
if [[ $EUID -eq 0 ]]; then
    fatal "Do not run as root. Run as your admin user."
fi

command -v openclaw >/dev/null 2>&1 || fatal "OpenClaw CLI not found"
command -v npm >/dev/null 2>&1 || fatal "npm not found"

CURRENT_VERSION=$(openclaw --version 2>/dev/null || echo "unknown")
info "Current OpenClaw version: $CURRENT_VERSION"

# ---------------------------------------------------------------------------
# Check for updates
# ---------------------------------------------------------------------------
info "Checking npm for latest version..."
LATEST_VERSION=$(npm view openclaw version 2>/dev/null || echo "unknown")
info "Latest available version: $LATEST_VERSION"

if [[ "$CURRENT_VERSION" == "$LATEST_VERSION" ]]; then
    success "Already up to date ($CURRENT_VERSION)"
    if $CHECK_ONLY; then exit 0; fi

    if ! $CHECK_ONLY; then
        echo ""
        read -rp "  Already current. Force reinstall anyway? [y/N] " force
        [[ "$force" =~ ^[Yy]$ ]] || { info "Nothing to do."; exit 0; }
    fi
fi

if $CHECK_ONLY; then
    echo ""
    echo "  Update available: $CURRENT_VERSION -> $LATEST_VERSION"
    echo "  Run without --check to install."
    exit 0
fi

# ---------------------------------------------------------------------------
# Update
# ---------------------------------------------------------------------------
echo ""
info "Updating OpenClaw: $CURRENT_VERSION -> $LATEST_VERSION"

sudo npm install -g openclaw@latest
NEW_VERSION=$(openclaw --version 2>/dev/null || echo "unknown")
success "Updated to: $NEW_VERSION"

# ---------------------------------------------------------------------------
# Restart gateway
# ---------------------------------------------------------------------------
if ! $SKIP_RESTART; then
    echo ""
    if systemctl is-active --quiet "$SYSTEMD_SERVICE" 2>/dev/null; then
        info "Restarting $SYSTEMD_SERVICE..."
        sudo systemctl restart "$SYSTEMD_SERVICE"

        # Wait for boot
        echo -n "  Waiting for gateway..."
        for i in {1..15}; do
            if systemctl is-active --quiet "$SYSTEMD_SERVICE" 2>/dev/null; then
                break
            fi
            echo -n "."
            sleep 4
        done
        echo ""

        if systemctl is-active --quiet "$SYSTEMD_SERVICE" 2>/dev/null; then
            success "Gateway restarted and running"
        else
            warn "Gateway may still be booting. Check: sudo journalctl -u $SYSTEMD_SERVICE -f"
        fi
    else
        warn "$SYSTEMD_SERVICE is not running. Skipping restart."
        info "Start with: sudo systemctl start $SYSTEMD_SERVICE"
    fi
else
    info "Skipping restart (--skip-restart). Restart manually:"
    echo "  sudo systemctl restart $SYSTEMD_SERVICE"
fi

# ---------------------------------------------------------------------------
# Fix ownership (in case npm install touched anything in the user dir)
# ---------------------------------------------------------------------------
if [[ -d "$USER_HOME/.openclaw" ]]; then
    sudo chown -R "$SERVICE_USER:$SERVICE_USER" "$USER_HOME/.openclaw" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
success "Update complete: $CURRENT_VERSION -> $NEW_VERSION"
echo "  Service: $SYSTEMD_SERVICE"
echo "  Logs:    sudo journalctl -u $SYSTEMD_SERVICE -f"
