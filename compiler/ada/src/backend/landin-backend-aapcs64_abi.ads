--  arm64 C transport: the Procedure Call Standard for the Arm 64-bit
--  Architecture, and Apple's variant of it.  ABI placement never enters
--  neutral IR.
--
--  Both conventions share the eight integer and eight vector argument
--  registers, homogeneous floating aggregates of one to four members, the
--  sixteen-byte bound above which a composite is passed by reference to a
--  caller's copy, and the indirect result address in x8.  Apple differs in
--  two places: every unnamed argument of a variadic call goes on the stack
--  in an eight-byte slot, and a named scalar or homogeneous floating
--  aggregate on the stack takes its natural size and alignment rather than
--  a whole eight-byte slot.  The convention comes from the description's C
--  ABI, never from its architecture.
with Landin.IR;
with Landin.Targets;

package Landin.Backend.AAPCS64_ABI is

   type Carrier_Class is (No_Class, Integer_Class, Float_Class);
   type Class_Run is array (Positive range 1 .. 4) of Carrier_Class;
   type Register_Run is array (Positive range 1 .. 4) of Natural;

   type Classification is record
      Size      : Landin.Targets.Byte_Count := 0;
      Alignment : Landin.Targets.Byte_Alignment := 1;
      Aggregate : Boolean := False;
      Indirect  : Boolean := False;
      Float_Bytes : Landin.Targets.Byte_Count := 0;
      Count     : Natural range 0 .. 4 := 0;
      Classes   : Class_Run := [others => No_Class];
   end record;

   function Classify
     (Of_Unit : Landin.IR.Unit;
      Part    : Landin.IR.Signature_Part;
      Facts   : Landin.Targets.Target_Facts) return Classification;

   type Location is record
      Shape     : Classification;
      On_Stack  : Boolean := False;
      Stack_At  : Landin.Targets.Byte_Count := 0;
      --  One-based x0..x7 or v0..v7; indirect results use x8.
      Registers : Register_Run := [others => 0];
   end record;
   type Location_Array is array (Positive range <>) of Location;

   type Plan (Count : Natural) is record
      Result      : Location;
      Arguments   : Location_Array (1 .. Count);
      GP_Used     : Natural range 0 .. 8 := 0;
      FP_Used    : Natural range 0 .. 8 := 0;
      Stack_Bytes : Landin.Targets.Byte_Count := 0;
   end record;

   function Assign
     (Of_Unit    : Landin.IR.Unit;
      Parameters : Landin.IR.Signature_Part_Array;
      Result     : Landin.IR.Signature_Part;
      Facts      : Landin.Targets.Target_Facts;
      Maximum : Landin.Targets.Byte_Count :=
        Landin.Targets.Byte_Count'Last;
      Fixed_Count : Natural := Natural'Last) return Plan;

   --  Lowering keeps the original fixed signature and promotes scalar tail
   --  actuals.  The logical aggregate destination is not a C argument.
   function Call_Plan
     (Of_Unit : Landin.IR.Unit;
      Item    : Landin.IR.Item_Id;
      Call    : Landin.IR.Value_Id;
      Facts   : Landin.Targets.Target_Facts;
      Maximum : Landin.Targets.Byte_Count :=
        Landin.Targets.Byte_Count'Last) return Plan;

   function Signature_Plan
     (Of_Unit   : Landin.IR.Unit;
      Signature : Landin.IR.Signature_Id;
      Facts     : Landin.Targets.Target_Facts;
      Maximum : Landin.Targets.Byte_Count :=
        Landin.Targets.Byte_Count'Last) return Plan;

end Landin.Backend.AAPCS64_ABI;
