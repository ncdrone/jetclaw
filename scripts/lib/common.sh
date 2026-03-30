#!/usr/bin/env bash
#
# common.sh — Shared utilities for all jetclaw install scripts
#
# Source this file at the top of every script:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/../lib/common.sh"  (from scripts/)
#   source "$SCRIPT_DIR/lib/common.sh"     (from scripts/lib/)
#
# Provides: colors, logging, prompts, validation, execution helpers,
#           JSON generation, prerequisite checks.
#

# Prevent double-sourcing
[[ -n "${_JETCLAW_COMMON_LOADED:-}" ]] && return 0
_JETCLAW_COMMON_LOADED=1

# ---------------------------------------------------------------------------
# Logging — all output goes to terminal AND a log file
# ---------------------------------------------------------------------------
LOG_FILE="${LOG_FILE:-/tmp/openclaw-install-$(date +%Y%m%d-%H%M%S).log}"
exec > >(tee -a "$LOG_FILE") 2>&1

# ---------------------------------------------------------------------------
# State tracking for cleanup
# ---------------------------------------------------------------------------
CURRENT_PHASE="${CURRENT_PHASE:-pre-flight}"

cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        echo ""
        echo -e "\033[0;31m[FAILED]\033[0m Script failed during: $CURRENT_PHASE"
        echo -e "\033[0;31m[FAILED]\033[0m Log file: $LOG_FILE"
        echo ""
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Colors / helpers — check the REAL terminal, not the tee pipe
# ---------------------------------------------------------------------------
if [[ -t 0 ]]; then
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
    read -rp "  $msg [Y/n] " confirm
    [[ "$confirm" =~ ^[Nn]$ ]] && { warn "Paused. Re-run when ready."; exit 0; }
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

    eval "current_val=\"\${$varname:-}\""

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
DRY_RUN="${DRY_RUN:-false}"

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
# Prerequisite checks — call from individual scripts
# ---------------------------------------------------------------------------
require_sudo() {
    if [[ $EUID -eq 0 ]]; then
        fatal "Do not run this script as root. Run as your admin user with sudo access."
    fi
    sudo -n true 2>/dev/null || {
        info "Enter your password to confirm sudo access:"
        sudo -v || fatal "Sudo access required."
    }
    success "Sudo access confirmed"
}

require_python3() {
    command -v python3 >/dev/null 2>&1 || fatal "python3 is required but not found. Install: sudo apt install -y python3"
}

require_service_user() {
    local user="${1:?}"
    id "$user" &>/dev/null || fatal "Service user '$user' does not exist. Run 03-create-service-user.sh first."
    [[ -d "/var/lib/$user" ]] || fatal "Home directory /var/lib/$user does not exist."
}

require_node() {
    command -v node &>/dev/null || fatal "Node.js is not installed. Run 04-install-deps.sh first."
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
