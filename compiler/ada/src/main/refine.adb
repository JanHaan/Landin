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
with Landin.Platform;
with Landin.Platform.Native;
with Landin.Platform.Native.Tools;

procedure Refine is

   package Command_Line renames Ada.Command_Line;
   package Unbounded renames Ada.Strings.Unbounded;
   package Text_IO renames Ada.Text_IO;

   Arguments : Landin.Platform.Path_List;
   Host      : Landin.Platform.Native.Native_Filesystem;
   Tools     : Landin.Platform.Native.Tools.Native_Tool_Runner;

begin
   for Index in 1 .. Command_Line.Argument_Count loop
      Arguments.Append (Command_Line.Argument (Index));
   end loop;

   declare
      Result : constant Landin.Driver.Outcome :=
        Landin.Driver.Execute (Arguments, Host, Tools);
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

      if Unbounded.Length (Result.Report) > 0 then
         String'Write
           (Text_IO.Text_Streams.Stream (Text_IO.Standard_Error),
            Unbounded.To_String (Result.Report));
      end if;

      Command_Line.Set_Exit_Status
        (Command_Line.Exit_Status (Result.Status));
   end;

exception
   when Landin.Compiler_Defect =>
      Text_IO.Put_Line
        (Text_IO.Standard_Error, "refine: internal compiler defect");
      Command_Line.Set_Exit_Status (70);

   when Landin.Host_Exhausted =>
      Text_IO.Put_Line
        (Text_IO.Standard_Error, "refine: host resources exhausted");
      Command_Line.Set_Exit_Status (71);

   when Landin.External_Tool_Failed =>
      Text_IO.Put_Line
        (Text_IO.Standard_Error, "refine: an external tool could not be run");
      Command_Line.Set_Exit_Status (72);

   --  Storage_Error is the host running out, not the compiler being
   --  wrong, and it is the way an exhausted host actually shows up: the
   --  compiler never raises Host_Exhausted for memory itself.
   when Storage_Error =>
      Text_IO.Put_Line
        (Text_IO.Standard_Error, "refine: host resources exhausted");
      Command_Line.Set_Exit_Status (71);

   --  Anything else arriving here is a defect as well, and the point of a
   --  handler is that a user reads a sentence instead of a traceback.
   when others =>
      Text_IO.Put_Line
        (Text_IO.Standard_Error, "refine: internal compiler defect");
      Command_Line.Set_Exit_Status (70);
end Refine;
