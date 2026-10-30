with Ada.Strings;
--  Fixtures that are run, not merely parsed.
--
--  A recorded expectation nobody compares to anything is not a test, it is
--  a file that looks like one.  Every fixture carrying `expect` and `args`
--  is executed here through the real tool adapter, and its bytes and exit
--  status are compared with what it claims.

with Ada.Characters.Handling;
with Ada.Containers.Indefinite_Ordered_Sets;
with Ada.Containers.Vectors;
with Ada.Directories;
with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Environment_Variables;
with Ada.Text_IO;

with Landin.Backend.Toolchain;
with Landin.Json;
with Landin.Optimization;
with Landin.Platform;
with Landin.Platform.Native;
with Landin.Platform.Native.Tools;
with Landin.Targets;
with Landin.Targets.Capabilities;
with Landin.Targets.Levels;
with Landin.Testing.Fakes;
with Landin.Testing.Fixtures;
with Landin.Testing.Lanes;

--  This suite runs the real `refine` against the real fixture tree through
--  the real tool adapter.  That is the point of it: everything else in the
--  repository can be checked with fakes, and a recorded expectation cannot.

package body Landin.Tests.Fixture_Execution_Suite is

   package Unbounded renames Ada.Strings.Unbounded;
   package Environment renames Ada.Environment_Variables;

   use Landin.Testing.Fixtures;
   use type Landin.Platform.Read_Status;
   use type Landin.Platform.Remove_Status;
   use type Landin.Platform.Write_Status;
   use type Landin.Platform.Termination;
   use type Landin.Platform.Capture_Mode;
   use type Landin.Targets.Architecture;
   use type Landin.Targets.Capabilities.Backend_Kind;
   use type Landin.Targets.Capabilities.Hosted_System;

   Fixture_Root : constant String := "../tests/fixtures";
   Selected     : Unbounded.Unbounded_String;

   package Lanes renames Landin.Testing.Lanes;

   function In_Lane (Case_Item : Fixture) return Boolean
     is (Lanes.Applies (Landin.Testing.Fixtures.Targets (Case_Item)));

   --  A recorded fixture that names its own target is a verdict of that
   --  target's that no host changes, so every lane runs it; one that takes
   --  the default is its lane's.
   function Recorded_In_Lane (Case_Item : Fixture) return Boolean
     is (Ada.Strings.Fixed.Index (Args (Case_Item), "--target=") > 0
         or else In_Lane (Case_Item));

   function Recorded_Lane_Count (Found : Catalogue) return Natural;

   function Recorded_Lane_Count (Found : Catalogue) return Natural is
      Total : Natural := 0;
   begin
      for Index in 1 .. Count (Found) loop
         if Expect (Nth (Found, Index)) /= ""
           and then Recorded_In_Lane (Nth (Found, Index))
         then
            Total := Total + 1;
         end if;
      end loop;
      return Total;
   end Recorded_Lane_Count;

   --  A refine invocation for the lane: the target a cross run names, then
   --  the rest.  A fixture's own `args` that name a target keep it.
   function Lane_Arguments
     (Rest : Landin.Platform.Path_List) return Landin.Platform.Path_List;

   function Lane_Arguments
     (Rest : Landin.Platform.Path_List) return Landin.Platform.Path_List
   is
      Result : Landin.Platform.Path_List := Lanes.Target_Arguments;
   begin
      for Argument of Rest loop
         if Argument'Length > 9
           and then Argument (Argument'First .. Argument'First + 8)
                    = "--target="
         then
            return Rest;
         end if;
      end loop;
      for Argument of Rest loop
         Result.Append (Argument);
      end loop;
      return Result;
   end Lane_Arguments;

   --  A compiled program run on the lane: directly on the host's own, and
   --  through the named runner on any other.
   procedure Run_Program
     (Runner    : Landin.Platform.Tool_Runner'Class;
      Program   : String;
      Arguments : Landin.Platform.Path_List;
      Outcome   : out Landin.Platform.Tool_Result;
      Capture   : Landin.Platform.Capture_Mode);

   procedure Run_Program
     (Runner    : Landin.Platform.Tool_Runner'Class;
      Program   : String;
      Arguments : Landin.Platform.Path_List;
      Outcome   : out Landin.Platform.Tool_Result;
      Capture   : Landin.Platform.Capture_Mode)
   is
      Through : Landin.Platform.Path_List;
   begin
      if Lanes.Runner = "" then
         Runner.Run (Program, Arguments, Outcome, Capture);
      else
         Through.Append (Program);
         for Argument of Arguments loop
            Through.Append (Argument);
         end loop;
         Runner.Run (Lanes.Runner, Through, Outcome, Capture);
      end if;
   end Run_Program;

   procedure Select_Fixture (Path : String) is
   begin
      Selected := Unbounded.To_Unbounded_String (Path);
   end Select_Fixture;

   function Lane_Command (Label, Target : String) return String is
     (if Target = "linux-x86-64" then
         "./scripts/dev-test.sh --fixture=" & Label
         & " on a Linux x86-64 host"
      elsif Target = "linux-arm64" then
         "./scripts/dev-test.sh --target=linux-arm64 --runner=qemu-aarch64"
         & " --fixture=" & Label & ", or natively on a Linux arm64 host"
      elsif Target = "linux-rv64" then
         "QEMU_CPU=max,xtheadba=true ./scripts/dev-test.sh"
         & " --target=linux-rv64 --runner=qemu-riscv64 --fixture=" & Label
      elsif Target = "darwin-arm64" then
         "./scripts/dev-test.sh --fixture=" & Label & " on a Mac, or"
         & " compiler/tests/darwin/check.py --parity --case=" & Label
         & " --refine=REFINE --output=DIR"
         & " there; the gate's darwin jobs run both"
      elsif Target in "freebsd-x86-64" | "freebsd-arm64" then
         "compiler/tests/freebsd/check.py --arch="
         & (if Target = "freebsd-x86-64" then "amd64" else "arm64")
         & " --kind=runtime --case="
         & Label (Ada.Strings.Fixed.Index (Label, "/") + 1 .. Label'Last)
         & " --refine=REFINE --output=DIR, or the gate's freebsd-"
         & (if Target = "freebsd-x86-64" then "amd64" else "arm64")
         & " jobs (compiler/tests/freebsd/README.md)"
      elsif Target = "cortex-m0" then
         "environments/cortex-m/backend_corpus.py --case=" & Label
         & " --refine=REFINE --output=DIR, or the gate's cortex-m job"
      else
         "no lane runs it: " & Target & " is a layout model the targets"
         & " suite measures");

   function Lane_Note (Path : String) return String is
      Host  : Landin.Platform.Native.Native_Filesystem;
      Found : Catalogue;
   begin
      Discover (Found, Fixture_Root, Host, Only => Path);
      if Problem_Count (Found) /= 0 or else Count (Found) /= 1 then
         return "";
      end if;
      declare
         Case_Item : constant Fixture := Nth (Found, 1);
         Named : constant String :=
           Landin.Testing.Fixtures.Targets (Case_Item);
         Note  : Unbounded.Unbounded_String;
         First : Integer := Named'First;
      begin
         if Recorded_In_Lane (Case_Item) then
            return "";
         end if;
         Unbounded.Append
           (Note, "NOT APPLICABLE " & Path & ": it does not apply to this"
            & " run's target, " & Lanes.Target_Name & ", for its targets"
            & " are " & Named & "; run it on its own lane:" & ASCII.LF);
         for Index in Named'First .. Named'Last + 1 loop
            if Index > Named'Last or else Named (Index) = ',' then
               declare
                  One : constant String := Ada.Strings.Fixed.Trim
                    (Named (First .. Index - 1), Ada.Strings.Both);
               begin
                  if One /= "" then
                     Unbounded.Append
                       (Note, "  " & One & ": " & Lane_Command (Path, One)
                        & ASCII.LF);
                  end if;
               end;
               First := Index + 1;
            end if;
         end loop;
         return Unbounded.To_String (Note);
      end;
   end Lane_Note;

   --  How many fixtures may be in flight at once.  One unless a run asks
   --  for more, so the harness behaves exactly as it always has by default
   --  and a parallel run is something a caller opted into.  An unreadable
   --  or absurd value is one job rather than an error: this decides how
   --  fast the suite runs, never what it concludes.
   function Job_Count return Positive;

   function Job_Count return Positive is
      Name : constant String := "LANDIN_TEST_JOBS";
   begin
      if not Environment.Exists (Name) then
         return 1;
      end if;

      return Positive'Value (Environment.Value (Name));
   exception
      when others =>
         return 1;
   end Job_Count;

   --  Run a corpus-wide loop across workers, and read afterwards as though
   --  it had not been.
   --
   --  Two cases in this suite are eighty-one per cent of the whole test
   --  program's time and two per cent of its checks, because the work is
   --  spawning refine, the assembler, the linker and the produced program
   --  rather than anything computed here.  That work parallelises with
   --  cores instead of contending for them.
   --
   --  Each worker is given its own context, and the results are absorbed
   --  in WORK ORDER once every worker has finished.  So the transcript
   --  does not depend on which worker finished first, and one job runs the
   --  work in the order it was collected, which is the order it always
   --  ran in.  That is the property the equivalence check holds: the same
   --  transcript, whatever LANDIN_TEST_JOBS says.
   generic
      type Element is private;
      type Element_Array is array (Positive range <>) of Element;
      with procedure Perform
        (Piece : Element; Item : in out Landin.Testing.Context);
   procedure Across_Workers
     (Work : Element_Array; Item : in out Landin.Testing.Context);

   procedure Across_Workers
     (Work : Element_Array; Item : in out Landin.Testing.Context)
   is
      type Context_Array is
        array (Positive range <>) of Landin.Testing.Context;
      Results : Context_Array (Work'Range);
      --  A sharded run's share of the work; every slot otherwise.  The
      --  caller's counters come from the whole collection, so a shard
      --  still checks that nothing was left out of it.
      Owned   : array (Work'Range) of Boolean;
      Count   : Natural := 0;
   begin
      for Slot in Work'Range loop
         Owned (Slot) := Landin.Testing.In_Share (Slot - Work'First);
         if Owned (Slot) then
            Count := Count + 1;
         end if;
      end loop;

      if Count = 0 then
         return;
      end if;

      declare
         Jobs : constant Positive := Positive'Min (Job_Count, Count);

         protected Dispenser is
            procedure Next (Slot : out Natural);
         private
            Cursor : Natural := Work'First;
         end Dispenser;

         protected body Dispenser is
            procedure Next (Slot : out Natural) is
            begin
               while Cursor <= Work'Last and then not Owned (Cursor) loop
                  Cursor := Cursor + 1;
               end loop;

               if Cursor > Work'Last then
                  Slot := 0;
               else
                  Slot := Cursor;
                  Cursor := Cursor + 1;
               end if;
            end Next;
         end Dispenser;

         task type Worker;

         task body Worker is
            Slot : Natural;
         begin
            loop
               Dispenser.Next (Slot);
               exit when Slot = 0;

               --  A worker that dies takes its fixture's verdict with it
               --  and leaves a shorter transcript that still says pass.
               --  So the raise is recorded where the case would have
               --  recorded it, and the run stays red rather than smaller.
               begin
                  Perform (Work (Slot), Results (Slot));
               exception
                  when Error : others =>
                     Landin.Testing.Fail
                       (Results (Slot),
                        "raised "
                        & Ada.Exceptions.Exception_Name (Error));
               end;
            end loop;
         end Worker;

         Workers : array (1 .. Jobs) of Worker;
         pragma Unreferenced (Workers);
      begin
         --  Every worker is awaited at the end of this block.
         null;
      end;

      for Slot in Work'Range loop
         Landin.Testing.Absorb (Item, Results (Slot));
      end loop;
   end Across_Workers;

   --  Mirrors compiler/ada/landin_common.gpr, so a harness run from
   --  compiler/ada finds the executable the same build produced.
   function Refine_Path return String;

   function Refine_Path return String is
      Tag  : constant String :=
        (if Environment.Exists ("LANDIN_BUILD_TAG")
         then Environment.Value ("LANDIN_BUILD_TAG") else "local");
      Mode : constant String :=
        (if Environment.Exists ("LANDIN_BUILD_MODE")
         then Environment.Value ("LANDIN_BUILD_MODE") else "debug");
   begin
      if Environment.Exists ("LANDIN_REFINE") then
         return Environment.Value ("LANDIN_REFINE");
      end if;

      return "build/" & Tag & "/" & Mode & "/bin/refine";
   end Refine_Path;

   --  Where a runtime fixture's executable is built.  Beside `refine`
   --  itself, because that directory is already per-host, already
   --  disposable and already removed by scripts/clean.sh -- and because
   --  Landin.Platform has no way to create one, which is a gap worth
   --  leaving until something needs it for a reason better than this.
   function Output_Directory return String;

   function Output_Directory return String is
      Path : constant String := Refine_Path;
      Last : Natural := Path'Last;
   begin
      while Last >= Path'First and then Path (Last) /= '/' loop
         Last := Last - 1;
      end loop;

      return (if Last >= Path'First
              then Path (Path'First .. Last) else "");
   end Output_Directory;

   --  Arguments are whitespace-separated.  A fixture that needs an
   --  argument containing a space needs a richer format, and saying so is
   --  better than quietly splitting it.
   function Split (Text : String) return Landin.Platform.Path_List;

   function Split (Text : String) return Landin.Platform.Path_List is
      Result : Landin.Platform.Path_List;
      First  : Integer := Text'First;
   begin
      for Index in Text'Range loop
         if Text (Index) in ' ' | ASCII.HT | ASCII.LF | ASCII.VT
           | ASCII.FF | ASCII.CR
         then
            if Index > First then
               Result.Append (Text (First .. Index - 1));
            end if;
            First := Index + 1;
         end if;
      end loop;

      if First <= Text'Last then
         Result.Append (Text (First .. Text'Last));
      end if;

      return Result;
   end Split;

   --  What refine is run with for a fixture's report: its `args`, and for
   --  a rooted fixture the module arguments its `root` gives after them,
   --  so a rooted fixture's `args` name only options such as its target.
   function Invocation (Case_Item : Fixture) return Landin.Platform.Path_List;

   function Invocation (Case_Item : Fixture) return Landin.Platform.Path_List
     is (Source_Arguments (Case_Item, Fixture_Root));

   function Label_Of (Item : Fixture) return String is
     (Class_Directory (Class (Item)) & "/" & Name (Item));

   --  A watchdog stops a child with a signal, but that intervention is not
   --  the trap a fixture promised to produce.  Keep the verdict on the typed
   --  outcome rather than on the adapter's explanatory output.
   function Satisfies_Termination_Expectation
     (Ended : Landin.Platform.Termination;
      Traps : Boolean) return Boolean
   is
     (case Ended is
         when Landin.Platform.Exited    => not Traps,
         when Landin.Platform.Signaled  => Traps,
         when Landin.Platform.Timed_Out => False);

   --  D361: some line of Output is exactly Line.  The report names the
   --  file relative to its module's root, so where a lane put the fixture
   --  and how it spelled the path cannot change the line.
   function Reports_Trap (Output, Line : String) return Boolean;

   function Reports_Trap (Output, Line : String) return Boolean is
      First : Positive := Output'First;
   begin
      for Index in Output'Range loop
         if Output (Index) = ASCII.LF then
            declare
               Text : constant String := Output (First .. Index - 1);
            begin
               if Text = Line then
                  return True;
               end if;
            end;
            First := Index + 1;
         end if;
      end loop;
      return False;
   end Reports_Trap;

   procedure A_Timeout_Cannot_Satisfy_A_Trap
     (Item : in out Landin.Testing.Context);

   procedure A_Timeout_Cannot_Satisfy_A_Trap
     (Item : in out Landin.Testing.Context)
   is
      Runner      : Landin.Testing.Fakes.Fake_Tool_Runner;
      Overdue     : Landin.Platform.Tool_Result;
      Trap_Result : Landin.Platform.Tool_Result;
      Cleanup_Exit : Landin.Platform.Tool_Result;
   begin
      --  Deliberately identical text: the typed outcome, not stderr prose,
      --  must decide whether the fixture produced its promised trap.
      Runner.Add_Result
        (Exit_Code => 0,
         Output    => "same captured output",
         Ended     => Landin.Platform.Timed_Out);
      Runner.Add_Result
        (Exit_Code => 0,
         Output    => "same captured output",
         Ended     => Landin.Platform.Signaled);

      Runner.Run
        ("overdue", Landin.Platform.No_Arguments, Overdue,
         Landin.Platform.Merged);
      Runner.Run
        ("signaled", Landin.Platform.No_Arguments, Trap_Result,
         Landin.Platform.Merged);

      Landin.Testing.Check
        (Item, Overdue.Ended = Landin.Platform.Timed_Out,
         "the fake preserves a watchdog expiration");
      Landin.Testing.Check
        (Item,
         not Satisfies_Termination_Expectation
           (Overdue.Ended, Traps => True),
         "a watchdog expiration cannot satisfy a trap fixture");
      Landin.Testing.Check
        (Item, Trap_Result.Ended = Landin.Platform.Signaled,
         "the fake preserves signal termination");
      Landin.Testing.Check
        (Item,
         Satisfies_Termination_Expectation
           (Trap_Result.Ended, Traps => True),
         "signal termination can satisfy a trap fixture");

      --  The no-unwind fixtures call exit(99) if cleanup is reached.
      --  That ordinary exit must fail their trap oracle, even after a fault.
      Runner.Add_Result (Exit_Code => 99, Output => "");
      Runner.Run ("cleanup", Landin.Platform.No_Arguments, Cleanup_Exit);
      Landin.Testing.Check
        (Item, Cleanup_Exit.Ended = Landin.Platform.Exited
         and then Cleanup_Exit.Exit_Code = 99,
         "the fake retains the cleanup observer's ordinary exit");
      Landin.Testing.Check
        (Item, not Satisfies_Termination_Expectation
           (Cleanup_Exit.Ended, Traps => True),
         "cleanup reaching exit cannot satisfy a no-unwind trap fixture");
   end A_Timeout_Cannot_Satisfy_A_Trap;

   Error_Mark   : aliased constant String := "error[";
   Warning_Mark : aliased constant String := "warning[";
   Levels : constant array (1 .. 2) of access constant String :=
     [Error_Mark'Access, Warning_Mark'Access];

   function Codes_In (Text : String) return String;

   function Codes_In (Text : String) return String is
      Found : Unbounded.Unbounded_String;

      --  A diagnostic begins a line with its level and its code; a warning
      --  is pinned exactly as an error is, in the order the report has it.
      function Code_At (Start : Positive; Mark : String) return Boolean
        is (Start + Mark'Length + 5 <= Text'Last
            and then (Start = Text'First
                      or else Text (Start - 1) = ASCII.LF)
            and then Text (Start .. Start + Mark'Length - 1) = Mark
            and then Text (Start + Mark'Length + 5) = ']');
   begin
      for Start in Text'Range loop
         for Mark of Levels loop
            if Code_At (Start, Mark.all) then
               if Unbounded.Length (Found) > 0 then
                  Unbounded.Append (Found, ", ");
               end if;

               Unbounded.Append
                 (Found,
                  Text (Start + Mark'Length .. Start + Mark'Length + 4));
            end if;
         end loop;
      end loop;

      return Unbounded.To_String (Found);
   end Codes_In;

   procedure Check_Compiler_Outcome
     (Case_Item : Fixture;
      Outcome   : Landin.Platform.Tool_Result;
      Item      : in out Landin.Testing.Context);

   procedure Check_Compiler_Outcome
     (Case_Item : Fixture;
      Outcome   : Landin.Platform.Tool_Result;
      Item      : in out Landin.Testing.Context)
   is
      Label : constant String := Label_Of (Case_Item);
   begin
      Landin.Testing.Check
        (Item, Outcome.Ended = Landin.Platform.Exited,
         Label & ": refine returned a status");
      Landin.Testing.Check_Equal
        (Item, Outcome.Exit_Code, Status (Case_Item),
         Label & ": recorded exit status");
      if Class (Case_Item) = Negative_Program then
         Landin.Testing.Check_Equal
           (Item, Codes_In (Unbounded.To_String (Outcome.Output)),
            Normalized_Codes (Codes (Case_Item)),
            Label & ": the report carries its pinned codes");
      end if;
   end Check_Compiler_Outcome;

   --  An accepted program may warn, and each warning is pinned: its
   --  `codes:` says which, in order, and without the key it says none.  A
   --  warning nobody pinned is a change nobody saw.
   procedure Check_Accepted_Report
     (Case_Item : Fixture;
      Label     : String;
      Report    : String;
      Item      : in out Landin.Testing.Context);

   procedure Check_Accepted_Report
     (Case_Item : Fixture;
      Label     : String;
      Report    : String;
      Item      : in out Landin.Testing.Context) is
   begin
      Landin.Testing.Check_Equal
        (Item, Codes_In (Report), Normalized_Codes (Codes (Case_Item)),
         Label & ": an accepted program reports what it pins");
   end Check_Accepted_Report;

   --  All recorded and compiled-program oracles use the same capture
   --  selection and stderr obligation. The runner seam permits fake checks.
   --  Compiled is a program refine built, which a cross lane runs through
   --  its runner; refine itself always runs on the host.
   procedure Run_With_Stream
     (Case_Item : Fixture;
      Label : String;
      Runner : Landin.Platform.Tool_Runner'Class;
      Program : String;
      Arguments : Landin.Platform.Path_List;
      Outcome : out Landin.Platform.Tool_Result;
      Item : in out Landin.Testing.Context;
      Compiled : Boolean := False);

   procedure Run_With_Stream
     (Case_Item : Fixture;
      Label : String;
      Runner : Landin.Platform.Tool_Runner'Class;
      Program : String;
      Arguments : Landin.Platform.Path_List;
      Outcome : out Landin.Platform.Tool_Result;
      Item : in out Landin.Testing.Context;
      Compiled : Boolean := False)
   is
      Capture : constant Landin.Platform.Capture_Mode :=
        (if Stream (Case_Item) = Output
         then Landin.Platform.Output_Only else Landin.Platform.Merged);
   begin
      if Compiled then
         Run_Program (Runner, Program, Arguments, Outcome, Capture);
      else
         Runner.Run (Program, Arguments, Outcome, Capture);
      end if;
      if Stream (Case_Item) = Output then
         Landin.Testing.Check_Equal
           (Item, Unbounded.To_String (Outcome.Error_Output), "",
            Label & ": standard error is empty");
      end if;
   end Run_With_Stream;

   procedure Check_Output
     (Case_Item : Fixture;
      Label : String;
      Outcome : Landin.Platform.Tool_Result;
      Expected : String;
      Item : in out Landin.Testing.Context);

   procedure Check_Output
     (Case_Item : Fixture;
      Label : String;
      Outcome : Landin.Platform.Tool_Result;
      Expected : String;
      Item : in out Landin.Testing.Context)
   is
   begin
      Landin.Testing.Check_Equal
        (Item, Unbounded.To_String (Outcome.Output), Expected,
         Label & ": recorded "
         & (if Stream (Case_Item) = Output
            then "standard output" else "merged output"));
   end Check_Output;

   procedure Run_Recorded
     (Case_Item : Fixture;
      Host      : in out Landin.Platform.Filesystem'Class;
      Program   : String;
      Item      : in out Landin.Testing.Context);

   procedure Run_Recorded
     (Case_Item : Fixture;
      Host      : in out Landin.Platform.Filesystem'Class;
      Program   : String;
      Item      : in out Landin.Testing.Context)
   is
      Label    : constant String := Label_Of (Case_Item);
      Where    : constant String :=
        Fixture_Root & "/" & Label & "/" & Expect (Case_Item);
      Expected : Unbounded.Unbounded_String;
      Read     : Landin.Platform.Read_Status;
      Runner   : Landin.Platform.Native.Tools.Native_Tool_Runner;
      Outcome  : Landin.Platform.Tool_Result;
   begin
      Host.Read_File (Where, Expected, Read);

      if Read /= Landin.Platform.Read_Ok then
         Landin.Testing.Fail
           (Item, Label & ": expected file is unreadable");
         return;
      end if;

      Run_With_Stream
        (Case_Item, Label, Runner, Program,
         Lane_Arguments (Invocation (Case_Item)), Outcome, Item);
      --  A stale report names the command that re-records it alone.
      Check_Output
        (Case_Item,
         Label & " (once the difference is read, ./scripts/test.sh"
         & " --record=" & Label & " re-records it)",
         Outcome, Unbounded.To_String (Expected), Item);
      Check_Compiler_Outcome (Case_Item, Outcome, Item);
   end Run_Recorded;

   --  Record_Report over any host and runner, so a case can hold it to
   --  its refusals without a compiler or the real tree.
   procedure Record_Report_With
     (Path    : String;
      Host    : in out Landin.Platform.Filesystem'Class;
      Runner  : Landin.Platform.Tool_Runner'Class;
      Program : String;
      Wrote   : out Boolean;
      Said    : out Unbounded.Unbounded_String);

   procedure Record_Report_With
     (Path    : String;
      Host    : in out Landin.Platform.Filesystem'Class;
      Runner  : Landin.Platform.Tool_Runner'Class;
      Program : String;
      Wrote   : out Boolean;
      Said    : out Unbounded.Unbounded_String)
   is
      Found : Catalogue;
   begin
      Wrote := False;
      Said := Unbounded.Null_Unbounded_String;
      if not Host.Exists (Program) then
         Said := Unbounded.To_Unbounded_String
           ("refine was not found at " & Program
            & "; record through scripts/test.sh");
         return;
      end if;

      Discover (Found, Fixture_Root, Host, Only => Path);
      if Problem_Count (Found) /= 0 then
         Said := Unbounded.To_Unbounded_String
           (Path & ": " & Nth_Problem (Found, 1));
         return;
      elsif Count (Found) /= 1 or else Label_Of (Nth (Found, 1)) /= Path
      then
         Said := Unbounded.To_Unbounded_String
           (Path & " names no fixture; name it CLASS/NAME, as --fixture"
            & " does");
         return;
      elsif Expect (Nth (Found, 1)) = "" then
         Said := Unbounded.To_Unbounded_String
           (Path & " records no report: its metadata names no `expect`");
         return;
      end if;

      declare
         Case_Item : constant Fixture := Nth (Found, 1);
         Where     : constant String :=
           Fixture_Root & "/" & Path & "/" & Expect (Case_Item);
         Outcome   : Landin.Platform.Tool_Result;
         Verdict   : Landin.Testing.Context;
         Status    : Landin.Platform.Write_Status;
      begin
         Run_With_Stream
           (Case_Item, Path, Runner, Program,
            Lane_Arguments (Invocation (Case_Item)), Outcome, Verdict);
         Check_Compiler_Outcome (Case_Item, Outcome, Verdict);
         if Landin.Testing.Failures (Verdict) /= 0 then
            Said := Unbounded.To_Unbounded_String
              (Path & ": not recorded, because the run no longer meets"
               & " the fixture's metadata:" & ASCII.LF
               & Landin.Testing.Failure_Text (Verdict));
            return;
         end if;
         Host.Write_File (Where, Unbounded.To_String (Outcome.Output), Status);
         Wrote := Status = Landin.Platform.Write_Ok;
         Said := Unbounded.To_Unbounded_String
           ((if Wrote then "wrote " else "could not write ")
            & "compiler/tests/fixtures/" & Path & "/" & Expect (Case_Item));
      end;
   exception
      when Landin.External_Tool_Failed =>
         Wrote := False;
         Said := Unbounded.To_Unbounded_String
           ("refine could not be run: " & Program);
   end Record_Report_With;

   procedure Record_Report
     (Path  : String;
      Wrote : out Boolean;
      Said  : out Ada.Strings.Unbounded.Unbounded_String)
   is
      Host   : Landin.Platform.Native.Native_Filesystem;
      Runner : Landin.Platform.Native.Tools.Native_Tool_Runner;
   begin
      Record_Report_With (Path, Host, Runner, Refine_Path, Wrote, Said);
   end Record_Report;

   --  A report re-recorded by name writes the bytes refine reports now,
   --  and only while its status and codes are still the ones pinned: a
   --  recording replaces bytes and never a verdict.
   procedure A_Report_Is_Recorded_By_Name
     (Item : in out Landin.Testing.Context);

   procedure A_Report_Is_Recorded_By_Name
     (Item : in out Landin.Testing.Context)
   is
      Directory : constant String := Fixture_Root & "/negative/sample";
      Expected  : constant String := Directory & "/expected.txt";
      Report    : constant String :=
        "error[L0100]: a fresh report" & ASCII.LF;

      procedure Attempt
        (Exit_Code : Integer; Output : String; Path : String;
         Wrote : out Boolean; Said : out Unbounded.Unbounded_String;
         Written : out Unbounded.Unbounded_String);

      procedure Attempt
        (Exit_Code : Integer; Output : String; Path : String;
         Wrote : out Boolean; Said : out Unbounded.Unbounded_String;
         Written : out Unbounded.Unbounded_String)
      is
         Host   : Landin.Testing.Fakes.Fake_Filesystem;
         Runner : Landin.Testing.Fakes.Fake_Tool_Runner;
      begin
         Host.Add_File ("/bin/refine", "");
         Host.Add_Directory (Fixture_Root);
         Host.Add_Directory (Fixture_Root & "/negative");
         Host.Add_Directory (Directory);
         Host.Add_File
           (Directory & "/fixture.meta",
            "class: negative" & ASCII.LF
            & "summary: a refusal whose report is recorded" & ASCII.LF
            & "program: program.ldn" & ASCII.LF
            & "codes: L0100" & ASCII.LF
            & "constructs: 0380" & ASCII.LF
            & "targets: linux-x86-64" & ASCII.LF
            & "expect: expected.txt" & ASCII.LF
            & "args: " & Directory & "/program.ldn" & ASCII.LF);
         Host.Add_File (Directory & "/program.ldn", "x: u8 = (" & ASCII.LF);
         Host.Add_File (Expected, "error[L0100]: a stale report" & ASCII.LF);
         Runner.Set_Result (Exit_Code, Output);
         Record_Report_With
           (Path, Host, Runner, "/bin/refine", Wrote, Said);
         Written := Unbounded.To_Unbounded_String
           (Landin.Testing.Fakes.Written (Host, Expected));
      end Attempt;

      Wrote   : Boolean;
      Said    : Unbounded.Unbounded_String;
      Written : Unbounded.Unbounded_String;
   begin
      Attempt (1, Report, "negative/sample", Wrote, Said, Written);
      Landin.Testing.Check
        (Item, Wrote, "a report still meeting its metadata is recorded: "
         & Unbounded.To_String (Said));
      Landin.Testing.Check_Equal
        (Item, Unbounded.To_String (Written), Report,
         "the recording is what refine reports now");

      Attempt (0, Report, "negative/sample", Wrote, Said, Written);
      Landin.Testing.Check
        (Item, not Wrote and then Unbounded.To_String (Written) = ""
         and then Unbounded.Index (Said, "no longer meets") > 0,
         "a changed status is not recorded: " & Unbounded.To_String (Said));

      Attempt (1, "error[L0101]: another refusal" & ASCII.LF,
               "negative/sample", Wrote, Said, Written);
      Landin.Testing.Check
        (Item, not Wrote and then Unbounded.To_String (Written) = "",
         "a changed code is not recorded: " & Unbounded.To_String (Said));

      Attempt (1, Report, "negative/absent", Wrote, Said, Written);
      Landin.Testing.Check
        (Item, not Wrote and then Unbounded.Index (Said, "CLASS/NAME") > 0,
         "an unknown fixture is refused with the naming rule: "
         & Unbounded.To_String (Said));
   end A_Report_Is_Recorded_By_Name;


   --  A compiler success can only satisfy this attempt with a new file.
   --  Removal is a host operation, so fake runners can pin stale-output
   --  refusal without starting a compiler, assembler or generated program.
   procedure Produce_Output
     (Host    : Landin.Platform.Filesystem'Class;
      Runner  : Landin.Platform.Tool_Runner'Class;
      Program, Label, Path : String;
      Args    : Landin.Platform.Path_List;
      Item    : in out Landin.Testing.Context;
      Ready   : out Boolean);

   --  The same, handing back what the producer said, which for refine is
   --  its report.
   procedure Produce_Output
     (Host    : Landin.Platform.Filesystem'Class;
      Runner  : Landin.Platform.Tool_Runner'Class;
      Program, Label, Path : String;
      Args    : Landin.Platform.Path_List;
      Item    : in out Landin.Testing.Context;
      Ready   : out Boolean;
      Said    : out Unbounded.Unbounded_String);

   procedure Produce_Output
     (Host    : Landin.Platform.Filesystem'Class;
      Runner  : Landin.Platform.Tool_Runner'Class;
      Program, Label, Path : String;
      Args    : Landin.Platform.Path_List;
      Item    : in out Landin.Testing.Context;
      Ready   : out Boolean)
   is
      Ignored : Unbounded.Unbounded_String;
   begin
      Produce_Output
        (Host, Runner, Program, Label, Path, Args, Item, Ready, Ignored);
   end Produce_Output;

   procedure Produce_Output
     (Host    : Landin.Platform.Filesystem'Class;
      Runner  : Landin.Platform.Tool_Runner'Class;
      Program, Label, Path : String;
      Args    : Landin.Platform.Path_List;
      Item    : in out Landin.Testing.Context;
      Ready   : out Boolean;
      Said    : out Unbounded.Unbounded_String)
   is
      Removed : Landin.Platform.Remove_Status;
      Outcome : Landin.Platform.Tool_Result;
   begin
      Ready := False;
      Said := Unbounded.Null_Unbounded_String;
      Host.Remove_File (Path, Removed);
      if Removed = Landin.Platform.Not_Removable or else Host.Exists (Path)
      then
         Landin.Testing.Fail
           (Item, Label & ": could not clear the previous output at " & Path);
         return;
      end if;

      Runner.Run (Program, Args, Outcome, Landin.Platform.Merged);
      Said := Outcome.Output;
      if Outcome.Ended /= Landin.Platform.Exited then
         Landin.Testing.Fail
           (Item, Label & ": producer was stopped before completing output"
            & ASCII.LF & Unbounded.To_String (Outcome.Output));
      elsif Outcome.Exit_Code /= 0 then
         Landin.Testing.Fail
           (Item, Label & ": producer failed to complete output"
            & ASCII.LF & Unbounded.To_String (Outcome.Output));
      elsif not Host.Exists (Path) or else Host.Is_Directory (Path) then
         Landin.Testing.Fail
           (Item, Label & ": producer reported success and wrote no file at "
            & Path);
      else
         Ready := True;
      end if;
   exception
      when Landin.External_Tool_Failed =>
         Landin.Testing.Fail
           (Item, Label & ": producer could not be run: " & Program);
   end Produce_Output;

   procedure Emit_Positive
     (Case_Item : Fixture;
      Host      : Landin.Platform.Filesystem'Class;
      Program   : String;
      Item      : in out Landin.Testing.Context);

   procedure Emit_Positive
     (Case_Item : Fixture;
      Host      : Landin.Platform.Filesystem'Class;
      Program   : String;
      Item      : in out Landin.Testing.Context)
   is
      Label   : constant String := "positive/" & Name (Case_Item);
      Written : constant String :=
        Output_Directory & "positive-" & Name (Case_Item) & ".s";
      Runner  : Landin.Platform.Native.Tools.Native_Tool_Runner;
      Ready   : Boolean;
      Said    : Unbounded.Unbounded_String;
      Args    : Landin.Platform.Path_List;
   begin
      Append_Module_Arguments (Case_Item, Fixture_Root, Args);
      Landin.Platform.Add (Args, "--emit=asm");
      Landin.Platform.Add (Args, "-o");
      Landin.Platform.Add (Args, Written);

      Produce_Output
        (Host, Runner, Program, Label, Written, Lane_Arguments (Args), Item,
         Ready, Said);
      if Ready then
         Landin.Testing.Check
           (Item, True, Label & ": this attempt produced fresh assembly");
         Check_Accepted_Report
           (Case_Item, Label, Unbounded.To_String (Said), Item);
      end if;
   end Emit_Positive;

   procedure Run_Negative
     (Case_Item : Fixture;
      Program   : String;
      Item      : in out Landin.Testing.Context);

   procedure Run_Negative
     (Case_Item : Fixture;
      Program   : String;
      Item      : in out Landin.Testing.Context)
   is
      Runner  : Landin.Platform.Native.Tools.Native_Tool_Runner;
      Outcome : Landin.Platform.Tool_Result;
      Args    : Landin.Platform.Path_List;
   begin
      Args := Invocation (Case_Item);
      if Module_Root (Case_Item) = "" then
         Append_Module_Arguments (Case_Item, Fixture_Root, Args);
      end if;
      Runner.Run
        (Program, Lane_Arguments (Args), Outcome, Landin.Platform.Merged);

      Check_Compiler_Outcome (Case_Item, Outcome, Item);
   end Run_Negative;

   procedure Recorded_Expectations_Hold
     (Item : in out Landin.Testing.Context);

   procedure Recorded_Expectations_Hold
     (Item : in out Landin.Testing.Context)
   is
      Host    : Landin.Platform.Native.Native_Filesystem;
      Found   : Catalogue;
      Program : constant String := Refine_Path;
      Ran     : Natural := 0;
      Pinned  : Natural := 0;
      Negative_Ran : Boolean := False;
      End_To_End_Ran : Boolean := False;
   begin
      if not Host.Exists (Program) then
         Landin.Testing.Fail
           (Item,
            "refine was not found at " & Program
            & "; run the harness through scripts/test.sh");
         return;
      end if;

      Discover (Found, Fixture_Root, Host);

      Landin.Testing.Check_Equal
        (Item, Problem_Count (Found), 0,
         "the fixture tree parses before anything is run");
      if Problem_Count (Found) /= 0 then
         return;
      end if;

      for Index in 1 .. Count (Found) loop
         declare
            Case_Item : constant Fixture := Nth (Found, Index);
         begin
            if Expect (Case_Item) /= "" and then Recorded_In_Lane (Case_Item)
            then
               Run_Recorded (Case_Item, Host, Program, Item);
               Ran := Ran + 1;
               Negative_Ran := Negative_Ran
                 or else Class (Case_Item) = Negative_Program;
               End_To_End_Ran := End_To_End_Ran
                 or else Class (Case_Item) = End_To_End;
               if Stream (Case_Item) = Output then
                  Pinned := Pinned + 1;
               end if;
            end if;
         end;
      end loop;

      Landin.Testing.Check_Equal
        (Item, Ran, Recorded_Lane_Count (Found),
         "every recorded expectation was attempted");
      Landin.Testing.Check
        (Item, Negative_Ran and then End_To_End_Ran,
         "recorded negative and end-to-end obligations remain present");
      Landin.Testing.Check
        (Item, Pinned > 0, "a recorded run pins refine's output stream");

      --  And a multi-argument run, because a runner that passed only the
      --  first argument would satisfy every single-argument fixture.
      declare
         Runner  : Landin.Platform.Native.Tools.Native_Tool_Runner;
         Several : Landin.Platform.Path_List;
         Outcome : Landin.Platform.Tool_Result;
      begin
         Landin.Platform.Add (Several, "--target=synthetic-32");
         Landin.Platform.Add (Several, "--wat");

         Runner.Run (Program, Several, Outcome,
                     Landin.Platform.Merged);

         Landin.Testing.Check_Equal
           (Item, Outcome.Exit_Code, 2,
            "every argument reaches the tool, not just the first");
         Landin.Testing.Check
           (Item,
            Ada.Strings.Fixed.Index
              (Unbounded.To_String (Outcome.Output), "--wat") > 0,
            "the second argument is the one reported");
      end;
   end Recorded_Expectations_Hold;


   ------------------------------------------------------------------
   --  Runtime and ABI fixtures
   --
   --  Compiled, linked and executed, and the only cases in this
   --  repository that run a program this compiler produced.  Everything
   --  else can be checked against a command line; whether the bytes are
   --  *correct* is what running them says.
   --
   ------------------------------------------------------------------
   --  Every positive fixture is emitted, and not merely accepted
   --
   --  A positive fixture is a program the compiler must accept, and until the
   --  construct matrix that was the whole of what any case asked of one.
   --  Accepting is not emitting: an audit of the first native path found four
   --  of [1810]'s statement forms that every stage accepted and no case had
   --  ever asked a backend for, so a construct could reach a compiler defect
   --  and the corpus would say nothing.  This asks the backend for all of
   --  them.
   --
   --  It does not run them.  What a positive fixture claims is that the
   --  program is legal, and most of the corpus is a fragment with no
   --  entry point to run; the runtime class is where a claim about a
   --  machine belongs.  The three words the matrix wants are separate for
   --  this reason: accepted, emitted, executed.
   ------------------------------------------------------------------

   procedure Hosted_Library_Links_And_Runs
     (Item : in out Landin.Testing.Context);

   procedure Hosted_Library_Links_And_Runs
     (Item : in out Landin.Testing.Context)
   is
      Host    : Landin.Platform.Native.Native_Filesystem;
      Runner  : Landin.Platform.Native.Tools.Native_Tool_Runner;
      LF      : constant String := [ASCII.LF];

      --  Every hosted lane links and runs these consumers. Only Linux
      --  x86-64 currently gives each item its own section and collects dead
      --  sections, so only that backend promises the Absent symbols vanish.
      procedure Check_Linked
        (Name, Program : String; Absent : Landin.Platform.Path_List;
         Required : String := "");

      procedure Check_Linked
        (Name, Program : String; Absent : Landin.Platform.Path_List;
         Required : String := "")
      is
         Source  : constant String := Output_Directory & Name & ".ldn";
         Built   : constant String := Output_Directory & Name;
         Args    : Landin.Platform.Path_List;
         Nm_Args : Landin.Platform.Path_List;
         Written : Landin.Platform.Write_Status;
         Ready   : Boolean;
         Symbols : Landin.Platform.Tool_Result;
         Ran     : Landin.Platform.Tool_Result;
      begin
         Host.Write_File (Source, Program, Written);
         Landin.Testing.Check
           (Item, Written = Landin.Platform.Write_Ok,
            Name & ": regression source was written");
         if Written /= Landin.Platform.Write_Ok then
            return;
         end if;

         Args.Append (Source);
         Args.Append ("--emit=exe");
         --  These consumers call the C library, which a static Linux link
         --  does not have.
         Args.Append ("--link=libc");
         Args.Append ("-o");
         Args.Append (Built);
         if Lanes.Toolchain /= "" then
            Args.Append ("--toolchain=" & Lanes.Toolchain);
         end if;
         Produce_Output
           (Host, Runner, Refine_Path, Name, Built, Lane_Arguments (Args),
            Item, Ready);
         if not Ready then
            return;
         end if;

         Nm_Args.Append ("-a");
         Nm_Args.Append (Built);
         Runner.Run ("nm", Nm_Args, Symbols, Landin.Platform.Merged);
         Landin.Testing.Check
           (Item, Symbols.Ended = Landin.Platform.Exited
            and then Symbols.Exit_Code = 0,
            Name & ": linked symbols are readable");
         if Symbols.Ended = Landin.Platform.Exited
           and then Symbols.Exit_Code = 0
         then
            if Landin.Targets.Capabilities.Backend_For (Lanes.Target)
              = Landin.Targets.Capabilities.X86_64_ELF
            then
               for Symbol of Absent loop
                  Landin.Testing.Check
                    (Item, Ada.Strings.Fixed.Index
                       (Unbounded.To_String (Symbols.Output), Symbol) = 0,
                     Name & ": " & Symbol & " is absent from the executable");
               end loop;
            end if;
            if Required /= "" then
               Landin.Testing.Check
                 (Item, Ada.Strings.Fixed.Index
                    (Unbounded.To_String (Symbols.Output), Required) > 0,
                  Name & ": the reachable routine remains linked");
            end if;
         end if;

         Run_Program
           (Runner, Built, Landin.Platform.No_Arguments, Ran,
            Landin.Platform.Merged);
         Landin.Testing.Check
           (Item, Ran.Ended = Landin.Platform.Exited
            and then Ran.Exit_Code = 0
            and then Unbounded.Length (Ran.Output) = 0,
            Name & ": hosted main runs");
      end Check_Linked;

      Main : constant String :=
        "public main: () -> (code: i32) = code = 0 end main" & LF;
      Count : constant String :=
        "extern(c) getpid: () -> (id: i32)" & LF;
      Absent : Landin.Platform.Path_List;
   begin
      --  A hosted program that never imports hosted/system defines no argument
      --  root, so its entry calls no initializer.
      Absent.Append ("_landin_host_initialize_arguments");
      Check_Linked ("hosted-entry-without-io", Main, Absent);

      --  Importing hosted/system brings the root, and the entry calls it.
      Check_Linked
        ("hosted-entry-with-io",
         "import hosted/system" & LF & Main,
         Landin.Platform.No_Arguments, "_landin_host_initialize_arguments");

      --  A declaration alone links nothing from the C library.
      Absent.Clear;
      Absent.Append ("getpid");
      Check_Linked ("unused-c-import", Count & Main, Absent);

      --  A routine nothing reaches retains neither itself nor its import.
      Absent.Clear;
      Absent.Append ("dead_process_reader");
      Absent.Append ("getpid");
      Check_Linked
        ("dead-c-import-caller",
         Count
         & "dead_process_reader: () -> (n: i32) ="
         & " n = getpid()"
         & " end dead_process_reader" & LF & Main,
         Absent);

      --  Nor does an unreachable datum holding the caller's address.
      Absent.Clear;
      Absent.Append ("dead_holder");
      Absent.Append ("held_process_reader");
      Absent.Append ("getpid");
      Check_Linked
        ("dead-c-import-datum",
         Count
         & "counter: type = () -> (n: i32)" & LF
         & "holder: type = struct" & LF
         & "    run: counter" & LF
         & "end holder" & LF
         & "held_process_reader: () -> (n: i32) ="
         & " n = getpid()"
         & " end held_process_reader" & LF
         & "dead_holder: holder = (run: held_process_reader)" & LF
         & Main,
         Absent);

      --  Nor an erased conformance table only a dead routine builds.
      Absent.Clear;
      Absent.Append ("dead_erased_reader");
      Absent.Append ("evidence_process_reader");
      Absent.Append ("getpid");
      Check_Linked
        ("dead-c-import-evidence",
         Count
         & "counting: type = concept (t: type)" & LF
         & "    count: (self: ptr t) -> (n: i32)" & LF
         & "end counting" & LF
         & "thing: type = struct" & LF
         & "    value: i32" & LF
         & "end thing" & LF
         & "evidence_process_reader: (self: ptr thing) -> (n: i32) =" & LF
         & "    n = getpid()" & LF
         & "end evidence_process_reader" & LF
         & "thing is counting (count: evidence_process_reader)" & LF
         & "dead_erased_reader: () -> (n: i32) =" & LF
         & "    item: thing = (value: 1)" & LF
         & "    erased: any counting = any(addr item)" & LF
         & "    n = erased.count()" & LF
         & "end dead_erased_reader" & LF
         & Main,
         Absent);

      --  Collection must retain a reachable import. Every hosted lane
      --  executes this call.
      Check_Linked
        ("live-c-import-caller",
         Count & "public main: () -> (code: i32) =" & LF
         & "    code = if getpid() > 0 then 0 else 1 end if" & LF
         & "end main" & LF,
         Landin.Platform.No_Arguments, "getpid");
   end Hosted_Library_Links_And_Runs;

   procedure Every_Positive_Fixture_Is_Emitted
     (Item : in out Landin.Testing.Context);

   procedure Every_Positive_Fixture_Is_Emitted
     (Item : in out Landin.Testing.Context)
   is
      Host    : Landin.Platform.Native.Native_Filesystem;
      Found   : Catalogue;
      Program : constant String := Refine_Path;
      Ran     : Natural := 0;
   begin
      if not Host.Exists (Program) then
         Landin.Testing.Fail
           (Item,
            "refine was not found at " & Program
            & "; run the harness through scripts/test.sh");
         return;
      end if;

      Discover (Found, Fixture_Root, Host);
      Landin.Testing.Check_Equal
        (Item, Problem_Count (Found), 0, "positive metadata is valid");
      if Problem_Count (Found) /= 0 then
         return;
      end if;

      declare
         type Index_Array is array (Positive range <>) of Positive;

         Work : Index_Array (1 .. Count (Found));
         Last : Natural := 0;

         procedure Emit_One
           (Piece : Positive; Slot : in out Landin.Testing.Context);

         procedure Emit_One
           (Piece : Positive; Slot : in out Landin.Testing.Context) is
         begin
            Emit_Positive (Nth (Found, Piece), Host, Program, Slot);
         end Emit_One;

         procedure Emit_Each is new Across_Workers
           (Element => Positive,
            Element_Array => Index_Array,
            Perform => Emit_One);
      begin
         --  Collected first, run second: the work order is the corpus
         --  order whatever the workers do with it.
         for Index in 1 .. Count (Found) loop
            declare
               Case_Item : constant Fixture := Nth (Found, Index);
            begin
               if Class (Case_Item) = Positive_Program
                 and then Landin.Testing.Fixtures.Program (Case_Item) /= ""
                 and then In_Lane (Case_Item)
               then
                  Last := Last + 1;
                  Work (Last) := Index;
               end if;
            end;
         end loop;

         Ran := Last;
         Emit_Each (Work (1 .. Last), Item);
      end;

      Landin.Testing.Check_Equal
        (Item, Ran,
         Program_Count
           (Found, Positive_Program, Lane => Lanes.Fixture_Label),
         "every eligible positive fixture was attempted");
      Landin.Testing.Check
        (Item, Ran > 0, "the positive program obligation remains present");
   end Every_Positive_Fixture_Is_Emitted;

   --  A host that cannot finish the target fails rather than skipping.
   --  That is the same rule scripts/env.sh already applies to the pinned
   --  GNAT -- a machine without it is told so and stops, rather than
   --  quietly building nothing -- and compiler/tests/README.md states it
   --  for fixtures directly: an expectation nobody runs is a fault.  The
   --  failure carries refine's own report, which is where L0500's note
   --  says which toolchain would satisfy it.
   ------------------------------------------------------------------

   --  Compiler profiles are harness policy, never fixture `args`. Each run
   --  independently checks the original exact status/output/trap oracle.
   type Profile_Array is array (Positive range <>) of
     Landin.Optimization.Options;
   Profiles : constant Profile_Array :=
     [(Landin.Optimization.None, Landin.Optimization.Off),
      (Landin.Optimization.Size, Landin.Optimization.Off),
      (Landin.Optimization.Size, Landin.Optimization.Auto),
      (Landin.Optimization.Speed, Landin.Optimization.Auto),
      (Landin.Optimization.None, Landin.Optimization.All_Eligible),
      (Landin.Optimization.Speed, Landin.Optimization.All_Eligible)];

   function Profile_Name (Profile : Positive) return String is
     (Landin.Optimization.Spelling (Profiles (Profile).Optimize) & "-"
      & Landin.Optimization.Spelling (Profiles (Profile).Specialize));

   procedure Append_Profile
     (Arguments : in out Landin.Platform.Path_List; Profile : Positive);

   procedure Append_Profile
     (Arguments : in out Landin.Platform.Path_List; Profile : Positive) is
   begin
      Arguments.Append ("--optimize=" & Landin.Optimization.Spelling
        (Profiles (Profile).Optimize));
      Arguments.Append ("--specialize=" & Landin.Optimization.Spelling
        (Profiles (Profile).Specialize));
   end Append_Profile;

   --  The levels of the lane's family a runtime fixture's `levels:` names;
   --  the other families' levels are their own lanes' to run.
   function Lane_Levels (Case_Item : Fixture) return Landin.Platform.Path_List
     is (Levels_Of_Family (Case_Item, Lanes.Target));

   --  An arm64 executable carries no level note, so the image that ran is
   --  held to its level by its instructions.  At Armv8.1-A an atomic
   --  read-modify-write is one LSE instruction and none of the default's
   --  exclusive-monitor loops, `ldxr`, `ldaxr`, `stxr` and `stlxr` at any
   --  width, remains; at the default the same fixture's image holds no LSE
   --  instruction at all, at any ordering (D499).
   --  The lane's toolchain says which objdump reads the image.
   procedure Check_Arm64_Level
     (Built, Label : String; Leveled : Boolean;
      Item : in out Landin.Testing.Context);

   procedure Check_Arm64_Level
     (Built, Label : String; Leveled : Boolean;
      Item : in out Landin.Testing.Context)
   is
      Runner : Landin.Platform.Native.Tools.Native_Tool_Runner;
      Listing : Landin.Platform.Tool_Result;
      Args : Landin.Platform.Path_List;
      --  A cross lane's objdump is its driver's, named or the target's
      --  default, since the host's own cannot read another architecture.
      Driver : constant String :=
        Landin.Backend.Toolchain.Driver_For (Lanes.Target, Lanes.Toolchain);
      Tool : constant String :=
        (if not Lanes.Is_Native and then Driver'Length > 4
           and then Driver (Driver'Last - 3 .. Driver'Last) = "-gcc"
         then Driver (Driver'First .. Driver'Last - 4) & "-objdump"
         else "objdump");
   begin
      Args.Append ("-d");
      Args.Append ("--no-show-raw-insn");
      Args.Append (Built);
      Runner.Run (Tool, Args, Listing, Landin.Platform.Output_Only);
      declare
         Text : constant String := Unbounded.To_String (Listing.Output);

         --  A mnemonic at the start of an instruction, so `ldxr` also
         --  finds `ldxrb` and `ldxrh` and never the acquiring `ldaxr`, and
         --  `ldadd` every ordering's and width's LSE add.
         function Has (Word : String) return Boolean
           is (Ada.Strings.Fixed.Index (Text, ASCII.HT & Word) > 0);

         LSE : constant Boolean :=
           Has ("ldadd") or else Has ("swp") or else Has ("cas");
      begin
         Landin.Testing.Check
           (Item, Listing.Ended = Landin.Platform.Exited
                    and then Listing.Exit_Code = 0
                    and then Has ("ret"),
            Label & ": " & Tool & " disassembled the image");
         if Leveled then
            Landin.Testing.Check
              (Item, LSE, Label & ": the image holds an LSE instruction");
            Landin.Testing.Check
              (Item, not Has ("ldxr") and then not Has ("ldaxr")
                       and then not Has ("stxr") and then not Has ("stlxr"),
               Label & ": no exclusive-monitor loop remains");
         else
            Landin.Testing.Check
              (Item, not LSE,
               Label & ": the default's image holds no LSE instruction");
         end if;
      end;
   end Check_Arm64_Level;

   --  An RV64 executable carries no ISA note either, but its RISC-V
   --  attributes name the ISA every object was assembled for, merged: the
   --  `.attribute arch` refine writes for the level among them.  The image
   --  built at a level is held to that string naming each of the level's
   --  extensions, read with the lane's readelf.
   procedure Check_RV64_Level
     (Built, Label, Level : String;
      Item : in out Landin.Testing.Context);

   procedure Check_RV64_Level
     (Built, Label, Level : String;
      Item : in out Landin.Testing.Context)
   is
      package L renames Landin.Targets.Levels;
      Runner : Landin.Platform.Native.Tools.Native_Tool_Runner;
      Listing : Landin.Platform.Tool_Result;
      Args : Landin.Platform.Path_List;
      Driver : constant String :=
        Landin.Backend.Toolchain.Driver_For (Lanes.Target, Lanes.Toolchain);
      Tool : constant String :=
        (if Driver'Length > 4
           and then Driver (Driver'Last - 3 .. Driver'Last) = "-gcc"
         then Driver (Driver'First .. Driver'Last - 4) & "-readelf"
         else "readelf");
      Selected : constant L.Feature_Level :=
        L.Level_Named (Lanes.Target, Level);
   begin
      Args.Append ("-A");
      Args.Append (Built);
      Runner.Run (Tool, Args, Listing, Landin.Platform.Output_Only);
      declare
         Text : constant String := Unbounded.To_String (Listing.Output);
         Marker : constant String := "Tag_RISCV_arch: """;
         At_Tag : constant Natural := Ada.Strings.Fixed.Index (Text, Marker);
         Stop : constant Natural :=
           (if At_Tag = 0 then 0
            else Ada.Strings.Fixed.Index
              (Text (At_Tag + Marker'Length .. Text'Last), """"));
         Arch : constant String :=
           (if Stop = 0 then ""
            else Text (At_Tag + Marker'Length .. Stop - 1));
         --  Each extension with its version taken off: `zba1p0` is zba.
         function Unversioned (Name : String) return String;

         function Unversioned (Name : String) return String is
            Last : Natural := Name'Last;
         begin
            while Last >= Name'First and then Name (Last) in '0' .. '9' loop
               Last := Last - 1;
            end loop;
            if Last > Name'First and then Name (Last) = 'p'
              and then Name (Last - 1) in '0' .. '9'
            then
               Last := Last - 1;
               while Last >= Name'First and then Name (Last) in '0' .. '9'
               loop
                  Last := Last - 1;
               end loop;
            end if;
            return Name (Name'First .. Last);
         end Unversioned;

         Named : Unbounded.Unbounded_String :=
           Unbounded.To_Unbounded_String (" ");
         Missing : Unbounded.Unbounded_String;
         Start : Positive := Arch'First;
         First : Boolean := True;
      begin
         while Start <= Arch'Last loop
            declare
               Underscore : constant Natural :=
                 Ada.Strings.Fixed.Index (Arch (Start .. Arch'Last), "_");
               Part : constant String :=
                 Arch (Start .. (if Underscore = 0 then Arch'Last
                                 else Underscore - 1));
            begin
               if First and then Part'Length > 4
                 and then Part (Part'First .. Part'First + 3) = "rv64"
               then
                  Unbounded.Append
                    (Named, Unversioned (Part (Part'First + 4 .. Part'Last))
                     & " ");
               else
                  Unbounded.Append (Named, Unversioned (Part) & " ");
               end if;
               First := False;
               exit when Underscore = 0;
               Start := Underscore + 1;
            end;
         end loop;
         for Each in L.Feature loop
            if L.Has (Selected, Each)
              and then Unbounded.Index
                (Named, " " & L.Spelling (Each) & " ") = 0
            then
               Unbounded.Append (Missing, " " & L.Spelling (Each));
            end if;
         end loop;
         Landin.Testing.Check
           (Item, Listing.Ended = Landin.Platform.Exited
                    and then Listing.Exit_Code = 0
                    and then Arch /= ""
                    and then Unbounded.Length (Missing) = 0,
            Label & ": the executable needs " & Level & " ("
            & Tool & " reads Tag_RISCV_arch """ & Arch & """"
            & (if Unbounded.Length (Missing) = 0 then ""
               else ", lacking" & Unbounded.To_String (Missing)) & ")");
      end;
   end Check_RV64_Level;

   --  What the processor that runs the lane's executables says it has: the
   --  line of /proc/cpuinfo that lists its features, `flags` on x86-64 and
   --  `Features` on arm64, with a space at each end.  The deliberate
   --  exception to the fake platform: what is asked is a real processor,
   --  because a level above it must be refused rather than run and hoped.
   --  A native lane reads this host's own file.  A cross lane's runner is
   --  asked rather than assumed, because an emulator presents the processor
   --  it emulates, and QEMU's `-cpu cortex-a53` has no LSE: a C program the
   --  lane's driver links copies the file the runner shows it.  Any other
   --  lane has no Linux to ask, so a level there is unverified.  Asked once,
   --  before the workers start, so every run reads one answer.
   Processor_Asked   : Boolean := False;
   Processor_Flags   : Unbounded.Unbounded_String;
   Processor_Source  : Unbounded.Unbounded_String;
   Processor_Problem : Unbounded.Unbounded_String;

   procedure Ask_Lane_Processor (Host : Landin.Platform.Filesystem'Class);

   --  RISC-V Linux lists no flags: its `isa` line is the ISA string,
   --  `rv64imafdc_zicsr_zifencei_zba`, whose base names its single-letter
   --  extensions and each part after an underscore one more.  Spelled out
   --  as the other families' flags are, a space at each end of each.
   function ISA_Extensions (ISA : String) return String;

   function ISA_Extensions (ISA : String) return String is
      Text : constant String := Ada.Characters.Handling.To_Lower
        (Ada.Strings.Fixed.Trim (ISA, Ada.Strings.Both));
      Result : Unbounded.Unbounded_String :=
        Unbounded.To_Unbounded_String (" ");
      Start : Positive := Text'First;
      First : Boolean := True;
   begin
      while Start <= Text'Last loop
         declare
            Stop : constant Natural :=
              Ada.Strings.Fixed.Index (Text (Start .. Text'Last), "_");
            Part : constant String :=
              Text (Start .. (if Stop = 0 then Text'Last else Stop - 1));
         begin
            if First then
               if Part'Length > 4
                 and then Part (Part'First .. Part'First + 3) = "rv64"
               then
                  for Letter of Part (Part'First + 4 .. Part'Last) loop
                     Unbounded.Append (Result, Letter & " ");
                  end loop;
               end if;
               First := False;
            elsif Part'Length > 0 then
               Unbounded.Append (Result, Part & " ");
            end if;
            exit when Stop = 0;
            Start := Stop + 1;
         end;
      end loop;
      return Unbounded.To_String (Result);
   end ISA_Extensions;

   --  Darwin's sysctl for each Armv8.1-A feature, under hw.optional.arm,
   --  and the Linux flag Host_Has_Level knows it by.
   subtype Darwin_Feature is Positive range 1 .. 3;
   function Darwin_Key (Each : Darwin_Feature) return String
     is (case Each is
            when 1 => "FEAT_LSE", when 2 => "FEAT_CRC32",
            when 3 => "FEAT_RDM");
   function Darwin_Flag (Each : Darwin_Feature) return String
     is (case Each is
            when 1 => "atomics", when 2 => "crc32", when 3 => "asimdrdm");

   --  Whether `sysctl -n KEY` answered 1.  It ends its answer with a line
   --  feed, which a trim of spaces alone keeps, so every blank, tab and
   --  line ending on either side is dropped first.
   function Sysctl_Says_Yes (Output : String) return Boolean;

   function Sysctl_Says_Yes (Output : String) return Boolean is
      First : Positive := Output'First;
      Last : Natural := Output'Last;
      function Blank (C : Character) return Boolean
        is (C in ' ' | ASCII.HT | ASCII.LF | ASCII.CR);
   begin
      while First <= Last and then Blank (Output (First)) loop
         First := First + 1;
      end loop;
      while Last >= First and then Blank (Output (Last)) loop
         Last := Last - 1;
      end loop;
      return Output (First .. Last) = "1";
   end Sysctl_Says_Yes;

   procedure Ask_Lane_Processor (Host : Landin.Platform.Filesystem'Class) is
      Line : constant String :=
        (case Landin.Targets.Architecture_Of (Lanes.Target) is
            when Landin.Targets.Arm64 => "Features",
            when Landin.Targets.RV64 => "isa",
            when others => "flags");
      Text : Unbounded.Unbounded_String;

      procedure Refuse (Problem : String);

      procedure Refuse (Problem : String) is
      begin
         Processor_Problem := Unbounded.To_Unbounded_String (Problem);
      end Refuse;
   begin
      if Processor_Asked then
         return;
      end if;
      Processor_Asked := True;
      if Landin.Targets.Capabilities.Hosted_System_Of (Lanes.Target)
        = Landin.Targets.Capabilities.Darwin and then Lanes.Is_Native
      then
         --  A Mac has no /proc/cpuinfo; its kernel names each feature in
         --  a sysctl, which compiler/tests/darwin/check.py asks too.  Each
         --  that answers 1 becomes the flag Host_Has_Level reads.
         Processor_Source := Unbounded.To_Unbounded_String
           ("this Mac's hw.optional.arm sysctls");
         Processor_Flags := Unbounded.To_Unbounded_String (" ");
         for Each in Darwin_Feature loop
            declare
               Runner : Landin.Platform.Native.Tools.Native_Tool_Runner;
               Args : Landin.Platform.Path_List;
               Asked : Landin.Platform.Tool_Result;
            begin
               Args.Append ("-n");
               Args.Append ("hw.optional.arm." & Darwin_Key (Each));
               Runner.Run
                 ("/usr/sbin/sysctl", Args, Asked,
                  Landin.Platform.Output_Only);
               if Asked.Ended = Landin.Platform.Exited
                 and then Asked.Exit_Code = 0
                 and then Sysctl_Says_Yes
                   (Unbounded.To_String (Asked.Output))
               then
                  Unbounded.Append (Processor_Flags, Darwin_Flag (Each) & " ");
               end if;
            end;
         end loop;
         return;
      elsif Landin.Targets.Capabilities.Hosted_System_Of (Lanes.Target)
        /= Landin.Targets.Capabilities.Linux
      then
         Refuse ("the " & Lanes.Target_Name & " lane has no /proc/cpuinfo"
                 & " to confirm a level with");
         return;
      elsif Lanes.Is_Native then
         Processor_Source :=
           Unbounded.To_Unbounded_String ("this host's /proc/cpuinfo");
         declare
            Read : Landin.Platform.Read_Status;
         begin
            Host.Read_File ("/proc/cpuinfo", Text, Read);
            if Read /= Landin.Platform.Read_Ok then
               Refuse ("this host's /proc/cpuinfo is unreadable");
               return;
            end if;
         end;
      elsif Lanes.Runner = "" then
         Refuse ("the cross lane names no runner to ask");
         return;
      else
         Processor_Source := Unbounded.To_Unbounded_String
           ("/proc/cpuinfo as " & Lanes.Runner & " presents it");
         declare
            Source : constant String :=
              Output_Directory & "lane-processor.c";
            Built : constant String := Output_Directory & "lane-processor";
            Driver : constant String :=
              Landin.Backend.Toolchain.Driver_For
                (Lanes.Target, Lanes.Toolchain);
            Runner : Landin.Platform.Native.Tools.Native_Tool_Runner;
            Written : Landin.Platform.Write_Status;
            Args : Landin.Platform.Path_List;
            Linked : Landin.Platform.Tool_Result;
            Copied : Landin.Platform.Tool_Result;
         begin
            Host.Write_File
              (Source,
               "#include <stdio.h>" & ASCII.LF
               & "int main(void)" & ASCII.LF
               & "{" & ASCII.LF
               & "    FILE *info = fopen(""/proc/cpuinfo"", ""r"");"
               & ASCII.LF
               & "    int c;" & ASCII.LF
               & "    if (info == NULL)" & ASCII.LF
               & "        return 1;" & ASCII.LF
               & "    while ((c = fgetc(info)) != EOF)" & ASCII.LF
               & "        putchar(c);" & ASCII.LF
               & "    return fclose(info) != 0;" & ASCII.LF
               & "}" & ASCII.LF,
               Written);
            if Written /= Landin.Platform.Write_Ok then
               Refuse ("the processor probe could not be written");
               return;
            end if;
            Args.Append (Source);
            Args.Append ("-o");
            Args.Append (Built);
            Runner.Run (Driver, Args, Linked, Landin.Platform.Merged);
            if Linked.Ended /= Landin.Platform.Exited
              or else Linked.Exit_Code /= 0
            then
               Refuse (Driver & " could not link the processor probe: "
                       & Unbounded.To_String (Linked.Output));
               return;
            end if;
            Run_Program
              (Runner, Built, Landin.Platform.No_Arguments, Copied,
               Landin.Platform.Output_Only);
            if Copied.Ended /= Landin.Platform.Exited
              or else Copied.Exit_Code /= 0
            then
               Refuse (Lanes.Runner & " could not run the processor probe: "
                       & Unbounded.To_String (Copied.Output)
                       & Unbounded.To_String (Copied.Error_Output));
               return;
            end if;
            Text := Copied.Output;
         end;
      end if;
      declare
         Whole : constant String := Unbounded.To_String (Text);
         At_Flags : constant Natural :=
           Ada.Strings.Fixed.Index (Whole, Line & ASCII.HT);
         Colon : constant Natural :=
           (if At_Flags = 0 then 0
            else Ada.Strings.Fixed.Index (Whole, ":", At_Flags));
         Ends : constant Natural :=
           (if At_Flags = 0 then 0
            else Ada.Strings.Fixed.Index (Whole, "" & ASCII.LF, At_Flags));
      begin
         if Colon = 0 or else (Ends /= 0 and then Colon > Ends) then
            Refuse (Unbounded.To_String (Processor_Source) & " has no "
                    & Line & " line");
            return;
         end if;
         Processor_Flags := Unbounded.To_Unbounded_String
           (Whole (Colon .. (if Ends = 0 then Whole'Last else Ends - 1))
            & " ");
         Unbounded.Replace_Element (Processor_Flags, 1, ' ');
         if Line = "isa" then
            Processor_Flags := Unbounded.To_Unbounded_String
              (ISA_Extensions (Unbounded.To_String (Processor_Flags)));
         end if;
      end;
   end Ask_Lane_Processor;

   --  An emulator a cross lane runs its executables under is asked to show
   --  it is not one known to break every program before any runs.  Ubuntu
   --  24.04's qemu-riscv64, 8.2.2, wrote a 32-byte sigaction record over
   --  Linux's 24-byte one for riscv64, so every program that set a signal
   --  disposition overwrote its own frame and died before writing
   --  anything, and a gate run said "the program returned a status" about
   --  240 of them, naming nothing.  The probe is the record itself rather
   --  than a version number: a C program the lane's driver links asks for
   --  SIGPIPE's action through the system call with a guard word after
   --  Linux's record, and an emulator that writes the guard is refused,
   --  by its name and the version it reports, with the reason.  Words is
   --  the record's length in machine words: three on RV64, which has no
   --  restorer, and four on x86-64 and arm64.
   procedure Probe_Runner
     (Host        : Landin.Platform.Filesystem'Class;
      Tools       : Landin.Platform.Tool_Runner'Class;
      Runner_Name : String;
      Driver      : String;
      Words       : Positive;
      Directory   : String;
      Problem     : out Unbounded.Unbounded_String);

   procedure Probe_Runner
     (Host        : Landin.Platform.Filesystem'Class;
      Tools       : Landin.Platform.Tool_Runner'Class;
      Runner_Name : String;
      Driver      : String;
      Words       : Positive;
      Directory   : String;
      Problem     : out Unbounded.Unbounded_String)
   is
      Source  : constant String := Directory & "lane-runner.c";
      Built   : constant String := Directory & "lane-runner";
      Count   : constant String := Positive'Image (Words);
      Written : Landin.Platform.Write_Status;
      Args    : Landin.Platform.Path_List;
      Linked  : Landin.Platform.Tool_Result;
      Ran     : Landin.Platform.Tool_Result;
      Through : Landin.Platform.Path_List;
   begin
      Problem := Unbounded.Null_Unbounded_String;
      Host.Write_File
        (Source,
         "#define _GNU_SOURCE" & ASCII.LF
         & "#include <signal.h>" & ASCII.LF
         & "#include <string.h>" & ASCII.LF
         & "#include <sys/syscall.h>" & ASCII.LF
         & "#include <unistd.h>" & ASCII.LF
         & "/* Linux's rt_sigaction record, and one guard word after it. */"
         & ASCII.LF
         & "struct record { unsigned long words[" & Count
         & " ]; unsigned long guard; };" & ASCII.LF
         & "int main(void)" & ASCII.LF
         & "{" & ASCII.LF
         & "    struct record old;" & ASCII.LF
         & "    memset(&old, 0xa5, sizeof old);" & ASCII.LF
         & "    if (syscall(SYS_rt_sigaction, SIGPIPE, (void *)0, &old, 8)"
         & " != 0)" & ASCII.LF
         & "        return 2;" & ASCII.LF
         & "    return old.guard != (unsigned long)0xa5a5a5a5a5a5a5a5UL"
         & " ? 3 : 0;" & ASCII.LF
         & "}" & ASCII.LF,
         Written);
      if Written /= Landin.Platform.Write_Ok then
         Problem := Unbounded.To_Unbounded_String
           ("the runner probe could not be written at " & Source);
         return;
      end if;
      Args.Append (Source);
      Args.Append ("-std=c11");
      Args.Append ("-o");
      Args.Append (Built);
      Tools.Run (Driver, Args, Linked, Landin.Platform.Merged);
      if Linked.Ended /= Landin.Platform.Exited or else Linked.Exit_Code /= 0
      then
         Problem := Unbounded.To_Unbounded_String
           (Driver & " could not link the runner probe: "
            & Unbounded.To_String (Linked.Output));
         return;
      end if;
      Through.Append (Built);
      Tools.Run (Runner_Name, Through, Ran, Landin.Platform.Merged);
      if Ran.Ended = Landin.Platform.Exited and then Ran.Exit_Code = 0 then
         return;
      end if;
      declare
         Version : Landin.Platform.Tool_Result;
         Asked   : Landin.Platform.Path_List;
         Line    : Unbounded.Unbounded_String;
      begin
         Asked.Append ("--version");
         Tools.Run (Runner_Name, Asked, Version, Landin.Platform.Merged);
         declare
            Said : constant String := Unbounded.To_String (Version.Output);
            Ends : constant Natural :=
              Ada.Strings.Fixed.Index (Said, "" & ASCII.LF);
         begin
            Line := Unbounded.To_Unbounded_String
              (if Ends = 0 then Said else Said (Said'First .. Ends - 1));
         end;
         Problem := Unbounded.To_Unbounded_String
           (Runner_Name & " is refused before any program runs under it"
            & (if Unbounded.Length (Line) = 0 then ""
               else " (" & Unbounded.To_String (Line) & ")")
            & ": "
            & (if Ran.Ended = Landin.Platform.Exited
                 and then Ran.Exit_Code = 3
               then "asked for a signal's action, it wrote past Linux's"
                    & Positive'Image (Words * 8) & "-byte sigaction record,"
                    & " as Ubuntu 24.04's QEMU 8.2 does for riscv64, so"
                    & " every program that sets a signal disposition would"
                    & " overwrite its own frame and die before writing"
                    & " anything"
               else "it could not run the runner probe, which asks for a"
                    & " signal's action ("
                    & (if Ran.Ended = Landin.Platform.Exited
                       then "status" & Integer'Image (Ran.Exit_Code)
                       else "it did not exit")
                    & "): " & Unbounded.To_String (Ran.Output))
            & "; run the lane under the pinned QEMU, which nix develop"
            & " provides and nix build .#qemu-user builds");
      exception
         when Landin.External_Tool_Failed =>
            Problem := Unbounded.To_Unbounded_String
              (Runner_Name & " could not run the runner probe");
      end;
   exception
      when Landin.External_Tool_Failed =>
         Problem := Unbounded.To_Unbounded_String
           (Driver & " or " & Runner_Name
            & " could not be started for the runner probe");
   end Probe_Runner;

   --  The lane's own runner, probed once before the workers start.
   Runner_Asked   : Boolean := False;
   Runner_Problem : Unbounded.Unbounded_String;

   function Lane_Runner_Problem
     (Host : Landin.Platform.Filesystem'Class) return String;

   function Lane_Runner_Problem
     (Host : Landin.Platform.Filesystem'Class) return String
   is
      Tools : Landin.Platform.Native.Tools.Native_Tool_Runner;
   begin
      if not Runner_Asked then
         Runner_Asked := True;
         if not Lanes.Is_Native and then Lanes.Runner /= ""
           and then Landin.Targets.Capabilities.Hosted_System_Of (Lanes.Target)
                    = Landin.Targets.Capabilities.Linux
         then
            Probe_Runner
              (Host, Tools, Lanes.Runner,
               Landin.Backend.Toolchain.Driver_For
                 (Lanes.Target, Lanes.Toolchain),
               (if Landin.Targets.Architecture_Of (Lanes.Target)
                     = Landin.Targets.RV64
                then 3 else 4),
               Output_Directory, Runner_Problem);
         end if;
      end if;
      return Unbounded.To_String (Runner_Problem);
   end Lane_Runner_Problem;

   --  The probe on fakes: an emulator that writes past the record is
   --  refused by name, version and reason; one that does not is held to
   --  nothing more.
   --  A Mac's level is confirmed by `sysctl -n` printing 1 and a line
   --  feed; a trim of spaces alone kept the line feed and refused every
   --  feature of a Mac that has them all.
   procedure A_Sysctl_Answer_Is_Read_Past_Its_Line_Ending
     (Item : in out Landin.Testing.Context);

   procedure A_Sysctl_Answer_Is_Read_Past_Its_Line_Ending
     (Item : in out Landin.Testing.Context) is
   begin
      Landin.Testing.Check
        (Item, Sysctl_Says_Yes ("1" & ASCII.LF), "1 and a line feed is yes");
      Landin.Testing.Check
        (Item, Sysctl_Says_Yes (" 1" & ASCII.CR & ASCII.LF),
         "a carriage return and a blank are dropped too");
      Landin.Testing.Check
        (Item, Sysctl_Says_Yes ("1"), "a bare 1 is yes");
      Landin.Testing.Check
        (Item, not Sysctl_Says_Yes ("0" & ASCII.LF), "0 is no");
      Landin.Testing.Check
        (Item, not Sysctl_Says_Yes ("" & ASCII.LF), "an empty answer is no");
      Landin.Testing.Check
        (Item, not Sysctl_Says_Yes ("10" & ASCII.LF), "10 is no");
   end A_Sysctl_Answer_Is_Read_Past_Its_Line_Ending;

   procedure A_Known_Bad_Runner_Is_Refused
     (Item : in out Landin.Testing.Context);

   procedure A_Known_Bad_Runner_Is_Refused
     (Item : in out Landin.Testing.Context)
   is
      procedure Probe
        (Status : Integer; Problem : out Unbounded.Unbounded_String;
         Linked : Integer := 0);

      procedure Probe
        (Status : Integer; Problem : out Unbounded.Unbounded_String;
         Linked : Integer := 0)
      is
         Host  : Landin.Testing.Fakes.Fake_Filesystem;
         Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      begin
         Tools.Add_Result (Linked, "");
         Tools.Add_Result (Status, "");
         Tools.Add_Result
           (0, "qemu-riscv64 version 8.2.2 (Debian 1:8.2.2+ds-0ubuntu1.10)"
               & ASCII.LF & "Copyright (c) 2003-2023" & ASCII.LF);
         Probe_Runner
           (Host, Tools, "qemu-riscv64", "riscv64-linux-gnu-gcc", 3, "/w/",
            Problem);
      end Probe;

      Problem : Unbounded.Unbounded_String;
   begin
      Probe (0, Problem);
      Landin.Testing.Check_Equal
        (Item, Unbounded.To_String (Problem), "",
         "an emulator that keeps to Linux's record runs the lane");

      Probe (3, Problem);
      declare
         Said : constant String := Unbounded.To_String (Problem);
      begin
         Landin.Testing.Check
           (Item,
            Ada.Strings.Fixed.Index (Said, "qemu-riscv64 is refused") = 1
            and then Ada.Strings.Fixed.Index
              (Said, "(qemu-riscv64 version 8.2.2 (Debian") > 0
            and then Ada.Strings.Fixed.Index
              (Said, "past Linux's 24-byte sigaction record") > 0
            and then Ada.Strings.Fixed.Index (Said, ".#qemu-user") > 0,
            "a known-bad emulator is refused by name, version and reason: "
            & Said);
      end;

      Probe (139, Problem);
      Landin.Testing.Check
        (Item,
         Ada.Strings.Fixed.Index
           (Unbounded.To_String (Problem), "status 139") > 0,
         "an emulator that cannot run the probe at all is refused too: "
         & Unbounded.To_String (Problem));

      Probe (0, Problem, Linked => 1);
      Landin.Testing.Check
        (Item,
         Ada.Strings.Fixed.Index
           (Unbounded.To_String (Problem), "could not link the runner probe")
         > 0,
         "a probe the driver cannot link says so");
   end A_Known_Bad_Runner_Is_Refused;

   --  Whether the lane's processor has every feature of a level of its
   --  family.  The flags are the kernel's names, which are the feature
   --  names of D255 but for `cx16`, `lahf_lm`, `pni` for SSE3 and `abm` for
   --  LZCNT on x86-64, and `atomics` for LSE and `asimdrdm` for RDM on
   --  arm64.  A level nothing confirmed is unverified, never inferred from
   --  the default's run or from another target's lane.
   function Host_Has_Level
     (Level : String; Missing : out Unbounded.Unbounded_String)
      return Boolean;

   function Host_Has_Level
     (Level : String; Missing : out Unbounded.Unbounded_String)
      return Boolean
   is
      package L renames Landin.Targets.Levels;
      Selected : constant L.Feature_Level :=
        L.Level_Named (Lanes.Target, Level);
   begin
      Missing := Unbounded.Null_Unbounded_String;
      if not Processor_Asked then
         raise Compiler_Defect
           with "a level was run before the lane's processor was asked";
      elsif Unbounded.Length (Processor_Problem) > 0 then
         Missing := Processor_Problem;
         return False;
      end if;
      for Each in L.Feature loop
         if L.Has (Selected, Each) then
            declare
               Kernel : constant String :=
                 (case Each is
                     when L.Cmpxchg16b => "cx16",
                     when L.Lahf       => "lahf_lm",
                     when L.Sse3       => "pni",
                     when L.Lzcnt      => "abm",
                     when L.Lse        => "atomics",
                     when L.Rdm        => "asimdrdm",
                     when others       => L.Spelling (Each));
            begin
               if Unbounded.Index (Processor_Flags, " " & Kernel & " ") = 0
               then
                  Unbounded.Append (Missing, " " & L.Spelling (Each));
               end if;
            end;
         end if;
      end loop;
      if Unbounded.Length (Missing) > 0 then
         Missing := Unbounded.To_Unbounded_String
           (Unbounded.To_String (Processor_Source) & " lacks"
            & Unbounded.To_String (Missing));
         return False;
      end if;
      return True;
   end Host_Has_Level;

   --  Say on standard error which levels the lane's processor confirmed and
   --  from where.  Not in the transcript, which is the same on every host
   --  that runs a lane; a processor's feature list is not.
   procedure Report_Levels (Levels : Landin.Platform.Path_List);

   procedure Report_Levels (Levels : Landin.Platform.Path_List) is
      Missing : Unbounded.Unbounded_String;
   begin
      for Level of Levels loop
         if Host_Has_Level (Level, Missing) then
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "landin_tests: " & Lanes.Target_Name & " " & Level
               & " confirmed by " & Unbounded.To_String (Processor_Source));
         else
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "landin_tests: " & Lanes.Target_Name & " " & Level
               & " UNVERIFIED: " & Unbounded.To_String (Missing));
         end if;
      end loop;
   end Report_Levels;

   --  A compiled program reads the file `stdin:` names, below its fixture
   --  DIRECTORY, as its standard input, and an empty one when the fixture
   --  names none: never the harness's own, which may be a terminal that
   --  would hold the run until its time limit.
   procedure Feed_Standard_Input
     (Runner    : in out Landin.Platform.Native.Tools.Native_Tool_Runner;
      Case_Item : Fixture;
      Directory : String);

   procedure Feed_Standard_Input
     (Runner    : in out Landin.Platform.Native.Tools.Native_Tool_Runner;
      Case_Item : Fixture;
      Directory : String) is
   begin
      Runner.Set_Input
        (if Standard_Input (Case_Item) = "" then "/dev/null"
         else Directory & "/" & Standard_Input (Case_Item));
   end Feed_Standard_Input;

   --  Build each of the fixture's `c-shared` sources, below its fixture
   --  DIRECTORY, into a shared object of its own beside BUILT with the
   --  lane's C driver, and hand back their paths, which the program is
   --  given first among its arguments.  An ELF object may leave a symbol
   --  for the loader to find in another object; a Darwin one is linked to
   --  do the same, with `-undefined dynamic_lookup`.
   procedure Build_Shared_Objects
     (Case_Item : Fixture;
      Host      : Landin.Platform.Filesystem'Class;
      Directory : String;
      Built     : String;
      Label     : String;
      Item      : in out Landin.Testing.Context;
      Objects   : out Landin.Platform.Path_List;
      Ready     : out Boolean);

   procedure Build_Shared_Objects
     (Case_Item : Fixture;
      Host      : Landin.Platform.Filesystem'Class;
      Directory : String;
      Built     : String;
      Label     : String;
      Item      : in out Landin.Testing.Context;
      Objects   : out Landin.Platform.Path_List;
      Ready     : out Boolean)
   is
      Facts  : constant Landin.Targets.Target_Facts := Lanes.Target;
      Darwin : constant Boolean :=
        Landin.Targets.Capabilities.Hosted_System_Of (Facts)
          = Landin.Targets.Capabilities.Darwin;
      Driver : constant String :=
        Landin.Backend.Toolchain.Driver_For (Facts, Lanes.Toolchain);
      Rest   : constant String := C_Shared (Case_Item);
      First  : Integer := Rest'First;
      Runner : Landin.Platform.Native.Tools.Native_Tool_Runner;

      procedure Build_One (Named : String);

      procedure Build_One (Named : String) is
         Source : constant String :=
           Ada.Strings.Fixed.Trim (Named, Ada.Strings.Both);
         Object : constant String :=
           Built & "-" & Shared_Stem (Source)
           & (if Darwin then ".dylib" else ".so");
         Args   : Landin.Platform.Path_List;
         Built_One : Boolean;
      begin
         if not Ready or else Source = "" then
            return;
         end if;
         Landin.Platform.Add (Args, Directory & "/" & Source);
         Landin.Platform.Add (Args, "-std=c11");
         Landin.Platform.Add (Args, "-Wall");
         Landin.Platform.Add (Args, "-Wextra");
         Landin.Platform.Add (Args, "-Werror");
         Landin.Platform.Add (Args, "-fPIC");
         if Darwin then
            Landin.Platform.Add (Args, "-dynamiclib");
            Landin.Platform.Add (Args, "-Wl,-undefined,dynamic_lookup");
         else
            Landin.Platform.Add (Args, "-shared");
         end if;
         Landin.Platform.Add (Args, "-o");
         Landin.Platform.Add (Args, Object);
         Produce_Output
           (Host, Runner, Driver, Label & " shared " & Source, Object,
            Args, Item, Built_One);
         Ready := Built_One;
         Objects.Append (Object);
      end Build_One;
   begin
      Objects.Clear;
      Ready := True;
      if Rest = "" then
         return;
      end if;
      if Driver = "" then
         Landin.Testing.Fail
           (Item, Label & ": " & Landin.Targets.Name (Facts)
            & " names no C toolchain driver for its shared objects");
         Ready := False;
         return;
      end if;
      for Index in Rest'Range loop
         if Rest (Index) = ',' then
            Build_One (Rest (First .. Index - 1));
            First := Index + 1;
         end if;
      end loop;
      if First <= Rest'Last then
         Build_One (Rest (First .. Rest'Last));
      end if;
   end Build_Shared_Objects;

   procedure Run_Runtime
     (Case_Item : Fixture;
      Host      : Landin.Platform.Filesystem'Class;
      Program   : String;
      Profile   : Positive;
      Item      : in out Landin.Testing.Context;
      Level     : String := "");

   procedure Run_Runtime
     (Case_Item : Fixture;
      Host      : Landin.Platform.Filesystem'Class;
      Program   : String;
      Profile   : Positive;
      Item      : in out Landin.Testing.Context;
      Level     : String := "")
   is
      At_Level : constant String :=
        (if Level = "" then "" else " at " & Level);
      Label   : constant String := "runtime/" & Name (Case_Item)
        & " [" & Profile_Name (Profile) & At_Level & "]";
      Built   : constant String :=
        Output_Directory & "runtime-" & Name (Case_Item)
        & "-" & Profile_Name (Profile)
        & (if Level = "" then "" else "-" & Level);
      Runner  : Landin.Platform.Native.Tools.Native_Tool_Runner;
      Ready   : Boolean;
      Outcome : Landin.Platform.Tool_Result;
      Args    : Landin.Platform.Path_List;
      Runtime_Arguments : Landin.Platform.Path_List;
      Expected : Unbounded.Unbounded_String;
      Read     : Landin.Platform.Read_Status;
      Said     : Unbounded.Unbounded_String;
   begin
      if Level /= "" then
         declare
            Missing : Unbounded.Unbounded_String;
         begin
            if not Host_Has_Level (Level, Missing) then
               Landin.Testing.Fail
                 (Item, Label & ": UNVERIFIED, not run: "
                  & Unbounded.To_String (Missing));
               return;
            end if;
         end;
      end if;

      Append_Module_Arguments (Case_Item, Fixture_Root, Args);

      Append_Profile (Args, Profile);
      if Level /= "" then
         Landin.Platform.Add (Args, "--level=" & Level);
      end if;
      Landin.Platform.Add (Args, "--emit=exe");
      if Link_Mode (Case_Item) /= ""
        and then Landin.Targets.Capabilities.Hosted_System_Of (Lanes.Target)
          /= Landin.Targets.Capabilities.No_Hosted_System
      then
         Landin.Platform.Add (Args, "--link=" & Link_Mode (Case_Item));
      end if;
      Landin.Platform.Add (Args, "-o");
      Landin.Platform.Add (Args, Built);
      if Lanes.Toolchain /= "" then
         Landin.Platform.Add (Args, "--toolchain=" & Lanes.Toolchain);
      end if;

      Produce_Output
        (Host, Runner, Program, Label, Built, Lane_Arguments (Args), Item,
         Ready, Said);
      if Ready then
         Check_Accepted_Report
           (Case_Item, Label, Unbounded.To_String (Said), Item);

         --  The executable is held to the level it was built for: its GNU
         --  property note names that level as needed, which is also what
         --  makes the loader refuse it on a processor without it.  This is
         --  the image that then runs, so the lowering is shown to have
         --  reached the bytes, not only the assembly text.  An arm64
         --  executable carries no note, so its image is held to holding
         --  the level's instructions and not the default's sequence, and
         --  the default's image of a fixture that names a level is held to
         --  holding none of them.  Linux's and Darwin's arm64 alike: the
         --  architecture picks the inspection, never the host, since a
         --  Mac has objdump and no readelf.
         if Landin.Targets.Architecture_Of (Lanes.Target)
              = Landin.Targets.Arm64
           and then (Level /= "" or else not Lane_Levels (Case_Item).Is_Empty)
         then
            Check_Arm64_Level (Built, Label, Level /= "", Item);
         elsif Lanes.Target_Name = "linux-rv64" and then Level /= "" then
            Check_RV64_Level (Built, Label, Level, Item);
         elsif Level /= "" then
            declare
               Note : Landin.Platform.Tool_Result;
               Args : Landin.Platform.Path_List;
            begin
               Args.Append ("-n");
               Args.Append (Built);
               Runner.Run ("readelf", Args, Note, Landin.Platform.Merged);
               --  The C runtime's objects add the baseline to a libc
               --  link's note; a static link has none of them.  The
               --  static image carries the note all the same, though no
               --  loader reads it: platform/linux's entry is what refuses
               --  a processor below the level there.
               Landin.Testing.Check
                 (Item, Ada.Strings.Fixed.Index
                    (Unbounded.To_String (Note.Output),
                     "x86 ISA needed: x86-64-baseline, " & Level) > 0
                  or else Ada.Strings.Fixed.Index
                    (Unbounded.To_String (Note.Output),
                     "x86 ISA needed: " & Level & ASCII.LF) > 0,
                  Label & ": the executable needs " & Level);
            end;
         end if;
         declare
            Objects : Landin.Platform.Path_List;
            Shared  : Boolean;
         begin
            Build_Shared_Objects
              (Case_Item, Host, Fixture_Root & "/runtime/" & Name (Case_Item),
               Built, Label, Item, Objects, Shared);
            if not Shared then
               return;
            end if;
            Runtime_Arguments := Objects;
            Append_Program_Arguments
              (Case_Item, Fixture_Root & "/runtime/" & Name (Case_Item),
               Runtime_Arguments);
         end;
         Feed_Standard_Input
           (Runner, Case_Item, Fixture_Root & "/runtime/" & Name (Case_Item));
         Run_With_Stream
           (Case_Item, Label, Runner, Built, Runtime_Arguments, Outcome, Item,
            Compiled => True);

         if Outcome.Ended = Landin.Platform.Timed_Out then
            Landin.Testing.Fail
              (Item, Label & ": the program exceeded its execution time limit"
               & ASCII.LF & Unbounded.To_String (Outcome.Output));
         else
            if Run_Expect (Case_Item) /= "" then
               Host.Read_File
                 (Fixture_Root & "/runtime/" & Name (Case_Item) & "/"
                  & Run_Expect (Case_Item), Expected, Read);
               if Read /= Landin.Platform.Read_Ok then
                  Landin.Testing.Fail
                    (Item, Label & ": runtime expectation is unreadable ("
                     & Landin.Platform.Read_Status'Image (Read) & ")");
               else
                  Check_Output
                    (Case_Item, Label, Outcome,
                     Unbounded.To_String (Expected), Item);
               end if;
            end if;

            if Traps (Case_Item) then
               Landin.Testing.Check
                 (Item,
                  Satisfies_Termination_Expectation
                    (Outcome.Ended, Traps => True),
                  Label & ": the program trapped rather than returning a"
                  & " status");
               if Trap_Report (Case_Item) /= "" then
                  Landin.Testing.Check
                    (Item,
                     Reports_Trap
                       (Unbounded.To_String (Outcome.Output)
                        & Unbounded.To_String (Outcome.Error_Output),
                        Trap_Report (Case_Item)),
                     Label & ": no line `" & Trap_Report (Case_Item)
                     & "` was written; the program wrote: "
                     & Unbounded.To_String (Outcome.Output)
                     & Unbounded.To_String (Outcome.Error_Output));
               end if;
            else
               Landin.Testing.Check
                 (Item,
                  Satisfies_Termination_Expectation
                    (Outcome.Ended, Traps => False),
                  Label & ": the program returned a status");
               if Outcome.Ended = Landin.Platform.Exited then
                  Landin.Testing.Check_Equal
                    (Item, Outcome.Exit_Code, Status_At (Case_Item, Level),
                     Label & ": the program's own exit status");
               end if;
            end if;
         end if;
      end if;
   end Run_Runtime;

   --  ABI fixtures deliberately stop refine at assembly.  Their C sources
   --  belong to this repository-owned test harness, not to a product C-input
   --  adapter, and the target-selected driver receives each one as its own
   --  argument-vector element.
   procedure Run_ABI
     (Case_Item : Fixture;
      Host      : Landin.Platform.Filesystem'Class;
      Program   : String;
      Profile   : Positive;
      Item      : in out Landin.Testing.Context);

   procedure Run_ABI
     (Case_Item : Fixture;
      Host      : Landin.Platform.Filesystem'Class;
      Program   : String;
      Profile   : Positive;
      Item      : in out Landin.Testing.Context)
   is
      Label     : constant String := "abi/" & Name (Case_Item)
        & " [" & Profile_Name (Profile) & "]";
      Directory : constant String := Fixture_Root & "/abi/" & Name (Case_Item);
      Assembly  : constant String :=
        Output_Directory & "abi-" & Name (Case_Item)
        & "-" & Profile_Name (Profile) & ".s";
      Built     : constant String :=
        Output_Directory & "abi-" & Name (Case_Item)
        & "-" & Profile_Name (Profile);
      Facts     : constant Landin.Targets.Target_Facts := Lanes.Target;
      Driver    : constant String :=
        Landin.Backend.Toolchain.Driver_For (Facts, Lanes.Toolchain);
      Runner    : Landin.Platform.Native.Tools.Native_Tool_Runner;
      Ready     : Boolean;
      Said      : Unbounded.Unbounded_String;
      Outcome   : Landin.Platform.Tool_Result;
      Refine_Arguments : Landin.Platform.Path_List;
      Driver_Arguments : Landin.Platform.Path_List;
      Runtime_Arguments : Landin.Platform.Path_List;
      Expected  : Unbounded.Unbounded_String;
      Read      : Landin.Platform.Read_Status;
   begin
      Append_Module_Arguments
        (Case_Item, Fixture_Root, Refine_Arguments);

      Landin.Platform.Add
        (Refine_Arguments, "--target=" & Landin.Targets.Name (Facts));
      Append_Profile (Refine_Arguments, Profile);
      Landin.Platform.Add (Refine_Arguments, "--emit=asm");
      --  The C driver below links the assembly with its C peers and with
      --  the C runtime, which starts the program: the libc link mode.
      if Landin.Targets.Capabilities.Hosted_System_Of (Facts)
        /= Landin.Targets.Capabilities.No_Hosted_System
      then
         Landin.Platform.Add (Refine_Arguments, "--link=libc");
      end if;
      Landin.Platform.Add (Refine_Arguments, "-o");
      Landin.Platform.Add (Refine_Arguments, Assembly);

      Produce_Output
        (Host, Runner, Program, Label & " assembly", Assembly,
         Refine_Arguments, Item, Ready, Said);
      if not Ready then
         return;
      end if;
      Check_Accepted_Report
        (Case_Item, Label, Unbounded.To_String (Said), Item);

      Landin.Platform.Add (Driver_Arguments, Assembly);
      declare
         Rest  : constant String := C_Sources (Case_Item);
         First : Integer := Rest'First;

         procedure Add_One (Named : String);

         procedure Add_One (Named : String) is
            Trimmed : constant String :=
              Ada.Strings.Fixed.Trim (Named, Ada.Strings.Both);
         begin
            if Trimmed /= "" then
               Landin.Platform.Add
                 (Driver_Arguments, Directory & "/" & Trimmed);
            end if;
         end Add_One;
      begin
         for Index in Rest'Range loop
            if Rest (Index) = ',' then
               Add_One (Rest (First .. Index - 1));
               First := Index + 1;
            end if;
         end loop;

         if First <= Rest'Last then
            Add_One (Rest (First .. Rest'Last));
         end if;
      end;

      Landin.Platform.Add (Driver_Arguments, "-std=c11");
      Landin.Platform.Add (Driver_Arguments, "-Wall");
      Landin.Platform.Add (Driver_Arguments, "-Wextra");
      Landin.Platform.Add (Driver_Arguments, "-Werror");
      --  x86-64's emitted code addresses data RIP-relative and absolute
      --  alike; arm64's is position-independent, as the driver defaults.
      if Landin.Targets.Architecture_Of (Facts) = Landin.Targets.X86_64 then
         Landin.Platform.Add (Driver_Arguments, "-no-pie");
      end if;
      declare
         Options : constant Landin.Platform.Path_List :=
           Split (C_Args (Case_Item));
      begin
         for Argument of Options loop
            Landin.Platform.Add (Driver_Arguments, Argument);
         end loop;
      end;
      Landin.Platform.Add (Driver_Arguments, "-o");
      Landin.Platform.Add (Driver_Arguments, Built);

      if Driver = "" then
         Landin.Testing.Fail
           (Item, Label & ": " & Landin.Targets.Name (Facts)
            & " names no C toolchain driver");
         return;
      end if;

      Produce_Output
        (Host, Runner, Driver, Label & " C link", Built,
         Driver_Arguments, Item, Ready);
      if Ready then
         declare
            Objects : Landin.Platform.Path_List;
            Shared  : Boolean;
         begin
            Build_Shared_Objects
              (Case_Item, Host, Directory, Built, Label, Item, Objects,
               Shared);
            if not Shared then
               return;
            end if;
            Runtime_Arguments := Objects;
            Append_Program_Arguments
              (Case_Item, Directory, Runtime_Arguments);
         end;
         Feed_Standard_Input (Runner, Case_Item, Directory);
         Run_With_Stream
           (Case_Item, Label, Runner, Built, Runtime_Arguments, Outcome, Item,
            Compiled => True);

         if Outcome.Ended = Landin.Platform.Timed_Out then
            Landin.Testing.Fail
              (Item, Label & ": the program exceeded its execution time limit"
               & ASCII.LF & Unbounded.To_String (Outcome.Output));
         else
            if Run_Expect (Case_Item) /= "" then
               Host.Read_File
                 (Directory & "/" & Run_Expect (Case_Item), Expected, Read);
               if Read /= Landin.Platform.Read_Ok then
                  Landin.Testing.Fail
                    (Item, Label & ": runtime expectation is unreadable ("
                     & Landin.Platform.Read_Status'Image (Read) & ")");
               else
                  Check_Output
                    (Case_Item, Label, Outcome,
                     Unbounded.To_String (Expected), Item);
               end if;
            end if;

            if Traps (Case_Item) then
               Landin.Testing.Check
                 (Item,
                  Satisfies_Termination_Expectation
                    (Outcome.Ended, Traps => True),
                  Label & ": the program trapped rather than returning a"
                  & " status");
            else
               Landin.Testing.Check
                 (Item,
                  Satisfies_Termination_Expectation
                    (Outcome.Ended, Traps => False),
                  Label & ": the program returned a status");
               if Outcome.Ended = Landin.Platform.Exited then
                  Landin.Testing.Check_Equal
                    (Item, Outcome.Exit_Code, Status (Case_Item),
                     Label & ": the program's own exit status");
               end if;
            end if;
         end if;
      end if;
   end Run_ABI;

   --  D255: the assembler is held to the build's level, the default
   --  included, so an assembly block can use no instruction the level does
   --  not have.  On the lane's own toolchain a block naming an instruction
   --  of a higher level -- BMI2's `shlx` on x86-64, LSE's `ldaddal` on arm64
   --  -- is refused by the assembler at every level below the one that adds
   --  it, the default unnamed and named, and assembles at that level.  The
   --  accepted build runs only where the lane's processor confirms the
   --  level; anywhere else its run is unverified.
   procedure An_Assembly_Block_Is_Held_To_Its_Level
     (Item : in out Landin.Testing.Context);

   procedure An_Assembly_Block_Is_Held_To_Its_Level
     (Item : in out Landin.Testing.Context)
   is
      Host   : Landin.Platform.Native.Native_Filesystem;
      Runner : Landin.Platform.Native.Tools.Native_Tool_Runner;
      LF     : constant String := [ASCII.LF];
      Is_X86 : constant Boolean :=
        Landin.Targets.Architecture_Of (Lanes.Target)
          = Landin.Targets.X86_64;
      Is_RV64 : constant Boolean :=
        Landin.Targets.Architecture_Of (Lanes.Target)
          = Landin.Targets.RV64;
      --  Labelled as a runtime program, which it is: a lane with no driver
      --  refuses it exactly as it refuses every runtime fixture.
      Name   : constant String := "runtime/assembly-held-to-its-level";
      File   : constant String := "assembly-held-to-its-level";
      Source : constant String := Output_Directory & File & ".ldn";
      Block  : constant String :=
        (if Is_X86
         then "    r = assembler.block(""shlxq {b}, {a}, {a}""," & LF
              & "        inout a: u64 at general = value," & LF
              & "        in b: u64 at general = 1)" & LF
         elsif Is_RV64
         then "    r = assembler.block(""th.addsl {r}, {a}, {a}, 0""," & LF
              & "        out r: u64 at general," & LF
              & "        in a: u64 at general = value)" & LF
         else "    r = assembler.block(""ldaddal {a}, {a}, [{p}]""," & LF
              & "        inout a: u64 at general = value," & LF
              & "        in p: usize at general = usize(addr cell))" & LF
              & "    r = r + cell - value" & LF);
      Program : constant String :=
        "mut cell: u64 = 21" & LF
        & "doubled: (value: u64) -> (r: u64) =" & LF
        & Block
        & "end doubled" & LF
        & "public main: () -> (code: i32) =" & LF
        & "    code = i32(doubled(21))" & LF
        & "end main" & LF;
      Instruction : constant String :=
        (if Is_X86 then "shlx" elsif Is_RV64 then "th.addsl" else "ldaddal");
      Refusal : constant String :=
        (if Is_X86 then "`shlx' is not supported on"
         elsif Is_RV64 then "xtheadba"
         else "selected processor does not support `ldaddal");
      --  The levels below the one that adds the instruction: the default
      --  unnamed, then each named.  arm64 has one, so it is named once;
      --  RV64's baseline and its other extension both lack T-Head's.
      Below_Count : constant Positive := (if Is_X86 or Is_RV64 then 3 else 2);

      function Below (Each : Positive) return String
        is (if Each = 1 then ""
            elsif Is_X86 then (if Each = 2 then "x86-64-v1" else "x86-64-v2")
            elsif Is_RV64 then (if Each = 2 then "rv64gc" else "rv64gc_zba")
            else "armv8-a");

      Level : constant String :=
        (if Is_X86 then "x86-64-v3"
         elsif Is_RV64 then "rv64gc_xtheadba" else "armv8.1-a");
      Written : Landin.Platform.Write_Status;

      function Build (At_Level, Built : String)
        return Landin.Platform.Tool_Result;

      function Build (At_Level, Built : String)
        return Landin.Platform.Tool_Result
      is
         Args : Landin.Platform.Path_List;
         Removed : Landin.Platform.Remove_Status;
         Outcome : Landin.Platform.Tool_Result;
      begin
         Host.Remove_File (Built, Removed);
         if At_Level /= "" then
            Args.Append ("--level=" & At_Level);
         end if;
         Args.Append ("--emit=exe");
         Args.Append ("-o");
         Args.Append (Built);
         if Lanes.Toolchain /= "" then
            Args.Append ("--toolchain=" & Lanes.Toolchain);
         end if;
         Args.Append (Source);
         Runner.Run
           (Refine_Path, Lane_Arguments (Args), Outcome,
            Landin.Platform.Merged);
         return Outcome;
      end Build;
   begin
      if Landin.Targets.Capabilities.Hosted_System_Of (Lanes.Target)
        = Landin.Targets.Capabilities.No_Hosted_System
      then
         Landin.Testing.Fail
           (Item, Lanes.Target_Name & " links no hosted program to hold");
         return;
      end if;
      Host.Write_File (Source, Program, Written);
      if Written /= Landin.Platform.Write_Ok then
         Landin.Testing.Fail (Item, Name & ": the source was not written");
         return;
      end if;

      --  The accepted build goes through the runtime fixtures' own producer,
      --  so a lane with no driver refuses it as it refuses theirs.
      declare
         Label : constant String := Name & " [at " & Level & "]";
         Built : constant String := Output_Directory & File & "-" & Level;
         Args : Landin.Platform.Path_List;
         Ready : Boolean;
         Missing : Unbounded.Unbounded_String;
         Ran : Landin.Platform.Tool_Result;
      begin
         Args.Append ("--level=" & Level);
         Args.Append ("--emit=exe");
         Args.Append ("-o");
         Args.Append (Built);
         if Lanes.Toolchain /= "" then
            Args.Append ("--toolchain=" & Lanes.Toolchain);
         end if;
         Args.Append (Source);
         Produce_Output
           (Host, Runner, Refine_Path, Label, Built, Lane_Arguments (Args),
            Item, Ready);
         if not Ready then
            return;
         end if;
         Ask_Lane_Processor (Host);
         if not Host_Has_Level (Level, Missing) then
            Landin.Testing.Fail
              (Item, Label & ": UNVERIFIED, not run: "
               & Unbounded.To_String (Missing));
            return;
         end if;
         Run_Program
           (Runner, Built, Landin.Platform.No_Arguments, Ran,
            Landin.Platform.Merged);
         Landin.Testing.Check
           (Item, Ran.Ended = Landin.Platform.Exited
              and then Ran.Exit_Code = 42,
            Label & ": the block runs" & LF
            & Unbounded.To_String (Ran.Output));
      end;

      --  Only then the refusals, which need the driver that just linked.
      for Each in 1 .. Below_Count loop
         declare
            Below_Level : constant String := Below (Each);
            Label : constant String :=
              Name & (if Each = 1 then " [at the default]"
                      else " [at an explicit " & Below_Level & "]");
            Built : constant String :=
              Output_Directory & File & "-below-" & Natural'Image (Each)(2);
            Outcome : constant Landin.Platform.Tool_Result :=
              Build (Below_Level, Built);
            Said : constant String := Unbounded.To_String (Outcome.Output);
         begin
            Landin.Testing.Check
              (Item, Outcome.Ended = Landin.Platform.Exited
                 and then Outcome.Exit_Code = 1
                 and then Ada.Strings.Fixed.Index (Said, "error[L0501]") > 0
                 and then Ada.Strings.Fixed.Index (Said, Refusal) > 0
                 and then not Host.Exists (Built),
               Label & ": the assembler refuses " & Instruction & LF & Said);
         end;
      end loop;
   end An_Assembly_Block_Is_Held_To_Its_Level;

   --  What a cross lane's emulator fails for a reason of its own.
   --
   --  QEMU's user emulation is not Linux on the lane's processor: it
   --  answers getsockopt(SO_RCVTIMEO) with a zero-length record, runs
   --  another architecture's executable started from inside it only
   --  through a binfmt_misc handler, and so on.  A fixture meeting one of
   --  those fails on every run of the lane, and with nothing saying so a
   --  regression could be told apart only by building an unchanged
   --  compiler and running again.  compiler/tests/cross-lanes.json lists
   --  each one: the fixture, the runners it fails under, the failure lines
   --  it fails with, and why.  A listed fixture whose every failure is one
   --  of its lines is an expected host failure, reported on standard error
   --  and not counted; any other failure of it is reported as a failure,
   --  and one that passes fails too, because its row is then stale.  A row
   --  that needs no binfmt_misc handler does not apply where one is
   --  registered for the runner.  Native lanes read none of it.
   Cross_Lanes_Record : constant String := "../tests/cross-lanes.json";

   type Host_Failure is record
      Fixture  : Unbounded.Unbounded_String;
      Runners  : Landin.Platform.Path_List;
      Failures : Landin.Platform.Path_List;
      Reason   : Unbounded.Unbounded_String;
      Binfmt   : Boolean := False;
   end record;

   package Host_Failure_Vectors is new Ada.Containers.Vectors
     (Positive, Host_Failure);

   Host_Failures : Host_Failure_Vectors.Vector;

   --  The runner's own name, without the directory a path gives it.
   function Runner_Name return String;

   function Runner_Name return String is
      Text : constant String := Lanes.Runner;
      First : Positive := Text'First;
   begin
      for Index in Text'Range loop
         if Text (Index) = '/' then
            First := Index + 1;
         end if;
      end loop;
      return Text (First .. Text'Last);
   end Runner_Name;

   --  Whether a binfmt_misc handler runs the runner's architecture: by
   --  Debian's name for it, qemu-aarch64, or NixOS's, aarch64-linux.
   function Binfmt_Registered
     (Host : Landin.Platform.Filesystem'Class) return Boolean;

   function Binfmt_Registered
     (Host : Landin.Platform.Filesystem'Class) return Boolean
   is
      Name : constant String := Runner_Name;
      Handlers : constant String := "/proc/sys/fs/binfmt_misc/";
   begin
      return Host.Exists (Handlers & Name)
        or else (Name'Length > 5
                 and then Name (Name'First .. Name'First + 4) = "qemu-"
                 and then Host.Exists
                   (Handlers & Name (Name'First + 5 .. Name'Last)
                    & "-linux"));
   end Binfmt_Registered;

   --  Reads the record into Host_Failures, keeping the rows that apply to
   --  this lane's runner.  A record that cannot be read is a failure.
   procedure Load_Host_Failures
     (Host : Landin.Platform.Filesystem'Class;
      Item : in out Landin.Testing.Context);

   procedure Load_Host_Failures
     (Host : Landin.Platform.Filesystem'Class;
      Item : in out Landin.Testing.Context)
   is
      Text : Unbounded.Unbounded_String;
      Read : Landin.Platform.Read_Status;
      Record_Document : Landin.Json.Document;
      Registered : constant Boolean := Binfmt_Registered (Host);

      function Strings
        (Within : Landin.Json.Value) return Landin.Platform.Path_List;

      function Strings
        (Within : Landin.Json.Value) return Landin.Platform.Path_List
      is
         Result : Landin.Platform.Path_List;
      begin
         if Landin.Json.Is_Kind
           (Record_Document, Within, Landin.Json.Array_Value)
         then
            for Position in 1 .. Landin.Json.Length (Record_Document, Within)
            loop
               declare
                  One : constant Landin.Json.Value := Landin.Json.Element
                    (Record_Document, Within, Position);
               begin
                  if Landin.Json.Is_Kind
                    (Record_Document, One, Landin.Json.String_Value)
                  then
                     Result.Append (Landin.Json.Text (Record_Document, One));
                  end if;
               end;
            end loop;
         end if;
         return Result;
      end Strings;
   begin
      Host_Failures.Clear;
      if Lanes.Is_Native or else Lanes.Runner = "" then
         return;
      end if;
      Host.Read_File (Cross_Lanes_Record, Text, Read);
      if Read /= Landin.Platform.Read_Ok then
         Landin.Testing.Fail (Item, Cross_Lanes_Record & " is unreadable");
         return;
      end if;
      Landin.Json.Parse (Record_Document, Unbounded.To_String (Text));
      if not Landin.Json.Ok (Record_Document) then
         Landin.Testing.Fail
           (Item, Cross_Lanes_Record & " is not JSON: "
            & Landin.Json.Fault (Record_Document));
         return;
      end if;
      declare
         Rows : constant Landin.Json.Value := Landin.Json.Member
           (Record_Document, Landin.Json.Root (Record_Document), "expected");
      begin
         if not Landin.Json.Is_Kind
           (Record_Document, Rows, Landin.Json.Array_Value)
         then
            Landin.Testing.Fail
              (Item, Cross_Lanes_Record & " has no ""expected"" list");
            return;
         end if;
         for Position in 1 .. Landin.Json.Length (Record_Document, Rows) loop
            declare
               Row : constant Landin.Json.Value :=
                 Landin.Json.Element (Record_Document, Rows, Position);
               Fixture_Value : constant Landin.Json.Value :=
                 Landin.Json.Member (Record_Document, Row, "fixture");
               Reason_Value : constant Landin.Json.Value :=
                 Landin.Json.Member (Record_Document, Row, "reason");
               One : Host_Failure;
            begin
               if not Landin.Json.Is_Kind
                   (Record_Document, Fixture_Value, Landin.Json.String_Value)
                 or else not Landin.Json.Is_Kind
                   (Record_Document, Reason_Value, Landin.Json.String_Value)
               then
                  Landin.Testing.Fail
                    (Item, Cross_Lanes_Record & ": row" & Position'Image
                     & " needs a fixture and a reason");
                  return;
               end if;
               One.Fixture := Unbounded.To_Unbounded_String
                 (Landin.Json.Text (Record_Document, Fixture_Value));
               One.Reason := Unbounded.To_Unbounded_String
                 (Landin.Json.Text (Record_Document, Reason_Value));
               One.Runners := Strings
                 (Landin.Json.Member (Record_Document, Row, "runners"));
               One.Failures := Strings
                 (Landin.Json.Member (Record_Document, Row, "failures"));
               One.Binfmt := Landin.Json.Is_Kind
                 (Record_Document,
                  Landin.Json.Member (Record_Document, Row, "needs_binfmt"),
                  Landin.Json.True_Value);
               if One.Failures.Is_Empty then
                  Landin.Testing.Fail
                    (Item, Cross_Lanes_Record & ": "
                     & Unbounded.To_String (One.Fixture)
                     & " lists no failure lines");
               elsif One.Runners.Contains (Runner_Name)
                 and then not (One.Binfmt and then Registered)
               then
                  Host_Failures.Append (One);
               end if;
            end;
         end loop;
      end;
   end Load_Host_Failures;

   --  The row for a fixture under this lane's runner, or 0.
   function Host_Failure_Of (Fixture_Name : String) return Natural;

   function Host_Failure_Of (Fixture_Name : String) return Natural is
   begin
      for Index in 1 .. Natural (Host_Failures.Length) loop
         if Unbounded.To_String (Host_Failures.Element (Index).Fixture)
           = Fixture_Name
         then
            return Index;
         end if;
      end loop;
      return 0;
   end Host_Failure_Of;

   --  Whether every failure a listed fixture met is one of its row's lines.
   function Only_Listed_Failures
     (Row : Host_Failure; Local : Landin.Testing.Context) return Boolean;

   function Only_Listed_Failures
     (Row : Host_Failure; Local : Landin.Testing.Context) return Boolean
   is
      Text : constant String := Landin.Testing.Failure_Text (Local);
      Start : Positive := Text'First;
      Marker : constant String := "failed: ";
   begin
      while Start <= Text'Last loop
         declare
            Stop : Natural := Ada.Strings.Fixed.Index
              (Text (Start .. Text'Last), [1 => ASCII.LF]);
            Line : constant String :=
              Text (Start .. (if Stop = 0 then Text'Last else Stop - 1));
            Found : Boolean := False;
         begin
            if Ada.Strings.Fixed.Index (Line, Marker) > 0 then
               for Wanted of Row.Failures loop
                  Found := Found
                    or else Ada.Strings.Fixed.Index (Line, Wanted) > 0;
               end loop;
               if not Found then
                  return False;
               end if;
            end if;
            if Stop = 0 then
               Stop := Text'Last;
            end if;
            Start := Stop + 1;
         end;
      end loop;
      return True;
   end Only_Listed_Failures;

   procedure Runtime_Fixtures_Execute
     (Item : in out Landin.Testing.Context);

   procedure Runtime_Fixtures_Execute
     (Item : in out Landin.Testing.Context)
   is
      Host        : Landin.Platform.Native.Native_Filesystem;
      Found       : Catalogue;
      Program     : constant String := Refine_Path;
      Runtime_Ran : Natural := 0;
      ABI_Ran     : Natural := 0;
      Runtime_Profiles : Natural := 0;
      ABI_Profiles : Natural := 0;
   begin
      if not Host.Exists (Program) then
         Landin.Testing.Fail
           (Item,
            "refine was not found at " & Program
            & "; run the harness through scripts/test.sh");
         return;
      end if;

      Discover (Found, Fixture_Root, Host);
      Landin.Testing.Check_Equal
        (Item, Problem_Count (Found), 0, "runtime and ABI metadata is valid");
      if Problem_Count (Found) /= 0 then
         return;
      end if;

      if Lane_Runner_Problem (Host) /= "" then
         Landin.Testing.Fail (Item, Lane_Runner_Problem (Host));
         return;
      end if;

      declare
         type Piece_Kind is (Runtime_Piece, ABI_Piece);

         --  One piece of work per fixture, its profiles run in order inside
         --  it.  Every profile runs the same program, and a program may name
         --  a fixed file -- r480-hosted-text writes and removes one -- so two
         --  of its profiles on two workers would race on it.  Different
         --  fixtures still run in parallel.
         type Piece_Record is record
            Index   : Positive;
            Kind    : Piece_Kind;
         end record;

         type Piece_Array is array (Positive range <>) of Piece_Record;

         Work : Piece_Array
           (1 .. Count_Of (Found, Runtime) + Count_Of (Found, Abi));
         Last : Natural := 0;

         procedure Run_One
           (Piece : Piece_Record; Slot : in out Landin.Testing.Context);

         --  Which fixtures failed only as their cross-lanes row says, by
         --  fixture: each worker writes the fixtures of its own pieces.
         Expected_Seen : array (1 .. Count (Found)) of Natural :=
           [others => 0]
           with Independent_Components;

         procedure Run_One
           (Piece : Piece_Record; Slot : in out Landin.Testing.Context)
         is
            Case_Item : constant Fixture := Nth (Found, Piece.Index);
            Listed : constant Natural :=
              (if Piece.Kind = Runtime_Piece
               then Host_Failure_Of ("runtime/" & Name (Case_Item))
               else Host_Failure_Of ("abi/" & Name (Case_Item)));
            Local : Landin.Testing.Context;

            procedure Run_Profiles (Into : in out Landin.Testing.Context);

            procedure Run_Profiles (Into : in out Landin.Testing.Context) is
            begin
               for Profile in 1 .. Profile_Count (Case_Item) loop
                  case Piece.Kind is
                     when Runtime_Piece =>
                        Run_Runtime (Case_Item, Host, Program, Profile, Into);
                        for Level of Lane_Levels (Case_Item) loop
                           Run_Runtime
                             (Case_Item, Host, Program, Profile, Into,
                              Level);
                        end loop;
                     when ABI_Piece =>
                        Run_ABI (Case_Item, Host, Program, Profile, Into);
                  end case;
               end loop;
            end Run_Profiles;
         begin
            if Listed = 0 then
               Run_Profiles (Slot);
               return;
            end if;
            Run_Profiles (Local);
            declare
               Row : constant Host_Failure := Host_Failures.Element (Listed);
            begin
               if Landin.Testing.Failures (Local) = 0 then
                  Landin.Testing.Fail
                    (Slot, Unbounded.To_String (Row.Fixture)
                     & " passed under " & Runner_Name & ", which "
                     & Cross_Lanes_Record & " lists as failing there ("
                     & Unbounded.To_String (Row.Reason)
                     & "): remove the runner from its row, or the row");
               elsif Only_Listed_Failures (Row, Local) then
                  Landin.Testing.Check
                    (Slot, True, "an expected host failure");
                  Expected_Seen (Piece.Index) := Listed;
               else
                  Landin.Testing.Absorb (Slot, Local);
                  Landin.Testing.Fail
                    (Slot, Unbounded.To_String (Row.Fixture)
                     & " failed under " & Runner_Name & " otherwise than "
                     & Cross_Lanes_Record & " lists, so the failures above"
                     & " are not the host's ("
                     & Unbounded.To_String (Row.Reason) & ")");
               end if;
            end;
         end Run_One;

         procedure Run_Each is new Across_Workers
           (Element => Piece_Record,
            Element_Array => Piece_Array,
            Perform => Run_One);
      begin
         --  In corpus order.  The counters come from the collection rather
         --  than from the workers, so they say the same thing at any job
         --  count.
         for Index in 1 .. Count (Found) loop
            declare
               Case_Item : constant Fixture := Nth (Found, Index);
            begin
               if not In_Lane (Case_Item) then
                  null;
               elsif Class (Case_Item) = Runtime then
                  Runtime_Ran := Runtime_Ran + 1;
                  Last := Last + 1;
                  Work (Last) := (Index, Runtime_Piece);
                  Runtime_Profiles := Runtime_Profiles
                    + Profile_Count (Case_Item)
                      * (1 + Natural (Lane_Levels (Case_Item).Length));
               elsif Class (Case_Item) = Abi then
                  ABI_Ran := ABI_Ran + 1;
                  Last := Last + 1;
                  Work (Last) := (Index, ABI_Piece);
                  ABI_Profiles := ABI_Profiles + Profile_Count (Case_Item);
               end if;
            end;
         end loop;

         declare
            Levels : Landin.Platform.Path_List;
         begin
            for Piece of Work (1 .. Last) loop
               if Piece.Kind = Runtime_Piece then
                  for Level of Lane_Levels (Nth (Found, Piece.Index)) loop
                     if not Levels.Contains (Level) then
                        Levels.Append (Level);
                     end if;
                  end loop;
               end if;
            end loop;
            if not Levels.Is_Empty then
               Ask_Lane_Processor (Host);
               Report_Levels (Levels);
            end if;
         end;
         Load_Host_Failures (Host, Item);
         Run_Each (Work (1 .. Last), Item);
         for Index in Expected_Seen'Range loop
            if Expected_Seen (Index) /= 0 then
               Ada.Text_IO.Put_Line
                 (Ada.Text_IO.Standard_Error,
                  "landin_tests: expected host failure under "
                  & Runner_Name & ": "
                  & Unbounded.To_String
                      (Host_Failures.Element (Expected_Seen (Index)).Fixture)
                  & ": "
                  & Unbounded.To_String
                      (Host_Failures.Element (Expected_Seen (Index)).Reason));
            end if;
         end loop;
      end;

      --  And the lane's own assembler, held to the build's level.
      An_Assembly_Block_Is_Held_To_Its_Level (Item);

      Landin.Testing.Check_Equal
        (Item, Runtime_Ran,
         Count_Of (Found, Runtime, Lanes.Fixture_Label),
         "every runtime fixture of the lane was selected");
      Landin.Testing.Check_Equal
        (Item, ABI_Ran, Count_Of (Found, Abi, Lanes.Fixture_Label),
         "every ABI fixture of the lane was selected");
      Landin.Testing.Check_Equal
        (Item, Runtime_Profiles,
         Profile_Run_Count
           (Found, Runtime, Lanes.Target, Lanes.Fixture_Label),
         "every runtime profile was attempted");
      Landin.Testing.Check_Equal
        (Item, ABI_Profiles,
         Profile_Run_Count (Found, Abi, Lanes.Target, Lanes.Fixture_Label),
         "every ABI profile was attempted");
      Landin.Testing.Check
        (Item, Runtime_Ran > 0, "the runtime obligation remains present");
      --  [1630]'s audit: every hosted lane executes an assembly block whose
      --  operands are integers, so the lane runs that fixture or is red.
      Landin.Testing.Check
        (Item, (for some Index in 1 .. Count (Found) =>
                  Label_Of (Nth (Found, Index)) = "runtime/assembly-operands"
                  and then In_Lane (Nth (Found, Index))),
         "the lane executes an assembly block with integer operands");
      Landin.Testing.Check
        (Item, ABI_Ran > 0, "the ABI obligation remains present");
   end Runtime_Fixtures_Execute;

   procedure Selected_Fixture_Executes
     (Item : in out Landin.Testing.Context);

   procedure Selected_Fixture_Executes
     (Item : in out Landin.Testing.Context)
   is
      Host    : Landin.Platform.Native.Native_Filesystem;
      Found   : Catalogue;
      Program : constant String := Refine_Path;
      Wanted  : constant String := Unbounded.To_String (Selected);
      Ran     : Natural := 0;
   begin
      if not Host.Exists (Program) then
         Landin.Testing.Fail
           (Item,
            "refine was not found at " & Program
            & "; run the harness through scripts/test.sh");
         return;
      end if;

      Discover (Found, Fixture_Root, Host, Only => Wanted);
      Landin.Testing.Check_Equal
        (Item, Problem_Count (Found), 0,
         "the selected fixture metadata is valid");
      Landin.Testing.Check_Equal
        (Item, Count (Found), 1,
         Wanted & ": exactly one fixture was selected");

      if Problem_Count (Found) /= 0 or else Count (Found) /= 1 then
         return;
      end if;

      for Index in 1 .. Count (Found) loop
         declare
            Case_Item : constant Fixture := Nth (Found, Index);
         begin
            if Label_Of (Case_Item) = Wanted
              and then not Recorded_In_Lane (Case_Item)
            then
               Landin.Testing.Fail
                 (Item, Wanted & ": names no " & Lanes.Fixture_Label
                  & " target, so the " & Lanes.Target_Name
                  & " lane does not run it");
            elsif Label_Of (Case_Item) = Wanted
              and then Class (Case_Item) in Runtime | Abi
              and then Lane_Runner_Problem (Host) /= ""
            then
               Ran := Ran + 1;
               Landin.Testing.Fail (Item, Lane_Runner_Problem (Host));
            elsif Label_Of (Case_Item) = Wanted then
               Ran := Ran + 1;

               if Class (Case_Item) = Abi then
                  for Profile in 1 .. Profile_Count (Case_Item) loop
                     Run_ABI (Case_Item, Host, Program, Profile, Item);
                  end loop;
               elsif Expect (Case_Item) /= "" then
                  Run_Recorded (Case_Item, Host, Program, Item);
               elsif Class (Case_Item) = Positive_Program then
                  Emit_Positive (Case_Item, Host, Program, Item);
               elsif Class (Case_Item) = Negative_Program then
                  Run_Negative (Case_Item, Program, Item);
               elsif Class (Case_Item) = Runtime then
                  if not Lane_Levels (Case_Item).Is_Empty then
                     Ask_Lane_Processor (Host);
                     Report_Levels (Lane_Levels (Case_Item));
                  end if;
                  for Profile in 1 .. Profile_Count (Case_Item) loop
                     Run_Runtime (Case_Item, Host, Program, Profile, Item);
                     for Level of Lane_Levels (Case_Item) loop
                        Run_Runtime
                          (Case_Item, Host, Program, Profile, Item, Level);
                     end loop;
                  end loop;
               else
                  Landin.Testing.Fail
                    (Item, Wanted & ": this fixture class has no focused"
                     & " execution contract");
               end if;
            end if;
         end;
      end loop;

      Landin.Testing.Check_Equal
        (Item, Ran, 1, Wanted & ": one fixture was executed");
   end Selected_Fixture_Executes;

   --  Exercise the shared verdict against fake metadata and outcomes.
   --  No fixture program, compiler or host tool is started by this case.
   procedure Outputs_Belong_To_Their_Producing_Attempt
     (Item : in out Landin.Testing.Context);

   procedure Outputs_Belong_To_Their_Producing_Attempt
     (Item : in out Landin.Testing.Context)
   is
      package Fakes renames Landin.Testing.Fakes;
      type Writer (Files : not null access Fakes.Fake_Filesystem) is
        new Fakes.Fake_Tool_Runner with record
         Creates : Boolean := False;
         Directory : Boolean := False;
      end record;

      overriding procedure Run
        (Host : Writer; Program : String;
         Arguments : Landin.Platform.Path_List;
         Result : out Landin.Platform.Tool_Result;
         Capture : Landin.Platform.Capture_Mode := Landin.Platform.Merged);

      overriding procedure Run
        (Host : Writer; Program : String;
         Arguments : Landin.Platform.Path_List;
         Result : out Landin.Platform.Tool_Result;
         Capture : Landin.Platform.Capture_Mode := Landin.Platform.Merged)
      is
         Written : Landin.Platform.Write_Status;
      begin
         Fakes.Run
           (Fakes.Fake_Tool_Runner (Host), Program, Arguments,
            Result, Capture);
         if Host.Directory then
            Host.Files.Add_Directory ("output");
         elsif Host.Creates then
            Host.Files.Write_File ("output", "fresh", Written);
            pragma Assert (Written = Landin.Platform.Write_Ok);
         end if;
      end Run;

      type Scenario is
        (Missing_Output, Stale_Output, Fresh_Output, Repeated_Attempt,
         Blocked_Removal, Existing_Directory, Produced_Directory,
         Failed_Producer, Timed_Out_Producer, Missing_Producer);
   begin
      for Case_Kind in Scenario loop
         declare
            Files : aliased Fakes.Fake_Filesystem;
            Runner : Writer (Files'Access);
            Probe : Landin.Testing.Context;
            Ready : Boolean;
            Expected_Runs : constant Natural :=
              (if Case_Kind in Blocked_Removal | Existing_Directory
                                | Missing_Producer
               then 0 elsif Case_Kind = Repeated_Attempt then 2 else 1);
         begin
            if Case_Kind = Existing_Directory then
               Files.Add_Directory ("output");
            elsif Case_Kind /= Missing_Output then
               Files.Add_File ("output", "stale");
            end if;
            Runner.Set_Result
              ((if Case_Kind = Failed_Producer then 1 else 0), "",
               (if Case_Kind = Timed_Out_Producer
                then Landin.Platform.Timed_Out else Landin.Platform.Exited));
            Runner.Creates := Case_Kind in Fresh_Output | Repeated_Attempt
                                          | Failed_Producer;
            Runner.Directory := Case_Kind = Produced_Directory;
            if Case_Kind = Blocked_Removal then
               Files.Refuse_Removals;
            elsif Case_Kind = Missing_Producer then
               Runner.Raise_On_Run
                 (Landin.External_Tool_Failed'Identity,
                  "tool not found: fake");
            end if;
            Produce_Output
              (Files, Runner, "fake", Scenario'Image (Case_Kind), "output",
               Landin.Platform.No_Arguments, Probe, Ready);
            if Case_Kind = Repeated_Attempt then
               Landin.Testing.Check
                 (Item, Ready and then Files.Exists ("output"),
                  "the first attempt really creates its output");
               Runner.Creates := False;
               Produce_Output
                 (Files, Runner, "fake", "second attempt", "output",
                  Landin.Platform.No_Arguments, Probe, Ready);
            end if;
            Landin.Testing.Check
              (Item, Ready = (Case_Kind = Fresh_Output),
               Scenario'Image (Case_Kind) & " retains the freshness verdict");
            Landin.Testing.Check_Equal
              (Item, Landin.Testing.Failures (Probe),
               (if Case_Kind = Fresh_Output then 0 else 1),
               Scenario'Image (Case_Kind) & ": "
               & Landin.Testing.Failure_Text (Probe));
            Landin.Testing.Check_Equal
              (Item, Runner.Run_Count, Expected_Runs,
               "a removal refusal cannot reach the producing tool");
         end;
      end loop;
   end Outputs_Belong_To_Their_Producing_Attempt;

   procedure Negative_Metadata_Decides_The_Verdict
     (Item : in out Landin.Testing.Context);

   procedure Negative_Metadata_Decides_The_Verdict
     (Item : in out Landin.Testing.Context)
   is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Found : Catalogue;
      LF : constant Character := ASCII.LF;
      Report : constant String :=
        "error[L0004]: first" & LF & "error[L0004]: second" & LF
        & "error[L0103]: last" & LF;

      procedure Check
        (Case_Item : Fixture; Exit_Code : Integer; Text : String;
         Ended : Landin.Platform.Termination; Expected_Failures : Natural);

      procedure Check
        (Case_Item : Fixture; Exit_Code : Integer; Text : String;
         Ended : Landin.Platform.Termination; Expected_Failures : Natural)
      is
         Probe : Landin.Testing.Context;
         Outcome : constant Landin.Platform.Tool_Result :=
           (Ended, Exit_Code, Unbounded.To_Unbounded_String (Text),
            Unbounded.Null_Unbounded_String);
      begin
         Check_Compiler_Outcome (Case_Item, Outcome, Probe);
         Landin.Testing.Check_Equal
           (Item, Landin.Testing.Checks (Probe), 3,
            "each negative compares termination, status and ordered codes");
         Landin.Testing.Check_Equal
           (Item, Landin.Testing.Failures (Probe), Expected_Failures,
            "the declared contract alone decides the verdict"
            & ASCII.LF & Landin.Testing.Failure_Text (Probe));
      end Check;
   begin
      Host.Add_Directory ("root/negative");
      Host.Add_Directory ("root/negative/compiled");
      Host.Add_File
        ("root/negative/compiled/fixture.meta",
         "class: negative" & LF & "summary: a compiled refusal" & LF
         & "constructs: 1740" & LF & "program: bad.ldn" & LF
         & "status: 2" & LF & "codes: L0004,L0004, L0103" & LF
         & "targets: linux-x86-64" & LF);
      Host.Add_Directory ("root/negative/recorded");
      Host.Add_File
        ("root/negative/recorded/fixture.meta",
         "class: negative" & LF & "summary: a recorded refusal" & LF
         & "constructs: 1740" & LF & "expect: expected.txt" & LF
         & "args: --bad" & LF & "status: 2" & LF
         & "codes: L0004,L0004, L0103" & LF
         & "targets: linux-x86-64" & LF);
      Host.Add_Directory ("root/negative/default-status");
      Host.Add_File
        ("root/negative/default-status/fixture.meta",
         "class: negative" & LF & "summary: the default refusal status" & LF
         & "constructs: 1740" & LF & "program: bad.ldn" & LF
         & "codes: L0004,L0004, L0103" & LF
         & "targets: linux-x86-64" & LF);
      Discover (Found, "root", Host);
      Landin.Testing.Check_Equal
        (Item, Problem_Count (Found), 0, "the fake metadata is valid");
      Landin.Testing.Check_Equal
        (Item, Count (Found), 3, "both forms and the default are covered");
      for Position in 1 .. Count (Found) loop
         declare
            Case_Item : constant Fixture := Nth (Found, Position);
            Expected_Status : constant Integer :=
              (if Name (Case_Item) = "default-status" then 1 else 2);
         begin
            Check
              (Case_Item, Expected_Status, Report, Landin.Platform.Exited, 0);
            Check
              (Case_Item, 3 - Expected_Status, Report,
               Landin.Platform.Exited, 1);
            Check
              (Case_Item, Expected_Status, "error[L0103]: first" & LF
               & "error[L0004]: next" & LF & "error[L0004]: last" & LF,
               Landin.Platform.Exited, 1);
            Check
              (Case_Item, Expected_Status, "error[L0004]: first" & LF
               & "error[L0103]: last" & LF, Landin.Platform.Exited, 1);
            Check (Case_Item, 0, Report, Landin.Platform.Timed_Out, 2);
            Check (Case_Item, 0, Report, Landin.Platform.Signaled, 2);
         end;
      end loop;
   end Negative_Metadata_Decides_The_Verdict;

   --  Only fake tools run here. Runtime/ABI metadata exercises the exact
   --  same oracle used after a native build, without assembling a fixture.
   procedure Stream_Metadata_Decides_The_Oracle
     (Item : in out Landin.Testing.Context);

   procedure Stream_Metadata_Decides_The_Oracle
     (Item : in out Landin.Testing.Context)
   is
      procedure Check_Class (Kind : Fixture_Class; Choice : Stream_Choice);

      procedure Check_Class (Kind : Fixture_Class; Choice : Stream_Choice) is
         Host : Landin.Testing.Fakes.Fake_Filesystem;
         Found : Catalogue;
         Directory : constant String :=
           "root/" & Class_Directory (Kind) & "/stream";
         LF : constant Character := ASCII.LF;

         procedure Check
           (Text : String; Errors : String; Expected_Failures : Natural);

         procedure Check
           (Text : String; Errors : String; Expected_Failures : Natural)
         is
            Runner : Landin.Testing.Fakes.Fake_Tool_Runner;
            Outcome : Landin.Platform.Tool_Result;
            Probe : Landin.Testing.Context;
            Case_Item : constant Fixture := Nth (Found, 1);
         begin
            Runner.Add_Result (0, Text, Error_Output => Errors);
            Run_With_Stream
              (Case_Item, "stream [none-off]", Runner, "fake-program",
               Landin.Platform.No_Arguments, Outcome, Probe);
            Check_Output
              (Case_Item, "stream [none-off]", Outcome, "wanted", Probe);
            Landin.Testing.Check_Equal
              (Item, Runner.Run_Count, 1, "the program runs once");
            Landin.Testing.Check
              (Item, Runner.Last_Capture =
                 (if Choice = Output then Landin.Platform.Output_Only
                  else Landin.Platform.Merged),
               "metadata selects the actual capture request");
            Landin.Testing.Check_Equal
              (Item, Landin.Testing.Checks (Probe),
               (if Choice = Output then 2 else 1),
               "output-only has an independent stderr obligation");
            Landin.Testing.Check_Equal
              (Item, Landin.Testing.Failures (Probe), Expected_Failures,
               "the oracle distinguishes wrong and additional streams");
            if Expected_Failures > 0 then
               Landin.Testing.Check
                 (Item, Ada.Strings.Fixed.Index
                    (Landin.Testing.Failure_Text (Probe), "[none-off]") > 0,
                  "output failures preserve the profile label");
            end if;
         end Check;
      begin
         Host.Add_Directory ("root");
         Host.Add_Directory ("root/" & Class_Directory (Kind));
         Host.Add_Directory (Directory);
         Host.Add_File (Directory & "/main.ldn", "");
         Host.Add_File (Directory & "/peer.c", "");
         Host.Add_File
           (Directory & "/fixture.meta",
            "class: " & Class_Directory (Kind) & LF
            & "summary: stream contract" & LF
            & "targets: linux-x86-64" & LF & "constructs: 1740" & LF
            & "program: main.ldn" & LF
            & (if Kind in Runtime | Abi
               then "profiles: standard" & LF else "")
            & (if Kind = Abi then "c-sources: peer.c" & LF else "")
            & "stream: " & (if Choice = Output then "output" else "merged")
            & LF);
         Discover (Found, "root", Host);
         Landin.Testing.Check_Equal
           (Item, Problem_Count (Found), 0, "stream metadata is valid");
         Landin.Testing.Check_Equal
           (Item, Count (Found), 1, "the fixture remains discoverable");
         if Count (Found) = 1 then
            Check ("wanted", "", 0);
            if Choice = Output then
               Check ("", "wanted", 2);
               Check ("wanted", "additional", 1);
            else
               Check ("wrong", "", 1);
            end if;
         end if;
      end Check_Class;
   begin
      Check_Class (Unit, Output);
      Check_Class (Unit, Merged);
      Check_Class (Runtime, Output);
      Check_Class (Runtime, Merged);
      Check_Class (Abi, Output);
      Check_Class (Abi, Merged);
   end Stream_Metadata_Decides_The_Oracle;

   --  The debugger sessions hold each complete workload to the source
   --  closure compiler/tests/debugging/workload-sources.json records, and
   --  only the gate's GDB and LLDB jobs run them, so a library file added to
   --  a module the workloads import failed there naming no file and no way
   --  to regenerate the record.  This compares the same closure, the build
   --  report's sources, in the test program every change runs, and names
   --  each file that differs and the command that rewrites the record.
   --  Real host: it runs the built refine over the real repository.
   procedure Debugger_Workload_Inventories_Hold
     (Item : in out Landin.Testing.Context);

   procedure Debugger_Workload_Inventories_Hold
     (Item : in out Landin.Testing.Context)
   is
      package Names is new Ada.Containers.Indefinite_Ordered_Sets (String);

      Record_Path : constant String :=
        "../tests/debugging/workload-sources.json";
      Program : constant String := Refine_Path;
      Shown : constant String :=
        (if Program'Length > 0 and then Program (Program'First) = '/'
         then Program else "compiler/ada/" & Program);
      Regenerate : constant String :=
        "python3 compiler/tests/debugging/workload_sources.py --refine "
        & Shown & " --write";
      Host : Landin.Platform.Native.Native_Filesystem;
      Runner : Landin.Platform.Native.Tools.Native_Tool_Runner;
      Text : Unbounded.Unbounded_String;
      Read : Landin.Platform.Read_Status;
      Inventory : Landin.Json.Document;

      --  The path a report names, from compiler/ada where the harness
      --  runs, as the record writes it: from the repository root.  The
      --  hosted entry's platform module, which the compiler adds to a
      --  program that imports nothing, is found in the library, which the
      --  report names absolutely.
      Root : constant String := Ada.Directories.Full_Name ("../..") & "/";

      function Repository_Path (Path : String) return String;

      function Repository_Path (Path : String) return String is
      begin
         if Path'Length > Root'Length
           and then Path (Path'First .. Path'First + Root'Length - 1) = Root
         then
            return Path (Path'First + Root'Length .. Path'Last);
         elsif Path'Length > 6
           and then Path (Path'First .. Path'First + 5) = "../../"
         then
            return Path (Path'First + 6 .. Path'Last);
         elsif Path'Length > 3
           and then Path (Path'First .. Path'First + 2) = "../"
         then
            return "compiler/" & Path (Path'First + 3 .. Path'Last);
         end if;
         return "compiler/ada/" & Path;
      end Repository_Path;

      function Unhex (Digits_Text : String) return String;

      function Unhex (Digits_Text : String) return String is
         function Digit (C : Character) return Natural is
           (case C is
               when '0' .. '9' => Character'Pos (C) - Character'Pos ('0'),
               when 'a' .. 'f' => Character'Pos (C) - Character'Pos ('a') + 10,
               when others => Character'Pos (C) - Character'Pos ('A') + 10);
         Result : String (1 .. Digits_Text'Length / 2);
      begin
         for Index in Result'Range loop
            Result (Index) := Character'Val
              (16 * Digit (Digits_Text (Digits_Text'First + 2 * Index - 2))
               + Digit (Digits_Text (Digits_Text'First + 2 * Index - 1)));
         end loop;
         return Result;
      end Unhex;

      procedure Compare (Workload : String; Recorded : Landin.Json.Value);

      procedure Compare (Workload : String; Recorded : Landin.Json.Value) is
         Fixture_Name : constant String :=
           (if Workload = "parser" then "derived-parser"
            elsif Workload = "containers" then "derived-containers"
            elsif Workload = "hosted" then "derived-hosted-memory"
            elsif Workload = "switch" then "stack-switch-frames" else "");
         Assembly : constant String :=
           Output_Directory & "workload-" & Workload & ".s";
         Report_Path : constant String :=
           Output_Directory & "workload-" & Workload & ".json";
         Args : Landin.Platform.Path_List;
         Outcome : Landin.Platform.Tool_Result;
         Report_Text : Unbounded.Unbounded_String;
         Report : Landin.Json.Document;
         Wanted, Built : Names.Set;
         Difference : Unbounded.Unbounded_String;
      begin
         if Fixture_Name = "" then
            Landin.Testing.Fail
              (Item, Record_Path & " names a workload, " & Workload
               & ", that the debugger sessions do not run");
            return;
         end if;
         for Position in 1 .. Landin.Json.Length (Inventory, Recorded) loop
            Wanted.Include
              (Landin.Json.Text
                 (Inventory, Landin.Json.Element
                    (Inventory, Recorded, Position)));
         end loop;
         --  The sessions' own request, less the debugger's: none/off, so
         --  the closure is the source's rather than an optimizer's.
         Args.Append ("compile");
         Args.Append ("--target=linux-x86-64");
         Args.Append (Fixture_Root & "/runtime/" & Fixture_Name);
         Args.Append ("--root=../..");
         Args.Append ("--emit=asm");
         Args.Append ("-o");
         Args.Append (Assembly);
         Args.Append ("--optimize=none");
         Args.Append ("--specialize=off");
         Args.Append ("--build-report=" & Report_Path);
         Runner.Run (Program, Args, Outcome, Landin.Platform.Merged);
         if Outcome.Ended /= Landin.Platform.Exited
           or else Outcome.Exit_Code /= 0
         then
            Landin.Testing.Fail
              (Item, "the " & Workload & " debugger workload did not compile: "
               & Unbounded.To_String (Outcome.Output));
            return;
         end if;
         Host.Read_File (Report_Path, Report_Text, Read);
         if Read /= Landin.Platform.Read_Ok then
            Landin.Testing.Fail
              (Item, "the " & Workload & " workload left no build report");
            return;
         end if;
         Landin.Json.Parse (Report, Unbounded.To_String (Report_Text));
         declare
            Sources : constant Landin.Json.Value := Landin.Json.Member
              (Report, Landin.Json.Root (Report), "sources");
         begin
            for Position in 1 .. Landin.Json.Length (Report, Sources) loop
               Built.Include
                 (Repository_Path
                    (Unhex (Landin.Json.Text
                       (Report, Landin.Json.Member
                          (Report, Landin.Json.Element
                             (Report, Sources, Position), "path_hex")))));
            end loop;
         end;
         for Name of Names.Difference (Built, Wanted) loop
            Unbounded.Append (Difference, ASCII.LF & "  added   " & Name);
         end loop;
         for Name of Names.Difference (Wanted, Built) loop
            Unbounded.Append (Difference, ASCII.LF & "  removed " & Name);
         end loop;
         Landin.Testing.Check
           (Item, Unbounded.Length (Difference) = 0,
            "the " & Workload & " debugger workload's source closure differs"
            & " from compiler/tests/debugging/workload-sources.json:"
            & Unbounded.To_String (Difference) & ASCII.LF
            & "  regenerate it with " & Regenerate);
      end Compare;
   begin
      if not Host.Exists (Program) then
         Landin.Testing.Fail
           (Item, "refine was not found at " & Program
            & "; run the harness through scripts/test.sh");
         return;
      end if;
      Host.Read_File (Record_Path, Text, Read);
      if Read /= Landin.Platform.Read_Ok then
         Landin.Testing.Fail (Item, Record_Path & " is unreadable");
         return;
      end if;
      Landin.Json.Parse (Inventory, Unbounded.To_String (Text));
      if not Landin.Json.Ok (Inventory)
        or else not Landin.Json.Is_Kind
          (Inventory, Landin.Json.Root (Inventory), Landin.Json.Object_Value)
      then
         Landin.Testing.Fail (Item, Record_Path & " is not a JSON object");
         return;
      end if;
      Landin.Testing.Check_Equal
        (Item,
         Landin.Json.Length (Inventory, Landin.Json.Root (Inventory)), 4,
         "the record names the four debugger workloads");
      for Position in 1 ..
        Landin.Json.Length (Inventory, Landin.Json.Root (Inventory))
      loop
         Compare
           (Landin.Json.Key
              (Inventory, Landin.Json.Root (Inventory), Position),
            Landin.Json.Member_Value
              (Inventory, Landin.Json.Root (Inventory), Position));
      end loop;
   end Debugger_Workload_Inventories_Hold;

   --  The debugger sessions expect each workload's stack to hold named
   --  routines at each stop, and only the gate's GDB and LLDB jobs ran
   --  them, so renaming or removing one of those routines in the library
   --  failed there and nowhere a change is made.  workload-frames.json
   --  holds the stops both debuggers read and the file declaring each
   --  routine; this reads each one there, on every run, and names the
   --  session, the stop and the command that finds a moved routine again.
   --  Real host: it reads the real repository's sources.
   procedure Debugger_Session_Frames_Are_Declared
     (Item : in out Landin.Testing.Context);

   procedure Debugger_Session_Frames_Are_Declared
     (Item : in out Landin.Testing.Context)
   is
      Frames_Path  : constant String :=
        "../tests/debugging/workload-frames.json";
      Sources_Path : constant String :=
        "../tests/debugging/workload-sources.json";
      Regenerate   : constant String :=
        "python3 compiler/tests/debugging/workload_frames.py --write";
      Sessions     : constant String :=
        "GDB in compiler/tests/debugging/check.py, LLDB in"
        & " compiler/tests/debugging/darwin_workloads.py, and the switch"
        & " workload's on every target through"
        & " compiler/tests/debugging/switch_frames.py";
      Host    : Landin.Platform.Native.Native_Filesystem;
      Frames  : Landin.Json.Document;
      Sources : Landin.Json.Document;

      function Load
        (Path : String; Into : in out Landin.Json.Document) return Boolean;

      function Load
        (Path : String; Into : in out Landin.Json.Document) return Boolean
      is
         Text : Unbounded.Unbounded_String;
         Read : Landin.Platform.Read_Status;
      begin
         Host.Read_File (Path, Text, Read);
         if Read /= Landin.Platform.Read_Ok then
            Landin.Testing.Fail (Item, Path & " is unreadable");
            return False;
         end if;
         Landin.Json.Parse (Into, Unbounded.To_String (Text));
         if not Landin.Json.Ok (Into)
           or else not Landin.Json.Is_Kind
             (Into, Landin.Json.Root (Into), Landin.Json.Object_Value)
         then
            Landin.Testing.Fail (Item, Path & " is not a JSON object");
            return False;
         end if;
         return True;
      end Load;

      --  Whether Text declares Routine at its top level: a line that
      --  begins with the name, or with `public` and the name, then `:`.
      function Declares (Text, Routine : String) return Boolean;

      function Declares (Text, Routine : String) return Boolean is
         Line : Positive := Text'First;
         Ends : Natural;

         function At_Line (From : Positive; Last : Natural) return Boolean;

         function At_Line (From : Positive; Last : Natural) return Boolean is
            Rest : Positive := From;
         begin
            if Last - From + 1 > 7 and then Text (From .. From + 6) = "public "
            then
               Rest := From + 7;
               while Rest <= Last and then Text (Rest) = ' ' loop
                  Rest := Rest + 1;
               end loop;
            end if;
            if Last - Rest + 1 <= Routine'Length
              or else Text (Rest .. Rest + Routine'Length - 1) /= Routine
            then
               return False;
            end if;
            Rest := Rest + Routine'Length;
            while Rest <= Last and then Text (Rest) = ' ' loop
               Rest := Rest + 1;
            end loop;
            return Rest <= Last and then Text (Rest) = ':';
         end At_Line;
      begin
         while Line <= Text'Last loop
            Ends := Ada.Strings.Fixed.Index
              (Text (Line .. Text'Last), [1 => ASCII.LF]);
            if Ends = 0 then
               Ends := Text'Last + 1;
            end if;
            if At_Line (Line, Ends - 1) then
               return True;
            end if;
            Line := Ends + 1;
         end loop;
         return False;
      end Declares;

      procedure Hold
        (Workload : String; Stop : String; Routine : String;
         Declared : Landin.Json.Value; Closure : Landin.Json.Value);

      procedure Hold
        (Workload : String; Stop : String; Routine : String;
         Declared : Landin.Json.Value; Closure : Landin.Json.Value)
      is
         Named    : constant Landin.Json.Value :=
           Landin.Json.Member (Frames, Declared, Routine);
         Session  : constant String :=
           "the " & Workload & " debugger session (" & Sessions
           & ") expects " & Routine & " in its stack at " & Stop;
         In_Closure : Boolean := False;
      begin
         if not Landin.Json.Is_Kind (Frames, Named, Landin.Json.String_Value)
         then
            Landin.Testing.Fail
              (Item, Session & ", and workload-frames.json names no file"
               & " declaring it; regenerate it with " & Regenerate);
            return;
         end if;
         declare
            File : constant String := Landin.Json.Text (Frames, Named);
            Text : Unbounded.Unbounded_String;
            Read : Landin.Platform.Read_Status;
         begin
            if Landin.Json.Is_Kind (Sources, Closure, Landin.Json.Array_Value)
            then
               for Position in 1 .. Landin.Json.Length (Sources, Closure) loop
                  if Landin.Json.Text
                    (Sources, Landin.Json.Element (Sources, Closure, Position))
                    = File
                  then
                     In_Closure := True;
                  end if;
               end loop;
            end if;
            Host.Read_File ("../../" & File, Text, Read);
            if not In_Closure then
               Landin.Testing.Fail
                 (Item, Session & " from " & File & ", which the workload is"
                  & " not built from; regenerate it with " & Regenerate);
            elsif Read /= Landin.Platform.Read_Ok
              or else not Declares (Unbounded.To_String (Text), Routine)
            then
               Landin.Testing.Fail
                 (Item, Session & ", and " & File & " no longer declares it;"
                  & " a moved routine is found again by " & Regenerate
                  & ", and a renamed one is renamed in the stops of"
                  & " compiler/tests/debugging/workload-frames.json");
            else
               Landin.Testing.Check (Item, True, Session);
            end if;
         end;
      end Hold;
   begin
      if not Load (Frames_Path, Frames)
        or else not Load (Sources_Path, Sources)
      then
         return;
      end if;
      Landin.Testing.Check_Equal
        (Item, Landin.Json.Length (Frames, Landin.Json.Root (Frames)), 4,
         "the frames name the four debugger workloads");
      for Position in
        1 .. Landin.Json.Length (Frames, Landin.Json.Root (Frames))
      loop
         declare
            Workload : constant String :=
              Landin.Json.Key (Frames, Landin.Json.Root (Frames), Position);
            Entry_Value : constant Landin.Json.Value :=
              Landin.Json.Member_Value
                (Frames, Landin.Json.Root (Frames), Position);
            Stops    : constant Landin.Json.Value :=
              Landin.Json.Member (Frames, Entry_Value, "stops");
            Beneath  : constant Landin.Json.Value :=
              Landin.Json.Member (Frames, Entry_Value, "beneath");
            Declared : constant Landin.Json.Value :=
              Landin.Json.Member (Frames, Entry_Value, "declared");
            Closure  : constant Landin.Json.Value :=
              Landin.Json.Member
                (Sources, Landin.Json.Root (Sources), Workload);
         begin
            if not Landin.Json.Is_Kind
                (Frames, Stops, Landin.Json.Object_Value)
              or else Landin.Json.Length (Frames, Stops) = 0
            then
               Landin.Testing.Fail
                 (Item, Workload & " has no stops in " & Frames_Path);
            else
               for Stop in 1 .. Landin.Json.Length (Frames, Stops) loop
                  declare
                     Stack : constant Landin.Json.Value :=
                       Landin.Json.Member_Value (Frames, Stops, Stop);
                  begin
                     for Frame in 1 .. Landin.Json.Length (Frames, Stack) loop
                        Hold
                          (Workload,
                           "stop " & Landin.Json.Key (Frames, Stops, Stop),
                           Landin.Json.Text
                             (Frames,
                              Landin.Json.Element (Frames, Stack, Frame)),
                           Declared, Closure);
                     end loop;
                  end;
               end loop;
            end if;
            if Landin.Json.Is_Kind (Frames, Beneath, Landin.Json.Array_Value)
            then
               for Frame in 1 .. Landin.Json.Length (Frames, Beneath) loop
                  Hold
                    (Workload, "every stop",
                     Landin.Json.Text
                       (Frames, Landin.Json.Element (Frames, Beneath, Frame)),
                     Declared, Closure);
               end loop;
            end if;
         end;
      end loop;
   end Debugger_Session_Frames_Are_Declared;

   procedure Register
     (Into : in out Landin.Testing.Registry;
      Include_Target_Workloads : Boolean := True) is
   begin
      Landin.Testing.Register
        (Into, "fixture execution",
         "debugger workload inventories are their closures",
         Debugger_Workload_Inventories_Hold'Access);
      Landin.Testing.Register
        (Into, "fixture execution",
         "debugger session frames are declared",
         Debugger_Session_Frames_Are_Declared'Access);
      Landin.Testing.Register
        (Into, "fixture execution", "a report is recorded by name",
         A_Report_Is_Recorded_By_Name'Access);
      Landin.Testing.Register
        (Into, "fixture execution", "a known-bad runner is refused",
         A_Known_Bad_Runner_Is_Refused'Access);
      Landin.Testing.Register
        (Into, "fixture execution",
         "a sysctl answer is read past its line ending",
         A_Sysctl_Answer_Is_Read_Past_Its_Line_Ending'Access);
      Landin.Testing.Register
        (Into, "fixture execution",
         "outputs belong to their producing attempt",
         Outputs_Belong_To_Their_Producing_Attempt'Access);
      Landin.Testing.Register
        (Into, "fixture execution", "stream metadata decides the oracle",
         Stream_Metadata_Decides_The_Oracle'Access);
      Landin.Testing.Register
        (Into, "fixture execution", "negative metadata decides the verdict",
         Negative_Metadata_Decides_The_Verdict'Access);
      Landin.Testing.Register
        (Into, "fixture execution", "a timeout cannot satisfy a trap",
         A_Timeout_Cannot_Satisfy_A_Trap'Access);
      Landin.Testing.Register
        (Into, "fixture execution", "recorded expectations hold",
         Recorded_Expectations_Hold'Access);
      if Include_Target_Workloads then
         Landin.Testing.Register
           (Into, "fixture execution", "hosted library links and runs",
            Hosted_Library_Links_And_Runs'Access);
         Landin.Testing.Register
           (Into, "fixture execution", "every positive fixture is emitted",
            Every_Positive_Fixture_Is_Emitted'Access, Divided => True);
         Landin.Testing.Register
           (Into, "fixture execution", "runtime fixtures execute",
            Runtime_Fixtures_Execute'Access, Divided => True);
      end if;

      if Unbounded.Length (Selected) > 0 then
         Landin.Testing.Register
           (Into, "fixture execution", "selected fixture executes",
            Selected_Fixture_Executes'Access);
      end if;
   end Register;

end Landin.Tests.Fixture_Execution_Suite;
