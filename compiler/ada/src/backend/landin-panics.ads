--  Compiler-check identities and explicit source handler selection. This
--  table is compilation data; it allocates nothing in a Landin image.
--
--  It also holds what D361's hosted default says about a failed check:
--  with no selected handler on a target with a hosted system, each trap
--  writes one line naming its source site and kind before it ends.  The
--  line's text is decided here, once, so every backend writes the same
--  bytes; how it reaches standard error is each backend's.
private with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;
with Landin.IR;
with Landin.Provenance;
with Landin.Source;
with Landin.Stages;

package Landin.Panics is
   --  D232's canonical domain, with D451's fifth kind: a stack switch
   --  past its limit, or a stack too small to prepare.
   type Kind is
     (Out_Of_Range, Overflow, Bad_Conversion, Unreachable, Stack_Exhausted);
   type Site_Number is range 0 .. 2 ** 32 - 1;
   type Plan is private;

   procedure Prepare
     (Context : in out Landin.Stages.Compilation;
      Into : out Plan;
      Problem : out Ada.Strings.Unbounded.Unbounded_String);

   --  A source file named by its path relative to its module's root, as
   --  D361's report names it: `core/vec/vec.ldn` for a library module's,
   --  `main.ldn` for the entry module's, whatever path it was read from.
   function Displayed_Name
     (Context : in out Landin.Stages.Compilation;
      Source  : Landin.Source.Source_Id) return String;

   function Handler (Of_Plan : Plan) return Landin.IR.Item_Id;
   function Code (Of_Plan : Plan; Reason : Kind) return Positive;
   function For_Value
     (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id;
      Value : Landin.IR.Value_Id) return Kind;
   function Site
     (Of_Plan : Plan; Origin : Landin.Provenance.Origin;
      Reason : Kind) return Site_Number;
   function Base
     (Of_Plan : Plan; Source : Landin.Source.Source_Id) return Site_Number;

   --  D361: no handler is selected and the target has a hosted system, so
   --  a failed check writes Report's line to standard error before the
   --  terminal instruction.  Firmware keeps D232's bare instruction.
   function Reports_Default (Of_Plan : Plan) return Boolean;

   --  Whether a failed check calls anything before its terminal
   --  instruction: a selected handler, or D361's default report.
   function Calls_Out (Of_Plan : Plan) return Boolean;

   --  The line D361's default writes for a check at Origin, newline
   --  included: `FILE:LINE:COLUMN: trap: KIND`, or `trap: KIND` for a
   --  site with no source.  A file is named by its path relative to its
   --  module's root: a library module's by its module path,
   --  `core/vec/vec.ldn`, an entry-module file by its own name,
   --  `main.ldn`, so the bytes depend neither on where the program or the
   --  library is nor on how a path was spelled.
   function Report
     (Of_Plan : Plan; Origin : Landin.Provenance.Origin;
      Reason : Kind) return String
     with Pre => Reports_Default (Of_Plan);

private
   package Offset_Vectors is new Ada.Containers.Vectors
     (Positive, Landin.Source.Byte_Offset, Landin.Source."=");
   type Source_Range is record
      First : Site_Number;
      Length : Landin.Source.Byte_Offset;
      --  Only for D361's report: the file's displayed name and the byte
      --  offset at which each of its lines starts.
      Name : Ada.Strings.Unbounded.Unbounded_String;
      Lines : Offset_Vectors.Vector;
   end record;
   package Range_Vectors is new Ada.Containers.Vectors
     (Positive, Source_Range);
   type Code_Array is array (Kind) of Positive;
   type Plan is record
      Selected : Landin.IR.Item_Id := Landin.IR.No_Item;
      Hosted : Boolean := False;
      Codes : Code_Array := [1, 2, 3, 4, 5];
      Sources : Range_Vectors.Vector;
   end record;
end Landin.Panics;
