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
--  two notes, the construct and its standing, and it is not a misspelling
--  and must never be reported as one.
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
      Compile_Time_Assertion_Failed,
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
            when Compile_Time_Assertion_Failed =>
               Catalogue.Compile_Time_Assertion_Failed,
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
   --
   --  A type name the tour writes and [1790] omits was the parser's until
   --  [1795] let a type position hold a declared name.  Once any identifier
   --  may stand there, whether one names a type the kernel lacks is a
   --  question about what it resolved to.
   --
   --  D190: [1790]'s scalar rule spells thirteen names and has never
   --  spelled u128, i128 or f16, so their refusal is the specification's
   --  and not a schedule's, and what R7.20 inherits is written there.
   --  Narrow_Float_Type is narrow and not Float: f32 and f64 have been
   --  implemented since D162 and this row is only f16.
   type Refused_Use is
     (Wide_Integer_Type,
      Narrow_Float_Type,
      --  [0670] declares one.  R2.20 admits contextual storage, copies,
      --  zero images, labelled literals and constructions; R7.20 records
      --  what is left as the form's boundary: an untyped literal with no
      --  destination, a module image [1940] cannot fold, and a nested
      --  body that could not be laid out.
      Struct_Value,
      --  D74 lays out and measures [0680]'s declaration, D75 gives it
      --  storage and a zero image, and D76 admits contextual case writes.
      --  A variant part is a member of its struct and a case is written
      --  where its part is the destination, so neither has a value of its
      --  own; R7.20 records that boundary.
      Variant_Value,
      --  [0520] declares one.  An array literal or repetition takes its
      --  shape from a destination or an inferred binding, and a module
      --  image keeps [1940]'s boundary; R7.20 records both.
      Array_Value,
      Array_Element,
      --  D135's parameterized aliases are checked here, including an
      --  unapplied constructor and malformed positional application.
      Parameterized_Type_Alias,
      --  [0540]'s contextual all-bits-zero image.
      Zeroed_Value,
      --  [1580]'s entry stood here and R7.40 removed it.  Nothing raised it:
      --  the categories that paragraph lists are refused where they are
      --  written, as the C boundary's own type errors, which is what
      --  "refused explicitly rather than guessed" already promises.  An
      --  entry no report reaches cannot say which work records the boundary,
      --  and its note still named the finished R4.40 as the item that would
      --  enable them.  `negative/r740-c-category-boundary` pins the report
      --  that is actually made.
      --
      --  D188: [0660]'s range subtype is its base type constrained, so
      --  `[]percent` and `[]u8` would be one type and a `[]u8` write of an
      --  excluded value would enter constrained storage unchecked.  A
      --  composite or reference position, `addr` of a constrained place and
      --  a generic type argument therefore refuse one; D236 makes that the
      --  recorded boundary rather than a pending promise.  An `extern (c)`
      --  signature is not this refusal: [1580]'s hosted-scalar boundary
      --  already refuses it and keeps that report, which R4.40 owns.
      Constrained_Composition,
      --  D212 withdraws [0820]'s builtin type and lexical block.  Keep
      --  migration guidance for the unresolved type spelling; a declared
      --  ordinary type of that name has already resolved normally.
      Arena_Region);

   function Construct (Item : Refused_Use)
     return Landin.Tokens.Construct_Reference
     is (case Item is
            when Wide_Integer_Type  => "[0150]",
            when Narrow_Float_Type  => "[0170]",
            when Struct_Value       => "[0670]",
            when Variant_Value      => "[0680]",
            when Array_Value        => "[0520]",
            when Array_Element      => "[0520]",
            when Parameterized_Type_Alias => "[1350]",
            when Zeroed_Value       => "[0540]",
            when Constrained_Composition => "[0660]",
            when Arena_Region       => "[0820]")
     with Post => Landin.Tokens.Is_Valid_Construct (Construct'Result);

   --  The type names above, spelled once.  A name that is not here is a
   --  name nothing in either document writes as a type, and resolution has
   --  already reported it as declared nowhere.
   --
   --  `arena` is here and not in the parser's word table for the reason
   --  this stage exists: `core/mem` declares a type of that name, so
   --  whether `arena` is the withdrawn builtin spelling is a question
   --  about what it resolved to and not about the bytes.
   type Refused_Type_Name is
     (Wide_Unsigned, Wide_Signed, Float_16, Arena_Handle);

   function Spelling (Item : Refused_Type_Name) return String
     is (case Item is
            when Wide_Unsigned => "u128",
            when Wide_Signed   => "i128",
            when Float_16      => "f16",
            when Arena_Handle  => "arena");

   function Refusal (Item : Refused_Type_Name) return Refused_Use
     is (case Item is
            when Wide_Unsigned
               | Wide_Signed   => Wide_Integer_Type,
            when Float_16      => Narrow_Float_Type,
            when Arena_Handle  => Arena_Region);

   procedure Report
     (Item    : Failure;
      Source  : Landin.Source.Source_Id;
      Where   : Landin.Source.Span;
      Message : String;
      Note    : String := "";
      Related : Landin.Provenance.Origin := Landin.Provenance.No_Origin;
      Because : String := "";
      Refused : Refused_Use := Struct_Value;
      Into    : in out Diagnostic_List);

private

   --  What each refused use is, which is what the second note [1830]
   --  promises says.
   function Standing (Item : Refused_Use) return Refusal_Standing
     is (case Item is
            --  D237 transfers u128, i128 and f16 to the Language evolution
            --  successor, whose trigger is a program that needs them.
            --  [0150] and [0170] are otherwise enabled.
            when Wide_Integer_Type
               | Narrow_Float_Type  => Transferred,
            --  D241 leaves each aggregate form its permanent source
            --  boundary: a value that needs a destination it was not
            --  given, a module image [1940] cannot fold, or a guard no
            --  enabled source reaches.
            when Struct_Value
               | Variant_Value
               | Array_Value
               | Array_Element
               | Zeroed_Value      => Recorded_Boundary,
            --  D135 fixed what an application of [1350]'s declaration may
            --  be: fully applied and positional.  An unapplied constructor
            --  or a malformed application is that rule's boundary.
            when Parameterized_Type_Alias => Recorded_Boundary,
            --  D236 records the composite, reference and generic positions
            --  as [0660]'s permanent source-form boundary: a constraint
            --  belongs to a scalar binding, parameter, return or
            --  conversion.
            when Constrained_Composition => Recorded_Boundary,
            --  D212 withdraws both forms, with explicit ordinary allocator
            --  migration guidance.
            when Arena_Region       => Withdrawn);

end Landin.Diagnostics.Checking;
