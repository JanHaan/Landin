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
--  describes it and what the construct's standing is, and may invent
--  neither.
--
--  Two facts about the codes.  L0010 is reused rather than reinvented: the
--  parser retains the code born in lexical refusal, though the scanner no
--  longer raises it. A refusal is one rule however it is spelled.
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
      Type_Parameter,
      --  Bracketed constructs whose spelling the parser alone can tell
      --  from [1790]'s array type and [0520]'s array literal.
      Array_Repetition,
      Indexing,
      --  D64 parses [0710]'s nonempty labelled form and D72 its call-shaped
      --  construction.  [0720]'s all-`of` spelling remains outside [1810]'s
      --  enabled expression grammar.
      Struct_All_Of,
      Volatile_Reference,
      Shared_Declaration,
      --  D212 withdraws [0820]'s lexical arena block by its shape.  The
      --  word is not reserved and names a library type today, so only a
      --  statement-position `arena name do` is this construct.
      Arena_Block);

   --  Where the tour describes it.  Ordered by construct so that a reader
   --  can check the column against tour.md by running down it, and
   --  check.py does exactly that.
   function Construct (Item : Refused_Construct)
     return Landin.Tokens.Construct_Reference
     is (case Item is
            when Shared_Declaration   => "[0100]",
            when Declared_Type        => "[0120]",
            when Struct_Type          => "[0670]",
            when Type_Parameter       => "[1290]",
            when Array_Repetition     => "[0560]",
            when Indexing             => "[0570]",
            when Struct_All_Of         => "[0720]",
            when Arena_Block           => "[0820]",
            when Volatile_Reference    => "[0850]")
     with Post => Landin.Tokens.Is_Valid_Construct (Construct'Result);

   --  D367: spellings another language gives a construct Landin writes
   --  another way.  The parser never reads one as anything: it refuses
   --  the line as it always did, and only when the tokens it stopped on
   --  spell a row here does the report it makes name the Landin form
   --  instead of what the parser needed.  A row is the spelling, the
   --  Landin form, the paragraph that defines that form and the fixture
   --  that pins the one report; check.py holds each to the grammar and
   --  to its fixture.  A foreign form with no single Landin construct to
   --  name, such as `++` between two operands for concatenation, has no
   --  row and keeps the parser's own report.
   type Foreign_Form is
     (Elif_Word,
      Elseif_Word,
      Fn_Word,
      As_Conversion,
      Postfix_Increment,
      Star_Pointer,
      Double_Ampersand,
      Double_Bar,
      Bang_Equal);

   function Foreign_Spelling (Item : Foreign_Form) return String
     is (case Item is
            when Elif_Word         => "elif",
            when Elseif_Word       => "elseif",
            when Fn_Word           => "fn",
            when As_Conversion     => "as",
            when Postfix_Increment => "++",
            when Star_Pointer      => "*",
            when Double_Ampersand  => "&&",
            when Double_Bar        => "||",
            when Bang_Equal        => "!=");

   --  What the form is written as in Landin, the word a fix writes where
   --  it has one.
   function Landin_Spelling (Item : Foreign_Form) return String
     is (case Item is
            when Elif_Word | Elseif_Word => "elsif",
            when Fn_Word           => "name: (parameters) -> (returns) =",
            when As_Conversion     => "type(value)",
            when Postfix_Increment => "inc",
            when Star_Pointer      => "ptr",
            when Double_Ampersand  => "and",
            when Double_Bar        => "or",
            when Bang_Equal        => "<>");

   function Foreign_Construct (Item : Foreign_Form)
     return Landin.Tokens.Construct_Reference
     is (case Item is
            when Elif_Word | Elseif_Word => "[1810]",
            when Fn_Word           => "[1800]",
            when As_Conversion     => "[0310]",
            when Postfix_Increment => "[0400]",
            when Star_Pointer      => "[0430]",
            when Double_Ampersand
               | Double_Bar        => "[0340]",
            when Bang_Equal        => "[0350]")
     with Post => Landin.Tokens.Is_Valid_Construct
                    (Foreign_Construct'Result);

   --  The negative fixture whose recorded report is this row's.
   function Foreign_Fixture (Item : Foreign_Form) return String
     is (case Item is
            when Elif_Word         => "foreign-elif-is-named",
            when Elseif_Word       => "foreign-elseif-is-named",
            when Fn_Word           => "foreign-fn-is-named",
            when As_Conversion     => "foreign-as-is-named",
            when Postfix_Increment => "foreign-postfix-increment-is-named",
            when Star_Pointer      => "foreign-star-pointer-is-named",
            when Double_Ampersand  => "foreign-double-ampersand-is-named",
            when Double_Bar        => "foreign-double-bar-is-named",
            when Bang_Equal        => "foreign-bang-equal-is-named");

   --  The report's sentence.  Every one begins "Landin writes", which is
   --  also how D261's repair search knows the report is already the
   --  smallest change and leaves it standing.
   function Foreign_Message (Item : Foreign_Form) return String
     is (case Item is
            when Elif_Word | Elseif_Word =>
               "Landin writes `elsif`, not `" & Foreign_Spelling (Item)
               & "`, for another condition of an `if`",
            when Fn_Word =>
               "Landin writes a function as `name: (parameters) ->"
               & " (returns) =`, with no `fn`",
            when As_Conversion =>
               "Landin writes a conversion as its type applied to the"
               & " value, `type(value)`, not with `as`",
            when Postfix_Increment =>
               "Landin writes `inc name` to add one, not `name++`",
            when Star_Pointer =>
               "Landin writes a pointer type as `ptr T`, not `*T`",
            when Double_Ampersand =>
               "Landin writes `and`, not `&&`",
            when Double_Bar =>
               "Landin writes `or`, not `||`",
            when Bang_Equal =>
               "Landin writes `<>` for inequality, not `!=`");

   function Foreign_Note (Item : Foreign_Form) return String
     is (Foreign_Construct (Item) & ": "
         & (case Item is
               when Elif_Word | Elseif_Word =>
                  "an `if` goes on with `elsif condition then` and ends"
                  & " with an optional `else` and `end if`",
               when Fn_Word =>
                  "a function is its name, a colon, its signature and `=`,"
                  & " and its body closes with `end name`",
               when As_Conversion =>
                  "nothing converts on its own, and a conversion is a call"
                  & " of the type converted to, as in `u32(count)`",
               when Postfix_Increment =>
                  "`inc` and `dec` are statements of their own, and"
                  & " there is no `++` or `--`",
               when Star_Pointer =>
                  "`ptr T` points at a `T` it may read, and `ptr mut T`"
                  & " at one it may also write",
               when Double_Ampersand | Double_Bar =>
                  "the logical operators are the words `and`, `or` and"
                  & " `not`; `&` and `|` are bitwise",
               when Bang_Equal =>
                  "the comparisons are `==`, `<>`, `<`, `<=`, `>` and"
                  & " `>=`"));

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
      Fixes    : Fix_List := No_Fixes;
      Into     : in out Diagnostic_List);

private

   --  What each refused construct is, which is what the second note [1830]
   --  promises says.  This package records what spec.md decided and may
   --  not decide it, exactly as Landin.Diagnostics.Lexical does for a
   --  refused lexeme.
   function Standing (Item : Refused_Construct) return Refusal_Standing
     is (case Item is
            --  A type is declared by name, an aggregate is written
            --  against a named type, an element is read through a named
            --  place, and a type parameter is written where a type is.
            --  Each shape is the source-form boundary of a construct the
            --  kernel enables.
            when Declared_Type
               | Struct_Type
               | Array_Repetition
               | Indexing
               | Struct_All_Of
               | Type_Parameter        => Recorded_Boundary,
            --  D233's inferred `a, b := e` and the declarations that keep
            --  one name.
            when Shared_Declaration    => Recorded_Boundary,
            --  D212 withdraws the lexical arena block, and D238 the
            --  volatile pointer type: D227's scalar accesses and D228's
            --  register operations are volatile by the operation, over an
            --  ordinary pointer.
            when Arena_Block
               | Volatile_Reference    => Withdrawn);

end Landin.Diagnostics.Syntactic;
