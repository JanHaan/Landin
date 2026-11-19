--  `refine-dap`: the Debug Adapter Protocol server, run as `refine dap`
--  (D1383, D1523).
--
--  With no arguments it serves one editor over standard input and output
--  until the editor disconnects.  It answers `--describe`, `--help` and
--  `--complete`, the whole of a split command's contract with `refine`
--  (D1485), and refuses anything else with its usage.

with Ada.Command_Line;
with Ada.Text_IO;

with Landin.Adapter.Sessions;
with Landin.Build_Identity;
with Landin.Json;
with Landin.Library;
with Landin.Platform.Native;
with Landin.Platform.Native.Tools;

procedure Refine_Dap is

   package Command_Line renames Ada.Command_Line;
   package Text_IO renames Ada.Text_IO;

   Summary : constant String :=
     "serve the Debug Adapter Protocol over GDB and LLDB";

   Usage : constant String :=
     "usage: refine dap" & ASCII.LF
     & ASCII.LF
     & "A Debug Adapter Protocol server.  An editor starts it as"
     & " its debug" & ASCII.LF
     & "adapter and talks to it over standard input and output"
     & " until the" & ASCII.LF
     & "editor disconnects.  Nobody types at it." & ASCII.LF
     & ASCII.LF
     & "A launch request names a program refine compile"
     & " --debug=full wrote:" & ASCII.LF
     & "  {""program"": ""PATH"", ""args"": [...], ""cwd"":"
     & " ""DIR"", ""stopOnEntry"": false}" & ASCII.LF
     & ASCII.LF
     & "An attach request adds ""remote"", where a debugger stub"
     & " listens:" & ASCII.LF
     & "HOST:PORT, or for GDB a socket's path.  The program and its"
     & " sources" & ASCII.LF
     & "must be at the same paths on both machines." & ASCII.LF
     & ASCII.LF
     & "A Linux program is debugged with GDB.  A macOS or FreeBSD"
     & " program is" & ASCII.LF
     & "debugged with lldb-dap, LLVM's own adapter, found on PATH"
     & " or, on" & ASCII.LF
     & "macOS, by xcrun --find lldb-dap." & ASCII.LF
     & "  ""debugger"": ""gdb"" or ""lldb""  chooses the other"
     & " debugger" & ASCII.LF
     & "  ""debuggerPath"": ""PATH""       names the executable to"
     & " start" & ASCII.LF
     & ASCII.LF
     & "Library files are shown from the installed library.  What"
     & " the program" & ASCII.LF
     & "writes reaches the editor's console." & ASCII.LF
     & ASCII.LF
     & "Compile with --panic-map, which writes"
     & " PROGRAM.sources.json, and a" & ASCII.LF
     & "stop in panic_handler is shown as an exception at the"
     & " source line and" & ASCII.LF
     & "column of its site:" & ASCII.LF
     & "  panic: overflow at main.ldn:36:5" & ASCII.LF
     & "Set a function breakpoint on panic_handler to stop there." & ASCII.LF;

   function Description return String;
   function Description return String is
      B : Landin.Json.Builder;
   begin
      Landin.Json.Begin_Object (B);
      Landin.Json.Name (B, "format");
      Landin.Json.Write_String (B, "landin-command-1");
      Landin.Json.Name (B, "name");
      Landin.Json.Write_String (B, "dap");
      Landin.Json.Name (B, "summary");
      Landin.Json.Write_String (B, Summary);
      Landin.Json.Name (B, "source_digest");
      Landin.Json.Write_String (B, Landin.Build_Identity.Source_Digest);
      Landin.Json.Name (B, "codes");
      Landin.Json.Begin_Array (B);
      Landin.Json.End_Array (B);
      Landin.Json.End_Object (B);
      return Landin.Json.Result (B);
   end Description;

   Help_Option : constant String := "--help";
   Count : constant Natural := Command_Line.Argument_Count;
begin
   if Count = 1 and then Command_Line.Argument (1) = "--describe" then
      Text_IO.Put_Line (Description);
   elsif Count = 1 and then Command_Line.Argument (1) in "--help" | "-h"
   then
      Text_IO.Put (Usage);
   elsif Count >= 2 and then Command_Line.Argument (1) = "--complete"
     and then Command_Line.Argument (2) = "--"
   then
      --  `refine dap` takes no words; only its help is offered.
      if Count = 3
        and then Command_Line.Argument (3)'Length <= 6
        and then Help_Option (1 .. Command_Line.Argument (3)'Length)
          = Command_Line.Argument (3)
      then
         Text_IO.Put_Line ("--help");
      end if;
   elsif Count = 0 then
      declare
         Files : Landin.Platform.Native.Native_Filesystem;
         Tools : Landin.Platform.Native.Tools.Native_Tool_Runner;
         Client : Landin.Platform.Native.Native_Channel;
         Debugger : aliased Landin.Platform.Native.Native_Debugger_Session;
         Status : Integer;
      begin
         Landin.Adapter.Sessions.Serve
           (Client, Debugger, Files, Tools,
            Landin.Library.Located_For_Split (Files), Status);
         Command_Line.Set_Exit_Status (Command_Line.Exit_Status (Status));
      end;
   else
      Text_IO.Put (Text_IO.Standard_Error,
                   "refine dap takes no arguments; an editor starts it"
                   & " and speaks the Debug Adapter Protocol to it"
                   & ASCII.LF & ASCII.LF & Usage);
      Command_Line.Set_Exit_Status (2);
   end if;
end Refine_Dap;
