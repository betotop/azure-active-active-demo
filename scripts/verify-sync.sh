#!/usr/bin/env bash
# Compara ambas bases: conteo y hash de todas las filas (incluye borradas lógicamente). Deben coincidir cuando no hay lag.
. "$(dirname "$0")/lib.sh"
require_state
Q="SELECT count(*) || ' filas · hash ' || coalesce(md5(string_agg(id::text||'|'||version||'|'||estado||'|'||prioridad||'|'||titulo||'|'||origin_region||'|'||updated_at::text||'|'||coalesce(deleted_at::text,''), ',' ORDER BY id)),'vacio') FROM tickets;"
ra=$(run_on_vm A "cd /opt/aa && set -a && . ./.env && set +a && PGCONNECT_TIMEOUT=10 PGPASSWORD=\$PG_PASSWORD timeout 30 psql -h \$PG_HOST -U \$PG_USER -d \$PG_DB -At -c \"$Q\"" | tr -d '\r' | grep -v '^$' | tail -n 1)
rb=$(run_on_vm B "cd /opt/aa && set -a && . ./.env && set +a && PGCONNECT_TIMEOUT=10 PGPASSWORD=\$PG_PASSWORD timeout 30 psql -h \$PG_HOST -U \$PG_USER -d \$PG_DB -At -c \"$Q\"" | tr -d '\r' | grep -v '^$' | tail -n 1)
echo "A: $ra"; echo "B: $rb"
if [ -n "$ra" ] && [ "$ra" = "$rb" ]; then c_ok "Las dos bases son idénticas"; else c_warn "Difieren (¿lag pendiente o región caída?). Repite en unos segundos."; exit 1; fi
