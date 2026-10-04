with Landin.Optimization;
with Landin.Targets;

package Landin.IR.Simplification is
   --  Input is verified even when the objective disables edits.
   --  No floating reassociation, cross-block values, or unchecked assumptions.
   procedure Run
     (Into : in out Unit;
      Facts : Landin.Targets.Target_Facts;
      Objective : Landin.Optimization.Objective);

   --  For the driver after lowering or specialization verified Into against
   --  these same Facts. No IR edit may intervene. An enabled pass verifies
   --  its changed output; Run checks independently supplied input.
   procedure Run_On_Verified
     (Into : in out Unit;
      Facts : Landin.Targets.Target_Facts;
      Objective : Landin.Optimization.Objective);
end Landin.IR.Simplification;
