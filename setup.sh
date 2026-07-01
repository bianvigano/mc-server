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
#  Interactive mode if --type not provided
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

# Set defaults
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
require_cmd() {
    for cmd in "$@"; do
        if ! command -v "$cmd" &>/dev/null; then
            echo "Error: $cmd not found. Install it first."
            exit 1
        fi
    done
}

accept_eula() {
    if [ -f "eula.txt" ]; then
        sed -i 's/eula=false/eula=true/' eula.txt
    else
        echo "eula=true" > eula.txt
    fi
}

detect_java() {
    if command -v java &>/dev/null; then
        JAVA_VER=$(java -version 2>&1 | head -1 | sed 's/.*"\([0-9]*\).*/\1/')
        echo "Java $JAVA_VER found"
    else
        echo "Error: Java not found. Install Java 17+ first."
        exit 1
    fi
}

# ═══════════════════════════════════════════════
#  Download: Paper
# ═══════════════════════════════════════════════
download_paper() {
    local API="https://fill.papermc.io/v3/projects/paper"

    # Resolve latest version if not set
    if [ -z "$MC_VERSION" ]; then
        echo "[1/4] Resolving latest Paper version..."
        MC_VERSION=$(curl -s -H "User-Agent: $USER_AGENT" "$API" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data[0] if isinstance(data, list) else data.get('versions', [data])[0])
" 2>/dev/null)
        if [ -z "$MC_VERSION" ]; then
            echo "Error: Failed to resolve latest Paper version"
            exit 1
        fi
    fi
    echo "  Version: $MC_VERSION"

    # Get builds
    echo "[2/4] Fetching Paper builds for $MC_VERSION..."
    local BUILDS_JSON
    BUILDS_JSON=$(curl -s -H "User-Agent: $USER_AGENT" "$API/versions/$MC_VERSION/builds")

    # Extract latest stable build
    local BUILD_URL
    BUILD_URL=$(echo "$BUILDS_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
builds = data.get('builds', data) if isinstance(data, dict) else data
# Filter stable builds
stable = [b for b in builds if b.get('channel') == 'STABLE' or 'STABLE' in str(b.get('channel', '')).upper()]
if not stable:
    stable = builds
latest = stable[-1] if isinstance(stable, list) else stable
build_num = latest.get('build', '?')
downloads = latest.get('downloads', {})
url = downloads.get('server:default', {}).get('url', '')
print(f'{build_num}|{url}')
" 2>/dev/null)

    local BUILD_NUM=$(echo "$BUILD_URL" | cut -d'|' -f1)
    local JAR_URL=$(echo "$BUILD_URL" | cut -d'|' -f2)

    if [ -z "$JAR_URL" ] || [ "$JAR_URL" = "" ]; then
        echo "Error: Failed to get Paper download URL"
        echo "  Response snippet: ${BUILDS_JSON:0:200}"
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

    # Resolve latest version if not set
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

    echo "[2/4] Fetching Purpur builds for $MC_VERSION..."

    # Download latest build directly
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

    # Resolve latest stable MC version if not set
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

    # Resolve loader version
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

    # Resolve installer version
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

    # Download installer jar
    local INSTALLER_JAR="fabric-installer-${FABRIC_INSTALLER}.jar"
    local INSTALLER_URL="https://maven.fabricmc.net/net/fabricmc/fabric-installer/${FABRIC_INSTALLER}/${INSTALLER_JAR}"

    echo "[4/6] Downloading Fabric installer..."
    mkdir -p "$INSTALL_DIR"
    curl -fsSL -o "$INSTALL_DIR/$INSTALLER_JAR" "$INSTALLER_URL"
    echo "  Saved: $INSTALL_DIR/$INSTALLER_JAR"

    # Install Fabric server
    echo "[5/6] Installing Fabric server..."
    cd "$INSTALL_DIR"
    java -jar "$INSTALLER_JAR" server \
        -mcversion "$MC_VERSION" \
        -loader "$FABRIC_LOADER" \
        -downloadMinecraft

    # Detect server jar
    SERVER_JAR=$(ls -1 fabric-server-*.jar 2>/dev/null | head -1)
    if [ -z "$SERVER_JAR" ]; then
        echo "Error: Fabric server jar not found after install"
        exit 1
    fi

    # Cleanup installer
    rm -f "$INSTALLER_JAR"

    # Mark as fabric install
    echo "fabric" > .mc-type
    echo "$MC_VERSION" > .mc-version
    echo "$FABRIC_LOADER" > .fabric-loader
    echo "$SERVER_JAR" > .server-jar
    echo "  Done: $SERVER_JAR"
}

# ═══════════════════════════════════════════════
#  Generate start.sh
# ═══════════════════════════════════════════════
generate_start_sh() {
    local TYPE_UPPER="${SERVER_TYPE^^}"
    local JAR_NAME="$1"
    local SESSION_NAME="minecraft-${SERVER_TYPE}"
    local ABS_DIR
    ABS_DIR=$(cd "$INSTALL_DIR" && pwd)

    cat > "$INSTALL_DIR/start.sh" << STARTEOF
#!/bin/bash
# Auto-generated start script for ${TYPE_UPPER} MC ${MC_VERSION}
# Usage: ./start.sh {start|stop|restart|status|console}
# Auto-detects: tmux > screen > nohup fallback

set -e

SESSION_NAME="${SESSION_NAME}"
JAVA_XMS="\${JAVA_XMS:-1G}"
JAVA_XMX="\${JAVA_XMX:-2G}"
JAVA_FLAGS="\${JAVA_FLAGS:--XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200}"
SERVER_JAR="${JAR_NAME}"
PID_FILE=".server.pid"

# Auto-port kill
get_port() {
    grep -E '^server-port=' server.properties 2>/dev/null | cut -d= -f2 || echo "25565"
}

auto_kill_port() {
    local PORT=\$(get_port)
    local PID
    PID=\$(lsof -ti :"\$PORT" 2>/dev/null || true)
    if [ -n "\$PID" ]; then
        echo "[!] Port \$PORT sudah dipakai. Killing: \$PID"
        kill "\$PID" 2>/dev/null || true
        sleep 2
    fi
}

# Detect available multiplexer
detect_backend() {
    if command -v tmux &>/dev/null && tmux new-session -d -s _test_backend 2>/dev/null; then
        tmux kill-session -t _test_backend 2>/dev/null
        echo "tmux"
    elif command -v screen &>/dev/null && screen -dmS _test_backend 2>/dev/null; then
        screen -S _test_backend -X quit 2>/dev/null
        echo "screen"
    else
        echo "nohup"
    fi
}

BACKEND="\${FORCE_BACKEND:-\$(detect_backend)}"

is_running() {
    case "\$BACKEND" in
        tmux)   tmux has-session -t "\$SESSION_NAME" 2>/dev/null ;;
        screen) screen -list 2>/dev/null | grep -q "\$SESSION_NAME" ;;
        nohup)  [ -f "\$PID_FILE" ] && kill -0 "\$(cat "\$PID_FILE")" 2>/dev/null ;;
    esac
}

do_start() {
    if is_running; then
        echo "[*] Server sudah jalan (\$BACKEND: \$SESSION_NAME)"
        return
    fi

    auto_kill_port

    echo "[*] Starting ${TYPE_UPPER} server (MC ${MC_VERSION})..."
    echo "    RAM: \$JAVA_XMS - \$JAVA_XMX"
    echo "    Backend: \$BACKEND"

    case "\$BACKEND" in
        tmux)
            tmux new-session -d -s "\$SESSION_NAME" "cd ${ABS_DIR} && java \$JAVA_FLAGS -Xms\$JAVA_XMS -Xmx\$JAVA_XMX -jar \$SERVER_JAR nogui"
            echo "    Attach: tmux attach -t \$SESSION_NAME"
            echo "    Detach: Ctrl+B, D"
            ;;
        screen)
            cd "${ABS_DIR}"
            screen -dmS "\$SESSION_NAME" java \$JAVA_FLAGS -Xms"\$JAVA_XMS" -Xmx"\$JAVA_XMX" -jar "\$SERVER_JAR" nogui
            echo "    Attach: screen -r \$SESSION_NAME"
            echo "    Detach: Ctrl+A, D"
            ;;
        nohup)
            mkdir -p logs
            cd "${ABS_DIR}"
            nohup java \$JAVA_FLAGS -Xms"\$JAVA_XMS" -Xmx"\$JAVA_XMX" -jar "\$SERVER_JAR" nogui > logs/console.log 2>&1 &
            echo \$! > "\$PID_FILE"
            echo "    Log: tail -f logs/console.log"
            ;;
    esac

    sleep 3
    if is_running; then
        echo "[*] Server started successfully."
    else
        echo "[ERROR] Server gagal start. Cek log."
        exit 1
    fi
}

do_stop() {
    if ! is_running; then
        echo "[*] Server tidak jalan."
        rm -f "\$PID_FILE"
        return
    fi
    echo "[*] Stopping server..."

    case "\$BACKEND" in
        tmux)
            tmux send-keys -t "\$SESSION_NAME" "save-all" Enter
            sleep 2
            tmux send-keys -t "\$SESSION_NAME" "stop" Enter
            ;;
        screen)
            screen -S "\$SESSION_NAME" -p 0 -X stuff "save-all^M"
            sleep 2
            screen -S "\$SESSION_NAME" -p 0 -X stuff "stop^M"
            ;;
        nohup)
            if [ -f "\$PID_FILE" ]; then
                kill "\$(cat "\$PID_FILE")" 2>/dev/null || true
            fi
            ;;
    esac

    for i in \$(seq 1 30); do
        if ! is_running; then
            echo "[*] Server stopped."
            rm -f "\$PID_FILE"
            return
        fi
        sleep 1
    done

    echo "[WARN] Force killing..."
    case "\$BACKEND" in
        tmux)   tmux kill-session -t "\$SESSION_NAME" 2>/dev/null || true ;;
        screen) screen -S "\$SESSION_NAME" -X quit 2>/dev/null || true ;;
        nohup)  kill -9 "\$(cat "\$PID_FILE")" 2>/dev/null || true ;;
    esac
    rm -f "\$PID_FILE"
}

do_status() {
    if is_running; then
        echo "[*] Server status: RUNNING (\$BACKEND: \$SESSION_NAME)"
    else
        echo "[*] Server status: STOPPED"
    fi
}

do_console() {
    if ! is_running; then
        echo "[*] Server tidak jalan."
        exit 1
    fi
    case "\$BACKEND" in
        tmux)
            echo "[*] Attaching (Ctrl+B, D to detach)..."
            sleep 1
            tmux attach -t "\$SESSION_NAME"
            ;;
        screen)
            echo "[*] Attaching (Ctrl+A, D to detach)..."
            sleep 1
            screen -r "\$SESSION_NAME"
            ;;
        nohup)
            echo "[*] Tailing console log (Ctrl+C to stop tailing)..."
            tail -f logs/console.log
            ;;
    esac
}

case "\${1}" in
    start)          do_start ;;
    stop)           do_stop ;;
    restart)        do_stop; sleep 2; do_start ;;
    status)         do_status ;;
    console|attach) do_console ;;
    *)
        echo "Usage: \$0 {start|stop|restart|status|console}"
        echo ""
        echo "Env vars:"
        echo "  JAVA_XMS       Min RAM  (default: 1G)"
        echo "  JAVA_XMX       Max RAM  (default: 2G)"
        echo "  JAVA_FLAGS     JVM flags (default: G1GC tuning)"
        echo "  FORCE_BACKEND  tmux|screen|nohup (auto-detected)"
        echo ""
        echo "Examples:"
        echo "  ./start.sh start"
        echo "  JAVA_XMX=4G ./start.sh start"
        echo "  FORCE_BACKEND=nohup ./start.sh start"
        ;;
esac
STARTEOF
    chmod +x "$INSTALL_DIR/start.sh"
}

# ═══════════════════════════════════════════════
#  Generate backup.sh
# ═══════════════════════════════════════════════
generate_backup_sh() {
    local TYPE_UPPER="${SERVER_TYPE^^}"
    local SESSION_NAME="minecraft-${SERVER_TYPE}"
    local ABS_DIR
    ABS_DIR=$(cd "$INSTALL_DIR" && pwd)

    cat > "$INSTALL_DIR/backup.sh" << BACKEOF
#!/bin/bash
# Auto-generated backup script for ${TYPE_UPPER} MC ${MC_VERSION}
# Usage: ./backup.sh [label]
# Or add to crontab: 0 */4 * * * /path/to/backup.sh auto

set -e

SERVER_DIR="${ABS_DIR}"
BACKUP_DIR="\$(dirname "\$SERVER_DIR")/minecraft-backups"
TIMESTAMP=\$(date +%Y%m%d_%H%M%S)
LABEL="\${1:-manual}"
BACKUP_NAME="${SERVER_TYPE}-mc${MC_VERSION}-\${LABEL}-\${TIMESTAMP}"
MAX_BACKUPS="\${MAX_BACKUPS:-24}"
SESSION_NAME="${SESSION_NAME}"

mkdir -p "\$BACKUP_DIR"

echo "[*] Starting backup: \$BACKUP_NAME"
echo "    From: \$SERVER_DIR"
echo "    To:   \$BACKUP_DIR"

# Tell server to save
save_freeze() {
    if command -v tmux &>/dev/null && tmux has-session -t "\$SESSION_NAME" 2>/dev/null; then
        tmux send-keys -t "\$SESSION_NAME" "say [Backup] Starting backup..." Enter
        tmux send-keys -t "\$SESSION_NAME" "save-all" Enter
        sleep 5
        tmux send-keys -t "\$SESSION_NAME" "save-off" Enter
        sleep 3
    elif screen -list 2>/dev/null | grep -q "\$SESSION_NAME"; then
        screen -S "\$SESSION_NAME" -p 0 -X stuff "say [Backup] Starting backup...^M"
        screen -S "\$SESSION_NAME" -p 0 -X stuff "save-all^M"
        sleep 5
        screen -S "\$SESSION_NAME" -p 0 -X stuff "save-off^M"
        sleep 3
    fi
}

save_unfreeze() {
    if command -v tmux &>/dev/null && tmux has-session -t "\$SESSION_NAME" 2>/dev/null; then
        tmux send-keys -t "\$SESSION_NAME" "save-on" Enter
        tmux send-keys -t "\$SESSION_NAME" "say [Backup] Done!" Enter
    elif screen -list 2>/dev/null | grep -q "\$SESSION_NAME"; then
        screen -S "\$SESSION_NAME" -p 0 -X stuff "save-on^M"
        screen -S "\$SESSION_NAME" -p 0 -X stuff "say [Backup] Done!^M"
    fi
}

save_freeze

# Create tar.gz
cd "\$SERVER_DIR"
tar czf "\$BACKUP_DIR/\${BACKUP_NAME}.tar.gz" \\
    --exclude='libraries' \\
    --exclude='*.jar' \\
    --exclude='logs' \\
    --exclude='crash-reports' \\
    --exclude='world/session.lock' \\
    .

save_unfreeze

# Cleanup old backups
if [ -d "\$BACKUP_DIR" ]; then
    BACKUP_COUNT=\$(ls -1 "\$BACKUP_DIR"/*.tar.gz 2>/dev/null | wc -l)
    if [ "\$BACKUP_COUNT" -gt "\$MAX_BACKUPS" ]; then
        ls -1t "\$BACKUP_DIR"/*.tar.gz | tail -n +\$((MAX_BACKUPS + 1)) | xargs rm -f
        echo "  Cleaned old backups (keeping last \$MAX_BACKUPS)"
    fi
fi

echo "[*] Backup complete: \$BACKUP_DIR/\${BACKUP_NAME}.tar.gz"
echo "  Size: \$(du -h "\$BACKUP_DIR/\${BACKUP_NAME}.tar.gz" | cut -f1)"
BACKEOF
    chmod +x "$INSTALL_DIR/backup.sh"
}

# ═══════════════════════════════════════════════
#  Generate systemd service
# ═══════════════════════════════════════════════
generate_systemd() {
    local TYPE_UPPER="${SERVER_TYPE^^}"
    local SESSION_NAME="minecraft-${SERVER_TYPE}"
    local SERVICE_NAME="minecraft-${SERVER_TYPE}"
    local ABS_DIR
    ABS_DIR=$(cd "$INSTALL_DIR" && pwd)

    # Detect if screen is available for ExecStart
    local EXEC_START
    if command -v screen &>/dev/null; then
        EXEC_START="/usr/bin/screen -dmS ${SESSION_NAME} java -Xms1G -Xmx2G -XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 -jar ${ABS_DIR}/${SERVER_JAR} nogui"
    else
        EXEC_START="/bin/bash -c 'cd ${ABS_DIR} && nohup java -Xms1G -Xmx2G -XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 -jar ${SERVER_JAR} nogui > logs/console.log 2>&1 & echo \\$! > .server.pid'"
    fi

    cat > "$INSTALL_DIR/${SERVICE_NAME}.service" << SERVICEEOF
[Unit]
Description=${TYPE_UPPER} Minecraft Server (MC ${MC_VERSION})
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
SERVICEEOF

    echo "  Systemd service: ${SERVICE_NAME}.service"
}

# ═══════════════════════════════════════════════
#  Main flow
# ═══════════════════════════════════════════════
cd /tmp

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

# Accept EULA (for paper/purpur)
cd "$INSTALL_DIR"
accept_eula

# Save metadata
echo "$SERVER_TYPE" > .mc-type
echo "$MC_VERSION" > .mc-version
echo "$SERVER_JAR" > .server-jar

# Generate universal scripts
cd "$INSTALL_DIR"
generate_start_sh "$SERVER_JAR"
generate_backup_sh
generate_systemd

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
