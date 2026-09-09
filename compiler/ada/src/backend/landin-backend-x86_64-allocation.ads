--  Deterministic physical locations for the verified block-local value model.
--  Only the five otherwise-unused SysV callee-save GP registers are allocated.
--  Scratch, argument, failure and SSE registers remain owned by selection.
with Ada.Containers.Vectors;
with Landin.Optimization;

package Landin.Backend.X86_64.Allocation is

   subtype Width is Landin.Targets.Scalar_Size
     range Landin.Targets.Byte_1 .. Landin.Targets.Byte_8;
   type Register_Id is (No_Register, RBX, R12, R13, R14, R15);
   subtype Saved_Register is Register_Id range RBX .. R15;
   type Location_Kind is (Absent, Stack, GP);
   type Location is record
      Kind : Location_Kind := Absent;
      Size : Width := Landin.Targets.Byte_8;
      Register : Register_Id := No_Register;
      Home : Natural := 0;
      Address_Required : Boolean := False;
   end record;
   package Location_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Location);
   subtype Locations is Location_Vectors.Vector;
   type Register_Set is array (Saved_Register) of Boolean;
   --  Plans own heap-backed locations, including the reference plan.  Their
   --  retained size must not become an automatic host-stack allocation.
   type Plan (Slots, Values : Natural) is record
      Slot : Location_Vectors.Vector;
      Value : Location_Vectors.Vector;
      Used : Register_Set := [others => False];
      Spill_Homes : Natural := 0;
   end record;

   function Make
     (Of_Unit : Landin.IR.Unit;
      Item : Landin.IR.Item_Id;
      Facts : Landin.Targets.Target_Facts;
      Options : Landin.Optimization.Options) return Plan;

   --  The same allocation/storage plan is consumed by preflight and emission.
   function Frame_For
     (Of_Unit : Landin.IR.Unit;
      Item : Landin.IR.Item_Id;
      Facts : Landin.Targets.Target_Facts;
      Of_Plan : Plan;
      Options : Landin.Optimization.Options) return Frame;

   function Name (Register : Saved_Register; Size : Width) return String;
   function Save_Count (Of_Plan : Plan) return Natural;
   function Save_Index
     (Of_Plan : Plan; Register : Saved_Register) return Positive;

end Landin.Backend.X86_64.Allocation;
