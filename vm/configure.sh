#!/usr/bin/env bash
# Se ejecuta DENTRO de la VM (vía az vm run-command). Idempotente.
# 1) rol de replicación + esquema + publicación en Postgres  2) conector Debezium  3) topics Kafka
set -euo pipefail
cd /opt/aa
set -a; . ./.env; set +a
export PGPASSWORD="$PG_PASSWORD"
PSQL="psql -h $PG_HOST -U $PG_USER -d $PG_DB -v ON_ERROR_STOP=1 -X -q"

echo "== [$REGION] Postgres: rol REPLICATION + esquema + publicación"
for i in $(seq 1 20); do
  if $PSQL -c "select 1" >/dev/null 2>&1; then break; fi
  echo "   esperando a Postgres ($i)…"; sleep 10
done
$PSQL -c "ALTER ROLE \"$PG_USER\" WITH REPLICATION;"
$PSQL -f db/schema.sql
$PSQL -At -c "SHOW wal_level;" | sed 's/^/   wal_level=/'

echo "== [$REGION] Kafka: topics"
for i in $(seq 1 30); do
  if docker compose exec -T kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:19092 --list >/dev/null 2>&1; then break; fi
  echo "   esperando a Kafka ($i)…"; sleep 5
done
docker compose exec -T kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:19092 --create --if-not-exists \
  --topic "cdc.${REGION}.public.tickets" --partitions 1 --replication-factor 1 --config retention.ms=604800000 >/dev/null
echo "   topic cdc.${REGION}.public.tickets listo"

echo "== [$REGION] Kafka Connect: conector Debezium pg-source-${REGION}"
for i in $(seq 1 60); do
  if curl -fsS localhost:8083/connectors >/dev/null 2>&1; then break; fi
  echo "   esperando a Connect ($i)…"; sleep 5
done
envsubst < connect/connector.json.tpl > /tmp/connector.json
curl -fsS -X PUT -H 'Content-Type: application/json' --data @/tmp/connector.json \
  "localhost:8083/connectors/pg-source-${REGION}/config" >/dev/null
rm -f /tmp/connector.json
sleep 8
curl -s "localhost:8083/connectors/pg-source-${REGION}/status" | jq -c '{connector: .connector.state, tasks: [.tasks[].state]}'
echo "== [$REGION] slots:"
$PSQL -At -c "SELECT slot_name || ' active=' || active FROM pg_replication_slots;" | sed 's/^/   /'
echo "CONFIGURE_OK"
