#!/usr/bin/env bash
# Crea un registro en una región y espera verla replicada en la otra (A→B y B→A). Mide el tiempo.
. "$(dirname "$0")/lib.sh"
require_state; need jq; need curl
fail=0
for pair in "A B" "B A"; do
  set -- $pair; SRC=$1; DST=$2
  id=$(python3 -c 'import uuid;print(uuid.uuid4())')
  t0=$(date +%s)
  resp=$(curl -sf --max-time 8 -X PUT -H 'Content-Type: application/json' \
    -d "{\"titulo\":\"Prueba de humo $SRC→$DST $(date +%H:%M:%S)\",\"prioridad\":\"alta\"}" "https://$(fqdn_of $SRC)/tickets/$id") || { c_err "[$SRC] no se pudo escribir"; fail=1; continue; }
  folio=$(echo "$resp" | jq -r .folio)
  found=0
  for i in $(seq 1 40); do
    if curl -sf --max-time 5 "https://$(fqdn_of $DST)/tickets/$id" >/dev/null 2>&1; then found=1; break; fi
    sleep 1
  done
  if [ "$found" = 1 ]; then c_ok "$SRC→$DST: $folio replicada en $(( $(date +%s) - t0 )) s"; else c_err "$SRC→$DST: $folio NO apareció en $DST en 40 s"; fail=1; fi
done
exit $fail
