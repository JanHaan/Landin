--  Native Xtensa selection for the backend's 32-bit logical scratch words.
--  Logical words have fixed homes at a7 + 4*N; a8-a13 are transient physical
--  scratch. No logical instruction is stored in the emitted program.
with Ada.Strings.Unbounded;

package Landin.Backend.Xtensa_Machine is
   procedure Select_Word
     (Instruction : String;
      Into : in out Ada.Strings.Unbounded.Unbounded_String;
      Serial : in out Natural);
end Landin.Backend.Xtensa_Machine;
