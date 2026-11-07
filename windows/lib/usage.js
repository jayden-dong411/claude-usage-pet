// Account usage (5-hour / weekly limits). Sources, in order (same as macOS):
//  1. the Claude desktop app's claude.ai login (its cookies; Windows: DPAPI + AES-GCM), read only
//  2. Claude Code's OAuth token in ~/.claude/.credentials.json, read only, skipped when expired
//  3. a claude.ai login made inside this app (its own persistent cookie partition)
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { execFile } = require('child_process');
const { BrowserWindow, session, net } = require('electron');
const { isWin, credentialsFile, desktopDataDir } = require('./paths');

const CHROME_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36';

class NotLoggedIn extends Error { constructor() { super('未登录'); this.code = 'NOT_LOGGED_IN'; } }

function parseWindow(w) {
  if (!w || typeof w.utilization !== 'number') return null;
  return { utilization: Math.max(0, w.utilization), resetsAt: w.resets_at ? Date.parse(w.resets_at) : null };
}

function parseUsage(obj, source) {
  const extras = [];
  const opus = parseWindow(obj.seven_day_opus); if (opus) extras.push({ label: '7 天 · Opus', window: opus });
  const son = parseWindow(obj.seven_day_sonnet); if (son) extras.push({ label: '7 天 · Sonnet', window: son });
  return { fiveHour: parseWindow(obj.five_hour), sevenDay: parseWindow(obj.seven_day), extras, account: null, plan: null, source };
}

// ---------------------------------------------------------------- web (claude.ai session)

const SCRIPT = (preferOrg) => `(async () => {
  const preferOrg = ${JSON.stringify(preferOrg || '')};
  const acc = await fetch('/api/account', {credentials: 'include', headers: {accept: 'application/json'}});
  if (!acc.ok) return JSON.stringify({error: 'auth', status: acc.status});
  const a = await acc.json();
  const ms = a.memberships || [];
  let org = null;
  for (const m of ms) if (preferOrg && m.organization && m.organization.uuid === preferOrg) { org = m.organization; break; }
  if (!org) for (const m of ms) {
    const o = m.organization || {}; const caps = o.capabilities || [];
    if (!caps.includes('chat')) continue;
    const paid = caps.some(c => c.startsWith('claude_max') || c.startsWith('claude_pro') || c === 'raven');
    if (!org || paid) org = o;
  }
  if (!org && ms.length) org = ms[0].organization;
  if (!org) return JSON.stringify({error: 'noorg'});
  const u = await fetch('/api/organizations/' + org.uuid + '/usage', {credentials: 'include', headers: {accept: 'application/json'}});
  if (!u.ok) return JSON.stringify({error: 'usage', status: u.status});
  return JSON.stringify({email: a.email_address, org: org.name, caps: org.capabilities || [], usage: await u.json()});
})()`;

class WebFetcher {
  constructor(partition) { this.partition = partition; this.win = null; this.loaded = false; }

  get session() { return session.fromPartition(this.partition); }

  async ensure() {
    if (this.win && !this.win.isDestroyed() && this.loaded) return;
    if (!this.win || this.win.isDestroyed()) {
      this.win = new BrowserWindow({ show: false, width: 400, height: 300, webPreferences: { partition: this.partition, contextIsolation: true } });
      this.win.webContents.setUserAgent(CHROME_UA);
    }
    await Promise.race([
      this.win.loadURL('https://claude.ai/api/account'),
      new Promise((_, rej) => setTimeout(() => rej(new Error('连接超时')), 25000)),
    ]).catch((e) => { if (!/ERR_ABORTED|ERR_HTTP_RESPONSE_CODE_FAILURE/.test(String(e))) throw e; });
    this.loaded = true;
  }

  async fetch(preferOrg) {
    try { await this.ensure(); } catch (e) { this.loaded = false; throw e; }
    const raw = await this.win.webContents.executeJavaScript(SCRIPT(preferOrg), true);
    const obj = JSON.parse(raw);
    if (obj.error === 'auth') throw new NotLoggedIn();
    if (obj.error) throw new Error(obj.error === 'noorg' ? '没有找到组织' : `请求失败 (HTTP ${obj.status})`);
    const snap = parseUsage(obj.usage || {}, 'claude.ai 网页登录');
    snap.account = obj.email || null;
    const caps = obj.caps || [];
    snap.plan = caps.some((c) => c.startsWith('claude_max')) ? 'Max' : caps.some((c) => c.startsWith('claude_pro')) ? 'Pro'
      : caps.includes('raven') ? 'Team' : 'Free';
    return snap;
  }

  async importCookies(cookies) {
    for (const c of cookies) {
      try {
        await this.session.cookies.set({
          url: 'https://claude.ai', name: c.name, value: c.value, domain: c.domain, path: c.path || '/',
          secure: c.secure, httpOnly: c.httpOnly, expirationDate: c.expires || undefined,
        });
      } catch { /* skip odd cookies */ }
    }
  }

  async clear() {
    if (this.win && !this.win.isDestroyed()) this.win.destroy();
    this.win = null; this.loaded = false;
    await this.session.clearStorageData();
  }
}

// ---------------------------------------------------------------- Claude Code OAuth token

async function fetchOAuth() {
  let o;
  try { o = JSON.parse(fs.readFileSync(credentialsFile, 'utf8')).claudeAiOauth; } catch { return null; }
  if (!o?.accessToken) return null;
  if ((o.expiresAt || 0) < Date.now() + 30e3) throw new Error('Claude Code 令牌已过期');
  const get = async (p) => {
    const r = await net.fetch('https://api.anthropic.com' + p, {
      headers: { Authorization: `Bearer ${o.accessToken}`, 'anthropic-beta': 'oauth-2025-04-20', 'User-Agent': 'ClaudeUsagePet/1.1' },
    });
    if (!r.ok) throw new Error(r.status === 401 ? '登录已失效 (401)' : `请求失败 (HTTP ${r.status})`);
    return r.json();
  };
  const snap = parseUsage(await get('/api/oauth/usage'), 'Claude Code 登录');
  snap.plan = o.subscriptionType ? o.subscriptionType[0].toUpperCase() + o.subscriptionType.slice(1) : null;
  try { snap.account = (await get('/api/oauth/profile')).account?.email || null; } catch { /* optional */ }
  return snap;
}

// ---------------------------------------------------------------- Claude desktop cookies (Windows)

function powershell(script) {
  return new Promise((resolve, reject) => {
    execFile('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', script],
      { windowsHide: true, maxBuffer: 4 << 20, timeout: 20000 },
      (err, out) => (err ? reject(err) : resolve(String(out).trim())));
  });
}

async function dpapiUnprotect(buf) {
  const b64 = buf.toString('base64');
  const out = await powershell(`Add-Type -AssemblyName System.Security; ` +
    `$b=[Convert]::FromBase64String('${b64}'); ` +
    `$p=[System.Security.Cryptography.ProtectedData]::Unprotect($b,$null,[System.Security.Cryptography.DataProtectionScope]::CurrentUser); ` +
    `[Convert]::ToBase64String($p)`);
  return Buffer.from(out, 'base64');
}

let SQL = null;
async function sqlJs() {
  if (!SQL) {
    const initSqlJs = require('sql.js');
    const dist = path.join(path.dirname(require.resolve('sql.js')), '');
    SQL = await initSqlJs({ locateFile: (f) => path.join(dist, f) });
  }
  return SQL;
}

/** Copies the (possibly in-use) cookie database to a temp file. */
async function copyLocked(src) {
  const dst = path.join(os.tmpdir(), `claude-usage-pet-cookies-${process.pid}.db`);
  try { fs.copyFileSync(src, dst); return dst; } catch { /* locked: try a shared-read open */ }
  const esc = (p) => p.replace(/'/g, "''");
  await powershell(`$s=[System.IO.File]::Open('${esc(src)}','Open','Read','ReadWrite,Delete'); ` +
    `$d=[System.IO.File]::Create('${esc(dst)}'); $s.CopyTo($d); $d.Close(); $s.Close()`);
  return dst;
}

let cachedKey = null;
async function readDesktopCookies() {
  if (!isWin) throw new Error('只在 Windows 上读取桌面版登录');
  const dir = desktopDataDir();
  const dbPath = [path.join(dir, 'Network', 'Cookies'), path.join(dir, 'Cookies')].find((p) => fs.existsSync(p));
  if (!dbPath) throw new Error('没找到 Claude 桌面版的数据');
  if (!cachedKey) {
    const ls = JSON.parse(fs.readFileSync(path.join(dir, 'Local State'), 'utf8'));
    const enc = Buffer.from(ls.os_crypt.encrypted_key, 'base64');
    cachedKey = await dpapiUnprotect(enc.subarray(5));   // strip the "DPAPI" prefix
  }
  let tmp;
  try { tmp = await copyLocked(dbPath); } catch { throw new Error('Claude 桌面版正在占用 cookie 文件'); }
  try {
    const S = await sqlJs();
    const db = new S.Database(fs.readFileSync(tmp));
    let version = 0;
    try { version = Number(db.exec("SELECT value FROM meta WHERE key='version'")[0].values[0][0]) || 0; } catch {}
    const res = db.exec("SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly FROM cookies WHERE host_key IN ('claude.ai', '.claude.ai')");
    db.close();
    const rows = res[0]?.values || [];
    const cookies = [];
    for (const [domain, name, value, enc, cpath, expires, secure, httpOnly] of rows) {
      let v = value;
      if (!v && enc && enc.length > 31) {
        const b = Buffer.from(enc);
        const prefix = b.subarray(0, 3).toString();
        if (prefix !== 'v10' && prefix !== 'v11') continue;
        try {
          const nonce = b.subarray(3, 15), tag = b.subarray(b.length - 16), data = b.subarray(15, b.length - 16);
          const d = crypto.createDecipheriv('aes-256-gcm', cachedKey, nonce);
          d.setAuthTag(tag);
          let plain = Buffer.concat([d.update(data), d.final()]);
          if (version >= 24 && plain.length >= 32) plain = plain.subarray(32);   // SHA-256(host) prefix
          v = plain.toString('utf8');
        } catch { continue; }
      }
      const exp = Number(expires) > 0 ? Number(expires) / 1e6 - 11644473600 : null;
      cookies.push({ domain, name, value: v, path: cpath, expires: exp, secure: !!secure, httpOnly: !!httpOnly });
    }
    const sk = cookies.find((c) => c.name === 'sessionKey');
    if (!sk || (sk.expires && sk.expires * 1000 < Date.now())) throw new Error('桌面版没有登录 claude.ai');
    return cookies;
  } finally { try { fs.unlinkSync(tmp); } catch {} }
}

module.exports = { WebFetcher, fetchOAuth, readDesktopCookies, parseUsage, NotLoggedIn, CHROME_UA };
