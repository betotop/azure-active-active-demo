#!/usr/bin/env bash
# Enciende la demo por la mañana: PostgreSQL si está detenido (gobernanza MCAPS o stop.sh --db) y las VMs.
. "$(dirname "$0")/lib.sh"
require_state
# PostgreSQL: se inicia si está detenido (por scripts/stop.sh --db o por la gobernanza de la suscripción, que en MCAPS
# detiene los Flexible Server de noche). "--db" fuerza el intento aunque el estado no se pueda leer.
for r in A B; do
  st=$(az postgres flexible-server show -g "$(rg_of $r)" -n "$(pg_of $r)" --query state -o tsv 2>/dev/null || echo "?")
  if [ "$st" = "Stopped" ] || [ "${1:-}" = "--db" ]; then
    c_info "Iniciando PostgreSQL $r (estado: $st)…"
    az postgres flexible-server start -g "$(rg_of $r)" -n "$(pg_of $r)" >/dev/null 2>&1 &
  else
    echo "   PostgreSQL $r: $st"
  fi
done
wait
c_info "Encendiendo VMs A y B…"
az vm start -g "$RG_A" -n "$VM_A" >/dev/null & az vm start -g "$RG_B" -n "$VM_B" >/dev/null & wait
"$ROOT/scripts/fix-subnet-nsg.sh"
"$ROOT/scripts/wait-healthy.sh"
