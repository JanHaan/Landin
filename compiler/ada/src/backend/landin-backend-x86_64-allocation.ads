--  Deterministic physical locations for the verified block-local value model.
--  Five otherwise-unused SysV callee-save GP registers and, for call-free
--  speed routines, eight XMM registers are allocated.  Scratch, argument and
--  failure registers remain owned by selection.
with Ada.Containers.Vectors;
with Landin.Optimization;

package Landin.Backend.X86_64.Allocation is

   subtype Width is Landin.Targets.Scalar_Size
     range Landin.Targets.Byte_1 .. Landin.Targets.Byte_8;
   type Register_Id is (No_Register, RBX, R12, R13, R14, R15);
   subtype Saved_Register is Register_Id range RBX .. R15;
   type SSE_Register is (XMM8, XMM9, XMM10, XMM11, XMM12, XMM13, XMM14,
                         XMM15);
   type Location_Kind is (Absent, Stack, GP, SSE);
   type Location is record
      Kind : Location_Kind := Absent;
      Size : Width := Landin.Targets.Byte_8;
      Register : Register_Id := No_Register;
      Float_Register : SSE_Register := XMM8;
      Home : Natural := 0;
      Address_Required : Boolean := False;
   end record;
   package Location_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Location);
   subtype Locations is Location_Vectors.Vector;
   type Register_Set is array (Saved_Register) of Boolean;
   type SSE_Register_Set is array (SSE_Register) of Boolean;
   --  Plans own heap-backed locations, including the reference plan.  Their
   --  retained size must not become an automatic host-stack allocation.
   type Plan (Slots, Values : Natural) is record
      Slot : Location_Vectors.Vector;
      Value : Location_Vectors.Vector;
      Used : Register_Set := [others => False];
      Used_SSE : SSE_Register_Set := [others => False];
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
      Options : Landin.Optimization.Options;
      Maximum : Landin.Targets.Byte_Count :=
        Landin.Targets.Byte_Count'Last) return Frame;

   function Name (Register : Saved_Register; Size : Width) return String;
   function Name (Register : SSE_Register) return String;
   function Save_Count (Of_Plan : Plan) return Natural;
   function SSE_Count (Of_Plan : Plan) return Natural;
   function Save_Index
     (Of_Plan : Plan; Register : Saved_Register) return Positive;

end Landin.Backend.X86_64.Allocation;
