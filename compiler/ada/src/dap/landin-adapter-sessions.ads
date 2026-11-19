--  One editor's debugging session (D1523-D1527).
--
--  Serve reads the editor's requests from Client until it disconnects or
--  its input ends.  `launch` and `attach` choose the debugger: GDB for an
--  ELF program unless it is FreeBSD's, LLDB for FreeBSD's and for a
--  Mach-O, or the one the request's `debugger` names, started as its
--  `debuggerPath` says or by its usual name.  GDB is spoken to over
--  GDB/MI and every request is answered here; LLDB is LLDB's own adapter,
--  `lldb-dap`, and its messages are relayed, renumbered, with the launch
--  and attach arguments written in its terms.
--
--  What both get alike: the library's files, recorded as
--  `/landin-library/NAMESPACE/...` (D422), are shown from the library
--  this command was shipped with, mapped one namespace at a time so that
--  nothing else under the library's directory is renamed (D1525); and a
--  stop in a `panic_handler` is an exception stop whose description is the
--  site it received, resolved through the program's source table (D1526).

with Landin.Platform;

package Landin.Adapter.Sessions is

   type Debugger_Kind is (GDB, LLDB);

   --  The debugger a program takes from its first bytes: LLDB for a
   --  Mach-O and for an ELF whose header names FreeBSD, else GDB.
   function Debugger_For (Header : String) return Debugger_Kind;

   --  Where a recorded path is read from: a library file's
   --  `/landin-library/NAMESPACE/REST` under Library, any other path as
   --  it is, and every path as it is when Library is "".
   function Local_Path (Recorded, Library : String) return String;

   --  The reverse: a file under one of Library's namespaces as the
   --  debug information records it.
   function Recorded_Path (Local, Library : String) return String;

   --  Serve one editor.  Status is 0 when the editor disconnected or its
   --  input ended between messages, 1 when its framing could not be read.
   procedure Serve
     (Client   : in out Landin.Platform.Channel'Class;
      Debugger : aliased in out Landin.Platform.Debugger_Session'Class;
      Files    : Landin.Platform.Filesystem'Class;
      Tools    : Landin.Platform.Tool_Runner'Class;
      Library  : String;
      Status   : out Integer);

end Landin.Adapter.Sessions;
