#!/usr/bin/env bash
# Verifica herramientas, suscripción, proveedores, políticas con Deny, cuota, SKUs y hace what-if del Bicep.
. "$(dirname "$0")/lib.sh"
need az; need jq; need node; need npx; need ssh-keygen; need openssl
ok=1
c_info "Suscripción activa"
az account show --query "{name:name, id:id, tenant:tenantId}" -o table || { c_err "haz 'az login' y 'az account set -s <suscripción>'"; exit 1; }

c_info "Proveedores de recursos (registrando los que falten)…"
for p in Microsoft.Compute Microsoft.Network Microsoft.DBforPostgreSQL Microsoft.Web Microsoft.DevTestLab; do
  st=$(az provider show -n "$p" --query registrationState -o tsv 2>/dev/null || echo "Unknown")
  if [ "$st" != "Registered" ]; then az provider register -n "$p" >/dev/null 2>&1 || true; c_warn "$p: $st (registro solicitado)"; else echo "   $p: Registered"; fi
done

c_info "Asignaciones de política visibles (si hay Deny de ubicación/SKU/IP pública, el despliegue fallará)"
az policy assignment list --disable-scope-strict-match --query "[].{nombre:displayName, scope:scope, enforcement:enforcementMode}" -o table 2>/dev/null | head -25 || true

c_info "VM $VM_SIZE: disponibilidad para esta suscripción y cuota de la familia en $REGION_A y $REGION_B"
for r in "$REGION_A" "$REGION_B"; do
  sku=$(az vm list-skus -l "$r" --size "$VM_SIZE" --all --query "[?name=='$VM_SIZE'] | [0]" -o json 2>/dev/null)
  if [ -z "$sku" ] || [ "$sku" = "null" ]; then c_err "$r: $VM_SIZE no existe en la región"; ok=0; continue; fi
  restr=$(echo "$sku" | jq -r '[.restrictions[].reasonCode] | unique | join(",")')
  fam=$(echo "$sku" | jq -r .family)
  if [ -n "$restr" ]; then c_err "$r: $VM_SIZE restringido ($restr). Cambia VM_SIZE o la región en deploy.env"; ok=0; else echo "   $r: $VM_SIZE disponible"; fi
  az vm list-usage -l "$r" -o json 2>/dev/null | jq -r --arg r "$r" --arg f "$fam" '.[] | select(.name.value=="cores" or .name.value==$f) | "   \($r) cuota \(.name.value): \(.currentValue)/\(.limit)"' || c_warn "no se pudo leer la cuota en $r"
done

c_info "SKU de PostgreSQL $PG_SKU disponible en ambas regiones"
for r in "$REGION_A" "$REGION_B"; do
  if az postgres flexible-server list-skus -l "$r" --query "[0].supportedServerEditions[?name=='Burstable'].supportedServerSkus[].name" -o tsv 2>/dev/null | grep -qx "$PG_SKU"; then echo "   $r: OK"; else c_warn "$r: $PG_SKU no aparece como disponible"; ok=0; fi
done

c_info "Static Web Apps en $SWA_LOCATION (regiones válidas: centralus eastus2 westus2 westeurope eastasia)"
case "$SWA_LOCATION" in centralus|eastus2|westus2|westeurope|eastasia) echo "   OK";; *) c_err "SWA_LOCATION inválida"; ok=0;; esac

c_info "Bicep: compilación y what-if (sin crear nada)"
az bicep install >/dev/null 2>&1 || true
az bicep build -f "$ROOT/infra/main.bicep" --stdout >/dev/null && echo "   compila OK"
mkdir -p "$SECRETS"
[ -f "$SECRETS/id_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -f "$SECRETS/id_ed25519" -C "aa-demo"
az deployment sub what-if -l "$REGION_A" -n "aa-preflight" -f "$ROOT/infra/main.bicep" \
  -p prefix="$PREFIX" suffix="${SUFFIX:-pre123}" regionA="$REGION_A" regionB="$REGION_B" swaLocation="$SWA_LOCATION" \
     vmSize="$VM_SIZE" vmImageSku="${VM_IMAGE_SKU:-server}" trustedLaunch="${TRUSTED_LAUNCH:-true}" pgSku="$PG_SKU" pgVersion="$PG_VERSION" adminUsername="$ADMIN_USERNAME" pgAdminUser="$PG_ADMIN_USER" \
     sshPublicKey="$(cat "$SECRETS/id_ed25519.pub")" pgAdminPassword="Aa1-preflight-only-0000" \
     shutdownTime="$SHUTDOWN_TIME" timeZoneId="$TIME_ZONE" allowSshFrom="${ALLOW_SSH_FROM:-}" \
  --no-pretty-print --query "status" -o tsv 2>&1 | tail -n 5 || { c_err "what-if falló (revisa políticas/parámetros)"; ok=0; }

if [ "$ok" = 1 ]; then c_ok "Preflight sin bloqueos conocidos. Siguiente: scripts/deploy.sh"; else c_warn "Preflight con advertencias: revisa antes de desplegar"; fi
