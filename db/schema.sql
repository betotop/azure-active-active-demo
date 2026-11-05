-- Esquema de la demo (idéntico en ambas regiones; Debezium NO replica DDL).
CREATE TABLE IF NOT EXISTS public.tickets (
  id            uuid PRIMARY KEY,                       -- lo genera el cliente: evita colisiones entre regiones
  folio         text NOT NULL,
  titulo        text NOT NULL,
  estado        text NOT NULL DEFAULT 'abierto',        -- abierto | en_proceso | resuelto | cerrado
  prioridad     text NOT NULL DEFAULT 'media',          -- baja | media | alta | critica
  origin_region text NOT NULL,                          -- región que hizo la ÚLTIMA escritura (anti-eco + desempate)
  created_at    timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at    timestamptz NOT NULL DEFAULT clock_timestamp(),  -- reloj del servidor Postgres: base del LWW
  version       bigint NOT NULL DEFAULT 1,
  deleted_at    timestamptz                             -- soft delete (compatible con LWW)
);
CREATE INDEX IF NOT EXISTS tickets_updated_idx ON public.tickets (updated_at DESC) WHERE deleted_at IS NULL;
-- Imagen completa en updates/deletes: el Replicator ve origin_region también en borrados.
ALTER TABLE public.tickets REPLICA IDENTITY FULL;

-- Tabla de heartbeat de Debezium: mantiene el slot avanzando aunque no haya tráfico (evita WAL retenido).
CREATE TABLE IF NOT EXISTS public.dbz_heartbeat (id int PRIMARY KEY, ts timestamptz NOT NULL DEFAULT now());
INSERT INTO public.dbz_heartbeat (id, ts) VALUES (1, now()) ON CONFLICT (id) DO NOTHING;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'dbz_pub') THEN
    CREATE PUBLICATION dbz_pub FOR TABLE public.tickets, public.dbz_heartbeat;
  END IF;
END $$;
