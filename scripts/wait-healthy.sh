#!/usr/bin/env bash
# Espera a que ambas APIs respondan /health por HTTPS (incluye la emisión del certificado por Caddy).
. "$(dirname "$0")/lib.sh"
require_state
for R in A B; do
  f=$(fqdn_of "$R"); okr=0
  for i in $(seq 1 36); do
    if curl -sf --max-time 5 "https://$f/health" >/dev/null 2>&1; then okr=1; break; fi
    sleep 5
  done
  if [ "$okr" = 1 ]; then c_ok "[$R] https://$f/health OK"; else
    c_warn "[$R] https://$f/health no responde aún. Diagnóstico TLS:"; curl -sv --max-time 8 "https://$f/health" 2>&1 | grep -iE "SSL|certificate|HTTP/" | head -n 5
    echo "   logs de Caddy:"; run_on_vm "$R" "cd /opt/aa && docker compose logs --tail 15 caddy 2>&1 | cut -c1-200"; fi
done
