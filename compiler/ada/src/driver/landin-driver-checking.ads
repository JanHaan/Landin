--  The stages a request runs on what it loaded, in the one order there is.
--
--  Syntax, configuration, names, types and the lowering, then the panic
--  contract the entry module's handler must meet.  Each stage stops the
--  run on a refusal, so a file with a missing `then` does not also report
--  every name the hole swallowed.  `refine` and a server both check a
--  program here, so neither can check a program differently from the
--  other: what a server shows is what the build will say.

with Landin.Panics;
with Landin.Stages;

package Landin.Driver.Checking is

   --  Every stage on Context's sources, watched as each starts and ends.
   --  Panic is the handler plan the emission reads; it is meaningful only
   --  when Context has not failed.
   procedure Run
     (Context : in out Landin.Stages.Compilation;
      Panic   : out Landin.Panics.Plan;
      Watch   : not null access procedure
        (Name : String; Finished : Boolean));

   --  The same, unwatched, for a caller that measures nothing.
   procedure Run
     (Context : in out Landin.Stages.Compilation;
      Panic   : out Landin.Panics.Plan);

end Landin.Driver.Checking;
