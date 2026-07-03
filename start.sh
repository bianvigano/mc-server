#!/bin/bash
# start.sh — Universal MC server launcher
# Usage: ./start.sh {start|stop|restart|status|console|config|stats|world|send|plugins|menu}
# Auto-detects: tmux > screen > nohup fallback

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ═══════════════════════════════════════════
#  Config — override via env vars
# ═══════════════════════════════════════════
SESSION_NAME="${SESSION_NAME:-minecraft}"
JAVA_XMS="${JAVA_XMS:-1G}"
JAVA_XMX="${JAVA_XMX:-2G}"
JAVA_FLAGS="${JAVA_FLAGS:--XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200}"
PID_FILE=".server.pid"

# Auto-detect server jar
# Read .mc-info if exists
if [ -f ".mc-info" ]; then
    SERVER_TYPE="$(grep '^type=' .mc-info | cut -d= -f2)"
    MC_VERSION="$(grep '^version=' .mc-info | cut -d= -f2)"
    SERVER_JAR_VAL="$(grep '^jar=' .mc-info | cut -d= -f2)"
fi
SERVER_TYPE="${SERVER_TYPE:-unknown}"

# Set default Java flags based on server type
set_java_flags_by_type() {
    case "$SERVER_TYPE" in
        paper|purpur)
            # Paper/PaperSpigot defaults are fine
            JAVA_FLAGS="${JAVA_FLAGS:--XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200}"
            ;;
        fabric)
            # Fabric often needs a bit more metaspace
            JAVA_FLAGS="${JAVA_FLAGS:--XX:+UseG1GC -XX:+UnlockExperimentalVMOptions -XX:MaxGCPauseMillis=100 -XX:+DisableExplicitGC -XX:MaxMetaspaceSize=256M}"
            ;;
        forge)
            # Forge may need more metaspace and different GC
            JAVA_FLAGS="${JAVA_FLAGS:--XX:+UseG1GC -XX:+UnlockExperimentalVMOptions -XX:MaxGCPauseMillis=100 -XX:+DisableExplicitGC -XX:MaxMetaspaceSize=512M}"
            ;;
        fabric|forge|paper|purpur|spigot|bukkit|vanilla)
            # generic fallback
            :
            ;;
        *)
            # unknown type, keep default
            :
            ;;
    esac
}
# Apply type-specific flags if JAVA_FLAGS not explicitly set by user
if [ -z "${JAVA_FLAGS+x}" ]; then
    set_java_flags_by_type
fi

# Auto-detect server jar
if [ -n "$SERVER_JAR" ]; then
    JAR="$SERVER_JAR"
elif [ -n "$SERVER_JAR_VAL" ]; then
    JAR="$SERVER_JAR_VAL"
else
    JAR="$(ls -1 paper.jar purpur.jar craftbukkit.jar spigot.jar fabric-server-*.jar 2>/dev/null | head -1)"
fi

# ═══════════════════════════════════════════
#  Auto-port kill
# ═══════════════════════════════════════════
get_port() {
    grep -E '^server-port=' server.properties 2>/dev/null | cut -d= -f2 || echo "25565"
}

auto_kill_port() {
    local PORT
    PORT=$(get_port)
    local PID
    PID=$(lsof -ti :"${PORT}" 2>/dev/null || true)
    if [ -n "$PID" ]; then
        echo "[!] Port ${PORT} sudah dipakai. Killing: ${PID}"
        kill "$PID" 2>/dev/null || true
        sleep 2
    fi
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

BACKEND="${FORCE_BACKEND:-$(detect_backend)}"

is_running() {
    case "$BACKEND" in
        tmux)   tmux has-session -t "$SESSION_NAME" 2>/dev/null ;;
        screen) screen -list 2>/dev/null | grep -q "$SESSION_NAME" ;;
        nohup)  [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null ;;
    esac
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

# ═══════════════════════════════════════════
#  Commands: start/stop/restart/status/console
# ═══════════════════════════════════════════
do_start() {
    if is_running; then
        echo "[*] Server sudah jalan ($BACKEND: $SESSION_NAME)"
        return
    fi

    auto_kill_port

    echo "[*] Starting server..."
    echo "    Type:    $SERVER_TYPE"
    echo "    Jar:     $JAR"
    echo "    Port:    $(get_port)"
    echo "    RAM:     $JAVA_XMS - $JAVA_XMX"
    echo "    Backend: $BACKEND"
    echo "    Java Flags: $JAVA_FLAGS"

    case "$BACKEND" in
        tmux)
            tmux new-session -d -s "$SESSION_NAME" "java $JAVA_FLAGS -Xms$JAVA_XMS -Xmx$JAVA_XMX -jar $JAR nogui"
            echo "    Attach: tmux attach -t $SESSION_NAME"
            ;;
        screen)
            screen -dmS "$SESSION_NAME" java $JAVA_FLAGS -Xms"$JAVA_XMS" -Xmx"$JAVA_XMX" -jar "$JAR" nogui
            echo "    Attach: screen -r $SESSION_NAME"
            ;;
        nohup)
            mkdir -p logs
            nohup java $JAVA_FLAGS -Xms"$JAVA_XMS" -Xmx"$JAVA_XMX" -jar "$JAR" nogui > logs/console.log 2>&1 &
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
#  Command: config — read/set/view server.properties
# ═══════════════════════════════════════════
do_config() {
    local PROP_FILE="server.properties"
    if [ ! -f "$PROP_FILE" ]; then
        echo "[ERROR] $PROP_FILE not found. Run server first to generate it."
        exit 1
    fi

    case "${2:-}" in
        "")
            # Show all properties
            echo "=== server.properties ==="
            grep -v '^#' "$PROP_FILE" | grep -v '^$' | sort
            ;;
        list)
            echo "=== server.properties ==="
            grep -v '^#' "$PROP_FILE" | grep -v '^$' | sort
            ;;
        get)
            if [ -z "$3" ]; then
                echo "Usage: $0 config get <key>"
                exit 1
            fi
            grep -E "^${3}=" "$PROP_FILE" 2>/dev/null || echo "[NOT FOUND] $3"
            ;;
        set)
            if [ -z "$3" ] || [ -z "$4" ]; then
                echo "Usage: $0 config set <key> <value>"
                exit 1
            fi
            local KEY="$3"
            shift 3
            local VALUE="$*"

            if grep -qE "^${KEY}=" "$PROP_FILE"; then
                sed -i "s|^${KEY}=.*|${KEY}=${VALUE}|" "$PROP_FILE"
            else
                echo "${KEY}=${VALUE}" >> "$PROP_FILE"
            fi
            echo "[OK] ${KEY}=${VALUE}"

            # Notify running server
            if is_running; then
                send_cmd "reload"
                echo "[*] Server reload sent."
            fi
            ;;
        help)
            echo "Usage: $0 config [list|get|set] [key] [value]"
            echo ""
            echo "Examples:"
            echo "  $0 config                           # Show all"
            echo "  $0 config get server-port            # Read one"
            echo "  $0 config set server-port 25566      # Set value"
            echo "  $0 config set motd \"My Server\"       # Set with spaces"
            echo ""
            echo "Common keys:"
            echo "  server-port, gamemode, difficulty, max-players,"
            echo "  motd, online-mode, pvp, view-distance, level-seed"
            ;;
        *)
            # Treat as key shorthand: ./start.sh config server-port
            grep -E "^${2}=" "$PROP_FILE" 2>/dev/null || echo "[NOT FOUND] $2"
            ;;
    esac
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
#  Interactive menu
# ═══════════════════════════════════════════
show_menu() {
    while true; do
        clear
        echo "=== Minecraft Server Manager ==="
        echo "Server: $SERVER_TYPE"
        echo "Jar:    $JAR"
        echo "Backend: $BACKEND"
        echo "RAM:    $JAVA_XMS - $JAVA_XMX"
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
        echo "13) Exit"
        echo ""
        read -p "Pilih opsi [1-13]: " choice
        case "$choice" in
            1) do_start ;;
            2) do_stop ;;
            3) do_stop; sleep 2; do_start ;;
            4) do_status ;;
            5) do_console ;;
            6)
                echo "Config menu:"
                echo "  a) Lihat semua properti"
                echo "  b) Ambil nilai properti"
                echo "  c) Set properti"
                echo "  d) Bantuan"
                read -p "Pilih [a-d]: " subc
                case "$subc" in
                    a) do_config ;;
                    b)
                        read -p "Key: " key
                        do_config get "$key"
                        ;;
                    c)
                        read -p "Key: " key
                        read -p "Value: " val
                        do_config set "$key" "$val"
                        ;;
                    d) do_config help ;;
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
                    1) export FORCE_BACKEND=tmux ;;
                    2) export FORCE_BACKEND=screen ;;
                    3) export FORCE_BACKEND=nohup ;;
                    *) echo "Pilihan tidak valid." ;;
                esac
                echo "Backend akan berlaku pada perintah berikutnya."
                read -p "Tekan Enter untuk lanjut..." ;;
            12)
                echo "RAM saat ini: XMS=$JAVA_XMS, XMX=$JAVA_XMX"
                read -p "XMS (misal 1G): " xms
                read -p "XMX (misal 2G): " xmx
                if [ -n "$xms" ]; then export JAVA_XMS="$xms"; fi
                if [ -n "$xmx" ]; then export JAVA_XMX="$xmx"; fi
                echo "RAM akan diperbarui pada start berikutnya."
                read -p "Tekan Enter untuk lanjut..." ;;
            13)
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
    show_menu
else
    case "$1" in
        start)          do_start ;;
        stop)           do_stop ;;
        restart)        do_stop; sleep 2; do_start ;;
        status)         do_status ;;
        console|attach) do_console ;;
        config)         do_config "$@" ;;
        stats|monitor)  do_stats ;;
        world)          do_world "$@" ;;
        send|cmd)       do_send "$@" ;;
        plugins|plugin) shift; do_plugins "$@" ;;
        *)
            echo "Usage: $0 {command}"
            echo ""
            echo "Server:"
            echo "  start              Start server"
            echo "  stop               Stop server"
            echo "  restart            Restart server"
            echo "  status             Server status"
            echo "  console            Attach to console"
            echo "  send <cmd>         Send command to server"
            echo ""
            echo "Config:"
            echo "  config             Show all properties"
            echo "  config get <key>   Read a property"
            echo "  config set <key> <val>  Set a property"
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
            echo "  plugins search <q>    Search Modrinth"
            echo "  plugins install <slug>  Install plugin"
            echo "  plugins remove <slug>   Remove plugin"
            echo "  plugins list          List installed"
            echo "  plugins update        Update all"
            echo ""
            echo "Interactive mode:"
            echo "  (no arguments)       Show menu"
            ;;
    esac
fi