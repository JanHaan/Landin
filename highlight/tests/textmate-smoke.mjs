import fs from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";

const tests = path.dirname(fileURLToPath(import.meta.url));
const root = path.dirname(tests);
const require = createRequire(path.join(root, "textmate/package.json"));
const { loadWASM, OnigScanner, OnigString } = require("vscode-oniguruma");
const { INITIAL, Registry, parseRawGrammar } = require("vscode-textmate");
const grammarPath = path.join(root, "textmate/syntaxes/landin.tmLanguage.json");
const fixturePath = path.join(tests, "lexical.ldn");
const wasmPath = require.resolve("vscode-oniguruma/release/onig.wasm");
const wasm = fs.readFileSync(wasmPath);
await loadWASM(wasm.buffer.slice(wasm.byteOffset, wasm.byteOffset + wasm.byteLength));

const registry = new Registry({
  onigLib: Promise.resolve({
    createOnigScanner: (sources) => new OnigScanner(sources),
    createOnigString: (source) => new OnigString(source),
  }),
  loadGrammar: async (scope) => {
    if (scope !== "source.landin") return null;
    return parseRawGrammar(fs.readFileSync(grammarPath, "utf8"), grammarPath);
  },
});

const grammar = await registry.loadGrammar("source.landin");
if (!grammar) throw new Error("Landin TextMate grammar did not load");

const expectations = new Map([
  ["documentation comment", "comment.line.documentation.landin"],
  ["nested block comment", "comment.block.landin"],
  ["public", "keyword.control.landin"],
  ["u23", "storage.type.builtin.landin"],
  ["escaped", "string.quoted.double.landin"],
  ["this is part of the raw literal", "string.quoted.other.raw.landin"],
  ["compiler", "support.module.landin"],
  ["member", "variable.other.member.landin"],
  ["0x2a", "constant.numeric.landin"],
  ["true", "constant.language.landin"],
]);
const found = new Set();
let stack = INITIAL;
for (const line of fs.readFileSync(fixturePath, "utf8").split("\n")) {
  const result = grammar.tokenizeLine(line, stack);
  stack = result.ruleStack;
  for (const [needle, scope] of expectations) {
    const column = line.indexOf(needle);
    if (column < 0) continue;
    const token = result.tokens.find(
      (candidate) => candidate.startIndex <= column && candidate.endIndex > column,
    );
    if (token?.scopes.includes(scope)) found.add(needle);
  }
}

const missing = [...expectations.keys()].filter((needle) => !found.has(needle));
if (missing.length) {
  throw new Error(`TextMate scopes were not produced for: ${missing.join(", ")}`);
}
console.log("TextMate tokenizer smoke clean");
