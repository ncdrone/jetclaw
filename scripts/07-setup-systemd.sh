#!/usr/bin/env bash
#
# 07-setup-systemd.sh — Create hardened systemd service for OpenClaw gateway
#
# Creates a system-level service (not user-level) with docker/tailscale
# dependencies, security flags, and auto-restart.
#
# Run ON the target machine as your admin user with sudo access.
#
# Usage:
#   ./scripts/07-setup-systemd.sh --user praxis
#   ./scripts/07-setup-systemd.sh --user praxis --port 18789 --start
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# ---------------------------------------------------------------------------
# CLI arguments
# ---------------------------------------------------------------------------
SERVICE_USER="${SERVICE_USER:-}"
GATEWAY_PORT="${GATEWAY_PORT:-18789}"
START_NOW="${START_NOW:-false}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)      [[ $# -ge 2 ]] || fatal "--user requires a value"; SERVICE_USER="$2"; shift 2 ;;
        --port)      [[ $# -ge 2 ]] || fatal "--port requires a value"; GATEWAY_PORT="$2"; shift 2 ;;
        --start)     START_NOW=true; shift ;;
        --dry-run)   DRY_RUN=true; shift ;;
        --help)      echo "Usage: $0 --user <name> [--port <port>] [--start] [--dry-run]"; exit 0 ;;
        *) fatal "Unknown argument: $1" ;;
    esac
done

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
require_sudo
prompt_value SERVICE_USER "Service user name"
require_service_user "$SERVICE_USER"

USER_HOME="/var/lib/$SERVICE_USER"
SYSTEMD_SERVICE="openclaw-${SERVICE_USER}.service"
SYSTEMD_PATH="/etc/systemd/system/$SYSTEMD_SERVICE"
OPENCLAW_BIN="${OPENCLAW_BIN:-$(which openclaw 2>/dev/null || echo "/usr/bin/openclaw")}"

command -v openclaw &>/dev/null || fatal "OpenClaw not installed. Run 06-install-openclaw.sh first."

phase "SETUP SYSTEMD SERVICE"

info "Creating systemd service: $SYSTEMD_SERVICE"
echo "  Service file: $SYSTEMD_PATH"
echo "  Runs as:      $SERVICE_USER"
echo "  Starts:       $OPENCLAW_BIN gateway run"
echo "  Auto-restart: on failure (10s delay)"
echo ""

# Build Requires= line conditionally
REQUIRES_LINE=""
if command -v docker &>/dev/null; then
    REQUIRES_LINE="Requires=docker.service"
fi

if ! $DRY_RUN; then
    sudo tee "$SYSTEMD_PATH" >/dev/null <<SVCEOF
[Unit]
Description=OpenClaw Gateway ($SERVICE_USER)
After=network-online.target docker.service tailscaled.service
Wants=network-online.target
$REQUIRES_LINE

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$USER_HOME
Environment=HOME=$USER_HOME
ExecStart=$OPENCLAW_BIN gateway run
Restart=on-failure
RestartSec=10

# Minimal security -- access control via sudoers + methodology
NoNewPrivileges=false
PrivateTmp=true
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SVCEOF
fi

run_cmd sudo systemctl daemon-reload
run_cmd sudo systemctl enable "$SYSTEMD_SERVICE"
success "Service created and enabled"

# ---------------------------------------------------------------------------
# Optionally start now
# ---------------------------------------------------------------------------
if $START_NOW || prompt_yn "Start the gateway now?" "y"; then
    run_cmd sudo systemctl start "$SYSTEMD_SERVICE"

    if ! $DRY_RUN; then
        # Determine wait time based on platform
        WAIT_SECS=60
        if [[ -f /proc/device-tree/model ]] && grep -qi "jetson\|orin\|tegra" /proc/device-tree/model 2>/dev/null; then
            info "Jetson detected. Gateway boot takes ~60 seconds on ARM..."
            WAIT_SECS=70
        else
            info "Waiting for gateway to boot..."
            WAIT_SECS=30
        fi

        echo -n "  "
        elapsed=0
        while (( elapsed < WAIT_SECS )); do
            if sudo ss -tlnp 2>/dev/null | grep -q ":${GATEWAY_PORT} "; then
                break
            fi
            echo -n "."
            sleep 5
            (( elapsed += 5 ))
        done
        echo ""

        if sudo ss -tlnp 2>/dev/null | grep -q ":${GATEWAY_PORT} "; then
            success "Gateway is listening on port $GATEWAY_PORT"
        else
            warn "Gateway not yet listening. It may still be booting."
            echo "  Check logs: sudo journalctl -u $SYSTEMD_SERVICE -f"
        fi
    fi
else
    info "Start later with: sudo systemctl start $SYSTEMD_SERVICE"
fi

echo ""
success "=== Systemd service configured ==="
