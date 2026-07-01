#!/bin/bash
# backup.sh — Universal MC server backup
# Usage: ./backup.sh [label]
# Cron:  0 */4 * * * /path/to/backup.sh auto
#
# Env vars:
#   BACKUP_DIR    Custom backup location (default: ../minecraft-backups)
#   MAX_BACKUPS   Keep last N backups (default: 24)
#   SESSION_NAME  tmux/screen session name (default: minecraft)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ═══════════════════════════════════════════
#  Config
# ═══════════════════════════════════════════
SERVER_DIR="$SCRIPT_DIR"
BACKUP_DIR="${BACKUP_DIR:-$(dirname "$SCRIPT_DIR")/minecraft-backups}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LABEL="${1:-manual}"
SESSION_NAME="${SESSION_NAME:-minecraft}"
MAX_BACKUPS="${MAX_BACKUPS:-24}"

# Detect server type
if [ -f ".mc-type" ]; then
    SERVER_TYPE="$(cat .mc-type)"
elif ls paper.jar &>/dev/null; then
    SERVER_TYPE="paper"
elif ls purpur.jar &>/dev/null; then
    SERVER_TYPE="purpur"
elif ls fabric-server-*.jar &>/dev/null; then
    SERVER_TYPE="fabric"
else
    SERVER_TYPE="mc"
fi

# Detect MC version
if [ -f ".mc-version" ]; then
    MC_VER="$(cat .mc-version)"
else
    MC_VER="unknown"
fi

BACKUP_NAME="${SERVER_TYPE}-mc${MC_VER}-${LABEL}-${TIMESTAMP}"

mkdir -p "$BACKUP_DIR"

echo "[*] Starting backup: $BACKUP_NAME"
echo "    From: $SERVER_DIR"
echo "    To:   $BACKUP_DIR"

# ═══════════════════════════════════════════
#  Tell server to save + pause saves
# ═══════════════════════════════════════════
save_freeze() {
    if command -v tmux &>/dev/null && tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        tmux send-keys -t "$SESSION_NAME" "say [Backup] Starting backup..." Enter
        tmux send-keys -t "$SESSION_NAME" "save-all" Enter
        sleep 5
        tmux send-keys -t "$SESSION_NAME" "save-off" Enter
        sleep 3
    elif screen -list 2>/dev/null | grep -q "$SESSION_NAME"; then
        screen -S "$SESSION_NAME" -p 0 -X stuff "say [Backup] Starting backup...^M"
        screen -S "$SESSION_NAME" -p 0 -X stuff "save-all^M"
        sleep 5
        screen -S "$SESSION_NAME" -p 0 -X stuff "save-off^M"
        sleep 3
    fi
}

save_unfreeze() {
    if command -v tmux &>/dev/null && tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        tmux send-keys -t "$SESSION_NAME" "save-on" Enter
        tmux send-keys -t "$SESSION_NAME" "say [Backup] Done!" Enter
    elif screen -list 2>/dev/null | grep -q "$SESSION_NAME"; then
        screen -S "$SESSION_NAME" -p 0 -X stuff "save-on^M"
        screen -S "$SESSION_NAME" -p 0 -X stuff "say [Backup] Done!^M"
    fi
}

# ═══════════════════════════════════════════
#  Backup
# ═══════════════════════════════════════════
save_freeze

cd "$SERVER_DIR"
tar czf "$BACKUP_DIR/${BACKUP_NAME}.tar.gz" \
    --exclude='libraries' \
    --exclude='*.jar' \
    --exclude='logs' \
    --exclude='crash-reports' \
    --exclude='world/session.lock' \
    .

save_unfreeze

# ═══════════════════════════════════════════
#  Cleanup old backups
# ═══════════════════════════════════════════
if [ -d "$BACKUP_DIR" ]; then
    BACKUP_COUNT=$(ls -1 "$BACKUP_DIR"/*.tar.gz 2>/dev/null | wc -l)
    if [ "$BACKUP_COUNT" -gt "$MAX_BACKUPS" ]; then
        ls -1t "$BACKUP_DIR"/*.tar.gz | tail -n +$((MAX_BACKUPS + 1)) | xargs rm -f
        echo "  Cleaned old backups (keeping last $MAX_BACKUPS)"
    fi
fi

echo "[*] Backup complete: $BACKUP_DIR/${BACKUP_NAME}.tar.gz"
echo "  Size: $(du -h "$BACKUP_DIR/${BACKUP_NAME}.tar.gz" | cut -f1)"
