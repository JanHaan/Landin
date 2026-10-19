with Ada.Strings.Unbounded;

with Landin.Testing;

package Landin.Tests.Fixture_Execution_Suite is
   --  Configures the one end-to-end fixture case registered for a focused
   --  developer run.  The ordinary complete suite never calls this.
   procedure Select_Fixture (Path : String);

   --  Rewrite one recorded fixture's `expect` file, CLASS/NAME as
   --  --fixture names it, with what refine reports for it now.  Nothing
   --  is written unless the fixture is one with an `expect`, refine ran
   --  and its status and ordered codes are still the ones the metadata
   --  pins: a recording replaces the bytes, never the verdict.  Said is
   --  what happened, for the person who asked.
   procedure Record_Report
     (Path  : String;
      Wrote : out Boolean;
      Said  : out Ada.Strings.Unbounded.Unbounded_String);

   --  Host scope retains recorded diagnostics but omits native target
   --  workload emission and execution. The ordinary suite includes both.
   procedure Register
     (Into : in out Landin.Testing.Registry;
      Include_Target_Workloads : Boolean := True);
end Landin.Tests.Fixture_Execution_Suite;
