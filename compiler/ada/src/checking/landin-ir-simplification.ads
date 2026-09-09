with Landin.Optimization;
with Landin.Targets;

package Landin.IR.Simplification is
   --  Input and output are verified even when the objective disables edits.
   --  No floating reassociation, cross-block values, or unchecked assumptions.
   procedure Run
     (Into : in out Unit;
      Facts : Landin.Targets.Target_Facts;
      Objective : Landin.Optimization.Objective);
end Landin.IR.Simplification;
