import { Failure, boundedText, parseJSON, MAX_CHAT_HISTORY_BYTES, MAX_CHAT_HISTORY_TURNS } from "./policy.js";

export function trimTurns(turns) {
  let trimmed = false;
  while (turns.length > MAX_CHAT_HISTORY_TURNS
      || new TextEncoder().encode(JSON.stringify(turns)).length > MAX_CHAT_HISTORY_BYTES) {
    if (turns.length === 1) throw new Failure(413, "This turn is too large to keep in conversation context.");
    turns.shift(); trimmed = true;
  }
  return { turns, trimmed };
}

// Server-owned history. A caller cannot inject assistant messages or obtain
// another conversation using the preview password alone.
export class Conversations {
  constructor(storage) {
    this.sql = storage.sql;
    this.sql.exec(`CREATE TABLE IF NOT EXISTS conversations (
      id TEXT PRIMARY KEY, token_hash TEXT NOT NULL, turns TEXT NOT NULL,
      active TEXT, until_ms INTEGER NOT NULL DEFAULT 0, cancelled INTEGER NOT NULL DEFAULT 0,
      trimmed INTEGER NOT NULL DEFAULT 0
    )`);
  }
  async fetch(request) {
    if (request.method !== "POST") return new Response(null, { status: 405 });
    const path = new URL(request.url).pathname;
    const data = parseJSON(await boundedText(request.body, 96_000));
    if (!/^[a-f0-9-]{36}$/.test(data.id || "") || !/^[a-f0-9]{64}$/.test(data.tokenHash || "")) {
      throw new Failure(400, "Invalid conversation credentials.");
    }
    const rows = this.sql.exec("SELECT * FROM conversations WHERE id = ?", data.id).toArray();
    let row = rows[0];
    if (row && row.token_hash !== data.tokenHash) {
      return Response.json({ error: "This conversation is not accessible." }, { status: 403 });
    }
    if (path === "/conversation/begin") {
      if (!/^[a-f0-9-]{36}$/.test(data.turn || "")) throw new Failure(400, "Invalid turn identity.");
      if (!row) {
        this.sql.exec("INSERT INTO conversations (id, token_hash, turns) VALUES (?, ?, '[]')", data.id, data.tokenHash);
        row = { turns: "[]", active: null, until_ms: 0, trimmed: 0 };
      }
      if (row.active && row.until_ms > Date.now()) {
        return Response.json({ error: "The previous turn is still finishing. Try shortly." }, { status: 409 });
      }
      this.sql.exec("UPDATE conversations SET active = ?, until_ms = ?, cancelled = 0 WHERE id = ?",
        data.turn, Date.now() + 120_000, data.id);
      return Response.json({ history: JSON.parse(row.turns), contextTrimmed: Boolean(row.trimmed) });
    }
    if (!row) return Response.json({ error: "Conversation not found." }, { status: 404 });
    if (path === "/conversation/cancel") {
      this.sql.exec("UPDATE conversations SET cancelled = 1 WHERE id = ?", data.id);
      return Response.json({ stopped: true });
    }
    if (path === "/conversation/check") {
      return Response.json({ stopped: Boolean(row.cancelled) || row.active !== data.turn || row.until_ms <= Date.now() });
    }
    if (path === "/conversation/finish") {
      if (row.active !== data.turn) {
        return Response.json({ error: "The conversation turn has expired." }, { status: 409 });
      }
      const turns = JSON.parse(row.turns);
      if (data.entry) turns.push(data.entry);
      const retained = trimTurns(turns);
      this.sql.exec("UPDATE conversations SET turns = ?, active = NULL, until_ms = 0, trimmed = ? WHERE id = ?",
        JSON.stringify(retained.turns), Number(retained.trimmed || row.trimmed), data.id);
      return Response.json({ saved: true });
    }
    return new Response(null, { status: 404 });
  }
}
