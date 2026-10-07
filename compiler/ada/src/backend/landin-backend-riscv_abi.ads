--  Explicit RV64 Linux LP64D C transport. Target facts supply physical
--  layout, not the choice of convention: calling this package is that
--  choice. Placements never enter target-neutral IR.
with Landin.IR;
with Landin.Targets;
with Landin.Types;

package Landin.Backend.RiscV_ABI is

   type Carrier_Class is (Integer_Class, Float_Class);
   type Carrier is record
      Class : Carrier_Class := Integer_Class;
      Offset : Landin.Targets.Byte_Count := 0;
      Bytes : Landin.Targets.Byte_Count := 0;
      Scalar : Landin.Types.Type_Kind := Landin.Types.No_Value;
   end record;
   type Carrier_Array is array (Positive range 1 .. 2) of Carrier;
   type Classification is record
      Size : Landin.Targets.Byte_Count := 0;
      Alignment : Landin.Targets.Byte_Alignment := 1;
      Aggregate : Boolean := False;
      Indirect : Boolean := False;
      Count : Natural range 0 .. 2 := 0;
      Parts : Carrier_Array;
   end record;

   function Classify
     (Of_Unit : Landin.IR.Unit; Part : Landin.IR.Signature_Part;
      Facts : Landin.Targets.Target_Facts;
      Floating : Boolean := True) return Classification;

   type Carrier_Location is record
      --  One-based a0..a7 or fa0..fa7; zero means a stack carrier.
      Register : Natural range 0 .. 8 := 0;
      Stack_At : Landin.Targets.Byte_Count := 0;
   end record;
   type Carrier_Locations is array (Positive range 1 .. 2)
     of Carrier_Location;
   type Location is record
      Shape : Classification;
      Parts : Carrier_Locations;
   end record;
   type Location_Array is array (Positive range <>) of Location;
   type Plan (Count : Natural) is record
      Result : Location;
      Arguments : Location_Array (1 .. Count);
      GP_Used, FP_Used : Natural range 0 .. 8 := 0;
      Stack_Bytes : Landin.Targets.Byte_Count := 0;
   end record;

   function Assign
     (Of_Unit : Landin.IR.Unit;
      Parameters : Landin.IR.Signature_Part_Array;
      Result : Landin.IR.Signature_Part;
      Facts : Landin.Targets.Target_Facts;
      Maximum : Landin.Targets.Byte_Count :=
        Landin.Targets.Byte_Count'Last;
      Fixed_Count : Natural := Natural'Last) return Plan;

   function Call_Plan
     (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id;
      Call : Landin.IR.Value_Id; Facts : Landin.Targets.Target_Facts;
      Maximum : Landin.Targets.Byte_Count :=
        Landin.Targets.Byte_Count'Last) return Plan;
   function Signature_Plan
     (Of_Unit : Landin.IR.Unit; Signature : Landin.IR.Signature_Id;
      Facts : Landin.Targets.Target_Facts;
      Maximum : Landin.Targets.Byte_Count :=
        Landin.Targets.Byte_Count'Last) return Plan;

end Landin.Backend.RiscV_ABI;
