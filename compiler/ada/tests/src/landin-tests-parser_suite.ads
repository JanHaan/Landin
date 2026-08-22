--  R1.40's parser, held to the corpus from both sides.
--
--  `check.py` derives every program under `fixtures/positive` from the
--  grammar in `tour.md` and refuses every one under `negative`.  This
--  suite runs the parser over the same tree and requires the same verdict,
--  which is what makes the grammar and the implementation one agreement
--  rather than two opinions: a program the grammar derives and the parser
--  rejects fails here, and so does the reverse.
--
--  It reads the real fixture tree through the native adapter.  That is a
--  deliberate exception to the fake-filesystem rule, for the same reason
--  the lexer suite makes it: a corpus copied into Ada literals stops being
--  the corpus.

with Landin.Testing;

package Landin.Tests.Parser_Suite is

   procedure Register (Into : in out Landin.Testing.Registry);

end Landin.Tests.Parser_Suite;
