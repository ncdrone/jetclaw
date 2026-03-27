# Complete Setup Guide — Hardened OpenClaw Deployment

**Admin user**: `<your-admin-user>` | **Service user**: `<your-agent-name>` | **Hostname**: `<your-hostname>`

This guide covers everything from a fresh Ubuntu machine to a fully secured, production-ready OpenClaw deployment. Security is the foundation -- every step builds on it.

> **Prefer automation?** The `jetclaw-install.sh` script automates this entire guide. This manual is for understanding what it does, or for doing things the script doesn't cover.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              INTERNET                                        │
└───────────────────────────────────┬─────────────────────────────────────────┘
                                    │
                           (Outbound only)
                                    │
┌───────────────────────────────────┼─────────────────────────────────────────┐
│                           YOUR NETWORK                                       │
│                                   │                                          │
│    ┌──────────────────────────────┼──────────────────────────────────────┐  │
│    │                        TARGET MACHINE                               │  │
│    │                              │                                       │  │
│    │   ┌──────────────────┐   ┌──────────────────┐   ┌────────────────┐  │  │
│    │   │   UFW Firewall   │   │    Tailscale     │   │  Quad9 DNS     │  │  │
│    │   │ (deny incoming)  │   │  (100.x.x.x)     │   │  (malware      │  │  │
│    │   │                  │   │  (your devices)  │   │   blocking)    │  │  │
│    │   └──────────────────┘   └──────────────────┘   └────────────────┘  │  │
│    │                              │                                       │  │
│    │   ┌──────────────────────────┴───────────────────────────────────┐  │  │
│    │   │              USER SEPARATION                                  │  │  │
│    │   │                                                               │  │  │
│    │   │   admin (you)              │    service user (the agent)     │  │  │
│    │   │   ├─ full sudo             │    ├─ scoped sudo (sudoers)     │  │  │
│    │   │   ├─ SSH login             │    ├─ no SSH (password locked)   │  │  │
│    │   │   ├─ /home/<admin>         │    ├─ /var/lib/<agent>/          │  │  │
│    │   │   └─ full control          │    └─ runs OpenClaw (jailed)     │  │  │
│    │   └──────────────────────────┴───────────────────────────────────┘  │  │
│    │                              │                                       │  │
│    │   ┌──────────────────────────┴───────────────────────────────────┐  │  │
│    │   │              OpenClaw Gateway (127.0.0.1:<port>)             │  │  │
│    │   └──────────────────────────────────────────────────────────────┘  │  │
│    │                              │                                       │  │
│    └──────────────────────────────┼───────────────────────────────────────┘  │
│                                   │                                          │
│                          (Outbound to APIs)                                  │
│                    Anthropic, Telegram, GitHub, etc.                         │
└──────────────────────────────────────────────────────────────────────────────┘
```

**Why this architecture?**
- If the agent gets compromised via prompt injection, it's trapped in its own user space
- Can't read your SSH keys
- Can't sudo (except scoped commands)
- Can't modify system files
- Quad9 DNS blocks known malware domains

---

# Part 1: System Hardening

*Complete these steps on a fresh Ubuntu 22.04+ installation (or JetPack 6.x for Jetsons).*

## 1.1 System Update

```bash
sudo apt update && sudo apt upgrade -y
sudo apt autoremove -y
sudo reboot
```

After reboot:

```bash
sudo apt install -y curl git vim htop tmux ufw fail2ban unattended-upgrades
```

> **Why `apt upgrade` not `full-upgrade`?** On Jetsons, `full-upgrade` can remove NVIDIA packages to satisfy dependencies. `upgrade` is the safe variant.

**Verify:**
```bash
command -v ufw && command -v fail2ban-client && command -v curl && command -v git
```

## 1.2 Change Hostname

```bash
sudo hostnamectl set-hostname <your-hostname>
```

Update `/etc/hosts`:
```
127.0.1.1    <your-hostname>
```

**Verify:**
```bash
hostnamectl
# Should show: Static hostname: <your-hostname>
```

## 1.3 Create Service User

```bash
# Create system user with bash shell
sudo useradd --system --shell /bin/bash --create-home --home-dir /var/lib/<agent> <agent>

# Lock password (prevents login, but sudo -u <agent> still works)
sudo passwd -l <agent>

# Create directories
sudo mkdir -p /var/lib/<agent>/{config,workspace,logs,.openclaw,.secrets}
sudo chown -R <agent>:<agent> /var/lib/<agent>
sudo chmod 700 /var/lib/<agent>
```

**Why `/bin/bash` and not `nologin`?** Using `/usr/sbin/nologin` prevents `sudo -u <agent>` from running interactive commands (they freeze). Since the password is locked and there's no SSH key, `/bin/bash` is safe -- no one can log in directly.

**Verify:**
```bash
id <agent>
getent passwd <agent> | grep /bin/bash
sudo -u <agent> whoami
# Should print the agent name and NOT freeze
```

## 1.4 SSH Key Setup (On Your Mac)

```bash
# Generate a DEDICATED key (don't reuse work keys)
ssh-keygen -t ed25519 -C "<your-hostname>" -f ~/.ssh/id_ed25519_<your-hostname>

# Add to macOS Keychain
ssh-add --apple-use-keychain ~/.ssh/id_ed25519_<your-hostname>

# Copy to the target machine
ssh-copy-id -i ~/.ssh/id_ed25519_<your-hostname>.pub <admin>@<machine-ip>
```

Add to `~/.ssh/config` on Mac:
```
Host <your-hostname>
    HostName <machine-ip>
    User <admin>
    IdentityFile ~/.ssh/id_ed25519_<your-hostname>
    IdentitiesOnly yes
    ServerAliveInterval 30
    ServerAliveCountMax 3
```

**Test:** `ssh <your-hostname>` should connect without a password prompt.

## 1.5 Lock Down SSH

```bash
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
```

Create `/etc/ssh/sshd_config.d/hardening.conf`:
```
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
X11Forwarding no
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
AllowUsers <admin>
```

```bash
sudo sshd -t          # Validate (should output nothing)
sudo systemctl restart sshd
```

**CRITICAL:** Open a NEW terminal and test `ssh <your-hostname>` before closing your current session!

## 1.6 Firewall

```bash
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from 127.0.0.1

# Temporary LAN access (until Tailscale is up)
sudo ufw allow from 192.168.0.0/16 to any port 22
sudo ufw allow from 10.0.0.0/8 to any port 22

sudo ufw --force enable
```

## 1.7 Tailscale

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --ssh
tailscale ip -4   # Note your 100.x.x.x IP
```

Now lock SSH to Tailscale only:
```bash
sudo ufw delete allow from 192.168.0.0/16 to any port 22
sudo ufw delete allow from 10.0.0.0/8 to any port 22
sudo ufw allow from 100.64.0.0/10 to any port 22
```

Update `~/.ssh/config` on Mac to use the Tailscale hostname instead of the LAN IP.

## 1.8 Fail2ban

Create `/etc/fail2ban/jail.local`:
```ini
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 3

[sshd]
enabled = true
port = ssh
maxretry = 3
bantime = 24h
```

```bash
sudo systemctl enable --now fail2ban
```

## 1.9 Automatic Security Updates

```bash
sudo dpkg-reconfigure -plow unattended-upgrades
# Select: Yes
```

## 1.10 Disable Unnecessary Services

```bash
sudo systemctl disable --now avahi-daemon 2>/dev/null
sudo systemctl disable --now cups 2>/dev/null
sudo systemctl disable --now bluetooth 2>/dev/null
sudo systemctl disable --now ModemManager 2>/dev/null
sudo systemctl disable --now rpcbind rpcbind.socket 2>/dev/null
```

## 1.11 Encrypted DNS (Quad9)

Edit `/etc/systemd/resolved.conf`:
```ini
[Resolve]
DNS=9.9.9.9#dns.quad9.net 149.112.112.112#dns.quad9.net
FallbackDNS=
DNSOverTLS=yes
DNSSEC=yes
Domains=~.
```

```bash
sudo systemctl restart systemd-resolved
```

**Why Quad9?** Blocks known malware domains. Extra protection if prompt injection tries to reach malicious URLs. `FallbackDNS=` (empty) prevents fallback to unencrypted ISP DNS.

**Verify:**
```bash
resolvectl status
# Should show 9.9.9.9 with DNS over TLS
```

---

# Part 2: Install Dependencies

> **User context:** System packages are installed system-wide with `sudo`. OpenClaw *config and data* lives in `/var/lib/<agent>/.openclaw/` owned by the service user. Always run `openclaw` commands with `sudo -u <agent>`.

## 2.1 Node.js 22

```bash
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt install -y nodejs

node --version   # Should be 22.x
```

## 2.2 Docker (optional)

```bash
sudo apt install -y docker.io docker-compose-plugin

# Add users to docker group
sudo usermod -aG docker <admin>
sudo usermod -aG docker <agent>
```

Configure Docker security (`/etc/docker/daemon.json`):
```json
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
```

```bash
sudo systemctl restart docker
sudo systemctl enable docker
```

## 2.3 PostgreSQL (optional)

```bash
sudo apt install -y postgresql postgresql-contrib
```

Create database:
```bash
sudo -u postgres psql <<SQL
CREATE USER <agent> WITH PASSWORD '<strong-password>';
CREATE DATABASE <agent> OWNER <agent>;
SQL
```

Store credentials:
```bash
sudo -u <agent> tee /var/lib/<agent>/.secrets/postgres > /dev/null <<EOF
PGHOST=localhost
PGUSER=<agent>
PGPASSWORD=<strong-password>
PGDATABASE=<agent>
EOF
sudo -u <agent> chmod 600 /var/lib/<agent>/.secrets/postgres
```

## 2.4 Nginx (optional)

```bash
sudo apt install -y nginx
```

Grant service user write access to site configs:
```bash
sudo chgrp <agent> /etc/nginx/sites-available /etc/nginx/sites-enabled
sudo chmod g+w /etc/nginx/sites-available /etc/nginx/sites-enabled
```

## 2.5 Chromium (optional, needed for browser tools)

```bash
sudo apt install -y chromium-browser
```

---

# Part 3: Install OpenClaw

## 3.1 Install CLI

```bash
# npm install avoids the auto-onboarding that the curl installer triggers
sudo npm install -g openclaw@latest

openclaw --version
```

## 3.2 Enable Tailscale Serve

```bash
sudo tailscale serve --bg <port>
```

1. Open the URL it shows in your browser
2. **CHECK** "HTTPS certificates"
3. **UNCHECK** "Tailscale Funnel" (this exposes to the public internet!)
4. Click Enable

Set the Tailscale operator:
```bash
sudo tailscale set --operator=<agent>
```

## 3.3 Get API Keys

- **Claude Max token:** Run `claude setup-token` on your Mac (uses subscription limits)
- **Regular API key:** From console.anthropic.com (per-token billing)

> **Note:** OAuth tokens (`sk-ant-oat01-*`) expire periodically and need rotation. Regular API keys (`sk-ant-api03-*`) are more stable for always-on agents.

## 3.4 Run Onboarding

```bash
sudo -u <agent> openclaw onboard
```

| Prompt | Choose | Why |
|--------|--------|-----|
| What to set up? | **Local gateway** | Installing on this machine |
| Workspace directory | Accept default | `/var/lib/<agent>/.openclaw/workspace` |
| Onboarding mode | **Manual** | See all options |
| Model/auth provider | **Anthropic** | Your choice |
| Gateway port | **18789** | Default is fine (or your chosen port) |
| Gateway bind | **Loopback (127.0.0.1)** | Most secure |
| Gateway auth | **Token** | Recommended |
| Tailscale exposure | **Serve** | NOT Funnel |
| Reset Tailscale on exit? | **No** | Keep config persistent |
| Gateway token | **Leave blank** | Auto-generates secure token |
| Configure channels? | **No** | Add later |

**Save the gateway token!** You need it for the dashboard.

## 3.5 Set File Permissions

```bash
sudo chmod 700 /var/lib/<agent>/.openclaw
sudo chmod 600 /var/lib/<agent>/.openclaw/openclaw.json
sudo chown -R <agent>:<agent> /var/lib/<agent>/.openclaw
```

## 3.6 Create Systemd Service

Create `/etc/systemd/system/openclaw-<agent>.service`:
```ini
[Unit]
Description=OpenClaw Gateway (<agent>)
After=network-online.target docker.service tailscaled.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
User=<agent>
Group=<agent>
WorkingDirectory=/var/lib/<agent>
Environment=HOME=/var/lib/<agent>
ExecStart=/usr/bin/openclaw gateway run
Restart=on-failure
RestartSec=10
NoNewPrivileges=false
PrivateTmp=true
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
```

> **Note:** Use `which openclaw` to verify the binary path. It may be `/usr/local/bin/openclaw` on some systems. Remove `Requires=docker.service` if Docker is not installed.

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now openclaw-<agent>
```

Gateway takes ~60 seconds to boot on Jetson (ARM + Node.js). Less on x86 VPS.

**Verify:**
```bash
sudo systemctl status openclaw-<agent>
sudo ss -tlnp | grep <port>
```

## 3.7 Access the Dashboard

### First time: SSH tunnel
```bash
# On your Mac — Terminal 1:
ssh -N -L <port>:127.0.0.1:<port> <admin>@<your-hostname>

# Terminal 2:
open "http://localhost:<port>/?token=YOUR_GATEWAY_TOKEN"
```

The tunnel is supposed to hang (`-N` flag). Localhost connections are auto-approved.

### Enable Tailscale access
In the dashboard: Config > Gateway > Auth > enable "Allow Tailscale". Then approve your browser:

```bash
sudo -u <agent> openclaw devices list
sudo -u <agent> openclaw devices approve <id>
```

### Daily access
```
https://<tailscale-hostname>/?token=YOUR_GATEWAY_TOKEN
```

---

# Part 4: Scoped Sudoers

The service user gets restricted sudo for managing services only.

Create `/etc/sudoers.d/<agent>`:
```
<agent> ALL=(ALL) NOPASSWD: /usr/bin/systemctl daemon-reload
<agent> ALL=(ALL) NOPASSWD: /usr/bin/systemctl start arsenal-*
<agent> ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop arsenal-*
<agent> ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart arsenal-*
<agent> ALL=(ALL) NOPASSWD: /usr/bin/systemctl enable arsenal-*
<agent> ALL=(ALL) NOPASSWD: /usr/bin/systemctl enable --now arsenal-*
<agent> ALL=(ALL) NOPASSWD: /usr/bin/systemctl status arsenal-*
<agent> ALL=(ALL) NOPASSWD: /usr/bin/systemctl disable arsenal-*
<agent> ALL=(ALL) NOPASSWD: /usr/bin/systemctl reload nginx
<agent> ALL=(ALL) NOPASSWD: /usr/sbin/nginx -t
<agent> ALL=(ALL) NOPASSWD: /usr/bin/tee /etc/systemd/system/arsenal-*
<agent> ALL=(ALL) NOPASSWD: /usr/bin/journalctl -u arsenal-*
<agent> ALL=(ALL) NOPASSWD: /usr/bin/tailscale serve *
```

```bash
sudo chmod 440 /etc/sudoers.d/<agent>
sudo visudo -c -f /etc/sudoers.d/<agent>   # Must say "parsed OK"
```

### What the service user CAN do
- Start/stop/restart arsenal-* services
- Create/update nginx configs and reload
- Read arsenal service logs
- Manage Tailscale Serve
- Install npm/pip packages locally (no sudo needed)
- Connect to PostgreSQL (database auth)
- Push to GitHub (PAT auth)
- Run Docker containers (docker group)

### What the service user CANNOT do
- Install system packages
- Edit sudoers or system config
- Touch non-arsenal systemd services
- Access the admin user's home directory
- Run arbitrary commands as root

---

# Part 5: GitHub Access (optional)

## 5.1 Create a GitHub Account for the Agent

1. Sign up at github.com with a dedicated email
2. Enable 2FA
3. You hold all credentials -- the agent only gets a token

## 5.2 Create a Fine-Grained PAT

On the agent's GitHub account:
1. Settings > Developer settings > Fine-grained tokens
2. Generate:
   - **Expiration:** 90 days (rotate periodically)
   - **Repository access:** Only select repositories
   - **Permissions:** Contents (R/W), Pull requests (R/W), Issues (R/W)

## 5.3 Configure Git

```bash
sudo -u <agent> git config --global user.name "<agent>"
sudo -u <agent> git config --global user.email "<agent-email>"
```

## 5.4 Store the Token

```bash
echo "github_pat_YOURTOKEN" | sudo -u <agent> tee /var/lib/<agent>/.secrets/github > /dev/null
sudo -u <agent> chmod 600 /var/lib/<agent>/.secrets/github
```

## 5.5 Workflow

Agent writes code > pushes to a branch (never main) > opens a PR > you review and merge.

---

# Part 6: Secrets Management

All credentials live in `/var/lib/<agent>/.secrets/` with mode `600`.

| File | Contents |
|------|----------|
| `github` | GitHub fine-grained PAT |
| `postgres` | PostgreSQL connection variables (PGHOST, PGUSER, PGPASSWORD, PGDATABASE) |
| `gateway-token` | OpenClaw gateway token |

**Rules:**
- Never put tokens in `openclaw.json` or workspace files
- Never commit secrets to git
- The service user owns these files and can read/write them
- You access them via `sudo`

---

# Part 7: Post-Install Verification

Run these after setup:

```bash
# Service running
sudo systemctl status openclaw-<agent>

# Port listening
sudo ss -tlnp | grep <port>

# File ownership (should all be owned by the service user)
find /var/lib/<agent> -not -user <agent> | head -5

# No accidental config in admin home
ls -la ~/. openclaw 2>/dev/null && echo "WARNING: remove ~/.openclaw"

# OpenClaw diagnostics
sudo -u <agent> openclaw doctor --fix

# Security audit
sudo -u <agent> openclaw security audit --deep

# Firewall status
sudo ufw status verbose

# DNS verification
resolvectl status | grep 9.9.9.9
```

---

# Part 8: Common Operations

```bash
# Run any OpenClaw command
sudo -u <agent> openclaw <command>

# Gateway management
sudo systemctl start|stop|restart openclaw-<agent>
sudo journalctl -u openclaw-<agent> -f

# Fix file ownership (if something ran as wrong user)
sudo chown -R <agent>:<agent> /var/lib/<agent>/.openclaw

# Device pairing (web dashboard)
sudo -u <agent> openclaw devices list
sudo -u <agent> openclaw devices approve <id>

# Telegram pairing
sudo -u <agent> openclaw pairing list telegram
sudo -u <agent> openclaw pairing approve telegram <code>
```

---

# Gotchas

- **Never run `openclaw` commands as root or your admin user.** Always `sudo -u <agent>`. Running as root creates root-owned files the service user can't write to later.
- **The SSH tunnel (`ssh -N -L ...`) is supposed to hang.** That's the `-N` flag.
- **Tailscale Serve requires operator permissions.** Run `sudo tailscale set --operator=<agent>`.
- **`openclaw pairing` is for Telegram channels.** `openclaw devices` is for web browsers. They are different systems.
- **Gateway takes ~60 seconds to boot on Jetson.** Node.js on ARM64 is slow to start. Be patient.
- **OAuth tokens expire.** If using `sk-ant-oat01-*` tokens, monitor for auth failures and rotate.
