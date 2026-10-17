with Landin.Panics;
--  Linux x86-64 assembly for a verified unit.
--
--  Text, not objects.  `tour.md` [1550] says Landin keeps its own native
--  backends and emits assembly for platform assembler and linker tooling,
--  so what this produces is what an assembler is handed and not an ELF
--  file this compiler wrote.  The syntax is GNU as's AT&T form, source
--  before destination, because that is what the tool named by
--  `Landin.Platform`'s runner accepts without a switch.
--
--  The legacy overload selects none/off: accumulator computation and one
--  frame cell per scalar value.  Explicit size/speed emission uses a typed,
--  deterministic GP allocation plan with block-local intervals, reused spill
--  homes, eligible cross-block scalar slots and spans of single-block ones.
--  A location holds a caller-saved register where nothing in its interval
--  writes that register, a parameter the one it arrives in, and a small
--  routine no callee-saved register at all.  Speed emission also keeps
--  eligible float slots and values in XMM8..XMM15 wherever no call falls
--  inside their interval, and aligns the head of each loop.
--  Scratch registers and failure transport remain reserved; only used GP
--  callee saves get homes.
--  The same allocation and target-byte frame planner serve preflight and
--  emission.  Final selected instruction evidence controls body sharing and
--  reports actual emitted sites.  Nothing reads a clock, hash iteration order
--  or host address; public and address-observed entries stay distinct.
--
--  Ordinary add, subtract and multiply each test signed overflow or unsigned
--  carry/borrow at the operation and reach an explicit `ud2` before the
--  result is used; their wrapping forms ignore those flags.  Size and speed
--  compute an operation in its result's register when it has one, with an
--  integer constant that fits as an immediate, and write a one- or two-byte
--  value moving into a register zero-extended to the whole of it.  Unsigned
--  multiply, and every multiply at none, uses x86-64's one-operand form so
--  its implicit high half makes unsigned overflow observable too; a signed
--  one at size and speed is `imul`'s two- or three-operand form, whose
--  overflow flag is the same.  An element is reached, after its bounds
--  check, as one `disp(%base,%index,scale)` operand, and an indexed or
--  slice address whose one use is an indirect access is folded into it.
--  Divide and
--  remainder guard a zero divisor before their one-operand instruction;
--  signed division explicitly traps the minimum over minus one, while signed
--  remainder produces that pair's specified zero without executing `idiv`.
--  A known nonzero divisor needs no guard; a power of two is a shift, and at
--  speed any other is a high multiply by its reciprocal, so neither divides.
--  Unary minus is checked the same way, because [1890] gives it its own
--  integer type back: `neg` reports the lowest signed value as overflow and
--  every nonzero unsigned value as carry.  [0330]'s `~`, `&`, `^` and `|`
--  cannot leave their own type and so carry no edge at all, and [0340]'s
--  `not` flips the low bit alone rather than the byte, because [1870] fixes
--  a bool at zero or one.
--  Comparisons load their left operand, where size and speed do not hold
--  it in a register, compare the right at that operand's width, and
--  materialize a one-byte bool with the signed or unsigned
--  condition [1890] requires.  Optimized, a comparison whose one use is the
--  branch after it jumps on the flags instead, a float one in an operand
--  order that sends an unordered NaN where D162 says.
--  A shift carries the two rules the hardware does not give: the amount is
--  tested against the type's own width, because
--  [0320] and D13 fill with zeros beyond it while x86-64 would mask the
--  count, and a signed amount is tested for being negative, because [1950]
--  leaves the ones the compiler could not read to the trap.  A call fills
--  the internal convention's six argument registers from its operands in
--  order, each at its own parameter's width.  Later scalar arguments occupy
--  eight-byte stack slots in source order; the outgoing run is rounded to the
--  target's stack alignment and reclaimed after the call.  A scalar result
--  comes from the accumulator into a frame cell; D106's aggregate result uses
--  one leading opaque destination address and a complete callee-to-caller
--  storage copy, while a callee returning none leaves nothing to take.
--
--  A module value is data and not code.  [1460] says nothing runs before the
--  entry point, so a datum's block is folded here rather than executed.
--  Checking has already folded with target facts to validate the value;
--  this backend folds the verified scalar datum instructions into its image.
--  What comes out is an
--  object at its own alignment.  Read-only images go in `.rodata`; writable
--  images go in `.data`, including aggregate and array images whose bytes
--  are all zero.  An absent zero image is reserved in `.bss`, where it costs
--  no bytes in the object or the image.  A binding with no value holds zero,
--  which D10 settled, so it is reserved; so are scalar folds that reach zero,
--  aggregates and arrays with omitted or whole-`zeroed` initializers, and
--  [0670]'s module state, which has no other value it could hold.  A routine
--  reaches one by name, RIP-relative, rather than through a frame cell.
--
--  Every opcode `Landin.IR` spells is emitted, so the case that dispatches
--  them is exhaustive rather than ending in a defect: a new opcode fails to
--  compile here instead of failing at run time.
--
--  Nothing here asks the host how wide a pointer is.  Sizes come from
--  `Landin.Backend.Size_Of` against the target description handed in, so
--  a register is chosen by a target fact rather than by the machine this
--  compiler is running on.

with Ada.Strings.Unbounded;

with Landin.Build_Reports;
with Landin.Debugging;
with Landin.Optimization;
with Landin.IR;
with Landin.Resolution;
with Landin.Source.Names;
with Landin.Targets;
with Landin.Targets.Levels;

package Landin.Backend.X86_64 is

   --  Physical internal arguments include hidden result addresses, but not
   --  an indirect call's code address. Count arithmetic allocates no storage.
   --  Stack_Limit_Exceeded reports an unencodable aligned area. Incoming
   --  preflight reserves sixteen additional bytes for the saved frame/call.
   function Native_Argument_Bytes
     (Count : Natural;
      Facts : Landin.Targets.Target_Facts;
      Maximum : Landin.Targets.Byte_Count := 16#7fff_ffff#)
      return Landin.Targets.Byte_Count;

   --  Frame cells and probe endpoints use signed 32-bit displacements from
   --  %rbp/%rsp.  The driver asks before emission so a larger verified frame
   --  is an explicit refusal rather than bad text or host arithmetic overflow.
   --  Large reservations probe in at most 4096-byte decrements, including
   --  a final partial interval; this safety correction also applies to none.
   function Frame_Is_Addressable
     (Of_Unit : Landin.IR.Unit;
      Item    : Landin.IR.Item_Id;
      Facts   : Landin.Targets.Target_Facts) return Boolean;

   --  Meanings and Names put a symbol on an item and say whether [1740]
   --  made it `public`, for the same reason `Landin.IR.Dump` is handed
   --  them: `Landin.IR` holds identities and refers to the resolution table
   --  rather than copying it.
   function Text
     (Of_Unit  : Landin.IR.Unit;
      Meanings : Landin.Resolution.Table;
      Names    : Landin.Source.Names.Table;
      Facts    : Landin.Targets.Target_Facts;
      Hosted_Entry : Landin.IR.Item_Id := Landin.IR.No_Item) return String;

   function Frame_Is_Addressable
     (Of_Unit : Landin.IR.Unit;
      Item    : Landin.IR.Item_Id;
      Facts   : Landin.Targets.Target_Facts;
      Options : Landin.Optimization.Options) return Boolean;

   function Text
     (Of_Unit  : Landin.IR.Unit;
      Meanings : Landin.Resolution.Table;
      Names    : Landin.Source.Names.Table;
      Facts    : Landin.Targets.Target_Facts;
      Options  : Landin.Optimization.Options;
      Hosted_Entry : Landin.IR.Item_Id := Landin.IR.No_Item) return String;

   --  Append actual emitted routine statistics; preserve earlier pass reports.
   procedure Emit
     (Of_Unit  : Landin.IR.Unit;
      Meanings : Landin.Resolution.Table;
      Names    : Landin.Source.Names.Table;
      Facts    : Landin.Targets.Target_Facts;
      Options  : Landin.Optimization.Options;
      Assembly : out Ada.Strings.Unbounded.Unbounded_String;
      Report   : in out Landin.Build_Reports.Report;
      Hosted_Entry : Landin.IR.Item_Id := Landin.IR.No_Item;
      Debug : access constant Landin.Debugging.Information := null;
      Panic : access constant Landin.Panics.Plan := null;
      Level : Landin.Targets.Levels.Feature_Level :=
        Landin.Targets.Levels.Default_Level (Landin.Targets.Linux_X86_64));

end Landin.Backend.X86_64;
