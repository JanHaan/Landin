with Ada.Calendar;
with Ada.Strings.Unbounded;

with GNAT.OS_Lib;

with Interfaces.C;

package body Landin.Platform.Native.Tools is

   package Unbounded renames Ada.Strings.Unbounded;
   package OS renames GNAT.OS_Lib;

   use type Ada.Calendar.Time;
   use type Interfaces.C.int;
   use type OS.File_Descriptor;
   use type OS.Process_Id;
   use type OS.String_Access;

   --  GNAT's own wait reports only whether the child exited zero, and the
   --  harness needs the status a program chose.  waitpid is the one POSIX
   --  call that answers both without blocking, on the two hosts this
   --  adapter serves; its status word is decoded the way both spell it.
   function Wait_Pid
     (Pid     : Interfaces.C.int;
      Status  : access Interfaces.C.int;
      Options : Interfaces.C.int) return Interfaces.C.int
     with Import, Convention => C, External_Name => "waitpid";

   No_Hang : constant Interfaces.C.int := 1;

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
      List    : OS.Argument_List (1 .. Integer (Arguments.Length)) :=
        [others => null];
      Located : OS.String_Access := null;
      Name    : OS.String_Access := null;
      FD      : OS.File_Descriptor := OS.Invalid_FD;
      Success : Boolean;
      Status  : Integer;
      Timed_Out : Boolean := False;
      Reader  : Native_Filesystem;
      Read    : Read_Status;

      procedure Release_Arguments;

      procedure Release_Arguments is
      begin
         for Item of List loop
            OS.Free (Item);
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

      for Index in List'Range loop
         List (Index) := new String'(Arguments.Element (Index));
      end loop;

      --  The GNAT runtime chooses a name unique to this process and creates it
      --  before returning.  The filename-based Spawn owns the descriptor it
      --  uses, so the creation descriptor must not remain open across Spawn.
      OS.Create_Temp_Output_File (FD, Name);

      if FD = OS.Invalid_FD or else Name = null then
         raise External_Tool_Failed
           with "could not create temporary tool output";
      end if;

      OS.Close (FD, Success);
      if not Success then
         raise External_Tool_Failed
           with "could not close temporary tool output";
      end if;
      FD := OS.Invalid_FD;

      declare
         Pid : constant OS.Process_Id :=
           OS.Non_Blocking_Spawn
             (Program_Name => Located.all,
              Args         => List,
              Output_File  => Name.all,
              Err_To_Out   => Capture = Merged);
         Deadline : constant Ada.Calendar.Time :=
           Ada.Calendar.Clock + Host.Limit;
         Word   : aliased Interfaces.C.int := 0;
         Reaped : Interfaces.C.int := 0;
      begin
         if Pid = OS.Invalid_Pid then
            raise External_Tool_Failed with "could not run tool: " & Program;
         end if;

         Timed_Out := False;
         loop
            Reaped :=
              Wait_Pid (Interfaces.C.int (OS.Pid_To_Integer (Pid)),
                        Word'Access, No_Hang);
            exit when Reaped /= 0;
            if Ada.Calendar.Clock > Deadline then
               OS.Kill (Pid, Hard_Kill => True);
               Reaped :=
                 Wait_Pid (Interfaces.C.int (OS.Pid_To_Integer (Pid)),
                           Word'Access, 0);
               Timed_Out := True;
               exit;
            end if;
            delay 0.02;
         end loop;

         if Reaped < 0 then
            raise External_Tool_Failed
              with "could not wait for tool: " & Program;
         end if;

         --  The low seven bits name a signal, or nothing; the next byte is
         --  the exit status when there was one.
         if Timed_Out or else Integer (Word) mod 128 /= 0 then
            Status := -1;
         else
            Status := (Integer (Word) / 256) mod 256;
         end if;
      end;

      Reader.Read_File (Name.all, Result.Output, Read);
      if Read /= Read_Ok then
         Result.Output := Unbounded.Null_Unbounded_String;
      end if;
      if Timed_Out then
         Unbounded.Append
           (Result.Output,
            "landin: " & Program & " ran longer than the limit of"
            & Duration'Image (Host.Limit) & " seconds and was stopped"
            & ASCII.LF);
      end if;

      --  A child that a signal killed is reported here as -1, and an
      --  ordinary exit as its own status.  That is measured rather than
      --  assumed: this exact call answers `success=TRUE code=-1` for a
      --  child killed by SIGILL and by SIGSEGV, and `code=7` for one that
      --  exited 7, on the pinned GNAT inside the linux/amd64 image.  A
      --  POSIX exit status is one byte and so can never be -1, which is
      --  what makes the two answerable apart.
      --
      --  No signal number reaches the record; [1960] says which signal is
      --  not stable program behaviour, and this seam is where that stops.
      if Status = -1 then
         Result.Ended := Landin.Platform.Signaled;
         Result.Exit_Code := 0;
      else
         Result.Ended := Landin.Platform.Exited;
         Result.Exit_Code := Status;
      end if;

      Cleanup_Capture;
      Release_Arguments;
   exception
      when others =>
         begin
            Cleanup_Capture;
         exception
            when others => null;
         end;
         Release_Arguments;
         raise;
   end Run;

end Landin.Platform.Native.Tools;
