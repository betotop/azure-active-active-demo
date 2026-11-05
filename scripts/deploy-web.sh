#!/usr/bin/env bash
# Genera web/config.json con las URLs de las APIs, copia el guion y la guía de Kafka a web/docs/ y publica web/ en
# Static Web Apps (plan Free) con la SWA CLI.
. "$(dirname "$0")/lib.sh"
require_state; need npx; need jq
write_web_config
stage_web_docs
TOKEN=$(az staticwebapp secrets list -n "$SWA_NAME" -g "$RG_G" --query properties.apiKey -o tsv)
c_info "Publicando web/ en $SWA_NAME (https://$SWA_HOST)…"
# Se ejecuta desde la raíz del repo: StaticSitesClient rechaza que el directorio actual sea la carpeta publicada
# ("Current directory cannot be identical to or contained within artifact folders"). El token va por variable de entorno.
out=$( cd "$ROOT" && SWA_CLI_DEPLOYMENT_TOKEN="$TOKEN" npx --yes @azure/static-web-apps-cli@2 deploy web --env production 2>&1 | tail -n 12 ) || true
echo "$out"
case "$out" in
  *"Project deployed"*|*"deployed to"*) c_ok "SPA publicado: https://$SWA_HOST" ;;
  *spawn*|*"error -86"*|*EBADARCH*|*"Bad CPU type"*|*"Exec format"*|*ENOEXEC*|*ENOENT*)
    # La SWA CLI ejecuta un binario x64 (StaticSitesClient): en Mac Apple Silicon sin Rosetta o en Linux arm64 no corre.
    # Respaldo: publicar desde la VM A con Docker + emulación amd64 (scripts/deploy-web-vm.sh).
    c_warn "SWA CLI nativa no pudo ejecutar StaticSitesClient; publicando desde la VM A…"
    exec "$ROOT/scripts/deploy-web-vm.sh" ;;
  *) c_err "la publicación en Static Web Apps falló (ver la salida de la SWA CLI arriba)"; exit 1 ;;
esac
