import assert from "node:assert/strict";
import test from "node:test";
import { Miniflare, convertV4MiniflareOptions } from "miniflare";
import { MONTHLY_MICRO_USD, RESERVATION_MICRO_USD } from "../src/policy.js";

test("real workerd provider fetch succeeds and refuses credential-bearing redirects", async () => {
  const secret = "runtime-test-" + "x".repeat(40);
  let redirect = false, calls = 0;
  const mf = new Miniflare(convertV4MiniflareOptions({ modules: true,
    scriptPath: new URL("../build/bundle/worker.js", import.meta.url).pathname,
    compatibilityDate: "2026-10-08", durableObjects: { BUDGET: { className: "Budget", useSQLite: true } },
    bindings: { PRIVATE_MODE: "true", ANSWERS_ENABLED: "true", PREVIEW_KEY: secret,
      RATE_SALT: secret, ANTHROPIC_API_KEY: "fake-runtime-api-key", ADMIN_KEY: "admin-" + secret },
    serviceBindings: { ASSETS: () => new Response("preview") },
    outboundService: async request => {
      calls++;
      assert.equal(request.url, "https://api.anthropic.com/v1/messages");
      assert.equal(request.headers.get("x-api-key"), "fake-runtime-api-key");
      if (redirect) return new Response(null, { status: 302,
        headers: { Location: "https://attacker.example/credential-trap" } });
      const body = await request.json();
      const passages = JSON.parse(body.messages[0].content).sources;
      return Response.json({ stop_reason: "end_turn", usage: { input_tokens: 1000, output_tokens: 100 },
        content: [{ type: "text", text: JSON.stringify({ answer: "A supported explanation.",
          citations: [passages[0].id], code: null }) }] });
    }
  }));
  try {
    const ask = () => mf.dispatchFetch("https://preview.example/api/ask", { method: "POST",
      headers: { "Content-Type": "application/json", "X-Preview-Key": secret },
      body: JSON.stringify({ question: "How do memory arenas work?",
        conversation: "a".repeat(8) + "-" + "b".repeat(27), secret: "must-not-be-stored" }) });
    const successful = await ask();
    assert.equal(successful.status, 200);
    assert.equal((await successful.json()).answer, "A supported explanation.");
    redirect = true;
    assert.equal((await ask()).status, 502);
    assert.equal(calls, 2); // The redirect destination is never fetched.
    const namespace = await mf.getDurableObjectNamespace("BUDGET");
    const stub = namespace.get(namespace.idFromName("landin-public-budget-v1"));
    const state = await (await stub.fetch("https://budget.internal/status")).json();
    assert.equal(state.bookedMicroUSD, 150 + RESERVATION_MICRO_USD);
    assert.equal(state.active, 0);
    const exportRequest = key => mf.dispatchFetch("https://preview.example/api/transcripts", {
      headers: { "X-Admin-Key": key, "X-Preview-Key": secret } });
    assert.equal((await exportRequest(secret)).status, 401);
    const exported = await exportRequest("admin-" + secret);
    assert.equal(exported.headers.get("Cache-Control"), "no-store");
    const page = await exported.json();
    assert.equal(page.records.length, 2);
    assert.equal(page.records[0].question, "How do memory arenas work?");
    assert.equal(page.records[0].response.answer, "A supported explanation.");
    assert.equal(page.records[0].state, "complete");
    assert.equal(page.records[0].costMicroUSD, 150);
    assert.equal(page.records[1].status, 502);
    assert.equal(page.records[1].costMicroUSD, null);
    assert.equal(page.records[0].conversation, page.records[1].conversation);
    const stored = JSON.stringify(page);
    for (const forbidden of [secret, "fake-runtime-api-key", "must-not-be-stored", "x-api-key"]) {
      assert.equal(stored.includes(forbidden), false);
    }
    const next = await mf.dispatchFetch("https://preview.example/api/transcripts?cursor=" + page.nextCursor,
      { headers: { "X-Admin-Key": "admin-" + secret } });
    assert.deepEqual((await next.json()).records, []);
  } finally { await mf.dispose(); }
});

test("real workerd SQLite transactions serialize concurrent quota requests", async () => {
  const mf = new Miniflare(convertV4MiniflareOptions({ modules: true,
    scriptPath: new URL("../build/bundle/worker.js", import.meta.url).pathname,
    compatibilityDate: "2026-10-08", durableObjects: { BUDGET: { className: "Budget", useSQLite: true } },
    bindings: { PRIVATE_MODE: "true", ANSWERS_ENABLED: "true" },
    serviceBindings: { ASSETS: () => new Response("preview") },
    outboundService: () => { throw new Error("Tests must not reach external services"); }
  }));
  try {
    const configuration = await mf.dispatchFetch("https://preview.example/api/config");
    assert.equal(configuration.status, 200); assert.equal((await configuration.json()).private, true);
    const unauthenticated = await mf.dispatchFetch("https://preview.example/api/ask", {
      method: "POST", body: JSON.stringify({ question: "Explain origins" }) });
    assert.equal(unauthenticated.status, 401);
    const namespace = await mf.getDurableObjectNamespace("BUDGET");
    const id = namespace.idFromName("landin-public-budget-v1");
    const stub = namespace.get(id);
    const count = Math.floor(MONTHLY_MICRO_USD / RESERVATION_MICRO_USD);
    // Book uncertain calls through the REAL storage boundary, until only
    // one more full reservation fits. No test-only production endpoint.
    for (let n = 0; n < count - 1; n++) {
      const claim = crypto.randomUUID();
      const response = await stub.fetch("https://budget.internal/reserve", {
        method: "POST", body: JSON.stringify({ operation: "ask", id: claim,
          client: (n + 100).toString(16).padStart(64, "0") }) });
      assert.equal(response.status, 200);
      assert.equal((await stub.fetch("https://budget.internal/settle", {
        method: "POST", body: JSON.stringify({ id: claim, cost: null }) })).status, 200);
    }
    const responses = await Promise.all(Array.from({ length: 20 }, (_, n) => stub.fetch("https://budget.internal/reserve", {
      method: "POST", body: JSON.stringify({ operation: "ask", id: crypto.randomUUID(),
        client: n.toString(16).padStart(64, "0") }) })));
    assert.equal(responses.filter(r => r.status === 200).length, 1);
    assert.equal(responses.filter(r => r.status === 429).length, 19);
    const state = await (await stub.fetch("https://budget.internal/status")).json();
    assert.equal(state.bookedMicroUSD, count * RESERVATION_MICRO_USD);
    assert.equal(state.active, 1);
    assert.ok(state.bookedMicroUSD <= MONTHLY_MICRO_USD);
  } finally { await mf.dispose(); }
});
