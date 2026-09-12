with Ada.Real_Time;
with Ada.Strings.Unbounded;

with GNAT.OS_Lib;

with Interfaces.C;
with Interfaces.C.Strings;

package body Landin.Platform.Native.Tools is

   package Unbounded renames Ada.Strings.Unbounded;
   package OS renames GNAT.OS_Lib;
   package C_Strings renames Interfaces.C.Strings;

   use type Ada.Real_Time.Time;
   use type Interfaces.C.int;
   use type Interfaces.C.size_t;
   use type OS.File_Descriptor;
   use type OS.String_Access;

   --  Host structs and wait/signal constants belong to the C adapter.
   --  The spawn action establishes a private process group before exec.
   function Start_Tool
     (Args    : C_Strings.chars_ptr_array;
      Capture : Interfaces.C.int;
      Merged  : Interfaces.C.int;
      Child   : access Interfaces.C.int) return Interfaces.C.int
     with Import, Convention => C, External_Name => "landin_tool_start";

   function Wait_Tool
     (Child   : Interfaces.C.int;
      Status  : access Interfaces.C.int;
      No_Hang : Interfaces.C.int) return Interfaces.C.int
     with Import, Convention => C, External_Name => "landin_tool_wait";

   function Stop_Tool
     (Child  : Interfaces.C.int;
      Status : access Interfaces.C.int) return Interfaces.C.int
     with Import, Convention => C, External_Name => "landin_tool_stop";

   procedure Set_Limit
     (Host : in out Native_Tool_Runner; Seconds : Duration) is
   begin
      Host.Limit := Seconds;
   end Set_Limit;

   overriding procedure Run
     (Host      : Native_Tool_Runner;
      Program   : String;
      Arguments : Path_List;
      Result    : out Tool_Result;
      Capture   : Capture_Mode := Merged)
   is
      List           : C_Strings.chars_ptr_array
        (0 .. Interfaces.C.size_t (Arguments.Length) + 1) :=
          [others => C_Strings.Null_Ptr];
      Located        : OS.String_Access := null;
      Name           : OS.String_Access := null;
      FD             : OS.File_Descriptor := OS.Invalid_FD;
      Success        : Boolean;
      Status         : aliased Interfaces.C.int := 0;
      Pid            : aliased Interfaces.C.int := 0;
      Exceeded_Limit : Boolean := False;
      Reader         : Native_Filesystem;
      Read           : Read_Status;

      procedure Stop_Child;

      procedure Stop_Child is
      begin
         if Pid > 0 then
            if Stop_Tool (Pid, Status'Access) /= Pid then
               raise External_Tool_Failed
                 with "could not stop tool process group: " & Program;
            end if;
            Pid := 0;
         end if;
      end Stop_Child;

      procedure Release_Arguments;

      procedure Release_Arguments is
      begin
         for Item of List loop
            C_Strings.Free (Item);
         end loop;
         OS.Free (Located);
      end Release_Arguments;

      procedure Cleanup_Capture;

      procedure Cleanup_Capture is
         Closed  : Boolean := True;
         Deleted : Boolean := True;
      begin
         if FD /= OS.Invalid_FD then
            OS.Close (FD, Closed);
            if Closed then
               FD := OS.Invalid_FD;
            end if;
         end if;

         if Name /= null then
            OS.Delete_File (Name.all, Deleted);
            OS.Free (Name);
         end if;

         if not Closed or else not Deleted then
            raise External_Tool_Failed
              with "could not remove temporary tool output";
         end if;
      end Cleanup_Capture;

   begin
      Result := (Ended     => Landin.Platform.Exited,
                 Exit_Code => 0,
                 Output    => Unbounded.Null_Unbounded_String);
      Located := OS.Locate_Exec_On_Path (Program);

      if Located = null then
         raise External_Tool_Failed
           with "tool not found on PATH: " & Program;
      end if;

      List (0) := C_Strings.New_String (Located.all);
      for Index in 1 .. Natural (Arguments.Length) loop
         List (Interfaces.C.size_t (Index)) :=
           C_Strings.New_String (Arguments.Element (Index));
      end loop;

      --  The GNAT runtime chooses a name unique to this process and creates it
      --  before returning. Pass that open descriptor to the spawn action,
      --  avoiding a second filename lookup before the child captures output.
      OS.Create_Temp_Output_File (FD, Name);

      if FD = OS.Invalid_FD or else Name = null then
         raise External_Tool_Failed
           with "could not create temporary tool output";
      end if;

      declare
         Deadline : constant Ada.Real_Time.Time :=
           Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (Host.Limit);
         Reaped : Interfaces.C.int := 0;
      begin
         if Start_Tool
           (List, Interfaces.C.int (FD),
            Boolean'Pos (Capture = Merged), Pid'Access) /= 0
         then
            raise External_Tool_Failed with "could not run tool: " & Program;
         end if;

         OS.Close (FD, Success);
         if not Success then
            raise External_Tool_Failed
              with "could not close temporary tool output";
         end if;
         FD := OS.Invalid_FD;

         Exceeded_Limit := False;
         loop
            Reaped :=
              Wait_Tool (Pid, Status'Access, No_Hang => 1);
            exit when Reaped /= 0;
            if Ada.Real_Time.Clock > Deadline then
               Stop_Child;
               Exceeded_Limit := True;
               exit;
            end if;
            delay 0.02;
         end loop;

         if Reaped < 0 then
            raise External_Tool_Failed
              with "could not wait for tool: " & Program;
         end if;

         Pid := 0;
      end;

      Reader.Read_File (Name.all, Result.Output, Read);
      if Read /= Read_Ok then
         Result.Output := Unbounded.Null_Unbounded_String;
      end if;
      if Exceeded_Limit then
         Unbounded.Append
           (Result.Output,
            "landin: " & Program & " ran longer than the limit of"
            & Duration'Image (Host.Limit) & " seconds and was stopped"
            & ASCII.LF);
      end if;

      --  The host adapter decodes wait status using the host's macros:
      --  an ordinary exit retains its status; signal termination is -1.
      --  The native platform cases check both outcomes on each host.
      --
      --  A watchdog kill has the same POSIX wait status as another signal,
      --  so Exceeded_Limit takes precedence over that decoding.  No signal
      --  number reaches the record; [1960] says which signal is not stable
      --  program behaviour, and this seam is where that stops.
      if Exceeded_Limit then
         Result.Ended := Landin.Platform.Timed_Out;
         Result.Exit_Code := 0;
      elsif Status = -1 then
         Result.Ended := Landin.Platform.Signaled;
         Result.Exit_Code := 0;
      else
         Result.Ended := Landin.Platform.Exited;
         Result.Exit_Code := Integer (Status);
      end if;

      Cleanup_Capture;
      Release_Arguments;
   exception
      when others =>
         begin
            Stop_Child;
         exception
            when others => null;
         end;
         begin
            Cleanup_Capture;
         exception
            when others => null;
         end;
         Release_Arguments;
         raise;
   end Run;

end Landin.Platform.Native.Tools;
