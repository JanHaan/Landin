import { Failure, MODEL, EFFORT, MAX_OUTPUT, MAX_BODY_BYTES, MAX_CODE_BYTES,
  MAX_QUESTION_BYTES, boundedText, parseJSON, inputText, sameSecret,
  clientIdentity, usageCost, digest } from "./policy.js";
import { retrieve, SYSTEM, ANSWER_FORMAT, messages, validateAnswer } from "./retrieval.js";
import { chatTurn, conversationCredentials } from "./chat.js";
import { remoteJSON } from "./upstream.js";

function json(data, status = 200) {
  return Response.json(data, { status, headers: { "Cache-Control": "no-store" } });
}

async function authorize(request, env, operation, fetcher) {
  if (env.PRIVATE_MODE !== "false") {
    if (!await sameSecret(request.headers.get("x-preview-key"), env.PREVIEW_KEY)) {
      throw new Failure(401, "A valid private preview key is required.");
    }
    return;
  }
  if (!env.TURNSTILE_SECRET_KEY || !env.TURNSTILE_SITE_KEY) {
    throw new Failure(503, "Public access is not configured.");
  }
  const token = request.headers.get("x-turnstile-token");
  if (!token || token.length > 2048) throw new Failure(403, "Please verify your request.");
  const verification = await remoteJSON("https://challenges.cloudflare.com/turnstile/v0/siteverify", {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ secret: env.TURNSTILE_SECRET_KEY, response: token,
      remoteip: request.headers.get("cf-connecting-ip") || undefined })
  }, fetcher);
  const origin = request.headers.get("origin") || new URL(request.url).origin;
  if (!verification.success || verification.action !== operation
      || verification.hostname !== new URL(origin).hostname) {
    throw new Failure(403, "Request verification failed.");
  }
}

function coordinator(env) {
  if (!env.BUDGET) throw new Failure(503, "The quota service is unavailable.");
  // Never derive this identity from a visitor, model, snapshot or deployment.
  // Redeployments use the SAME ledger, so they cannot reset the budget.
  return env.BUDGET.get(env.BUDGET.idFromName("landin-public-budget-v1"));
}

async function ledgerCall(stub, path, data) {
  const response = await stub.fetch("https://budget.internal/" + path, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(data)
  });
  const result = await response.json();
  if (!response.ok) throw new Failure(response.status, result.error || "The quota service is unavailable.");
  return result;
}

async function executeCode(env, code, client, deadline, fetcher) {
  if (env.EXECUTION_ENABLED !== "true") throw new Failure(503, "Execution is unavailable.");
  // Leave time for the sandbox's own destruction deadline and final answer.
  if (deadline - Date.now() < 50_000) throw new Failure(504, "There is not enough turn time left for another execution.");
  const cloudflare = env.EXECUTION_BACKEND === "cloudflare";
  let runner;
  if (cloudflare) {
    if (!env.EXECUTION || !/^[a-f0-9]{64}$/.test(env.COMPILER_SHA256 || "")) throw new Failure(503, "Execution is not configured.");
  } else {
    try { runner = new URL(env.RUNNER_URL); } catch { /* checked below */ }
    if (!runner || runner.protocol !== "https:" || runner.username || runner.password
        || !env.RUNNER_KEY || env.RUNNER_KEY.length < 32) throw new Failure(503, "Execution is not configured.");
  }
  const stub = coordinator(env), id = crypto.randomUUID();
  await ledgerCall(stub, "reserve", { id, client, operation: "run", cloudflare });
  let cost = null;
  try {
    let data;
    if (cloudflare) {
      const runtime = env.EXECUTION.get(env.EXECUTION.idFromName("landin-execution-v1"));
      const result = await runtime.fetch("https://execution.internal/run", { method: "POST",
        headers: { "Content-Type": "application/json" }, body: JSON.stringify({ code }),
        signal: AbortSignal.timeout(45_000) });
      if (!result.ok) throw new Failure(result.status, "Execution is unavailable. Try later.");
      data = parseJSON(await boundedText(result.body, 48_000));
    } else data = await remoteJSON(runner.href, { method: "POST",
      headers: { "Content-Type": "application/json", Authorization: "Bearer " + env.RUNNER_KEY },
      body: JSON.stringify({ code }) }, fetcher, 48_000);
    if (!data || !["compile_error", "ran", "terminated", "timeout", "output_limit"].includes(data.status)
        || typeof data.output !== "string" || new TextEncoder().encode(data.output).length > 16_384
        || !(data.exitCode === null || Number.isInteger(data.exitCode))
        || typeof data.compiler !== "string" || data.compiler.length > 160) throw new Failure(502, "The execution service returned an invalid result.");
    cost = 0;
    return { status: data.status, output: data.output, exitCode: data.exitCode, compiler: data.compiler };
  } finally { await ledgerCall(stub, "settle", { id, cost }); }
}

export function createService(corpus, fetcher = fetch) {
  return {
    async fetch(request, env) {
      const url = new URL(request.url);
      const origin = request.headers.get("origin");
      const permitted = !origin || origin === url.origin || origin === env.ALLOWED_ORIGIN;
      let response, recording, manualSession;
      const beginTranscript = async (operation, text, input) => {
        const id = crypto.randomUUID(), stub = coordinator(env);
        const conversation = typeof input.conversation === "string"
          && /^[a-f0-9-]{36}$/.test(input.conversation) ? input.conversation : id;
        await ledgerCall(stub, "transcripts/start", { id, conversation,
          started: new Date().toISOString(), operation,
          ...(operation === "run" ? { code: text } : { question: text }),
          model: operation === "ask" ? MODEL : null,
          effort: operation === "ask" ? EFFORT : null,
          maxOutput: operation === "ask" ? MAX_OUTPUT : null,
          snapshot: { commit: corpus.commit, sha256: corpus.sha256, dirty: corpus.dirty } });
        recording = { id, stub, usage: null, costMicroUSD: null, upstreamAttempted: false };
        if (["search", "run"].includes(operation) && request.headers.has("x-conversation-key")) {
          const credentials = await conversationCredentials(request, input);
          const session = { ...credentials, turn: id };
          await ledgerCall(stub, "conversation/begin", session);
          manualSession = { stub, session, operation, text };
        }
      };
      try {
        if (!permitted) throw new Failure(403, "This origin is not allowed.");
        if (request.method === "OPTIONS" && url.pathname.startsWith("/api/")) {
          response = new Response(null, { status: 204 });
        } else if (url.pathname === "/api/config" && request.method === "GET") {
          response = json({ private: env.PRIVATE_MODE !== "false",
            answers: env.ANSWERS_ENABLED === "true" && Boolean(env.ANTHROPIC_API_KEY),
            execution: env.EXECUTION_ENABLED === "true",
            turnstileSiteKey: env.TURNSTILE_SITE_KEY || "", snapshot: {
              commit: corpus.commit, sha256: corpus.sha256, dirty: corpus.dirty } });
        } else if (["/api/execution/status", "/api/execution/diagnostics"].includes(url.pathname)
            && request.method === "GET") {
          if (!await sameSecret(request.headers.get("x-admin-key"), env.ADMIN_KEY)) throw new Failure(401, "A valid administrator key is required.");
          if (!env.EXECUTION) throw new Failure(503, "Execution is not configured.");
          response = await env.EXECUTION.get(env.EXECUTION.idFromName("landin-execution-v1"))
            .fetch("https://execution.internal/" + url.pathname.split("/").at(-1));
        } else if (url.pathname === "/api/budget" && request.method === "GET") {
          if (!await sameSecret(request.headers.get("x-preview-key"), env.PREVIEW_KEY)) {
            throw new Failure(401, "A valid private preview key is required.");
          }
          response = await coordinator(env).fetch("https://budget.internal/status");
        } else if (url.pathname === "/api/transcripts" && request.method === "GET") {
          if (!await sameSecret(request.headers.get("x-admin-key"), env.ADMIN_KEY)) {
            throw new Failure(401, "A valid administrator key is required.");
          }
          const cursor = url.searchParams.get("cursor") || "0";
          if (!/^\d{1,16}$/.test(cursor) || !Number.isSafeInteger(Number(cursor))) {
            throw new Failure(400, "Invalid export cursor.");
          }
          response = await coordinator(env).fetch("https://budget.internal/transcripts?cursor=" + cursor);
        } else if (["/api/chat", "/api/chat/cancel"].includes(url.pathname) && request.method === "POST") {
          if (env.ANSWERS_ENABLED !== "true" || !env.ANTHROPIC_API_KEY) throw new Failure(503, "The answer service is unavailable. Documentation search remains available.");
          await authorize(request, env, "ask", fetcher);
          const stub = coordinator(env);
          if (url.pathname.endsWith("cancel")) {
            const input = parseJSON(await boundedText(request.body, MAX_BODY_BYTES));
            const credentials = await conversationCredentials(request, input);
            response = json(await ledgerCall(stub, "conversation/cancel", credentials));
          } else response = await chatTurn(request, env, corpus, { stub, call: ledgerCall,
            provider: (body, timeout) => remoteJSON("https://api.anthropic.com/v1/messages", {
              method: "POST", headers: { "Content-Type": "application/json", "x-api-key": env.ANTHROPIC_API_KEY,
                "anthropic-version": "2023-06-01" }, body: JSON.stringify(body)
            }, fetcher, 96_000, timeout),
            execute: (code, client, deadline) => executeCode(env, code, client, deadline, fetcher) });
        } else if (url.pathname === "/api/search" && request.method === "POST") {
          await authorize(request, env, "search", fetcher);
          const input = parseJSON(await boundedText(request.body, MAX_BODY_BYTES));
          const question = inputText(input?.question, MAX_QUESTION_BYTES, "Question");
          const stub = coordinator(env), id = crypto.randomUUID();
          const client = await clientIdentity(request, env.RATE_SALT);
          await ledgerCall(stub, "reserve", { id, client, operation: "search" });
          try {
            await beginTranscript("search", question, input);
            response = json({ sources: retrieve(corpus, question).map(({ id, title, url, source, authority }) =>
              ({ id, title, url, source, authority })) });
          } finally { await ledgerCall(stub, "settle", { id, cost: 0 }); }
        } else if (["/api/ask", "/api/run"].includes(url.pathname) && request.method === "POST") {
          const operation = url.pathname.endsWith("run") ? "run" : "ask";
          if (env.ANSWERS_ENABLED !== "true" || (operation === "run" && env.EXECUTION_ENABLED !== "true")) {
            throw new Failure(503, "This service is paused. Documentation search remains available.");
          }
          await authorize(request, env, operation, fetcher);
          const input = parseJSON(await boundedText(request.body, MAX_BODY_BYTES));
          const text = operation === "ask"
            ? inputText(input?.question, MAX_QUESTION_BYTES, "Question")
            : inputText(input?.code, MAX_CODE_BYTES, "Source");
          await beginTranscript(operation, text, input);
          const passages = operation === "ask" ? retrieve(corpus, text) : [];
          if (operation === "ask" && !passages.length) {
            response = json({ answer: "I could not find supporting Landin documentation. Try a more specific question.",
              citations: [], code: null, snapshot: corpus.sha256 });
          } else {
            if (operation === "ask" && !env.ANTHROPIC_API_KEY) throw new Failure(503, "The answer service is not configured.");
            let runner;
            const cloudflare = operation === "run" && env.EXECUTION_BACKEND === "cloudflare";
            if (operation === "run") {
              if (cloudflare) {
                if (!env.EXECUTION || !/^[a-f0-9]{64}$/.test(env.COMPILER_SHA256 || "")) {
                  throw new Failure(503, "Execution is not configured.");
                }
              } else {
                try { runner = new URL(env.RUNNER_URL); } catch { /* fail below */ }
                if (!runner || runner.protocol !== "https:" || runner.username || runner.password
                  || !env.RUNNER_KEY || env.RUNNER_KEY.length < 32) {
                  throw new Failure(503, "Execution is not configured.");
                }
              }
            }
            const stub = coordinator(env);
            const id = recording.id;
            const client = await clientIdentity(request, env.RATE_SALT);
            await ledgerCall(stub, "reserve", { id, client, operation, cloudflare });
            let cost = null;
            try {
              recording.upstreamAttempted = true;
              if (operation === "ask") {
                const data = await remoteJSON("https://api.anthropic.com/v1/messages", {
                  method: "POST", headers: { "Content-Type": "application/json",
                    "x-api-key": env.ANTHROPIC_API_KEY, "anthropic-version": "2023-06-01" },
                  body: JSON.stringify({ model: MODEL, max_tokens: MAX_OUTPUT,
                    thinking: { type: "adaptive" }, output_config: { effort: EFFORT, format: ANSWER_FORMAT },
                    system: SYSTEM, messages: messages(text, passages) })
                }, fetcher, 96_000);
                cost = usageCost(data.usage);
                recording.upstream = data.upstream;
                recording.usage = { inputTokens: data.usage.input_tokens,
                  outputTokens: data.usage.output_tokens, stopReason: data.stop_reason };
                if (data.stop_reason !== "end_turn") {
                  throw new Failure(502, "The answer did not finish within its limits. Try documentation search.");
                }
                response = json({ ...validateAnswer(data, passages), snapshot: corpus.sha256 });
              } else {
                let data;
                if (cloudflare) {
                  const runtime = env.EXECUTION.get(env.EXECUTION.idFromName("landin-execution-v1"));
                  const result = await runtime.fetch("https://execution.internal/run", {
                    method: "POST", headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({ code: text }) });
                  if (!result.ok) throw new Failure(result.status, "Execution is unavailable. Try later.");
                  data = parseJSON(await boundedText(result.body, 48_000));
                } else data = await remoteJSON(runner.href, { method: "POST",
                  headers: { "Content-Type": "application/json", "Authorization": "Bearer " + env.RUNNER_KEY },
                  body: JSON.stringify({ code: text }) }, fetcher, 48_000);
                // Treat every sandbox output as untrusted, even its JSON shape.
                if (!data || !["compile_error", "ran", "terminated", "timeout", "output_limit"].includes(data.status)
                    || typeof data.output !== "string" || new TextEncoder().encode(data.output).length > 16_384
                    || !(data.exitCode === null || Number.isInteger(data.exitCode))
                    || typeof data.compiler !== "string" || data.compiler.length > 160) {
                  throw new Failure(502, "The execution service returned an invalid result.");
                }
                cost = 0;
                response = json({ status: data.status, output: data.output,
                  exitCode: data.exitCode, compiler: data.compiler });
              }
            } finally {
              // Ambiguous failures retain the full reservation. No automatic
              // retry: a timed-out call may already have incurred charges.
              await ledgerCall(stub, "settle", { id, cost });
              recording.costMicroUSD = cost;
            }
          }
        } else if (url.pathname.startsWith("/api/")) {
          response = json({ error: "No such endpoint or method." }, 404);
        } else {
          response = await env.ASSETS.fetch(request);
        }
      } catch (error) {
        if (recording && error.upstream) recording.upstreamFailure = error.upstream;
        response = json({ error: error instanceof Failure ? error.message : "The service is unavailable. Try later." },
          error instanceof Failure ? error.status : 503);
      }
      if (manualSession) {
        try {
          const { stub, session, operation, text } = manualSession;
          const data = await response.clone().json();
          const hash = operation === "run" && response.ok ? await digest(text) : null;
          await ledgerCall(stub, "conversation/finish", { ...session, ...(response.ok ? { entry: {
            question: operation === "search" ? text : "Build and run this source file.",
            workspaceCode: operation === "run" ? text : "", code: operation === "run" ? text : null,
            codeSHA256: hash, citations: (data.sources || []).map(p => p.id),
            answer: operation === "search" ? "Relevant documentation was found."
              : `Manual run: ${data.status}; exit ${data.exitCode ?? "unavailable"}.`,
            execution: operation === "run" ? [{ sourceSHA256: hash, status: data.status,
              exitCode: data.exitCode, output: data.output.slice(0, 2000) }] : []
          } } : {}) });
        } catch { response = json({ error: "Conversation storage is unavailable. Try later." }, 503); }
      }
      if (recording) {
        try {
          await ledgerCall(recording.stub, "transcripts/finish", { id: recording.id,
            finished: new Date().toISOString(), status: response.status,
            response: await response.clone().json(), usage: recording.usage,
            costMicroUSD: recording.costMicroUSD, upstreamAttempted: recording.upstreamAttempted,
            ...(recording.upstream ? { upstream: recording.upstream } : {}),
            ...(recording.upstreamFailure ? { upstreamFailure: recording.upstreamFailure } : {}) });
        } catch {
          // A pending row survives a crash or failed completion write. No
          // answer is delivered when its transcript cannot be saved.
          response = json({ error: "Transcript storage is unavailable. Try later." }, 503);
        }
      }
      // Response text never becomes HTML. CSP also blocks third-party images,
      // frames, and navigation gadgets embedded in a manipulated answer.
      const headers = new Headers(response.headers);
      headers.set("X-Content-Type-Options", "nosniff");
      headers.set("Referrer-Policy", "no-referrer");
      if (url.pathname.startsWith("/api/")) headers.set("Cache-Control", "no-store");
      headers.set("Content-Security-Policy", "default-src 'self'; script-src 'self' https://challenges.cloudflare.com; style-src 'self'; font-src 'self'; img-src 'self'; connect-src 'self' https://challenges.cloudflare.com; frame-src https://challenges.cloudflare.com; frame-ancestors 'none'; base-uri 'none'; form-action 'self'");
      if (permitted && origin) {
        headers.set("Access-Control-Allow-Origin", origin);
        headers.set("Vary", "Origin");
        headers.set("Access-Control-Allow-Methods", "POST, GET, OPTIONS");
        headers.set("Access-Control-Allow-Headers", "Content-Type, X-Preview-Key, X-Turnstile-Token, X-Admin-Key, X-Conversation-Key");
      }
      return new Response(response.body, { status: response.status, headers });
    }
  };
}
