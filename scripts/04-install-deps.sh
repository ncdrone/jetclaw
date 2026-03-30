#!/usr/bin/env bash
#
# 04-install-deps.sh — Install infrastructure dependencies
#
# Installs: Node.js, Docker, PostgreSQL, Nginx, Chromium
# Each component is skippable with --skip-* flags.
#
# Run ON the target machine as your admin user with sudo access.
#
# Usage:
#   ./scripts/04-install-deps.sh --user praxis
#   ./scripts/04-install-deps.sh --user praxis --skip-docker --skip-postgres
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# ---------------------------------------------------------------------------
# CLI arguments
# ---------------------------------------------------------------------------
SERVICE_USER="${SERVICE_USER:-}"
ADMIN_USER="${ADMIN_USER:-$(whoami)}"
DB_NAME="${DB_NAME:-}"
DB_USER="${DB_USER:-}"
DB_PASS="${DB_PASS:-}"
SKIP_DOCKER="${SKIP_DOCKER:-false}"
SKIP_POSTGRES="${SKIP_POSTGRES:-false}"
SKIP_NGINX="${SKIP_NGINX:-false}"
SKIP_CHROMIUM="${SKIP_CHROMIUM:-false}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)           [[ $# -ge 2 ]] || fatal "--user requires a value"; SERVICE_USER="$2"; shift 2 ;;
        --admin-user)     [[ $# -ge 2 ]] || fatal "--admin-user requires a value"; ADMIN_USER="$2"; shift 2 ;;
        --db-name)        [[ $# -ge 2 ]] || fatal "--db-name requires a value"; DB_NAME="$2"; shift 2 ;;
        --db-user)        [[ $# -ge 2 ]] || fatal "--db-user requires a value"; DB_USER="$2"; shift 2 ;;
        --db-pass)        [[ $# -ge 2 ]] || fatal "--db-pass requires a value"; DB_PASS="$2"; shift 2 ;;
        --skip-docker)    SKIP_DOCKER=true; shift ;;
        --skip-postgres)  SKIP_POSTGRES=true; shift ;;
        --skip-nginx)     SKIP_NGINX=true; shift ;;
        --skip-chromium)  SKIP_CHROMIUM=true; shift ;;
        --dry-run)        DRY_RUN=true; shift ;;
        --help)           echo "Usage: $0 --user <name> [--skip-docker] [--skip-postgres] [--skip-nginx] [--skip-chromium] [--dry-run]"; exit 0 ;;
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
SECRETS_DIR="$USER_HOME/.secrets"

phase "INSTALL DEPENDENCIES"

# =========================================================================
# Node.js 22 (always required)
# =========================================================================
if command -v node &>/dev/null && node --version 2>/dev/null | grep -q "^v22"; then
    success "Node.js 22 already installed ($(node --version))"
else
    info "Installing Node.js 22..."
    if ! $DRY_RUN; then
        local_tmp=$(mktemp)
        curl -fsSL https://deb.nodesource.com/setup_22.x -o "$local_tmp"
        if [[ -s "$local_tmp" ]]; then
            sudo -E bash "$local_tmp"
            rm -f "$local_tmp"
        else
            rm -f "$local_tmp"
            fatal "NodeSource setup script download failed"
        fi
    fi
    run_cmd sudo apt install -y nodejs
    verify_shell "Node.js 22 installed" "node --version | grep -q '^v22'"
fi

# =========================================================================
# Docker (optional)
# =========================================================================
if ! $SKIP_DOCKER; then
    if command -v docker &>/dev/null; then
        success "Docker already installed"
    else
        info "Installing Docker..."
        run_cmd sudo apt install -y docker.io docker-compose-plugin
    fi

    info "Adding users to docker group..."
    run_cmd sudo usermod -aG docker "$ADMIN_USER" 2>/dev/null || true
    run_cmd sudo usermod -aG docker "$SERVICE_USER" 2>/dev/null || true

    if ! $DRY_RUN; then
        if [[ ! -f /etc/docker/daemon.json ]] || ! grep -q "no-new-privileges" /etc/docker/daemon.json 2>/dev/null; then
            info "Configuring Docker security..."
            sudo tee /etc/docker/daemon.json >/dev/null <<'DOCKEREOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "no-new-privileges": true,
  "userland-proxy": false,
  "live-restore": true
}
DOCKEREOF
            sudo systemctl restart docker
        fi
    fi
    run_cmd sudo systemctl enable docker
    success "Docker configured"
else
    info "Docker: SKIPPED"
fi

# =========================================================================
# PostgreSQL (optional)
# =========================================================================
if ! $SKIP_POSTGRES; then
    if command -v psql &>/dev/null; then
        success "PostgreSQL already installed"
    else
        info "Installing PostgreSQL..."
        run_shell "sudo apt update && sudo apt install -y postgresql postgresql-contrib"
    fi

    echo ""
    if prompt_yn "Create a database now?" "y"; then
        prompt_value DB_NAME "Database name" "$SERVICE_USER"
        prompt_value DB_USER "Database user" "$SERVICE_USER"

        if [[ -z "$DB_PASS" ]]; then
            DB_PASS=$(openssl rand -hex 16)
            info "Generated database password (will be saved to secrets)"
        fi

        if ! $DRY_RUN; then
            sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';" 2>/dev/null || warn "User $DB_USER may already exist"
            sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;" 2>/dev/null || warn "Database $DB_NAME may already exist"

            sudo -u "$SERVICE_USER" tee "$SECRETS_DIR/postgres" >/dev/null <<PGEOF
PGHOST=localhost
PGUSER=$DB_USER
PGPASSWORD=$DB_PASS
PGDATABASE=$DB_NAME
PGEOF
            sudo chmod 600 "$SECRETS_DIR/postgres"
            success "Database created and credentials saved to $SECRETS_DIR/postgres"
        fi
    else
        info "Skipping database creation."
    fi
else
    info "PostgreSQL: SKIPPED"
fi

# =========================================================================
# Nginx (optional)
# =========================================================================
if ! $SKIP_NGINX; then
    if command -v nginx &>/dev/null; then
        success "Nginx already installed"
    else
        info "Installing Nginx..."
        run_cmd sudo apt install -y nginx
    fi

    info "Granting $SERVICE_USER write access to nginx site configs..."
    run_cmd sudo chgrp "$SERVICE_USER" /etc/nginx/sites-available /etc/nginx/sites-enabled
    run_cmd sudo chmod g+w /etc/nginx/sites-available /etc/nginx/sites-enabled
    run_cmd sudo systemctl enable nginx
    success "Nginx configured"
else
    info "Nginx: SKIPPED"
fi

# =========================================================================
# Chromium (optional)
# =========================================================================
CHROMIUM_PATH=""
if ! $SKIP_CHROMIUM; then
    if command -v chromium-browser &>/dev/null; then
        CHROMIUM_PATH=$(which chromium-browser)
        success "Chromium already installed: $CHROMIUM_PATH"
    elif command -v chromium &>/dev/null; then
        CHROMIUM_PATH=$(which chromium)
        success "Chromium already installed: $CHROMIUM_PATH"
    else
        info "Installing Chromium browser..."
        run_cmd sudo apt install -y chromium-browser
        CHROMIUM_PATH=$(which chromium-browser 2>/dev/null || which chromium 2>/dev/null || echo "")
        if [[ -n "$CHROMIUM_PATH" ]]; then
            success "Chromium installed: $CHROMIUM_PATH"
        else
            warn "Chromium install may have failed."
        fi
    fi
else
    info "Chromium: SKIPPED"
fi

echo ""
success "=== Dependencies installed ==="

# Export for orchestrator
export CHROMIUM_PATH
