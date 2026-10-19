with Landin.IR.If_Conversion;
with Landin.IR.In_Place;
with Landin.IR.Inlining;
with Landin.IR.Simplification;
with Landin.IR.Specialization;

package body Landin.IR.Pipeline is

   procedure Run_On_Verified
     (Into    : in out Unit;
      Facts   : Landin.Targets.Target_Facts;
      Options : Landin.Optimization.Options;
      Report  : in out Landin.Build_Reports.Report) is
   begin
      Landin.IR.Specialization.Run_On_Verified
        (Into, Facts, Options, Report);
      Landin.IR.Inlining.Run_On_Verified (Into, Facts, Options.Optimize);
      Landin.IR.Simplification.Run_On_Verified
        (Into, Facts, Options.Optimize);
      Landin.IR.If_Conversion.Run_On_Verified
        (Into, Facts, Options.Optimize);
      Landin.IR.In_Place.Run_On_Verified (Into, Facts, Options.Optimize);
   end Run_On_Verified;

end Landin.IR.Pipeline;
