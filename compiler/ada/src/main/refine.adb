--  `refine` - the direct compiler executable.
--
--  The program is thin on purpose: it turns command-line arguments into a
--  request, prints what the driver produced, and exits with the driver's
--  status.  An unexpected exception here is a compiler defect and says so;
--  it does not print a stack trace at a user.

with Ada.Command_Line;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Ada.Text_IO.Text_Streams;

with Landin;
with Landin.Driver;
with Landin.Commands;
with Landin.Platform;
with Landin.Platform.Native;
with Landin.Platform.Native.Tools;
with Landin.Server.Sessions;

procedure Refine is

   package Command_Line renames Ada.Command_Line;
   package Unbounded renames Ada.Strings.Unbounded;
   package Text_IO renames Ada.Text_IO;

   Arguments : Landin.Platform.Path_List;
   Host      : aliased Landin.Platform.Native.Native_Filesystem;
   Tools     : Landin.Platform.Native.Tools.Native_Tool_Runner;
   Meter     : Landin.Platform.Native.Native_Meter;

   procedure Finish_Command (Status : Command_Line.Exit_Status);

   procedure Finish_Command (Status : Command_Line.Exit_Status) is
      Signal_Number : constant Natural :=
        Landin.Platform.Native.Tools.Cancellation_Requested;
   begin
      if Signal_Number /= 0 then
         --  The signal may be the one that says nobody reads this stream.
         begin
            Text_IO.Put_Line
              (Text_IO.Standard_Error, "refine: cancelled by signal"
               & Natural'Image (Signal_Number));
         exception
            when others =>
               null;
         end;
      end if;
      Landin.Platform.Native.Tools.End_Invocation;
      Command_Line.Set_Exit_Status
        (if Signal_Number = 0 then Status
         else Command_Line.Exit_Status (128 + Signal_Number));
   end Finish_Command;

begin
   for Index in 1 .. Command_Line.Argument_Count loop
      Arguments.Append (Command_Line.Argument (Index));
   end loop;

   --  A server talks to its editor for as long as the editor runs it, so
   --  it has the process's channel rather than a request and a result.
   if Landin.Commands.Is_Server (Arguments, Host) then
      declare
         Channel : Landin.Platform.Native.Native_Channel;
         Status  : Landin.Server.Sessions.Exit_Status;
      begin
         Landin.Server.Sessions.Serve (Channel, Host'Access, Status);
         Command_Line.Set_Exit_Status (Command_Line.Exit_Status (Status));
         return;
      end;
   end if;

   Landin.Platform.Native.Tools.Begin_Invocation;
   declare
      Result : Landin.Driver.Outcome :=
        Landin.Commands.Execute
          (Arguments, Host, Tools, Meter,
           Terminal_Color => Landin.Platform.Native.Diagnostic_Color);

      --  A run that will not launch still owns its private directory.
      procedure Abandon_Launch;

      procedure Abandon_Launch is
         use type Landin.Platform.Remove_Status;
         Removed : Landin.Platform.Remove_Status;
      begin
         if Unbounded.Length (Result.Launch_Directory) = 0 then
            return;
         end if;
         Host.Remove_Tree
           (Unbounded.To_String (Result.Launch_Directory), Removed);
         if Removed = Landin.Platform.Not_Removable then
            Unbounded.Append
              (Result.Report, "refine: could not remove cancelled run's "
               & "private directory: "
               & Unbounded.To_String (Result.Launch_Directory) & ": "
               & Host.Removal_Failure_Reason & ASCII.LF);
         end if;
         Result.Launch_Program := Unbounded.Null_Unbounded_String;
         Result.Launch_Directory := Unbounded.Null_Unbounded_String;
      end Abandon_Launch;
   begin
      --  Compilation can finish just as cancellation arrives. A pending
      --  run still owns its private directory, but must not launch a program.
      if Landin.Platform.Native.Tools.Cancellation_Requested /= 0 then
         Abandon_Launch;
      end if;

      --  What compiling said, then the program.  Writing can fail: the
      --  reader of the pipe has gone, which while a run's directory exists
      --  is a recorded signal and a refused write rather than the end of
      --  the process.  The directory is removed on that way out too, and
      --  a recorded signal is reported as the cancellation it is.
      begin
         --  Written as bytes, not as text.  Ada.Text_IO does not recognise
         --  the line feeds inside these strings, so it believes the last line
         --  is unterminated and appends a terminator of its own: a blank line
         --  at the end of every run, and a golden file nobody can record.
         if Unbounded.Length (Result.Output) > 0 then
            String'Write
              (Text_IO.Text_Streams.Stream (Text_IO.Standard_Output),
               Unbounded.To_String (Result.Output));
         end if;

         if Unbounded.Length (Result.Trace) > 0 then
            String'Write
              (Text_IO.Text_Streams.Stream (Text_IO.Standard_Error),
               Unbounded.To_String (Result.Trace));
         end if;

         if Unbounded.Length (Result.Report) > 0 then
            String'Write
              (Text_IO.Text_Streams.Stream (Text_IO.Standard_Error),
               Unbounded.To_String (Result.Report));
         end if;

         --  D526: `refine run`'s program, once what compiling it said is
         --  written, so the program's output follows it.
         if Unbounded.Length (Result.Launch_Program) > 0 then
            Text_IO.Flush (Text_IO.Standard_Output);
            Text_IO.Flush (Text_IO.Standard_Error);
            Landin.Commands.Launch (Result, Host, Tools);
            if Unbounded.Length (Result.Report) > 0 then
               String'Write
                 (Text_IO.Text_Streams.Stream (Text_IO.Standard_Error),
                  Unbounded.To_String (Result.Report));
            end if;
         end if;
      exception
         when others =>
            Abandon_Launch;
            if Landin.Platform.Native.Tools.Cancellation_Requested = 0 then
               raise;
            end if;
      end;

      Finish_Command
        (Command_Line.Exit_Status (Result.Status));
   end;

exception
   --  A defect the driver already turned into an outcome does not reach
   --  here: Landin.Driver.Execute renders what the run had decided and
   --  returns Status_Defect, so a reader sees their program's report and
   --  the compiler's failure under it.  This stays as the backstop for
   --  one raised outside that boundary, where there is nothing to render.
   when Landin.Compiler_Defect =>
      Text_IO.Put_Line
        (Text_IO.Standard_Error, "refine: internal compiler defect");
      Finish_Command (Landin.Driver.Status_Defect);

   when Landin.Host_Exhausted =>
      Text_IO.Put_Line
        (Text_IO.Standard_Error, "refine: host resources exhausted");
      Finish_Command (71);

   when Landin.External_Tool_Failed =>
      Text_IO.Put_Line
        (Text_IO.Standard_Error, "refine: an external tool could not be run");
      Finish_Command (72);

   --  Storage_Error is the host running out, not the compiler being
   --  wrong, and it is the way an exhausted host actually shows up: the
   --  compiler never raises Host_Exhausted for memory itself.
   when Storage_Error =>
      Text_IO.Put_Line
        (Text_IO.Standard_Error, "refine: host resources exhausted");
      Finish_Command (71);

   --  Anything else arriving here is a defect as well, and the point of a
   --  handler is that a user reads a sentence instead of a traceback.
   when others =>
      Text_IO.Put_Line
        (Text_IO.Standard_Error, "refine: internal compiler defect");
      Finish_Command (Landin.Driver.Status_Defect);
end Refine;
