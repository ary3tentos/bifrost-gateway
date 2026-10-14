#!/usr/bin/env bash
# Backup consistente do config.db (providers, virtual keys, budgets) via sqlite3 .backup.
# Rode como root (cron), porque data/ pertence ao UID 1000 do container:
#   0 3 * * * /opt/llm-gateway/scripts/backup.sh >> /var/log/llm-gateway-backup.log 2>&1
# Requer: apt install sqlite3
# Uso: backup.sh [--with-logs]   (--with-logs inclui o logs.db, que pode ser grande)
#
# O backup sem a BIFROST_ENCRYPTION_KEY é inútil: as keys ficam criptografadas.
# Guarde a encryption key no cofre de senhas, separada destes arquivos.
set -euo pipefail

cd "$(dirname "$0")/.."

RETENTION_DAYS=14
STAMP="$(date +%Y%m%d-%H%M%S)"
DBS=(config)
if [ "${1:-}" = "--with-logs" ]; then
  DBS+=(logs)
fi

mkdir -p backups
chmod 700 backups

for db in "${DBS[@]}"; do
  src="data/${db}.db"
  out="backups/${db}-${STAMP}.db"
  if [ ! -f "$src" ]; then
    echo "AVISO: $src não existe, pulando." >&2
    continue
  fi
  sqlite3 "$src" ".backup '$out'"
  gzip "$out"
  echo "OK: ${out}.gz"
done

find backups -name '*.db.gz' -mtime +"$RETENTION_DAYS" -delete
