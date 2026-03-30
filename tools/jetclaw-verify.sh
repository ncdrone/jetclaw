#!/usr/bin/env bash
#
# jetclaw-verify.sh — Comprehensive verification of hardening + OpenClaw installation
#
# Run ON the target machine. Shows pass/fail for every install step and
# a per-section dashboard (COMPLETE / PARTIAL / MISSING / NOT INSTALLED).
#
set -uo pipefail

# Colors
if [[ -t 0 ]]; then
    RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m'
    BLUE='\033[0;34m' CYAN='\033[0;36m' BOLD='\033[1m' NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' NC=''
fi

# Global counters
PASS=0; FAIL=0; WARN=0; SKIP=0

# Per-section counters
SEC_PASS=0; SEC_FAIL=0; SEC_WARN=0; SEC_SKIP=0

# Section dashboard (built up as we go)
declare -a DASHBOARD_NAMES=()
declare -a DASHBOARD_STATUS=()
declare -a DASHBOARD_DETAIL=()

pass() { echo -e "  ${GREEN}PASS${NC}  $*"; ((PASS++)); ((SEC_PASS++)); }
fail() { echo -e "  ${RED}FAIL${NC}  $*"; ((FAIL++)); ((SEC_FAIL++)); }
warn() { echo -e "  ${YELLOW}WARN${NC}  $*"; ((WARN++)); ((SEC_WARN++)); }
skip() { echo -e "  ${CYAN}SKIP${NC}  $*"; ((SKIP++)); ((SEC_SKIP++)); }

# Start a new section — resets per-section counters
begin_section() {
    SEC_PASS=0; SEC_FAIL=0; SEC_WARN=0; SEC_SKIP=0
    echo -e "\n${BOLD}$*${NC}\n"
}

# End a section — compute status and add to dashboard
end_section() {
    local name="$1"
    local total=$((SEC_PASS + SEC_FAIL + SEC_WARN + SEC_SKIP))
    local status detail

    if [[ $total -eq 0 ]]; then
        status="${CYAN}NOT CHECKED${NC}"
        detail="no checks ran"
    elif [[ $SEC_FAIL -eq 0 && $SEC_WARN -eq 0 && $SEC_SKIP -eq 0 ]]; then
        status="${GREEN}COMPLETE${NC}"
        detail="${SEC_PASS}/${total} passed"
    elif [[ $SEC_PASS -eq 0 && $SEC_FAIL -eq 0 && $SEC_WARN -eq 0 ]]; then
        status="${CYAN}NOT INSTALLED${NC}"
        detail="all skipped"
    elif [[ $SEC_PASS -eq 0 && $SEC_SKIP -eq $total ]]; then
        status="${CYAN}NOT INSTALLED${NC}"
        detail="optional, not present"
    elif [[ $SEC_PASS -eq 0 ]]; then
        status="${RED}MISSING${NC}"
        detail="${SEC_FAIL} failed, ${SEC_WARN} warnings"
    else
        status="${YELLOW}PARTIAL${NC}"
        local parts=()
        [[ $SEC_PASS -gt 0 ]] && parts+=("${SEC_PASS} ok")
        [[ $SEC_FAIL -gt 0 ]] && parts+=("${SEC_FAIL} failed")
        [[ $SEC_WARN -gt 0 ]] && parts+=("${SEC_WARN} warn")
        [[ $SEC_SKIP -gt 0 ]] && parts+=("${SEC_SKIP} skip")
        detail=$(IFS=', '; echo "${parts[*]}")
    fi

    DASHBOARD_NAMES+=("$name")
    DASHBOARD_STATUS+=("$status")
    DASHBOARD_DETAIL+=("$detail")
}

# Helpers
check_perms() {
    local path="$1" expected="$2" label="${3:-$1}"
    if [[ ! -e "$path" ]]; then fail "$label: does not exist"; return 1; fi
    local perms
    perms=$(stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path" 2>/dev/null)
    if [[ "$perms" == "$expected" ]]; then pass "$label permissions: $perms"
    else fail "$label permissions: $perms (expected $expected)"; fi
}

check_owner() {
    local path="$1" expected="$2" label="${3:-$1}"
    if [[ ! -e "$path" ]]; then fail "$label: does not exist"; return 1; fi
    local owner
    owner=$(stat -c '%U' "$path" 2>/dev/null || stat -f '%Su' "$path" 2>/dev/null)
    if [[ "$owner" == "$expected" ]]; then pass "$label owned by: $expected"
    else fail "$label owned by: $owner (expected $expected)"; fi
}


# =========================================================================
begin_section "=== SYSTEM HARDENING ==="
# =========================================================================

# Hostname
HOSTNAME=$(hostnamectl --static 2>/dev/null || hostname)
if [[ "$HOSTNAME" != "localhost" && "$HOSTNAME" != "orin" && "$HOSTNAME" != "ubuntu" && -n "$HOSTNAME" ]]; then
    pass "Hostname set: $HOSTNAME"
else
    warn "Hostname may be default: $HOSTNAME"
fi

# Base packages
for pkg in curl git vim htop tmux ufw fail2ban; do
    if command -v "$pkg" &>/dev/null || dpkg -s "$pkg" &>/dev/null 2>&1; then
        pass "Package installed: $pkg"
    else
        fail "Package missing: $pkg"
    fi
done

# SSH hardening
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
    grep -qE "^PasswordAuthentication\s+no" "$SSH_CONF" 2>/dev/null && pass "SSH: PasswordAuthentication no" || fail "SSH: PasswordAuthentication not disabled"
    grep -qE "^PermitRootLogin\s+no" "$SSH_CONF" 2>/dev/null && pass "SSH: PermitRootLogin no" || fail "SSH: PermitRootLogin not disabled"
    grep -qE "^PubkeyAuthentication\s+yes" "$SSH_CONF" 2>/dev/null && pass "SSH: PubkeyAuthentication yes" || fail "SSH: PubkeyAuthentication not enabled"
    grep -qE "^PermitEmptyPasswords\s+no" "$SSH_CONF" 2>/dev/null && pass "SSH: PermitEmptyPasswords no" || warn "SSH: PermitEmptyPasswords not explicitly no"
    grep -qE "^X11Forwarding\s+no" "$SSH_CONF" 2>/dev/null && pass "SSH: X11Forwarding no" || warn "SSH: X11Forwarding not disabled"
    grep -qE "^MaxAuthTries\s+[1-3]$" "$SSH_CONF" 2>/dev/null && pass "SSH: MaxAuthTries <= 3" || warn "SSH: MaxAuthTries not set to 3 or lower"
    grep -qE "^ClientAliveInterval\s+[0-9]+" "$SSH_CONF" 2>/dev/null && pass "SSH: ClientAliveInterval configured" || warn "SSH: ClientAliveInterval not set"

    if grep -qE "^AllowUsers" "$SSH_CONF" 2>/dev/null; then
        ALLOWED=$(grep "^AllowUsers" "$SSH_CONF" | awk '{$1=""; print $0}' | xargs)
        pass "SSH: AllowUsers restricted to: $ALLOWED"
    else
        warn "SSH: No AllowUsers restriction"
    fi
fi

# UFW
if command -v ufw &>/dev/null; then
    if sudo ufw status 2>/dev/null | grep -q "Status: active"; then
        pass "UFW firewall active"
        sudo ufw status 2>/dev/null | grep -q "deny (incoming)" && pass "UFW: default incoming deny" || fail "UFW: default incoming not deny"
        sudo ufw status 2>/dev/null | grep -q "allow (outgoing)" && pass "UFW: default outgoing allow" || warn "UFW: default outgoing not allow"
        sudo ufw status 2>/dev/null | grep -q "127.0.0.1" && pass "UFW: localhost allowed" || warn "UFW: no explicit localhost rule"
        sudo ufw status 2>/dev/null | grep -q "100.64.0.0/10" && pass "UFW: Tailscale SSH rule present" || warn "UFW: no Tailscale SSH rule"
    else
        fail "UFW not active"
    fi
else
    fail "UFW not installed"
fi

# Fail2ban
if systemctl is-active --quiet fail2ban 2>/dev/null; then
    pass "Fail2ban running"
    if [[ -f /etc/fail2ban/jail.local ]]; then
        pass "Fail2ban jail.local configured"
        grep -qE "bantime\s*=\s*24h" /etc/fail2ban/jail.local 2>/dev/null && pass "Fail2ban: SSH bantime 24h" || warn "Fail2ban: SSH bantime not 24h"
    else
        warn "Fail2ban: no custom jail.local"
    fi
else
    fail "Fail2ban not running"
fi

# Auto updates
systemctl is-active --quiet unattended-upgrades 2>/dev/null && pass "Unattended upgrades active" || warn "Unattended upgrades not active"

# Unnecessary services
for svc in avahi-daemon cups bluetooth ModemManager rpcbind; do
    systemctl is-active --quiet "$svc" 2>/dev/null && warn "Unnecessary service running: $svc" || pass "Service disabled: $svc"
done

# DNS
if [[ -f /etc/systemd/resolved.conf ]]; then
    grep -q "9.9.9.9" /etc/systemd/resolved.conf 2>/dev/null && pass "DNS: Quad9 configured" || fail "DNS: Quad9 not configured"
    grep -qE "^DNSOverTLS=yes" /etc/systemd/resolved.conf 2>/dev/null && pass "DNS: DNS-over-TLS enabled" || fail "DNS: DNS-over-TLS not enabled"
    grep -qE "^FallbackDNS=.+" /etc/systemd/resolved.conf 2>/dev/null && pass "DNS: fallback servers configured" || warn "DNS: no fallback servers (may lose DNS if Quad9 unreachable)"
else
    fail "DNS: /etc/systemd/resolved.conf not found"
fi

end_section "System Hardening"


# =========================================================================
begin_section "=== TAILSCALE ==="
# =========================================================================

if command -v tailscale &>/dev/null; then
    pass "Tailscale installed"

    if tailscale status &>/dev/null; then
        TS_IP=$(tailscale ip -4 2>/dev/null || echo "unknown")
        pass "Tailscale connected (IP: $TS_IP)"
        tailscale status --json 2>/dev/null | grep -q '"SSH": true' 2>/dev/null && pass "Tailscale SSH enabled" || warn "Tailscale SSH may not be enabled"
    else
        warn "Tailscale installed but not connected"
    fi

    tailscale serve status 2>/dev/null | grep -q "proxy" 2>/dev/null && pass "Tailscale Serve active" || warn "Tailscale Serve not configured"

    TS_OPERATOR=$(tailscale debug prefs 2>/dev/null | grep -o '"OperatorUser":"[^"]*"' | cut -d'"' -f4)
    [[ -n "$TS_OPERATOR" ]] && pass "Tailscale operator set: $TS_OPERATOR" || warn "Tailscale operator not set"
else
    skip "Tailscale not installed"
fi

end_section "Tailscale"


# =========================================================================
begin_section "=== SERVICE USER ==="
# =========================================================================

DETECTED_USERS=$(systemctl list-unit-files 'openclaw-*.service' --no-legend 2>/dev/null | awk '{print $1}' | sed 's/openclaw-//;s/\.service//')
[[ -z "$DETECTED_USERS" ]] && DETECTED_USERS=$(find /var/lib -maxdepth 2 -name ".openclaw" -type d 2>/dev/null | sed 's|/var/lib/||;s|/.openclaw||')

if [[ -z "$DETECTED_USERS" ]]; then
    warn "No OpenClaw service users detected"
else
    for SVC_USER in $DETECTED_USERS; do
        echo -e "  ${BLUE}--- Checking user: $SVC_USER ---${NC}"
        HOME_DIR="/var/lib/$SVC_USER"

        if ! id "$SVC_USER" &>/dev/null; then fail "User missing: $SVC_USER"; continue; fi
        pass "User exists: $SVC_USER"

        USER_UID=$(id -u "$SVC_USER" 2>/dev/null)
        [[ "$USER_UID" -lt 1000 ]] && pass "System user (UID: $USER_UID)" || warn "Not a system user (UID: $USER_UID)"

        USER_SHELL=$(getent passwd "$SVC_USER" | cut -d: -f7)
        [[ "$USER_SHELL" == "/bin/bash" ]] && pass "Shell: /bin/bash" || fail "Shell: $USER_SHELL (should be /bin/bash)"

        sudo passwd -S "$SVC_USER" 2>/dev/null | grep -q "L" && pass "Password locked" || warn "Password may not be locked"

        if [[ -d "$HOME_DIR" ]]; then
            pass "Home directory exists: $HOME_DIR"
            check_perms "$HOME_DIR" "700" "Home dir"
            check_owner "$HOME_DIR" "$SVC_USER" "Home dir"
        else
            fail "Home directory missing: $HOME_DIR"
        fi

        for subdir in .openclaw .secrets workspace logs; do
            if [[ -d "$HOME_DIR/$subdir" ]]; then
                pass "Directory exists: ~/$subdir"
            elif [[ "$subdir" == ".openclaw" || "$subdir" == ".secrets" ]]; then
                fail "Directory missing: ~/$subdir"
            else
                warn "Directory missing: ~/$subdir"
            fi
        done

        [[ -d "$HOME_DIR/.openclaw" ]] && { check_perms "$HOME_DIR/.openclaw" "700" "~/.openclaw"; check_owner "$HOME_DIR/.openclaw" "$SVC_USER" "~/.openclaw"; }
        [[ -d "$HOME_DIR/.secrets" ]] && { check_perms "$HOME_DIR/.secrets" "700" "~/.secrets"; check_owner "$HOME_DIR/.secrets" "$SVC_USER" "~/.secrets"; }

        # Sudoers
        if [[ -f "/etc/sudoers.d/$SVC_USER" ]]; then
            pass "Sudoers file exists"
            sudo visudo -c -f "/etc/sudoers.d/$SVC_USER" &>/dev/null && pass "Sudoers syntax valid" || fail "Sudoers syntax invalid"
            for entry in "arsenal-*" "nginx" "journalctl" "tailscale serve"; do
                grep -q "$entry" "/etc/sudoers.d/$SVC_USER" 2>/dev/null && pass "Sudoers entry: $entry" || warn "Sudoers missing: $entry"
            done
        else
            warn "No sudoers file for $SVC_USER"
        fi

        sudo -u "$SVC_USER" whoami &>/dev/null && pass "sudo -u $SVC_USER works" || fail "sudo -u $SVC_USER fails"

        # Git identity
        GIT_NAME=$(sudo -u "$SVC_USER" git config --global user.name 2>/dev/null)
        [[ -n "$GIT_NAME" ]] && pass "Git user.name: $GIT_NAME" || warn "Git user.name not configured"
        GIT_EMAIL=$(sudo -u "$SVC_USER" git config --global user.email 2>/dev/null)
        [[ -n "$GIT_EMAIL" ]] && pass "Git user.email: $GIT_EMAIL" || warn "Git user.email not configured"

        # Secrets
        [[ -f "$HOME_DIR/.secrets/github" ]] && { pass "GitHub token exists"; check_perms "$HOME_DIR/.secrets/github" "600" "GitHub token"; } || warn "GitHub token not found"
        [[ -f "$HOME_DIR/.secrets/postgres" ]] && { pass "PostgreSQL creds exist"; check_perms "$HOME_DIR/.secrets/postgres" "600" "PostgreSQL creds"; } || warn "PostgreSQL creds not found"
        [[ -f "$HOME_DIR/.secrets/gateway-token" ]] && { pass "Gateway token exists"; check_perms "$HOME_DIR/.secrets/gateway-token" "600" "Gateway token"; } || warn "Gateway token not found"

        # Ownership audit
        BAD_OWNER=$(find "$HOME_DIR" -not -user "$SVC_USER" 2>/dev/null | head -5)
        if [[ -z "$BAD_OWNER" ]]; then
            pass "File ownership: all owned by $SVC_USER"
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

# Accidental .openclaw
for home in /home/*/; do
    user=$(basename "$home")
    [[ -d "$home/.openclaw" ]] && fail "Accidental .openclaw in /home/$user/"
done

end_section "Service User"


# =========================================================================
begin_section "=== DEPENDENCIES ==="
# =========================================================================

# Node.js
if command -v node &>/dev/null; then
    NODE_VER=$(node --version 2>/dev/null)
    [[ "$NODE_VER" == v22* || "$NODE_VER" == v24* ]] && pass "Node.js: $NODE_VER" || warn "Node.js: $NODE_VER (expected v22/v24)"
else
    fail "Node.js not installed"
fi

# Docker
if command -v docker &>/dev/null; then
    pass "Docker installed"
    systemctl is-active --quiet docker 2>/dev/null && pass "Docker running" || warn "Docker not running"
    if [[ -f /etc/docker/daemon.json ]]; then
        pass "Docker daemon.json exists"
        grep -q '"no-new-privileges"' /etc/docker/daemon.json 2>/dev/null && pass "Docker: no-new-privileges" || warn "Docker: no-new-privileges not set"
        grep -q '"live-restore"' /etc/docker/daemon.json 2>/dev/null && pass "Docker: live-restore" || warn "Docker: live-restore not set"
    else
        warn "Docker: no daemon.json"
    fi
    for SVC_USER in $DETECTED_USERS; do
        id -nG "$SVC_USER" 2>/dev/null | grep -qw docker && pass "Docker: $SVC_USER in group" || warn "Docker: $SVC_USER NOT in group"
    done
else
    skip "Docker not installed (optional)"
fi

# PostgreSQL
if command -v psql &>/dev/null; then
    pass "PostgreSQL installed"
    systemctl is-active --quiet postgresql 2>/dev/null && pass "PostgreSQL running" || warn "PostgreSQL not running"
    sudo -u postgres psql -lqt 2>/dev/null | cut -d '|' -f 1 | grep -qw orbitguard && pass "PostgreSQL: orbitguard DB exists" || warn "PostgreSQL: orbitguard DB not found"
    sudo -u postgres psql -c "\\du" 2>/dev/null | grep -qw orbitguard && pass "PostgreSQL: orbitguard user exists" || warn "PostgreSQL: orbitguard user not found"
else
    skip "PostgreSQL not installed (optional)"
fi

# Nginx
if command -v nginx &>/dev/null; then
    pass "Nginx installed"
    systemctl is-active --quiet nginx 2>/dev/null && pass "Nginx running" || warn "Nginx not running"
    for SVC_USER in $DETECTED_USERS; do
        if [[ -d /etc/nginx/sites-available ]]; then
            SITES_GROUP=$(stat -c '%G' /etc/nginx/sites-available 2>/dev/null || stat -f '%Sg' /etc/nginx/sites-available 2>/dev/null)
            [[ "$SITES_GROUP" == "$SVC_USER" ]] && pass "Nginx: sites-available group=$SVC_USER" || warn "Nginx: sites-available group=$SITES_GROUP (expected $SVC_USER)"
        fi
    done
else
    skip "Nginx not installed (optional)"
fi

# Chromium
if command -v chromium-browser &>/dev/null || command -v chromium &>/dev/null; then
    pass "Chromium installed"
else
    skip "Chromium not installed (optional)"
fi

# OpenClaw CLI
if command -v openclaw &>/dev/null; then
    OC_VER=$(openclaw --version 2>/dev/null || echo "unknown")
    pass "OpenClaw CLI: $OC_VER"
else
    fail "OpenClaw CLI not installed"
fi

end_section "Dependencies"


# =========================================================================
begin_section "=== EXTERNAL APPS ==="
# =========================================================================

command -v wrangler &>/dev/null && pass "Wrangler: $(wrangler --version 2>/dev/null | head -1)" || skip "Wrangler not installed (optional)"
command -v gcloud &>/dev/null && pass "Google Cloud CLI: $(gcloud --version 2>/dev/null | head -1)" || skip "Google Cloud CLI not installed (optional)"
command -v gh &>/dev/null && pass "GitHub CLI: $(gh --version 2>/dev/null | head -1)" || skip "GitHub CLI not installed (optional)"

end_section "External Apps"


# =========================================================================
begin_section "=== OPENCLAW GATEWAY ==="
# =========================================================================

for SVC_USER in $DETECTED_USERS; do
    SERVICE="openclaw-${SVC_USER}.service"
    SERVICE_FILE="/etc/systemd/system/$SERVICE"
    OPENCLAW_DIR="/var/lib/$SVC_USER/.openclaw"

    echo -e "  ${BLUE}--- Checking gateway: $SVC_USER ---${NC}"

    # Systemd service
    if [[ -f "$SERVICE_FILE" ]]; then
        pass "Service file exists: $SERVICE"
        grep -qE "^User=$SVC_USER" "$SERVICE_FILE" 2>/dev/null && pass "Service: User=$SVC_USER" || fail "Service: User= wrong"
        grep -q "openclaw gateway run" "$SERVICE_FILE" 2>/dev/null && pass "Service: ExecStart correct" || fail "Service: ExecStart wrong"
        grep -qE "^NoNewPrivileges=false" "$SERVICE_FILE" 2>/dev/null && pass "Service: NoNewPrivileges=false (v2)" || warn "Service: NoNewPrivileges not false"
        grep -q "ProtectSystem" "$SERVICE_FILE" 2>/dev/null && fail "Service: ProtectSystem still set (remove for v2)" || pass "Service: no ProtectSystem (v2)"
        grep -q "PrivateTmp=true" "$SERVICE_FILE" 2>/dev/null && pass "Service: PrivateTmp=true" || warn "Service: PrivateTmp not set"
        if command -v docker &>/dev/null; then
            grep -q "docker.service" "$SERVICE_FILE" 2>/dev/null && pass "Service: docker dependency" || warn "Service: no docker dependency"
        fi
        grep -q "tailscaled.service" "$SERVICE_FILE" 2>/dev/null && pass "Service: tailscale dependency" || warn "Service: no tailscale dependency"
    else
        fail "Service file missing: $SERVICE_FILE"
    fi

    systemctl is-active --quiet "$SERVICE" 2>/dev/null && pass "Service running" || warn "Service not running"
    systemctl is-enabled --quiet "$SERVICE" 2>/dev/null && pass "Service enabled (auto-start)" || warn "Service not enabled"

    # Config
    if [[ -f "$OPENCLAW_DIR/openclaw.json" ]]; then
        pass "Config exists: openclaw.json"
        check_perms "$OPENCLAW_DIR/openclaw.json" "600" "openclaw.json"
        check_owner "$OPENCLAW_DIR/openclaw.json" "$SVC_USER" "openclaw.json"

        (grep -q '"loopback"' "$OPENCLAW_DIR/openclaw.json" 2>/dev/null || grep -q '"127.0.0.1"' "$OPENCLAW_DIR/openclaw.json" 2>/dev/null) \
            && pass "Gateway bound to loopback" || fail "Gateway may be on 0.0.0.0!"

        if grep -q '"mdns"' "$OPENCLAW_DIR/openclaw.json" 2>/dev/null; then
            grep -q '"off"' "$OPENCLAW_DIR/openclaw.json" 2>/dev/null && pass "mDNS disabled" || warn "mDNS may be enabled"
        else
            warn "mDNS not configured"
        fi

        grep -q '"redactSensitive"' "$OPENCLAW_DIR/openclaw.json" 2>/dev/null && pass "Log redaction configured" || warn "Log redaction not configured"
    else
        fail "Config missing: $OPENCLAW_DIR/openclaw.json"
    fi

    # Auth profiles
    AUTH_FILE="$OPENCLAW_DIR/agents/main/agent/auth-profiles.json"
    if [[ -f "$AUTH_FILE" ]]; then
        pass "Auth profiles exist"
        check_perms "$AUTH_FILE" "600" "auth-profiles.json"
        check_owner "$AUTH_FILE" "$SVC_USER" "auth-profiles.json"
    else
        warn "Auth profiles missing"
    fi

    # Port
    PORT=$(grep -o '"port": [0-9]*' "$OPENCLAW_DIR/openclaw.json" 2>/dev/null | grep -o '[0-9]*' || echo "18789")
    sudo ss -tlnp 2>/dev/null | grep -q ":${PORT} " && pass "Gateway listening on port $PORT" || warn "Gateway not listening on port $PORT"

    # Workspace
    if [[ -d "$OPENCLAW_DIR/workspace" ]]; then
        pass "Workspace directory exists"
        check_owner "$OPENCLAW_DIR/workspace" "$SVC_USER" "Workspace"
    else
        warn "Workspace directory missing"
    fi

    echo ""
done

end_section "OpenClaw Gateway"


# =========================================================================
begin_section "=== ARSENAL SERVICES ==="
# =========================================================================

ARSENAL_SERVICES=$(systemctl list-unit-files 'arsenal-*.service' --no-legend 2>/dev/null | awk '{print $1}' | sed 's/\.service//')

if [[ -z "$ARSENAL_SERVICES" ]]; then
    skip "No Arsenal services found"
else
    for svc in $ARSENAL_SERVICES; do
        systemctl is-active --quiet "${svc}.service" 2>/dev/null && pass "Running: $svc" || warn "Not running: $svc"
    done
    if [[ -d /etc/nginx/sites-available ]]; then
        ls /etc/nginx/sites-available/arsenal* &>/dev/null && pass "Nginx Arsenal configs found" || warn "No Nginx Arsenal configs"
    fi
fi

end_section "Arsenal Services"


# =========================================================================
begin_section "=== NETWORK ==="
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

end_section "Network"


# =========================================================================
# DASHBOARD
# =========================================================================
echo ""
echo -e "${BOLD}================================================================${NC}"
echo -e "${BOLD}  INSTALLATION STATUS DASHBOARD${NC}"
echo -e "${BOLD}================================================================${NC}"
echo ""

# Print dashboard table
for i in "${!DASHBOARD_NAMES[@]}"; do
    printf "  %-22s %b  %s\n" "${DASHBOARD_NAMES[$i]}" "${DASHBOARD_STATUS[$i]}" "(${DASHBOARD_DETAIL[$i]})"
done

echo ""
echo -e "${BOLD}----------------------------------------------------------------${NC}"

TOTAL=$((PASS + FAIL + WARN + SKIP))
echo ""
echo -e "  ${GREEN}PASS: $PASS${NC}    ${RED}FAIL: $FAIL${NC}    ${YELLOW}WARN: $WARN${NC}    ${CYAN}SKIP: $SKIP${NC}    Total: $TOTAL"
echo ""

if [[ $FAIL -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}All critical checks passed.${NC}"
else
    echo -e "  ${RED}${BOLD}$FAIL critical issue(s) found. Review FAIL items above.${NC}"
fi
[[ $WARN -gt 0 ]] && echo -e "  ${YELLOW}$WARN warning(s) — review recommended but not blocking.${NC}"
echo ""
