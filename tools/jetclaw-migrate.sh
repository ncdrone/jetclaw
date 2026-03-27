#!/usr/bin/env bash
#
# jetclaw-migrate.sh — Copy a running OpenClaw instance to a new machine
#
# Run FROM your Mac (or any machine with SSH access to source and target).
# Part of the jetclaw toolkit: https://github.com/your-user/jetclaw
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
SOURCE_HOST=""
TARGET_HOST=""
SOURCE_USER=""
TARGET_USER=""
TARGET_PORT=""
TARGET_HOSTNAME=""
EXCLUDE_SESSIONS=false
EXCLUDE_CREDENTIALS=false
DRY_RUN=false

# ---------------------------------------------------------------------------
# Colors / helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
fatal()   { error "$*"; exit 1; }
phase()   { echo -e "\n${BOLD}========== $* ==========${NC}\n"; }

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<'EOF'
Usage: openclaw-migrate.sh --source <user@host> --target <user@host> --source-user <name> [options]

Required:
  --source <user@host>       Source machine SSH (e.g., ncd@metis)
  --target <user@host>       Target machine SSH (e.g., ncd@jetson2)
  --source-user <name>       Source OpenClaw service user (e.g., praxis)

Optional:
  --target-user <name>       Target service user (default: same as source-user)
  --target-port <number>     New gateway port (default: keep source config)
  --target-hostname <name>   New hostname in config (default: keep source)
  --exclude-sessions         Don't copy session history
  --exclude-credentials      Don't copy API keys/tokens (re-enter on target)
  --dry-run                  Show rsync/ssh commands without executing
  --help                     Show this help

Examples:
  # Copy from Jetson to VPS (keep sessions, exclude creds)
  ./openclaw-migrate.sh \
    --source ncd@metis --target ncd@aws-instance \
    --source-user praxis --exclude-credentials

  # Move to new Jetson with different port
  ./openclaw-migrate.sh \
    --source ncd@jetson2 --target ncd@jetson3 \
    --source-user praxis --target-port 18790
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --source)           SOURCE_HOST="$2"; shift 2 ;;
        --target)           TARGET_HOST="$2"; shift 2 ;;
        --source-user)      SOURCE_USER="$2"; shift 2 ;;
        --target-user)      TARGET_USER="$2"; shift 2 ;;
        --target-port)      TARGET_PORT="$2"; shift 2 ;;
        --target-hostname)  TARGET_HOSTNAME="$2"; shift 2 ;;
        --exclude-sessions) EXCLUDE_SESSIONS=true; shift ;;
        --exclude-credentials) EXCLUDE_CREDENTIALS=true; shift ;;
        --dry-run)          DRY_RUN=true; shift ;;
        --help)             usage ;;
        *) fatal "Unknown argument: $1" ;;
    esac
done

# Validate
[[ -z "$SOURCE_HOST" ]] && fatal "Missing: --source"
[[ -z "$TARGET_HOST" ]] && fatal "Missing: --target"
[[ -z "$SOURCE_USER" ]] && fatal "Missing: --source-user"
[[ -z "$TARGET_USER" ]] && TARGET_USER="$SOURCE_USER"

SOURCE_DIR="/var/lib/$SOURCE_USER/.openclaw"
TARGET_DIR="/var/lib/$TARGET_USER/.openclaw"

# ---------------------------------------------------------------------------
# PHASE 1: PRE-FLIGHT
# ---------------------------------------------------------------------------
phase "PHASE 1: PRE-FLIGHT CHECKS"

info "Source: $SOURCE_HOST (user: $SOURCE_USER, dir: $SOURCE_DIR)"
info "Target: $TARGET_HOST (user: $TARGET_USER, dir: $TARGET_DIR)"

# Test SSH to source
info "Testing SSH to source..."
if ssh -o ConnectTimeout=5 "$SOURCE_HOST" "echo ok" >/dev/null 2>&1; then
    success "Source SSH works"
else
    fatal "Cannot SSH to source: $SOURCE_HOST"
fi

# Test SSH to target
info "Testing SSH to target..."
if ssh -o ConnectTimeout=5 "$TARGET_HOST" "echo ok" >/dev/null 2>&1; then
    success "Target SSH works"
else
    fatal "Cannot SSH to target: $TARGET_HOST"
fi

# Check source dir exists
info "Checking source OpenClaw directory..."
if ssh "$SOURCE_HOST" "sudo test -d '$SOURCE_DIR'" 2>/dev/null; then
    success "Source directory exists: $SOURCE_DIR"
else
    fatal "Source OpenClaw directory not found: $SOURCE_DIR on $SOURCE_HOST"
fi

# Check source dir size
SOURCE_SIZE=$(ssh "$SOURCE_HOST" "sudo du -sh '$SOURCE_DIR' 2>/dev/null | cut -f1" || echo "unknown")
info "Source directory size: $SOURCE_SIZE"

# Check target has openclaw
info "Checking target has OpenClaw CLI..."
if ssh "$TARGET_HOST" "command -v openclaw" >/dev/null 2>&1; then
    success "OpenClaw CLI found on target"
else
    warn "OpenClaw CLI not found on target. Run openclaw-install.sh on target first."
    fatal "Target missing OpenClaw. Install it first, then migrate."
fi

# Check target service user exists
info "Checking target service user..."
if ssh "$TARGET_HOST" "id '$TARGET_USER'" >/dev/null 2>&1; then
    success "Target user $TARGET_USER exists"
else
    warn "Target user $TARGET_USER does not exist."
    fatal "Run openclaw-install.sh on target first to create the service user, then migrate."
fi

echo ""
if ! $DRY_RUN; then
    read -rp "Proceed with migration? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }
fi

# ---------------------------------------------------------------------------
# PHASE 2: RSYNC
# ---------------------------------------------------------------------------
phase "PHASE 2: TRANSFER FILES"

# Build rsync excludes
EXCLUDES=(
    --exclude='node_modules'
    --exclude='.cache'
    --exclude='ms-playwright'
    --exclude='chromium-*'
)

if $EXCLUDE_SESSIONS; then
    EXCLUDES+=(--exclude='agents/*/sessions')
    info "Excluding session history"
fi

if $EXCLUDE_CREDENTIALS; then
    EXCLUDES+=(
        --exclude='auth/'
        --exclude='credentials/'
        --exclude='agents/*/auth-profiles.json'
    )
    info "Excluding credentials (you'll need to re-enter API keys)"
fi

# We need to rsync via a temp directory since we can't direct rsync between
# two remote hosts. Use the local machine as a relay.
TEMP_DIR=$(mktemp -d)
trap "rm -rf '$TEMP_DIR'" EXIT

info "Step 1: Pulling from source to local temp..."
RSYNC_CMD="rsync -avz --progress ${EXCLUDES[*]} '$SOURCE_HOST:$SOURCE_DIR/' '$TEMP_DIR/openclaw/'"

if $DRY_RUN; then
    echo -e "${YELLOW}[DRY-RUN]${NC} $RSYNC_CMD"
else
    # Need sudo on source to read the service user's files
    # Use ssh + tar instead of direct rsync for sudo access
    info "Packaging source files (via sudo on source)..."
    EXCLUDE_ARGS=""
    for ex in "${EXCLUDES[@]}"; do
        # Convert rsync excludes to tar excludes
        pattern=$(echo "$ex" | sed "s/--exclude='//" | sed "s/'//")
        EXCLUDE_ARGS="$EXCLUDE_ARGS --exclude='$pattern'"
    done

    mkdir -p "$TEMP_DIR/openclaw"
    ssh "$SOURCE_HOST" "sudo tar czf - -C '/var/lib/$SOURCE_USER' .openclaw $EXCLUDE_ARGS 2>/dev/null" | \
        tar xzf - -C "$TEMP_DIR/openclaw/" --strip-components=1 2>/dev/null || \
        fatal "Failed to pull files from source"

    LOCAL_SIZE=$(du -sh "$TEMP_DIR/openclaw/" | cut -f1)
    success "Pulled $LOCAL_SIZE to local temp"
fi

info "Step 2: Pushing to target..."
if $DRY_RUN; then
    echo -e "${YELLOW}[DRY-RUN]${NC} rsync local temp -> $TARGET_HOST:$TARGET_DIR/"
else
    # Push via tar + ssh for sudo write access on target
    ssh "$TARGET_HOST" "sudo mkdir -p '$TARGET_DIR'"
    tar czf - -C "$TEMP_DIR/openclaw" . | \
        ssh "$TARGET_HOST" "sudo tar xzf - -C '$TARGET_DIR/'" || \
        fatal "Failed to push files to target"
    success "Files transferred to target"
fi

# ---------------------------------------------------------------------------
# PHASE 3: CONFIGURE TARGET
# ---------------------------------------------------------------------------
phase "PHASE 3: CONFIGURE TARGET"

info "Fixing file ownership..."
if $DRY_RUN; then
    echo -e "${YELLOW}[DRY-RUN]${NC} ssh $TARGET_HOST sudo chown -R $TARGET_USER:$TARGET_USER $TARGET_DIR"
else
    ssh "$TARGET_HOST" "sudo chown -R '$TARGET_USER:$TARGET_USER' '$TARGET_DIR'"
    ssh "$TARGET_HOST" "sudo chmod 700 '$TARGET_DIR'"
    ssh "$TARGET_HOST" "sudo chmod 600 '$TARGET_DIR/openclaw.json' 2>/dev/null || true"
    success "Ownership fixed"
fi

# Update config if port or hostname changed
if [[ -n "$TARGET_PORT" ]] || [[ -n "$TARGET_HOSTNAME" ]]; then
    info "Updating config on target..."

    if ! $DRY_RUN; then
        # Pull config, modify, push back
        CONFIG_TEMP=$(mktemp)
        ssh "$TARGET_HOST" "sudo cat '$TARGET_DIR/openclaw.json'" > "$CONFIG_TEMP"

        if [[ -n "$TARGET_PORT" ]]; then
            # Update port in config (simple sed -- works for the port field)
            sed -i.bak "s/\"port\": [0-9]*/\"port\": $TARGET_PORT/" "$CONFIG_TEMP"
            info "Updated gateway port to $TARGET_PORT"
        fi

        if [[ -n "$TARGET_HOSTNAME" ]]; then
            # Update hostname references in allowedOrigins etc.
            # This is a best-effort replacement
            OLD_HOST=$(grep -o '"https://[^"]*\.ts\.net[^"]*"' "$CONFIG_TEMP" | head -1 | tr -d '"' | sed 's|https://||' | cut -d'/' -f1 || true)
            if [[ -n "$OLD_HOST" ]]; then
                sed -i.bak "s|$OLD_HOST|$TARGET_HOSTNAME|g" "$CONFIG_TEMP"
                info "Updated hostname references: $OLD_HOST -> $TARGET_HOSTNAME"
            fi
        fi

        # Push updated config
        cat "$CONFIG_TEMP" | ssh "$TARGET_HOST" "sudo -u '$TARGET_USER' tee '$TARGET_DIR/openclaw.json' >/dev/null"
        rm -f "$CONFIG_TEMP" "$CONFIG_TEMP.bak"
        success "Config updated on target"
    else
        echo -e "${YELLOW}[DRY-RUN]${NC} Update port/hostname in $TARGET_DIR/openclaw.json"
    fi
fi

if $EXCLUDE_CREDENTIALS; then
    echo ""
    warn "==> Credentials were excluded from migration."
    warn "    You need to set up API keys on the target:"
    warn "    ssh $TARGET_HOST"
    warn "    sudo -u $TARGET_USER openclaw onboard"
    echo ""
fi

# ---------------------------------------------------------------------------
# PHASE 4: START ON TARGET
# ---------------------------------------------------------------------------
phase "PHASE 4: START GATEWAY"

SERVICE_NAME="openclaw-${TARGET_USER}.service"
SERVICE_PATH="/etc/systemd/system/$SERVICE_NAME"

info "Checking for systemd service on target..."
if ! $DRY_RUN; then
    if ssh "$TARGET_HOST" "test -f '$SERVICE_PATH'" 2>/dev/null; then
        success "Service file exists: $SERVICE_NAME"
    else
        warn "Service file not found. The install script should have created it."
        warn "Run openclaw-install.sh on target if this is a fresh machine."
    fi

    info "Restarting gateway on target..."
    ssh "$TARGET_HOST" "sudo systemctl daemon-reload && sudo systemctl restart '$SERVICE_NAME'" || \
        warn "Failed to restart. Check: ssh $TARGET_HOST sudo journalctl -u $SERVICE_NAME -f"

    info "Waiting for gateway to start..."
    sleep 15
    PORT_TO_CHECK="${TARGET_PORT:-18789}"
    if ssh "$TARGET_HOST" "sudo ss -tlnp | grep -q ':$PORT_TO_CHECK'" 2>/dev/null; then
        success "Gateway is listening on port $PORT_TO_CHECK"
    else
        warn "Gateway not yet listening. It may still be booting (~60s on ARM)."
        warn "Check: ssh $TARGET_HOST sudo journalctl -u $SERVICE_NAME -f"
    fi
else
    echo -e "${YELLOW}[DRY-RUN]${NC} ssh $TARGET_HOST sudo systemctl restart $SERVICE_NAME"
fi

# ---------------------------------------------------------------------------
# PHASE 5: POST-MIGRATION
# ---------------------------------------------------------------------------
phase "PHASE 5: POST-MIGRATION"

echo -e "${BOLD}Migration complete!${NC}"
echo ""
echo "  Source: $SOURCE_HOST ($SOURCE_USER)"
echo "  Target: $TARGET_HOST ($TARGET_USER)"
echo ""
echo -e "${BOLD}Next steps:${NC}"
echo "  1. Re-pair Telegram/WhatsApp on the new instance"
echo "     (messaging platform sessions don't transfer)"
echo ""
echo "  2. Update your Mac SSH config if the target has a new hostname"
echo ""
echo "  3. Verify Tailscale Serve on the target:"
echo "     ssh $TARGET_HOST sudo tailscale serve status"
echo ""
echo "  4. Test the dashboard:"
echo "     ssh -N -L ${TARGET_PORT:-18789}:127.0.0.1:${TARGET_PORT:-18789} $TARGET_HOST"
echo "     Then open: http://localhost:${TARGET_PORT:-18789}"
echo ""

# Ask about source
echo -e "${BOLD}Source instance:${NC}"
echo "  The source gateway was NOT stopped during migration."
echo "  If this was a move (not a copy), stop the source:"
echo "    ssh $SOURCE_HOST sudo systemctl stop openclaw-${SOURCE_USER}"
echo "    ssh $SOURCE_HOST sudo systemctl disable openclaw-${SOURCE_USER}"
echo ""

success "Done."
