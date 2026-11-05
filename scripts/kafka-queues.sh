#!/usr/bin/env bash
# Muestra las "colas" de Kafka de una región: topics, marcas de agua del topic CDC, lag del grupo del par
# (= eventos pendientes de replicar hacia la otra región), conector Debezium, contadores del Replicator y,
# opcionalmente, los últimos N eventos del topic. Corre dentro de la VM con run-command (sin SSH; ~30–60 s).
# Uso: scripts/kafka-queues.sh [A|B] [N]      (por defecto A y N=0; la salida de run-command se corta a 4 KB)
. "$(dirname "$0")/lib.sh"
require_state
R=$(upper "${1:-A}"); r=$(lower "$R"); p=$(lower "$(peer_of "$R")"); N="${2:-0}"
case "$N" in ''|*[!0-9]*) c_err "N debe ser un entero: $N"; exit 1;; esac
c_info "[$R] Kafka $R · topic cdc.$r.public.tickets · lo consume replicator-$p desde la región $(upper "$p")"
run_on_vm "$R" "cd /opt/aa
K='docker compose exec -T kafka /opt/kafka/bin'; B='--bootstrap-server localhost:19092'; T=cdc.$r.public.tickets
echo '## topics'; \$K/kafka-topics.sh \$B --list 2>/dev/null
echo '## marcas de agua de '\$T' (inicio = evento más viejo disponible · fin = siguiente offset a escribir)'
ST=\$(\$K/kafka-get-offsets.sh \$B --topic \$T --time -2 2>/dev/null | awk -F: '{print \$3}'); EN=\$(\$K/kafka-get-offsets.sh \$B --topic \$T --time -1 2>/dev/null | awk -F: '{print \$3}')
echo \"   inicio=\$ST fin=\$EN (eventos retenidos: \$((EN-ST)))\"
echo '## grupo replicator-$p (LAG = eventos que $(upper "$p") aún no ha aplicado)'
\$K/kafka-consumer-groups.sh \$B --describe --group replicator-$p 2>/dev/null | cut -c1-150
echo '## conector Debezium pg-source-$r'; curl -s localhost:8083/connectors/pg-source-$r/status | cut -c1-300; echo
echo '## replicator-$r (contadores en Redis repl:stats)'; docker compose exec -T redis redis-cli hgetall repl:stats | paste - - | cut -c1-90
if [ $N -gt 0 ]; then S=\$((EN-$N)); [ \$S -lt \$ST ] && S=\$ST
  echo \"## últimos $N eventos de \$T (desde el offset \$S)\"
  \$K/kafka-console-consumer.sh \$B --topic \$T --partition 0 --offset \$S --max-messages $N --timeout-ms 20000 --property print.timestamp=true 2>/dev/null | cut -c1-600
fi"
