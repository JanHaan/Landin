--  Scripted language-server sessions.
--
--  A session is a directory under `compiler/tests/server/`: a
--  `session.lsp` transcript and, beside it, an optional `workspace/` tree.
--  The tree is served by a fake filesystem under `/workspace`, so a URI in
--  a transcript is `file:///workspace/...` on every host.
--
--  A transcript is lines.  `#` starts a comment and a blank line is
--  nothing.  `-> ` is followed by one JSON message the editor sends; it is
--  framed and fed to the server in order.  `<- ` is followed by one message
--  the server must send, byte for byte as the server writes JSON, and every
--  message it sends must be one of them, in order.  `exit: N` is the status
--  the session must end with, and is the last line.  `chunk: N`, before any
--  message, feeds the input N bytes at a time.  `raw: ` is followed by
--  bytes sent as they are, with `\r` and `\n` for CR and LF, for a frame
--  that is wrong on purpose.  `pause` is where the editor waits: input
--  sent before it is a burst the server sees all at once, and the server
--  catches up there, as it would while a person stops typing.
--
--  The session runs in the test program against the fake channel, never as
--  a process; `compiler/tests/server/native_session.py` runs the same
--  transcripts through `refine lsp` itself.

with Ada.Strings.Unbounded;

package Landin.Testing.Sessions is

   type Outcome is record
      --  Empty when the session ran as written.
      Problem  : Ada.Strings.Unbounded.Unbounded_String;
      --  The transcript with every `<-` line what the server sent.
      Recorded : Ada.Strings.Unbounded.Unbounded_String;
      --  What the server logged, for a person reading a failure.
      Log      : Ada.Strings.Unbounded.Unbounded_String;
      Analyses : Natural := 0;
   end record;

   --  Run the session in Directory, read through the real filesystem.
   --  With navigation omitted, the same edits still publish diagnostics.
   --  Its analysis count is a baseline for checking query reuse.
   function Run
     (Directory : String; Include_Navigation : Boolean := True)
     return Outcome;

end Landin.Testing.Sessions;
