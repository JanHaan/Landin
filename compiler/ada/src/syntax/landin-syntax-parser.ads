--  The parse.
--
--  A child of Landin.Syntax on purpose: Tree has no constructor in the
--  parent's visible part, so the only unit in the compiler that can build
--  one is the one that reads tokens.  It reads tokens and never bytes: the
--  scan already interned every identifier and carried every span, so a
--  parser that reached for the snapshot would be re-deciding a lexical
--  question that [1750] gave to Landin.Tokens.Lexer.
--
--  The parse never fails.  A construct it cannot read becomes an Error node
--  of the band it needed and a diagnostic beside it, and the parse resumes:
--  an ill-formed program is data [0950], and R1.40's exit evidence is that a
--  malformed file yields several ordered diagnostics and no crash.  The one
--  thing that can raise is Landin.Compiler_Defect, and only for a defect in
--  this package.
--
--  Recovery is a forward scan, which is why Landin.Tokens.Skip_To exists and
--  takes a Kind_Set whose membership of End_Of_Input is the proof it stops.
--  The boundaries it resumes at are the ones the grammar makes unambiguous:
--  the start of a declaration, `end`, and a statement boundary inside a
--  block.  A recovery point is never a token the parser guessed at.
--
--  Descent is recursive and the operator levels of [1820] are Pratt, which
--  is the split the roadmap names: ten binary levels written as ten mutually
--  recursive functions would repeat the same loop ten times, and the
--  precedence table is the only thing that differs between them.

with Landin.Diagnostics;
with Landin.Source.Names;
with Landin.Tokens;

package Landin.Syntax.Parser is

   use type Landin.Source.Source_Id;

   --  Recursive descent over a hostile file needs a floor, because the
   --  grammar's nesting is unbounded and the host's stack is not: `((((`
   --  repeated is a legal prefix.  Reaching this depth is a diagnostic and
   --  an Error node, not an exception, and it is a constant rather than a
   --  literal in the body so that a fixture can be written against it.
   --  Later stages need no equivalent: they read the table in index order.
   Nesting_Limit : constant := 128;

   --  Reads one token stream into a tree, appending every syntax diagnostic
   --  to Report.  Names is in out because the parser has to intern the
   --  spellings it compares against -- the scalar type names of [1790], and
   --  the leading names [1830] refuses -- and interning is by bytes, so
   --  asking twice gets the same identity.
   --
   --  Lexical faults are not this procedure's to report; the syntax stage
   --  calls Landin.Diagnostics.Lexical for those, before this, so that a
   --  file with an unreadable byte and a missing `then` reports both.
   function Parse
     (From   : Landin.Tokens.Token_Stream;
      Names  : in out Landin.Source.Names.Table;
      Report : in out Landin.Diagnostics.Diagnostic_List) return Tree
     with Post => Landin.Tokens.Source_Of (From) = Source_Of (Parse'Result);

end Landin.Syntax.Parser;
