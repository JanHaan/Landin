--  The optimization passes `refine compile` runs over a verified unit, in
--  the order it runs them.  The driver calls this and nothing else between
--  lowering and emission, and a test that inspects emitted code calls it
--  too, so what the test sees is what the command line emits: the slots,
--  their use counts and the checks that remain are the pipeline's, never
--  those of a unit no pass has simplified.

with Landin.Build_Reports;
with Landin.Optimization;
with Landin.Targets;

package Landin.IR.Pipeline is

   --  Specialization, inlining, scalar replacement with simplification,
   --  if-conversion and in-place parameter reads, each verifying its
   --  output.  Report receives specialization's evidence.
   procedure Run_On_Verified
     (Into    : in out Unit;
      Facts   : Landin.Targets.Target_Facts;
      Options : Landin.Optimization.Options;
      Report  : in out Landin.Build_Reports.Report);

end Landin.IR.Pipeline;
