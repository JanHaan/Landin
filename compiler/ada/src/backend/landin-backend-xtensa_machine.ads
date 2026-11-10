--  Native Xtensa selection for the backend's 32-bit logical scratch words.
--  Opaque assembly retains homes at a7 + 4*N. Assembly-free routines may
--  keep five scratch words in their window's a2-a6; a8-a13 are transient
--  scratch. No logical instruction is stored in the emitted program.
with Ada.Strings.Unbounded;

package Landin.Backend.Xtensa_Machine is
   --  Compact homes exclude zero, SP, the derived immutable CFA and
   --  register-held scratch words; unused x26 also has no home.
   --  Any other omitted logical word is refused rather than aliased.
   function Word_Offset (Word : Natural; Compact : Boolean)
      return Landin.Targets.Byte_Count;

   procedure Select_Word
     (Instruction : String;
      Into : in out Ada.Strings.Unbounded.Unbounded_String;
      Serial : in out Natural;
      Frame_Bytes : Landin.Targets.Byte_Count := 0;
      Scratch_Registers : Boolean := False);

   --  Shorten only local jumps proved in range by a conservative bound
   --  over a complete framed routine, retaining arbitrary-range fallback.
   procedure Compact_Jumps
     (Into : in out Ada.Strings.Unbounded.Unbounded_String;
      First : Positive);
end Landin.Backend.Xtensa_Machine;
