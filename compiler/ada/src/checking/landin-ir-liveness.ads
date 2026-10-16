--  Where a routine's slots hold a value something later reads, and how
--  deeply its loops nest, over the order every backend lays a routine out
--  in: blocks by identity and each block's values in order.  Position N is
--  the Nth value so met, and position zero is the routine's entry, before
--  its first value.  Neither answer chooses a location: a backend decides
--  which slots it may keep in a register, and the slots it may not are
--  its own to know.
with Ada.Containers.Vectors;
with Landin.IR.Control_Flow;

package Landin.IR.Liveness is

   package Count_Vectors is new Ada.Containers.Vectors (Positive, Natural);

   --  How many loops enclose each block, from the control flow alone.  An
   --  unreachable block is in none.
   function Loop_Depths
     (Of_Graph : Control_Flow.Graph) return Count_Vectors.Vector;

   --  One slot's live interval: every position at which it holds a value
   --  that some path on to a read still needs, with every reference to it.
   --  Between two such positions it may be dead, where no path reads what
   --  it holds; a location kept for First .. Last is never disturbed by
   --  anything else's.  An unreferenced slot's interval is empty.
   type Interval is record
      First : Natural := 1;
      Last : Natural := 0;
   end record;
   function Is_Empty (Span : Interval) return Boolean
     is (Span.Last < Span.First);
   package Interval_Vectors is new Ada.Containers.Vectors
     (Positive, Interval);

   --  Each slot's interval.  A parameter is written at entry.  A load, a
   --  field or element operation reaching the slot, a storage operand
   --  naming it, a call's failure slot and, at a leave, the result slot
   --  and the first parameter of a routine returning an aggregate or an
   --  array, all read it; a store and an assembly output write it.  Work
   --  is the routine's values and blocks, plus each slot's blocks it is
   --  live into; past a bound linear in the routine, the slots left are
   --  given the whole routine instead, which is never wrong.
   function Slot_Intervals
     (Of_Unit : Unit; Item : Item_Id; Of_Graph : Control_Flow.Graph)
      return Interval_Vectors.Vector;

end Landin.IR.Liveness;
