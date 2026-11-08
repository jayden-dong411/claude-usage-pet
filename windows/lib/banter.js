// What the pets say — the Windows twin of ../../Sources/Banter.swift, reading the same Assets/banter.json
// (copied to windows/assets/banter.json by prepare-assets.sh). Mood pools, time-of-day / weekday pools and
// anytime chatter; no line repeats until a dozen others were said; {five} {week} {time} … are filled in.
const fs = require('fs');
const path = require('path');

let data = null;
function load() {
  if (data) return data;
  try { data = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'assets', 'banter.json'), 'utf8')); } catch { data = { pets: {}, duets: [] }; }
  return data;
}

const recent = [];
const pad = (n) => String(n).padStart(2, '0');

function fill(line, vars = {}) {
  const d = new Date();
  const all = { time: `${pad(d.getHours())}:${pad(d.getMinutes())}`, ...vars };
  const out = line.replace(/\{(\w+)\}/g, (m, k) => (all[k] != null ? all[k] : m));
  return out.includes('{') ? null : out;
}

function pickFresh(pool, vars) {
  const ready = pool.map((l) => fill(l, vars)).filter(Boolean);
  const fresh = ready.filter((l) => !recent.includes(l));
  const list = fresh.length ? fresh : ready;
  if (!list.length) return null;
  const line = list[Math.floor(Math.random() * list.length)];
  recent.push(line);
  if (recent.length > 14) recent.splice(0, recent.length - 14);
  return line;
}

function timeKeys(d = new Date()) {
  const h = d.getHours(), wd = d.getDay(), keys = [];
  if (h >= 5 && h < 11) keys.push('morning');
  else if (h >= 11 && h < 14) keys.push('noon');
  else if (h >= 14 && h < 18) keys.push('afternoon');
  else if (h >= 18 && h < 23) keys.push('evening');
  else if (h === 23 || h === 0) keys.push('late');
  if (wd === 1) keys.push('monday');
  if (wd === 5 && h >= 12) keys.push('friday');
  if (wd === 0 || wd === 6) keys.push('weekend');
  return keys;
}

/** A line from one pool, e.g. 'petted', 'hop'. */
function line(pet, mood, vars) {
  return pickFresh(load().pets[pet]?.moods?.[mood] || [], vars);
}

/** Something to say now and then: mostly about the mood, sometimes the time of day, sometimes anything. */
function chatter(pet, moods, vars) {
  const p = load().pets[pet];
  if (!p) return null;
  const timePool = timeKeys().flatMap((k) => p.time?.[k] || []);
  const moodPool = moods.flatMap((m) => p.moods?.[m] || []);
  const r = Math.random();
  const order = r < 0.5 ? [moodPool, p.idle, timePool] : r < 0.72 && timePool.length ? [timePool, moodPool, p.idle] : [p.idle, moodPool, timePool];
  for (const pool of order) {
    if (!pool?.length) continue;
    const l = pickFresh(pool, vars);
    if (l) return l;
  }
  return null;
}

const name = (pet) => load().pets[pet]?.name || pet;

/** Builds a duet between pets a and b; usage(id) → highest limit in use (or null). */
function duet(a, b, usage) {
  const h = new Date().getHours(), wd = new Date().getDay();
  const cond = (when, x, y) => {
    const px = usage(x), py = usage(y);
    switch (when) {
      case 'any': return true;
      case 'A_high': return (px ?? 0) >= 75;
      case 'B_high': return (py ?? 0) >= 75;
      case 'A_low': return (px ?? 100) <= 25;
      case 'B_low': return (py ?? 100) <= 25;
      case 'both_high': return (px ?? 0) >= 75 && (py ?? 0) >= 75;
      case 'both_low': return (px ?? 100) <= 25 && (py ?? 100) <= 25;
      case 'night': return h >= 23 || h < 5;
      case 'morning': return h >= 6 && h < 11;
      case 'friday': return wd === 5;
      case 'weekend': return wd === 0 || wd === 6;
      default: return false;
    }
  };
  const options = [];
  for (const d of load().duets || []) {
    if (Array.isArray(d.pair)) {
      if (d.pair.length !== 2 || !d.pair.includes(a) || !d.pair.includes(b) || a === b) continue;
      if (cond(d.when, d.pair[0], d.pair[1])) options.push([d, d.pair[0], d.pair[1]], [d, d.pair[0], d.pair[1]]);
    } else if (cond(d.when, a, b)) {
      for (let i = 0; i < (d.when === 'any' ? 1 : 3); i++) options.push([d, a, b]);
    }
  }
  if (!options.length) return null;
  const [d, ra, rb] = options[Math.floor(Math.random() * options.length)];
  const pct = (id) => { const u = usage(id); return u == null ? undefined : `${Math.round(u)}%`; };
  const vars = { A: name(ra), B: name(rb), Apct: pct(ra), Bpct: pct(rb) };
  const lines = [];
  let t = 0;
  for (const [role, text] of d.lines) {
    const f = fill(text, vars);
    if (!f) return null;
    lines.push({ pet: role === 'A' ? ra : rb, text: f, delay: t });
    t += 3.6;
  }
  return lines;
}

module.exports = { chatter, line, duet, name, fill };
