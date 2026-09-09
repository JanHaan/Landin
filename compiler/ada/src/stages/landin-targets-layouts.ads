--  Pure placement of complete source-indexed units.  Array lengths never
--  become planner entries.  C subset eligibility belongs to checking/C_ABI;
--  its already classified units use the same source-order placement here.
with Landin.Layouts;

package Landin.Targets.Layouts is

   type Field_Extent is record
      Size      : Byte_Count := 0;
      Alignment : Byte_Alignment := 1;
   end record;

   type Field_Extent_Array is array (Positive range <>) of Field_Extent;
   type Field_Order is array (Positive range <>) of Positive;
   type Field_Offsets is array (Positive range <>) of Byte_Count;

   type Plan (Count : Natural) is record
      --  Positions, not input-array indexes: both arrays start at one even
      --  if the input is a slice with another lower bound.
      Order        : Field_Order (1 .. Count);
      Offsets      : Field_Offsets (1 .. Count);
      Size         : Byte_Count := 0;
      Alignment    : Byte_Alignment := 1;
      Natural_Size : Byte_Count := 0;
      Saved_Bytes  : Byte_Count := 0;
   end record;

   --  Stable descending alignment is only selected when the final padded
   --  size is strictly smaller.  Zero-size units still require alignment.
   --  Invalid alignment or byte-count overflow raises Compiler_Defect in
   --  every build mode.  Maximum limits the selected size, so an optimal
   --  placement may rescue a natural layout above a target's object limit.
   function Make
     (Fields  : Field_Extent_Array;
      Policy  : Landin.Layouts.Policy := Landin.Layouts.Natural;
      Maximum : Byte_Count := Byte_Count'Last) return Plan;

   --  Same computation, returning False for invalid/oversized placement so
   --  source checking can diagnose it instead of raising a compiler defect.
   function Fits
     (Fields  : Field_Extent_Array;
      Policy  : Landin.Layouts.Policy := Landin.Layouts.Natural;
      Maximum : Byte_Count := Byte_Count'Last) return Boolean;

end Landin.Targets.Layouts;
