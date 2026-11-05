#!/usr/bin/env bash
# Funciones comunes. Compatible con bash 3.2 (macOS) y bash 5 (Linux).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF="$ROOT/deploy.env"
STATE="$ROOT/.env.deploy"
SECRETS="$ROOT/.secrets"
# shellcheck disable=SC1090
if [ -f "$CONF" ]; then set -a; . "$CONF"; set +a; fi
# shellcheck disable=SC1090
if [ -f "$STATE" ]; then set -a; . "$STATE"; set +a; fi
PREFIX="${PREFIX:-aa}"
RG_A="rg-$PREFIX-a"; RG_B="rg-$PREFIX-b"; RG_G="rg-$PREFIX-global"
VM_A="vm-$PREFIX-a"; VM_B="vm-$PREFIX-b"
NSG_A="nsg-$PREFIX-a"; NSG_B="nsg-$PREFIX-b"

c_info() { printf '\033[1;34m▸ %s\033[0m\n' "$*"; }
c_ok()   { printf '\033[1;32m✔ %s\033[0m\n' "$*"; }
c_warn() { printf '\033[1;33m⚠ %s\033[0m\n' "$*"; }
c_err()  { printf '\033[1;31m✖ %s\033[0m\n' "$*" >&2; }
need()   { command -v "$1" >/dev/null 2>&1 || { c_err "falta la herramienta '$1'"; exit 1; }; }
upper()  { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }
lower()  { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# state_set CLAVE VALOR  → persiste en .env.deploy (idempotente)
state_set() {
  touch "$STATE"
  { grep -v "^$1=" "$STATE" || true; } > "$STATE.tmp"
  printf '%s=%s\n' "$1" "$2" >> "$STATE.tmp"
  mv "$STATE.tmp" "$STATE"
  export "$1=$2"
}

rg_of()   { case "$(upper "$1")" in A) echo "$RG_A";; B) echo "$RG_B";; *) c_err "región inválida: $1 (usa A o B)"; exit 1;; esac; }
vm_of()   { case "$(upper "$1")" in A) echo "$VM_A";; B) echo "$VM_B";; esac; }
nsg_of()  { case "$(upper "$1")" in A) echo "$NSG_A";; B) echo "$NSG_B";; esac; }
pg_of()   { case "$(upper "$1")" in A) echo "${PG_A_NAME:-}";; B) echo "${PG_B_NAME:-}";; esac; }
pgfqdn_of(){ case "$(upper "$1")" in A) echo "${PG_A_FQDN:-}";; B) echo "${PG_B_FQDN:-}";; esac; }
fqdn_of() { case "$(upper "$1")" in A) echo "${VM_A_FQDN:-}";; B) echo "${VM_B_FQDN:-}";; esac; }
ip_of()   { case "$(upper "$1")" in A) echo "${VM_A_IP:-10.10.1.10}";; B) echo "${VM_B_IP:-10.20.1.10}";; esac; }
name_of() { case "$(upper "$1")" in A) echo "${REGION_A_NAME:-Región A}";; B) echo "${REGION_B_NAME:-Región B}";; esac; }
peer_of() { case "$(upper "$1")" in A) echo "B";; B) echo "A";; esac; }
region_of(){ case "$(upper "$1")" in A) echo "$REGION_A";; B) echo "$REGION_B";; esac; }

# run_on_vm A 'script' → ejecuta por el agente de la VM (sin SSH). Salida limitada a ~4 KB por Azure.
run_on_vm() {
  local rg vm
  rg=$(rg_of "$1"); vm=$(vm_of "$1"); shift
  az vm run-command invoke -g "$rg" -n "$vm" --command-id RunShellScript --scripts "$1" \
    --query "value[0].message" -o tsv 2>/dev/null | sed -e 's/^Enable succeeded: *//' -e '/^\[stdout\]$/d' -e '/^\[stderr\]$/d'
}

require_state() {
  if [ -z "${VM_A_FQDN:-}" ]; then c_err "no hay despliegue registrado en .env.deploy; ejecuta scripts/deploy.sh"; exit 1; fi
}

# ensure_kafka_ui_secret → contraseña de la consola de Kafka (https://<VM>/kafka-ui/) en .secrets/kafka_ui_password (se crea
# si no existe) y su hash bcrypt en .secrets/kafka_ui_hash, que Caddy usa en basic_auth (se recalcula si cambia la
# contraseña). El hash lo genera `caddy hash-password` en Docker si hay un demonio local; si no, htpasswd -B (viene en
# macOS; en Linux, apache2-utils). Deja el hash en KAFKA_UI_HASH.
ensure_kafka_ui_secret() {
  local pw hash
  mkdir -p "$SECRETS"
  if [ ! -s "$SECRETS/kafka_ui_password" ]; then
    (umask 077; printf '%s\n' "$(openssl rand -base64 30 | tr -dc 'A-Za-z0-9' | head -c 24)" > "$SECRETS/kafka_ui_password")
    c_info "contraseña nueva para la consola de Kafka en .secrets/kafka_ui_password"
  fi
  if [ ! -s "$SECRETS/kafka_ui_hash" ] || [ "$SECRETS/kafka_ui_password" -nt "$SECRETS/kafka_ui_hash" ]; then
    pw=$(cat "$SECRETS/kafka_ui_password")
    if hash=$(docker run --rm caddy:2 caddy hash-password --plaintext "$pw" 2>/dev/null) && [ -n "$hash" ]; then :
    elif command -v htpasswd >/dev/null 2>&1; then hash=$(htpasswd -nbBC 10 x "$pw" 2>/dev/null | cut -d: -f2)
    else c_err "para el hash de la contraseña de la consola de Kafka hace falta Docker (caddy hash-password) o htpasswd (apache2-utils)"; exit 1; fi
    case "$hash" in '$2'*) ;; *) c_err "no se pudo generar el hash bcrypt de la consola de Kafka"; exit 1;; esac
    (umask 077; printf '%s\n' "$hash" > "$SECRETS/kafka_ui_hash")
  fi
  KAFKA_UI_HASH=$(cat "$SECRETS/kafka_ui_hash")
}

# write_web_config → genera web/config.json con las URLs de las APIs (lo lee el SPA)
write_web_config() {
  cat > "$ROOT/web/config.json" <<JSON
{
  "preferred": "a",
  "generated": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "regions": [
    { "key": "a", "name": "$(name_of A)", "url": "https://$VM_A_FQDN" },
    { "key": "b", "name": "$(name_of B)", "url": "https://$VM_B_FQDN" }
  ],
  "probe_interval_ms": 3000,
  "probe_timeout_ms": 1500,
  "request_timeout_ms": 2500,
  "failback_healthy_probes": 3
}
JSON
}

# stage_web_docs → copia a web/docs/ el guion de la demo y la guía de Kafka (más el SVG de arquitectura que usa el guion)
# para publicarlos junto al SPA: https://<SWA_HOST>/docs/guion-demo.html y https://<VM_FQDN>/app/docs/guion-demo.html.
# web/docs/ es generado (ignorado por git): la fuente sigue siendo docs/. En docs/ los dos HTML llevan hosts de ejemplo
# (aa-xxxxxx-a.centralus… y aa-xxxxxx-b.canadacentral…, los mismos de web/config.example.json) para que el repositorio no
# contenga direcciones reales; aquí se sustituyen por VM_A_FQDN y VM_B_FQDN del despliegue (.env.deploy).
stage_web_docs() {
  local f
  mkdir -p "$ROOT/web/docs"
  cp "$ROOT/docs/architecture.svg" "$ROOT/web/docs/"
  for f in guion-demo.html kafka-guia.html; do
    sed -e "s|aa-xxxxxx-a\.centralus\.cloudapp\.azure\.com|${VM_A_FQDN:-aa-xxxxxx-a.centralus.cloudapp.azure.com}|g" \
        -e "s|aa-xxxxxx-b\.canadacentral\.cloudapp\.azure\.com|${VM_B_FQDN:-aa-xxxxxx-b.canadacentral.cloudapp.azure.com}|g" \
        "$ROOT/docs/$f" > "$ROOT/web/docs/$f"
  done
}
