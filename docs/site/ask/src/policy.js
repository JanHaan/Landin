// Pricing reviewed against Anthropic's October 7, 2026 announcement.
// Keep model and prices together; changing either requires a budget review.
export const MODEL = "claude-haiku-5-5";
// Chosen by the operator after the paired effort evaluation, never a visitor.
export const EFFORT = "high";
// Thinking and final text share this hard provider limit.
export const MAX_OUTPUT = 4096;
export const MONTHLY_MICRO_USD = 70_000_000;
// Separate admission budget for Cloudflare container compute. This does not
// cap paid Worker/DO requests, storage, logs, registry or provider overages.
export const EXECUTION_MONTHLY_MICRO_USD = 5_000_000;
export const EXECUTION_RESERVATION_MICRO_USD = 2000;
export const SANDBOX_DEADLINE_MS = 45_000;
// Reserve the entire model's 1M context at the higher input/output rates.
// This avoids treating a local token estimate as a financial boundary.
export const RESERVATION_MICRO_USD = 500_000 + MAX_OUTPUT * 2.5;
export const MAX_BODY_BYTES = 16_384;
export const MAX_CODE_BYTES = 8192;
export const MAX_QUESTION_BYTES = 2048;
export const MAX_CONTEXT_BYTES = 28_000;
export const MAX_CHAT_BODY_BYTES = 24_576;
export const MAX_CHAT_HISTORY_BYTES = 65_536;
export const MAX_CHAT_HISTORY_TURNS = 8;
export const MAX_AGENT_CALLS = 4;
export const MAX_AGENT_TOOLS = 3;
export const MAX_AGENT_RUNS = 2;
export const CHAT_DEADLINE_MS = 90_000;

export class Failure extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

export function usageCost(usage) {
  if (!usage || !Number.isSafeInteger(usage.input_tokens)
      || !Number.isSafeInteger(usage.output_tokens)
      || usage.input_tokens < 0 || usage.input_tokens > 1_000_000
      || usage.output_tokens < 0 || usage.output_tokens > MAX_OUTPUT
      || (usage.cache_creation_input_tokens ?? 0) !== 0
      || (usage.cache_read_input_tokens ?? 0) !== 0) {
    throw new Failure(502, "The answer service returned invalid usage.");
  }
  const long = usage.input_tokens > 100_000;
  return Math.ceil(usage.input_tokens * (long ? 0.5 : 0.1)
                   + usage.output_tokens * (long ? 2.5 : 0.5));
}

export async function boundedText(stream, maxBytes) {
  if (!stream) throw new Failure(400, "A request body is required.");
  const reader = stream.getReader();
  const parts = [];
  let length = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      length += value.byteLength;
      if (length > maxBytes) {
        await reader.cancel();
        throw new Failure(413, "The request or response is too large.");
      }
      parts.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const part of parts) { bytes.set(part, offset); offset += part.length; }
  try { return new TextDecoder("utf-8", { fatal: true }).decode(bytes); }
  catch { throw new Failure(400, "Invalid UTF-8."); }
}

export function parseJSON(text) {
  try { return JSON.parse(text); }
  catch { throw new Failure(400, "Invalid JSON."); }
}

export function inputText(value, maximum, label) {
  if (typeof value !== "string" || !value.trim()
      || new TextEncoder().encode(value).length > maximum
      || value.includes("\0")) {
    throw new Failure(400, `${label} is empty or too large.`);
  }
  return value;
}

export async function digest(value) {
  const bytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(bytes), n => n.toString(16).padStart(2, "0")).join("");
}

export async function sameSecret(given, expected) {
  if (typeof given !== "string" || !expected || expected.length < 32) return false;
  return await digest(given) === await digest(expected);
}

export async function clientIdentity(request, salt) {
  if (!salt || salt.length < 32) throw new Failure(503, "The service is not configured.");
  const day = new Date().toISOString().slice(0, 10);
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(salt),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const ip = request.headers.get("cf-connecting-ip") || "local-preview";
  const bytes = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(day + "\0" + ip));
  return Array.from(new Uint8Array(bytes), n => n.toString(16).padStart(2, "0")).join("");
}
