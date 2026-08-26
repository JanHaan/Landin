with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Landin.Driver;
with Landin.Platform;
with Landin.Testing.Fakes;

package body Landin.Tests.Driver_Suite is

   package Unbounded renames Ada.Strings.Unbounded;

   function Contains (Text : String; Needle : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Needle) > 0);

   LF : constant Character := Character'Val (10);

   function Arguments_Of (First : String) return Landin.Platform.Path_List;

   --  How many times a needle occurs, which is how a case says a thing was
   --  rendered once rather than on both paths.
   function Occurrences (Text : String; Needle : String) return Natural;

   function Occurrences (Text : String; Needle : String) return Natural is
      Seen : Natural := 0;
      From : Positive := Text'First;
   begin
      loop
         declare
            At_Next : constant Natural :=
              Ada.Strings.Fixed.Index (Text (From .. Text'Last), Needle);
         begin
            exit when At_Next = 0;
            Seen := Seen + 1;
            exit when At_Next + Needle'Length > Text'Last;
            From := At_Next + Needle'Length;
         end;
      end loop;

      return Seen;
   end Occurrences;

   function Both (First, Second : String) return Landin.Platform.Path_List;

   function Both (First, Second : String)
     return Landin.Platform.Path_List
   is
      Result : Landin.Platform.Path_List;
   begin
      Result.Append (First);
      Result.Append (Second);
      return Result;
   end Both;

   function Arguments_Of (First : String) return Landin.Platform.Path_List is
      Result : Landin.Platform.Path_List;
   begin
      Result.Append (First);
      return Result;
   end Arguments_Of;

   procedure No_Arguments_Is_Misuse (Item : in out Landin.Testing.Context);

   procedure No_Arguments_Is_Misuse (Item : in out Landin.Testing.Context) is
      Host   : Landin.Testing.Fakes.Fake_Filesystem;
      Tools  : Landin.Testing.Fakes.Fake_Tool_Runner;
      Empty  : Landin.Platform.Path_List;
      Result : constant Landin.Driver.Outcome :=
        Landin.Driver.Execute (Empty, Host, Tools);
   begin
      Landin.Testing.Check_Equal
        (Item, Result.Status, Landin.Driver.Status_Misuse,
         "no arguments is misuse");
      Landin.Testing.Check
        (Item, Contains (Unbounded.To_String (Result.Output), "usage:"),
         "misuse prints usage");
   end No_Arguments_Is_Misuse;

   procedure Identity_Claims_No_Version
     (Item : in out Landin.Testing.Context);

   procedure Identity_Claims_No_Version
     (Item : in out Landin.Testing.Context)
   is
      Host   : Landin.Testing.Fakes.Fake_Filesystem;
      Tools  : Landin.Testing.Fakes.Fake_Tool_Runner;
      Result : constant Landin.Driver.Outcome :=
        Landin.Driver.Execute (Arguments_Of ("--identify"), Host, Tools);
      Text   : constant String := Unbounded.To_String (Result.Output);
   begin
      Landin.Testing.Check_Equal
        (Item, Result.Status, Landin.Driver.Status_Success,
         "identifying succeeds");
      Landin.Testing.Check
        (Item, Contains (Text, "no release version is assigned"),
         "identity is version neutral");
      Landin.Testing.Check
        (Item,
         Contains
           (Text, "language frontend: scanner, parser, names, types"),
         "identity names the frontend it has");
      Landin.Testing.Check
        (Item, not Contains (Text, "0."),
         "identity carries no version number");
   end Identity_Claims_No_Version;

   procedure Unknown_Options_Are_Diagnosed
     (Item : in out Landin.Testing.Context);

   procedure Unknown_Options_Are_Diagnosed
     (Item : in out Landin.Testing.Context)
   is
      Host   : Landin.Testing.Fakes.Fake_Filesystem;
      Tools  : Landin.Testing.Fakes.Fake_Tool_Runner;
      Result : constant Landin.Driver.Outcome :=
        Landin.Driver.Execute (Arguments_Of ("--wat"), Host, Tools);
      Text   : constant String := Unbounded.To_String (Result.Report);
   begin
      Landin.Testing.Check_Equal
        (Item, Result.Status, Landin.Driver.Status_Misuse,
         "an unknown option is misuse");
      Landin.Testing.Check
        (Item, Contains (Text, "L0002"), "the option code is reported");
      Landin.Testing.Check
        (Item, Contains (Text, "--wat"), "the option is named");
   end Unknown_Options_Are_Diagnosed;

   procedure Missing_Sources_Are_Data (Item : in out Landin.Testing.Context);

   procedure Missing_Sources_Are_Data
     (Item : in out Landin.Testing.Context)
   is
      Host   : Landin.Testing.Fakes.Fake_Filesystem;
      Tools  : Landin.Testing.Fakes.Fake_Tool_Runner;
      Result : constant Landin.Driver.Outcome :=
        Landin.Driver.Execute (Arguments_Of ("absent.ldn"), Host, Tools);
      Text   : constant String := Unbounded.To_String (Result.Report);
   begin
      Landin.Testing.Check_Equal
        (Item, Result.Status, Landin.Driver.Status_Reported,
         "a missing source is reported, not a crash");
      Landin.Testing.Check
        (Item, Contains (Text, "L0003"), "the unreadable code is reported");
      Landin.Testing.Check
        (Item, Contains (Text, "absent.ldn"), "the path is named");
   end Missing_Sources_Are_Data;

   --  The frontend, reached the way a user reaches it.  The suites above
   --  hold the scanner and the parser to the corpus; what this one asserts
   --  is that the driver runs them, and that a syntax diagnostic renders
   --  against the real source -- the snippet and the caret included,
   --  because a span that is right and a caret that is not is still wrong.
   procedure Sources_Are_Scanned_And_Parsed
     (Item : in out Landin.Testing.Context);

   procedure Sources_Are_Scanned_And_Parsed
     (Item : in out Landin.Testing.Context)
   is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
   begin
      Host.Add_File ("main.ldn", "if: u32 = 1" & LF);
      Host.Add_File ("good.ldn", "n: u32 = 1" & LF);

      declare
         Result : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute (Arguments_Of ("main.ldn"), Host, Tools);
         Text   : constant String := Unbounded.To_String (Result.Report);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, Landin.Driver.Status_Reported,
            "a file the grammar refuses is reported");
         Landin.Testing.Check
           (Item, Contains (Text, "L0100"),
            "[1760]: a keyword is not available as a name");
         Landin.Testing.Check
           (Item, Contains (Text, "main.ldn:1:1"),
            "the report points into the source");

         --  The span is the keyword itself, so the caret lands under it
         --  rather than somewhere convenient.
         Landin.Testing.Check
           (Item, Contains (Text, "1 | if: u32 = 1"),
            "the snippet is the source's first line");
         Landin.Testing.Check
           (Item, Contains (Text, LF & "  | ^"),
            "and the caret is under its first byte");
      end;

      declare
         Result : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute (Arguments_Of ("good.ldn"), Host, Tools);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, Landin.Driver.Status_Success,
            "a file the grammar derives is accepted");
         Landin.Testing.Check_Equal
           (Item, Unbounded.To_String (Result.Report), "",
            "and nothing is reported about it");
      end;
   end Sources_Are_Scanned_And_Parsed;

   --  An empty file has no first byte, and `program ::= declaration*`
   --  [1740] derives none of them, so it is a program and it is accepted.
   --  What is worth asserting is that the frontend ran over a file with no
   --  bytes and said nothing, rather than pointing at a position that does
   --  not exist.
   procedure An_Empty_Source_Is_Accepted
     (Item : in out Landin.Testing.Context);

   procedure An_Empty_Source_Is_Accepted
     (Item : in out Landin.Testing.Context)
   is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
   begin
      Host.Add_File ("empty.ldn", "");

      declare
         Result : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute (Arguments_Of ("empty.ldn"), Host, Tools);
         Text   : constant String := Unbounded.To_String (Result.Report);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, Landin.Driver.Status_Success,
            "an empty file is a program with no declarations");
         Landin.Testing.Check_Equal
           (Item, Text, "", "and nothing is reported about it");
      end;
   end An_Empty_Source_Is_Accepted;

   procedure Targets_Are_Selected_By_Name
     (Item : in out Landin.Testing.Context);

   procedure Targets_Are_Selected_By_Name
     (Item : in out Landin.Testing.Context)
   is
      Host  : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Known : constant Landin.Driver.Outcome :=
        Landin.Driver.Execute
          (Arguments_Of ("--target=synthetic-32"), Host, Tools);
      Wrong : constant Landin.Driver.Outcome :=
        Landin.Driver.Execute (Arguments_Of ("--target=vax"), Host, Tools);
   begin
      Landin.Testing.Check_Equal
        (Item, Known.Status, Landin.Driver.Status_Success,
         "a described target is accepted");
      --  The reported name is read back out of the compilation, so this
      --  also asserts that the context was created from the selected
      --  facts rather than from the default host-shaped ones.
      Landin.Testing.Check_Equal
        (Item, Unbounded.To_String (Known.Output),
         "target: synthetic-32" & Character'Val (10),
         "the compilation carries the selected target");
      Landin.Testing.Check_Equal
        (Item, Wrong.Status, Landin.Driver.Status_Reported,
         "an undescribed target is reported");
      Landin.Testing.Check
        (Item, Contains (Unbounded.To_String (Wrong.Report), "L0004"),
         "the unknown target code is used");
      Landin.Testing.Check
        (Item, not Contains (Unbounded.To_String (Wrong.Output), "target:"),
         "a refused target is not announced as selected");
   end Targets_Are_Selected_By_Name;

   --  Help is a documented surface: R0.50 asks for deterministic help, and
   --  nothing exercised it.
   procedure Help_Is_Printed (Item : in out Landin.Testing.Context);

   procedure Help_Is_Printed (Item : in out Landin.Testing.Context) is
      Host   : Landin.Testing.Fakes.Fake_Filesystem;
      Tools  : Landin.Testing.Fakes.Fake_Tool_Runner;
      Asked  : constant Landin.Driver.Outcome :=
        Landin.Driver.Execute (Arguments_Of ("--help"), Host, Tools);
      Bare   : Landin.Platform.Path_List;
   begin
      Landin.Testing.Check_Equal
        (Item, Asked.Status, Landin.Driver.Status_Success,
         "asking for help succeeds");
      Landin.Testing.Check_Equal
        (Item, Unbounded.To_String (Asked.Output), Landin.Driver.Usage,
         "help prints exactly the usage text");
      Landin.Testing.Check
        (Item, Contains (Landin.Driver.Usage, "--target=NAME"),
         "the usage text lists the target option");
      Landin.Testing.Check
        (Item, Contains (Landin.Driver.Usage, "source.ldn"),
         "the usage text says what it takes");

      --  And no arguments prints the same text, with the misuse status.
      declare
         Empty : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute (Bare, Host, Tools);
      begin
         Landin.Testing.Check_Equal
           (Item, Unbounded.To_String (Empty.Output), Landin.Driver.Usage,
            "no arguments prints the same usage text");
      end;
   end Help_Is_Printed;

   --  Help or identity must not excuse a misuse.  `refine --wat --identify`
   --  used to print the identity and exit zero.
   procedure Misuse_Outranks_Help (Item : in out Landin.Testing.Context);

   procedure Misuse_Outranks_Help (Item : in out Landin.Testing.Context) is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;

   begin
      declare
         procedure Refuses (First, Second : String);

         procedure Refuses (First, Second : String) is
            Result : constant Landin.Driver.Outcome :=
              Landin.Driver.Execute (Both (First, Second), Host, Tools);
         begin
            Landin.Testing.Check_Equal
              (Item, Result.Status, Landin.Driver.Status_Misuse,
               First & " " & Second & " keeps the misuse status");
            Landin.Testing.Check
              (Item,
               Contains (Unbounded.To_String (Result.Report), "L0002"),
               First & " " & Second & " still reports the option");
         end Refuses;
      begin
         Refuses ("--wat", "--identify");
         Refuses ("--identify", "--wat");
         Refuses ("--wat", "--help");
         Refuses ("--help", "--wat");
      end;
   end Misuse_Outranks_Help;

   --  The target a compilation gets when nobody asked for one, and the
   --  64-bit target by name.  Both were unpinned: the default could be
   --  changed and the linux-x86-64 branch removed with the suite green.
   procedure Targets_Have_A_Default (Item : in out Landin.Testing.Context);

   procedure Targets_Have_A_Default (Item : in out Landin.Testing.Context) is
      Host     : Landin.Testing.Fakes.Fake_Filesystem;
      Tools    : Landin.Testing.Fakes.Fake_Tool_Runner;
      Named    : constant Landin.Driver.Outcome :=
        Landin.Driver.Execute
          (Arguments_Of ("--target=linux-x86-64"), Host, Tools);
   begin
      Landin.Testing.Check_Equal
        (Item, Unbounded.To_String (Named.Output), "target: linux-x86-64"
         & Character'Val (10),
         "the 64-bit target is selectable by name");

      --  With no --target= the identity is what says which targets exist,
      --  and the driver's default is the first of them.
      Landin.Testing.Check
        (Item, Contains (Landin.Driver.Identity, "linux-x86-64"),
         "the default target is one the identity names");
      Landin.Testing.Check
        (Item, Contains (Landin.Driver.Identity, "synthetic-32"),
         "and so is the synthetic one");
   end Targets_Have_A_Default;

   --  A source that exists and cannot be read is its own branch, and it
   --  was never taken by a test.
   procedure Unreadable_Sources_Are_Reported
     (Item : in out Landin.Testing.Context);

   procedure Unreadable_Sources_Are_Reported
     (Item : in out Landin.Testing.Context)
   is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
   begin
      Host.Add_Unreadable ("locked.ldn");

      declare
         Result : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute (Arguments_Of ("locked.ldn"), Host, Tools);
         Text   : constant String := Unbounded.To_String (Result.Report);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, Landin.Driver.Status_Reported,
            "an unreadable source is reported");
         Landin.Testing.Check
           (Item, Contains (Text, "source not readable: locked.ldn"),
            "and it is distinguished from a missing one");
      end;
   end Unreadable_Sources_Are_Reported;

   --  The exit statuses are an interface: name them, so a change to one is
   --  a change a test notices.
   procedure Exit_Statuses_Are_Fixed (Item : in out Landin.Testing.Context);

   procedure Exit_Statuses_Are_Fixed (Item : in out Landin.Testing.Context) is
   begin
      Landin.Testing.Check_Equal
        (Item, Landin.Driver.Status_Success, 0, "success is zero");
      Landin.Testing.Check_Equal
        (Item, Landin.Driver.Status_Reported, 1, "a report is one");
      Landin.Testing.Check_Equal
        (Item, Landin.Driver.Status_Misuse, 2, "misuse is two");
      --  Sysexits' EX_SOFTWARE, which is what a caller reads to tell the
      --  compiler being wrong from the program being wrong.
      Landin.Testing.Check_Equal
        (Item, Landin.Driver.Status_Defect, 70, "a defect is seventy");
   end Exit_Statuses_Are_Fixed;


   ------------------------------------------------------------------
   --  R1.80: what a request leaves behind
   --
   --  A fake filesystem and a fake tool runner, so the whole path from a
   --  request to an invocation is asserted without a disk or a process.
   --  What is pinned here is the argv and which files exist; that the
   --  toolchain then produces a working program is the runtime fixture's,
   --  and it is the only case that starts one.
   ------------------------------------------------------------------

   Entry_Program : constant String :=
     "public main: () -> (code: i32) =" & LF
     & "    code = 42" & LF
     & "end main" & LF;

   procedure Assembly_Is_Written_Without_A_Tool
     (Item : in out Landin.Testing.Context);

   procedure Assembly_Is_Written_Without_A_Tool
     (Item : in out Landin.Testing.Context)
   is
      Host  : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
   begin
      Host.Add_File ("main.ldn", Entry_Program);

      declare
         Result : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute
             (Both ("main.ldn", "--emit=asm"), Host, Tools);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, Landin.Driver.Status_Success,
            "an accepted program emits and succeeds");
         Landin.Testing.Check_Equal
           (Item, Tools.Run_Count, 0,
            "assembly is the compiler's own work and runs no tool");
         Landin.Testing.Check
           (Item,
            Contains (Host.Written (Landin.Driver.Default_Assembly),
                      "main:"),
            "the default assembly path holds the routine");
      end;
   end Assembly_Is_Written_Without_A_Tool;

   --  The whole invocation, in order.  A containment check would pass on a
   --  command line that had lost its output.
   procedure An_Executable_Runs_The_Triplet_Driver
     (Item : in out Landin.Testing.Context);

   procedure An_Executable_Runs_The_Triplet_Driver
     (Item : in out Landin.Testing.Context)
   is
      Host  : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Args  : Landin.Platform.Path_List;
   begin
      Host.Add_File ("main.ldn", Entry_Program);
      Args.Append ("main.ldn");
      Args.Append ("--emit=exe");
      Args.Append ("-o");
      Args.Append ("main");

      declare
         Result : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute (Args, Host, Tools);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, Landin.Driver.Status_Success,
            "the program is accepted and finished");
         Landin.Testing.Check_Equal
           (Item, Tools.Run_Count, 1, "one invocation and no more");
         Landin.Testing.Check_Equal
           (Item, Unbounded.To_String (Tools.Call_At (1).Program),
            "x86_64-pc-linux-gnu-gcc",
            "the driver is found by the target's triplet");
         Landin.Testing.Check_Equal
           (Item, Landin.Platform.Joined (Tools.Call_At (1).Arguments),
            "main.s" & LF & "-o" & LF & "main" & LF,
            "and is handed the assembly it wrote and the output asked for");
         Landin.Testing.Check
           (Item, Contains (Host.Written ("main.s"), ".globl main"),
            "the assembly beside the output is what it assembles");
      end;
   end An_Executable_Runs_The_Triplet_Driver;

   procedure A_Named_Linker_Reaches_The_Driver
     (Item : in out Landin.Testing.Context);

   procedure A_Named_Linker_Reaches_The_Driver
     (Item : in out Landin.Testing.Context)
   is
      Host  : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Args  : Landin.Platform.Path_List;
   begin
      Host.Add_File ("main.ldn", Entry_Program);
      Args.Append ("main.ldn");
      Args.Append ("--emit=exe");
      Args.Append ("-o");
      Args.Append ("main");
      Args.Append ("--toolchain=x86_64-unknown-linux-gnu-gcc");
      Args.Append ("--linker=mold");

      declare
         Result : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute (Args, Host, Tools);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, Landin.Driver.Status_Success,
            "a named toolchain and linker still succeed");
         --  The spelling a Homebrew cross toolchain installs, which is why
         --  the override exists: the convention would have looked for
         --  x86_64-pc-linux-gnu-gcc and found nothing.
         Landin.Testing.Check_Equal
           (Item, Unbounded.To_String (Tools.Call_At (1).Program),
            "x86_64-unknown-linux-gnu-gcc",
            "a named toolchain wins over the triplet");
         Landin.Testing.Check_Equal
           (Item, Landin.Platform.Joined (Tools.Call_At (1).Arguments),
            "main.s" & LF & "-o" & LF & "main" & LF & "-fuse-ld=mold" & LF,
            "and the linker rides through as one more argument");
      end;
   end A_Named_Linker_Reaches_The_Driver;

   --  [1970] is required before anything is written, so a program that
   --  could never be linked leaves no file behind on the way to saying so.
   procedure A_Hosted_Program_Needs_Its_Entry
     (Item : in out Landin.Testing.Context);

   procedure A_Hosted_Program_Needs_Its_Entry
     (Item : in out Landin.Testing.Context)
   is
      Host  : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
   begin
      Host.Add_File
        ("lib.ldn",
         "public f: () -> (r: i32) =" & LF
         & "    r = 1" & LF & "end f" & LF);

      declare
         Result : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute
             (Both ("lib.ldn", "--emit=exe"), Host, Tools);
         Report : constant String := Unbounded.To_String (Result.Report);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, Landin.Driver.Status_Reported,
            "a module with no entry cannot be an executable");
         Landin.Testing.Check
           (Item, Contains (Report, "L0502"), "and says which rule");
         Landin.Testing.Check_Equal
           (Item, Tools.Run_Count, 0, "no tool is run");
         Landin.Testing.Check_Equal
           (Item, Host.Written (Landin.Driver.Default_Executable & ".s"),
            "", "and nothing was written first");
      end;
   end A_Hosted_Program_Needs_Its_Entry;

   procedure A_Failing_Toolchain_Is_Reported
     (Item : in out Landin.Testing.Context);

   procedure A_Failing_Toolchain_Is_Reported
     (Item : in out Landin.Testing.Context)
   is
      Host  : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
   begin
      Host.Add_File ("main.ldn", Entry_Program);
      Tools.Set_Result (1, "as: unrecognised opcode");

      declare
         Result : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute
             (Both ("main.ldn", "--emit=exe"), Host, Tools);
         Report : constant String := Unbounded.To_String (Result.Report);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, Landin.Driver.Status_Reported,
            "a toolchain that failed is a reported failure");
         Landin.Testing.Check
           (Item, Contains (Report, "L0501"), "and says which rule");
         Landin.Testing.Check
           (Item, Contains (Report, "as: unrecognised opcode"),
            "carrying what the tool actually said");
      end;
   end A_Failing_Toolchain_Is_Reported;

   --  A tool a signal killed has no exit status at all, and reading the one
   --  beside it would read zero.  The driver asks how the run ended before
   --  it asks what it returned, or an assembler that died would be a
   --  success that wrote nothing.
   procedure A_Killed_Toolchain_Is_Reported
     (Item : in out Landin.Testing.Context);

   procedure A_Killed_Toolchain_Is_Reported
     (Item : in out Landin.Testing.Context)
   is
      Host  : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
   begin
      Host.Add_File ("main.ldn", Entry_Program);
      Tools.Set_Result (0, "", Landin.Platform.Signaled);

      declare
         Result : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute
             (Both ("main.ldn", "--emit=exe"), Host, Tools);
         Report : constant String := Unbounded.To_String (Result.Report);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, Landin.Driver.Status_Reported,
            "a toolchain a signal killed is a reported failure");
         Landin.Testing.Check
           (Item, Contains (Report, "L0501"), "and says which rule");
         Landin.Testing.Check
           (Item, not Contains (Report, "status 0"),
            "without claiming it returned a status");
      end;
   end A_Killed_Toolchain_Is_Reported;

   --  [1650] hands six integer arguments in registers and the rest on the
   --  stack, and this backend has only the first half.  Nothing in the
   --  kernel bounds a parameter list, so a seventh is a program the
   --  frontend accepts and the backend cannot emit -- which must be a
   --  report naming the parameter, and not an internal defect.
   procedure A_Seventh_Parameter_Is_Reported
     (Item : in out Landin.Testing.Context);

   procedure A_Seventh_Parameter_Is_Reported
     (Item : in out Landin.Testing.Context)
   is
      Host  : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
   begin
      Host.Add_File
        ("wide.ldn",
         "seven: (a: i32, b: i32, c: i32, d: i32, e: i32, f: i32,"
         & " g: i32) -> (r: i32) =" & LF
         & "    r = a + g" & LF
         & "end seven" & LF);

      declare
         Result : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute
             (Both ("wide.ldn", "--emit=asm"), Host, Tools);
         Report : constant String := Unbounded.To_String (Result.Report);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, Landin.Driver.Status_Reported,
            "a seventh parameter is a reported refusal");
         Landin.Testing.Check
           (Item, Contains (Report, "L0503"), "and says which rule");
         Landin.Testing.Check
           (Item, Contains (Report, "seven"),
            "naming the routine that has one");
         Landin.Testing.Check
           (Item, not Host.Exists ("wide.s"),
            "and nothing is written");
      end;
   end A_Seventh_Parameter_Is_Reported;

   procedure A_Frame_Outside_Its_Encoding_Is_Reported
     (Item : in out Landin.Testing.Context);

   procedure A_Frame_Outside_Its_Encoding_Is_Reported
     (Item : in out Landin.Testing.Context)
   is
      Host  : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
   begin
      Host.Add_File
        ("wide.ldn",
         "edge: () -> none =" & LF
         & "    mut bytes: [2147483648]u8" & LF
         & "end edge" & LF
         & "overflow: () -> none =" & LF
         & "    mut bytes: [18446744073709551615]u8" & LF
         & "end overflow" & LF);

      declare
         Result : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute
             (Both ("wide.ldn", "--emit=asm"), Host, Tools);
         Report : constant String := Unbounded.To_String (Result.Report);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, Landin.Driver.Status_Reported,
            "an unencodable frame is a reported refusal");
         Landin.Testing.Check
           (Item, Contains (Report, "L0504"), "and says which limit");
         Landin.Testing.Check
           (Item,
            Contains (Report, "edge") and then Contains (Report, "overflow"),
            "naming both the encoding edge and target-width overflow");
         Landin.Testing.Check
           (Item, not Host.Exists ("wide.s"), "and writes nothing");
      end;
   end A_Frame_Outside_Its_Encoding_Is_Reported;

   --  A target with no backend cannot be asked for a file at all, which is
   --  the same fact Landin.Targets.Capabilities already states.
   procedure A_Target_With_No_Backend_Emits_Nothing
     (Item : in out Landin.Testing.Context);

   procedure A_Target_With_No_Backend_Emits_Nothing
     (Item : in out Landin.Testing.Context)
   is
      Host  : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Args  : Landin.Platform.Path_List;
   begin
      Host.Add_File ("main.ldn", Entry_Program);
      Args.Append ("main.ldn");
      Args.Append ("--emit=asm");
      Args.Append ("--target=synthetic-32");

      declare
         Result : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute (Args, Host, Tools);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, Landin.Driver.Status_Reported,
            "synthetic-32 has no backend and so no output");
         Landin.Testing.Check
           (Item, Contains (Unbounded.To_String (Result.Report), "L0500"),
            "and says which rule");
      end;
   end A_Target_With_No_Backend_Emits_Nothing;

   --  A refused program is not emitted, for the same reason the lowering
   --  refuses to run on one: a file written from a failed compilation is a
   --  plausible artefact of nothing.
   --  A defect is the compiler failing, not the program being wrong, and
   --  the two arrive together: by the time one is raised the run has
   --  usually already decided several things about the source.  Losing
   --  those leaves a user with `internal compiler defect` and nothing to
   --  act on, when the report already held the sentence that mattered.
   --
   --  The unknown option is what puts a diagnostic in the report before
   --  anything is read, and the read is where the defect is injected: a
   --  tool runs only on a compilation that was not refused, so a defect
   --  there could never have one before it.
   procedure A_Defect_Keeps_What_Was_Reported
     (Item : in out Landin.Testing.Context);

   procedure A_Defect_Keeps_What_Was_Reported
     (Item : in out Landin.Testing.Context)
   is
      Host  : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
   begin
      Host.Add_File
        ("fine.ldn",
         "public main: () -> (code: i32) =" & LF
         & "    code = 0" & LF & "end main" & LF);
      Host.Raise_On_Read;

      declare
         Result : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute
             (Both ("--wat", "fine.ldn"), Host, Tools);
         Report : constant String := Unbounded.To_String (Result.Report);
      begin
         Landin.Testing.Check
           (Item, Contains (Report, "L0002"),
            "what the run had already reported survives the defect");
         Landin.Testing.Check
           (Item, Contains (Report, "internal compiler defect"),
            "and the defect is written under it");
         Landin.Testing.Check_Equal
           (Item, Result.Status, Landin.Driver.Status_Defect,
            "and the status says the compiler failed, not the program");

         --  Once each: the report is rendered on one path or the other
         --  and never on both.
         Landin.Testing.Check_Equal
           (Item, Occurrences (Report, "L0002"), 1,
            "the diagnostic is not rendered twice");
         Landin.Testing.Check_Equal
           (Item, Occurrences (Report, "internal compiler defect"), 1,
            "and neither is the defect");
      end;
   end A_Defect_Keeps_What_Was_Reported;

   --  The regression the driver's promise was found through: a struct one
   --  of whose fields was refused has no layout, and reading a field that
   --  is fine used to ask it for one.  Kept as a case because it is what
   --  a user was left holding when the report went missing.
   procedure A_Struct_Missing_Its_Layout_Is_Reported
     (Item : in out Landin.Testing.Context);

   procedure A_Struct_Missing_Its_Layout_Is_Reported
     (Item : in out Landin.Testing.Context)
   is
      Host  : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
   begin
      Host.Add_File
        ("holed.ldn",
         "inner: type = struct" & LF
         & "    q: u32" & LF
         & "end inner" & LF
         & "outer: type = struct" & LF
         & "    part: inner" & LF
         & "    count: u32" & LF
         & "end outer" & LF
         & "mut here: outer" & LF
         & "f: () -> (r: u32) =" & LF
         & "    r = here.count" & LF
         & "end f" & LF);

      declare
         Result : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute
             (Arguments_Of ("holed.ldn"), Host, Tools);
         Report : constant String := Unbounded.To_String (Result.Report);
      begin
         Landin.Testing.Check
           (Item, Contains (Report, "L0304"),
            "the field that stopped the layout is what is reported");
         Landin.Testing.Check
           (Item, not Contains (Report, "internal compiler defect"),
            "and reading another field of it is not a defect");
         Landin.Testing.Check_Equal
           (Item, Result.Status, Landin.Driver.Status_Reported,
            "so the program is refused rather than the compiler failing");
      end;
   end A_Struct_Missing_Its_Layout_Is_Reported;

   --  And the same promise where the defect is the compiler's own: a run
   --  that raises hands back a status rather than escaping, so the caller
   --  prints one sentence instead of an unhandled exception.
   procedure A_Defect_Is_A_Status_And_Not_An_Escape
     (Item : in out Landin.Testing.Context);

   procedure A_Defect_Is_A_Status_And_Not_An_Escape
     (Item : in out Landin.Testing.Context)
   is
      Host  : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
   begin
      Host.Add_File
        ("fine.ldn",
         "public main: () -> (code: i32) =" & LF
         & "    code = 0" & LF & "end main" & LF);
      Tools.Raise_On_Run;

      declare
         Result : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute
             (Both ("fine.ldn", "--emit=exe"), Host, Tools);
         Report : constant String := Unbounded.To_String (Result.Report);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, Landin.Driver.Status_Defect,
            "a defect is its own status");
         Landin.Testing.Check
           (Item, Contains (Report, "internal compiler defect"),
            "and says so where a reader is looking");
      end;
   end A_Defect_Is_A_Status_And_Not_An_Escape;

   procedure A_Refused_Program_Writes_Nothing
     (Item : in out Landin.Testing.Context);

   procedure A_Refused_Program_Writes_Nothing
     (Item : in out Landin.Testing.Context)
   is
      Host  : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
   begin
      Host.Add_File
        ("bad.ldn",
         "public main: () -> (code: i32) =" & LF
         & "    code = nowhere" & LF & "end main" & LF);

      declare
         Result : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute
             (Both ("bad.ldn", "--emit=exe"), Host, Tools);
         Report : constant String := Unbounded.To_String (Result.Report);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, Landin.Driver.Status_Reported,
            "the program is refused");
         Landin.Testing.Check_Equal
           (Item, Tools.Run_Count, 0, "and no tool is run");
         Landin.Testing.Check_Equal
           (Item, Host.Written (Landin.Driver.Default_Executable & ".s"),
            "", "and nothing is written");

         --  The assertion that makes the guard load-bearing.  Without it
         --  the backend still refuses -- a refused program has an empty
         --  Unit, so [1970]'s entry is missing from it -- and the reader
         --  gets a second complaint about an entry point on a program
         --  whose actual fault is an unknown name.  That is the noise the
         --  pipeline's stop-at-the-first-refusal exists to prevent, and
         --  a report is where it would show up rather than a file.
         Landin.Testing.Check
           (Item, Contains (Report, "L0201"),
            "the unknown name is what is reported");
         Landin.Testing.Check
           (Item, not Contains (Report, "L0502"),
            "and a refused program is not also asked for an entry");
      end;
   end A_Refused_Program_Writes_Nothing;

   --  `-o` takes the argument after it, so a `-o` with nothing after it is
   --  an unfinished request rather than a request to write to "".
   procedure A_Dangling_Output_Is_Misuse
     (Item : in out Landin.Testing.Context);

   procedure A_Dangling_Output_Is_Misuse
     (Item : in out Landin.Testing.Context)
   is
      Host  : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
   begin
      Host.Add_File ("main.ldn", Entry_Program);

      declare
         Dangling : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute (Both ("main.ldn", "-o"), Host, Tools);
         Unknown : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute
             (Both ("main.ldn", "--emit=wat"), Host, Tools);
      begin
         Landin.Testing.Check_Equal
           (Item, Dangling.Status, Landin.Driver.Status_Misuse,
            "a -o with nothing after it is misuse");
         Landin.Testing.Check_Equal
           (Item, Unknown.Status, Landin.Driver.Status_Misuse,
            "and so is an --emit nobody defined");
      end;
   end A_Dangling_Output_Is_Misuse;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "driver", "no arguments is misuse",
         No_Arguments_Is_Misuse'Access);
      Landin.Testing.Register
        (Into, "driver", "identity claims no version",
         Identity_Claims_No_Version'Access);
      Landin.Testing.Register
        (Into, "driver", "unknown options are diagnosed",
         Unknown_Options_Are_Diagnosed'Access);
      Landin.Testing.Register
        (Into, "driver", "missing sources are data",
         Missing_Sources_Are_Data'Access);
      Landin.Testing.Register
        (Into, "driver", "sources are scanned and parsed",
         Sources_Are_Scanned_And_Parsed'Access);
      Landin.Testing.Register
        (Into, "driver", "targets are selected by name",
         Targets_Are_Selected_By_Name'Access);
      Landin.Testing.Register
        (Into, "driver", "help is printed", Help_Is_Printed'Access);
      Landin.Testing.Register
        (Into, "driver", "misuse outranks help",
         Misuse_Outranks_Help'Access);
      Landin.Testing.Register
        (Into, "driver", "targets have a default",
         Targets_Have_A_Default'Access);
      Landin.Testing.Register
        (Into, "driver", "unreadable sources are reported",
         Unreadable_Sources_Are_Reported'Access);
      Landin.Testing.Register
        (Into, "driver", "exit statuses are fixed",
         Exit_Statuses_Are_Fixed'Access);
      Landin.Testing.Register
        (Into, "driver", "an empty source is accepted",
         An_Empty_Source_Is_Accepted'Access);
      Landin.Testing.Register
        (Into, "driver", "assembly is written without a tool",
         Assembly_Is_Written_Without_A_Tool'Access);
      Landin.Testing.Register
        (Into, "driver", "an executable runs the triplet driver",
         An_Executable_Runs_The_Triplet_Driver'Access);
      Landin.Testing.Register
        (Into, "driver", "a named linker reaches the driver",
         A_Named_Linker_Reaches_The_Driver'Access);
      Landin.Testing.Register
        (Into, "driver", "a hosted program needs its entry",
         A_Hosted_Program_Needs_Its_Entry'Access);
      Landin.Testing.Register
        (Into, "driver", "a failing toolchain is reported",
         A_Failing_Toolchain_Is_Reported'Access);
      Landin.Testing.Register
        (Into, "driver", "a killed toolchain is reported",
         A_Killed_Toolchain_Is_Reported'Access);
      Landin.Testing.Register
        (Into, "driver", "a seventh parameter is reported",
         A_Seventh_Parameter_Is_Reported'Access);
      Landin.Testing.Register
        (Into, "driver", "a frame outside its encoding is reported",
         A_Frame_Outside_Its_Encoding_Is_Reported'Access);
      Landin.Testing.Register
        (Into, "driver", "a target with no backend emits nothing",
         A_Target_With_No_Backend_Emits_Nothing'Access);
      Landin.Testing.Register
        (Into, "driver", "a defect is a status and not an escape",
         A_Defect_Is_A_Status_And_Not_An_Escape'Access);
      Landin.Testing.Register
        (Into, "driver", "a defect keeps what was reported",
         A_Defect_Keeps_What_Was_Reported'Access);
      Landin.Testing.Register
        (Into, "driver", "a struct missing its layout is reported",
         A_Struct_Missing_Its_Layout_Is_Reported'Access);
      Landin.Testing.Register
        (Into, "driver", "a refused program writes nothing",
         A_Refused_Program_Writes_Nothing'Access);
      Landin.Testing.Register
        (Into, "driver", "a dangling output is misuse",
         A_Dangling_Output_Is_Misuse'Access);
   end Register;

end Landin.Tests.Driver_Suite;
