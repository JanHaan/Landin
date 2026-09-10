with Ada.Strings;
--  Fixtures that are run, not merely parsed.
--
--  A recorded expectation nobody compares to anything is not a test, it is
--  a file that looks like one.  Every fixture carrying `expect` and `args`
--  is executed here through the real tool adapter, and its bytes and exit
--  status are compared with what it claims.

with Ada.Strings.Fixed;
with Ada.Environment_Variables;
with Ada.Strings.Unbounded;

with Landin.Backend.Toolchain;
with Landin.Optimization;
with Landin.Platform;
with Landin.Platform.Native;
with Landin.Platform.Native.Tools;
with Landin.Targets;
with Landin.Testing.Fakes;
with Landin.Testing.Fixtures;

--  This suite runs the real `refine` against the real fixture tree through
--  the real tool adapter.  That is the point of it: everything else in the
--  repository can be checked with fakes, and a recorded expectation cannot.

package body Landin.Tests.Fixture_Execution_Suite is

   package Unbounded renames Ada.Strings.Unbounded;
   package Environment renames Ada.Environment_Variables;

   use Landin.Testing.Fixtures;
   use type Landin.Platform.Read_Status;
   use type Landin.Platform.Termination;

   Fixture_Root : constant String := "../tests/fixtures";
   Selected     : Unbounded.Unbounded_String;

   procedure Select_Fixture (Path : String) is
   begin
      Selected := Unbounded.To_Unbounded_String (Path);
   end Select_Fixture;

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

   procedure A_Timeout_Cannot_Satisfy_A_Trap
     (Item : in out Landin.Testing.Context);

   procedure A_Timeout_Cannot_Satisfy_A_Trap
     (Item : in out Landin.Testing.Context)
   is
      Runner      : Landin.Testing.Fakes.Fake_Tool_Runner;
      Overdue     : Landin.Platform.Tool_Result;
      Trap_Result : Landin.Platform.Tool_Result;
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
   end A_Timeout_Cannot_Satisfy_A_Trap;

   function Codes_In (Text : String) return String;

   function Codes_In (Text : String) return String is
      Found : Unbounded.Unbounded_String;
      Mark  : constant String := "error[";
   begin
      for Start in Text'Range loop
         if Start + Mark'Length + 5 <= Text'Last
           and then Text (Start .. Start + Mark'Length - 1) = Mark
           and then Text (Start + Mark'Length + 5) = ']'
         then
            if Unbounded.Length (Found) > 0 then
               Unbounded.Append (Found, ", ");
            end if;

            Unbounded.Append
              (Found,
               Text (Start + Mark'Length .. Start + Mark'Length + 4));
         end if;
      end loop;

      return Unbounded.To_String (Found);
   end Codes_In;

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

      Runner.Run
        (Program   => Program,
         Arguments => Split (Args (Case_Item)),
         Result    => Outcome,
         Capture   =>
           (if Stream (Case_Item) = Output
            then Landin.Platform.Output_Only
            else Landin.Platform.Merged));

      Landin.Testing.Check_Equal
        (Item,
         Unbounded.To_String (Outcome.Output),
         Unbounded.To_String (Expected),
         Label & ": recorded "
         & (if Stream (Case_Item) = Output
            then "standard output" else "merged output"));
      Landin.Testing.Check
        (Item, Outcome.Ended = Landin.Platform.Exited,
         Label & ": refine returned a status");
      Landin.Testing.Check_Equal
        (Item, Outcome.Exit_Code, Status (Case_Item),
         Label & ": recorded exit status");
   end Run_Recorded;

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
      Outcome : Landin.Platform.Tool_Result;
      Args    : Landin.Platform.Path_List;
   begin
      Append_Module_Arguments (Case_Item, Fixture_Root, Args);
      Landin.Platform.Add (Args, "--emit=asm");
      Landin.Platform.Add (Args, "-o");
      Landin.Platform.Add (Args, Written);

      Runner.Run (Program, Args, Outcome, Landin.Platform.Merged);

      if Outcome.Ended /= Landin.Platform.Exited then
         Landin.Testing.Fail
           (Item,
            Label & ": refine was stopped before it could emit" & ASCII.LF
            & Unbounded.To_String (Outcome.Output));
      elsif Outcome.Exit_Code /= 0 then
         Landin.Testing.Fail
           (Item,
            Label & ": accepted but not emitted" & ASCII.LF
            & Unbounded.To_String (Outcome.Output));
      else
         Landin.Testing.Check
           (Item, Host.Exists (Written), Label & ": the assembly was written");
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
      Label   : constant String := "negative/" & Name (Case_Item);
      Runner  : Landin.Platform.Native.Tools.Native_Tool_Runner;
      Outcome : Landin.Platform.Tool_Result;
      Args    : Landin.Platform.Path_List;
   begin
      Append_Module_Arguments (Case_Item, Fixture_Root, Args);
      Runner.Run (Program, Args, Outcome, Landin.Platform.Merged);

      Landin.Testing.Check
        (Item, Outcome.Ended = Landin.Platform.Exited,
         Label & ": refine returned a status");
      Landin.Testing.Check_Equal
        (Item, Outcome.Exit_Code, 1, Label & ": the program was refused");
      Landin.Testing.Check_Equal
        (Item, Codes_In (Unbounded.To_String (Outcome.Output)),
         Normalized_Codes (Codes (Case_Item)),
         Label & ": the report carries its pinned codes");
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

      for Index in 1 .. Count (Found) loop
         declare
            Case_Item : constant Fixture := Nth (Found, Index);
         begin
            if Expect (Case_Item) /= "" then
               Ran := Ran + 1;
               Run_Recorded (Case_Item, Host, Program, Item);
            end if;
         end;
      end loop;

      --  Without this the whole case would pass by running nothing, which
      --  is the exact failure it exists to catch.
      Landin.Testing.Check
        (Item, Ran >= 2,
         "at least the recorded end-to-end and negative fixtures ran");

      --  At least one fixture must pin the stream, or swapping refine's
      --  two streams would again be invisible to every fixture.
      declare
         Pinned : Natural := 0;
      begin
         for Index in 1 .. Count (Found) loop
            if Expect (Nth (Found, Index)) /= ""
              and then Stream (Nth (Found, Index)) = Output
            then
               Pinned := Pinned + 1;
            end if;
         end loop;

         Landin.Testing.Check
           (Item, Pinned >= 1,
            "a fixture pins which stream refine wrote to");
      end;

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
   --  A positive fixture is a program the compiler must accept, and until
   --  R1.90 that was the whole of what any case asked of one.  Accepting
   --  is not emitting: R1.80's audit found four of [1810]'s statement
   --  forms that every stage accepted and no case had ever asked a
   --  backend for, so a construct could reach a compiler defect and the
   --  corpus would say nothing.  This asks the backend for all of them.
   --
   --  It does not run them.  What a positive fixture claims is that the
   --  program is legal, and most of the corpus is a fragment with no
   --  entry point to run; the runtime class is where a claim about a
   --  machine belongs.  The three words the matrix wants are separate for
   --  this reason: accepted, emitted, executed.
   ------------------------------------------------------------------

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

      for Index in 1 .. Count (Found) loop
         declare
            Case_Item : constant Fixture := Nth (Found, Index);
         begin
            if Class (Case_Item) = Positive_Program
              and then Landin.Testing.Fixtures.Program (Case_Item) /= ""
            then
               Ran := Ran + 1;
               Emit_Positive (Case_Item, Host, Program, Item);
            end if;
         end;
      end loop;

      --  Without this the case would pass by emitting nothing, which is
      --  the failure the whole class exists to prevent.
      Landin.Testing.Check
        (Item, Ran >= 50,
         "the positive corpus was emitted rather than skipped");
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

   function Profile_Count (Case_Item : Fixture) return Positive is
     (if Ada.Strings.Fixed.Index (Name (Case_Item), "generic") > 0
         or else Ada.Strings.Fixed.Index (Name (Case_Item), "any-") > 0
         or else Ada.Strings.Fixed.Index (Name (Case_Item), "r450") > 0
         or else Name (Case_Item) in "allocator-vec-pressure"
           | "diagnostic-loggers-dispatch" | "core-io-erased-system"
           | "derived-containers"
      then Profiles'Length else 4);

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

   procedure Run_Runtime
     (Case_Item : Fixture;
      Host      : Landin.Platform.Filesystem'Class;
      Program   : String;
      Profile   : Positive;
      Item      : in out Landin.Testing.Context);

   procedure Run_Runtime
     (Case_Item : Fixture;
      Host      : Landin.Platform.Filesystem'Class;
      Program   : String;
      Profile   : Positive;
      Item      : in out Landin.Testing.Context)
   is
      Label   : constant String := "runtime/" & Name (Case_Item)
        & " [" & Profile_Name (Profile) & "]";
      Built   : constant String :=
        Output_Directory & "runtime-" & Name (Case_Item)
        & "-" & Profile_Name (Profile);
      Runner  : Landin.Platform.Native.Tools.Native_Tool_Runner;
      Compile : Landin.Platform.Tool_Result;
      Outcome : Landin.Platform.Tool_Result;
      Args    : Landin.Platform.Path_List;
      Runtime_Arguments : Landin.Platform.Path_List;
      Expected : Unbounded.Unbounded_String;
      Read     : Landin.Platform.Read_Status;
   begin
      Append_Module_Arguments (Case_Item, Fixture_Root, Args);

      Append_Profile (Args, Profile);
      Landin.Platform.Add (Args, "--emit=exe");
      Landin.Platform.Add (Args, "-o");
      Landin.Platform.Add (Args, Built);

      Runner.Run (Program, Args, Compile, Landin.Platform.Merged);

      if Compile.Ended /= Landin.Platform.Exited then
         Landin.Testing.Fail
           (Item,
            Label & ": refine was stopped before it could produce an"
            & " executable" & ASCII.LF
            & Unbounded.To_String (Compile.Output));
      elsif Compile.Exit_Code /= 0 then
         Landin.Testing.Fail
           (Item,
            Label & ": refine could not produce an executable" & ASCII.LF
            & Unbounded.To_String (Compile.Output));
      elsif not Host.Exists (Built) then
         Landin.Testing.Fail
           (Item,
            Label & ": refine reported success and wrote no executable at "
            & Built);
      else
         Runtime_Arguments := Split (Run_Args (Case_Item));
         Runner.Run
           (Built, Runtime_Arguments, Outcome, Landin.Platform.Merged);

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
                    (Item, Label & ": runtime expectation is unreadable");
               else
                  Landin.Testing.Check_Equal
                    (Item,
                     Unbounded.To_String (Outcome.Output),
                     Unbounded.To_String (Expected),
                     Label & ": recorded merged runtime output");
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
      Facts     : constant Landin.Targets.Target_Facts :=
        Landin.Targets.Linux_X86_64;
      Driver    : constant String :=
        Landin.Backend.Toolchain.Driver_For (Facts, "");
      Runner    : Landin.Platform.Native.Tools.Native_Tool_Runner;
      Emit      : Landin.Platform.Tool_Result;
      Compile   : Landin.Platform.Tool_Result;
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
      Landin.Platform.Add (Refine_Arguments, "-o");
      Landin.Platform.Add (Refine_Arguments, Assembly);

      Runner.Run
        (Program, Refine_Arguments, Emit, Landin.Platform.Merged);

      if Emit.Ended /= Landin.Platform.Exited then
         Landin.Testing.Fail
           (Item,
            Label & ": refine was stopped before it could emit assembly"
            & ASCII.LF & Unbounded.To_String (Emit.Output));
         return;
      elsif Emit.Exit_Code /= 0 then
         Landin.Testing.Fail
           (Item,
            Label & ": refine could not emit assembly" & ASCII.LF
            & Unbounded.To_String (Emit.Output));
         return;
      elsif not Host.Exists (Assembly) then
         Landin.Testing.Fail
           (Item,
            Label & ": refine reported success and wrote no assembly at "
            & Assembly);
         return;
      end if;

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
      Landin.Platform.Add (Driver_Arguments, "-no-pie");
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
           (Item, Label & ": linux-x86-64 names no C toolchain driver");
         return;
      end if;

      begin
         Runner.Run
           (Driver, Driver_Arguments, Compile, Landin.Platform.Merged);
      exception
         when Landin.External_Tool_Failed =>
            Landin.Testing.Fail
              (Item, Label & ": C toolchain driver could not be run: "
               & Driver);
            return;
      end;

      if Compile.Ended /= Landin.Platform.Exited then
         Landin.Testing.Fail
           (Item,
            Label & ": the C toolchain was stopped before it could link"
            & ASCII.LF & Unbounded.To_String (Compile.Output));
      elsif Compile.Exit_Code /= 0 then
         Landin.Testing.Fail
           (Item,
            Label & ": the C toolchain could not link the ABI fixture"
            & ASCII.LF & Unbounded.To_String (Compile.Output));
      elsif not Host.Exists (Built) then
         Landin.Testing.Fail
           (Item,
            Label & ": the C toolchain reported success and wrote no"
            & " executable at " & Built);
      else
         Runtime_Arguments := Split (Run_Args (Case_Item));
         Runner.Run
           (Built, Runtime_Arguments, Outcome, Landin.Platform.Merged);

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
                    (Item, Label & ": runtime expectation is unreadable");
               else
                  Landin.Testing.Check_Equal
                    (Item,
                     Unbounded.To_String (Outcome.Output),
                     Unbounded.To_String (Expected),
                     Label & ": recorded merged runtime output");
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
   begin
      if not Host.Exists (Program) then
         Landin.Testing.Fail
           (Item,
            "refine was not found at " & Program
            & "; run the harness through scripts/test.sh");
         return;
      end if;

      Discover (Found, Fixture_Root, Host);

      for Index in 1 .. Count (Found) loop
         declare
            Case_Item : constant Fixture := Nth (Found, Index);
         begin
            if Class (Case_Item) = Runtime then
               Runtime_Ran := Runtime_Ran + 1;
               for Profile in 1 .. Profile_Count (Case_Item) loop
                  Run_Runtime (Case_Item, Host, Program, Profile, Item);
               end loop;
            elsif Class (Case_Item) = Abi then
               ABI_Ran := ABI_Ran + 1;
               for Profile in 1 .. Profile_Count (Case_Item) loop
                  Run_ABI (Case_Item, Host, Program, Profile, Item);
               end loop;
            end if;
         end;
      end loop;

      --  Without these the case would pass by running nothing, which is
      --  the failure both executable fixture classes exist to prevent.
      Landin.Testing.Check
        (Item, Runtime_Ran >= 1, "at least one runtime fixture was found");
      Landin.Testing.Check
        (Item, ABI_Ran >= 1, "at least one ABI fixture was found");
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

      Discover (Found, Fixture_Root, Host);
      Landin.Testing.Check_Equal
        (Item, Problem_Count (Found), 0,
         "the fixture tree parses before the selection is run");

      for Index in 1 .. Count (Found) loop
         declare
            Case_Item : constant Fixture := Nth (Found, Index);
         begin
            if Label_Of (Case_Item) = Wanted then
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
                  for Profile in 1 .. Profile_Count (Case_Item) loop
                     Run_Runtime (Case_Item, Host, Program, Profile, Item);
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
        (Item, Ran, 1, Wanted & ": exactly one fixture was selected");
   end Selected_Fixture_Executes;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "fixture execution", "a timeout cannot satisfy a trap",
         A_Timeout_Cannot_Satisfy_A_Trap'Access);
      Landin.Testing.Register
        (Into, "fixture execution", "recorded expectations hold",
         Recorded_Expectations_Hold'Access);
      Landin.Testing.Register
        (Into, "fixture execution", "every positive fixture is emitted",
         Every_Positive_Fixture_Is_Emitted'Access);
      Landin.Testing.Register
        (Into, "fixture execution", "runtime fixtures execute",
         Runtime_Fixtures_Execute'Access);

      if Unbounded.Length (Selected) > 0 then
         Landin.Testing.Register
           (Into, "fixture execution", "selected fixture executes",
            Selected_Fixture_Executes'Access);
      end if;
   end Register;

end Landin.Tests.Fixture_Execution_Suite;
