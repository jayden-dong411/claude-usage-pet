// Daily Claude Code statistics from ~/.claude/projects/**/*.jsonl (same rules as the macOS app):
// tokens = `usage` of each assistant reply, counted once per message id;
// active time = gaps of at most 5 minutes between consecutive lines of one session.
// Files are read incrementally; the result is cached in the app's user-data folder.
const fs = require('fs');
const path = require('path');
const { projectsDir } = require('./paths');

const VERSION = 1;
const CHUNK = 8 << 20;
const K = (s) => Buffer.from(s, 'utf8');
const kTs = K('"timestamp":"'), kCwd = K('"cwd":"'), kUsage = K('"usage":{'), kAsst = K('"type":"assistant"');
const kId = K('"id":"msg_'), kModel = K('"model":"'), kIn = K('"input_tokens":'), kOut = K('"output_tokens":');
const kCw = K('"cache_creation_input_tokens":'), kCr = K('"cache_read_input_tokens":');

const emptyTokens = () => ({ input: 0, output: 0, cacheWrite: 0, cacheRead: 0 });
const addTokens = (a, b) => { a.input += b.input; a.output += b.output; a.cacheWrite += b.cacheWrite; a.cacheRead += b.cacheRead; };
const total = (t) => t.input + t.output + t.cacheWrite + t.cacheRead;
const emptyDay = () => ({ tokens: emptyTokens(), messages: 0, activeSeconds: 0, sessions: [], models: {}, projects: {} });

function dayKey(ms) {
  const d = new Date(ms);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

function strAfter(line, key, from = 0) {
  const i = line.indexOf(key, from);
  if (i < 0) return null;
  const s = i + key.length;
  let e = s;
  while (e < line.length && line[e] !== 0x22) { if (line[e] === 0x5c) e++; e++; }
  return line.toString('utf8', s, Math.min(e, line.length));
}

function intAfter(line, key, from) {
  const i = line.indexOf(key, from);
  if (i < 0) return 0;
  let k = i + key.length, v = 0;
  while (k < line.length && line[k] >= 48 && line[k] <= 57) { v = v * 10 + (line[k] - 48); k++; }
  return v;
}

function listJsonl(dir, out = []) {
  let ents = [];
  try { ents = fs.readdirSync(dir, { withFileTypes: true }); } catch { return out; }
  for (const e of ents) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) listJsonl(p, out);
    else if (e.name.endsWith('.jsonl')) out.push(p);
  }
  return out;
}

class UsageIndexer {
  constructor(cacheFile) {
    this.cacheFile = cacheFile;
    this.cache = { version: VERSION, files: {}, days: {}, seen: {} };
    try {
      const c = JSON.parse(fs.readFileSync(cacheFile, 'utf8'));
      if (c.version === VERSION) this.cache = c;
    } catch { /* first run */ }
    this.running = false;
  }

  save() {
    try { fs.writeFileSync(this.cacheFile + '.tmp', JSON.stringify(this.cache)); fs.renameSync(this.cacheFile + '.tmp', this.cacheFile); } catch { /* ignore */ }
  }

  day(k) { return this.cache.days[k] || (this.cache.days[k] = emptyDay()); }

  /** Index new lines; yields to the event loop between chunks. */
  async run(onProgress = () => {}) {
    if (this.running) return this.cache.days;
    this.running = true;
    try {
      const files = listJsonl(projectsDir).map((f) => { let s = 0; try { s = fs.statSync(f).size; } catch {} return [f, s]; });
      const todo = files.reduce((a, [f, s]) => a + Math.max(0, s - ((this.cache.files[f] || {}).offset || 0)), 0);
      let done = 0, lastReport = -1;
      for (const [file, size] of files) {
        let st = this.cache.files[file] || { offset: 0, lastTs: 0, project: '', fromCwd: false };
        if (size < st.offset) st = { offset: 0, lastTs: 0, project: '', fromCwd: false };
        if (size <= st.offset) continue;
        if (!st.project) st.project = projectFromFolder(file);
        const isSub = file.includes(`${path.sep}subagents${path.sep}`);
        const session = path.basename(file, '.jsonl');
        const fd = fs.openSync(file, 'r');
        try {
          let pos = st.offset, carry = Buffer.alloc(0);
          while (pos < size) {
            const len = Math.min(CHUNK, size - pos);
            const chunk = Buffer.alloc(len);
            fs.readSync(fd, chunk, 0, len, pos);
            pos += len;
            const buf = carry.length ? Buffer.concat([carry, chunk]) : chunk;
            let start = 0, nl;
            while ((nl = buf.indexOf(0x0a, start)) >= 0) {
              this.line(buf.subarray(start, nl), st, session, isSub);
              start = nl + 1;
            }
            st.offset = pos - (buf.length - start);   // only complete lines count as read
            carry = buf.subarray(start);
            done += len;
            const p = todo ? done / todo : 1;
            if (p - lastReport > 0.01) { lastReport = p; onProgress(Math.min(1, p)); }
            await new Promise((r) => setImmediate(r));
          }
        } finally { fs.closeSync(fd); }
        this.cache.files[file] = st;
      }
      onProgress(1);
      this.save();
      return this.cache.days;
    } finally { this.running = false; }
  }

  line(line, st, session, isSub) {
    if (line.length < 30) return;
    const ts = strAfter(line, kTs);
    if (!ts) return;
    const t = Date.parse(ts);
    if (!Number.isFinite(t)) return;
    const k = dayKey(t);
    if (!st.fromCwd) {
      const cwd = strAfter(line, kCwd);
      if (cwd) { st.project = path.basename(cwd.replace(/\\\\/g, '\\')) || cwd; st.fromCwd = true; }
    }
    if (!isSub) {
      const d = this.day(k);
      if (st.lastTs > 0) {
        const gap = (t - st.lastTs) / 1000;
        if (gap > 0 && gap <= 300) {
          d.activeSeconds += gap;
          const p = d.projects[st.project] || (d.projects[st.project] = { tokens: emptyTokens(), activeSeconds: 0, messages: 0 });
          p.activeSeconds += gap;
        }
      }
      if (t > st.lastTs) st.lastTs = t;
      if (!d.sessions.includes(session)) d.sessions.push(session);
    }
    const ui = line.indexOf(kUsage);
    if (ui < 0 || line.indexOf(kAsst) < 0) return;
    const id = strAfter(line, kId);
    if (!id || this.cache.seen[id]) return;
    this.cache.seen[id] = 1;
    const model = strAfter(line, kModel) || 'unknown';
    if (model === '<synthetic>') return;
    const tk = { input: intAfter(line, kIn, ui), output: intAfter(line, kOut, ui), cacheWrite: intAfter(line, kCw, ui), cacheRead: intAfter(line, kCr, ui) };
    const d = this.day(k);
    d.messages += 1;
    addTokens(d.tokens, tk);
    addTokens(d.models[model] || (d.models[model] = emptyTokens()), tk);
    const p = d.projects[st.project] || (d.projects[st.project] = { tokens: emptyTokens(), activeSeconds: 0, messages: 0 });
    addTokens(p.tokens, tk);
    p.messages += 1;
  }
}

function projectFromFolder(file) {
  const rel = path.relative(projectsDir, file).split(path.sep)[0] || '';
  const parts = rel.split('-').filter(Boolean);
  return parts[parts.length - 1] || rel || '未知项目';
}

module.exports = { UsageIndexer, dayKey, total, emptyDay, emptyTokens, addTokens };
