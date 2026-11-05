#!/usr/bin/env bash
# Si la gobernanza asoció un NSG ajeno a snet-vm (solo reglas por defecto), añade nuestras reglas (443/80 Internet, 9092 VNet par).
. "$(dirname "$0")/lib.sh"
require_state
for R in A B; do
  rg=$(rg_of $R); vnet="vnet-$PREFIX-$(lower $R)"; peer=$([ "$R" = "A" ] && echo 10.20.0.0/16 || echo 10.10.0.0/16)
  nsg=$(az network vnet subnet show -g "$rg" --vnet-name "$vnet" -n snet-vm --query "networkSecurityGroup.id" -o tsv 2>/dev/null | sed 's/.*\///')
  if [ -z "$nsg" ]; then echo "   [$R] snet-vm sin NSG"; continue; fi
  if [ "$nsg" = "$(nsg_of $R)" ]; then echo "   [$R] snet-vm usa nuestro NSG ($nsg): nada que hacer"; continue; fi
  c_info "[$R] snet-vm tiene el NSG ajeno $nsg: agregando reglas…"
  az network nsg rule create -g "$rg" --nsg-name "$nsg" -n AllowHTTPS-Internet --priority 100 --direction Inbound --access Allow --protocol Tcp --source-address-prefixes Internet --destination-port-ranges 443 -o none 2>/dev/null || true
  az network nsg rule create -g "$rg" --nsg-name "$nsg" -n AllowHTTP-ACME --priority 110 --direction Inbound --access Allow --protocol Tcp --source-address-prefixes Internet --destination-port-ranges 80 -o none 2>/dev/null || true
  az network nsg rule create -g "$rg" --nsg-name "$nsg" -n AllowKafka-PeerVnet --priority 120 --direction Inbound --access Allow --protocol Tcp --source-address-prefixes "$peer" --destination-port-ranges 9092 -o none 2>/dev/null || true
  c_ok "[$R] reglas presentes en $nsg"
done
