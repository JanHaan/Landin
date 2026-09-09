--  Exhaustive conservative effects.  A possible trap is observable even
--  when the produced scalar is unused.  Unchecked grants no alias facts.
package Landin.IR.Effects is
   type Effect_Set is record
      Reads, Writes, Calls, Traps, Control, Adjacency : Boolean := False;
   end record;
   function Of_Code (Op : Opcode) return Effect_Set;
   function Weight (Op : Opcode) return Positive;
end Landin.IR.Effects;
