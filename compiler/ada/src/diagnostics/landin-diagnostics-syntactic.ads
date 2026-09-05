--  Turning a parse failure into a diagnostic.
--
--  The sibling of Landin.Diagnostics.Lexical, for the same reason and with
--  the same rule: every code it raises comes from
--  Landin.Diagnostics.Catalogue, every diagnostic it builds is checked
--  against that code's row before it leaves, and Landin.Syntax.Parser
--  therefore contains no code at all.
--
--  It also owns the other half of [1830].  Landin.Tokens.Construct answers
--  for a refused *lexeme*, because the scan can see `1.5` and name it.  A
--  refused *construct* is spelled with tokens the kernel enables -- `loop`
--  remains an ordinary identifier because [1760] does not reserve it -- so
--  only the parser
--  knows it met one, and only from where it was standing.  The parser says
--  which construct it met; this package says which paragraph of the tour
--  describes it and which roadmap item enables it, and may invent neither.
--
--  Two facts about the codes.  L0010 is reused rather than reinvented: the
--  catalogue already records that it is raised by the scanner today and by
--  the parser at R1.40, and a refusal is one rule however it is spelled.
--  And a failure whose rule is the same gets one code with two sentences,
--  because prose lives at the raise site: `if: u32 = 1` and `_: u32 = 1`
--  are both [1760] saying that this is not available as a name.

with Landin.Diagnostics.Catalogue;
with Landin.Source;
with Landin.Tokens;

package Landin.Diagnostics.Syntactic is

   --  The rules the parser can find broken.  One per rule, not one per
   --  place: Token_Expected covers a `then` that is not there and an `end`
   --  that is not there, and the secondary label says which construct went
   --  unclosed.  The names are the catalogue's, so a reader comparing the
   --  two files compares names rather than numbers.
   type Failure is
     (Name_Expected,
      Type_Expected,
      Expression_Expected,
      Token_Expected,
      Unclosed_Construct,
      Assignment_In_Expression,
      Comparison_Chained,
      Return_Carries_Value,
      Public_On_Statement,
      End_Name_Mismatch,
      Stray_Token,
      Nesting_Too_Deep,
      Positional_After_Named,
      Construct_Not_Enabled);

   function Code_For (Item : Failure)
     return Landin.Diagnostics.Catalogue.Code_Name
     is (case Item is
            when Name_Expected        =>
               Catalogue.Name_Expected,
            when Type_Expected        =>
               Catalogue.Type_Expected,
            when Expression_Expected  =>
               Catalogue.Expression_Expected,
            when Token_Expected       =>
               Catalogue.Token_Expected,
            when Unclosed_Construct   =>
               Catalogue.Unclosed_Construct,
            when Assignment_In_Expression =>
               Catalogue.Assignment_In_Expression,
            when Comparison_Chained   =>
               Catalogue.Comparison_Chained,
            when Return_Carries_Value =>
               Catalogue.Return_Carries_Value,
            when Public_On_Statement  =>
               Catalogue.Public_On_Statement,
            when End_Name_Mismatch    =>
               Catalogue.End_Name_Mismatch,
            when Stray_Token          =>
               Catalogue.Stray_Token,
            when Positional_After_Named =>
               Catalogue.Positional_After_Named,
            when Nesting_Too_Deep     =>
               Catalogue.Nesting_Too_Deep,
            when Construct_Not_Enabled =>
               Catalogue.Construct_Not_Enabled);

   --  The constructs the tour describes, the kernel omits, and only the
   --  parser can recognise.  Each is a shape rather than a token: the same
   --  spelling `type` is [0120] where a binding's type belongs and [1290]
   --  where a parameter's does, which is why the parser names the construct
   --  and not the lexeme it saw.
   --
   --  Several are ordinary identifiers to the scan, because [1760] does
   --  not reserve them.  The table keeps those omissions distinguishable
   --  from ordinary names.
   type Refused_Construct is
     (Declared_Type,
      Struct_Type,
      Distinct_Type,
      Type_Parameter,
      Parameterized_Atom_Union,
      --  Bracketed constructs whose spelling the parser alone can tell
      --  from [1790]'s array type and [0520]'s array literal.
      Array_Repetition,
      Indexing,
      --  D64 parses [0710]'s nonempty labelled form and D72 its call-shaped
      --  construction.  [0720]'s all-`of` spelling remains outside [1810]'s
      --  enabled expression grammar.
      Struct_All_Of,
      Import_Alias,
      Selected_Import);

   --  Where the tour describes it.  Ordered by construct so that a reader
   --  can check the column against tour.md by running down it, and
   --  check.py does exactly that.
   function Construct (Item : Refused_Construct)
     return Landin.Tokens.Construct_Reference
     is (case Item is
            when Declared_Type        => "[0120]",
            when Struct_Type          => "[0670]",
            when Distinct_Type        => "[0650]",
            when Type_Parameter       => "[1290]",
            when Parameterized_Atom_Union => "[1350]",
            when Array_Repetition     => "[0560]",
            when Indexing             => "[0570]",
            when Struct_All_Of         => "[0720]",
            when Import_Alias          => "[1430]",
            when Selected_Import       => "[1440]")
     with Post => Landin.Tokens.Is_Valid_Construct (Construct'Result);

   --  What the parser hands over: a rule, a place, and the sentence a user
   --  reads.  Refused is meaningful only for Construct_Not_Enabled, and
   --  Related is the second place a reader looks -- the `if` that was never
   --  closed, the first comparison of a chain, the function whose name the
   --  `end` did not match.  Report checks the catalogue row for the code it
   --  used against the diagnostic it just built, so a code whose
   --  occurrences do not carry what its row promises is a compiler defect
   --  rather than a shipped diagnostic.
   procedure Report
     (Item     : Failure;
      Source   : Landin.Source.Source_Id;
      Where    : Landin.Source.Span;
      Message  : String;
      Note     : String := "";
      Related  : Landin.Source.Span := Landin.Source.Empty_Span;
      Because  : String := "";
      Refused  : Refused_Construct := Declared_Type;
      Into     : in out Diagnostic_List);

private

   --  Where the roadmap says a refused construct becomes available.  The
   --  note [1830] promises has to name work, and this package may not
   --  invent it: it records what ROADMAP.md already says, exactly as
   --  Landin.Diagnostics.Lexical does for a refused lexeme.
   function Enabled_By (Item : Refused_Construct) return String
     is (case Item is
            --  R2.20 implements the types a program declares.
            when Declared_Type        => "R2.20",
            --  The remaining R2.20 constructs each wait for their own
            --  aggregate slice.
            when Struct_Type
               | Distinct_Type
               | Array_Repetition
               | Indexing
               | Struct_All_Of         => "R2.20",
            when Import_Alias
               | Selected_Import       => "R4.30",
            --  R2.40 implements type and fixed parameters.
            when Type_Parameter
               | Parameterized_Atom_Union => "R2.40");

end Landin.Diagnostics.Syntactic;
