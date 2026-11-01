--  ARMv6-M base AAPCS and Landin transport planning, not emission.
--  Inputs are verified neutral signatures. Generic evidence is already in
--  their parameter run; only the aggregate result address is added here.
--
--  D616: a description with a float unit selects AAPCS32's VFP variant.
--  Its candidates, an f32 or f64 and, in the C convention, a homogeneous
--  aggregate of one to four of them, take the lowest free run of s0-s15,
--  a double an even-aligned pair, so a single back-fills a gap a double
--  left; once one goes to the stack no further VFP register is taken.
--  Results are s0/d0, s0-s3/d0-d3 for an aggregate.  Variadic calls keep
--  the base PCS, s16-s31 (d8-d15) are call-preserved, and core register
--  placement of everything else is unchanged.
with Landin.IR;
with Landin.Targets;
with Landin.Types;

package Landin.Backend.Arm32_ABI is

   type Convention is (External_C, Internal_Landin);
   type Extension is (No_Extension, Zero_Extend, Sign_Extend);

   type Classification is record
      Size      : Landin.Targets.Byte_Count := 0;
      Alignment : Landin.Targets.Byte_Alignment := 1;
      Composite : Boolean := False;
      Indirect  : Boolean := False;
      Extend    : Extension := No_Extension;
      --  D616: an f32 or f64, or a C aggregate of one to four of one of
      --  them, has its float type and member count here; anything else
      --  has none and zero, whatever bank the plan uses.
      Float_Base : Landin.Types.Type_Kind := Landin.Types.No_Value;
      Members    : Natural range 0 .. 4 := 0;
   end record;

   function Classify
     (Of_Unit : Landin.IR.Unit;
      Part    : Landin.IR.Signature_Part;
      Facts   : Landin.Targets.Target_Facts;
      ABI     : Convention) return Classification;

   --  D616: the VFP argument and result bank, s0-s15, counted in single
   --  slots, and the call-preserved rest of the register file.
   VFP_Slots : constant := 16;
   subtype VFP_Slot is Natural range 0 .. VFP_Slots;
   First_Preserved_VFP : constant := 16;
   Last_Preserved_VFP  : constant := 31;

   type Location is record
      Shape       : Classification;
      --  Zero-based r0..r3, with 4 meaning no core register.
      First_Core  : Natural range 0 .. 4 := 4;
      Core_Count  : Natural range 0 .. 4 := 0;
      --  The first single slot, s0..s15, with 16 meaning no VFP register,
      --  and how many single slots: a double at d<n> is 2n and two.
      First_VFP   : VFP_Slot := VFP_Slots;
      VFP_Count   : VFP_Slot := 0;
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
      --  D616: whether this plan uses the VFP bank.
      VFP         : Boolean := False;
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
   --  VFP selects D616's variant, which a variadic signature never uses.
   function Assign
     (Of_Unit    : Landin.IR.Unit;
      Parameters : Landin.IR.Signature_Part_Array;
      Results    : Landin.IR.Signature_Part_Array;
      Facts      : Landin.Targets.Target_Facts;
      ABI        : Convention;
      Has_Error  : Boolean := False;
      Maximum    : Landin.Targets.Byte_Count := 16#FFFF_FFFF#;
      Fixed_Count : Natural := Natural'Last;
      VFP        : Boolean := False) return Plan;

   --  D616: whether the unit's selected description has a float unit,
   --  which every call and signature plan of it then uses.
   function Uses_VFP (Of_Unit : Landin.IR.Unit) return Boolean;

   --  A location's VFP registers as assembly names them: s<n> for a
   --  single, d<n> for each double of a double candidate.
   function VFP_Register
     (Item : Location; Index : Positive) return String
     with Pre => Item.VFP_Count > 0;

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
