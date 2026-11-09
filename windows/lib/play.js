// Small interactions shared by the Windows pets — the twin of ../../Sources/PetPlay.swift:
// picked up / put down, shaken while dragged, poked (double-clicked again and again), the pointer resting
// on her, right-click 「投喂」 and 「陪我聊聊」, "thanks" when a session you approved carries on,
// "welcome back" after 10+ minutes away, and dropping one pet onto the other (a "bump" duet).
const { powerMonitor } = require('electron');
const banter = require('./banter');

/**
 * @param o.me      'claude' | 'codex'
 * @param o.say     (text, seconds)
 * @param o.react   (mood, seconds) — mood names as in react(): 'oops', 'hop', 'petted', 'clicked', 'greet', 'taskDone'
 * @param o.quiet   () → true when no bubble is up
 * @param o.vars    () → values for {five} {week}
 * @param o.moods   () → current moods for 「说句话」
 * @param o.duet    the DuetLink (lib/duet.js), for bumping into the other pet
 * @param o.bounds  () → this pet window's bounds
 * @param o.face    (name, seconds) → show one of the v3 expressions (dizzy, angry, wink, excited, eating …)
 */
function createPlay(o) {
  let hops = [], lastHover = 0, meals = [], away = false, dragging = false;
  const line = (pool, v) => banter.line(o.me, pool, v);
  const face = (n, s) => { if (o.face) o.face(n, s); };

  return {
    /** Every pet-drag event; the first one of a drag counts as being picked up. */
    dragged() {
      if (dragging) return;
      dragging = true;
      if (Math.random() < 0.35) { const l = line('dragStart'); if (l) o.say(l, 2.5); }
    },
    dropped() {
      dragging = false;
      if (o.duet && o.duet.bump(o.bounds())) return;
      if (Math.random() < 0.4) { const l = line('dropped'); if (l) o.say(l, 3); }
    },
    shaken() { o.react('oops', 3); face('dizzy', 3.5); const l = line('dizzy'); if (l) o.say(l, 3); },
    /** True when this double-click was one too many (3 within 8 s): she complains instead of jumping. */
    doubleClicked() {
      const now = Date.now();
      hops = hops.filter((t) => now - t < 8000).concat(now);
      if (hops.length < 3) return false;
      hops = [];
      o.react('oops', 3); face('angry', 3);
      const l = line('poked'); if (l) o.say(l, 3);
      return true;
    },
    hovered() {
      if (Date.now() - lastHover < 45e3 || !o.quiet()) return;
      lastHover = Date.now();
      o.react('clicked', 2.5); face('wink', 3);
      const l = line('hover'); if (l) o.say(l, 3);
    },
    resumed() { face('wink', 3); const l = line('thanks'); if (l) o.say(l, 3.5); },
    /** Every couple of seconds: notices you coming back after 10+ minutes away. */
    tick() {
      const idle = powerMonitor.getSystemIdleTime();
      if (idle >= 600) { away = true; return; }
      if (away && idle < 3) { away = false; o.react('greet', 3); face('excited', 4); const l = line('welcomeBack'); if (l) o.say(l, 4); }
    },
    /** 「投喂」 and 「陪我聊聊」 submenus for the right-click menu. */
    menuItems() {
      const foods = banter.foods(o.me);
      const items = [];
      if (foods.length) {
        items.push({ label: '投喂', submenu: foods.map((f) => ({ label: `${f.emoji} ${f.name}`, click: () => this.feed(f) })) });
      }
      items.push({ label: '陪我聊聊', submenu: [
        { label: '说句话', click: () => { const l = banter.chatter(o.me, o.moods(), o.vars()); if (l) { o.react('clicked', 2.5); o.say(l, 4.5); } } },
        { label: '讲个冷知识 / 笑话', click: () => { const l = banter.chatter(o.me, [], o.vars()); if (l) { o.react('clicked', 2.5); o.say(l, 4.5); } } },
      ] });
      return items;
    },
    feed(f) {
      const now = Date.now();
      meals = meals.filter((t) => now - t < 3600e3).concat(now);
      if (meals.length > 5) { o.react('oops', 3); face('dizzy', 3); const l = line('full'); if (l) o.say(l, 3); return; }
      o.react(f.fav ? 'taskDone' : 'petted', 3);
      face(f.fav ? 'eating' : 'excited', 3.5);          // her favourite: she's drawn eating it
      const l = line(f.fav ? 'favFed' : 'fed', { food: f.name }); if (l) o.say(l, 3.5);
    },
  };
}

module.exports = { createPlay };
