#!/usr/bin/env bash
# Resumen del estado de ambas regiones (usa /status de cada API).
. "$(dirname "$0")/lib.sh"
require_state; need jq
for R in A B; do
  f=$(fqdn_of "$R")
  if ! s=$(curl -sf --max-time 6 "https://$f/status"); then c_err "[$R] $f sin respuesta"; continue; fi
  echo "$s" | jq -r --arg R "$R" '
    "[\($R)] \(.region_name) · uptime \(.uptime_s)s",
    "   Postgres: \(if .postgres.ok then "OK · \(.postgres.tickets) registros · \(.postgres.latency_ms) ms · slot \(.postgres.slots[0].slot_name // "-") activo=\(.postgres.slots[0].active // "-") WAL retenido=\(.postgres.slots[0].retained_bytes // 0) B" else "ERROR \(.postgres.error)" end)",
    "   Redis:    \(if .redis.ok then "OK · lista en caché=\(.redis.list_cached)" else "ERROR \(.redis.error)" end)",
    "   Kafka:    \(if .kafka.ok then "OK · topic \(.kafka.topic) fin=\(.kafka.topic_end) · pendientes para el par=\(.kafka.outbound_pending)" else "ERROR \(.kafka.error)" end)",
    "   Debezium: \(.connect.state // .connect.error) \(.connect.error // "")",
    "   Replicator: \(if .replicator.ok then "vivo · aplicados=\(.replicator.applied // 0) eco=\(.replicator.echo // 0) viejos=\(.replicator.skipped_older // 0) errores=\(.replicator.errors // 0) lag=\(.replicator.last_lag_ms // "-") ms · kafka par conectado=\(.replicator.peer_connected // 0)" else "SIN LATIDO" end)",
    "   Kafka del par alcanzable: \(.peer_kafka_reachable)"'
done
