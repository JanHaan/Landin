import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { retrieve, validateAnswer } from "../src/retrieval.js";

const corpus = JSON.parse(await readFile(new URL("../build/corpus.json", import.meta.url)));
const cases = JSON.parse(await readFile(new URL("../evaluation.json", import.meta.url)));
for (const item of cases) {
  if (!item.sources) continue;
  test("retrieval: " + item.question, () => {
    const passages = retrieve(corpus, item.question);
    for (const source of item.sources) {
      assert.ok(passages.some(p => p.source === source), `missing ${source}: ${passages.map(p => p.source + ':' + p.title).join(', ')}`);
    }
  });
}
test("passage IDs and links are unique and bound to the public corpus", () => {
  assert.equal(new Set(corpus.passages.map(p => p.id)).size, corpus.passages.length);
  for (const p of corpus.passages) assert.equal(new URL(p.url).origin, "https://www.701.dev");
});
test("a requested loop program includes a complete running program and normative function/control rules", () => {
  const passages = retrieve(corpus, "Write a Landin program that sums the integers 1 through 10.");
  assert.ok(passages.some(p => p.source === "examples.md" && p.text.includes("public main:")));
  for (const id of ["[1800]", "[1810]", "[1830]"]) {
    assert.ok(passages.some(p => p.source === "spec.md" && p.title.startsWith(id)), `missing ${id}`);
  }
});
test("only a fixed non-factual refusal can omit citations", () => {
  const data = answer => ({ content: [{ type: "text", text: JSON.stringify(answer) }] });
  const refusal = { answer: "I can help with questions about Landin and its published documentation.", citations: [], code: null };
  assert.deepEqual(validateAnswer(data(refusal), []), refusal);
  assert.throws(() => validateAnswer(data({ ...refusal, answer: "Landin supports every target." }), []));
  assert.throws(() => validateAnswer(data({ ...refusal, code: "unverified source" }), []));
});
test("known diagnostic codes retrieve their actual entry before general catalogue prose", () => {
  const passages = retrieve(corpus, "What does l0327 mean?");
  assert.equal(passages[0].source, "docs/diagnostics.md");
  assert.equal(passages[0].title, "L0327");
  assert.ok(passages[0].text.includes("argument"));
});
