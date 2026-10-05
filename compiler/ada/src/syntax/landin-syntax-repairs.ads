--  The smallest repair of a refused statement.
--
--  The parser says what it needed and where, and that is often not what a
--  person wrote wrong: `v: u32 mut = 41` needs a name after `mut`, but the
--  mistake is `mut`.  D261 asks a different question of the same line:
--  which one-token change makes it parse.  A token deleted, written twice
--  in a row, swapped with the next, moved to the line's start, or the token
--  the parser asked for inserted -- each is tried on that line alone, in a
--  routine of its own, and the first report the parser made on the line is
--  restated as the repair that settles it.  When no single change does,
--  the report is left as the parser made it.
--
--  The trials read the line's bytes and run the scanner and the parser over
--  a few hundred bytes each, so the parser itself stays the reader of
--  tokens it was and never reads a byte.  They are limited to one line and
--  a bounded count of tokens, which is what keeps a refused file as cheap
--  to report as an accepted one.

with Landin.Diagnostics;
with Landin.Source;

package Landin.Syntax.Repairs is

   --  The report of one parse of Snapshot, with the first error on each
   --  line of a routine body that one change repairs restated as that
   --  change.  Every other report is passed through unchanged, in order.
   --  Parsed is Snapshot's tree: only a report inside one of its routine
   --  bodies is tried, because a body declares nothing outside it.
   function Restated
     (Snapshot : Landin.Source.Snapshot;
      Parsed   : Landin.Syntax.Tree;
      Found    : Landin.Diagnostics.Diagnostic_List)
      return Landin.Diagnostics.Diagnostic_List;

end Landin.Syntax.Repairs;
