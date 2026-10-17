with Landin.Optimization;
with Landin.Targets;

--  Scalar replacement of small aggregates.  A slice or a small record of
--  scalars held in a slot otherwise travels through storage: every field
--  read is a load from the slot, every whole assignment a block copy, and
--  neither forwarding nor register allocation sees a field.  This pass
--  gives each part of such a slot a scalar slot of its own, so the parts
--  are ordinary scalars to every later stage.
--
--  A local slot whose every use names a part or copies or clears it whole
--  is split: part reads and writes become scalar loads and stores, a whole
--  copy one load and store per part, a clear one store of zero per part.
--  An address taken, a partial copy, a nested path or any other use keeps
--  the slot whole, and so does its being a routine's result.  A parameter
--  the routine never writes stays whole as its caller's copy arrived; at
--  speed, each part a loop reads is copied out of it once on entry, where
--  a register can hold it, and every read of that part becomes a load of
--  the copy.  Only parts without packing or atom codes are moved, whose
--  loads carry no check, so no trap moves or disappears.
--
--  At size a declared variable keeps its frame cell for the debugger, so
--  only compiler temporaries are split there, and no parameter is copied:
--  a copy pays for itself only in a register.  A split declared variable
--  records its pieces (Landin.IR.First_Piece), which is how its debugger
--  location is described.
--
--  Simplification runs this pass first, so the parts it moves meet
--  forwarding, folding and the proofs of checks as scalars, and verifies
--  the two passes' output together: one walk of the unit, not two.
--
--  Linear in instructions plus slots plus blocks: one scan classifies
--  every slot's uses, one strongly connected component walk finds the
--  blocks on a loop, and one rebuild copies each instruction once and adds
--  at most one load and one store per moved part.
package Landin.IR.Scalar_Replacement is
   --  Input is verified, even when the objective disables edits, and so
   --  is the output.  For callers other than simplification.
   procedure Run
     (Into : in out Unit;
      Facts : Landin.Targets.Target_Facts;
      Objective : Landin.Optimization.Objective);

   --  For Landin.IR.Simplification on a unit verified against the facts it
   --  is given.  Its output is not verified here: simplification verifies
   --  its own output, which this pass's edits are part of.
   procedure Replace
     (Into : in out Unit;
      Objective : Landin.Optimization.Objective);
end Landin.IR.Scalar_Replacement;
