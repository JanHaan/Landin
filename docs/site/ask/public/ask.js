const byID = id => document.getElementById(id);
let config, widget, pending = false, controller, conversation, conversationKey;
let lastRunCode = null, messageCount = 0;
function resetConversation() {
  conversation = crypto.randomUUID();
  conversationKey = [...crypto.getRandomValues(new Uint8Array(32))].map(n => n.toString(16).padStart(2, '0')).join('');
}
resetConversation();
function busy(value) {
  pending = value;
  const q = byID('question').value, source = byID('code').value;
  const valid = Boolean(q.trim()) && new TextEncoder().encode(q).length <= 2048;
  const access = !config?.private || Boolean(byID('preview-key').value.trim());
  byID('ask').disabled = value || !valid || !config?.answers || !access;
  byID('search').disabled = value || !valid || !config || !access;
  byID('run').disabled = value || !config?.execution || !access || !source.trim()
    || new TextEncoder().encode(source).length > 8192;
  byID('new-chat').disabled = value;
  byID('clear-code').disabled = value;
  byID('stop').hidden = !value || !controller;
}
async function token(action) {
  if (config.private) return '';
  if (!window.turnstile) throw new Error('Request verification is unavailable.');
  if (widget != null) window.turnstile.remove(widget);
  return new Promise((resolve, reject) => {
    widget = window.turnstile.render(byID('challenge'), { sitekey: config.turnstileSiteKey, action,
      callback: resolve, 'error-callback': () => reject(new Error('Request verification failed.')),
      'expired-callback': () => reject(new Error('Request verification expired.')) });
  });
}
async function call(operation, body, signal) {
  const headers = { 'Content-Type': 'application/json' };
  {
    if (config.private) headers['X-Preview-Key'] = byID('preview-key').value;
    else headers['X-Turnstile-Token'] = await token(operation.startsWith('chat') ? 'ask' : operation);
  }
  if (operation.startsWith('chat')) headers['X-Conversation-Key'] = conversationKey;
  const response = await fetch('/api/' + operation, { method: 'POST', headers,
    body: JSON.stringify({ ...body, conversation }), signal: signal || AbortSignal.timeout(60_000) });
  const result = await response.json();
  if (!response.ok) { const error = new Error(result.error || 'The request failed.'); error.steps = result.steps; throw error; }
  return result;
}
function appendSources(node, items) {
  const ul = document.createElement('ul');
  for (const item of items) {
    let url; try { url = new URL(item.url); } catch { continue; }
    if (url.origin !== 'https://www.701.dev') continue;
    const li = document.createElement('li'), link = document.createElement('a'), note = document.createElement('small');
    link.href = url.href; link.textContent = item.title;
    note.textContent = item.source + ' · ' + item.authority;
    li.append(link, note); ul.append(li);
  }
  node.append(ul);
}
function message(role, text, items = [], code = null) {
  byID('welcome')?.remove();
  const node = document.createElement('article'), label = document.createElement('div'), content = document.createElement('div');
  node.className = 'message ' + role; label.className = 'message-label'; content.className = 'message-text';
  label.textContent = role === 'user' ? 'You' : 'Landin'; content.textContent = text;
  node.append(label, content); if (items.length) appendSources(node, items);
  if (code) {
    const button = document.createElement('button'); button.type = 'button'; button.textContent = 'Open this source';
    button.addEventListener('click', () => { byID('code').value = code; sourceChanged(); }); node.append(button);
  }
  byID('conversation').append(node);
  // Limit browser DOM growth without deleting the private transcripts.
  if (++messageCount > 64) byID('conversation').firstElementChild?.remove();
  byID('conversation').scrollTop = byID('conversation').scrollHeight;
  return node;
}
function sourceChanged() {
  byID('run-status').textContent = byID('code').value === lastRunCode ? 'Console result matches this source.' : 'Current source has not been run.';
  busy(pending);
}
function execution(result, code, label = 'Assistant run') {
  const entry = document.createElement('div'), heading = document.createElement('div'), output = document.createElement('pre');
  entry.className = 'console-entry';
  heading.textContent = `${label} · ${result.status} · exit ${result.exitCode ?? 'unavailable'}`;
  output.textContent = result.output || '(no output)';
  const details = document.createElement('details'), summary = document.createElement('summary'), source = document.createElement('pre');
  summary.textContent = 'Source for this run'; source.textContent = code; details.append(summary, source);
  const compiler = document.createElement('small'); compiler.textContent = 'Compiler ' + result.compiler;
  entry.append(heading, output, details, compiler); byID('console').append(entry);
  if (byID('console').children.length > 20) byID('console').firstElementChild.remove();
  byID('console').scrollTop = byID('console').scrollHeight; lastRunCode = code;
}
async function ask(operation) {
  if (pending || !byID('question').value.trim()) return;
  const question = byID('question').value, source = byID('code').value;
  if (operation === 'chat') controller = new AbortController();
  busy(true); byID('status').textContent = operation === 'chat' ? 'Working on your message…' : 'Finding documentation…';
  message('user', question); byID('question').value = '';
  const timeout = controller ? setTimeout(() => controller.abort(), 100_000) : null;
  try {
    const data = await call(operation, { question, ...(operation === 'chat' ? { workspaceCode: source } : {}) }, controller?.signal);
    const node = message('assistant', data.answer || 'Relevant documentation', data.citations || data.sources || [], data.code);
    for (const step of data.steps || []) {
      const note = document.createElement('div'); note.className = 'tool-note';
      note.textContent = step.tool === 'search_docs' ? `Searched documentation: ${step.query}` : `Built and ran source: ${step.result?.status || step.state}`;
      node.append(note);
      if (step.result && step.code) execution(step.result, step.code);
    }
    if (data.code) { byID('code').value = data.code; sourceChanged(); }
    byID('status').textContent = data.contextTrimmed ? 'Older turns have left the model context. Full transcripts remain saved.' : '';
  } catch (error) {
    const text = error.name === 'AbortError' ? 'Stopped waiting. A current call may finish; no further steps are requested after cancellation.' : error.message;
    message('assistant', text); byID('status').textContent = text;
    for (const step of error.steps || []) if (step.result && step.code) execution(step.result, step.code);
    if (error.name === 'AbortError') call('chat/cancel', {}).catch(() => {});
  } finally { clearTimeout(timeout); controller = null; busy(false); }
}
byID('ask-form').addEventListener('submit', event => { event.preventDefault(); ask('chat'); });
byID('question').addEventListener('input', () => busy(pending));
byID('preview-key').addEventListener('input', () => {
  busy(pending);
  if (byID('preview-key').value.trim() && byID('status').textContent === 'Enter your private preview key to start chatting.') byID('status').textContent = 'Ready.';
});
byID('code').addEventListener('input', sourceChanged);
byID('search').addEventListener('click', () => ask('search'));
byID('stop').addEventListener('click', async () => {
  byID('stop').disabled = true; byID('status').textContent = 'Stopping after the current call…';
  try { await call('chat/cancel', {}); controller?.abort(); }
  catch (error) { byID('status').textContent = error.message; }
  finally { byID('stop').disabled = false; }
});
byID('new-chat').addEventListener('click', () => {
  resetConversation(); byID('conversation').replaceChildren(); byID('console').replaceChildren();
  byID('code').value = ''; byID('question').value = ''; byID('status').textContent = 'New conversation.';
  messageCount = 0; lastRunCode = null; sourceChanged(); byID('question').focus();
});
byID('clear-code').addEventListener('click', () => { byID('code').value = ''; sourceChanged(); });
byID('clear-console').addEventListener('click', () => byID('console').replaceChildren());
byID('run').addEventListener('click', async () => {
  if (pending) return; const source = byID('code').value;
  busy(true); byID('run-status').textContent = 'Building and running…';
  try { const result = await call('run', { code: source }); execution(result, source, 'Your run'); sourceChanged(); }
  catch (error) { byID('run-status').textContent = error.message; }
  finally { busy(false); }
});
async function initialize() {
  const response = await fetch('/api/config'); if (!response.ok) throw new Error('The service is unavailable.');
  config = await response.json(); byID('private-access').hidden = !config.private;
  byID('execution-state').textContent = config.execution ? 'Execution available' : 'Execution backend unavailable';
  byID('revision').textContent = `Documentation ${config.snapshot.sha256.slice(0, 12)}; commit ${config.snapshot.commit.slice(0, 12)}${config.snapshot.dirty ? '; local changes' : ''}`;
  if (!config.private) {
    const script = document.createElement('script'); script.src = 'https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit';
    await new Promise((resolve, reject) => { script.onload = resolve; script.onerror = () => reject(new Error('Request verification is unavailable.')); document.head.append(script); });
  }
  busy(false);
  if (!config.answers) byID('status').textContent = 'Generated answers are unavailable. Documentation search is ready.';
  else if (config.private) byID('status').textContent = 'Enter your private preview key to start chatting.';
}
initialize().catch(error => { byID('status').textContent = error.message; });
