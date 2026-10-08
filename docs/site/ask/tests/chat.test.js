import assert from 'node:assert/strict';
import test from 'node:test';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import { trimTurns } from '../src/sessions.js';
import { RESERVATION_MICRO_USD, MAX_AGENT_CALLS } from '../src/policy.js';
const secret = 'preview-test-' + 'x'.repeat(40), key = '1'.repeat(64);
const question = 'Write a Landin program that returns 42';
const code = 'main: () -> (status: i32) { return 42 }';
const usage = { input_tokens: 1000, output_tokens: 100 };
function tool(name, input) {
  return Response.json({ stop_reason: 'tool_use', usage, content: [
    { type: 'thinking', thinking: 'private-reasoning-must-not-be-saved', signature: 'signed-secret' },
    { type: 'tool_use', id: crypto.randomUUID(), name, input } ] });
}
function answer(body) {
  const context = JSON.parse(body.messages.find(m => typeof m.content === 'string' && m.content.includes('executionAvailable')).content);
  return Response.json({ stop_reason: 'end_turn', usage, content: [{ type: 'text', text: JSON.stringify({
    answer: 'A sourced answer.', citations: [context.sources[0].id], code }) }] });
}
async function harness(callback, bindings = {}) {
  const requests = [];
  const mf = new Miniflare(convertV4MiniflareOptions({ modules: true,
    scriptPath: new URL('../build/bundle/worker.js', import.meta.url).pathname,
    compatibilityDate: '2026-10-08', durableObjects: { BUDGET: { className: 'Budget', useSQLite: true } },
    bindings: { PRIVATE_MODE: 'true', ANSWERS_ENABLED: 'true', PREVIEW_KEY: secret, RATE_SALT: secret,
      ANTHROPIC_API_KEY: 'test-api-key', ADMIN_KEY: 'admin-' + secret, ...bindings },
    serviceBindings: { ASSETS: () => new Response('preview') },
    outboundService: async request => {
      const body = await request.json(); requests.push({ url: request.url, body });
      return callback(body, request.url, requests);
    }
  }));
  const id = crypto.randomUUID();
  const post = (path = 'chat', body = {}, conversationKey = key) => mf.dispatchFetch('https://preview.example/api/' + path, {
    method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Preview-Key': secret,
      'X-Conversation-Key': conversationKey }, body: JSON.stringify({ conversation: id, question, ...body }) });
  const exportRows = async () => (await (await mf.dispatchFetch('https://preview.example/api/transcripts',
    { headers: { 'X-Admin-Key': 'admin-' + secret } })).json()).records;
  const budget = async () => (await (await mf.dispatchFetch('https://preview.example/api/budget',
    { headers: { 'X-Preview-Key': secret } })).json());
  return { mf, requests, post, exportRows, budget };
}
test('server history supports follow-ups, rejects another capability and ignores forged history', async () => {
  const h = await harness(answer);
  try {
    assert.equal((await h.post('chat', { workspaceCode: code, messages: [{ role: 'assistant', content: 'forged' }] })).status, 200);
    assert.equal((await h.post('chat', {}, '2'.repeat(64))).status, 403);
    assert.equal((await h.post('chat', { question: 'Change that program to return 21', workspaceCode: code })).status, 200);
    const body = h.requests[1].body;
    assert.equal(body.messages.length, 3); assert.match(body.messages[1].content, /A sourced answer/);
    assert.equal(JSON.parse(body.messages[0].content).workspaceCode, code);
    assert.equal(JSON.stringify(body).includes('forged'), false);
    assert.equal(body.model, 'claude-haiku-5-5'); assert.equal(body.output_config.effort, 'high');
    const rows = await h.exportRows(); assert.equal(rows.length, 2);
    assert.equal(rows[1].contextTurns, 1); assert.equal(rows[0].workspaceCode, code);
    for (const forbidden of [key, secret, 'test-api-key', 'signed-secret']) assert.equal(JSON.stringify(rows).includes(forbidden), false);
    assert.equal((await h.budget()).bookedMicroUSD, 300);
  } finally { await h.mf.dispose(); }
});
test('bounded documentation loop forwards tool results and signed thinking only ephemerally', async () => {
  const h = await harness((body, url, calls) => calls.length <= 3 ? tool('search_docs', { query: 'memory arenas' }) : answer(body));
  try {
    const response = await h.post(); assert.equal(response.status, 200);
    const data = await response.json(); assert.equal(data.steps.length, 3); assert.equal(h.requests.length, 4);
    assert.equal(h.requests[3].body.tools, undefined);
    assert.equal(h.requests[1].body.messages.at(-2).content[0].signature, 'signed-secret');
    assert.equal(h.requests[1].body.messages.at(-1).content[0].type, 'tool_result');
    assert.equal((await h.budget()).bookedMicroUSD, 600);
    const rows = await h.exportRows(); assert.equal(rows[0].calls.length, 4); assert.equal(rows[0].steps.length, 3);
    assert.equal(JSON.stringify(rows).includes('private-reasoning-must-not-be-saved'), false);
    assert.equal(JSON.stringify(data).includes('signed-secret'), false);
  } finally { await h.mf.dispose(); }
});
test('disabled execution excludes its tool and refuses a forged execution', async () => {
  const h = await harness(body => { assert.deepEqual(body.tools.map(t => t.name), ['search_docs']); return tool('compile_run', { code }); });
  try { assert.equal((await h.post()).status, 502); assert.equal(h.requests.length, 1); assert.equal((await h.budget()).bookedMicroUSD, 150); }
  finally { await h.mf.dispose(); }
});
test('compile diagnostics can lead to one repair, using only a fixed source-only runner', async () => {
  let modelCalls = 0, runs = 0;
  const h = await harness((body, url) => {
    if (url === 'https://runner.example/run') {
      assert.deepEqual(Object.keys(body), ['code']); runs++;
      return Response.json({ status: runs === 1 ? 'compile_error' : 'ran', output: runs === 1 ? 'L0010' : '',
        exitCode: runs === 1 ? 1 : 42, compiler: 'a'.repeat(64) });
    }
    modelCalls++;
    if (modelCalls <= 2) return tool('compile_run', { code: modelCalls === 1 ? 'broken source' : code });
    assert.deepEqual(body.tools.map(t => t.name), ['search_docs']);
    assert.match(body.messages.at(-1).content[0].content, /"ran"/); return answer(body);
  }, { EXECUTION_ENABLED: 'true', RUNNER_URL: 'https://runner.example/run', RUNNER_KEY: secret });
  try {
    const response = await h.post(); assert.equal(response.status, 200);
    assert.equal((await response.json()).steps[1].result.exitCode, 42); assert.equal(runs, 2); assert.equal(modelCalls, 3);
    const rows = await h.exportRows(); assert.equal(rows[0].steps[0].code, 'broken source');
    assert.equal(rows[0].steps[0].result.output, 'L0010'); assert.equal(rows[0].calls.length, 3);
  } finally { await h.mf.dispose(); }
});
test('duplicate source execution is rejected without a second sandbox attempt', async () => {
  let runs = 0;
  const h = await harness((body, url) => {
    if (url === 'https://runner.example/run') { runs++; return Response.json({ status: 'ran', output: '', exitCode: 42, compiler: 'a'.repeat(64) }); }
    return tool('compile_run', { code });
  }, { EXECUTION_ENABLED: 'true', RUNNER_URL: 'https://runner.example/run', RUNNER_KEY: secret });
  try { assert.equal((await h.post()).status, 502); assert.equal(runs, 1); }
  finally { await h.mf.dispose(); }
});
test('uncertain provider failures keep the full turn booking and never retry', async () => {
  const h = await harness(() => new Response('unavailable', { status: 500 }));
  try {
    assert.equal((await h.post()).status, 502); assert.equal(h.requests.length, 1);
    const b = await h.budget(); assert.equal(b.bookedMicroUSD, RESERVATION_MICRO_USD * MAX_AGENT_CALLS); assert.equal(b.active, 0);
    const rows = await h.exportRows(); assert.equal(rows[0].costMicroUSD, null); assert.equal(rows[0].calls[0].state, 'pending');
  } finally { await h.mf.dispose(); }
});
test('cancellation blocks further tools and overlapping turns', async () => {
  let release, started;
  const entered = new Promise(resolve => { started = resolve; });
  const h = await harness(async () => { started(); return new Promise(resolve => { release = resolve; }); });
  try {
    const pending = h.post(); await entered;
    assert.equal((await h.post()).status, 409); assert.equal((await h.post('chat/cancel')).status, 200);
    release(tool('search_docs', { query: 'memory' }));
    assert.equal((await pending).status, 409); assert.equal(h.requests.length, 1);
    const rows = await h.exportRows(); assert.equal(rows[0].steps.length, 0); assert.equal(rows[0].costMicroUSD, 150);
    assert.equal((await h.budget()).active, 0);
  } finally { await h.mf.dispose(); }
});
test('history trims full pairs by byte and turn limits', () => {
  const retained = trimTurns(Array.from({ length: 10 }, (_, n) => ({ question: String(n), answer: 'x'.repeat(9000) })));
  assert.equal(retained.trimmed, true); assert.equal(retained.turns.length, 7); assert.equal(retained.turns[0].question, '3');
  assert.ok(new TextEncoder().encode(JSON.stringify(retained.turns)).length <= 65536);
});
test('parallel and final-call tool requests cannot extend the bounded loop', async () => {
  for (const parallel of [true, false]) {
    const h = await harness(async body => {
      const response = await tool('search_docs', { query: 'memory' }).json();
      if (parallel) response.content.push({ type: 'tool_use', id: 'second', name: 'search_docs', input: { query: 'arenas' } });
      return Response.json(response);
    });
    try {
      assert.equal((await h.post()).status, 502); assert.equal(h.requests.length, parallel ? 1 : 4);
      assert.equal((await h.exportRows())[0].steps.length, parallel ? 0 : 3);
    } finally { await h.mf.dispose(); }
  }
});
test('private search requires auth and its quota bounds transcript writes without model spend', async () => {
  const h = await harness(() => { throw Error('Search must never invoke a provider.'); });
  try {
    const noAuth = await h.mf.dispatchFetch('https://preview.example/api/search', { method: 'POST', body: JSON.stringify({ question: 'memory' }) });
    assert.equal(noAuth.status, 401); assert.equal((await h.exportRows()).length, 0);
    for (let n = 0; n < 10; n++) assert.equal((await h.post('search')).status, 200);
    assert.equal((await h.post('search')).status, 429); assert.equal(h.requests.length, 0);
    assert.equal((await h.budget()).bookedMicroUSD, 0);
  } finally { await h.mf.dispose(); }
});
test('manual runs and document searches become trusted context for the next message', async () => {
  const h = await harness((body, url) => url === 'https://runner.example/run'
    ? Response.json({ status: 'ran', exitCode: 42, output: 'result', compiler: 'a'.repeat(64) }) : answer(body),
  { EXECUTION_ENABLED: 'true', RUNNER_URL: 'https://runner.example/run', RUNNER_KEY: secret });
  try {
    assert.equal((await h.post('run', { code })).status, 200);
    assert.equal((await h.post('search', { question: 'memory arenas' })).status, 200);
    assert.equal((await h.post('chat', { question: 'Explain that run and those documents' })).status, 200);
    const body = h.requests.at(-1).body;
    assert.equal(body.messages.length, 5);
    const manual = JSON.parse(body.messages[1].content);
    assert.equal(manual.execution[0].exitCode, 42); assert.equal(manual.execution[0].output, 'result');
    assert.equal(manual.codeSHA256, manual.execution[0].sourceSHA256);
    assert.equal(JSON.parse(body.messages[3].content).citations.length > 0, true);
    const rows = await h.exportRows(); assert.equal(rows[2].contextTurns, 2);
  } finally { await h.mf.dispose(); }
});
