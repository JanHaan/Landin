const byID = id => document.getElementById(id);
let config, widget, pending = false;
const conversation = crypto.randomUUID();

function busy(value) {
  pending = value;
  const question = byID("question").value;
  const validQuestion = Boolean(question.trim()) && new TextEncoder().encode(question).length <= 2048;
  byID("ask").disabled = value || !validQuestion || !config?.answers;
  byID("search").disabled = value || !validQuestion || !config;
  byID("run").disabled = value || !config?.execution;
}

async function token(action) {
  if (config.private) return "";
  if (!window.turnstile) throw new Error("Request verification is unavailable.");
  if (widget != null) window.turnstile.remove(widget);
  return new Promise((resolve, reject) => {
    widget = window.turnstile.render(byID("challenge"), {
      sitekey: config.turnstileSiteKey, action,
      callback: resolve,
      "error-callback": () => reject(new Error("Request verification failed.")),
      "expired-callback": () => reject(new Error("Request verification expired."))
    });
  });
}

async function call(operation, body) {
  const headers = { "Content-Type": "application/json" };
  if (operation !== "search") {
    if (config.private) headers["X-Preview-Key"] = byID("preview-key").value;
    else headers["X-Turnstile-Token"] = await token(operation);
  }
  const response = await fetch("/api/" + operation, { method: "POST", headers,
    body: JSON.stringify({ ...body, conversation }), signal: AbortSignal.timeout(operation === "run" ? 60_000 : 45_000) });
  const result = await response.json();
  if (!response.ok) throw new Error(result.error || "The request failed.");
  return result;
}

function sources(items) {
  byID("sources").replaceChildren();
  for (const item of items) {
    const url = new URL(item.url);
    if (url.origin !== "https://www.701.dev") continue;
    const li = document.createElement("li"), link = document.createElement("a");
    link.href = url.href; link.textContent = item.title;
    const note = document.createElement("small");
    note.textContent = item.source + " · " + item.authority;
    li.append(link, note); byID("sources").append(li);
  }
}

async function ask(operation) {
  if (pending) return;
  if (!byID("question").value.trim()) { byID("question").focus(); return; }
  busy(true); byID("status").textContent = "Looking up the documentation…";
  byID("result").hidden = true; byID("example").hidden = true;
  try {
    const data = await call(operation, { question: byID("question").value });
    // Never interpret model output or execution output as markup.
    byID("answer").textContent = data.answer || "Relevant documentation";
    sources(data.citations || data.sources || []);
    byID("result").hidden = false;
    if (data.code) {
      byID("code").value = data.code; byID("example").hidden = false;
      byID("output").textContent = ""; byID("run-status").textContent = "Not run.";
    }
    byID("status").textContent = "";
  } catch (error) { byID("status").textContent = error.message; }
  finally { busy(false); }
}

byID("ask-form").addEventListener("submit", event => { event.preventDefault(); ask("ask"); });
byID("question").addEventListener("input", () => busy(pending));
byID("search").addEventListener("click", () => ask("search"));
byID("new-program").addEventListener("click", () => {
  byID("example").hidden = false; byID("code").value = "";
  byID("code").focus(); byID("output").textContent = "";
  byID("run-status").textContent = "Not run.";
});
byID("run").addEventListener("click", async () => {
  if (pending) return;
  busy(true); byID("run-status").textContent = "Building and running…";
  byID("output").textContent = "";
  try {
    const data = await call("run", { code: byID("code").value });
    byID("run-status").textContent = `${data.status}; exit ${data.exitCode ?? "unavailable"}; compiler ${data.compiler}`;
    byID("output").textContent = data.output;
  } catch (error) { byID("run-status").textContent = error.message; }
  finally { busy(false); }
});

async function initialize() {
  const response = await fetch("/api/config");
  if (!response.ok) throw new Error("The service is unavailable.");
  config = await response.json();
  byID("private-access").hidden = !config.private || (!config.answers && !config.execution);
  byID("editor").hidden = !config.execution;
  byID("revision").textContent = `Documentation ${config.snapshot.sha256.slice(0, 12)}; commit ${config.snapshot.commit.slice(0, 12)}${config.snapshot.dirty ? "; local changes" : ""}`;
  if (!config.private) {
    const script = document.createElement("script");
    script.src = "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit";
    await new Promise((resolve, reject) => {
      script.onload = resolve;
      script.onerror = () => reject(new Error("Request verification is unavailable."));
      document.head.append(script);
    });
  }
  busy(false);
  if (!config.answers) byID("status").textContent = "Generated answers are unavailable. Documentation search is ready.";
}
initialize().catch(error => { byID("status").textContent = error.message; });
