#!/usr/bin/env bash
# Respaldo de deploy-web.sh: publica web/ en Static Web Apps DESDE la VM A, usando Docker con emulación amd64
# (la SWA CLI necesita el binario x64 StaticSitesClient; sirve cuando la máquina local no puede ejecutarlo, p. ej. Mac sin Rosetta).
. "$(dirname "$0")/lib.sh"
require_state; need tar; need base64
[ -f "$ROOT/web/config.json" ] || { c_err "falta web/config.json: ejecuta scripts/deploy-web.sh primero (lo genera)"; exit 1; }
stage_web_docs
TOKEN=$(az staticwebapp secrets list -n "$SWA_NAME" -g "$RG_G" --query properties.apiKey -o tsv)
B64=$(COPYFILE_DISABLE=1 tar -C "$ROOT/web" --no-xattrs -czf - . | base64 | tr -d '\n')
c_info "Publicando el SPA desde $(vm_of A) (Docker + emulación amd64; 3–8 min)…"
# cwd=/src y "deploy web": StaticSitesClient rechaza ejecutarse con el directorio actual dentro de la carpeta publicada.
out=$(run_on_vm A "set -e; export DEBIAN_FRONTEND=noninteractive; docker run --privileged --rm tonistiigi/binfmt --install amd64 >/dev/null 2>&1 || true; mkdir -p /opt/aa/web && cd /opt/aa/web && echo '$B64' | base64 -d | tar xzf -; docker run --rm --platform linux/amd64 -v /opt/aa/web:/src/web -w /src -e SWA_CLI_DEPLOYMENT_TOKEN='$TOKEN' -e NPM_CONFIG_FETCH_RETRIES=5 node:20-bookworm npx --yes @azure/static-web-apps-cli@2 deploy web --env production 2>&1 | grep -v '^\$' | tail -n 10")
echo "$out" | cut -c1-200
case "$out" in *"Project deployed"*|*"deployed to"*) c_ok "SPA publicado: https://$SWA_HOST";; *) c_err "la publicación desde la VM no confirmó éxito"; exit 1;; esac
