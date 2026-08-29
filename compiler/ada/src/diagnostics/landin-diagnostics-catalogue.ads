--  The diagnostic catalogue.
--
--  Every code the compiler can raise has a row here, and this is the only
--  place in `src/` where a code is written. A code with no row does not
--  compile: each column is an exhaustive case over Code_Name, so leaving one
--  out is a missing-case error rather than a warning.
--
--  Prose is deliberately absent. `L0003` is raised with two sentences today
--  -- a source that is missing and one that is unreadable -- because one
--  rule was violated and the difference between the two is wording. A table
--  of messages would either lie about that or split a code for a wording
--  reason, which is the worst reason to spend a stable identifier. The exact
--  bytes live in a fixture's golden; what a code requires of every one of
--  its occurrences lives here.
--
--  A code is a name, not an address. The bands below record where a code was
--  born, not which stage owns it: `L0010` is raised by the scanner today and
--  by the parser at R1.40. A retired code keeps its row, so its number can
--  never be handed to a different rule -- that is how "codes remain stable"
--  becomes a fact in a file rather than a promise in a paragraph.
--
--     L0001-L0009  the driver and the chassis
--     L0010-L0099  lexical, and the refusal of what is not enabled
--     L0100-L0199  reserved for R1.40's syntax failures
--     L0200-L0299  name resolution, assigned at R1.50
--     L0300-L0399  types and definite assignment, assigned at R1.60
--     L0400-L0499  deliberately unassigned; see below
--     L0500-L0599  the backend and its toolchain, assigned at R1.80

--  `L0400`-`L0499` is the band R1.70 would have taken and did not, and it
--  stays empty on purpose.  Malformed IR cannot be caused by a source
--  program: the frontend refuses every ill-formed one, and the lowering
--  refuses to run on a program that was refused.  So a verifier failure is
--  a `Landin.Compiler_Defect` and never a diagnostic, and a code here
--  would be a promise that some program can provoke it -- the promise
--  `landin.ads` forbids.  A later reader should not spend the band before
--  reading that argument.

package Landin.Diagnostics.Catalogue is

   type Code_Name is
     (
      --  The driver, assigned at R0.50 because a driver that cannot
      --  explain itself cannot be tested.
      No_Frontend,
      Unknown_Option,
      Unreadable_Source,
      Unknown_Target,
      --  Added at R1.80, when the driver first wrote a file.  It sits
      --  beside Unreadable_Source because it is the same rule from the
      --  other side, and a band records where a code was born.
      Unwritable_Output,
      --  The scanner, assigned at R1.30.
      Construct_Not_Enabled,
      Malformed_Integer,
      Unknown_Bytes,
      Unterminated_Comment,
      Unterminated_Literal,
      --  The parser, assigned at R1.40. One per rule of the grammar the
      --  parser can find broken, in the order the reader meets them:
      --  what was required and absent, then what was present and refused.
      Name_Expected,
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
      --  The resolver, assigned at R1.50.  Two rules and not more: a name
      --  declared twice in one scope, and a name used and never declared.
      Duplicate_Declaration,
      Unresolved_Name,
      --  The checker, assigned at R1.60.  Five rules: a literal no type
      --  holds, two types that must agree and do not, a name read before
      --  it is assigned, a place that may not be written, and a name used
      --  in a way the kernel does not enable.  Impossible_Operand joined
      --  them at R1.70, where [1950] was written: it is the operand half
      --  of what Literal_Out_Of_Range is the result half of.
      Literal_Out_Of_Range,
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
      --  The backend and its toolchain, assigned from R1.80 onwards.  None
      --  is about a frontend construct: two are the host failing to finish
      --  an accepted program, one is [1970]'s missing entry shape, one is a
      --  verified shape this backend cannot encode, and L0503 is retained
      --  after R2.30 retired the register-only argument limit.
      No_Toolchain,
      Toolchain_Failed,
      Entry_Point_Missing,
      Argument_Not_In_A_Register,
      Frame_Not_Addressable);

   --  Live, or kept so its number is never reused. A code is retired when
   --  the rule it names stops existing: `No_Frontend` retires when the
   --  frontend is wired to the driver.
   type Disposition is (Live, Retired);

   function Code (Of_Code : Code_Name) return Code_String
     is (case Of_Code is
            when No_Frontend           => "L0001",
            when Unknown_Option        => "L0002",
            when Unreadable_Source     => "L0003",
            when Unknown_Target        => "L0004",
            when Unwritable_Output     => "L0005",
            when Construct_Not_Enabled => "L0010",
            when Malformed_Integer     => "L0011",
            when Unknown_Bytes         => "L0012",
            when Unterminated_Comment  => "L0013",
            when Unterminated_Literal  => "L0014",
            when Name_Expected            => "L0100",
            when Type_Expected            => "L0101",
            when Expression_Expected      => "L0102",
            when Token_Expected           => "L0103",
            when Unclosed_Construct       => "L0104",
            when Assignment_In_Expression => "L0105",
            when Comparison_Chained       => "L0106",
            when Return_Carries_Value     => "L0107",
            when Public_On_Statement      => "L0108",
            when End_Name_Mismatch        => "L0109",
            when Stray_Token              => "L0110",
            when Nesting_Too_Deep         => "L0111",
            when Duplicate_Declaration    => "L0200",
            when Unresolved_Name          => "L0201",
            when Literal_Out_Of_Range     => "L0300",
            when Type_Mismatch            => "L0301",
            when Not_Definitely_Assigned  => "L0302",
            when Immutable_Target         => "L0303",
            when Unsupported_Use          => "L0304",
            when Not_Known_At_Compile_Time => "L0305",
            when Impossible_Operand        => "L0306",
            when Cyclic_Type_Alias         => "L0307",
            when Unresolved_Field          => "L0308",
            when Field_Named_Twice         => "L0309",
            when Field_Not_Given           => "L0310",
            when Variant_Case_Named_Twice  => "L0311",
            when Variant_Case_Not_Matched  => "L0312",
            when Recursive_Nominal_Value   => "L0313",
            when No_Toolchain              => "L0500",
            when Toolchain_Failed          => "L0501",
            when Entry_Point_Missing       => "L0502",
            when Argument_Not_In_A_Register => "L0503",
            when Frame_Not_Addressable      => "L0504");

   function Level (Of_Code : Code_Name) return Severity
     is (case Of_Code is
            when No_Frontend           => Error,
            when Unknown_Option        => Error,
            when Unreadable_Source     => Error,
            when Unknown_Target        => Error,
            when Unwritable_Output     => Error,
            when Construct_Not_Enabled => Error,
            when Malformed_Integer     => Error,
            when Unknown_Bytes         => Error,
            when Unterminated_Comment  => Error,
            when Unterminated_Literal  => Error,
            when Name_Expected .. Nesting_Too_Deep => Error,
            when Duplicate_Declaration => Error,
            when Unresolved_Name       => Error,
            when Literal_Out_Of_Range
               .. Recursive_Nominal_Value => Error,
            when No_Toolchain .. Frame_Not_Addressable => Error);

   --  Argument_Not_In_A_Register retired at R2.30: the internal scalar
   --  convention now places every argument after the sixth in an aligned
   --  stack run.
   function State (Of_Code : Code_Name) return Disposition
     is (case Of_Code is
            --  Retired at R1.40: the frontend is wired to the
            --  driver, so nothing raises this any more.  The row
            --  stays so its number can never be handed to
            --  another rule.
            when No_Frontend           => Retired,
            when Unknown_Option        => Live,
            when Unreadable_Source     => Live,
            when Unknown_Target        => Live,
            when Unwritable_Output     => Live,
            when Construct_Not_Enabled => Live,
            when Malformed_Integer     => Live,
            when Unknown_Bytes         => Live,
            when Unterminated_Comment  => Live,
            when Unterminated_Literal  => Live,
            when Name_Expected .. Nesting_Too_Deep => Live,
            when Duplicate_Declaration => Live,
            when Unresolved_Name       => Live,
            when Literal_Out_Of_Range
               .. Recursive_Nominal_Value => Live,
            when No_Toolchain .. Entry_Point_Missing => Live,
            when Argument_Not_In_A_Register => Retired,
            when Frame_Not_Addressable => Live);

   --  The rule the code enforces, in one line. Documentation, not prose a
   --  user reads: the message at the raise site is what a user reads.
   function Rule (Of_Code : Code_Name) return String
     is (case Of_Code is
            when No_Frontend           =>
               "a source was read and no frontend is wired to the driver",
            when Unknown_Option        =>
               "an option the driver does not define",
            when Unreadable_Source     =>
               "a source that is missing or cannot be read",
            when Unknown_Target        =>
               "a target no description names",
            when Unwritable_Output     =>
               "an output file that cannot be written",
            when Construct_Not_Enabled =>
               "[1830]: the tour describes this and the kernel omits it",
            when Malformed_Integer     =>
               "[1770]: a digit outside the base the prefix selected",
            when Unknown_Bytes         =>
               "[1750]: a run of bytes no rule spells",
            when Unterminated_Comment  =>
               "[1780]: a block comment that is never closed",
            when Unterminated_Literal  =>
               "[0260]: a quoted literal that is never closed",
            when Name_Expected         =>
               "[1760]: a name position holds something that is not a name",
            when Type_Expected         =>
               "[1790]: a type position holds no type the kernel enables",
            when Expression_Expected   =>
               "[1820]: an expression was required and none begins here",
            when Token_Expected        =>
               "[1810]: a terminal the production spells is absent",
            when Unclosed_Construct    =>
               "[1800]: a construct whose closing `end` never arrives",
            when Assignment_In_Expression =>
               "[0390]: assignment is a statement, never an expression",
            when Comparison_Chained    =>
               "[1820]: comparison takes at most one operator",
            when Return_Carries_Value  =>
               "[1810]: `return` carries no value; assign the named return",
            when Public_On_Statement   =>
               "[1740]: `public` rides on a declaration, not a statement",
            when End_Name_Mismatch     =>
               "[1800]: the name on `end` is not the name declared",
            when Stray_Token           =>
               "[1740]: a run of tokens beginning no declaration or"
               & " statement",
            when Nesting_Too_Deep      =>
               "an implementation limit on how deeply a construct nests",
            when Duplicate_Declaration =>
               "[1850]: one scope gives one name to one thing",
            when Unresolved_Name       =>
               "[1860]: a name used and declared in no visible scope",
            when Literal_Out_Of_Range  =>
               "a compile-time magnitude its context or target does not"
               & " hold",
            when Type_Mismatch         =>
               "[1890]: two types that must agree and do not",
            when Not_Definitely_Assigned =>
               "[1910]: a name read on a path that does not assign it",
            when Immutable_Target      =>
               "[1900]: a place that may not be written",
            when Unsupported_Use       =>
               "[1920]: a name used in a way the kernel does not enable",
            when Not_Known_At_Compile_Time =>
               "[1940]/D136: a value required before runtime that the"
               & " compiler's closed fold cannot produce",
            when Impossible_Operand    =>
               "[1950]: an operand the operation cannot take, where the"
               & " compiler knows it",
            when Cyclic_Type_Alias     =>
               "[1795]: a chain of aliases that reaches no type",
            when Unresolved_Field      =>
               "[0750]: a field a struct was not declared with",
            when Field_Named_Twice     =>
               "[0710]: a struct literal names a field at most once",
            when Field_Not_Given       =>
               "[0710]: every field is named or covered by `of`",
            when Variant_Case_Named_Twice =>
               "[1210]: a match names each variant case at most once",
            when Variant_Case_Not_Matched =>
               "[1210]: an exhaustive match names every variant case",
            when Recursive_Nominal_Value =>
               "D137: a nominal value layout cannot contain itself by value",
            when No_Toolchain          =>
               "[1550]: no assembler and linker for the target on this"
               & " host",
            when Toolchain_Failed      =>
               "[1550]: the platform assembler or linker refused what"
               & " was emitted",
            when Entry_Point_Missing   =>
               "[1970]: a hosted program with no"
               & " `public main: () -> (code: i32)`",
            when Argument_Not_In_A_Register =>
               "retired: the register-only internal calling limit",
            when Frame_Not_Addressable =>
               "a verified frame outside x86-64's signed displacement"
               & " encoding");

   ------------------------------------------------------------------
   --  What every occurrence of a code must carry
   --
   --  The row states the shape; the fixture states where. Both are checked,
   --  and neither is prose.
   ------------------------------------------------------------------

   --  Whether the diagnostic must name a source. The driver's own codes
   --  are raised before any file is read, so they must not.
   function Needs_Source (Of_Code : Code_Name) return Boolean
     is (case Of_Code is
            when No_Frontend           => True,
            when Unknown_Option        => False,
            when Unreadable_Source     => False,
            when Unknown_Target        => False,
            when Unwritable_Output     => False,
            when Construct_Not_Enabled => True,
            when Malformed_Integer     => True,
            when Unknown_Bytes         => True,
            when Unterminated_Comment  => True,
            when Unterminated_Literal  => True,
            when Name_Expected .. Nesting_Too_Deep => True,
            when Duplicate_Declaration => True,
            when Unresolved_Name       => True,
            when Literal_Out_Of_Range
               .. Recursive_Nominal_Value => True,
            --  None of the three is about a place in a file.  Two are
            --  the host failing to finish an accepted program, and the
            --  third is a declaration the module never made, which has
            --  no span by definition.
            when No_Toolchain .. Frame_Not_Addressable => False);

   --  Whether the primary span must cover at least one byte. An empty span
   --  points between two bytes, which is right for a missing token and
   --  wrong for a lexeme that is present and refused.
   function Needs_Non_Empty_Span (Of_Code : Code_Name) return Boolean
     is (case Of_Code is
            when No_Frontend           => False,
            when Unknown_Option        => False,
            when Unreadable_Source     => False,
            when Unknown_Target        => False,
            when Unwritable_Output     => False,
            when Construct_Not_Enabled => True,
            when Malformed_Integer     => True,
            when Unknown_Bytes         => True,
            when Unterminated_Comment  => False,
            when Unterminated_Literal  => True,
            when Name_Expected .. Unclosed_Construct => False,
            when Assignment_In_Expression .. Nesting_Too_Deep => True,
            --  A name that is duplicated or unknown is written down: there
            --  is a lexeme to point at, and it is the name itself.
            when Duplicate_Declaration => True,
            when Unresolved_Name       => True,
            --  Every one of these points at something a program wrote.
            when Literal_Out_Of_Range
               .. Recursive_Nominal_Value =>
               True,
            when No_Toolchain .. Frame_Not_Addressable => False);

   --  The admitted secondary-label interval. Every code except L0300 and
   --  L0306 has one exact count. Those two semantic rules point only at the
   --  direct defect when it is written there, but a substitution-dependent
   --  occurrence is primary at the application and may relate the template.
   function Minimum_Secondaries (Of_Code : Code_Name) return Natural
     is (case Of_Code is
            when Unterminated_Comment  => 1,
            when Unterminated_Literal  => 1,
            --  Each of these is only readable next to a second place: the
            --  opener that was never closed, the name that was declared,
            --  the first comparison of a chain, the return it may not
            --  carry a value for, the function the `public` is inside.
            when Type_Expected         => 1,
            when Expression_Expected   => 1,
            when Token_Expected        => 1,
            when Unclosed_Construct    => 1,
            when Comparison_Chained    => 1,
            when Return_Carries_Value  => 1,
            when Public_On_Statement   => 1,
            when End_Name_Mismatch     => 1,
            when Nesting_Too_Deep      => 1,
            --  The earlier declaration, which is the whole complaint and
            --  may be in another file.  An unresolved name has no second
            --  place by definition, which is why it asks for none.
            when Duplicate_Declaration => 1,
            when Unresolved_Name       => 0,
            --  A mismatch is only readable next to the place that stated
            --  the requirement, and an unwritable place next to its
            --  declaration. A direct literal or fold out of range has no
            --  second place: the type it did not fit is named in the
            --  sentence, because a defaulted literal [0200] has no
            --  annotation to point at. Maximum_Secondaries admits the
            --  template expression for a substitution-dependent fold.
            when Type_Mismatch         => 1,
            when Immutable_Target      => 1,
            when Not_Definitely_Assigned => 1,
            when Field_Named_Twice     => 1,
            when Variant_Case_Named_Twice => 1,
            when Recursive_Nominal_Value => 1,
            when Literal_Out_Of_Range  => 0,
            when Unsupported_Use       => 0,
            when Not_Known_At_Compile_Time => 0,
            --  A direct operand is written down and is the only place to
            --  point at: [1950] says the report names it and not the
            --  operator. Maximum_Secondaries admits the template operand
            --  when an application is the primary place.
            when Impossible_Operand    => 0,
            when others                => 0);

   function Maximum_Secondaries (Of_Code : Code_Name) return Natural
     is (case Of_Code is
            when Literal_Out_Of_Range | Impossible_Operand
               | Unsupported_Use => 1,
            when others => Minimum_Secondaries (Of_Code));

   --  How many notes. [1830] promises a diagnostic that names the construct
   --  and says which work enables it, which is two facts and so two notes.
   function Required_Notes (Of_Code : Code_Name) return Natural
     is (case Of_Code is
            when No_Frontend           => 1,
            when Construct_Not_Enabled => 2,
            when Malformed_Integer     => 1,
            when Unknown_Bytes         => 1,
            when Name_Expected .. Nesting_Too_Deep => 1,
            when Duplicate_Declaration => 1,
            when Unresolved_Name       => 1,
            when Literal_Out_Of_Range  => 1,
            when Type_Mismatch         => 1,
            when Not_Definitely_Assigned => 1,
            when Immutable_Target      => 1,
            --  [1830]'s two facts, the same two L0010 carries: which
            --  construct this is, and which work enables it.
            when Unsupported_Use       => 2,
            when Not_Known_At_Compile_Time => 1,
            when Impossible_Operand    => 1,
            when Cyclic_Type_Alias     => 1,
            when Unresolved_Field      => 1,
            when Field_Named_Twice     => 1,
            when Field_Not_Given       => 1,
            when Variant_Case_Named_Twice => 1,
            when Variant_Case_Not_Matched => 1,
            when Recursive_Nominal_Value => 1,
            --  The one diagnostic here a user is stuck on rather than
            --  informed by, so it owes them the way out: which program
            --  was looked for, and how to name another.
            when No_Toolchain          => 1,
            when others                => 0);

   function Count return Natural
     is (Code_Name'Pos (Code_Name'Last) - Code_Name'Pos (Code_Name'First) + 1);

   --  Which name a code string belongs to, for a test that starts from the
   --  number. Raises Compiler_Defect on a code no row holds, because a code
   --  outside the catalogue is the defect this package exists to prevent.
   function Named (Text : Code_String) return Code_Name;

end Landin.Diagnostics.Catalogue;
