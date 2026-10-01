//! Starts `refine lsp`, the Landin compiler's language server, for Landin
//! buffers: diagnostics, definitions, hover, formatting and quick fixes from
//! the compiler's own stages.  `refine` is found on the worktree's path, and
//! nothing is downloaded: the server is the compiler the project builds with.

use zed_extension_api as zed;

struct Landin;

impl zed::Extension for Landin {
    fn new() -> Self {
        Landin
    }

    fn language_server_command(
        &mut self,
        _language_server_id: &zed::LanguageServerId,
        worktree: &zed::Worktree,
    ) -> zed::Result<zed::Command> {
        let command = worktree
            .which("refine")
            .ok_or_else(|| "refine is not on the path; see docs/server.md".to_string())?;
        Ok(zed::Command {
            command,
            args: vec!["lsp".to_string()],
            env: worktree.shell_env(),
        })
    }
}

zed::register_extension!(Landin);
