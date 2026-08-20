with Ada.Strings.Unbounded;

with GNAT.OS_Lib;

package body Landin.Platform.Native.Tools is

   package Unbounded renames Ada.Strings.Unbounded;
   package OS renames GNAT.OS_Lib;

   use type OS.String_Access;

   --  Every run stages its capture under its own name, so two runners
   --  sharing a scratch directory cannot read each other's output.
   Captures : Natural := 0;

   function Trimmed (Value : Natural) return String;

   function Trimmed (Value : Natural) return String is
      Raw : constant String := Natural'Image (Value);
   begin
      return Raw (Raw'First + 1 .. Raw'Last);
   end Trimmed;

   function Create (Scratch_Directory : String) return Native_Tool_Runner is
   begin
      return Result : Native_Tool_Runner do
         Result.Scratch.Append (Scratch_Directory);
      end return;
   end Create;

   overriding procedure Run
     (Host      : Native_Tool_Runner;
      Program   : String;
      Arguments : Path_List;
      Result    : out Tool_Result;
      Capture   : Capture_Mode := Merged)
   is
      List    : OS.Argument_List (1 .. Integer (Arguments.Length));
      Located : OS.String_Access;
      Success : Boolean;
      Status  : Integer;
      Reader  : Native_Filesystem;
      Read    : Read_Status;
   begin
      Result := (Exit_Code => 0, Output => Unbounded.Null_Unbounded_String);

      --  Create is the only way to get a usable runner.  A default-
      --  initialised one has nowhere to stage captured output, and finding
      --  that out by indexing an empty vector is not a diagnosis.  The
      --  check has to come before anything reads Scratch, which is why the
      --  capture path is not a declaration.
      if Host.Scratch.Is_Empty then
         raise Compiler_Defect
           with "tool runner used without a scratch directory";
      end if;

      Captures := Captures + 1;
      Located := OS.Locate_Exec_On_Path (Program);

      if Located = null then
         raise External_Tool_Failed
           with "tool not found on PATH: " & Program;
      end if;

      for Index in List'Range loop
         List (Index) := new String'(Arguments.Element (Index));
      end loop;

      declare
         Capture_Path : constant String :=
           Host.Scratch.Element (1) & "/tool-output-"
           & Trimmed (Captures) & ".txt";
      begin
         OS.Spawn
           (Program_Name => Located.all,
            Args         => List,
            Output_File  => Capture_Path,
            Success      => Success,
            Return_Code  => Status,
            Err_To_Out   => Capture = Merged);

         for Item of List loop
            OS.Free (Item);
         end loop;
         OS.Free (Located);

         if not Success then
            raise External_Tool_Failed with "could not run tool: " & Program;
         end if;

         Reader.Read_File (Capture_Path, Result.Output, Read);

         if Read /= Read_Ok then
            Result.Output := Unbounded.Null_Unbounded_String;
         end if;

         Result.Exit_Code := Status;
      end;
   end Run;

end Landin.Platform.Native.Tools;
