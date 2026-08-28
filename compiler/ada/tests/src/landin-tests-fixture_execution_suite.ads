with Landin.Testing;

package Landin.Tests.Fixture_Execution_Suite is
   --  Configures the one end-to-end fixture case registered for a focused
   --  developer run.  The ordinary complete suite never calls this.
   procedure Select_Fixture (Path : String);

   procedure Register (Into : in out Landin.Testing.Registry);
end Landin.Tests.Fixture_Execution_Suite;
