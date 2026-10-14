#!/usr/bin/env bash
# Latência: Azure direto x gateway (passthrough), mesmo deployment e mesmo payload.
# Uso: bash scripts/bench-latency.sh            (padrão: gpt-5.4, 5 rodadas)
#      N=10 DEP=gpt-4.1 VER=2025-01-01-preview bash scripts/bench-latency.sh
set -u
cd "$(dirname "$0")/.." || exit 1

AZ_EP=$(grep '^AZURE_ENDPOINT=' .env | cut -d= -f2- | tr -d '"' | sed 's#/*$##')
AZ_KEY=$(grep '^AZURE_API_KEY=' .env | cut -d= -f2- | tr -d '"')
VK=$(grep '^BIFROST_VK_CHAT_AI=' .env | cut -d= -f2- | tr -d '"')
DEP=${DEP:-gpt-5.4}
VER=${VER:-2024-12-01-preview}
N=${N:-5}

P="/openai/deployments/$DEP/chat/completions?api-version=$VER"
MSG='"messages":[{"role":"user","content":"Responda apenas: ok"}],"max_completion_tokens":300'
NORMAL="{$MSG}"
STREAM="{$MSG,\"stream\":true,\"stream_options\":{\"include_usage\":true}}"
OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT

call() { # $1=azure|gateway  $2=normal|stream
  local url key body
  if [ "$1" = azure ]; then url="$AZ_EP$P"; key="$AZ_KEY"; else url="http://127.0.0.1:8081/azure_passthrough$P"; key="$VK"; fi
  if [ "$2" = stream ]; then body="$STREAM"; else body="$NORMAL"; fi
  curl -s -N -o /dev/null --max-time 120 \
    -w "$1 $2 %{http_code} %{time_starttransfer} %{time_total}\n" \
    -X POST "$url" -H "api-key: $key" -H 'Content-Type: application/json' -d "$body" >> "$OUT"
}

echo "Deployment: $DEP | api-version: $VER | rodadas: $N"
for i in $(seq 1 "$N"); do
  for modo in normal stream; do
    if [ $((i % 2)) -eq 1 ]; then call azure "$modo"; call gateway "$modo"
    else call gateway "$modo"; call azure "$modo"; fi
  done
  echo "  rodada $i/$N concluída"
done

awk '
function med(arr, k, cnt,   i, j, t, a) {
  for (i = 1; i <= cnt; i++) a[i] = arr[k, i]
  for (i = 2; i <= cnt; i++) { t = a[i]; j = i - 1; while (j > 0 && a[j] > t) { a[j + 1] = a[j]; j-- } a[j + 1] = t }
  return (cnt % 2) ? a[(cnt + 1) / 2] : (a[cnt / 2] + a[cnt / 2 + 1]) / 2
}
function row(label, m, arr,   ka, kg, a, g) {
  ka = "azure " m; kg = "gateway " m
  if (!n[ka] || !n[kg]) { printf "%-26s sem dados suficientes\n", label; return }
  a = med(arr, ka, n[ka]) * 1000; g = med(arr, kg, n[kg]) * 1000
  printf "%-26s %10.0f ms %10.0f ms %+10.0f ms\n", label, a, g, g - a
}
$3 == 200 { k = $1 " " $2; n[k]++; ttfb[k, n[k]] = $4; total[k, n[k]] = $5; next }
{ err++; errs = errs " " $1 "/" $2 "=HTTP" $3 }
END {
  printf "\n%-26s %13s %13s %14s\n", "Mediana das rodadas", "Azure direto", "Gateway", "Diferença"
  row("Sem stream (total)", "normal", total)
  row("Stream (primeiro byte)", "stream", ttfb)
  row("Stream (total)", "stream", total)
  if (err) printf "\nFalhas:%s\n", errs
}' "$OUT"
