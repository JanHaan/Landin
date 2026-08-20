--  The repository's own test harness.
--
--  There is no third-party test framework here and there will not be one:
--  the compiler's test suite is part of the compiler, and a harness small
--  enough to read is a harness that can be trusted to be deterministic.
--
--  A case registers a name and a procedure.  Registration order does not
--  matter: cases run sorted by suite and name, so the transcript of a run
--  is the same on every host.

with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

package Landin.Testing is

   type Context is limited private;

   procedure Check
     (Item : in out Context; Condition : Boolean; Description : String);

   procedure Check_Equal
     (Item : in out Context; Actual, Expected : String; Description : String);

   procedure Check_Equal
     (Item : in out Context; Actual, Expected : Integer; Description : String);

   procedure Fail (Item : in out Context; Description : String);

   function Checks (Item : Context) return Natural;
   function Failures (Item : Context) return Natural;
   function Failure_Text (Item : Context) return String;

   type Case_Body is access procedure (Item : in out Context);

   type Registry is limited private;

   --  Raises Compiler_Defect on a duplicate (Suite, Name): two cases with
   --  one name is a harness defect, and silently running one of them is how
   --  a suite starts lying about its coverage.
   procedure Register
     (Into  : in out Registry;
      Suite : String;
      Name  : String;
      Run   : not null Case_Body);

   function Is_Registered
     (In_Registry : Registry; Suite : String; Name : String) return Boolean;

   --  True when at least one case is registered under this suite name.
   --  The test program asserts its own inventory with it: a suite that
   --  stops being registered has to make a run red rather than make it
   --  smaller.
   function Has_Suite (In_Registry : Registry; Suite : String) return Boolean;

   function Case_Count (In_Registry : Registry) return Natural;

   type Summary is record
      Cases  : Natural := 0;
      Passed : Natural := 0;
      Failed : Natural := 0;
      Checks : Natural := 0;
   end record;

   procedure Run
     (In_Registry : Registry;
      Transcript  : out Ada.Strings.Unbounded.Unbounded_String;
      Result      : out Summary);

private

   package Unbounded renames Ada.Strings.Unbounded;

   type Context is limited record
      Checks   : Natural := 0;
      Failures : Natural := 0;
      Text     : Unbounded.Unbounded_String;
   end record;

   type Entry_Record is record
      Suite : Unbounded.Unbounded_String;
      Name  : Unbounded.Unbounded_String;
      Run   : Case_Body;
   end record;

   package Entry_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Entry_Record);

   type Registry is limited record
      Items : Entry_Vectors.Vector;
   end record;

end Landin.Testing;
