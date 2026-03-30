#!/usr/bin/env bash
#
# jetclaw-verify.sh — Comprehensive verification of hardening + OpenClaw installation
#
# Run ON the target machine. Shows pass/fail for every install step from the
# metis-complete-guide-v2.md checklist. Covers: system hardening, Tailscale,
# service user, dependencies, apps, OpenClaw gateway, Arsenal services, and network.
#
set -uo pipefail

# Colors
if [[ -t 0 ]]; then
    RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m'
    BLUE='\033[0;34m' CYAN='\033[0;36m' BOLD='\033[1m' NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' NC=''
fi

PASS=0
FAIL=0
WARN=0
SKIP=0

pass() { echo -e "  ${GREEN}PASS${NC}  $*"; ((PASS++)); }
fail() { echo -e "  ${RED}FAIL${NC}  $*"; ((FAIL++)); }
warn() { echo -e "  ${YELLOW}WARN${NC}  $*"; ((WARN++)); }
skip() { echo -e "  ${CYAN}SKIP${NC}  $*"; ((SKIP++)); }
section() { echo -e "\n${BOLD}$*${NC}\n"; }

# Helper: check file permissions (Linux stat format)
check_perms() {
    local path="$1" expected="$2" label="${3:-$1}"
    if [[ ! -e "$path" ]]; then
        fail "$label: does not exist"
        return 1
    fi
    local perms
    perms=$(stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path" 2>/dev/null)
    if [[ "$perms" == "$expected" ]]; then
        pass "$label permissions: $perms"
    else
        fail "$label permissions: $perms (expected $expected)"
    fi
}

# Helper: check file ownership
check_owner() {
    local path="$1" expected="$2" label="${3:-$1}"
    if [[ ! -e "$path" ]]; then
        fail "$label: does not exist"
        return 1
    fi
    local owner
    owner=$(stat -c '%U' "$path" 2>/dev/null || stat -f '%Su' "$path" 2>/dev/null)
    if [[ "$owner" == "$expected" ]]; then
        pass "$label owned by: $expected"
    else
        fail "$label owned by: $owner (expected $expected)"
    fi
}

# =========================================================================
section "=== SYSTEM HARDENING (Guide Part 1) ==="
# =========================================================================

# --- 1.2 Hostname ---
HOSTNAME=$(hostnamectl --static 2>/dev/null || hostname)
if [[ "$HOSTNAME" != "localhost" && "$HOSTNAME" != "orin" && "$HOSTNAME" != "ubuntu" && -n "$HOSTNAME" ]]; then
    pass "Hostname set: $HOSTNAME"
else
    warn "Hostname may be default: $HOSTNAME"
fi

# --- 1.3 Base packages ---
for pkg in curl git vim htop tmux ufw fail2ban; do
    if command -v "$pkg" &>/dev/null || dpkg -s "$pkg" &>/dev/null 2>&1; then
        pass "Package installed: $pkg"
    else
        fail "Package missing: $pkg"
    fi
done

# --- 1.6 SSH hardening ---
# Check both hardening.conf drop-in and main sshd_config
SSH_CONF=""
if [[ -f /etc/ssh/sshd_config.d/hardening.conf ]]; then
    SSH_CONF="/etc/ssh/sshd_config.d/hardening.conf"
    pass "SSH hardening drop-in config exists"
elif [[ -f /etc/ssh/sshd_config ]]; then
    SSH_CONF="/etc/ssh/sshd_config"
    warn "No SSH hardening drop-in; checking main sshd_config"
else
    fail "No SSH config found"
fi

if [[ -n "$SSH_CONF" ]]; then
    # PasswordAuthentication no
    if grep -qE "^PasswordAuthentication\s+no" "$SSH_CONF" 2>/dev/null; then
        pass "SSH: PasswordAuthentication no"
    else
        fail "SSH: PasswordAuthentication not disabled"
    fi

    # PermitRootLogin no
    if grep -qE "^PermitRootLogin\s+no" "$SSH_CONF" 2>/dev/null; then
        pass "SSH: PermitRootLogin no"
    else
        fail "SSH: PermitRootLogin not disabled"
    fi

    # PubkeyAuthentication yes
    if grep -qE "^PubkeyAuthentication\s+yes" "$SSH_CONF" 2>/dev/null; then
        pass "SSH: PubkeyAuthentication yes"
    else
        fail "SSH: PubkeyAuthentication not enabled"
    fi

    # PermitEmptyPasswords no
    if grep -qE "^PermitEmptyPasswords\s+no" "$SSH_CONF" 2>/dev/null; then
        pass "SSH: PermitEmptyPasswords no"
    else
        warn "SSH: PermitEmptyPasswords not explicitly set to no"
    fi

    # X11Forwarding no
    if grep -qE "^X11Forwarding\s+no" "$SSH_CONF" 2>/dev/null; then
        pass "SSH: X11Forwarding no"
    else
        warn "SSH: X11Forwarding not explicitly disabled"
    fi

    # MaxAuthTries 3
    if grep -qE "^MaxAuthTries\s+[1-3]$" "$SSH_CONF" 2>/dev/null; then
        pass "SSH: MaxAuthTries <= 3"
    else
        warn "SSH: MaxAuthTries not set to 3 or lower"
    fi

    # ClientAliveInterval
    if grep -qE "^ClientAliveInterval\s+[0-9]+" "$SSH_CONF" 2>/dev/null; then
        pass "SSH: ClientAliveInterval configured"
    else
        warn "SSH: ClientAliveInterval not set"
    fi

    # AllowUsers (optional but recommended)
    if grep -qE "^AllowUsers" "$SSH_CONF" 2>/dev/null; then
        ALLOWED=$(grep "^AllowUsers" "$SSH_CONF" | awk '{$1=""; print $0}' | xargs)
        pass "SSH: AllowUsers restricted to: $ALLOWED"
    else
        warn "SSH: No AllowUsers restriction"
    fi
fi

# --- 1.7 UFW Firewall ---
if command -v ufw &>/dev/null; then
    if sudo ufw status 2>/dev/null | grep -q "Status: active"; then
        pass "UFW firewall active"

        if sudo ufw status 2>/dev/null | grep -q "deny (incoming)"; then
            pass "UFW: default incoming deny"
        else
            fail "UFW: default incoming not set to deny"
        fi

        if sudo ufw status 2>/dev/null | grep -q "allow (outgoing)"; then
            pass "UFW: default outgoing allow"
        else
            warn "UFW: default outgoing not set to allow"
        fi

        if sudo ufw status 2>/dev/null | grep -q "127.0.0.1"; then
            pass "UFW: localhost allowed"
        else
            warn "UFW: no explicit localhost rule"
        fi

        # Check for Tailscale-only SSH (should NOT have LAN rules)
        if sudo ufw status 2>/dev/null | grep -q "100.64.0.0/10"; then
            pass "UFW: Tailscale SSH rule present (100.64.0.0/10)"
        else
            warn "UFW: no Tailscale SSH rule"
        fi

        if sudo ufw status 2>/dev/null | grep -qE "192\.168\.|10\.0\.0\." | grep -q "22"; then
            warn "UFW: LAN SSH rules still present (should be Tailscale-only)"
        fi
    else
        fail "UFW not active"
    fi
else
    fail "UFW not installed"
fi

# --- 1.9 Fail2ban ---
if systemctl is-active --quiet fail2ban 2>/dev/null; then
    pass "Fail2ban running"
    if [[ -f /etc/fail2ban/jail.local ]]; then
        pass "Fail2ban jail.local configured"
        if grep -qE "bantime\s*=\s*24h" /etc/fail2ban/jail.local 2>/dev/null; then
            pass "Fail2ban: SSH bantime 24h"
        else
            warn "Fail2ban: SSH bantime not set to 24h"
        fi
    else
        warn "Fail2ban: no custom jail.local (using defaults)"
    fi
else
    fail "Fail2ban not running"
fi

# --- 1.10 Automatic updates ---
if systemctl is-active --quiet unattended-upgrades 2>/dev/null; then
    pass "Unattended upgrades active"
else
    warn "Unattended upgrades not active"
fi

# --- 1.11 Unnecessary services disabled ---
for svc in avahi-daemon cups bluetooth ModemManager rpcbind; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        warn "Unnecessary service still running: $svc"
    else
        pass "Service disabled: $svc"
    fi
done

# --- 1.12 DNS hardening ---
if [[ -f /etc/systemd/resolved.conf ]]; then
    if grep -q "9.9.9.9" /etc/systemd/resolved.conf 2>/dev/null; then
        pass "DNS: Quad9 configured"
    else
        fail "DNS: Quad9 not configured"
    fi

    if grep -qE "^DNSOverTLS=yes" /etc/systemd/resolved.conf 2>/dev/null; then
        pass "DNS: DNS-over-TLS enabled"
    else
        fail "DNS: DNS-over-TLS not enabled"
    fi

    if grep -qE "^DNSSEC=yes" /etc/systemd/resolved.conf 2>/dev/null; then
        pass "DNS: DNSSEC enabled"
    else
        warn "DNS: DNSSEC not enabled"
    fi

    if grep -qE "^FallbackDNS=$" /etc/systemd/resolved.conf 2>/dev/null; then
        pass "DNS: fallback DNS disabled (no plaintext fallback)"
    else
        warn "DNS: fallback DNS not explicitly disabled"
    fi
else
    fail "DNS: /etc/systemd/resolved.conf not found"
fi

# =========================================================================
section "=== TAILSCALE (Guide Part 1.8) ==="
# =========================================================================

if command -v tailscale &>/dev/null; then
    pass "Tailscale installed"

    if tailscale status &>/dev/null; then
        TS_IP=$(tailscale ip -4 2>/dev/null || echo "unknown")
        pass "Tailscale connected (IP: $TS_IP)"

        # Check Tailscale SSH
        if tailscale status --json 2>/dev/null | grep -q '"SSH": true' 2>/dev/null; then
            pass "Tailscale SSH enabled"
        else
            warn "Tailscale SSH may not be enabled"
        fi
    else
        warn "Tailscale installed but not connected"
    fi

    # Check Tailscale Serve
    if tailscale serve status 2>/dev/null | grep -q "proxy" 2>/dev/null; then
        pass "Tailscale Serve active"
    else
        warn "Tailscale Serve not configured"
    fi

    # Check operator
    TS_OPERATOR=$(tailscale debug prefs 2>/dev/null | grep -o '"OperatorUser":"[^"]*"' | cut -d'"' -f4)
    if [[ -n "$TS_OPERATOR" ]]; then
        pass "Tailscale operator set: $TS_OPERATOR"
    else
        warn "Tailscale operator not set (service user can't manage Serve)"
    fi
else
    warn "Tailscale not installed"
fi

# =========================================================================
section "=== SERVICE USER (Guide Parts 1.4, 5, 6, 7) ==="
# =========================================================================

# Auto-detect service users
DETECTED_USERS=$(systemctl list-unit-files 'openclaw-*.service' --no-legend 2>/dev/null | awk '{print $1}' | sed 's/openclaw-//;s/\.service//')

if [[ -z "$DETECTED_USERS" ]]; then
    DETECTED_USERS=$(find /var/lib -maxdepth 2 -name ".openclaw" -type d 2>/dev/null | sed 's|/var/lib/||;s|/.openclaw||')
fi

if [[ -z "$DETECTED_USERS" ]]; then
    warn "No OpenClaw service users detected"
else
    for SVC_USER in $DETECTED_USERS; do
        echo -e "  ${BLUE}--- Checking user: $SVC_USER ---${NC}"
        HOME_DIR="/var/lib/$SVC_USER"

        # User exists
        if ! id "$SVC_USER" &>/dev/null; then
            fail "User missing: $SVC_USER"
            continue
        fi
        pass "User exists: $SVC_USER"

        # System user (UID < 1000)
        USER_UID=$(id -u "$SVC_USER" 2>/dev/null)
        if [[ "$USER_UID" -lt 1000 ]]; then
            pass "System user (UID: $USER_UID)"
        else
            warn "Not a system user (UID: $USER_UID, expected < 1000)"
        fi

        # Shell = /bin/bash
        USER_SHELL=$(getent passwd "$SVC_USER" | cut -d: -f7)
        if [[ "$USER_SHELL" == "/bin/bash" ]]; then
            pass "Shell: /bin/bash"
        else
            fail "Shell: $USER_SHELL (should be /bin/bash)"
        fi

        # Password locked
        if sudo passwd -S "$SVC_USER" 2>/dev/null | grep -q "L"; then
            pass "Password locked"
        else
            warn "Password may not be locked"
        fi

        # Home directory
        if [[ -d "$HOME_DIR" ]]; then
            pass "Home directory exists: $HOME_DIR"
            check_perms "$HOME_DIR" "700" "Home dir"
            check_owner "$HOME_DIR" "$SVC_USER" "Home dir"
        else
            fail "Home directory missing: $HOME_DIR"
        fi

        # Required subdirectories
        for subdir in .openclaw .secrets workspace logs; do
            local_path="$HOME_DIR/$subdir"
            if [[ -d "$local_path" ]]; then
                pass "Directory exists: ~/$subdir"
            else
                if [[ "$subdir" == ".openclaw" || "$subdir" == ".secrets" ]]; then
                    fail "Directory missing: ~/$subdir"
                else
                    warn "Directory missing: ~/$subdir"
                fi
            fi
        done

        # .openclaw dir permissions
        if [[ -d "$HOME_DIR/.openclaw" ]]; then
            check_perms "$HOME_DIR/.openclaw" "700" "~/.openclaw"
            check_owner "$HOME_DIR/.openclaw" "$SVC_USER" "~/.openclaw"
        fi

        # .secrets dir permissions
        if [[ -d "$HOME_DIR/.secrets" ]]; then
            check_perms "$HOME_DIR/.secrets" "700" "~/.secrets"
            check_owner "$HOME_DIR/.secrets" "$SVC_USER" "~/.secrets"
        fi

        # --- Sudoers (Part 5) ---
        if [[ -f "/etc/sudoers.d/$SVC_USER" ]]; then
            pass "Sudoers file exists: /etc/sudoers.d/$SVC_USER"

            if sudo visudo -c -f "/etc/sudoers.d/$SVC_USER" &>/dev/null; then
                pass "Sudoers syntax valid"
            else
                fail "Sudoers syntax invalid"
            fi

            # Check for key entries
            for entry in "arsenal-*" "nginx" "journalctl" "tailscale serve"; do
                if grep -q "$entry" "/etc/sudoers.d/$SVC_USER" 2>/dev/null; then
                    pass "Sudoers entry: $entry"
                else
                    warn "Sudoers missing entry for: $entry"
                fi
            done
        else
            warn "No sudoers file for $SVC_USER"
        fi

        # sudo -u works
        if sudo -u "$SVC_USER" whoami &>/dev/null; then
            pass "sudo -u $SVC_USER works (no freeze)"
        else
            fail "sudo -u $SVC_USER fails"
        fi

        # --- Git identity (Part 6.4) ---
        GIT_NAME=$(sudo -u "$SVC_USER" git config --global user.name 2>/dev/null)
        if [[ -n "$GIT_NAME" ]]; then
            pass "Git user.name: $GIT_NAME"
        else
            warn "Git user.name not configured for $SVC_USER"
        fi

        GIT_EMAIL=$(sudo -u "$SVC_USER" git config --global user.email 2>/dev/null)
        if [[ -n "$GIT_EMAIL" ]]; then
            pass "Git user.email: $GIT_EMAIL"
        else
            warn "Git user.email not configured for $SVC_USER"
        fi

        # --- GitHub token (Part 6.5) ---
        if [[ -f "$HOME_DIR/.secrets/github" ]]; then
            pass "GitHub token exists: ~/.secrets/github"
            check_perms "$HOME_DIR/.secrets/github" "600" "GitHub token"
            check_owner "$HOME_DIR/.secrets/github" "$SVC_USER" "GitHub token"
        else
            warn "GitHub token not found: ~/.secrets/github"
        fi

        # --- PostgreSQL credentials (Part 7.2) ---
        if [[ -f "$HOME_DIR/.secrets/postgres" ]]; then
            pass "PostgreSQL creds exist: ~/.secrets/postgres"
            check_perms "$HOME_DIR/.secrets/postgres" "600" "PostgreSQL creds"
            check_owner "$HOME_DIR/.secrets/postgres" "$SVC_USER" "PostgreSQL creds"
        else
            warn "PostgreSQL creds not found: ~/.secrets/postgres"
        fi

        # --- Gateway token (Part 4) ---
        if [[ -f "$HOME_DIR/.secrets/gateway-token" ]]; then
            pass "Gateway token exists: ~/.secrets/gateway-token"
            check_perms "$HOME_DIR/.secrets/gateway-token" "600" "Gateway token"
        else
            warn "Gateway token not found: ~/.secrets/gateway-token"
        fi

        # --- File ownership audit ---
        BAD_OWNER=$(find "$HOME_DIR" -not -user "$SVC_USER" 2>/dev/null | head -5)
        if [[ -z "$BAD_OWNER" ]]; then
            pass "File ownership: all files owned by $SVC_USER"
        else
            fail "Files NOT owned by $SVC_USER:"
            echo "$BAD_OWNER" | while read -r f; do
                f_owner=$(stat -c '%U' "$f" 2>/dev/null || stat -f '%Su' "$f" 2>/dev/null)
                echo "         $f (owned by $f_owner)"
            done
        fi

        echo ""
    done
fi

# Check for accidental .openclaw in admin homes
for home in /home/*/; do
    user=$(basename "$home")
    if [[ -d "$home/.openclaw" ]]; then
        fail "Accidental .openclaw in /home/$user/ — should be removed"
    fi
done

# =========================================================================
section "=== DEPENDENCIES (Guide Parts 2-3) ==="
# =========================================================================

# --- Node.js ---
if command -v node &>/dev/null; then
    NODE_VER=$(node --version 2>/dev/null)
    if [[ "$NODE_VER" == v22* || "$NODE_VER" == v24* ]]; then
        pass "Node.js: $NODE_VER"
    else
        warn "Node.js: $NODE_VER (expected v22.x or v24.x)"
    fi
else
    fail "Node.js not installed"
fi

# --- Docker ---
if command -v docker &>/dev/null; then
    pass "Docker installed"

    if systemctl is-active --quiet docker 2>/dev/null; then
        pass "Docker running"
    else
        warn "Docker not running"
    fi

    # daemon.json security
    if [[ -f /etc/docker/daemon.json ]]; then
        pass "Docker daemon.json exists"

        if grep -q '"no-new-privileges"' /etc/docker/daemon.json 2>/dev/null; then
            pass "Docker: no-new-privileges configured"
        else
            warn "Docker: no-new-privileges not set in daemon.json"
        fi

        if grep -q '"live-restore"' /etc/docker/daemon.json 2>/dev/null; then
            pass "Docker: live-restore configured"
        else
            warn "Docker: live-restore not set in daemon.json"
        fi
    else
        warn "Docker: no daemon.json (using defaults)"
    fi

    # Users in docker group
    for SVC_USER in $DETECTED_USERS; do
        if id -nG "$SVC_USER" 2>/dev/null | grep -qw docker; then
            pass "Docker: $SVC_USER in docker group"
        else
            warn "Docker: $SVC_USER NOT in docker group"
        fi
    done
else
    skip "Docker not installed (optional)"
fi

# --- PostgreSQL ---
if command -v psql &>/dev/null; then
    pass "PostgreSQL installed"

    if systemctl is-active --quiet postgresql 2>/dev/null; then
        pass "PostgreSQL running"
    else
        warn "PostgreSQL not running"
    fi

    # Check for orbitguard database
    if sudo -u postgres psql -lqt 2>/dev/null | cut -d '|' -f 1 | grep -qw orbitguard; then
        pass "PostgreSQL: orbitguard database exists"
    else
        warn "PostgreSQL: orbitguard database not found"
    fi

    # Check for orbitguard user
    if sudo -u postgres psql -c "\\du" 2>/dev/null | grep -qw orbitguard; then
        pass "PostgreSQL: orbitguard user exists"
    else
        warn "PostgreSQL: orbitguard user not found"
    fi
else
    skip "PostgreSQL not installed (optional)"
fi

# --- Nginx ---
if command -v nginx &>/dev/null; then
    pass "Nginx installed"

    if systemctl is-active --quiet nginx 2>/dev/null; then
        pass "Nginx running"
    else
        warn "Nginx not running"
    fi

    # Check service user write access to sites-available
    for SVC_USER in $DETECTED_USERS; do
        if [[ -d /etc/nginx/sites-available ]]; then
            SITES_GROUP=$(stat -c '%G' /etc/nginx/sites-available 2>/dev/null || stat -f '%Sg' /etc/nginx/sites-available 2>/dev/null)
            if [[ "$SITES_GROUP" == "$SVC_USER" ]]; then
                pass "Nginx: sites-available group owned by $SVC_USER"
            else
                warn "Nginx: sites-available group is $SITES_GROUP (expected $SVC_USER)"
            fi
        fi
    done
else
    skip "Nginx not installed (optional)"
fi

# --- Chromium ---
if command -v chromium-browser &>/dev/null || command -v chromium &>/dev/null; then
    CHROMIUM_PATH=$(command -v chromium-browser 2>/dev/null || command -v chromium 2>/dev/null)
    pass "Chromium installed: $CHROMIUM_PATH"
else
    skip "Chromium not installed (optional, needed for browser tools)"
fi

# --- OpenClaw CLI ---
if command -v openclaw &>/dev/null; then
    OC_VER=$(openclaw --version 2>/dev/null || echo "unknown")
    pass "OpenClaw CLI: $OC_VER"
else
    fail "OpenClaw CLI not installed"
fi

# =========================================================================
section "=== EXTERNAL APPS ==="
# =========================================================================

# --- Cloudflare Wrangler ---
if command -v wrangler &>/dev/null; then
    WRANGLER_VER=$(wrangler --version 2>/dev/null | head -1)
    pass "Wrangler installed: $WRANGLER_VER"
else
    skip "Wrangler not installed (optional)"
fi

# --- Google Cloud CLI ---
if command -v gcloud &>/dev/null; then
    GCLOUD_VER=$(gcloud --version 2>/dev/null | head -1)
    pass "Google Cloud CLI installed: $GCLOUD_VER"
else
    skip "Google Cloud CLI not installed (optional)"
fi

# --- GitHub CLI ---
if command -v gh &>/dev/null; then
    GH_VER=$(gh --version 2>/dev/null | head -1)
    pass "GitHub CLI installed: $GH_VER"
else
    skip "GitHub CLI not installed (optional)"
fi

# =========================================================================
section "=== OPENCLAW GATEWAY (Guide Part 4) ==="
# =========================================================================

for SVC_USER in $DETECTED_USERS; do
    SERVICE="openclaw-${SVC_USER}.service"
    SERVICE_FILE="/etc/systemd/system/$SERVICE"
    OPENCLAW_DIR="/var/lib/$SVC_USER/.openclaw"

    echo -e "  ${BLUE}--- Checking gateway: $SVC_USER ---${NC}"

    # --- Systemd service ---
    if [[ -f "$SERVICE_FILE" ]]; then
        pass "Systemd service file exists: $SERVICE"

        # Service content validation
        if grep -qE "^User=$SVC_USER" "$SERVICE_FILE" 2>/dev/null; then
            pass "Service: User=$SVC_USER"
        else
            fail "Service: User= not set to $SVC_USER"
        fi

        if grep -q "openclaw gateway run" "$SERVICE_FILE" 2>/dev/null; then
            pass "Service: ExecStart runs openclaw gateway"
        else
            fail "Service: ExecStart doesn't run openclaw gateway"
        fi

        if grep -qE "^NoNewPrivileges=false" "$SERVICE_FILE" 2>/dev/null; then
            pass "Service: NoNewPrivileges=false (v2 unsandboxed)"
        else
            warn "Service: NoNewPrivileges not set to false (may break sudo)"
        fi

        if grep -q "ProtectSystem" "$SERVICE_FILE" 2>/dev/null; then
            fail "Service: ProtectSystem still set (should be removed for v2)"
        else
            pass "Service: no ProtectSystem (v2 unsandboxed)"
        fi

        if grep -q "PrivateTmp=true" "$SERVICE_FILE" 2>/dev/null; then
            pass "Service: PrivateTmp=true"
        else
            warn "Service: PrivateTmp not set"
        fi

        # Dependency on docker (if docker installed)
        if command -v docker &>/dev/null; then
            if grep -q "docker.service" "$SERVICE_FILE" 2>/dev/null; then
                pass "Service: depends on docker.service"
            else
                warn "Service: no docker.service dependency (docker is installed)"
            fi
        fi

        if grep -q "tailscaled.service" "$SERVICE_FILE" 2>/dev/null; then
            pass "Service: depends on tailscaled.service"
        else
            warn "Service: no tailscaled.service dependency"
        fi
    else
        fail "Systemd service file missing: $SERVICE_FILE"
    fi

    # Service status
    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        pass "Service running"
    else
        warn "Service not running"
    fi

    if systemctl is-enabled --quiet "$SERVICE" 2>/dev/null; then
        pass "Service enabled (auto-start on boot)"
    else
        warn "Service not enabled"
    fi

    # --- Config file ---
    if [[ -f "$OPENCLAW_DIR/openclaw.json" ]]; then
        pass "Config exists: openclaw.json"
        check_perms "$OPENCLAW_DIR/openclaw.json" "600" "openclaw.json"
        check_owner "$OPENCLAW_DIR/openclaw.json" "$SVC_USER" "openclaw.json"

        # Bind address
        if grep -q '"loopback"' "$OPENCLAW_DIR/openclaw.json" 2>/dev/null || \
           grep -q '"127.0.0.1"' "$OPENCLAW_DIR/openclaw.json" 2>/dev/null; then
            pass "Gateway bound to loopback (not exposed)"
        else
            fail "Gateway may be bound to 0.0.0.0 — check config!"
        fi

        # mDNS disabled
        if grep -q '"mdns"' "$OPENCLAW_DIR/openclaw.json" 2>/dev/null; then
            if grep -q '"off"' "$OPENCLAW_DIR/openclaw.json" 2>/dev/null; then
                pass "mDNS discovery disabled"
            else
                warn "mDNS may be enabled (check discovery.mdns.mode)"
            fi
        else
            warn "mDNS config not found in openclaw.json"
        fi

        # Log redaction
        if grep -q '"redactSensitive"' "$OPENCLAW_DIR/openclaw.json" 2>/dev/null; then
            pass "Log redaction configured"
        else
            warn "Log redaction not configured in openclaw.json"
        fi
    else
        fail "Config missing: $OPENCLAW_DIR/openclaw.json"
    fi

    # --- Auth profiles ---
    AUTH_FILE="$OPENCLAW_DIR/agents/main/agent/auth-profiles.json"
    if [[ -f "$AUTH_FILE" ]]; then
        pass "Auth profiles exist: auth-profiles.json"
        check_perms "$AUTH_FILE" "600" "auth-profiles.json"
        check_owner "$AUTH_FILE" "$SVC_USER" "auth-profiles.json"
    else
        warn "Auth profiles missing: $AUTH_FILE"
    fi

    # --- Port listening ---
    PORT=$(grep -o '"port": [0-9]*' "$OPENCLAW_DIR/openclaw.json" 2>/dev/null | grep -o '[0-9]*' || echo "18789")
    if sudo ss -tlnp 2>/dev/null | grep -q ":${PORT} "; then
        pass "Gateway listening on port $PORT"
    else
        warn "Gateway not listening on port $PORT"
    fi

    # --- Workspace ---
    if [[ -d "$OPENCLAW_DIR/workspace" ]]; then
        pass "Workspace directory exists"
        check_owner "$OPENCLAW_DIR/workspace" "$SVC_USER" "Workspace"
    else
        warn "Workspace directory missing"
    fi

    echo ""
done

# =========================================================================
section "=== ARSENAL SERVICES (Guide Part 8) ==="
# =========================================================================

ARSENAL_SERVICES=$(systemctl list-unit-files 'arsenal-*.service' --no-legend 2>/dev/null | awk '{print $1}' | sed 's/\.service//')

if [[ -z "$ARSENAL_SERVICES" ]]; then
    skip "No Arsenal services found"
else
    for svc in $ARSENAL_SERVICES; do
        if systemctl is-active --quiet "${svc}.service" 2>/dev/null; then
            pass "Arsenal service running: $svc"
        else
            warn "Arsenal service not running: $svc"
        fi
    done

    # Check nginx configs for Arsenal
    if [[ -d /etc/nginx/sites-available ]]; then
        ARSENAL_CONFIGS=$(ls /etc/nginx/sites-available/arsenal* 2>/dev/null)
        if [[ -n "$ARSENAL_CONFIGS" ]]; then
            pass "Nginx Arsenal configs found"
        else
            warn "No Nginx Arsenal configs in sites-available"
        fi
    fi
fi

# =========================================================================
section "=== NETWORK ==="
# =========================================================================

echo -e "  ${BLUE}Listening ports:${NC}"
sudo ss -tlnp 2>/dev/null | grep LISTEN | while read -r line; do
    port=$(echo "$line" | awk '{print $4}' | rev | cut -d: -f1 | rev)
    proc=$(echo "$line" | grep -o 'users:(("[^"]*"' | cut -d'"' -f2)
    addr=$(echo "$line" | awk '{print $4}' | rev | cut -d: -f2- | rev)
    if [[ "$addr" == "127.0.0.1" || "$addr" == "::1" || "$addr" == "" ]]; then
        pass "Port $port ($proc) — loopback only"
    elif [[ "$addr" == "0.0.0.0" || "$addr" == "*" || "$addr" == "::" ]]; then
        warn "Port $port ($proc) — exposed on all interfaces"
    else
        pass "Port $port ($proc) — $addr"
    fi
done

# =========================================================================
section "=== SUMMARY ==="
# =========================================================================

TOTAL=$((PASS + FAIL + WARN + SKIP))

echo ""
echo -e "  ${GREEN}PASS: $PASS${NC}    ${RED}FAIL: $FAIL${NC}    ${YELLOW}WARN: $WARN${NC}    ${CYAN}SKIP: $SKIP${NC}    Total: $TOTAL"
echo ""

if [[ $FAIL -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}All critical checks passed.${NC}"
else
    echo -e "  ${RED}${BOLD}$FAIL critical issue(s) found. Review FAIL items above.${NC}"
fi

if [[ $WARN -gt 0 ]]; then
    echo -e "  ${YELLOW}$WARN warning(s) — review recommended but not blocking.${NC}"
fi

echo ""
