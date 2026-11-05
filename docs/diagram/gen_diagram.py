#!/usr/bin/env python3
"""Genera docs/architecture.svg (SVG autocontenido, íconos oficiales Azure como <symbol>)."""
import re, pathlib, sys

ICONS = pathlib.Path.home() / "Microsoft/demoarc/assets/azure-icons/Azure_Public_Service_Icons/Icons"
OUT = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path("docs/architecture.svg")

ICON_FILES = {
    "browser": "general/10783-icon-service-Browser.svg",
    "swa": "web/01007-icon-service-Static-Apps.svg",
    "vm": "compute/10021-icon-service-Virtual-Machine.svg",
    "pg": "databases/10131-icon-service-Azure-Database-PostgreSQL-Server.svg",
    "vnet": "networking/10061-icon-service-Virtual-Networks.svg",
    "peer": "other/01285-icon-service-Peerings.svg",
    "pip": "networking/10069-icon-service-Public-IP-Addresses.svg",
    "nsg": "networking/10067-icon-service-Network-Security-Groups.svg",
    "redis": "databases/10137-icon-service-Cache-Redis.svg",
    "queue": "general/10840-icon-service-Storage-Queue.svg",
    "flow": "general/10852-icon-service-Workflow.svg",
    "code": "general/10787-icon-service-Code.svg",
    "cert": "web/00049-icon-service-App-Service-Certificates.svg",
    "api": "web/10048-icon-service-API-Connections.svg",
    "rg": "general/10007-icon-service-Resource-Groups.svg",
    "budget": "general/10793-icon-service-Cost-Budgets.svg",
    "policy": "management + governance/10316-icon-service-Policy.svg",
    "devtest": "devops/10264-icon-service-DevTest-Labs.svg",
    "bastion": "networking/02422-icon-service-Bastions.svg",
}


def load_icon(key, rel):
    s = (ICONS / rel).read_text(encoding="utf-8")
    s = re.sub(r"<\?xml[^>]*\?>", "", s)
    m = re.search(r"<svg[^>]*>", s)
    head = m.group(0)
    vb = re.search(r'viewBox="([^"]+)"', head)
    vb = vb.group(1) if vb else "0 0 18 18"
    inner = s[m.end(): s.rfind("</svg>")]
    inner = re.sub(r"<title>.*?</title>", "", inner, flags=re.S)
    ids = sorted(set(re.findall(r'id="([^"]+)"', inner)), key=len, reverse=True)
    for i in ids:
        inner = inner.replace(f'id="{i}"', f'id="{key}-{i}"')
        inner = inner.replace(f"url(#{i})", f"url(#{key}-{i})")
        inner = inner.replace(f'href="#{i}"', f'href="#{key}-{i}"')
    styles = re.findall(r"<style[^>]*>(.*?)</style>", inner, flags=re.S)
    if styles:
        classes = sorted(set(re.findall(r"\.([A-Za-z_][\w-]*)", " ".join(styles))), key=len, reverse=True)
        for c in classes:
            inner = re.sub(rf"\.{re.escape(c)}(?![\w-])", f".{key}-{c}", inner)
            inner = re.sub(rf'class="([^"]*)\b{re.escape(c)}\b([^"]*)"',
                           lambda mm: f'class="{mm.group(1)}{key}-{c}{mm.group(2)}"', inner)
    return f'<symbol id="ic-{key}" viewBox="{vb}">{inner}</symbol>'


symbols = "".join(load_icon(k, v) for k, v in ICON_FILES.items())

BG = "#0b1626"
ZONE, ZONE_S = "#0e2038", "#2c5f9e"
VNET, VNET_S = "#10233f", "#3a5a80"
BOX, BOX_S = "#122c4d", "#2c5f9e"
MINI, MINI_S = "#16233c", "#3a5a80"
TXT, TXT2 = "#e6edf7", "#9fb0c9"
BLUE, TEAL, PURPLE, GREEN, AMBER, RED = "#4da3ff", "#58d1c9", "#c084fc", "#4ade80", "#fbbf24", "#f87171"
FONT = "Segoe UI, Inter, Helvetica Neue, Arial, sans-serif"

parts = []
P = parts.append


def esc(t):
    return t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def text(x, y, t, size=10.5, fill=TXT2, weight="normal", anchor="start", italic=False):
    st = ' font-style="italic"' if italic else ""
    P(f'<text x="{x}" y="{y}" font-size="{size}" fill="{fill}" font-weight="{weight}" text-anchor="{anchor}"{st}>{esc(t)}</text>')


def chip(x, y, t, color, anchor="start", size=9):
    w = int(len(t) * size * 0.56 + 14)
    if anchor == "end":
        x = x - w
    P(f'<rect x="{x}" y="{y}" width="{w}" height="16" rx="8" fill="{color}" fill-opacity="0.16" stroke="{color}" stroke-opacity="0.55"/>')
    P(f'<text x="{x + w / 2}" y="{y + 11.5}" font-size="{size}" fill="{color}" text-anchor="middle">{esc(t)}</text>')
    return w


def box(x, y, w, h, icon, title, lines, fill=BOX, stroke=BOX_S, isz=28, tsize=12, lsize=10.5, title_fill=TXT):
    P(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="8" fill="{fill}" stroke="{stroke}" stroke-width="1.2"/>')
    P(f'<use href="#ic-{icon}" x="{x + 12}" y="{y + 7}" width="{isz}" height="{isz}"/>')
    text(x + 12 + isz + 9, y + 7 + isz / 2 + 4, title, tsize, title_fill, "600")
    ly = y + 7 + isz + 12
    for ln in lines:
        text(x + 12, ly, ln, lsize)
        ly += lsize + 3


def mini(x, y, w, h, icon, title, lines, stroke=MINI_S, isz=20, lsize=8.6):
    P(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="6" fill="{MINI}" stroke="{stroke}" stroke-width="1.1"/>')
    P(f'<use href="#ic-{icon}" x="{x + 8}" y="{y + 7}" width="{isz}" height="{isz}"/>')
    text(x + 8 + isz + 6, y + 17, title, 10.5, TXT, "600")
    ly = y + 31
    for ln in lines:
        text(x + 8, ly, ln, lsize)
        ly += lsize + 2.4


def arrow(points, color, dashed=False, width=1.6, head=True):
    pts = " ".join(f"{a},{b}" for a, b in points)
    d = ' stroke-dasharray="5,4"' if dashed else ""
    mk = f' marker-end="url(#arr-{color[1:]})"' if head else ""
    P(f'<polyline points="{pts}" fill="none" stroke="{color}" stroke-width="{width}"{d}{mk}/>')


def label(x, y, lines, color, anchor="start", size=8.6, weight="normal"):
    for i, ln in enumerate(lines):
        text(x, y + i * (size + 2), ln, size, color, weight, anchor)


def step(x, y, n, color=BLUE):
    P(f'<circle cx="{x}" cy="{y}" r="8" fill="{color}" />')
    P(f'<text x="{x}" y="{y + 3.5}" font-size="10" font-weight="700" fill="#0b1626" text-anchor="middle">{n}</text>')


markers = "".join(
    f'<marker id="arr-{c[1:]}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="{c}"/></marker>'
    for c in [BLUE, TEAL, PURPLE, GREEN, AMBER, TXT2, RED]
)

W = 1000

# ---------- título ----------
text(20, 30, "Demo de resiliencia Activo-Activo en Azure", 19, TXT, "700")
text(20, 48, "SPA cacheada en el navegador · 2 regiones · API + Kafka + Redis en VM · PostgreSQL Flexible con CDC (Debezium) · replicación bidireccional por Kafka",
     10.5, TXT2)
chip(980, 16, "desplegada · 20-oct-2026 · Central US + Canada Central", GREEN, anchor="end")

# ---------- banda global ----------
P(f'<rect x="10" y="62" width="980" height="134" rx="10" fill="{ZONE}" stroke="{ZONE_S}" stroke-dasharray="6,4"/>')
text(24, 80, "CAPA GLOBAL (no depende de la región A ni B)", 11, BLUE, "700")

box(30, 90, 262, 98, "browser", "Navegador · SPA / PWA cacheada", [
    "Service Worker: app-shell en caché (versionada)",
    "Failover A⇄B: health 3 s · timeout 2 s · reintento",
    "Idempotency-Key (uuid) · modo 'fijar región'",
    "Panel: estado A/B, lag CDC, cola Kafka, conflictos",
], stroke=BLUE, lsize=9.6)

box(372, 90, 262, 98, "swa", "Azure Static Web Apps (Free)", [
    "Hosting global del SPA · HTTPS · CDN",
    "config.json con URLs de API A y B",
    "Si SWA cae, el SPA sigue desde la caché del SW",
    "Costo: $0 (plan Free)",
], stroke=BLUE, lsize=9.6)
chip(622, 98, "$0", GREEN, anchor="end")
arrow([(292, 126), (372, 126)], BLUE)
step(332, 116, 1)

text(662, 102, "FLUJO", 10.5, TXT, "700")
flow = [
    (1, "Carga del SPA desde SWA; el Service Worker lo cachea."),
    (2, "El SPA llama a la API de la región activa (HTTPS 443)."),
    (3, "Si A no responde, reintenta en B: 0 interrupción percibida."),
    (4, "API escribe en Postgres local (origin_region, updated_at, uuid)."),
    (5, "Debezium captura el cambio (slot lógico) → topic Kafka local."),
    (6, "Replicator remoto consume por peering: filtra eco, upsert LWW."),
    (7, "Región caída → su cola Kafka (offsets) espera hasta que vuelva."),
]
fy = 116
for n, t in flow:
    step(668, fy - 3, n, BLUE if n < 7 else AMBER)
    text(682, fy, t, 9.4, TXT2)
    fy += 12.6

# ---------- regiones ----------
REG = {
    "A": dict(x=10, name="REGIÓN A · Central US", rg="rg-aa-a", cidr="10.10.0.0/16", pref="preferida por el SPA"),
    "B": dict(x=535, name="REGIÓN B · Canada Central", rg="rg-aa-b", cidr="10.20.0.0/16", pref="failover / activa"),
}
RY, RH, RW = 222, 566, 455
MH = 56


def region(key):
    r = REG[key]
    x0 = r["x"]
    P(f'<rect x="{x0}" y="{RY}" width="{RW}" height="{RH}" rx="10" fill="{ZONE}" stroke="{ZONE_S}"/>')
    text(x0 + 58, RY + 20, r["name"], 12, TXT, "700")
    chip(x0 + RW - 24, RY + 8, r["pref"], GREEN if key == "A" else AMBER, anchor="end")
    text(x0 + 58, RY + 34, f'{r["rg"]} · tags project/owner/env · destroy.sh lo borra completo', 9, TXT2)
    mini(x0 + 58, RY + 42, 172, 44, "pip", "IP pública estática", [
        "Standard · DNS label *.cloudapp.azure.com",
        "sobrevive a desasignar la VM",
    ], stroke=BLUE, isz=18, lsize=8.2)
    mini(x0 + 238, RY + 42, 190, 44, "nsg", "NSG (sin 22/3389)", [
        "443/80 desde Internet · 9092 solo VNet par",
        "la policy MCAPS no tiene nada que cortar",
    ], stroke=BLUE, isz=18, lsize=8.2)
    vx, vy, vw, vh = x0 + 12, RY + 96, RW - 24, RH - 108
    P(f'<rect x="{vx}" y="{vy}" width="{vw}" height="{vh}" rx="8" fill="{VNET}" stroke="{VNET_S}" stroke-dasharray="5,4"/>')
    P(f'<use href="#ic-vnet" x="{vx + 8}" y="{vy + 5}" width="18" height="18"/>')
    text(vx + 30, vy + 17, f'VNet {r["cidr"]} · snet-vm · snet-pg (delegada a Flexible Server)', 9.5, TXT2)
    bx, by, bw, bh = vx + 12, vy + 28, vw - 24, 270
    P(f'<rect x="{bx}" y="{by}" width="{bw}" height="{bh}" rx="8" fill="{BOX}" stroke="{BOX_S}" stroke-width="1.2"/>')
    P(f'<use href="#ic-vm" x="{bx + 10}" y="{by + 6}" width="26" height="26"/>')
    text(bx + 44, by + 17, "VM Standard_B2ps_v2 (Arm64) · Ubuntu 24.04", 11, TXT, "600")
    text(bx + 44, by + 30, "2 vCPU / 8 GiB · Docker Compose · cloud-init idempotente", 8.8, TXT2)
    chip(bx + bw - 8, by + 6, "auto-shutdown 20:00", AMBER, anchor="end")
    chip(bx + bw - 8, by + 24, "≈ $20–39/mes", TEAL, anchor="end")
    r1, r2, r3 = by + 44, by + 112, by + 180
    if key == "A":
        lc, rc = bx + 12, bx + 212        # app a la izquierda, datos a la derecha
    else:
        lc, rc = bx + 212, bx + 12        # datos a la izquierda (junto al carril), app a la derecha
    # columna app
    mini(lc, r1, 188, MH, "cert", "Caddy · TLS automático", [
        "443→API · Let's Encrypt / ZeroSSL",
        "cert: DNS label o dominio propio",
    ], stroke=TEAL)
    mini(lc, r2, 188, MH, "api", "API FastAPI (Python)", [
        "/tickets (idempotente) · /health",
        "/status · /events SSE · CORS",
    ], stroke=TEAL)
    redis_x = lc if key == "A" else lc + 70
    mini(redis_x, r3, 118, MH, "redis", "Redis OSS", [
        "cache-aside TTL 30 s",
        "pub/sub → SSE",
    ], stroke=TEAL)
    other = "b" if key == "A" else "a"
    me = key.lower()
    if key == "A":
        # fila1 Replicator (ancho), fila2 Kafka (estrecho, pegado al carril), fila3 Connect
        mini(rc, r1, 188, MH, "flow", "Replicator (Python)", [
            f"consume cdc.{other}.* del Kafka remoto",
            "filtra eco · upsert LWW · commit",
        ], stroke=AMBER)
        kx, cx = rc + 70, rc + 70
        mini(kx, r2, 118, MH, "queue", "Kafka (KRaft)", [
            f"topic cdc.{me}.tickets",
            "7 d · :9092 privado",
        ], stroke=AMBER)
        mini(cx, r3, 118, MH, "flow", "Connect+Debezium", [
            f"slot dbz_{me} · pgoutput",
            "heartbeat (evita WAL)",
        ], stroke=AMBER, lsize=8.3)
        rep_line_x, rep_from = rc + 36, r1 + MH
        kafka_edge = (kx + 118, r2 + MH / 2)
        rep_edge = (rc + 188, r1 + MH / 2)
        cdc_x, prod_x = rc + 100, rc + 150
        api_line_x = lc + 150
    else:
        # fila1 Kafka (ancho, pegado al carril), fila2 Replicator (estrecho izq), fila3 Connect (estrecho der)
        mini(rc, r1, 188, MH, "queue", "Apache Kafka (KRaft)", [
            f"topic cdc.{me}.tickets · retención 7 d",
            "listener :9092 en IP privada",
        ], stroke=AMBER)
        mini(rc, r2, 118, MH, "flow", "Replicator", [
            f"consume cdc.{other}.*",
            "eco · LWW · commit",
        ], stroke=AMBER)
        cx = rc + 70
        mini(cx, r3, 118, MH, "flow", "Connect+Debezium", [
            f"slot dbz_{me} · pgoutput",
            "heartbeat (evita WAL)",
        ], stroke=AMBER, lsize=8.3)
        rep_line_x, rep_from = rc + 36, r2 + MH
        kafka_edge = (rc, r1 + MH / 2)
        rep_edge = (rc, r2 + MH / 2)
        cdc_x, prod_x = rc + 100, rc + 150
        api_line_x = lc + 36
    px, py, pw, ph = bx, by + bh + 26, bw, 100
    box(px, py, pw, ph, "pg", "PostgreSQL Flexible Server · B1ms", [
        "Burstable 1 vCPU / 2 GiB · 32 GiB · PG 16 · backup 7 d · sin HA (demo)",
        "wal_level=logical · publication + slot · heartbeat Debezium · rol REPLICATION",
        "Acceso privado (snet-pg + Private DNS zone) · sslmode=require",
        "tickets(id uuid, folio, titulo, estado, origin_region, updated_at, version, deleted_at)",
    ], stroke=PURPLE, lsize=9.2)
    chip(px + pw - 8, py + 6, "≈ $16/mes", TEAL, anchor="end")
    # API -> Postgres
    arrow([(api_line_x, r2 + MH), (api_line_x, py)], PURPLE)
    step(api_line_x, r2 + MH + 16, 4, PURPLE)
    if key == "A":
        label(api_line_x + 6, r3 + MH + 14, ["lee/escribe local", "origin_region, updated_at"], PURPLE)
    else:
        label(api_line_x - 6, r3 + MH + 14, ["lee/escribe local", "origin, updated_at"], PURPLE, anchor="end")
    # Replicator -> Postgres
    arrow([(rep_line_x, rep_from), (rep_line_x, py)], AMBER)
    step(rep_line_x, rep_from + 16, 6, AMBER)
    if key == "A":
        label(rep_line_x - 6, r3 + MH + 40, ["aplica remoto (LWW)", "invalida Redis"], AMBER, anchor="end")
    else:
        label(rep_line_x + 6, r3 + MH + 14, ["aplica remoto (LWW)", "invalida Redis"], AMBER)
    # Postgres -> Connect (CDC) y Connect -> Kafka
    arrow([(cdc_x, py), (cdc_x, r3 + MH)], GREEN)
    step(cdc_x, py - 14, 5, GREEN)
    label(cdc_x + 12, py - 12, ["CDC (slot lógico)"], GREEN)
    if key == "A":
        arrow([(prod_x, r3), (prod_x, r2 + MH)], GREEN, width=1.4)
    else:
        arrow([(prod_x, r3), (prod_x, r1 + MH)], GREEN, width=1.4)
    # Caddy -> API
    arrow([(lc + 94, r1 + MH), (lc + 94, r2)], TEAL, width=1.4)
    return dict(lc=lc, rc=rc, r1=r1, r2=r2, r3=r3, kafka_edge=kafka_edge, rep_edge=rep_edge, py=py)


ga = region("A")
gb = region("B")

# ---------- cross-region: dos flechas horizontales paralelas en el carril ----------
# Kafka B (fila 1, borde izq) -> Replicator A (fila 1, borde der)
arrow([gb["kafka_edge"], ga["rep_edge"]], AMBER, width=1.8)
yk1 = gb["kafka_edge"][1]
label(502, yk1 - 9, ["cdc.b.* · pull desde A"], AMBER, anchor="middle", size=8.6, weight="700")
# Kafka A (fila 2, borde der) -> Replicator B (fila 2, borde izq)
arrow([ga["kafka_edge"], gb["rep_edge"]], AMBER, width=1.8)
yk2 = ga["kafka_edge"][1]
label(502, yk2 - 9, ["cdc.a.* · pull desde B"], AMBER, anchor="middle", size=8.6, weight="700")
# peering
pyb = ga["r3"] + 4
P(f'<rect x="468" y="{pyb}" width="64" height="100" rx="8" fill="{VNET}" stroke="{AMBER}" stroke-dasharray="4,3"/>')
P(f'<use href="#ic-peer" x="482" y="{pyb + 6}" width="36" height="36"/>')
text(500, pyb + 56, "Peering", 9.5, TXT, "700", "middle")
text(500, pyb + 68, "global VNet", 9, TXT2, anchor="middle")
text(500, pyb + 80, "privado · ~30 ms", 8.5, TXT2, anchor="middle")
text(500, pyb + 92, "pull: la cola espera", 8.5, AMBER, anchor="middle")
step(500, pyb + 120, 7, AMBER)
label(500, pyb + 142, ["Si A cae: Kafka B", "retiene cdc.b.* y el", "grupo replicator-a", "reanuda al volver"], TXT2, anchor="middle", size=8.4)

# ---------- navegador -> Caddy A (activa) y Caddy B (failover) ----------
cy_a = ga["r1"] + MH / 2
arrow([(60, 188), (60, 210), (40, 210), (40, cy_a), (ga["lc"], cy_a)], BLUE, width=1.8)
label(66, 207, ["activa (preferida)"], BLUE, size=8.6, weight="700")
step(40, 246, 2)
cy_b = gb["r1"] + MH / 2
arrow([(262, 188), (262, 210), (975, 210), (975, cy_b), (gb["lc"] + 188, cy_b)], BLUE, dashed=True, width=1.8)
label(480, 207, ["failover: si A no responde, el navegador reintenta en B (línea punteada)"], BLUE, anchor="middle", size=8.6, weight="700")
step(975, 246, 3)

# ---------- operación / gobierno ----------
OY = RY + RH + 16
P(f'<rect x="10" y="{OY}" width="980" height="118" rx="10" fill="{ZONE}" stroke="{ZONE_S}" stroke-dasharray="6,4"/>')
text(24, OY + 18, "OPERACIÓN, GOBIERNO Y COSTO (rg-aa-global + scripts del repo)", 11, BLUE, "700")
oy = OY + 28
ops = [
    ("policy", "Preflight políticas MCAPS", ["policy assignments con Deny", "locations · SKUs · cuota vCPU · IP", "what-if del Bicep antes de crear"], BLUE),
    ("devtest", "Auto-shutdown 20:00", ["DevTestLab/schedules por VM", "TZ: Central Standard Time (Mexico)", "start.sh de mañana (o Automation)"], AMBER),
    ("budget", "Costo estimado", ["≈ $90/mes con apagado nocturno", "≈ $128/mes 24x7 · sin alertas", "+ Defender del sub (ver docs/costos)"], GREEN),
    ("bastion", "Operación sin SSH", ["az vm run-command (canal agente)", "Bastion Developer opcional ($0)", "status.sh · docker compose logs"], TEAL),
    ("code", "Repo + IA", ["Bicep + az CLI + compose local", "scripts: deploy · chaos · verify", "PROMPT.md: Copilot / Claude / Codex"], PURPLE),
]
ox = 14
for icon, title, lines, col in ops:
    box(ox, oy, 188, 80, icon, title, lines, stroke=col, isz=24, tsize=10.5, lsize=8.8)
    ox += 196

# ---------- leyenda ----------
LY = OY + 134
legend = [
    (BLUE, False, "tráfico de la app (HTTPS)"),
    (BLUE, True, "failover del navegador"),
    (PURPLE, False, "lecturas/escrituras locales"),
    (GREEN, False, "CDC Debezium → Kafka"),
    (AMBER, False, "replicación cross-region (pull)"),
]
lx = 24
for col, dash, lab in legend:
    d = ' stroke-dasharray="5,4"' if dash else ""
    P(f'<line x1="{lx}" y1="{LY}" x2="{lx + 28}" y2="{LY}" stroke="{col}" stroke-width="2"{d}/>')
    text(lx + 34, LY + 3.5, lab, 9, TXT2)
    lx += 34 + len(lab) * 5.2 + 22
text(24, LY + 20, "Precios PAYG aproximados (oct-2026, Central US / Canada Central), sin los planes Defender de la suscripción: validar en la calculadora de precios de Azure.", 8.5, TXT2, italic=True)
H = LY + 32

svg = f'''<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" aria-label="Arquitectura de la demo Activo-Activo en Azure: SPA cacheada, dos regiones con VM (Caddy, API, Redis, Kafka, Debezium, Replicator) y PostgreSQL Flexible Server, replicación bidireccional por Kafka sobre peering global, operación con auto-shutdown y preflight de políticas" font-family="{FONT}">
<defs>{symbols}{markers}</defs>
<rect width="{W}" height="{H}" fill="{BG}"/>
{"".join(parts)}
</svg>
'''
OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text(svg, encoding="utf-8")
print(f"OK {OUT} ({len(svg)//1024} KiB, {len(ICON_FILES)} íconos, alto {H})")
