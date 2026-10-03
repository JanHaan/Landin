// Starts `refine lsp`, the Landin compiler's language server, for Landin
// documents: diagnostics, definitions, hover, formatting and quick fixes
// from the compiler's own stages.  `landin.server.path` names the compiler
// when `refine` is not on the path; an empty `landin.server.path` and no
// `refine` leaves the extension highlighting only, and says so once.
"use strict";

const vscode = require("vscode");
const { LanguageClient } = require("vscode-languageclient/node");

let client;

async function activate(context) {
  const settings = vscode.workspace.getConfiguration("landin");
  if (!settings.get("server.enable", true)) {
    return;
  }
  const command = settings.get("server.path") || "refine";
  const server = { command, args: ["lsp"] };
  const target = settings.get("server.target", "");
  const level = settings.get("server.level", "");
  const options = settings.get("server.options", {});
  const initializationOptions = { options };
  if (target) initializationOptions.target = target;
  if (level) initializationOptions.level = level;
  client = new LanguageClient(
    "refine",
    "refine lsp",
    { run: server, debug: server },
    { documentSelector: [{ language: "landin" }], initializationOptions }
  );
  try {
    await client.start();
  } catch (error) {
    client = undefined;
    vscode.window.showWarningMessage(
      `Landin: could not start ${command} lsp (${error.message}); ` +
        "set landin.server.path to the refine compiler."
    );
  }
}

function deactivate() {
  return client ? client.stop() : undefined;
}

module.exports = { activate, deactivate };
