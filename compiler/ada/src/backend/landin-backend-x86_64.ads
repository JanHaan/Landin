--  Linux x86-64 assembly for a verified unit.
--
--  Text, not objects.  `tour.md` [1550] says Landin keeps its own native
--  backends and emits assembly for platform assembler and linker tooling,
--  so what this produces is what an assembler is handed and not an ELF
--  file this compiler wrote.  The syntax is GNU as's AT&T form, source
--  before destination, because that is what the tool named by
--  `Landin.Platform`'s runner accepts without a switch.
--
--  Every value is computed in the accumulator and stored to its frame
--  cell, and every operand is loaded back from one.  `Landin.Backend`'s
--  header argues that shape and states its cost; the consequence here is
--  that instruction selection never has to ask which register holds
--  what, and that the text is a function of the IR alone.  Deterministic
--  is a requirement and not a nicety: R1.80's exit evidence asks for
--  deterministic assembly, and nothing below reads a clock, a hash order
--  or an address.
--
--  Ordinary add, subtract and multiply each test signed overflow or unsigned
--  carry/borrow at the operation and reach an explicit `ud2` before storing
--  a result; their wrapping forms ignore those flags and store the low-width
--  result immediately.  Multiply uses x86-64's one-operand form so its
--  implicit high half makes unsigned overflow observable too.  Divide and
--  remainder guard a zero divisor before their one-operand instruction;
--  signed division explicitly traps the minimum over minus one, while signed
--  remainder produces that pair's specified zero without executing `idiv`.
--  Unary minus is checked the same way, because [1890] gives it its own
--  integer type back: `neg` reports the lowest signed value as overflow and
--  every nonzero unsigned value as carry.  [0330]'s `~`, `&`, `^` and `|`
--  cannot leave their own type and so carry no edge at all, and [0340]'s
--  `not` flips the low bit alone rather than the byte, because [1870] fixes
--  a bool at zero or one.
--  Comparisons load their left operand, compare the right at that operand's
--  width, and materialize a one-byte bool with the signed or unsigned
--  condition [1890] requires.  A shift carries the two rules the hardware
--  does not give: the amount is tested against the type's own width, because
--  [0320] and D13 fill with zeros beyond it while x86-64 would mask the
--  count, and a signed amount is tested for being negative, because [1950]
--  leaves the ones the compiler could not read to the trap.  A call fills
--  [1650]'s six argument registers from its operands in order, each at its
--  own parameter's width, and takes the result from the accumulator into a
--  frame cell; a callee returning none leaves nothing to take.  The frame is
--  a multiple of the target's stack alignment, so `%rsp` still meets the ABI
--  where a call is made.  Module data is not here yet.  An opcode this does
--  not yet
--  spell raises Compiler_Defect rather than emitting
--  something plausible.
--
--  Nothing here asks the host how wide a pointer is.  Sizes come from
--  `Landin.Backend.Size_Of` against the target description handed in, so
--  a register is chosen by a target fact rather than by the machine this
--  compiler is running on.

with Landin.IR;
with Landin.Resolution;
with Landin.Source.Names;
with Landin.Targets;

package Landin.Backend.X86_64 is

   --  Meanings and Names put a symbol on an item and say whether [1740]
   --  made it `public`, for the same reason `Landin.IR.Dump` is handed
   --  them: `Landin.IR` holds identities and refers to R1.50's table
   --  rather than copying it.
   function Text
     (Of_Unit  : Landin.IR.Unit;
      Meanings : Landin.Resolution.Table;
      Names    : Landin.Source.Names.Table;
      Facts    : Landin.Targets.Target_Facts) return String;

end Landin.Backend.X86_64;
