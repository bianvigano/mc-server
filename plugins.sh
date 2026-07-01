#!/bin/bash
# plugins.sh — Modrinth plugin management for Paper/Purpur
# Usage: ./plugins.sh {search|install|remove|list|update} [args]
# Requires: curl, jq or python3

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGINS_DIR="${PLUGINS_DIR:-./plugins}"
PLUGINS_MANIFEST="$PLUGINS_DIR/.installed.json"
MODRINTH_API="https://api.modrinth.com/v2"
USER_AGENT="mc-server/1.0 (https://github.com/bianvigano/mc-server)"

cd "$SCRIPT_DIR"

# Detect MC version
# Read .mc-info
if [ -f ".mc-info" ]; then
    MC_VERSION="$(grep '^version=' .mc-info | cut -d= -f2 || echo '1.21')"
    SERVER_TYPE="$(grep '^type=' .mc-info | cut -d= -f2 || echo 'paper')"
else
    MC_VERSION="${MC_VERSION:-1.21}"
    SERVER_TYPE="paper"
fi

# Map type to Modrinth loader name
case "$SERVER_TYPE" in
    paper)   LOADER="paper" ;;
    purpur)  LOADER="paper" ;;  # purpur works with paper plugins
    fabric)  LOADER="fabric" ;;
    *)       LOADER="paper" ;;
esac

# ═══════════════════════════════════════════
#  Helper: JSON parsing (prefer jq, fallback python3)
# ═══════════════════════════════════════════
json_parse() {
    local DATA="$1"
    local QUERY="$2"
    if command -v jq &>/dev/null; then
        echo "$DATA" | jq -r "$QUERY"
    else
        echo "$DATA" | python3 -c "
import sys, json
data = json.load(sys.stdin)
# Simple jq-like queries
if '$QUERY' == '.title':
    print(data.get('title', ''))
elif '$QUERY' == '.slug':
    print(data.get('slug', ''))
elif '$QUERY' == '.description':
    print(data.get('description', ''))
elif '$QUERY' == '.project_type':
    print(data.get('project_type', ''))
elif '$QUERY'.startswith('.'):
    key = '$QUERY'.strip('.')
    if isinstance(data, list):
        for item in data:
            print(item.get(key, ''))
    else:
        print(data.get(key, ''))
else:
    print(data)
" 2>/dev/null
    fi
}

json_array_len() {
    local DATA="$1"
    if command -v jq &>/dev/null; then
        echo "$DATA" | jq 'length'
    else
        echo "$DATA" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null
    fi
}

# ═══════════════════════════════════════════
#  Manifest helpers
# ═══════════════════════════════════════════
init_manifest() {
    mkdir -p "$PLUGINS_DIR"
    if [ ! -f "$PLUGINS_MANIFEST" ]; then
        echo "[]" > "$PLUGINS_MANIFEST"
    fi
}

manifest_add() {
    local SLUG="$1"
    local NAME="$2"
    local FILENAME="$3"
    local VERSION_ID="$4"
    local JAR_NAME="$5"

    init_manifest
    python3 -c "
import json, sys
with open('$PLUGINS_MANIFEST') as f:
    data = json.load(f)
# Remove existing entry with same slug
data = [d for d in data if d.get('slug') != '$SLUG']
data.append({
    'slug': '$SLUG',
    'name': '$NAME',
    'filename': '$JAR_NAME',
    'version_id': '$VERSION_ID'
})
with open('$PLUGINS_MANIFEST', 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null
}

manifest_remove() {
    local SLUG="$1"
    init_manifest
    python3 -c "
import json
with open('$PLUGINS_MANIFEST') as f:
    data = json.load(f)
data = [d for d in data if d.get('slug') != '$SLUG']
with open('$PLUGINS_MANIFEST', 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null
}

manifest_list() {
    init_manifest
    python3 -c "
import json
with open('$PLUGINS_MANIFEST') as f:
    data = json.load(f)
if not data:
    print('  No plugins installed.')
else:
    for p in data:
        print(f\"  {p['slug']:30s} {p['filename']}\")
" 2>/dev/null
}

# ═══════════════════════════════════════════
#  Command: search
# ═══════════════════════════════════════════
do_search() {
    local QUERY="$1"
    if [ -z "$QUERY" ]; then
        echo "Usage: $0 search <query>"
        exit 1
    fi

    echo "[*] Searching Modrinth: $QUERY"
    local FACETS
    FACETS=$(python3 -c "
import json
facets = [['project_type:plugin'], ['categories:$LOADER'], ['versions:$MC_VERSION']]
print(json.dumps(facets))
" 2>/dev/null)

    local RESULT
    RESULT=$(curl -s -H "User-Agent: $USER_AGENT" \
        "$MODRINTH_API/search?query=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$QUERY'))")&facets=$FACETS&limit=10")

    python3 -c "
import sys, json
data = json.load(sys.stdin)
hits = data.get('hits', [])
if not hits:
    print('  No results found.')
else:
    print(f\"  {'SLUG':30s} {'DOWNLOADS':>10s}  DESCRIPTION\")
    print(f\"  {'-'*30} {'-'*10}  {'-'*40}\")
    for h in hits:
        slug = h.get('slug', '')[:30]
        desc = h.get('description', '')[:40]
        dl = h.get('downloads', 0)
        dl_str = f'{dl:,}' if isinstance(dl, int) else str(dl)
        print(f'  {slug:30s} {dl_str:>10s}  {desc}')
" <<< "$RESULT" 2>/dev/null
}

# ═══════════════════════════════════════════
#  Command: install
# ═══════════════════════════════════════════
do_install() {
    local SLUG="$1"
    if [ -z "$SLUG" ]; then
        echo "Usage: $0 install <slug-or-url>"
        echo "  slug:  essentialsx, luckperms, worldedit"
        echo "  url:   https://modrinth.com/plugin/essentialsx"
        exit 1
    fi

    # Extract slug from URL if needed
    if [[ "$SLUG" == *modrinth.com* ]]; then
        SLUG=$(echo "$SLUG" | sed 's|.*/||')
    fi

    echo "[*] Fetching project info: $SLUG"
    local PROJECT
    PROJECT=$(curl -s -H "User-Agent: $USER_AGENT" "$MODRINTH_API/project/$SLUG")

    local NAME
    NAME=$(json_parse "$PROJECT" '.title')
    local PROJECT_ID
    PROJECT_ID=$(json_parse "$PROJECT" '.id')

    if [ -z "$PROJECT_ID" ] || [ "$PROJECT_ID" = "null" ]; then
        echo "[ERROR] Plugin not found: $SLUG"
        exit 1
    fi

    echo "  Name: $NAME"

    # Get latest version for our MC version + loader
    echo "[*] Fetching latest version for MC $MC_VERSION / $LOADER..."
    local VERSIONS
    VERSIONS=$(curl -s -H "User-Agent: $USER_AGENT" \
        "$MODRINTH_API/project/$PROJECT_ID/version?loaders=[\"$LOADER\"]&game_versions=[\"$MC_VERSION\"]")

    local VERSION_JSON
    VERSION_JSON=$(python3 -c "
import sys, json
data = json.load(sys.stdin)
if not data:
    print('{}')
    sys.exit()
# Get latest (first in list)
v = data[0]
files = v.get('files', [])
primary = next((f for f in files if f.get('primary')), files[0] if files else {})
print(json.dumps({
    'version_id': v.get('id', ''),
    'version_number': v.get('version_number', ''),
    'filename': primary.get('filename', ''),
    'url': primary.get('url', ''),
    'name': v.get('name', '')
}))
" <<< "$VERSIONS" 2>/dev/null)

    local FILENAME
    FILENAME=$(json_parse "$VERSION_JSON" '.filename')
    local DOWNLOAD_URL
    DOWNLOAD_URL=$(json_parse "$VERSION_JSON" '.url')
    local VERSION_ID
    VERSION_ID=$(json_parse "$VERSION_JSON" '.version_id')

    if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" = "null" ] || [ "$DOWNLOAD_URL" = "" ]; then
        echo "[ERROR] No compatible version found for MC $MC_VERSION / $LOADER"
        exit 1
    fi

    echo "  File: $FILENAME"
    echo "[*] Downloading..."
    mkdir -p "$PLUGINS_DIR"
    curl -fsSL -H "User-Agent: $USER_AGENT" -o "$PLUGINS_DIR/$FILENAME" "$DOWNLOAD_URL"
    echo "[OK] Installed: $PLUGINS_DIR/$FILENAME"

    manifest_add "$SLUG" "$NAME" "$FILENAME" "$VERSION_ID" "$FILENAME"

    echo "  Restart server to load plugin."
}

# ═══════════════════════════════════════════
#  Command: remove
# ═══════════════════════════════════════════
do_remove() {
    local SLUG="$1"
    if [ -z "$SLUG" ]; then
        echo "Usage: $0 remove <slug>"
        exit 1
    fi

    init_manifest

    # Find filename from manifest
    local FILENAME
    FILENAME=$(python3 -c "
import json
with open('$PLUGINS_MANIFEST') as f:
    data = json.load(f)
for p in data:
    if p.get('slug') == '$SLUG':
        print(p.get('filename', ''))
        break
" 2>/dev/null)

    if [ -n "$FILENAME" ] && [ -f "$PLUGINS_DIR/$FILENAME" ]; then
        rm -f "$PLUGINS_DIR/$FILENAME"
        echo "[OK] Removed: $FILENAME"
    else
        echo "[WARN] Plugin file not found for slug: $SLUG"
    fi

    manifest_remove "$SLUG"
    echo "  Restart server to unload plugin."
}

# ═══════════════════════════════════════════
#  Command: list
# ═══════════════════════════════════════════
do_list() {
    echo "=== Installed Plugins ==="
    manifest_list

    # Also show any untracked jars
    if [ -d "$PLUGINS_DIR" ]; then
        local UNTRACKED
        UNTRACKED=$(ls -1 "$PLUGINS_DIR"/*.jar 2>/dev/null | while read jar; do
            local JNAME
            JNAME=$(basename "$jar")
            if ! grep -q "$JNAME" "$PLUGINS_MANIFEST" 2>/dev/null; then
                echo "  [untracked] $JNAME"
            fi
        done)
        if [ -n "$UNTRACKED" ]; then
            echo ""
            echo "Untracked (not installed via plugins.sh):"
            echo "$UNTRACKED"
        fi
    fi
}

# ═══════════════════════════════════════════
#  Command: update
# ═══════════════════════════════════════════
do_update() {
    init_manifest

    local COUNT
    COUNT=$(python3 -c "
import json
with open('$PLUGINS_MANIFEST') as f:
    data = json.load(f)
print(len(data))
" 2>/dev/null)

    if [ "$COUNT" = "0" ]; then
        echo "[*] No plugins to update."
        return
    fi

    echo "[*] Checking $COUNT plugin(s) for updates..."
    local UPDATED=0

    python3 -c "
import json
with open('$PLUGINS_MANIFEST') as f:
    data = json.load(f)
for p in data:
    print(p.get('slug', ''))
" 2>/dev/null | while read SLUG; do
        if [ -z "$SLUG" ]; then continue; fi

        # Get current version
        local CUR_VERSION_ID
        CUR_VERSION_ID=$(python3 -c "
import json
with open('$PLUGINS_MANIFEST') as f:
    data = json.load(f)
for p in data:
    if p.get('slug') == '$SLUG':
        print(p.get('version_id', ''))
        break
" 2>/dev/null)

        # Get latest version
        local PROJECT_ID
        PROJECT_ID=$(curl -s -H "User-Agent: $USER_AGENT" "$MODRINTH_API/project/$SLUG" | \
            python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)

        if [ -z "$PROJECT_ID" ]; then
            echo "  [SKIP] $SLUG — project not found"
            continue
        fi

        local LATEST_VERSION
        LATEST_VERSION=$(curl -s -H "User-Agent: $USER_AGENT" \
            "$MODRINTH_API/project/$PROJECT_ID/version?loaders=[\"$LOADER\"]&game_versions=[\"$MC_VERSION\"]" | \
            python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0].get('id','') if d else '')" 2>/dev/null)

        if [ -z "$LATEST_VERSION" ] || [ "$LATEST_VERSION" = "" ]; then
            echo "  [SKIP] $SLUG — no version for MC $MC_VERSION"
            continue
        fi

        if [ "$CUR_VERSION_ID" = "$LATEST_VERSION" ]; then
            echo "  [OK] $SLUG — up to date"
        else
            echo "  [UPDATE] $SLUG"
            # Re-download
            local OLD_FILE
            OLD_FILE=$(python3 -c "
import json
with open('$PLUGINS_MANIFEST') as f:
    data = json.load(f)
for p in data:
    if p.get('slug') == '$SLUG':
        print(p.get('filename', ''))
        break
" 2>/dev/null)

            # Get new version details
            local VERSION_JSON
            VERSION_JSON=$(curl -s -H "User-Agent: $USER_AGENT" \
                "$MODRINTH_API/project/$PROJECT_ID/version?loaders=[\"$LOADER\"]&game_versions=[\"$MC_VERSION\"]")

            local NEW_FILE NEW_URL
            NEW_FILE=$(python3 -c "
import sys,json
d=json.load(sys.stdin)
v=d[0] if d else {}
files=v.get('files',[])
primary=next((f for f in files if f.get('primary')), files[0] if files else {})
print(primary.get('filename',''))
" <<< "$VERSION_JSON" 2>/dev/null)
            NEW_URL=$(python3 -c "
import sys,json
d=json.load(sys.stdin)
v=d[0] if d else {}
files=v.get('files',[])
primary=next((f for f in files if f.get('primary')), files[0] if files else {})
print(primary.get('url',''))
" <<< "$VERSION_JSON" 2>/dev/null)

            if [ -n "$NEW_URL" ] && [ "$NEW_URL" != "" ]; then
                rm -f "$PLUGINS_DIR/$OLD_FILE"
                curl -fsSL -H "User-Agent: $USER_AGENT" -o "$PLUGINS_DIR/$NEW_FILE" "$NEW_URL"
                manifest_add "$SLUG" "$SLUG" "$NEW_FILE" "$LATEST_VERSION" "$NEW_FILE"
                echo "    $OLD_FILE -> $NEW_FILE"
                UPDATED=$((UPDATED + 1))
            fi
        fi
    done

    echo "[*] Done. Updated $UPDATED plugin(s). Restart server to apply."
}

# ═══════════════════════════════════════════
#  Entry point
# ═══════════════════════════════════════════
case "${1}" in
    search|s)   shift; do_search "$@" ;;
    install|i)  shift; do_install "$@" ;;
    remove|r)   shift; do_remove "$@" ;;
    list|ls)    do_list ;;
    update|u)   do_update ;;
    *)
        echo "Usage: $0 {search|install|remove|list|update} [args]"
        echo ""
        echo "Commands:"
        echo "  search <query>          Search Modrinth for plugins"
        echo "  install <slug>          Install plugin by slug"
        echo "  remove <slug>           Remove installed plugin"
        echo "  list                    List installed plugins"
        echo "  update                  Update all installed plugins"
        echo ""
        echo "Examples:"
        echo "  $0 search essentials"
        echo "  $0 install essentialsx"
        echo "  $0 install https://modrinth.com/plugin/luckperms"
        echo "  $0 remove luckperms"
        echo "  $0 update"
        echo ""
        echo "Env vars:"
        echo "  PLUGINS_DIR     Plugin directory (default: ./plugins)"
        echo "  MC_VERSION      Minecraft version (auto-detected from .mc-info)"
        ;;
esac
