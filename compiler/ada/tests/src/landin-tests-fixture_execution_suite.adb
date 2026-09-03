--  Fixtures that are run, not merely parsed.
--
--  A recorded expectation nobody compares to anything is not a test, it is
--  a file that looks like one.  Every fixture carrying `expect` and `args`
--  is executed here through the real tool adapter, and its bytes and exit
--  status are compared with what it claims.

with Ada.Strings.Fixed;
with Ada.Environment_Variables;
with Ada.Strings.Unbounded;

with Landin.Platform;
with Landin.Platform.Native;
with Landin.Platform.Native.Tools;
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
         if Text (Index) = ' ' then
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
      Source  : constant String :=
        Fixture_Root & "/positive/" & Name (Case_Item) & "/"
        & Landin.Testing.Fixtures.Program (Case_Item);
      Written : constant String :=
        Output_Directory & "positive-" & Name (Case_Item) & ".s";
      Runner  : Landin.Platform.Native.Tools.Native_Tool_Runner;
      Outcome : Landin.Platform.Tool_Result;
      Args    : Landin.Platform.Path_List;
   begin
      Landin.Platform.Add (Args, Source);
      declare
         Rest : constant String := With_Sources (Case_Item);
         First : Integer := Rest'First;

         procedure Add_One (Named : String);

         procedure Add_One (Named : String) is
            Trimmed : constant String :=
              Ada.Strings.Fixed.Trim (Named, Ada.Strings.Both);
         begin
            if Trimmed /= "" then
               Landin.Platform.Add
                 (Args, Fixture_Root & "/positive/" & Name (Case_Item)
                  & "/" & Trimmed);
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
      Source  : constant String :=
        Fixture_Root & "/" & Label & "/"
        & Landin.Testing.Fixtures.Program (Case_Item);
      Runner  : Landin.Platform.Native.Tools.Native_Tool_Runner;
      Outcome : Landin.Platform.Tool_Result;
      Args    : Landin.Platform.Path_List;
   begin
      Landin.Platform.Add (Args, Source);
      Runner.Run (Program, Args, Outcome, Landin.Platform.Merged);

      Landin.Testing.Check
        (Item, Outcome.Ended = Landin.Platform.Exited,
         Label & ": refine returned a status");
      Landin.Testing.Check_Equal
        (Item, Outcome.Exit_Code, 1, Label & ": the program was refused");
      Landin.Testing.Check_Equal
        (Item, Codes_In (Unbounded.To_String (Outcome.Output)),
         Codes (Case_Item), Label & ": the report carries its pinned codes");
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
   --  Runtime fixtures
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

   procedure Run_Runtime
     (Case_Item : Fixture;
      Host      : Landin.Platform.Filesystem'Class;
      Program   : String;
      Item      : in out Landin.Testing.Context);

   procedure Run_Runtime
     (Case_Item : Fixture;
      Host      : Landin.Platform.Filesystem'Class;
      Program   : String;
      Item      : in out Landin.Testing.Context)
   is
      Label   : constant String := "runtime/" & Name (Case_Item);
      Source  : constant String :=
        Fixture_Root & "/runtime/" & Name (Case_Item) & "/"
        & Landin.Testing.Fixtures.Program (Case_Item);
      Built   : constant String :=
        Output_Directory & "runtime-" & Name (Case_Item);
      Runner  : Landin.Platform.Native.Tools.Native_Tool_Runner;
      Compile : Landin.Platform.Tool_Result;
      Outcome : Landin.Platform.Tool_Result;
      Args    : Landin.Platform.Path_List;
      Runtime_Arguments : Landin.Platform.Path_List;
      Expected : Unbounded.Unbounded_String;
      Read     : Landin.Platform.Read_Status;
   begin
      if Module_Root (Case_Item) = "" then
         Landin.Platform.Add (Args, Source);
      else
         Landin.Platform.Add
           (Args,
            "--root=" & Fixture_Root & "/runtime/" & Name (Case_Item)
            & "/" & Module_Root (Case_Item));
         Landin.Platform.Add
           (Args, Fixture_Root & "/runtime/" & Name (Case_Item));
      end if;

      --  [1840]'s module scope is every file compiled together, so a
      --  fixture that claims something about it hands `refine` more than
      --  one source.
      if Module_Root (Case_Item) = "" then
         declare
            Rest  : constant String := With_Sources (Case_Item);
            First : Integer := Rest'First;

            procedure Add_One (Named : String);

            procedure Add_One (Named : String) is
               Trimmed : constant String :=
                 Ada.Strings.Fixed.Trim (Named, Ada.Strings.Both);
            begin
               if Trimmed /= "" then
                  Landin.Platform.Add
                    (Args,
                     Fixture_Root & "/runtime/" & Name (Case_Item) & "/"
                     & Trimmed);
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
      end if;

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
              (Item, Outcome.Ended = Landin.Platform.Signaled,
               Label & ": the program trapped rather than returning a"
               & " status");
         else
            Landin.Testing.Check
              (Item, Outcome.Ended = Landin.Platform.Exited,
               Label & ": the program returned a status");
            Landin.Testing.Check_Equal
              (Item, Outcome.Exit_Code, Status (Case_Item),
               Label & ": the program's own exit status");
         end if;
      end if;
   end Run_Runtime;

   procedure Runtime_Fixtures_Execute
     (Item : in out Landin.Testing.Context);

   procedure Runtime_Fixtures_Execute
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
            if Class (Case_Item) = Runtime then
               Ran := Ran + 1;
               Run_Runtime (Case_Item, Host, Program, Item);
            end if;
         end;
      end loop;

      --  Without this the case would pass by running nothing, which is
      --  the failure the class exists to prevent.
      Landin.Testing.Check
        (Item, Ran >= 1, "at least one runtime fixture was found");
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

               if Expect (Case_Item) /= "" then
                  Run_Recorded (Case_Item, Host, Program, Item);
               elsif Class (Case_Item) = Positive_Program then
                  Emit_Positive (Case_Item, Host, Program, Item);
               elsif Class (Case_Item) = Negative_Program then
                  Run_Negative (Case_Item, Program, Item);
               elsif Class (Case_Item) = Runtime then
                  Run_Runtime (Case_Item, Host, Program, Item);
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
