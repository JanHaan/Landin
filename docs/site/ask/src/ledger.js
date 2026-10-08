import { MONTHLY_MICRO_USD, RESERVATION_MICRO_USD,
  EXECUTION_MONTHLY_MICRO_USD, EXECUTION_RESERVATION_MICRO_USD, MAX_AGENT_CALLS } from "./policy.js";

export function emptyLedger() {
  return { months: {}, executionMonths: {}, day: "", counts: {}, clients: {}, claims: {}, halted: false };
}

// Called inside a Durable Object storage transaction. No remote call or
// asynchronous work can occur between checking a limit and booking funds.
export function reserve(state, { operation, client, id, cloudflare = false, agentTurn = false }, now = Date.now()) {
  if (!["ask", "run", "search"].includes(operation) || !/^[a-f0-9]{64}$/.test(client)
      || typeof id !== "string" || !/^[a-f0-9-]{36}$/.test(id)) {
    return { status: 400, error: "Invalid reservation." };
  }
  const date = new Date(now).toISOString();
  const month = date.slice(0, 7), day = date.slice(0, 10);
  state.executionMonths ||= {};
  if (state.day !== day) { state.day = day; state.counts = {}; state.clients = {}; }
  for (const [key, claim] of Object.entries(state.claims)) {
    // Expiry frees the concurrency slot, never the reserved money.
    if (now - claim.started > 120_000) delete state.claims[key];
  }
  for (const key of Object.keys(state.months)) {
    if (key !== month && !Object.values(state.claims).some(claim => claim.month === key)) delete state.months[key];
  }
  for (const key of Object.keys(state.executionMonths)) {
    if (key !== month && !Object.values(state.claims).some(claim => claim.month === key)) delete state.executionMonths[key];
  }
  if (state.halted && operation !== "search") return { status: 503, error: "The service is paused." };
  if (state.claims[id]) return { status: 409, error: "Duplicate reservation." };
  const active = Object.values(state.claims).filter(claim => claim.operation === operation).length;
  if (active >= (operation === "run" ? 1 : 4)) return { status: 429, error: "The service is busy. Try later." };
  const execution = operation === "run" && cloudflare;
  const cost = operation === "ask" ? RESERVATION_MICRO_USD * (agentTurn ? MAX_AGENT_CALLS : 1)
    : execution ? EXECUTION_RESERVATION_MICRO_USD : 0;
  const account = execution ? state.executionMonths : state.months;
  const spent = account[month] || 0;
  const limit = execution ? EXECUTION_MONTHLY_MICRO_USD : MONTHLY_MICRO_USD;
  if (spent + cost > limit) return { status: 429, error: `This month's ${execution ? "execution" : "answer"} budget is exhausted. Documentation search remains available.` };
  const limits = operation === "ask" ? { minute: 3, day: 20, total: 1000 }
    : operation === "run" ? { minute: 2, day: 5, total: 200 } : { minute: 10, day: 50, total: 1000 };
  const key = client + ":" + operation;
  const user = state.clients[key] || { day: 0, minute: -1, count: 0 };
  const minute = Math.floor(now / 60_000);
  if (user.minute !== minute) { user.minute = minute; user.count = 0; }
  if (user.day >= limits.day || user.count >= limits.minute || (state.counts[operation] || 0) >= limits.total) {
    return { status: 429, error: "The request limit has been reached. Try later." };
  }
  user.day++; user.count++;
  state.clients[key] = user;
  state.counts[operation] = (state.counts[operation] || 0) + 1;
  account[month] = spent + cost;
  state.claims[id] = { operation, month, cost, execution, started: now };
  return { status: 200, id };
}

export function settle(state, { id, cost }) {
  const claim = state.claims[id];
  if (!claim) return { status: 200 }; // A late/duplicate settlement never refunds twice.
  if (cost !== null && (!Number.isSafeInteger(cost) || cost < 0 || cost > claim.cost)) {
    state.halted = true;
    delete state.claims[id];
    return { status: 503, error: "The service is paused." };
  }
  if (cost !== null && !claim.execution) state.months[claim.month] -= claim.cost - cost;
  // Container bookings are never refunded from untrusted runtime reports.
  delete state.claims[id];
  return { status: 200 };
}
