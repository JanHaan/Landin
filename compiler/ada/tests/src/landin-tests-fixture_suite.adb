with Ada.Strings.Fixed;

with Landin.Platform.Native;
with Landin.Testing.Fakes;
with Landin.Testing.Fixtures;

package body Landin.Tests.Fixture_Suite is

   use Landin.Testing.Fixtures;

   LF : constant Character := Character'Val (10);

   --  The repository's real fixture trees, relative to the directory the
   --  harness is run from (compiler/ada).
   Valid_Root   : constant String := "../tests/fixtures";
   Invalid_Root : constant String := "../tests/harness-cases/malformed";

   function Mentions
     (In_Catalogue : Catalogue; Needle : String) return Boolean;

   function Mentions
     (In_Catalogue : Catalogue; Needle : String) return Boolean
   is
   begin
      for Index in 1 .. Problem_Count (In_Catalogue) loop
         if Ada.Strings.Fixed.Index
              (Nth_Problem (In_Catalogue, Index), Needle) > 0
         then
            return True;
         end if;
      end loop;
      return False;
   end Mentions;

   procedure Classes_Have_Directories (Item : in out Landin.Testing.Context);

   procedure Classes_Have_Directories
     (Item : in out Landin.Testing.Context)
   is
      Found : Boolean;
      Named : Fixture_Class;
   begin
      --  Every class, because a renamed directory makes Discover look at a
      --  path that does not exist and quietly find nothing there.
      Landin.Testing.Check_Equal
        (Item, Class_Directory (Unit), "unit", "unit directory");
      Landin.Testing.Check_Equal
        (Item, Class_Directory (Positive_Program), "positive",
         "positive directory");
      Landin.Testing.Check_Equal
        (Item, Class_Directory (Negative_Program), "negative",
         "negative directory");
      Landin.Testing.Check_Equal
        (Item, Class_Directory (Runtime), "runtime", "runtime directory");
      Landin.Testing.Check_Equal
        (Item, Class_Directory (Abi), "abi", "abi directory");
      Landin.Testing.Check_Equal
        (Item, Class_Directory (Debugger), "debugger", "debugger directory");
      Landin.Testing.Check_Equal
        (Item, Class_Directory (End_To_End), "end-to-end",
         "end to end directory");

      --  And every round trip, so a directory name and the class it names
      --  cannot drift apart.
      for Kind in Fixture_Class loop
         Named := Class_Of (Class_Directory (Kind), Found);
         Landin.Testing.Check
           (Item, Found, Class_Directory (Kind) & " is a known class");
         Landin.Testing.Check
           (Item, Named = Kind, Class_Directory (Kind) & " round trips");
      end loop;

      Named := Class_Of ("nonsense", Found);
      Landin.Testing.Check (Item, not Found, "an unknown class is refused");
      Landin.Testing.Check
        (Item, Named = Unit, "a refused class does not invent a value");
   end Classes_Have_Directories;

   procedure Diagnostic_Code_Boundaries_Are_Normalized
     (Item : in out Landin.Testing.Context);

   procedure Diagnostic_Code_Boundaries_Are_Normalized
     (Item : in out Landin.Testing.Context)
   is
   begin
      Landin.Testing.Check_Equal
        (Item, Normalized_Codes (""), "",
         "normalization preserves an empty code list");
      Landin.Testing.Check_Equal
        (Item, Normalized_Codes ("L0314,L0314"), "L0314, L0314",
         "normalization preserves an unspaced duplicate code");
      Landin.Testing.Check_Equal
        (Item,
         Normalized_Codes ("  L0314 , L0102,  L0314  "),
         "L0314, L0102, L0314",
         "normalization changes spacing without sorting or deduplicating");
   end Diagnostic_Code_Boundaries_Are_Normalized;

   procedure Well_Formed_Fixtures_Are_Discovered
     (Item : in out Landin.Testing.Context);

   procedure Well_Formed_Fixtures_Are_Discovered
     (Item : in out Landin.Testing.Context)
   is
      Host  : Landin.Testing.Fakes.Fake_Filesystem;
      Found : Catalogue;
   begin
      Host.Add_Directory ("root");
      Host.Add_Directory ("root/unit");
      Host.Add_Directory ("root/unit/zebra");
      Host.Add_File
        ("root/unit/zebra/fixture.meta",
         "class: unit" & LF & "summary: later by name" & LF
         & "targets: linux-x86-64" & LF);
      Host.Add_Directory ("root/unit/alpha");
      Host.Add_File
        ("root/unit/alpha/fixture.meta",
         "# a comment" & LF & LF & "class: unit" & LF
         & "summary: earlier by name" & LF
         & "targets: linux-x86-64" & LF);
      Host.Add_Directory ("root/positive");
      Host.Add_Directory ("root/positive/rooted-positive");
      Host.Add_File ("root/positive/rooted-positive/main.ldn", "");
      Host.Add_File
        ("root/positive/rooted-positive/fixture.meta",
         "class: positive" & LF & "summary: an imported acceptance" & LF
         & "constructs: 1740" & LF & "program: main.ldn" & LF
         & "root: ../../../../.." & LF & "targets: linux-x86-64" & LF);
      Host.Add_Directory ("root/negative");
      Host.Add_Directory ("root/negative/broken-name");
      Host.Add_File
        ("root/negative/broken-name/fixture.meta",
         "class: negative" & LF & "summary: a rejection" & LF
         & "constructs: 1740" & LF
         & "targets: linux-x86-64" & LF
         & "program: broken.ldn" & LF & "expect: broken.expected" & LF
         & "args: broken.ldn" & LF & "status: 1" & LF);
      Host.Add_Directory ("root/negative/rooted-negative");
      Host.Add_File ("root/negative/rooted-negative/program.ldn", "");
      Host.Add_File
        ("root/negative/rooted-negative/fixture.meta",
         "class: negative" & LF & "summary: an imported refusal" & LF
         & "constructs: 1740" & LF & "program: program.ldn" & LF
         & "root: ../../../../.." & LF & "codes: L0314" & LF
         & "targets: linux-x86-64" & LF);
      Host.Add_Directory ("root/abi");
      Host.Add_Directory ("root/abi/c-bridge");
      Host.Add_Directory ("root/abi/c-bridge/imports");
      Host.Add_Directory ("root/abi/c-bridge/native");
      Host.Add_File ("root/abi/c-bridge/program.ldn", "");
      Host.Add_File ("root/abi/c-bridge/peer.c", "");
      Host.Add_File ("root/abi/c-bridge/native/helper.c", "");
      Host.Add_File ("root/abi/c-bridge/expected.txt", "42" & LF);
      Host.Add_File
        ("root/abi/c-bridge/fixture.meta",
         "class: abi" & LF & "summary: C and Landin call each other" & LF
         & "program: program.ldn" & LF & "root: imports" & LF
         & "c-sources: peer.c, native/helper.c" & LF
         & "c-args: -DVALUE=42" & ASCII.HT & "-lm" & LF
         & "run_args: first second" & LF
         & "run_expect: expected.txt" & LF & "status: 42" & LF
         & "constructs: 1570, 1580, 1600" & LF
         & "targets: linux-x86-64" & LF);
      Host.Add_Directory ("root/abi/c-with");
      Host.Add_File ("root/abi/c-with/program.ldn", "");
      Host.Add_File ("root/abi/c-with/second.ldn", "");
      Host.Add_File ("root/abi/c-with/peer.c", "");
      Host.Add_File
        ("root/abi/c-with/fixture.meta",
         "class: abi" & LF & "summary: a multifile Landin side" & LF
         & "program: program.ldn" & LF & "with: second.ldn" & LF
         & "c-sources: peer.c" & LF & "status: 42" & LF
         & "constructs: 1570" & LF & "targets: linux-x86-64" & LF);

      Discover (Found, "root", Host);

      Landin.Testing.Check_Equal
        (Item, Problem_Count (Found), 0,
         "well-formed fixtures have no problems");
      Landin.Testing.Check_Equal (Item, Count (Found), 7, "seven fixtures");
      Landin.Testing.Check_Equal
        (Item, Count_Of (Found, Unit), 2, "two unit fixtures");
      Landin.Testing.Check_Equal
        (Item, Count_Of (Found, Positive_Program), 1,
         "one positive fixture");
      Landin.Testing.Check_Equal
        (Item, Count_Of (Found, Negative_Program), 2,
         "two negative fixtures");
      Landin.Testing.Check_Equal
        (Item, Name (Nth (Found, 1)), "alpha", "classes then names order");
      Landin.Testing.Check_Equal
        (Item, Name (Nth (Found, 2)), "zebra", "names are sorted");
      Landin.Testing.Check_Equal
        (Item, Name (Nth (Found, 3)), "rooted-positive",
         "positive fixtures follow unit fixtures");
      Landin.Testing.Check_Equal
        (Item, Name (Nth (Found, 4)), "broken-name",
         "a later class comes after an earlier one");
      Landin.Testing.Check_Equal
        (Item, Name (Nth (Found, 5)), "rooted-negative",
         "negative names stay sorted");
      Landin.Testing.Check_Equal
        (Item, Summary (Nth (Found, 1)), "earlier by name", "summary is kept");
      Landin.Testing.Check_Equal
        (Item, Targets (Nth (Found, 1)), "linux-x86-64", "targets are kept");
      Landin.Testing.Check_Equal
        (Item, Program (Nth (Found, 4)), "broken.ldn", "program is kept");
      Landin.Testing.Check_Equal
        (Item, Expect (Nth (Found, 4)), "broken.expected", "expect is kept");
      Landin.Testing.Check_Equal
        (Item, Constructs (Nth (Found, 4)), "1740", "constructs are kept");
      Landin.Testing.Check_Equal
        (Item, Module_Root (Nth (Found, 3)), "../../../../..",
         "positive root is kept");
      Landin.Testing.Check_Equal
        (Item, Module_Root (Nth (Found, 5)), "../../../../..",
         "negative root is kept");
      declare
         Positive_Arguments : Landin.Platform.Path_List;
         Negative_Arguments : Landin.Platform.Path_List;
         Abi_Arguments      : Landin.Platform.Path_List;
         With_Arguments     : Landin.Platform.Path_List;
      begin
         Append_Module_Arguments
           (Nth (Found, 3), "root", Positive_Arguments);
         Append_Module_Arguments
           (Nth (Found, 5), "root", Negative_Arguments);
         Append_Module_Arguments
           (Nth (Found, 6), "root", Abi_Arguments);
         Append_Module_Arguments
           (Nth (Found, 7), "root", With_Arguments);

         Landin.Testing.Check_Equal
           (Item, Natural (Positive_Arguments.Length), 2,
            "a rooted positive contributes two module arguments");
         Landin.Testing.Check_Equal
           (Item, Positive_Arguments.Element (1),
            "--root=root/positive/rooted-positive/../../../../..",
            "the positive root is relative to its fixture directory");
         Landin.Testing.Check_Equal
           (Item, Positive_Arguments.Element (2),
            "root/positive/rooted-positive",
            "the positive fixture directory is the entry module");
         Landin.Testing.Check_Equal
           (Item, Natural (Negative_Arguments.Length), 2,
            "a rooted negative contributes two module arguments");
         Landin.Testing.Check_Equal
           (Item, Negative_Arguments.Element (1),
            "--root=root/negative/rooted-negative/../../../../..",
            "the negative root is relative to its fixture directory");
         Landin.Testing.Check_Equal
           (Item, Negative_Arguments.Element (2),
            "root/negative/rooted-negative",
            "the negative fixture directory is the entry module");
         Landin.Testing.Check_Equal
           (Item, Natural (Abi_Arguments.Length), 2,
            "a rooted ABI fixture contributes two module arguments");
         Landin.Testing.Check_Equal
           (Item, Abi_Arguments.Element (1),
            "--root=root/abi/c-bridge/imports",
            "the ABI root is relative to its fixture directory");
         Landin.Testing.Check_Equal
           (Item, Abi_Arguments.Element (2), "root/abi/c-bridge",
            "the ABI fixture directory remains the entry module");
         Landin.Testing.Check_Equal
           (Item, Natural (With_Arguments.Length), 2,
            "an unrooted multifile fixture contributes both source files");
         Landin.Testing.Check_Equal
           (Item, With_Arguments.Element (1),
            "root/abi/c-with/program.ldn",
            "an unrooted fixture starts with its named program");
         Landin.Testing.Check_Equal
           (Item, With_Arguments.Element (2),
            "root/abi/c-with/second.ldn",
            "unrooted companion sources retain metadata order");
      end;
      Landin.Testing.Check_Equal
        (Item, Count_Of (Found, Abi), 2, "two ABI fixtures");
      Landin.Testing.Check_Equal
        (Item, Name (Nth (Found, 6)), "c-bridge",
         "ABI follows the earlier fixture classes");
      Landin.Testing.Check_Equal
        (Item, Module_Root (Nth (Found, 6)), "imports", "ABI root is kept");
      Landin.Testing.Check_Equal
        (Item, C_Sources (Nth (Found, 6)), "peer.c, native/helper.c",
         "ordered C sources are kept");
      Landin.Testing.Check_Equal
        (Item, C_Args (Nth (Found, 6)),
         "-DVALUE=42" & ASCII.HT & "-lm", "C arguments are kept");
      Landin.Testing.Check_Equal
        (Item, Run_Args (Nth (Found, 6)), "first second",
         "ABI program arguments are kept");
      Landin.Testing.Check_Equal
        (Item, Run_Expect (Nth (Found, 6)), "expected.txt",
         "ABI output expectation is kept");
      Landin.Testing.Check_Equal
        (Item, Name (Nth (Found, 7)), "c-with", "ABI names stay sorted");
      Landin.Testing.Check_Equal
        (Item, With_Sources (Nth (Found, 7)), "second.ldn",
         "ABI Landin companions are kept separately");
   end Well_Formed_Fixtures_Are_Discovered;

   procedure Malformed_Metadata_Is_Refused
     (Item : in out Landin.Testing.Context);

   procedure Malformed_Metadata_Is_Refused
     (Item : in out Landin.Testing.Context)
   is
      Host  : Landin.Testing.Fakes.Fake_Filesystem;
      Found : Catalogue;
   begin
      Host.Add_Directory ("root");
      Host.Add_Directory ("root/unit");

      Host.Add_Directory ("root/unit/no-metadata");

      Host.Add_Directory ("root/unit/unknown-key");
      Host.Add_File
        ("root/unit/unknown-key/fixture.meta",
         "class: unit" & LF & "summary: fine" & LF & "colour: blue" & LF);

      Host.Add_Directory ("root/unit/duplicate-key");
      Host.Add_File
        ("root/unit/duplicate-key/fixture.meta",
         "class: unit" & LF & "summary: one" & LF & "summary: two" & LF);

      Host.Add_Directory ("root/unit/missing-summary");
      Host.Add_File
        ("root/unit/missing-summary/fixture.meta", "class: unit" & LF);

      Host.Add_Directory ("root/unit/missing-targets");
      Host.Add_File
        ("root/unit/missing-targets/fixture.meta",
         "class: unit" & LF & "summary: no applicability" & LF);

      Host.Add_Directory ("root/unit/wrong-class");
      Host.Add_File
        ("root/unit/wrong-class/fixture.meta",
         "class: negative" & LF & "summary: mismatched" & LF);

      Host.Add_Directory ("root/unit/not-a-pair");
      Host.Add_File
        ("root/unit/not-a-pair/fixture.meta",
         "class: unit" & LF & "summary: fine" & LF & "nonsense" & LF);

      Host.Add_File ("root/unit/stray.txt", "not a fixture");

      --  A trapping program has no exit status to record [1960], so a
      --  fixture that claims one as well is claiming two answers.
      Host.Add_Directory ("root/runtime");
      Host.Add_Directory ("root/runtime/traps-and-a-status");
      Host.Add_File
        ("root/runtime/traps-and-a-status/fixture.meta",
         "class: runtime" & LF & "summary: both" & LF
         & "constructs: 1960" & LF
         & "program: main.ldn" & LF & "status: 42" & LF
         & "traps: yes" & LF);

      Host.Add_Directory ("root/runtime/traps-is-not-a-verdict");
      Host.Add_File
        ("root/runtime/traps-is-not-a-verdict/fixture.meta",
         "class: runtime" & LF & "summary: odd" & LF
         & "constructs: 1960" & LF
         & "program: main.ldn" & LF & "traps: perhaps" & LF);

      --  A construct is four digits and the documents define which four.
      --  This side checks the shape; check.py checks that the paragraph
      --  exists, because it is the thing that reads the documents.
      Host.Add_Directory ("root/unit/constructs-are-not-four-digits");
      Host.Add_File
        ("root/unit/constructs-are-not-four-digits/fixture.meta",
         "class: unit" & LF & "summary: shapeless" & LF
         & "constructs: 1810, twelve" & LF);

      Host.Add_Directory ("root/unit/with-and-no-program");
      Host.Add_File
        ("root/unit/with-and-no-program/fixture.meta",
         "class: unit" & LF & "summary: rootless" & LF
         & "with: second.ldn" & LF);

      Host.Add_Directory ("root/unit/constructs-twice");
      Host.Add_File
        ("root/unit/constructs-twice/fixture.meta",
         "class: unit" & LF & "summary: twice" & LF
         & "constructs: 1810" & LF & "constructs: 1820" & LF);

      Host.Add_Directory ("root/unit/codes-empty");
      Host.Add_File
        ("root/unit/codes-empty/fixture.meta",
         "class: unit" & LF & "summary: no diagnostic code" & LF
         & "codes:" & LF & "targets: linux-x86-64" & LF);

      Host.Add_Directory ("root/unit/codes-leading-comma");
      Host.Add_File
        ("root/unit/codes-leading-comma/fixture.meta",
         "class: unit" & LF & "summary: empty first code" & LF
         & "codes: ,L0314" & LF & "targets: linux-x86-64" & LF);

      Host.Add_Directory ("root/unit/codes-trailing-comma");
      Host.Add_File
        ("root/unit/codes-trailing-comma/fixture.meta",
         "class: unit" & LF & "summary: empty last code" & LF
         & "codes: L0314," & LF & "targets: linux-x86-64" & LF);

      Host.Add_Directory ("root/unit/codes-doubled-comma");
      Host.Add_File
        ("root/unit/codes-doubled-comma/fixture.meta",
         "class: unit" & LF & "summary: empty middle code" & LF
         & "codes: L0314,,L0102" & LF
         & "targets: linux-x86-64" & LF);

      Host.Add_Directory ("root/runtime/traps-twice");
      Host.Add_File
        ("root/runtime/traps-twice/fixture.meta",
         "class: runtime" & LF & "summary: twice" & LF
         & "constructs: 1960" & LF
         & "program: main.ldn" & LF & "traps: yes" & LF
         & "traps: no" & LF);

      --  Only a runtime fixture runs a program at all, so nothing else has
      --  anything that could trap.
      Host.Add_Directory ("root/unit/traps-without-a-program");
      Host.Add_File
        ("root/unit/traps-without-a-program/fixture.meta",
         "class: unit" & LF & "summary: misplaced" & LF
         & "traps: yes" & LF);

      Host.Add_Directory ("root/abi");
      Host.Add_Directory ("root/abi/missing-c-sources");
      Host.Add_File
        ("root/abi/missing-c-sources/fixture.meta",
         "class: abi" & LF & "summary: no C companion" & LF
         & "program: program.ldn" & LF & "constructs: 1570" & LF
         & "targets: linux-x86-64" & LF);

      Host.Add_Directory ("root/abi/duplicate-c-sources");
      Host.Add_File
        ("root/abi/duplicate-c-sources/fixture.meta",
         "class: abi" & LF & "summary: twice" & LF
         & "program: program.ldn" & LF & "constructs: 1570" & LF
         & "targets: linux-x86-64" & LF & "c-sources: peer.c" & LF
         & "c-sources: other.c" & LF);

      Host.Add_Directory ("root/abi/duplicate-c-args");
      Host.Add_File
        ("root/abi/duplicate-c-args/fixture.meta",
         "class: abi" & LF & "summary: arguments twice" & LF
         & "program: program.ldn" & LF & "constructs: 1570" & LF
         & "targets: linux-x86-64" & LF & "c-sources: peer.c" & LF
         & "c-args: -DONE" & LF & "c-args: -DTWO" & LF);

      Host.Add_Directory ("root/abi/duplicate-c-source-path");
      Host.Add_File
        ("root/abi/duplicate-c-source-path/fixture.meta",
         "class: abi" & LF & "summary: same companion twice" & LF
         & "program: program.ldn" & LF & "constructs: 1570" & LF
         & "targets: linux-x86-64" & LF
         & "c-sources: peer.c, peer.c" & LF);

      Host.Add_Directory ("root/abi/invalid-c-source-path");
      Host.Add_File
        ("root/abi/invalid-c-source-path/fixture.meta",
         "class: abi" & LF & "summary: path escapes" & LF
         & "program: program.ldn" & LF & "constructs: 1570" & LF
         & "targets: linux-x86-64" & LF
         & "c-sources: ../peer.c" & LF);

      Host.Add_Directory ("root/abi/missing-c-source-file");
      Host.Add_File
        ("root/abi/missing-c-source-file/fixture.meta",
         "class: abi" & LF & "summary: absent companion" & LF
         & "program: program.ldn" & LF & "constructs: 1570" & LF
         & "targets: linux-x86-64" & LF & "c-sources: absent.c" & LF);

      Host.Add_Directory ("root/abi/c-source-in-with");
      Host.Add_File ("root/abi/c-source-in-with/peer.c", "");
      Host.Add_File
        ("root/abi/c-source-in-with/fixture.meta",
         "class: abi" & LF & "summary: mixed source lists" & LF
         & "program: program.ldn" & LF & "constructs: 1570" & LF
         & "targets: linux-x86-64" & LF & "with: peer.c" & LF
         & "c-sources: peer.c" & LF);

      Host.Add_Directory ("root/unit/c-fields-outside-abi");
      Host.Add_File
        ("root/unit/c-fields-outside-abi/fixture.meta",
         "class: unit" & LF & "summary: misplaced C metadata" & LF
         & "targets: linux-x86-64" & LF & "c-sources: peer.c" & LF
         & "c-args: -DVALUE=1" & LF);

      Host.Add_Directory ("root/unit/root-in-unit");
      Host.Add_File
        ("root/unit/root-in-unit/fixture.meta",
         "class: unit" & LF & "summary: misplaced import root" & LF
         & "root: imports" & LF & "targets: linux-x86-64" & LF);
      Host.Add_Directory ("root/debugger");
      Host.Add_Directory ("root/debugger/root-in-debugger");
      Host.Add_File
        ("root/debugger/root-in-debugger/fixture.meta",
         "class: debugger" & LF & "summary: premature import root" & LF
         & "root: imports" & LF & "targets: linux-x86-64" & LF);
      Host.Add_Directory ("root/end-to-end");
      Host.Add_Directory ("root/end-to-end/root-in-end-to-end");
      Host.Add_File
        ("root/end-to-end/root-in-end-to-end/fixture.meta",
         "class: end-to-end" & LF & "summary: misplaced import root" & LF
         & "root: imports" & LF & "targets: linux-x86-64" & LF);

      Host.Add_Directory ("root/positive");
      Host.Add_Directory ("root/positive/root-without-program");
      Host.Add_File
        ("root/positive/root-without-program/fixture.meta",
         "class: positive" & LF & "summary: no corpus file" & LF
         & "root: imports" & LF & "targets: linux-x86-64" & LF);
      Host.Add_Directory ("root/positive/root-with-empty-program");
      Host.Add_File
        ("root/positive/root-with-empty-program/fixture.meta",
         "class: positive" & LF & "summary: empty corpus file name" & LF
         & "program:" & LF & "root: imports" & LF
         & "constructs: 1740" & LF & "targets: linux-x86-64" & LF);
      Host.Add_Directory ("root/positive/root-and-with");
      Host.Add_File ("root/positive/root-and-with/main.ldn", "");
      Host.Add_File ("root/positive/root-and-with/second.ldn", "");
      Host.Add_File
        ("root/positive/root-and-with/fixture.meta",
         "class: positive" & LF & "summary: two module mechanisms" & LF
         & "program: main.ldn" & LF & "with: second.ldn" & LF
         & "root: imports" & LF & "constructs: 1740" & LF
         & "targets: linux-x86-64" & LF);

      Host.Add_Directory ("root/negative");
      Host.Add_Directory ("root/negative/root-without-program");
      Host.Add_File
        ("root/negative/root-without-program/fixture.meta",
         "class: negative" & LF & "summary: no refused corpus file" & LF
         & "root: imports" & LF & "targets: linux-x86-64" & LF);
      Host.Add_Directory ("root/negative/root-with-empty-program");
      Host.Add_File
        ("root/negative/root-with-empty-program/fixture.meta",
         "class: negative" & LF & "summary: empty refused file name" & LF
         & "program:" & LF & "root: imports" & LF
         & "constructs: 1740" & LF & "targets: linux-x86-64" & LF);
      Host.Add_Directory ("root/negative/root-names-nothing");
      Host.Add_File ("root/negative/root-names-nothing/program.ldn", "");
      Host.Add_File
        ("root/negative/root-names-nothing/fixture.meta",
         "class: negative" & LF & "summary: an empty import root" & LF
         & "program: program.ldn" & LF & "root:" & LF
         & "codes: L0314" & LF & "constructs: 1740" & LF
         & "targets: linux-x86-64" & LF);

      Discover (Found, "root", Host);

      Landin.Testing.Check_Equal
        (Item, Count (Found), 0,
         "a fixture with any reported fault is not accepted");
      Landin.Testing.Check
        (Item, Mentions (Found, "metadata is missing or unreadable"),
         "a fixture without metadata is reported");
      Landin.Testing.Check
        (Item, Mentions (Found, "unknown key: colour"),
         "an unknown key is reported");
      Landin.Testing.Check
        (Item, Mentions (Found, "duplicate key: summary"),
         "a duplicate key is reported");
      Landin.Testing.Check
        (Item, Mentions (Found, "missing required key: summary"),
         "a missing required key is reported");
      Landin.Testing.Check
        (Item, Mentions (Found, "missing required key: targets"),
         "missing target applicability is reported");
      Landin.Testing.Check
        (Item, Mentions (Found, "does not match directory"),
         "a class that disagrees with its directory is reported");
      Landin.Testing.Check
        (Item, Mentions (Found, "is not `key: value`"),
         "a malformed line is reported");
      Landin.Testing.Check
        (Item, Mentions (Found, "fixture entry is not a directory"),
         "a stray file in a class directory is reported");
      Landin.Testing.Check
        (Item, Mentions (Found, "a trapping fixture has no exit status"),
         "traps beside a status is reported");
      Landin.Testing.Check
        (Item, Mentions (Found, "traps is not yes or no"),
         "a traps value that is not a verdict is reported");
      Landin.Testing.Check
        (Item, Mentions (Found, "a construct is four digits"),
         "a construct that is not four digits is reported");
      Landin.Testing.Check
        (Item, Mentions (Found, "there is no program to be the rest of"),
         "the rest of a module with no program is reported");
      Landin.Testing.Check
        (Item, Mentions (Found, "duplicate key: constructs"),
         "a repeated constructs is reported");
      Landin.Testing.Check
        (Item,
         Mentions
           (Found,
            "root/unit/codes-empty/fixture.meta: a code is L and four digits"),
         "an empty codes list is reported");
      Landin.Testing.Check
        (Item,
         Mentions
           (Found,
            "root/unit/codes-leading-comma/fixture.meta: a code is L and"
            & " four digits"),
         "a leading empty code is reported");
      Landin.Testing.Check
        (Item,
         Mentions
           (Found,
            "root/unit/codes-trailing-comma/fixture.meta: a code is L and"
            & " four digits"),
         "a trailing empty code is reported");
      Landin.Testing.Check
        (Item,
         Mentions
           (Found,
            "root/unit/codes-doubled-comma/fixture.meta: a code is L and"
            & " four digits"),
         "an empty code between commas is reported");
      Landin.Testing.Check
        (Item, Mentions (Found, "duplicate key: traps"),
         "a repeated traps is reported");
      Landin.Testing.Check
        (Item,
         Mentions
           (Found, "only a runtime or ABI fixture runs a program"),
         "traps outside the executable classes is reported");
      Landin.Testing.Check
        (Item, Mentions (Found, "an ABI fixture needs c-sources"),
         "missing ABI C sources are reported");
      Landin.Testing.Check
        (Item, Mentions (Found, "duplicate key: c-sources"),
         "repeated C sources metadata is reported");
      Landin.Testing.Check
        (Item, Mentions (Found, "duplicate key: c-args"),
         "repeated C argument metadata is reported");
      Landin.Testing.Check
        (Item, Mentions (Found, "duplicate c-sources path"),
         "a repeated C source path is reported");
      Landin.Testing.Check
        (Item, Mentions (Found, "not a relative .c file"),
         "an escaping C source path is reported");
      Landin.Testing.Check
        (Item, Mentions (Found, "which is missing or not a file"),
         "a missing C source is reported");
      Landin.Testing.Check
        (Item, Mentions (Found, "C source belongs in c-sources, never with"),
         "a C source in with is reported");
      Landin.Testing.Check
        (Item, Mentions (Found, "c-sources belong only to an ABI fixture"),
         "C sources outside the ABI class are reported");
      Landin.Testing.Check
        (Item, Mentions (Found, "c-args belong only to an ABI fixture"),
         "C arguments outside the ABI class are reported");
      Landin.Testing.Check
        (Item,
         Mentions
           (Found,
            "root/unit/root-in-unit/fixture.meta: root belongs only to a"
            & " positive, negative, runtime or ABI fixture"),
         "a root on a unit fixture is reported");
      Landin.Testing.Check
        (Item,
         Mentions
           (Found,
            "root/debugger/root-in-debugger/fixture.meta: root belongs only"
            & " to a positive, negative, runtime or ABI fixture"),
         "a root on a debugger fixture is reported");
      Landin.Testing.Check
        (Item,
         Mentions
           (Found,
            "root/end-to-end/root-in-end-to-end/fixture.meta: root belongs"
            & " only to a positive, negative, runtime or ABI fixture"),
         "a root on an end-to-end fixture is reported");
      Landin.Testing.Check
        (Item,
         Mentions
           (Found,
            "root/positive/root-without-program/fixture.meta: a rooted"
            & " positive or negative fixture needs a nonempty program"),
         "a rooted positive missing its program is reported");
      Landin.Testing.Check
        (Item,
         Mentions
           (Found,
            "root/positive/root-with-empty-program/fixture.meta: a rooted"
            & " positive or negative fixture needs a nonempty program"),
         "a rooted positive with an empty program is reported");
      Landin.Testing.Check
        (Item,
         Mentions
           (Found,
            "root/negative/root-without-program/fixture.meta: a rooted"
            & " positive or negative fixture needs a nonempty program"),
         "a rooted negative missing its program is reported");
      Landin.Testing.Check
        (Item,
         Mentions
           (Found,
            "root/negative/root-with-empty-program/fixture.meta: a rooted"
            & " positive or negative fixture needs a nonempty program"),
         "a rooted negative with an empty program is reported");
      Landin.Testing.Check
        (Item,
         Mentions
           (Found,
            "root/positive/root-and-with/fixture.meta: a rooted fixture"
            & " discovers its module files instead of naming them with"
            & " `with`"),
         "root and with remain mutually exclusive");
      Landin.Testing.Check
        (Item,
         Mentions
           (Found,
            "root/negative/root-names-nothing/fixture.meta: root names no"
            & " directory"),
         "an empty root is reported");
   end Malformed_Metadata_Is_Refused;

   --  Reads the repository's real fixture tree, deliberately: the tree is
   --  the thing under test, and a fake copy of it would prove nothing
   --  about what is on disk.
   procedure Repository_Fixtures_Are_Clean
     (Item : in out Landin.Testing.Context);

   procedure Repository_Fixtures_Are_Clean
     (Item : in out Landin.Testing.Context)
   is
      Host  : Landin.Platform.Native.Native_Filesystem;
      Found : Catalogue;
   begin
      Discover (Found, Valid_Root, Host);

      Landin.Testing.Check
        (Item, Count (Found) > 0,
         "the repository's fixture tree contains fixtures");
      Landin.Testing.Check_Equal
        (Item, Problem_Count (Found), 0,
         "the repository's fixture tree has no metadata problems");
   end Repository_Fixtures_Are_Clean;

   procedure Repository_Malformed_Cases_Are_Refused
     (Item : in out Landin.Testing.Context);

   procedure Repository_Malformed_Cases_Are_Refused
     (Item : in out Landin.Testing.Context)
   is
      Host  : Landin.Platform.Native.Native_Filesystem;
      Found : Catalogue;

      procedure Reports (Case_Name : String; Fault : String);

      --  Naming the case as well as the fault is what makes a deleted or
      --  renamed case fail here, instead of quietly shrinking what the
      --  on-disk tree covers.
      procedure Reports (Case_Name : String; Fault : String) is
         Seen : Boolean := False;
      begin
         for Index in 1 .. Problem_Count (Found) loop
            declare
               Problem : constant String := Nth_Problem (Found, Index);
            begin
               if Ada.Strings.Fixed.Index (Problem, Case_Name) > 0
                 and then Ada.Strings.Fixed.Index (Problem, Fault) > 0
               then
                  Seen := True;
               end if;
            end;
         end loop;

         Landin.Testing.Check
           (Item, Seen, Case_Name & " is reported: " & Fault);
      end Reports;

   begin
      Discover (Found, Invalid_Root, Host);

      Landin.Testing.Check_Equal
        (Item, Count (Found), 0, "no malformed fixture is accepted");

      --  One per row of compiler/tests/harness-cases/README.md.
      Reports ("no-metadata", "metadata is missing or unreadable");
      Reports ("unknown-key", "unknown key: colour");
      Reports ("duplicate-key", "duplicate key: summary");
      Reports ("missing-summary", "missing required key: summary");
      Reports ("wrong-class", "does not match directory");
      Reports ("not-a-pair", "is not `key: value`");
      Reports ("unknown-target", "unknown target: vax-11-780");
      Reports ("stray.txt", "fixture entry is not a directory");

      --  Exact, so a new fault cannot be added to the tree without being
      --  named here, and an old one cannot vanish.
      Landin.Testing.Check_Equal
        (Item, Problem_Count (Found), 8,
         "the documented malformed cases are the reported ones");
   end Repository_Malformed_Cases_Are_Refused;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "fixtures", "classes have directories",
         Classes_Have_Directories'Access);
      Landin.Testing.Register
        (Into, "fixtures", "diagnostic code boundaries are normalized",
         Diagnostic_Code_Boundaries_Are_Normalized'Access);
      Landin.Testing.Register
        (Into, "fixtures", "well formed fixtures are discovered",
         Well_Formed_Fixtures_Are_Discovered'Access);
      Landin.Testing.Register
        (Into, "fixtures", "malformed metadata is refused",
         Malformed_Metadata_Is_Refused'Access);
      Landin.Testing.Register
        (Into, "fixtures", "repository fixtures are clean",
         Repository_Fixtures_Are_Clean'Access);
      Landin.Testing.Register
        (Into, "fixtures", "repository malformed cases are refused",
         Repository_Malformed_Cases_Are_Refused'Access);
   end Register;

end Landin.Tests.Fixture_Suite;
