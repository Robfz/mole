# SSH Tunnel

A persistent reverse SSH tunnel system that allows secure remote access to a Mac behind NAT, using a Linux server as a jump host with Mosh support for reliable connections.

## Overview

This project provides scripts to set up and manage a reverse SSH tunnel from a Mac (behind NAT/firewall) to a Linux server with a public IP. Remote clients can then connect to the Mac through the server.

```
┌─────────────────┐         ┌─────────────────┐         ┌─────────────────┐
│  Remote Client  │  Mosh   │  Linux Server   │  SSH    │   Mac (NAT)     │
│                 │ ──────► │  (Public IP)    │ ◄────── │                 │
│  laptop/phone   │         │  Jump Host      │ Tunnel  │  Target Machine │
└─────────────────┘         └─────────────────┘         └─────────────────┘
```

**Connection Flow:**
1. Mac establishes a persistent reverse tunnel to the Linux server
2. Client connects to Linux server via Mosh (handles flaky connections)
3. From the server, client SSHs through the tunnel to reach the Mac

## Features

- **Persistent tunnel** via `autossh` with automatic reconnection
- **Sleep prevention** using `caffeinate` to keep Mac awake while tunnel is active
- **Mosh support** for reliable connections over unstable networks
- **Named client keys** for easy identification and management
- **launchd integration** for automatic startup on Mac login

## Prerequisites

### Linux Server
- Public IP address or domain name
- SSH server running
- Root/sudo access
- Firewall access to open ports

### Mac
- macOS with Homebrew installed
- SSH key access to the Linux server (set this up first)
- Admin access

### Clients
- SSH client
- Mosh client (recommended)

## Quick Start

### 1. Set up the Linux Server

Copy scripts to your server and run:

```bash
./setup-tunnel-server.sh --tunnel-port 2222
```

This will:
- Install Mosh
- Configure SSH for gateway ports
- Open firewall ports (TCP 2222, UDP 60000-61000)

### 2. Set up the Mac

First, ensure you can SSH to your server:

```bash
ssh user@your-server.com
```

Then run the setup:

```bash
./setup-tunnel-mac.sh \
  --host your-server.com \
  --user admin \
  --clients m4,s23,laptop
```

This will:
- Install `autossh` and `mosh` via Homebrew
- Generate SSH keys for each client
- Configure a launchd service for the persistent tunnel
- Start the tunnel

### 3. Distribute Client Keys

The setup creates keys in `~/.ssh/tunnel-clients/`:

```
~/.ssh/tunnel-clients/m4_ed25519
~/.ssh/tunnel-clients/m4_ed25519.pub
~/.ssh/tunnel-clients/s23_ed25519
...
```

Securely distribute the private keys (`*_ed25519`, not `.pub`) to your clients.

### 4. Connect from a Client

**Option 1: Mosh + SSH (recommended)**

```bash
# Connect to the jump server
mosh admin@your-server.com

# Then SSH to the Mac through the tunnel
ssh -p 2222 -i ~/.ssh/m4_ed25519 macuser@localhost
```

**Option 2: SSH ProxyJump (single command)**

```bash
ssh -J admin@your-server.com -p 2222 -i ~/.ssh/m4_ed25519 macuser@localhost
```

## Scripts Reference

### Mac Scripts

| Script | Purpose |
|--------|---------|
| `setup-tunnel-mac.sh` | Initial setup and configuration |
| `tunnel-control-mac.sh` | Start/stop/restart the tunnel |
| `tunnel-status-mac.sh` | Detailed status and diagnostics |
| `uninstall-tunnel-mac.sh` | Remove tunnel configuration |

### Server Scripts

| Script | Purpose |
|--------|---------|
| `setup-tunnel-server.sh` | Initial server configuration |
| `tunnel-status-server.sh` | Server status and diagnostics |
| `uninstall-tunnel-server.sh` | Remove server configuration |

## Usage

### Mac Commands

```bash
# Start/stop/restart tunnel
./tunnel-control-mac.sh start
./tunnel-control-mac.sh stop
./tunnel-control-mac.sh restart
./tunnel-control-mac.sh status

# Detailed status
./tunnel-status-mac.sh

# View logs
tail -f /tmp/ssh-tunnel.log
```

### Setup Options

#### setup-tunnel-mac.sh

| Flag | Description | Default |
|------|-------------|---------|
| `-H, --host` | Server hostname/IP | (required) |
| `-u, --user` | Server username | (required) |
| `-c, --clients` | Comma-separated client names | (required) |
| `-p, --tunnel-port` | Tunnel port on server | 2222 |
| `-k, --key-path` | Path to store client keys | ~/.ssh/tunnel-clients |

#### setup-tunnel-server.sh

| Flag | Description | Default |
|------|-------------|---------|
| `-p, --tunnel-port` | Tunnel port to open | 2222 |

## How It Works

### The Reverse Tunnel

The Mac runs this command (via launchd):

```bash
caffeinate -s autossh -M 0 -N \
  -o 'ServerAliveInterval 30' \
  -o 'ServerAliveCountMax 3' \
  -R 2222:localhost:22 \
  user@server
```

- `caffeinate -s` prevents Mac sleep while tunnel is active
- `autossh -M 0` monitors the connection and reconnects if it drops
- `-R 2222:localhost:22` creates a reverse tunnel: server's port 2222 → Mac's port 22
- `ServerAliveInterval/CountMax` detects dead connections

### launchd Service

The tunnel runs as a user launch agent (`~/Library/LaunchAgents/com.robfz.ssh-tunnel.plist`) that:
- Starts automatically at login
- Restarts if the process dies
- Only runs when network is available

## Troubleshooting

### Tunnel won't start

1. Check if you can SSH to the server manually:
   ```bash
   ssh user@your-server.com
   ```

2. Check the logs:
   ```bash
   tail -f /tmp/ssh-tunnel.log
   tail -f /tmp/ssh-tunnel.err
   ```

3. Run the status script:
   ```bash
   ./tunnel-status-mac.sh
   ```

### Connection drops frequently

1. Check your internet connection stability
2. Verify `ServerAliveInterval` settings in the plist
3. Check server's `ClientAliveInterval` in `/etc/ssh/sshd_config`

### Can't connect through tunnel

1. On the server, verify the tunnel port is listening:
   ```bash
   ss -tlnp | grep 2222
   ```

2. Check if GatewayPorts is configured:
   ```bash
   grep GatewayPorts /etc/ssh/sshd_config
   ```

3. Test locally on the server:
   ```bash
   ssh -p 2222 macuser@localhost
   ```

### Mac goes to sleep

The tunnel uses `caffeinate -s` which should prevent sleep while on AC power. If issues persist:

```bash
# Check caffeinate is running
pgrep -f "caffeinate.*autossh"

# Manual override (prevents all sleep)
sudo pmset -a sleep 0
```

## Security Considerations

- **Client keys**: Store private keys securely. Consider using passphrases.
- **Tunnel binding**: The tunnel binds to `localhost` on the server, so direct external access to the tunnel port is not possible.
- **Firewall**: Only necessary ports are opened (tunnel port + Mosh UDP range).
- **Key rotation**: Periodically regenerate client keys and update authorized_keys.

## Uninstalling

### Mac

```bash
./uninstall-tunnel-mac.sh --remove-keys --remove-auth
```

### Server

```bash
./uninstall-tunnel-server.sh --tunnel-port 2222 --uninstall-mosh
```

## License

MIT
