#!/usr/bin/env bash
# Borra TODO (los 3 grupos de recursos). Pide confirmación.
. "$(dirname "$0")/lib.sh"
echo "Se borrarán los grupos de recursos: $RG_A, $RG_B, $RG_G en $(az account show --query name -o tsv)"
read -r -p "Escribe BORRAR para confirmar: " ans
[ "$ans" = "BORRAR" ] || { echo "cancelado"; exit 1; }
for rg in "$RG_A" "$RG_B" "$RG_G"; do az group delete -n "$rg" --yes --no-wait 2>/dev/null && echo "   borrando $rg…" || echo "   $rg no existe"; done
rm -f "$STATE" "$ROOT/.deploy-outputs.json" "$ROOT/web/config.json"
c_ok "Borrado en curso (unos minutos). Los secretos locales en .secrets/ se conservan; bórralos si ya no los quieres."
