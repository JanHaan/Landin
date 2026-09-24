--  ARMv6-M base AAPCS and Landin transport planning, not emission.
--  Inputs are verified neutral signatures. Generic evidence is already in
--  their parameter run; only the aggregate result address is added here.
with Landin.IR;
with Landin.Targets;

package Landin.Backend.Arm32_ABI is

   type Convention is (External_C, Internal_Landin);
   type Extension is (No_Extension, Zero_Extend, Sign_Extend);

   type Classification is record
      Size      : Landin.Targets.Byte_Count := 0;
      Alignment : Landin.Targets.Byte_Alignment := 1;
      Composite : Boolean := False;
      Indirect  : Boolean := False;
      Extend    : Extension := No_Extension;
   end record;

   function Classify
     (Of_Unit : Landin.IR.Unit;
      Part    : Landin.IR.Signature_Part;
      Facts   : Landin.Targets.Target_Facts;
      ABI     : Convention) return Classification;

   type Location is record
      Shape       : Classification;
      --  Zero-based r0..r3, with 4 meaning no core register.
      First_Core  : Natural range 0 .. 4 := 4;
      Core_Count  : Natural range 0 .. 4 := 0;
      --  A split composite's stack suffix begins after Core_Count words
      --  in its object. Stack_At is relative to sp at the call boundary.
      Stack_At    : Landin.Targets.Byte_Count := 0;
      Stack_Bytes : Landin.Targets.Byte_Count := 0;
   end record;
   type Location_Array is array (Positive range <>) of Location;

   type Plan (Count : Natural) is record
      Result      : Location;
      Arguments   : Location_Array (1 .. Count);
      Core_Used   : Natural range 0 .. 4 := 0;
      Stack_Bytes : Landin.Targets.Byte_Count := 0;
      --  Landin uses r12 for zero-success/nonzero dense atom errors.
      --  It is independent of r0/r1 and is never an AAPCS C result.
      Has_Error   : Boolean := False;
   end record;

   Error_Register        : constant := 12;
   Frame_Register        : constant := 11;
   Frame_Record_Bytes    : constant := 8;
   Call_Stack_Alignment  : constant := 8;
   Minimum_SP_Alignment  : constant := 4;
   Thumb_Address_Bit     : constant := 1;

   --  C varargs use the same base PCS; callers must first apply C default
   --  promotions. Fixed_Count identifies the boundary and validates tails.
   --  Native multiple results form one natural-layout caller-owned object.
   --  Maximum bounds outgoing stack bytes, not a claim of physical RAM.
   function Assign
     (Of_Unit    : Landin.IR.Unit;
      Parameters : Landin.IR.Signature_Part_Array;
      Results    : Landin.IR.Signature_Part_Array;
      Facts      : Landin.Targets.Target_Facts;
      ABI        : Convention;
      Has_Error  : Boolean := False;
      Maximum    : Landin.Targets.Byte_Count := 16#FFFF_FFFF#;
      Fixed_Count : Natural := Natural'Last) return Plan;

   --  The call adapter removes neutral destination/callee operands and
   --  classifies promoted C tail actuals; direct and indirect calls agree.
   function Call_Plan
     (Of_Unit : Landin.IR.Unit;
      Item    : Landin.IR.Item_Id;
      Call    : Landin.IR.Value_Id;
      Facts   : Landin.Targets.Target_Facts;
      Maximum : Landin.Targets.Byte_Count := 16#FFFF_FFFF#) return Plan;

   function Signature_Plan
     (Of_Unit   : Landin.IR.Unit;
      Signature : Landin.IR.Signature_Id;
      Facts     : Landin.Targets.Target_Facts;
      Maximum   : Landin.Targets.Byte_Count := 16#FFFF_FFFF#) return Plan;

end Landin.Backend.Arm32_ABI;
