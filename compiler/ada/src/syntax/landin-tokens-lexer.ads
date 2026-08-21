--  The scan.
--
--  A child of Landin.Tokens on purpose: Token and Token_Stream have no
--  constructor in the parent's visible part, so the only unit in the
--  compiler that can build a token is the one that reads bytes.
--
--  The scan never fails. A byte no rule spells becomes a token of a kind
--  that says so, with a fault beside it, and the scan continues at the next
--  byte: an ill-formed program is data [0950], and a parser that recovers
--  needs a stream to recover in.

with Landin.Source;
with Landin.Source.Names;

package Landin.Tokens.Lexer is

   --  Reads one snapshot into a stream, interning identifiers into Names.
   --  The stream always ends in End_Of_Input, and every span in it lies
   --  inside From.
   procedure Lex
     (From   : Landin.Source.Snapshot;
      Names  : in out Landin.Source.Names.Table;
      Into   : out Token_Stream);

end Landin.Tokens.Lexer;
