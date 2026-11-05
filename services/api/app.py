"""API de la región (FastAPI).

- /tickets: CRUD idempotente (uuid generado por el cliente), escrituras locales con origin_region.
- /health : prueba Postgres y Redis (lo usa el SPA para decidir el failover).
- /status : telemetría para el panel: slot de replicación, cola saliente en Kafka, estado del
            conector Debezium, estadísticas del Replicator, alcance del Kafka par.
- /events : SSE alimentado por Redis pub/sub (escrituras locales y cambios replicados).
"""
import asyncio
import datetime as dt
import json
import logging
import os
import socket
import time
import uuid
from contextlib import asynccontextmanager

import httpx
import redis.asyncio as aioredis
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, Response, StreamingResponse
from psycopg.rows import dict_row
from psycopg_pool import AsyncConnectionPool
from pydantic import BaseModel, Field

log = logging.getLogger("api")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

REGION = os.environ["REGION"].lower()
PEER = os.environ["PEER_REGION"].lower()
REGION_NAME = os.environ.get("REGION_NAME", REGION.upper())
PEER_KAFKA = os.environ["PEER_KAFKA"]
LOCAL_KAFKA = os.environ.get("LOCAL_KAFKA", "kafka:19092")
REDIS_URL = os.environ.get("REDIS_URL", "redis://redis:6379/0")
CONNECT_URL = os.environ.get("CONNECT_URL", "http://connect:8083")
PG_DSN = (
    f"host={os.environ['PG_HOST']} port=5432 dbname={os.environ.get('PG_DB', 'appdb')} "
    f"user={os.environ['PG_USER']} password={os.environ['PG_PASSWORD']} sslmode=require connect_timeout=3"
)
TOPIC_LOCAL = f"cdc.{REGION}.public.tickets"
PEER_GROUP = f"replicator-{PEER}"
LIST_KEY = "tickets:list"
EVENTS_CH = "events"
STATS_KEY = "repl:stats"
COLS = "id, folio, titulo, estado, prioridad, origin_region, created_at, updated_at, version, deleted_at"
ESTADOS = ("abierto", "en_proceso", "resuelto", "cerrado")
PRIORIDADES = ("baja", "media", "alta", "critica")
START = time.time()

pool = AsyncConnectionPool(
    PG_DSN, min_size=1, max_size=6, open=False, kwargs={"row_factory": dict_row, "autocommit": True}
)
r = aioredis.from_url(REDIS_URL, decode_responses=True, socket_timeout=2, socket_connect_timeout=2)


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def ser(row: dict) -> dict:
    out = {}
    for k, v in row.items():
        if isinstance(v, dt.datetime):
            out[k] = v.isoformat()
        elif isinstance(v, uuid.UUID):
            out[k] = str(v)
        else:
            out[k] = v
    return out


@asynccontextmanager
async def lifespan(_: FastAPI):
    await pool.open(wait=False)
    log.info("api región %s arriba (peer=%s, peer_kafka=%s)", REGION, PEER, PEER_KAFKA)
    yield
    await pool.close()
    await r.aclose()


app = FastAPI(title=f"API región {REGION.upper()} · demo activo-activo", lifespan=lifespan)
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"], expose_headers=["X-Region", "X-Cache"])


@app.middleware("http")
async def region_header(request: Request, call_next):
    resp = await call_next(request)
    resp.headers["X-Region"] = REGION
    return resp


async def q(sql: str, params=(), timeout: float = 2.5, fetch: str = "all"):
    async with pool.connection(timeout=timeout) as conn:
        cur = await asyncio.wait_for(conn.execute(sql, params), timeout)
        if fetch == "one":
            return await cur.fetchone()
        if fetch == "all":
            return await cur.fetchall()
        return cur.rowcount


async def invalidate_and_publish(evt: dict):
    try:
        await r.delete(LIST_KEY)
        await r.publish(EVENTS_CH, json.dumps(evt, default=str))
    except Exception as e:  # Redis caído no debe romper la escritura
        log.warning("redis no disponible al invalidar/publicar: %s", e)


# ---------------------------------------------------------------- salud
@app.get("/")
async def root():
    return {"service": "api-activo-activo", "region": REGION, "region_name": REGION_NAME,
            "endpoints": ["/health", "/status", "/tickets", "/events"]}


@app.get("/health")
async def health():
    try:
        await q("SELECT 1", timeout=1.5, fetch="one")
        await asyncio.wait_for(r.ping(), 1.0)
    except Exception as e:
        return JSONResponse({"status": "down", "region": REGION, "error": str(e)[:160], "ts": now_iso()}, status_code=503)
    return {"status": "ok", "region": REGION, "ts": now_iso()}


# ---------------------------------------------------------------- tickets
class TicketIn(BaseModel):
    titulo: str = Field(min_length=1, max_length=200)
    estado: str = "abierto"
    prioridad: str = "media"
    folio: str | None = Field(default=None, max_length=40)


def validar(estado: str | None, prioridad: str | None):
    if estado is not None and estado not in ESTADOS:
        raise HTTPException(400, f"estado inválido, usa uno de {ESTADOS}")
    if prioridad is not None and prioridad not in PRIORIDADES:
        raise HTTPException(400, f"prioridad inválida, usa una de {PRIORIDADES}")


def new_folio() -> str:
    return f"{REGION.upper()}-{dt.datetime.now(dt.timezone.utc).strftime('%y%m%d')}-{uuid.uuid4().hex[:4].upper()}"


@app.get("/tickets")
async def list_tickets():
    cached = None
    try:
        cached = await r.get(LIST_KEY)
    except Exception:
        pass
    if cached:
        return Response(cached, media_type="application/json", headers={"X-Cache": "HIT"})
    rows = await q(f"SELECT {COLS} FROM tickets WHERE deleted_at IS NULL ORDER BY updated_at DESC LIMIT 200")
    body = json.dumps({"region": REGION, "ts": now_iso(), "items": [ser(x) for x in rows]})
    try:
        await r.set(LIST_KEY, body, ex=30)
    except Exception:
        pass
    return Response(body, media_type="application/json", headers={"X-Cache": "MISS"})


@app.get("/tickets/{tid}")
async def get_ticket(tid: uuid.UUID):
    row = await q(f"SELECT {COLS} FROM tickets WHERE id = %s", (tid,), fetch="one")
    if not row:
        raise HTTPException(404, "no existe")
    return ser(row)


@app.post("/tickets", status_code=201)
async def create_ticket(t: TicketIn):
    return await upsert_ticket(uuid.uuid4(), t)


@app.put("/tickets/{tid}")
async def upsert_ticket(tid: uuid.UUID, t: TicketIn):
    """Idempotente: repetir el PUT con el mismo id (p. ej. tras un failover) no duplica."""
    validar(t.estado, t.prioridad)
    row = await q(
        f"""INSERT INTO tickets (id, folio, titulo, estado, prioridad, origin_region)
            VALUES (%s, %s, %s, %s, %s, %s)
            ON CONFLICT (id) DO UPDATE SET
              titulo = EXCLUDED.titulo, estado = EXCLUDED.estado, prioridad = EXCLUDED.prioridad,
              origin_region = EXCLUDED.origin_region, updated_at = clock_timestamp(),
              version = tickets.version + 1, deleted_at = NULL
            RETURNING {COLS}""",
        (tid, t.folio or new_folio(), t.titulo, t.estado, t.prioridad, REGION), fetch="one")
    out = ser(row)
    await invalidate_and_publish({"type": "upsert", "region": REGION, "ticket": out, "ts": now_iso()})
    return out


@app.patch("/tickets/{tid}")
async def patch_ticket(tid: uuid.UUID, body: dict):
    campos = {k: v for k, v in body.items() if k in ("titulo", "estado", "prioridad")}
    if not campos:
        raise HTTPException(400, "nada que actualizar (titulo, estado, prioridad)")
    validar(campos.get("estado"), campos.get("prioridad"))
    sets = ", ".join(f"{k} = %s" for k in campos)
    row = await q(
        f"""UPDATE tickets SET {sets}, origin_region = %s, updated_at = clock_timestamp(), version = version + 1
            WHERE id = %s AND deleted_at IS NULL RETURNING {COLS}""",
        (*campos.values(), REGION, tid), fetch="one")
    if not row:
        raise HTTPException(404, "no existe")
    out = ser(row)
    await invalidate_and_publish({"type": "upsert", "region": REGION, "ticket": out, "ts": now_iso()})
    return out


@app.delete("/tickets/{tid}")
async def delete_ticket(tid: uuid.UUID):
    """Soft delete: compatible con LWW y se replica como un update."""
    row = await q(
        f"""UPDATE tickets SET deleted_at = clock_timestamp(), updated_at = clock_timestamp(),
            version = version + 1, origin_region = %s
            WHERE id = %s AND deleted_at IS NULL RETURNING {COLS}""",
        (REGION, tid), fetch="one")
    if not row:
        raise HTTPException(404, "no existe")
    out = ser(row)
    await invalidate_and_publish({"type": "delete", "region": REGION, "ticket": out, "ts": now_iso()})
    return out


# ---------------------------------------------------------------- status
async def check_pg():
    t0 = time.perf_counter()
    cnt = await q("SELECT count(*) AS n FROM tickets WHERE deleted_at IS NULL", fetch="one")
    slots = await q(
        """SELECT slot_name, active,
                  pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)::bigint AS retained_bytes
           FROM pg_replication_slots""")
    return {"ok": True, "latency_ms": round((time.perf_counter() - t0) * 1000, 1),
            "tickets": cnt["n"], "slots": [ser(s) for s in slots]}


async def check_redis():
    t0 = time.perf_counter()
    await asyncio.wait_for(r.ping(), 1.5)
    ttl = await r.ttl(LIST_KEY)
    return {"ok": True, "latency_ms": round((time.perf_counter() - t0) * 1000, 1),
            "list_cached": ttl > 0, "list_ttl_s": ttl if ttl > 0 else 0}


def check_kafka():
    """Cola SALIENTE: eventos de mi topic que el Replicator de la región par aún no ha consumido.
    Sus offsets viven en MI Kafka, así que si la otra región está caída, aquí se ve crecer la cola."""
    from confluent_kafka import Consumer, ConsumerGroupTopicPartitions, TopicPartition
    from confluent_kafka.admin import AdminClient

    admin = AdminClient({"bootstrap.servers": LOCAL_KAFKA, "socket.timeout.ms": 3000})
    md = admin.list_topics(timeout=3)
    out = {"ok": True, "topic": TOPIC_LOCAL, "topic_exists": TOPIC_LOCAL in md.topics,
           "topic_end": 0, "peer_group": PEER_GROUP, "peer_group_committed": None, "outbound_pending": 0}
    if not out["topic_exists"]:
        return out
    c = Consumer({"bootstrap.servers": LOCAL_KAFKA, "group.id": f"status-probe-{REGION}",
                  "enable.auto.commit": False, "socket.timeout.ms": 3000})
    try:
        lo, hi = c.get_watermark_offsets(TopicPartition(TOPIC_LOCAL, 0), timeout=3)
    finally:
        c.close()
    out["topic_end"] = hi
    committed = None
    try:
        futs = admin.list_consumer_group_offsets([ConsumerGroupTopicPartitions(PEER_GROUP)], require_stable=False)
        res = list(futs.values())[0].result(timeout=3)
        for tp in res.topic_partitions:
            if tp.topic == TOPIC_LOCAL and tp.partition == 0 and tp.offset >= 0:
                committed = tp.offset
    except Exception as e:
        out["group_error"] = str(e)[:120]
    out["peer_group_committed"] = committed
    out["outbound_pending"] = max(hi - (committed if committed is not None else lo), 0)
    return out


async def check_connect():
    async with httpx.AsyncClient(timeout=3) as cli:
        resp = await cli.get(f"{CONNECT_URL}/connectors/pg-source-{REGION}/status")
    if resp.status_code == 404:
        return {"ok": False, "state": "NO_REGISTRADO"}
    d = resp.json()
    tasks = [t.get("state") for t in d.get("tasks", [])]
    state = d.get("connector", {}).get("state")
    trace = next((t.get("trace", "")[:200] for t in d.get("tasks", []) if t.get("trace")), None)
    return {"ok": state == "RUNNING" and all(t == "RUNNING" for t in tasks), "state": state,
            "tasks": tasks, "error": trace}


async def repl_stats():
    h = await r.hgetall(STATS_KEY)
    out = {}
    for k, v in h.items():
        try:
            out[k] = int(v)
        except ValueError:
            try:
                out[k] = float(v)
            except ValueError:
                out[k] = v
    alive_at = out.get("alive_at")
    out["alive"] = bool(alive_at) and (time.time() - float(alive_at)) < 20
    out["ok"] = out["alive"]
    return out


def tcp_ok(hostport: str, timeout: float = 1.5) -> bool:
    host, _, port = hostport.rpartition(":")
    try:
        with socket.create_connection((host, int(port)), timeout=timeout):
            return True
    except OSError:
        return False


@app.get("/status")
async def status():
    results = await asyncio.gather(
        check_pg(), check_redis(), asyncio.to_thread(check_kafka), check_connect(), repl_stats(),
        asyncio.to_thread(tcp_ok, PEER_KAFKA), return_exceptions=True)

    def norm(x):
        return {"ok": False, "error": str(x)[:160]} if isinstance(x, BaseException) else x

    pg, rd, kf, cn, rp, peer = results
    return {"region": REGION, "region_name": REGION_NAME, "peer": PEER, "ts": now_iso(),
            "uptime_s": int(time.time() - START), "postgres": norm(pg), "redis": norm(rd),
            "kafka": norm(kf), "connect": norm(cn), "replicator": norm(rp),
            "peer_kafka_reachable": peer if isinstance(peer, bool) else False}


# ---------------------------------------------------------------- SSE
@app.get("/events")
async def events(request: Request):
    async def gen():
        pubsub = r.pubsub()
        await pubsub.subscribe(EVENTS_CH)
        yield f"event: hello\ndata: {json.dumps({'region': REGION, 'ts': now_iso()})}\n\n"
        try:
            while True:
                if await request.is_disconnected():
                    break
                msg = await pubsub.get_message(ignore_subscribe_messages=True, timeout=5.0)
                if msg is None:
                    yield ": ping\n\n"
                    continue
                yield f"data: {msg['data']}\n\n"
        finally:
            try:
                await pubsub.unsubscribe(EVENTS_CH)
                await pubsub.aclose()
            except Exception:
                pass

    return StreamingResponse(gen(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})
