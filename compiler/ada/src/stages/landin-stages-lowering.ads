--  The lowering stage.
--
--  It walks what the checker checked and builds Landin.IR from it.  The
--  frontend ends here: everything above this produces a diagnostic or does
--  not, and everything below it produces instructions.
--
--  It runs on nothing that was refused, and says so on its first line
--  rather than relying on Landin.Stages.Run stopping at the first refusal.
--  That is not belt and braces.  R1.70 assigns this stage no diagnostic
--  code at all -- `L0400`-`L0499` is deliberately unassigned -- and the
--  argument for that is that malformed IR cannot be caused by a source
--  program, because the frontend refused every ill-formed one first.  The
--  argument is only true while nothing lowers a refused program, and
--  nothing in `Landin.IR` enforces it; the pipeline's stop-at-a-refusal is
--  a property of the driver's ordering, one `Append` away from being
--  false.  So the stage states it itself, and the guarantee stops
--  depending on who calls it.
--
--  Two passes, and the first exists for a reason [1740] states.  A module
--  is a set, so `f` may call `g` written below it, and `Emit_Call`'s
--  `Holds (Into, Callee)` therefore needs `g`'s item to exist before `f`'s
--  body is walked.  Pass one creates every item, over every tree; pass two
--  fills them one at a time.  Filling them one at a time is also required
--  rather than tidy: an item's slots, blocks and instructions are runs in
--  four shared vectors, and `Landin.IR.Open_Run` refuses an interleaved
--  fill.
--
--  Scopes are asked for, never worked out.  `Landin.Resolution.Scope_At`
--  says which scope a node opened, and every `Add_Block` here passes what
--  it answered.  Landin.IR's header is the rule: "a scope tree here would
--  be a second authority on a question R1.50 answered once".

package Landin.Stages.Lowering is

   type Instance is limited new Landin.Stages.Stage with null record;

   overriding function Name (Item : Instance) return String;

   overriding procedure Run
     (Item    : Instance;
      Context : in out Compilation;
      Outcome : out Stage_Outcome);

end Landin.Stages.Lowering;
