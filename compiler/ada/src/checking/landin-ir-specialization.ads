with Landin.Build_Reports;
with Landin.Optimization;
with Landin.Targets;

package Landin.IR.Specialization is
   --  Whole-program static evidence devirtualization. Existing instance
   --  entries and their hidden ABI are retained; exposed/unknown entries
   --  retain the working indirect fallback. No new semantic instances.
   procedure Run
     (Into : in out Unit;
      Facts : Landin.Targets.Target_Facts;
      Options : Landin.Optimization.Options;
      Report : in out Landin.Build_Reports.Report);

   --  For the driver after lowering verified Into against these same Facts.
   --  No IR edit may intervene. Run remains the checked entry for callers
   --  without that guarantee; an enabled pass verifies its changed output.
   procedure Run_On_Verified
     (Into : in out Unit;
      Facts : Landin.Targets.Target_Facts;
      Options : Landin.Optimization.Options;
      Report : in out Landin.Build_Reports.Report);
end Landin.IR.Specialization;
