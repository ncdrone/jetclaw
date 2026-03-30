#!/usr/bin/env bash
#
# 02-install-tailscale.sh — Install Tailscale and lock SSH to Tailscale network
#
# Run ON the target machine as your admin user with sudo access.
# Can be run standalone or called by the orchestrator.
#
# Usage:
#   ./scripts/02-install-tailscale.sh --hostname praxis --admin-user ncd
#   ./scripts/02-install-tailscale.sh --tailscale-auth tskey-auth-xxx
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# ---------------------------------------------------------------------------
# CLI arguments
# ---------------------------------------------------------------------------
HOSTNAME_NEW="${HOSTNAME_NEW:-$(hostnamectl --static 2>/dev/null || hostname)}"
ADMIN_USER="${ADMIN_USER:-$(whoami)}"
SERVICE_USER="${SERVICE_USER:-}"
TAILSCALE_AUTH="${TAILSCALE_AUTH:-}"
SKIP_SSH_LOCK="${SKIP_SSH_LOCK:-false}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --hostname)        [[ $# -ge 2 ]] || fatal "--hostname requires a value"; HOSTNAME_NEW="$2"; shift 2 ;;
        --admin-user)      [[ $# -ge 2 ]] || fatal "--admin-user requires a value"; ADMIN_USER="$2"; shift 2 ;;
        --service-user)    [[ $# -ge 2 ]] || fatal "--service-user requires a value"; SERVICE_USER="$2"; shift 2 ;;
        --tailscale-auth)  [[ $# -ge 2 ]] || fatal "--tailscale-auth requires a value"; TAILSCALE_AUTH="$2"; shift 2 ;;
        --skip-ssh-lock)   SKIP_SSH_LOCK=true; shift ;;
        --dry-run)         DRY_RUN=true; shift ;;
        --help)            echo "Usage: $0 [--hostname <name>] [--admin-user <name>] [--tailscale-auth <key>] [--dry-run]"; exit 0 ;;
        *) fatal "Unknown argument: $1" ;;
    esac
done

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
require_sudo
phase "INSTALL TAILSCALE"

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
if command -v tailscale &>/dev/null; then
    success "Tailscale already installed"
else
    info "Installing Tailscale..."
    if ! $DRY_RUN; then
        local_tmp=$(mktemp)
        curl -fsSL https://tailscale.com/install.sh -o "$local_tmp"
        if [[ -s "$local_tmp" ]] && head -1 "$local_tmp" | grep -q '^#!'; then
            sh "$local_tmp"
        else
            rm -f "$local_tmp"
            fatal "Tailscale install script download failed or is invalid"
        fi
        rm -f "$local_tmp"
    fi
fi

# ---------------------------------------------------------------------------
# Authenticate
# ---------------------------------------------------------------------------
TS_STATE=$(tailscale status --json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('BackendState',''))" 2>/dev/null || echo "")
if [[ "$TS_STATE" == "Running" ]]; then
    success "Tailscale already connected"
else
    info "Bringing Tailscale up..."
    if [[ -n "$TAILSCALE_AUTH" ]]; then
        run_cmd sudo tailscale up --ssh --auth-key="$TAILSCALE_AUTH"
    else
        echo "  This will open a Tailscale login URL."
        action_required "When the URL appears, open it in your browser and log in\n  to your Tailscale account to authorize this machine."
        pause_confirm "Ready to run 'tailscale up'?"
        sudo tailscale up --ssh --reset || sudo tailscale up --ssh --operator="${SERVICE_USER:-}" || warn "Tailscale up had issues."
    fi
fi

# ---------------------------------------------------------------------------
# Get Tailscale info
# ---------------------------------------------------------------------------
TS_IP="unknown"
TS_FQDN=""
if ! $DRY_RUN; then
    TS_IP=$(tailscale ip -4 2>/dev/null || echo "unknown")
    TS_FQDN=$(tailscale status --json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Self',{}).get('DNSName','').rstrip('.'))" 2>/dev/null || echo "")
    success "Tailscale connected"
    info "Tailscale IP:       $TS_IP"
    info "Tailscale hostname: $TS_FQDN"
fi

# ---------------------------------------------------------------------------
# Lock SSH to Tailscale
# ---------------------------------------------------------------------------
if ! $SKIP_SSH_LOCK; then
    echo ""
    info "Locking SSH to Tailscale network only..."
    echo "  This removes temporary LAN SSH rules and restricts"
    echo "  SSH access to Tailscale IPs (100.64.0.0/10)."
    echo ""

    action_required "After this step, you can ONLY SSH via Tailscale.\n  Make sure your Mac is on the same Tailscale network.\n\n  Test from your Mac:\n    ssh $ADMIN_USER@${TS_FQDN:-$HOSTNAME_NEW}"

    pause_confirm "Your Mac is on Tailscale and you can reach this machine?"

    run_shell "sudo ufw delete allow from 192.168.0.0/16 to any port 22 2>/dev/null || true"
    run_shell "sudo ufw delete allow from 10.0.0.0/8 to any port 22 2>/dev/null || true"
    run_shell "sudo ufw allow from 100.64.0.0/10 to any port 22"
    success "SSH restricted to Tailscale network"
fi

# ---------------------------------------------------------------------------
# Mac SSH setup instructions
# ---------------------------------------------------------------------------
TS_IP_CURRENT=$(tailscale ip -4 2>/dev/null || echo '<jetson-ip>')
TS_HOST="${TS_FQDN:-$HOSTNAME_NEW.your-tailnet.ts.net}"

echo ""
info "Run these commands on your Mac to set up SSH access:"
echo ""
echo -e "${GREEN}--- COPY FROM HERE ---${NC}"
echo ""
cat <<SSHBLOCK
ssh-keygen -t ed25519 -C "$HOSTNAME_NEW" -f ~/.ssh/id_ed25519_$HOSTNAME_NEW
ssh-copy-id -i ~/.ssh/id_ed25519_$HOSTNAME_NEW.pub $ADMIN_USER@$TS_IP_CURRENT
ssh-add --apple-use-keychain ~/.ssh/id_ed25519_$HOSTNAME_NEW
cat >> ~/.ssh/config << 'EOF'

Host $HOSTNAME_NEW
    HostName $TS_HOST
    User $ADMIN_USER
    IdentityFile ~/.ssh/id_ed25519_$HOSTNAME_NEW
    IdentitiesOnly yes
    ServerAliveInterval 30
    ServerAliveCountMax 3
EOF
SSHBLOCK
echo ""
echo -e "${GREEN}--- TO HERE ---${NC}"
echo ""
info "After running the above, test with: ssh $HOSTNAME_NEW"

echo ""
success "=== Tailscale setup complete ==="

# Export for orchestrator
export TS_IP TS_FQDN
