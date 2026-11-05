#!/usr/bin/env bash
# Despliegue completo: Bicep → reinicio Postgres (wal_level) → bundle a las VMs → CDC → SPA → prueba de humo.
. "$(dirname "$0")/lib.sh"
need az; need jq; need npx; need ssh-keygen; need openssl; need tar; need base64; need python3
t_start=$(date +%s)
SUB=$(az account show --query "[name, id]" -o tsv | tr '\n' ' ')
c_info "Suscripción: $SUB"

mkdir -p "$SECRETS"
if [ ! -f "$SECRETS/pg_password" ]; then
  printf 'Aa1%s\n' "$(openssl rand -base64 30 | tr -dc 'A-Za-z0-9' | head -c 21)" > "$SECRETS/pg_password"
fi
[ -f "$SECRETS/id_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -f "$SECRETS/id_ed25519" -C "aa-demo"
PG_PASSWORD=$(cat "$SECRETS/pg_password")
SSH_PUB=$(cat "$SECRETS/id_ed25519.pub")
ensure_kafka_ui_secret   # contraseña + hash de la consola de Kafka, antes de que push-bundle A y B corran en paralelo
[ -n "${SUFFIX:-}" ] || state_set SUFFIX "$(openssl rand -hex 3)"
[ -n "${KAFKA_CLUSTER_ID_A:-}" ] || state_set KAFKA_CLUSTER_ID_A "$(python3 -c 'import uuid,base64;print(base64.urlsafe_b64encode(uuid.uuid4().bytes).decode().rstrip("="))')"
[ -n "${KAFKA_CLUSTER_ID_B:-}" ] || state_set KAFKA_CLUSTER_ID_B "$(python3 -c 'import uuid,base64;print(base64.urlsafe_b64encode(uuid.uuid4().bytes).decode().rstrip("="))')"
if [ -z "${ACME_EMAIL:-}" ]; then ACME_EMAIL=$(az account show --query user.name -o tsv); fi
state_set ACME_EMAIL "$ACME_EMAIL"
state_set PG_USER "$PG_ADMIN_USER"

c_info "1/7 Bicep: 3 grupos de recursos, 2 VNets+peering, 2 VMs, 2 PostgreSQL, SWA (10–15 min)…"
az deployment sub create -l "$REGION_A" -n "aa-$SUFFIX" -f "$ROOT/infra/main.bicep" \
  -p prefix="$PREFIX" suffix="$SUFFIX" regionA="$REGION_A" regionB="$REGION_B" swaLocation="$SWA_LOCATION" \
     vmSize="$VM_SIZE" vmImageSku="${VM_IMAGE_SKU:-server}" trustedLaunch="${TRUSTED_LAUNCH:-true}" pgSku="$PG_SKU" pgVersion="$PG_VERSION" adminUsername="$ADMIN_USERNAME" pgAdminUser="$PG_ADMIN_USER" \
     sshPublicKey="$SSH_PUB" pgAdminPassword="$PG_PASSWORD" shutdownTime="$SHUTDOWN_TIME" timeZoneId="$TIME_ZONE" \
     allowSshFrom="${ALLOW_SSH_FROM:-}" \
  --query properties.outputs -o json > "$ROOT/.deploy-outputs.json"
for k in vmAFqdn:VM_A_FQDN vmBFqdn:VM_B_FQDN vmAPrivateIp:VM_A_IP vmBPrivateIp:VM_B_IP pgAName:PG_A_NAME pgBName:PG_B_NAME \
         pgAFqdn:PG_A_FQDN pgBFqdn:PG_B_FQDN swaName:SWA_NAME swaHostname:SWA_HOST; do
  state_set "${k#*:}" "$(jq -r ".${k%%:*}.value" "$ROOT/.deploy-outputs.json")"
done
c_ok "Infra lista: A=$VM_A_FQDN  B=$VM_B_FQDN  SPA=https://$SWA_HOST"

"$ROOT/scripts/fix-subnet-nsg.sh"
c_info "2/7 Reiniciando PostgreSQL (aplica wal_level=logical) y deshabilitando Defender ATP a nivel recurso…"
az postgres flexible-server restart -g "$RG_A" -n "$PG_A_NAME" >/dev/null &
az postgres flexible-server restart -g "$RG_B" -n "$PG_B_NAME" >/dev/null &
wait
SUB_ID=$(az account show --query id -o tsv)
for r in A B; do
  st=$(az rest --method put --url "https://management.azure.com/subscriptions/$SUB_ID/resourceGroups/$(rg_of $r)/providers/Microsoft.DBforPostgreSQL/flexibleServers/$(pg_of $r)/advancedThreatProtectionSettings/Default?api-version=2023-12-01-preview" \
        --body '{"properties":{"state":"Disabled"}}' --query properties.state -o tsv 2>/dev/null || true)
  if [ "$st" = "Disabled" ]; then echo "   Defender ATP deshabilitado en Postgres $r"; else c_warn "no se pudo deshabilitar ATP en $r (gobernanza); costo Defender OSS DB aplica"; fi
done

c_info "3/7 Enviando la pila a las VMs (run-command, sin SSH) y levantando contenedores (5–8 min)…"
"$ROOT/scripts/push-bundle.sh" A > "$ROOT/.push-a.log" 2>&1 &
"$ROOT/scripts/push-bundle.sh" B > "$ROOT/.push-b.log" 2>&1 &
wait
tail -n 12 "$ROOT/.push-a.log"; tail -n 12 "$ROOT/.push-b.log"

c_info "4/7 Configurando CDC (rol, esquema, publicación, conector Debezium, topics)…"
"$ROOT/scripts/configure-cdc.sh" A > "$ROOT/.cdc-a.log" 2>&1 &
"$ROOT/scripts/configure-cdc.sh" B > "$ROOT/.cdc-b.log" 2>&1 &
wait
tail -n 8 "$ROOT/.cdc-a.log"; tail -n 8 "$ROOT/.cdc-b.log"

c_info "5/7 Publicando el SPA en Static Web Apps…"
"$ROOT/scripts/deploy-web.sh"

c_info "6/7 Esperando certificados TLS y salud de ambas regiones…"
"$ROOT/scripts/wait-healthy.sh"

c_info "7/7 Prueba de humo: replicación A→B y B→A"
"$ROOT/scripts/smoke-test.sh" || c_warn "la prueba de humo no pasó; revisa scripts/status.sh"

echo
c_ok "Listo en $(( ($(date +%s) - t_start) / 60 )) min."
echo "   SPA (modo automático):   https://$SWA_HOST"
echo "   SPA fijado a A / B:      https://$SWA_HOST/?region=a   ·   https://$SWA_HOST/?region=b"
echo "   SPA servido por región:  https://$VM_A_FQDN/app/   ·   https://$VM_B_FQDN/app/"
echo "   API A: https://$VM_A_FQDN/status   API B: https://$VM_B_FQDN/status"
echo "   Consola de Kafka (usuario ${KAFKA_UI_USER:-demo}, contraseña en .secrets/kafka_ui_password): https://$VM_A_FQDN/kafka-ui/   ·   https://$VM_B_FQDN/kafka-ui/"
echo "   Guion de la demo: docs/runbook-demo.md · Caos: scripts/chaos.sh · Apagado automático: ${SHUTDOWN_TIME:0:2}:${SHUTDOWN_TIME:2:2} ($TIME_ZONE)"
