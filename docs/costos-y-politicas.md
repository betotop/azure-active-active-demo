# Costos y políticas (MCAPS)

## Costo estimado (USD/mes, pago por uso, precios de lista aproximados de oct-2026; validar en la calculadora de Azure)

| Recurso | 24×7 | Con apagado 20:00 → 08:00 |
|---|---|---|
| 2 × VM `Standard_B2ps_v2` (Arm64, 2 vCPU / 8 GiB) | ~78 | ~40 |
| 2 × disco SO Standard SSD 64 GiB | ~10 | ~10 |
| 2 × IP pública estática Standard | ~7 | ~7 |
| 2 × PostgreSQL Flexible B1ms + 32 GiB | ~32 | ~32 (~20 si también se detienen de noche con `scripts/stop.sh --db`) |
| Peering global (tráfico de demo < 1 GB) | < 1 | < 1 |
| Static Web Apps Free, auto-shutdown, run-command | 0 | 0 |
| **Subtotal infraestructura** | **~128** | **~90** (~78 deteniendo Postgres de noche) |

Lo que sigue costando con las VMs apagadas: discos, IPs y Postgres (~49/mes). `scripts/destroy.sh` lo borra todo.

### Defender for Cloud (lo impone la suscripción)

En la suscripción usada, los planes de Defender están en **Standard**: Servers P2 (~15 USD/VM/mes), open-source relational databases (~15 USD/servidor/mes), CSPM (~5 USD por recurso facturable) y otros. `scripts/deploy.sh` deshabilita la protección a nivel de recurso en los dos Postgres (REST `advancedThreatProtectionSettings/Default` → `Disabled`; en la suscripción de referencia quedó `Disabled`). Servers P2 y CSPM siguen aplicando: cuenta con ~40–50 USD/mes adicionales. Revísalo en Cost Management tras el primer día.

## Por qué no choca con las políticas de MCAPS

| Riesgo típico en MCAPS | Cómo lo evita la demo |
|---|---|
| NSG con 22/3389 abiertos a Internet se modifica o deniega | No hay reglas de gestión: solo 443/80 desde Internet y 9092 desde la VNet par. Operación con `az vm run-command` |
| PaaS con acceso público | PostgreSQL con acceso privado (subred delegada + Private DNS zone) |
| Cuentas de storage públicas | No se crean cuentas de storage (boot diagnostics gestionado) |
| Auto-shutdown obligatorio | `Microsoft.DevTestLab/schedules` a las 20:00 en la zona configurada; convive con el de MCAPS |
| SKUs restringidos por suscripción | `scripts/preflight.sh` comprueba disponibilidad y cuota de `VM_SIZE` y `PG_SKU` en ambas regiones. En la suscripción de referencia los B-series x64 estaban restringidos y por eso se usa `B2ps_v2` (Arm64) |
| Trusted Launch | Parámetro `TRUSTED_LAUNCH`; los tamaños Arm64 B-series no lo soportan y se despliega sin él |
| Etiquetas requeridas | `tags` en `infra/main.bicep` (`project`, `env`, `autoshutdown`) |
| NSG automático en subredes | Observado: la gobernanza asocia un NSG propio (`vnet-<x>-snet-vm-nsg-<región>`, solo reglas por defecto) a cada subred sin NSG, lo que bloqueó 443/80 desde Internet tras el primer reinicio. El Bicep ahora asocia nuestro NSG también a `snet-vm`; `scripts/fix-subnet-nsg.sh` añade las reglas a un NSG ajeno si aparece |

## TLS para las APIs

Las APIs usan el DNS label `*.cloudapp.azure.com` de la IP pública. Ese dominio **no** está en la Public Suffix List, así que Let's Encrypt aplica límites compartidos por `azure.com`; Caddy usa ZeroSSL como respaldo automático. Si tienes un dominio propio, apunta `api-a` y `api-b` a las IPs y pon esos nombres en `PUBLIC_FQDN` (en `scripts/push-bundle.sh`) y en `web/config.json`. Contingencia para el día de la demo: aceptar manualmente un certificado autofirmado en el navegador del presentador.

## Apagado y encendido

- **Observado en la suscripción de referencia**: una automatización de la gobernanza (service principal, no el usuario) detuvo los dos PostgreSQL Flexible Server a las 06:05 UTC (00:05 CDMX) la primera noche. Es bienvenido para el costo (~50 % menos en Postgres), pero significa que cada mañana hay que arrancarlos: `scripts/start.sh` lo detecta y lo hace.

- Apagado: 20:00 (`SHUTDOWN_TIME`, `TIME_ZONE` en `deploy.env`), por VM, sin notificación (configurable en `infra/modules/region.bicep`).
- Encendido: `scripts/start.sh` (2–3 min hasta `/health`). Con `--db` también inicia Postgres si lo detuviste.
- Opcional: una cuenta de Azure Automation con identidad administrada (gratis hasta 500 min/mes) puede encender a las 08:00 y detener Postgres de noche; no se incluye para no depender de registros de aplicación en tenants corporativos.
