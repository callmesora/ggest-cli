// Inline widgets the assistant can emit as <ui-element type="...">JSON</ui-element>.
// Every value is inserted as text (never HTML), so model output cannot inject markup.
import { h } from "./dom.js";
import { icon } from "./icons.js";

const SVG = "http://www.w3.org/2000/svg";
const COLORS = ["var(--c1)", "var(--c2)", "var(--c3)", "var(--c4)"];
const LABELS = { kpis: "numbers", chart: "chart", breakdown: "breakdown", table: "table", callout: "note", suggestions: "suggestions" };

function s(tag, attrs = {}) {
  const el = document.createElementNS(SVG, tag);
  for (const [k, v] of Object.entries(attrs)) el.setAttribute(k, v);
  return el;
}

export function formatValue(v, unit = "") {
  if (typeof v !== "number" || !Number.isFinite(v)) return v === null || v === undefined ? "–" : String(v);
  if (unit === "%") return `${v.toLocaleString(undefined, { maximumFractionDigits: 1 })}%`;
  const abs = Math.abs(v);
  const compact = abs >= 1000
    ? new Intl.NumberFormat(undefined, { notation: "compact", maximumFractionDigits: abs >= 1e6 ? 2 : 1 }).format(v)
    : v.toLocaleString(undefined, { maximumFractionDigits: abs < 10 ? 2 : 0 });
  if (unit === "€" || unit === "EUR") return `€${compact}`;
  return unit ? `${compact} ${unit}` : compact;
}

function niceStep(range, ticks) {
  const raw = range / ticks;
  const mag = 10 ** Math.floor(Math.log10(raw || 1));
  const norm = raw / mag;
  return (norm <= 1 ? 1 : norm <= 2 ? 2 : norm <= 2.5 ? 2.5 : norm <= 5 ? 5 : 10) * mag;
}

export function scale(values) {
  const nums = values.filter((v) => typeof v === "number" && Number.isFinite(v));
  let lo = Math.min(0, ...nums);
  let hi = Math.max(0, ...nums);
  if (lo === hi) hi = lo + 1;
  const step = niceStep(hi - lo, 4);
  lo = Math.floor(lo / step) * step;
  hi = Math.ceil(hi / step) * step;
  const ticks = [];
  for (let t = lo; t <= hi + step / 2; t += step) ticks.push(+t.toFixed(10));
  return { lo, hi, ticks };
}

// ---------- kpis ----------
function trendOf(item) {
  if (item.trend) return item.trend;
  const d = String(item.delta || "").trim();
  if (d.startsWith("-") || d.startsWith("−")) return "down";
  if (d.startsWith("+")) return "up";
  return "flat";
}

function kpis(data) {
  const items = Array.isArray(data.items) ? data.items : [];
  return h("div", { class: "kpis" }, items.map((it) => {
    const trend = trendOf(it);
    return h("div", { class: "kpi" },
      h("div", { class: "kpi-label" }, it.label ?? ""),
      h("div", { class: "kpi-value" }, it.value ?? "–"),
      (it.delta || it.hint) && h("div", { class: "kpi-foot" },
        it.delta && h("span", { class: `delta ${trend}` }, trend === "up" ? "▲" : trend === "down" ? "▼" : "•", " ", it.delta),
        it.hint && h("span", { class: "kpi-hint" }, it.hint)));
  }));
}

// ---------- chart ----------
const W = 640, H = 250, M = { l: 52, r: 14, t: 12, b: 30 };

function axes(svg, sc, xs, y) {
  for (const t of sc.ticks) {
    svg.append(s("line", { class: "grid", x1: M.l, x2: W - M.r, y1: y(t), y2: y(t) }));
    const label = s("text", { x: M.l - 8, y: y(t) + 4, "text-anchor": "end" });
    label.textContent = formatValue(t);
    svg.append(label);
  }
  svg.append(s("line", { class: "axis", x1: M.l, x2: W - M.r, y1: y(0), y2: y(0) }));
  const every = Math.ceil(xs.length / 12);
  xs.forEach((x, i) => {
    if (i % every) return;
    const t = s("text", { x: xs.center(i), y: H - 10, "text-anchor": "middle" });
    t.textContent = String(x.label);
    svg.append(t);
  });
}

function drawBars(svg, series, n, slot, y) {
  const inner = slot * 0.72;
  const bw = Math.max(2, inner / series.length - 2);
  const groups = [];
  for (let i = 0; i < n; i++) {
    const g = s("g", { "data-i": i });
    series.forEach((sr, k) => {
      const v = Number(sr.values?.[i]);
      if (!Number.isFinite(v)) return;
      const x = M.l + i * slot + (slot - inner) / 2 + k * (bw + 2);
      const top = Math.min(y(v), y(0));
      g.append(s("rect", { class: "bar", x, y: top, width: bw, height: Math.max(1, Math.abs(y(v) - y(0))), rx: 3,
        fill: COLORS[k % COLORS.length] }));
    });
    svg.append(g);
    groups.push(g);
  }
  return groups;
}

function drawLines(svg, series, n, center, y) {
  const groups = Array.from({ length: n }, (_, i) => s("g", { "data-i": i }));
  series.forEach((sr, k) => {
    const pts = (sr.values || []).map((v, i) => [center(i), y(Number(v))]).filter(([, py]) => Number.isFinite(py));
    const d = pts.map(([px, py], i) => `${i ? "L" : "M"}${px},${py}`).join(" ");
    svg.append(s("path", { d, fill: "none", stroke: COLORS[k % COLORS.length], "stroke-width": 2.2, "stroke-linejoin": "round" }));
    pts.forEach(([px, py], i) => groups[i]?.append(s("circle", { cx: px, cy: py, r: 3.2, fill: COLORS[k % COLORS.length] })));
  });
  groups.forEach((g) => svg.append(g));
  return groups;
}

function hover(wrap, svg, groups, data, center, slot) {
  const tip = h("div", { class: "tip", style: { display: "none" } });
  wrap.append(tip);
  const n = groups.length;
  for (let i = 0; i < n; i++) {
    const hit = s("rect", { x: M.l + i * slot, y: M.t, width: slot, height: H - M.t - M.b, fill: "transparent" });
    hit.addEventListener("mouseenter", () => {
      groups.forEach((g, j) => g.classList.toggle("dim", j !== i));
      tip.replaceChildren(h("b", {}, String(data.x[i])), ...data.series.flatMap((sr) =>
        [h("br"), `${sr.name || "value"}: ${formatValue(Number(sr.values?.[i]), data.unit)}`]));
      const ratio = svg.getBoundingClientRect().width / W;
      Object.assign(tip.style, { display: "block", left: `${14 + center(i) * ratio}px`, top: `${8 + M.t * ratio + 20}px` });
    });
    svg.append(hit);
  }
  svg.addEventListener("mouseleave", () => {
    groups.forEach((g) => g.classList.remove("dim"));
    tip.style.display = "none";
  });
}

function chart(data) {
  const xsRaw = Array.isArray(data.x) ? data.x : [];
  const series = (Array.isArray(data.series) ? data.series : []).slice(0, 4);
  const n = xsRaw.length;
  const slot = (W - M.l - M.r) / Math.max(1, n);
  const center = (i) => M.l + i * slot + slot / 2;
  const sc = scale(series.flatMap((sr) => (sr.values || []).map(Number)));
  const y = (v) => M.t + (H - M.t - M.b) * (1 - (v - sc.lo) / (sc.hi - sc.lo));
  const svg = s("svg", { class: "chart-svg", viewBox: `0 0 ${W} ${H}`, role: "img", "aria-label": data.title || "chart" });
  const xs = xsRaw.map((label) => ({ label }));
  xs.center = center;
  axes(svg, sc, xs, y);
  const groups = data.kind === "line" ? drawLines(svg, series, n, center, y) : drawBars(svg, series, n, slot, y);
  const wrap = h("div", { class: "chart-wrap" }, svg);
  hover(wrap, svg, groups, { ...data, x: xsRaw, series }, center, slot);
  const legend = series.length > 1 && h("div", { class: "legend" }, series.map((sr, k) =>
    h("span", {}, h("i", { style: { background: COLORS[k % COLORS.length] } }), sr.name || `Series ${k + 1}`)));
  return h("div", { class: "w-card" }, data.title && h("div", { class: "w-title" }, data.title), wrap, legend);
}

// ---------- breakdown ----------
function breakdown(data) {
  const items = Array.isArray(data.items) ? data.items : [];
  const max = Math.max(...items.map((it) => Math.abs(Number(it.value) || 0)), 1);
  return h("div", { class: "w-card" }, data.title && h("div", { class: "w-title" }, data.title),
    h("div", { class: "bd" }, items.map((it) => h("div", { class: "bd-row" },
      h("span", { class: "bd-label", title: it.label }, it.label ?? ""),
      h("div", { class: "bd-track" }, h("div", { class: "bd-fill",
        style: { width: `${(100 * Math.abs(Number(it.value) || 0)) / max}%`, background: COLORS[0] } })),
      h("span", { class: "bd-val" }, it.display ?? formatValue(Number(it.value), data.unit))))));
}

// ---------- table ----------
function table(data) {
  const cols = Array.isArray(data.columns) ? data.columns : [];
  const align = Array.isArray(data.align) ? data.align : [];
  const cls = (i) => (align[i] === "right" ? "r" : align[i] === "center" ? "c" : "");
  const rows = Array.isArray(data.rows) ? data.rows : [];
  return h("div", { class: "w-card" }, data.title && h("div", { class: "w-title" }, data.title),
    h("div", { class: "w-table" }, h("table", {},
      h("thead", {}, h("tr", {}, cols.map((c, i) => h("th", { class: cls(i) }, c)))),
      h("tbody", {}, rows.map((r) => h("tr", {}, (Array.isArray(r) ? r : cols.map((c) => r?.[c])).map((v, i) =>
        h("td", { class: cls(i) }, typeof v === "number" ? formatValue(v, data.unit) : v ?? ""))))))));
}

// ---------- callout ----------
const TONES = { info: "info", success: "okCircle", warning: "alert", danger: "errCircle" };
function callout(data) {
  const tone = TONES[data.tone] ? data.tone : "info";
  return h("div", { class: `callout ${tone}` }, icon(TONES[tone]),
    h("div", {}, data.title && h("div", { class: "ct" }, data.title), data.text && h("div", {}, data.text)));
}

// ---------- suggestions ----------
function suggestions(data, ctx) {
  const items = (Array.isArray(data.items) ? data.items : []).slice(0, 4);
  return h("div", { class: "suggest" }, items.map((text) =>
    h("button", { class: "chip", onclick: () => ctx.onAsk?.(String(text)) }, icon("sparkle"), String(text))));
}

const RENDER = { kpis, chart, breakdown, table, callout, suggestions };

export function renderSegment(seg, ctx = {}) {
  if (seg.kind === "pending") {
    return h("div", { class: "w w-skel" }, `Preparing ${LABELS[seg.type] || "widget"}…`);
  }
  const render = RENDER[seg.type];
  if (seg.kind === "bad" || !render || typeof seg.data !== "object" || seg.data === null) {
    return h("details", { class: "w w-bad" }, h("summary", {}, `Could not draw this ${LABELS[seg.type] || seg.type}`),
      h("pre", {}, seg.raw ?? JSON.stringify(seg.data, null, 2)));
  }
  try {
    return h("div", { class: "w", dataset: { widget: seg.type } }, render(seg.data, ctx));
  } catch (e) {
    return h("div", { class: "w w-bad" }, `Could not draw this ${LABELS[seg.type]}: ${e.message}`);
  }
}
