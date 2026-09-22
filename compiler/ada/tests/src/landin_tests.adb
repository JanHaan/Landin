--  The test program.
--
--  Suites register themselves here, explicitly.  Elaboration order is not a
--  registration mechanism: a suite that appears only because a unit happened
--  to be elaborated is a suite that can silently disappear.

with Ada.Command_Line;
with Ada.Containers.Generic_Array_Sort;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with Landin.Testing;
with Landin.Tests.Array_Layout_Suite;
with Landin.Tests.IR_Optimization_Suite;
with Landin.Tests.Backend_Plans_Suite;
with Landin.Tests.Backend_Scale_Suite;
with Landin.Tests.Frontend_Review_Suite;
with Landin.Tests.Host_Reports_Suite;
with Landin.Tests.Backend_Suite;
with Landin.Tests.Catalogue_Suite;
with Landin.Tests.Checking_Suite;
with Landin.Tests.Debugging_Suite;
with Landin.Tests.Diagnostics_Suite;
with Landin.Tests.Driver_Suite;
with Landin.Tests.Fixture_Execution_Suite;
with Landin.Tests.Fixture_Suite;
with Landin.Tests.Harness_Suite;
with Landin.Tests.IR_Suite;
with Landin.Tests.Lexer_Suite;
with Landin.Tests.Lowering_Suite;
with Landin.Tests.Optimization_Driver_Suite;
with Landin.Tests.Optimization_Foundations_Suite;
with Landin.Tests.Parser_Suite;
with Landin.Tests.Platform_Suite;
with Landin.Tests.Resolution_Suite;
with Landin.Tests.Source_Suite;
with Landin.Tests.Stages_Suite;
with Landin.Tests.Targets_Suite;
with Landin.Tests.Cortex_Suite;
with Landin.Tests.Toolchain_Suite;
with Landin.Tests.Verifier_Suite;
with Landin.Tests.X86_Optimization_Suite;

procedure Landin_Tests is

   package Unbounded renames Ada.Strings.Unbounded;
   package Text_IO renames Ada.Text_IO;

   Cases      : Landin.Testing.Registry;
   Transcript : Unbounded.Unbounded_String;
   Result     : Landin.Testing.Summary;

   type Requested_Mode is
     (Run_All, Run_Host, Record_Artefacts, Run_Suite, Run_Case,
      Run_Fixture, Misuse);

   Mode         : Requested_Mode := Run_All;
   Host_Only    : Boolean := False;
   Suite_Filter : Unbounded.Unbounded_String;
   Case_Filter  : Unbounded.Unbounded_String;
   Fixture      : Unbounded.Unbounded_String;

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
     ["array layout     ",
      "backend          ",
      "backend plans    ",
      "backend scale    ",
      "frontend review  ",
      "host reports     ",
      "catalogue        ",
      "checking         ",
      "debugging        ",
      "diagnostics      ",
      "driver           ",
      "fixture execution",
      "fixtures         ",
      "harness          ",
      "ir               ",
      "ir opt           ",
      "lexer            ",
      "lowering         ",
      "opt driver       ",
      "opt foundations  ",
      "parser           ",
      "platform         ",
      "resolution       ",
      "source           ",
      "stages           ",
      "targets          ",
      "cortex ABI       ",
      "toolchain        ",
      "verifier         ",
      "x86 opt          "];

   function Trimmed (Name : Suite_Name) return String;

   function Starts_With (Text, Prefix : String) return Boolean;

   procedure Read_Arguments;

   procedure Print_Usage;

   function Trimmed (Name : Suite_Name) return String is
      Last : Natural := Name'Last;
   begin
      while Last >= Name'First and then Name (Last) = ' ' loop
         Last := Last - 1;
      end loop;
      return Name (Name'First .. Last);
   end Trimmed;

   function Starts_With (Text, Prefix : String) return Boolean is
     (Text'Length >= Prefix'Length
      and then Text (Text'First .. Text'First + Prefix'Length - 1) = Prefix);

   procedure Print_Usage is
   begin
      Text_IO.Put_Line
        (Text_IO.Standard_Error,
         "usage: landin_tests [--record | --suite=NAME |"
         & " --case=SUITE/NAME | --fixture=CLASS/NAME]");
      Text_IO.Put_Line
        (Text_IO.Standard_Error,
         "       landin_tests --host [--suite=NAME | --case=SUITE/NAME]");
   end Print_Usage;

   procedure Read_Arguments is
      Selected : Positive := 1;
   begin
      if Ada.Command_Line.Argument_Count = 0 then
         return;
      elsif Ada.Command_Line.Argument_Count = 2 then
         if Ada.Command_Line.Argument (1) = "--host" then
            Selected := 2;
         elsif Ada.Command_Line.Argument (2) /= "--host" then
            Mode := Misuse;
            return;
         end if;
         Host_Only := True;
      elsif Ada.Command_Line.Argument_Count /= 1 then
         Mode := Misuse;
         return;
      end if;

      declare
         Argument : constant String := Ada.Command_Line.Argument (Selected);
      begin
         if Argument = "--record" then
            Mode := Record_Artefacts;
         elsif Argument = "--host" then
            Mode := Run_Host;
         elsif Starts_With (Argument, "--suite=")
           and then Argument'Length > 8
         then
            Mode := Run_Suite;
            Suite_Filter := Unbounded.To_Unbounded_String
              (Argument (Argument'First + 8 .. Argument'Last));
         elsif Starts_With (Argument, "--case=")
           and then Argument'Length > 7
         then
            declare
               Value : constant String :=
                 Argument (Argument'First + 7 .. Argument'Last);
               Slash : constant Natural :=
                 Ada.Strings.Fixed.Index (Value, "/");
            begin
               if Slash = 0
                 or else Slash = Value'First
                 or else Slash = Value'Last
               then
                  Mode := Misuse;
               else
                  Mode := Run_Case;
                  Suite_Filter := Unbounded.To_Unbounded_String
                    (Value (Value'First .. Slash - 1));
                  Case_Filter := Unbounded.To_Unbounded_String
                    (Value (Slash + 1 .. Value'Last));
               end if;
            end;
         elsif Starts_With (Argument, "--fixture=")
           and then Argument'Length > 10
         then
            Mode := Run_Fixture;
            Fixture := Unbounded.To_Unbounded_String
              (Argument (Argument'First + 10 .. Argument'Last));
         else
            Mode := Misuse;
         end if;
      end;
      if Host_Only and then Mode not in Run_Suite | Run_Case then
         Mode := Misuse;
      end if;
   end Read_Arguments;

begin
   Read_Arguments;

   if Mode = Misuse then
      Print_Usage;
      Ada.Command_Line.Set_Exit_Status (2);
      return;
   end if;

   --  Recording writes the artefact and runs no case, so a run that
   --  recorded can never be mistaken for a run that passed.  Chosen only
   --  by an argument a human typed: no environment variable, and nothing
   --  that rewrites a golden because it did not match.
   if Mode = Record_Artefacts then
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

            Landin.Tests.Targets_Suite.Record_Artefact
              ("../tests/layout.targets", Wrote);

            if Wrote then
               Text_IO.Put_Line ("wrote compiler/tests/layout.targets");
            else
               Text_IO.Put_Line
                 (Text_IO.Standard_Error,
                  "could not write ../tests/layout.targets");
               Ada.Command_Line.Set_Exit_Status (1);
            end if;
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

   if Mode = Run_Fixture then
      Landin.Tests.Fixture_Execution_Suite.Select_Fixture
        (Unbounded.To_String (Fixture));
   end if;

   Landin.Tests.Array_Layout_Suite.Register (Cases);
   Landin.Tests.IR_Optimization_Suite.Register (Cases);
   Landin.Tests.Backend_Plans_Suite.Register (Cases);
   Landin.Tests.Backend_Scale_Suite.Register (Cases);
   Landin.Tests.Frontend_Review_Suite.Register (Cases);
   Landin.Tests.Host_Reports_Suite.Register (Cases);
   Landin.Tests.Backend_Suite.Register (Cases);
   Landin.Tests.Catalogue_Suite.Register (Cases);
   Landin.Tests.Checking_Suite.Register (Cases);
   Landin.Tests.Debugging_Suite.Register (Cases);
   Landin.Tests.Diagnostics_Suite.Register (Cases);
   Landin.Tests.Driver_Suite.Register (Cases);
   Landin.Tests.Fixture_Execution_Suite.Register
     (Cases, Include_Target_Workloads => Mode /= Run_Host and not Host_Only);
   Landin.Tests.Fixture_Suite.Register (Cases);
   Landin.Tests.Harness_Suite.Register (Cases);
   Landin.Tests.IR_Suite.Register (Cases);
   Landin.Tests.Lexer_Suite.Register (Cases);
   Landin.Tests.Lowering_Suite.Register (Cases);
   Landin.Tests.Optimization_Driver_Suite.Register (Cases);
   Landin.Tests.Optimization_Foundations_Suite.Register (Cases);
   Landin.Tests.Parser_Suite.Register (Cases);
   Landin.Tests.Platform_Suite.Register (Cases);
   Landin.Tests.Resolution_Suite.Register (Cases);
   Landin.Tests.Source_Suite.Register (Cases);
   Landin.Tests.Stages_Suite.Register (Cases);
   Landin.Tests.Targets_Suite.Register (Cases);
   Landin.Tests.Cortex_Suite.Register (Cases);
   Landin.Tests.Toolchain_Suite.Register (Cases);
   Landin.Tests.Verifier_Suite.Register (Cases);
   Landin.Tests.X86_Optimization_Suite.Register (Cases);

   for Suite of Expected_Suites loop
      if not Landin.Testing.Has_Suite (Cases, Trimmed (Suite)) then
         raise Landin.Compiler_Defect
           with "test suite is not registered: " & Trimmed (Suite);
      end if;
   end loop;

   if Landin.Testing.Suite_Count (Cases) /= Expected_Suites'Length then
      raise Landin.Compiler_Defect
        with "a registered suite is absent from the expected inventory";
   end if;

   case Mode is
      when Run_All | Run_Host =>
         Landin.Testing.Run (Cases, Transcript, Result);
      when Run_Suite =>
         Landin.Testing.Run
           (Cases, Unbounded.To_String (Suite_Filter), "",
            Transcript, Result);
      when Run_Case =>
         Landin.Testing.Run
           (Cases,
            Unbounded.To_String (Suite_Filter),
            Unbounded.To_String (Case_Filter),
            Transcript, Result);
      when Run_Fixture =>
         Landin.Testing.Run
           (Cases, "fixture execution", "selected fixture executes",
            Transcript, Result);
      when Record_Artefacts | Misuse =>
         raise Landin.Compiler_Defect with "test mode reached the runner";
   end case;

   if Mode = Run_Host or else Host_Only then
      Text_IO.Put_Line
        ("HOST-ONLY compiler checks; target workload"
         & " emission/execution excluded");
      Text_IO.New_Line;
   end if;
   Text_IO.Put (Unbounded.To_String (Transcript));

   --  Where the run went, on standard error, when asked.  Not in the
   --  transcript: that is parsed, and is the one thing promised to be the
   --  same on every host, which a duration can never be.  A suite that
   --  costs forty minutes should be able to say so rather than be guessed
   --  at from the outside, which is how the last three measurements were
   --  taken.
   if Ada.Environment_Variables.Exists ("LANDIN_TEST_TIMINGS") then
      declare
         use type Unbounded.Unbounded_String;
         Measured : constant Landin.Testing.Timing_Vectors.Vector :=
           Landin.Testing.Last_Timings;

         type Row is record
            Suite   : Unbounded.Unbounded_String;
            Seconds : Duration := 0.0;
            Cases   : Natural := 0;
         end record;

         type Row_Array is array (Positive range <>) of Row;

         function Slower (Left, Right : Row) return Boolean is
           (Left.Seconds > Right.Seconds);

         procedure Sort_Rows is new Ada.Containers.Generic_Array_Sort
           (Index_Type => Positive, Element_Type => Row,
            Array_Type => Row_Array, "<" => Slower);

         Suites : Row_Array (1 .. Natural (Measured.Length));
         Last   : Natural := 0;
         Total  : Duration := 0.0;
      begin
         for Measurement of Measured loop
            Total := Total + Measurement.Seconds;

            declare
               Known : Natural := 0;
            begin
               for Index in 1 .. Last loop
                  if Suites (Index).Suite = Measurement.Suite then
                     Known := Index;
                  end if;
               end loop;

               if Known = 0 then
                  Last := Last + 1;
                  Suites (Last) := (Measurement.Suite,
                                    Measurement.Seconds, 1);
               else
                  Suites (Known).Seconds :=
                    Suites (Known).Seconds + Measurement.Seconds;
                  Suites (Known).Cases := Suites (Known).Cases + 1;
               end if;
            end;
         end loop;

         Sort_Rows (Suites (1 .. Last));

         Text_IO.New_Line (Text_IO.Standard_Error);
         Text_IO.Put_Line
           (Text_IO.Standard_Error,
            "timings: " & Duration'Image (Total) & "s over"
            & Natural'Image (Natural (Measured.Length)) & " cases");
         Text_IO.Put_Line
           (Text_IO.Standard_Error, "  seconds  share  cases  suite");

         for Index in 1 .. Last loop
            declare
               Share : constant Natural :=
                 (if Total > 0.0
                  then Natural (Float'Floor
                        (Float (Suites (Index).Seconds) * 100.0
                         / Float (Total)))
                  else 0);
            begin
               Text_IO.Put_Line
                 (Text_IO.Standard_Error,
                  Duration'Image (Suites (Index).Seconds)
                  & "  " & Natural'Image (Share) & "%"
                  & Natural'Image (Suites (Index).Cases) & "  "
                  & Unbounded.To_String (Suites (Index).Suite));
            end;
         end loop;

         --  The slowest cases by name, because one case inside a suite is
         --  usually the whole of it.
         Text_IO.New_Line (Text_IO.Standard_Error);
         Text_IO.Put_Line (Text_IO.Standard_Error, "  slowest cases:");

         declare
            Cases : Row_Array (1 .. Natural (Measured.Length));
            Count : Natural := 0;
         begin
            for Measurement of Measured loop
               Count := Count + 1;
               Cases (Count) :=
                 (Measurement.Suite
                    & Unbounded.To_Unbounded_String (" / ")
                    & Measurement.Name,
                  Measurement.Seconds, 1);
            end loop;

            Sort_Rows (Cases (1 .. Count));

            for Index in 1 .. Natural'Min (12, Count) loop
               Text_IO.Put_Line
                 (Text_IO.Standard_Error,
                  Duration'Image (Cases (Index).Seconds) & "  "
                  & Unbounded.To_String (Cases (Index).Suite));
            end loop;
         end;
      end;
   end if;

   if Result.Failed > 0 or else Result.Cases = 0 then
      if Result.Cases = 0 then
         Text_IO.Put_Line
           (Text_IO.Standard_Error, "landin_tests: no test case matched");
      end if;
      Ada.Command_Line.Set_Exit_Status (1);
   end if;
end Landin_Tests;
