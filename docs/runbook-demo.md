# Guion de la demo (runbook)

Antes de empezar: `./scripts/start.sh` (enciende PostgreSQL si la gobernanza lo detuvo de noche y las VMs; 3–5 min), `./scripts/status.sh` (todo OK), `./scripts/seed.sh A 6` (datos de ejemplo).

Abre las ventanas del SPA (URL global en `.env.deploy` → `SWA_HOST`; si no se publicó en Static Web Apps, usa `https://<VM_A_FQDN>/app/`, que sirve el mismo SPA):

| Ventana | URL | Para qué |
|---|---|---|
| Automática | `https://<SWA_HOST>/` | Es el usuario final: no sabe de regiones. En el formulario eliges a qué región mandar cada registro (automática, A o B) |
| Fijada a A | `https://<SWA_HOST>/?region=a` | Ver lo que hay en la base de A |
| Fijada a B | `https://<SWA_HOST>/?region=b` | Ver lo que hay en la base de B |
| Visor A | `https://<SWA_HOST>/visor.html?region=a` | Tabla de la base de A en vivo, sin failover: tenla abierta para que el cliente vea dónde cae cada escritura |
| Visor B | `https://<SWA_HOST>/visor.html?region=b` | Lo mismo para la base de B |

## Escena 0 · Normalidad (2 min)

1. Crea un registro con "Guardar en: Región A". En ~1 s (medido con `scripts/smoke-test.sh`) aparece en el visor de B resaltado como `replicado desde A` y en la bitácora de B: "replicado … desde A". Repite con "Guardar en: Región B" y mira el visor de A.
2. En el panel: Debezium `RUNNING`, Replicator vivo, cola → 0, lag de pocos cientos de ms.
3. Qué decir: cada escritura va a Postgres local; Debezium la captura por el slot lógico; el Replicator de la otra región la consume por el peering y la aplica. La vuelta la descarta como eco.

## Escena 1 · Cae la región A (3 min)

```bash
./scripts/chaos.sh stop-vm A        # ~35 s en desasignar (medido)
```

1. La ventana automática pasa a "Conectado a Región B (failover)" sin mostrar error. Crea y edita registros: todo sigue funcionando. Si eliges "Guardar en: Región A" a propósito, el SPA avisa que A no respondió y no guarda.
2. En el panel de B: "Cola → A: N eventos esperan a A" crece con cada escritura. El Replicator de B dice "Kafka A: NO alcanzable".
3. Qué decir: el navegador reintenta en B en el mismo segundo; Kafka B conserva los eventos con los offsets del grupo `replicator-a`.

Variante: `./scripts/chaos.sh stop-db A` apaga solo Postgres A; `/health` de A falla y el resultado es el mismo (recuperar con `start-db A`, 1–2 min).

## Escena 2 · Vuelve A (3 min)

```bash
./scripts/chaos.sh start-vm A       # espera a /health (~75 s medido, incluye arranque de contenedores)
./scripts/verify-sync.sh            # conteo + hash idénticos
```

1. La cola de B baja a 0 en segundos (medido: 3 eventos drenados antes de que `/health` de A respondiera; el Replicator mostró lag ≈ 61 s = duración de la caída); en la bitácora de la ventana fijada a A aparecen los "replicado … desde B" en ráfaga.
2. La ventana automática vuelve a A tras 3 sondeos sanos ("failback").
3. Qué decir: RPO = lo que A escribió justo antes de caer y B no alcanzó a leer; llega ahora porque el log de Kafka A está en disco.

## Escena 3 · Partición y conflicto (opcional, 3 min)

```bash
./scripts/chaos.sh partition        # bloquea 9092 entre VNets
```

1. Ambas regiones siguen aceptando escrituras; las colas crecen en los dos paneles.
2. Edita el texto del **mismo** registro en la ventana fijada a A y en la fijada a B (botón "editar").
3. `./scripts/chaos.sh heal` → los Replicators drenan; gana la última escritura por `updated_at`; `./scripts/verify-sync.sh` vuelve a coincidir.

## Cierre

- A las 20:00 (`TIME_ZONE`) las VMs se apagan solas: el SPA muestra "Sin conexión · datos en caché" y encola escrituras en el navegador (se envían al volver).
- `./scripts/stop.sh --db` apaga también Postgres si no hay demo mañana. `./scripts/destroy.sh` borra todo.

## Si algo falla

| Síntoma | Qué mirar |
|---|---|
| `https://<SWA_HOST>` muestra el 404 de Azure Static Web Apps | El SPA no se publicó (SWA CLI necesita x64/Rosetta): usa `https://<VM_A_FQDN>/app/` o publica desde una máquina x64 con `./scripts/deploy-web.sh` |
| `/health` de una región en 503 | `./scripts/status.sh`; Postgres detenido o VM apagada |
| Debezium no está `RUNNING` | `./scripts/configure-cdc.sh A` (idempotente); logs: `run_on_vm A 'cd /opt/aa && docker compose logs --tail 50 connect'` |
| La cola no baja al volver la región | `run_on_vm A 'cd /opt/aa && docker compose logs --tail 50 replicator'`; revisa el NSG (regla ChaosDenyKafka) |
| El SPA no carga | `./scripts/deploy-web.sh` (regenera `web/config.json` y publica) |
| El navegador muestra una versión anterior del SPA tras publicar | El SPA se recarga solo al detectar la versión nueva; si no, abre la misma URL con `?reset=1` (borra solo el Service Worker y la caché de esta app, no la de otros sitios) |
| TLS falla en una API | `./scripts/wait-healthy.sh` muestra los logs de Caddy |
