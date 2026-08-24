--  The test program.
--
--  Suites register themselves here, explicitly.  Elaboration order is not a
--  registration mechanism: a suite that appears only because a unit happened
--  to be elaborated is a suite that can silently disappear.

with Ada.Command_Line;
with Ada.Directories;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with Landin.Testing;
with Landin.Tests.Backend_Suite;
with Landin.Tests.Catalogue_Suite;
with Landin.Tests.Diagnostics_Suite;
with Landin.Tests.Driver_Suite;
with Landin.Tests.Fixture_Execution_Suite;
with Landin.Tests.Fixture_Suite;
with Landin.Tests.Harness_Suite;
with Landin.Tests.IR_Suite;
with Landin.Tests.Lexer_Suite;
with Landin.Tests.Lowering_Suite;
with Landin.Tests.Parser_Suite;
with Landin.Tests.Platform_Suite;
with Landin.Tests.Resolution_Suite;
with Landin.Tests.Source_Suite;
with Landin.Tests.Stages_Suite;
with Landin.Tests.Targets_Suite;
with Landin.Tests.Verifier_Suite;

procedure Landin_Tests is

   package Unbounded renames Ada.Strings.Unbounded;
   package Text_IO renames Ada.Text_IO;

   Cases      : Landin.Testing.Registry;
   Transcript : Unbounded.Unbounded_String;
   Result     : Landin.Testing.Summary;

   --  Every suite resolves the repository's trees relative to compiler/ada
   --  and writes its scratch files under build/ there.  Run from anywhere
   --  else, the fixture cases would report the repository's own fixtures as
   --  broken and leave a stray tree behind, so say what is wrong and stop
   --  before a single case runs.
   Marker : constant String := "../tests/fixtures";

   --  Named here, so a suite that stops registering makes the run red
   --  rather than making it shorter.  One padded array rather than a list
   --  of accesses: the suite names are short and the widths are obvious.
   subtype Suite_Name is String (1 .. 17);

   Expected_Suites : constant array (Positive range <>) of Suite_Name :=
     ["backend          ",
      "diagnostics      ",
      "driver           ",
      "fixture execution",
      "fixtures         ",
      "harness          ",
      "ir               ",
      "lowering         ",
      "parser           ",
      "platform         ",
      "resolution       ",
      "source           ",
      "stages           ",
      "targets          ",
      "verifier         "];

   function Trimmed (Name : Suite_Name) return String;

   function Trimmed (Name : Suite_Name) return String is
      Last : Natural := Name'Last;
   begin
      while Last >= Name'First and then Name (Last) = ' ' loop
         Last := Last - 1;
      end loop;
      return Name (Name'First .. Last);
   end Trimmed;

begin
   --  Recording writes the artefact and runs no case, so a run that
   --  recorded can never be mistaken for a run that passed.  Chosen only
   --  by an argument a human typed: no environment variable, and nothing
   --  that rewrites a golden because it did not match.
   if Ada.Command_Line.Argument_Count = 1
     and then Ada.Command_Line.Argument (1) = "--record"
   then
      declare
         Path  : constant String := "../tests/lowering.ir";
         Wrote : Boolean;
      begin
         if not Ada.Directories.Exists (Marker) then
            Text_IO.Put_Line
              (Text_IO.Standard_Error,
               "landin_tests --record must be run from compiler/ada");
            Ada.Command_Line.Set_Exit_Status (2);
            return;
         end if;

         Landin.Tests.Lowering_Suite.Record_Artefact (Path, Wrote);

         if Wrote then
            Text_IO.Put_Line ("wrote compiler/tests/lowering.ir");
         else
            Text_IO.Put_Line
              (Text_IO.Standard_Error, "could not write " & Path);
            Ada.Command_Line.Set_Exit_Status (1);
         end if;
      end;

      return;
   end if;

   if not Ada.Directories.Exists (Marker) then
      Text_IO.Put_Line
        (Text_IO.Standard_Error,
         "landin_tests must be run from compiler/ada; " & Marker
         & " is not reachable from here");
      Ada.Command_Line.Set_Exit_Status (2);
      return;
   end if;

   Landin.Tests.Backend_Suite.Register (Cases);
   Landin.Tests.Catalogue_Suite.Register (Cases);
   Landin.Tests.Diagnostics_Suite.Register (Cases);
   Landin.Tests.Driver_Suite.Register (Cases);
   Landin.Tests.Fixture_Execution_Suite.Register (Cases);
   Landin.Tests.Fixture_Suite.Register (Cases);
   Landin.Tests.Harness_Suite.Register (Cases);
   Landin.Tests.IR_Suite.Register (Cases);
   Landin.Tests.Lexer_Suite.Register (Cases);
   Landin.Tests.Lowering_Suite.Register (Cases);
   Landin.Tests.Parser_Suite.Register (Cases);
   Landin.Tests.Platform_Suite.Register (Cases);
   Landin.Tests.Resolution_Suite.Register (Cases);
   Landin.Tests.Source_Suite.Register (Cases);
   Landin.Tests.Stages_Suite.Register (Cases);
   Landin.Tests.Targets_Suite.Register (Cases);
   Landin.Tests.Verifier_Suite.Register (Cases);

   for Suite of Expected_Suites loop
      if not Landin.Testing.Has_Suite (Cases, Trimmed (Suite)) then
         raise Landin.Compiler_Defect
           with "test suite is not registered: " & Trimmed (Suite);
      end if;
   end loop;

   Landin.Testing.Run (Cases, Transcript, Result);
   Text_IO.Put (Unbounded.To_String (Transcript));

   if Result.Failed > 0 or else Result.Cases = 0 then
      Ada.Command_Line.Set_Exit_Status (1);
   end if;
end Landin_Tests;
