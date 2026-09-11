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
           (Text,
            "language frontend: scanner, parser, names, types, "
            & "definite assignment"),
         "identity names the frontend it has");
      Landin.Testing.Check
        (Item,
         Contains
           (Text, "backend: linux-x86-64 assembly"),
         "identity names the assembly backend it has");
      Landin.Testing.Check
        (Item,
         Contains
           (Text,
            "executable output: assembled and linked by a"
            & " GNU-triplet-selected toolchain"),
         "identity explains how executable output is produced");
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

   --  R4.21: an emission request without a source, and an empty root,
   --  are misuse rather than a silent success or a search from `/`.
   procedure Emission_Without_Sources_Is_Misuse
     (Item : in out Landin.Testing.Context);

   procedure Emission_Without_Sources_Is_Misuse
     (Item : in out Landin.Testing.Context)
   is
      Host   : Landin.Testing.Fakes.Fake_Filesystem;
      Tools  : Landin.Testing.Fakes.Fake_Tool_Runner;
      Emit   : Landin.Platform.Path_List := Arguments_Of ("--emit=exe");
      Rooted : constant Landin.Platform.Path_List := Arguments_Of ("--root=");
   begin
      Emit.Append ("-o");
      Emit.Append ("app");
      declare
         Result : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute (Emit, Host, Tools);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, Landin.Driver.Status_Misuse,
            "emitting with no source is misuse");
         Landin.Testing.Check
           (Item,
            Contains (Unbounded.To_String (Result.Report),
                      "need a source"),
            "the report says what was missing");
      end;
      declare
         Result : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute (Rooted, Host, Tools);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, Landin.Driver.Status_Misuse,
            "an empty root is misuse");
         Landin.Testing.Check
           (Item,
            Contains (Unbounded.To_String (Result.Report),
                      "names no directory"),
            "the report says the root is empty");
      end;
   end Emission_Without_Sources_Is_Misuse;

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

   ------------------------------------------------------------------
   --  R3.10: directory modules and ordered roots
   ------------------------------------------------------------------

   procedure Reachable_Modules_Are_Loaded
     (Item : in out Landin.Testing.Context);

   procedure Reachable_Modules_Are_Loaded
     (Item : in out Landin.Testing.Context)
   is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Args : Landin.Platform.Path_List;
   begin
      Host.Add_Directory ("entry");
      Host.Add_Directory ("root");
      Host.Add_Directory ("root/math");
      Host.Add_File
        ("entry/main.ldn",
         "import math" & LF
         & "public main: () -> (code: i32) =" & LF
         & "    copy: math.number = math.answer()" & LF
         & "    made: math.point = math.point(value: copy)" & LF
         & "    code = made.value" & LF
         & "end main" & LF);
      Host.Add_File
        ("root/math/answer.ldn",
         "public number: type = i32" & LF
         & "public point: type = struct" & LF
         & "    value: number" & LF
         & "end point" & LF
         & "public answer: () -> (value: number) =" & LF
         & "    value = helper()" & LF
         & "end answer" & LF);
      Host.Add_File
        ("root/math/helper.ldn",
         "helper: () -> (value: i32) =" & LF
         & "    value = 42" & LF
         & "end helper" & LF);
      Args.Append ("--root=root");
      Args.Append ("entry");

      declare
         Result : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute (Args, Host, Tools);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, Landin.Driver.Status_Success,
            "a public function in a reached module is callable");
         Landin.Testing.Check_Equal
           (Item, Unbounded.To_String (Result.Report), "",
            "the reachable program reports nothing");
      end;
   end Reachable_Modules_Are_Loaded;

   procedure Roots_Are_Searched_In_Order
     (Item : in out Landin.Testing.Context);

   procedure Roots_Are_Searched_In_Order
     (Item : in out Landin.Testing.Context)
   is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Args : Landin.Platform.Path_List;
   begin
      Host.Add_Directory ("entry");
      Host.Add_Directory ("first");
      Host.Add_Directory ("first/lib");
      Host.Add_Directory ("second");
      Host.Add_Directory ("second/lib");
      Host.Add_File
        ("entry/main.ldn",
         "import lib" & LF
         & "public main: () -> (code: i32) =" & LF
         & "    code = lib.answer()" & LF
         & "end main" & LF);
      Host.Add_File
        ("first/lib/good.ldn",
         "public answer: () -> (value: i32) =" & LF
         & "    value = 1" & LF
         & "end answer" & LF);
      Host.Add_File ("second/lib/bad.ldn", "if: i32 = 0" & LF);
      Args.Append ("--root=first");
      Args.Append ("--root=second");
      Args.Append ("entry");

      declare
         Result : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute (Args, Host, Tools);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, Landin.Driver.Status_Success,
            "the first root wins for one logical module name");
      end;
   end Roots_Are_Searched_In_Order;

   procedure Private_Imported_Names_Are_Diagnosed
     (Item : in out Landin.Testing.Context);

   procedure Private_Imported_Names_Are_Diagnosed
     (Item : in out Landin.Testing.Context)
   is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Args : Landin.Platform.Path_List;
   begin
      Host.Add_Directory ("entry");
      Host.Add_Directory ("root");
      Host.Add_Directory ("root/lib");
      Host.Add_File
        ("entry/main.ldn",
         "import lib" & LF & "seen: i32 = lib.hidden" & LF);
      Host.Add_File ("root/lib/private.ldn", "hidden: i32 = 7" & LF);
      Args.Append ("--root=root");
      Args.Append ("entry");

      declare
         Result : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute (Args, Host, Tools);
         Report : constant String := Unbounded.To_String (Result.Report);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, Landin.Driver.Status_Reported,
            "a private member is not visible across modules");
         Landin.Testing.Check
           (Item, Contains (Report, "L0202"),
            "the inaccessible-name diagnostic owns the refusal");
         Landin.Testing.Check
           (Item, Contains (Report, "root/lib/private.ldn:1"),
            "the declaration is related to the report");
      end;
   end Private_Imported_Names_Are_Diagnosed;

   procedure Missing_Modules_Are_Diagnosed
     (Item : in out Landin.Testing.Context);

   procedure Missing_Modules_Are_Diagnosed
     (Item : in out Landin.Testing.Context)
   is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Args : Landin.Platform.Path_List;
   begin
      Host.Add_Directory ("entry");
      Host.Add_Directory ("root");
      Host.Add_File ("entry/main.ldn", "import absent" & LF);
      Args.Append ("--root=root");
      Args.Append ("entry");

      declare
         Result : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute (Args, Host, Tools);
         Report : constant String := Unbounded.To_String (Result.Report);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, Landin.Driver.Status_Reported,
            "an absent imported module is reported");
         Landin.Testing.Check
           (Item, Contains (Report, "L0006"),
            "the missing-module diagnostic owns the refusal");
      end;
   end Missing_Modules_Are_Diagnosed;

   procedure Invalid_Entry_Modules_Are_Diagnosed
     (Item : in out Landin.Testing.Context);

   procedure Invalid_Entry_Modules_Are_Diagnosed
     (Item : in out Landin.Testing.Context)
   is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Args : Landin.Platform.Path_List;
   begin
      Host.Add_Directory ("root");
      Host.Add_File ("entry.ldn", "value: i32 = 1" & LF);
      Args.Append ("--root=root");
      Args.Append ("entry.ldn");

      declare
         Result : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute (Args, Host, Tools);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, Landin.Driver.Status_Reported,
            "a rooted entry must be a directory");
         Landin.Testing.Check
           (Item, Contains (Unbounded.To_String (Result.Report), "L0007"),
            "the invalid-module-directory code is reported");
      end;
   end Invalid_Entry_Modules_Are_Diagnosed;

   procedure Imported_Main_Is_Not_The_Entry
     (Item : in out Landin.Testing.Context);

   procedure Imported_Main_Is_Not_The_Entry
     (Item : in out Landin.Testing.Context)
   is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Args : Landin.Platform.Path_List;
   begin
      Host.Add_Directory ("entry");
      Host.Add_Directory ("root");
      Host.Add_Directory ("root/lib");
      Host.Add_File
        ("entry/start.ldn",
         "import lib" & LF
         & "public start: () -> (code: i32) =" & LF
         & "    code = lib.answer()" & LF
         & "end start" & LF);
      Host.Add_File
        ("root/lib/main.ldn",
         "public answer: () -> (value: i32) =" & LF
         & "    value = 1" & LF
         & "end answer" & LF
         & "public main: () -> (code: i32) =" & LF
         & "    code = 42" & LF
         & "end main" & LF);
      Args.Append ("--root=root");
      Args.Append ("--emit=exe");
      Args.Append ("entry");

      declare
         Result : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute (Args, Host, Tools);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, Landin.Driver.Status_Reported,
            "a main outside the entry module is not selected");
         Landin.Testing.Check
           (Item, Contains (Unbounded.To_String (Result.Report), "L0502"),
            "the ordinary missing-entry diagnostic is reported");
      end;
   end Imported_Main_Is_Not_The_Entry;

   procedure Reached_Conformances_Share_One_Register
     (Item : in out Landin.Testing.Context);

   procedure Reached_Conformances_Share_One_Register
     (Item : in out Landin.Testing.Context)
   is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Args : Landin.Platform.Path_List;
   begin
      Host.Add_Directory ("entry");
      Host.Add_Directory ("root");
      Host.Add_Directory ("root/a");
      Host.Add_Directory ("root/b");
      Host.Add_Directory ("root/shared");
      Host.Add_File
        ("entry/main.ldn", "import a" & LF & "import b" & LF);
      Host.Add_File
        ("root/a/a.ldn",
         "import shared" & LF & "i32 is shared.ordered ()" & LF);
      Host.Add_File
        ("root/b/b.ldn",
         "import shared" & LF & "i32 is shared.ordered ()" & LF);
      Host.Add_File
        ("root/shared/concept.ldn",
         "public ordered: type = concept (t: type)" & LF
         & "end ordered" & LF);
      Args.Append ("--root=root");
      Args.Append ("entry");

      declare
         Result : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute (Args, Host, Tools);
         Report : constant String := Unbounded.To_String (Result.Report);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, Landin.Driver.Status_Reported,
            "colliding conformances in separate modules are refused");
         Landin.Testing.Check
           (Item, Contains (Report, "L0317"),
            "the whole-program conformance collision is reported");
         Landin.Testing.Check
           (Item, Contains (Report, "root/a/a.ldn:2")
             and then Contains (Report, "root/b/b.ldn:2"),
            "both module declarations participate in the report");
      end;
   end Reached_Conformances_Share_One_Register;

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

   procedure Caller_Files_Are_Separate
     (Item : in out Landin.Testing.Context);

   procedure Caller_Files_Are_Separate
     (Item : in out Landin.Testing.Context)
   is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Path : constant String := "caller:" & Character'Val (34) & ".ldn";
      Program : constant String :=
        "site: type = struct" & LF
        & " file_id: u32 line: u32 column: u32" & LF
        & "end site" & LF
        & "capture: (caller where: site) -> (value: u32) =" & LF
        & " value = where.line end capture" & LF
        & "public main: () -> (code: i32) =" & LF
        & " code = i32(capture() + capture()) end main" & LF;
      Args : constant Landin.Platform.Path_List := Both (Path, "--emit=exe");
      Result : Landin.Driver.Outcome;
      Original : Unbounded.Unbounded_String;
      Original_Assembly : Unbounded.Unbounded_String;
   begin
      Host.Add_File (Path, Program);
      Result := Landin.Driver.Execute (Args, Host, Tools);
      Landin.Testing.Check_Equal
        (Item, Result.Status, Landin.Driver.Status_Success,
         "a caller program emits its code and file map");
      declare
         Map : constant String := Host.Written
           (Landin.Driver.Source_Map_Beside
              (Landin.Driver.Default_Executable));
         Marker : constant String := """build_id"":""";
         First : constant Natural := Ada.Strings.Fixed.Index (Map, Marker)
           + Marker'Length;
      begin
         Original := Unbounded.To_Unbounded_String (Map);
         Original_Assembly := Unbounded.To_Unbounded_String
           (Host.Written ("a.out.s"));
         Landin.Testing.Check
           (Item, Contains (Map, "63616c6c65723a222e6c646e"),
            "the off-target map preserves colons and quotes as path bytes");
         Landin.Testing.Check_Equal
           (Item, Occurrences (Map, """file_id"":"), 1,
            "two sites share one filename entry");
         Landin.Testing.Check
           (Item, Contains
              (Landin.Platform.Joined (Tools.Call_At (1).Arguments),
               "-Wl,--build-id=0x" & Map (First .. First + 63)),
            "the linker receives the source map's build identity");
         Landin.Testing.Check
           (Item, not Contains (Host.Written ("a.out.s"), Path)
              and then not Contains (Host.Written ("a.out.s"), ".rodata"),
            "caller coordinates create no source strings or static datums");
      end;
      for Changed in Boolean loop
         declare
            Fresh : Landin.Testing.Fakes.Fake_Filesystem;
         begin
            Fresh.Add_File
              (Path, Program
               & (if Changed then "-- changed source" & LF else ""));
            Result := Landin.Driver.Execute (Args, Fresh, Tools);
            Landin.Testing.Check_Equal
              (Item, Result.Status, Landin.Driver.Status_Success,
               "the repeated or changed source emits successfully");
            Landin.Testing.Check
              (Item, (Fresh.Written ("a.out.sources.json")
                 /= Unbounded.To_String (Original)) = Changed,
               "only a changed source changes the mapping identity");
            Landin.Testing.Check
              (Item, (Fresh.Written ("a.out.s")
                 /= Unbounded.To_String (Original_Assembly)) = Changed,
               "assembly identity includes changes that do not alter code");
         end;
      end loop;
   end Caller_Files_Are_Separate;

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

   --  R2.30 retires the register-only backend limit.  A routine with a
   --  seventh scalar parameter is ordinary accepted input to emission, not
   --  a backend refusal.
   procedure A_Seventh_Parameter_Is_Emitted
     (Item : in out Landin.Testing.Context);

   procedure A_Seventh_Parameter_Is_Emitted
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
           (Item, Result.Status, Landin.Driver.Status_Success,
            "a seventh parameter is emitted");
         Landin.Testing.Check
           (Item, Report'Length = 0, "without a backend refusal");
         Landin.Testing.Check
           (Item,
            Contains
              (Host.Written (Landin.Driver.Default_Assembly),
               "movl 16(%rbp), %eax"),
            "and assembly for the stack parameter is written");
      end;
   end A_Seventh_Parameter_Is_Emitted;

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
         & "end overflow" & LF
         & "wide: type = struct" & LF
         & "    bytes: [2147483648]u8" & LF
         & "end wide" & LF
         & "nested: () -> none =" & LF
         & "    mut item: wide" & LF
         & "end nested" & LF);

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
            Contains (Report, "edge")
              and then Contains (Report, "overflow")
              and then Contains (Report, "nested"),
            "naming the array, target-width and nested-field frames");
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
         "outer: type = struct" & LF
         & "    part: f16" & LF
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

   --  Output failure is injected through the platform seam: native
   --  permissions are host policy and cannot make a deterministic case.
   procedure An_Unwritable_Output_Is_Reported
     (Item : in out Landin.Testing.Context);

   procedure An_Unwritable_Output_Is_Reported
     (Item : in out Landin.Testing.Context)
   is
      Host  : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
   begin
      Host.Add_File ("main.ldn", Entry_Program);
      Host.Refuse_Writes;

      declare
         Result : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute
             (Both ("main.ldn", "--emit=asm"), Host, Tools);
         Report : constant String := Unbounded.To_String (Result.Report);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, Landin.Driver.Status_Reported,
            "an output write failure is reported");
         Landin.Testing.Check
           (Item, Contains (Report, "L0005"), "with the output code");
         Landin.Testing.Check_Equal
           (Item, Host.Written (Landin.Driver.Default_Assembly), "",
            "and no bytes are retained");
      end;
   end An_Unwritable_Output_Is_Reported;

   procedure Fixed_Options_Are_Deterministic
     (Item : in out Landin.Testing.Context);

   procedure Fixed_Options_Are_Deterministic
     (Item : in out Landin.Testing.Context)
   is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Args : Landin.Platform.Path_List;
   begin
      Host.Add_File
        ("a.ldn", "option next: u32 = count + 1" & LF
         & "compiler.assert(next == 6)" & LF
         & "compiler.assert(compiler.build_mode == release)" & LF
         & "fixed if enabled and next == 6 then" & LF
         & "answer: i32 = 42" & LF
         & "else" & LF & "answer: missing = nope()" & LF & "end if" & LF);
      Host.Add_File
        ("b.ldn", "option count: u32 = 2" & LF
         & "option enabled: bool = false" & LF);
      Args.Append ("--option=count=5");
      Args.Append ("--build-mode=release");
      Args.Append ("--option=enabled=true");
      Args.Append ("a.ldn");
      Args.Append ("b.ldn");
      for Pass in 1 .. 2 loop
         declare
            Result : constant Landin.Driver.Outcome :=
              Landin.Driver.Execute (Args, Host, Tools);
         begin
            Landin.Testing.Check_Equal
              (Item, Result.Status, Landin.Driver.Status_Success,
               "forward defaults use effective overrides: "
               & Unbounded.To_String (Result.Report));
         end;
         Args.Replace_Element (1, "--option=enabled=true");
         Args.Replace_Element (3, "--option=count=5");
         Args.Replace_Element (4, "b.ldn");
         Args.Replace_Element (5, "a.ldn");
      end loop;
   end Fixed_Options_Are_Deterministic;

   procedure Fixed_Facts_Come_From_The_Target
     (Item : in out Landin.Testing.Context);

   procedure Fixed_Facts_Come_From_The_Target
     (Item : in out Landin.Testing.Context)
   is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
   begin
      Host.Add_File
        ("facts.ldn",
         "compiler.assert(compiler.word_size == 8 * sizeof usize)" & LF
         & "compiler.assert(compiler.byte_order == little)" & LF
         & "compiler.assert(compiler.c_sysv_lp64"
         & " == (compiler.arch == x86_64))" & LF
         & "compiler.assert(true or (1 / 0 == 0))" & LF
         & "compiler.assert(not (false and (1 / 0 == 0)))" & LF
         & "compiler.assert(compiler.build_mode == debug)" & LF
         & "fixed if compiler.arch == synthetic_32 then" & LF
         & "compiler.assert(sizeof usize == 4)" & LF
         & "compiler.assert(alignof usize == 4)" & LF
         & "else" & LF
         & "compiler.assert(sizeof usize == 8)" & LF
         & "compiler.assert(alignof usize == 8)" & LF
         & "end if" & LF);
      for Target in 1 .. 2 loop
         declare
            Args : constant Landin.Platform.Path_List := Both
              ((if Target = 1 then "--target=linux-x86-64"
                else "--target=synthetic-32"), "facts.ldn");
            Result : constant Landin.Driver.Outcome :=
              Landin.Driver.Execute (Args, Host, Tools);
         begin
            Landin.Testing.Check_Equal
              (Item, Result.Status, Landin.Driver.Status_Success,
               "width and alignment come from target: "
               & Unbounded.To_String (Result.Report));
         end;
      end loop;
   end Fixed_Facts_Come_From_The_Target;

   procedure Invalid_Options_Are_Refused
     (Item : in out Landin.Testing.Context);

   procedure Invalid_Options_Are_Refused
     (Item : in out Landin.Testing.Context) is
      procedure Refuse
        (Source, Option, Needle : String; Extra : String := "");
      procedure Refuse
        (Source, Option, Needle : String; Extra : String := "")
      is
         Host : Landin.Testing.Fakes.Fake_Filesystem;
         Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
         Args : Landin.Platform.Path_List;
      begin
         Host.Add_File ("bad.ldn", Source & LF);
         if Option /= "" then
            Args.Append (Option);
         end if;
         if Extra /= "" then
            Args.Append (Extra);
         end if;
         Args.Append ("bad.ldn");
         declare
            Result : constant Landin.Driver.Outcome :=
              Landin.Driver.Execute (Args, Host, Tools);
         begin
            Landin.Testing.Check
              (Item, Result.Status in Landin.Driver.Status_Reported
                   | Landin.Driver.Status_Misuse
               and then Contains
                 (Unbounded.To_String (Result.Report), Needle),
               "refused " & Needle & ": "
               & Unbounded.To_String (Result.Report));
            Landin.Testing.Check_Equal
              (Item, Tools.Run_Count, 0, "invalid options never invoke tools");
         end;
      end Refuse;
   begin
      Refuse ("", "--option=unknown=1", "unknown build option");
      Refuse ("option n: u8 = 1", "--option=n=256", "outside its type range");
      Refuse ("option n: u32 = 1", "--option=n=-1", "outside its type range");
      Refuse ("option n: usize = 1", "--option=n=4294967296",
              "outside its type range", "--target=synthetic-32");
      Refuse ("option n: bool = true", "--option=n=1", "not a typed literal");
      Refuse ("option n: i32 = 1", "--option=n=true", "not a typed literal");
      Refuse ("option n: i32 = 1", "--option=n=1+2", "not a typed literal");
      Refuse ("option n: u64 = 1", "--option=n=18446744073709551616",
              "not a typed literal");
      Refuse ("option n: u32 = 1", "--option=n=1",
              "repeated build option", "--option=n=2");
      Refuse ("", "--option==1", "invalid or repeated build option");
      Refuse ("", "--option=x=", "invalid or repeated build option");
      Refuse ("", "--build-mode=fast", "one debug or release value");
      Refuse ("", "--build-mode=debug", "one debug or release value",
              "--build-mode=release");
      Refuse ("option n: u32 = missing", "--option=n=1",
              "not a compiler-owned fixed value");
      Refuse ("option n: u8 = 256", "--option=n=1", "outside its type range");
      Refuse ("option a: u32 = b" & LF & "option b: u32 = a",
              "--option=a=1", "cyclic option defaults");
      Refuse ("option a: bool = true or a", "", "cyclic option defaults");
      Refuse ("option a: u32 = 1" & LF & "option a: u32 = 2", "",
              "option `a` is declared twice");
      Refuse ("fixed if false then" & LF & "option n: u32 = 1" & LF
              & "end if", "", "outside every fixed arm");
      Refuse ("option n: f32 = 1", "", "bool or an integer scalar");
      Refuse ("option n: bool = false and 123", "",
              "incompatible types");
      Refuse ("compiler.assert(true or (1 + false == 2))", "",
              "incompatible types");
      Refuse ("", "--option=LogLevel=1", "invalid or repeated build option");
      Refuse ("compiler.assert(false)", "", "assertion is false");
      Refuse ("compiler.assert(1)", "", "compiler.assert needs bool");
      Refuse ("compiler.assert(true or f())", "", "closed fixed");
      Refuse ("compiler.assert(sizeof thing == 8)", "", "scalar name");
      Refuse ("compiler.assert(compiler.c_sysv_lp64 + 1 == 2)", "",
              "incompatible types");
      Refuse ("compiler.assert(compiler.c_sysv_lp64)", "",
              "assertion is false", "--target=synthetic-32");
   end Invalid_Options_Are_Refused;

   procedure Libraries_Keep_Their_Written_Order
     (Item : in out Landin.Testing.Context);

   procedure Libraries_Keep_Their_Written_Order
     (Item : in out Landin.Testing.Context)
   is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Args : Landin.Platform.Path_List;
   begin
      Host.Add_Directory ("entry");
      Host.Add_Directory ("root");
      Host.Add_Directory ("root/support");
      Host.Add_File
        ("entry/z.ldn", "linker.library(""third"")" & LF);
      Host.Add_File
        ("entry/a.ldn", "import support" & LF
         & "linker.library(""first"")" & LF
         & "fixed if false then" & LF
         & "linker.library(runtime())" & LF
         & "compiler.assert(false)" & LF
         & "else" & LF & "linker.library(""second"")" & LF & "end if" & LF
         & "public main: () -> (code: i32) = code = 42 end main" & LF);
      Host.Add_File
        ("root/support/a.ldn", "linker.library(""first"")" & LF);
      Args.Append ("--root=root");
      Args.Append ("--emit=exe");
      Args.Append ("entry");
      Tools.Set_Result (0, "");
      declare
         Result : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute (Args, Host, Tools);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, Landin.Driver.Status_Success,
            "active directives reach the tool: "
            & Unbounded.To_String (Result.Report));
         if Tools.Run_Count = 1 then
            declare
               Call : constant Landin.Testing.Fakes.Tool_Call :=
                 Tools.Call_At (1);
            begin
               Landin.Testing.Check_Equal
                 (Item, Call.Arguments.Element (2), "-l:libfirst.a",
                  "entry first file precedes other modules");
               Landin.Testing.Check_Equal
                 (Item, Call.Arguments.Element (3), "-l:libsecond.a",
                  "active arm keeps declaration order");
               Landin.Testing.Check_Equal
                 (Item, Call.Arguments.Element (4), "-l:libthird.a",
                  "directory files are canonical sorted");
               Landin.Testing.Check_Equal
                 (Item, Call.Arguments.Element (5), "-l:libfirst.a",
                  "reached module repeats are preserved");
            end;
         else
            Landin.Testing.Check (Item, False, "one tool invocation expected");
         end if;
      end;
   end Libraries_Keep_Their_Written_Order;

   procedure Builtin_Imports_Never_Search_Roots
     (Item : in out Landin.Testing.Context);

   procedure Builtin_Imports_Never_Search_Roots
     (Item : in out Landin.Testing.Context)
   is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
   begin
      Host.Add_Directory ("entry");
      Host.Add_Directory ("root");
      Host.Add_Directory ("root/landin");
      Host.Add_Directory ("root/landin/compiler");
      Host.Add_File
        ("root/landin/compiler/bad.ldn", "this must never parse !" & LF);
      for Which in 1 .. 3 loop
         Host.Add_File
           ("entry/main.ldn", "import landin/compiler"
            & (case Which is
                 when 1 => "", when 2 => " as c", when others => " (arch)")
            & LF);
         declare
            Result : constant Landin.Driver.Outcome :=
              Landin.Driver.Execute (Both ("--root=root", "entry"),
                                     Host, Tools);
            Error : constant String :=
              Unbounded.To_String (Result.Report);
         begin
            Landin.Testing.Check
              (Item, Result.Status = Landin.Driver.Status_Reported
               and then Contains (Error, "L0203")
               and then Contains (Error, "explicitly imported")
               and then not Contains (Error, "root/landin/compiler"),
               "builtin import suffix cannot reach source: " & Error);
         end;
      end loop;
   end Builtin_Imports_Never_Search_Roots;

   procedure R440_Helper_Refusals_Have_No_Effects
     (Item : in out Landin.Testing.Context);

   procedure R440_Helper_Refusals_Have_No_Effects
     (Item : in out Landin.Testing.Context)
   is
      procedure Check (Source, Message : String; Executable : Boolean);

      procedure Check (Source, Message : String; Executable : Boolean) is
         Host : Landin.Testing.Fakes.Fake_Filesystem;
         Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
         Args : Landin.Platform.Path_List := Arguments_Of ("bad.ldn");
      begin
         Host.Add_File ("bad.ldn", Source);
         --  Any attempted write adds an output diagnostic; it cannot hide
         --  behind a discarded buffer or a successful fake tool invocation.
         Host.Refuse_Writes;
         Tools.Raise_On_Run;
         Args.Append ("--target=linux-x86-64");
         Args.Append (if Executable then "--emit=exe" else "--emit=asm");
         Args.Append ("-o");
         Args.Append ("refused");
         declare
            Result : constant Landin.Driver.Outcome :=
              Landin.Driver.Execute (Args, Host, Tools);
            Report : constant String := Unbounded.To_String (Result.Report);
         begin
            Landin.Testing.Check_Equal
              (Item, Result.Status, Landin.Driver.Status_Reported,
               "helper source errors are reports, not backend defects");
            Landin.Testing.Check
              (Item, Occurrences (Report, "error[") = 1
                 and then Contains (Report, "error[L0301]: " & Message)
                 and then not Contains (Report, "L0502")
                 and then not Contains (Report, "internal compiler defect"),
               "only the precise source helper contract owns the refusal");
            Landin.Testing.Check_Equal
              (Item, Tools.Run_Count, 0, "no assembler or linker is invoked");
            Landin.Testing.Check
              (Item, Unbounded.To_String (Result.Output) = ""
                 and then Host.Written ("refused") = ""
                 and then Host.Written ("refused.s") = "",
               "neither output nor intermediate assembly is written");
         end;
      end Check;
   begin
      for Executable in Boolean loop
         Check
           ("extern(c) _landin_host_initialize_arguments:"
            & " (argc: i32, argv: ptr ptr u8) -> none" & LF,
            "compiler-owned helper `_landin_host_initialize_arguments`"
            & " requires escaping argv", Executable);
         Check
           ("extern(c) _landin_host_initialize_arguments:"
            & " (argc: i32, escaping argv: ptr ptr u32) -> none" & LF,
            "compiler-owned helper `_landin_host_initialize_arguments`"
            & " requires parameter 2 to be `ptr ptr u8`", Executable);
         Check
           ("extern(c) _landin_host_argument_at_from:"
            & " (table: ptr ptr u8, index: usize) -> (data: ptr u8)" & LF,
            "compiler-owned helper `_landin_host_argument_at_from`"
            & " requires its result from parameter 1", Executable);
         Check
           ("extern(c) _landin_host_heap_allocate:"
            & " (length: usize, alignment: usize) -> (data: ptr mut u8)" & LF,
            "compiler-owned helper `_landin_host_heap_allocate`"
            & " requires result `one atom | ptr mut u8`", Executable);
         Check
           ("link(symbol: ""_landin_host_errno"") replacement: () -> none ="
            & LF & "end replacement" & LF,
            "compiler-owned helper `_landin_host_errno`"
            & " cannot be defined by source", Executable);
      end loop;
   end R440_Helper_Refusals_Have_No_Effects;

   procedure R440_Hosted_Linkage_Has_No_Effects
     (Item : in out Landin.Testing.Context);

   procedure R440_Hosted_Linkage_Has_No_Effects
     (Item : in out Landin.Testing.Context)
   is
      Main : constant String := "public main: () -> (code: i32) =" & LF
        & "    code = 0" & LF & "end main" & LF;
      Foreign : constant String :=
        "extern(c) link(symbol: ""main"") foreign: () -> (code: i32)" & LF;

      procedure Check (Executable, Rooted, Reverse_Order : Boolean);

      procedure Check (Executable, Rooted, Reverse_Order : Boolean) is
         Host : Landin.Testing.Fakes.Fake_Filesystem;
         Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
         Args : Landin.Platform.Path_List;
      begin
         if Rooted then
            Host.Add_Directory ("entry");
            Host.Add_Directory ("root");
            Host.Add_Directory ("root/foreign");
            Host.Add_File ("entry/main.ldn", "import foreign" & LF & Main);
            Host.Add_File ("root/foreign/bridge.ldn", Foreign);
            Args.Append ("--root=root");
            Args.Append ("entry");
         else
            Host.Add_File ("main.ldn", Main);
            Host.Add_File ("foreign.ldn", Foreign);
            Args.Append (if Reverse_Order then "foreign.ldn" else "main.ldn");
            Args.Append (if Reverse_Order then "main.ldn" else "foreign.ldn");
         end if;
         Host.Refuse_Writes;
         Tools.Raise_On_Run;
         Args.Append ("--target=linux-x86-64");
         Args.Append (if Executable then "--emit=exe" else "--emit=asm");
         Args.Append ("-o");
         Args.Append ("collision");
         declare
            Result : constant Landin.Driver.Outcome :=
              Landin.Driver.Execute (Args, Host, Tools);
            Report : constant String := Unbounded.To_String (Result.Report);
         begin
            Landin.Testing.Check_Equal
              (Item, Result.Status, Landin.Driver.Status_Reported,
               "a forced main collision is a source report");
            Landin.Testing.Check
              (Item, Occurrences (Report, "error[") = 1
                 and then Contains
                   (Report, "error[L0301]: link symbol `main` collides with"
                    & " the selected native hosted entry")
                 and then Contains (Report, "the selected hosted entry")
                 and then not Contains (Report, "L0502"),
               "entry selection is independent of file and discovery order");
            Landin.Testing.Check
              (Item, Tools.Run_Count = 0
                 and then Unbounded.To_String (Result.Output) = ""
                 and then Host.Written ("collision") = ""
                 and then Host.Written ("collision.s") = "",
               "main collision cannot reach output or host tools");
         end;
      end Check;
   begin
      for Executable in Boolean loop
         Check (Executable, False, False);
         Check (Executable, False, True);
         Check (Executable, True, False);
      end loop;
      declare
         Host : Landin.Testing.Fakes.Fake_Filesystem;
         Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      begin
         Host.Add_File
           ("renamed.ldn", "public link(symbol: ""elsewhere"") main:"
            & " () -> (code: i32) =" & LF & "    code = 0" & LF
            & "end main" & LF);
         declare
            Result : constant Landin.Driver.Outcome := Landin.Driver.Execute
              (Both ("renamed.ldn", "--emit=exe"), Host, Tools);
            Report : constant String := Unbounded.To_String (Result.Report);
         begin
            Landin.Testing.Check
              (Item, Result.Status = Landin.Driver.Status_Reported
                 and then Occurrences (Report, "error[") = 1
                 and then Contains (Report, "L0502")
                 and then not Contains (Report, "L0301")
                 and then Tools.Run_Count = 0
                 and then Host.Written
                   (Landin.Driver.Default_Executable & ".s") = "",
               "renamed native main keeps the missing-entry refusal");
         end;
      end;
      declare
         Host : Landin.Testing.Fakes.Fake_Filesystem;
         Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
         Args : Landin.Platform.Path_List;
      begin
         Host.Add_Directory ("entry");
         Host.Add_Directory ("root");
         Host.Add_Directory ("root/library");
         Host.Add_File
           ("entry/bridge.ldn", "import library" & LF & Foreign);
         Host.Add_File ("root/library/main.ldn", Main);
         Args.Append ("--root=root");
         Args.Append ("entry");
         Args.Append ("--emit=asm");
         declare
            Result : constant Landin.Driver.Outcome :=
              Landin.Driver.Execute (Args, Host, Tools);
         begin
            Landin.Testing.Check
              (Item, Result.Status = Landin.Driver.Status_Success
                 and then Unbounded.To_String (Result.Report) = ""
                 and then Tools.Run_Count = 0,
               "another module's native main does not select hosted startup");
         end;
      end;
   end R440_Hosted_Linkage_Has_No_Effects;

   procedure R440_Qualified_Alias_Conversions
     (Item : in out Landin.Testing.Context);

   procedure R440_Qualified_Alias_Conversions
     (Item : in out Landin.Testing.Context)
   is
      procedure Check (Source, Code, Message : String);

      procedure Check (Source, Code, Message : String) is
         Host : Landin.Testing.Fakes.Fake_Filesystem;
         Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
         Args : Landin.Platform.Path_List := Arguments_Of ("--root=root");
      begin
         Host.Add_Directory ("entry");
         Host.Add_Directory ("root");
         Host.Add_Directory ("root/aliases");
         Host.Add_File ("entry/main.ldn", "import aliases" & LF & Source);
         Host.Add_File
           ("root/aliases/types.ldn",
            "public percent: type = u8 range 0..100" & LF
            & "public ratio: type = percent" & LF
            & "public word: type = usize" & LF
            & "hidden: type = u8" & LF
            & "public value: u8 = 7" & LF
            & "public convert: (value: u8) -> (result: u8) =" & LF
            & "    result = value + 1" & LF & "end convert" & LF);
         Host.Refuse_Writes;
         Tools.Raise_On_Run;
         Args.Append ("--target=linux-x86-64");
         Args.Append ("entry");
         declare
            Result : constant Landin.Driver.Outcome :=
              Landin.Driver.Execute (Args, Host, Tools);
            Report : constant String := Unbounded.To_String (Result.Report);
         begin
            Landin.Testing.Check_Equal
              (Item, Result.Status,
               (if Code = "" then Landin.Driver.Status_Success
                else Landin.Driver.Status_Reported),
               "qualified aliases retain their declaration category");
            Landin.Testing.Check
              (Item, (if Code = "" then Report = ""
                      else Occurrences (Report, "error[") = 1
                        and then Contains (Report, "error[" & Code & "]")
                        and then Contains (Report, Message)),
               "a qualified conversion has exactly its own diagnostic");
            Landin.Testing.Check_Equal
              (Item, Tools.Run_Count, 0, "checking invokes no host tools");
         end;
      end Check;
   begin
      Check
        ("image: u8 = aliases.ratio(42)" & LF
         & "use: (input: u16) -> (result: usize) =" & LF
         & "    narrowed: u8 = aliases.ratio(input)" & LF
         & "    called: u8 = aliases.convert(narrowed)" & LF
         & "    result = aliases.word(called)" & LF & "end use" & LF,
         "", "");
      Check
        ("use: () -> (result: u8) =" & LF
         & "    result = aliases.ratio(101)" & LF & "end use" & LF,
         "L0300", "this is 101, and the declared range is 0 .. 100");
      Check
        ("use: () -> (result: u8) =" & LF
         & "    result = aliases.value(1)" & LF & "end use" & LF,
         "L0301", "this value is not a function, so this is not a call");
      Check
        ("use: () -> (result: u8) =" & LF
         & "    result = aliases.hidden(1)" & LF & "end use" & LF,
         "L0202", "hidden");
   end R440_Qualified_Alias_Conversions;

   procedure R491_Refusals_Have_No_Effects
     (Item : in out Landin.Testing.Context);

   procedure R491_Refusals_Have_No_Effects
     (Item : in out Landin.Testing.Context)
   is
      procedure Check
        (Source, Code : String; Count : Positive; Executable : Boolean);

      procedure Check
        (Source, Code : String; Count : Positive; Executable : Boolean)
      is
         Host : Landin.Testing.Fakes.Fake_Filesystem;
         Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
         Args : Landin.Platform.Path_List := Arguments_Of ("bad.ldn");
      begin
         Host.Add_File ("bad.ldn", Source);
         Host.Refuse_Writes;
         Tools.Raise_On_Run;
         Args.Append ("--target=linux-x86-64");
         Args.Append (if Executable then "--emit=exe" else "--emit=asm");
         declare
            Result : constant Landin.Driver.Outcome :=
              Landin.Driver.Execute (Args, Host, Tools);
            Report : constant String := Unbounded.To_String (Result.Report);
         begin
            Landin.Testing.Check_Equal
              (Item, Result.Status, Landin.Driver.Status_Reported,
               "invalid source has an ordinary diagnostic");
            Landin.Testing.Check
              (Item, Contains (Report, "error[" & Code & "]")
                 and then Occurrences (Report, "error[") = Count
                 and then not Contains (Report, "internal compiler defect"),
               "the source refusal retains its diagnostic contract");
            Landin.Testing.Check_Equal
              (Item, Host.Write_Count, 0, "no output write is attempted");
            Landin.Testing.Check_Equal
              (Item, Tools.Run_Count, 0, "no tool is invoked");
         end;
      end Check;
   begin
      for Executable in Boolean loop
         Check
           ("f: () -> none = loop do complete end loop end f",
            "L0110", 1, Executable);
         Check
           ("f: () -> none = loop do continue with 1 end loop end f",
            "L0110", 1, Executable);
         Check
           ("public import core/mem", "L0103", 2, Executable);
         Check
           ("public fixed if true then value: i32 = 42 end if",
            "L0103", 1, Executable);
         Check
           ("public main: () -> (code: i32) = code = [] end main",
            "L0301", 1, Executable);
         Check
           ("public main: () -> (code: i32) = code = 1 ) end main",
            "L0110", 1, Executable);
         Check
           ("public []: () -> (code: i32) = code = 42 end main",
            "L0103", 7, Executable);
         Check
           ("readable: type = concept (item: type)" & LF
            & "read: (self: item) -> (result: i32) end readable" & LF
            & "read_i32: (self: i32) -> (result: i32) = self end read_i32"
            & LF & "public i32 is readable (read: read_i32)",
            "L0103", 1, Executable);
      end loop;
   end R491_Refusals_Have_No_Effects;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "driver", "R4.91 refusals have no effects",
         R491_Refusals_Have_No_Effects'Access);
      Landin.Testing.Register
        (Into, "driver", "R4.40 qualified alias conversions",
         R440_Qualified_Alias_Conversions'Access);
      Landin.Testing.Register
        (Into, "driver", "R4.40 helper refusals have no effects",
         R440_Helper_Refusals_Have_No_Effects'Access);
      Landin.Testing.Register
        (Into, "driver", "R4.40 hosted linkage has no effects",
         R440_Hosted_Linkage_Has_No_Effects'Access);
      Landin.Testing.Register
        (Into, "driver", "fixed options are deterministic",
         Fixed_Options_Are_Deterministic'Access);
      Landin.Testing.Register
        (Into, "driver", "fixed facts come from the target",
         Fixed_Facts_Come_From_The_Target'Access);
      Landin.Testing.Register
        (Into, "driver", "invalid options are refused",
         Invalid_Options_Are_Refused'Access);
      Landin.Testing.Register
        (Into, "driver", "libraries keep their written order",
         Libraries_Keep_Their_Written_Order'Access);
      Landin.Testing.Register
        (Into, "driver", "builtin imports never search roots",
         Builtin_Imports_Never_Search_Roots'Access);
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
        (Into, "driver", "emission without sources is misuse",
         Emission_Without_Sources_Is_Misuse'Access);
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
        (Into, "driver", "reachable modules are loaded",
         Reachable_Modules_Are_Loaded'Access);
      Landin.Testing.Register
        (Into, "driver", "roots are searched in order",
         Roots_Are_Searched_In_Order'Access);
      Landin.Testing.Register
        (Into, "driver", "private imported names are diagnosed",
         Private_Imported_Names_Are_Diagnosed'Access);
      Landin.Testing.Register
        (Into, "driver", "missing modules are diagnosed",
         Missing_Modules_Are_Diagnosed'Access);
      Landin.Testing.Register
        (Into, "driver", "invalid entry modules are diagnosed",
         Invalid_Entry_Modules_Are_Diagnosed'Access);
      Landin.Testing.Register
        (Into, "driver", "imported main is not the entry",
         Imported_Main_Is_Not_The_Entry'Access);
      Landin.Testing.Register
        (Into, "driver", "reached conformances share one register",
         Reached_Conformances_Share_One_Register'Access);
      Landin.Testing.Register
        (Into, "driver", "caller files are separate",
         Caller_Files_Are_Separate'Access);
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
        (Into, "driver", "a seventh parameter is emitted",
         A_Seventh_Parameter_Is_Emitted'Access);
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
      Landin.Testing.Register
        (Into, "driver", "an unwritable output is reported",
         An_Unwritable_Output_Is_Reported'Access);
   end Register;

end Landin.Tests.Driver_Suite;
