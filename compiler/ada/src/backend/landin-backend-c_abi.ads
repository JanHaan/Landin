--  System V AMD64's native C boundary, derived only from target facts and
--  neutral IR shapes.  Classification and register exhaustion are one plan
--  shared by calls, routine entry and results; no placement is stored in IR.
with Landin.IR;
with Landin.Targets;

package Landin.Backend.C_ABI is

   type Eightbyte_Class is (No_Class, Integer_Class, SSE_Class);
   type Class_Run is array (Positive range 1 .. 2) of Eightbyte_Class;
   type Register_Run is array (Positive range 1 .. 2) of Natural;

   type Classification is record
      Size      : Landin.Targets.Byte_Count := 0;
      Alignment : Landin.Targets.Byte_Alignment := 1;
      Aggregate : Boolean := False;
      Memory    : Boolean := False;
      Count     : Natural range 0 .. 2 := 0;
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
      --  One-based within each independent bank.  Results use the same
      --  indices, with two GP and two SSE registers instead of six/eight.
      Registers : Register_Run := [others => 0];
   end record;
   type Location_Array is array (Positive range <>) of Location;

   type Plan (Count : Natural) is record
      Result      : Location;
      Arguments   : Location_Array (1 .. Count);
      GP_Used     : Natural range 0 .. 6 := 0;
      SSE_Used    : Natural range 0 .. 8 := 0;
      Stack_Bytes : Landin.Targets.Byte_Count := 0;
   end record;

   function Assign
     (Of_Unit    : Landin.IR.Unit;
      Parameters : Landin.IR.Signature_Part_Array;
      Result     : Landin.IR.Signature_Part;
      Facts      : Landin.Targets.Target_Facts) return Plan;

   --  Lowering keeps the original fixed signature and promotes scalar tail
   --  actuals.  The logical aggregate destination is not a C argument.
   function Call_Plan
     (Of_Unit : Landin.IR.Unit;
      Item    : Landin.IR.Item_Id;
      Call    : Landin.IR.Value_Id;
      Facts   : Landin.Targets.Target_Facts) return Plan;

   function Signature_Plan
     (Of_Unit   : Landin.IR.Unit;
      Signature : Landin.IR.Signature_Id;
      Facts     : Landin.Targets.Target_Facts) return Plan;

end Landin.Backend.C_ABI;
