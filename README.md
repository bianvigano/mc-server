# mc-server

All-in-one Minecraft server setup. Downloads, installs, configures EULA, and generates launcher + backup + systemd service.

Supports: **Paper**, **Purpur**, **Fabric**

## Features

- Auto-download server jar from official APIs (PaperMC, PurpurMC, Fabric Meta)
- Accept EULA automatically
- `start.sh` — Universal launcher (tmux/screen/nohup auto-detect, auto-port kill)
- `backup.sh` — Universal backup with rotation
- `plugins.sh` — Modrinth plugin management (search, install, remove, update)
- `update.sh` — Update server jar without touching world/config
- `multi.sh` — Multi-server instance manager
- `docker.sh` — Docker Compose generator (alternative to bare-metal)
- Systemd service for auto-start on boot

## Quick Start

```bash
# Bare metal setup
./setup.sh --type paper
./setup.sh --type purpur --version 1.21.4
./setup.sh --type fabric --version 1.21.4

# Or Docker
./docker.sh --type paper --ram 2G
docker compose up -d
```

## Commands

```bash
cd paper-server  # or purpur-server, fabric-server

# Server
./start.sh start              # Start
./start.sh stop               # Stop
./start.sh restart            # Restart
./start.sh status             # Status
./start.sh console            # Attach console
./start.sh send "say Hello"   # Send command

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
| `--type` | *(interactive)* | Server type: `paper`, `purpur`, `fabric` |
| `--version` | latest | Minecraft version |
| `--dir` | `./<type>-server` | Output directory |
| `--build` | latest stable | Paper: specific build number |
| `--fabric-loader` | latest stable | Fabric: specific loader version |
| `--fabric-installer` | latest stable | Fabric: specific installer version |

## Server Types

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
├── setup.sh        # Multi-type bare-metal setup
├── start.sh        # Universal launcher + config + stats + world + plugins
├── backup.sh       # Universal backup with rotation
├── plugins.sh      # Modrinth plugin manager
├── update.sh       # Update server jar
├── multi.sh        # Multi-instance manager
├── docker.sh       # Docker Compose generator
└── README.md
```

After setup:
```
<prefix>-server/
├── start.sh         # Launcher + commands
├── backup.sh        # Backup
├── plugins/         # Plugins directory
├── world/           # World data
├── server.jar       # Paper/Purpur/Fabric jar
├── .mc-type         # Server type
├── .mc-version      # MC version
├── .server-jar      # Jar filename
├── eula.txt         # Auto-accepted
└── server.properties
```

## Multi-Server

Run multiple instances from one mc-server repo:

```bash
./setup.sh --type paper --dir ./survival
./setup.sh --type purpur --dir ./creative
./setup.sh --type fabric --dir ./modded

# List all instances
./multi.sh list

# Manage specific instance
./multi.sh start survival
./multi.sh stop creative
./multi.sh status modded
./multi.sh send survival "say Hello"
./multi.sh plugins survival search worldedit

# Bulk operations
./multi.sh all start
./multi.sh all stop
./multi.sh all status
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
0 */4 * * * /root/paper-server/backup.sh auto
```

## Systemd (auto-start on boot)

```bash
sudo cp paper-server/minecraft-paper.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable minecraft-paper
sudo systemctl start minecraft-paper
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

## Requirements

- Java 17+
- curl, python3 (for setup script only)
- tmux or screen (optional, auto-detects)
- tar (for backup)
- jq or python3 (for plugins.sh)

## How It Works

**Paper/Purpur:**
1. Queries official API for latest version + build
2. Downloads server jar directly
3. Accepts EULA
4. Copies start.sh, backup.sh; generates systemd service

**Fabric:**
1. Queries `meta.fabricmc.net` for latest stable loader + installer
2. Downloads installer jar from `maven.fabricmc.net`
3. Runs installer to download Minecraft server + Fabric
4. Accepts EULA
5. Copies start.sh, backup.sh; generates systemd service
6. Cleans up installer jar

## License

MIT
