with Landin.Optimization;
with Landin.Targets;

--  D94/D95 pass an `in` aggregate as the address of its caller's storage,
--  and the callee copies that storage into its own shaped parameter slot
--  before the body runs.  The copy is what keeps the parameter a value: a
--  write to the original during the call never reaches it.  D211 lets a
--  compiler drop the copy where that is unobservable, and this pass drops
--  it for a parameter that:
--
--  * the callee only reads: no store, clear, fill or variant selection
--    names it, no `addr` or slice is taken of it, and its storage address
--    goes nowhere but to a by-value argument of a call, directly or
--    through a slot lowering keeps it in across later arguments;
--  * nothing the callee does before its last read can write memory
--    outside the callee's own frame, which is the only memory the caller's
--    storage can be.  A store through an address or to a module datum, an
--    atomic access, an assembly block, an indirect call, a call to an
--    import, a call whose result lands outside the frame, and a direct call
--    to a routine that may do any of those, transitively, all could; the
--    last is decided once for the whole unit.  A call that passes the
--    parameter on reads it during the call, so it counts only when a read
--    follows it: the callee it reaches keeps its own copy unless its own
--    reads are as safe;
--  * and, when it is two words wide or narrower, is not read inside a
--    loop, where reading through a carrier kept in memory costs more than
--    the copy it saves.
--
--  Such a parameter's slot becomes an address slot holding the carrier,
--  and every reach of it goes through that address.  It keeps its
--  declaration, so a debugger describes it as before.  A fresh slot takes
--  its old shape as its home (In_Place_Home), so that D97's zero carrier
--  still has the callee clear its own storage and read that.  The caller
--  and the convention do not change.
--
--  First, a call is given a slice or `any` argument's own storage in place
--  of the fresh copy lowering makes of it, when nothing between that copy
--  and the call can write memory: the callee then copies, or reads in
--  place, the same bytes.
--
--  The work is linear: one walk of every routine for the summaries, a
--  worklist over the reversed direct-call edges, and one walk of each
--  routine with such a parameter.  `--optimize none` changes nothing.
package Landin.IR.In_Place is
   procedure Run
     (Into : in out Unit;
      Facts : Landin.Targets.Target_Facts;
      Objective : Landin.Optimization.Objective);

   --  For the driver after simplification verified Into against these same
   --  Facts.  An enabled pass verifies its changed output.
   procedure Run_On_Verified
     (Into : in out Unit;
      Facts : Landin.Targets.Target_Facts;
      Objective : Landin.Optimization.Objective);
end Landin.IR.In_Place;
