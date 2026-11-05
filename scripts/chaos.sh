#!/usr/bin/env bash
# Escenarios de caos para la demo.
#   chaos.sh stop-vm A|B     desasigna la VM (región caída)         chaos.sh start-vm A|B
#   chaos.sh stop-db A|B     detiene PostgreSQL de la región        chaos.sh start-db A|B
#   chaos.sh stop-api A|B    para solo api+caddy (falla suave)      chaos.sh start-api A|B
#   chaos.sh partition       corta Kafka (9092) entre regiones      chaos.sh heal
. "$(dirname "$0")/lib.sh"
require_state
act="${1:?uso: chaos.sh <stop-vm|start-vm|stop-db|start-db|stop-api|start-api|partition|heal> [A|B]}"
R="${2:-}"
case "$act" in
  stop-vm)   c_info "Desasignando $(vm_of $R) ($(region_of $R))…"; az vm deallocate -g "$(rg_of $R)" -n "$(vm_of $R)" >/dev/null; c_ok "región $R caída (VM desasignada)";;
  start-vm)  c_info "Encendiendo $(vm_of $R)…"; az vm start -g "$(rg_of $R)" -n "$(vm_of $R)" >/dev/null
             for i in $(seq 1 40); do curl -sf --max-time 4 "https://$(fqdn_of $R)/health" >/dev/null 2>&1 && break; sleep 5; done
             c_ok "región $R de vuelta: https://$(fqdn_of $R)/health";;
  stop-db)   c_info "Deteniendo PostgreSQL $(pg_of $R)…"; az postgres flexible-server stop -g "$(rg_of $R)" -n "$(pg_of $R)" >/dev/null; c_ok "Postgres $R detenido";;
  start-db)  c_info "Iniciando PostgreSQL $(pg_of $R)…"; az postgres flexible-server start -g "$(rg_of $R)" -n "$(pg_of $R)" >/dev/null; c_ok "Postgres $R iniciado";;
  stop-api)  run_on_vm "$R" "cd /opt/aa && docker compose stop caddy api && echo API_STOPPED"; c_ok "api+caddy de $R detenidos";;
  start-api) run_on_vm "$R" "cd /opt/aa && docker compose start api caddy && echo API_STARTED"; c_ok "api+caddy de $R arriba";;
  partition)
    c_info "Bloqueando 9092 entre VNets (regla Deny prioridad 50 en ambos NSG)…"
    az network nsg rule create -g "$RG_A" --nsg-name "$NSG_A" -n ChaosDenyKafka --priority 50 --direction Inbound --access Deny --protocol Tcp --destination-port-ranges 9092 --source-address-prefixes 10.20.0.0/16 -o none
    az network nsg rule create -g "$RG_B" --nsg-name "$NSG_B" -n ChaosDenyKafka --priority 50 --direction Inbound --access Deny --protocol Tcp --destination-port-ranges 9092 --source-address-prefixes 10.10.0.0/16 -o none
    c_ok "partición activa: cada región sigue escribiendo; las colas crecen en ambos Kafka";;
  heal)
    c_info "Quitando reglas de partición…"
    az network nsg rule delete -g "$RG_A" --nsg-name "$NSG_A" -n ChaosDenyKafka -o none 2>/dev/null || true
    az network nsg rule delete -g "$RG_B" --nsg-name "$NSG_B" -n ChaosDenyKafka -o none 2>/dev/null || true
    c_ok "partición resuelta: los Replicators drenan las colas (LWW decide conflictos)";;
  *) c_err "acción desconocida: $act"; exit 1;;
esac
