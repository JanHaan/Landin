with Ada.Strings.Unbounded;

with GNAT.OS_Lib;

package body Landin.Platform.Native.Tools is

   package Unbounded renames Ada.Strings.Unbounded;
   package OS renames GNAT.OS_Lib;

   use type OS.File_Descriptor;
   use type OS.String_Access;

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

      pragma Unreferenced (Host);
   begin
      Result := (Exit_Code => 0, Output => Unbounded.Null_Unbounded_String);
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

      OS.Spawn
        (Program_Name => Located.all,
         Args         => List,
         Output_File  => Name.all,
         Success      => Success,
         Return_Code  => Status,
         Err_To_Out   => Capture = Merged);

      if not Success then
         raise External_Tool_Failed with "could not run tool: " & Program;
      end if;

      Reader.Read_File (Name.all, Result.Output, Read);
      if Read /= Read_Ok then
         Result.Output := Unbounded.Null_Unbounded_String;
      end if;
      Result.Exit_Code := Status;

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
