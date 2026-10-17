with Landin.Optimization;
with Landin.Targets;

--  D338's if-conversion.  A block that ends in a branch whose two arms
--  rejoin, each arm one block with nothing but a jump after it or no
--  block at all, branches only to choose which values some private slots
--  end up holding.  When neither arm can trap, call, read or write
--  anything but such a slot, or do anything else a program could tell
--  apart from not doing it, the block computes both arms itself, chooses
--  each slot's value with Choose, stores it and jumps to where the arms
--  met.  That is what D211 lets a compiler do: no trap, effect or order
--  changes, so nothing observable does.
--
--  A private slot is a scalar that nothing names but its own loads and
--  stores: no address, assembly output, aggregate operation, pointer,
--  function or atom metadata reaches it.  An arm may load one, store
--  one, and compute from what it loaded with operations that cannot
--  trap: constants, comparisons, bitwise and wrapping arithmetic, float
--  arithmetic, a conversion that is total, and an operation whose check
--  was proved or lies in an `unchecked` region.
--
--  One trapping operation is admitted, because converting it moves no
--  trap: a checked integer addition or subtraction that updates a slot
--  from the slot's own earlier value, `x = x + k` or `x = x - k`, in an
--  arm whose other side leaves the slot alone.  It becomes
--  `x + (if c then k else 0)`, which traps exactly when the arm would
--  have, at the same place in the program's order: nothing between the
--  branch and the arm, or the arm and its end, can trap or be observed.
--  Counting the elements a condition holds for, as C's `n += a < b`
--  does, is the case that asks for it.  An update that cannot trap, a
--  wrapping one or one whose check was proved, takes the same form, which
--  arm64 makes one conditional increment.
--
--  A branch whose condition the head block computes from a slot an arm
--  stores stays a branch: in a loop, each choice would wait for the
--  comparison, which waits for the choice before it, where a predicted
--  branch waits for neither.
--
--  Each arm is held to six operations other than constants, loads and
--  stores, and the pair to four slots chosen, so both arms together cost
--  about what a mispredicted branch does.  The work is one walk of each
--  routine for the facts and one for the rebuild, after which nothing
--  reaches the arms' blocks and Rewriting.Compact drops them, so it is
--  linear in the routine.  `--optimize none` converts nothing.
package Landin.IR.If_Conversion is
   procedure Run
     (Into : in out Unit;
      Facts : Landin.Targets.Target_Facts;
      Objective : Landin.Optimization.Objective);

   --  For the driver after simplification verified Into against these
   --  same Facts.  A pass that changes anything verifies its output.
   procedure Run_On_Verified
     (Into : in out Unit;
      Facts : Landin.Targets.Target_Facts;
      Objective : Landin.Optimization.Objective);
end Landin.IR.If_Conversion;
