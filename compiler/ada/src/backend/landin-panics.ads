--  Compiler-check identities and explicit source handler selection. This
--  table is compilation data; it allocates nothing in a Landin image.
private with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;
with Landin.IR;
with Landin.Provenance;
with Landin.Source;
with Landin.Stages;

package Landin.Panics is
   type Kind is (Out_Of_Range, Overflow, Bad_Conversion, Unreachable);
   type Site_Number is range 0 .. 2 ** 32 - 1;
   type Plan is private;

   procedure Prepare
     (Context : in out Landin.Stages.Compilation;
      Into : out Plan;
      Problem : out Ada.Strings.Unbounded.Unbounded_String);

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

private
   type Source_Range is record
      First : Site_Number;
      Length : Landin.Source.Byte_Offset;
   end record;
   package Range_Vectors is new Ada.Containers.Vectors
     (Positive, Source_Range);
   type Code_Array is array (Kind) of Positive;
   type Plan is record
      Selected : Landin.IR.Item_Id := Landin.IR.No_Item;
      Codes : Code_Array := [1, 2, 3, 4];
      Sources : Range_Vectors.Vector;
   end record;
end Landin.Panics;
