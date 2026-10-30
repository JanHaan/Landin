--  Turning a scanner fault into a diagnostic.
--
--  The scanner leaves a fault carrying a kind and spans and no code, because
--  the catalogue is not the scanner's.  This is the one place the two meet:
--  every code it raises comes from Landin.Diagnostics.Catalogue, and every
--  diagnostic it builds satisfies that code's row -- Report checks the row it
--  just used, so a diagnostic that does not carry what its code requires never
--  leaves this package.

with Landin.Diagnostics.Catalogue;
with Landin.Source;
with Landin.Tokens;

package Landin.Diagnostics.Lexical is

   --  Reports every fault the scan found, in the order the scan found them,
   --  but a word with a capital, which Report_Word reports once the parse
   --  has said what the word names.  Landin.Diagnostics.Sorted decides
   --  reporting order later; this is the order the bytes are in.
   procedure Report
     (Stream : Landin.Tokens.Token_Stream;
      Into   : in out Diagnostic_List);

   --  D528: one word with a capital, Spelling, reported once over the whole
   --  word.  C_Name says that the word names a function declared
   --  `extern(c)` without `link(symbol: ...)`, and then the note shows that
   --  annotation with the word as C's symbol and a lower-case Landin name;
   --  elsewhere it offers the lower-case spelling.  Landin.Syntax.Parser
   --  calls this, because only the parse knows what the word names.
   procedure Report_Word
     (Source   : Landin.Source.Source_Id;
      Fault    : Landin.Tokens.Fault;
      Spelling : String;
      C_Name   : Boolean;
      Into     : in out Diagnostic_List)
     with Pre => Landin.Tokens."="
                   (Landin.Tokens.Kind (Fault),
                    Landin.Tokens.Capitalised_Identifier);

   --  The lower-case spelling a word with capitals offers: a capital that
   --  begins a part is preceded by an underscore, so `InitWindow` is
   --  `init_window` and `HTTPServer` is `http_server`.
   function Lower_Spelling (Word : String) return String;

   --  Which code a fault kind raises. Exposed so a test can assert the
   --  mapping without building a stream.
   function Code_For (Fault : Landin.Tokens.Fault_Kind)
     return Landin.Diagnostics.Catalogue.Code_Name;

end Landin.Diagnostics.Lexical;
