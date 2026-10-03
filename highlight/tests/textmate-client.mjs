import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const tests = path.dirname(fileURLToPath(import.meta.url));
const source = fs.readFileSync(path.join(tests, "../textmate/extension.js"), "utf8");

async function startedWith(settings) {
  let argumentsGiven;
  const module = { exports: {} };
  const vscode = {
    workspace: {
      getConfiguration: () => ({
        get: (name, fallback) => settings[name] ?? fallback,
      }),
    },
    window: {
      showWarningMessage: (message) => { throw new Error(message); },
    },
  };
  class LanguageClient {
    constructor(...args) { argumentsGiven = args; }
    async start() {}
  }
  vm.runInNewContext(source, {
    module,
    require: (name) => name === "vscode" ? vscode : { LanguageClient },
  });
  await module.exports.activate({});
  return JSON.parse(JSON.stringify(argumentsGiven));
}

const defaults = await startedWith({});
assert.deepEqual(defaults[2], {
  run: { command: "refine", args: ["lsp"] },
  debug: { command: "refine", args: ["lsp"] },
});
assert.deepEqual(defaults[3].initializationOptions, { options: {} });

const configured = await startedWith({
  "server.target": "cortex-m0",
  "server.level": "armv7-m",
  "server.options": { enabled: "false" },
});
assert.deepEqual(configured[3].initializationOptions, {
  target: "cortex-m0",
  level: "armv7-m",
  options: { enabled: "false" },
});

console.log("TextMate language client settings clean");
