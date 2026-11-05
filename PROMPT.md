# Prompt para levantar la demo con un agente (GitHub Copilot, Claude Code o Codex)

Copia el bloque siguiente en el chat del agente, con el repositorio abierto como espacio de trabajo.

```text
Eres un ingeniero de plataforma. Vas a desplegar la demo "Activo-Activo en Azure" de este repositorio
en MI suscripción, sin cambiar la arquitectura. Lee primero README.md, docs/architecture.md y deploy.env.

Contexto y reglas:
- Todo se crea con Bicep (infra/) y scripts bash (scripts/). No uses el portal ni crees recursos a mano.
- No abras SSH ni RDP: la operación de las VMs es con `az vm run-command` (scripts/lib.sh → run_on_vm).
- No modifiques el código de services/, web/ ni vm/ salvo que un error del despliegue lo exija; si lo haces,
  explica el cambio y mantenlo mínimo.
- Secretos: los genera scripts/deploy.sh en .secrets/ (ignorado por git). Nunca los imprimas ni los subas.
- Si un comando de Azure falla por política (Deny), cuota o SKU no disponible, NO improvises alternativas:
  detente, muestra el error completo y propón el cambio de parámetro (región o VM_SIZE en deploy.env).

Pasos:
1. Verifica herramientas: az (≥ 2.60), bicep (az bicep version), node ≥ 18 (npx), jq, python3, openssl, ssh-keygen.
2. `az login` (si hace falta) y `az account set -s "<NOMBRE O ID DE MI SUSCRIPCIÓN>"`. Confírmame nombre e id.
3. Revisa deploy.env conmigo: REGION_A, REGION_B, VM_SIZE, TIME_ZONE (zona del apagado 20:00). Cámbialos solo si te lo pido.
4. Ejecuta `./scripts/preflight.sh` y pégame el resumen. Si hay ✖, detente y espera mi decisión.
5. Ejecuta `./scripts/deploy.sh` (15–25 min). Al terminar, pégame las URLs que imprime y el resultado de la prueba de humo.
6. Ejecuta `./scripts/status.sh` y `./scripts/verify-sync.sh` y confirma que ambas bases son idénticas.
7. Sigue docs/runbook-demo.md para ensayar: `./scripts/chaos.sh stop-vm A`, observar el SPA, `./scripts/chaos.sh start-vm A`,
   `./scripts/verify-sync.sh`. Reporta tiempos.
8. Recuérdame: las VMs se apagan solas a las 20:00 (TIME_ZONE); por la mañana `./scripts/start.sh`.
   Para borrar todo: `./scripts/destroy.sh`.
```

## Variables que el agente puede necesitar

| Variable (deploy.env) | Valor por defecto | Notas |
|---|---|---|
| `REGION_A` / `REGION_B` | ver deploy.env | Deben tener disponibles `VM_SIZE` y `PG_SKU` para tu suscripción (`preflight.sh` lo comprueba) |
| `VM_SIZE` | ver deploy.env | 2 vCPU / 8 GiB recomendado (Kafka + Kafka Connect son JVM) |
| `TIME_ZONE` | `Central Standard Time (Mexico)` | Id de zona horaria de Windows para el apagado automático |
| `SHUTDOWN_TIME` | `2000` | HHmm |
| `ALLOW_SSH_FROM` | vacío | CIDR del operador; vacío = sin SSH (recomendado) |
| `ACME_EMAIL` | usuario de `az account show` | Cuenta ACME de Caddy (Let's Encrypt / ZeroSSL) |

## Qué debe salir bien

- `preflight.sh` sin ✖.
- `deploy.sh` termina con "Listo en N min" y la prueba de humo muestra "A→B … replicada en X s" y "B→A … replicada en Y s".
- `https://<SWA>` carga el SPA con el badge "Conectado a Región A".
