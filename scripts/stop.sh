#!/usr/bin/env bash
# Desasigna las VMs (y con --db detiene PostgreSQL: ahorra ~50 % de su costo; Azure lo reinicia solo a los 7 días).
. "$(dirname "$0")/lib.sh"
require_state
c_info "Desasignando VMs A y B…"
az vm deallocate -g "$RG_A" -n "$VM_A" >/dev/null & az vm deallocate -g "$RG_B" -n "$VM_B" >/dev/null & wait
if [ "${1:-}" = "--db" ]; then
  c_info "Deteniendo PostgreSQL A y B…"
  az postgres flexible-server stop -g "$RG_A" -n "$PG_A_NAME" >/dev/null 2>&1 & az postgres flexible-server stop -g "$RG_B" -n "$PG_B_NAME" >/dev/null 2>&1 & wait
fi
c_ok "Apagado. Enciende con scripts/start.sh [--db]"
