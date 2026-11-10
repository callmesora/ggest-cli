// gGest Assistant: projects (one per gGest database), chats, streaming answers with tool steps and widgets.
import { api, streamChat } from "./api.js";
import { parseSegments, markdown } from "./content.js";
import { append, autosize, clear, h, relTime, toast } from "./dom.js";
import { icon } from "./icons.js";
import { renderSegment } from "./widgets.js";

const $ = (id) => document.getElementById(id);
const state = {
  settings: { has_key: false, model: "" },
  models: [],
  projects: [],
  current: null, // { session | null, projectId, messages, draftModel }
  live: new Map(), // sessionId -> { controller, turn }
  collapsed: new Set(JSON.parse(localStorage.getItem("collapsed") || "[]")),
  stick: true,
};

const STARTERS = [
  { icon: "trend", title: "How is the business doing?", sub: "This year vs the same days last year", q: "How is the business doing this year compared with the same period last year? What drove the change?" },
  { icon: "users", title: "Top customers", sub: "Who buys the most this year", q: "Who are our top 10 customers this year, and how do they compare with last year?" },
  { icon: "receipt", title: "Money owed to us", sub: "Open receivables and slow payers", q: "How much do customers owe us right now, how old is it, and who should we chase first?" },
  { icon: "wrench", title: "Repair desk", sub: "Open repairs and what breaks most", q: "What is open at the repair desk right now and what are the most common faults this year?" },
];

// ---------- helpers ----------
const projectOf = (id) => state.projects.find((p) => p.id === id);
const modelLabel = (id) => state.models.find((m) => m.id === id)?.label || id || "No model";
const activeModel = () => state.current?.session?.model || state.current?.draftModel || state.settings.model;

function saveCollapsed() {
  localStorage.setItem("collapsed", JSON.stringify([...state.collapsed]));
}

function setTheme(theme) {
  if (theme === "system") {
    delete document.documentElement.dataset.theme;
    localStorage.removeItem("theme");
  } else {
    document.documentElement.dataset.theme = theme;
    localStorage.setItem("theme", theme);
  }
}

function isDark() {
  const t = document.documentElement.dataset.theme;
  return t ? t === "dark" : matchMedia("(prefers-color-scheme: dark)").matches;
}

// ---------- turns: messages -> user question + assistant parts ----------
function addText(parts, text) {
  const last = parts[parts.length - 1];
  if (last?.type === "text") last.text += text;
  else parts.push({ type: "text", text });
}

function addTool(parts, item) {
  const last = parts[parts.length - 1];
  if (last?.type === "tools") last.items.push(item);
  else parts.push({ type: "tools", items: [item] });
}

function buildTurns(messages) {
  const turns = [];
  const byId = new Map();
  for (const m of messages) {
    if (m.role === "user") turns.push({ user: m.content, parts: [] });
    else if (!turns.length) continue;
    else if (m.role === "assistant") {
      const turn = turns[turns.length - 1];
      turn.model = m.model || turn.model;
      if (m.content) addText(turn.parts, m.content);
      for (const c of m.tool_calls || []) {
        const item = { id: c.id, name: c.function.name, args: c.function.arguments, running: false, summary: "not run", ok: false };
        byId.set(c.id, item);
        addTool(turn.parts, item);
      }
    } else if (m.role === "tool" && byId.has(m.tool_call_id)) {
      Object.assign(byId.get(m.tool_call_id), { summary: m.summary, ok: m.ok, preview: m.preview });
    }
  }
  return turns;
}

// ---------- sidebar ----------
function renderSidebar() {
  const side = clear($("sidebar"));
  const currentId = state.current?.session?.id;
  append(side, [
    h("div", { class: "brand" },
      h("div", { class: "brand-mark" }, icon("logo")),
      h("div", { class: "brand-name" }, "gGest Assistant", h("small", {}, "Business answers from your ERP")),
      h("button", { class: "icon-btn", title: "Hide sidebar", onclick: toggleSidebar }, icon("sidebar"))),
    h("button", { class: "new-chat", onclick: () => newChat() }, icon("edit"), "New chat"),
    h("div", { class: "side-scroll" },
      h("div", { class: "side-label" }, "Projects",
        h("button", { class: "icon-btn sm", title: "Add a project (another gGest database)", onclick: () => projectModal() }, icon("plus"))),
      state.projects.length ? state.projects.map((p) => projectBlock(p, currentId))
        : h("div", { class: "empty-side" }, "No projects yet. Add one for each gGest database.")),
    h("div", { class: "side-foot" },
      h("button", { class: "model-chip", title: "Settings", onclick: settingsModal },
        h("span", { class: `dot ${state.settings.has_key ? "" : "off"}` }),
        h("span", {}, state.settings.has_key ? modelLabel(state.settings.model) : "Add your OpenRouter key")),
      h("button", { class: "icon-btn", title: isDark() ? "Light theme" : "Dark theme",
        onclick: () => { setTheme(isDark() ? "light" : "dark"); renderSidebar(); } }, icon(isDark() ? "sun" : "moon")),
      h("button", { class: "icon-btn", title: "Settings", onclick: settingsModal }, icon("settings"))),
  ]);
}

function projectBlock(p, currentId) {
  const collapsed = state.collapsed.has(p.id);
  const toggle = () => {
    if (collapsed) state.collapsed.delete(p.id); else state.collapsed.add(p.id);
    saveCollapsed();
    renderSidebar();
  };
  return h("div", { class: `project ${collapsed ? "collapsed" : ""}` },
    h("div", { class: "project-row", onclick: toggle, title: p.db_path },
      icon("chevronDown", "chev"), icon("folder"), h("span", { class: "name" }, p.name),
      h("span", { class: "row-actions" },
        h("button", { class: "icon-btn sm", title: "New chat in this project", onclick: (e) => { e.stopPropagation(); newChat(p.id); } }, icon("plus")),
        h("button", { class: "icon-btn sm", title: "Project settings", onclick: (e) => { e.stopPropagation(); projectModal(p); } }, icon("settings")))),
    h("div", { class: "sessions" },
      p.sessions.length ? p.sessions.map((sess) => h("div", {
        class: `session ${sess.id === currentId ? "active" : ""} ${state.live.has(sess.id) ? "streaming" : ""}`,
        onclick: () => openSession(sess.id),
      },
      h("span", { class: "title" }, sess.title),
      h("span", { class: "when" }, relTime(sess.updated_at)),
      h("span", { class: "row-actions" },
        h("button", { class: "icon-btn sm", title: "Delete chat", onclick: (e) => { e.stopPropagation(); deleteSession(sess); } }, icon("trash")))))
        : h("div", { class: "empty-side" }, "No chats yet")));
}

function toggleSidebar() {
  const app = $("app");
  if (matchMedia("(max-width: 820px)").matches) app.classList.toggle("sidebar-open");
  else app.classList.toggle("sidebar-hidden");
  renderMain();
}

// ---------- navigation ----------
function newChat(projectId) {
  const pid = projectId || state.current?.projectId || state.projects[0]?.id;
  state.current = { session: null, projectId: pid, messages: [], draftModel: null };
  state.collapsed.delete(pid);
  renderSidebar();
  renderMain();
  $("composer-input")?.focus();
}

async function openSession(id) {
  try {
    const session = await api.session(id);
    state.current = { session, projectId: session.project_id, messages: session.messages };
    state.stick = true;
    $("app").classList.remove("sidebar-open");
    renderSidebar();
    renderMain();
  } catch (e) {
    toast(e.message, "err");
  }
}

async function deleteSession(sess) {
  if (!confirm(`Delete the chat “${sess.title}”?`)) return;
  await api.deleteSession(sess.id);
  state.live.get(sess.id)?.controller.abort();
  const p = projectOf(sess.project_id);
  p.sessions = p.sessions.filter((x) => x.id !== sess.id);
  if (state.current?.session?.id === sess.id) newChat(sess.project_id);
  else renderSidebar();
}

// ---------- main pane ----------
function renderMain() {
  const main = clear($("main"));
  if (!state.settings.has_key) return main.append(setupView());
  if (!state.projects.length) return main.append(topbar(), noProjectView());
  const cur = state.current;
  const live = cur.session && state.live.get(cur.session.id);
  const turns = buildTurns(cur.messages);
  const scroller = h("div", { class: "scroller", id: "scroller" });
  if (!turns.length && !live) scroller.append(heroView());
  else {
    const thread = h("div", { class: "thread", id: "thread" });
    turns.forEach((t, i) => thread.append(...turnView(t, { last: i === turns.length - 1 && !live })));
    if (live) thread.append(...turnView(live.turn, { live: true }));
    scroller.append(thread);
  }
  scroller.addEventListener("scroll", () => {
    state.stick = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 80;
    $("topbar")?.classList.toggle("scrolled", scroller.scrollTop > 4);
  });
  main.append(topbar(), scroller, composer(Boolean(live)));
  requestAnimationFrame(() => { if (state.stick) scroller.scrollTop = scroller.scrollHeight; });
}

function topbar() {
  const cur = state.current;
  const project = cur && projectOf(cur.projectId);
  const sidebarHidden = $("app").classList.contains("sidebar-hidden") || matchMedia("(max-width: 820px)").matches;
  const title = h("div", { class: "title", title: "Double-click to rename" }, cur?.session?.title || "New chat");
  if (cur?.session) title.addEventListener("dblclick", () => renameTitle(title));
  return h("div", { class: "topbar", id: "topbar" },
    sidebarHidden && h("button", { class: "icon-btn", title: "Show sidebar", onclick: toggleSidebar }, icon("sidebar")),
    title,
    project && h("span", { class: "crumb" }, icon("db"), project.name),
    h("span", { class: "spacer" }),
    state.settings.has_key && modelMenu());
}

function renameTitle(el) {
  el.contentEditable = "true";
  el.focus();
  document.getSelection().selectAllChildren(el);
  const done = async (save) => {
    el.contentEditable = "false";
    const title = el.textContent.trim();
    if (!save || !title) return renderMain();
    const s = await api.updateSession(state.current.session.id, { title });
    state.current.session.title = s.title;
    const p = projectOf(s.project_id);
    p.sessions = p.sessions.map((x) => (x.id === s.id ? { ...x, title: s.title } : x));
    renderSidebar();
    renderMain();
  };
  el.addEventListener("keydown", (e) => {
    if (e.key === "Enter") { e.preventDefault(); done(true); }
    if (e.key === "Escape") done(false);
  });
  el.addEventListener("blur", () => done(true), { once: true });
}

function modelMenu() {
  const wrap = h("div", { class: "model-select" });
  const btn = h("button", { class: "model-btn", onclick: (e) => { e.stopPropagation(); open(); } },
    icon("sparkle"), modelLabel(activeModel()), icon("chevronDown"));
  wrap.append(btn);
  function open() {
    if (wrap.querySelector(".menu")) return close();
    const current = activeModel();
    const menu = h("div", { class: "menu" },
      state.models.map((m) => h("button", { class: `menu-item ${m.id === current ? "selected" : ""}`, onclick: () => choose(m.id) },
        h("div", {}, h("div", { class: "mi-title" }, m.label), h("div", { class: "mi-sub" }, m.note)), icon("check", "check"))),
      h("div", { class: "menu-sep" }),
      h("button", { class: "menu-item", onclick: () => { close(); settingsModal(); } },
        h("div", {}, h("div", { class: "mi-title" }, "Other model…"), h("div", { class: "mi-sub" }, "Any OpenRouter model id, in Settings"))));
    wrap.append(menu);
    setTimeout(() => document.addEventListener("click", close, { once: true }));
  }
  function close() { wrap.querySelector(".menu")?.remove(); }
  async function choose(id) {
    close();
    const cur = state.current;
    if (cur.session) cur.session = { ...cur.session, ...(await api.updateSession(cur.session.id, { model: id })) };
    else cur.draftModel = id;
    renderMain();
  }
  return wrap;
}

// ---------- a turn ----------
function turnView(turn, { live = false, last = false } = {}) {
  const user = h("div", { class: "msg-user" }, h("div", { class: "bubble" }, turn.user));
  return [user, assistantView(turn, live, last)];
}

function assistantView(turn, live, last) {
  const body = h("div", { class: "a-body" });
  turn.parts.forEach((part, i) => {
    const isLast = i === turn.parts.length - 1;
    if (part.type === "text") body.append(...textView(part.text, live && isLast));
    else body.append(stepsView(part, live && isLast));
  });
  if (live && (!turn.parts.length || turn.parts[turn.parts.length - 1].type === "tools" && !turn.parts.at(-1).items.some((x) => x.running))) {
    body.append(h("div", { class: "thinking" }, h("span", { class: "spinner" }), turn.parts.length ? "Reading the results…" : "Thinking…"));
  }
  if (turn.error) body.append(h("div", { class: "error-card" }, icon("alert"), turn.error));
  if (!live) body.append(actions(turn));
  return h("div", { class: "msg-assistant" }, h("div", { class: `avatar ${live ? "busy" : ""}` }, icon("logo")), body);
}

function textView(text, streaming) {
  const segs = parseSegments(text, streaming);
  const out = segs.map((seg) => (seg.kind === "md" ? Object.assign(h("div", { class: "md" }), { innerHTML: markdown(seg.text) })
    : renderSegment(seg, { onAsk: (q) => send(q) })));
  if (streaming) {
    const lastMd = [...out].reverse().find((el) => el.classList.contains("md"));
    if (lastMd && segs[segs.length - 1]?.kind === "md") {
      const tail = lastMd.lastElementChild || lastMd;
      tail.classList.add("caret");
    }
  }
  return out;
}

function argsPreview(raw) {
  try {
    const args = JSON.parse(raw || "{}");
    return Object.entries(args).map(([k, v]) => `${k}=${typeof v === "object" ? JSON.stringify(v) : v}`).join("  ");
  } catch {
    return raw || "";
  }
}

function prettyJson(raw) {
  try { return JSON.stringify(JSON.parse(raw), null, 2); } catch { return raw || ""; }
}

function resultPreview(p) {
  if (!p.columns) return h("pre", {}, prettyJson(p.text));
  const more = p.row_count > p.rows.length ? `${p.row_count - p.rows.length} more rows` : "";
  return h("div", { class: "w-table mini" }, h("table", {},
    h("thead", {}, h("tr", {}, p.columns.map((c) => h("th", {}, c)))),
    h("tbody", {}, p.rows.map((r) => h("tr", {}, r.map((v) => h("td", {}, v === null ? "" : typeof v === "object" ? JSON.stringify(v) : String(v))))))),
  more && h("div", { class: "help" }, more));
}

function stepsView(part, live) {
  const running = part.items.find((x) => x.running);
  const failed = part.items.filter((x) => !x.running && !x.ok).length;
  const label = running ? `Running ${running.name}…`
    : `Used ${part.items.length} tool${part.items.length > 1 ? "s" : ""}${failed ? ` · ${failed} failed` : ""}`;
  const box = h("div", { class: `steps ${part.open ? "open" : ""}` });
  const head = h("button", { class: "steps-head", onclick: () => { part.open = !part.open; box.classList.toggle("open"); } },
    running ? h("span", { class: "spinner" }) : icon("tool"), label, icon("chevronDown", "chev"));
  const list = h("div", { class: "steps-list" }, part.items.map((it) => {
    const step = h("div", { class: `step ${it.open ? "open" : ""}` });
    const status = it.running ? h("span", { class: "status" }, h("span", { class: "spinner" }))
      : h("span", { class: `status ${it.ok ? "ok" : "err"}` }, icon(it.ok ? "check" : "x"));
    step.append(
      h("div", { class: "step-row", onclick: () => { it.open = !it.open; step.classList.toggle("open"); } },
        status, h("span", { class: "step-name" }, it.name), h("span", { class: "step-args" }, argsPreview(it.args)),
        h("span", { class: `step-sum ${it.ok || it.running ? "" : "err"}` }, it.running ? "" : it.summary || "")),
      h("div", { class: "step-detail" },
        h("div", { class: "lbl2" }, "Arguments"), h("pre", {}, prettyJson(it.args)),
        it.preview && h("div", { class: "lbl2" }, "Result"), it.preview && resultPreview(it.preview)));
    return step;
  }));
  box.append(head, list);
  if (live && running) box.classList.add("open");
  return box;
}

function actions(turn) {
  const text = turn.parts.filter((p) => p.type === "text").map((p) => p.text).join("\n\n");
  const copyBtn = h("button", { class: "icon-btn sm", title: "Copy answer", onclick: async () => {
    await navigator.clipboard.writeText(text.replace(/<ui-element[\s\S]*?<\/ui-element>/g, "").trim());
    copyBtn.replaceChildren(icon("check"));
    setTimeout(() => copyBtn.replaceChildren(icon("copy")), 1400);
  } }, icon("copy"));
  return h("div", { class: "a-actions" }, text && copyBtn, turn.model && h("span", { class: "meta-note" }, modelLabel(turn.model)));
}

// ---------- empty states ----------
function heroView() {
  const project = projectOf(state.current.projectId);
  return h("div", { class: "hero" },
    h("div", { class: "avatar" }, icon("logo")),
    h("h1", {}, "What would you like to know?"),
    h("p", {}, `Ask about sales, customers, repairs, stock or money owed — answered from ${project?.name || "your"} gGest data.`),
    h("div", { class: "starters" }, STARTERS.map((s) => h("button", { class: "starter", onclick: () => send(s.q) },
      h("div", { class: "s-ico" }, icon(s.icon)), h("b", {}, s.title), h("span", {}, s.sub)))));
}

function noProjectView() {
  return h("div", { class: "hero" },
    h("div", { class: "avatar" }, icon("db")),
    h("h1", {}, "Add your first project"),
    h("p", {}, "A project is one gGest database (the data.sqlite built by ggest-cli). Chats live inside a project."),
    h("button", { class: "btn primary", onclick: () => projectModal() }, icon("plus"), "Add a project"));
}

function setupView() {
  let model = state.settings.model || state.models[0]?.id;
  const keyInput = h("input", { class: "field", type: "password", placeholder: "sk-or-v1-…", autocomplete: "off" });
  const result = h("div", {});
  const models = modelPicker(() => model, (id) => { model = id; });
  const start = async () => {
    const key = keyInput.value.trim();
    if (!key) return keyInput.focus();
    result.replaceChildren(h("div", { class: "test-result" }, h("span", { class: "spinner" }), "Checking the key…"));
    const check = await api.testKey(key).catch((e) => ({ ok: false, message: e.message }));
    if (!check.ok) return result.replaceChildren(h("div", { class: "test-result err" }, icon("errCircle"), check.message));
    state.settings = await api.saveSettings({ api_key: key, model });
    toast("Key saved. You're ready to go.");
    await load();
  };
  keyInput.addEventListener("keydown", (e) => { if (e.key === "Enter") start(); });
  return h("div", { class: "scroller" }, h("div", { class: "setup" },
    h("div", { class: "brand-mark", style: { width: "40px", height: "40px", borderRadius: "11px", marginBottom: "14px" } }, icon("logo")),
    h("h2", {}, "Welcome to gGest Assistant"),
    h("p", { class: "help", style: { fontSize: "14px" } }, "Ask questions about your business in plain language. Answers come from your gGest data, read-only."),
    h("label", { class: "lbl" }, h("span", { class: "step-n" }, "1"), "OpenRouter API key"),
    keyInput,
    h("div", { class: "help" }, "Create one at ", h("a", { href: "https://openrouter.ai/keys", target: "_blank", rel: "noopener" }, "openrouter.ai/keys"),
      ". It is stored only on this computer."),
    result,
    h("label", { class: "lbl" }, h("span", { class: "step-n" }, "2"), "Model"),
    models,
    h("div", { style: { marginTop: "18px", display: "flex", justifyContent: "flex-end" } },
      h("button", { class: "btn primary", onclick: start }, "Check key and start", icon("arrowRight")))));
}

function modelPicker(get, set) {
  const box = h("div", { class: "models" });
  const draw = () => box.replaceChildren(...state.models.map((m) => h("label", { class: `model-opt ${get() === m.id ? "selected" : ""}` },
    h("input", { type: "radio", name: "model", checked: get() === m.id, onchange: () => { set(m.id); draw(); } }),
    h("div", {}, h("div", { class: "mo-title" }, m.label), h("div", { class: "mo-sub" }, m.note)),
    h("span", { class: "vendor" }, m.vendor))));
  draw();
  return box;
}

// ---------- composer and sending ----------
function composer(busy) {
  const project = projectOf(state.current?.projectId);
  const input = h("textarea", { id: "composer-input", rows: 1, placeholder: busy ? "Answering…" : `Ask about ${project?.name || "your business"}…` });
  input.value = state.current?.draftText || "";
  const sendBtn = h("button", { class: `send ${busy ? "stop" : ""}`, title: busy ? "Stop" : "Send (Enter)" }, icon(busy ? "stop" : "send"));
  sendBtn.disabled = !busy && !input.value.trim();
  input.addEventListener("input", () => {
    autosize(input);
    state.current.draftText = input.value;
    if (!busy) sendBtn.disabled = !input.value.trim();
  });
  input.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
      e.preventDefault();
      if (!busy && input.value.trim()) send(input.value);
    }
  });
  sendBtn.addEventListener("click", () => (busy ? stop() : send(input.value)));
  requestAnimationFrame(() => autosize(input));
  return h("div", { class: "composer-wrap" },
    h("div", { class: "composer" }, input,
      h("div", { class: "composer-bar" },
        h("span", { class: "hint" }, icon("db"), h("span", {}, project ? `${project.name} · read-only` : "")),
        sendBtn)),
    h("div", { class: "disclaimer" }, "Answers can be wrong: check important figures in gGest."));
}

function stop() {
  const id = state.current?.session?.id;
  state.live.get(id)?.controller.abort();
}

async function ensureSession() {
  const cur = state.current;
  if (cur.session) return cur.session;
  const session = await api.createSession(cur.projectId, cur.draftModel || null);
  cur.session = session;
  projectOf(session.project_id).sessions.unshift(session);
  return session;
}

async function send(text) {
  text = (text || "").trim();
  if (!text || !state.current) return;
  if (state.current.session && state.live.has(state.current.session.id)) return;
  let session;
  try {
    session = await ensureSession();
  } catch (e) {
    return toast(e.message, "err");
  }
  state.current.draftText = "";
  const turn = { user: text, parts: [], model: session.model || state.settings.model };
  const controller = new AbortController();
  state.live.set(session.id, { controller, turn });
  state.stick = true;
  renderSidebar();
  renderMain();
  const items = new Map();
  let frame = 0;
  const repaint = () => {
    if (frame) return;
    frame = requestAnimationFrame(() => {
      frame = 0;
      if (state.current?.session?.id === session.id) renderLive(session.id);
    });
  };
  const onEvent = (ev) => {
    if (ev.type === "text") addText(turn.parts, ev.delta);
    else if (ev.type === "tool_start") {
      const item = { id: ev.id, name: ev.name, args: ev.args, running: true };
      items.set(ev.id, item);
      addTool(turn.parts, item);
    } else if (ev.type === "tool_end") Object.assign(items.get(ev.id) || {}, { running: false, ok: ev.ok, summary: ev.summary, preview: ev.preview });
    else if (ev.type === "title") renameInSidebar(session.id, ev.title);
    else if (ev.type === "error") turn.error = ev.message;
    repaint();
  };
  try {
    await streamChat(session.id, text, onEvent, controller.signal);
  } catch (e) {
    if (e.name !== "AbortError") turn.error = e.message;
  }
  state.live.delete(session.id);
  await refreshSession(session.id, turn.error);
}

function renameInSidebar(sessionId, title) {
  for (const p of state.projects) {
    for (const s of p.sessions) if (s.id === sessionId) s.title = title;
  }
  if (state.current?.session?.id === sessionId) state.current.session.title = title;
  renderSidebar();
  const t = document.querySelector(".topbar .title");
  if (t && state.current?.session?.id === sessionId) t.textContent = title;
}

function renderLive(sessionId) {
  const thread = $("thread");
  const live = state.live.get(sessionId);
  if (!thread || !live) return renderMain();
  const old = thread.lastElementChild;
  old.replaceWith(assistantView(live.turn, true, false));
  const scroller = $("scroller");
  if (state.stick) scroller.scrollTop = scroller.scrollHeight;
}

async function refreshSession(sessionId, error) {
  const session = await api.session(sessionId).catch(() => null);
  for (const p of state.projects) {
    p.sessions = p.sessions.map((s) => (s.id === sessionId && session ? { ...s, title: session.title, updated_at: Date.now() / 1000 } : s));
    p.sessions.sort((a, b) => b.updated_at - a.updated_at);
  }
  if (session && state.current?.session?.id === sessionId) {
    state.current.session = session;
    state.current.messages = session.messages;
    if (error) toast(error, "err");
  }
  renderSidebar();
  renderMain();
}

// ---------- modals ----------
function modal(title, bodyEls, footEls) {
  const back = h("div", { class: "modal-back" });
  const close = () => { back.remove(); document.removeEventListener("keydown", esc); };
  const esc = (e) => { if (e.key === "Escape") close(); };
  document.addEventListener("keydown", esc);
  back.addEventListener("mousedown", (e) => { if (e.target === back) close(); });
  back.append(h("div", { class: "modal", role: "dialog", "aria-label": title },
    h("div", { class: "modal-head" }, h("h2", {}, title), h("button", { class: "icon-btn", title: "Close", onclick: close }, icon("x"))),
    h("div", { class: "modal-body" }, bodyEls),
    h("div", { class: "modal-foot" }, footEls(close))));
  $("overlay").append(back);
  back.querySelector("input, textarea")?.focus();
  return close;
}

function settingsModal() {
  let model = state.settings.model;
  const known = state.models.some((m) => m.id === model);
  const keyInput = h("input", { class: "field", type: "password", autocomplete: "off",
    placeholder: state.settings.has_key ? `Saved: ${state.settings.key_hint} — paste a new key to replace it` : "sk-or-v1-…" });
  const custom = h("input", { class: "field", placeholder: "e.g. meta-llama/llama-5-maverick", value: known ? "" : model || "" });
  const result = h("div", {});
  const picker = modelPicker(() => model, (id) => { model = id; custom.value = ""; });
  const theme = localStorage.getItem("theme") || "system";
  const seg = h("div", { class: "seg" }, ["system", "light", "dark"].map((t) =>
    h("button", { class: t === theme ? "on" : "", onclick: (e) => {
      setTheme(t);
      seg.querySelectorAll("button").forEach((b) => b.classList.remove("on"));
      e.currentTarget.classList.add("on");
      renderSidebar();
    } }, t[0].toUpperCase() + t.slice(1))));
  const test = async () => {
    result.replaceChildren(h("div", { class: "test-result" }, h("span", { class: "spinner" }), "Checking…"));
    const r = await api.testKey(keyInput.value.trim()).catch((e) => ({ ok: false, message: e.message }));
    result.replaceChildren(r.ok
      ? h("div", { class: "test-result ok" }, icon("okCircle"), `Key works${r.label ? ` (${r.label})` : ""}${r.usage != null ? ` · used $${Number(r.usage).toFixed(2)}` : ""}`)
      : h("div", { class: "test-result err" }, icon("errCircle"), r.message));
  };
  modal("Settings", [
    h("div", { class: "section" },
      h("h3", {}, "OpenRouter"),
      h("label", { class: "lbl" }, "API key"),
      h("div", { class: "inline-row" }, keyInput, h("button", { class: "btn", onclick: test }, "Test")),
      h("div", { class: "help" }, "Stored only on this computer. Get a key at ",
        h("a", { href: "https://openrouter.ai/keys", target: "_blank", rel: "noopener" }, "openrouter.ai/keys"), "."),
      result),
    h("div", { class: "section" },
      h("h3", {}, "Default model"),
      h("div", { class: "help" }, "Used for new chats. Each chat can switch model from the top bar."),
      picker,
      h("label", { class: "lbl" }, "Or any OpenRouter model id"),
      custom,
      h("div", { class: "help" }, "The model must support tool calling.")),
    h("div", { class: "section" }, h("h3", {}, "Appearance"), h("div", { style: { marginTop: "8px" } }, seg)),
  ], (close) => [
    state.settings.has_key && h("button", { class: "btn danger", style: { marginRight: "auto" }, onclick: async () => {
      if (!confirm("Remove the saved OpenRouter key from this computer?")) return;
      state.settings = await api.saveSettings({ api_key: "" });
      close(); renderSidebar(); renderMain();
    } }, "Remove key"),
    h("button", { class: "btn", onclick: close }, "Cancel"),
    h("button", { class: "btn primary", onclick: async () => {
      try {
        const data = { model: custom.value.trim() || model };
        if (keyInput.value.trim()) data.api_key = keyInput.value.trim();
        state.settings = await api.saveSettings(data);
        close(); toast("Settings saved"); renderSidebar(); renderMain();
      } catch (e) { toast(e.message, "err"); }
    } }, "Save"),
  ]);
}

function projectModal(project) {
  const name = h("input", { class: "field", value: project?.name || "", placeholder: "e.g. Inforbyte" });
  const path = h("input", { class: "field", value: project?.db_path || "", placeholder: "C:\\…\\data\\data.sqlite" });
  const notes = h("textarea", { class: "field", rows: 4, placeholder: "Optional: what the assistant should know about this company (business units, special invoice series, priorities)…" });
  notes.value = project?.instructions || "";
  modal(project ? "Project settings" : "Add a project", [
    h("label", { class: "lbl" }, "Name"), name,
    h("label", { class: "lbl" }, "gGest database"), path,
    h("div", { class: "help" }, "The data.sqlite file built by ggest-cli (pipeline/refresh.py) for this company."),
    h("label", { class: "lbl" }, "Notes for the assistant"), notes,
  ], (close) => [
    project && h("button", { class: "btn danger", style: { marginRight: "auto" }, onclick: async () => {
      if (!confirm(`Delete the project “${project.name}” and all its chats? The database file is not touched.`)) return;
      await api.deleteProject(project.id);
      state.projects = state.projects.filter((p) => p.id !== project.id);
      close();
      if (state.current?.projectId === project.id) newChat(state.projects[0]?.id); else renderSidebar();
    } }, "Delete project"),
    h("button", { class: "btn", onclick: close }, "Cancel"),
    h("button", { class: "btn primary", onclick: async () => {
      const data = { name: name.value.trim(), db_path: path.value.trim(), instructions: notes.value };
      try {
        if (project) Object.assign(project, await api.updateProject(project.id, data));
        else {
          const created = await api.createProject(data);
          state.projects.push(created);
          state.current = { session: null, projectId: created.id, messages: [] };
        }
        close(); renderSidebar(); renderMain();
      } catch (e) { toast(e.message, "err"); }
    } }, project ? "Save" : "Add project"),
  ]);
}

// ---------- start ----------
async function load() {
  try {
    const data = await api.state();
    Object.assign(state, { settings: data.settings, models: data.models, projects: data.projects });
  } catch (e) {
    toast(`Could not reach the assistant server: ${e.message}`, "err");
    return;
  }
  const recent = state.projects.flatMap((p) => p.sessions).sort((a, b) => b.updated_at - a.updated_at)[0];
  renderSidebar();
  if (recent && state.settings.has_key) await openSession(recent.id);
  else newChat(state.projects[0]?.id);
}

matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => renderSidebar());
load();
