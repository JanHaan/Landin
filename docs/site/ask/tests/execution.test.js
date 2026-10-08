import assert from "node:assert/strict";
import test from "node:test";
import { Execution } from "../src/execution.js";
import { createService } from "../src/service.js";
import { emptyLedger, reserve, settle } from "../src/ledger.js";
import { EXECUTION_MONTHLY_MICRO_USD, EXECUTION_RESERVATION_MICRO_USD } from "../src/policy.js";
import { readFile } from "node:fs/promises";

const secret = "test-" + "x".repeat(40);
const compiler = "a".repeat(64);
const environment = { EXECUTION_ENABLED: "true", COMPILER_SHA256: compiler };
const request = code => new Request("https://execution.internal/run", {
  method: "POST", body: JSON.stringify({ code, image: "attacker", command: "arbitrary" }) });

function fixture({ failCleanup = false, failRun = false, malformed = false } = {}) {
  const data = new Map(), events = [];
  const ctx = { storage: {
    get: async key => data.get(key), put: async (key, value) => data.set(key, value),
    delete: async key => data.delete(key), setAlarm: async value => data.set("alarm", value),
    deleteAlarm: async () => data.delete("alarm")
  }, blockConcurrencyWhile: callback => callback() };
  ctx.container = {
    running: false,
    start(options) { assert.deepEqual(options, { enableInternet: false }); this.running = true; events.push("start"); },
    async setInactivityTimeout(ms) { assert.equal(ms, 1000); },
    async inspect() { return this.running ? { image: "checked" } : null; },
    async destroy() {
      events.push("destroy");
      if (failCleanup) throw Error("cleanup failure");
      this.running = false;
    },
    getTcpPort(port) {
      assert.equal(port, 8080);
      return { async fetch(url, options) {
        if (url.endsWith("health")) return Response.json({ ready: true });
        events.push("run");
        assert.deepEqual(Object.keys(JSON.parse(options.body)), ["code"]);
        if (failRun) throw Error("lost response");
        return Response.json(malformed ? { status: "ran", output: "x".repeat(20_000) }
          : { status: "ran", exitCode: 42, output: "<script>untrusted</script>", compiler: "forged" });
      } };
    }
  };
  return { ctx, data, events, execution: new Execution(ctx, environment) };
}

test("Cloudflare compute has a separate monthly ceiling; uncertain jobs never refund", () => {
  const state = emptyLedger();
  state.executionMonths["2026-10"] = EXECUTION_MONTHLY_MICRO_USD - EXECUTION_RESERVATION_MICRO_USD;
  const now = Date.parse("2026-10-08T12:00:00Z");
  const first = { id: crypto.randomUUID(), operation: "run", client: "a".repeat(64), cloudflare: true };
  assert.equal(reserve(state, first, now).status, 200);
  settle(state, { id: first.id, cost: 0 });
  assert.equal(state.executionMonths["2026-10"], EXECUTION_MONTHLY_MICRO_USD);
  assert.equal(reserve(state, { ...first, id: crypto.randomUUID() }, now + 60_000).status, 429);
  settle(state, { id: first.id, cost: 0 });
  assert.equal(state.executionMonths["2026-10"], EXECUTION_MONTHLY_MICRO_USD);
  assert.equal(state.months["2026-10"], undefined);
});

test("one Cloudflare job uses fixed image config and returns trusted compiler identity after destruction", async () => {
  const f = fixture();
  const response = await f.execution.fetch(request("visitor program"));
  assert.equal(response.status, 200);
  assert.equal((await response.json()).compiler, compiler);
  assert.deepEqual(f.events, ["start", "run", "destroy"]);
  assert.equal(f.data.get("job"), undefined);
  assert.equal(f.data.get("alarm"), undefined);
});

test("lost execution response does not retry and still destroys the entire microVM", async () => {
  const f = fixture({ failRun: true });
  assert.equal((await f.execution.fetch(request("visitor program"))).status, 503);
  assert.deepEqual(f.events, ["start", "run", "destroy"]);
  assert.equal(f.ctx.container.running, false);
});

test("private lifecycle diagnostics distinguish startup from execution without retaining exception text", async () => {
  const f = fixture();
  f.ctx.container.start = () => { throw Error("connection reset: private-token-value"); };
  assert.equal((await f.execution.fetch(request("visitor program"))).status, 503);
  const response = await f.execution.fetch(new Request("https://execution.internal/diagnostics"));
  const { lastAttempt } = await response.json();
  assert.deepEqual(Object.keys(lastAttempt).sort(),
    ["started", "finished", "phase", "category", "status", "cleanupVerified"].sort());
  assert.equal(lastAttempt.phase, "startup");
  assert.equal(lastAttempt.category, "disconnected");
  assert.equal(lastAttempt.cleanupVerified, true);
  assert.ok(!JSON.stringify(lastAttempt).includes("private-token-value"));
  assert.deepEqual(f.events, ["destroy"]);
  const lost = fixture({ failRun: true });
  await lost.execution.fetch(request("source"));
  assert.equal(lost.data.get("lastAttempt").phase, "execution");
});

test("failed diagnostic persistence does not skip sandbox destruction", async () => {
  const f = fixture();
  const put = f.ctx.storage.put;
  f.ctx.storage.put = async (key, value) => {
    if (key === "lastAttempt") throw Error("storage unavailable");
    return put(key, value);
  };
  assert.equal((await f.execution.fetch(request("source"))).status, 503);
  assert.equal(f.ctx.container.running, false);
  assert.equal(f.data.get("job"), undefined);
  assert.deepEqual(f.events, ["start", "run", "destroy"]);
});

test("cleanup failure keeps a durable closed slot; alarm can only retry destruction", async () => {
  const f = fixture({ failCleanup: true });
  assert.equal((await f.execution.fetch(request("visitor program"))).status, 503);
  assert.ok(f.data.get("job"));
  assert.ok(f.data.get("alarm"));
  assert.equal((await f.execution.fetch(request("second program"))).status, 503);
  assert.equal(f.events.filter(e => e === "start").length, 1);
  await assert.rejects(f.execution.alarm());
  assert.equal(f.events.filter(e => e === "start").length, 1);
});

test("DO restart discards the previous container and never resumes its files or processes", async () => {
  const f = fixture();
  await f.execution.ready;
  f.data.set("job", { deadline: Date.now() + 1000 });
  f.ctx.container.running = true;
  const restarted = new Execution(f.ctx, environment);
  await restarted.ready;
  assert.deepEqual(f.events, ["destroy"]);
  assert.equal(f.data.get("job"), undefined);
});

test("the absolute deadline aborts a hung job and destroys the instance", async t => {
  t.mock.timers.enable({ apis: ["setTimeout", "Date"] });
  const f = fixture();
  let executing = false;
  f.ctx.container.getTcpPort = () => ({ async fetch(url, options) {
    if (url.endsWith("health")) return new Response("ready");
    executing = true;
    return new Promise((_, reject) => options.signal.addEventListener("abort", () => reject(Error("aborted")), { once: true }));
  } });
  const response = f.execution.fetch(request("infinite program"));
  while (!executing) await new Promise(resolve => setImmediate(resolve));
  t.mock.timers.tick(45_000);
  assert.equal((await response).status, 504);
  assert.equal(f.ctx.container.running, false);
  assert.equal(f.data.get("job"), undefined);
});

test("concurrent execution cannot start a second container", async () => {
  const f = fixture();
  const responses = await Promise.all([f.execution.fetch(request("first")), f.execution.fetch(request("second"))]);
  assert.deepEqual(responses.map(r => r.status).sort(), [200, 429]);
  assert.equal(f.events.filter(e => e === "start").length, 1);
});

test("the deadline also bounds startup configuration and cannot later run visitor code", async t => {
  t.mock.timers.enable({ apis: ["setTimeout", "Date"] });
  const f = fixture();
  let releaseStartup;
  f.ctx.container.setInactivityTimeout = () => new Promise(resolve => { releaseStartup = resolve; });
  const response = f.execution.fetch(request("visitor program"));
  while (!releaseStartup) await new Promise(resolve => setImmediate(resolve));
  t.mock.timers.tick(45_000);
  assert.equal((await response).status, 504);
  releaseStartup();
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(f.events, ["start", "destroy"]);
  assert.equal(f.data.get("job"), undefined);
});

test("malformed output is bounded and execution still cleans up", async () => {
  const f = fixture({ malformed: true });
  assert.equal((await f.execution.fetch(request("first"))).status, 502);
  assert.equal(f.ctx.container.running, false);
});

test("missing compiler identity and invalid source never start a sandbox", async () => {
  const f = fixture();
  assert.equal((await f.execution.fetch(request("x".repeat(8193)))).status, 400);
  assert.deepEqual(f.events, []);
  const disabled = new Execution(f.ctx, { ...environment, COMPILER_SHA256: "" });
  assert.equal((await disabled.fetch(request("valid"))).status, 503);
  assert.deepEqual(f.events, []);
});

test("public service reserves compute before calling only its private execution binding", async () => {
  const corpus = JSON.parse(await readFile(new URL("../build/corpus.json", import.meta.url)));
  const state = emptyLedger();
  let calls = 0;
  const env = { ...environment, EXECUTION_BACKEND: "cloudflare", PRIVATE_MODE: "true",
    PREVIEW_KEY: secret, RATE_SALT: secret, ANSWERS_ENABLED: "true",
    BUDGET: { idFromName: name => name, get: () => ({ async fetch(url, options) {
      const body = JSON.parse(options.body);
      const result = url.endsWith("reserve") ? reserve(state, body) : settle(state, body);
      return Response.json(result, { status: result.status });
    } }) },
    EXECUTION: { idFromName: name => { assert.equal(name, "landin-execution-v1"); return name; },
      get: () => ({ async fetch(url, options) {
        calls++;
        assert.equal(Object.values(state.executionMonths)[0], EXECUTION_RESERVATION_MICRO_USD);
        assert.deepEqual(Object.keys(JSON.parse(options.body)), ["code"]);
        return Response.json({ status: "ran", exitCode: 42, output: "ok", compiler });
      } }) }
  };
  const service = createService(corpus, () => { throw Error("no external runner"); });
  const incoming = new Request("https://ask.example/api/run", { method: "POST",
    headers: { "X-Preview-Key": secret }, body: JSON.stringify({ code: "source", url: "https://attacker.example" }) });
  assert.equal((await service.fetch(incoming, env)).status, 200);
  assert.equal(calls, 1);
  assert.equal(Object.values(state.executionMonths)[0], EXECUTION_RESERVATION_MICRO_USD);
});
test('administrator container status observes an empty sandbox without starting one', async () => {
  const f = fixture();
  const response = await f.execution.fetch(new Request('https://execution.internal/status'));
  assert.deepEqual(await response.json(), { busy: false, job: null, running: false, image: null });
  assert.deepEqual(f.events, []);
  const corpus = JSON.parse(await readFile(new URL('../build/corpus.json', import.meta.url)));
  const service = createService(corpus, () => { throw Error('Status never uses a provider'); });
  const env = { ADMIN_KEY: 'admin-' + secret, EXECUTION: { idFromName: name => name,
    get: () => ({ fetch: request => f.execution.fetch(new Request(request)) }) } };
  assert.equal((await service.fetch(new Request('https://preview.example/api/execution/status', { headers: { 'X-Admin-Key': secret } }), env)).status, 401);
  assert.equal((await service.fetch(new Request('https://preview.example/api/execution/status', { headers: { 'X-Admin-Key': 'admin-' + secret } }), env)).status, 200);
  assert.equal((await service.fetch(new Request('https://preview.example/api/execution/diagnostics', { headers: { 'X-Preview-Key': secret } }), env)).status, 401);
  const diagnostics = await service.fetch(new Request('https://preview.example/api/execution/diagnostics', { headers: { 'X-Admin-Key': 'admin-' + secret } }), env);
  assert.deepEqual(await diagnostics.json(), { lastAttempt: null });
});
