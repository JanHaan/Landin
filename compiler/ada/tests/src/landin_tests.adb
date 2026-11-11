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

with Landin.Platform;
with Landin.Testing;
with Landin.Testing.Lanes;
with Landin.Tests.Arm64_Selection_Suite;
with Landin.Tests.Array_Layout_Suite;
with Landin.Tests.IR_Inlining_Suite;
with Landin.Tests.IR_Optimization_Suite;
with Landin.Tests.Backend_Plans_Suite;
with Landin.Tests.Backend_Scale_Suite;
with Landin.Tests.Frontend_Review_Suite;
with Landin.Tests.Host_Reports_Suite;
with Landin.Tests.Backend_Suite;
with Landin.Tests.Catalogue_Suite;
with Landin.Tests.Checking_Suite;
with Landin.Tests.Debugging_Suite;
with Landin.Tests.Bindings_Suite;
with Landin.Tests.Devices_Suite;
with Landin.Tests.Diagnostics_Suite;
with Landin.Tests.Driver_Suite;
with Landin.Tests.Commands_Suite;
with Landin.Tests.Fixture_Execution_Suite;
with Landin.Tests.Fixture_Suite;
with Landin.Tests.Fixes_Suite;
with Landin.Tests.Formatting_Suite;
with Landin.Tests.Harness_Suite;
with Landin.Tests.IR_Suite;
with Landin.Tests.Json_Suite;
with Landin.Tests.Lexer_Suite;
with Landin.Tests.Lowering_Suite;
with Landin.Tests.Memory_Suite;
with Landin.Tests.Mutation_Suite;
with Landin.Tests.Newcomer_Suite;
with Landin.Tests.Optimization_Driver_Suite;
with Landin.Tests.Optimization_Foundations_Suite;
with Landin.Tests.Parser_Suite;
with Landin.Tests.Platform_Suite;
with Landin.Tests.Resolution_Suite;
with Landin.Tests.Server_Suite;
with Landin.Tests.Source_Suite;
with Landin.Tests.Stack_Report_Suite;
with Landin.Tests.Stages_Suite;
with Landin.Tests.Targets_Suite;
with Landin.Tests.Cortex_Suite;
with Landin.Tests.RV32_Firmware_Suite;
with Landin.Tests.Xtensa_Backend_Suite;
with Landin.Tests.Toolchain_Suite;
with Landin.Tests.Verifier_Suite;
with Landin.Tests.X86_Optimization_Suite;
with Landin.Tests.Xml_Suite;

procedure Landin_Tests is

   package Unbounded renames Ada.Strings.Unbounded;
   package Text_IO renames Ada.Text_IO;

   Cases      : Landin.Testing.Registry;
   Transcript : Unbounded.Unbounded_String;
   Result     : Landin.Testing.Summary;

   type Requested_Mode is
     (Run_All, Run_Host, Record_Artefacts, Run_Suite, Run_Case,
      Run_Fixture, List_Cases, Misuse);

   Mode         : Requested_Mode := Run_All;
   Host_Only    : Boolean := False;
   --  Every --suite and --case of a focused run, in the order given.
   Selected     : Landin.Testing.Selector_Vectors.Vector;
   --  Every --fixture, in the order given.
   Fixtures     : Landin.Platform.Path_List;
   --  What each --record=WHAT names, in the order given, an empty one for
   --  a bare --record and so every recorded artefact.
   Recordings   : Landin.Platform.Path_List;
   --  Every --fixture-code and --record-code, in the order given: each
   --  becomes the --fixture or --record of every recorded fixture whose
   --  report carries the code, once the fixture tree is known to be here.
   Fixture_Codes, Record_Codes : Landin.Platform.Path_List;
   --  The suite each --cases=SUITE names, in the order given, an empty
   --  one for a bare --cases and so every suite.
   Listing      : Landin.Platform.Path_List;
   Of_Shard    : Landin.Testing.Shard := Landin.Testing.Whole;
   --  A fixture run's FILTERED line for each fixture, and the note of each
   --  another lane runs, around the transcript.
   Fixture_Lines, Fixture_Notes : Unbounded.Unbounded_String;

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
     ["arm64 selection  ",
      "array layout     ",
      "backend          ",
      "backend plans    ",
      "backend scale    ",
      "frontend review  ",
      "host reports     ",
      "catalogue        ",
      "checking         ",
      "debugging        ",
      "bindings         ",
      "devices          ",
      "diagnostics      ",
      "driver           ",
      "commands         ",
      "fixture execution",
      "fixtures         ",
      "fixes            ",
      "formatting       ",
      "harness          ",
      "ir               ",
      "ir opt           ",
      "json             ",
      "lexer            ",
      "lowering         ",
      "memory           ",
      "mutation         ",
      "opt driver       ",
      "opt foundations  ",
      "parser           ",
      "platform         ",
      "resolution       ",
      "server           ",
      "source           ",
      "stack report     ",
      "stages           ",
      "targets          ",
      "cortex ABI       ",
      "rv32 firmware    ",
      "xtensa backend   ",
      "toolchain        ",
      "verifier         ",
      "x86 opt          ",
      "xml              "];

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
         "usage: landin_tests [--record | --fixture=CLASS/NAME"
         & " ... --suite=NAME ... --case=SUITE/NAME ...]");
      Text_IO.Put_Line
        (Text_IO.Standard_Error,
         "       landin_tests --record=lowering | --record=layout |"
         & " --record=server/NAME | --record=CLASS/NAME ...");
      Text_IO.Put_Line
        (Text_IO.Standard_Error,
         "       landin_tests --host"
         & " [--suite=NAME ... --case=SUITE/NAME ...]");
      Text_IO.Put_Line
        (Text_IO.Standard_Error,
         "       --suite, --case and --fixture repeat, and one run runs"
         & " every case any of them names");
      Text_IO.Put_Line
        (Text_IO.Standard_Error,
         "       and --record=WHAT repeats, recording each in turn");
      Text_IO.Put_Line
        (Text_IO.Standard_Error,
         "       landin_tests [--host] --cases=SUITE ... | --cases");
      Text_IO.Put_Line
        (Text_IO.Standard_Error,
         "       --cases=SUITE lists that suite's cases and runs none, one"
         & " SUITE/NAME to a line as");
      Text_IO.Put_Line
        (Text_IO.Standard_Error,
         "       --case= takes it; --cases alone lists every suite's");
      Text_IO.Put_Line
        (Text_IO.Standard_Error,
         "       --fixture-code=LNNNN is --fixture, and --record-code=LNNNN"
         & " --record, for every recorded");
      Text_IO.Put_Line
        (Text_IO.Standard_Error,
         "       fixture whose expect file carries that diagnostic code:"
         & " the reports a change to its");
      Text_IO.Put_Line
        (Text_IO.Standard_Error,
         "       text changes");
      Text_IO.Put_Line
        (Text_IO.Standard_Error,
         "       and any of --target=NAME --runner=PROGRAM"
         & " --toolchain=DRIVER");
      Text_IO.Put_Line
        (Text_IO.Standard_Error,
         "       and, with no selection or --host alone, --shard=I/N");
   end Print_Usage;

   --  The lane's own options may accompany any selection, each once; what
   --  is left is the selection, read as before.
   procedure Read_Arguments is
      Rest : array (1 .. 2) of Natural := [0, 0];
      Kept : Natural := 0;
      Seen_Target, Seen_Runner, Seen_Toolchain : Boolean := False;
      Seen_Shard : Boolean := False;
      Selecting : Boolean := False;

      function Value (Argument, Prefix : String) return String
        is (Argument (Argument'First + Prefix'Length .. Argument'Last));

      --  I/N with 1 <= I <= N <= 64, both written as plain decimals.
      function Read_Shard (Text : String) return Boolean;

      function Read_Shard (Text : String) return Boolean is
         Slash : constant Natural := Ada.Strings.Fixed.Index (Text, "/");

         function Number (Digits_Of : String) return Natural is
           (if Digits_Of'Length in 1 .. 2
              and then (for all C of Digits_Of => C in '0' .. '9')
            then Natural'Value (Digits_Of) else 0);
      begin
         if Slash = 0 then
            return False;
         end if;

         declare
            Index : constant Natural :=
              Number (Text (Text'First .. Slash - 1));
            Count : constant Natural := Number (Text (Slash + 1 .. Text'Last));
         begin
            if Index = 0 or else Count = 0 or else Count > 64
              or else Index > Count
            then
               return False;
            end if;
            Of_Shard := (Index => Index, Count => Count);
            return True;
         end;
      end Read_Shard;
   begin
      for Index in 1 .. Ada.Command_Line.Argument_Count loop
         declare
            Argument : constant String := Ada.Command_Line.Argument (Index);
         begin
            if Starts_With (Argument, "--target=") then
               if Seen_Target
                 or else not Landin.Testing.Lanes.Select_Target
                   (Value (Argument, "--target="))
               then
                  Mode := Misuse;
                  return;
               end if;
               Seen_Target := True;
            elsif Starts_With (Argument, "--runner=")
              and then Argument'Length > 9
            then
               if Seen_Runner then
                  Mode := Misuse;
                  return;
               end if;
               Landin.Testing.Lanes.Select_Runner
                 (Value (Argument, "--runner="));
               Seen_Runner := True;
            elsif Starts_With (Argument, "--toolchain=")
              and then Argument'Length > 12
            then
               if Seen_Toolchain then
                  Mode := Misuse;
                  return;
               end if;
               Landin.Testing.Lanes.Select_Toolchain
                 (Value (Argument, "--toolchain="));
               Seen_Toolchain := True;
            elsif Starts_With (Argument, "--shard=") then
               if Seen_Shard
                 or else not Read_Shard (Value (Argument, "--shard="))
               then
                  Mode := Misuse;
                  return;
               end if;
               Seen_Shard := True;
            elsif Starts_With (Argument, "--suite=")
              and then Argument'Length > 8
            then
               Selecting := True;
               Selected.Append
                 (Landin.Testing.Selector'
                   (Suite => Unbounded.To_Unbounded_String
                     (Value (Argument, "--suite=")),
                   Name  => Unbounded.Null_Unbounded_String));
            elsif Starts_With (Argument, "--fixture=")
              and then Argument'Length > 10
            then
               Selecting := True;
               Fixtures.Append (Value (Argument, "--fixture="));
            elsif Starts_With (Argument, "--fixture-code=")
              and then Argument'Length > 15
            then
               Selecting := True;
               Fixture_Codes.Append (Value (Argument, "--fixture-code="));
            elsif Starts_With (Argument, "--record-code=")
              and then Argument'Length > 14
            then
               Record_Codes.Append (Value (Argument, "--record-code="));
            elsif Argument = "--record" then
               Recordings.Append ("");
            elsif Starts_With (Argument, "--record=")
              and then Argument'Length > 9
            then
               Recordings.Append (Value (Argument, "--record="));
            elsif Argument = "--cases" then
               Listing.Append ("");
            elsif Starts_With (Argument, "--cases=")
              and then Argument'Length > 8
            then
               Listing.Append (Value (Argument, "--cases="));
            elsif Starts_With (Argument, "--case=")
              and then Argument'Length > 7
            then
               declare
                  Named : constant String := Value (Argument, "--case=");
                  Slash : constant Natural :=
                    Ada.Strings.Fixed.Index (Named, "/");
               begin
                  Selecting := True;
                  if Slash = 0
                    or else Slash = Named'First
                    or else Slash = Named'Last
                  then
                     --  Refused once the cases are registered, with the
                     --  names nearest it (Landin.Testing.Selection_Problem).
                     Selected.Append
                       (Landin.Testing.Selector'
                          (Suite => Unbounded.Null_Unbounded_String,
                           Name  => Unbounded.To_Unbounded_String (Named)));
                     goto Next;
                  end if;
                  Selected.Append
                    (Landin.Testing.Selector'
                      (Suite => Unbounded.To_Unbounded_String
                        (Named (Named'First .. Slash - 1)),
                      Name  => Unbounded.To_Unbounded_String
                        (Named (Slash + 1 .. Named'Last))));
               end;
            elsif Kept = Rest'Last then
               Mode := Misuse;
               return;
            else
               Kept := Kept + 1;
               Rest (Kept) := Index;
            end if;
         end;
         <<Next>>
      end loop;

      if not Landin.Testing.Lanes.Has_Target then
         Text_IO.Put_Line
           (Text_IO.Standard_Error,
            "landin_tests: no target describes this host; name --target=");
         Mode := Misuse;
         return;
      end if;

      --  Listing runs nothing, so it takes no selection and records
      --  nothing.  --host may accompany it, since the host scope registers
      --  other cases of `fixture execution` than a target run does.
      if not Listing.Is_Empty then
         if Selecting or else Seen_Shard or else Kept > 1
           or else not Recordings.Is_Empty or else not Record_Codes.Is_Empty
           or else (Kept = 1
                    and then Ada.Command_Line.Argument (Rest (1)) /= "--host")
         then
            Mode := Misuse;
         else
            Host_Only := Kept = 1;
            Mode := List_Cases;
         end if;
         return;
      end if;

      --  Recording writes and runs nothing else, so it takes no selection.
      if not Recordings.Is_Empty or else not Record_Codes.Is_Empty then
         Mode :=
           (if Selecting or else Kept > 0 or else Seen_Shard then Misuse
            else Record_Artefacts);
         return;
      end if;

      if Selecting then
         --  Suites, cases and fixtures select alone, or suites and cases
         --  with --host and nothing else, since a fixture is a target
         --  workload; a shard is a share of the complete run.
         if Kept > 1 or else Seen_Shard
           or else (Kept = 1
                    and then (Ada.Command_Line.Argument (Rest (1)) /= "--host"
                              or else not Fixtures.Is_Empty
                              or else not Fixture_Codes.Is_Empty))
         then
            Mode := Misuse;
            return;
         end if;
         Host_Only := Kept = 1;
         Mode := (if not Fixtures.Is_Empty or else not Fixture_Codes.Is_Empty
                  then Run_Fixture
                  elsif Unbounded.Length (Selected.Last_Element.Name) = 0
                    and then Natural (Selected.Length) = 1
                  then Run_Suite else Run_Case);
         return;
      end if;

      if Kept = 0 then
         return;
      elsif Kept = 1 and then Ada.Command_Line.Argument (Rest (1)) = "--host"
      then
         Mode := Run_Host;
      else
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

   --  A code names the fixtures whose recorded reports carry it.  Read
   --  from the fixture tree, so only where it is; elsewhere the refusals
   --  below say where to run from.
   if Ada.Directories.Exists (Marker) then
      declare
         procedure Expand
           (Codes : Landin.Platform.Path_List;
            Into  : in out Landin.Platform.Path_List;
            Ok    : in out Boolean);

         procedure Expand
           (Codes : Landin.Platform.Path_List;
            Into  : in out Landin.Platform.Path_List;
            Ok    : in out Boolean) is
         begin
            for Code of Codes loop
               declare
                  Paths   : Landin.Platform.Path_List;
                  Problem : Unbounded.Unbounded_String;
               begin
                  Landin.Tests.Fixture_Execution_Suite.Fixtures_Reporting
                    (Code, Paths, Problem);
                  if Unbounded.Length (Problem) /= 0 then
                     Text_IO.Put_Line
                       (Text_IO.Standard_Error,
                        "landin_tests: " & Unbounded.To_String (Problem));
                     Ok := False;
                  end if;
                  for Path of Paths loop
                     if not Into.Contains (Path) then
                        Into.Append (Path);
                     end if;
                  end loop;
               end;
            end loop;
         end Expand;

         Ok : Boolean := True;
      begin
         Expand (Fixture_Codes, Fixtures, Ok);
         Expand (Record_Codes, Recordings, Ok);
         if not Ok then
            Ada.Command_Line.Set_Exit_Status (2);
            return;
         end if;
      end;
   end if;

   --  Recording writes the artefact and runs no case, so a run that
   --  recorded can never be mistaken for a run that passed.  Chosen only
   --  by an argument a human typed: no environment variable, and nothing
   --  that rewrites a golden because it did not match.
   if Mode = Record_Artefacts then
      if not Ada.Directories.Exists (Marker) then
         Text_IO.Put_Line
           (Text_IO.Standard_Error,
            "landin_tests --record must be run from compiler/ada");
         Ada.Command_Line.Set_Exit_Status (2);
         return;
      end if;

      for What of Recordings loop
         declare
            Wrote : Boolean := True;

            procedure Wrote_Or_Not (Done : Boolean; Name : String);

            procedure Wrote_Or_Not (Done : Boolean; Name : String) is
            begin
               if Done then
                  Text_IO.Put_Line ("wrote " & Name);
               else
                  Text_IO.Put_Line
                    (Text_IO.Standard_Error, "could not write " & Name);
                  Wrote := False;
               end if;
            end Wrote_Or_Not;
         begin
            --  Each artefact on its own, so re-recording one never
            --  rewrites the others; with nothing named, all three as
            --  before.  A failure is the run's, and the rest still record.
            if What = "" or else What = "lowering" then
               Landin.Tests.Lowering_Suite.Record_Artefact
                 ("../tests/lowering.ir", Wrote);
               Wrote_Or_Not (Wrote, "compiler/tests/lowering.ir");
            end if;
            if Wrote and then (What = "" or else What = "layout") then
               Landin.Tests.Targets_Suite.Record_Artefact
                 ("../tests/layout.targets", Wrote);
               Wrote_Or_Not (Wrote, "compiler/tests/layout.targets");
            end if;
            if Wrote and then What = "" then
               declare
                  Said : Unbounded.Unbounded_String;
               begin
                  Landin.Tests.Server_Suite.Record_Sessions (Wrote, Said);
                  if Wrote then
                     Text_IO.Put_Line ("wrote compiler/tests/server");
                  else
                     Text_IO.Put_Line
                       (Text_IO.Standard_Error, Unbounded.To_String (Said));
                  end if;
               end;
            elsif Starts_With (What, "server/") then
               declare
                  Name  : constant String :=
                    What (What'First + 7 .. What'Last);
                  Found : Boolean;
                  Said  : Unbounded.Unbounded_String;
               begin
                  Landin.Tests.Server_Suite.Record_Session
                    (Name, Found, Wrote, Said);
                  if Found and then Wrote then
                     Text_IO.Put_Line
                       ("wrote compiler/tests/server/" & Name
                        & "/session.lsp");
                  elsif Found then
                     Text_IO.Put_Line
                       (Text_IO.Standard_Error, Unbounded.To_String (Said));
                  else
                     Text_IO.Put_Line
                       (Text_IO.Standard_Error,
                        "landin_tests: no session compiler/tests/server/"
                        & Name & "/session.lsp to record");
                     Wrote := False;
                  end if;
               end;
            elsif What /= "" and then What /= "lowering"
              and then What /= "layout"
            then
               declare
                  Said : Unbounded.Unbounded_String;
               begin
                  Landin.Tests.Fixture_Execution_Suite.Record_Report
                    (What, Wrote, Said);
                  if Wrote then
                     Text_IO.Put_Line (Unbounded.To_String (Said));
                  else
                     Text_IO.Put_Line
                       (Text_IO.Standard_Error, Unbounded.To_String (Said));
                  end if;
               end;
            end if;
            if not Wrote then
               Ada.Command_Line.Set_Exit_Status (1);
            end if;
         end;
      end loop;

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

   --  Each fixture another lane runs is not a failure here: say where it
   --  runs and run it not, which a FILTERED run already says is not the
   --  complete suite.  The fixtures this lane runs are one case, run with
   --  whatever --suite and --case also select.
   if Mode = Run_Fixture then
      declare
         Applicable : Landin.Platform.Path_List;
      begin
         for Path of Fixtures loop
            Unbounded.Append (Fixture_Lines, "FILTERED fixture=" & Path
                              & ASCII.LF);
            declare
               Note : constant String :=
                 Landin.Tests.Fixture_Execution_Suite.Lane_Note (Path);
            begin
               if Note = "" then
                  Applicable.Append (Path);
               else
                  Unbounded.Append (Fixture_Notes, ASCII.LF & Note);
               end if;
            end;
         end loop;
         if Applicable.Is_Empty and then Selected.Is_Empty then
            Text_IO.Put (Unbounded.To_String (Fixture_Lines)
                         & Unbounded.To_String (Fixture_Notes));
            return;
         end if;
         if not Applicable.Is_Empty then
            Landin.Tests.Fixture_Execution_Suite.Select_Fixtures (Applicable);
            Selected.Append
              (Landin.Testing.Selector'
                 (Suite => Unbounded.To_Unbounded_String
                    ("fixture execution"),
                  Name  => Unbounded.To_Unbounded_String
                    ("selected fixtures execute")));
         end if;
      end;
   end if;

   Landin.Tests.Arm64_Selection_Suite.Register (Cases);
   Landin.Tests.Array_Layout_Suite.Register (Cases);
   Landin.Tests.IR_Inlining_Suite.Register (Cases);
   Landin.Tests.IR_Optimization_Suite.Register (Cases);
   Landin.Tests.Backend_Plans_Suite.Register (Cases);
   Landin.Tests.Backend_Scale_Suite.Register (Cases);
   Landin.Tests.Frontend_Review_Suite.Register (Cases);
   Landin.Tests.Host_Reports_Suite.Register (Cases);
   Landin.Tests.Backend_Suite.Register (Cases);
   Landin.Tests.Catalogue_Suite.Register (Cases);
   Landin.Tests.Checking_Suite.Register (Cases);
   Landin.Tests.Debugging_Suite.Register (Cases);
   Landin.Tests.Devices_Suite.Register (Cases);
   Landin.Tests.Bindings_Suite.Register (Cases);
   Landin.Tests.Diagnostics_Suite.Register (Cases);
   Landin.Tests.Driver_Suite.Register (Cases);
   Landin.Tests.Newcomer_Suite.Register (Cases);
   Landin.Tests.Commands_Suite.Register (Cases);
   Landin.Tests.Fixture_Execution_Suite.Register
     (Cases, Include_Target_Workloads => Mode /= Run_Host and not Host_Only);
   Landin.Tests.Fixture_Suite.Register (Cases);
   Landin.Tests.Formatting_Suite.Register (Cases);
   Landin.Tests.Fixes_Suite.Register (Cases);
   Landin.Tests.Harness_Suite.Register (Cases);
   Landin.Tests.IR_Suite.Register (Cases);
   Landin.Tests.Json_Suite.Register (Cases);
   Landin.Tests.Lexer_Suite.Register (Cases);
   Landin.Tests.Lowering_Suite.Register (Cases);
   Landin.Tests.Memory_Suite.Register (Cases);
   Landin.Tests.Mutation_Suite.Register (Cases);
   Landin.Tests.Optimization_Driver_Suite.Register (Cases);
   Landin.Tests.Optimization_Foundations_Suite.Register (Cases);
   Landin.Tests.Parser_Suite.Register (Cases);
   Landin.Tests.Platform_Suite.Register (Cases);
   Landin.Tests.Resolution_Suite.Register (Cases);
   Landin.Tests.Server_Suite.Register (Cases);
   Landin.Tests.Source_Suite.Register (Cases);
   Landin.Tests.Stack_Report_Suite.Register (Cases);
   Landin.Tests.Stages_Suite.Register (Cases);
   Landin.Tests.Targets_Suite.Register (Cases);
   Landin.Tests.Cortex_Suite.Register (Cases);
   Landin.Tests.RV32_Firmware_Suite.Register (Cases);
   Landin.Tests.Xtensa_Backend_Suite.Register (Cases);
   Landin.Tests.Toolchain_Suite.Register (Cases);
   Landin.Tests.Verifier_Suite.Register (Cases);
   Landin.Tests.X86_Optimization_Suite.Register (Cases);
   Landin.Tests.Xml_Suite.Register (Cases);

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

   --  The cases as `--case=` takes them, from the registry itself, so a
   --  case is named without reading its suite's source.  A suite that is
   --  not one is refused with the names nearest it, as a selector is.
   if Mode = List_Cases then
      declare
         Refused : Boolean := False;
      begin
         for Suite of Listing loop
            if Suite /= ""
              and then not Landin.Testing.Has_Suite (Cases, Suite)
            then
               Text_IO.Put_Line
                 (Text_IO.Standard_Error,
                  "landin_tests: "
                  & Landin.Testing.Selection_Problem
                      (Cases,
                       (Suite => Unbounded.To_Unbounded_String (Suite),
                        Name  => Unbounded.Null_Unbounded_String)));
               Refused := True;
            end if;
         end loop;
         if Refused then
            Ada.Command_Line.Set_Exit_Status (2);
            return;
         end if;
         for Suite of Listing loop
            declare
               List : constant String :=
                 Landin.Testing.Case_List (Cases, Suite);
            begin
               --  Put_Line ends the last line itself: Text_IO would add
               --  a blank one after a Put that ended in a line feed.
               if List /= "" then
                  Text_IO.Put_Line (List (List'First .. List'Last - 1));
               end if;
            end;
         end loop;
         return;
      end;
   end if;

   --  A selector that names nothing is refused before anything runs, with
   --  the names nearest it, rather than by a run that matched nothing.
   declare
      Refused : Boolean := False;
   begin
      for One of Selected loop
         declare
            Problem : constant String :=
              Landin.Testing.Selection_Problem (Cases, One);
         begin
            if Problem /= "" then
               Text_IO.Put_Line
                 (Text_IO.Standard_Error, "landin_tests: " & Problem);
               Refused := True;
            end if;
         end;
      end loop;
      if Refused then
         Ada.Command_Line.Set_Exit_Status (2);
         return;
      end if;
   end;

   case Mode is
      when Run_All | Run_Host =>
         Landin.Testing.Run
           (Cases, Of_Shard, Transcript, Result,
            Record_Timings =>
              Ada.Environment_Variables.Exists ("LANDIN_TEST_TIMINGS"),
            Progress       => Landin.Testing.Write_Progress'Access);
      when Run_Suite | Run_Case | Run_Fixture =>
         Landin.Testing.Run
           (Cases, Selected, Transcript, Result,
            Record_Timings =>
              Ada.Environment_Variables.Exists ("LANDIN_TEST_TIMINGS"),
            Progress       => Landin.Testing.Write_Progress'Access);
      when Record_Artefacts | List_Cases | Misuse =>
         raise Landin.Compiler_Defect with "test mode reached the runner";
   end case;

   if Mode = Run_Host or else Host_Only then
      Text_IO.Put_Line
        ("HOST-ONLY compiler checks; target workload"
         & " emission/execution excluded");
      Text_IO.New_Line;
   end if;
   --  A native run's transcript is what it always was, and a cross run's
   --  says it is one, so the two cannot be read as each other.
   if not Landin.Testing.Lanes.Is_Native then
      Text_IO.Put_Line ("LANE " & Landin.Testing.Lanes.Describe);
      Text_IO.New_Line;
   end if;
   Text_IO.Put (Unbounded.To_String (Fixture_Lines)
                & Unbounded.To_String (Transcript)
                & Unbounded.To_String (Fixture_Notes));

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
