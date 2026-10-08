import { Failure, boundedText, parseJSON } from "./policy.js";

// The binding is private. Only the service constructs these records, never
// request headers, provider reasoning, or an arbitrary visitor-supplied object.
export class TranscriptStore {
  constructor(storage) {
    this.sql = storage.sql;
    this.sql.exec(`CREATE TABLE IF NOT EXISTS transcripts (
      seq INTEGER PRIMARY KEY AUTOINCREMENT,
      id TEXT NOT NULL UNIQUE,
      record TEXT NOT NULL
    )`);
  }

  async fetch(request) {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/transcripts") {
      const cursor = url.searchParams.get("cursor") || "0";
      if (!/^\d{1,16}$/.test(cursor) || !Number.isSafeInteger(Number(cursor))) {
        return Response.json({ error: "Invalid export cursor." }, { status: 400 });
      }
      const rows = this.sql.exec("SELECT seq, record FROM transcripts WHERE seq > ? ORDER BY seq LIMIT 5",
        Number(cursor)).toArray();
      return Response.json({ schema: 1, records: rows.map(row => JSON.parse(row.record)),
        nextCursor: rows.length ? String(rows.at(-1).seq) : null });
    }
    if (request.method !== "POST") return new Response(null, { status: 405 });
    const data = parseJSON(await boundedText(request.body, 96_000));
    if (!/^[a-f0-9-]{36}$/.test(data.id || "")) throw new Failure(400, "Invalid transcript identity.");
    if (url.pathname === "/transcripts/start") {
      this.sql.exec("INSERT INTO transcripts (id, record) VALUES (?, ?)", data.id,
        JSON.stringify({ ...data, state: "pending" }));
    } else if (url.pathname === "/transcripts/finish") {
      const previous = this.sql.exec("SELECT record FROM transcripts WHERE id = ?", data.id).one();
      this.sql.exec("UPDATE transcripts SET record = ? WHERE id = ?",
        JSON.stringify({ ...JSON.parse(previous.record), ...data, state: "complete" }), data.id);
    } else return new Response(null, { status: 404 });
    return Response.json({ saved: true });
  }
}
