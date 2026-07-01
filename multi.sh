#!/bin/bash
# multi.sh — Multi-server manager
# Manage multiple MC server instances from one mc-server repo
# Usage: ./multi.sh {start|stop|status|console|cmd} <instance> [args]
#
# Each instance is a directory with its own server.properties, .mc-type, .server-jar, etc.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTANCES_DIR="${INSTANCES_DIR:-.}"

# ═══════════════════════════════════════════
#  Find all instances
# ═══════════════════════════════════════════
list_instances() {
    local FOUND=0
    for dir in "$INSTANCES_DIR"/*/; do
        if [ -f "$dir/.mc-type" ] && [ -f "$dir/.server-jar" ]; then
            local NAME
            NAME=$(basename "$dir")
            local TYPE
            TYPE=$(cat "$dir/.mc-type")
            local VER
            VER=$(cat "$dir/.mc-version" 2>/dev/null || echo "?")
            local PORT
            PORT=$(grep -E '^server-port=' "$dir/server.properties" 2>/dev/null | cut -d= -f2 || echo "25565")

            # Check running
            local STATUS="STOPPED"
            if [ -f "$dir/.server.pid" ] && kill -0 "$(cat "$dir/.server.pid")" 2>/dev/null; then
                STATUS="RUNNING"
            elif tmux has-session -t "mc-${NAME}" 2>/dev/null; then
                STATUS="RUNNING"
            fi

            printf "  %-20s %-8s %-8s %-6s %s\n" "$NAME" "$TYPE" "$VER" "$PORT" "$STATUS"
            FOUND=$((FOUND + 1))
        fi
    done

    if [ "$FOUND" -eq 0 ]; then
        echo "  No instances found."
        echo "  Run: ./setup.sh --type <type> --dir ./<name>"
    fi
}

# ═══════════════════════════════════════════
#  Run command on instance
# ═══════════════════════════════════════════
run_instance() {
    local INSTANCE="$1"
    shift
    local DIR="$INSTANCES_DIR/$INSTANCE"

    if [ ! -d "$DIR" ]; then
        echo "[ERROR] Instance not found: $INSTANCE"
        echo "Available:"
        list_instances
        exit 1
    fi

    cd "$DIR"

    if [ -f "start.sh" ]; then
        SESSION_NAME="mc-${INSTANCE}" ./start.sh "$@"
    else
        echo "[ERROR] start.sh not found in $DIR"
        exit 1
    fi
}

# ═══════════════════════════════════════════
#  Bulk operations
# ═══════════════════════════════════════════
do_all() {
    local CMD="$1"
    echo "[*] Running '$CMD' on all instances..."
    for dir in "$INSTANCES_DIR"/*/; do
        if [ -f "$dir/.mc-type" ] && [ -f "$dir/start.sh" ]; then
            local NAME
            NAME=$(basename "$dir")
            echo ""
            echo "=== $NAME ==="
            cd "$dir"
            SESSION_NAME="mc-${NAME}" ./start.sh "$CMD" 2>&1 || true
        fi
    done
}

# ═══════════════════════════════════════════
#  Entry point
# ═══════════════════════════════════════════
case "${1:-}" in
    list|ls)
        echo "=== MC Server Instances ==="
        echo ""
        printf "  %-20s %-8s %-8s %-6s %s\n" "INSTANCE" "TYPE" "VERSION" "PORT" "STATUS"
        printf "  %-20s %-8s %-8s %-6s %s\n" "--------" "----" "-------" "----" "------"
        list_instances
        ;;
    start|stop|restart|status|console|config|stats|world|send|plugins)
        if [ -z "${2:-}" ]; then
            echo "Usage: $0 $1 <instance>"
            echo ""
            echo "Available instances:"
            list_instances
            exit 1
        fi
        run_instance "$2" "$@"
        ;;
    all)
        if [ -z "${2:-}" ]; then
            echo "Usage: $0 all {start|stop|status}"
            exit 1
        fi
        do_all "$2"
        ;;
    *)
        echo "Usage: $0 {command} <instance>"
        echo ""
        echo "Commands:"
        echo "  list                      List all instances"
        echo "  start <instance>          Start instance"
        echo "  stop <instance>           Stop instance"
        echo "  restart <instance>        Restart instance"
        echo "  status <instance>         Instance status"
        echo "  console <instance>        Attach to console"
        echo "  config <instance> [args]  Manage config"
        echo "  stats <instance>          Server stats"
        echo "  world <instance> [args]   World management"
        echo "  send <instance> <cmd>     Send command"
        echo "  plugins <instance> [args] Plugin management"
        echo ""
        echo "Bulk:"
        echo "  all start                 Start all instances"
        echo "  all stop                  Stop all instances"
        echo "  all status                Status of all instances"
        echo ""
        echo "Examples:"
        echo "  $0 list"
        echo "  $0 start survival"
        echo "  $0 status survival"
        echo "  $0 send survival \"say Hello\""
        echo "  $0 plugins creative search worldedit"
        echo "  $0 all stop"
        ;;
esac
