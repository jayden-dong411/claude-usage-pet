// Codex (ChatGPT desktop / Codex CLI) data for the GPT龙娘 Windows edition — the twin of
// ../companions/ChatGPTPet/Sources/Codex.swift and UsageIndex.swift.
//   ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl   one file per thread
//   ~/.codex/session_index.jsonl                   thread titles
const fs = require('fs');
const path = require('path');
const { home } = require('./paths');

const ROOT = path.join(home, '.codex');
const SESSIONS = path.join(ROOT, 'sessions');
const INDEX = path.join(ROOT, 'session_index.jsonl');

function listRollouts(maxAgeMs) {
  const out = [];
  const walk = (d, depth) => {
    let entries = [];
    try { entries = fs.readdirSync(d, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      const p = path.join(d, e.name);
      if (e.isDirectory() && depth < 4) walk(p, depth + 1);
      else if (e.name.endsWith('.jsonl')) {
        try {
          const st = fs.statSync(p);
          if (!maxAgeMs || Date.now() - st.mtimeMs < maxAgeMs) out.push({ path: p, mtime: st.mtimeMs, size: st.size });
        } catch {}
      }
    }
  };
  walk(SESSIONS, 0);
  return out;
}

/** Reads `file` from `offset`; returns the complete lines and the new offset. */
function readNew(file, offset, size) {
  if (size <= offset) return { lines: [], offset };
  const fd = fs.openSync(file, 'r');
  try {
    const len = size - offset;
    const buf = Buffer.alloc(len);
    fs.readSync(fd, buf, 0, len, offset);
    const last = buf.lastIndexOf(0x0a);
    if (last < 0) return { lines: [], offset };
    return { lines: buf.subarray(0, last).toString('utf8').split('\n'), offset: offset + last + 1 };
  } finally { fs.closeSync(fd); }
}

// ------------------------------------------------------------------ threads (tasks)

class CodexReader {
  constructor() { this.threads = new Map(); this.titles = new Map(); this.indexOffset = 0; }

  readIndex() {
    let size = 0;
    try { size = fs.statSync(INDEX).size; } catch { return; }
    if (size < this.indexOffset) { this.indexOffset = 0; this.titles.clear(); }
    const r = readNew(INDEX, this.indexOffset, size);
    this.indexOffset = r.offset;
    for (const l of r.lines) {
      try { const o = JSON.parse(l); if (o.id && typeof o.thread_name === 'string') this.titles.set(o.id, o.thread_name); } catch {}
    }
  }

  readThread(f) {
    let st = this.threads.get(f.path);
    if (!st || f.size < st.offset) st = { offset: 0, id: '', cwd: '', model: null, threadSource: null, lastStarted: 0, lastFinished: 0, lastEvent: 0, pending: new Set(), plan: [] };
    const r = readNew(f.path, st.offset, f.size);
    st.offset = r.offset;
    const wanted = ['"session_meta"', '"turn_context"', '"task_started"', '"task_complete"', '"turn_aborted"', '"function_call"', '"custom_tool_call"', '_call_output"'];
    for (const l of r.lines) {
      if (!wanted.some((w) => l.includes(w))) continue;
      let o; try { o = JSON.parse(l); } catch { continue; }
      const ts = Date.parse(o.timestamp) || 0;
      if (ts) st.lastEvent = Math.max(st.lastEvent, ts);
      const p = o.payload || {};
      const kind = `${o.type}/${p.type || ''}`;
      if (o.type === 'session_meta') { st.id = p.id || p.session_id || st.id; st.cwd = p.cwd || st.cwd; st.threadSource = p.thread_source || null; }
      else if (o.type === 'turn_context') { st.model = p.model || st.model; st.cwd = p.cwd || st.cwd; }
      else if (kind === 'event_msg/task_started') { st.lastStarted = ts; st.pending.clear(); }
      else if (kind === 'event_msg/task_complete' || kind === 'event_msg/turn_aborted') { st.lastFinished = ts; st.pending.clear(); }
      else if (kind === 'response_item/function_call' || kind === 'response_item/custom_tool_call') {
        const name = p.name || '', call = p.call_id || '';
        if (name.includes('request_user_input') && call) st.pending.add(call);
        if (name === 'update_plan' && typeof p.arguments === 'string') {
          try { const a = JSON.parse(p.arguments); if (Array.isArray(a.plan)) st.plan = a.plan.map((x) => [x.step || '', x.status || 'pending']); } catch {}
        }
      } else if (kind === 'response_item/function_call_output' || kind === 'response_item/custom_tool_call_output') {
        if (p.call_id) st.pending.delete(p.call_id);
      }
    }
    this.threads.set(f.path, st);
    return st;
  }

  /** Titled threads touched within `windowMs`, newest first. */
  sessions(windowMs = 6 * 3600e3) {
    this.readIndex();
    const now = Date.now();
    const out = [];
    for (const f of listRollouts(Math.max(windowMs, 86400e3))) {
      const st = this.readThread(f);
      if (now - f.mtime > windowMs || !st.id) continue;
      const title = this.titles.get(st.id) || '';
      if (!title && st.threadSource !== 'user') continue;          // imported / background threads
      const running = st.lastStarted > st.lastFinished && now - (st.lastEvent || f.mtime) < 30 * 60e3;
      const status = running ? (st.pending.size ? 'waiting' : 'busy') : 'idle';
      let progress = null;
      if (st.plan.length) {
        const done = st.plan.filter((x) => x[1] === 'completed').length;
        const cur = (st.plan.find((x) => x[1] === 'in_progress') || st.plan.find((x) => x[1] === 'pending') || [])[0];
        progress = { done, total: st.plan.length, current: done >= st.plan.length ? null : cur || null };
      }
      const folder = st.cwd ? path.basename(st.cwd) : '';
      out.push({
        id: st.id, name: title || folder || '未命名线程', status, cwd: st.cwd, model: st.model,
        statusSince: running ? (st.lastStarted || f.mtime) : (st.lastFinished || st.lastEvent || f.mtime), progress,
        isBusy: status === 'busy', isWaiting: status === 'waiting', waitingLabel: '等你回复',
        statusLabel: status === 'busy' ? '进行中' : status === 'waiting' ? '等你回复' : '空闲',
        folderName: folder || '—', entryLabel: st.model || 'Codex',
      });
    }
    return out.sort((a, b) => (b.isWaiting - a.isWaiting) || (b.isBusy - a.isBusy) || (b.statusSince - a.statusSince));
  }
}

// ------------------------------------------------------------------ daily statistics

const pad = (n) => String(n).padStart(2, '0');
const dayKey = (t) => { const d = new Date(t); return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`; };
const emptyDay = () => ({ tokens: { input: 0, output: 0, cacheWrite: 0, cacheRead: 0 }, messages: 0, activeSeconds: 0, sessions: [], models: {}, projects: {} });
const addTk = (a, b) => { a.input += b.input; a.output += b.output; a.cacheWrite += b.cacheWrite; a.cacheRead += b.cacheRead; };

/** Same rules as the Mac app: a reply counts when the thread's running token total moves; active
 *  time = gaps of at most 5 minutes between consecutive lines of the same thread. Incremental, cached. */
class CodexIndexer {
  constructor(cacheFile) {
    this.cacheFile = cacheFile;
    this.running = false;
    try { this.cache = JSON.parse(fs.readFileSync(cacheFile, 'utf8')); } catch { this.cache = null; }
    if (!this.cache || this.cache.version !== 1) this.cache = { version: 1, files: {}, days: {} };
  }

  async run(progress) {
    this.running = true;
    try {
      const files = listRollouts(0);
      const todo = files.reduce((a, f) => a + Math.max(0, f.size - (this.cache.files[f.path]?.offset || 0)), 0);
      let done = 0;
      for (const f of files) {
        let st = this.cache.files[f.path];
        if (!st || f.size < st.offset) st = { offset: 0, lastTs: 0, project: '未知项目', projectFromCwd: false, lastTotal: 0, model: 'unknown' };
        if (f.size <= st.offset) continue;
        const session = path.basename(f.path, '.jsonl');
        const r = readNew(f.path, st.offset, f.size);
        for (const l of r.lines) this.line(l, st, session);
        done += r.offset - st.offset;
        st.offset = r.offset;
        this.cache.files[f.path] = st;
        if (progress && todo) progress(Math.min(1, done / todo));
        await new Promise((res) => setImmediate(res));      // keep the UI responsive
      }
      try { fs.writeFileSync(this.cacheFile, JSON.stringify(this.cache)); } catch {}
      return this.cache.days;
    } finally { this.running = false; }
  }

  line(l, st, session) {
    const m = /"timestamp":"([^"]+)"/.exec(l);
    if (!m) return;
    const t = Date.parse(m[1]);
    if (!t) return;
    const day = dayKey(t);
    const d = this.cache.days[day] || (this.cache.days[day] = emptyDay());
    if (!st.projectFromCwd) {
      const c = /"cwd":"((?:[^"\\]|\\.)*)"/.exec(l);
      if (c && c[1]) { st.project = path.basename(c[1].replace(/\\\\/g, '\\').replace(/\\/g, '/')); st.projectFromCwd = true; }
    }
    if (st.lastTs) {
      const gap = (t - st.lastTs) / 1000;
      if (gap > 0 && gap <= 300) {
        d.activeSeconds += gap;
        const p = d.projects[st.project] || (d.projects[st.project] = { tokens: { input: 0, output: 0, cacheWrite: 0, cacheRead: 0 }, activeSeconds: 0, messages: 0 });
        p.activeSeconds += gap;
      }
    }
    if (t > st.lastTs) st.lastTs = t;
    if (!d.sessions.includes(session)) d.sessions.push(session);
    if (l.includes('"type":"turn_context"')) {
      const mm = /"model":"([^"]+)"/.exec(l);
      if (mm) st.model = mm[1];
      return;
    }
    if (!l.includes('"type":"token_count"') || !l.includes('"last_token_usage"')) return;
    let o; try { o = JSON.parse(l); } catch { return; }
    const info = o.payload?.info;
    if (!info?.total_token_usage || !info.last_token_usage) return;
    const total = info.total_token_usage.total_tokens || 0;
    if (total === st.lastTotal) return;                      // same reply reported again
    st.lastTotal = total;
    const u = info.last_token_usage;
    const cached = u.cached_input_tokens || 0;
    const tk = { input: Math.max(0, (u.input_tokens || 0) - cached), output: u.output_tokens || 0, cacheWrite: u.cache_write_input_tokens || 0, cacheRead: cached };
    if (tk.input + tk.output + tk.cacheWrite + tk.cacheRead === 0) return;
    d.messages += 1;
    addTk(d.tokens, tk);
    addTk(d.models[st.model] || (d.models[st.model] = { input: 0, output: 0, cacheWrite: 0, cacheRead: 0 }), tk);
    const p = d.projects[st.project] || (d.projects[st.project] = { tokens: { input: 0, output: 0, cacheWrite: 0, cacheRead: 0 }, activeSeconds: 0, messages: 0 });
    addTk(p.tokens, tk);
    p.messages += 1;
  }
}

module.exports = { CodexReader, CodexIndexer };
