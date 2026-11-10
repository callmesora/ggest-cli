// Assistant text -> segments: Markdown, inline <ui-element> widgets, and a placeholder for a widget still streaming.
/* global marked, DOMPurify */

const ELEMENT = /<ui-element\s+type\s*=\s*["']([\w-]+)["']\s*>([\s\S]*?)<\/ui-element>/g;
const FENCED = /```[\w-]*[ \t]*\n(\s*<ui-element[\s\S]*?<\/ui-element>\s*)\n?```/g;
const OPEN_TAG = "<ui-element";

function partialTagStart(text) {
  // "...<ui-el" at the very end while streaming: hide it until we know what it is
  const lt = text.lastIndexOf("<");
  if (lt < 0) return -1;
  const tail = text.slice(lt);
  return OPEN_TAG.startsWith(tail) || tail.startsWith(OPEN_TAG) ? lt : -1;
}

function widget(type, body) {
  try {
    return { kind: "widget", type, data: JSON.parse(body.trim()) };
  } catch {
    return { kind: "bad", type, raw: body.trim() };
  }
}

export function parseSegments(text, streaming = false) {
  const source = (text || "").replace(FENCED, "$1");
  const out = [];
  let last = 0;
  for (const m of source.matchAll(ELEMENT)) {
    if (m.index > last) out.push({ kind: "md", text: source.slice(last, m.index) });
    out.push(widget(m[1], m[2]));
    last = m.index + m[0].length;
  }
  let rest = source.slice(last);
  const open = rest.indexOf(OPEN_TAG);
  if (open >= 0) {
    const type = (rest.slice(open).match(/type\s*=\s*["']([\w-]+)/) || [])[1] || "widget";
    if (open > 0) out.push({ kind: "md", text: rest.slice(0, open) });
    out.push({ kind: "pending", type });
    return out;
  }
  if (streaming) {
    const cut = partialTagStart(rest);
    if (cut >= 0) rest = rest.slice(0, cut);
  }
  if (rest.trim()) out.push({ kind: "md", text: rest });
  return out.filter((s) => s.kind !== "md" || s.text.trim());
}

let hooked = false;
export function markdown(text) {
  if (!hooked) {
    DOMPurify.addHook("afterSanitizeAttributes", (node) => {
      if (node.tagName === "A") {
        node.setAttribute("target", "_blank");
        node.setAttribute("rel", "noopener noreferrer");
      }
    });
    hooked = true;
  }
  const html = marked.parse(text, { gfm: true, breaks: false });
  return DOMPurify.sanitize(html, { USE_PROFILES: { html: true } });
}
