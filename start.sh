#!/bin/bash
# start.sh — Universal MC server launcher
# Usage: ./start.sh {start|run|stop|restart|status|console|config|stats|world|send|rename|new|plugins|mcinfo|menu}
# Auto-detects: tmux > screen > nohup fallback

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ═══════════════════════════════════════════
#  Config — override via env vars
# ═══════════════════════════════════════════
INFO_FILE=".mc-info"
DEFAULT_JAVA_FLAGS="-XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200"
PID_FILE=".server.pid"

# Resolve Java binary path by version
# Usage: JAVA_BIN=$(resolve_java_bin "$JAVA_VERSION")
# Maps: 8 -> /usr/lib/jvm/java-8-openjdk-amd64/bin/java
# Falls back to system 'java' if version not found or JAVA_VERSION empty
resolve_java_bin() {
    local VER="$1"
    if [ -z "$VER" ]; then
        echo "java"
        return
    fi
    local CANDIDATE="/usr/lib/jvm/java-${VER}-openjdk-amd64/bin/java"
    if [ -x "$CANDIDATE" ]; then
        echo "$CANDIDATE"
    else
        echo "java"
    fi
}

mcinfo_get() {
    local KEY="$1"
    [ -f "$INFO_FILE" ] || return 1
    awk -F= -v key="$KEY" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$INFO_FILE"
}

mcinfo_set() {
    local KEY="$1"
    shift
    local VALUE="$*"
    local TMP_FILE
    TMP_FILE="$(mktemp)"

    if [ -f "$INFO_FILE" ]; then
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
        ' "$INFO_FILE" > "$TMP_FILE"
    else
        printf "%s=%s\n" "$KEY" "$VALUE" > "$TMP_FILE"
    fi

    mv "$TMP_FILE" "$INFO_FILE"
}

reload_mcinfo_values() {
    MCINFO_SERVER_TYPE="$(mcinfo_get type 2>/dev/null || true)"
    MCINFO_MC_VERSION="$(mcinfo_get version 2>/dev/null || true)"
    MCINFO_SERVER_JAR="$(mcinfo_get jar 2>/dev/null || true)"
    MCINFO_BACKEND="$(mcinfo_get backend 2>/dev/null || true)"
    MCINFO_XMS="$(mcinfo_get xms 2>/dev/null || true)"
    MCINFO_XMX="$(mcinfo_get xmx 2>/dev/null || true)"
    MCINFO_AUTO_RESTART="$(mcinfo_get auto_restart 2>/dev/null || true)"
    MCINFO_JAVA_FLAGS="$(mcinfo_get java_flags 2>/dev/null || true)"
    MCINFO_JAVA_VERSION="$(mcinfo_get java_version 2>/dev/null || true)"
}

reload_mcinfo_values

SERVER_TYPE="${SERVER_TYPE:-${MCINFO_SERVER_TYPE:-unknown}}"
MC_VERSION="${MC_VERSION:-${MCINFO_MC_VERSION:-}}"
SERVER_JAR_VAL="${SERVER_JAR_VAL:-${MCINFO_SERVER_JAR:-}}"
JAVA_XMS="${JAVA_XMS:-${MCINFO_XMS:-1G}}"
JAVA_XMX="${JAVA_XMX:-${MCINFO_XMX:-2G}}"
AUTO_RESTART="${AUTO_RESTART:-${MCINFO_AUTO_RESTART:-false}}"
JAVA_VERSION="${JAVA_VERSION:-${MCINFO_JAVA_VERSION:-}}"
JAVA_BIN="$(resolve_java_bin "$JAVA_VERSION")"

# Session name priority: env > .mc-info > default
SESSION_NAME="${SESSION_NAME:-$(mcinfo_get session_name 2>/dev/null || true)}"
SESSION_NAME="${SESSION_NAME:-minecraft}"

# Set default Java flags based on server type
set_java_flags_by_type() {
    case "$SERVER_TYPE" in
        paper|folia|purpur)
            JAVA_FLAGS="$DEFAULT_JAVA_FLAGS"
            ;;
        fabric|quilt)
            JAVA_FLAGS="-XX:+UseG1GC -XX:+UnlockExperimentalVMOptions -XX:MaxGCPauseMillis=100 -XX:+DisableExplicitGC -XX:MaxMetaspaceSize=256M"
            ;;
        forge|neoforge)
            JAVA_FLAGS="-XX:+UseG1GC -XX:+UnlockExperimentalVMOptions -XX:MaxGCPauseMillis=100 -XX:+DisableExplicitGC -XX:MaxMetaspaceSize=512M"
            ;;
        *)
            JAVA_FLAGS="$DEFAULT_JAVA_FLAGS"
            ;;
    esac
}

if [ -z "${JAVA_FLAGS+x}" ] && [ -n "$MCINFO_JAVA_FLAGS" ]; then
    JAVA_FLAGS="$MCINFO_JAVA_FLAGS"
fi

# Apply type-specific flags if JAVA_FLAGS not explicitly set by user or .mc-info
if [ -z "${JAVA_FLAGS+x}" ]; then
    set_java_flags_by_type
fi

# Auto-detect server jar — scan folder untuk *.jar
# 0 jar  → error
# 1 jar  → langsung pakai
# >1 jar → menu pilihan
detect_server_jar() {
    if [ -n "$SERVER_JAR" ]; then
        echo "$SERVER_JAR"
        return
    elif [ -n "$SERVER_JAR_VAL" ]; then
        echo "$SERVER_JAR_VAL"
        return
    fi

    # Cek launcher script (.sh) dulu
    local LAUNCHER
    LAUNCHER="$(ls -1 mc-launch.sh 2>/dev/null | head -1)"
    [ -n "$LAUNCHER" ] && { echo "$LAUNCHER"; return; }

    # Scan semua .jar di current directory
    local JARS=()
    while IFS= read -r f; do
        JARS+=("$f")
    done < <(ls -1 *.jar 2>/dev/null)

    if [ ${#JARS[@]} -eq 0 ]; then
        return 1
    elif [ ${#JARS[@]} -eq 1 ]; then
        echo "${JARS[0]}"
    else
        echo "[*] Ditemukan ${#JARS[@]} file jar:" >&2
        local i=1
        for jar in "${JARS[@]}"; do
            echo "  $i) $jar" >&2
            ((i++))
        done
        echo "" >&2
        local choice
        read -rp "Pilih jar [1-${#JARS[@]}]: " choice >&2
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le ${#JARS[@]} ]; then
            echo "${JARS[$((choice-1))]}"
        else
            echo "[ERROR] Pilihan tidak valid." >&2
            return 1
        fi
    fi
}

JAR=""

# ═══════════════════════════════════════════
#  Auto-port switch (bukan kill)
# ═══════════════════════════════════════════
get_port() {
    grep -E '^server-port=' server.properties 2>/dev/null | cut -d= -f2 || echo "25565"
}

find_free_port() {
    local P="$1" TRY=0
    while [ "$TRY" -lt 20 ]; do
        if ! lsof -ti :"${P}" >/dev/null 2>&1; then
            echo "$P"
            return 0
        fi
        P=$((P + 1))
        TRY=$((TRY + 1))
    done
    return 1
}

# ponytail: port bergeser permanen di server.properties; kalau port lama mau
# dipakai lagi, ubah manual via ./start.sh config set server-port 25565
auto_switch_port() {
    local PORT
    PORT=$(get_port)
    PORT=${PORT:-25565}
    if ! lsof -ti :"${PORT}" >/dev/null 2>&1; then
        return 0
    fi
    local NEWPORT
    NEWPORT=$(find_free_port $((PORT + 1))) || {
        echo "[ERROR] Tidak ada port bebas setelah ${PORT}. Ubah manual: ./start.sh config set server-port <port>"
        return 1
    }
    if [ -f server.properties ]; then
        sed -i "s|^server-port=.*|server-port=${NEWPORT}|" server.properties
    else
        printf 'server-port=%s\n' "$NEWPORT" > server.properties
    fi
    echo "[!] Port ${PORT} sudah dipakai. Server ini pindah ke port ${NEWPORT} (disimpan di server.properties)."
}

# ═══════════════════════════════════════════
#  Backend detection
# ═══════════════════════════════════════════
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

refresh_runtime_from_mcinfo() {
    reload_mcinfo_values

    SERVER_TYPE="${MCINFO_SERVER_TYPE:-unknown}"
    MC_VERSION="${MCINFO_MC_VERSION:-}"
    SERVER_JAR_VAL="${MCINFO_SERVER_JAR:-}"
    JAVA_XMS="${MCINFO_XMS:-1G}"
    JAVA_XMX="${MCINFO_XMX:-2G}"
    AUTO_RESTART="${MCINFO_AUTO_RESTART:-false}"
    JAVA_VERSION="${MCINFO_JAVA_VERSION:-}"
    JAVA_BIN="$(resolve_java_bin "$JAVA_VERSION")"

    if [ -n "$MCINFO_JAVA_FLAGS" ]; then
        JAVA_FLAGS="$MCINFO_JAVA_FLAGS"
    else
        set_java_flags_by_type
    fi

    JAR=""  # reset — only start/run calls detect_server_jar

    case "${FORCE_BACKEND:-${MCINFO_BACKEND:-}}" in
        tmux|screen|nohup)
            BACKEND="${FORCE_BACKEND:-$MCINFO_BACKEND}"
            ;;
        *)
            BACKEND="$(detect_backend)"
            ;;
    esac
}

case "${FORCE_BACKEND:-${MCINFO_BACKEND:-}}" in
    tmux|screen|nohup)
        BACKEND="${FORCE_BACKEND:-$MCINFO_BACKEND}"
        ;;
    *)
        BACKEND="$(detect_backend)"
        ;;
esac

is_running() {
    case "$BACKEND" in
        tmux)   tmux has-session -t "$SESSION_NAME" 2>/dev/null ;;
        screen) screen -list 2>/dev/null | grep -q "$SESSION_NAME" ;;
        nohup)  [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null ;;
    esac
}

# ═══════════════════════════════════════════
#  Session name management
# ═══════════════════════════════════════════
is_valid_name() {
    printf '%s' "$1" | grep -qE '^[A-Za-z0-9._-]+$'
}

set_session_name() {
    local NEW="$1"
    if [ -z "$NEW" ]; then
        echo "Usage: $0 rename <nama-baru>"
        return 1
    fi
    if ! is_valid_name "$NEW"; then
        echo "[ERROR] Nama tidak valid: $NEW (hanya huruf/angka/.-_ )"
        return 1
    fi
    if [ "$NEW" = "$SESSION_NAME" ]; then
        echo "[*] Nama sudah: $SESSION_NAME"
        return 0
    fi
    if is_running; then
        case "$BACKEND" in
            tmux)
                if tmux rename-session -t "$SESSION_NAME" "$NEW" 2>/dev/null; then
                    echo "[OK] tmux session renamed: $SESSION_NAME -> $NEW"
                else
                    echo "[ERROR] Gagal rename tmux session."
                    return 1
                fi
                ;;
            *)
                # ponytail: rename live hanya tmux; screen/nohup berlaku setelah stop+start
                echo "[WARN] Backend $BACKEND: rename berlaku setelah stop + start."
                ;;
        esac
    fi
    SESSION_NAME="$NEW"
    mcinfo_set session_name "$NEW"
    echo "[OK] Tersimpan ke $INFO_FILE: session_name=$NEW"
}

prompt_when_running() {
    [ -t 0 ] || return 0
    echo ""
    echo "Pilihan:"
    echo "  1) Ganti nama session (misal: minecraft1) — server tetap jalan"
    echo "  2) Stop lalu start ulang dengan nama baru"
    echo "  3) Daftar nama BARU (misal: minecraft1) lalu start dengan nama itu"
    echo "  Enter) Batal"
    read -rp "Pilih [1/2/3]: " c
    case "$c" in
        1)
            read -rp "Nama session baru: " n
            if [ -n "$n" ]; then
                set_session_name "$n" || true
            fi
            ;;
        2)
            read -rp "Nama session baru: " n
            if [ -n "$n" ]; then
                do_stop
                sleep 2
                set_session_name "$n" || true
                do_start
            fi
            ;;
        3)
            prompt_new_instance
            ;;
    esac
}

# ═══════════════════════════════════════════
#  Server names — daftar nama server disimpan di $INFO_FILE (key: servers)
#  Format: servers=minecraft,minecraft1,...
#  Nama dipakai sebagai nama session tmux/screen.
#  ponytail: semua nama share folder ini (world & port sama), jadi
#  jalankan satu-satu; pisah folder manual kalau butuh paralel beneran.
# ═══════════════════════════════════════════
servers_list() {
    local L
    L="$(mcinfo_get servers 2>/dev/null || true)"
    echo "${L//,/ }"
}

is_session_running() {
    tmux has-session -t "$1" 2>/dev/null \
        || screen -list 2>/dev/null | grep -qE "[.]${1}[[:space:]]"
}

add_server_name() {
    local NAME="$1"
    local EXISTING
    EXISTING="$(mcinfo_get servers 2>/dev/null || true)"
    case ",${EXISTING}," in
        *,"${NAME}",*) return 0 ;;
    esac
    if [ -n "$EXISTING" ]; then
        mcinfo_set servers "${EXISTING},${NAME}"
    else
        mcinfo_set servers "$NAME"
    fi
}

list_servers() {
    local S
    for S in $(servers_list); do
        if is_session_running "$S"; then
            echo "  $S  [RUNNING]"
        else
            echo "  $S  [stop]"
        fi
    done
}

start_new_instance() {
    local NAME="$1"
    if ! is_valid_name "$NAME"; then
        echo "[ERROR] Nama tidak valid: ${NAME:-<kosong>} (hanya huruf/angka/.-_ )"
        return 1
    fi
    if is_session_running "$NAME"; then
        echo "[ERROR] Session '$NAME' sedang jalan."
        return 1
    fi
    add_server_name "$NAME"
    echo "[OK] Terdaftar di $INFO_FILE -> servers=$(mcinfo_get servers 2>/dev/null || true)"
    echo "[*] Menjalankan server sebagai: $NAME"
    SESSION_NAME="$NAME" bash "$SCRIPT_DIR/start.sh" start
}

# Nama default utk instance baru: minecraft -> minecraft1 -> minecraft2 ...
# ponytail: cek session jalan + daftar nama di $INFO_FILE
next_instance_name() {
    local BASE="minecraft"
    local N="$BASE"
    local i=1
    while :; do
        local TAKEN=""
        if is_session_running "$N"; then
            echo "  (skip $N: session sedang jalan)" >&2
            TAKEN=1
        else
            local S
            for S in $(servers_list); do
                if [ "$S" = "$N" ]; then
                    echo "  (skip $N: sudah terdaftar di $INFO_FILE)" >&2
                    TAKEN=1
                    break
                fi
            done
        fi
        [ -z "$TAKEN" ] && break
        N="$BASE$((i++))"
    done
    echo "$N"
}

prompt_new_instance() {
    local DEF n
    DEF="$(next_instance_name)"
    read -rp "Nama server baru ($DEF) [Enter: pakai nama ini]: " n
    [ -z "$n" ] && n="$DEF"
    start_new_instance "$n" || true
}

# ═══════════════════════════════════════════
#  Send command to server console
# ═══════════════════════════════════════════
send_cmd() {
    local CMD="$1"
    case "$BACKEND" in
        tmux)   tmux send-keys -t "$SESSION_NAME" "$CMD" Enter ;;
        screen) screen -S "$SESSION_NAME" -p 0 -X stuff "${CMD}^M" ;;
        nohup)  echo "$CMD" > /proc/$(cat "$PID_FILE")/fd/0 2>/dev/null || true ;;
    esac
}

is_launcher_script() {
    case "$JAR" in
        *.sh) [ -f "$JAR" ] ;;
        *)    return 1 ;;
    esac
}

build_launch_command() {
    if is_launcher_script; then
        printf 'cd %q && MC_JAVA_FLAGS=%q MC_JAVA_XMS=%q MC_JAVA_XMX=%q MC_JAVA_BIN=%q bash %q nogui' \
            "$SCRIPT_DIR" "$JAVA_FLAGS" "$JAVA_XMS" "$JAVA_XMX" "$JAVA_BIN" "$JAR"
    else
        printf 'cd %q && %q %s -Xms%q -Xmx%q -jar %q nogui' \
            "$SCRIPT_DIR" "$JAVA_BIN" "$JAVA_FLAGS" "$JAVA_XMS" "$JAVA_XMX" "$JAR"
    fi
}

launch_foreground() {
    if is_launcher_script; then
        MC_JAVA_FLAGS="$JAVA_FLAGS" MC_JAVA_XMS="$JAVA_XMS" MC_JAVA_XMX="$JAVA_XMX" MC_JAVA_BIN="$JAVA_BIN" \
            bash "$JAR" nogui
    else
        "$JAVA_BIN" $JAVA_FLAGS -Xms"$JAVA_XMS" -Xmx"$JAVA_XMX" -jar "$JAR" nogui
    fi
}

# ═══════════════════════════════════════════
#  Commands: start/stop/restart/status/console
# ═══════════════════════════════════════════
do_start() {
    if is_running; then
        echo "[*] Server sudah jalan ($BACKEND: $SESSION_NAME)"
        prompt_when_running
        return
    fi

    JAR="${SERVER_JAR:-$(detect_server_jar)}" || true
    if [ -z "$JAR" ] || [ ! -f "$JAR" ]; then
        echo "[ERROR] File jar tidak ditemukan: ${JAR:-<empty>}"
        exit 1
    fi

    auto_switch_port

    echo "[*] Starting server..."
    echo "    Type:    $SERVER_TYPE"
    echo "    Jar:     $JAR"
    echo "    Port:    $(get_port)"
    echo "    RAM:     $JAVA_XMS - $JAVA_XMX"
    echo "    Backend: $BACKEND"
    echo "    Java:    ${JAVA_VERSION:-system} ($JAVA_BIN)"
    echo "    Java Flags: $JAVA_FLAGS"

    local LAUNCH_CMD
    LAUNCH_CMD="$(build_launch_command)"

    case "$BACKEND" in
        tmux)
            tmux new-session -d -s "$SESSION_NAME" "$LAUNCH_CMD"
            echo "    Attach: tmux attach -t $SESSION_NAME"
            ;;
        screen)
            screen -dmS "$SESSION_NAME" bash -lc "$LAUNCH_CMD"
            echo "    Attach: screen -r $SESSION_NAME"
            ;;
        nohup)
            mkdir -p logs
            nohup bash -lc "$LAUNCH_CMD" > logs/console.log 2>&1 &
            echo $! > "$PID_FILE"
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

do_run() {
    if is_running; then
        echo "[*] Server sudah jalan ($BACKEND: $SESSION_NAME)"
        prompt_when_running
        return
    fi

    JAR="${SERVER_JAR:-$(detect_server_jar)}" || true
    if [ -z "$JAR" ] || [ ! -f "$JAR" ]; then
        echo "[ERROR] File jar tidak ditemukan: ${JAR:-<empty>}"
        exit 1
    fi

    auto_switch_port

    while true; do
        echo "[*] Menjalankan server langsung di terminal ini..."
        echo "    Type:    $SERVER_TYPE"
        echo "    Jar:     $JAR"
        echo "    Port:    $(get_port)"
        echo "    RAM:     $JAVA_XMS - $JAVA_XMX"
        echo "    Backend: direct"
        echo "    Java:    ${JAVA_VERSION:-system} ($JAVA_BIN)"
        echo "    Java Flags: $JAVA_FLAGS"
        echo ""

        launch_foreground

        if [ "$AUTO_RESTART" = "true" ]; then
            echo "[WARN] Server berhenti. Restart lagi dalam 1 detik..."
            echo "       Tekan Ctrl+C untuk keluar."
            sleep 1
        else
            echo "[*] Server selesai dijalankan."
            break
        fi
    done
}

do_stop() {
    if ! is_running; then
        echo "[*] Server tidak jalan."
        rm -f "$PID_FILE"
        return
    fi
    echo "[*] Stopping server..."

    send_cmd "save-all"
    sleep 2
    send_cmd "stop"

    for i in $(seq 1 30); do
        if ! is_running; then
            echo "[*] Server stopped."
            rm -f "$PID_FILE"
            return
        fi
        sleep 1
    done

    echo "[WARN] Force killing..."
    case "$BACKEND" in
        tmux)   tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true ;;
        screen) screen -S "$SESSION_NAME" -X quit 2>/dev/null || true ;;
        nohup)  kill -9 "$(cat "$PID_FILE")" 2>/dev/null || true ;;
    esac
    rm -f "$PID_FILE"
}

do_status() {
    if is_running; then
        echo "[*] Server status: RUNNING ($BACKEND: $SESSION_NAME)"
        echo "    Type: $SERVER_TYPE"
        echo "    Port: $(get_port)"
    else
        echo "[*] Server status: STOPPED"
    fi
}

do_console() {
    if ! is_running; then
        echo "[*] Server tidak jalan."
        exit 1
    fi
    case "$BACKEND" in
        tmux)
            echo "[*] Attaching (Ctrl+B, D to detach)..."
            sleep 1
            tmux attach -t "$SESSION_NAME"
            ;;
        screen)
            echo "[*] Attaching (Ctrl+A, D to detach)..."
            sleep 1
            screen -r "$SESSION_NAME"
            ;;
        nohup)
            echo "[*] Tailing console log (Ctrl+C to stop tailing)..."
            tail -f logs/console.log
            ;;
    esac
}

# ═══════════════════════════════════════════
#  Command: config — read/set/view server.properties OR .mc-info (RAM/backend/etc)
# ═══════════════════════════════════════════
do_config() {
    local PROP_FILE="server.properties"
    local INFO_FILE=".mc-info"
    
    # Helper to decide which source based on key
    is_mcinfo_key() {
        case "$1" in
            ram|xms|xmx|backend|type|version|jar|auto_restart|java_flags|java_version|session_name|servers) return 0 ;;
            *) return 1 ;;
        esac
    }

    # Show all .mc-info + server.properties
    show_all() {
        echo "=== .mc-info (launcher config) ==="
        if [ -f "$INFO_FILE" ]; then
            cat "$INFO_FILE"
        else
            echo "[NOT FOUND] Run ./setup.sh or ./start.sh config init first"
        fi
        echo ""
        echo "=== server.properties (Minecraft settings) ==="
        grep -v '^#' "$PROP_FILE" | grep -v '^$' | sort
    }

    case "${2:-}" in
        "")
            # Show both sections
            show_all
            ;;
        list)
            show_all
            ;;
        get)
            if [ -z "$3" ]; then
                echo "Usage: $0 config get <key>"
                echo "Keys from .mc-info: ram (alias xmx), xms, xmx, backend, type, version, jar, auto_restart, java_flags"
                echo "Keys from server.properties: server-port, gamemode, difficulty, max-players, motd, ..."
                exit 1
            fi
            KEY="$3"
            # Alias: ram → xmx
            [ "$KEY" = "ram" ] && KEY="xmx"
            # Priority: .mc-info keys first, then server.properties
            if is_mcinfo_key "$KEY"; then
                mcinfo_get "$KEY" 2>/dev/null || echo "[NOT FOUND] $KEY in .mc-info"
            else
                grep -E "^${KEY}=" "$PROP_FILE" 2>/dev/null || echo "[NOT FOUND] $KEY"
            fi
            ;;
        set)
            # Support two syntaxes:
            # 1) key=value single arg: ./start.sh config set xmx=4G
            # 2) key val two args:    ./start.sh config set xmx 4G
            if [ -n "$3" ] && [[ "$3" == *=* ]]; then
                # Single arg mode: "key=value"
                KEY="${3%%=*}"
                VALUE="${3#*=}"
                # Trim whitespace
                KEY=$(echo "$KEY" | tr -d ' ')
                VALUE=$(echo "$VALUE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            elif [ -z "$3" ] || [ -z "$4" ]; then
                echo "Usage: $0 config set <key> <value>"
                echo ""
                echo "Supports two syntaxes:"
                echo "  • key=value (single arg): $0 config set xmx=4G"
                echo "  • key value   (two args): $0 config set xmx 4G"
                echo ""
                echo "Examples:"
                echo "  $0 config set xmx=4G              # Max RAM to 4GB (.mc-info)"
                echo "  $0 config set backend=screen      # Switch to screen backend"
                echo "  $0 config set server-port=25566   # Server port (server.properties)"
                echo "  $0 config set motd=\"Welcome!\"     # MOTD with spaces"
                echo ""
                echo "Available .mc-info keys: xms, xmx, backend, type, version, jar, auto_restart, java_flags, session_name"
                echo "Available server.properties keys: server-port, gamemode, difficulty, max-players, motd, online-mode, pvp, ..."
                exit 1
            else
                # Two arg mode: key + value separately
                KEY="$3"
                shift 3
                VALUE="$*"
                # Trim whitespace
                KEY=$(echo "$KEY" | tr -d ' ')
                VALUE=$(echo "$VALUE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            fi

            # Alias: ram → xmx (user-friendly), AND set xms to same value
            # so both min & max RAM are equal (recommended for MC servers)
            SET_BOTH=0
            if [ "$KEY" = "ram" ]; then
                KEY="xmx"
                SET_BOTH=1
            fi
            
            if is_mcinfo_key "$KEY"; then
                # Save to .mc-info
                if [ -f "$INFO_FILE" ]; then
                    # Update existing line
                    if grep -qE "^${KEY}=" "$INFO_FILE"; then
                        sed -i "s|^${KEY}=.*|${KEY}=${VALUE}|" "$INFO_FILE"
                    else
                        # Append if missing
                        echo "${KEY}=${VALUE}" >> "$INFO_FILE"
                    fi
                    echo "[OK] ${KEY}=${VALUE} (saved to .mc-info)"
                    # If ram= alias used, also set xms to the same value
                    if [ "$SET_BOTH" = "1" ]; then
                        if grep -qE "^xms=" "$INFO_FILE"; then
                            sed -i "s|^xms=.*|xms=${VALUE}|" "$INFO_FILE"
                        else
                            echo "xms=${VALUE}" >> "$INFO_FILE"
                        fi
                        echo "[OK] xms=${VALUE} (saved to .mc-info, matched with xmx)"
                    fi
                    # Refresh runtime
                    refresh_runtime_from_mcinfo
                    echo "[OK] Runtime config updated."
                else
                    echo "[ERROR] .mc-info not found. Create via: ./start.sh config init"
                    exit 1
                fi
            else
                # Save to server.properties
                if [ ! -f "$PROP_FILE" ]; then
                    echo "[ERROR] $PROP_FILE not found. Run server first."
                    exit 1
                fi
                if grep -qE "^${KEY}=" "$PROP_FILE"; then
                    sed -i "s|^${KEY}=.*|${KEY}=${VALUE}|" "$PROP_FILE"
                else
                    echo "${KEY}=${VALUE}" >> "$PROP_FILE"
                fi
                echo "[OK] ${KEY}=${VALUE} (saved to server.properties)"
                
                # Notify running server
                if is_running; then
                    send_cmd "reload"
                    echo "[*] Server reload sent."
                fi
            fi
            ;;
        init)
            # Initialize .mc-info if missing
            if [ -f "$INFO_FILE" ]; then
                echo "[OK] .mc-info already exists."
                exit 0
            fi
            echo "Creating .mc-info with current values..."
            cat > "$INFO_FILE" <<EOF
type=${SERVER_TYPE:-unknown}
version=${MC_VERSION:-latest}
jar=${SERVER_JAR:-server.jar}
backend=${BACKEND:-$(detect_backend)}
xms=${JAVA_XMS:-1G}
xmx=${JAVA_XMX:-2G}
auto_restart=${AUTO_RESTART:-false}
java_flags=${JAVA_FLAGS:-}
EOF
            echo "[OK] .mc-info created with default values."
            refresh_runtime_from_mcinfo
            ;;
        help|--help|-h)
            do_config_help
            ;;
        help-)
            do_config_help
            ;;
        *)
            # Try shorthand: ./start.sh config server-port → get
            KEY="$2"
            # Alias: ram → xmx
            [ "$KEY" = "ram" ] && KEY="xmx"
            if is_mcinfo_key "$KEY"; then
                mcinfo_get "$KEY" 2>/dev/null || echo "[NOT FOUND] $KEY in .mc-info"
            else
                grep -E "^${KEY}=" "$PROP_FILE" 2>/dev/null || echo "[NOT FOUND] $KEY"
            fi
            ;;
    esac
}

do_config_help() {
    echo "Usage: $0 config [list|get|set|init|help] [options]"
    echo ""
    echo "Config split into 2 sources:"
    echo "  • .mc-info → launcher defaults (RAM, backend, auto-restart, etc.)"
    echo "  • server.properties → Minecraft settings (port, difficulty, etc.)"
    echo ""
    echo "Commands:"
    echo "  $0 config               Show all config"
    echo "  $0 config list          Show all config"
    echo "  $0 config get <key>     Read one property"
    echo "  $0 config set <key=value>  Set one property"
    echo "  $0 config init          Create .mc-info with defaults"
    echo "  $0 config help          Show this help"
    echo ""
    echo ".mc-info keys (launcher):"
    echo "  ram=<GB>    Set BOTH xms & xmx to same value  [easiest]"
    echo "  xms=<GB>    Min Java heap (e.g., 1G, 2G)"
    echo "  xmx=<GB>    Max Java heap (e.g., 2G, 4G, 8G)"
    echo "  backend=tmux|screen|nohup  Launcher backend"
    echo "  auto_restart=true|false     Auto-restart after crash"
    echo "  type=folia|paper|...        Server type (read-only)"
    echo "  version=1.21.4              Minecraft version"
    echo ""
    echo "server.properties keys (Minecraft):"
    echo "  server-port=25565   Game port"
    echo "  motd=\"My Server\"    Server name display"
    echo "  gamemode=survival  Game mode"
    echo "  difficulty=hard     Difficulty level"
    echo "  max-players=20      Player cap"
    echo "  ... plus many others"
    echo ""
    echo "Examples:"
    echo "  $0 config set ram=5G               # Set BOTH xms & xmx to 5GB (recommended)"
    echo "  $0 config set xmx=4G              # Increase Max RAM to 4GB only"
    echo "  $0 config set xms=2G              # Set Min RAM to 2GB"
    echo "  $0 config set backend=screen      # Switch to screen backend"
    echo "  $0 config set server-port=25566   # Change game port (triggers reload)"
    echo "  $0 config set motd=\"Hello World\"  # Update MOTD"
    echo "  $0 config init                    # Create .mc-info if missing"
    echo ""
    echo "Note: For interactive RAM change, use: $0 config init -> then edit manually or run $0 start for menu."
}

# ═══════════════════════════════════════════
#  Command: stats — server monitoring
# ═══════════════════════════════════════════
do_stats() {
    if ! is_running; then
        echo "[*] Server tidak jalan."
        exit 1
    fi

    echo "=== Server Stats ==="
    echo "Type:     $SERVER_TYPE"
    echo "Port:     $(get_port)"
    echo "Backend:  $BACKEND"
    echo ""

    # Memory usage (JVM process)
    local PID
    case "$BACKEND" in
        tmux)
            PID=$(tmux list-panes -t "$SESSION_NAME" -F "#{pane_pid}" 2>/dev/null | head -1)
            # get child java process
            PID=$(pgrep -P "$PID" java 2>/dev/null || echo "$PID")
            ;;
        screen)
            PID=$(screen -list 2>/dev/null | grep "$SESSION_NAME" | grep -oP '\d+' | head -1)
            PID=$(pgrep -P "$PID" java 2>/dev/null || echo "$PID")
            ;;
        nohup)
            PID=$(cat "$PID_FILE" 2>/dev/null)
            ;;
    esac

    if [ -n "$PID" ] && [ -d "/proc/$PID" ]; then
        local RSS_KB
        RSS_KB=$(awk '/VmRSS/{print $2}' /proc/$PID/status 2>/dev/null || echo "?")
        local THREADS
        THREADS=$(ls /proc/$PID/task 2>/dev/null | wc -l)
        echo "PID:      $PID"
        echo "RAM:      ${RSS_KB} KB ($(echo "scale=1; ${RSS_KB:-0}/1024" | bc 2>/dev/null || echo "?") MB)"
        echo "Threads:  $THREADS"
    fi

    echo ""

    # Try RCON for player list + TPS
    local RCON_PORT
    RCON_PORT=$(grep -E '^rcon.port=' server.properties 2>/dev/null | cut -d= -f2)
    local RCON_ENABLED
    RCON_ENABLED=$(grep -E '^enable-rcon=' server.properties 2>/dev/null | cut -d= -f2)

    if [ "$RCON_ENABLED" = "true" ] && command -v mcrcon &>/dev/null; then
        local RCON_PASS
        RCON_PASS=$(grep -E '^rcon.password=' server.properties 2>/dev/null | cut -d= -f2)
        local PORT_NUM
        PORT_NUM=$(get_port)

        echo "=== Via RCON ==="
        echo "Players:"
        mcrcon -H 127.0.0.1 -P "${RCON_PORT:-25575}" -p "$RCON_PASS" "list" 2>/dev/null || echo "  [RCON failed]"
        echo ""
        echo "TPS:"
        mcrcon -H 127.0.0.1 -P "${RCON_PORT:-25575}" -p "$RCON_PASS" "tps" 2>/dev/null || echo "  [TPS command requires Paper/Purpur]"
    else
        echo "RCON not enabled or mcrcon not installed."
        echo "  Enable:  ./start.sh config set enable-rcon true"
        echo "  Install: sudo apt install mcrcon  (or build from github.com/Tiiffi/mcrcon)"
    fi
}

# ═══════════════════════════════════════════
#  Command: world — backup/restore/list
# ═══════════════════════════════════════════
WORLD_BACKUP_DIR="${WORLD_BACKUP_DIR:-./world-backups}"

do_world() {
    local WDIR="${2:-}"
    local WORLD_DIR="${WDIR:-world}"

    case "${2:-help}" in
        backup)
            local LABEL="${3:-manual}"
            local TS
            TS=$(date +%Y%m%d_%H%M%S)
            mkdir -p "$WORLD_BACKUP_DIR"
            local NAME="${WORLD_DIR}-${LABEL}-${TS}.tar.gz"

            # Freeze saves if server running
            if is_running; then
                send_cmd "save-all"
                sleep 3
                send_cmd "save-off"
                sleep 1
            fi

            echo "[*] Backing up world: $WORLD_DIR..."
            tar czf "$WORLD_BACKUP_DIR/$NAME" --exclude='session.lock' "$WORLD_DIR/" 2>/dev/null

            # Unfreeze
            if is_running; then
                send_cmd "save-on"
            fi

            local SIZE
            SIZE=$(du -h "$WORLD_BACKUP_DIR/$NAME" | cut -f1)
            echo "[OK] $WORLD_BACKUP_DIR/$NAME ($SIZE)"

            # Auto-rotate (keep last 10)
            local COUNT
            COUNT=$(ls -1 "$WORLD_BACKUP_DIR"/*.tar.gz 2>/dev/null | wc -l)
            if [ "$COUNT" -gt 10 ]; then
                ls -1t "$WORLD_BACKUP_DIR"/*.tar.gz | tail -n +11 | xargs rm -f
                echo "  Cleaned old world backups (keeping last 10)"
            fi
            ;;
        restore)
            local BACKUP_FILE="$3"
            if [ -z "$BACKUP_FILE" ]; then
                echo "Available backups:"
                ls -1t "$WORLD_BACKUP_DIR"/*.tar.gz 2>/dev/null | head -10
                echo ""
                echo "Usage: $0 world restore <file>"
                exit 1
            fi

            if is_running; then
                echo "[ERROR] Stop server first!"
                exit 1
            fi

            # Backup current world before restore
            if [ -d "$WORLD_DIR" ]; then
                local TS
                TS=$(date +%Y%m%d_%H%M%S)
                mv "$WORLD_DIR" "${WORLD_DIR}.before-restore-${TS}"
                echo "  Current world moved to ${WORLD_DIR}.before-restore-${TS}"
            fi

            echo "[*] Restoring world from: $BACKUP_FILE"
            tar xzf "$BACKUP_FILE"
            echo "[OK] World restored. Start server to verify."
            ;;
        list)
            echo "=== World Backups ==="
            if [ -d "$WORLD_BACKUP_DIR" ]; then
                ls -lh "$WORLD_BACKUP_DIR"/*.tar.gz 2>/dev/null || echo "  No backups found."
            else
                echo "  No backups found."
            fi
            ;;
        delete)
            if [ -n "$3" ] && [ -f "$WORLD_BACKUP_DIR/$3" ]; then
                rm -f "$WORLD_BACKUP_DIR/$3"
                echo "[OK] Deleted: $3"
            else
                echo "Usage: $0 world delete <filename>"
            fi
            ;;
        help|*)
            echo "Usage: $0 world {backup|restore|list|delete} [args]"
            echo ""
            echo "Commands:"
            echo "  backup [label]            # Backup world (default: world/)"
            echo "  restore <file>            # Restore from backup file"
            echo "  list                      # List world backups"
            echo "  delete <filename>         # Delete a backup"
            echo ""
            echo "Options:"
            echo "  WORLD_DIR=<dir> ./start.sh world backup   # Custom world dir"
            echo "  WORLD_BACKUP_DIR=<dir> ./start.sh world backup  # Custom backup location"
            ;;
    esac
}

# ═══════════════════════════════════════════
#  Command: send — send raw command to server
# ═══════════════════════════════════════════
do_send() {
    if ! is_running; then
        echo "[*] Server tidak jalan."
        exit 1
    fi
    if [ -z "$2" ]; then
        echo "Usage: $0 send <command>"
        echo "Example: $0 send \"say Hello world\""
        exit 1
    fi
    shift
    send_cmd "$*"
    echo "[OK] Sent: $*"
}

# ═══════════════════════════════════════════
#  Command: plugins — Modrinth plugin management
# ═══════════════════════════════════════════
do_plugins() {
    # Delegate to plugins.sh if exists, otherwise inline
    if [ -f "$SCRIPT_DIR/plugins.sh" ]; then
        bash "$SCRIPT_DIR/plugins.sh" "$@"
    else
        echo "[ERROR] plugins.sh not found in $SCRIPT_DIR"
        echo "  Download: curl -fsSL https://raw.githubusercontent.com/bianvigano/mc-server/main/plugins.sh -o plugins.sh && chmod +x plugins.sh"
        exit 1
    fi
}

# ═══════════════════════════════════════════
#  Command: mcinfo — view/edit .mc-info
# ═══════════════════════════════════════════
do_mcinfo() {
    if [ -f "$INFO_FILE" ]; then
        echo "=== .mc-info (current) ==="
        cat "$INFO_FILE"
        echo ""
        echo "Edit .mc-info? (y/n)"
        read -p "> " answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            echo "Enter new content (end with a blank line):"
            local lines=()
            while IFS= read -r line; do
                if [ -z "$line" ]; then
                    break
                fi
                lines+=("$line")
            done
            printf "%s\n" "${lines[@]}" > "$INFO_FILE"
            echo "[OK] .mc-info updated."
            refresh_runtime_from_mcinfo
        fi
    else
        echo ".mc-info not found. Create a new one?"
        read -p "Create .mc-info now? (y/n) " ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            echo "Creating .mc-info with default values."
            cat > "$INFO_FILE" <<EOF
type=${SERVER_TYPE}
version=${MC_VERSION}
jar=${JAR}
backend=${BACKEND}
xms=${JAVA_XMS}
xmx=${JAVA_XMX}
auto_restart=${AUTO_RESTART}
java_flags=${JAVA_FLAGS}
EOF
            echo "[OK] .mc-info created."
            refresh_runtime_from_mcinfo
        else
            echo "No .mc-info created."
        fi
    fi
}

# ═══════════════════════════════════════════
#  Usage / help
# ═══════════════════════════════════════════
print_usage() {
    echo "Usage: $0 menu"
    echo ""
    echo "Server:"
    echo "  start              Start server"
    echo "  run                Run server directly in foreground"
    echo "  stop               Stop server"
    echo "  restart            Restart server"
    echo "  status             Server status"
    echo "  console            Attach to console"
    echo "  send <cmd>         Send command to server"
    echo "  rename <nama>      Ganti nama session (misal: minecraft1)"
    echo "  new <nama>         Bikin instance baru (world & port sendiri)"
    echo ""
    echo "Config:"
    echo "  config              Show all .mc-info + server.properties"
    echo "  config get <key>    Read one property (.mc-info or server.properties)"
    echo "  config set <key=val> Set property (RAM: ram/xmx/xms | Minecraft: port/motd/etc)"
    echo "  config init         Create .mc-info with default values if missing"
    echo "  config help         Show detailed help for config command"
    echo ""
    echo "Quick RAM examples:"
    echo "  ./start.sh config set ram=5G       # Set BOTH xms & xmx to 5GB (recommended)"
    echo "  ./start.sh config set xmx=4G      # Change Max RAM to 4GB only"
    echo "  ./start.sh config set backend=screen  # Switch to screen launcher"
    echo ""
    echo "Monitoring:"
    echo "  stats              RAM, PID, threads, RCON info"
    echo ""
    echo "World:"
    echo "  world backup [label]  Backup world"
    echo "  world restore <file>  Restore world"
    echo "  world list            List world backups"
    echo "  world delete <file>   Delete a backup"
    echo ""
    echo "Plugins:"
    echo "  plugins search <q>      Search Modrinth"
    echo "  plugins install <slug>  Install plugin"
    echo "  plugins remove <slug>   Remove plugin"
    echo "  plugins list            List installed"
    echo "  plugins update          Update all"
    echo ""
    echo "Menu:"
    echo "  menu               Show interactive menu"
    echo ""
    echo "Environment variables (override for ONE run only; .mc-info is the permanent source):"
    echo "  JAVA_XMS          Min RAM               (default: 1G)"
    echo "  JAVA_XMX          Max RAM               (default: 2G)"
    echo "  JAVA_VERSION      Java version (8/11/17/21) (default: system)"
    echo "  JAVA_FLAGS        JVM flags             (default: G1GC tuning)"
    echo "  AUTO_RESTART      true|false            (default: false)"
    echo "  SERVER_JAR        Jar filename          (auto-detected)"
    echo "  SESSION_NAME      Screen/tmux name      (default: minecraft, tersimpan di .mc-info)"
    echo "  FORCE_BACKEND     tmux|screen|nohup     (auto-detected)"
    echo "  WORLD_BACKUP_DIR  World backup location (default: ./world-backups)"
    echo ""
    echo "[TIP] Save permanently with config instead:"
    echo "  ./start.sh config set xmx=4G      # Permanently use 4GB RAM"
    echo "  ./start.sh config init            # Initialize .mc-info if missing"
    echo ""
}

# ═══════════════════════════════════════════
#  Interactive menu
# ═══════════════════════════════════════════
show_menu() {
    while true; do
        clear
        echo "=== Minecraft Server Manager ==="
        echo "Server: $SERVER_TYPE"
        echo "Jar:    $JAR"
        echo "Backend: $BACKEND (session: $SESSION_NAME)"
        echo "RAM:    $JAVA_XMS - $JAVA_XMX"
        echo "Java:   ${JAVA_VERSION:-system} ($JAVA_BIN)"
        echo "Java Flags: $JAVA_FLAGS"
        echo ""
        echo "1) Start server"
        echo "2) Stop server"
        echo "3) Restart server"
        echo "4) Status"
        echo "5) Console / Attach"
        echo "6) Configure server.properties"
        echo "7) Stats / Monitor"
        echo "8) World backup/restore"
        echo "9) Plugin management (Modrinth)"
        echo "10) Send command to server"
        echo "11) Change backend (tmux/screen/nohup)"
        echo "12) Change Java memory (XMS/XMX)"
        echo "13) Change Java version"
        echo "14) View/Edit .mc-info"
        echo "15) Ganti nama session"
        echo "16) Daftar nama server baru (misal: minecraft1)"
        echo "17) Exit"
        echo ""
        read -p "Pilih opsi [1-17]: " choice
        case "$choice" in
            1) do_start ;;
            2) do_stop ;;
            3) do_stop; sleep 2; do_start ;;
            4) do_status ;;
            5) do_console ;;
            6)
                echo "Config menu:"
                echo "  a) Lihat semua (.mc-info + server.properties)"
                echo "  b) Baca nilai satu property"
                echo "  c) Set nilai (RAM: xmx/xms | Minecraft: server-port/motd/difficulty/etc)"
                echo "  d) Inisialisasi .mc-info jika belum ada"
                echo "  e) Bantuan lengkap"
                read -p "Pilih [a-e]: " subc
                case "$subc" in
                    a) do_config ;;
                    b)
                        echo "Ketik key dari .mc-info atau server.properties:"
                        echo "  mcinfo-keys: xms, xmx, backend, auto_restart, java_flags, session_name"
                        echo "  prop-keys:   server-port, motd, gamemode, difficulty, max-players, online-mode, pvp"
                        read -p "Key: " key
                        do_config get "$key"
                        ;;
                    c)
                        echo "Format: key=value"
                        echo "Contoh: xmx=4G           # Ubah Max RAM ke 4GB (saves to .mc-info)"
                        echo "        backend=screen   # Ubah launcher backend"
                        echo "        server-port=25566  # Ubah game port (triggers reload)"
                        read -p "Key=Value: " kv
                        if [[ "$kv" == *=* ]]; then
                            do_config set "$kv"
                        else
                            echo "[ERROR] Format harus key=value (contoh: xmx=4G)"; exit 1
                        fi
                        ;;
                    d)
                        do_config init
                        ;;
                    e) do_config help ;;
                    *) echo "Pilihan tidak valid." ;;
                esac
                read -p "Tekan Enter untuk lanjut..." ;;
            7) do_stats ;;
            8)
                echo "World menu:"
                echo "  a) Backup world"
                echo "  b) Restore world"
                echo "  c) Daftar backup"
                echo "  d) Hapus backup"
                read -p "Pilih [a-d]: " subc
                case "$subc" in
                    a)
                        read -p "Label (kosong untuk manual): " label
                        do_world backup "$label"
                        ;;
                    b)
                        ls -1t "$WORLD_BACKUP_DIR"/*.tar.gz 2>/dev/null | head -5
                        read -p "File backup (path lengkap atau hanya nama): " file
                        # if only filename given, prepend dir
                        if [[ "$file" != */* ]]; then
                            file="$WORLD_BACKUP_DIR/$file"
                        fi
                        do_world restore "$file"
                        ;;
                    c) do_world list ;;
                    d)
                        ls -1t "$WORLD_BACKUP_DIR"/*.tar.gz 2>/dev/null | head -5
                        read -p "File backup untuk dihapus: " file
                        if [[ "$file" != */* ]]; then
                            file="$WORLD_BACKUP_DIR/$file"
                        fi
                        do_world delete "$(basename "$file")"
                        ;;
                    *) echo "Pilihan tidak valid." ;;
                esac
                read -p "Tekan Enter untuk lanjut..." ;;
            9) shift; do_plugins "$@" ;;
            10)
                read -p "Perintah yang akan dikirim: " cmd
                do_send "$cmd"
                read -p "Tekan Enter untuk lanjut..." ;;
            11)
                echo "Backend saat ini: $BACKEND"
                echo "Pilih backend baru:"
                echo "  1) tmux"
                echo "  2) screen"
                echo "  3) nohup"
                read -p "Pilih [1-3]: " be
                case "$be" in
                    1) BACKEND=tmux; mcinfo_set backend "$BACKEND"; echo "[OK] backend=$BACKEND disimpan ke $INFO_FILE" ;;
                    2) BACKEND=screen; mcinfo_set backend "$BACKEND"; echo "[OK] backend=$BACKEND disimpan ke $INFO_FILE" ;;
                    3) BACKEND=nohup; mcinfo_set backend "$BACKEND"; echo "[OK] backend=$BACKEND disimpan ke $INFO_FILE" ;;
                    *) echo "Pilihan tidak valid." ;;
                esac
                echo "Backend akan berlaku pada perintah berikutnya."
                read -p "Tekan Enter untuk lanjut..." ;;
            12)
                echo "RAM saat ini: XMS=$JAVA_XMS, XMX=$JAVA_XMX"
                read -p "XMS (misal 1G): " xms
                read -p "XMX (misal 2G): " xmx
                if [ -n "$xms" ]; then
                    JAVA_XMS="$xms"
                    mcinfo_set xms "$JAVA_XMS"
                fi
                if [ -n "$xmx" ]; then
                    JAVA_XMX="$xmx"
                    mcinfo_set xmx "$JAVA_XMX"
                fi
                if [ -n "$xms" ] || [ -n "$xmx" ]; then
                    echo "[OK] RAM disimpan ke $INFO_FILE"
                fi
                echo "RAM akan diperbarui pada start berikutnya."
                read -p "Tekan Enter untuk lanjut..." ;;
            13)
                echo "Java version saat ini: ${JAVA_VERSION:-system default (21)}"
                echo "Versi yang tersedia: 8, 11, 17, 21"
                read -p "Pilih versi Java (kosong untuk system default): " jv
                if [ -n "$jv" ]; then
                    JAVA_VERSION="$jv"
                else
                    JAVA_VERSION=""
                fi
                JAVA_BIN="$(resolve_java_bin "$JAVA_VERSION")"
                mcinfo_set java_version "$JAVA_VERSION"
                echo "[OK] Java version=$JAVA_VERSION disimpan ke $INFO_FILE"
                echo "    Binary: $JAVA_BIN"
                read -p "Tekan Enter untuk lanjut..."
                ;;
            14) do_mcinfo ;;
            15)
                read -rp "Nama session baru: " nn
                if [ -n "$nn" ]; then
                    set_session_name "$nn" || true
                fi
                read -p "Tekan Enter untuk lanjut..."
                ;;
            16)
                prompt_new_instance
                read -p "Tekan Enter untuk lanjut..."
                ;;
            17)
                echo "Keluar..."
                break
                ;;
            *) echo "Pilihan tidak valid." ; read -p "Tekan Enter untuk lanjut..." ;;
        esac
    done
}

# ═══════════════════════════════════════════
#  Entry point
# ═══════════════════════════════════════════
if [ -z "$1" ]; then
    # No arguments -> show interactive menu
    print_usage
else
    case "$1" in
        start)          do_start ;;
        run)            do_run ;;
        stop)           do_stop ;;
        restart)        do_stop; sleep 2; do_start ;;
        status)         do_status ;;
        console|attach) do_console ;;
        config)         do_config "$@" ;;
        stats|monitor)  do_stats ;;
        world)          do_world "$@" ;;
        send|cmd)       do_send "$@" ;;
        rename)         shift; set_session_name "${1:-}" ;;
        new)
            shift
            if [ -z "${1:-}" ]; then
                echo "Server terdaftar di $INFO_FILE:"
                list_servers
                [ -d "$SCRIPT_DIR/.instances" ] && echo "  (folder .instances/ versi lama tidak dipakai lagi, boleh dihapus)"
                echo "Usage: $0 new <nama-server>"
                exit 1
            fi
            start_new_instance "$1"
            ;;
        plugins|plugin) shift; do_plugins "$@" ;;
        mcinfo)         do_mcinfo ;;
        menu)           show_menu ;;
        *)
            print_usage
            ;;
    esac
fi
