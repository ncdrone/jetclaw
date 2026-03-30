#!/usr/bin/env bash
#
# jetclaw-install.sh — Orchestrator for modular OpenClaw installation
#
# Gathers configuration interactively (or via CLI args), then dispatches
# to individual scripts in scripts/ for each phase. Each script can also
# be run standalone if you only need a specific step.
#
# Run ON the target machine as your admin user with sudo access.
#
# Requires: bash 4.2+, python3, sudo access
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$SCRIPT_DIR/scripts"

# Verify scripts directory exists
[[ -d "$SCRIPTS" ]] || { echo "[ERROR] scripts/ directory not found at $SCRIPTS"; exit 1; }
[[ -f "$SCRIPTS/lib/common.sh" ]] || { echo "[ERROR] scripts/lib/common.sh not found"; exit 1; }

source "$SCRIPTS/lib/common.sh"

# ---------------------------------------------------------------------------
# Defaults (overridden by CLI args or interactive prompts)
# ---------------------------------------------------------------------------
HOSTNAME_NEW=""
SERVICE_USER=""
GATEWAY_PORT=""
ADMIN_USER=""
API_KEY=""
TAILSCALE_AUTH=""
WORKSPACE_TEMPLATE=""
TELEGRAM_TOKEN=""
GITHUB_TOKEN=""
GITHUB_EMAIL=""
DOMAIN=""
DISPLAY_NAME=""
COMPANY_NAME=""
DB_NAME=""
DB_USER=""
DB_PASS=""
SKIP_HARDENING=false
SKIP_TAILSCALE=false
SKIP_DOCKER=false
SKIP_NGINX=false
SKIP_POSTGRES=false
SKIP_CHROMIUM=false
SKIP_GITHUB=false
SKIP_WRANGLER=false
SKIP_GCLOUD=false
SKIP_APPS=false

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<'EOF'
Usage: jetclaw-install.sh [options]

Orchestrator for modular OpenClaw installation. All values are prompted
interactively. CLI arguments are optional overrides.

Individual scripts can also be run directly from scripts/:
  scripts/01-harden-system.sh    System hardening
  scripts/02-install-tailscale.sh  Tailscale setup
  scripts/03-create-service-user.sh  Service user + sudoers
  scripts/04-install-deps.sh     Node, Docker, PostgreSQL, Nginx, Chromium
  scripts/05-install-apps.sh     GitHub, Wrangler, gcloud
  scripts/06-install-openclaw.sh OpenClaw CLI + config
  scripts/07-setup-systemd.sh    Systemd service
  scripts/08-summary.sh          Verification + next steps

Options:
  --hostname <name>          Machine hostname
  --user <name>              Service user to create
  --port <number>            Gateway port (default: 18789)
  --admin-user <name>        Admin user (default: current user)
  --api-key <key>            Anthropic API key
  --tailscale-auth <key>     Tailscale auth key (non-interactive)
  --workspace-template <dir> Workspace files to copy in
  --telegram-token <token>   Pre-configure Telegram bot
  --github-token <token>     GitHub fine-grained PAT
  --github-email <email>     GitHub email for commits
  --domain <domain>          Domain for Tailscale Serve
  --display-name <name>      What the agent calls you
  --company <name>           Company/organization name
  --db-name <name>           PostgreSQL database name
  --db-user <name>           PostgreSQL database user
  --db-pass <pass>           PostgreSQL database password
  --skip-hardening           Skip system hardening
  --skip-tailscale           Skip Tailscale installation
  --skip-docker              Skip Docker installation
  --skip-nginx               Skip Nginx installation
  --skip-postgres            Skip PostgreSQL installation
  --skip-chromium            Skip Chromium browser installation
  --skip-github              Skip GitHub configuration
  --skip-wrangler            Skip Cloudflare Wrangler
  --skip-gcloud              Skip Google Cloud CLI
  --skip-apps                Skip all apps (github, wrangler, gcloud)
  --dry-run                  Show commands without executing
  --help                     Show this help
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Parse CLI arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --hostname)
            [[ $# -ge 2 ]] || fatal "--hostname requires a value"
            HOSTNAME_NEW="$2"; shift 2 ;;
        --user)
            [[ $# -ge 2 ]] || fatal "--user requires a value"
            SERVICE_USER="$2"; shift 2 ;;
        --port)
            [[ $# -ge 2 ]] || fatal "--port requires a value"
            GATEWAY_PORT="$2"; shift 2 ;;
        --admin-user)
            [[ $# -ge 2 ]] || fatal "--admin-user requires a value"
            ADMIN_USER="$2"; shift 2 ;;
        --api-key)
            [[ $# -ge 2 ]] || fatal "--api-key requires a value"
            API_KEY="$2"; shift 2 ;;
        --tailscale-auth)
            [[ $# -ge 2 ]] || fatal "--tailscale-auth requires a value"
            TAILSCALE_AUTH="$2"; shift 2 ;;
        --workspace-template)
            [[ $# -ge 2 ]] || fatal "--workspace-template requires a value"
            WORKSPACE_TEMPLATE="$2"; shift 2 ;;
        --telegram-token)
            [[ $# -ge 2 ]] || fatal "--telegram-token requires a value"
            TELEGRAM_TOKEN="$2"; shift 2 ;;
        --github-token)
            [[ $# -ge 2 ]] || fatal "--github-token requires a value"
            GITHUB_TOKEN="$2"; shift 2 ;;
        --github-email)
            [[ $# -ge 2 ]] || fatal "--github-email requires a value"
            GITHUB_EMAIL="$2"; shift 2 ;;
        --domain)
            [[ $# -ge 2 ]] || fatal "--domain requires a value"
            DOMAIN="$2"; shift 2 ;;
        --display-name)
            [[ $# -ge 2 ]] || fatal "--display-name requires a value"
            DISPLAY_NAME="$2"; shift 2 ;;
        --company)
            [[ $# -ge 2 ]] || fatal "--company requires a value"
            COMPANY_NAME="$2"; shift 2 ;;
        --db-name)
            [[ $# -ge 2 ]] || fatal "--db-name requires a value"
            DB_NAME="$2"; shift 2 ;;
        --db-user)
            [[ $# -ge 2 ]] || fatal "--db-user requires a value"
            DB_USER="$2"; shift 2 ;;
        --db-pass)
            [[ $# -ge 2 ]] || fatal "--db-pass requires a value"
            DB_PASS="$2"; shift 2 ;;
        --skip-hardening)   SKIP_HARDENING=true; shift ;;
        --skip-tailscale)   SKIP_TAILSCALE=true; shift ;;
        --skip-docker)      SKIP_DOCKER=true; shift ;;
        --skip-nginx)       SKIP_NGINX=true; shift ;;
        --skip-postgres)    SKIP_POSTGRES=true; shift ;;
        --skip-chromium)    SKIP_CHROMIUM=true; shift ;;
        --skip-github)      SKIP_GITHUB=true; shift ;;
        --skip-wrangler)    SKIP_WRANGLER=true; shift ;;
        --skip-gcloud)      SKIP_GCLOUD=true; shift ;;
        --skip-apps)        SKIP_APPS=true; shift ;;
        --dry-run)          DRY_RUN=true; shift ;;
        --help)             usage ;;
        *) fatal "Unknown argument: $1\nRun with --help for usage." ;;
    esac
done


# =========================================================================
# WELCOME & INTERACTIVE SETUP
# =========================================================================
echo ""
echo -e "${BOLD}================================================================${NC}"
echo -e "${BOLD}       OpenClaw Hardened Install — Interactive Setup${NC}"
echo -e "${BOLD}================================================================${NC}"
echo ""
echo "  This script walks you through setting up a fully hardened"
echo "  OpenClaw instance. It dispatches to individual scripts in"
echo "  scripts/ for each phase."
echo ""
echo -e "  ${DIM}Tip: You can also pass arguments to skip prompts.${NC}"
echo -e "  ${DIM}Run with --help to see all options.${NC}"
echo -e "  ${DIM}Log file: $LOG_FILE${NC}"
echo ""

# -- Pre-flight: must have sudo, must not be root -------------------------
require_sudo

command -v python3 >/dev/null 2>&1 || fatal "python3 is required. Install: sudo apt install -y python3"
success "Python3 available"
echo ""

# -- Gather inputs ---------------------------------------------------------
echo -e "${BOLD}--- Basic Configuration ---${NC}"
echo ""

if [[ -z "$ADMIN_USER" ]]; then
    DETECTED_USER="$(whoami)"
    prompt_value ADMIN_USER "Admin username on this machine" "$DETECTED_USER"
fi
info "Admin user: $ADMIN_USER"

prompt_value HOSTNAME_NEW "Hostname for this machine (e.g., praxis, ergon)"
validate_hostname "$HOSTNAME_NEW"

prompt_value SERVICE_USER "Service user to create (e.g., praxis, ergon)" "$HOSTNAME_NEW"
validate_username "$SERVICE_USER"

prompt_value GATEWAY_PORT "Gateway port" "18789"
validate_port "$GATEWAY_PORT"

echo ""
echo -e "${BOLD}--- API Keys ---${NC}"
echo ""
echo "  You need an Anthropic API key. Options:"
echo "    A) Claude Max token  — from 'claude setup-token' on your Mac"
echo "    B) Regular API key   — from console.anthropic.com"
echo ""
prompt_secret API_KEY "Paste your Anthropic API key (input hidden)"

if [[ "$API_KEY" == sk-ant-oat01-* ]]; then
    warn "This looks like an OAuth token (sk-ant-oat01-*). These expire periodically."
    warn "You'll need to rotate it when it expires. Consider a regular API key."
    pause_continue
fi

echo ""
echo -e "${BOLD}--- Agent Identity ---${NC}"
echo ""
echo "  These are used to personalize the agent's meta-frameworks."
echo ""
prompt_value DISPLAY_NAME "What should the agent call you? (your first name)" ""
read -rp "  Company/organization name (or leave blank): " COMPANY_NAME

echo ""
echo -e "${BOLD}--- Optional Features ---${NC}"
echo ""

# Telegram
if [[ -z "$TELEGRAM_TOKEN" ]]; then
    if prompt_yn "Set up a Telegram bot?" "n"; then
        echo ""
        echo "  Create a bot via @BotFather on Telegram first."
        echo "  You'll get a token like: 8234172661:AAF7RRT0shi..."
        echo ""
        prompt_secret TELEGRAM_TOKEN "Paste Telegram bot token (input hidden)"
    fi
fi

# GitHub
if [[ -z "$GITHUB_TOKEN" ]] && ! $SKIP_GITHUB; then
    if prompt_yn "Set up GitHub access for this agent?" "n"; then
        echo ""
        echo "  Create a fine-grained PAT at github.com/settings/tokens"
        echo "  with only the repos this agent needs access to."
        echo ""
        prompt_secret GITHUB_TOKEN "Paste GitHub PAT (input hidden)"
        prompt_value GITHUB_EMAIL "GitHub email for commits"
    else
        SKIP_GITHUB=true
    fi
fi

# Workspace template
if [[ -z "$WORKSPACE_TEMPLATE" ]]; then
    if prompt_yn "Copy in a workspace template (personality files, etc.)?" "n"; then
        prompt_value WORKSPACE_TEMPLATE "Path to workspace template directory"
        if [[ ! -d "$WORKSPACE_TEMPLATE" ]]; then
            warn "Directory not found: $WORKSPACE_TEMPLATE -- skipping."
            WORKSPACE_TEMPLATE=""
        fi
    fi
fi

# Installation scope
echo ""
echo -e "${BOLD}--- Installation Scope ---${NC}"
echo ""
echo "  The full install includes: system hardening, Tailscale, Docker,"
echo "  Nginx, PostgreSQL, Chromium, external apps, and OpenClaw."
echo ""

INSTALL_ALL=false
if prompt_yn "Install everything? (say No to choose individually)" "y"; then
    INSTALL_ALL=true
    info "Installing all components."
else
    info "Choose which components to install:"
    echo ""

    if ! $SKIP_HARDENING; then
        if ! prompt_yn "  System hardening? (UFW, SSH lockdown, Quad9 DNS, fail2ban)" "y"; then
            SKIP_HARDENING=true
        fi
    fi

    if ! $SKIP_TAILSCALE; then
        if ! prompt_yn "  Tailscale?" "y"; then
            SKIP_TAILSCALE=true
        fi
    fi

    if ! $SKIP_DOCKER; then
        if ! prompt_yn "  Docker?" "y"; then
            SKIP_DOCKER=true
        fi
    fi

    if ! $SKIP_NGINX; then
        if ! prompt_yn "  Nginx (reverse proxy for apps)?" "y"; then
            SKIP_NGINX=true
        fi
    fi

    if ! $SKIP_POSTGRES; then
        if ! prompt_yn "  PostgreSQL?" "y"; then
            SKIP_POSTGRES=true
        fi
    fi

    if ! $SKIP_CHROMIUM; then
        if ! prompt_yn "  Chromium (browser tools/research skill)?" "y"; then
            SKIP_CHROMIUM=true
        fi
    fi

    if ! $SKIP_APPS; then
        if ! prompt_yn "  External apps? (GitHub CLI, Wrangler, gcloud)" "y"; then
            SKIP_APPS=true
        fi
    fi
fi

# -- Confirm everything ----------------------------------------------------
phase "CONFIRM SETTINGS"

echo "  Hostname:           $HOSTNAME_NEW"
echo "  Service user:       $SERVICE_USER"
echo "  Home directory:     /var/lib/$SERVICE_USER"
echo "  Gateway port:       $GATEWAY_PORT"
echo "  Admin user:         $ADMIN_USER"
echo "  API key:            ${API_KEY:0:12}..."
echo "  Display name:       ${DISPLAY_NAME:-$ADMIN_USER}"
echo "  Company:            ${COMPANY_NAME:-<not set>}"
echo "  Telegram:           $( [[ -n "$TELEGRAM_TOKEN" ]] && echo 'configured' || echo 'not configured' )"
echo "  GitHub:             $( $SKIP_GITHUB && echo 'SKIP' || echo "${GITHUB_EMAIL:-not configured}" )"
echo "  Workspace template: ${WORKSPACE_TEMPLATE:-none}"
echo ""
echo "  Install hardening:  $( $SKIP_HARDENING && echo 'SKIP' || echo 'YES' )"
echo "  Install Tailscale:  $( $SKIP_TAILSCALE && echo 'SKIP' || echo 'YES' )"
echo "  Install Docker:     $( $SKIP_DOCKER && echo 'SKIP' || echo 'YES' )"
echo "  Install Nginx:      $( $SKIP_NGINX && echo 'SKIP' || echo 'YES' )"
echo "  Install PostgreSQL: $( $SKIP_POSTGRES && echo 'SKIP' || echo 'YES' )"
echo "  Install Chromium:   $( $SKIP_CHROMIUM && echo 'SKIP' || echo 'YES' )"
echo "  Install Apps:       $( $SKIP_APPS && echo 'SKIP' || echo 'YES' )"
echo ""

if ! prompt_yn "Everything look right? Begin installation?" "y"; then
    warn "Aborted. Re-run when ready."
    exit 0
fi


# =========================================================================
# DISPATCH TO INDIVIDUAL SCRIPTS
# =========================================================================
# All config is passed via exported environment variables so sub-scripts
# pick up values without needing CLI args (they still accept them for
# standalone use).

export HOSTNAME_NEW SERVICE_USER GATEWAY_PORT ADMIN_USER API_KEY
export TAILSCALE_AUTH WORKSPACE_TEMPLATE TELEGRAM_TOKEN
export GITHUB_TOKEN GITHUB_EMAIL DOMAIN DISPLAY_NAME COMPANY_NAME
export DB_NAME DB_USER DB_PASS
export SKIP_HARDENING SKIP_TAILSCALE SKIP_DOCKER SKIP_NGINX
export SKIP_POSTGRES SKIP_CHROMIUM SKIP_GITHUB SKIP_WRANGLER SKIP_GCLOUD
export DRY_RUN LOG_FILE


# -------------------------------------------------------------------------
# 01: System Hardening
# -------------------------------------------------------------------------
if ! $SKIP_HARDENING; then
    bash "$SCRIPTS/01-harden-system.sh"
    pause_continue "Press Enter to continue to Tailscale setup..."
else
    phase "SYSTEM HARDENING (SKIPPED)"
    info "Assuming system is already hardened."
fi

# -------------------------------------------------------------------------
# 02: Tailscale
# -------------------------------------------------------------------------
if ! $SKIP_TAILSCALE; then
    bash "$SCRIPTS/02-install-tailscale.sh"
    pause_continue "Press Enter to continue to user setup..."
else
    phase "TAILSCALE (SKIPPED)"
fi

# -------------------------------------------------------------------------
# 03: Service User (always required)
# -------------------------------------------------------------------------
bash "$SCRIPTS/03-create-service-user.sh"
pause_continue

# -------------------------------------------------------------------------
# 04: Dependencies
# -------------------------------------------------------------------------
bash "$SCRIPTS/04-install-deps.sh"
pause_continue

# -------------------------------------------------------------------------
# 05: Apps (GitHub, Wrangler, gcloud)
# -------------------------------------------------------------------------
if ! $SKIP_APPS; then
    bash "$SCRIPTS/05-install-apps.sh"
    pause_continue
else
    phase "EXTERNAL APPS (SKIPPED)"
fi

# -------------------------------------------------------------------------
# 06: OpenClaw
# -------------------------------------------------------------------------
bash "$SCRIPTS/06-install-openclaw.sh"
pause_continue

# -------------------------------------------------------------------------
# 07: Systemd Service
# -------------------------------------------------------------------------
bash "$SCRIPTS/07-setup-systemd.sh"

# -------------------------------------------------------------------------
# 08: Summary + Verification
# -------------------------------------------------------------------------
bash "$SCRIPTS/08-summary.sh"
