// Usage readings over time → trend line and "runs out at" forecast (same rules as macOS).
const fs = require('fs');

const KEEP = 8 * 86400e3;

class UsageHistory {
  constructor(file) {
    this.file = file;
    this.samples = [];
    try {
      const cutoff = Date.now() - KEEP;
      this.samples = fs.readFileSync(file, 'utf8').split('\n').filter(Boolean)
        .map((l) => { try { return JSON.parse(l); } catch { return null; } })
        .filter((s) => s && s.t > cutoff);
    } catch { /* none yet */ }
  }

  record(snap) {
    const account = snap.account || 'unknown';
    const s = {
      t: Date.now(), account,
      fiveHour: snap.fiveHour?.utilization ?? null, fiveReset: snap.fiveHour?.resetsAt ?? null,
      sevenDay: snap.sevenDay?.utilization ?? null, sevenReset: snap.sevenDay?.resetsAt ?? null,
    };
    const last = [...this.samples].reverse().find((x) => x.account === account);
    if (last && last.fiveHour === s.fiveHour && last.sevenDay === s.sevenDay && s.t - last.t < 600e3) return;
    this.samples.push(s);
    try { fs.appendFileSync(this.file, JSON.stringify(s) + '\n'); } catch { /* ignore */ }
  }

  loadDemo(account, now5) {
    const now = Date.now(), reset = now + 7800e3;
    this.samples = Array.from({ length: 13 }, (_, i) => ({
      t: now + (i - 12) * 300e3, account, fiveHour: now5 - (12 - i) * 2.2, fiveReset: reset,
      sevenDay: 28, sevenReset: now + 340000e3,
    }));
  }

  static same(a, b) { return a != null && b != null && Math.abs(a - b) < 180e3; }

  fiveHourSeries(account, win) {
    if (!win?.resetsAt) return [];
    return this.samples.filter((s) => s.account === (account || 'unknown') && UsageHistory.same(s.fiveReset, win.resetsAt) && s.fiveHour != null)
      .map((s) => [s.t, s.fiveHour]);
  }

  forecast(account, fiveHour, win) {
    if (!win?.resetsAt) return null;
    const now = Date.now();
    const lookback = fiveHour ? 90 * 60e3 : 24 * 3600e3;
    const minSpan = fiveHour ? 10 * 60e3 : 2 * 3600e3;
    const pts = this.samples.filter((s) => s.account === (account || 'unknown') && s.t > now - lookback
      && UsageHistory.same(fiveHour ? s.fiveReset : s.sevenReset, win.resetsAt))
      .map((s) => [s.t, fiveHour ? s.fiveHour : s.sevenDay]).filter((p) => p[1] != null);
    if (!pts.length || now - pts[0][0] < minSpan) return { kind: 'collecting' };
    const rise = win.utilization - pts[0][1];
    if (rise <= 0.5) return { kind: 'flat' };
    const perHour = rise / ((now - pts[0][0]) / 3600e3);
    const eta = now + (Math.max(0, 100 - win.utilization) / perHour) * 3600e3;
    return eta < win.resetsAt ? { kind: 'runsOut', at: eta, perHour } : { kind: 'safe', perHour };
  }
}

module.exports = { UsageHistory };
