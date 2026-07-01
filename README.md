# mc-server

All-in-one Minecraft server setup. Downloads, installs, configures EULA, and generates launcher + backup + systemd service.

Supports: **Bukkit**, **Spigot**, **Paper**, **Purpur**, **Fabric**

## Features

- Interactive setup with version list from API
- Auto-download server jar from official APIs (PaperMC, PurpurMC, Fabric Meta, SpigotMC BuildTools)
- Accept EULA automatically
- `start.sh` — Universal launcher (tmux/screen/nohup auto-detect, auto-port kill)
- `start.sh config` — Read/set server.properties from CLI
- `start.sh stats` — Server monitoring (RAM, PID, threads, TPS via RCON)
- `start.sh world` — World backup/restore/list
- `start.sh send` — Send commands to server console
- `backup.sh` — Universal backup with rotation
- `plugins.sh` — Modrinth plugin management (search, install, remove, update)
- `update.sh` — Update server jar without touching world/config
- `docker.sh` — Docker Compose generator (alternative to bare-metal)
- Systemd service for auto-start on boot
- Progress bar on all jar downloads

## Quick Start

```bash
# One-file setup (downloads other scripts from GitHub automatically)
curl -fsSL -o setup.sh https://raw.githubusercontent.com/bianvigano/mc-server/main/setup.sh
chmod +x setup.sh
./setup.sh
```

Or with flags:

```bash
./setup.sh --type paper
./setup.sh --type purpur --version 1.21.4
./setup.sh --type fabric --version 1.21.4
./setup.sh --type bukkit --version 1.21.4
./setup.sh --type spigot --version 1.21.4
```

## Interactive Mode

```bash
$ ./setup.sh

========================================
  MC Server Setup
========================================

Pilih server type:
  1) Bukkit   — Original plugin API (legacy)
  2) Spigot   — Optimized Bukkit (legacy)
  3) Paper    — Performance + Bukkit/Spigot plugin support
  4) Purpur   — Paper + extra configurability
  5) Fabric   — Mod loader (mods, not plugins)

Pilih [1/2/3/4/5]: 4

Nama directory [./purpur-server]: survival

[*] Fetching available versions for PURPUR...

Available versions:
  > 26.2
  > 26.1
  > 1.21.11
  > 1.21.10
  > 1.21.9
  > ...

Ketik versi [latest = 26.1.2]: 1.21.4
```

- Pilih server type (1-5)
- Ketik nama directory (Enter = default)
- Pilih versi dari list (Enter = latest)

## Commands

```bash
cd survival  # server directory

# Server
./start.sh start              # Start
./start.sh stop               # Stop
./start.sh restart            # Restart
./start.sh status             # Status
./start.sh console            # Attach console
./start.sh send "say Hello"   # Send command to server

# Config
./start.sh config                    # Show all properties
./start.sh config server-port        # Read one key
./start.sh config set motd "Hi!"     # Set a key

# Monitoring
./start.sh stats              # RAM, PID, threads, TPS (needs RCON)

# World
./start.sh world backup           # Backup world
./start.sh world backup "before-update"  # Labeled backup
./start.sh world list             # List backups
./start.sh world restore <file>   # Restore

# Plugins (Paper/Purpur only)
./start.sh plugins search essentials
./start.sh plugins install essentialsx
./start.sh plugins list
./start.sh plugins update

# RAM
JAVA_XMX=4G ./start.sh start
```

## Setup Script

```bash
./setup.sh [OPTIONS]
```

| Option | Default | Description |
|--------|---------|-------------|
| `--type` | *(interactive)* | Server type: `bukkit`, `spigot`, `paper`, `purpur`, `fabric` |
| `--version` | latest | Minecraft version |
| `--dir` | `./<type>-server` | Output directory |
| `--build` | latest stable | Paper: specific build number |
| `--fabric-loader` | latest stable | Fabric: specific loader version |
| `--fabric-installer` | latest stable | Fabric: specific installer version |

## Server Types

### Bukkit / Spigot
- Original plugin API / Optimized Bukkit
- Built via SpigotMC BuildTools (requires git)
- Compiled from source (takes a few minutes)

### Paper
- High-performance fork of Spigot
- Compatible with all Bukkit/Spigot plugins
- API: `fill.papermc.io/v3`

### Purpur
- Fork of Paper with extra configurability
- Compatible with Bukkit/Spigot/Paper plugins
- API: `api.purpurmc.org/v2`

### Fabric
- Mod loader (mods, not plugins)
- Rich mod ecosystem (Sodium, Lithium, etc.)
- API: `meta.fabricmc.net/v2`

## Files

```
mc-server/
├── setup.sh        # Multi-type bare-metal setup (only file needed)
├── start.sh        # Universal launcher + config + stats + world + plugins
├── backup.sh       # Universal backup with rotation
├── plugins.sh      # Modrinth plugin manager
├── update.sh       # Update server jar
├── docker.sh       # Docker Compose generator
└── README.md
```

After setup:
```
<dir>/
├── start.sh         # Launcher + commands
├── backup.sh        # Backup
├── plugins.sh       # Plugin manager
├── update.sh        # Server updater
├── plugins/         # Plugins directory
├── world/           # World data
├── server.jar       # Paper/Purpur/Fabric jar
├── .mc-info         # Server metadata (type, version, jar)
├── eula.txt         # Auto-accepted
└── server.properties
```

Metadata format (`.mc-info`):
```
type=paper
version=1.21.4
jar=paper.jar
```

## Docker Mode

```bash
./docker.sh --type paper --ram 2G --port 25565
docker compose up -d
docker compose logs -f
docker compose down
```

## Backup

```bash
# Manual backup
./backup.sh

# Labeled backup
./backup.sh before-mods

# Custom location
BACKUP_DIR=/mnt/backup ./backup.sh

# Keep more backups (default: 24)
MAX_BACKUPS=48 ./backup.sh
```

### Auto-Backup (cron)

```bash
crontab -e
# Add: Backup every 4 hours
0 */4 * * * /root/survival/backup.sh auto
```

## Systemd (auto-start on boot)

```bash
sudo cp survival/minecraft-purpur.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable minecraft-purpur
sudo systemctl start minecraft-purpur
```

## Monitoring

```bash
# Basic status
./start.sh stats

# With RCON (for TPS, player list)
./start.sh config set enable-rcon true
./start.sh config set rcon.password "secret"
./start.sh restart
./start.sh stats
```

## Update Server

```bash
./update.sh                     # Update to latest
./update.sh --version 1.21.5    # Update to specific version
```

Updates the server jar only. World, config, and plugins are untouched.

## Requirements

- Java 17+
- curl, python3 (for setup script only)
- tmux or screen (optional, auto-detects)
- tar (for backup)
- git (for Bukkit/Spigot BuildTools)
- mcrcon (optional, for TPS monitoring)

## How It Works

**Paper/Purpur:**
1. Queries official API for version list + current stable
2. Downloads server jar directly with progress bar
3. Accepts EULA
4. Copies start.sh, backup.sh, plugins.sh, update.sh from repo or GitHub
5. Generates systemd service

**Fabric:**
1. Queries `meta.fabricmc.net` for latest stable loader + installer
2. Downloads installer jar from `maven.fabricmc.net`
3. Runs installer to download Minecraft server + Fabric
4. Accepts EULA
5. Copies scripts; generates systemd service
6. Cleans up installer jar

**Bukkit/Spigot:**
1. Downloads SpigotMC BuildTools
2. Compiles server jar from source
3. Accepts EULA
4. Copies scripts; generates systemd service

## License

MIT
