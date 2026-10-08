import corpus from "../build/corpus.json" with { type: "json" };
import { createService } from "./service.js";
import { emptyLedger, reserve, settle } from "./ledger.js";
import { TranscriptStore } from "./transcripts.js";
export { Execution } from "./execution.js";

export default createService(corpus);

export class Budget {
  constructor(ctx) { this.ctx = ctx; this.transcripts = new TranscriptStore(ctx.storage); }
  async fetch(request) {
    if (new URL(request.url).pathname.startsWith("/transcripts")) {
      return this.transcripts.fetch(request);
    }
    if (request.method === "GET" && new URL(request.url).pathname === "/status") {
      const state = await this.ctx.storage.get("ledger") || emptyLedger();
      const month = new Date().toISOString().slice(0, 7);
      return Response.json({ month, bookedMicroUSD: state.months[month] || 0,
        executionBookedMicroUSD: state.executionMonths?.[month] || 0,
        active: Object.keys(state.claims).length, halted: state.halted });
    }
    if (request.method !== "POST") return new Response(null, { status: 405 });
    const path = new URL(request.url).pathname;
    if (!["/reserve", "/settle"].includes(path)) return new Response(null, { status: 404 });
    const data = await request.json();
    const result = await this.ctx.storage.transaction(async txn => {
      const state = await txn.get("ledger") || emptyLedger();
      const result = path === "/reserve" ? reserve(state, data) : settle(state, data);
      await txn.put("ledger", state);
      return result;
    });
    return Response.json(result, { status: result.status });
  }
}
