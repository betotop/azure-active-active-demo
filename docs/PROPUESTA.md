# Propuesta: demo de resiliencia Activo-Activo en Azure

> **Decisión final (20-oct-2026, tras la revisión):** regiones **Central US + Canada Central**; VM **Standard_B2ps_v2** (Arm64, 2 vCPU / 8 GiB) porque los B-series x64 están restringidos para la suscripción en esas regiones; apagado 20:00 `Central Standard Time (Mexico)`; sin dominio propio (Caddy con `*.cloudapp.azure.com`); sin alertas de presupuesto; suscripción MCAPS gestionada (nombre omitido). Lo vigente está en [README.md](../README.md) y [costos-y-politicas.md](costos-y-politicas.md); este documento se conserva como registro de la propuesta.

| | |
|---|---|
| **Estado** | Propuesta para revisión. **Nada construido ni aprovisionado.** |
| **Fecha** | 20-oct-2026 |
| **Suscripción detectada en `az`** | `<suscripción MCAPS detectada>` (MCAPS, entorno gestionado) |
| **Regiones propuestas** | A = **South Central US** (la más cercana a México) · B = **East US 2** (~30 ms entre ambas, precios bajos, SKUs disponibles) |
| **Zona horaria detectada en tu Mac** | `America/Mexico_City` → `Central Standard Time (Mexico)` para el auto-shutdown de las 20:00 |
| **Diagrama** | [architecture.svg](architecture.svg) |

---

## 1. Qué demuestra la demo (guion en 5 escenas)

Escenario de negocio: **"Mesa de solicitudes ciudadanas"**, una app crítica de un servicio público donde se crean y actualizan solicitudes (tickets) que deben seguir operando aunque caiga una región completa.

| Escena | Acción | Qué ve el público |
|---|---|---|
| 0. Normalidad | Tres ventanas del SPA: una fijada a A, una fijada a B y una en modo automático. Crear un ticket en A. | Aparece en B en 1–2 s (CDC → Kafka → Replicator). Panel: lag 0, cola 0. |
| 1. Cae la región A | `./scripts/chaos.sh stop-vm A` (desasigna la VM). Variante: `stop-db A` detiene solo Postgres A. | La ventana automática conmuta a B **sin error visible**; cambia el badge "Conectado a: B". El usuario sigue creando y editando. |
| 2. Cola en Kafka B | Seguir escribiendo en B. | Panel: "Kafka B retiene N eventos para A" (lag del grupo `replicator-a` crece). |
| 3. Vuelve A | `./scripts/chaos.sh start-vm A` (2–3 min hasta que levantan los contenedores). | Replicator A drena la cola; `./scripts/verify-sync.sh` muestra ambas bases idénticas (conteo + hash). La ventana automática hace failback (opcional). |
| 4. Conflicto (opcional) | `chaos.sh partition` corta el 9092 entre VNets; editar el mismo ticket en A y en B; `chaos.sh heal`. | Al reconectar gana el último `updated_at` (LWW); el panel muestra "conflicto resuelto". |
| Cierre | 20:00: auto-shutdown de ambas VMs. | El SPA muestra "sin regiones disponibles" con los datos en caché del Service Worker (y cola offline si se activa). |

---

## 2. Arquitectura propuesta

Ver [architecture.svg](architecture.svg). Resumen por capa:

| Capa | Componente | Elección | Por qué |
|---|---|---|---|
| Global | SPA / PWA | HTML + JS sin bundler, Service Worker con app-shell versionada, `config.json` con las URLs de A y B | "Cache tipo SPA" explícita y auditable; el failover vive en el cliente → 0 interrupción percibida y sin depender de DNS ni de un balanceador global |
| Global | Hosting del SPA | **Azure Static Web Apps, plan Free** | $0, distribución global, HTTPS incluido, no vive en A ni en B. Alternativa: Storage static website |
| Región ×2 | Cómputo | **VM Standard_B2as_v2** (2 vCPU / 8 GiB), Ubuntu 24.04, Docker Compose vía cloud-init | Kafka + Kafka Connect son JVM (~2.5 GB entre ambos) y Defender for Servers instala agentes; con 4 GiB (B2als_v2, ~mitad de precio) funciona pero justo. El tamaño es parámetro |
| Región | TLS de entrada | **Caddy** (reverse proxy 443 → API, certificados automáticos) | SWA sirve por HTTPS: la API debe ser HTTPS o el navegador bloquea por *mixed content* |
| Región | API | **FastAPI (Python)**: `/tickets` (CRUD idempotente), `/health`, `/status`, `/events` (SSE) | Código corto y legible para explicar en la demo |
| Región | Caché | **Redis 7 en contenedor** (en la VM, como pediste) | Cache-aside con TTL 30 s + pub/sub para empujar eventos al navegador; se invalida al aplicar cambios remotos |
| Región | Mensajería | **Apache Kafka 3.x (KRaft, 1 nodo)** en contenedor | Retención 7 días; listener en la IP privada de la VM (puerto 9092), nunca expuesto a Internet |
| Región | CDC | **Kafka Connect + Debezium PostgreSQL** (plugin `pgoutput`) | Estándar de industria. Alternativa más ligera si hace falta memoria: Debezium Server |
| Región | Aplicador | **Replicator (Python, ~150 líneas)**: consume el topic de la *otra* región y aplica en Postgres local | Hace lo que un sink JDBC no sabe hacer: descartar eco, resolver conflictos LWW, soft-delete, invalidar Redis, exponer métricas |
| Región | Base de datos | **Azure Database for PostgreSQL Flexible Server, Burstable B1ms** (1 vCore / 2 GiB), 32 GiB, PG 16, acceso privado (VNet) | Es el plan más barato que admite `wal_level=logical` (requisito de CDC). Verificado hoy: B1ms disponible en ambas regiones |
| Red | VNet por región (10.10/16 y 10.20/16), **peering global** bidireccional, NSG, IP pública estática con DNS label, Private DNS zone para Postgres | Todo el tráfico A⇄B va por red privada; solo 443/80 miran a Internet |
| Operación | Auto-shutdown 20:00 (`Microsoft.DevTestLab/schedules`), `az vm run-command` para operar sin SSH, Bastion Developer opcional ($0), presupuesto con alerta, `preflight.sh`, `destroy.sh` | Barato, sin puertos de gestión y reversible |
| Repo | Bicep + `az` CLI, Docker Compose local (las 2 regiones en tu Mac), docs, scripts, `PROMPT.md` para Copilot / Claude / Codex | Reproducible en otra suscripción con un comando |

---

## 3. Flujo de datos y semántica de replicación

1. **Escritura**: el SPA genera el `id` (uuid) y manda `PUT /tickets/{id}` con `Idempotency-Key`; la API escribe en Postgres local con `origin_region = 'A'`, `updated_at = clock_timestamp()` (reloj del servidor Postgres, no del navegador) y `version + 1`. Borrados = soft delete (`deleted_at`).
2. **Captura**: Debezium lee el slot lógico y publica en `cdc.a.public.tickets` (1 partición, clave = id → orden total por fila). Heartbeat cada 10 s para que el slot avance aunque no haya tráfico (evita que crezca el WAL en Flexible Server).
3. **Transporte**: el Replicator de **B** consume `cdc.a.*` directamente del Kafka de **A** por el peering (modelo *pull*). Los offsets del grupo `replicator-b` viven en Kafka A: si B se cae, no se pierde nada; al volver, reanuda donde iba. Simétrico para A.
4. **Aplicación**: upsert `INSERT … ON CONFLICT (id) DO UPDATE … WHERE excluded.updated_at > tickets.updated_at` (empate → gana la región alfabéticamente menor). Commit del offset **después** de aplicar: entrega *at-least-once* + upsert idempotente = efectivamente una vez.
5. **Anti-eco**: el Replicator escribe preservando `origin_region`; Debezium local vuelve a capturar esa fila y la publica; el Replicator remoto la descarta porque `origin_region == su región`. El panel muestra "eco descartado: N" (sirve para explicarlo).
6. **Ventana de pérdida (RPO)**: lo escrito en A en el último instante antes de caer y aún no consumido por B llega cuando A vuelve (el log de Kafka A está en disco). Se muestra como "llegadas tardías". Es la naturaleza del activo-activo asíncrono y conviene decirlo en la demo.
7. **DDL no se replica** (Debezium solo captura DML): el esquema vive en `db/schema.sql` y se aplica a las dos bases.

### Failover en el navegador

- `config.json`: `[{"region":"A","url":"https://…"}, {"region":"B","url":"https://…"}]`, preferencia A.
- Sondeo `/health` (DB + Redis) cada 3 s con timeout 1.5 s; cada request de negocio con timeout 2.5 s.
- Fallo de red, timeout o 5xx → reintento inmediato en la otra región y cambio de región activa. Como las escrituras son idempotentes por `id`, reintentar no duplica.
- Failback: solo cuando la región preferida responde sana 3 sondeos seguidos (evita *flapping*). Modo "fijar región" para las ventanas de demostración.
- Opcional (flag): cola offline en IndexedDB si ninguna región responde (por ejemplo después de las 20:00), con reenvío al volver.

---

## 4. Lo que te faltaba considerar (checklist de diseño)

1. **Eco infinito** en replicación bidireccional → columna `origin_region` + filtro en el aplicador.
2. **Conflictos** → LWW determinista por `updated_at` + región; en producción, propiedad por región (*home region*) o CRDT.
3. **Ids** → uuid generado por el cliente; nunca `serial`, colisionan entre regiones.
4. **Idempotencia en el reintento** → la escritura pudo entrar en A justo antes de caer; el reintento en B no debe duplicar.
5. **Borrados** → soft delete; los *tombstones* y LWW no se llevan bien.
6. **Crecimiento del WAL** → un slot de replicación inactivo (Debezium caído o VM apagada a las 20:00) retiene WAL en Postgres; `max_slot_wal_keep_size` acota el riesgo y `heartbeat` lo evita en reposo. Un B1ms con 32 GiB se llenaría en semanas si se ignora.
7. **Parámetros de Flexible Server** → `wal_level=logical` (requiere reinicio), `max_replication_slots`, `max_wal_senders`, `ALTER ROLE … REPLICATION`, publicación y `REPLICA IDENTITY`.
8. **Durabilidad de la "cola"** → retención de 7 días en Kafka, datos en disco persistente (sobreviven al desasignar la VM), offsets commiteados tras aplicar.
9. **Orden** → una partición por tabla con clave = id; suficiente para la demo.
10. **Caché desactualizada** → el Replicator invalida Redis al aplicar; TTL corto como red de seguridad.
11. **Health real** → `/health` prueba Postgres y Redis, no solo el proceso; si no, el SPA no detecta `stop-db`.
12. **Flapping** → failback con histéresis; modo fijo para demostrar.
13. **HTTPS obligatorio y CORS** → Caddy con certificado automático; API con CORS para el dominio de SWA.
14. **IP pública estática** → la dinámica cambia al desasignar y rompe DNS/certificados.
15. **Reloj** → `updated_at` lo pone Postgres (hora Azure); nunca el navegador.
16. **Snapshot inicial de Debezium** → ambas bases empiezan vacías y la semilla se carga solo en A, así la propia replicación llena B.
17. **Arranque tras apagado** → contenedores `restart: always`, Debezium reanuda desde sus offsets, el slot persiste en Postgres.
18. **Nombres únicos** → sufijo aleatorio en DNS labels y nombre de SWA.
19. **Cuota de vCPU y SKU** → `preflight.sh` revisa cuota de la familia Basv2 por región y disponibilidad de B1ms (hoy el comando de cuota devolvió vacío desde tu Mac; el script lo reintenta).
20. **Qué no cubre la demo** → alta disponibilidad *dentro* de una región (una VM por región), autenticación de Kafka (red privada), Key Vault, Entra ID para Postgres. Se documentan como "camino a producción".

---

## 5. Seguridad y políticas MCAPS (para que nada te corte la comunicación)

**Lo verificado hoy en tu suscripción (solo lectura):**

- `az policy assignment list` solo muestra tres asignaciones a nivel suscripción, todas de Defender for Cloud (ASC DataProtection, OpenSourceRelationalDatabasesProtection, Defender for SQL on machines). Las políticas de grupo de administración no son visibles con tus permisos, así que la restricción que te cortó la comunicación en el pasado seguramente vive ahí (lo típico en MCAPS: NSG que abre 22/3389 a Internet se modifica o deniega).
- Planes de Defender en **Standard** (pagados): Servers P2, Open-source relational databases, CSPM, Storage, Key Vault, Resource Manager, AI, Containers, Cosmos DB, SQL, App Services. Impactan el costo (sección 6).

**Diseño para no chocar con la política:**

- **Ningún puerto de gestión abierto**: el NSG solo permite 443/80 desde Internet y 9092 desde la VNet par. Operación con `az vm run-command` (va por el agente, no por la red) y, si quieres consola, Bastion Developer ($0, si la región lo ofrece). Opción `ALLOW_SSH_FROM=<tu-ip>/32` desactivada por defecto.
- **Postgres solo privado** (subred delegada + Private DNS zone). El esquema y la configuración de CDC se aplican desde la VM con `run-command`, no desde tu Mac.
- **Kafka y Redis nunca en Internet**; Redis ni siquiera sale del host.
- **Sin cuentas de storage públicas** (boot diagnostics con storage gestionado) y sin secretos en el repo: la contraseña de Postgres se genera al desplegar y se inyecta por cloud-init; se guarda en `.env.generated` (ignorado por git).
- **Etiquetas** parametrizables por si la suscripción exige alguna (`project`, `owner`, `env`, `autoshutdown`).
- **`preflight.sh`** antes de crear nada: asignaciones con efecto Deny, *allowed locations*, SKUs permitidos, cuota, y `az deployment sub what-if` del Bicep. Si una política deniega IPs públicas en NIC, el script se detiene y propone la alternativa (Azure Front Door Standard, ~$35/mes, o Load Balancer Standard).

**Riesgo conocido de TLS:** `cloudapp.azure.com` **no** está en la Public Suffix List (lo verifiqué hoy), así que Let's Encrypt comparte límites por "dominio registrado" (`azure.com`). Caddy cae automáticamente a ZeroSSL si Let's Encrypt limita. Lo más robusto es un **dominio propio** (`api-a.demo.tudominio.com`, `api-b…`) si tienes uno; plan de contingencia para el día de la demo: certificado autofirmado aceptado manualmente en el navegador del presentador.

---

## 6. Costos estimados (USD/mes, pago por uso, precios de lista aproximados; validar en la calculadora)

| Recurso | 24×7 | Con apagado 20:00 → 08:00 |
|---|---|---|
| 2 × VM B2as_v2 (2 vCPU / 8 GiB) | ~97 | ~49 |
| 2 × disco SO Standard SSD 64 GiB | ~10 | ~10 |
| 2 × IP pública estática Standard | ~7 | ~7 |
| 2 × PostgreSQL Flexible B1ms + 32 GiB | ~32 | ~32 (~20 si también se detienen de noche) |
| Peering global (tráfico de demo < 1 GB) | < 1 | < 1 |
| Static Web Apps Free, Bastion Developer, presupuesto, run-command | 0 | 0 |
| **Subtotal infraestructura** | **~147** | **~99** (~87 deteniendo Postgres de noche) |
| Opción económica: VMs B2als_v2 (4 GiB) | ~98 | ~75 |

**Costo que impone tu suscripción (Defender for Cloud en Standard):** aproximadamente $15/VM/mes (Servers P2), $15/servidor/mes (open-source relational databases) y ~$5 por recurso facturable (CSPM) → **hasta ~$80/mes adicionales** si no se excluye nada. Mitigación prevista en el Bicep: deshabilitar Defender a nivel de recurso en los dos Postgres (`advancedThreatProtectionSettings`) y, si la gobernanza lo permite, en las VMs (`Microsoft.Security/pricings` a nivel recurso). CSPM no se puede excluir por recurso. Esto se confirma con la primera factura diaria en Cost Management.

Protecciones: presupuesto mensual con alertas al 80 % y 100 % (correo parametrizable), `destroy.sh` borra los tres grupos de recursos, y los discos/IP siguen costando con la VM apagada (~$17/mes), lo que se documenta.

---

## 7. Apagado a las 20:00 y encendido

- **Apagado**: recurso `Microsoft.DevTestLab/schedules` `shutdown-computevm-<vm>` por VM, 20:00 en `Central Standard Time (Mexico)` (parámetro), con notificación opcional 30 min antes. Es gratis y es lo que usa el portal. Si MCAPS impone su propio auto-shutdown (suele ser en UTC), convive sin problema: gana el primero que llegue.
- **Encendido**: `./scripts/start.sh` (un comando, 2–3 min hasta `/health` verde en ambas regiones). Opcional: cuenta de Azure Automation con identidad administrada (gratis hasta 500 min/mes) para encender a las 08:00 y detener/arrancar también los Postgres de noche. Lo dejo como flag porque en tenants corporativos a veces no se pueden crear *app registrations*, y Automation con identidad administrada lo evita.
- **Efecto en la demo**: a las 20:00 caen las dos regiones a la vez; el SPA queda en modo "sin regiones" con datos en caché. Si quieres mostrarlo como escena, se activa la cola offline.

---

## 8. Estructura del repositorio que construiría

```
azure-active-active-demo/
├── README.md                    # qué es, cómo levantarlo en 1 comando, cómo correr la demo
├── PROMPT.md                    # prompt listo para GitHub Copilot / Claude / Codex
├── AGENTS.md · CLAUDE.md · .github/copilot-instructions.md   # mismas instrucciones, convención de cada agente
├── docs/
│   ├── architecture.svg / architecture.md   # diagrama + explicación
│   ├── runbook-demo.md          # guion de las 5 escenas con comandos y qué decir
│   ├── decisiones.md            # ADRs cortos (por qué pull, por qué LWW, por qué SWA…)
│   ├── costos.md · mcaps-politicas.md · camino-a-produccion.md
├── infra/                       # Bicep: main.bicep (suscripción) + módulos network, vm, postgres, swa, budget
│   └── params/demo.bicepparam
├── scripts/                     # preflight.sh · deploy.sh · configure-cdc.sh · status.sh · chaos.sh
│                                # verify-sync.sh · start.sh · stop.sh · destroy.sh
├── vm/                          # cloud-init.yaml · docker-compose.yml · caddy/Caddyfile · connect/debezium.json
├── services/api/                # FastAPI
├── services/replicator/         # aplicador Python
├── web/                         # SPA + service worker + staticwebapp.config.json
├── db/schema.sql · db/seed.sql
└── local/docker-compose.yml     # las dos "regiones" en tu Mac (2 Postgres, 2 Kafka, 2 API…) para ensayar sin costo
```

`PROMPT.md` dirá, en esencia: "clona el repo, ejecuta `az login`, selecciona la suscripción, corre `scripts/preflight.sh`, luego `scripts/deploy.sh`, verifica con `scripts/status.sh` y sigue `docs/runbook-demo.md`"; con los parámetros (regiones, tamaño de VM, zona horaria, dominio) explicados y los puntos donde el agente debe detenerse a pedir confirmación.

---

## 9. Plan de construcción (si autorizas)

| Fase | Qué | Costo Azure | Tiempo estimado |
|---|---|---|---|
| 0 | Repo completo + ensayo local con Docker Compose (2 regiones en tu Mac), pruebas de failover, eco y LWW | $0 | 1 sesión |
| 1 | `preflight.sh` contra tu suscripción + `deploy.sh` (Bicep) + `configure-cdc.sh` + publicación del SPA | empieza a correr el costo | ~30–40 min de despliegue |
| 2 | Ejecutar el guion completo (caos, cola, recuperación, verificación), ajustar tiempos, dejar runbook y commit final | — | 1 sesión |

Puedo autorizar por fases: construir y probar en local primero (sin gastar) y aprovisionar cuando me confirmes.

---

## 10. Riesgos y supuestos

| Riesgo | Probabilidad | Mitigación |
|---|---|---|
| Política de grupo de administración deniega IP pública o la región elegida | baja–media | `preflight.sh` + what-if; alternativa Front Door Standard (~$35/mes) o cambio de región |
| Let's Encrypt limita por `azure.com` | media | ZeroSSL automático; dominio propio; contingencia con autofirmado aceptado |
| Memoria justa en la VM (Kafka + Connect + agentes de Defender) | baja con 8 GiB | heaps acotados (Kafka 512 MB, Connect 1 GB); B2as_v2 por defecto |
| WAL retenido por slot inactivo durante apagados largos | media | `max_slot_wal_keep_size`, heartbeat, alerta en `/status`; detener Postgres de noche lo anula |
| Costo de Defender que no se puede excluir | alta (ya está en Standard) | documentado; exclusión por recurso donde Azure lo permita; presupuesto con alerta |
| Cuota de vCPU en una región | baja | `preflight.sh`; tamaño y región son parámetros |

---

## 11. Preguntas antes de autorizar (con mi valor por defecto)

1. **Regiones**: ¿South Central US + East US 2? (Alternativas: Mexico Central como A si quieres "región en México", +costo y hay que verificar SKUs; Brazil South es ~30 % más caro.)
2. **Zona horaria del apagado**: ¿`Central Standard Time (Mexico)` (20:00 CDMX)?
3. **Tamaño de VM**: ¿B2as_v2 8 GiB (recomendado) o B2als_v2 4 GiB (económico)?
4. **Dominio**: ¿tienes un dominio propio para `api-a` / `api-b`? Si no, uso `*.cloudapp.azure.com` con el plan de contingencia descrito.
5. **Correo para la alerta de presupuesto** y monto (propongo $150/mes).
6. **Fases**: ¿construyo y pruebo en local primero (Fase 0, $0) y aprovisiono cuando confirmes, o todo de una vez?
7. **Suscripción destino**: ¿la que está activa en `az` (`<suscripción MCAPS detectada>`) u otra?
