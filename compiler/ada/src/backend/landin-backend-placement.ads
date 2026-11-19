--  What a register allocator reads of a routine before it places
--  anything (D1403): the order the backends lay its values out in, where
--  each value is read last, which slots may live outside their frame cell
--  at all and how much each is used, and each slot's live interval from
--  Landin.IR.Liveness.  Nothing here names a register: which register may
--  hold a slot or value at a position is the backend's own question,
--  since it turns on what its selection writes there.  arm64 and RISC-V
--  place over the same answers.
with Landin.IR.Liveness;
with Landin.Backend.Work_Arrays;

package Landin.Backend.Placement is

   type Counts is array (Positive range <>) of Natural;
   package Count_Buffers is new Landin.Backend.Work_Arrays
     (Natural, Counts, 0);
   package Mask_Buffers is new Landin.Backend.Work_Arrays
     (Boolean, Home_Mask, False);

   --  Positions count from one in layout order: blocks by identity and
   --  each block's values in order, as Landin.IR.Liveness counts them.
   --  Boundaries is Values + 1, the length of Calls_Before.
   type Usage (Values, Slots, Boundaries : Natural) is limited record
      --  The value at each position, and each value's position.
      Sequence, Starts : Count_Buffers.Buffer (Values);
      --  Each value's last reader's position, or its own when nothing
      --  reads it.  Evidence_Self reads its projection's receiver.
      Lasts : Count_Buffers.Buffer (Values);
      --  For each load, the position of the next store to its slot in the
      --  same block, else Natural'Last; computed without assembly only.
      Written_After : Count_Buffers.Buffer (Values);
      --  How many calls and assembly blocks lie before each position:
      --  Calls_Before (P + 1) - Calls_Before (P) is one at a call.
      Calls_Before : Count_Buffers.Buffer (Boundaries);
      --  Whether a value must have a frame home: assembly reads its
      --  inputs, and C transport its scalar arguments and result, there.
      Address_Required : Mask_Buffers.Buffer (Values);
      --  Each slot's loads and stores, or reads of the address it holds,
      --  counted once each, and weighted eight times for each loop around
      --  them, up to four, when Speed.  A parameter counts its entry, and
      --  a Landin routine's result slot its leave, without assembly.
      Uses, Weights : Count_Buffers.Buffer (Slots);
      --  Each parameter slot's place among the parameters, else 0.
      Parameter_Of : Count_Buffers.Buffer (Slots);
      --  Each slot's first and last load or store, by position, the
      --  block of its first, and whether another block has one too.
      First_Use, Last_Use, First_Block : Count_Buffers.Buffer (Slots);
      Across_Blocks : Mask_Buffers.Buffer (Slots);
      --  A scalar slot no storage operand, C transport, failure carrier
      --  or source alias reaches by address.
      Eligible : Mask_Buffers.Buffer (Slots);
      --  Each slot's live interval.  At size a source variable's covers
      --  the whole routine, so that a debugger finds it anywhere.
      Spans : Landin.IR.Liveness.Interval_Vectors.Vector;
      Has_Assembly : Boolean := False;
      C_Entry : Boolean := False;
      --  Scalar results and operands, the routine's scalar traffic.
      Traffic : Natural := 0;
   end record;

   --  Fill Into, whose discriminants are the routine's value and slot
   --  counts and one more than its value count.  Debugger_Spans gives a
   --  source variable's slot the whole routine at size; a backend whose
   --  debug information describes no local passes False (D1567).
   procedure Measure
     (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id;
      Speed : Boolean; Into : in out Usage;
      Debugger_Spans : Boolean := True);

end Landin.Backend.Placement;
