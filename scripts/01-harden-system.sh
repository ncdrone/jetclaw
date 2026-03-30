#!/usr/bin/env bash
#
# 01-harden-system.sh — System hardening: updates, SSH, UFW, fail2ban, DNS
#
# Run ON the target machine as your admin user with sudo access.
# Can be run standalone or called by the orchestrator.
#
# Usage:
#   ./scripts/01-harden-system.sh --hostname praxis --admin-user ncd
#   ./scripts/01-harden-system.sh --dry-run
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# ---------------------------------------------------------------------------
# CLI arguments
# ---------------------------------------------------------------------------
HOSTNAME_NEW="${HOSTNAME_NEW:-}"
ADMIN_USER="${ADMIN_USER:-$(whoami)}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --hostname)    [[ $# -ge 2 ]] || fatal "--hostname requires a value"; HOSTNAME_NEW="$2"; shift 2 ;;
        --admin-user)  [[ $# -ge 2 ]] || fatal "--admin-user requires a value"; ADMIN_USER="$2"; shift 2 ;;
        --dry-run)     DRY_RUN=true; shift ;;
        --help)        echo "Usage: $0 --hostname <name> [--admin-user <name>] [--dry-run]"; exit 0 ;;
        *) fatal "Unknown argument: $1" ;;
    esac
done

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
require_sudo
phase "SYSTEM HARDENING"

# Gather inputs interactively if not provided
prompt_value HOSTNAME_NEW "Hostname for this machine (e.g., praxis, ergon)"
validate_hostname "$HOSTNAME_NEW"

# ---------------------------------------------------------------------------
# Step 1/8: System update
# ---------------------------------------------------------------------------
info "Step 1/8: Updating system packages..."
run_shell "sudo apt update && sudo apt upgrade -y"
run_cmd sudo apt autoremove -y

info "Installing base packages..."
run_cmd sudo apt install -y curl git vim htop tmux ufw fail2ban unattended-upgrades
verify "Base packages installed" command -v ufw
verify "fail2ban installed" command -v fail2ban-client

# ---------------------------------------------------------------------------
# Step 2/8: Hostname
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Step 3/8: SSH hardening
# ---------------------------------------------------------------------------
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
echo -e "  ${CYAN}# Step 2: Copy it to this machine${NC}"
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
SSH_HARDENING_SKIPPED=false
while true; do
    read -rp "  SSH key works without password? (YES/NO): " ssh_key_confirm
    case "$ssh_key_confirm" in
        YES) success "SSH key access confirmed"; break ;;
        NO)
            warn "Skipping SSH hardening. Password auth will remain enabled."
            SSH_HARDENING_SKIPPED=true
            break ;;
        *) warn "Type YES or NO (full word, capitalized)" ;;
    esac
done

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
        sudo sshd -t || fatal "SSH config validation failed!"
        sudo systemctl restart sshd
    fi

    success "SSH hardened"
    echo ""
    echo -e "  ${BG_RED}${BOLD} !!! WARNING: Password auth is now DISABLED !!! ${NC}"
    echo ""

    action_required "Open a ${BOLD}NEW${NC}${YELLOW} terminal and verify you can still SSH in:\n\n    ${BOLD}ssh $ADMIN_USER@$CURRENT_IP${NC}\n\n  ${RED}Do NOT close this terminal until you've confirmed!${NC}"

    echo ""
    echo -e "  ${BG_YELLOW}${BOLD} Type YES if SSH works, or NO to roll back: ${NC}"
    echo ""
    while true; do
        read -rp "  SSH confirmed? (YES/NO): " ssh_confirm
        case "$ssh_confirm" in
            YES) success "SSH confirmed working"; break ;;
            NO)
                warn "Rolling back SSH hardening..."
                sudo rm -f /etc/ssh/sshd_config.d/hardening.conf
                sudo systemctl restart sshd
                success "Password auth re-enabled."
                info "Fix your SSH key access, then re-run the script."
                exit 0 ;;
            *) warn "Type YES or NO (full word, capitalized)" ;;
        esac
    done
fi

# ---------------------------------------------------------------------------
# Step 4/8: Firewall (UFW)
# ---------------------------------------------------------------------------
info "Step 4/8: Configuring firewall (UFW)..."

if ! $DRY_RUN; then
    UFW_BACKUP="/tmp/ufw-backup-$(date +%s).txt"
    sudo ufw status numbered > "$UFW_BACKUP" 2>/dev/null || true
    info "Existing UFW rules backed up to: $UFW_BACKUP"
fi

run_cmd sudo ufw --force reset
run_cmd sudo ufw default deny incoming
run_cmd sudo ufw default allow outgoing
run_shell "sudo ufw allow from 127.0.0.1"

# Temporary LAN access (replaced by Tailscale later)
info "Adding temporary LAN SSH access (run 02-install-tailscale.sh to lock to Tailscale)..."
run_shell "sudo ufw allow from 192.168.0.0/16 to any port 22"
run_shell "sudo ufw allow from 10.0.0.0/8 to any port 22"

run_cmd sudo ufw --force enable
success "Firewall configured (deny all incoming, allow outgoing)"

# ---------------------------------------------------------------------------
# Step 5/8: Fail2ban
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Step 6/8: Auto updates
# ---------------------------------------------------------------------------
info "Step 6/8: Enabling automatic security updates..."
if ! $DRY_RUN; then
    echo 'Unattended-Upgrade::Allowed-Origins { "${distro_id}:${distro_codename}-security"; };' | \
        sudo tee /etc/apt/apt.conf.d/50unattended-upgrades-override >/dev/null
    sudo systemctl enable --now unattended-upgrades
fi
success "Automatic security updates enabled"

# ---------------------------------------------------------------------------
# Step 7/8: Kill unnecessary services
# ---------------------------------------------------------------------------
info "Step 7/8: Disabling unnecessary services..."
for svc in avahi-daemon cups bluetooth ModemManager rpcbind rpcbind.socket; do
    run_cmd sudo systemctl disable --now "$svc" 2>/dev/null || true
done
success "Disabled: avahi, cups, bluetooth, ModemManager, rpcbind"

# ---------------------------------------------------------------------------
# Step 8/8: Quad9 DNS
# ---------------------------------------------------------------------------
info "Step 8/8: Configuring encrypted DNS (Quad9)..."
echo "  Quad9 blocks known malware domains -- extra protection against"
echo "  prompt injection trying to reach malicious URLs."
if ! $DRY_RUN; then
    sudo tee /etc/systemd/resolved.conf >/dev/null <<'DNSEOF'
[Resolve]
DNS=9.9.9.9#dns.quad9.net 149.112.112.112#dns.quad9.net
FallbackDNS=1.1.1.1 8.8.8.8
DNSOverTLS=yes
Domains=~.
DNSEOF
    sudo systemctl restart systemd-resolved
fi

if resolvectl status 2>/dev/null | grep -q '9.9.9.9' || grep -q '9.9.9.9' /etc/systemd/resolved.conf 2>/dev/null; then
    success "DNS configured"
else
    warn "Could not verify DNS. Check manually: resolvectl status"
fi

echo ""
success "=== System hardening complete ==="
