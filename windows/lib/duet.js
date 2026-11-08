// Lets the Windows pets (Claude大小姐 main.js, GPT龙娘 main-gpt.js) chat with each other — the Windows
// twin of the duets in ../../Sources/PetHub.swift. They share <appData>/AIPets:
//   alive-<pet>.json   heartbeat every 2 s
//   duet.json          the current exchange { id, at, lines: [{ pet, text, delay }] }, written by the leader
//   duet-now           debug: create this file to start a duet right away
// The leader is the first running pet in ORDER; it starts a duet every 7–15 minutes while you are around.
const fs = require('fs');
const path = require('path');
const banter = require('./banter');
const { shareDir, readPeer } = require('./peers');

const ORDER = ['claude', 'codex'];

class DuetLink {
  /**
   * @param me        'claude' | 'codex'
   * @param onLines   (myLines, totalSeconds) → show the pet and say them at their delays
   * @param canChat   () → true when a duet may start now (setting on, user around, not focusing)
   */
  constructor(me, onLines, canChat) {
    this.me = me; this.onLines = onLines; this.canChat = canChat;
    this.seen = 0; this.timer = null;
    this.nextDuet = Date.now() + (150 + Math.random() * 150) * 1000;
  }

  file(name) { return path.join(shareDir, name); }

  start() {
    try { fs.mkdirSync(shareDir, { recursive: true }); } catch {}
    try { this.seen = JSON.parse(fs.readFileSync(this.file('duet.json'), 'utf8')).id || 0; } catch {}
    this.timer = setInterval(() => this.tick(), 2000);
  }

  stop() { clearInterval(this.timer); try { fs.unlinkSync(this.file(`alive-${this.me}.json`)); } catch {} }

  alive() {
    return ORDER.filter((p) => {
      if (p === this.me) return true;
      try { return Date.now() - JSON.parse(fs.readFileSync(this.file(`alive-${p}.json`), 'utf8')).at < 10e3; } catch { return false; }
    });
  }

  usage(id) {
    const u = readPeer(id, 600e3);           // only fresh readings: no "交给我吧" from old numbers
    const v = u?.windows?.map((w) => w.utilization);
    return v?.length ? Math.max(...v) : null;
  }

  startDuet() {
    const pets = this.alive();
    if (pets.length < 2) return false;
    const a = pets.includes(this.me) && Math.random() < 0.5 ? this.me : pets[Math.floor(Math.random() * pets.length)];
    const others = pets.filter((p) => p !== a);
    const b = others[Math.floor(Math.random() * others.length)];
    const lines = banter.duet(a, b, (id) => this.usage(id));
    if (!lines) return false;
    let id = 0;
    try { id = JSON.parse(fs.readFileSync(this.file('duet.json'), 'utf8')).id || 0; } catch {}
    fs.writeFileSync(this.file('duet.json'), JSON.stringify({ id: id + 1, at: Date.now(), lines }));
    return true;
  }

  tick() {
    try { fs.writeFileSync(this.file(`alive-${this.me}.json`), JSON.stringify({ at: Date.now() })); } catch {}
    const leader = this.alive()[0] === this.me;
    if (leader) {
      let now = false;
      try { fs.unlinkSync(this.file('duet-now')); now = true; } catch {}
      if (now) this.startDuet();
      else if (Date.now() >= this.nextDuet) {
        this.nextDuet = Date.now() + (420 + Math.random() * 480) * 1000;
        if (this.canChat()) this.startDuet();
      }
    }
    try {
      const d = JSON.parse(fs.readFileSync(this.file('duet.json'), 'utf8'));
      if (d.id > this.seen) {
        this.seen = d.id;
        if (Date.now() - d.at < 30e3) {
          const mine = d.lines.filter((l) => l.pet === this.me);
          const total = Math.max(...d.lines.map((l) => l.delay)) + 4;
          if (mine.length) this.onLines(mine, total);
        }
      }
    } catch { /* no duet yet */ }
  }
}

module.exports = { DuetLink };
