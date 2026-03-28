#!/usr/bin/env bash
#
# jetclaw-verify.sh — Verify hardening and OpenClaw installation status
#
# Run ON the target machine. Shows pass/fail for every hardening step.
#
set -uo pipefail

# Colors
if [[ -t 0 ]]; then
    RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m'
    BLUE='\033[0;34m' BOLD='\033[1m' NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
fi

PASS=0
FAIL=0
WARN=0

pass() { echo -e "  ${GREEN}PASS${NC}  $*"; ((PASS++)); }
fail() { echo -e "  ${RED}FAIL${NC}  $*"; ((FAIL++)); }
warn() { echo -e "  ${YELLOW}WARN${NC}  $*"; ((WARN++)); }
section() { echo -e "\n${BOLD}$*${NC}\n"; }

# ---------------------------------------------------------------------------
section "=== SYSTEM HARDENING ==="
# ---------------------------------------------------------------------------

# Hostname
HOSTNAME=$(hostnamectl --static 2>/dev/null || hostname)
if [[ "$HOSTNAME" != "localhost" && "$HOSTNAME" != "orin" && -n "$HOSTNAME" ]]; then
    pass "Hostname set: $HOSTNAME"
else
    warn "Hostname may be default: $HOSTNAME"
fi

# SSH hardening
if [[ -f /etc/ssh/sshd_config.d/hardening.conf ]]; then
    pass "SSH hardening config exists"

    if grep -q "PasswordAuthentication no" /etc/ssh/sshd_config.d/hardening.conf 2>/dev/null; then
        pass "Password auth disabled"
    else
        fail "Password auth still enabled"
    fi

    if grep -q "PermitRootLogin no" /etc/ssh/sshd_config.d/hardening.conf 2>/dev/null; then
        pass "Root login disabled"
    else
        fail "Root login still allowed"
    fi

    if grep -q "PubkeyAuthentication yes" /etc/ssh/sshd_config.d/hardening.conf 2>/dev/null; then
        pass "Pubkey auth enabled"
    else
        fail "Pubkey auth not enabled"
    fi

    if grep -q "AllowUsers" /etc/ssh/sshd_config.d/hardening.conf 2>/dev/null; then
        ALLOWED=$(grep "AllowUsers" /etc/ssh/sshd_config.d/hardening.conf | awk '{print $2}')
        pass "SSH AllowUsers: $ALLOWED"
    else
        warn "No AllowUsers restriction"
    fi
else
    fail "SSH hardening config missing (/etc/ssh/sshd_config.d/hardening.conf)"
fi

# UFW
if command -v ufw &>/dev/null; then
    if sudo ufw status 2>/dev/null | grep -q "Status: active"; then
        pass "UFW firewall active"

        if sudo ufw status 2>/dev/null | grep -q "deny (incoming)"; then
            pass "Default incoming: deny"
        else
            fail "Default incoming not set to deny"
        fi

        if sudo ufw status 2>/dev/null | grep -q "allow (outgoing)"; then
            pass "Default outgoing: allow"
        else
            warn "Default outgoing not set to allow"
        fi

        # Check for Tailscale rule
        if sudo ufw status 2>/dev/null | grep -q "100.64.0.0/10"; then
            pass "Tailscale SSH rule present"
        else
            warn "No Tailscale SSH rule (may be using LAN rules instead)"
        fi

        # Check for localhost
        if sudo ufw status 2>/dev/null | grep -q "127.0.0.1"; then
            pass "Localhost allowed"
        else
            warn "No explicit localhost rule"
        fi
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
    else
        warn "No custom jail.local (using defaults)"
    fi
else
    fail "Fail2ban not running"
fi

# Unattended upgrades
if systemctl is-active --quiet unattended-upgrades 2>/dev/null; then
    pass "Unattended upgrades active"
else
    warn "Unattended upgrades not active"
fi

# DNS
if grep -q "9.9.9.9" /etc/systemd/resolved.conf 2>/dev/null; then
    pass "Quad9 DNS configured"

    if grep -q "DNSOverTLS=yes" /etc/systemd/resolved.conf 2>/dev/null; then
        pass "DNS over TLS enabled"
    else
        fail "DNS over TLS not enabled"
    fi

    if grep -q "DNSSEC=yes" /etc/systemd/resolved.conf 2>/dev/null; then
        pass "DNSSEC enabled"
    else
        warn "DNSSEC not enabled"
    fi

    if grep -q "FallbackDNS=$" /etc/systemd/resolved.conf 2>/dev/null; then
        pass "Fallback DNS disabled (no plaintext fallback)"
    else
        warn "Fallback DNS not explicitly disabled"
    fi
else
    fail "Quad9 DNS not configured"
fi

# Unnecessary services
for svc in avahi-daemon cups bluetooth ModemManager rpcbind; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        warn "Service still running: $svc"
    else
        pass "Service disabled: $svc"
    fi
done

# ---------------------------------------------------------------------------
section "=== TAILSCALE ==="
# ---------------------------------------------------------------------------

if command -v tailscale &>/dev/null; then
    pass "Tailscale installed"
    if tailscale status &>/dev/null; then
        TS_IP=$(tailscale ip -4 2>/dev/null || echo "unknown")
        pass "Tailscale connected (IP: $TS_IP)"
    else
        warn "Tailscale installed but not connected"
    fi
else
    warn "Tailscale not installed"
fi

# ---------------------------------------------------------------------------
section "=== SERVICE USER ==="
# ---------------------------------------------------------------------------

# Auto-detect service users (look for openclaw-* services)
DETECTED_USERS=$(systemctl list-unit-files 'openclaw-*.service' --no-legend 2>/dev/null | awk '{print $1}' | sed 's/openclaw-//;s/\.service//')

if [[ -z "$DETECTED_USERS" ]]; then
    # Try to find users from /var/lib with .openclaw directories
    DETECTED_USERS=$(find /var/lib -maxdepth 2 -name ".openclaw" -type d 2>/dev/null | sed 's|/var/lib/||;s|/.openclaw||')
fi

if [[ -z "$DETECTED_USERS" ]]; then
    warn "No OpenClaw service users detected"
else
    for SVC_USER in $DETECTED_USERS; do
        echo -e "  ${BLUE}Checking user: $SVC_USER${NC}"

        if id "$SVC_USER" &>/dev/null; then
            pass "User exists: $SVC_USER"
        else
            fail "User missing: $SVC_USER"
            continue
        fi

        # Shell
        SHELL=$(getent passwd "$SVC_USER" | cut -d: -f7)
        if [[ "$SHELL" == "/bin/bash" ]]; then
            pass "Shell: /bin/bash"
        else
            fail "Shell: $SHELL (should be /bin/bash)"
        fi

        # Password locked
        if sudo passwd -S "$SVC_USER" 2>/dev/null | grep -q "L"; then
            pass "Password locked"
        else
            warn "Password may not be locked"
        fi

        # Home directory
        HOME_DIR="/var/lib/$SVC_USER"
        if [[ -d "$HOME_DIR" ]]; then
            pass "Home directory exists: $HOME_DIR"

            PERMS=$(stat -c '%a' "$HOME_DIR" 2>/dev/null || stat -f '%Lp' "$HOME_DIR" 2>/dev/null)
            if [[ "$PERMS" == "700" ]]; then
                pass "Home permissions: 700"
            else
                fail "Home permissions: $PERMS (should be 700)"
            fi

            OWNER=$(stat -c '%U' "$HOME_DIR" 2>/dev/null || stat -f '%Su' "$HOME_DIR" 2>/dev/null)
            if [[ "$OWNER" == "$SVC_USER" ]]; then
                pass "Home owned by: $SVC_USER"
            else
                fail "Home owned by: $OWNER (should be $SVC_USER)"
            fi
        else
            fail "Home directory missing: $HOME_DIR"
        fi

        # Sudoers
        if [[ -f "/etc/sudoers.d/$SVC_USER" ]]; then
            pass "Sudoers file exists"
            if sudo visudo -c -f "/etc/sudoers.d/$SVC_USER" &>/dev/null; then
                pass "Sudoers syntax valid"
            else
                fail "Sudoers syntax invalid"
            fi
        else
            warn "No sudoers file for $SVC_USER"
        fi

        # sudo -u works
        if sudo -u "$SVC_USER" whoami &>/dev/null; then
            pass "sudo -u $SVC_USER works"
        else
            fail "sudo -u $SVC_USER fails"
        fi

        echo ""
    done
fi

# ---------------------------------------------------------------------------
section "=== DEPENDENCIES ==="
# ---------------------------------------------------------------------------

# Node.js
if command -v node &>/dev/null; then
    NODE_VER=$(node --version 2>/dev/null)
    if [[ "$NODE_VER" == v22* ]]; then
        pass "Node.js: $NODE_VER"
    else
        warn "Node.js: $NODE_VER (expected v22.x)"
    fi
else
    fail "Node.js not installed"
fi

# Docker
if command -v docker &>/dev/null; then
    pass "Docker installed"
    if systemctl is-active --quiet docker 2>/dev/null; then
        pass "Docker running"
    else
        warn "Docker not running"
    fi
else
    warn "Docker not installed (optional)"
fi

# Nginx
if command -v nginx &>/dev/null; then
    pass "Nginx installed"
    if systemctl is-active --quiet nginx 2>/dev/null; then
        pass "Nginx running"
    else
        warn "Nginx not running"
    fi
else
    warn "Nginx not installed (optional)"
fi

# PostgreSQL
if command -v psql &>/dev/null; then
    pass "PostgreSQL installed"
    if systemctl is-active --quiet postgresql 2>/dev/null; then
        pass "PostgreSQL running"
    else
        warn "PostgreSQL not running"
    fi
else
    warn "PostgreSQL not installed (optional)"
fi

# Chromium
if command -v chromium-browser &>/dev/null || command -v chromium &>/dev/null; then
    pass "Chromium installed"
else
    warn "Chromium not installed (optional, needed for browser tools)"
fi

# OpenClaw
if command -v openclaw &>/dev/null; then
    OC_VER=$(openclaw --version 2>/dev/null || echo "unknown")
    pass "OpenClaw CLI: $OC_VER"
else
    fail "OpenClaw not installed"
fi

# ---------------------------------------------------------------------------
section "=== OPENCLAW GATEWAY ==="
# ---------------------------------------------------------------------------

for SVC_USER in $DETECTED_USERS; do
    SERVICE="openclaw-${SVC_USER}.service"
    OPENCLAW_DIR="/var/lib/$SVC_USER/.openclaw"

    echo -e "  ${BLUE}Checking gateway: $SVC_USER${NC}"

    # Service exists
    if systemctl list-unit-files "$SERVICE" --no-legend 2>/dev/null | grep -q "$SERVICE"; then
        pass "Systemd service exists: $SERVICE"
    else
        fail "Systemd service missing: $SERVICE"
        continue
    fi

    # Service running
    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        pass "Service running"
    else
        warn "Service not running"
    fi

    # Config exists
    if [[ -f "$OPENCLAW_DIR/openclaw.json" ]]; then
        pass "Config exists: openclaw.json"

        PERMS=$(stat -c '%a' "$OPENCLAW_DIR/openclaw.json" 2>/dev/null || stat -f '%Lp' "$OPENCLAW_DIR/openclaw.json" 2>/dev/null)
        if [[ "$PERMS" == "600" ]]; then
            pass "Config permissions: 600"
        else
            warn "Config permissions: $PERMS (should be 600)"
        fi
    else
        fail "Config missing: $OPENCLAW_DIR/openclaw.json"
    fi

    # Port listening
    PORT=$(grep -o '"port": [0-9]*' "$OPENCLAW_DIR/openclaw.json" 2>/dev/null | grep -o '[0-9]*' || echo "18789")
    if sudo ss -tlnp 2>/dev/null | grep -q ":${PORT} "; then
        pass "Gateway listening on port $PORT"
    else
        warn "Gateway not listening on port $PORT"
    fi

    # Bind address
    if grep -q '"loopback"' "$OPENCLAW_DIR/openclaw.json" 2>/dev/null || grep -q '"127.0.0.1"' "$OPENCLAW_DIR/openclaw.json" 2>/dev/null; then
        pass "Gateway bound to loopback (not exposed)"
    else
        fail "Gateway may be bound to 0.0.0.0 (check config!)"
    fi

    # mDNS disabled
    if grep -q '"mdns"' "$OPENCLAW_DIR/openclaw.json" 2>/dev/null && grep -q '"off"' "$OPENCLAW_DIR/openclaw.json" 2>/dev/null; then
        pass "mDNS discovery disabled"
    else
        warn "mDNS may be enabled (check discovery.mdns.mode)"
    fi

    # Workspace
    if [[ -d "$OPENCLAW_DIR/workspace" ]]; then
        pass "Workspace directory exists"
    else
        warn "Workspace directory missing"
    fi

    # Secrets
    if [[ -d "/var/lib/$SVC_USER/.secrets" ]]; then
        pass "Secrets directory exists"
        SECRETS_PERMS=$(stat -c '%a' "/var/lib/$SVC_USER/.secrets" 2>/dev/null || stat -f '%Lp' "/var/lib/$SVC_USER/.secrets" 2>/dev/null)
        if [[ "$SECRETS_PERMS" == "700" ]]; then
            pass "Secrets permissions: 700"
        else
            warn "Secrets permissions: $SECRETS_PERMS (should be 700)"
        fi
    else
        warn "Secrets directory missing"
    fi

    # Check for bad ownership
    BAD_OWNER=$(find "/var/lib/$SVC_USER" -not -user "$SVC_USER" 2>/dev/null | head -3)
    if [[ -z "$BAD_OWNER" ]]; then
        pass "File ownership: all owned by $SVC_USER"
    else
        fail "Files not owned by $SVC_USER:"
        echo "$BAD_OWNER" | while read -r f; do echo "         $f"; done
    fi

    echo ""
done

# Check for accidental .openclaw in admin homes
for home in /home/*/; do
    user=$(basename "$home")
    if [[ -d "$home/.openclaw" ]]; then
        fail "Accidental .openclaw in /home/$user/ -- should be removed"
    fi
done

# ---------------------------------------------------------------------------
section "=== NETWORK ==="
# ---------------------------------------------------------------------------

# Open ports
echo -e "  ${BLUE}Listening ports:${NC}"
sudo ss -tlnp 2>/dev/null | grep LISTEN | while read -r line; do
    port=$(echo "$line" | awk '{print $4}' | rev | cut -d: -f1 | rev)
    proc=$(echo "$line" | grep -o 'users:(("[^"]*"' | cut -d'"' -f2)
    addr=$(echo "$line" | awk '{print $4}' | rev | cut -d: -f2- | rev)
    if [[ "$addr" == "127.0.0.1" || "$addr" == "::1" || "$addr" == "" ]]; then
        pass "Port $port ($proc) -- loopback only"
    elif [[ "$addr" == "0.0.0.0" || "$addr" == "*" || "$addr" == "::" ]]; then
        warn "Port $port ($proc) -- exposed on all interfaces"
    else
        pass "Port $port ($proc) -- $addr"
    fi
done

# ---------------------------------------------------------------------------
section "=== SUMMARY ==="
# ---------------------------------------------------------------------------

echo ""
echo -e "  ${GREEN}PASS: $PASS${NC}    ${RED}FAIL: $FAIL${NC}    ${YELLOW}WARN: $WARN${NC}"
echo ""

if [[ $FAIL -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}All critical checks passed.${NC}"
else
    echo -e "  ${RED}${BOLD}$FAIL critical issue(s) found. Review FAIL items above.${NC}"
fi
echo ""
