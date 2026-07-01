# mc-server

All-in-one Minecraft server setup. Downloads, installs, configures EULA, and generates launcher + backup + systemd service.

Supports: **Paper**, **Purpur**, **Fabric**

## Features

- Auto-download server jar from official APIs (PaperMC, PurpurMC, Fabric Meta)
- Accept EULA automatically
- Generate `start.sh` — server launcher (auto-detect tmux/screen/nohup)
- Generate `backup.sh` — auto-backup with rotation
- Generate systemd service for auto-start on boot
- Auto-kill stale processes on the configured port before start
- Zero config — just run and go

## Quick Start

```bash
# 1. Setup (interactive)
./setup.sh

# Or with flags:
./setup.sh --type paper
./setup.sh --type purpur --version 1.21.4
./setup.sh --type fabric --version 1.21.4

# 2. Start server
cd paper-server  # or purpur-server, fabric-server
./start.sh start
```

## Setup Script

```
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

## Generated Files

```
<prefix>-server/
├── start.sh                    # Server launcher (tmux/screen/nohup)
├── backup.sh                   # Backup with auto-rotation
├── minecraft-<type>.service    # Systemd service file
├── server.jar                  # Server jar (paper.jar/purpur.jar/fabric-server-*.jar)
├── eula.txt                    # Auto-accepted
├── libraries/                  # Server dependencies
└── server.properties           # Minecraft config
```

## Commands

```bash
# Start/Stop
./start.sh start
./start.sh stop
./start.sh restart

# Monitor
./start.sh status
./start.sh console          # tmux/screen: attach, nohup: tail log

# Custom RAM
JAVA_XMX=4G ./start.sh start

# Force specific backend
FORCE_BACKEND=nohup ./start.sh start
```

## Config (server.properties)

```bash
# View all properties
./start.sh config

# Read a property
./start.sh config server-port

# Set a property
./start.sh config server-port 25566
./start.sh config motd "My Cool Server"
./start.sh config difficulty hard
./start.sh config gamemode creative
./start.sh config max-players 20
./start.sh config online-mode false
```

Common keys:

| Key | Values | Default |
|-----|--------|---------|
| server-port | 1-65535 | 25565 |
| gamemode | survival/creative/adventure/spectator | survival |
| difficulty | peaceful/easy/normal/hard | normal |
| max-players | number | 20 |
| motd | text | A Minecraft Server |
| online-mode | true/false | true |
| pvp | true/false | true |
| level-seed | number/text | random |
| view-distance | 2-32 | 10 |
| simulation-distance | 2-32 | 10 |

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
```

Add one of:

```bash
# Every 4 hours
0 */4 * * * /root/paper-server/backup.sh auto

# Every hour
0 * * * * /root/paper-server/backup.sh auto

# Every 12 hours
0 */12 * * * /root/paper-server/backup.sh auto
```

## Systemd (auto-start on boot)

```bash
sudo cp minecraft-paper.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable minecraft-paper
sudo systemctl start minecraft-paper

# Status & logs
sudo systemctl status minecraft-paper
sudo journalctl -u minecraft-paper -f
```

## Backend Detection

`start.sh` auto-detects the best multiplexer:

1. **tmux** — preferred
2. **screen** — fallback
3. **nohup** — last resort, logs to `logs/console.log`

Force specific backend:
```bash
FORCE_BACKEND=tmux ./start.sh start
FORCE_BACKEND=screen ./start.sh start
FORCE_BACKEND=nohup ./start.sh start
```

## Updating

```bash
# Update setup script
curl -fsSL https://raw.githubusercontent.com/bianvigano/mc-server/main/setup.sh -o setup.sh
chmod +x setup.sh

# Update launcher/backup scripts
cd ~/paper-server
curl -fsSL https://raw.githubusercontent.com/bianvigano/mc-server/main/start.sh -o start.sh
curl -fsSL https://raw.githubusercontent.com/bianvigano/mc-server/main/backup.sh -o backup.sh
chmod +x start.sh backup.sh
```

## Requirements

- Java 17+
- curl, python3 (for setup script only)
- tmux or screen (optional, auto-detects)
- tar (for backup)

## How It Works

**Paper/Purpur:**
1. Queries official API for latest version + build
2. Downloads server jar directly
3. Accepts EULA
4. Generates start.sh, backup.sh, systemd service

**Fabric:**
1. Queries `meta.fabricmc.net` for latest stable loader + installer
2. Downloads installer jar from `maven.fabricmc.net`
3. Runs installer to download Minecraft server + Fabric
4. Accepts EULA
5. Generates start.sh, backup.sh, systemd service
6. Cleans up installer jar

## License

MIT
