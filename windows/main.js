// Claude大小姐 · Claude 用量桌宠 — Windows (Electron) edition. Mirrors the macOS app in ../Sources.
const { app, BrowserWindow, ipcMain, Menu, Tray, nativeImage, nativeTheme, screen, shell, Notification, powerMonitor, net } = require('electron');
const fs = require('fs');
const path = require('path');
const { loadSessions, ProgressTracker, decorate } = require('./lib/sessions');
const { UsageIndexer, dayKey } = require('./lib/indexer');
const { UsageHistory } = require('./lib/history');
const { WebFetcher, fetchOAuth, readDesktopCookies, CHROME_UA } = require('./lib/usage');
const { Foreground } = require('./lib/foreground');
const EXPR = require('./lib/expressions');
const { readPeers, codexError, writePeer } = require('./lib/peers');
const banter = require('./lib/banter');
const { DuetLink } = require('./lib/duet');
const { CodexIndexer } = require('./lib/codex');

app.userAgentFallback = CHROME_UA;
const args = process.argv.slice(1);
const snapIdx = args.indexOf('--snapshot');
const SNAPSHOT = snapIdx >= 0 ? path.resolve(args[snapIdx + 1] || 'snapshots') : null;
const DEMO = args.includes('--demo');

if (!SNAPSHOT && !app.requestSingleInstanceLock()) app.quit();

const ATTRIBUTION = '素材：Claude大小姐的日记本（github.com/opsCar/claude-daxiaojie-assets）· 角色设定：ZipZipPipe（胖次狐）· 设定图：lmy414/ai-chan-sheets · CC BY-NC-SA 4.0；v3 小人：ai-chan-sheets 的 Claude娘设定图（CC BY-NC-SA 4.0）';
const LEVEL_NAMES = ['暂无数据', '活力满满', '状态良好', '注意压力', '压力山大'];
const CLAUDE_PROCS = ['claude'];                       // Claude desktop's process name (Claude.exe)
const BASE = { w: 220, h: 300 };
const asset = (...p) => path.join(__dirname, 'assets', ...p);

// ------------------------------------------------------------------ settings

const DEFAULTS = { scale: 1, opacity: 1, rotateSeconds: 12, chatter: true, onlyWithClaude: true,
  hideInFullscreen: false, alertWaiting: true, notifications: true, launchAtLogin: false, petPos: null, hasSecondary: false,
  figure: 'stickers', peersExpanded: false, focusMinutes: 25, sitReminder: true, nightReminder: true, chatterSeconds: 30, petChat: true };
let settingsFile, settings = { ...DEFAULTS };
function loadSettings() {
  settingsFile = path.join(app.getPath('userData'), 'settings.json');
  try { settings = { ...DEFAULTS, ...JSON.parse(fs.readFileSync(settingsFile, 'utf8')) }; } catch { /* defaults */ }
}
function saveSettings() { try { fs.writeFileSync(settingsFile, JSON.stringify(settings, null, 1)); } catch {} }

// ------------------------------------------------------------------ state

const state = {
  usage: null, usageError: null, needsLogin: false, loadingUsage: false, lastUsageUpdate: null,
  secondary: null, secondaryError: null,
  sessions: [], days: {}, otherDays: {}, indexing: false, indexProgress: 0, lastIndexed: null,
  face: 'hi', bubble: null,
  v3face: 'smile', hopAt: 0, shakeAt: 0,           // v3 look + jump / shake animations in the pet page
  peers: [], codexError: null,                     // other tools' usage (lib/peers.js)
  focusEnd: 0, restEnd: 0,                          // focus timer
};
const V3_FACES = ['smile', 'calm', 'surprised', 'shy', 'pout', 'giggle', 'serious', 'aggrieved'];
const hasV3 = () => fs.existsSync(asset('v3', 'face_smile.png'));
let history, indexer, codexIndexer, duetLink, tracker, primaryWeb, secondaryWeb, foreground;
let pet, panel, dashboard, settingsWin, tray;
const logins = { main: null, second: null };
let prevStatus = new Map();

function level() {
  const u = state.usage;
  if (!u) return 0;
  const vals = [u.fiveHour?.utilization, u.sevenDay?.utilization].filter((v) => typeof v === 'number');
  if (!vals.length) return 0;
  const m = Math.max(...vals);
  return m < 40 ? 1 : m < 70 ? 2 : m < 90 ? 3 : 4;
}

function payload() {
  const acct = state.usage?.account;
  return {
    ...state,
    platform: process.platform,
    level: level(), levelName: LEVEL_NAMES[level()],
    settings, attribution: ATTRIBUTION,
    forecast5: history.forecast(acct, true, state.usage?.fiveHour),
    forecast7: history.forecast(acct, false, state.usage?.sevenDay),
    spark: history.fiveHourSeries(acct, state.usage?.fiveHour),
    petTask: taskText(), petPill: pillText(), alert: state.sessions.some((s) => s.isWaiting),
    v3: settings.figure === 'v3' && hasV3(), hasV3: hasV3(), ownSource: 'claude', dashSource: args.includes('--dash-all') ? 'all' : null,
    focusing: state.focusEnd > Date.now(), resting: state.restEnd > Date.now(),
    now: Date.now(),
  };
}

let broadcastQueued = false;
function broadcast() {
  if (broadcastQueued) return;
  broadcastQueued = true;
  setImmediate(() => {
    broadcastQueued = false;
    const p = payload();
    for (const w of [pet, panel, dashboard, settingsWin]) if (w && !w.isDestroyed()) w.webContents.send('state', p);
    if (tray) {
      const f = state.usage?.fiveHour;
      tray.setToolTip(`Claude大小姐 · 5h ${f ? Math.round(f.utilization) + '%' : '—'}` + (p.focusing || p.resting ? ` · ${p.petPill}` : ''));
    }
  });
}

const clip = (s, n) => (s.length > n ? s.slice(0, n - 1) + '…' : s);
const mmss = (ms) => { const s = Math.max(0, Math.ceil(ms / 1000)); return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`; };
function pillText() {
  if (state.focusEnd > Date.now()) return `🍅 专注 ${mmss(state.focusEnd - Date.now())}`;
  if (state.restEnd > Date.now()) return `☕ 休息 ${mmss(state.restEnd - Date.now())}`;
  const u = state.usage;
  if (!u) return state.needsLogin ? '点我登录看用量' : '5h —  ·  7d —';
  const f = (w) => (w ? `${Math.round(w.utilization)}%` : '—');
  return `5h ${f(u.fiveHour)}  ·  7d ${f(u.sevenDay)}`;
}
function taskText() {
  const waiting = state.sessions.filter((s) => s.isWaiting), busy = state.sessions.filter((s) => s.isBusy);
  const all = [...waiting, ...busy];
  if (!all.length) return null;
  const line = (s) => {
    if (s.isWaiting) return `⏳ ${clip(s.name, 10)} · ${s.waitingLabel}`;
    if (s.progress) return `⚡ ${clip(s.name, 11)} · ${s.progress.done}/${s.progress.total}`;
    return `⚡ ${clip(s.name, 11)} · ${fmtDuration(Date.now() - s.statusSince)}`;
  };
  if (all.length === 1) return all[0].progress?.current ? `${line(all[0])}\n▸ ${clip(all[0].progress.current, 16)}` : line(all[0]);
  const lines = all.slice(0, 3).map(line);
  if (all.length > 3) lines.push(`还有 ${all.length - 3} 个任务…`);
  return lines.join('\n');
}
function fmtDuration(ms) {
  const s = Math.max(0, Math.floor(ms / 1000)), d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
  return d ? `${d}天${h}小时` : h ? `${h}小时${m}分` : m ? `${m}分钟` : '不到1分钟';
}

// ------------------------------------------------------------------ expressions

let reactionUntil = 0, nextRotate = 0, moodKey = '', lastNudge = 0, bubbleTimer = null;

function baseMoods() {
  const lv = level();
  const moods = [state.usage ? ['breezy', 'breezy', 'calm', 'strained', 'crushed'][lv] : 'noData'];
  if (state.sessions.some((s) => s.isBusy) || state.focusEnd > Date.now()) moods.push('working');
  if (settings.alertWaiting && state.sessions.some((s) => s.isWaiting)) moods.push('needsYou');
  const h = new Date().getHours();
  if (h >= 1 && h < 6) moods.push('night');
  return moods;
}
function pick(moods) {
  const all = moods.flatMap((m) => EXPR.faces[m] || []);
  const choices = all.filter((f) => f !== state.face);
  const list = choices.length ? choices : all;
  return list[Math.floor(Math.random() * list.length)] || 'happy';
}
function say(text, seconds = 5) {
  state.bubble = text;
  clearTimeout(bubbleTimer);
  bubbleTimer = setTimeout(() => { state.bubble = null; broadcast(); }, seconds * 1000);
  broadcast();
}
// v3 look: expression pools per state, mostly cheerful, swapped every 6–12 s.
const V3_POOLS = { idle: ['smile', 'giggle', 'smile', 'shy', 'giggle', 'calm'], working: ['smile', 'giggle', 'serious', 'smile', 'calm'],
  waiting: ['surprised', 'smile', 'shy'], strained: ['pout', 'smile', 'surprised'], crushed: ['aggrieved', 'pout', 'surprised'], sleepy: ['giggle', 'calm', 'shy'] };
const V3_REACT = { taskDone: 'giggle', hop: 'giggle', petted: 'shy', oops: 'aggrieved', crushed: 'aggrieved', needsYou: 'surprised',
  taskStarted: 'serious', working: 'serious' };
let v3Next = 0;
function v3State(moods) {
  if (moods.includes('needsYou')) return 'waiting';
  if (moods.includes('working')) return 'working';
  if (moods[0] === 'strained') return 'strained';
  if (moods[0] === 'crushed') return 'crushed';
  if (moods.includes('night')) return 'sleepy';
  return 'idle';
}
function v3Rotate(force) {
  const now = Date.now();
  if (!force && (now < v3Next || now < reactionUntil)) return;
  const pool = V3_POOLS[v3State(baseMoods())].filter((f) => f !== state.v3face);
  state.v3face = pool[Math.floor(Math.random() * pool.length)] || 'smile';
  v3Next = now + (6 + Math.random() * 6) * 1000;
}
function react(mood, seconds = 5, text = null) {
  state.face = pick([mood]);
  state.v3face = V3_REACT[mood] || 'smile';
  if (mood === 'hop' || mood === 'taskDone') state.hopAt = Date.now();
  if (mood === 'petted' || mood === 'oops') state.shakeAt = Date.now();
  v3Next = Date.now() + seconds * 1000;
  reactionUntil = Date.now() + seconds * 1000;
  nextRotate = reactionUntil;
  if (text) say(text); else broadcast();
}
function tickFace() {
  const now = Date.now();
  if (now < reactionUntil) return;
  if (settings.figure === 'v3' && now >= v3Next) { v3Rotate(true); broadcast(); }
  const w = state.sessions.find((s) => s.isWaiting);
  if (settings.alertWaiting && w && now - lastNudge > 180e3) {
    lastNudge = now;
    react('needsYou', 6, `「${w.name}」还在${w.waitingLabel}哦`);
    notify('Claude大小姐', `「${w.name}」还在${w.waitingLabel}`);
    return;
  }
  const moods = baseMoods(), key = moods.join(',');
  const changed = key !== moodKey;
  if (!changed && now < nextRotate) return;
  moodKey = key;
  state.face = pick(moods);
  const base = settings.rotateSeconds;
  nextRotate = now + (base * (0.7 + Math.random() * 0.6)) * 1000;
  broadcast();
}

// Says something on her own every `chatterSeconds` (±30%), from lib/banter.js.
let nextChatter = Date.now() + 10e3;
function tickChatter() {
  const now = Date.now();
  if (now < nextChatter || now < reactionUntil) return;
  nextChatter = now + settings.chatterSeconds * (0.7 + Math.random() * 0.6) * 1000;
  if (!settings.chatter || state.bubble || state.focusEnd > now) return;
  const u = state.usage, pc = (w) => (w ? `${Math.round(w.utilization)}%` : undefined);
  const moods = baseMoods();
  const l = banter.chatter('claude', moods, { five: pc(u?.fiveHour), week: pc(u?.sevenDay) })
    || (EXPR.lines[moods[0]] || [])[0];
  if (l) say(l, 4.5);
}

// Two pets chatting (lib/duet.js): pop up for the exchange and say my lines.
function duetLines(lines, total) {
  forceShowUntil = Date.now() + total * 1000;
  updateVisibility();
  for (const l of lines) setTimeout(() => { react('clicked', 3.4); say(l.text, 3.4); }, l.delay * 1000);
  nextChatter = Date.now() + (total + 10) * 1000;
}
function canChat() {
  const fg = foreground?.current || { known: false };
  return settings.petChat && !state.focusEnd && !state.restEnd && powerMonitor.getSystemIdleTime() < 120
    && (!fg.known || ['claude', 'chatgpt', 'codex'].includes(fg.name));
}

function notify(title, body) {
  if (!settings.notifications || petVisible() || !Notification.isSupported()) return;
  const n = new Notification({ title, body, icon: asset('icon.png'), silent: false });
  n.on('click', () => openPanel());
  n.show();
}

// ------------------------------------------------------------------ data refresh

function refreshSessions(notifyChanges) {
  const list = DEMO ? state.sessions : loadSessions();
  if (!DEMO) {
    for (const s of list) s.progress = tracker.progress(s.id);
    tracker.prune(new Set(list.map((s) => s.id)));
  }
  if (notifyChanges && prevStatus.size) {
    for (const s of list) {
      const prev = prevStatus.get(s.id);
      if (prev === 'busy' && (s.status === 'idle' || s.status === 'shell')) {
        react('taskDone', 5, `「${s.name}」完成了哦～`);
        notify('Claude大小姐', `「${s.name}」完成了`);
      }
      if (s.isWaiting && prev !== 'waiting' && settings.alertWaiting) {
        lastNudge = Date.now();
        react('needsYou', 8, `「${s.name}」${s.waitingLabel}～`);
        notify('Claude大小姐', `「${s.name}」${s.waitingLabel}`);
      }
    }
    const started = list.find((s) => s.isBusy && prevStatus.get(s.id) !== 'busy' && prevStatus.get(s.id) !== 'waiting');
    if (started) react('taskStarted', 5, `「${started.name}」开工！`);
  }
  prevStatus = new Map(list.map((s) => [s.id, s.status]));
  state.sessions = list;
  broadcast();
}

function applyUsage(snap) {
  state.usage = snap; state.usageError = null; state.needsLogin = false; state.lastUsageUpdate = Date.now();
  history.record(snap);
  const win = (label, w) => (w ? { label, utilization: w.utilization, resetsAt: w.resetsAt || null } : null);
  writePeer({ provider: 'claude', title: 'Claude', plan: snap.plan || null, observedAt: Date.now(),
    windows: [win('5 小时', snap.fiveHour), win('每周', snap.sevenDay)].filter(Boolean) });
  if (logins.main) { logins.main.close(); react('greet', 5, '登录成功，本小姐看到用量了～'); }
  broadcast();
}

async function refreshUsage() {
  if (DEMO || state.loadingUsage) return;
  state.loadingUsage = true; broadcast();
  const errors = [];
  try {
    let imported = false;
    try {
      const cookies = await readDesktopCookies();
      await primaryWeb.importCookies(cookies);
      imported = true;
      const snap = await primaryWeb.fetch(cookies.find((c) => c.name === 'lastActiveOrg')?.value);
      snap.source = 'Claude 桌面版登录';
      return applyUsage(snap);
    } catch (e) { errors.push(`桌面版登录：${e.message}`); }
    try {
      const snap = await fetchOAuth();
      if (snap) return applyUsage(snap);
    } catch (e) { errors.push(`Claude Code 令牌：${e.message}`); }
    if (!imported) {
      try { return applyUsage(await primaryWeb.fetch()); } catch (e) {
        if (e.code === 'NOT_LOGGED_IN') { state.needsLogin = true; errors.push('claude.ai 未登录'); } else errors.push(`claude.ai：${e.message}`);
      }
    }
    state.usageError = errors.join('；');
  } finally {
    state.loadingUsage = false;
    await refreshSecondary();
    broadcast();
  }
}

async function refreshSecondary() {
  if (!settings.hasSecondary || DEMO) return;
  try {
    const snap = await secondaryWeb.fetch();
    snap.source = '另一个账号';
    state.secondary = snap; state.secondaryError = null;
    history.record(snap);
    if (logins.second) { logins.second.close(); react('greet', 5, `另一个账号（${snap.account || ''}）也接上啦～`); }
  } catch (e) {
    state.secondary = null;
    state.secondaryError = e.code === 'NOT_LOGGED_IN' ? '还没登录' : e.message;
  }
  broadcast();
}

async function refreshPeers() {
  if (DEMO) return;
  state.peers = await readPeers((url, opts) => net.fetch(url, opts));
  state.codexError = codexError();
  broadcast();
}

// ------------------------------------------------------------------ focus timer & wellness reminders

let forceShowUntil = 0, streakStart = 0, nextSit = Infinity, lastActive = 0, lastNight = 0;

function startFocus() {
  state.restEnd = 0;
  state.focusEnd = Date.now() + settings.focusMinutes * 60e3;
  streakStart = 0;
  react('taskStarted', 4, `专注 ${settings.focusMinutes} 分钟，开始！本小姐帮你看着时间～`);
}
function stopFocus() {
  const was = state.focusEnd > Date.now();
  state.focusEnd = 0; state.restEnd = 0;
  say(was ? '好吧，这次就先到这里～' : '那就继续加油吧！');
}
function remind(mood, text, title) {
  forceShowUntil = Date.now() + 12e3;
  updateVisibility();
  react(mood, 12, null);
  say(text, 12);
  if (settings.notifications && Notification.isSupported()) {
    const n = new Notification({ title, body: text, icon: asset('icon.png') });
    n.on('click', () => openPanel());
    n.show();
  }
}
function tickFocus() {
  const now = Date.now();
  if (state.focusEnd && now >= state.focusEnd) {
    state.focusEnd = 0;
    state.restEnd = now + 5 * 60e3;
    remind('taskDone', `专注 ${settings.focusMinutes} 分钟完成！起来活动 5 分钟、喝口水吧～`, '🍅 专注完成');
  } else if (state.restEnd && now >= state.restEnd) {
    state.restEnd = 0; streakStart = 0;
    remind('greet', '休息结束～ 要再来一轮专注的话右键我哦', '☕ 休息结束');
  }
  if (state.focusEnd || state.restEnd) broadcast();
}
function tickWellness() {
  const now = Date.now();
  const idle = powerMonitor.getSystemIdleTime();               // seconds
  const fg = foreground?.current || { known: false };
  if (idle < 120 && (!fg.known || CLAUDE_PROCS.includes(fg.name))) lastActive = now;
  if (idle >= 300 || now - lastActive > 600e3 || state.focusEnd || state.restEnd) streakStart = 0;
  else if (!streakStart) { streakStart = now; nextSit = now + 2 * 3600e3; }
  if (settings.sitReminder && streakStart && now >= nextSit) {
    nextSit = now + 30 * 60e3;
    const mins = Math.floor((now - streakStart) / 60e3);
    const span = mins >= 60 ? `${Math.floor(mins / 60)} 小时${mins % 60 ? ` ${mins % 60} 分` : ''}` : `${mins} 分钟`;
    remind('care', `已经连续用了 ${span}啦，站起来走走、喝口水吧～`, '🧋 该活动啦');
  }
  const h = new Date().getHours();
  if (settings.nightReminder && h < 5 && now - lastActive < 120e3 && now - lastNight > 3600e3) {
    lastNight = now;
    remind('night', `已经 ${h === 0 ? 12 : h} 点多了，早点休息吧～`, '🌙 该睡啦');
  }
}

async function refreshIndex() {
  if (DEMO || indexer.running) return;
  state.indexing = true; broadcast();
  try {
    state.days = await indexer.run((p) => { state.indexProgress = p; broadcast(); });
    state.otherDays = await codexIndexer.run();          // Codex, for the dashboard's Claude / Codex / 合计 switch
    state.lastIndexed = Date.now();
  } finally { state.indexing = false; broadcast(); }
}

// ------------------------------------------------------------------ windows

function petBounds() {
  const w = Math.round(BASE.w * settings.scale), h = Math.round(BASE.h * settings.scale);
  const wa = screen.getPrimaryDisplay().workArea;
  let { x, y } = settings.petPos || { x: wa.x + wa.width - w - 24, y: wa.y + wa.height - h - 12 };
  const on = screen.getAllDisplays().some((d) => x > d.bounds.x - 40 && x < d.bounds.x + d.bounds.width && y > d.bounds.y - 40 && y < d.bounds.y + d.bounds.height);
  if (!on) { x = wa.x + wa.width - w - 24; y = wa.y + wa.height - h - 12; }
  return { x, y, width: w, height: h };
}

function webPrefs(extra = {}) {
  return { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, nodeIntegration: false, ...extra };
}

function createPet() {
  pet = new BrowserWindow({
    ...petBounds(), transparent: true, frame: false, resizable: false, maximizable: false, minimizable: false,
    alwaysOnTop: true, skipTaskbar: true, hasShadow: false, focusable: false, show: false, backgroundColor: '#00000000',
    webPreferences: webPrefs(),
  });
  pet.setAlwaysOnTop(true, 'floating');
  if (process.platform === 'darwin') pet.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  pet.setIgnoreMouseEvents(true, { forward: true });
  pet.webContents.setZoomFactor(settings.scale);
  pet.setOpacity(settings.opacity);
  pet.loadFile(path.join(__dirname, 'renderer', 'pet.html'));
  pet.webContents.on('did-finish-load', () => { pet.webContents.setZoomFactor(settings.scale); broadcast(); updateVisibility(); });
}

function createPanel() {
  panel = new BrowserWindow({
    width: 380, height: 720, frame: false, resizable: false, show: false, alwaysOnTop: true, skipTaskbar: true,
    maximizable: false, minimizable: false, fullscreenable: false,
    backgroundColor: nativeTheme.shouldUseDarkColors ? '#1f1f1f' : '#ffffff', webPreferences: webPrefs(),
  });
  panel.loadFile(path.join(__dirname, 'renderer', 'panel.html'));
  panel.on('blur', () => { if (!SNAPSHOT) panel.hide(); });
}

function positionPanel() {
  const pb = pet.getBounds();
  const [w, h] = panel.getSize();
  const wa = screen.getDisplayMatching(pb).workArea;
  let x = pb.x - w - 8;
  if (x < wa.x) x = pb.x + pb.width + 8;
  x = Math.min(Math.max(wa.x + 4, x), wa.x + wa.width - w - 4);
  const y = Math.min(Math.max(wa.y + 4, pb.y + pb.height - h), wa.y + wa.height - h - 4);
  panel.setPosition(Math.round(x), Math.round(y));
}

function openPanel() {
  if (!panel || panel.isDestroyed()) createPanel();
  if (panel.isVisible()) { panel.hide(); return; }
  refreshSessions(false);
  if (!state.lastUsageUpdate || Date.now() - state.lastUsageUpdate > 30e3) refreshUsage();
  positionPanel();
  panel.show(); panel.focus();
  broadcast();
}

function openSingle(ref, file, opts) {
  if (ref && !ref.isDestroyed()) { ref.show(); ref.focus(); return ref; }
  const w = new BrowserWindow({ show: false, autoHideMenuBar: true, backgroundColor: nativeTheme.shouldUseDarkColors ? '#1c1c1c' : '#f6f6f4', webPreferences: webPrefs(), ...opts });
  w.setMenu(null);
  w.loadFile(path.join(__dirname, 'renderer', file));
  w.once('ready-to-show', () => { if (!SNAPSHOT) w.show(); broadcast(); });
  w.webContents.on('did-finish-load', broadcast);
  return w;
}
function openDashboard() { if (panel) panel.hide(); refreshIndex(); dashboard = openSingle(dashboard, 'dashboard.html', { width: 900, height: 900, minWidth: 760, minHeight: 600, title: 'Claude Code 用量统计' }); }
function openSettings() { if (panel) panel.hide(); settingsWin = openSingle(settingsWin, 'settings.html', { width: 480, height: 700, resizable: false, title: 'Claude大小姐 设置' }); }

function openLogin(which) {
  if (panel) panel.hide();
  if (logins[which] && !logins[which].isDestroyed()) { logins[which].focus(); return; }
  if (which === 'second' && !settings.hasSecondary) { settings.hasSecondary = true; saveSettings(); }
  const web = which === 'second' ? secondaryWeb : primaryWeb;
  const w = new BrowserWindow({ width: 480, height: 760, autoHideMenuBar: true,
    title: which === 'second' ? '登录另一个 claude.ai 账号 —— 只读取用量' : '登录 claude.ai —— 大小姐只读取用量',
    webPreferences: { partition: web.partition, contextIsolation: true } });
  w.setMenu(null);
  w.webContents.setUserAgent(CHROME_UA);
  w.webContents.setWindowOpenHandler(({ url }) => { w.loadURL(url); return { action: 'deny' }; });
  w.loadURL('https://claude.ai/login');
  const poll = setInterval(() => { web.loaded = false; which === 'second' ? refreshSecondary() : refreshUsage(); }, 4000);
  w.on('closed', () => { clearInterval(poll); logins[which] = null; });
  logins[which] = w;
}

function openSession(id) {
  const s = state.sessions.find((x) => x.id === id);
  if (!s) return;
  if (panel) panel.hide();
  let url = null;
  if (s.hostSessionId && s.hostSessionId.startsWith('local_')) {
    url = `claude://code/continue?session=${encodeURIComponent(s.hostSessionId)}&source=desktop_action`;
  } else if (s.bridgeSessionId && /^(session|cse)_/.test(s.bridgeSessionId)) {
    url = `claude://code/${s.bridgeSessionId}`;
  }
  if (url) shell.openExternal(url).catch(() => s.cwd && shell.openPath(s.cwd));
  else if (s.cwd) shell.openPath(s.cwd);
}

// ------------------------------------------------------------------ only over Claude

function ownWindowFocused() { return BrowserWindow.getAllWindows().some((w) => !w.isDestroyed() && w.isFocused()); }
function petVisible() { return pet && !pet.isDestroyed() && pet.isVisible(); }
function updateVisibility() {
  if (!pet || pet.isDestroyed() || SNAPSHOT) return;
  const fg = foreground?.current || { known: false };
  let show = true;
  if (Date.now() < forceShowUntil) show = true;
  else if (settings.onlyWithClaude && fg.known) {
    const ours = ['claudeusagepet', 'electron', app.getName().toLowerCase()].includes(fg.name);
    show = CLAUDE_PROCS.includes(fg.name) || ours || ownWindowFocused();
  }
  if (show && settings.hideInFullscreen && fg.fullscreen && CLAUDE_PROCS.includes(fg.name)) show = false;
  if (show && !pet.isVisible()) pet.showInactive();
  else if (!show && pet.isVisible()) { pet.hide(); if (panel && panel.isVisible() && !panel.isFocused()) panel.hide(); }
}

// ------------------------------------------------------------------ menus & tray

function focusItems() {
  if (state.focusEnd > Date.now()) return [{ label: `结束专注（还剩 ${mmss(state.focusEnd - Date.now())}）`, click: stopFocus }];
  if (state.restEnd > Date.now()) return [{ label: `跳过休息（还剩 ${mmss(state.restEnd - Date.now())}）`, click: stopFocus },
    { label: `再专注 ${settings.focusMinutes} 分钟`, click: startFocus }];
  return [{ label: `🍅 开始专注 ${settings.focusMinutes} 分钟`, click: startFocus }];
}
function menuTemplate() {
  return [
    ...(hasV3() ? [
      { label: '形象：表情头像', type: 'radio', checked: settings.figure !== 'v3', click: () => setSetting('figure', 'stickers') },
      { label: '形象：v3 小人', type: 'radio', checked: settings.figure === 'v3', click: () => setSetting('figure', 'v3') },
      { type: 'separator' }] : []),
    { label: '查看用量和任务', click: openPanel },
    { label: '用量统计…', click: openDashboard },
    { label: '立即刷新', click: () => { refreshUsage(); refreshPeers(); say('刷新好啦'); } },
    { type: 'separator' },
    ...focusItems(),
    { type: 'separator' },
    { label: '登录 / 切换 claude.ai 账号…', click: () => openLogin('main') },
    { label: '退出 claude.ai 登录', click: async () => { await primaryWeb.clear(); state.usage = null; refreshUsage(); say('已退出 claude.ai 登录'); } },
    { label: settings.hasSecondary ? '重新登录另一个账号…' : '添加另一个账号…', click: () => openLogin('second') },
    ...(settings.hasSecondary ? [{ label: '移除另一个账号', click: async () => {
      settings.hasSecondary = false; saveSettings(); await secondaryWeb.clear(); state.secondary = null; broadcast(); say('已移除另一个账号');
    } }] : []),
    { type: 'separator' },
    { label: '设置…', click: openSettings },
    { label: '开机自动启动', type: 'checkbox', checked: settings.launchAtLogin, click: (i) => setSetting('launchAtLogin', i.checked) },
    { label: '回到屏幕右下角', click: () => { settings.petPos = null; saveSettings(); pet.setBounds(petBounds()); } },
    { type: 'separator' },
    { label: '素材署名…', click: () => shell.openExternal('https://github.com/opsCar/claude-daxiaojie-assets') },
    { label: '退出大小姐', click: farewell },
  ];
}

function createTray() {
  const img = nativeImage.createFromPath(asset('icon.png')).resize({ width: 16, height: 16 });
  tray = new Tray(img);
  tray.setToolTip('Claude大小姐');
  const rebuild = () => tray.setContextMenu(Menu.buildFromTemplate([
    { label: '显示桌宠', click: () => { pet.showInactive(); } },
    ...menuTemplate(),
  ]));
  rebuild();
  tray.on('click', openPanel);
  tray.on('right-click', rebuild);
}

function farewell() {
  if (panel) panel.hide();
  react('farewell', 3, '下次见～');
  setTimeout(() => app.exit(0), 1200);
}

function setSetting(key, value) {
  if (!(key in DEFAULTS)) return;
  if (typeof DEFAULTS[key] === 'number' && typeof value === 'string') value = +value;
  settings[key] = value;
  saveSettings();
  if (key === 'scale' && pet) { pet.setBounds(petBounds()); pet.webContents.setZoomFactor(value); }
  if (key === 'opacity' && pet) pet.setOpacity(value);
  if (key === 'launchAtLogin') app.setLoginItemSettings({ openAtLogin: !!value });
  if (key === 'onlyWithClaude' || key === 'hideInFullscreen') updateVisibility();
  if (key === 'figure') { v3Rotate(true); react('greet', 3, value === 'v3' ? '换成 v3 小人啦～' : '换回表情头像啦～'); }
  broadcast();
}

// ------------------------------------------------------------------ IPC

ipcMain.on('pet-mouse', (_e, interactive) => { if (pet) pet.setIgnoreMouseEvents(!interactive, { forward: true }); });
ipcMain.on('pet-click', () => { if (!panel || !panel.isVisible()) react('clicked', 4); openPanel(); });
ipcMain.on('pet-drag', (_e, { dx, dy }) => { if (!pet) return; const [x, y] = pet.getPosition(); pet.setPosition(x + dx, y + dy); });
ipcMain.on('pet-drag-end', () => { if (!pet) return; const [x, y] = pet.getPosition(); settings.petPos = { x, y }; saveSettings(); if (panel) panel.hide(); });
ipcMain.on('pet-menu', () => Menu.buildFromTemplate(menuTemplate()).popup({ window: pet }));
ipcMain.on('pet-dblclick', () => { if (panel) panel.hide(); react('hop', 2.4, Math.random() < 0.5 ? banter.line('claude', 'hop') : null); });
ipcMain.on('pet-petted', () => {
  react('petted', 4, banter.line('claude', 'petted') || '诶嘿嘿…');
});
ipcMain.on('panel-size', (_e, h) => {
  if (!panel) return;
  const wa = screen.getDisplayMatching(panel.getBounds()).workArea;
  panel.setSize(380, Math.min(Math.ceil(h), Math.floor(wa.height * 0.92)));
  if (panel.isVisible()) positionPanel();
});
ipcMain.handle('act', async (_e, name, ...a) => {
  switch (name) {
    case 'refresh': return refreshUsage();
    case 'refreshIndex': return refreshIndex();
    case 'login': return openLogin('main');
    case 'loginSecond': return openLogin('second');
    case 'openSession': return openSession(a[0]);
    case 'dashboard': return openDashboard();
    case 'settings': return openSettings();
    case 'credits': return shell.openExternal('https://github.com/opsCar/claude-daxiaojie-assets');
    case 'quit': return farewell();
    case 'setSetting': return setSetting(a[0], a[1]);
    case 'togglePeers': return setSetting('peersExpanded', !settings.peersExpanded);
    case 'openPeer': return shell.openExternal({ codex: 'https://chatgpt.com/codex', grok: 'grokbot://', deepseek: 'https://platform.deepseek.com/usage' }[a[0]] || 'https://claude.ai');
    case 'startFocus': return startFocus();
    case 'stopFocus': return stopFocus();
    case 'resetSettings': for (const k of ['scale', 'opacity', 'rotateSeconds', 'chatter', 'onlyWithClaude', 'hideInFullscreen', 'alertWaiting', 'notifications', 'focusMinutes', 'sitReminder', 'nightReminder', 'chatterSeconds', 'petChat']) setSetting(k, DEFAULTS[k]); return;
    case 'state': return payload();
    default: return null;
  }
});

// ------------------------------------------------------------------ demo data & snapshots

function demoData() {
  const now = Date.now();
  const mk = (name, status, folder, ago, wait, done, total, step) => decorate({
    id: name, pid: 1, name, status, cwd: `C:\\Users\\demo\\${folder}`, entrypoint: 'claude-desktop',
    startedAt: now - ago - 600e3, statusSince: now - ago, waitingFor: wait, hostSessionId: null, bridgeSessionId: null,
    progress: { done, total, current: step },
  });
  state.sessions = [
    mk('重构登录模块', 'waiting', 'web-app', 90e3, 'permission prompt', 2, 5, '运行数据库迁移'),
    mk('写周报', 'busy', 'notes', 320e3, null, 3, 4, '整理本周完成的事项'),
    mk('修复图表显示问题', 'idle', 'dashboard', 1500e3, null, 4, 4, null),
    mk('翻译 README', 'idle', 'docs', 5400e3, null, 2, 2, null),
  ];
  const w = (u, s) => ({ utilization: u, resetsAt: now + s * 1000 });
  state.usage = { fiveHour: w(63, 7800), sevenDay: w(28, 340000), extras: [], account: 'demo@example.com', plan: 'Max', source: '演示数据' };
  state.secondary = { fiveHour: w(18, 12000), sevenDay: w(41, 200000), extras: [], account: 'other@example.com', plan: 'Pro', source: '另一个账号' };
  settings.hasSecondary = true;
  state.peers = [
    { provider: 'codex', title: 'ChatGPT · Codex', plan: 'Plus', observedAt: now - 60e3,
      windows: [{ label: '5 小时', utilization: 22, resetsAt: now + 9000e3 }, { label: '每周', utilization: 47, resetsAt: now + 300000e3 }] },
    { provider: 'grok', title: 'Grok Bot', plan: 'Premium', observedAt: now - 600e3, windows: [{ label: '每周', utilization: 43, resetsAt: now + 370000e3 }] },
    { provider: 'deepseek', title: 'DeepSeek', windows: [], observedAt: now - 120e3, short: 'DeepSeek ¥16.96',
      lines: ['余额 ¥16.96', '今天花了 ¥1.04 · 近 7 天 ¥9.21', '按近 7 天的速度约还能用 12 天'] },
  ];
  if (args.includes('--expand')) settings.peersExpanded = true;
  if (args.includes('--v3')) settings.figure = 'v3';
  if (args.includes('--focus')) state.focusEnd = now + (23 * 60 + 12) * 1000;
  state.lastUsageUpdate = now; state.lastIndexed = now;
  history.loadDemo('demo@example.com', 63);
  let seed = 42;
  const rnd = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
  const days = {};
  for (let i = 0; i < 200; i++) {
    const d = new Date(now - i * 86400e3);
    const busyDay = d.getDay() !== 0 && d.getDay() !== 6;
    if (rnd() < (busyDay ? 0.15 : 0.55)) continue;
    const sc = (busyDay ? 1 : 0.4) * (0.3 + rnd() * 1.4) * (i < 60 ? 1 : 0.6);
    const tk = { input: Math.round(2000 * sc), output: Math.round(180000 * sc), cacheWrite: Math.round(1.8e6 * sc), cacheRead: Math.round(6e7 * sc) };
    const projects = {};
    for (const [p, share] of [['web-app', 0.45], ['dashboard', 0.25], ['notes', 0.18], ['docs', 0.12]]) {
      projects[p] = { tokens: { input: 0, output: Math.round(tk.output * share), cacheWrite: Math.round(tk.cacheWrite * share), cacheRead: Math.round(tk.cacheRead * share) }, activeSeconds: 9000 * sc * share, messages: 0 };
    }
    days[dayKey(d.getTime())] = { tokens: tk, messages: Math.round(120 * sc), activeSeconds: 9000 * sc,
      sessions: Array.from({ length: Math.max(1, Math.round(4 * sc)) }, (_, k) => `s${i}-${k}`),
      models: { 'claude-opus-5-5': tk, 'claude-haiku-5-5': { input: 0, output: Math.round(9000 * sc), cacheWrite: 0, cacheRead: Math.round(9e5 * sc) } }, projects };
  }
  state.days = days;
  state.otherDays = Object.fromEntries(Object.entries(days).map(([k, d]) => [k, { ...d, tokens: { input: d.tokens.input * 40, output: Math.round(d.tokens.output / 3), cacheWrite: 0, cacheRead: Math.round(d.tokens.cacheRead / 6) },
    activeSeconds: d.activeSeconds / 2, models: { 'gpt-6.1': { input: d.tokens.input * 40, output: Math.round(d.tokens.output / 3), cacheWrite: 0, cacheRead: Math.round(d.tokens.cacheRead / 6) } } }]));
  state.face = 'ojou_laugh';
  state.bubble = '本小姐驾到～ 点我看用量';
}

async function snapshots() {
  fs.mkdirSync(SNAPSHOT, { recursive: true });
  const shot = async (win, name) => {
    await new Promise((r) => setTimeout(r, 900));
    const img = await win.webContents.capturePage(undefined, { stayHidden: true });
    fs.writeFileSync(path.join(SNAPSHOT, name), img.toPNG());
  };
  // Every window stays hidden: capturePage can render hidden pages.
  createPanel();
  dashboard = openSingle(null, 'dashboard.html', { width: 900, height: 1250, title: 'dash' });
  settingsWin = openSingle(null, 'settings.html', { width: 480, height: 700, title: 'settings' });
  for (const theme of ['light', 'dark']) {
    nativeTheme.themeSource = theme;
    broadcast();
    await shot(pet, `pet-${theme}.png`);
    await shot(panel, `panel-${theme}.png`);
    await shot(dashboard, `dashboard-${theme}.png`);
    await shot(settingsWin, `settings-${theme}.png`);
  }
  fs.writeFileSync(path.join(SNAPSHOT, 'state.json'), JSON.stringify({ face: state.face, level: level(), sessions: state.sessions.length,
    days: Object.keys(state.days).length, petTask: taskText(), pill: pillText() }, null, 1));
  app.exit(0);
}

// ------------------------------------------------------------------ start

app.on('second-instance', () => openPanel());
app.on('window-all-closed', (e) => e.preventDefault?.());

app.whenReady().then(async () => {
  if (process.platform === 'darwin' && app.dock) app.dock.hide();
  if (process.platform === 'win32') app.setAppUserModelId('io.github.jayden-dong411.claude-usage-pet');   // needed for toasts
  loadSettings();
  const ud = app.getPath('userData');
  history = new UsageHistory(path.join(ud, 'usage-history.jsonl'));
  indexer = new UsageIndexer(path.join(ud, 'usage-index.json'));
  codexIndexer = new CodexIndexer(path.join(ud, 'codex-index.json'));
  tracker = new ProgressTracker();
  primaryWeb = new WebFetcher('persist:claude-main');
  secondaryWeb = new WebFetcher('persist:claude-second');
  if (DEMO) demoData();

  createPet();
  if (SNAPSHOT) {
    pet.webContents.once('did-finish-load', () => setTimeout(snapshots, 600));
    if (!DEMO) { refreshSessions(false); refreshIndex(); }
    return;
  }
  createTray();
  createPanel();
  foreground = new Foreground(() => updateVisibility());
  foreground.start();
  nativeTheme.on('updated', broadcast);
  if (settings.launchAtLogin) app.setLoginItemSettings({ openAtLogin: true });

  refreshSessions(false);
  refreshUsage();
  refreshIndex();
  refreshPeers();
  react('greet', 5, '本小姐驾到～ 点我看用量');
  setInterval(refreshPeers, 60e3);
  setInterval(tickFocus, 1000);
  setInterval(tickWellness, 2000);
  setInterval(() => refreshSessions(true), 3000);
  setInterval(refreshUsage, 90e3);
  setInterval(refreshIndex, 180e3);
  setInterval(() => { tickFace(); tickChatter(); updateVisibility(); }, 2000);
  duetLink = new DuetLink('claude', duetLines, canChat);
  duetLink.start();
  app.on('before-quit', () => duetLink.stop());
  pet.showInactive();
});
