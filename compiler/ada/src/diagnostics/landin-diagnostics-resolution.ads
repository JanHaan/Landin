--  Turning a name that resolved to nothing, or to two things, into a
--  diagnostic.
--
--  The third sibling of Landin.Diagnostics.Lexical and
--  Landin.Diagnostics.Syntactic, for the same reason and under the same
--  rule: every code it raises comes from Landin.Diagnostics.Catalogue,
--  every diagnostic it builds is checked against that code's row before it
--  leaves, and the stage that found the fault therefore contains no code at
--  all.
--
--  Four resolution rules: duplicate declarations [1850], unresolved
--  names [1860], inaccessible module members [1410], and reserved tool
--  namespace bindings or unavailable tool references [1480] [1560].
--  [1840] owns their source scopes; D201 extends the per-file import scope
--  and D202 separates configuration names from ordinary declarations.
--
--  One thing here is new in the compiler and it is the reason Related is an
--  Origin rather than a span.  Until now both places a diagnostic points at
--  were in one file, because a scan and a parse never cross one.  The
--  earlier of two declarations of one name can be in another file
--  altogether, so the second label carries its own source; that is why
--  Landin.Resolution keeps a Landin.Provenance.Declaration_Id, whose site
--  table already holds exactly that pair.

with Landin.Diagnostics.Catalogue;
with Landin.Provenance;
with Landin.Source;

package Landin.Diagnostics.Resolution is

   --  A code this package reports.  Failure is the catalogue's Code_Name
   --  derived, so it has the catalogue's names and a new code needs no
   --  second list here; Code_For is the conversion back.
   type Failure is new Landin.Diagnostics.Catalogue.Code_Name;

   function Code_For (Item : Failure)
     return Landin.Diagnostics.Catalogue.Code_Name
     is (Landin.Diagnostics.Catalogue.Code_Name (Item));

   --  What the resolver hands over: a rule, the name it was looking at, and
   --  the sentence a user reads.  Related is the earlier declaration and is
   --  meaningful only for a duplicate, which is why Report refuses a
   --  Because with no origin to attach it to.
   --
   --  Report checks the catalogue row for the code it used against the
   --  diagnostic it just built, so a code whose occurrences do not carry
   --  what its row promises is a compiler defect rather than a shipped
   --  diagnostic.  Fixes are attached in the order given, the first the
   --  one a tool prefers, and the row says whether the code may carry any.
   procedure Report
     (Item    : Failure;
      Source  : Landin.Source.Source_Id;
      Where   : Landin.Source.Span;
      Message : String;
      Note    : String;
      Related : Landin.Provenance.Origin := Landin.Provenance.No_Origin;
      Because : String := "";
      Fixes   : Fix_List := No_Fixes;
      Into    : in out Diagnostic_List);

end Landin.Diagnostics.Resolution;
