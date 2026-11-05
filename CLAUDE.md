# Instrucciones para agentes (Codex, Copilot, Claude Code)

- Propósito del repo: demo de resiliencia activo-activo en Azure (2 regiones, PostgreSQL Flexible + Debezium + Kafka + Redis en VM, SPA cacheado). Lee `README.md` y `docs/architecture.md` antes de tocar nada.
- Para desplegar o ensayar la demo sigue `PROMPT.md` paso a paso; no inventes recursos fuera de `infra/` ni ejecutes comandos de Azure que no estén en `scripts/`.
- Operación de VMs sin SSH: usa `scripts/lib.sh` (`run_on_vm A '<comando>'`). Salida limitada a 4 KB: usa `tail`.
- Compatibilidad: los scripts corren en bash 3.2 (macOS) y bash 5. Nada de `declare -A`, `${var,,}` ni `mapfile`.
- Secretos y estado local: `.secrets/`, `.env.deploy`, `web/config.json` están ignorados por git. No los commitees.
- Antes de proponer cambios de código: `python3 -m py_compile services/api/app.py services/replicator/replicator.py`, `node --check web/app.js`, `bash -n scripts/*.sh`, `az bicep build -f infra/main.bicep --stdout >/dev/null`.
- Costos: todo recurso nuevo debe justificarse; la demo apunta a ≈ 100 USD/mes con apagado nocturno.
