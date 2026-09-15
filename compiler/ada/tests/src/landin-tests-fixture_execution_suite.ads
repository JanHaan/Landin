with Landin.Testing;

package Landin.Tests.Fixture_Execution_Suite is
   --  Configures the one end-to-end fixture case registered for a focused
   --  developer run.  The ordinary complete suite never calls this.
   procedure Select_Fixture (Path : String);

   --  Host scope retains recorded diagnostics but omits native target
   --  workload emission and execution. The ordinary suite includes both.
   procedure Register
     (Into : in out Landin.Testing.Registry;
      Include_Target_Workloads : Boolean := True);
end Landin.Tests.Fixture_Execution_Suite;
