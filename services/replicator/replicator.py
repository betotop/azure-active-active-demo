"""Replicator: consume el CDC de la región PAR (su Kafka, por el peering) y lo aplica en Postgres local.

Reglas:
- Anti-eco: si origin_region == mi región, el evento es mi propio cambio que dio la vuelta → se descarta.
- LWW: el upsert solo gana si updated_at es más nuevo (desempate: región alfabéticamente menor).
- Modelo pull con offsets en el Kafka origen: si esta región estuvo caída, al volver reanuda donde iba.
- Commit del offset DESPUÉS de aplicar (at-least-once + upsert idempotente = efectivamente una vez).
- Invalida la caché Redis y publica un evento SSE al aplicar.
"""
import datetime as dt
import json
import os
import signal
import time

import psycopg
import redis as redislib
from confluent_kafka import Consumer, KafkaError

REGION = os.environ["REGION"].lower()
PEER = os.environ["PEER_REGION"].lower()
PEER_KAFKA = os.environ["PEER_KAFKA"]
REDIS_URL = os.environ.get("REDIS_URL", "redis://redis:6379/0")
PG_DSN = (
    f"host={os.environ['PG_HOST']} port=5432 dbname={os.environ.get('PG_DB', 'appdb')} "
    f"user={os.environ['PG_USER']} password={os.environ['PG_PASSWORD']} sslmode=require connect_timeout=5"
)
TOPIC = f"cdc.{PEER}.public.tickets"
GROUP = f"replicator-{REGION}"
LIST_KEY = "tickets:list"
EVENTS_CH = "events"
STATS_KEY = "repl:stats"

UPSERT = """
INSERT INTO tickets (id, folio, titulo, estado, prioridad, origin_region, created_at, updated_at, version, deleted_at)
VALUES (%(id)s::uuid, %(folio)s, %(titulo)s, %(estado)s, %(prioridad)s, %(origin_region)s,
        %(created_at)s::timestamptz, %(updated_at)s::timestamptz, %(version)s, %(deleted_at)s::timestamptz)
ON CONFLICT (id) DO UPDATE SET
  folio = EXCLUDED.folio, titulo = EXCLUDED.titulo, estado = EXCLUDED.estado, prioridad = EXCLUDED.prioridad,
  origin_region = EXCLUDED.origin_region, updated_at = EXCLUDED.updated_at, version = EXCLUDED.version,
  deleted_at = EXCLUDED.deleted_at
WHERE EXCLUDED.updated_at > tickets.updated_at
   OR (EXCLUDED.updated_at = tickets.updated_at AND EXCLUDED.origin_region < tickets.origin_region)
"""
DELETE = "DELETE FROM tickets WHERE id = %(id)s::uuid AND updated_at <= %(updated_at)s::timestamptz"

running = True


def log(msg: str):
    print(f"{dt.datetime.now(dt.timezone.utc).strftime('%H:%M:%S')} [replicator-{REGION}] {msg}", flush=True)


def stop(*_):
    global running
    running = False


class Stats:
    def __init__(self, url):
        self.r = redislib.Redis.from_url(url, decode_responses=True, socket_timeout=2, socket_connect_timeout=2)

    def _safe(self, fn):
        try:
            return fn()
        except Exception:
            return None

    def incr(self, field, n=1):
        self._safe(lambda: self.r.hincrby(STATS_KEY, field, n))

    def set(self, **fields):
        self._safe(lambda: self.r.hset(STATS_KEY, mapping=fields))

    def notify(self, ev, row, res):
        def _do():
            self.r.delete(LIST_KEY)
            self.r.publish(EVENTS_CH, json.dumps({
                "type": "replicated", "region": REGION, "from": row.get("origin_region"),
                "op": ev.get("op"), "result": res, "ticket": row,
                "ts": dt.datetime.now(dt.timezone.utc).isoformat()}))
        self._safe(_do)


def pg_connect(stats: Stats):
    while running:
        try:
            conn = psycopg.connect(PG_DSN, autocommit=True)
            log("postgres local conectado")
            stats.set(pg_connected=1)
            return conn
        except Exception as e:
            stats.set(pg_connected=0, last_error=f"pg: {e}"[:160])
            log(f"postgres local no disponible, reintento en 5 s: {e}")
            time.sleep(5)
    return None


def apply(conn, ev: dict, stats: Stats) -> str:
    op = ev.get("op")
    row = ev.get("after") if op in ("c", "u", "r") else ev.get("before")
    if not row:
        return "skip"
    if row.get("origin_region") == REGION:
        return "echo"
    if op == "d":
        cur = conn.execute(DELETE, row)
        return "deleted" if cur.rowcount else "skipped_older"
    cur = conn.execute(UPSERT, row)
    return "applied" if cur.rowcount else "skipped_older"


def main():
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    stats = Stats(REDIS_URL)
    stats.set(region=REGION, peer=PEER, topic=TOPIC, group=GROUP, started_at=time.time())
    log(f"consumiendo {TOPIC} desde {PEER_KAFKA} con grupo {GROUP}")
    consumer = Consumer({
        "bootstrap.servers": PEER_KAFKA,
        "group.id": GROUP,
        "client.id": f"replicator-{REGION}",
        "auto.offset.reset": "earliest",
        "enable.auto.commit": False,
        "session.timeout.ms": 30000,
        "socket.timeout.ms": 10000,
        "reconnect.backoff.max.ms": 10000,
        "log_level": 3,
    })
    consumer.subscribe([TOPIC])
    conn = pg_connect(stats)
    last_beat = 0.0
    peer_ok = None
    while running:
        now = time.time()
        if now - last_beat >= 5:
            last_beat = now
            try:
                consumer.list_topics(TOPIC, timeout=2)
                ok = 1
            except Exception:
                ok = 0
            if ok != peer_ok:
                log("kafka de la región par " + ("ALCANZABLE" if ok else "NO alcanzable (¿región caída?) — esperando"))
                peer_ok = ok
            stats.set(alive_at=now, peer_connected=ok)
        msg = consumer.poll(1.0)
        if msg is None:
            continue
        if msg.error():
            if msg.error().code() in (KafkaError._PARTITION_EOF, KafkaError.UNKNOWN_TOPIC_OR_PART):
                continue  # topic aún no creado en la región par: no es un error, solo esperar
            stats.incr("errors")
            stats.set(last_error=str(msg.error())[:160])
            log(f"error kafka: {msg.error()}")
            time.sleep(1)
            continue
        if not msg.value():
            consumer.commit(message=msg, asynchronous=False)
            continue
        try:
            ev = json.loads(msg.value())
        except Exception as e:
            stats.incr("errors")
            log(f"evento ilegible en offset {msg.offset()}: {e}")
            consumer.commit(message=msg, asynchronous=False)
            continue
        attempts = 0
        while running:
            try:
                res = apply(conn, ev, stats)
                break
            except psycopg.OperationalError as e:
                log(f"postgres se cayó aplicando el evento, reconectando: {e}")
                conn = pg_connect(stats)
            except Exception as e:
                attempts += 1
                stats.incr("errors")
                stats.set(last_error=str(e)[:160])
                log(f"error aplicando offset {msg.offset()} (intento {attempts}): {e}")
                if attempts >= 3:
                    res = "failed"
                    break
                time.sleep(2)
        else:
            break
        stats.incr(res)
        if res in ("applied", "deleted"):
            row = ev.get("after") or ev.get("before") or {}
            lag_ms = int(time.time() * 1000) - int(ev.get("ts_ms") or 0) if ev.get("ts_ms") else None
            stats.set(last_applied_at=time.time(), last_lag_ms=lag_ms if lag_ms is not None else -1,
                      last_offset=msg.offset())
            stats.notify(ev, row, res)
            log(f"{res} {row.get('folio')} (origen {row.get('origin_region')}, op {ev.get('op')}, lag {lag_ms} ms)")
        consumer.commit(message=msg, asynchronous=False)
    consumer.close()
    log("detenido")


if __name__ == "__main__":
    main()
