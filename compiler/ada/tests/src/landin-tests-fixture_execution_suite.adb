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
            Label     : constant String :=
              Class_Directory (Class (Case_Item)) & "/" & Name (Case_Item);
         begin
            if Expect (Case_Item) /= "" then
               Ran := Ran + 1;

               declare
                  Where    : constant String :=
                    Fixture_Root & "/"
                    & Class_Directory (Class (Case_Item)) & "/"
                    & Name (Case_Item) & "/" & Expect (Case_Item);
                  Expected : Unbounded.Unbounded_String;
                  Read     : Landin.Platform.Read_Status;
                  Runner   :
                    Landin.Platform.Native.Tools.Native_Tool_Runner;
                  Outcome  : Landin.Platform.Tool_Result;
               begin
                  Host.Read_File (Where, Expected, Read);

                  if Read /= Landin.Platform.Read_Ok then
                     Landin.Testing.Fail
                       (Item, Label & ": expected file is unreadable");
                  else
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
                     --  A `refine` a signal killed has no status, and
                     --  the field beside it holds zero, so a fixture
                     --  expecting zero would be satisfied by a compiler
                     --  that died after writing the right bytes.
                     Landin.Testing.Check
                       (Item,
                        Outcome.Ended = Landin.Platform.Exited,
                        Label & ": refine returned a status");
                     Landin.Testing.Check_Equal
                       (Item, Outcome.Exit_Code, Status (Case_Item),
                        Label & ": recorded exit status");
                  end if;
               end;
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
   --  A host that cannot finish the target fails rather than skipping.
   --  That is the same rule scripts/env.sh already applies to the pinned
   --  GNAT -- a machine without it is told so and stops, rather than
   --  quietly building nothing -- and compiler/tests/README.md states it
   --  for fixtures directly: an expectation nobody runs is a fault.  The
   --  failure carries refine's own report, which is where L0500's note
   --  says which toolchain would satisfy it.
   ------------------------------------------------------------------

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

               declare
                  Label : constant String :=
                    "runtime/" & Name (Case_Item);
                  Source : constant String :=
                    Fixture_Root & "/runtime/" & Name (Case_Item) & "/"
                    & Landin.Testing.Fixtures.Program (Case_Item);
                  Built : constant String :=
                    Output_Directory & "runtime-" & Name (Case_Item);
                  Runner  :
                    Landin.Platform.Native.Tools.Native_Tool_Runner;
                  Compile : Landin.Platform.Tool_Result;
                  Outcome : Landin.Platform.Tool_Result;
                  Args    : Landin.Platform.Path_List;
                  Nothing : Landin.Platform.Path_List;
               begin
                  Landin.Platform.Add (Args, Source);
                  Landin.Platform.Add (Args, "--emit=exe");
                  Landin.Platform.Add (Args, "-o");
                  Landin.Platform.Add (Args, Built);

                  Runner.Run (Program, Args, Compile,
                              Landin.Platform.Merged);

                  --  How the compile ended is asked before what it
                  --  returned, for the reason above: reading the zero
                  --  beside Signaled would send a stale executable from an
                  --  earlier run to be executed as though it were this
                  --  fixture's answer.
                  if Compile.Ended /= Landin.Platform.Exited then
                     Landin.Testing.Fail
                       (Item,
                        Label & ": refine was stopped before it could"
                        & " produce an executable" & ASCII.LF
                        & Unbounded.To_String (Compile.Output));
                  elsif Compile.Exit_Code /= 0 then
                     Landin.Testing.Fail
                       (Item,
                        Label & ": refine could not produce an executable"
                        & ASCII.LF
                        & Unbounded.To_String (Compile.Output));
                  elsif not Host.Exists (Built) then
                     Landin.Testing.Fail
                       (Item,
                        Label & ": refine reported success and wrote no"
                        & " executable at " & Built);
                  else
                     Runner.Run (Built, Nothing, Outcome,
                                 Landin.Platform.Merged);

                     --  [1960] makes a trap's encoding unstable, so a
                     --  trapping fixture is held to having ended without
                     --  a status and to nothing further: not to a signal
                     --  number, and not to which operation trapped.
                     if Traps (Case_Item) then
                        Landin.Testing.Check
                          (Item,
                           Outcome.Ended = Landin.Platform.Signaled,
                           Label & ": the program trapped rather than"
                           & " returning a status");
                     else
                        Landin.Testing.Check
                          (Item,
                           Outcome.Ended = Landin.Platform.Exited,
                           Label & ": the program returned a status");
                        Landin.Testing.Check_Equal
                          (Item, Outcome.Exit_Code, Status (Case_Item),
                           Label & ": the program's own exit status");
                     end if;
                  end if;
               end;
            end if;
         end;
      end loop;

      --  Without this the case would pass by running nothing, which is
      --  the failure the class exists to prevent.
      Landin.Testing.Check
        (Item, Ran >= 1, "at least one runtime fixture was found");
   end Runtime_Fixtures_Execute;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "fixture execution", "recorded expectations hold",
         Recorded_Expectations_Hold'Access);
      Landin.Testing.Register
        (Into, "fixture execution", "runtime fixtures execute",
         Runtime_Fixtures_Execute'Access);
   end Register;

end Landin.Tests.Fixture_Execution_Suite;
