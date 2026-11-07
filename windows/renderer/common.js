// Shared helpers for the panel and the dashboard.
const U = {
  cn(v) {
    if (v >= 1e8) return (v / 1e8).toFixed(2) + '亿';
    if (v >= 1e4) return (v / 1e4).toFixed(v >= 1e7 ? 0 : 1) + '万';
    return String(Math.round(v));
  },
  hours(s) {
    const m = Math.floor(s / 60);
    return m < 60 ? `${m}分钟` : `${Math.floor(m / 60)}小时${m % 60}分`;
  },
  duration(ms) {
    const s = Math.max(0, Math.floor(ms / 1000)), d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
    return d ? `${d}天${h}小时` : h ? `${h}小时${m}分` : m ? `${m}分钟` : '不到1分钟';
  },
  pad: (n) => String(n).padStart(2, '0'),
  clock(t) { const d = new Date(t); return `${U.pad(d.getHours())}:${U.pad(d.getMinutes())}:${U.pad(d.getSeconds())}`; },
  when(t) {
    const d = new Date(t), now = new Date();
    const hm = `${U.pad(d.getHours())}:${U.pad(d.getMinutes())}`;
    const sameDay = (a, b) => a.toDateString() === b.toDateString();
    if (sameDay(d, now)) return hm;
    if (sameDay(d, new Date(now.getTime() + 86400e3))) return `明天 ${hm}`;
    return `${d.getMonth() + 1}月${d.getDate()}日 ${'日一二三四五六'[d.getDay()].replace(/^/, '周')} ${hm}`;
  },
  resetText(w, now) { return w?.resetsAt ? `${U.duration(w.resetsAt - now)}后重置 · ${U.when(w.resetsAt)}` : '尚未开始计时'; },
  pct(v) { return v >= 10 ? `${Math.round(v)}%` : `${v.toFixed(1)}%`; },
  barColor(u) { return u < 40 ? 'var(--good)' : u < 70 ? 'var(--amber)' : u < 90 ? 'var(--deep)' : 'var(--alert)'; },
  forecastText(f) {
    if (!f) return null;
    if (f.kind === 'collecting') return '正在收集数据，稍后给出预测';
    if (f.kind === 'flat') return '最近没有增长';
    if (f.kind === 'safe') return `每小时约 +${U.pct(f.perHour)}，重置前用不完`;
    return `每小时约 +${U.pct(f.perHour)}，按这个速度约 ${U.when(f.at)} 用完`;
  },
  dayKey(d) { return `${d.getFullYear()}-${U.pad(d.getMonth() + 1)}-${U.pad(d.getDate())}`; },
  esc(s) { return String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])); },
  total: (t) => t ? t.input + t.output + t.cacheWrite + t.cacheRead : 0,

  /** Last n days ending today, oldest first. */
  series(days, n) {
    const out = [];
    const today = new Date(); today.setHours(0, 0, 0, 0);
    for (let i = n - 1; i >= 0; i--) {
      const d = new Date(today.getTime() - i * 86400e3);
      out.push({ date: d, stats: days[U.dayKey(d)] || null });
    }
    return out;
  },

  /** GitHub-style calendar of daily tokens (Monday first). Returns an HTML string. */
  heatmap(days, { weeks = 22, cell = 10, gap = 3, hoverId = 'heat-hover' } = {}) {
    const today = new Date(); today.setHours(0, 0, 0, 0);
    const dow = (today.getDay() + 6) % 7;                     // 0 = Monday
    const start = new Date(today.getTime() - (dow + (weeks - 1) * 7) * 86400e3);
    const cols = [];
    for (let w = 0; w < weeks; w++) {
      const col = [];
      for (let d = 0; d < 7; d++) {
        const date = new Date(start.getTime() + (w * 7 + d) * 86400e3);
        const s = days[U.dayKey(date)];
        col.push({ date, value: s ? U.total(s.tokens) : 0, s, future: date > today });
      }
      cols.push(col);
    }
    const vals = cols.flat().filter((c) => !c.future && c.value > 0).map((c) => c.value).sort((a, b) => a - b);
    const q = vals.length ? [0.25, 0.5, 0.75].map((p) => vals[Math.min(vals.length - 1, Math.floor(vals.length * p))]) : [1, 2, 3];
    const lvl = (v) => (v <= 0 ? 0 : v < q[0] ? 1 : v < q[1] ? 2 : v < q[2] ? 3 : 4);
    const label = (c) => {
      const t = `${c.date.getMonth() + 1}月${c.date.getDate()}日 周${'日一二三四五六'[c.date.getDay()]}`;
      return c.value ? `${t} · ${U.cn(c.value)} token · ${U.hours(c.s.activeSeconds)} · ${c.s.messages} 次回复` : `${t} · 没有使用`;
    };
    const lw = Math.round(cell * 1.6);
    const months = cols.map((col, i) => {
      const first = col.find((c) => c.date.getDate() === 1);
      if (first) return `${first.date.getMonth() + 1}月`;
      if (i === 0 && !cols.slice(1, 3).some((c2) => c2.some((c) => c.date.getDate() === 1))) return `${col[0].date.getMonth() + 1}月`;
      return '';
    });
    const fs = Math.max(9, cell - 1);
    let html = `<div class="heat-wrap" style="font-size:${fs}px">`;
    html += `<div class="heat-months" style="grid-template-columns:${lw}px repeat(${weeks},${cell}px);column-gap:${gap}px;margin-bottom:4px"><span></span>${months.map((m) => `<span>${m}</span>`).join('')}</div>`;
    html += `<div style="display:flex;gap:${gap}px"><div style="display:grid;grid-template-rows:repeat(7,${cell}px);row-gap:${gap}px;width:${lw}px;text-align:right;color:var(--text-2);line-height:${cell}px">`;
    html += ['一', '', '三', '', '五', '', ''].map((t) => `<span>${t}</span>`).join('') + '</div>';
    html += `<div class="heat" style="grid-template-rows:repeat(7,${cell}px);grid-auto-columns:${cell}px;gap:${gap}px">`;
    for (const col of cols) for (const c of col) {
      html += c.future ? `<span></span>`
        : `<span class="cell" data-tip="${U.esc(label(c))}" style="width:${cell}px;height:${cell}px;background:var(--heat${lvl(c.value)})"></span>`;
    }
    html += '</div></div>';
    const past = cols.flat().filter((c) => !c.future);
    const sum = past.reduce((a, c) => a + c.value, 0), active = past.filter((c) => c.value > 0).length;
    const sq = Math.round(cell * 0.9);
    html += `<div class="row" style="margin-top:6px;font-size:11px"><span class="muted" id="${hoverId}" data-default="近 ${weeks} 周 ${U.cn(sum)} token · 用了 ${active} 天">近 ${weeks} 周 ${U.cn(sum)} token · 用了 ${active} 天</span><span class="spacer"></span>`;
    html += `<span class="heat-legend">少 ${[0, 1, 2, 3, 4].map((l) => `<i style="width:${sq}px;height:${sq}px;background:var(--heat${l})"></i>`).join('')} 多</span></div></div>`;
    return html;
  },

  /** Hover readout for a heatmap inside `root`. */
  wireHeatmap(root, hoverId = 'heat-hover') {
    root.addEventListener('mouseover', (e) => {
      const tip = e.target?.dataset?.tip, out = document.getElementById(hoverId);
      if (out) out.textContent = tip || out.dataset.default;
    });
    root.addEventListener('mouseleave', () => { const out = document.getElementById(hoverId); if (out) out.textContent = out.dataset.default; });
  },
};
