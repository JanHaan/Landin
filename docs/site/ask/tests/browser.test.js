import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
import test from 'node:test';
const html = await readFile(new URL('../public/index.html', import.meta.url), 'utf8');
const script = await readFile(new URL('../public/ask.js', import.meta.url), 'utf8');
class Element {
  constructor() { this.value = ''; this.children = []; this.listeners = {}; this.disabled = false; this.hidden = false; }
  append(...nodes) { for (const node of nodes) { node.parent = this; this.children.push(node); } }
  replaceChildren(...nodes) { this.children = []; this.append(...nodes); }
  addEventListener(name, callback) { this.listeners[name] = callback; }
  remove() { if (this.parent) this.parent.children.splice(this.parent.children.indexOf(this), 1); }
  focus() {}
  get firstElementChild() { return this.children[0]; }
}
async function browser() {
  const nodes = new Map([...html.matchAll(/id="([^"]+)"/g)].map(m => [m[1], new Element()]));
  const requests = [];
  const document = { getElementById: id => nodes.get(id), createElement: () => new Element(), head: new Element() };
  const malicious = '<img src="https://attacker.example">';
  const context = vm.createContext({ document, window: {}, crypto, TextEncoder, URL, AbortSignal, AbortController,
    setTimeout, clearTimeout, fetch: async (url, options) => {
      if (url === '/api/config') return Response.json({ private: true, answers: true, execution: false,
        snapshot: { commit: 'c'.repeat(40), sha256: 'a'.repeat(64) } });
      const body = JSON.parse(options.body); requests.push({ url, body, headers: options.headers });
      return Response.json({ answer: malicious, code: 'main: () -> (status: i32) { return 42 }', citations: [
        { url: 'https://attacker.example/', title: 'bad' }, { url: 'https://www.701.dev/spec.html', title: malicious, source: 'spec.md', authority: 'normative' }
      ], steps: [] });
    } });
  vm.runInContext(script, context);
  await new Promise(resolve => setImmediate(resolve));
  return { nodes, requests, malicious, context };
}
test('two-pane browser sends follow-ups with workspace source and a stable private capability', async () => {
  const { nodes: n, requests, malicious } = await browser();
  assert.equal(n.get('ask').disabled, true);
  n.get('question').value = 'Write a program'; n.get('question').listeners.input();
  assert.equal(n.get('ask').disabled, true);
  n.get('preview-key').value = 'preview-key'; n.get('preview-key').listeners.input();
  assert.equal(n.get('ask').disabled, false);
  await n.get('ask-form').listeners.submit({ preventDefault() {} });
  // Submit handler triggers async ask without awaiting it.
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(requests[0].url, '/api/chat'); assert.equal(n.get('run').disabled, true);
  assert.match(n.get('code').value, /return 42/);
  assert.equal(n.get('conversation').children[1].children[1].textContent, malicious);
  const sources = n.get('conversation').children[1].children[2];
  assert.equal(sources.children.length, 1); assert.equal(sources.children[0].children[0].textContent, malicious);
  n.get('code').value = 'edited source'; n.get('code').listeners.input();
  n.get('question').value = 'Change it'; n.get('question').listeners.input();
  n.get('ask-form').listeners.submit({ preventDefault() {} });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(requests[1].body.workspaceCode, 'edited source');
  assert.equal(requests[0].body.conversation, requests[1].body.conversation);
  assert.equal(requests[0].headers['X-Conversation-Key'], requests[1].headers['X-Conversation-Key']);
  assert.equal(requests[0].body.messages, undefined);
  n.get('new-chat').listeners.click();
  n.get('question').value = 'Fresh chat'; n.get('question').listeners.input();
  n.get('ask-form').listeners.submit({ preventDefault() {} });
  await new Promise(resolve => setImmediate(resolve));
  assert.notEqual(requests[2].body.conversation, requests[0].body.conversation);
  assert.notEqual(requests[2].headers['X-Conversation-Key'], requests[0].headers['X-Conversation-Key']);
});
