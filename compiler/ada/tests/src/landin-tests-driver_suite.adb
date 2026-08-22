with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Landin.Driver;
with Landin.Platform;
with Landin.Testing.Fakes;

package body Landin.Tests.Driver_Suite is

   package Unbounded renames Ada.Strings.Unbounded;

   function Contains (Text : String; Needle : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Needle) > 0);

   function Arguments_Of (First : String) return Landin.Platform.Path_List;

   function Arguments_Of (First : String) return Landin.Platform.Path_List is
      Result : Landin.Platform.Path_List;
   begin
      Result.Append (First);
      return Result;
   end Arguments_Of;

   procedure No_Arguments_Is_Misuse (Item : in out Landin.Testing.Context);

   procedure No_Arguments_Is_Misuse (Item : in out Landin.Testing.Context) is
      Host   : Landin.Testing.Fakes.Fake_Filesystem;
      Empty  : Landin.Platform.Path_List;
      Result : constant Landin.Driver.Outcome :=
        Landin.Driver.Execute (Empty, Host);
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
      Result : constant Landin.Driver.Outcome :=
        Landin.Driver.Execute (Arguments_Of ("--identify"), Host);
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
      Result : constant Landin.Driver.Outcome :=
        Landin.Driver.Execute (Arguments_Of ("--wat"), Host);
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
      Result : constant Landin.Driver.Outcome :=
        Landin.Driver.Execute (Arguments_Of ("absent.ldn"), Host);
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
      LF   : constant Character := Character'Val (10);
      Host : Landin.Testing.Fakes.Fake_Filesystem;
   begin
      Host.Add_File ("main.ldn", "if: u32 = 1" & LF);
      Host.Add_File ("good.ldn", "n: u32 = 1" & LF);

      declare
         Result : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute (Arguments_Of ("main.ldn"), Host);
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
           Landin.Driver.Execute (Arguments_Of ("good.ldn"), Host);
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
   begin
      Host.Add_File ("empty.ldn", "");

      declare
         Result : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute (Arguments_Of ("empty.ldn"), Host);
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
      Known : constant Landin.Driver.Outcome :=
        Landin.Driver.Execute (Arguments_Of ("--target=synthetic-32"), Host);
      Wrong : constant Landin.Driver.Outcome :=
        Landin.Driver.Execute (Arguments_Of ("--target=vax"), Host);
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
      Asked  : constant Landin.Driver.Outcome :=
        Landin.Driver.Execute (Arguments_Of ("--help"), Host);
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
           Landin.Driver.Execute (Bare, Host);
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

      function Both (First, Second : String)
        return Landin.Platform.Path_List;

      function Both (First, Second : String)
        return Landin.Platform.Path_List
      is
         Result : Landin.Platform.Path_List;
      begin
         Result.Append (First);
         Result.Append (Second);
         return Result;
      end Both;

   begin
      declare
         procedure Refuses (First, Second : String);

         procedure Refuses (First, Second : String) is
            Result : constant Landin.Driver.Outcome :=
              Landin.Driver.Execute (Both (First, Second), Host);
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
      Named    : constant Landin.Driver.Outcome :=
        Landin.Driver.Execute (Arguments_Of ("--target=linux-x86-64"), Host);
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
   begin
      Host.Add_Unreadable ("locked.ldn");

      declare
         Result : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute (Arguments_Of ("locked.ldn"), Host);
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
   end Exit_Statuses_Are_Fixed;

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
   end Register;

end Landin.Tests.Driver_Suite;
