--  D537: the one check of a program's static images before emission, on
--  every target, against a budget the caller selects: the target's reach,
--  or a firmware profile's capacities.  No filesystem or tool effects.
with Landin.IR;
with Landin.Targets;

package Landin.Backend.Images is

   --  What a unit's images take, counted before section garbage collection
   --  and before optimization: every datum the unit holds, which is what
   --  the assembler is given.  A count that would pass the largest
   --  Byte_Count stays there and is Past, which no budget admits.
   type Count is record
      Bytes : Landin.Targets.Byte_Count := 0;
      Past  : Boolean := False;
   end record;

   type Usage is record
      Initialized : Count;
      Writable    : Count;
      Reserved    : Count;
   end record;

   function Measure
     (Of_Unit : Landin.IR.Unit;
      Facts   : Landin.Targets.Target_Facts) return Usage;

   --  Which part of the budget a usage exceeds, the first in this order.
   type Excess is (Within, Initialized, Writable, Reserved);

   function Exceeded
     (Used : Usage; Budget : Landin.Targets.Image_Budget) return Excess;

   --  The refusal's message: what the images take, against the part of
   --  the budget they exceed, which Holder names as what holds or reaches
   --  it: "x86-64's small code model reaches on linux-x86-64".
   function Refusal
     (Used   : Usage;
      Budget : Landin.Targets.Image_Budget;
      Over   : Excess;
      Holder : String) return String
     with Pre => Over /= Within;

end Landin.Backend.Images;
