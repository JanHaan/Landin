--  Turning a scanner fault into a diagnostic.
--
--  R1.20 left a fault carrying a kind and spans and no code, because the
--  catalogue is R1.30's. This is the one place the two meet: every code it
--  raises comes from Landin.Diagnostics.Catalogue, and every diagnostic it
--  builds satisfies that code's row -- Report checks the row it just used,
--  so a diagnostic that does not carry what its code requires never leaves
--  this package.

with Landin.Diagnostics.Catalogue;
with Landin.Tokens;

package Landin.Diagnostics.Lexical is

   --  Reports every fault the scan found, in the order the scan found them.
   --  Landin.Diagnostics.Sorted decides reporting order later; this is the
   --  order the bytes are in.
   procedure Report
     (Stream : Landin.Tokens.Token_Stream;
      Into   : in out Diagnostic_List);

   --  Which code a fault kind raises. Exposed so a test can assert the
   --  mapping without building a stream.
   function Code_For (Fault : Landin.Tokens.Fault_Kind)
     return Landin.Diagnostics.Catalogue.Code_Name;

private

   --  Where the roadmap says a refused construct becomes available. The
   --  note [1830] promises has to name work, and this package may not
   --  invent it: R1.30 records what ROADMAP.md already says.
   function Enabled_By (Refused : Landin.Tokens.Deferred_Kind) return String;

end Landin.Diagnostics.Lexical;
