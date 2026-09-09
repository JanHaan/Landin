--  What a routine's frame holds, and where.
--
--  `tour.md` [1550] says the frame pointer is always set up, and
--  `Landin.IR`'s header says a slot "has no address, no offset and no
--  size" because "where it lives is R1.80's frame question".  This is
--  that answer, and it is deliberately target-neutral: an offset here is
--  a count of target bytes and nothing below asks the host how wide a
--  thing is.  Which register the frame pointer is, and how a store to
--  one of these offsets is spelt, is a child's.
--
--  The reference layout gives every scalar value a separate cell.  The
--  allocation-driven overload instead consumes explicit storage needs:
--  pinned slots, reusable spill homes and callee-save homes.  Register
--  identities and the proof that two values can reuse storage belong to
--  the target child; this parent validates capacities and places bytes.
--  Neither representation expands a compact array into per-element cells.
--
--  Offsets grow downward and are reported as positive distances *below*
--  the frame pointer, because that is how every caller has to spell one
--  and a signed offset would make each of them negate it again.  A cell
--  is placed at the first distance that is at least its own size and a
--  multiple of its alignment, which is what makes the address it names
--  aligned rather than merely the count that reaches it.
--
--  bool is one byte here.  [0150] says a one-bit field outside a packed
--  struct "occupies the next machine width", and the next machine width
--  above one bit is a byte.  R2.10 owns layout in general and may have
--  more to say about a bool inside an aggregate; a frame cell is not an
--  aggregate, and this item cannot lay out a frame without an answer.

private with Ada.Containers.Vectors;

with Landin.IR;
with Landin.Targets;
with Landin.Layouts;
with Landin.Targets.Layouts;
with Landin.Types;

package Landin.Backend is

   type Frame is private;

   --  Slots first, in slot order, then values, in value order.  Both are
   --  functions of the lowering order alone, so the same source yields
   --  the same frame on any host -- the property `Landin.IR` argues for
   --  its own numbering, kept here rather than re-earned.
   function Laid_Out
     (Of_Unit : Landin.IR.Unit;
      Item    : Landin.IR.Item_Id;
      Facts   : Landin.Targets.Target_Facts) return Frame
     with Pre => Landin.IR.Holds (Of_Unit, Item);

   --  Indexes are source slot/value positions, starting at one.  False
   --  slots and zero value assignments reserve no storage.  Positive value
   --  assignments select an explicit spill home; disjoint live intervals
   --  may name the same home.  Homes and saves are placed in supplied order
   --  after pinned slots, with alignment checked against the target stack.
   type Home_Mask is array (Positive range <>) of Boolean;
   type Spill_Assignments is array (Positive range <>) of Natural;

   function Laid_Out
     (Of_Unit : Landin.IR.Unit;
      Item    : Landin.IR.Item_Id;
      Facts   : Landin.Targets.Target_Facts;
      Slots   : Home_Mask;
      Values  : Spill_Assignments;
      Spills  : Landin.Targets.Layouts.Field_Extent_Array;
      Saves   : Landin.Targets.Layouts.Field_Extent_Array) return Frame;

   function Has_Slot_Home
     (Of_Frame : Frame; Slot : Landin.IR.Slot_Id) return Boolean;
   function Has_Value_Home
     (Of_Frame : Frame; Value : Landin.IR.Value_Id) return Boolean;
   function Spill_Offset
     (Of_Frame : Frame; Home : Positive) return Landin.Targets.Byte_Count;
   function Save_Offset
     (Of_Frame : Frame; Home : Positive) return Landin.Targets.Byte_Count;

   --  Sum of requested home extents, excluding inter-home/final padding.
   function Spill_Bytes (Of_Frame : Frame) return Landin.Targets.Byte_Count;
   function Save_Bytes (Of_Frame : Frame) return Landin.Targets.Byte_Count;

   --  What the prologue subtracts: the whole extent, rounded up to the
   --  target's stack alignment so the frame leaves the stack as aligned
   --  as it found it.
   function Extent (Of_Frame : Frame) return Landin.Targets.Byte_Count;

   function Slot_Offset
     (Of_Frame : Frame; Slot : Landin.IR.Slot_Id)
     return Landin.Targets.Byte_Count;

   --  Where one field of an aggregate slot sits, as a distance below the
   --  frame pointer like any other cell.  A cell grows downward while
   --  aggregate fields grow upward from its base.  Subtract the selected
   --  source field's physical offset from the cell's downward distance;
   --  an explicit optimal layout may place that field out of source order.
   function Field_Offset
     (Of_Unit  : Landin.IR.Unit;
      Item     : Landin.IR.Item_Id;
      Of_Frame : Frame;
      Slot     : Landin.IR.Slot_Id;
      Field    : Landin.IR.Part_Position;
      Facts    : Landin.Targets.Target_Facts)
     return Landin.Targets.Byte_Count
     with Pre => Landin.IR.Holds (Of_Unit, Item)
                 and then Landin.IR.Holds (Of_Unit, Item, Slot)
                 and then (Landin.IR.Is_Aggregate (Of_Unit, Item, Slot)
                           or else Landin.IR.Is_Array
                                     (Of_Unit, Item, Slot))
                 and then Landin.IR."<="
                            (Landin.IR.Element_Total (Field),
                             Landin.IR.Slot_Part_Count
                               (Of_Unit, Item, Slot));

   --  How much room an aggregate slot takes, and how it must be aligned:
   --  [0750]'s whole placement over the slot's own field run.
   procedure Aggregate_Extent
     (Of_Unit   : Landin.IR.Unit;
      Item      : Landin.IR.Item_Id;
      Slot      : Landin.IR.Slot_Id;
      Facts     : Landin.Targets.Target_Facts;
      Size      : out Landin.Targets.Byte_Count;
      Alignment : out Landin.Targets.Byte_Alignment)
     with Pre => Landin.IR.Holds (Of_Unit, Item)
                 and then Landin.IR.Holds (Of_Unit, Item, Slot)
                 and then (Landin.IR.Is_Aggregate (Of_Unit, Item, Slot)
                           or else Landin.IR.Is_Array
                                     (Of_Unit, Item, Slot));

   --  Shared physical placement for all consumers, including datum image
   --  replay.  Order contains source field positions in physical order;
   --  Offsets is indexed by source position.  Nested fields apply their own
   --  policy, and variants retain their tag-first/source-order payloads.
   function Fields_Layout
     (Of_Unit : Landin.IR.Unit;
      Fields  : Landin.IR.Field_Shape_Array;
      Policy  : Landin.Layouts.Policy;
      Facts   : Landin.Targets.Target_Facts)
      return Landin.Targets.Layouts.Plan;

   function Aggregate_Layout
     (Of_Unit : Landin.IR.Unit;
      Shape   : Landin.IR.Field_Shape;
      Facts   : Landin.Targets.Target_Facts)
      return Landin.Targets.Layouts.Plan;

   function Nominal_Layout
     (Of_Unit : Landin.IR.Unit;
      Nominal : Landin.IR.Nominal_Type_Id;
      Facts   : Landin.Targets.Target_Facts)
      return Landin.Targets.Layouts.Plan;

   function Slot_Layout
     (Of_Unit : Landin.IR.Unit;
      Item    : Landin.IR.Item_Id;
      Slot    : Landin.IR.Slot_Id;
      Facts   : Landin.Targets.Target_Facts)
      return Landin.Targets.Layouts.Plan;

   function Datum_Layout
     (Of_Unit : Landin.IR.Unit;
      Item    : Landin.IR.Item_Id;
      Facts   : Landin.Targets.Target_Facts)
      return Landin.Targets.Layouts.Plan;

   function Measurement_Layout
     (Of_Unit : Landin.IR.Unit;
      Item    : Landin.IR.Item_Id;
      Value   : Landin.IR.Value_Id;
      Facts   : Landin.Targets.Target_Facts)
      return Landin.Targets.Layouts.Plan;

   --  The target extent of one neutral field shape.  D86 recursively replays
   --  a measurement-only aggregate run; runtime datum and slot runs retain
   --  the scalar, fixed-array and unfolded-variant shapes.
   procedure Field_Extent
     (Of_Unit   : Landin.IR.Unit;
      Shape     : Landin.IR.Field_Shape;
      Facts     : Landin.Targets.Target_Facts;
      Size      : out Landin.Targets.Byte_Count;
      Alignment : out Landin.Targets.Byte_Alignment);

   --  D76's scalar payload write reaches one field inside one selected
   --  case.  The offset is relative to the start of the variant part and
   --  is replayed from the same tag-first/max-payload rule as Field_Extent;
   --  no target byte offset enters Landin.IR.
   function Variant_Payload_Field_Offset
     (Of_Unit       : Landin.IR.Unit;
      Shape         : Landin.IR.Field_Shape;
      Which         : Positive;
      Payload_Field : Positive;
      Facts         : Landin.Targets.Target_Facts)
      return Landin.Targets.Byte_Count
     with Pre => Landin.IR."="
                   (Shape.Kind, Landin.IR.Variant_Field_Shape)
                 and then Which <= Shape.Cases
                 and then Landin.IR.Variant_Case_Run_Is_Valid
                   (Of_Unit, Shape, Which)
                 and then Payload_Field <=
                   Landin.IR.Variant_Case_Field_Count
                     (Of_Unit, Shape, Which);

   --  Answer one target-neutral measurement instruction.  Aggregate
   --  measurements carry declaration-order scalar or compact fixed-array
   --  fields and D74/D75's shared variant case runs; this
   --  target-owning seam derives their padded placement with Landin.Targets.
   procedure Measurement_Extent
     (Of_Unit   : Landin.IR.Unit;
      Item      : Landin.IR.Item_Id;
      Value     : Landin.IR.Value_Id;
      Facts     : Landin.Targets.Target_Facts;
      Size      : out Landin.Targets.Byte_Count;
      Alignment : out Landin.Targets.Byte_Alignment)
     with Pre => Landin.IR.Holds (Of_Unit, Item, Value)
                 and then Landin.IR.Op_Of (Of_Unit, Item, Value)
                          in Landin.IR.Measure_Size | Landin.IR.Measure_Align;

   function Value_Offset
     (Of_Frame : Frame; Value : Landin.IR.Value_Id)
     return Landin.Targets.Byte_Count;

   --  How much room one of [1790]'s scalars needs.  Not a width: a width
   --  is bits and comes from Landin.Types, and bool has none.
   function Size_Of
     (Item : Landin.Types.Scalar_Name;
      Facts : Landin.Targets.Target_Facts)
     return Landin.Targets.Scalar_Size;

private

   package Offset_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Landin.Targets.Byte_Count,
      "="          => Landin.Targets."=");

   package Home_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Boolean);

   type Frame is record
      Slots       : Offset_Vectors.Vector;
      Values      : Offset_Vectors.Vector;
      Slot_Homes  : Home_Vectors.Vector;
      Spills      : Offset_Vectors.Vector;
      Saves       : Offset_Vectors.Vector;
      Spill_Total : Landin.Targets.Byte_Count := 0;
      Save_Total  : Landin.Targets.Byte_Count := 0;
      Size        : Landin.Targets.Byte_Count := 0;
   end record;

end Landin.Backend;
