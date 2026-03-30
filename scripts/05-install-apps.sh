#!/usr/bin/env bash
#
# 05-install-apps.sh — Install apps that require API keys or auth flows
#
# Installs: GitHub CLI + PAT, Cloudflare Wrangler, Google Cloud CLI
# Each component is skippable with --skip-* flags.
#
# Run ON the target machine as your admin user with sudo access.
#
# Usage:
#   ./scripts/05-install-apps.sh --user praxis
#   ./scripts/05-install-apps.sh --user praxis --github-token ghp_xxx --skip-wrangler
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# ---------------------------------------------------------------------------
# CLI arguments
# ---------------------------------------------------------------------------
SERVICE_USER="${SERVICE_USER:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GITHUB_EMAIL="${GITHUB_EMAIL:-}"
SKIP_GITHUB="${SKIP_GITHUB:-false}"
SKIP_WRANGLER="${SKIP_WRANGLER:-false}"
SKIP_GCLOUD="${SKIP_GCLOUD:-false}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)           [[ $# -ge 2 ]] || fatal "--user requires a value"; SERVICE_USER="$2"; shift 2 ;;
        --github-token)   [[ $# -ge 2 ]] || fatal "--github-token requires a value"; GITHUB_TOKEN="$2"; shift 2 ;;
        --github-email)   [[ $# -ge 2 ]] || fatal "--github-email requires a value"; GITHUB_EMAIL="$2"; shift 2 ;;
        --skip-github)    SKIP_GITHUB=true; shift ;;
        --skip-wrangler)  SKIP_WRANGLER=true; shift ;;
        --skip-gcloud)    SKIP_GCLOUD=true; shift ;;
        --dry-run)        DRY_RUN=true; shift ;;
        --help)           echo "Usage: $0 --user <name> [--github-token <token>] [--skip-github] [--skip-wrangler] [--skip-gcloud] [--dry-run]"; exit 0 ;;
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

phase "INSTALL APPS (auth required)"

# =========================================================================
# GitHub (PAT storage + optional CLI)
# =========================================================================
if ! $SKIP_GITHUB; then
    echo -e "${BOLD}--- GitHub ---${NC}"
    echo ""

    # Prompt for token if not provided
    if [[ -z "$GITHUB_TOKEN" ]]; then
        if prompt_yn "Set up GitHub access for this agent?" "y"; then
            echo ""
            echo "  Create a fine-grained PAT at github.com/settings/tokens"
            echo "  with only the repos this agent needs access to."
            echo ""
            prompt_secret GITHUB_TOKEN "Paste GitHub PAT (input hidden)"
            if [[ -z "$GITHUB_EMAIL" ]]; then
                prompt_value GITHUB_EMAIL "GitHub email for commits"
            fi
        else
            SKIP_GITHUB=true
        fi
    fi

    if ! $SKIP_GITHUB && [[ -n "$GITHUB_TOKEN" ]]; then
        info "Storing GitHub PAT..."
        if ! $DRY_RUN; then
            sudo -u "$SERVICE_USER" tee "$SECRETS_DIR/github" >/dev/null <<GHEOF
GITHUB_TOKEN=$GITHUB_TOKEN
GHEOF
            sudo chmod 600 "$SECRETS_DIR/github"
        fi
        success "GitHub PAT saved to $SECRETS_DIR/github"

        # Update git email if provided
        if [[ -n "$GITHUB_EMAIL" ]]; then
            run_cmd sudo -u "$SERVICE_USER" git config --global user.email "$GITHUB_EMAIL"
            success "Git email updated: $GITHUB_EMAIL"
        fi

        # Install GitHub CLI if not present
        if ! command -v gh &>/dev/null; then
            if prompt_yn "Install GitHub CLI (gh)?" "y"; then
                info "Installing GitHub CLI..."
                if ! $DRY_RUN; then
                    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
                    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | \
                        sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
                    sudo apt update && sudo apt install -y gh
                fi
                success "GitHub CLI installed"
            fi
        else
            success "GitHub CLI already installed"
        fi
    fi
    echo ""
else
    info "GitHub: SKIPPED"
fi

# =========================================================================
# Cloudflare Wrangler
# =========================================================================
if ! $SKIP_WRANGLER; then
    echo -e "${BOLD}--- Cloudflare Wrangler ---${NC}"
    echo ""

    if command -v wrangler &>/dev/null; then
        WRANGLER_VER=$(wrangler --version 2>/dev/null | head -1)
        success "Wrangler already installed: $WRANGLER_VER"
    else
        if prompt_yn "Install Cloudflare Wrangler?" "y"; then
            require_node
            info "Installing Wrangler via npm..."
            run_cmd sudo npm install -g wrangler
            success "Wrangler installed"
        else
            SKIP_WRANGLER=true
        fi
    fi

    if ! $SKIP_WRANGLER && command -v wrangler &>/dev/null; then
        echo ""
        if prompt_yn "Log in to Cloudflare now? (opens browser)" "n"; then
            info "Starting Wrangler login..."
            echo "  This will open a browser window for Cloudflare authentication."
            echo ""
            wrangler login || warn "Wrangler login had issues. Run 'wrangler login' manually later."
        else
            info "Run 'wrangler login' later to authenticate."
        fi
    fi
    echo ""
else
    info "Wrangler: SKIPPED"
fi

# =========================================================================
# Google Cloud CLI
# =========================================================================
if ! $SKIP_GCLOUD; then
    echo -e "${BOLD}--- Google Cloud CLI ---${NC}"
    echo ""

    if command -v gcloud &>/dev/null; then
        GCLOUD_VER=$(gcloud --version 2>/dev/null | head -1)
        success "Google Cloud CLI already installed: $GCLOUD_VER"
    else
        if prompt_yn "Install Google Cloud CLI?" "y"; then
            info "Installing Google Cloud CLI..."
            if ! $DRY_RUN; then
                curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg 2>/dev/null || true
                echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | \
                    sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list >/dev/null
                sudo apt update && sudo apt install -y google-cloud-cli
            fi
            success "Google Cloud CLI installed"
        else
            SKIP_GCLOUD=true
        fi
    fi

    if ! $SKIP_GCLOUD && command -v gcloud &>/dev/null; then
        echo ""
        if prompt_yn "Log in to Google Cloud now?" "n"; then
            info "Starting gcloud auth..."
            echo "  This will open a browser window for Google authentication."
            echo ""
            gcloud auth login || warn "gcloud login had issues. Run 'gcloud auth login' manually later."
        else
            info "Run 'gcloud auth login' later to authenticate."
        fi
    fi
    echo ""
else
    info "Google Cloud CLI: SKIPPED"
fi

echo ""
success "=== Apps installed ==="
