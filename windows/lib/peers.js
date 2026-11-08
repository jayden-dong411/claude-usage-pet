// Other tools' usage for the "其他额度" section — the Windows twin of ../Sources/Peers.swift.
// - Codex: live from the ChatGPT account using the Codex CLI login (~/.codex/auth.json, read-only),
//   falling back to the newest `rate_limits` in ~/.codex/sessions logs.
// - Grok Bot: the desktop app's weekly-usage cache (<appData>/Grok Bot/sand-client-persistence).
// - DeepSeek: the balance DeepSeek Harness keeps in ~/.dsh/.dshw-usage.json.
const fs = require('fs');
const path = require('path');
const { home, isWin, isMac } = require('./paths');

const appData = isWin ? (process.env.APPDATA || path.join(home, 'AppData', 'Roaming'))
  : isMac ? path.join(home, 'Library', 'Application Support') : path.join(home, '.config');

// ---------------------------------------------------------------- Codex

let codexCache = { at: 0, value: null, error: null };

/** Live Codex limits; `fetchFn` is Electron's net.fetch (uses the system proxy). */
async function codexLive(fetchFn, maxAgeMs = 60e3) {
  if (Date.now() - codexCache.at < maxAgeMs) return codexCache.value;
  codexCache.at = Date.now();
  try {
    const auth = JSON.parse(fs.readFileSync(path.join(home, '.codex', 'auth.json'), 'utf8'));
    const t = auth.tokens || {};
    if (!t.access_token) throw new Error('没有找到 Codex 登录');
    const r = await fetchFn('https://chatgpt.com/backend-api/wham/usage', {
      headers: { Authorization: `Bearer ${t.access_token}`, 'ChatGPT-Account-Id': t.account_id || '', Accept: 'application/json', 'User-Agent': 'codex_cli_rs' },
    });
    if (r.status === 401 || r.status === 403) throw new Error('Codex 登录已过期，打开一次 Codex 就会自动续上');
    if (!r.ok) throw new Error(`查询失败（HTTP ${r.status}）`);
    const j = await r.json();
    const win = (w) => {
      if (!w) return { utilization: 0, resetsAt: null };
      const used = Number(w.used_percent) || 0;
      if (used === 0 && w.limit_window_seconds && w.reset_after_seconds >= w.limit_window_seconds - 60) return { utilization: 0, resetsAt: null };
      return { utilization: Math.max(0, used), resetsAt: w.reset_at ? w.reset_at * 1000 : null };
    };
    const rl = j.rate_limit || {};
    const plan = j.plan_type ? j.plan_type[0].toUpperCase() + j.plan_type.slice(1) : null;
    codexCache = { at: Date.now(), error: null,
      value: { provider: 'codex', title: 'ChatGPT · Codex', plan, observedAt: Date.now(),
        windows: [{ label: '5 小时', ...win(rl.primary_window) }, { label: '每周', ...win(rl.secondary_window) }] } };
  } catch (e) {
    codexCache = { at: Date.now(), value: null, error: e.message };
  }
  return codexCache.value;
}

/** Newest rate limits written by Codex in its local logs (misses web / phone / cloud usage). */
function codexLogs() {
  const root = path.join(home, '.codex', 'sessions');
  const files = [];
  const walk = (d, depth) => {
    let entries = [];
    try { entries = fs.readdirSync(d, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      const p = path.join(d, e.name);
      if (e.isDirectory() && depth < 4) walk(p, depth + 1);
      else if (e.name.endsWith('.jsonl')) {
        try { const m = fs.statSync(p).mtimeMs; if (Date.now() - m < 8 * 86400e3) files.push([p, m]); } catch {}
      }
    }
  };
  walk(root, 0);
  let best = null;
  for (const [p] of files.sort((a, b) => b[1] - a[1]).slice(0, 12)) {
    let text = '';
    try {
      const fd = fs.openSync(p, 'r'), size = fs.fstatSync(fd).size, len = Math.min(size, 2e6);
      const buf = Buffer.alloc(len); fs.readSync(fd, buf, 0, len, size - len); fs.closeSync(fd);
      text = buf.toString('utf8');
    } catch { continue; }
    const lines = text.split('\n').reverse();
    for (const l of lines) {
      if (!l.includes('"rate_limits"')) continue;
      try {
        const o = JSON.parse(l), rl = o.payload?.rate_limits, ts = Date.parse(o.timestamp);
        if (rl?.primary && (!best || ts > best.ts)) best = { ts, rl };
        break;
      } catch {}
    }
  }
  if (!best) return null;
  const win = (w, label) => {
    if (!w) return null;
    const reset = w.resets_at ? w.resets_at * 1000 : null;
    return reset && reset < Date.now() ? { label, utilization: 0, resetsAt: null } : { label, utilization: Math.max(0, w.used_percent || 0), resetsAt: reset };
  };
  const plan = best.rl.plan_type ? best.rl.plan_type[0].toUpperCase() + best.rl.plan_type.slice(1) : null;
  return { provider: 'codex', title: 'ChatGPT · Codex', plan, observedAt: best.ts,
    windows: [win(best.rl.primary, '5 小时'), win(best.rl.secondary, '每周')].filter(Boolean),
    note: '本机日志（网页版、手机和云端任务的用量看不到）' };
}

// ---------------------------------------------------------------- Grok Bot

function base32Decode(s) {
  const A = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  let bits = 0, value = 0;
  const out = [];
  for (const ch of s.toUpperCase()) {
    const i = A.indexOf(ch);
    if (i < 0) return null;
    value = (value << 5) | i; bits += 5;
    if (bits >= 8) { bits -= 8; out.push((value >> bits) & 0xff); }
  }
  return Buffer.from(out).toString('utf8');
}

function grokBot() {
  const dir = path.join(appData, 'Grok Bot', 'sand-client-persistence');
  let best = null;
  let names = [];
  try { names = fs.readdirSync(dir); } catch { return null; }
  for (const n of names) {
    if (!n.endsWith('.blob')) continue;
    const key = base32Decode(n.slice(0, -5));
    if (!key || !key.endsWith('.weekly-usage.cache')) continue;
    const p = path.join(dir, n);
    const m = fs.statSync(p).mtimeMs;
    if (!best || m > best.m) best = { p, m };
  }
  if (!best) return null;
  try {
    const v = JSON.parse(fs.readFileSync(best.p, 'utf8')).value;
    const u = v?.reading?.usage;
    if (!u || typeof u.percentUsed !== 'number') return null;
    let reset = u.nextResetMs || null, used = Math.max(0, u.percentUsed);
    if (reset && reset < Date.now()) { reset = null; used = 0; }
    return { provider: 'grok', title: 'Grok Bot', plan: u.unifiedPlanName || u.grokPlanLabel || null,
      observedAt: v.reading.readAtMs || best.m, windows: [{ label: '每周', utilization: used, resetsAt: reset }] };
  } catch { return null; }
}

// ---------------------------------------------------------------- DeepSeek

function deepseek() {
  const p = path.join(home, '.dsh', '.dshw-usage.json');
  try {
    const o = JSON.parse(fs.readFileSync(p, 'utf8'));
    if (typeof o.lastBalance !== 'number') return null;
    const pad = (n) => String(n).padStart(2, '0');
    const key = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
    const today = key(new Date());
    const hist = { ...(o.history || {}) };
    const todaySpend = o.date === today ? (o.todayUsage || 0) : 0;
    hist[today] = Math.max(hist[today] || 0, todaySpend);
    let week = 0;
    for (let i = 0; i < 7; i++) week += hist[key(new Date(Date.now() - i * 86400e3))] || 0;
    let currency = 'CNY';
    const acc = o.accounting;
    if (acc?.active && acc.books?.[acc.active]?.currency) currency = acc.books[acc.active].currency;
    const sym = currency === 'USD' ? '$' : '¥';
    const money = (v) => sym + v.toFixed(2);
    const lines = [`余额 ${money(o.lastBalance)}`, `今天花了 ${money(todaySpend)} · 近 7 天 ${money(week)}`];
    if (week / 7 > 0.01) lines.push(`按近 7 天的速度约还能用 ${Math.floor(o.lastBalance / (week / 7))} 天`);
    return { provider: 'deepseek', title: 'DeepSeek', windows: [], lines, observedAt: fs.statSync(p).mtimeMs,
      short: `DeepSeek ${money(o.lastBalance)}` };
  } catch { return null; }
}

// ---------------------------------------------------------------- sharing between the pets
// Same files and format as the macOS PeerStore: <appData>/AIPets/<provider>.json, dates in seconds.
// Claude limits can only be fetched by the Claude pet (it holds the claude.ai login), so it writes
// claude.json for the others; GPT龙娘 writes codex.json.

const shareDir = path.join(appData, 'AIPets');

function writePeer(u) {
  try {
    fs.mkdirSync(shareDir, { recursive: true });
    const sec = (t) => (t == null ? undefined : t / 1000);
    const out = { ...u, observedAt: sec(u.observedAt), windows: (u.windows || []).map((w) => ({ ...w, resetsAt: sec(w.resetsAt) })), lines: u.lines || [] };
    const file = path.join(shareDir, `${u.provider}.json`);
    fs.writeFileSync(file + '.tmp', JSON.stringify(out));
    fs.renameSync(file + '.tmp', file);
  } catch { /* sharing is best-effort */ }
}

function readPeer(provider, maxAgeMs = 24 * 3600e3) {
  try {
    const o = JSON.parse(fs.readFileSync(path.join(shareDir, `${provider}.json`), 'utf8'));
    const observedAt = o.observedAt * 1000;
    if (!(Date.now() - observedAt < maxAgeMs)) return null;
    return { ...o, observedAt, windows: (o.windows || []).map((w) => ({ ...w, resetsAt: w.resetsAt ? w.resetsAt * 1000 : null })) };
  } catch { return null; }
}

/** All other tools' usage that exists on this machine, leaving out `exclude` (the pet's own tool). */
async function readPeers(fetchFn, exclude = 'claude') {
  const out = [];
  if (exclude !== 'claude') { const c = readPeer('claude'); if (c) out.push(c); }
  if (exclude !== 'codex') {
    const c = readPeer('codex', 300e3) || (await codexLive(fetchFn)) || codexLogs();
    if (c) out.push(c);
  }
  const g = grokBot(); if (g) out.push(g);
  const d = deepseek(); if (d) out.push(d);
  return out;
}

const codexError = () => codexCache.error;

module.exports = { readPeers, codexError, codexLive, codexLogs, writePeer, readPeer };
