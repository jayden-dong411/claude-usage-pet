// Live Claude Code sessions (~/.claude/sessions/*.json) and their step progress,
// replayed from the task-list tool calls in each transcript. Mirrors the macOS app.
const fs = require('fs');
const path = require('path');
const { sessionsDir, projectsDir } = require('./paths');

function alive(pid) {
  try { process.kill(pid, 0); return true; } catch (e) { return e.code === 'EPERM'; }
}

const WAIT_LABELS = {
  'permission prompt': '等你批准',
  'input needed': '等你回复',
  'dialog open': '等你操作',
};

function decorate(s) {
  s.isBusy = s.status === 'busy';
  s.isWaiting = s.status === 'waiting';
  s.waitingLabel = WAIT_LABELS[s.waitingFor] || '等你处理';
  s.statusLabel = s.isBusy ? '进行中' : s.isWaiting ? s.waitingLabel
    : (s.status === 'idle' || s.status === 'shell') ? '空闲' : s.status;
  s.folderName = path.basename(s.cwd || '');
  const ep = s.entrypoint || '';
  s.entryLabel = ep.includes('desktop') ? '桌面版' : ep.includes('cli') ? '终端'
    : (ep.includes('vscode') || ep.includes('ide')) ? 'IDE' : (ep || 'Claude Code');
  return s;
}

function loadSessions() {
  let files = [];
  try { files = fs.readdirSync(sessionsDir).filter((f) => f.endsWith('.json')); } catch { return []; }
  const out = [];
  for (const f of files) {
    let o;
    try { o = JSON.parse(fs.readFileSync(path.join(sessionsDir, f), 'utf8')); } catch { continue; }
    if (typeof o.pid !== 'number' || !alive(o.pid)) continue;
    const name = (o.name || '').trim() || path.basename(o.cwd || '') || '未命名会话';
    out.push(decorate({
      id: o.sessionId || String(o.pid),
      pid: o.pid,
      name,
      status: o.status || 'unknown',
      cwd: o.cwd || '',
      entrypoint: o.entrypoint || '',
      startedAt: o.startedAt || 0,
      statusSince: o.statusUpdatedAt || o.updatedAt || 0,
      waitingFor: o.waitingFor || null,
      hostSessionId: o.hostSessionId || null,
      bridgeSessionId: o.bridgeSessionId || null,
      progress: null,
    }));
  }
  out.sort((a, b) => (b.isWaiting - a.isWaiting) || (b.isBusy - a.isBusy) || (b.statusSince - a.statusSince));
  return out;
}

class ProgressTracker {
  constructor() { this.entries = new Map(); }

  locate(sid) {
    let dirs = [];
    try { dirs = fs.readdirSync(projectsDir); } catch { return null; }
    for (const d of dirs) {
      const f = path.join(projectsDir, d, `${sid}.jsonl`);
      if (fs.existsSync(f)) return f;
    }
    return null;
  }

  progress(sid) {
    let e = this.entries.get(sid);
    if (!e) { e = { file: undefined, offset: 0, items: [] }; this.entries.set(sid, e); }
    if (e.file === undefined || e.file === null) e.file = this.locate(sid);
    if (!e.file) return null;
    this.readNew(e);
    if (!e.items.length) return null;
    const done = e.items.filter((i) => i.status === 'completed').length;
    const cur = (e.items.find((i) => i.status === 'in_progress') || e.items.find((i) => i.status === 'pending') || {}).content;
    return { done, total: e.items.length, current: done >= e.items.length ? null : cur || null };
  }

  prune(ids) { for (const k of [...this.entries.keys()]) if (!ids.has(k)) this.entries.delete(k); }

  readNew(e) {
    let size;
    try { size = fs.statSync(e.file).size; } catch { return; }
    if (size < e.offset) { e.offset = 0; e.items = []; }
    if (size <= e.offset) return;
    const fd = fs.openSync(e.file, 'r');
    try {
      const len = size - e.offset;
      const buf = Buffer.alloc(len);
      fs.readSync(fd, buf, 0, len, e.offset);
      const last = buf.lastIndexOf(0x0a);
      if (last < 0) return;
      e.offset += last + 1;
      const text = buf.subarray(0, last).toString('utf8');
      for (const line of text.split('\n')) {
        if (!line.includes('"tool_use"') || !/update_plan|TodoWrite|wrap_up/.test(line)) continue;
        let o;
        try { o = JSON.parse(line); } catch { continue; }
        if (o.type !== 'assistant' || !Array.isArray(o.message?.content)) continue;
        for (const c of o.message.content) if (c.type === 'tool_use') this.apply(c.name || '', c.input || {}, e);
      }
    } finally { fs.closeSync(fd); }
  }

  apply(name, input, e) {
    if (name === 'TodoWrite' && Array.isArray(input.todos)) {
      e.items = input.todos.map((t) => ({ content: t.activeForm || t.content || '', status: t.status || 'pending' }));
      return;
    }
    if (name.endsWith('wrap_up')) { e.items.forEach((i) => { i.status = 'completed'; }); return; }
    if (!name.endsWith('update_plan')) return;
    if (Array.isArray(input.items)) e.items = input.items.map((i) => ({ content: i.content || '', status: i.status || 'pending' }));
    if (input.advance === true) {
      const i = e.items.find((x) => x.status === 'in_progress'); if (i) i.status = 'completed';
      const j = e.items.find((x) => x.status === 'pending'); if (j) j.status = 'in_progress';
    }
    if (Array.isArray(input.done)) for (const n of input.done) { const it = e.items[n - 1]; if (it) it.status = 'completed'; }
    if (typeof input.start === 'number' && e.items[input.start - 1]) {
      e.items.forEach((x) => { if (x.status === 'in_progress') x.status = 'pending'; });
      e.items[input.start - 1].status = 'in_progress';
    }
  }
}

module.exports = { loadSessions, ProgressTracker, decorate };
