--  Native Xtensa selection for the backend's 32-bit logical scratch words.
--  Logical words have fixed homes at a7 + 4*N. Assembly-free routines may
--  keep four scratch words in their window's a2-a5; a8-a13 are transient
--  scratch. No logical instruction is stored in the emitted program.
with Ada.Strings.Unbounded;

package Landin.Backend.Xtensa_Machine is
   procedure Select_Word
     (Instruction : String;
      Into : in out Ada.Strings.Unbounded.Unbounded_String;
      Serial : in out Natural;
      Frame_Bytes : Natural := 0;
      Scratch_Registers : Boolean := False);

   --  Shorten only local jumps proved in range by a conservative bound
   --  over a complete framed routine, retaining arbitrary-range fallback.
   procedure Compact_Jumps
     (Into : in out Ada.Strings.Unbounded.Unbounded_String;
      First : Positive);
end Landin.Backend.Xtensa_Machine;
