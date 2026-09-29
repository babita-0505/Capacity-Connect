#!/usr/bin/env bash
# Capacity Connect - Automated Daily Database Backup Script
set -e

BACKUP_DIR="${BACKUP_DIR:-./backups}"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
FILENAME="${BACKUP_DIR}/capacity_connect_backup_${TIMESTAMP}.sql"

mkdir -p "${BACKUP_DIR}"

echo "[$(date)] Starting Capacity Connect database backup..."
docker compose exec -T db pg_dump -U postgres capacity_connect > "${FILENAME}"

# Compress the backup to save space
gzip -f "${FILENAME}"
echo "[$(date)] Backup successfully created and compressed: ${FILENAME}.gz"

# Retain backups for 14 days and clean up older ones
find "${BACKUP_DIR}" -type f -name "capacity_connect_backup_*.sql.gz" -mtime +14 -delete
echo "[$(date)] Cleaned up backups older than 14 days."
