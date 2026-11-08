// GPT龙娘 · ChatGPT / Codex 额度桌宠 — Windows (Electron) edition. Mirrors ../companions/ChatGPTPet.
// Shares the renderer pages and helpers with the Claude大小姐 Windows app (main.js); always uses the v3 look
// (the GPT龙娘 sprite sheet has no license to redistribute).
const { app, BrowserWindow, ipcMain, Menu, Tray, nativeImage, nativeTheme, screen, shell, Notification, powerMonitor, net } = require('electron');
const fs = require('fs');
const path = require('path');
const { CodexReader, CodexIndexer } = require('./lib/codex');
const { UsageHistory } = require('./lib/history');
const { Foreground } = require('./lib/foreground');
const { dayKey, UsageIndexer } = require('./lib/indexer');
const banter = require('./lib/banter');
const { DuetLink } = require('./lib/duet');
const { readPeers, codexLive, codexLogs, codexError, writePeer } = require('./lib/peers');

const NAME = 'GPT龙娘';
app.setName('GPTDragonPet');
app.setPath('userData', path.join(app.getPath('appData'), 'GPTDragonPet'));   // never share Claude大小姐's settings
const args = process.argv.slice(1);
const snapIdx = args.indexOf('--snapshot');
const SNAPSHOT = snapIdx >= 0 ? path.resolve(args[snapIdx + 1] || 'snapshots') : null;
const DEMO = args.includes('--demo');

if (!SNAPSHOT && !app.requestSingleInstanceLock()) app.quit();

const ATTRIBUTION = 'v3 小人：GPT娘（白龙娘）设定图里的 8 种表情，来自 github.com/lmy414/ai-chan-sheets，角色设定 ZipZipPipe，CC BY-NC-SA 4.0；去掉了白底并缩小了尺寸。';
const LEVEL_NAMES = ['暂无数据', '额度充足', '状态良好', '有点紧张', '快用完了'];
const HOST_PROCS = ['chatgpt', 'codex'];               // ChatGPT.exe / Codex.exe
const BASE = { w: 220, h: 300 };
const asset = (...p) => path.join(__dirname, 'assets', ...p);
const V3DIR = 'gpt-v3';

// ------------------------------------------------------------------ settings

const DEFAULTS = { scale: 1, opacity: 1, rotateSeconds: 12, chatter: true, onlyWithClaude: true,
  hideInFullscreen: false, alertWaiting: true, notifications: true, launchAtLogin: false, petPos: null,
  figure: 'v3', peersExpanded: false, focusMinutes: 25, sitReminder: true, nightReminder: true, chatterSeconds: 30, petChat: true };
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
  face: 'smile', bubble: null, v3face: 'smile', hopAt: 0, shakeAt: 0,
  peers: [], codexError: null, focusEnd: 0, restEnd: 0,
};
let history, indexer, claudeIndexer, duetLink, reader, foreground;
let pet, panel, dashboard, settingsWin, tray;
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
  return {
    ...state,
    platform: process.platform,
    level: level(), levelName: LEVEL_NAMES[level()],
    settings: { ...settings, hasSecondary: false }, attribution: ATTRIBUTION,
    forecast5: history.forecast('live', true, state.usage?.fiveHour),
    forecast7: history.forecast('live', false, state.usage?.sevenDay),
    spark: history.fiveHourSeries('live', state.usage?.fiveHour),
    petTask: taskText(), petPill: pillText(), alert: state.sessions.some((s) => s.isWaiting),
    v3: true, hasV3: false, hasStickers: false, v3dir: V3DIR, ownSource: 'codex', dashSource: args.includes('--dash-all') ? 'all' : null,
    petName: NAME, hostName: 'ChatGPT', canAddAccount: false, sessionNoun: '线程',
    emptyTasks: '现在没有进行中的 Codex 线程，龙娘在晒太阳～',
    attrShort: 'v3 小人：GPT娘（白龙娘）· ai-chan-sheets · 角色设定 ZipZipPipe · CC BY-NC-SA 4.0',
    dashTitle: 'Codex 用量统计',
    dashNote: '数据来自这台电脑上 ~/.codex/sessions 里的 Codex 会话记录（ChatGPT 桌面版和 Codex 命令行都算），不含网页版、手机和云端任务。使用时长按同一线程里相邻两条记录间隔不超过 5 分钟累计。',
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
      tray.setToolTip(`${NAME} · 5h ${f ? Math.round(f.utilization) + '%' : '—'}` + (p.focusing || p.resting ? ` · ${p.petPill}` : ''));
    }
  });
}

const clip = (s, n) => (s.length > n ? s.slice(0, n - 1) + '…' : s);
const mmss = (ms) => { const s = Math.max(0, Math.ceil(ms / 1000)); return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`; };
function pillText() {
  if (state.focusEnd > Date.now()) return `🍅 专注 ${mmss(state.focusEnd - Date.now())}`;
  if (state.restEnd > Date.now()) return `☕ 休息 ${mmss(state.restEnd - Date.now())}`;
  const u = state.usage;
  if (!u) return '5h —  ·  周 —';
  const f = (w) => (w ? `${Math.round(w.utilization)}%` : '—');
  return `5h ${f(u.fiveHour)}  ·  周 ${f(u.sevenDay)}`;
}
function fmtDuration(ms) {
  const s = Math.max(0, Math.floor(ms / 1000)), d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
  return d ? `${d}天${h}小时` : h ? `${h}小时${m}分` : m ? `${m}分钟` : '不到1分钟';
}
function taskText() {
  const all = [...state.sessions.filter((s) => s.isWaiting), ...state.sessions.filter((s) => s.isBusy)];
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

// ------------------------------------------------------------------ expressions (v3 only)

const V3_POOLS = { idle: ['smile', 'giggle', 'smile', 'shy', 'giggle', 'calm'], working: ['smile', 'giggle', 'serious', 'smile', 'calm'],
  waiting: ['surprised', 'smile', 'shy'], strained: ['pout', 'smile', 'surprised'], crushed: ['aggrieved', 'pout', 'surprised'], sleepy: ['giggle', 'calm', 'shy'] };
const V3_REACT = { taskDone: 'giggle', hop: 'giggle', petted: 'shy', oops: 'aggrieved', needsYou: 'surprised', taskStarted: 'serious',
  greet: 'smile', clicked: 'smile', care: 'smile', night: 'calm', farewell: 'smile' };
let reactionUntil = 0, v3Next = 0, nextChatter = Date.now() + 10e3, lastNudge = 0, bubbleTimer = null;

function mood() { return state.usage ? ['noData', 'breezy', 'calm', 'strained', 'crushed'][level()] : 'noData'; }
function v3State() {
  if (settings.alertWaiting && state.sessions.some((s) => s.isWaiting)) return 'waiting';
  if (state.sessions.some((s) => s.isBusy) || state.focusEnd > Date.now()) return 'working';
  const lv = level();
  if (lv === 3) return 'strained';
  if (lv === 4) return 'crushed';
  const h = new Date().getHours();
  return h >= 1 && h < 6 ? 'sleepy' : 'idle';
}
function v3Rotate() {
  const pool = V3_POOLS[v3State()].filter((f) => f !== state.v3face);
  state.v3face = pool[Math.floor(Math.random() * pool.length)] || 'smile';
  v3Next = Date.now() + (6 + Math.random() * 6) * 1000;
}
function say(text, seconds = 5) {
  state.bubble = text;
  clearTimeout(bubbleTimer);
  bubbleTimer = setTimeout(() => { state.bubble = null; broadcast(); }, seconds * 1000);
  broadcast();
}
function react(kind, seconds = 5, text = null) {
  state.v3face = V3_REACT[kind] || 'smile';
  if (kind === 'hop' || kind === 'taskDone') state.hopAt = Date.now();
  if (kind === 'petted' || kind === 'oops') state.shakeAt = Date.now();
  reactionUntil = v3Next = Date.now() + seconds * 1000;
  if (text) say(text); else broadcast();
}
const pickLine = (k) => banter.line('codex', k);
function tickFace() {
  const now = Date.now();
  if (now < reactionUntil) return;
  const w = state.sessions.find((s) => s.isWaiting);
  if (settings.alertWaiting && w && now - lastNudge > 180e3) {
    lastNudge = now;
    react('needsYou', 6, `「${w.name}」还在${w.waitingLabel}哦`);
    notify(NAME, `「${w.name}」还在${w.waitingLabel}`);
    return;
  }
  if (now >= v3Next) { v3Rotate(); broadcast(); }
  // Says something on her own every `chatterSeconds` (±30%).
  if (now >= nextChatter) {
    nextChatter = now + settings.chatterSeconds * (0.7 + Math.random() * 0.6) * 1000;
    if (settings.chatter && !state.bubble && !state.focusEnd) {
      const moods = [mood()];
      if (state.sessions.some((s) => s.isBusy)) moods.push('working');
      if (state.sessions.some((s) => s.isWaiting)) moods.push('needsYou');
      const h = new Date().getHours();
      if (h >= 1 && h < 6) moods.push('night');
      const u = state.usage, pc = (w) => (w ? `${Math.round(w.utilization)}%` : undefined);
      const l = banter.chatter('codex', moods, { five: pc(u?.fiveHour), week: pc(u?.sevenDay) });
      if (l) say(l, 4.5);
    }
  }
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
  const n = new Notification({ title, body, icon: asset('gpt-icon.png'), silent: false });
  n.on('click', () => openPanel());
  n.show();
}

// ------------------------------------------------------------------ data refresh

function refreshSessions(notifyChanges) {
  const list = DEMO ? state.sessions : reader.sessions();
  for (const s of list) { s.entrypoint = 'codex'; s.openTitle = '在 ChatGPT 里打开这个线程'; }
  if (notifyChanges && prevStatus.size) {
    for (const s of list) {
      const prev = prevStatus.get(s.id);
      if ((prev === 'busy' || prev === 'waiting') && s.status === 'idle') {
        react('taskDone', 5, `「${s.name}」完成了哦～`);
        notify(NAME, `「${s.name}」完成了`);
      }
      if (s.isWaiting && prev !== 'waiting' && settings.alertWaiting) {
        lastNudge = Date.now();
        react('needsYou', 8, `「${s.name}」${s.waitingLabel}～`);
        notify(NAME, `「${s.name}」${s.waitingLabel}`);
      }
    }
    const started = list.find((s) => s.isBusy && !['busy', 'waiting'].includes(prevStatus.get(s.id)));
    if (started) react('taskStarted', 5, `「${started.name}」开工！`);
  }
  prevStatus = new Map(list.map((s) => [s.id, s.status]));
  state.sessions = list;
  broadcast();
}

/** Live limits from the ChatGPT account (the Codex login), falling back to the newest numbers in the local logs. */
async function refreshUsage() {
  if (DEMO || state.loadingUsage) return;
  state.loadingUsage = true; broadcast();
  try {
    const live = await codexLive((url, opts) => net.fetch(url, opts), 50e3);
    const c = live || codexLogs();
    state.codexError = codexError();
    if (!c) {
      state.usage = null;
      state.usageError = state.codexError || '还没读到 Codex 的额度：在这台电脑上登录并用一次 Codex（ChatGPT 桌面版或 codex 命令行）就好。';
      return;
    }
    const win = (label) => { const w = c.windows.find((x) => x.label === label); return w ? { utilization: w.utilization, resetsAt: w.resetsAt } : null; };
    state.usage = { fiveHour: win('5 小时'), sevenDay: win('每周'), extras: [], plan: c.plan, account: 'ChatGPT 账号',
      source: live ? 'ChatGPT 账号实时额度' : '本机 Codex 日志（实时查询失败）' };
    state.usageError = live ? null : `实时查询失败：${state.codexError || '未知原因'}；先显示本机日志里的数字`;
    state.lastUsageUpdate = Date.now();
    if (live) { history.record({ ...state.usage, account: 'live' }); writePeer(live); }
  } finally { state.loadingUsage = false; broadcast(); }
}

async function refreshPeers() {
  if (DEMO) return;
  state.peers = await readPeers((url, opts) => net.fetch(url, opts), 'codex');
  broadcast();
}

async function refreshIndex() {
  if (DEMO || indexer.running) return;
  state.indexing = true; broadcast();
  try {
    state.days = await indexer.run((p) => { state.indexProgress = p; broadcast(); });
    state.otherDays = await claudeIndexer.run();         // Claude Code, for the dashboard's Claude / Codex / 合计 switch
    state.lastIndexed = Date.now();
  } finally { state.indexing = false; broadcast(); }
}

// ------------------------------------------------------------------ focus timer & wellness reminders

let forceShowUntil = 0, streakStart = 0, nextSit = Infinity, lastActive = 0, lastNight = 0;
function startFocus() {
  state.restEnd = 0; state.focusEnd = Date.now() + settings.focusMinutes * 60e3; streakStart = 0;
  react('taskStarted', 4, `专注 ${settings.focusMinutes} 分钟，开始！我帮你看着时间～`);
}
function stopFocus() {
  const was = state.focusEnd > Date.now();
  state.focusEnd = 0; state.restEnd = 0;
  say(was ? '好吧，这次就先到这里～' : '那就继续加油吧！');
}
function remind(kind, text, title) {
  forceShowUntil = Date.now() + 12e3;
  updateVisibility();
  react(kind, 12, null);
  say(text, 12);
  if (settings.notifications && Notification.isSupported()) {
    const n = new Notification({ title, body: text, icon: asset('gpt-icon.png') });
    n.on('click', () => openPanel());
    n.show();
  }
}
function tickFocus() {
  const now = Date.now();
  if (state.focusEnd && now >= state.focusEnd) {
    state.focusEnd = 0; state.restEnd = now + 5 * 60e3;
    remind('taskDone', `专注 ${settings.focusMinutes} 分钟完成！起来活动 5 分钟、喝口水吧～`, '🍅 专注完成');
  } else if (state.restEnd && now >= state.restEnd) {
    state.restEnd = 0; streakStart = 0;
    remind('greet', '休息结束～ 要再来一轮专注的话右键我哦', '☕ 休息结束');
  }
  if (state.focusEnd || state.restEnd) broadcast();
}
function tickWellness() {
  const now = Date.now();
  const idle = powerMonitor.getSystemIdleTime();
  const fg = foreground?.current || { known: false };
  if (idle < 120 && (!fg.known || HOST_PROCS.includes(fg.name))) lastActive = now;
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

// ------------------------------------------------------------------ windows

function petBounds() {
  const w = Math.round(BASE.w * settings.scale), h = Math.round(BASE.h * settings.scale);
  const wa = screen.getPrimaryDisplay().workArea;
  // Default spot: left of where Claude大小姐 sits, so the two don't overlap.
  const def = { x: wa.x + wa.width - 2 * w - 36, y: wa.y + wa.height - h - 12 };
  let { x, y } = settings.petPos || def;
  const on = screen.getAllDisplays().some((d) => x > d.bounds.x - 40 && x < d.bounds.x + d.bounds.width && y > d.bounds.y - 40 && y < d.bounds.y + d.bounds.height);
  if (!on) ({ x, y } = def);
  return { x, y, width: w, height: h };
}
const webPrefs = () => ({ preload: path.join(__dirname, 'preload.js'), contextIsolation: true, nodeIntegration: false });

function createPet() {
  pet = new BrowserWindow({
    ...petBounds(), transparent: true, frame: false, resizable: false, maximizable: false, minimizable: false,
    alwaysOnTop: true, skipTaskbar: true, hasShadow: false, focusable: false, show: false, backgroundColor: '#00000000',
    webPreferences: webPrefs(),
  });
  pet.setAlwaysOnTop(true, 'floating');
  if (process.platform === 'darwin') pet.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  pet.setIgnoreMouseEvents(true, { forward: true });
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
function openDashboard() { if (panel) panel.hide(); refreshIndex(); dashboard = openSingle(dashboard, 'dashboard.html', { width: 900, height: 900, minWidth: 760, minHeight: 600, title: 'Codex 用量统计' }); }
function openSettings() { if (panel) panel.hide(); settingsWin = openSingle(settingsWin, 'settings.html', { width: 480, height: 660, resizable: false, title: `${NAME} 设置` }); }

/** Opens the thread in the ChatGPT app (codex://threads/<id>), or its folder. */
function openSession(id) {
  const s = state.sessions.find((x) => x.id === id);
  if (!s) return;
  if (panel) panel.hide();
  shell.openExternal(`codex://threads/${encodeURIComponent(s.id)}`).catch(() => s.cwd && shell.openPath(s.cwd));
}

// ------------------------------------------------------------------ only over ChatGPT

function ownWindowFocused() { return BrowserWindow.getAllWindows().some((w) => !w.isDestroyed() && w.isFocused()); }
function petVisible() { return pet && !pet.isDestroyed() && pet.isVisible(); }
function updateVisibility() {
  if (!pet || pet.isDestroyed() || SNAPSHOT) return;
  const fg = foreground?.current || { known: false };
  let show = true;
  if (Date.now() < forceShowUntil) show = true;
  else if (settings.onlyWithClaude && fg.known) {
    const ours = ['gptdragonpet', 'electron', app.getName().toLowerCase()].includes(fg.name);
    show = HOST_PROCS.includes(fg.name) || ours || ownWindowFocused();
  }
  if (show && settings.hideInFullscreen && fg.fullscreen && HOST_PROCS.includes(fg.name)) show = false;
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
    { label: '查看额度和线程', click: openPanel },
    { label: 'Codex 用量统计…', click: openDashboard },
    { label: '立即刷新', click: () => { refreshUsage(); refreshPeers(); say('刷新好啦'); } },
    { type: 'separator' },
    ...focusItems(),
    { type: 'separator' },
    { label: '打开 ChatGPT 用量页', click: () => shell.openExternal('https://chatgpt.com/codex/settings/usage') },
    { label: '设置…', click: openSettings },
    { label: '开机自动启动', type: 'checkbox', checked: settings.launchAtLogin, click: (i) => setSetting('launchAtLogin', i.checked) },
    { label: '回到默认位置', click: () => { settings.petPos = null; saveSettings(); pet.setBounds(petBounds()); } },
    { type: 'separator' },
    { label: '素材署名…', click: () => shell.openExternal('https://github.com/lmy414/ai-chan-sheets') },
    { label: `退出${NAME}`, click: farewell },
  ];
}
function createTray() {
  tray = new Tray(nativeImage.createFromPath(asset('gpt-icon.png')).resize({ width: 16, height: 16 }));
  tray.setToolTip(NAME);
  const rebuild = () => tray.setContextMenu(Menu.buildFromTemplate([{ label: '显示桌宠', click: () => pet.showInactive() }, ...menuTemplate()]));
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
  if (!(key in DEFAULTS) || key === 'figure') return;
  if (typeof DEFAULTS[key] === 'number' && typeof value === 'string') value = +value;
  settings[key] = value;
  saveSettings();
  if (key === 'scale' && pet) { pet.setBounds(petBounds()); pet.webContents.setZoomFactor(value); }
  if (key === 'opacity' && pet) pet.setOpacity(value);
  if (key === 'launchAtLogin') app.setLoginItemSettings({ openAtLogin: !!value });
  if (key === 'onlyWithClaude' || key === 'hideInFullscreen') updateVisibility();
  broadcast();
}

// ------------------------------------------------------------------ IPC

ipcMain.on('pet-mouse', (_e, interactive) => { if (pet) pet.setIgnoreMouseEvents(!interactive, { forward: true }); });
ipcMain.on('pet-click', () => { if (!panel || !panel.isVisible()) react('clicked', 4); openPanel(); });
ipcMain.on('pet-drag', (_e, { dx, dy }) => { if (!pet) return; const [x, y] = pet.getPosition(); pet.setPosition(x + dx, y + dy); });
ipcMain.on('pet-drag-end', () => { if (!pet) return; const [x, y] = pet.getPosition(); settings.petPos = { x, y }; saveSettings(); if (panel) panel.hide(); });
ipcMain.on('pet-menu', () => Menu.buildFromTemplate(menuTemplate()).popup({ window: pet }));
ipcMain.on('pet-dblclick', () => { if (panel) panel.hide(); react('hop', 2.4, Math.random() < 0.34 ? pickLine('hop') : null); });
ipcMain.on('pet-petted', () => react('petted', 4, pickLine('petted')));
ipcMain.on('panel-size', (_e, h) => {
  if (!panel) return;
  const wa = screen.getDisplayMatching(panel.getBounds()).workArea;
  panel.setSize(380, Math.min(Math.ceil(h), Math.floor(wa.height * 0.92)));
  if (panel.isVisible()) positionPanel();
});
ipcMain.handle('act', async (_e, name, ...a) => {
  switch (name) {
    case 'refresh': refreshPeers(); return refreshUsage();
    case 'refreshIndex': return refreshIndex();
    case 'openSession': return openSession(a[0]);
    case 'dashboard': return openDashboard();
    case 'settings': return openSettings();
    case 'credits': return shell.openExternal('https://github.com/lmy414/ai-chan-sheets');
    case 'quit': return farewell();
    case 'setSetting': return setSetting(a[0], a[1]);
    case 'togglePeers': return setSetting('peersExpanded', !settings.peersExpanded);
    case 'openPeer': return shell.openExternal({ claude: 'https://claude.ai/settings/usage', grok: 'grokbot://', deepseek: 'https://platform.deepseek.com/usage' }[a[0]] || 'https://chatgpt.com/codex');
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
  const s = (name, status, folder, ago, progress) => ({
    id: name, name, status, cwd: `C:\\Users\\demo\\${folder}`, model: 'gpt-6.1', statusSince: now - ago, progress,
    isBusy: status === 'busy', isWaiting: status === 'waiting', waitingLabel: '等你回复',
    statusLabel: status === 'busy' ? '进行中' : status === 'waiting' ? '等你回复' : '空闲', folderName: folder, entryLabel: 'gpt-6.1',
    entrypoint: 'codex', openTitle: '在 ChatGPT 里打开这个线程',
  });
  state.sessions = [
    s('整理会议纪要', 'waiting', 'notes', 60e3, null),
    s('重构支付模块', 'busy', 'shop', 240e3, { done: 2, total: 5, current: '补充单元测试' }),
    s('翻译产品文档', 'idle', 'docs', 2400e3, null),
  ];
  const w = (u, sec) => ({ utilization: u, resetsAt: now + sec * 1000 });
  state.usage = { fiveHour: w(47, 9000), sevenDay: w(22, 400000), extras: [], plan: 'Plus', account: 'ChatGPT 账号', source: '演示数据' };
  state.peers = [
    { provider: 'claude', title: 'Claude', plan: 'Max', observedAt: now - 90e3,
      windows: [{ label: '5 小时', utilization: 63, resetsAt: now + 7800e3 }, { label: '每周', utilization: 28, resetsAt: now + 340000e3 }] },
    { provider: 'grok', title: 'Grok Bot', plan: 'Premium', observedAt: now - 600e3, windows: [{ label: '每周', utilization: 43, resetsAt: now + 370000e3 }] },
    { provider: 'deepseek', title: 'DeepSeek', windows: [], observedAt: now - 120e3, short: 'DeepSeek ¥16.96',
      lines: ['余额 ¥16.96', '今天花了 ¥1.04 · 近 7 天 ¥9.21', '按近 7 天的速度约还能用 12 天'] },
  ];
  if (args.includes('--expand')) settings.peersExpanded = true;
  if (args.includes('--focus')) state.focusEnd = now + (23 * 60 + 12) * 1000;
  state.lastUsageUpdate = now; state.lastIndexed = now;
  history.loadDemo('live', 47);
  let seed = 7;
  const rnd = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
  const days = {};
  for (let i = 0; i < 160; i++) {
    const d = new Date(now - i * 86400e3);
    const busyDay = d.getDay() !== 0 && d.getDay() !== 6;
    if (rnd() < (busyDay ? 0.2 : 0.6)) continue;
    const sc = (busyDay ? 1 : 0.4) * (0.3 + rnd() * 1.4);
    const tk = { input: Math.round(300000 * sc), output: Math.round(40000 * sc), cacheWrite: 0, cacheRead: Math.round(3e6 * sc) };
    const projects = {};
    for (const [p, share] of [['shop', 0.5], ['docs', 0.3], ['notes', 0.2]]) {
      projects[p] = { tokens: { input: Math.round(tk.input * share), output: Math.round(tk.output * share), cacheWrite: 0, cacheRead: Math.round(tk.cacheRead * share) }, activeSeconds: 6480 * sc * share, messages: 0 };
    }
    days[dayKey(d.getTime())] = { tokens: tk, messages: Math.round(60 * sc), activeSeconds: 6480 * sc,
      sessions: Array.from({ length: Math.max(1, Math.round(3 * sc)) }, (_, k) => `s${i}-${k}`), models: { 'gpt-6.1': tk }, projects };
  }
  state.days = days;
  state.otherDays = Object.fromEntries(Object.entries(days).map(([k, d]) => [k, { ...d, tokens: { input: Math.round(d.tokens.input / 100), output: d.tokens.output * 3, cacheWrite: d.tokens.cacheRead / 2, cacheRead: d.tokens.cacheRead * 8 },
    activeSeconds: d.activeSeconds * 1.4, models: { 'claude-opus-5-5': { input: Math.round(d.tokens.input / 100), output: d.tokens.output * 3, cacheWrite: d.tokens.cacheRead / 2, cacheRead: d.tokens.cacheRead * 8 } } }]));
  state.v3face = 'smile';
  state.bubble = '我是 GPT龙娘～ 点我看额度';
}

async function snapshots() {
  fs.mkdirSync(SNAPSHOT, { recursive: true });
  const shot = async (win, name) => {
    await new Promise((r) => setTimeout(r, 900));
    const img = await win.webContents.capturePage(undefined, { stayHidden: true });
    fs.writeFileSync(path.join(SNAPSHOT, name), img.toPNG());
  };
  createPanel();
  dashboard = openSingle(null, 'dashboard.html', { width: 900, height: 1250, title: 'dash' });
  settingsWin = openSingle(null, 'settings.html', { width: 480, height: 660, title: 'settings' });
  for (const theme of ['light', 'dark']) {
    nativeTheme.themeSource = theme;
    broadcast();
    await shot(pet, `pet-${theme}.png`);
    await shot(panel, `panel-${theme}.png`);
    await shot(dashboard, `dashboard-${theme}.png`);
    await shot(settingsWin, `settings-${theme}.png`);
  }
  fs.writeFileSync(path.join(SNAPSHOT, 'state.json'), JSON.stringify({ level: level(), sessions: state.sessions.map((s) => [s.name, s.status, s.progress]),
    usage: state.usage, usageError: state.usageError, peers: state.peers.map((p) => p.provider), days: Object.keys(state.days).length,
    petTask: taskText(), pill: pillText() }, null, 1));
  app.exit(0);
}

// ------------------------------------------------------------------ start

app.on('second-instance', () => openPanel());
app.on('window-all-closed', (e) => e.preventDefault?.());

app.whenReady().then(async () => {
  if (process.platform === 'darwin' && app.dock) app.dock.hide();
  if (process.platform === 'win32') app.setAppUserModelId('io.github.jayden-dong411.gpt-dragon-pet');   // needed for toasts
  loadSettings();
  const ud = app.getPath('userData');
  history = new UsageHistory(path.join(ud, 'usage-history.jsonl'));
  indexer = new CodexIndexer(path.join(ud, 'codex-index.json'));
  claudeIndexer = new UsageIndexer(path.join(ud, 'claude-index.json'));
  reader = new CodexReader();
  if (DEMO) demoData();

  createPet();
  if (SNAPSHOT) {
    if (!DEMO) { refreshSessions(false); await refreshUsage(); await refreshPeers(); await refreshIndex(); }
    const go = () => setTimeout(snapshots, 600);
    if (pet.webContents.isLoading()) pet.webContents.once('did-finish-load', go); else go();
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
  react('greet', 5, '我是 GPT龙娘～ 点我看额度');
  setInterval(refreshPeers, 60e3);
  setInterval(tickFocus, 1000);
  setInterval(tickWellness, 2000);
  setInterval(() => refreshSessions(true), 3000);
  setInterval(refreshUsage, 60e3);
  setInterval(refreshIndex, 180e3);
  setInterval(() => { tickFace(); updateVisibility(); }, 2000);
  duetLink = new DuetLink('codex', duetLines, canChat);
  duetLink.start();
  app.on('before-quit', () => duetLink.stop());
  pet.showInactive();
});
