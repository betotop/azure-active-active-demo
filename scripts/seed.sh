#!/usr/bin/env bash
# Crea registros de ejemplo en la región indicada (por defecto A). La replicación los lleva a la otra.
. "$(dirname "$0")/lib.sh"
require_state
R=$(upper "${1:-A}"); N="${2:-3}"
for i in $(seq 1 "$N"); do
  curl -sf --max-time 8 -X POST -H 'Content-Type: application/json' -d "{\"titulo\":\"Registro de ejemplo $i (creado en $R)\"}" "https://$(fqdn_of $R)/tickets" | jq -r '"   \(.folio) · \(.titulo)"'
done
c_ok "$N registros creados en $R"
