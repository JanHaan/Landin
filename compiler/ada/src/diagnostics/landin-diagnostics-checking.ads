--  Turning a type that does not agree, or a place that may not be written,
--  into a diagnostic.
--
--  The fourth sibling of Landin.Diagnostics.Lexical, .Syntactic and
--  .Resolution, under the same rule: every code it raises comes from
--  Landin.Diagnostics.Catalogue, every diagnostic it builds is checked
--  against that code's row before it leaves, and the stage that found the
--  fault therefore contains no code at all.
--
--  Twenty rules, each with its own paragraph in the specification, because
--  none of them could be read out of the older ones.  [1880] says where a
--  literal's type comes from and that a value the type does not hold is
--  refused; [1890] says what each operator takes and gives; [1900] says
--  what may be written; [1910] says a name must be assigned by every path
--  that reaches a read; [1920] says what a call means and what a name may
--  be used as; [1950] says which operand an operation cannot take; [1795]
--  says an alias chain has to reach a type; [0750] says what a struct may
--  select; and [0770]--[0830] supply escape, borrow and source-drift rules.
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
--  Not_Known_At_Compile_Time serves both [1940]'s static module images and
--  D136's fixed-array bounds: each requires an answer before runtime and
--  refuses a runtime name or call rather than executing user code. D136's
--  application-dependent range and operand failures retain L0300 and L0306:
--  the semantic rule is unchanged, while the application is primary and the
--  template expression is related.
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
--  Recursive_Nominal_Value is D137's finite-layout rule, distinct from
--  Cyclic_Type_Alias: an alias cycle reaches no type, while a nominal cycle
--  reaches a type whose by-value extent could never be finite.  Its related
--  label names the struct body or substituted field that closes the cycle.
--
--  Related is a Landin.Provenance.Origin and not a span, for the reason
--  Landin.Diagnostics.Resolution found first: the declaration a mismatch
--  points at can be in another file.  R2.60 adds whole-program conformance
--  collisions, unsatisfied concept constraints, and compiler-reserved
--  conformances; their related-source cardinalities are part of the rows.

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
      Impossible_Operand,
      Cyclic_Type_Alias,
      Unresolved_Field,
      Field_Named_Twice,
      Field_Not_Given,
      Variant_Case_Named_Twice,
      Variant_Case_Not_Matched,
      Recursive_Nominal_Value,
      Reference_Escapes,
      Borrowed_Place,
      Return_Sources_Disagree,
      Conformance_Collision,
      Unsatisfied_Constraint,
      Compiler_Conformance_Reserved);

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
               Catalogue.Impossible_Operand,
            when Cyclic_Type_Alias    =>
               Catalogue.Cyclic_Type_Alias,
            when Unresolved_Field     =>
               Catalogue.Unresolved_Field,
            when Field_Named_Twice    =>
               Catalogue.Field_Named_Twice,
            when Field_Not_Given      =>
               Catalogue.Field_Not_Given,
            when Variant_Case_Named_Twice =>
               Catalogue.Variant_Case_Named_Twice,
            when Variant_Case_Not_Matched =>
               Catalogue.Variant_Case_Not_Matched,
            when Recursive_Nominal_Value =>
               Catalogue.Recursive_Nominal_Value,
            when Reference_Escapes =>
               Catalogue.Reference_Escapes,
            when Borrowed_Place =>
               Catalogue.Borrowed_Place,
            when Return_Sources_Disagree =>
               Catalogue.Return_Sources_Disagree,
            when Conformance_Collision =>
               Catalogue.Conformance_Collision,
            when Unsatisfied_Constraint =>
               Catalogue.Unsatisfied_Constraint,
            when Compiler_Conformance_Reserved =>
               Catalogue.Compiler_Conformance_Reserved);

   --  The constructs the tour describes, the kernel omits, and only the
   --  checker can recognise, because recognising one means knowing what a
   --  name resolved to.
   type Refused_Use is
     (Scalar_Conversion,
      --  A type name the tour writes and [1790] omits.  These were the
      --  parser's until [1795] let a type position hold a declared name:
      --  once any identifier may stand there, whether one names a type
      --  the kernel lacks is a question about what it resolved to.
      Wide_Integer_Type,
      Float_Type,
      --  [0610]'s codepoint-ordinal access remains a separate R4.10
      --  increment after the text view identities themselves.
      Text_Indexing,
      --  [0670] declares one.  R2.20 admits contextual storage, copies,
      --  zero images and labelled literals but not a general aggregate
      --  value.
      Struct_Value,
      --  D74 lays out and measures [0680]'s declaration, D75 gives it
      --  storage and a zero image, and D76 admits contextual case writes;
      --  a general variant value remains refused.
      Variant_Value,
      --  [0520] declares one; a value of one waits, as a struct's did,
      --  and so does an element the kernel cannot lay out end to end.
      Array_Value,
      Array_Element,
      --  [1150]'s collection traversal is parsed alongside ranges so the
      --  checker can distinguish the source's element shape.  D160 enables
      --  slices and fixed arrays of scalar, pointer, atom, function and
      --  struct elements; the rest of the element shapes and [1320]'s
      --  iterable-evidence sources stay here.
      Collection_Traversal,
      --  D135's parameterized aliases are checked here, including an
      --  unapplied constructor and malformed positional application.
      Parameterized_Type_Alias,
      --  [0540]'s contextual all-bits-zero image.
      Zeroed_Value,
      --  [1580]'s aggregate, variadic and wider foreign ABI matrix.
      External_C_ABI);

   function Construct (Item : Refused_Use)
     return Landin.Tokens.Construct_Reference
     is (case Item is
            when Scalar_Conversion  => "[0700]",
            when Wide_Integer_Type  => "[0150]",
            when Float_Type         => "[0170]",
            when Text_Indexing      => "[0610]",
            when Struct_Value       => "[0670]",
            when Variant_Value      => "[0680]",
            when Array_Value        => "[0520]",
            when Array_Element      => "[0520]",
            when Collection_Traversal => "[1150]",
            when Parameterized_Type_Alias => "[1350]",
            when Zeroed_Value       => "[0540]",
            when External_C_ABI     => "[1580]")
     with Post => Landin.Tokens.Is_Valid_Construct (Construct'Result);

   --  The type names above, spelled once.  A name that is not here is a
   --  name nothing in either document writes as a type, and resolution has
   --  already reported it as declared nowhere.
   type Refused_Type_Name is
     (Wide_Unsigned, Wide_Signed, Float_16);

   function Spelling (Item : Refused_Type_Name) return String
     is (case Item is
            when Wide_Unsigned => "u128",
            when Wide_Signed   => "i128",
            when Float_16      => "f16");

   function Refusal (Item : Refused_Type_Name) return Refused_Use
     is (case Item is
            when Wide_Unsigned
               | Wide_Signed   => Wide_Integer_Type,
            when Float_16      => Float_Type);

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

   --  Where the roadmap says each becomes available.  R2.20 owns the
   --  remaining general aggregate-value contexts; R4.10 closes scalar
   --  conversions with the hosted construct matrix.
   function Enabled_By (Item : Refused_Use) return String
     is (case Item is
            when Scalar_Conversion => "R4.10",
            --  R4.10 closes the hosted construct matrix, including the wide
            --  integers, f16 and [0610]'s remaining text indexing.
            when Wide_Integer_Type
               | Float_Type
               | Text_Indexing     => "R4.10",
            when Struct_Value
               | Variant_Value
               | Array_Value
               | Array_Element
               | Zeroed_Value      => "R2.20",
            when Collection_Traversal => "R4.10",
            when Parameterized_Type_Alias => "R2.40",
            when External_C_ABI     => "R4.40");

end Landin.Diagnostics.Checking;
