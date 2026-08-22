--  Turning a type that does not agree, or a place that may not be written,
--  into a diagnostic.
--
--  The fourth sibling of Landin.Diagnostics.Lexical, .Syntactic and
--  .Resolution, under the same rule: every code it raises comes from
--  Landin.Diagnostics.Catalogue, every diagnostic it builds is checked
--  against that code's row before it leaves, and the stage that found the
--  fault therefore contains no code at all.
--
--  Seven rules, each with its own paragraph in the specification, because
--  none of them could be read out of the older ones.  [1880] says where a
--  literal's type comes from and that a value the type does not hold is
--  refused; [1890] says what each operator takes and gives; [1900] says
--  what may be written; [1910] says a name must be assigned by every path
--  that reaches a read; [1920] says what a call means and what a name may
--  be used as; and [1950] says which operand an operation cannot take.
--
--  Impossible_Operand is the operand half of what Literal_Out_Of_Range is
--  the result half of, and the two must not be merged.  A literal out of
--  range is a good operation whose answer the type does not hold, which
--  [1880] leaves to the trap inside a body; an impossible operand is a
--  divisor of zero or a negative shift amount, where [1950] says there is
--  no operation to perform at all.  One is about a result and the other
--  about an input, and a reader told the wrong one looks in the wrong
--  place.
--
--  Unsupported_Use is the checker's half of [1830], and it is separate from
--  Landin.Diagnostics.Syntactic's Construct_Not_Enabled for a reason of
--  information and not of stage.  The parser refuses `loop` because of the
--  word it read; the checker refuses `u8(x)` because of what `u8` turned
--  out to name, which is a fact no reading of the bytes could supply --
--  `u8(x)` is a perfectly good `call` production.  So it carries [1830]'s
--  two notes, the construct and the work that enables it, and it is not a
--  misspelling and must never be reported as one.
--
--  Related is a Landin.Provenance.Origin and not a span, for the reason
--  Landin.Diagnostics.Resolution found first: the declaration a mismatch
--  points at can be in another file.

with Landin.Diagnostics.Catalogue;
with Landin.Provenance;
with Landin.Source;
with Landin.Tokens;

package Landin.Diagnostics.Checking is

   --  The rules the checker can find broken.  The names are the
   --  catalogue's, so a reader comparing the two files compares names
   --  rather than numbers.
   type Failure is
     (Literal_Out_Of_Range,
      Type_Mismatch,
      Not_Definitely_Assigned,
      Immutable_Target,
      Unsupported_Use,
      Not_Known_At_Compile_Time,
      Impossible_Operand);

   function Code_For (Item : Failure)
     return Landin.Diagnostics.Catalogue.Code_Name
     is (case Item is
            when Literal_Out_Of_Range =>
               Catalogue.Literal_Out_Of_Range,
            when Type_Mismatch        =>
               Catalogue.Type_Mismatch,
            when Not_Definitely_Assigned =>
               Catalogue.Not_Definitely_Assigned,
            when Immutable_Target     =>
               Catalogue.Immutable_Target,
            when Unsupported_Use      =>
               Catalogue.Unsupported_Use,
            when Not_Known_At_Compile_Time =>
               Catalogue.Not_Known_At_Compile_Time,
            when Impossible_Operand   =>
               Catalogue.Impossible_Operand);

   --  The constructs the tour describes, the kernel omits, and only the
   --  checker can recognise, because recognising one means knowing what a
   --  name resolved to.
   type Refused_Use is
     (Scalar_Conversion,
      Function_Value,
      Call_Of_A_Binding);

   function Construct (Item : Refused_Use)
     return Landin.Tokens.Construct_Reference
     is (case Item is
            when Scalar_Conversion  => "[0700]",
            when Function_Value     => "[1000]",
            when Call_Of_A_Binding  => "[1000]")
     with Post => Landin.Tokens.Is_Valid_Construct (Construct'Result);

   procedure Report
     (Item    : Failure;
      Source  : Landin.Source.Source_Id;
      Where   : Landin.Source.Span;
      Message : String;
      Note    : String := "";
      Related : Landin.Provenance.Origin := Landin.Provenance.No_Origin;
      Because : String := "";
      Refused : Refused_Use := Scalar_Conversion;
      Into    : in out Diagnostic_List);

private

   --  Where the roadmap says each becomes available.  R2.20 implements the
   --  types a program declares, which is where [0700]'s construction and
   --  conversion form arrives; R2.30 implements full function values.
   function Enabled_By (Item : Refused_Use) return String
     is (case Item is
            when Scalar_Conversion => "R2.20",
            when Function_Value
               | Call_Of_A_Binding => "R2.30");

end Landin.Diagnostics.Checking;
