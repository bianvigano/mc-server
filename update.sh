#!/bin/bash
# update.sh — Update MC server jar without touching world/config/plugins
# Usage: ./update.sh [--version 1.21.4]
#
# Supports: paper, purpur, fabric
# Auto-detects type from .mc-type file

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

USER_AGENT="mc-server/1.0 (https://github.com/bianvigano/mc-server)"

# ═══════════════════════════════════════════
#  Detect current setup
# ═══════════════════════════════════════════
if [ -f ".mc-type" ]; then
    SERVER_TYPE="$(cat .mc-type)"
else
    echo "[ERROR] .mc-type not found. Run setup.sh first."
    exit 1
fi

if [ -f ".mc-version" ]; then
    CURRENT_VERSION="$(cat .mc-version)"
else
    CURRENT_VERSION="unknown"
fi

if [ -f ".server-jar" ]; then
    SERVER_JAR="$(cat .server-jar)"
else
    SERVER_JAR="$(ls -1 paper.jar purpur.jar fabric-server-*.jar 2>/dev/null | head -1)"
fi

# Parse args
NEW_VERSION=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version|-v) NEW_VERSION="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [--version VERSION]"
            echo ""
            echo "Options:"
            echo "  --version VER  Target MC version (default: latest)"
            echo ""
            echo "Current: $SERVER_TYPE $CURRENT_VERSION ($SERVER_JAR)"
            exit 0
            ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

echo "========================================"
echo "  MC Server Update"
echo "========================================"
echo "Type:    $SERVER_TYPE"
echo "Current: $CURRENT_VERSION"
echo "Jar:     $SERVER_JAR"
echo ""

# Check if server is running
is_running() {
    if [ -f ".server.pid" ] && kill -0 "$(cat .server.pid)" 2>/dev/null; then
        return 0
    elif tmux has-session -t "${SESSION_NAME:-minecraft}" 2>/dev/null; then
        return 0
    elif screen -list 2>/dev/null | grep -q "${SESSION_NAME:-minecraft}"; then
        return 0
    fi
    return 1
}

if is_running; then
    echo "[!] Server sedang jalan. Stop dulu!"
    echo "    ./start.sh stop"
    exit 1
fi

# Backup current jar
if [ -n "$SERVER_JAR" ] && [ -f "$SERVER_JAR" ]; then
    BACKUP_NAME="${SERVER_JAR}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$SERVER_JAR" "$BACKUP_NAME"
    echo "[*] Backed up current jar: $BACKUP_NAME"
fi

# ═══════════════════════════════════════════
#  Update per type
# ═══════════════════════════════════════════
update_paper() {
    local API="https://fill.papermc.io/v3/projects/paper"
    local TARGET_VER="${NEW_VERSION:-$CURRENT_VERSION}"

    echo "[*] Fetching Paper builds for $TARGET_VER..."
    local BUILDS_JSON
    BUILDS_JSON=$(curl -s -H "User-Agent: $USER_AGENT" "$API/versions/$TARGET_VER/builds")

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
latest = stable[-1] if stable else builds[-1]
build_num = latest.get('build', '?')
downloads = latest.get('downloads', {})
url = downloads.get('server:default', {}).get('url', '')
print(f'{build_num}|{url}')
" 2>/dev/null)

    local BUILD_NUM=$(echo "$BUILD_URL" | cut -d'|' -f1)
    local JAR_URL=$(echo "$BUILD_URL" | cut -d'|' -f2)

    if [ -z "$JAR_URL" ]; then
        echo "[ERROR] Failed to get Paper download URL"
        exit 1
    fi

    echo "[*] Downloading Paper build $BUILD_NUM..."
    curl -fsSL -H "User-Agent: $USER_AGENT" -o "paper.jar" "$JAR_URL"
    echo "$TARGET_VER" > .mc-version
    echo "[OK] Paper updated to build $BUILD_NUM"
}

update_purpur() {
    local API="https://api.purpurmc.org/v2/purpur"
    local TARGET_VER="${NEW_VERSION:-$CURRENT_VERSION}"

    echo "[*] Downloading Purpur $TARGET_VER (latest build)..."
    curl -fsSL -o "purpur.jar" "$API/$TARGET_VER/latest/download"
    echo "$TARGET_VER" > .mc-version
    echo "[OK] Purpur updated"
}

update_fabric() {
    local META="https://meta.fabricmc.net/v2"
    local TARGET_VER="${NEW_VERSION:-$CURRENT_VERSION}"

    # Get latest loader
    echo "[*] Fetching latest Fabric loader..."
    local LOADER_VERSION
    LOADER_VERSION=$(curl -s "$META/versions/loader" | python3 -c "
import sys, json
data = json.load(sys.stdin)
stable = [x for x in data if x.get('stable')]
print(stable[0]['version'] if stable else data[0]['version'])
" 2>/dev/null)

    # Get latest installer
    local INSTALLER_VERSION
    INSTALLER_VERSION=$(curl -s "$META/versions/installer" | python3 -c "
import sys, json
data = json.load(sys.stdin)
stable = [x for x in data if x.get('stable')]
print(stable[0]['version'] if stable else data[0]['version'])
" 2>/dev/null)

    echo "[*] Installing Fabric server..."
    local INSTALLER_JAR="fabric-installer-${INSTALLER_VERSION}.jar"
    curl -fsSL -o "$INSTALLER_JAR" \
        "https://maven.fabricmc.net/net/fabricmc/fabric-installer/${INSTALLER_VERSION}/${INSTALLER_JAR}"

    java -jar "$INSTALLER_JAR" server \
        -mcversion "$TARGET_VER" \
        -loader "$LOADER_VERSION" \
        -downloadMinecraft

    rm -f "$INSTALLER_JAR"

    # Update jar reference
    local NEW_JAR
    NEW_JAR=$(ls -1t fabric-server-*.jar 2>/dev/null | head -1)
    if [ -n "$NEW_JAR" ]; then
        echo "$NEW_JAR" > .server-jar
        echo "$TARGET_VER" > .mc-version
        echo "$LOADER_VERSION" > .fabric-loader
        echo "[OK] Fabric updated: $NEW_JAR"
    else
        echo "[ERROR] Fabric jar not found after update"
        exit 1
    fi
}

case "$SERVER_TYPE" in
    paper)  update_paper ;;
    purpur) update_purpur ;;
    fabric) update_fabric ;;
    *)      echo "[ERROR] Unknown type: $SERVER_TYPE"; exit 1 ;;
esac

# Cleanup old jar backups (keep last 3)
ls -1t *.bak.* 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null

echo ""
echo "========================================"
echo "  Update Complete!"
echo "========================================"
echo "Type: $SERVER_TYPE"
echo "Version: $(cat .mc-version 2>/dev/null || echo '?')"
echo ""
echo "  ./start.sh start"
echo ""
echo "All set! Happy crafting."
