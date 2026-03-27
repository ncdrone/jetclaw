# jetclaw

Hardened OpenClaw deployment toolkit. One interactive script takes a fresh Ubuntu machine (Jetson, VPS, or bare metal) to a fully secured, production-ready OpenClaw instance.

## What This Does

- **OS hardening** — UFW firewall, SSH lockdown, fail2ban, encrypted DNS (Quad9), automatic security updates, unnecessary services disabled
- **Service user isolation** — dedicated system user with locked password, scoped sudoers, no SSH access
- **Tailscale-only networking** — no ports exposed to the public internet, SSH restricted to tailnet
- **OpenClaw deployment** — CLI install, config generation (via Python for safe JSON), systemd service, Tailscale Serve
- **Arsenal tool support** — Nginx reverse proxy, PostgreSQL, Docker, Chromium browser, scoped sudoers for service management
- **Migration tooling** — copy a running instance to a new machine with one command

## Quick Start

```bash
# SSH into your target machine
ssh your-admin-user@your-machine

# Download and run
curl -O https://raw.githubusercontent.com/your-user/jetclaw/main/jetclaw-install.sh
chmod +x jetclaw-install.sh
./jetclaw-install.sh
```

The script is fully interactive. It will prompt for hostname, service user name, API keys, and which components to install. Every step that requires manual action (SSH key setup, Tailscale login, HTTPS certificate approval) pauses and waits.

### With CLI arguments

```bash
./jetclaw-install.sh \
  --hostname myagent \
  --user myagent \
  --port 18789 \
  --api-key "sk-ant-api03-YOUR-KEY"
```

Run `./jetclaw-install.sh --help` for all options.

## Structure

```
jetclaw/
├── jetclaw-install.sh              # Main install script (run on target)
├── tools/
│   ├── jetclaw-migrate.sh          # Copy instance to new machine (run from Mac)
│   └── jetclaw-update.sh           # Update OpenClaw + restart gateway
└── manual/
    └── complete-setup-guide.md     # Full step-by-step guide
```

## Scripts

| Script | Purpose | Run from |
|--------|---------|----------|
| `jetclaw-install.sh` | Full hardened install on a fresh machine | On the target machine |
| `tools/jetclaw-migrate.sh` | Copy a running instance to a new machine | From your Mac/laptop |
| `tools/jetclaw-update.sh` | Update OpenClaw CLI and restart gateway | On the target machine |

### Update

```bash
# Check for updates
./tools/jetclaw-update.sh --check

# Update and restart
./tools/jetclaw-update.sh --user myagent
```

Auto-detects the service user if there's only one OpenClaw service running.

## What Gets Installed

### Phase 1: System Hardening
- System update (`apt upgrade`, not `full-upgrade` to protect Jetson/NVIDIA packages)
- Hostname change
- SSH hardening (key-only auth, no root login, `AllowUsers`)
- UFW firewall (deny all incoming, allow Tailscale)
- Fail2ban (SSH: 3 attempts, 24h ban)
- Automatic security updates
- Disable unnecessary services (avahi, cups, bluetooth, ModemManager, rpcbind)
- Quad9 encrypted DNS with DNSSEC

### Phase 2: Service User
- System user with `/bin/bash` shell and locked password
- Home directory at `/var/lib/<username>/`
- Scoped sudoers (arsenal services, nginx, tailscale serve only)
- Git identity configuration

### Phase 3: Dependencies (all optional)
- Node.js 22
- Docker (with security config: log limits, no-new-privileges, no userland-proxy)
- PostgreSQL (with database creation and credential storage)
- Nginx (with service user write access to site configs)
- Chromium (for browser tools and research skills)
- GitHub PAT storage

### Phase 4: OpenClaw
- CLI install via npm (avoids auto-onboarding from curl installer)
- Tailscale Serve configuration
- Config generation via Python3 `json.dumps()` (no heredoc injection possible)
- Production defaults: heartbeat, context pruning, compaction, session isolation, log redaction
- Optional interactive onboarding (config backed up before onboarding runs)
- Browser config with `noSandbox: true` for ARM64

### Phase 5: Systemd Service
- Auto-detects `openclaw` binary path (works whether npm installs to `/usr/bin/` or `/usr/local/bin/`)
- Conditional `Requires=docker.service` (only when Docker is installed)
- Auto-detects Jetson hardware for appropriate boot wait time

### Phase 6: Post-Install Verification
- Service running check
- Port listening check
- File ownership audit
- Accidental `.openclaw` in admin home detection
- Optional `openclaw doctor` and `openclaw security audit --deep`

## Migration

```bash
# From your Mac — copy an instance from one machine to another
./jetclaw-migrate.sh \
  --source admin@source-machine \
  --target admin@target-machine \
  --source-user myagent
```

Transfers the `.openclaw/` directory (excluding Playwright, node_modules, cache), fixes ownership, updates config for the new hostname/port, and restarts the gateway.

Options: `--exclude-sessions`, `--exclude-credentials`, `--target-port`, `--target-hostname`, `--dry-run`.

## Manual

See `manual/` for a step-by-step guide that explains every decision. Useful if you want to understand what the scripts do before running them, or if you need to do something the scripts don't cover.

## Security Model

```
Internet
   |
   X  (all incoming denied)
   |
Machine ── UFW ── deny all incoming
   |              allow outgoing
   |              allow Tailscale (100.64.0.0/10) SSH only
   |
   ├── Admin User (you)
   │   ├── sudo access
   │   ├── SSH via Tailscale only
   │   └── manages everything
   │
   └── Service User (the agent)
       ├── no sudo (except scoped arsenal-* commands)
       ├── no SSH (password locked)
       ├── no access to admin home
       ├── owns /var/lib/<username>/
       └── runs OpenClaw gateway (loopback only)
           └── exposed via Tailscale Serve (tailnet only)
```

If the agent gets compromised via prompt injection, it is trapped in its own user space. It cannot read SSH keys, cannot sudo, cannot modify system files, cannot access other users' data.

## Requirements

- Ubuntu 22.04+ (JetPack 6.x for Jetsons)
- Admin user with sudo access
- Python3 (for JSON generation)
- SSH key access configured
- Anthropic API key

## License

MIT
