# Decisiones de diseño (ADR cortos) y camino a producción

| # | Decisión | Alternativas | Por qué |
|---|---|---|---|
| 1 | Failover en el **navegador** (config con A y B, sondeo y reintento) | Traffic Manager (DNS, depende del TTL), Front Door (~35 USD/mes, sondeos cada ≥ 10 s) | Es la forma más barata de lograr "0 interrupción percibida" y además se ve en la demo |
| 2 | Replicación **pull**: cada Replicator consume el Kafka de la otra región | MirrorMaker 2 (otro proceso), sink JDBC de Kafka Connect | Los offsets viven en el Kafka origen: si la región destino cae, la cola la espera. El aplicador en Python permite anti-eco, LWW y soft delete, que un sink JDBC no sabe hacer |
| 3 | Columna `origin_region` para el anti-eco | Filtrar en Debezium con SMT scripting (requiere jars extra), replication origins de Postgres (no expuestos por Debezium) | Simple, visible y auditable |
| 4 | LWW por `updated_at` del servidor Postgres | Propiedad por región (home region), CRDT | Suficiente para demostrar; en producción conviene asignar dueño por registro o usar relojes híbridos |
| 5 | uuid generado por el cliente + `PUT` idempotente | `serial` + `POST` | Un reintento tras failover no debe duplicar; los seriales chocan entre regiones |
| 6 | Soft delete | Tombstones de Debezium | Los borrados también entran al LWW y se pueden "revivir" si llega una escritura más nueva |
| 7 | Debezium en Kafka Connect | Debezium Server (más ligero) | Es el estándar que el público reconoce; cabe en 8 GiB |
| 8 | PostgreSQL Flexible **B1ms** con acceso privado | Postgres en la VM (más barato, no es PaaS), Single Server (retirado) | Plan más barato con `wal_level=logical`; privado para no chocar con políticas |
| 9 | Static Web Apps Free para el SPA | Storage static website, servirlo desde las VMs | Gratis, global, HTTPS; no depende de A ni de B |
| 10 | Sin SSH; `az vm run-command` | Bastion Standard (~140 USD/mes), SSH desde /32 | Nada que una política de puertos de gestión pueda cortar; Bastion Developer queda como opción gratuita |
| 11 | Secretos en `.secrets/` + `.env` en la VM con `chmod 600` | Key Vault + identidad administrada | Menos piezas para una demo; Key Vault es el primer paso a producción |
| 12 | Apagado con `DevTestLab/schedules` | Automation, Start/Stop v2 | Gratis y es lo que usa el portal; el encendido es `scripts/start.sh` |

## Camino a producción

- Entrada global con Azure Front Door (WAF, anycast) manteniendo el reintento en el cliente.
- Kafka con 3 brokers (o Event Hubs con endpoint Kafka), TLS + SASL, ACLs; Kafka Connect en modo distribuido.
- Postgres con HA zonal, réplicas de lectura, Entra ID y Private Endpoint; alertas sobre `pg_replication_slots`.
- Propiedad de registros por región o vector clocks para conflictos; cola de "conflictos a revisar".
- Observabilidad: Azure Monitor / Log Analytics para VMs y Postgres, métricas de lag del Replicator exportadas.
- Secretos en Key Vault con identidad administrada; imágenes en Azure Container Registry; despliegue por GitHub Actions con OIDC.
- Pruebas de caos programadas (Azure Chaos Studio).
