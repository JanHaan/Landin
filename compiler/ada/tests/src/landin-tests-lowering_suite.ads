with Ada.Strings.Unbounded;

with Landin.Testing;

package Landin.Tests.Lowering_Suite is

   procedure Register (Into : in out Landin.Testing.Registry);

   --  Writes `compiler/tests/lowering.ir` from the corpus as it is now,
   --  and runs no case at all.  Two disjoint modes in one binary, chosen
   --  only by an argument a human typed: recording must never be able to
   --  be mistaken for passing, and a golden that rewrites itself on a
   --  mismatch records the defect instead of reporting it.
   --
   --  When Wrote is False, Said is why: each problem that kept the corpus
   --  from lowering completely, as `lowering/the recorded corpus is
   --  current` reports them, or that the file could not be written.
   procedure Record_Artefact
     (Path  : String;
      Wrote : out Boolean;
      Said  : out Ada.Strings.Unbounded.Unbounded_String);

end Landin.Tests.Lowering_Suite;
