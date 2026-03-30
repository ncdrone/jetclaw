#!/usr/bin/env bash
#
# 06-install-openclaw.sh — Install OpenClaw CLI and configure the gateway
#
# Handles: npm install, Tailscale Serve, config generation, onboarding,
#          meta-frameworks, workspace templates.
#
# Run ON the target machine as your admin user with sudo access.
#
# Usage:
#   ./scripts/06-install-openclaw.sh --user praxis --api-key sk-ant-xxx
#   ./scripts/06-install-openclaw.sh --user praxis --api-key sk-ant-xxx --telegram-token xxx
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
API_KEY="${API_KEY:-}"
TELEGRAM_TOKEN="${TELEGRAM_TOKEN:-}"
WORKSPACE_TEMPLATE="${WORKSPACE_TEMPLATE:-}"
DISPLAY_NAME="${DISPLAY_NAME:-}"
COMPANY_NAME="${COMPANY_NAME:-}"
DOMAIN="${DOMAIN:-}"
SKIP_TAILSCALE="${SKIP_TAILSCALE:-false}"
SKIP_ONBOARD="${SKIP_ONBOARD:-false}"
SKIP_META="${SKIP_META:-false}"
CHROMIUM_PATH="${CHROMIUM_PATH:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)                [[ $# -ge 2 ]] || fatal "--user requires a value"; SERVICE_USER="$2"; shift 2 ;;
        --admin-user)          [[ $# -ge 2 ]] || fatal "--admin-user requires a value"; ADMIN_USER="$2"; shift 2 ;;
        --port)                [[ $# -ge 2 ]] || fatal "--port requires a value"; GATEWAY_PORT="$2"; shift 2 ;;
        --api-key)             [[ $# -ge 2 ]] || fatal "--api-key requires a value"; API_KEY="$2"; shift 2 ;;
        --telegram-token)      [[ $# -ge 2 ]] || fatal "--telegram-token requires a value"; TELEGRAM_TOKEN="$2"; shift 2 ;;
        --workspace-template)  [[ $# -ge 2 ]] || fatal "--workspace-template requires a value"; WORKSPACE_TEMPLATE="$2"; shift 2 ;;
        --display-name)        [[ $# -ge 2 ]] || fatal "--display-name requires a value"; DISPLAY_NAME="$2"; shift 2 ;;
        --company)             [[ $# -ge 2 ]] || fatal "--company requires a value"; COMPANY_NAME="$2"; shift 2 ;;
        --domain)              [[ $# -ge 2 ]] || fatal "--domain requires a value"; DOMAIN="$2"; shift 2 ;;
        --skip-tailscale)      SKIP_TAILSCALE=true; shift ;;
        --skip-onboard)        SKIP_ONBOARD=true; shift ;;
        --skip-meta)           SKIP_META=true; shift ;;
        --dry-run)             DRY_RUN=true; shift ;;
        --help)                echo "Usage: $0 --user <name> --api-key <key> [--port <port>] [--dry-run]"; exit 0 ;;
        *) fatal "Unknown argument: $1" ;;
    esac
done

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
require_sudo
require_python3
prompt_value SERVICE_USER "Service user name"
require_service_user "$SERVICE_USER"
require_node

validate_port "$GATEWAY_PORT"

USER_HOME="/var/lib/$SERVICE_USER"
OPENCLAW_DIR="$USER_HOME/.openclaw"
WORKSPACE_DIR="$OPENCLAW_DIR/workspace"
SECRETS_DIR="$USER_HOME/.secrets"

phase "INSTALL OPENCLAW"

# ---------------------------------------------------------------------------
# Get API key if not provided
# ---------------------------------------------------------------------------
if [[ -z "$API_KEY" ]]; then
    echo -e "${BOLD}--- API Keys ---${NC}"
    echo ""
    echo "  You need an Anthropic API key. Options:"
    echo "    A) Claude Max token  -- from 'claude setup-token' on your Mac"
    echo "    B) Regular API key   -- from console.anthropic.com"
    echo ""
    prompt_secret API_KEY "Paste your Anthropic API key (input hidden)"
fi

if [[ "$API_KEY" == sk-ant-oat01-* ]]; then
    warn "This looks like an OAuth token (sk-ant-oat01-*). These expire periodically."
    warn "You'll need to rotate it when it expires."
fi

# ---------------------------------------------------------------------------
# Install CLI
# ---------------------------------------------------------------------------
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

OPENCLAW_BIN=$(which openclaw 2>/dev/null || echo "/usr/bin/openclaw")
info "OpenClaw binary: $OPENCLAW_BIN"

# ---------------------------------------------------------------------------
# Tailscale Serve
# ---------------------------------------------------------------------------
if ! $SKIP_TAILSCALE && command -v tailscale &>/dev/null; then
    echo ""
    info "Setting up Tailscale Serve for gateway on port $GATEWAY_PORT..."

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

# ---------------------------------------------------------------------------
# Generate config via Python (safe JSON)
# ---------------------------------------------------------------------------
info "Generating OpenClaw configuration..."
echo ""

GATEWAY_TOKEN=""
if ! $DRY_RUN; then
    sudo -u "$SERVICE_USER" mkdir -p "$OPENCLAW_DIR"

    # Check if config already exists (re-run protection)
    SKIP_CONFIG_GEN=false
    if [[ -f "$OPENCLAW_DIR/openclaw.json" ]]; then
        warn "Config already exists: $OPENCLAW_DIR/openclaw.json"
        if prompt_yn "Overwrite existing config? (NO keeps your current config)" "n"; then
            sudo -u "$SERVICE_USER" cp "$OPENCLAW_DIR/openclaw.json" "$OPENCLAW_DIR/openclaw.json.backup-$(date +%s)"
            info "Existing config backed up"
        else
            info "Keeping existing config"
            if [[ -f "$SECRETS_DIR/gateway-token" ]]; then
                GATEWAY_TOKEN=$(sudo cat "$SECRETS_DIR/gateway-token" 2>/dev/null || echo "")
                info "Using existing gateway token"
            fi
            SKIP_CONFIG_GEN=true
        fi
    fi

    if ! $SKIP_CONFIG_GEN; then
        GATEWAY_TOKEN=$(openssl rand -hex 24)

        # Get Tailscale info for allowed origins
        TS_FQDN="${TS_FQDN:-}"
        if [[ -z "$TS_FQDN" ]] && command -v tailscale &>/dev/null; then
            TS_FQDN=$(tailscale status --json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Self',{}).get('DNSName','').rstrip('.'))" 2>/dev/null || echo "")
        fi

        ORIGINS='["https://localhost:'"$GATEWAY_PORT"'"'
        if [[ -n "$TS_FQDN" ]]; then
            ORIGINS="$ORIGINS, \"https://$TS_FQDN\""
        fi
        ORIGINS="$ORIGINS]"

        # Detect chromium if not passed in
        if [[ -z "$CHROMIUM_PATH" ]]; then
            CHROMIUM_PATH=$(command -v chromium-browser 2>/dev/null || command -v chromium 2>/dev/null || echo "")
        fi

        OC_PORT="$GATEWAY_PORT" \
        OC_WORKSPACE="$WORKSPACE_DIR" \
        OC_GATEWAY_TOKEN="$GATEWAY_TOKEN" \
        OC_ALLOWED_ORIGINS="$ORIGINS" \
        OC_TELEGRAM_TOKEN="${TELEGRAM_TOKEN:-}" \
        OC_SKIP_TAILSCALE="$SKIP_TAILSCALE" \
        OC_CHROMIUM_PATH="${CHROMIUM_PATH:-}" \
        generate_openclaw_config | sudo -u "$SERVICE_USER" tee "$OPENCLAW_DIR/openclaw.json" >/dev/null

        success "Config generated: $OPENCLAW_DIR/openclaw.json"

        # Store API key
        sudo -u "$SERVICE_USER" mkdir -p "$OPENCLAW_DIR/agents/main/agent"
        OC_API_KEY="$API_KEY" generate_auth_file | sudo -u "$SERVICE_USER" tee "$OPENCLAW_DIR/agents/main/agent/auth-profiles.json" >/dev/null
        sudo -u "$SERVICE_USER" chmod 600 "$OPENCLAW_DIR/agents/main/agent/auth-profiles.json"

        # Save gateway token
        sudo -u "$SERVICE_USER" tee "$SECRETS_DIR/gateway-token" >/dev/null <<< "$GATEWAY_TOKEN"
        sudo -u "$SERVICE_USER" chmod 600 "$SECRETS_DIR/gateway-token"

        success "API key and gateway token stored securely"
    fi

    echo ""
    info "Gateway token saved to: $SECRETS_DIR/gateway-token"
    info "Token: ${GATEWAY_TOKEN:0:12}... (see file for full token)"
else
    echo -e "${YELLOW}[DRY-RUN]${NC} Generate openclaw.json via Python3 JSON builder"
fi

# ---------------------------------------------------------------------------
# Onboarding (optional)
# ---------------------------------------------------------------------------
if ! $SKIP_ONBOARD; then
    echo ""
    info "OpenClaw interactive onboarding can finalize setup and validate config."
    echo ""

    if prompt_yn "Run 'openclaw onboard' now? (recommended for first install)" "y"; then
        if ! $DRY_RUN && [[ -f "$OPENCLAW_DIR/openclaw.json" ]]; then
            sudo -u "$SERVICE_USER" cp "$OPENCLAW_DIR/openclaw.json" "$OPENCLAW_DIR/openclaw.json.pre-onboard"
            info "Config backed up to openclaw.json.pre-onboard"
        fi

        echo ""
        echo "  Recommended onboarding choices:"
        echo "  +---------------------------------+----------------------------+"
        echo "  | Prompt                          | Choose                     |"
        echo "  +---------------------------------+----------------------------+"
        echo "  | What to set up?                 | Local gateway              |"
        echo "  | Workspace directory             | (accept default)           |"
        echo "  | Onboarding mode                 | Manual                     |"
        echo "  | Model/auth provider             | Anthropic                  |"
        echo "  | API key                         | (already configured)       |"
        echo "  | Gateway port                    | $GATEWAY_PORT              |"
        echo "  | Gateway bind                    | Loopback (127.0.0.1)       |"
        echo "  | Gateway auth                    | Token                      |"
        echo "  | Tailscale exposure              | Serve (NOT Funnel!)        |"
        echo "  | Reset Tailscale on exit?        | No                         |"
        echo "  | Configure channels?             | No (add later)             |"
        echo "  | Configure DM policies?          | No (accept pairing)        |"
        echo "  +---------------------------------+----------------------------+"
        echo ""

        pause_confirm "Ready to start onboarding?"

        if ! $DRY_RUN; then
            sudo -u "$SERVICE_USER" openclaw onboard || warn "Onboarding had issues. Re-run: sudo -u $SERVICE_USER openclaw onboard"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Fix permissions (after onboarding may have created root-owned files)
# ---------------------------------------------------------------------------
info "Setting file permissions..."
run_cmd sudo chown -R "$SERVICE_USER:$SERVICE_USER" "$USER_HOME"
run_cmd sudo chmod 700 "$OPENCLAW_DIR"
run_cmd sudo chmod 600 "$OPENCLAW_DIR/openclaw.json" 2>/dev/null || true
success "File permissions locked down"

# Check for accidental .openclaw in admin home
if [[ -d "/home/$ADMIN_USER/.openclaw" ]]; then
    warn "Found .openclaw directory in /home/$ADMIN_USER/"
    warn "Created by running openclaw commands without 'sudo -u $SERVICE_USER'."
    warn "Remove it: rm -rf /home/$ADMIN_USER/.openclaw"
fi

# ---------------------------------------------------------------------------
# Workspace template
# ---------------------------------------------------------------------------
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
fi

# ---------------------------------------------------------------------------
# Meta-frameworks
# ---------------------------------------------------------------------------
if ! $SKIP_META; then
    # Find templates relative to the jetclaw repo root
    REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
    TEMPLATES_SRC="$REPO_ROOT/templates/meta-frameworks"

    if prompt_yn "Install meta-frameworks? (operational philosophy templates)" "y"; then
        if ! $DRY_RUN; then
            if [[ -d "$TEMPLATES_SRC" ]]; then
                sudo -u "$SERVICE_USER" mkdir -p "$WORKSPACE_DIR/meta-frameworks"

                for f in "$TEMPLATES_SRC"/*.md; do
                    [[ -f "$f" ]] || continue
                    fname=$(basename "$f")
                    [[ "$fname" == "README.md" ]] && continue
                    sudo cp "$f" "$WORKSPACE_DIR/meta-frameworks/$fname"
                done

                # Replace placeholders
                AGENT_DISPLAY="${SERVICE_USER^}"
                info "Customizing meta-frameworks..."
                info "  {agent} -> $AGENT_DISPLAY"
                info "  {user} -> ${DISPLAY_NAME:-$ADMIN_USER}"
                [[ -n "${COMPANY_NAME:-}" ]] && info "  {company} -> $COMPANY_NAME"

                for f in "$WORKSPACE_DIR/meta-frameworks"/*.md; do
                    [[ -f "$f" ]] || continue
                    sudo sed -i "s|{agent}|$AGENT_DISPLAY|g" "$f"
                    sudo sed -i "s|{user}|${DISPLAY_NAME:-$ADMIN_USER}|g" "$f"
                    [[ -n "${COMPANY_NAME:-}" ]] && sudo sed -i "s|{company}|$COMPANY_NAME|g" "$f"
                    [[ -n "${DOMAIN:-}" ]] && sudo sed -i "s|{domain}|$DOMAIN|g" "$f"
                done

                sudo chown -R "$SERVICE_USER:$SERVICE_USER" "$WORKSPACE_DIR/meta-frameworks"
                success "Meta-frameworks installed and customized"
            else
                warn "Templates not found at: $TEMPLATES_SRC"
                warn "Make sure you cloned the full jetclaw repo."
            fi
        fi
    fi
fi

echo ""
success "=== OpenClaw installed ==="

# Export for orchestrator
export OPENCLAW_BIN GATEWAY_TOKEN
