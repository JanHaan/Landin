--  Fixture discovery.
--
--  A fixture is a directory holding a `fixture.meta` file and whatever the
--  fixture needs.  Fixtures live outside the Ada tree, under
--  `compiler/tests/`, because they describe the language and must survive a
--  bootstrap implementation being replaced.
--
--  Discovery is strict.  A fixture with an unknown key, a missing required
--  key, a repeated key or a class that disagrees with its directory is a
--  reported problem, not a fixture that quietly does not run.

with Ada.Containers.Indefinite_Vectors;
with Ada.Strings.Unbounded;

with Landin.Platform;
with Landin.Targets;

package Landin.Testing.Fixtures is

   type Fixture_Class is
     (Unit, Positive_Program, Negative_Program, Runtime, Abi, Debugger,
      End_To_End);

   --  The directory name that holds fixtures of this class.
   function Class_Directory (Item : Fixture_Class) return String;

   function Class_Of (Text : String; Found : out Boolean) return Fixture_Class;

   type Fixture is private;

   function Class   (Item : Fixture) return Fixture_Class;
   function Name    (Item : Fixture) return String;
   function Summary (Item : Fixture) return String;
   function Program (Item : Fixture) return String;
   function Expect  (Item : Fixture) return String;
   function Targets (Item : Fixture) return String;

   --  The diagnostic codes the report must carry, comma separated, in the
   --  order the report carries them, errors and warnings alike.  An ordered
   --  list and not a set: two refused constructs in one file are two
   --  reports, and a regression that doubles a count is invisible to a
   --  set.  A fixture whose program is accepted may name warnings only,
   --  and without the key its report must be empty.
   function Codes   (Item : Fixture) return String;

   --  Canonicalize the token boundaries in a comma-separated code list.  This
   --  removes spacing differences only: order and multiplicity are preserved.
   function Normalized_Codes (Text : String) return String;

   --  The arguments `refine` is run with, and the status it must exit with.
   --  A fixture that records an expectation and no way to produce it is
   --  dead data, so `expect` without `args` is a reported fault.
   function Args    (Item : Fixture) return String;
   --  Arguments handed to a compiled runtime or ABI program, separately from
   --  the `args` used to invoke refine for recorded command-line fixtures.
   function Run_Args (Item : Fixture) return String;
   --  Bytes expected from the compiled program on its selected Stream.
   --  This is separate from `expect`, which records refine's own output.
   function Run_Expect (Item : Fixture) return String;
   function Status  (Item : Fixture) return Integer;

   --  Required runtime/ABI metadata selects the four standard profiles or
   --  those four plus both forced-specialization profiles. Names do not
   --  select compiler policy, and a renamed fixture retains its matrix.
   function Profile_Count (Item : Fixture) return Positive
     with Pre => Class (Item) in Runtime | Abi;

   --  `levels:` names CPU feature levels, beyond each target's default, at
   --  which a runtime fixture is also executed (D255): a comma-separated
   --  list, each a level of one of the fixture's own targets.  Each lane
   --  reads the levels of its own family and runs the fixture's profiles
   --  again at each.  The empty string when the fixture names none.
   function Levels (Item : Fixture) return String;

   --  The levels `levels:` names that are x86-64's, which the Linux lane
   --  runs; each lane reads its own family's.
   function Levels_Of_Family
     (Item : Fixture; Family : Landin.Targets.Target_Facts)
      return Landin.Platform.Path_List;

   --  Whether the fixture's program must end without exiting.  [1960] says
   --  a trap's operating-system encoding is not stable program behaviour,
   --  so what a fixture may assert is that the program did not return a
   --  status -- never which signal ended it.  A trapping fixture therefore
   --  carries no `status`, and `Status` says nothing about one.
   function Traps (Item : Fixture) return Boolean;

   --  The constructs this fixture is evidence about, in the order it named
   --  them: `[NNNN]` ids without their brackets.  The construct matrix indexes
   --  the corpus by construct, and a citation in a summary is prose -- a
   --  matrix needs a list that was written to be read.  Which paragraphs exist
   --  is check.py's to know, because it is the thing that reads the documents;
   --  this side holds the shape only.
   function Constructs (Item : Fixture) return String;

   --  The rest of the module, when a fixture needs more than one file.
   --  [1840]'s module scope is "every file compiled together", so a claim
   --  about it cannot be made by a fixture that can only name one; this is
   --  what lets one be written.  `program` stays the file the fixture is
   --  named for, and these are handed to `refine` after it.
   function With_Sources (Item : Fixture) return String;

   --  An optional import root, relative to the fixture directory. A positive,
   --  negative, runtime or ABI fixture that names one is compiled as a
   --  directory entry module, so it can use the same repository-owned library
   --  modules users import. Rooted positive and negative fixtures still name a
   --  nonempty program as their compile-only corpus file.
   function Module_Root (Item : Fixture) return String;

   --  What the fixture's sources become once the first fix of every
   --  diagnostic in its report is applied, which must then compile clean.
   --  Comma separated.  A bare name is the program's result; `a -> b`
   --  names the result of another source the fixes edit, relative to the
   --  fixture directory as `with` is.  Only a negative fixture that names
   --  codes has a report to take fixes from.
   function Fixed (Item : Fixture) return String;

   --  Append the source-selection arguments for this fixture to a refine
   --  invocation.  A rooted fixture contributes `--root=<directory>/<root>`
   --  followed by its directory entry module.  Otherwise its program and each
   --  source named by `with` are appended in metadata order.
   procedure Append_Module_Arguments
     (Item         : Fixture;
      Fixture_Root : String;
      To           : in out Landin.Platform.Path_List);

   --  ABI fixtures pair emitted Landin assembly with these ordered C11
   --  companions.  The source names are comma-separated relative `.c` paths;
   --  compiler and linker arguments are whitespace-separated and are kept as
   --  argument-vector elements rather than reparsed by a shell.
   function C_Sources (Item : Fixture) return String;
   function C_Args    (Item : Fixture) return String;

   --  Which stream the expectation is about.  `output` means the bytes
   --  must arrive on standard output and standard error must be empty;
   --  `merged` accepts either, and is only right where a fixture does not
   --  care.  Without this, swapping refine's two streams changed nothing
   --  any fixture could see.
   type Stream_Choice is (Output, Merged);

   function Stream (Item : Fixture) return Stream_Choice;

   type Catalogue is limited private;

   --  With empty Only, read every fixture's metadata.  With a class/name
   --  label, inspect that class directory and read metadata only for matching
   --  entries.  A missing or ambiguous label remains visible through Count;
   --  matching metadata faults remain visible through Problem_Count.  A
   --  missing class directory is not a problem in the complete corpus.
   procedure Discover
     (Into : in out Catalogue;
      Root : String;
      Host : Landin.Platform.Filesystem'Class;
      Only : String := "");

   function Count (In_Catalogue : Catalogue) return Natural;

   --  Ordered by class, then by name.
   function Nth (In_Catalogue : Catalogue; Index : Positive) return Fixture
     with Pre => Index <= Count (In_Catalogue);

   function Count_Of
     (In_Catalogue : Catalogue; Of_Class : Fixture_Class;
      Lane : String := "") return Natural;

   --  Independent metadata obligations for the corpus runners. These count
   --  eligible fixtures, not successful verdicts or generated executables.
   --  LANE is a `targets:` label; a count with one counts only the fixtures
   --  that name it, and the empty string counts every fixture.
   function Program_Count
     (In_Catalogue : Catalogue;
      Of_Class : Fixture_Class;
      Require_Codes : Boolean := False;
      Lane : String := "") return Natural;

   function Recorded_Count (In_Catalogue : Catalogue) return Natural;

   --  FAMILY's levels are the ones each counted fixture also runs at.
   function Profile_Run_Count
     (In_Catalogue : Catalogue; Of_Class : Fixture_Class;
      Family : Landin.Targets.Target_Facts := Landin.Targets.Linux_X86_64;
      Lane : String := "") return Natural
     with Pre => Of_Class in Runtime | Abi;

   --  Compare every discovered identity and target list with check.py's
   --  independently generated targets.matrix. Reject missing, additional or
   --  duplicate rows and malformed catalogues; only its four prototype scope
   --  rows and comments are outside the fixture inventory.
   function Matches_Inventory
     (In_Catalogue : Catalogue; Text : String) return Boolean;

   function Problem_Count (In_Catalogue : Catalogue) return Natural;

   function Nth_Problem
     (In_Catalogue : Catalogue; Index : Positive) return String
     with Pre => Index <= Problem_Count (In_Catalogue);

private

   package Unbounded renames Ada.Strings.Unbounded;

   type Profile_Policy is (Standard, Specialization);

   type Fixture is record
      Class   : Fixture_Class := Unit;
      Name    : Unbounded.Unbounded_String;
      Summary : Unbounded.Unbounded_String;
      Program : Unbounded.Unbounded_String;
      Expect  : Unbounded.Unbounded_String;
      Targets : Unbounded.Unbounded_String;
      Args    : Unbounded.Unbounded_String;
      Run_Args : Unbounded.Unbounded_String;
      Run_Expect : Unbounded.Unbounded_String;
      Codes   : Unbounded.Unbounded_String;
      Status  : Integer := 0;
      Traps   : Boolean := False;
      Made_Of   : Ada.Strings.Unbounded.Unbounded_String;
      Beside    : Ada.Strings.Unbounded.Unbounded_String;
      Root      : Ada.Strings.Unbounded.Unbounded_String;
      Fixed     : Ada.Strings.Unbounded.Unbounded_String;
      C_Files   : Ada.Strings.Unbounded.Unbounded_String;
      C_Options : Ada.Strings.Unbounded.Unbounded_String;
      Stream    : Stream_Choice := Merged;
      Profiles  : Profile_Policy := Standard;
      Levels    : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   package Fixture_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => Fixture);

   package Problem_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => String);

   type Catalogue is limited record
      Items    : Fixture_Vectors.Vector;
      Problems : Problem_Vectors.Vector;
   end record;

end Landin.Testing.Fixtures;
