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

   --  The arguments `refine` is run with, and the status it must exit with.
   --  A fixture that records an expectation and no way to produce it is
   --  dead data, so `expect` without `args` is a reported fault.
   function Args    (Item : Fixture) return String;
   function Status  (Item : Fixture) return Integer;

   --  Which stream the expectation is about.  `output` means the bytes
   --  must arrive on standard output and standard error must be empty;
   --  `merged` accepts either, and is only right where a fixture does not
   --  care.  Without this, swapping refine's two streams changed nothing
   --  any fixture could see.
   type Stream_Choice is (Output, Merged);

   function Stream (Item : Fixture) return Stream_Choice;

   type Catalogue is limited private;

   --  Reads `Root/<class-directory>/<name>/fixture.meta` for every class.
   --  A missing class directory is not a problem: a class with no fixtures
   --  yet is the normal state early in the roadmap.
   procedure Discover
     (Into : in out Catalogue;
      Root : String;
      Host : Landin.Platform.Filesystem'Class);

   function Count (In_Catalogue : Catalogue) return Natural;

   --  Ordered by class, then by name.
   function Nth (In_Catalogue : Catalogue; Index : Positive) return Fixture
     with Pre => Index <= Count (In_Catalogue);

   function Count_Of
     (In_Catalogue : Catalogue; Of_Class : Fixture_Class) return Natural;

   function Problem_Count (In_Catalogue : Catalogue) return Natural;

   function Nth_Problem
     (In_Catalogue : Catalogue; Index : Positive) return String
     with Pre => Index <= Problem_Count (In_Catalogue);

private

   package Unbounded renames Ada.Strings.Unbounded;

   type Fixture is record
      Class   : Fixture_Class := Unit;
      Name    : Unbounded.Unbounded_String;
      Summary : Unbounded.Unbounded_String;
      Program : Unbounded.Unbounded_String;
      Expect  : Unbounded.Unbounded_String;
      Targets : Unbounded.Unbounded_String;
      Args    : Unbounded.Unbounded_String;
      Status  : Integer := 0;
      Stream  : Stream_Choice := Merged;
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
