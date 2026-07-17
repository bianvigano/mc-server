#!/bin/bash
# update.sh — Update MC server jar without touching world/config/plugins
# Usage: ./update.sh [--version 1.21.4]
#
# Supports: paper, purpur, fabric, forge, neoforge, quilt
# Auto-detects type from .mc-info file

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

USER_AGENT="mc-server/1.0 (https://github.com/bianvigano/mc-server)"

# ═══════════════════════════════════════════
#  Detect current setup
# ═══════════════════════════════════════════
if [ -f ".mc-info" ]; then
    SERVER_TYPE="$(grep '^type=' .mc-info | cut -d= -f2)"
    CURRENT_VERSION="$(grep '^version=' .mc-info | cut -d= -f2)"
    SERVER_JAR="$(grep '^jar=' .mc-info | cut -d= -f2)"
else
    echo "[ERROR] .mc-info not found. Run setup.sh first."
    exit 1
fi
SERVER_JAR="${SERVER_JAR:-$(ls -1 mc-launch.sh quilt-server-launch.jar paper.jar purpur.jar craftbukkit.jar spigot.jar fabric-server-*.jar 2>/dev/null | head -1)}"

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

mcinfo_set() {
    local KEY="$1"
    shift
    local VALUE="$*"
    local TMP_FILE
    TMP_FILE="$(mktemp)"

    if [ -f ".mc-info" ]; then
        awk -F= -v key="$KEY" -v value="$VALUE" '
            BEGIN { updated = 0 }
            $1 == key {
                print key "=" value
                updated = 1
                next
            }
            { print }
            END {
                if (!updated) {
                    print key "=" value
                }
            }
        ' ".mc-info" > "$TMP_FILE"
    else
        printf "%s=%s\n" "$KEY" "$VALUE" > "$TMP_FILE"
    fi

    mv "$TMP_FILE" ".mc-info"
}

create_modloader_wrapper() {
    local UNIX_ARGS_FILE
    UNIX_ARGS_FILE=$(find "$SCRIPT_DIR/libraries" -type f -name "unix_args.txt" 2>/dev/null | sort | tail -1)
    if [ -z "$UNIX_ARGS_FILE" ]; then
        echo "[ERROR] Failed to locate unix_args.txt in $SCRIPT_DIR/libraries"
        exit 1
    fi

    local RELATIVE_UNIX_ARGS="./${UNIX_ARGS_FILE#$SCRIPT_DIR/}"

    cat > "$SCRIPT_DIR/mc-launch.sh" << EOF
#!/bin/bash
set -e
SCRIPT_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
cd "\$SCRIPT_DIR"

JAVA_BIN="\${JAVA_BIN:-java}"
TMP_ARGS_FILE="\$SCRIPT_DIR/.mc-jvm-args.tmp"
trap 'rm -f "\$TMP_ARGS_FILE"' EXIT
: > "\$TMP_ARGS_FILE"

if [ -n "\${MC_JAVA_XMS:-}" ]; then
    echo "-Xms\${MC_JAVA_XMS}" >> "\$TMP_ARGS_FILE"
fi

if [ -n "\${MC_JAVA_XMX:-}" ]; then
    echo "-Xmx\${MC_JAVA_XMX}" >> "\$TMP_ARGS_FILE"
fi

if [ -n "\${MC_JAVA_FLAGS:-}" ]; then
    MC_JAVA_FLAGS="\$MC_JAVA_FLAGS" python3 - "\$TMP_ARGS_FILE" << 'PY'
import os
import shlex
import sys

flags = os.environ.get("MC_JAVA_FLAGS", "")
with open(sys.argv[1], "a", encoding="utf-8") as fh:
    for item in shlex.split(flags):
        fh.write(item + "\\n")
PY
fi

if [ "\$#" -eq 0 ]; then
    set -- nogui
fi

if [ -f "./user_jvm_args.txt" ]; then
    exec "\$JAVA_BIN" @"\$TMP_ARGS_FILE" @./user_jvm_args.txt @"$RELATIVE_UNIX_ARGS" "\$@"
else
    exec "\$JAVA_BIN" @"\$TMP_ARGS_FILE" @"$RELATIVE_UNIX_ARGS" "\$@"
fi
EOF

    chmod +x "$SCRIPT_DIR/mc-launch.sh"
}

resolve_latest_stable_game_version() {
    curl -s "https://meta.fabricmc.net/v2/versions/game" | python3 -c "
import sys, json
data = json.load(sys.stdin)
stable = [x for x in data if x.get('stable')]
print(stable[0]['version'] if stable else data[0]['version'])
" 2>/dev/null
}

derive_neoforge_mc_version() {
    python3 - "$1" << 'PY'
import sys

value = sys.argv[1].split('-', 1)[0]
parts = value.split('.')
if parts and parts[0] in {'20', '21'} and len(parts) >= 2:
    print(f"1.{parts[0]}.{parts[1]}")
elif len(parts) >= 2:
    print('.'.join(parts[:-1]))
else:
    print(value)
PY
}

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
    mcinfo_set version "$TARGET_VER"
    mcinfo_set jar "paper.jar"
    SERVER_JAR="paper.jar"
    echo "[OK] Paper updated to build $BUILD_NUM"
}

update_purpur() {
    local API="https://api.purpurmc.org/v2/purpur"
    local TARGET_VER="${NEW_VERSION:-$CURRENT_VERSION}"

    echo "[*] Downloading Purpur $TARGET_VER (latest build)..."
    curl -fsSL -o "purpur.jar" "$API/$TARGET_VER/latest/download"
    mcinfo_set version "$TARGET_VER"
    mcinfo_set jar "purpur.jar"
    SERVER_JAR="purpur.jar"
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
        mcinfo_set version "$TARGET_VER"
        mcinfo_set jar "$NEW_JAR"
        SERVER_JAR="$NEW_JAR"
        echo "$LOADER_VERSION" > .fabric-loader
        echo "[OK] Fabric updated: $NEW_JAR"
    else
        echo "[ERROR] Fabric jar not found after update"
        exit 1
    fi
}

update_forge() {
    local META_URL="https://maven.minecraftforge.net/releases/net/minecraftforge/forge/maven-metadata.xml"
    local TARGET_VER="${NEW_VERSION:-$CURRENT_VERSION}"
    local FORGE_VERSION

    echo "[*] Resolving Forge build for $TARGET_VER..."
    FORGE_VERSION=$(curl -s "$META_URL" | python3 -c "
import sys
from xml.etree import ElementTree as ET

target = '''$TARGET_VER'''.strip()
root = ET.fromstring(sys.stdin.read())
versions = [node.text for node in root.findall('.//version') if node.text]

prefixes = []
if target:
    prefixes.append(target)
    if target.startswith('1.'):
        prefixes.append(target[2:])
    else:
        prefixes.append('1.' + target)

selected = ''
for prefix in prefixes:
    matches = [v for v in versions if v == prefix or v.startswith(prefix + '-') or v.startswith(prefix + '.')]
    if matches:
        selected = matches[-1]
        break

if not selected:
    selected = root.findtext('.//release', '') or root.findtext('.//latest', '')

print(selected)
" 2>/dev/null)

    if [ -z "$FORGE_VERSION" ]; then
        echo "[ERROR] Failed to resolve Forge version"
        exit 1
    fi

    TARGET_VER="${FORGE_VERSION%%-*}"

    local INSTALLER_JAR="forge-${FORGE_VERSION}-installer.jar"
    local INSTALLER_URL="https://maven.minecraftforge.net/net/minecraftforge/forge/${FORGE_VERSION}/${INSTALLER_JAR}"

    echo "[*] Downloading Forge installer $FORGE_VERSION..."
    curl -fsSL -o "$INSTALLER_JAR" "$INSTALLER_URL"

    echo "[*] Installing Forge server..."
    java -jar "$INSTALLER_JAR" --installServer
    rm -f "$INSTALLER_JAR"

    create_modloader_wrapper
    mcinfo_set version "$TARGET_VER"
    mcinfo_set jar "mc-launch.sh"
    SERVER_JAR="mc-launch.sh"
    echo "[OK] Forge updated: $FORGE_VERSION"
}

update_neoforge() {
    local META_URL="https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml"
    local TARGET_VER="${NEW_VERSION:-$CURRENT_VERSION}"
    local NEOFORGE_VERSION

    echo "[*] Resolving NeoForge build for $TARGET_VER..."
    NEOFORGE_VERSION=$(curl -s "$META_URL" | python3 -c "
import sys
from xml.etree import ElementTree as ET

target = '''$TARGET_VER'''.strip()
root = ET.fromstring(sys.stdin.read())
versions = [node.text for node in root.findall('.//version') if node.text]

prefixes = []
if target:
    prefixes.append(target)
    if target.startswith('1.'):
        parts = target.split('.')
        if len(parts) >= 3:
            prefixes.append(f'{parts[1]}.{parts[2]}')
        prefixes.append(target[2:])

selected = ''
for prefix in prefixes:
    matches = [v for v in versions if v == prefix or v.startswith(prefix + '.') or v.startswith(prefix + '-')]
    if matches:
        selected = matches[-1]
        break

if not selected:
    selected = root.findtext('.//release', '') or root.findtext('.//latest', '')

print(selected)
" 2>/dev/null)

    if [ -z "$NEOFORGE_VERSION" ]; then
        echo "[ERROR] Failed to resolve NeoForge version"
        exit 1
    fi

    TARGET_VER="$(derive_neoforge_mc_version "$NEOFORGE_VERSION")"

    local INSTALLER_JAR="neoforge-${NEOFORGE_VERSION}-installer.jar"
    local INSTALLER_URL="https://maven.neoforged.net/releases/net/neoforged/neoforge/${NEOFORGE_VERSION}/${INSTALLER_JAR}"

    echo "[*] Downloading NeoForge installer $NEOFORGE_VERSION..."
    curl -fsSL -o "$INSTALLER_JAR" "$INSTALLER_URL"

    echo "[*] Installing NeoForge server..."
    java -jar "$INSTALLER_JAR" --installServer
    rm -f "$INSTALLER_JAR"

    create_modloader_wrapper
    mcinfo_set version "$TARGET_VER"
    mcinfo_set jar "mc-launch.sh"
    SERVER_JAR="mc-launch.sh"
    echo "[OK] NeoForge updated: $NEOFORGE_VERSION"
}

update_quilt() {
    local TARGET_VER="${NEW_VERSION:-$CURRENT_VERSION}"
    local INSTALLER_JAR="quilt-installer.jar"
    local INSTALLER_URL="https://quiltmc.org/api/v1/download-latest-installer/java-universal"

    if [ -z "$TARGET_VER" ]; then
        TARGET_VER="$(resolve_latest_stable_game_version)"
    fi

    echo "[*] Downloading Quilt installer..."
    curl -fsSL -o "$INSTALLER_JAR" "$INSTALLER_URL"

    echo "[*] Installing Quilt server $TARGET_VER..."
    java -jar "$INSTALLER_JAR" install server "$TARGET_VER" --download-server
    rm -f "$INSTALLER_JAR"

    if [ -d "$SCRIPT_DIR/server" ]; then
        shopt -s dotglob nullglob
        mv "$SCRIPT_DIR/server"/* "$SCRIPT_DIR/"
        shopt -u dotglob nullglob
        rmdir "$SCRIPT_DIR/server"
    fi

    if [ ! -f "quilt-server-launch.jar" ]; then
        echo "[ERROR] Quilt launcher jar not found after update"
        exit 1
    fi

    mcinfo_set version "$TARGET_VER"
    mcinfo_set jar "quilt-server-launch.jar"
    SERVER_JAR="quilt-server-launch.jar"
    echo "[OK] Quilt updated"
}

case "$SERVER_TYPE" in
    paper)  update_paper ;;
    purpur) update_purpur ;;
    fabric) update_fabric ;;
    forge) update_forge ;;
    neoforge) update_neoforge ;;
    quilt) update_quilt ;;
    *)      echo "[ERROR] Unknown type: $SERVER_TYPE"; exit 1 ;;
esac

# Cleanup old jar backups (keep last 3)
ls -1t *.bak.* 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null

echo ""
echo "========================================"
echo "  Update Complete!"
echo "========================================"
echo "Type: $SERVER_TYPE"
echo "Version: $(grep '^version=' .mc-info 2>/dev/null | cut -d= -f2 || echo '?')"
echo ""
echo "  ./start.sh start"
echo ""
echo "All set! Happy crafting."
