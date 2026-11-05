#!/usr/bin/env bash
# push-bundle.sh A|B : empaqueta compose + servicios + db, lo envía a la VM por run-command, hace docker compose up --build
# y recarga Caddy (el Caddyfile es un bind mount: compose no lo reaplica solo).
. "$(dirname "$0")/lib.sh"
require_state
R=$(upper "${1:?uso: push-bundle.sh A|B}"); P=$(peer_of "$R")
r=$(lower "$R"); p=$(lower "$P")
PG_PASSWORD=$(cat "$SECRETS/pg_password")
ensure_kafka_ui_secret

c_info "[$R] esperando cloud-init de $(vm_of "$R")…"
for i in $(seq 1 30); do
  out=$(run_on_vm "$R" "test -f /opt/aa/.cloud-init-done && echo READY || echo WAIT" || true)
  case "$out" in *READY*) break;; esac
  echo "   intento $i: aún no ($(echo "$out" | tr -d '\n' | cut -c1-60))"; sleep 15
done

stage=$(mktemp -d)
cp "$ROOT/vm/docker-compose.yml" "$ROOT/vm/configure.sh" "$stage/"
cp -r "$ROOT/vm/caddy" "$ROOT/vm/connect" "$stage/"
cp -r "$ROOT/services/api" "$stage/api"
cp -r "$ROOT/services/replicator" "$stage/replicator"
cp -r "$ROOT/db" "$stage/db"
[ -f "$ROOT/web/config.json" ] || write_web_config
stage_web_docs
cp -r "$ROOT/web" "$stage/web"
find "$stage" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
cat > "$stage/.env" <<ENV
REGION=$r
PEER_REGION=$p
REGION_NAME="$(name_of "$R")"
PEER_KAFKA=$(ip_of "$P"):9092
PRIVATE_IP=$(ip_of "$R")
PUBLIC_FQDN=$(fqdn_of "$R")
PG_HOST=$(pgfqdn_of "$R")
PG_USER=$PG_ADMIN_USER
PG_PASSWORD=$PG_PASSWORD
PG_DB=appdb
KAFKA_CLUSTER_ID=$(eval echo "\$KAFKA_CLUSTER_ID_$R")
ACME_EMAIL=$ACME_EMAIL
KAFKA_UI_USER=${KAFKA_UI_USER:-demo}
KAFKA_UI_READONLY=${KAFKA_UI_READONLY:-true}
KAFKA_UI_HASH='$KAFKA_UI_HASH'
ENV
COPYFILE_DISABLE=1 tar -C "$stage" --no-xattrs -czf "$stage.tgz" .
B64=$(base64 < "$stage.tgz" | tr -d '\n')
rm -rf "$stage" "$stage.tgz"
c_info "[$R] enviando bundle ($(( ${#B64} / 1024 )) KB) y ejecutando docker compose up --build…"
# El bundle se extrae en /opt/aa/.bundle y se copia encima con cp, que escribe en el mismo inodo: tar reemplaza cada archivo
# por uno nuevo y el bind mount del Caddyfile dentro del contenedor se quedaría con el viejo (caddy reload no vería el cambio).
run_on_vm "$R" "set -e; mkdir -p /opt/aa/data/kafka; rm -rf /opt/aa/.bundle; mkdir -p /opt/aa/.bundle; cd /opt/aa/.bundle; echo '$B64' | base64 -d | tar xzf -; cp -a /opt/aa/.bundle/. /opt/aa/; rm -rf /opt/aa/.bundle; cd /opt/aa; chown -R 1000:1000 /opt/aa/data/kafka; chmod +x configure.sh; chmod 600 .env; if docker compose up -d --build --remove-orphans > /tmp/compose.log 2>&1; then echo COMPOSE_OK; else echo COMPOSE_FAIL; tail -n 40 /tmp/compose.log; fi; if docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1; then echo CADDY_RELOADED; else echo CADDY_RELOAD_FAIL; fi; docker compose ps --format 'table {{.Service}}\t{{.Status}}'"
c_ok "[$R] bundle aplicado"
