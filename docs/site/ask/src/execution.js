import { Failure, MAX_BODY_BYTES, MAX_CODE_BYTES, SANDBOX_DEADLINE_MS,
  boundedText, inputText, parseJSON } from "./policy.js";

// The binding is private to the Worker. One fixed DO owns one container;
// visitors cannot choose its image, instance size, command or identity.
export class Execution {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env;
    this.busy = false;
    this.ready = ctx.blockConcurrencyWhile(async () => {
      const job = await ctx.storage.get("job");
      if (job || ctx.container?.running) await this.cleanup();
    });
  }

  async cleanup() {
    const container = this.ctx.container;
    if (!container) throw new Failure(503, "Execution is not configured.");
    // Delete the durable job only AFTER the provider confirms destruction.
    // A failed cleanup keeps the slot closed across DO restarts.
    await container.destroy();
    if (container.running || await container.inspect() !== null) {
      throw new Failure(503, "Sandbox cleanup could not be verified.");
    }
    await this.ctx.storage.delete("job");
    await this.ctx.storage.deleteAlarm();
  }

  async alarm() {
    try { await this.cleanup(); }
    catch {
      // Retry destruction only, never restart or rerun visitor code.
      await this.ctx.storage.setAlarm(Date.now() + 5000);
      throw new Error("Sandbox cleanup failed");
    }
  }

  async fetch(request) {
    await this.ready;
    if (request.method === "GET" && new URL(request.url).pathname === "/status") {
      const container = this.ctx.container;
      return Response.json({ busy: this.busy, job: await this.ctx.storage.get("job") || null,
        running: Boolean(container?.running), image: container ? await container.inspect() : null });
    }
    if (request.method !== "POST" || new URL(request.url).pathname !== "/run") {
      return new Response(null, { status: 404 });
    }
    if (this.busy) return Response.json({ error: "Execution is busy." }, { status: 429 });
    this.busy = true;
    let owned = false;
    let timer, response;
    const controller = new AbortController();
    try {
      if (await this.ctx.storage.get("job")) throw new Failure(503, "Execution is paused pending cleanup.");
      if (this.env.EXECUTION_ENABLED !== "true"
          || !/^[a-f0-9]{64}$/.test(this.env.COMPILER_SHA256 || "")) {
        throw new Failure(503, "Execution is not configured.");
      }
      const code = inputText(parseJSON(await boundedText(request.body, MAX_BODY_BYTES))?.code,
        MAX_CODE_BYTES, "Source");
      const container = this.ctx.container;
      if (!container || container.running) throw new Failure(503, "Execution is unavailable.");
      const deadline = Date.now() + SANDBOX_DEADLINE_MS;
      await this.ctx.storage.put("job", { deadline });
      owned = true;
      await this.ctx.storage.setAlarm(deadline);
      let rejectDeadline;
      const expires = new Promise((_, reject) => { rejectDeadline = reject; });
      timer = setTimeout(() => {
        controller.abort();
        rejectDeadline(new Failure(504, "Execution timed out."));
      }, Math.max(0, deadline - Date.now()));
      // The image/size come ONLY from the default-policy Wrangler config.
      // No secrets, user environment, shell strings or snapshots are passed.
      const attempt = async () => {
        container.start({ enableInternet: false });
        await container.setInactivityTimeout(1000);
        controller.signal.throwIfAborted();
        return this.run(container, code, deadline, controller.signal);
      };
      const result = await Promise.race([attempt(), expires]);
      response = Response.json(result);
    } catch (error) {
      response = Response.json({ error: error instanceof Failure ? error.message : "Execution is unavailable." },
        { status: error instanceof Failure ? error.status : 503 });
    } finally {
      clearTimeout(timer);
      controller.abort();
      if (owned) {
        try { await this.cleanup(); }
        catch { response = Response.json({ error: "Execution is paused pending cleanup." }, { status: 503 }); }
      }
      this.busy = false;
    }
    return response;
  }

  async run(container, code, deadline, signal) {
    const port = container.getTcpPort(8080);
    // Poll readiness only. Never retry the compile/run operation: a lost
    // response may still represent a billed or already completed execution.
    for (;;) {
      signal.throwIfAborted();
      if (Date.now() >= deadline) throw new Failure(504, "Sandbox startup timed out.");
      let ready = false;
      try {
        const health = await port.fetch("http://container/health", {
          signal: AbortSignal.any([signal, AbortSignal.timeout(1000)]) });
        ready = health.ok;
        await health.body?.cancel();
      } catch { /* startup is asynchronous */ }
      if (ready) break;
      await new Promise(resolve => setTimeout(resolve, 100));
    }
    signal.throwIfAborted();
    const result = await port.fetch("http://container/run", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code }),
      signal
    });
    if (!result.ok) throw new Failure(502, "The sandbox did not return a result.");
    const data = parseJSON(await boundedText(result.body, 48_000));
    if (!data || !["compile_error", "ran", "terminated", "timeout", "output_limit"].includes(data.status)
        || typeof data.output !== "string" || new TextEncoder().encode(data.output).length > 16_384
        || !(data.exitCode === null || Number.isSafeInteger(data.exitCode))) {
      throw new Failure(502, "The sandbox returned an invalid result.");
    }
    // Identity comes from the checked image configuration, never the job.
    return { status: data.status, output: data.output,
      exitCode: data.exitCode, compiler: this.env.COMPILER_SHA256 };
  }
}
