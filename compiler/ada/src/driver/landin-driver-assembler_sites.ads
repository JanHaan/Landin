--  Where in the source an assembler's refusal came from.
--
--  An assembler reads the `.s` the backend wrote and reports a line of it.
--  A line it refuses inside [1630]'s `assembler.block` is text the program
--  wrote, so the refusal is the program's: this finds the block that wrote
--  it.  The emitted bytes are not marked; each block's text is matched with
--  the refused line, and a line two blocks share is left unplaced rather
--  than placed at one of them.

with Landin.Diagnostics;
with Landin.IR;
with Landin.Source.Names;
with Landin.Targets;

package Landin.Driver.Assembler_Sites is

   --  The reports of an assembler's Output about the assembly Emitted, each
   --  one an L0501 at the block whose text holds the refused line, with
   --  the assembler's own words as its message.  Placed is False, and
   --  nothing is appended, when no line of Output could be placed: the
   --  caller then reports the tool's output as it stands.
   procedure Place
     (Output  : String;
      Emitted : String;
      Code    : Landin.IR.Unit;
      Names   : Landin.Source.Names.Table;
      Facts   : Landin.Targets.Target_Facts;
      Into    : in out Landin.Diagnostics.Diagnostic_List;
      Placed  : out Boolean);

end Landin.Driver.Assembler_Sites;
