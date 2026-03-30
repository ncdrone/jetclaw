#!/usr/bin/env bash
#
# 08-summary.sh — Post-install summary and next steps
#
# Displays configuration summary, pairing instructions, and common commands.
# Can also run post-install verification via tools/jetclaw-verify.sh.
#
# Run ON the target machine.
#
# Usage:
#   ./scripts/08-summary.sh --user praxis
#   ./scripts/08-summary.sh --user praxis --port 18789
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# ---------------------------------------------------------------------------
# CLI arguments
# ---------------------------------------------------------------------------
SERVICE_USER="${SERVICE_USER:-}"
ADMIN_USER="${ADMIN_USER:-$(whoami)}"
GATEWAY_PORT="${GATEWAY_PORT:-18789}"
SKIP_VERIFY="${SKIP_VERIFY:-false}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)          [[ $# -ge 2 ]] || fatal "--user requires a value"; SERVICE_USER="$2"; shift 2 ;;
        --admin-user)    [[ $# -ge 2 ]] || fatal "--admin-user requires a value"; ADMIN_USER="$2"; shift 2 ;;
        --port)          [[ $# -ge 2 ]] || fatal "--port requires a value"; GATEWAY_PORT="$2"; shift 2 ;;
        --skip-verify)   SKIP_VERIFY=true; shift ;;
        --help)          echo "Usage: $0 --user <name> [--port <port>] [--skip-verify]"; exit 0 ;;
        *) fatal "Unknown argument: $1" ;;
    esac
done

prompt_value SERVICE_USER "Service user name"

USER_HOME="/var/lib/$SERVICE_USER"
OPENCLAW_DIR="$USER_HOME/.openclaw"
WORKSPACE_DIR="$OPENCLAW_DIR/workspace"
SECRETS_DIR="$USER_HOME/.secrets"
SYSTEMD_SERVICE="openclaw-${SERVICE_USER}.service"
HOSTNAME_NEW=$(hostnamectl --static 2>/dev/null || hostname)

# Get Tailscale info if available
TS_FQDN=""
if command -v tailscale &>/dev/null && tailscale status &>/dev/null; then
    TS_FQDN=$(tailscale status --json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Self',{}).get('DNSName','').rstrip('.'))" 2>/dev/null || echo "")
fi

CURRENT_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "")

# ---------------------------------------------------------------------------
# Run verification
# ---------------------------------------------------------------------------
if ! $SKIP_VERIFY; then
    REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
    VERIFY_SCRIPT="$REPO_ROOT/tools/jetclaw-verify.sh"

    if [[ -x "$VERIFY_SCRIPT" ]]; then
        echo ""
        if prompt_yn "Run verification checks?" "y"; then
            bash "$VERIFY_SCRIPT"
            echo ""
        fi
    fi

    # Run openclaw doctor if gateway is up
    if systemctl is-active --quiet "$SYSTEMD_SERVICE" 2>/dev/null; then
        if prompt_yn "Run 'openclaw doctor' to validate?" "y"; then
            sudo -u "$SERVICE_USER" openclaw doctor --fix 2>/dev/null || warn "Doctor reported issues."
        fi

        if prompt_yn "Run 'openclaw security audit'?" "y"; then
            sudo -u "$SERVICE_USER" openclaw security audit --deep 2>/dev/null || warn "Security audit reported issues."
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
phase "INSTALLATION COMPLETE"

echo -e "  ${BOLD}Configuration:${NC}"
echo "    Hostname:         $HOSTNAME_NEW"
echo "    Service user:     $SERVICE_USER"
echo "    Home directory:   $USER_HOME"
echo "    OpenClaw config:  $OPENCLAW_DIR/openclaw.json"
echo "    Workspace:        $WORKSPACE_DIR"
echo "    Gateway port:     $GATEWAY_PORT"
echo "    Systemd service:  $SYSTEMD_SERVICE"
echo "    Gateway token:    $SECRETS_DIR/gateway-token"
echo "    Log file:         ${LOG_FILE:-/tmp/openclaw-install-*.log}"

if [[ -n "$TS_FQDN" ]]; then
    echo "    Tailscale host:   $TS_FQDN"
fi

# Best SSH target
SSH_TARGET="$HOSTNAME_NEW"
if [[ -z "$TS_FQDN" ]]; then
    SSH_TARGET="${CURRENT_IP:-$HOSTNAME_NEW}"
fi

echo ""
echo -e "  ${BOLD}Next Steps:${NC}"
echo ""
STEP=1
echo "  $STEP. ${BOLD}Read the gateway token:${NC}"
echo "     ssh $SSH_TARGET"
echo "     sudo cat $SECRETS_DIR/gateway-token"
echo ""
((STEP++))
echo "  $STEP. ${BOLD}Pair your browser${NC} (first time, via SSH tunnel):"
echo "     On your Mac, open two terminals:"
echo "       Terminal 1: ssh -N -L $GATEWAY_PORT:127.0.0.1:$GATEWAY_PORT $ADMIN_USER@$SSH_TARGET"
echo "       Terminal 2: open \"http://localhost:$GATEWAY_PORT/?token=YOUR_TOKEN\""
echo "     The tunnel is supposed to hang (that's the -N flag)."
echo ""

if [[ -n "$TS_FQDN" ]]; then
    ((STEP++))
    echo "  $STEP. ${BOLD}Enable Tailscale dashboard access${NC}:"
    echo "     In the localhost dashboard: Config > Gateway > Auth > 'Allow Tailscale'"
    echo "     Then approve your browser:"
    echo "       sudo -u $SERVICE_USER openclaw devices list"
    echo "       sudo -u $SERVICE_USER openclaw devices approve <id>"
    echo "     After pairing, access directly at:"
    echo "       https://$TS_FQDN/?token=YOUR_TOKEN"
    echo ""
fi

((STEP++))
echo "  $STEP. ${BOLD}Manage the service:${NC}"
echo "       sudo systemctl status $SYSTEMD_SERVICE"
echo "       sudo journalctl -u $SYSTEMD_SERVICE -f"
echo "       sudo systemctl restart $SYSTEMD_SERVICE"
echo ""
((STEP++))
echo "  $STEP. ${BOLD}Run commands as $SERVICE_USER:${NC}"
echo "       sudo -u $SERVICE_USER openclaw <command>"
echo ""

echo "  Common operations:"
echo "    # Fix file ownership (if something runs as wrong user)"
echo "    sudo chown -R $SERVICE_USER:$SERVICE_USER $OPENCLAW_DIR"
echo ""
echo "    # Edit config"
echo "    sudo -u $SERVICE_USER nano $OPENCLAW_DIR/openclaw.json"
echo ""
echo "    # NEVER run openclaw commands without sudo -u $SERVICE_USER"
echo "    # This creates files in the wrong place owned by the wrong user."
echo ""

success "Done. Welcome to $HOSTNAME_NEW."
