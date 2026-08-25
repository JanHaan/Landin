with Landin.Testing;

package Landin.Tests.Targets_Suite is
   procedure Register (Into : in out Landin.Testing.Registry);

   --  Writes `compiler/tests/layout.targets` from the target model as it
   --  is now, and runs no case.  The same two disjoint modes the lowering
   --  corpus keeps, for the same reason: a golden that rewrites itself on
   --  a mismatch records a defect instead of reporting one.
   procedure Record_Artefact (Path : String; Wrote : out Boolean);
end Landin.Tests.Targets_Suite;
