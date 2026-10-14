#!/usr/bin/env bash
# Sobe ou atualiza o gateway na VPS e espera o /health responder.
# Uso: /opt/llm-gateway/scripts/deploy.sh
set -euo pipefail

cd "$(dirname "$0")/.."

HEALTH_URL="http://127.0.0.1:8081/health"
CONTAINER_UID=1000

if [ ! -f .env ]; then
  echo "ERRO: .env não encontrado em $(pwd). Copie env.example para .env e preencha." >&2
  exit 1
fi
if [ "$(stat -c '%a' .env)" != "600" ]; then
  echo "AVISO: .env deveria ter permissão 600 (chmod 600 .env)." >&2
fi

mkdir -p data backups
if [ "$(stat -c '%u' data)" != "$CONTAINER_UID" ]; then
  echo "ERRO: data/ precisa pertencer ao UID $CONTAINER_UID do container." >&2
  echo "       Rode: sudo chown -R $CONTAINER_UID:0 $(pwd)/data" >&2
  exit 1
fi

docker compose config --quiet
docker compose pull
docker compose up -d --remove-orphans

# O primeiro boot leva ~80s (migrations + sync do catálogo de modelos); os seguintes, ~6s.
echo "Aguardando $HEALTH_URL ..."
for _ in $(seq 1 90); do
  if curl -fsS "$HEALTH_URL" >/dev/null 2>&1; then
    echo "Gateway saudável."
    docker compose ps
    exit 0
  fi
  sleep 2
done

echo "ERRO: gateway não respondeu em 180s." >&2
docker compose logs --tail 100 bifrost >&2
exit 1
