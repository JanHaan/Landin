--  Deterministic physical locations for the verified block-local value model
--  and for slots over their live intervals.  Five otherwise-unused SysV
--  callee-save GP registers, four caller-saved ones for values and, at
--  speed, eight XMM registers are allocated.  SysV saves no XMM register
--  across a call, so no XMM interval spans one.  Scratch, argument and
--  failure registers remain owned by selection.
with Ada.Containers.Vectors;
with Landin.Optimization;

package Landin.Backend.X86_64.Allocation is

   subtype Width is Landin.Targets.Scalar_Size
     range Landin.Targets.Byte_1 .. Landin.Targets.Byte_8;
   type Register_Id is (No_Register, RBX, R12, R13, R14, R15, RSI, RDI,
                        R8, R9);
   subtype General_Register is Register_Id range RBX .. R9;
   subtype Saved_Register is Register_Id range RBX .. R15;
   --  Four caller-saved registers selection touches only in the
   --  operations Untouched names in the body: a value may hold one only
   --  where none of those lies in its interval.  No slot holds one.
   subtype Caller_Saved is Register_Id range RSI .. R9;
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
      --  A slot may hold a register only over its live interval, in the
      --  order the routine's blocks are laid out: from the value From
      --  through the value Through, or from the entry when From is
      --  No_Value.  Outside it the register is another location's and the
      --  slot has no home.  Both stay No_Value for a slot whose location
      --  holds everywhere.
      From, Through : Landin.IR.Value_Id := Landin.IR.No_Value;
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

   --  The plan emission consumes; preflight asks for it only when the
   --  reference frame alone cannot show a frame addressable.
   function Frame_For
     (Of_Unit : Landin.IR.Unit;
      Item : Landin.IR.Item_Id;
      Facts : Landin.Targets.Target_Facts;
      Of_Plan : Plan;
      Options : Landin.Optimization.Options;
      Maximum : Landin.Targets.Byte_Count :=
        Landin.Targets.Byte_Count'Last) return Frame;

   --  An integer constant as the immediate operand selection writes for
   --  it: its two's complement pattern at its own width, read as signed,
   --  when that fits the sign-extended imm32 an instruction carries, and
   --  otherwise "".  A float constant has none.  Size and speed leave a
   --  constant with no location when every use of it is a right operand
   --  of add, subtract, a bitwise operator or a multiply selection does
   --  with `imul`, a constant shift amount, or the value a store to a
   --  slot, field, element, datum or address writes: selection writes
   --  the immediate at each of those.
   function Immediate
     (Of_Unit : Landin.IR.Unit;
      Item : Landin.IR.Item_Id;
      Value : Landin.IR.Value_Id;
      Facts : Landin.Targets.Target_Facts) return String;

   function Name (Register : General_Register; Size : Width) return String;
   function Name (Register : SSE_Register) return String;
   function Save_Count (Of_Plan : Plan) return Natural;
   function SSE_Count (Of_Plan : Plan) return Natural;
   function Save_Index
     (Of_Plan : Plan; Register : Saved_Register) return Positive;

end Landin.Backend.X86_64.Allocation;
