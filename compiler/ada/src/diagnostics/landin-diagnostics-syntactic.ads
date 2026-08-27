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
--  refused *construct* is spelled with tokens the kernel enables -- `loop`,
--  `match` and `type` are ordinary identifiers, since [1760] reserves
--  seventeen words and none of them is any of those -- so only the parser
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
   --  Nine of the fifteen are ordinary identifiers to the scan, because
   --  [1760] reserves seventeen words and none of them is `loop`, `while`,
   --  `for`, `match`, `defer`, `undo`, `try`, `fail`, `break` or
   --  `continue`.  Without this table the compiler would say that `loop`
   --  is a name that needs a `:` after it, which is true and useless.
   type Refused_Construct is
     (Try_Expression,
      Fail_Statement,
      Declared_Type,
      Float_Type,
      Text_Type,
      Parameter_Convention,
      Multiple_Returns,
      Defer_Statement,
      Undo_Statement,
      Loop_Statement,
      While_Statement,
      For_Statement,
      Continue_Statement,
      Struct_Type,
      Wide_Integer_Type,
      Distinct_Type,
      Break_Statement,
      Match_Statement,
      Type_Parameter,
      --  Bracketed constructs whose spelling the parser alone can tell
      --  from [1790]'s array type and [0520]'s array literal.
      Slice_Type,
      Array_Repetition,
      Indexing,
      --  [1820] indexes what a selection named, so the brackets come
      --  last: a field of an element is [0670]'s struct inside [0520]'s
      --  array, which is the element the layout cannot hold yet.
      Selection_From_An_Index);

   --  Where the tour describes it.  Ordered by construct so that a reader
   --  can check the column against tour.md by running down it, and
   --  check.py does exactly that.
   function Construct (Item : Refused_Construct)
     return Landin.Tokens.Construct_Reference
     is (case Item is
            when Try_Expression       => "[0960]",
            when Fail_Statement       => "[0970]",
            when Declared_Type        => "[0120]",
            when Float_Type           => "[0170]",
            when Text_Type            => "[0600]",
            when Parameter_Convention => "[0900]",
            when Multiple_Returns     => "[0920]",
            when Defer_Statement      => "[1100]",
            when Undo_Statement       => "[1110]",
            when Loop_Statement       => "[1130]",
            when While_Statement      => "[1140]",
            when For_Statement        => "[1150]",
            when Continue_Statement   => "[1180]",
            when Struct_Type          => "[0670]",
            when Wide_Integer_Type    => "[0150]",
            when Distinct_Type        => "[0650]",
            when Break_Statement      => "[1190]",
            when Match_Statement      => "[1210]",
            when Type_Parameter       => "[1290]",
            when Slice_Type           => "[0570]",
            when Array_Repetition     => "[0560]",
            when Indexing             => "[0570]",
            when Selection_From_An_Index => "[0520]")
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
            --  R2.30 implements control flow and declared errors.
            when Try_Expression
               | Fail_Statement
               | Defer_Statement
               | Undo_Statement
               | Loop_Statement
               | While_Statement
               | For_Statement
               | Continue_Statement
               | Break_Statement
               | Match_Statement
               | Multiple_Returns     => "R2.30",
            --  The remaining R2.20 constructs each wait for their own
            --  aggregate slice.
            when Struct_Type
               | Distinct_Type
               | Slice_Type
               | Array_Repetition
               | Indexing
               | Selection_From_An_Index => "R2.20",
            --  R2.40 implements type and fixed parameters.
            when Type_Parameter       => "R2.40",
            --  R2.50 sources [0900] for the parameter conventions.
            when Parameter_Convention => "R2.50",
            --  R4.10 closes the hosted construct matrix.
            when Wide_Integer_Type
               | Float_Type
               | Text_Type            => "R4.10");

end Landin.Diagnostics.Syntactic;
