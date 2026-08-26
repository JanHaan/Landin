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
--  Every value gets a cell, not only every slot, and that is a decision
--  rather than an oversight.  `Landin.IR` keeps values block-local so a
--  backend never has to compute dominance, and the cheapest correct way
--  to honour that is to give each defined value somewhere to live and to
--  reload it where it is used.  The roadmap asks for "deterministic
--  baseline code generation before competitive optimization" and puts
--  promoting a cell to a register in R4.50, where a register allocator
--  is actually being written.  The cost is stated plainly rather than
--  hidden: this frame is as large as the item has values, and every
--  operand is a memory reference.
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

   --  What the prologue subtracts: the whole extent, rounded up to the
   --  target's stack alignment so the frame leaves the stack as aligned
   --  as it found it.
   function Extent (Of_Frame : Frame) return Landin.Targets.Byte_Count;

   function Slot_Offset
     (Of_Frame : Frame; Slot : Landin.IR.Slot_Id)
     return Landin.Targets.Byte_Count;

   --  Where one field of an aggregate slot sits, as a distance below the
   --  frame pointer like any other cell.  A cell grows downward and
   --  [0750] lays a struct out upward, so field 1 is furthest from the
   --  frame pointer and the last field is nearest: this subtracts the
   --  field's own offset from the cell's, which is what keeps a hexdump
   --  of the cell matching the source.
   function Field_Offset
     (Of_Unit  : Landin.IR.Unit;
      Item     : Landin.IR.Item_Id;
      Of_Frame : Frame;
      Slot     : Landin.IR.Slot_Id;
      Field    : Positive;
      Facts    : Landin.Targets.Target_Facts)
     return Landin.Targets.Byte_Count
     with Pre => Landin.IR.Holds (Of_Unit, Item)
                 and then Landin.IR.Holds (Of_Unit, Item, Slot)
                 and then Landin.IR.Is_Aggregate (Of_Unit, Item, Slot)
                 and then Field
                          <= Landin.IR.Slot_Field_Count
                               (Of_Unit, Item, Slot);

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
                 and then Landin.IR.Is_Aggregate (Of_Unit, Item, Slot);

   function Value_Offset
     (Of_Frame : Frame; Value : Landin.IR.Value_Id)
     return Landin.Targets.Byte_Count;

   --  How much room one of [1790]'s eleven needs.  Not a width: a width
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

   type Frame is record
      Slots  : Offset_Vectors.Vector;
      Values : Offset_Vectors.Vector;
      Size   : Landin.Targets.Byte_Count := 0;
   end record;

end Landin.Backend;
