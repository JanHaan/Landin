with Ada.Command_Line;
with Ada.IO_Exceptions;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Ada.Text_IO.Text_Streams;
with Landin.Platform.Native;
with Landin.Platform.Native.Tools;
with Landin.Targets.Selection;

package body Landin.Splits.Native is

   package Command_Line renames Ada.Command_Line;
   package Text_IO renames Ada.Text_IO;
   package Unbounded renames Ada.Strings.Unbounded;

   --  The statuses `refine` ends with when the host or a tool failed it.
   Status_Host_Fault : constant Command_Line.Exit_Status := 71;
   Status_Tool_Fault : constant Command_Line.Exit_Status := 72;

   procedure Main (Name : String; Run : Entry_Point) is
      Program : constant String := "refine-" & Name;
      Arguments : Landin.Platform.Path_List;
      Host  : Landin.Platform.Native.Native_Filesystem;
      Tools : Landin.Platform.Native.Tools.Native_Tool_Runner;

      procedure Say (Line : String);
      procedure Say (Line : String) is
      begin
         Text_IO.Put_Line (Text_IO.Standard_Error, Program & ": " & Line);
      exception
         when Ada.IO_Exceptions.Device_Error | Ada.IO_Exceptions.Use_Error =>
            null;
      end Say;

      --  A recorded signal ends the run as `refine` ends it (D1047).
      procedure Finish (Status : Command_Line.Exit_Status);
      procedure Finish (Status : Command_Line.Exit_Status) is
         Signal_Number : constant Natural :=
           Landin.Platform.Native.Tools.Cancellation_Requested;
      begin
         if Signal_Number /= 0 then
            Say ("cancelled by signal" & Natural'Image (Signal_Number));
         end if;
         Landin.Platform.Native.Tools.End_Invocation;
         Command_Line.Set_Exit_Status
           (if Signal_Number = 0 then Status
            else Command_Line.Exit_Status (128 + Signal_Number));
      end Finish;
   begin
      for Index in 1 .. Command_Line.Argument_Count loop
         Arguments.Append (Command_Line.Argument (Index));
      end loop;
      Landin.Platform.Native.Tools.Begin_Invocation;
      declare
         Result : constant Landin.Outcomes.Outcome :=
           Run (Arguments, Host, Tools,
                Landin.Targets.Selection.Build_Triplet,
                Landin.Platform.Native.Diagnostic_Color);
      begin
         --  Written as bytes: Ada.Text_IO would add a line terminator of
         --  its own after the last line feed.
         if Unbounded.Length (Result.Output) > 0 then
            begin
               String'Write
                 (Text_IO.Text_Streams.Stream (Text_IO.Standard_Output),
                  Unbounded.To_String (Result.Output));
               Text_IO.Flush (Text_IO.Standard_Output);
            exception
               when Ada.IO_Exceptions.Device_Error
                  | Ada.IO_Exceptions.Use_Error =>
                  if Landin.Platform.Native.Tools.Cancellation_Requested = 0
                  then
                     Say ("cannot write to standard output");
                     Finish (Status_Host_Fault);
                     return;
                  end if;
            end;
         end if;
         begin
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
         exception
            when Ada.IO_Exceptions.Device_Error
               | Ada.IO_Exceptions.Use_Error =>
               null;
         end;
         Finish (Command_Line.Exit_Status (Result.Status));
      end;
   exception
      when Landin.Compiler_Defect =>
         Say ("internal compiler defect");
         Finish (Landin.Outcomes.Status_Defect);
      when Landin.Host_Exhausted =>
         Say ("host resources exhausted");
         Finish (Status_Host_Fault);
      when Landin.External_Tool_Failed =>
         Say ("an external tool could not be run");
         Finish (Status_Tool_Fault);
      when Storage_Error =>
         Say ("host resources exhausted: memory, or the stack this process"
           & " is limited to (`ulimit -s`)");
         Finish (Status_Host_Fault);
      when others =>
         Say ("internal compiler defect");
         Finish (Landin.Outcomes.Status_Defect);
   end Main;

end Landin.Splits.Native;
