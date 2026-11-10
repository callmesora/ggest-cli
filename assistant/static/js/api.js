// JSON API client and the chat stream reader (Server-Sent Events over a POST).

async function call(method, url, body) {
  const res = await fetch(url, {
    method,
    headers: body === undefined ? {} : { "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (res.status === 204) return null;
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `${res.status} ${res.statusText}`);
  return data;
}

export const api = {
  state: () => call("GET", "/api/state"),
  saveSettings: (data) => call("PUT", "/api/settings", data),
  testKey: (apiKey) => call("POST", "/api/settings/test", { api_key: apiKey || "" }),
  createProject: (data) => call("POST", "/api/projects", data),
  updateProject: (id, data) => call("PATCH", `/api/projects/${id}`, data),
  deleteProject: (id) => call("DELETE", `/api/projects/${id}`),
  createSession: (projectId, model) => call("POST", `/api/projects/${projectId}/sessions`, { model }),
  session: (id) => call("GET", `/api/sessions/${id}`),
  updateSession: (id, data) => call("PATCH", `/api/sessions/${id}`, data),
  deleteSession: (id) => call("DELETE", `/api/sessions/${id}`),
};

// Send a message and call onEvent(event) for every streamed event. Abort with signal to stop the answer.
export async function streamChat(sessionId, content, onEvent, signal) {
  const res = await fetch(`/api/sessions/${sessionId}/chat`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ content }),
    signal,
  });
  if (!res.ok) {
    const data = await res.json().catch(() => ({}));
    throw new Error(data.error || `${res.status} ${res.statusText}`);
  }
  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    let cut;
    while ((cut = buffer.indexOf("\n\n")) >= 0) {
      const chunk = buffer.slice(0, cut);
      buffer = buffer.slice(cut + 2);
      for (const line of chunk.split("\n")) {
        if (line.startsWith("data:")) onEvent(JSON.parse(line.slice(5).trim()));
      }
    }
  }
}
