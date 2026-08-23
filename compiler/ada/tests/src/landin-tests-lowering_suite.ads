with Landin.Testing;

package Landin.Tests.Lowering_Suite is

   procedure Register (Into : in out Landin.Testing.Registry);

   --  Writes `compiler/tests/lowering.ir` from the corpus as it is now,
   --  and runs no case at all.  Two disjoint modes in one binary, chosen
   --  only by an argument a human typed: recording must never be able to
   --  be mistaken for passing, and a golden that rewrites itself on a
   --  mismatch records the defect instead of reporting it.
   procedure Record_Artefact (Path : String; Wrote : out Boolean);

end Landin.Tests.Lowering_Suite;
