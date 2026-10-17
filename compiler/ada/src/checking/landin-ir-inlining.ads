with Landin.Optimization;
with Landin.Targets;

--  D339: at `--optimize speed`, a direct call to a small routine is
--  replaced by a copy of that routine's body, so that simplification can
--  fold the arguments the caller already knows and the call's own work --
--  saving registers, moving arguments, the frame -- is not done at all.
--
--  A call is copied when the routine it names:
--
--  * has a body here and nothing takes its address: no function value,
--    image or evidence table names it and it is not an entry, an import or
--    an export (D211), so the body stays, whatever is copied;
--  * is not the routine making the call, uses the ordinary convention and
--    Landin's own transport, returns, is not variadic, carries one scalar
--    result or none, has no placement and no assembly block;
--  * weighs at most Body_Bound of Landin.IR.Effects' weighted operations
--    as lowering made it.
--
--  and the call itself can be replaced exactly.  Every argument is already
--  evaluated where the call stands, so the copy stores each one into the
--  copy of its parameter -- by-value aggregates are copied, or cleared for
--  D97's zero carrier, as the routine's own entry would have done, unless
--  the routine only reads one and nothing can write the caller's storage
--  while the copy runs, and then the copy reads it there -- and jumps to the
--  copy of the routine's first block.  A parameter given a constant is read
--  as that constant, which is what simplification then folds.  Each
--  `return` jumps back to the rest of the caller's block, whose values that
--  crossed the call travel through slots, or are made again when they are
--  constants.
--  A routine that can fail is copied only where its call is lowering's
--  failure test and nothing else reads the call's status: each `fail`
--  stores its atom and jumps to the test's failing block, and each return
--  to its other block, which is what the test would have chosen.  Every
--  trap is the copied operation's own, with its own site, in the order the
--  routine ran them; cleanup is the routine's own code and runs where it
--  did.  The copies' own calls are not copied again: one level.
--
--  A caller grows by at most the larger of Growth_Floor and its own weight,
--  calls inside loops first, so no routine more than doubles and the work
--  stays linear in the program.  Cortex-M0 is left alone: its backend does
--  not read the objective and its debugger contract has no inlined frames.
--  Each copied block, slot and alias records where it came from
--  (Landin.IR.Inline_Site), which is what source debugging describes.
package Landin.IR.Inlining is

   Body_Bound : constant := 64;

   Growth_Floor : constant := 512;

   procedure Run
     (Into : in out Unit;
      Facts : Landin.Targets.Target_Facts;
      Objective : Landin.Optimization.Objective);

   --  For the driver after specialization verified Into against these same
   --  Facts.  An enabled pass verifies its changed output.
   procedure Run_On_Verified
     (Into : in out Unit;
      Facts : Landin.Targets.Target_Facts;
      Objective : Landin.Optimization.Objective);
end Landin.IR.Inlining;
