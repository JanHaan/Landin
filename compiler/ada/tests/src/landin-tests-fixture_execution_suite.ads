with Ada.Strings.Unbounded;

with Landin.Testing;

package Landin.Tests.Fixture_Execution_Suite is
   --  Configures the one end-to-end fixture case registered for a focused
   --  developer run.  The ordinary complete suite never calls this.
   procedure Select_Fixture (Path : String);

   --  What a focused run of fixture PATH says instead of running it when
   --  none of its `targets:` is this run's lane, and its `args` select no
   --  target of their own: that it does not apply here, and the command
   --  of each lane that does run it.  "" when the fixture applies, or when
   --  PATH selects no single well-formed fixture, which the run reports.
   function Lane_Note (Path : String) return String;

   --  The command that runs fixture LABEL on the lane of TARGET, a name
   --  `targets:` may hold.
   function Lane_Command (Label, Target : String) return String;

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
