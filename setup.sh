#!/bin/bash
# mc-server setup — All-in-one Minecraft server setup
# Supports: fabric, paper, purpur
# Usage: ./setup.sh --type paper --version 1.21.4
#        ./setup.sh --type fabric
#        ./setup.sh --type purpur --version 1.21.4
#        ./setup.sh (interactive)

set -e

# ═══════════════════════════════════════════════
#  Defaults
# ═══════════════════════════════════════════════
SERVER_TYPE=""
MC_VERSION=""
INSTALL_DIR=""
PAPER_BUILD=""
FABRIC_LOADER=""
FABRIC_INSTALLER=""
SETUP_DIR="$(cd "$(dirname "$0")" && pwd)"
USER_AGENT="mc-server/1.0 (https://github.com/bianvigano/mc-server)"

# ═══════════════════════════════════════════════
#  Parse args
# ═══════════════════════════════════════════════
while [[ $# -gt 0 ]]; do
    case "$1" in
        --type)       SERVER_TYPE="$2"; shift 2 ;;
        --version)    MC_VERSION="$2";  shift 2 ;;
        --dir)        INSTALL_DIR="$2"; shift 2 ;;
        --build)      PAPER_BUILD="$2"; shift 2 ;;
        --fabric-loader)    FABRIC_LOADER="$2";    shift 2 ;;
        --fabric-installer) FABRIC_INSTALLER="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --type TYPE       Server type: fabric, paper, purpur (required)"
            echo "  --version VER     Minecraft version (default: latest)"
            echo "  --dir DIR         Install directory (default: ./<type>-server)"
            echo "  --build NUM       Paper: specific build number"
            echo "  --fabric-loader   Fabric: specific loader version"
            echo "  --fabric-installer Fabric: specific installer version"
            echo ""
            echo "Examples:"
            echo "  $0 --type paper"
            echo "  $0 --type paper --version 1.21.4"
            echo "  $0 --type fabric --version 1.21.4"
            echo "  $0 --type purpur --version 1.21.4"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ═══════════════════════════════════════════════
#  Interactive mode
# ═══════════════════════════════════════════════
if [ -z "$SERVER_TYPE" ]; then
    echo "========================================"
    echo "  MC Server Setup"
    echo "========================================"
    echo ""
    echo "Pilih server type:"
    echo "  1) Paper    — Performance + Bukkit/Spigot plugin support"
    echo "  2) Purpur   — Paper + extra configurability"
    echo "  3) Fabric   — Mod loader (mods, not plugins)"
    echo ""
    read -rp "Pilih [1/2/3]: " choice
    case "$choice" in
        1) SERVER_TYPE="paper" ;;
        2) SERVER_TYPE="purpur" ;;
        3) SERVER_TYPE="fabric" ;;
        *) echo "Invalid choice"; exit 1 ;;
    esac
fi

# Validate type
case "$SERVER_TYPE" in
    paper|purpur|fabric) ;;
    *) echo "Error: --type must be paper, purpur, or fabric"; exit 1 ;;
esac

INSTALL_DIR="${INSTALL_DIR:-./${SERVER_TYPE}-server}"

echo ""
echo "========================================"
echo "  MC Server Setup — ${SERVER_TYPE^^}"
echo "========================================"
echo "Type:    $SERVER_TYPE"
echo "Dir:     $INSTALL_DIR"
echo ""

# ═══════════════════════════════════════════════
#  Shared functions
# ═══════════════════════════════════════════════
detect_java() {
    if command -v java &>/dev/null; then
        JAVA_VER=$(java -version 2>&1 | head -1 | sed 's/.*"\([0-9]*\).*/\1/')
        echo "Java $JAVA_VER found"
    else
        echo "Error: Java not found. Install Java 17+ first."
        exit 1
    fi
}

accept_eula() {
    if [ -f "eula.txt" ]; then
        sed -i 's/eula=false/eula=true/' eula.txt
    else
        echo "eula=true" > eula.txt
    fi
}

# ═══════════════════════════════════════════════
#  Download: Paper
# ═══════════════════════════════════════════════
download_paper() {
    local API="https://fill.papermc.io/v3/projects/paper"

    if [ -z "$MC_VERSION" ]; then
        echo "[1/4] Resolving latest Paper version..."
        MC_VERSION=$(curl -s -H "User-Agent: $USER_AGENT" "$API" | python3 -c "
import sys, json
data = json.load(sys.stdin)
versions = data.get('versions', {})
keys = list(versions.keys())
print(keys[0])
" 2>/dev/null)
        if [ -z "$MC_VERSION" ]; then
            echo "Error: Failed to resolve latest Paper version"
            exit 1
        fi
    fi
    echo "  Version: $MC_VERSION"

    echo "[2/4] Fetching Paper builds for $MC_VERSION..."
    local BUILDS_JSON
    BUILDS_JSON=$(curl -s -H "User-Agent: $USER_AGENT" "$API/versions/$MC_VERSION/builds")

    local BUILD_URL
    BUILD_URL=$(echo "$BUILDS_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
builds = data.get('builds', data) if isinstance(data, dict) else data
if isinstance(builds, dict):
    builds = builds.get('builds', [])
stable = [b for b in builds if str(b.get('channel', '')).upper() == 'STABLE']
if not stable:
    stable = builds
latest = stable[-1] if isinstance(stable, list) and stable else builds[-1]
build_num = latest.get('build', '?')
downloads = latest.get('downloads', {})
url = downloads.get('server:default', {}).get('url', '')
print(f'{build_num}|{url}')
" 2>/dev/null)

    local BUILD_NUM=$(echo "$BUILD_URL" | cut -d'|' -f1)
    local JAR_URL=$(echo "$BUILD_URL" | cut -d'|' -f2)

    if [ -z "$JAR_URL" ] || [ "$JAR_URL" = "" ]; then
        echo "Error: Failed to get Paper download URL"
        exit 1
    fi

    echo "  Build: $BUILD_NUM"
    echo "[3/4] Downloading Paper $MC_VERSION build $BUILD_NUM..."

    mkdir -p "$INSTALL_DIR"
    curl -fsSL -H "User-Agent: $USER_AGENT" -o "$INSTALL_DIR/paper.jar" "$JAR_URL"
    echo "  Saved: $INSTALL_DIR/paper.jar"
}

# ═══════════════════════════════════════════════
#  Download: Purpur
# ═══════════════════════════════════════════════
download_purpur() {
    local API="https://api.purpurmc.org/v2/purpur"

    if [ -z "$MC_VERSION" ]; then
        echo "[1/4] Resolving latest Purpur version..."
        MC_VERSION=$(curl -s "$API" | python3 -c "
import sys, json
data = json.load(sys.stdin)
versions = data.get('versions', data) if isinstance(data, dict) else data
print(versions[0] if isinstance(versions, list) else versions)
" 2>/dev/null)
        if [ -z "$MC_VERSION" ]; then
            echo "Error: Failed to resolve latest Purpur version"
            exit 1
        fi
    fi
    echo "  Version: $MC_VERSION"

    echo "[3/4] Downloading Purpur $MC_VERSION (latest build)..."
    mkdir -p "$INSTALL_DIR"
    curl -fsSL -o "$INSTALL_DIR/purpur.jar" "$API/$MC_VERSION/latest/download"
    echo "  Saved: $INSTALL_DIR/purpur.jar"
}

# ═══════════════════════════════════════════════
#  Download: Fabric
# ═══════════════════════════════════════════════
download_fabric() {
    local META="https://meta.fabricmc.net/v2"

    if [ -z "$MC_VERSION" ]; then
        echo "[1/6] Resolving latest Minecraft version..."
        MC_VERSION=$(curl -s "$META/versions/game" | python3 -c "
import sys, json
data = json.load(sys.stdin)
stable = [x for x in data if x.get('stable')]
print(stable[0]['version'] if stable else data[-1]['version'])
" 2>/dev/null)
    fi
    echo "  MC Version: $MC_VERSION"

    if [ -z "$FABRIC_LOADER" ]; then
        echo "[2/6] Resolving latest Fabric loader..."
        FABRIC_LOADER=$(curl -s "$META/versions/loader" | python3 -c "
import sys, json
data = json.load(sys.stdin)
stable = [x for x in data if x.get('stable')]
print(stable[0]['version'] if stable else data[0]['version'])
" 2>/dev/null)
    fi
    echo "  Loader: $FABRIC_LOADER"

    if [ -z "$FABRIC_INSTALLER" ]; then
        echo "[3/6] Resolving latest Fabric installer..."
        FABRIC_INSTALLER=$(curl -s "$META/versions/installer" | python3 -c "
import sys, json
data = json.load(sys.stdin)
stable = [x for x in data if x.get('stable')]
print(stable[0]['version'] if stable else data[0]['version'])
" 2>/dev/null)
    fi
    echo "  Installer: $FABRIC_INSTALLER"

    local INSTALLER_JAR="fabric-installer-${FABRIC_INSTALLER}.jar"
    local INSTALLER_URL="https://maven.fabricmc.net/net/fabricmc/fabric-installer/${FABRIC_INSTALLER}/${INSTALLER_JAR}"

    echo "[4/6] Downloading Fabric installer..."
    mkdir -p "$INSTALL_DIR"
    curl -fsSL -o "$INSTALL_DIR/$INSTALLER_JAR" "$INSTALLER_URL"

    echo "[5/6] Installing Fabric server..."
    cd "$INSTALL_DIR"
    java -jar "$INSTALLER_JAR" server \
        -mcversion "$MC_VERSION" \
        -loader "$FABRIC_LOADER" \
        -downloadMinecraft

    SERVER_JAR=$(ls -1 fabric-server-*.jar 2>/dev/null | head -1)
    if [ -z "$SERVER_JAR" ]; then
        echo "Error: Fabric server jar not found after install"
        exit 1
    fi

    rm -f "$INSTALLER_JAR"
    echo "$SERVER_JAR" > .server-jar
    echo "  Done: $SERVER_JAR"
}

# ═══════════════════════════════════════════════
#  Copy scripts to install dir
# ═══════════════════════════════════════════════
copy_scripts() {
    for f in start.sh backup.sh plugins.sh update.sh; do
        if [ -f "$SETUP_DIR/$f" ]; then
            cp "$SETUP_DIR/$f" "$INSTALL_DIR/$f"
            chmod +x "$INSTALL_DIR/$f"
        fi
    done
}

# ═══════════════════════════════════════════════
#  Generate systemd service
# ═══════════════════════════════════════════════
generate_systemd() {
    local SERVICE_NAME="minecraft-${SERVER_TYPE}"
    local SESSION_NAME="minecraft-${SERVER_TYPE}"
    local ABS_DIR
    ABS_DIR=$(cd "$INSTALL_DIR" && pwd)

    local EXEC_START
    if command -v screen &>/dev/null; then
        EXEC_START="/usr/bin/screen -dmS ${SESSION_NAME} java -Xms1G -Xmx2G -XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 -jar ${ABS_DIR}/${SERVER_JAR} nogui"
    else
        EXEC_START="/bin/bash -c 'cd ${ABS_DIR} && nohup java -Xms1G -Xmx2G -jar ${SERVER_JAR} nogui > logs/console.log 2>&1 & echo \$! > .server.pid'"
    fi

    cat > "$INSTALL_DIR/${SERVICE_NAME}.service" << EOF
[Unit]
Description=${SERVER_TYPE^^} Minecraft Server (MC ${MC_VERSION})
After=network.target
StartLimitIntervalSec=600
StartLimitBurst=3

[Service]
Type=forking
User=$(whoami)
Group=$(id -gn)
WorkingDirectory=${ABS_DIR}
ExecStart=${EXEC_START}
ExecStop=/bin/bash -c 'cd ${ABS_DIR} && ./start.sh stop'
Restart=on-failure
RestartSec=30
StandardOutput=append:${ABS_DIR}/logs/systemd.log
StandardError=append:${ABS_DIR}/logs/systemd.log

[Install]
WantedBy=multi-user.target
EOF

    echo "  Systemd: ${SERVICE_NAME}.service"
}

# ═══════════════════════════════════════════════
#  Main flow
# ═══════════════════════════════════════════════
detect_java

case "$SERVER_TYPE" in
    paper)
        download_paper
        SERVER_JAR="paper.jar"
        ;;
    purpur)
        download_purpur
        SERVER_JAR="purpur.jar"
        ;;
    fabric)
        download_fabric
        SERVER_JAR=$(cat "$INSTALL_DIR/.server-jar" 2>/dev/null || echo "")
        ;;
esac

# Accept EULA
cd "$INSTALL_DIR"
accept_eula

# Save metadata
echo "$SERVER_TYPE" > .mc-type
echo "$MC_VERSION" > .mc-version
echo "$SERVER_JAR" > .server-jar

# Copy standalone scripts + generate systemd
copy_scripts
generate_systemd

# Summary
echo ""
echo "========================================"
echo "  Setup Complete!"
echo "========================================"
echo ""
echo "Server:  $SERVER_TYPE ($MC_VERSION)"
echo "Dir:     $INSTALL_DIR/"
echo "Jar:     $SERVER_JAR"
echo ""
echo "Commands:"
echo "  cd $INSTALL_DIR"
echo "  ./start.sh start           # Start server"
echo "  ./start.sh stop            # Stop server"
echo "  ./start.sh console         # Attach console"
echo "  ./backup.sh                # Manual backup"
echo "  JAVA_XMX=4G ./start.sh start  # Custom RAM"
echo ""
echo "Systemd (auto-start on boot):"
echo "  sudo cp $INSTALL_DIR/minecraft-${SERVER_TYPE}.service /etc/systemd/system/"
echo "  sudo systemctl daemon-reload"
echo "  sudo systemctl enable minecraft-${SERVER_TYPE}"
echo "  sudo systemctl start minecraft-${SERVER_TYPE}"
echo ""
echo "Auto backup (cron):"
echo "  crontab -e"
echo "  0 */4 * * * $INSTALL_DIR/backup.sh auto"
echo ""
echo "All set! Happy crafting."
