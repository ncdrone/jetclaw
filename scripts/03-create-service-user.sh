#!/usr/bin/env bash
#
# 03-create-service-user.sh — Create service user with scoped sudoers
#
# Run ON the target machine as your admin user with sudo access.
# Can be run standalone or called by the orchestrator.
#
# Usage:
#   ./scripts/03-create-service-user.sh --user praxis --admin-user ncd
#   ./scripts/03-create-service-user.sh --user praxis --github-email praxis@example.com
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# ---------------------------------------------------------------------------
# CLI arguments
# ---------------------------------------------------------------------------
SERVICE_USER="${SERVICE_USER:-}"
ADMIN_USER="${ADMIN_USER:-$(whoami)}"
GITHUB_EMAIL="${GITHUB_EMAIL:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)          [[ $# -ge 2 ]] || fatal "--user requires a value"; SERVICE_USER="$2"; shift 2 ;;
        --admin-user)    [[ $# -ge 2 ]] || fatal "--admin-user requires a value"; ADMIN_USER="$2"; shift 2 ;;
        --github-email)  [[ $# -ge 2 ]] || fatal "--github-email requires a value"; GITHUB_EMAIL="$2"; shift 2 ;;
        --dry-run)       DRY_RUN=true; shift ;;
        --help)          echo "Usage: $0 --user <name> [--admin-user <name>] [--github-email <email>] [--dry-run]"; exit 0 ;;
        *) fatal "Unknown argument: $1" ;;
    esac
done

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
require_sudo
phase "CREATE SERVICE USER"

prompt_value SERVICE_USER "Service user to create (e.g., praxis, ergon)"
validate_username "$SERVICE_USER"

USER_HOME="/var/lib/$SERVICE_USER"
OPENCLAW_DIR="$USER_HOME/.openclaw"
SECRETS_DIR="$USER_HOME/.secrets"

# ---------------------------------------------------------------------------
# Create user
# ---------------------------------------------------------------------------
if id "$SERVICE_USER" &>/dev/null; then
    warn "User '$SERVICE_USER' already exists. Skipping creation."
    run_cmd sudo passwd -l "$SERVICE_USER"
    pause_confirm "Use existing user '$SERVICE_USER'?"
else
    info "Creating service user: $SERVICE_USER"
    echo "  Home: $USER_HOME"
    echo "  Shell: /bin/bash (password locked, no SSH)"
    echo ""
    run_cmd sudo useradd --system --shell /bin/bash --create-home --home-dir "$USER_HOME" "$SERVICE_USER"
    run_cmd sudo passwd -l "$SERVICE_USER"
    success "Service user created"
fi

# ---------------------------------------------------------------------------
# Directories
# ---------------------------------------------------------------------------
info "Setting up directories..."
run_cmd sudo mkdir -p "$USER_HOME/config"
run_cmd sudo mkdir -p "$USER_HOME/workspace"
run_cmd sudo mkdir -p "$USER_HOME/logs"
run_cmd sudo mkdir -p "$OPENCLAW_DIR"
run_cmd sudo mkdir -p "$SECRETS_DIR"
run_cmd sudo chown -R "$SERVICE_USER:$SERVICE_USER" "$USER_HOME"
run_cmd sudo chmod 700 "$USER_HOME"
verify "Service user works (sudo -u $SERVICE_USER whoami)" sudo -u "$SERVICE_USER" whoami

# ---------------------------------------------------------------------------
# Git identity
# ---------------------------------------------------------------------------
info "Configuring git identity for $SERVICE_USER..."
run_cmd sudo -u "$SERVICE_USER" git config --global user.name "$SERVICE_USER"
if [[ -n "$GITHUB_EMAIL" ]]; then
    run_cmd sudo -u "$SERVICE_USER" git config --global user.email "$GITHUB_EMAIL"
fi
success "Git identity configured"

# ---------------------------------------------------------------------------
# Scoped sudoers
# ---------------------------------------------------------------------------
info "Setting up scoped sudoers (restricted sudo for service management)..."
echo "  $SERVICE_USER will be able to:"
echo "    - Start/stop/restart arsenal-* services"
echo "    - Reload nginx, test nginx config"
echo "    - Create arsenal service files"
echo "    - Manage Tailscale Serve"
echo "  $SERVICE_USER will NOT be able to:"
echo "    - Install system packages"
echo "    - Edit sudoers or system config"
echo "    - Access $ADMIN_USER's home directory"
echo "    - Run arbitrary commands as root"
echo ""

if ! $DRY_RUN; then
    sudo tee "/etc/sudoers.d/$SERVICE_USER" >/dev/null <<SUDOEOF
# OpenClaw service user: $SERVICE_USER
# Scoped sudo -- only specific commands allowed

# Systemd: manage arsenal-* services only
$SERVICE_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl daemon-reload
$SERVICE_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl start arsenal-*
$SERVICE_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop arsenal-*
$SERVICE_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart arsenal-*
$SERVICE_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl enable arsenal-*
$SERVICE_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl enable --now arsenal-*
$SERVICE_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl status arsenal-*
$SERVICE_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl disable arsenal-*

# Nginx: test and reload only
$SERVICE_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl reload nginx
$SERVICE_USER ALL=(ALL) NOPASSWD: /usr/sbin/nginx -t

# Arsenal service files
$SERVICE_USER ALL=(ALL) NOPASSWD: /usr/bin/tee /etc/systemd/system/arsenal-*

# Logs
$SERVICE_USER ALL=(ALL) NOPASSWD: /usr/bin/journalctl -u arsenal-*

# Tailscale serve
$SERVICE_USER ALL=(ALL) NOPASSWD: /usr/bin/tailscale serve *
SUDOEOF
    sudo chmod 440 "/etc/sudoers.d/$SERVICE_USER"
fi

verify "Sudoers valid" sudo visudo -c -f "/etc/sudoers.d/$SERVICE_USER"

echo ""
success "=== Service user fully configured ==="
