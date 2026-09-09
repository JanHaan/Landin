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
end Landin.IR.Specialization;
