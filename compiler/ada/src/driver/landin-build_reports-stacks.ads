with Landin.Optimization;
with Landin.Panics;
with Landin.Stages;

--  D447's stack-depth report (D467, D468): for every routine the emitted
--  program has, its own frame on the target, the deepest stack of the
--  call graph below it that the compiler can close, and every place that
--  graph is opened instead: a call through a function value, through
--  `any` or through a generic's table, recursion, a foreign call, a
--  runtime helper, or assembly that may move the stack pointer.  Frames
--  are the backends' own figures (Routine_Statistics.Stack_Bytes); the
--  graph is read from the unit the backend was given, so the depths are
--  target-independent arithmetic over target facts.  Pure computation:
--  no paths beyond the module-relative names D361 uses, no clocks.
package Landin.Build_Reports.Stacks is

   function JSON
     (Of_Report    : Report;
      Context      : in out Landin.Stages.Compilation;
      Options      : Landin.Optimization.Options;
      Panic        : Landin.Panics.Plan;
      Hosted_Entry : Landin.IR.Item_Id) return String;

end Landin.Build_Reports.Stacks;
