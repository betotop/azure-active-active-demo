// Visor de datos de UNA región: lee la tabla directamente del API de esa región (sin failover) y la refresca en vivo
// (SSE + sondeo cada 2 s). Ábrelo en dos ventanas, ?region=a y ?region=b, para ver cómo cada escritura cae en una
// base y aparece en la otra por la replicación (Debezium → Kafka → Replicator).
const $ = (s) => document.querySelector(s);
const fmtTime = (t) => new Date(t).toLocaleTimeString('es-MX', { hour12: false });
const errName = (e) => (e && e.name === 'AbortError' ? 'timeout' : (e && e.message) || String(e));
const key = (new URLSearchParams(location.search).get('region') || 'a').toLowerCase();
const state = { reg: null, other: null, rows: [], seen: new Map(), es: null, refreshing: false };

async function fetchT(url, ms = 2500) {
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), ms);
  try { return await fetch(url, { cache: 'no-store', signal: ctl.signal }); } finally { clearTimeout(t); }
}

function log(kind, msg) {
  const ul = $('#log');
  const li = document.createElement('li');
  li.innerHTML = `<span class="t">${fmtTime(Date.now())}</span><span class="k-${kind}"></span>`;
  li.lastChild.textContent = msg;
  ul.prepend(li);
  while (ul.children.length > 60) ul.lastChild.remove();
}

function setStatus(ok, detail) {
  const b = $('#estado');
  b.className = 'badge ' + (ok ? 'ok' : 'down');
  b.textContent = (ok ? 'Responde · ' : 'SIN RESPUESTA · ') + detail;
  document.body.classList.toggle('down', !ok);
}

function render() {
  const tb = $('#filas');
  tb.innerHTML = '';
  const seen = new Map();
  const first = state.seen.size === 0;
  for (const t of state.rows) {
    const prev = state.seen.get(t.id);
    const origin = String(t.origin_region || '').toLowerCase();
    const tr = document.createElement('tr');
    tr.className = !first && prev === undefined ? 'new' : prev !== undefined && prev !== t.version ? 'changed' : '';
    tr.innerHTML = `<td class="t">${fmtTime(t.updated_at)}</td><td class="txt"></td>
      <td><span class="chip ${origin}">${origin === key ? 'escrito aquí (' + origin.toUpperCase() + ')' : 'replicado desde ' + origin.toUpperCase()}</span></td>
      <td class="mono">${t.folio}</td><td class="mono">v${t.version}</td>`;
    tr.querySelector('.txt').textContent = t.titulo;
    tb.appendChild(tr);
    seen.set(t.id, t.version);
  }
  state.seen = seen;
  $('#count').textContent = state.rows.length;
  $('#empty').classList.toggle('hidden', state.rows.length > 0);
}

async function refresh() {
  if (state.refreshing) return;
  state.refreshing = true;
  try {
    const r = await fetchT(state.reg.url + '/tickets');
    if (!r.ok) throw new Error('HTTP ' + r.status);
    const d = await r.json();
    state.rows = d.items || [];
    render();
    setStatus(true, `${state.rows.length} registros · leído ${fmtTime(Date.now())} · caché Redis: ${r.headers.get('X-Cache') || '?'}`);
  } catch (e) {
    setStatus(false, errName(e) + ' · se muestra la última lectura');
  } finally {
    state.refreshing = false;
  }
}

function connectSSE() {
  const es = new EventSource(state.reg.url + '/events');
  state.es = es;
  es.onopen = () => log('info', 'eventos en vivo conectados (SSE)');
  es.onerror = () => log('error', 'eventos en vivo desconectados; reintentando…');
  es.onmessage = (ev) => {
    let d;
    try { d = JSON.parse(ev.data); } catch { return; }
    const t = d.ticket || {};
    if (d.type === 'replicated') log('replicated', `replicado ${t.folio || ''} desde ${String(d.from || '').toUpperCase()} (${d.result}, op ${d.op})`);
    else if (d.type === 'upsert') log('write', `escrito aquí ${t.folio || ''} (v${t.version})`);
    else if (d.type === 'delete') log('write', `eliminado aquí ${t.folio || ''}`);
    setTimeout(refresh, 150);
  };
}

async function init() {
  let cfg;
  try {
    const r = await fetch('./config.json', { cache: 'no-store' });
    if (!r.ok) throw new Error('HTTP ' + r.status);
    cfg = await r.json();
  } catch (e) {
    setStatus(false, 'config.json no disponible (' + errName(e) + ')');
    return;
  }
  state.reg = cfg.regions.find((r) => r.key === key);
  if (!state.reg) { setStatus(false, `la región "${key}" no existe en config.json (usa ?region=a o ?region=b)`); return; }
  state.other = cfg.regions.find((r) => r.key !== key);
  document.body.classList.add('region-' + key);
  document.title = 'Visor · ' + state.reg.name;
  $('#titulo').textContent = 'Visor de datos · ' + state.reg.name;
  $('#nombre').textContent = state.reg.name;
  if (state.other) { const a = $('#otro'); a.href = './visor.html?region=' + state.other.key; a.textContent = 'Abrir visor de ' + state.other.name + ' ↗'; }
  $('#cfg-meta').textContent = 'API: ' + state.reg.url + '  ·  tabla public.tickets, lectura directa sin failover';
  $('#clear-log').onclick = () => { $('#log').innerHTML = ''; };
  await refresh();
  connectSSE();
  setInterval(refresh, 2000);
}

init();
