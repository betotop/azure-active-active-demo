// SPA "Registros": failover en el cliente entre dos regiones, región de escritura a elegir, SSE, panel de resiliencia.
// Sin bundler ni dependencias: lo que ves es lo que corre. El Service Worker (sw.js) cachea el app-shell.
const $ = (s) => document.querySelector(s);
const PENDING_KEY = 'aa-pending-writes';

const state = {
  cfg: null, regions: [], preferred: 'a', mode: 'auto', active: null,
  health: {}, status: {}, tickets: [], knownIds: new Set(),
  es: null, esRegion: null, refreshTimer: null, reloading: false,
};

// ------------------------------------------------------------------ utilidades
const fmtTime = (t) => new Date(t).toLocaleTimeString('es-MX', { hour12: false });
const fmtBytes = (b) => (b == null ? '—' : b < 1024 ? b + ' B' : b < 1048576 ? (b / 1024).toFixed(1) + ' KiB' : (b / 1048576).toFixed(1) + ' MiB');
const fmtErr = (x) => (x && x.error ? 'ERROR: ' + String(x.error).slice(0, 60) : (x && x.ok === false ? 'no disponible' : '…'));
const regionByKey = (k) => state.regions.find((r) => r.key === k);
const nameOf = (k) => (regionByKey(k) || { name: String(k).toUpperCase() }).name;
const others = (k) => state.regions.filter((r) => r.key !== k).map((r) => r.key);

function log(kind, msg) {
  const ul = $('#log');
  const li = document.createElement('li');
  li.innerHTML = `<span class="t">${fmtTime(Date.now())}</span><span class="k-${kind}"></span>`;
  li.lastChild.textContent = msg;
  ul.prepend(li);
  while (ul.children.length > 80) ul.lastChild.remove();
}

async function fetchT(url, opts = {}, ms = 2500) {
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), ms);
  try {
    return await fetch(url, { cache: 'no-store', ...opts, signal: ctl.signal });
  } finally {
    clearTimeout(t);
  }
}
const errName = (e) => (e && e.name === 'AbortError' ? 'timeout' : (e && e.message) || String(e));

// ------------------------------------------------------------------ sondeo de salud y elección de región
async function probe(reg) {
  const h = state.health[reg.key];
  const t0 = performance.now();
  let ok = false, err = null;
  try {
    const r = await fetchT(reg.url + '/health', {}, state.cfg.probe_timeout_ms);
    ok = r.ok;
    if (!ok) err = 'HTTP ' + r.status;
  } catch (e) {
    err = errName(e);
  }
  const was = h.ok;
  h.latency = Math.round(performance.now() - t0);
  h.ok = ok;
  h.err = err;
  h.consecutiveOk = ok ? h.consecutiveOk + 1 : 0;
  if (was !== undefined && was !== ok) log(ok ? 'failback' : 'error', `${reg.name}: ${ok ? 'responde de nuevo' : 'sin respuesta (' + err + ')'}`);
}

async function probeAll() {
  await Promise.all(state.regions.map(probe));
  chooseActive();
  renderBadge();
  renderPanel();
}

function chooseActive() {
  if (state.mode !== 'auto') {
    if (state.active !== state.mode) switchTo(state.mode, 'fijada');
    return;
  }
  const cur = state.active, pref = state.preferred;
  if (cur && state.health[cur] && state.health[cur].ok) {
    if (cur !== pref && state.health[pref] && state.health[pref].consecutiveOk >= state.cfg.failback_healthy_probes) switchTo(pref, 'failback');
    return;
  }
  const candidates = [pref, ...others(pref)].filter((k) => state.health[k] && state.health[k].ok);
  if (candidates.length) switchTo(candidates[0], cur ? 'failover' : 'inicio');
  else if (cur) {
    state.active = null;
    log('error', 'ninguna región responde: modo sin conexión (datos en caché, escrituras en cola)');
    renderBadge();
  }
}

function switchTo(key, why) {
  const from = state.active;
  state.active = key;
  const kind = why === 'failover' ? 'failover' : why === 'failback' ? 'failback' : 'info';
  log(kind, `${why}: ${from ? nameOf(from) + ' → ' : ''}${nameOf(key)}`);
  connectSSE();
  refreshTickets();
  flushPending();
  renderBadge();
}

// ------------------------------------------------------------------ llamadas a la API con reintento en la otra región
async function api(path, opts = {}) {
  const order = state.mode !== 'auto' ? [state.mode] : [state.active, ...others(state.active)].filter(Boolean);
  if (!order.length) throw new Error('sin región disponible');
  let lastErr;
  for (const key of order) {
    const reg = regionByKey(key);
    try {
      const r = await fetchT(reg.url + path, { ...opts, headers: { 'Content-Type': 'application/json', ...(opts.headers || {}) } }, state.cfg.request_timeout_ms);
      if (r.status >= 500) throw new Error('HTTP ' + r.status);
      if (state.mode === 'auto' && key !== state.active) {
        if (state.active) { state.health[state.active].ok = false; state.health[state.active].consecutiveOk = 0; }
        switchTo(key, 'failover');
      }
      return r;
    } catch (e) {
      lastErr = e;
      log('error', `${reg.name}: ${opts.method || 'GET'} ${path} falló (${errName(e)})`);
      if (state.mode === 'auto') { state.health[key].ok = false; state.health[key].consecutiveOk = 0; }
    }
  }
  throw lastErr;
}

// ------------------------------------------------------------------ tickets
async function refreshTickets() {
  try {
    const r = await api('/tickets');
    const d = await r.json();
    state.tickets = d.items || [];
    renderTickets(`${state.tickets.length} registros · leídos de ${nameOf(r.headers.get('X-Region') || d.region)} · caché Redis: ${r.headers.get('X-Cache') || '?'}`);
  } catch (e) {
    renderTickets('sin conexión: mostrando la última lista conocida');
  }
}

function scheduleRefresh() {
  clearTimeout(state.refreshTimer);
  state.refreshTimer = setTimeout(refreshTickets, 250);
}

function renderTickets(meta) {
  $('#list-meta').textContent = meta;
  const ul = $('#tickets');
  ul.innerHTML = '';
  for (const t of state.tickets) {
    const li = document.createElement('li');
    li.className = 'ticket' + (state.knownIds.size && !state.knownIds.has(t.id) ? ' new' : '');
    const origin = String(t.origin_region || '').toLowerCase();
    li.innerHTML = `
      <div class="title"></div>
      <div class="actions">
        <button class="small ghost" data-act="edit" title="Cambiar el texto (se escribe en la región elegida)">editar</button>
        <button class="small danger" data-act="del" title="Eliminar (borrado lógico)">×</button>
      </div>
      <div class="meta">
        <span class="chip ${origin}">escrito en ${origin.toUpperCase()}</span>
        <span>${t.folio}</span><span>v${t.version}</span><span>${fmtTime(t.updated_at)}</span>
      </div>`;
    li.querySelector('.title').textContent = t.titulo;
    li.querySelector('[data-act=edit]').onclick = () => editTicket(t);
    li.querySelector('[data-act=del]').onclick = () => deleteTicket(t.id, t.folio);
    ul.appendChild(li);
  }
  state.knownIds = new Set(state.tickets.map((t) => t.id));
}

// Región de escritura elegida en el formulario: 'auto' = la región activa con failover (api()); 'a' | 'b' = directo
// a esa región, sin reintento en la otra (si no responde, la escritura falla y se avisa).
const writeTarget = () => $('#destino').value;
async function write(path, opts = {}, target = writeTarget()) {
  if (target === 'auto') return api(path, opts);
  const reg = regionByKey(target);
  const r = await fetchT(reg.url + path, { ...opts, headers: { 'Content-Type': 'application/json', ...(opts.headers || {}) } }, state.cfg.request_timeout_ms);
  if (r.status >= 500) throw new Error('HTTP ' + r.status);
  return r;
}

async function createTicket(texto, target) {
  const id = crypto.randomUUID();                 // id del cliente: reintentar nunca duplica
  const body = JSON.stringify({ titulo: texto });
  try {
    const r = await write(`/tickets/${id}`, { method: 'PUT', body, headers: { 'Idempotency-Key': id } }, target);
    const t = await r.json();
    log('write', `guardado ${t.folio} en ${nameOf(r.headers.get('X-Region'))}`);
    scheduleRefresh();
  } catch (e) {
    if (target === 'auto') queuePending({ id, body, titulo: texto });
    else { log('error', `${nameOf(target)} no respondió (${errName(e)}): el registro NO se guardó; elige otra región`); $('#texto').value = texto; }
  }
}

function editTicket(t) {
  const v = prompt(`Nuevo texto para ${t.folio}:`, t.titulo);
  if (v == null) return;
  const texto = v.trim();
  if (texto && texto !== t.titulo) patchTicket(t.id, { titulo: texto });
}

async function patchTicket(id, campos) {
  try {
    const r = await write(`/tickets/${id}`, { method: 'PATCH', body: JSON.stringify(campos) });
    const t = await r.json();
    log('write', `editado ${t.folio} → "${Object.values(campos).join(', ')}" en ${nameOf(r.headers.get('X-Region'))}`);
    scheduleRefresh();
  } catch (e) {
    log('error', 'no se pudo editar: ' + errName(e));
  }
}

async function deleteTicket(id, folio) {
  try {
    const r = await write(`/tickets/${id}`, { method: 'DELETE' });
    log('write', `eliminado ${folio} en ${nameOf(r.headers.get('X-Region'))}`);
    scheduleRefresh();
  } catch (e) {
    log('error', 'no se pudo eliminar: ' + errName(e));
  }
}

// ------------------------------------------------------------------ cola offline (escrituras pendientes)
const loadPending = () => { try { return JSON.parse(localStorage.getItem(PENDING_KEY) || '[]'); } catch { return []; } };
const savePending = (arr) => { try { localStorage.setItem(PENDING_KEY, JSON.stringify(arr)); } catch {} renderPending(); };
function queuePending(w) {
  const arr = loadPending();
  arr.push(w);
  savePending(arr);
  log('error', `sin región disponible: "${w.titulo}" queda en cola local (${arr.length})`);
}
async function flushPending() {
  let arr = loadPending();
  if (!arr.length || !state.active) return;
  for (const w of [...arr]) {
    try {
      const r = await api(`/tickets/${w.id}`, { method: 'PUT', body: w.body, headers: { 'Idempotency-Key': w.id } });
      const t = await r.json();
      arr = arr.filter((x) => x.id !== w.id);
      savePending(arr);
      log('write', `cola local → creada ${t.folio} en ${nameOf(r.headers.get('X-Region'))}`);
    } catch (e) {
      break;
    }
  }
  scheduleRefresh();
}
function renderPending() {
  const n = loadPending().length;
  const p = $('#pending-info');
  p.classList.toggle('hidden', n === 0);
  p.textContent = n ? `${n} escritura(s) en cola local: se enviarán cuando una región responda.` : '';
}

// ------------------------------------------------------------------ SSE (tiempo real desde la región activa)
function connectSSE() {
  const key = state.active;
  if (!key) return;
  if (state.es && state.esRegion === key) return;
  if (state.es) { state.es.close(); state.es = null; }
  const reg = regionByKey(key);
  const es = new EventSource(reg.url + '/events');
  state.es = es;
  state.esRegion = key;
  es.onmessage = (ev) => { try { onEvent(JSON.parse(ev.data), reg); } catch {} };
}
function onEvent(d, reg) {
  const t = d.ticket || {};
  if (d.type === 'replicated') log('replicated', `${reg.name}: replicado ${t.folio || ''} desde ${String(d.from || '').toUpperCase()} (${d.result}, op ${d.op})`);
  else if (d.type === 'upsert') log('write', `${reg.name}: escrito ${t.folio || ''} (v${t.version})`);
  else if (d.type === 'delete') log('write', `${reg.name}: eliminado ${t.folio || ''}`);
  scheduleRefresh();
}

// ------------------------------------------------------------------ panel de resiliencia
async function pollStatus() {
  await Promise.all(state.regions.map(async (reg) => {
    try {
      const r = await fetchT(reg.url + '/status', {}, 3500);
      state.status[reg.key] = { ok: r.ok, data: await r.json(), at: Date.now() };
    } catch (e) {
      const prev = state.status[reg.key] || {};
      state.status[reg.key] = { ok: false, err: errName(e), at: Date.now(), data: prev.data };
    }
  }));
  renderPanel();
  $('#panel-meta').textContent = 'actualizado ' + fmtTime(Date.now());
}

function renderPanel() {
  for (const reg of state.regions) {
    const el = document.getElementById('region-' + reg.key);
    if (!el) continue;
    const h = state.health[reg.key] || {};
    const st = state.status[reg.key] || {};
    const d = st.data || {};
    const pg = d.postgres || {}, kf = d.kafka || {}, cn = d.connect || {}, rp = d.replicator || {}, rd = d.redis || {};
    const slot = (pg.slots || [])[0];
    const peer = others(reg.key)[0] || '?';
    el.className = 'region' + (state.active === reg.key ? ' active' : '') + (h.ok === false ? ' down' : '');
    const dot = h.ok ? 'ok' : h.ok === false ? 'down' : '';
    el.innerHTML = `
      <h3><span><span class="dot ${dot}"></span>${reg.name}</span>${state.active === reg.key ? '<span class="chip a">activa</span>' : ''}</h3>
      <dl class="kv">
        <dt>Salud</dt><dd>${h.ok ? 'OK · ' + h.latency + ' ms' : h.ok === false ? 'SIN RESPUESTA (' + (h.err || '') + ')' : '…'}</dd>
        <dt>Postgres</dt><dd>${pg.ok ? `OK · ${pg.tickets} registros · ${pg.latency_ms} ms` : fmtErr(pg)}</dd>
        <dt>Slot CDC</dt><dd>${slot ? `${slot.slot_name} ${slot.active ? 'activo' : 'INACTIVO'} · WAL retenido ${fmtBytes(slot.retained_bytes)}` : '—'}</dd>
        <dt>Redis</dt><dd>${rd.ok ? `OK · lista ${rd.list_cached ? 'en caché (' + rd.list_ttl_s + ' s)' : 'sin caché'}` : fmtErr(rd)}</dd>
        <dt>Debezium</dt><dd>${cn.state ? cn.state + (cn.ok ? '' : ' (' + (cn.error || 'tareas no RUNNING') + ')') : fmtErr(cn)}</dd>
        <dt>Cola → ${peer.toUpperCase()}</dt><dd class="${kf.outbound_pending > 0 ? 'big' : ''}">${kf.ok ? `${kf.outbound_pending} eventos esperan a ${peer.toUpperCase()} (fin del topic: ${kf.topic_end})` : fmtErr(kf)}</dd>
        <dt>Replicator</dt><dd>${rp.ok
          ? `aplicados ${rp.applied || 0} · eco ${rp.echo || 0} · viejos ${rp.skipped_older || 0} · lag ${rp.last_lag_ms >= 0 ? rp.last_lag_ms + ' ms' : '—'} · Kafka ${peer.toUpperCase()}: ${rp.peer_connected ? 'conectado' : 'NO alcanzable'}`
          : 'sin latido'}</dd>
      </dl>
      <p class="dim small">${st.at ? 'status ' + fmtTime(st.at) : ''}${st.ok === false ? ' · /status no disponible (' + (st.err || '') + ')' : ''}</p>`;
  }
}

function renderBadge() {
  const b = $('#active-badge');
  if (!state.active) {
    b.className = 'badge down';
    b.textContent = 'Sin conexión · datos en caché';
    return;
  }
  const pinned = state.mode !== 'auto';
  const failover = !pinned && state.active !== state.preferred;
  b.className = 'badge ' + (failover ? 'warn' : 'ok');
  b.textContent = `Conectado a ${nameOf(state.active)}${pinned ? ' (fijada)' : failover ? ' (failover)' : ''}`;
}

// ------------------------------------------------------------------ arranque
async function loadConfig() {
  const r = await fetch('./config.json', { cache: 'no-store' });
  if (!r.ok) throw new Error('config.json no disponible');
  return r.json();
}

// Borra lo que esta app guardó en el navegador (registro del Service Worker y cachés del app-shell) y vuelve a cargar
// sin el parámetro. No toca nada de otros sitios ni la cola local de escrituras pendientes.
async function resetLocal() {
  $('#cfg-meta').textContent = 'Borrando la caché de esta app en este navegador…';
  try {
    if ('serviceWorker' in navigator) for (const r of await navigator.serviceWorker.getRegistrations()) await r.unregister();
    if (window.caches) for (const k of await caches.keys()) await caches.delete(k);
  } catch {}
  const u = new URL(location.href);
  u.searchParams.delete('reset');
  location.replace(u.toString());
}

async function init() {
  // ?reset=1 → borra SOLO lo de esta app en este navegador (Service Worker y caché del app-shell; la cola local de
  // escrituras se conserva) y recarga limpio. Útil si el navegador sigue mostrando una versión anterior.
  if (new URLSearchParams(location.search).get('reset')) { await resetLocal(); return; }
  if ('serviceWorker' in navigator) {
    const hadController = !!navigator.serviceWorker.controller;
    navigator.serviceWorker.register('./sw.js').then((reg) => {
      $('#sw-badge').textContent = 'SW: ' + (navigator.serviceWorker.controller ? 'activo (app en caché)' : 'instalado');
      reg.addEventListener('updatefound', () => { $('#sw-badge').textContent = 'SW: actualizando…'; });
    }).catch(() => { $('#sw-badge').textContent = 'SW: no disponible'; });
    // Un SW nuevo tomó el control (se publicó otra versión): se recarga una sola vez para mostrarla de inmediato.
    navigator.serviceWorker.addEventListener('controllerchange', () => {
      $('#sw-badge').textContent = 'SW: activo (app en caché)';
      if (hadController && !state.reloading) { state.reloading = true; location.reload(); }
    });
  }
  let cfg;
  try {
    cfg = await loadConfig();
  } catch (e) {
    $('#cfg-meta').textContent = 'No se pudo cargar config.json (despliega con scripts/deploy-web.sh).';
    log('error', 'config.json no disponible');
    return;
  }
  state.cfg = { probe_interval_ms: 3000, probe_timeout_ms: 1500, request_timeout_ms: 2500, failback_healthy_probes: 3, ...cfg };
  state.regions = cfg.regions;
  state.preferred = cfg.preferred || 'a';
  // Si esta copia del SPA se sirve desde la VM de una región (https://<VM>/app/), esa región es la preferida: la copia
  // de A prefiere A y cae a B si A no responde; la de B prefiere B y cae a A. Desde Static Web Apps manda config.json.
  const served = state.regions.find((r) => { try { return new URL(r.url).host === location.host; } catch { return false; } });
  if (served) state.preferred = served.key;
  $('#mode option[value=auto]').textContent = 'Automática (preferida ' + state.preferred.toUpperCase() + ')';
  for (const r of state.regions) state.health[r.key] = { ok: undefined, consecutiveOk: 0 };
  const m = new URLSearchParams(location.search).get('region');
  if (m && regionByKey(m)) { state.mode = m; $('#mode').value = m; }
  $('#cfg-meta').textContent = 'APIs: ' + state.regions.map((r) => r.key.toUpperCase() + ' → ' + r.url).join('  ·  ') + (served ? '  ·  esta copia se sirve desde ' + served.name + ' (preferida)' : '');
  $('#mode').onchange = (e) => {
    state.mode = e.target.value;
    const u = new URL(location.href);
    if (state.mode === 'auto') u.searchParams.delete('region'); else u.searchParams.set('region', state.mode);
    history.replaceState(null, '', u);
    log('info', 'modo: ' + (state.mode === 'auto' ? 'automático' : 'fijado a ' + nameOf(state.mode)));
    chooseActive();
    renderBadge();
  };
  for (const r of state.regions) { const o = $(`#destino option[value=${r.key}]`); if (o) o.textContent = 'Guardar en: ' + r.name; }
  const d = new URLSearchParams(location.search).get('destino');
  if (d && (d === 'auto' || regionByKey(d))) $('#destino').value = d;
  $('#destino').onchange = (e) => {
    const u = new URL(location.href);
    if (e.target.value === 'auto') u.searchParams.delete('destino'); else u.searchParams.set('destino', e.target.value);
    history.replaceState(null, '', u);
    log('info', 'las escrituras van a: ' + (e.target.value === 'auto' ? 'la región activa (automática, con failover)' : nameOf(e.target.value)));
  };
  $('#new-form').onsubmit = (e) => {
    e.preventDefault();
    const texto = $('#texto').value.trim();
    if (!texto) return;
    createTicket(texto, writeTarget());
    $('#texto').value = '';
  };
  $('#clear-log').onclick = () => { $('#log').innerHTML = ''; };
  renderPending();
  await probeAll();
  pollStatus();
  setInterval(probeAll, state.cfg.probe_interval_ms);
  setInterval(pollStatus, 4000);
}

init();
