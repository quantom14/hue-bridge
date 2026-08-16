#!/bin/bash
set -euo pipefail

BACKUP_SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_SRC_DIR="$(dirname "$BACKUP_SRC_DIR")"

# --- Rotate log if too big (before tee opens it) ---
LOG_FILE="$BACKUP_SRC_DIR/backup.log"
MAX_SIZE=$((10 * 1024 * 1024)) # 10 MB
if [ -f "$LOG_FILE" ]; then
    if stat --version >/dev/null 2>&1; then
        FILE_SIZE=$(stat -c%s "$LOG_FILE")  # Linux
    else
        FILE_SIZE=$(stat -f%z "$LOG_FILE")  # macOS/BSD
    fi
    if [ "$FILE_SIZE" -gt "$MAX_SIZE" ]; then
        mv "$LOG_FILE" "$LOG_FILE.$(date +%Y%m%d-%H%M%S)"
        touch "$LOG_FILE"
    fi
fi

# --- Logging ---
exec > >(tee -a "$LOG_FILE") 2>&1
echo "[INFO] Starting backup at $(date)"

# --- Load environment ---
echo "[INFO] Loading environment variables from .env file"
set -a
source "$PROJECT_SRC_DIR/.env"
set +a

# --- Paths ---
BACKUP_ROOT="$BACKUP_SRC_DIR/backups"
mkdir -p "$BACKUP_ROOT"

# --- Clean up leftover staging dirs from previous failed runs ---
echo "[INFO] Removing any stale staging folders..."
find "$BACKUP_ROOT" -maxdepth 1 -type d -name ".staging_*" -exec rm -rf {} +

# --- Timestamped backup folder (staged while in progress) ---
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_NAME="backup_$TIMESTAMP"
STAGING_DIR="$BACKUP_ROOT/.staging_$TIMESTAMP"
mkdir -p "$STAGING_DIR"
echo "[INFO] Backup staging folder created at $STAGING_DIR"

# --- Backup PostgreSQL database ---
# No volume archives here: unlike Paperless, the pgdata volume holds nothing
# the dump does not already contain, and there is no media to preserve.
echo "[INFO] Dumping PostgreSQL database..."
docker compose -f "$PROJECT_SRC_DIR/db/docker-compose.yml" exec -T postgres \
    pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" > "$STAGING_DIR/db-$TIMESTAMP.sql"
echo "[INFO] Database dump completed."

# --- Sanity check: a dump with no COPY block is not a usable backup ---
if ! grep -q "COPY public.readings" "$STAGING_DIR/db-$TIMESTAMP.sql"; then
    echo "[ERROR] Dump contains no readings data, aborting"
    rm -rf "$STAGING_DIR"
    exit 1
fi
DUMP_SIZE=$(du -h "$STAGING_DIR/db-$TIMESTAMP.sql" | cut -f1)
READING_COUNT=$(docker compose -f "$PROJECT_SRC_DIR/db/docker-compose.yml" exec -T postgres \
    psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc 'SELECT count(*) FROM readings')
echo "[INFO] Dump size $DUMP_SIZE, $READING_COUNT readings"

# --- Compress ---
echo "[INFO] Compressing dump..."
gzip "$STAGING_DIR/db-$TIMESTAMP.sql"
echo "[INFO] Compression completed."

# --- Publish: atomic rename, then marker ---
FINAL_DIR="$BACKUP_ROOT/$BACKUP_NAME"
mv "$STAGING_DIR" "$FINAL_DIR"
echo "[INFO] Backup published to $FINAL_DIR"

echo "$BACKUP_NAME" > "$BACKUP_ROOT/.LAST_BACKUP_OK.tmp"
mv "$BACKUP_ROOT/.LAST_BACKUP_OK.tmp" "$BACKUP_ROOT/LAST_BACKUP_OK"
echo "[INFO] Marker updated: $BACKUP_NAME"

# --- Cleanup old backups (keep last 180) ---
MAX_BACKUPS=180
echo "[INFO] Cleaning up old backups, keeping last $MAX_BACKUPS"
BACKUP_DIRS=()
while IFS= read -r dir; do
    BACKUP_DIRS+=("$dir")
done < <(find "$BACKUP_ROOT" -maxdepth 1 -type d -name "backup_*" | sort)

NUM_BACKUPS=${#BACKUP_DIRS[@]}
if [ "$NUM_BACKUPS" -lt "$MAX_BACKUPS" ]; then
    echo "[INFO] Found only $NUM_BACKUPS backups so none will be deleted"
else
    NUM_TO_DELETE=$((NUM_BACKUPS - MAX_BACKUPS))
    echo "[INFO] Deleting $NUM_TO_DELETE old backup(s)"
    for OLD in "${BACKUP_DIRS[@]:0:$NUM_TO_DELETE}"; do
        echo "[INFO] Removing $OLD"
        rm -rf "$OLD"
    done
fi

echo "[INFO] Backup completed successfully at $(date). All files are in $FINAL_DIR"