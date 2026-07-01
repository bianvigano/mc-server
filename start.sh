#!/bin/bash
# start.sh — Universal MC server launcher
# Usage: ./start.sh {start|stop|restart|status|console}
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
if [ -n "$SERVER_JAR" ]; then
    JAR="$SERVER_JAR"
elif [ -f ".server-jar" ]; then
    JAR="$(cat .server-jar)"
else
    JAR="$(ls -1 paper.jar purpur.jar fabric-server-*.jar 2>/dev/null | head -1)"
fi

if [ -z "$JAR" ] || [ ! -f "$JAR" ]; then
    echo "[ERROR] Server jar not found. Run setup.sh first or set SERVER_JAR env var."
    exit 1
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
#  Commands
# ═══════════════════════════════════════════
do_start() {
    if is_running; then
        echo "[*] Server sudah jalan ($BACKEND: $SESSION_NAME)"
        return
    fi

    auto_kill_port

    echo "[*] Starting server..."
    echo "    Jar:    $JAR"
    echo "    RAM:    $JAVA_XMS - $JAVA_XMX"
    echo "    Backend: $BACKEND"

    case "$BACKEND" in
        tmux)
            tmux new-session -d -s "$SESSION_NAME" "java $JAVA_FLAGS -Xms$JAVA_XMS -Xmx$JAVA_XMX -jar $JAR nogui"
            echo "    Attach: tmux attach -t $SESSION_NAME"
            echo "    Detach: Ctrl+B, D"
            ;;
        screen)
            screen -dmS "$SESSION_NAME" java $JAVA_FLAGS -Xms"$JAVA_XMS" -Xmx"$JAVA_XMX" -jar "$JAR" nogui
            echo "    Attach: screen -r $SESSION_NAME"
            echo "    Detach: Ctrl+A, D"
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

    case "$BACKEND" in
        tmux)
            tmux send-keys -t "$SESSION_NAME" "save-all" Enter
            sleep 2
            tmux send-keys -t "$SESSION_NAME" "stop" Enter
            ;;
        screen)
            screen -S "$SESSION_NAME" -p 0 -X stuff "save-all^M"
            sleep 2
            screen -S "$SESSION_NAME" -p 0 -X stuff "stop^M"
            ;;
        nohup)
            if [ -f "$PID_FILE" ]; then
                kill "$(cat "$PID_FILE")" 2>/dev/null || true
            fi
            ;;
    esac

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
#  Entry point
# ═══════════════════════════════════════════
case "${1}" in
    start)          do_start ;;
    stop)           do_stop ;;
    restart)        do_stop; sleep 2; do_start ;;
    status)         do_status ;;
    console|attach) do_console ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|console}"
        echo ""
        echo "Env vars:"
        echo "  JAVA_XMS       Min RAM       (default: 1G)"
        echo "  JAVA_XMX       Max RAM       (default: 2G)"
        echo "  JAVA_FLAGS     JVM flags     (default: G1GC tuning)"
        echo "  SERVER_JAR     Jar filename  (auto-detected)"
        echo "  SESSION_NAME   Screen/tmux name (default: minecraft)"
        echo "  FORCE_BACKEND  tmux|screen|nohup (auto-detected)"
        echo ""
        echo "Examples:"
        echo "  ./start.sh start"
        echo "  JAVA_XMX=4G ./start.sh start"
        echo "  FORCE_BACKEND=nohup ./start.sh start"
        ;;
esac
