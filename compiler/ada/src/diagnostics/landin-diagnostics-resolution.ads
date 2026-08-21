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
--  Two rules and not more, and the tour states each in its own paragraph
--  because neither could be read out of [0130]: [1850] says one scope gives
--  one name to one thing, and [1860] says a name that names nothing is
--  refused.  Everything else the kernel can get wrong about a name is
--  either a syntax fault R1.40 already reports or a type fault R1.60 will.
--  [1840] is the third of the three and is not a failure: it is the list of
--  scopes the other two are about.
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

   --  The rules the resolver can find broken.  The names are the
   --  catalogue's, so a reader comparing the two files compares names
   --  rather than numbers.
   type Failure is (Duplicate_Declaration, Unresolved_Name);

   function Code_For (Item : Failure)
     return Landin.Diagnostics.Catalogue.Code_Name
     is (case Item is
            when Duplicate_Declaration =>
               Catalogue.Duplicate_Declaration,
            when Unresolved_Name       =>
               Catalogue.Unresolved_Name);

   --  What the resolver hands over: a rule, the name it was looking at, and
   --  the sentence a user reads.  Related is the earlier declaration and is
   --  meaningful only for a duplicate, which is why Report refuses a
   --  Because with no origin to attach it to.
   --
   --  Report checks the catalogue row for the code it used against the
   --  diagnostic it just built, so a code whose occurrences do not carry
   --  what its row promises is a compiler defect rather than a shipped
   --  diagnostic.
   procedure Report
     (Item    : Failure;
      Source  : Landin.Source.Source_Id;
      Where   : Landin.Source.Span;
      Message : String;
      Note    : String;
      Related : Landin.Provenance.Origin := Landin.Provenance.No_Origin;
      Because : String := "";
      Into    : in out Diagnostic_List);

end Landin.Diagnostics.Resolution;
