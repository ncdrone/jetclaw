#!/usr/bin/env bash
#
# jetclaw-install.sh — Interactive install of a hardened OpenClaw instance
#
# Run ON the target machine as your admin user with sudo access.
# Part of the jetclaw toolkit: https://github.com/your-user/jetclaw
# The script is interactive by default -- it prompts for everything.
# CLI arguments are optional overrides to skip prompts.
#
# Requires: bash 4.2+, python3, sudo access
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Logging — all output goes to terminal AND a log file
# ---------------------------------------------------------------------------
LOG_FILE="/tmp/openclaw-install-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

# ---------------------------------------------------------------------------
# State tracking for cleanup
# ---------------------------------------------------------------------------
CURRENT_PHASE="pre-flight"
UFW_BACKUP=""

cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        echo ""
        echo -e "\033[0;31m[FAILED]\033[0m Script failed during: $CURRENT_PHASE"
        echo -e "\033[0;31m[FAILED]\033[0m Log file: $LOG_FILE"
        echo ""
        echo "  To resume, re-run the script with --skip-hardening if hardening"
        echo "  is already complete, or fix the issue and re-run."
        if [[ -n "$UFW_BACKUP" && -f "$UFW_BACKUP" ]]; then
            echo "  UFW rules backed up to: $UFW_BACKUP"
        fi
    fi
}
trap cleanup EXIT

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
DRY_RUN=false

# ---------------------------------------------------------------------------
# Colors / helpers — check the REAL terminal, not the tee pipe
# ---------------------------------------------------------------------------
if [[ -t 0 ]]; then
    # stdin is a terminal = interactive session, enable colors
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    MAGENTA='\033[0;35m'
    BOLD='\033[1m'
    DIM='\033[2m'
    BG_RED='\033[41m'
    BG_YELLOW='\033[43m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' MAGENTA='' BOLD='' DIM='' BG_RED='' BG_YELLOW='' NC=''
fi

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
fatal()   { error "$*"; exit 1; }

phase() {
    CURRENT_PHASE="$*"
    echo ""
    echo -e "${BOLD}================================================================${NC}"
    echo -e "${BOLD}  $*${NC}"
    echo -e "${BOLD}================================================================${NC}"
    echo ""
}

action_required() {
    echo ""
    echo -e "  ${BG_YELLOW}${BOLD} >>> ACTION REQUIRED <<< ${NC}"
    echo ""
    echo -e "  ${YELLOW}$*${NC}"
    echo ""
}

pause_confirm() {
    local msg="${1:-Ready to continue?}"
    echo ""
    read -rp "  $msg [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { warn "Paused. Re-run when ready."; exit 0; }
    echo ""
}

pause_continue() {
    local msg="${1:-Press Enter to continue...}"
    echo ""
    read -rp "  $msg" _
    echo ""
}

# ---------------------------------------------------------------------------
# Safe prompt functions — NO eval, uses printf -v
# ---------------------------------------------------------------------------
prompt_value() {
    local varname="$1"
    local prompt_msg="$2"
    local default="${3:-}"
    local current_val=""

    # Read current value safely
    eval "current_val=\"\${$varname:-}\""

    # If already set via CLI arg, skip prompt
    if [[ -n "$current_val" ]]; then
        info "$prompt_msg: $current_val (from CLI)"
        return
    fi

    if [[ -n "$default" ]]; then
        read -rp "  $prompt_msg [$default]: " input
        printf -v "$varname" '%s' "${input:-$default}"
    else
        while true; do
            read -rp "  $prompt_msg: " input
            if [[ -n "$input" ]]; then
                printf -v "$varname" '%s' "$input"
                break
            fi
            warn "This field is required."
        done
    fi
}

prompt_secret() {
    local varname="$1"
    local prompt_msg="$2"
    local current_val=""

    eval "current_val=\"\${$varname:-}\""

    if [[ -n "$current_val" ]]; then
        info "$prompt_msg: ${current_val:0:12}... (from CLI)"
        return
    fi

    while true; do
        read -srp "  $prompt_msg: " input
        echo ""
        if [[ -n "$input" ]]; then
            printf -v "$varname" '%s' "$input"
            break
        fi
        warn "This field is required."
    done
}

prompt_yn() {
    local prompt_msg="$1"
    local default="${2:-n}"
    local hint="y/N"
    [[ "$default" == "y" ]] && hint="Y/n"

    read -rp "  $prompt_msg [$hint]: " input
    input="${input:-$default}"
    [[ "$input" =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------
validate_hostname() {
    local name="$1"
    if [[ ! "$name" =~ ^[a-z][a-z0-9-]*$ ]]; then
        fatal "Invalid hostname '$name'. Must start with lowercase letter, contain only a-z, 0-9, hyphens."
    fi
    if [[ ${#name} -gt 63 ]]; then
        fatal "Hostname '$name' too long (max 63 characters)."
    fi
}

validate_username() {
    local name="$1"
    if [[ ! "$name" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        fatal "Invalid username '$name'. Must start with lowercase letter or underscore, contain only a-z, 0-9, underscores, hyphens."
    fi
    if [[ ${#name} -gt 32 ]]; then
        fatal "Username '$name' too long (max 32 characters)."
    fi
}

validate_port() {
    local port="$1"
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        fatal "Invalid port '$port'. Must be a number."
    fi
    if (( port < 1024 || port > 65535 )); then
        fatal "Port $port out of range. Must be 1024-65535."
    fi
}

# ---------------------------------------------------------------------------
# Execution helpers
# ---------------------------------------------------------------------------

# run_cmd: Direct execution, safe from injection. Use for simple commands.
run_cmd() {
    if $DRY_RUN; then
        echo -e "${YELLOW}[DRY-RUN]${NC} $*"
    else
        "$@"
    fi
}

# run_shell: Uses eval for compound expressions (&&, pipes).
# ONLY use with pre-validated, script-controlled strings. Never with raw user input.
run_shell() {
    if $DRY_RUN; then
        echo -e "${YELLOW}[DRY-RUN]${NC} $*"
    else
        eval "$@"
    fi
}

verify() {
    local desc="$1"
    shift
    if $DRY_RUN; then
        echo -e "${YELLOW}[DRY-RUN]${NC} Verify: $desc"
        return
    fi
    local output
    if output=$("$@" 2>&1); then
        success "$desc"
    else
        error "Verification failed: $desc"
        error "Output: $output"
        fatal "Cannot continue."
    fi
}

verify_shell() {
    local desc="$1"
    shift
    if $DRY_RUN; then
        echo -e "${YELLOW}[DRY-RUN]${NC} Verify: $desc"
        return
    fi
    local output
    if output=$(eval "$@" 2>&1); then
        success "$desc"
    else
        error "Verification failed: $desc"
        error "Output: $output"
        fatal "Cannot continue."
    fi
}

# ---------------------------------------------------------------------------
# JSON generation via Python3 — safe from all injection
# ---------------------------------------------------------------------------
generate_openclaw_config() {
    python3 <<PYEOF
import json, os, sys

port = int(os.environ["OC_PORT"])
workspace = os.environ["OC_WORKSPACE"]
gateway_token = os.environ["OC_GATEWAY_TOKEN"]
allowed_origins = json.loads(os.environ["OC_ALLOWED_ORIGINS"])
telegram_token = os.environ.get("OC_TELEGRAM_TOKEN", "")
skip_tailscale = os.environ.get("OC_SKIP_TAILSCALE", "false") == "true"

config = {
    "auth": {
        "profiles": {
            "anthropic:default": {
                "provider": "anthropic",
                "mode": "api_key"
            }
        },
        "order": {
            "anthropic": ["anthropic:default"]
        }
    },
    "agents": {
        "defaults": {
            "model": {
                "primary": "anthropic/claude-sonnet-4-6",
                "fallbacks": [
                    "anthropic/claude-opus-4-6",
                    "anthropic/claude-opus-4-5",
                    "anthropic/claude-sonnet-4-5"
                ]
            },
            "workspace": workspace,
            "maxConcurrent": 4,
            "timeoutSeconds": 3600,
            "contextPruning": {
                "mode": "cache-ttl",
                "ttl": "1h"
            },
            "compaction": {
                "mode": "safeguard",
                "reserveTokensFloor": 4000
            },
            "heartbeat": {
                "every": "1h",
                "activeHours": {
                    "start": "05:00",
                    "end": "22:00",
                    "timezone": "America/Los_Angeles"
                }
            }
        },
        "list": [
            {"id": "main"}
        ]
    },
    "tools": {
        "web": {
            "search": {"enabled": True},
            "fetch": {"enabled": True}
        }
    },
    "gateway": {
        "port": port,
        "mode": "local",
        "bind": "loopback",
        "controlUi": {
            "allowedOrigins": allowed_origins
        },
        "auth": {
            "mode": "token",
            "token": gateway_token,
            "allowTailscale": True
        },
        "trustedProxies": ["127.0.0.1", "::1"]
    },
    "commands": {
        "native": "auto",
        "nativeSkills": "auto",
        "restart": True
    },
    "discovery": {
        "mdns": {"mode": "off"}
    },
    "session": {
        "dmScope": "per-channel-peer"
    },
    "logging": {
        "redactSensitive": "all",
        "redactPatterns": [
            "sk-ant-", "sk-", "password", "secret", "token", "api.key"
        ]
    },
    "hooks": {
        "enabled": True,
        "internal": {
            "enabled": True,
            "entries": {
                "bootstrap-extra-files": {"enabled": True, "paths": ["meta-frameworks/*.md"]},
                "session-memory": {"enabled": True},
                "command-logger": {"enabled": True},
                "qmd-recall": {"enabled": False}

            }
        }
    }
}

# Add Tailscale config
if not skip_tailscale:
    config["gateway"]["tailscale"] = {
        "mode": "serve",
        "resetOnExit": False
    }

# Add Telegram config
if telegram_token:
    config["channels"] = {
        "telegram": {
            "enabled": True,
            "dmPolicy": "pairing",
            "groupPolicy": "allowlist",
            "streaming": "partial",
            "accounts": {
                "default": {
                    "dmPolicy": "pairing",
                    "botToken": telegram_token,
                    "groupPolicy": "allowlist",
                    "streaming": "partial"
                }
            }
        }
    }
    config["plugins"] = {
        "entries": {
            "telegram": {"enabled": True}
        }
    }

# Add browser config if chromium is available
chromium_path = os.environ.get("OC_CHROMIUM_PATH", "")
if chromium_path:
    config["browser"] = {
        "enabled": True,
        "executablePath": chromium_path,
        "headless": True,
        "noSandbox": True
    }
    config["agents"]["defaults"]["sandbox"] = {
        "browser": {"enabled": True}
    }

print(json.dumps(config, indent=2))
PYEOF
}

generate_auth_file() {
    python3 <<PYEOF
import json, os
print(json.dumps({
    "anthropic:default": {
        "provider": "anthropic",
        "mode": "api_key",
        "key": os.environ["OC_API_KEY"]
    },
    "usageStats": {}
}, indent=2))
PYEOF
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<'EOF'
Usage: openclaw-install.sh [options]

All values are prompted interactively. CLI arguments are optional overrides.

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
  --dry-run                  Show commands without executing
  --help                     Show this help
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Parse CLI arguments — validates $2 exists before shift
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
echo "  This script will walk you through setting up a fully hardened"
echo "  OpenClaw instance. It will pause at each step that requires"
echo "  manual action (SSH key copy, Tailscale approval, etc.)."
echo ""
echo -e "  ${DIM}Tip: You can also pass arguments to skip prompts.${NC}"
echo -e "  ${DIM}Run with --help to see all options.${NC}"
echo -e "  ${DIM}Log file: $LOG_FILE${NC}"
echo ""

# -- Pre-flight: must have sudo, must not be root -------------------------
if [[ $EUID -eq 0 ]]; then
    fatal "Do not run this script as root. Run as your admin user with sudo access."
fi
sudo -n true 2>/dev/null || {
    info "Enter your password to confirm sudo access:"
    sudo -v || fatal "Sudo access required. Check your password and try again."
}
success "Sudo access confirmed"

# Check python3 is available (needed for JSON generation)
command -v python3 >/dev/null 2>&1 || fatal "python3 is required but not found. Install it: sudo apt install -y python3"
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

# Warn about OAuth token expiration
if [[ "$API_KEY" == sk-ant-oat01-* ]]; then
    warn "This looks like an OAuth token (sk-ant-oat01-*). These expire periodically."
    warn "You'll need to rotate it when it expires. Consider a regular API key for stability."
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
            warn "Directory not found: $WORKSPACE_TEMPLATE -- skipping workspace template."
            WORKSPACE_TEMPLATE=""
        fi
    fi
fi

# Skip flags
echo ""
echo -e "${BOLD}--- Installation Scope ---${NC}"
echo ""
echo "  The full install includes: system hardening, Tailscale, Docker,"
echo "  Nginx, PostgreSQL, Chromium, and OpenClaw."
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
fi

# Derived paths
USER_HOME="/var/lib/$SERVICE_USER"
OPENCLAW_DIR="$USER_HOME/.openclaw"
WORKSPACE_DIR="$OPENCLAW_DIR/workspace"
SECRETS_DIR="$USER_HOME/.secrets"
SYSTEMD_SERVICE="openclaw-${SERVICE_USER}.service"
SYSTEMD_PATH="/etc/systemd/system/$SYSTEMD_SERVICE"
OPENCLAW_BIN=""  # resolved after install

# -- Confirm everything ----------------------------------------------------
phase "CONFIRM SETTINGS"

echo "  Hostname:           $HOSTNAME_NEW"
echo "  Service user:       $SERVICE_USER"
echo "  Home directory:     $USER_HOME"
echo "  Gateway port:       $GATEWAY_PORT"
echo "  Admin user:         $ADMIN_USER"
echo "  API key:            ${API_KEY:0:12}..."
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
echo ""

if ! prompt_yn "Everything look right? Begin installation?" "y"; then
    warn "Aborted. Re-run when ready."
    exit 0
fi


# =========================================================================
# PHASE 1: SYSTEM HARDENING
# =========================================================================
if ! $SKIP_HARDENING; then
    phase "PHASE 1: SYSTEM HARDENING"

    # -- 1.1 System update --------------------------------------------------
    info "Step 1/8: Updating system packages..."
    info "This may take a few minutes."
    run_shell "sudo apt update && sudo apt upgrade -y"
    run_cmd sudo apt autoremove -y

    info "Installing base packages..."
    run_cmd sudo apt install -y curl git vim htop tmux ufw fail2ban unattended-upgrades
    verify "Base packages installed" command -v ufw
    verify "fail2ban installed" command -v fail2ban-client

    # -- 1.2 Hostname -------------------------------------------------------
    info "Step 2/8: Setting hostname to '$HOSTNAME_NEW'..."
    run_cmd sudo hostnamectl set-hostname "$HOSTNAME_NEW"

    if ! $DRY_RUN; then
        if grep -q "127.0.1.1" /etc/hosts; then
            sudo sed -i "s/^127.0.1.1.*/127.0.1.1    $HOSTNAME_NEW/" /etc/hosts
        else
            echo "127.0.1.1    $HOSTNAME_NEW" | sudo tee -a /etc/hosts >/dev/null
        fi
    fi
    verify_shell "Hostname set" "hostnamectl | grep -q '$HOSTNAME_NEW'"

    # -- 1.3 SSH hardening --------------------------------------------------
    info "Step 3/8: Hardening SSH configuration..."
    echo ""
    echo -e "  ${BG_RED}${BOLD} !!! THIS STEP WILL DISABLE PASSWORD LOGIN !!! ${NC}"
    echo ""
    echo -e "  ${YELLOW}You MUST have SSH key access working BEFORE continuing.${NC}"
    echo -e "  ${YELLOW}If you don't, you will be locked out of this machine.${NC}"
    echo ""
    echo -e "  ${BOLD}On your Mac, run these commands now:${NC}"
    echo ""
    echo -e "  ${GREEN}--- COPY AND PASTE INTO YOUR MAC TERMINAL ---${NC}"
    echo ""
    CURRENT_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<this-machine-ip>")
    echo -e "  ${CYAN}# Step 1: Generate an SSH key (skip if you already have one)${NC}"
    echo -e "  ${BOLD}ssh-keygen -t ed25519 -C \"$HOSTNAME_NEW\" -f ~/.ssh/id_ed25519_$HOSTNAME_NEW${NC}"
    echo ""
    echo -e "  ${CYAN}# Step 2: Copy it to this Jetson${NC}"
    echo -e "  ${BOLD}ssh-copy-id -i ~/.ssh/id_ed25519_$HOSTNAME_NEW.pub $ADMIN_USER@$CURRENT_IP${NC}"
    echo ""
    echo -e "  ${CYAN}# Step 3: Add SSH config entry on your Mac${NC}"
    echo -e "  ${BOLD}cat >> ~/.ssh/config << 'EOF'"
    echo ""
    echo "Host $HOSTNAME_NEW"
    echo "    HostName $CURRENT_IP"
    echo "    User $ADMIN_USER"
    echo "    IdentityFile ~/.ssh/id_ed25519_$HOSTNAME_NEW"
    echo "    IdentitiesOnly yes"
    echo "    ServerAliveInterval 30"
    echo "    ServerAliveCountMax 3"
    echo -e "EOF${NC}"
    echo ""
    echo -e "  ${CYAN}# Step 4: Test it works (should connect WITHOUT a password)${NC}"
    echo -e "  ${BOLD}ssh $HOSTNAME_NEW${NC}"
    echo ""
    echo -e "  ${GREEN}--- END ---${NC}"
    echo ""
    echo -e "  ${YELLOW}Only continue after Step 4 connects without asking for a password.${NC}"
    echo ""

    echo -e "  ${BG_YELLOW}${BOLD} Type YES when SSH key works, or NO to skip SSH hardening: ${NC}"
    echo ""
    while true; do
        read -rp "  SSH key works without password? (YES/NO): " ssh_key_confirm
        case "$ssh_key_confirm" in
            YES)
                success "SSH key access confirmed"
                break
                ;;
            NO)
                warn "Skipping SSH hardening. Password auth will remain enabled."
                warn "You can re-run the script later to harden SSH."
                # Jump past the SSH hardening block
                SSH_HARDENING_SKIPPED=true
                break
                ;;
            *)
                warn "Type YES or NO (full word, capitalized)"
                ;;
        esac
    done

    SSH_HARDENING_SKIPPED=${SSH_HARDENING_SKIPPED:-false}
    if ! $SSH_HARDENING_SKIPPED; then

    run_cmd sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup

    if ! $DRY_RUN; then
        sudo tee /etc/ssh/sshd_config.d/hardening.conf >/dev/null <<SSHEOF
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
X11Forwarding no
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
AllowUsers $ADMIN_USER
SSHEOF
        sudo sshd -t || fatal "SSH config validation failed! Check /etc/ssh/sshd_config.d/hardening.conf"
        sudo systemctl restart sshd
    fi

    success "SSH hardened"
    echo ""
    echo -e "  ${BG_RED}${BOLD} !!! WARNING: Password auth is now DISABLED !!! ${NC}"
    echo ""
    echo -e "  ${YELLOW}If you cannot SSH in from another terminal, type NO below${NC}"
    echo -e "  ${YELLOW}to restore password auth before you get locked out.${NC}"
    echo ""

    action_required "Open a ${BOLD}NEW${NC}${YELLOW} terminal and verify you can still SSH in:\n\n    ${BOLD}ssh $ADMIN_USER@$CURRENT_IP${NC}\n\n  ${RED}Do NOT close this terminal until you've confirmed!${NC}"

    echo ""
    echo -e "  ${BG_YELLOW}${BOLD} Type YES if SSH works, or NO to roll back: ${NC}"
    echo ""
    while true; do
        read -rp "  SSH confirmed? (YES/NO): " ssh_confirm
        case "$ssh_confirm" in
            YES)
                success "SSH confirmed working"
                break
                ;;
            NO)
                warn "Rolling back SSH hardening..."
                sudo rm -f /etc/ssh/sshd_config.d/hardening.conf
                sudo systemctl restart sshd
                success "Password auth re-enabled. SSH restored to previous state."
                info "Fix your SSH key access, then re-run the script."
                exit 0
                ;;
            *)
                warn "Type YES or NO (full word, capitalized)"
                ;;
        esac
    done

    fi  # end SSH_HARDENING_SKIPPED check

    # -- 1.4 Firewall -------------------------------------------------------
    info "Step 4/8: Configuring firewall (UFW)..."

    # Backup existing rules
    if ! $DRY_RUN; then
        UFW_BACKUP="/tmp/ufw-backup-$(date +%s).txt"
        sudo ufw status numbered > "$UFW_BACKUP" 2>/dev/null || true
        info "Existing UFW rules backed up to: $UFW_BACKUP"
    fi

    run_cmd sudo ufw --force reset
    run_cmd sudo ufw default deny incoming
    run_cmd sudo ufw default allow outgoing
    run_shell "sudo ufw allow from 127.0.0.1"

    if $SKIP_TAILSCALE; then
        info "Tailscale will be skipped -- keeping LAN SSH access open."
        run_shell "sudo ufw allow from 192.168.0.0/16 to any port 22"
        run_shell "sudo ufw allow from 10.0.0.0/8 to any port 22"
    else
        info "Adding temporary LAN SSH access (will be replaced by Tailscale)..."
        run_shell "sudo ufw allow from 192.168.0.0/16 to any port 22"
        run_shell "sudo ufw allow from 10.0.0.0/8 to any port 22"
    fi

    run_cmd sudo ufw --force enable
    success "Firewall configured (deny all incoming, allow outgoing)"

    # -- 1.5 Fail2ban -------------------------------------------------------
    info "Step 5/8: Configuring fail2ban..."
    if ! $DRY_RUN; then
        sudo tee /etc/fail2ban/jail.local >/dev/null <<'F2BEOF'
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 3

[sshd]
enabled = true
port = ssh
maxretry = 3
bantime = 24h
F2BEOF
    fi
    run_cmd sudo systemctl enable --now fail2ban
    success "Fail2ban configured (SSH: 3 attempts, 24h ban)"

    # -- 1.6 Auto updates ---------------------------------------------------
    info "Step 6/8: Enabling automatic security updates..."
    if ! $DRY_RUN; then
        echo 'Unattended-Upgrade::Allowed-Origins { "${distro_id}:${distro_codename}-security"; };' | \
            sudo tee /etc/apt/apt.conf.d/50unattended-upgrades-override >/dev/null
        sudo systemctl enable --now unattended-upgrades
    fi
    success "Automatic security updates enabled"

    # -- 1.7 Kill services ---------------------------------------------------
    info "Step 7/8: Disabling unnecessary services..."
    for svc in avahi-daemon cups bluetooth ModemManager rpcbind rpcbind.socket; do
        run_cmd sudo systemctl disable --now "$svc" 2>/dev/null || true
    done
    success "Disabled: avahi, cups, bluetooth, ModemManager, rpcbind"

    # -- 1.8 Quad9 DNS -------------------------------------------------------
    info "Step 8/8: Configuring encrypted DNS (Quad9)..."
    echo "  Quad9 blocks known malware domains -- extra protection against"
    echo "  prompt injection trying to reach malicious URLs."
    if ! $DRY_RUN; then
        sudo tee /etc/systemd/resolved.conf >/dev/null <<'DNSEOF'
[Resolve]
DNS=9.9.9.9#dns.quad9.net 149.112.112.112#dns.quad9.net
FallbackDNS=
DNSOverTLS=yes
DNSSEC=yes
Domains=~.
DNSEOF
        sudo systemctl restart systemd-resolved
    fi
    # Verify DNS -- check both resolvectl and the config file itself
    if resolvectl status 2>/dev/null | grep -q '9.9.9.9' || grep -q '9.9.9.9' /etc/systemd/resolved.conf 2>/dev/null; then
        success "DNS configured"
    else
        warn "Could not verify DNS. Check manually: resolvectl status"
        warn "Config was written to /etc/systemd/resolved.conf -- may need a reboot."
    fi
    echo ""
    success "=== System hardening complete ==="
    pause_continue "Press Enter to continue to Tailscale setup..."

else
    phase "PHASE 1: SYSTEM HARDENING (SKIPPED)"
    info "Assuming system is already hardened."
    pause_continue
fi


# =========================================================================
# PHASE 1.5: TAILSCALE
# =========================================================================
if ! $SKIP_TAILSCALE; then
    phase "PHASE 1.5: TAILSCALE"

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

    # Check if Tailscale is already connected
    if tailscale status &>/dev/null; then
        success "Tailscale already connected"
    else
        info "Bringing Tailscale up..."
        echo ""
        if [[ -n "$TAILSCALE_AUTH" ]]; then
            run_cmd sudo tailscale up --ssh --auth-key="$TAILSCALE_AUTH"
        else
            echo "  This will open a Tailscale login URL."

            action_required "When the URL appears, open it in your browser and log in\n  to your Tailscale account to authorize this machine."

            pause_confirm "Ready to run 'tailscale up'?"
            run_cmd sudo tailscale up --ssh
        fi
    fi

    TS_IP="unknown"
    TS_FQDN=""
    if ! $DRY_RUN; then
        TS_IP=$(tailscale ip -4 2>/dev/null || echo "unknown")
        TS_FQDN=$(tailscale status --json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Self',{}).get('DNSName','').rstrip('.'))" 2>/dev/null || echo "")
        success "Tailscale connected"
        info "Tailscale IP:       $TS_IP"
        info "Tailscale hostname: $TS_FQDN"
    fi

    # Lock SSH to Tailscale
    if ! $SKIP_HARDENING; then
        echo ""
        info "Locking SSH to Tailscale network only..."
        echo "  This removes the temporary LAN SSH rules and restricts"
        echo "  SSH access to Tailscale IPs (100.64.0.0/10)."
        echo ""

        action_required "After this step, you can ONLY SSH via Tailscale.\n  Make sure your Mac is on the same Tailscale network.\n\n  Test from your Mac:\n    ssh $ADMIN_USER@${TS_FQDN:-$HOSTNAME_NEW}"

        pause_confirm "Your Mac is on Tailscale and you can reach this machine?"

        run_shell "sudo ufw delete allow from 192.168.0.0/16 to any port 22 2>/dev/null || true"
        run_shell "sudo ufw delete allow from 10.0.0.0/8 to any port 22 2>/dev/null || true"
        run_shell "sudo ufw allow from 100.64.0.0/10 to any port 22"
        success "SSH restricted to Tailscale network"
    fi

    TS_IP_CURRENT=$(tailscale ip -4 2>/dev/null || echo '<jetson-ip>')
    TS_HOST="${TS_FQDN:-$HOSTNAME_NEW.your-tailnet.ts.net}"

    echo ""
    info "Run these commands on your Mac to set up SSH access:"
    echo ""
    echo -e "  ${BOLD}# 1. Generate key, copy to Jetson, add to keychain, and configure SSH${NC}"
    echo -e "  ${BOLD}#    Copy this entire block and paste into your Mac terminal:${NC}"
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

    pause_continue "Press Enter to continue to user setup..."
else
    phase "PHASE 1.5: TAILSCALE (SKIPPED)"
    TS_IP=""
    TS_FQDN=""
fi


# =========================================================================
# PHASE 2: CREATE SERVICE USER
# =========================================================================
phase "PHASE 2: CREATE SERVICE USER ($SERVICE_USER)"

if id "$SERVICE_USER" &>/dev/null; then
    warn "User '$SERVICE_USER' already exists. Skipping creation."
    # Ensure password is locked even if user existed
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

info "Setting up directories..."
run_cmd sudo mkdir -p "$USER_HOME/config"
run_cmd sudo mkdir -p "$USER_HOME/workspace"
run_cmd sudo mkdir -p "$USER_HOME/logs"
run_cmd sudo mkdir -p "$OPENCLAW_DIR"
run_cmd sudo mkdir -p "$SECRETS_DIR"
run_cmd sudo chown -R "$SERVICE_USER:$SERVICE_USER" "$USER_HOME"
run_cmd sudo chmod 700 "$USER_HOME"
verify "Service user works (sudo -u $SERVICE_USER whoami)" sudo -u "$SERVICE_USER" whoami

# Git config for the service user
if ! $SKIP_GITHUB || [[ -n "$GITHUB_EMAIL" ]]; then
    info "Configuring git identity for $SERVICE_USER..."
    run_cmd sudo -u "$SERVICE_USER" git config --global user.name "$SERVICE_USER"
    if [[ -n "$GITHUB_EMAIL" ]]; then
        run_cmd sudo -u "$SERVICE_USER" git config --global user.email "$GITHUB_EMAIL"
    fi
    success "Git identity configured"
fi

# Sudoers
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
success "Service user fully configured"
pause_continue


# =========================================================================
# PHASE 3: INSTALL DEPENDENCIES
# =========================================================================
phase "PHASE 3: INSTALL DEPENDENCIES"

# -- Node.js 22 -----------------------------------------------------------
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

# -- Docker ----------------------------------------------------------------
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

# -- PostgreSQL ------------------------------------------------------------
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
        info "Skipping database creation. Create later with:"
        echo "    sudo -u postgres psql"
        echo "    CREATE USER myuser WITH PASSWORD 'mypass';"
        echo "    CREATE DATABASE mydb OWNER myuser;"
    fi
else
    info "PostgreSQL: SKIPPED"
fi

# -- Nginx -----------------------------------------------------------------
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

# -- Chromium --------------------------------------------------------------
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
            warn "Chromium install may have failed. Browser tools may not work."
        fi
    fi
else
    info "Chromium: SKIPPED"
fi

# -- GitHub ----------------------------------------------------------------
if ! $SKIP_GITHUB && [[ -n "$GITHUB_TOKEN" ]]; then
    info "Storing GitHub PAT..."
    if ! $DRY_RUN; then
        sudo -u "$SERVICE_USER" tee "$SECRETS_DIR/github" >/dev/null <<GHEOF
GITHUB_TOKEN=$GITHUB_TOKEN
GHEOF
        sudo chmod 600 "$SECRETS_DIR/github"
    fi
    success "GitHub PAT saved to $SECRETS_DIR/github"
else
    info "GitHub: SKIPPED"
fi

success "=== Dependencies installed ==="
pause_continue


# =========================================================================
# PHASE 4: INSTALL OPENCLAW
# =========================================================================
phase "PHASE 4: INSTALL OPENCLAW"

# -- 4.1 Install CLI -------------------------------------------------------
if command -v openclaw &>/dev/null; then
    OC_VERSION=$(openclaw --version 2>/dev/null || echo "unknown")
    success "OpenClaw CLI already installed ($OC_VERSION)"

    if prompt_yn "Update to latest version?" "n"; then
        run_cmd sudo npm install -g openclaw@latest
    fi
else
    info "Installing OpenClaw CLI via npm..."
    echo "  (Using npm to avoid the auto-onboarding that the curl installer triggers)"
    run_cmd sudo npm install -g openclaw@latest
    verify "OpenClaw installed" command -v openclaw
fi

# Resolve actual binary path for systemd
OPENCLAW_BIN=$(which openclaw 2>/dev/null || echo "/usr/bin/openclaw")
info "OpenClaw binary: $OPENCLAW_BIN"

# -- 4.2 Tailscale Serve ---------------------------------------------------
if ! $SKIP_TAILSCALE; then
    echo ""
    info "Setting up Tailscale Serve for gateway on port $GATEWAY_PORT..."

    # Check for existing serve config
    if ! $DRY_RUN && tailscale serve status 2>/dev/null | grep -q "$GATEWAY_PORT"; then
        warn "Tailscale Serve already configured for port $GATEWAY_PORT"
    else
        run_cmd sudo tailscale serve --bg "$GATEWAY_PORT"
    fi

    action_required "Tailscale Serve needs HTTPS certificates enabled.\n\n  1. A URL was printed above -- open it in your browser\n  2. CHECK 'HTTPS certificates'\n  3. UNCHECK 'Tailscale Funnel' (this would expose to the public internet!)\n  4. Click Enable"

    pause_confirm "HTTPS certificates enabled in Tailscale admin?"

    info "Setting Tailscale operator to $SERVICE_USER..."
    run_cmd sudo tailscale set --operator="$SERVICE_USER"
    success "Tailscale Serve configured"
fi

# -- 4.3 Generate config via Python (safe JSON) ----------------------------
info "Generating OpenClaw configuration..."
echo ""

GATEWAY_TOKEN=""
if ! $DRY_RUN; then
    GATEWAY_TOKEN=$(openssl rand -hex 24)

    # Build allowed origins list
    ORIGINS='["https://localhost:'"$GATEWAY_PORT"'"'
    if [[ -n "${TS_FQDN:-}" ]]; then
        ORIGINS="$ORIGINS, \"https://$TS_FQDN\""
    fi
    ORIGINS="$ORIGINS]"

    sudo -u "$SERVICE_USER" mkdir -p "$OPENCLAW_DIR"

    # Generate config using Python (no injection possible)
    OC_PORT="$GATEWAY_PORT" \
    OC_WORKSPACE="$WORKSPACE_DIR" \
    OC_GATEWAY_TOKEN="$GATEWAY_TOKEN" \
    OC_ALLOWED_ORIGINS="$ORIGINS" \
    OC_TELEGRAM_TOKEN="${TELEGRAM_TOKEN:-}" \
    OC_SKIP_TAILSCALE="$SKIP_TAILSCALE" \
    OC_CHROMIUM_PATH="${CHROMIUM_PATH:-}" \
    generate_openclaw_config | sudo -u "$SERVICE_USER" tee "$OPENCLAW_DIR/openclaw.json" >/dev/null

    success "Config generated: $OPENCLAW_DIR/openclaw.json"

    # Store API key in the correct OpenClaw location
    # Docs: ~/.openclaw/agents/<agentId>/agent/auth-profiles.json
    sudo -u "$SERVICE_USER" mkdir -p "$OPENCLAW_DIR/agents/main/agent"
    OC_API_KEY="$API_KEY" generate_auth_file | sudo -u "$SERVICE_USER" tee "$OPENCLAW_DIR/agents/main/agent/auth-profiles.json" >/dev/null
    sudo -u "$SERVICE_USER" chmod 600 "$OPENCLAW_DIR/agents/main/agent/auth-profiles.json"

    # Save gateway token to secrets file
    sudo -u "$SERVICE_USER" tee "$SECRETS_DIR/gateway-token" >/dev/null <<< "$GATEWAY_TOKEN"
    sudo -u "$SERVICE_USER" chmod 600 "$SECRETS_DIR/gateway-token"

    success "API key and gateway token stored securely"
    echo ""
    info "Gateway token saved to: $SECRETS_DIR/gateway-token"
    info "API key saved to: $OPENCLAW_DIR/agents/main/agent/auth-profiles.json"
    info "Token: ${GATEWAY_TOKEN:0:12}... (see file for full token)"
    echo ""
else
    echo -e "${YELLOW}[DRY-RUN]${NC} Generate openclaw.json via Python3 JSON builder"
fi

# -- 4.4 Backup config, then optionally run onboarding --------------------
echo ""
info "OpenClaw interactive onboarding can finalize setup and validate config."
echo ""

if $INSTALL_ALL || prompt_yn "Run 'openclaw onboard' now? (recommended for first install)" "y"; then
    # Backup the generated config before onboarding potentially overwrites it
    if ! $DRY_RUN && [[ -f "$OPENCLAW_DIR/openclaw.json" ]]; then
        sudo -u "$SERVICE_USER" cp "$OPENCLAW_DIR/openclaw.json" "$OPENCLAW_DIR/openclaw.json.pre-onboard"
        info "Config backed up to openclaw.json.pre-onboard"
    fi

    echo ""
    echo "  Recommended onboarding choices:"
    echo "  ┌────────────────────────────┬───────────────────────────┐"
    echo "  │ Prompt                     │ Choose                    │"
    echo "  ├────────────────────────────┼───────────────────────────┤"
    echo "  │ What to set up?            │ Local gateway             │"
    echo "  │ Workspace directory        │ (accept default)          │"
    echo "  │ Onboarding mode            │ Manual                    │"
    echo "  │ Model/auth provider        │ Anthropic                 │"
    echo "  │ API key                    │ (already configured)      │"
    echo "  │ Gateway port               │ $GATEWAY_PORT             │"
    echo "  │ Gateway bind               │ Loopback (127.0.0.1)     │"
    echo "  │ Gateway auth               │ Token                     │"
    echo "  │ Tailscale exposure         │ Serve (NOT Funnel!)       │"
    echo "  │ Reset Tailscale on exit?   │ No                        │"
    echo "  │ Configure channels?        │ No (add later)            │"
    echo "  │ Configure DM policies?     │ No (accept pairing)       │"
    echo "  └────────────────────────────┴───────────────────────────┘"
    echo ""

    pause_confirm "Ready to start onboarding?"

    if ! $DRY_RUN; then
        sudo -u "$SERVICE_USER" openclaw onboard || warn "Onboarding had issues. You can re-run: sudo -u $SERVICE_USER openclaw onboard"
    else
        echo -e "${YELLOW}[DRY-RUN]${NC} sudo -u $SERVICE_USER openclaw onboard"
    fi
else
    info "Skipping onboarding. Run later: sudo -u $SERVICE_USER openclaw onboard"
fi

# -- 4.5 Permissions (run AFTER onboarding to catch root-owned files) ------
info "Setting file permissions..."
run_cmd sudo chown -R "$SERVICE_USER:$SERVICE_USER" "$USER_HOME"
run_cmd sudo chmod 700 "$OPENCLAW_DIR"
run_cmd sudo chmod 600 "$OPENCLAW_DIR/openclaw.json" 2>/dev/null || true
success "File permissions locked down"

# -- 4.6 Check for accidental .openclaw in admin home ----------------------
if [[ -d "/home/$ADMIN_USER/.openclaw" ]]; then
    warn "Found .openclaw directory in /home/$ADMIN_USER/ -- this was probably"
    warn "created by running openclaw commands without 'sudo -u $SERVICE_USER'."
    warn "It should be removed: rm -rf /home/$ADMIN_USER/.openclaw"
fi

# -- 4.7 Workspace template ------------------------------------------------
if [[ -n "$WORKSPACE_TEMPLATE" ]]; then
    info "Copying workspace template from $WORKSPACE_TEMPLATE..."
    if [[ -d "$WORKSPACE_TEMPLATE" ]]; then
        run_cmd sudo mkdir -p "$WORKSPACE_DIR"
        sudo cp -r "$WORKSPACE_TEMPLATE"/. "$WORKSPACE_DIR"/ 2>/dev/null || true
        run_cmd sudo chown -R "$SERVICE_USER:$SERVICE_USER" "$WORKSPACE_DIR"
        success "Workspace template copied"
    else
        warn "Template directory not found: $WORKSPACE_TEMPLATE"
    fi
else
    info "No workspace template provided (skipping)"
fi

# -- 4.8 Meta-frameworks (from jetclaw templates/) -------------------------
echo ""
# Find the templates directory relative to where the script lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_SRC="$SCRIPT_DIR/templates/meta-frameworks"

if $INSTALL_ALL || prompt_yn "Install meta-frameworks? (operational philosophy templates)" "y"; then
    if ! $DRY_RUN; then
        if [[ -d "$TEMPLATES_SRC" ]]; then
            sudo -u "$SERVICE_USER" mkdir -p "$WORKSPACE_DIR/meta-frameworks"

            # Copy all template files (skip README)
            for f in "$TEMPLATES_SRC"/*.md; do
                [[ -f "$f" ]] || continue
                fname=$(basename "$f")
                [[ "$fname" == "README.md" ]] && continue
                sudo cp "$f" "$WORKSPACE_DIR/meta-frameworks/$fname"
            done

            # Replace placeholders with actual values using | as sed delimiter
            # (avoids issues if values contain / or &)
            AGENT_DISPLAY="${SERVICE_USER^}"  # capitalize first letter
            info "Customizing meta-frameworks..."
            info "  {agent} → $AGENT_DISPLAY"
            info "  {user} → ${DISPLAY_NAME:-$ADMIN_USER}"
            if [[ -n "${COMPANY_NAME:-}" ]]; then
                info "  {company} → $COMPANY_NAME"
            fi

            for f in "$WORKSPACE_DIR/meta-frameworks"/*.md; do
                [[ -f "$f" ]] || continue
                sudo sed -i "s|{agent}|$AGENT_DISPLAY|g" "$f"
                sudo sed -i "s|{user}|${DISPLAY_NAME:-$ADMIN_USER}|g" "$f"
                if [[ -n "${COMPANY_NAME:-}" ]]; then
                    sudo sed -i "s|{company}|$COMPANY_NAME|g" "$f"
                fi
                if [[ -n "${DOMAIN:-}" ]]; then
                    sudo sed -i "s|{domain}|$DOMAIN|g" "$f"
                fi
            done

            sudo chown -R "$SERVICE_USER:$SERVICE_USER" "$WORKSPACE_DIR/meta-frameworks"
            success "Meta-frameworks installed and customized"
            echo "  Files:"
            ls "$WORKSPACE_DIR/meta-frameworks/"*.md 2>/dev/null | while read -r f; do
                echo "    $(basename "$f")"
            done
        else
            warn "Templates not found at: $TEMPLATES_SRC"
            warn "Make sure you cloned the full jetclaw repo (not just the script)."
        fi
    else
        echo -e "${YELLOW}[DRY-RUN]${NC} Copy meta-frameworks from $TEMPLATES_SRC to workspace, replace placeholders"
        echo -e "${YELLOW}[DRY-RUN]${NC}   {agent} → ${SERVICE_USER^}"
        echo -e "${YELLOW}[DRY-RUN]${NC}   {user} → ${DISPLAY_NAME:-$ADMIN_USER}"
        echo -e "${YELLOW}[DRY-RUN]${NC}   {company} → ${COMPANY_NAME:-<not set>}"
    fi
else
    info "Skipping meta-frameworks"
fi

success "=== OpenClaw installed ==="
pause_continue


# =========================================================================
# PHASE 5: SYSTEMD SERVICE
# =========================================================================
phase "PHASE 5: SYSTEMD SERVICE"

info "Creating systemd service: $SYSTEMD_SERVICE"
echo "  Service file: $SYSTEMD_PATH"
echo "  Runs as:      $SERVICE_USER"
echo "  Starts:       $OPENCLAW_BIN gateway run"
echo "  Auto-restart: on failure (10s delay)"
echo ""

# Build Requires= line conditionally
REQUIRES_LINE=""
if ! $SKIP_DOCKER && command -v docker &>/dev/null; then
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

echo ""
if $INSTALL_ALL || prompt_yn "Start the gateway now?" "y"; then
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


# =========================================================================
# PHASE 6: POST-INSTALL VERIFICATION
# =========================================================================
phase "PHASE 6: POST-INSTALL VERIFICATION"

info "Running post-install checks..."
echo ""

# Check service is running
if ! $DRY_RUN && systemctl is-active --quiet "$SYSTEMD_SERVICE" 2>/dev/null; then
    success "Systemd service: running"
else
    warn "Systemd service: not running (may still be booting)"
fi

# Check port
if ! $DRY_RUN && sudo ss -tlnp 2>/dev/null | grep -q ":${GATEWAY_PORT} "; then
    success "Gateway port $GATEWAY_PORT: listening"
else
    warn "Gateway port $GATEWAY_PORT: not yet listening"
fi

# Check file ownership
if ! $DRY_RUN; then
    BAD_OWNER=$(find "$USER_HOME" -not -user "$SERVICE_USER" 2>/dev/null | head -5)
    if [[ -z "$BAD_OWNER" ]]; then
        success "File ownership: all files owned by $SERVICE_USER"
    else
        warn "Some files not owned by $SERVICE_USER:"
        echo "$BAD_OWNER" | head -5
        echo "  Fix: sudo chown -R $SERVICE_USER:$SERVICE_USER $USER_HOME"
    fi
fi

# Check no accidental .openclaw in admin home
if [[ -d "/home/$ADMIN_USER/.openclaw" ]]; then
    warn "Accidental .openclaw in /home/$ADMIN_USER/ -- remove it"
else
    success "No accidental .openclaw in admin home"
fi

# Run openclaw doctor if gateway is up
if ! $DRY_RUN && systemctl is-active --quiet "$SYSTEMD_SERVICE" 2>/dev/null; then
    echo ""
    if $INSTALL_ALL || prompt_yn "Run 'openclaw doctor' to validate the installation?" "y"; then
        sudo -u "$SERVICE_USER" openclaw doctor --fix 2>/dev/null || warn "Doctor reported issues. Review output above."
    fi

    if $INSTALL_ALL || prompt_yn "Run 'openclaw security audit' to check security?" "y"; then
        sudo -u "$SERVICE_USER" openclaw security audit --deep 2>/dev/null || warn "Security audit reported issues. Review output above."
    fi
fi


# =========================================================================
# PHASE 7: SUMMARY & NEXT STEPS
# =========================================================================
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
echo "    Log file:         $LOG_FILE"

if [[ -n "${TS_FQDN:-}" ]]; then
    echo "    Tailscale host:   $TS_FQDN"
fi

# Use the best available SSH target for instructions
SSH_TARGET="$HOSTNAME_NEW"
if [[ -z "${TS_FQDN:-}" ]]; then
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

if [[ -n "${TS_FQDN:-}" ]]; then
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

if [[ -n "$TELEGRAM_TOKEN" ]]; then
    ((STEP++))
    echo "  $STEP. ${BOLD}Pair Telegram:${NC}"
    echo "       Message your bot on Telegram, then approve:"
    echo "       sudo -u $SERVICE_USER openclaw pairing list telegram"
    echo "       sudo -u $SERVICE_USER openclaw pairing approve telegram <code>"
    echo ""
fi

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
