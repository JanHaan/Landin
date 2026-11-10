--  The diagnostic catalogue.
--
--  Every code the compiler can raise has a row here, and this is the only
--  place in `src/` where a code is written. A code with no row does not
--  compile: the rows are one aggregate over Code_Name with no `others`, so
--  leaving a code or one of its columns out is an error rather than a
--  warning.
--
--  Prose is deliberately absent. `L0003` is raised with two sentences today
--  -- a source that is missing and one that is unreadable -- because one
--  rule was violated and the difference between the two is wording. A table
--  of messages would either lie about that or split a code for a wording
--  reason, which is the worst reason to spend a stable identifier. The exact
--  bytes live in a fixture's golden; what a code requires of every one of
--  its occurrences lives here.
--
--  A fix is data as well: whether an occurrence may carry one is a column,
--  like how many notes it requires, and the fix's own message is written
--  where it is built, in Landin.Diagnostics.Fixes, for the reason above.
--  What a code means to a person is written in `docs/diagnostics.md`, and
--  `refine explain` prints it from Landin.Diagnostics.Explanations, which is
--  generated from that page; a code without a section does not compile.
--
--  A warning is a row at warning level, and D251 is what admits one: the
--  compiler's judgement and never the language's, raised only on a program
--  it accepts.  An exact fix is offered where an edit is safe; otherwise
--  the observation stands alone.  Invocation policy may suppress or deny
--  warnings without changing language legality.  Its number is in the
--  band of the stage that found it, like
--  every other code; nothing about a number says it is a warning.
--
--  A code is a name, not an address. The bands below record where a code was
--  born, not which stage owns it: `L0010` began in lexical refusal and is
--  now raised only by the parser. A retired code keeps its row, so its
--  number can never be handed to a different rule. This makes stable codes
--  a fact in a file rather than a promise in a paragraph.
--
--     L0001-L0009  the driver and the chassis
--     L0010-L0099  lexical, and the refusal of what is not enabled
--     L0100-L0199  the parser's syntax failures
--     L0200-L0299  name resolution
--     L0300-L0399  types and definite assignment
--     L0400-L0499  deliberately unassigned; see below
--     L0500-L0599  the backend and its toolchain
--     L0600-       codes born once the bands above were spent, of any
--                  stage
--
--  Adding a code takes these steps, and the full `python3 check.py` names
--  the one left out:
--
--  1. An enumeral in Code_Name, in its band's group, and its row in Table
--     below.  Every column of a code is in that one row.
--  2. A section headed by the code in `docs/diagnostics.md`, then
--     `python3 check.py --catalogue`, which generates the explanation the
--     compiler carries.  A code with no section does not compile.
--  3. The raise.  A stage reports through its package --
--     Landin.Diagnostics.Modules, Resolution, Syntactic or Checking --
--     whose Failure is derived from Code_Name and so names the code
--     already; the scanner maps a Landin.Tokens.Fault_Kind in
--     Landin.Diagnostics.Lexical.Code_For, and `refine svd` a device fault
--     in Landin.Commands.Devices.Code_For.  The driver and the backend build
--     theirs from the row.  Each reporting package holds what it builds to
--     the row.
--  4. The evidence the row's Shown_By names: a negative fixture whose
--     `codes:` lists the code, a driver or command case that writes the
--     code, or the unit case at an implementation limit.  A code that
--     admits a fix also needs a fixture whose `fixed:` applies one.
--  5. `python3 check.py --generate`, which regenerates the reading copy and
--     the diagnostic matrix; the matrix finds the code's emitters by its
--     name anywhere in `src/`.
--  6. A secondary-label interval wider than one count joins the six the
--     catalogue suite's `rows are whole` names.

--  `L0400`-`L0499` is the band the IR and its verifier would have taken and
--  did not, and it stays empty on purpose.  Malformed IR cannot be caused by a
--  source program: the frontend refuses every ill-formed one, and the lowering
--  refuses to run on a program that was refused.  So a verifier failure is
--  a `Landin.Compiler_Defect` and never a diagnostic, and a code here
--  would be a promise that some program can provoke it -- the promise
--  `landin.ads` forbids.  A later reader should not spend the band before
--  reading that argument.

--  L0301 once covered every checker refusal that had no row of its own,
--  so its explanation, which says two types disagree, described the wrong
--  rule for most of its reports.  Each family of refusals with its own
--  rule and repair now has a row (L0327 onward), and L0301 keeps only a
--  value whose type is not the one its context or operation requires.  A
--  new checker refusal that is not that gets a row rather than L0301.

package Landin.Diagnostics.Catalogue is

   type Code_Name is
     (
      --  The driver, assigned first because a driver that cannot explain
      --  itself cannot be tested.
      No_Frontend,
      Unknown_Option,
      Unreadable_Source,
      Unknown_Target,
      --  Added when the driver first wrote a file.  It sits beside
      --  Unreadable_Source because it is the same rule from the other side,
      --  and a band records where a code was born.
      Unwritable_Output,
      Module_Not_Found,
      Module_Directory_Invalid,
      Module_Unavailable_For_Target,
      --  D366: a project root holds a library namespace the library
      --  supplies instead.  A warning: the program is compiled as D275
      --  says, and the reader is told which `core` it was compiled with.
      Root_Holds_Library_Module,
      --  D563: the first directory an import names holds no source, and a
      --  later root's directory of the same path holds the module.
      Empty_Module_Hides_Root,
      --  D1055: an import selects the directory of a source the request
      --  named as the entry module.
      Import_Of_Named_Entry,
      --  `refine fmt --check`: a source that parses and is not in the
      --  layout.  Whose rule is D252, not a language rule, and no program
      --  is refused for it.
      Not_Formatted,
      --  `--level=` names no CPU feature level of the selected target's
      --  family.  A sibling of Unknown_Target, and no program is refused
      --  for it.
      Unknown_Level,
      --  The scanner.
      Construct_Not_Enabled,
      Malformed_Integer,
      Unknown_Bytes,
      Unterminated_Comment,
      Unterminated_Literal,
      --  The parser.  One per rule of the grammar the parser can find broken,
      --  in the order the reader meets them: what was required and absent,
      --  then what was present and refused.
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
      Positional_After_Named,
      --  Resolution owns duplicate, unknown and inaccessible names, plus
      --  D202's reserved tool namespaces and unavailable tool references.
      Duplicate_Declaration,
      Unresolved_Name,
      Inaccessible_Name,
      Reserved_Tool_Name,
      --  The checker.  Its rows cover type agreement, definite
      --  assignment, references, layouts and the other semantic rules the
      --  kernel can find.  Impossible_Operand joined them with the IR,
      --  where [1950] was written: it is the operand half of what
      --  Literal_Out_Of_Range is the result half of.  Concepts and
      --  conformances add the rows below.
      Literal_Out_Of_Range,
      --  Tentative L0398: [0740]'s known whole-image write policy refusal.
      Register_Reserved_Bits,
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
      --  The conformance foundation.  These are checker failures: duplicate
      --  whole-program keys, a missing formal conformance, and an attempt to
      --  provide a compiler-owned conformance.
      Conformance_Collision,
      Unsatisfied_Constraint,
      Compiler_Conformance_Reserved,
      --  D161 enables [0260]'s byte-slice context and gives malformed
      --  [0270] escapes their own source-facing rule.
      Malformed_Text_Literal,
      --  D162's decimal spelling has a complete optional exponent, and
      --  D166's hexadecimal spelling has a complete required exponent.
      Malformed_Float_Literal,
      --  D163's character literal is exactly one Unicode scalar value.
      Malformed_Character_Literal,
      --  D164's raw literal has matching delimiters, UTF-8 source and one
      --  exact indentation prefix.
      Malformed_Raw_Literal,
      --  D247's storage bounds: too many declarations in a routine or
      --  fields in a struct body or variant case. An implementation limit,
      --  like L0111, and the checker's because counting what a routine
      --  declares needs the resolver's scopes.
      Size_Limit_Exceeded,
      Invalid_Option_Declaration,
      Invalid_Tool_Directive,
      --  The first warning: a judgement the language does not make and the
      --  compiler does, with the repair that settles it (D251).  It is the
      --  checker's because the checker is what knows whether `mut` was
      --  needed, and a band records where a code was born, so no band of
      --  its own says that a number is a warning.
      Mutable_Never_Written,
      --  Rules once reported as L0301.  Each is a family whose reports
      --  share one rule and one kind of repair, which is what an
      --  explanation can state; the report's note still names the exact
      --  paragraph.
      Call_Argument_Match,
      Zero_Image_Unavailable,
      Error_Contract_Violated,
      Assembly_Block_Contract,
      Result_Use,
      Control_Value,
      Match_Arm_Form,
      Aggregate_Form,
      Pointer_Union_Use,
      Packed_Image,
      Place_Required,
      Type_Declaration_Form,
      Signature_Form,
      Generic_Deduction,
      Conformance_Form,
      Erased_Contract,
      Noreturn_Contract,
      Memory_Contract,
      Machine_Entry_Contract,
      Foreign_Boundary,
      Linkage_Contract,
      Traversal_Source,
      --  D542-D547: a device description, and a placement in a region of
      --  the one it selects.  Configuration finds all but the last.
      Invalid_Description_Directive,
      Description_Structure,
      Description_Layout,
      Description_Core_Mismatch,
      Boot_Kind_Reserved,
      Region_Placement,
      No_Description,
      --  D587: a description's second-stage boot routine.  Configuration
      --  finds all five.
      Boot_Stage_Form,
      Boot_Stage_Outside,
      Boot_Stage_Unwanted,
      Boot_Stage_Repeated,
      Boot_Stage_Missing,
      --  D615: a description's float unit.  Configuration finds both.
      Float_Unit_Unsupported,
      Float_Unit_Level,
      --  D971: a description's cache.  Configuration finds both.
      Cache_Unsupported,
      Cache_Line_Wrong,
      --  D653: a stage the reset vector enters before compiler-owned reset.
      Reset_Stage_Return,
      Reset_Stage_Stack,
      --  D681, D683: a boot kind another family's ROM reads, and the ESP
      --  chip's facts without their image or the image without them.
      Boot_Kind_Family,
      ESP_Image_Facts,
      --  D688: RAM code in a profile with no RAM code runs in.
      RAM_Code_Unplaceable,
      --  D251 also admits removing a whole unused, effect-free local.
      Unused_Pure_Local,
      --  D760: an untyped float literal whose f32 rounding changes the
      --  integer a conversion gives.
      Literal_Rounded_Away,
      --  D949: text made of bytes with no scan outside `unchecked`.
      Unvalidated_Text_Checked,
      --  D1077: a bidirectional control in a comment or a literal.
      Bidirectional_Control,
      --  The backend and its toolchain.  None is about a frontend
      --  construct: two are the host failing to finish an accepted
      --  program, one is [1970]'s missing entry shape, one is a verified
      --  shape this backend cannot encode, and L0503 is retained after the
      --  internal calling convention retired the register-only argument
      --  limit.
      No_Toolchain,
      Toolchain_Failed,
      Entry_Point_Missing,
      Argument_Not_In_A_Register,
      Frame_Not_Addressable,
      Image_Budget_Exceeded,
      Panic_Contract_Invalid,
      Firmware_Frame_Exceeds_Stack,
      Handler_Exceeds_Stack_Margin,
      Library_Not_Found,
      --  D546's post-link contract.
      Linker_Script_Contract,
      --  D588: the assembled second stage, read from its object.
      Boot_Stage_Object,
      --  D638: the assembled image block, read from its object.
      Image_Block_Object,
      --  D685: the ESP application image refine writes, read back.
      ESP_Image_Object,
      --  D555-D558: `refine svd`, which reads a vendor's SVD and a
      --  selection policy and replaces the modules it generates.  No
      --  program is refused for any of them.
      Svd_Malformed,
      Svd_Policy_Invalid,
      Svd_Input_Mismatch,
      Svd_Form_Unsupported,
      Svd_Device_Inconsistent,
      Svd_Not_Found,
      Svd_Output_Refused,
      --  D820: `refine bindings`, which binds C headers for Landin.  No
      --  program is refused for any of them.
      Bindings_Policy_Invalid,
      Bindings_Clang_Refused,
      Bindings_Declaration_Refused,
      Bindings_Output_Refused,
      --  D924: a firmware image linked with C archives that holds what
      --  compiler-owned startup cannot honour, read after the link.
      Firmware_Foreign_Section);

   --  Live, or kept so its number is never reused. A code is retired when
   --  the rule it names stops existing: `No_Frontend` retired when the
   --  frontend was wired to the driver.
   type Disposition is (Live, Retired);

   --  Whether an occurrence may carry a fix, which the text renders as a
   --  `help` line and an editor offers as an action.  Must_Fix is a code
   --  whose every occurrence has one; No_Fix is a code a stage may not
   --  attach one to, because nothing it could rewrite is known to be what
   --  the program meant.  Landin.Stages.Report holds every diagnostic to
   --  this row as it joins a compilation's report.
   type Fix_Admission is (No_Fix, May_Fix, Must_Fix);

   --  What shows a live code is raised, which check.py holds the
   --  diagnostic matrix to.  Negative_Fixture is a program the code
   --  refuses, a negative fixture whose `codes:` names it.  Invocation is
   --  a code no source is refused with -- a command line, a host, a link
   --  or an SVD -- shown by a driver, command or end-to-end case.
   --  Implementation_Limit is met only by a program too large to keep in
   --  the corpus, shown by the unit case that generates one at and past
   --  the limit.  A retired row keeps what showed it when it was live.
   type Evidence is (Negative_Fixture, Invocation, Implementation_Limit);

   type Rule_Text is not null access constant String;

   --  One row per code, and every column of it in one place.
   type Row is record
      --  The stable identifier, unique to the row.
      Code     : Code_String;
      --  Stage warnings do not refuse; invocation policy is separate.  A
      --  warning is enabled by default; one that is not would add a column.
      Level    : Severity;
      State    : Disposition;
      --  Whether the diagnostic must name a source.  File-independent
      --  driver failures need none; source-attached failures do.
      Source   : Boolean;
      --  Whether the primary span must cover at least one byte.  An empty
      --  span points between two bytes, which is right for a missing token
      --  and wrong for a lexeme that is present and refused.
      Bytes    : Boolean;
      --  The admitted secondary-label interval, Least .. Most.  Every code
      --  except L0201, L0300, L0304, L0305, L0306 and L0325 has one exact
      --  count, and the catalogue suite's `rows are whole` names those six:
      --  a new code whose interval is wider joins its list.
      Least    : Natural;
      Most     : Natural;
      --  How many notes every occurrence carries.
      Notes    : Natural;
      --  Whether an occurrence may carry one note after those: the route,
      --  the form to write instead, which a code whose notes are fixed
      --  facts would otherwise have to write into its message (D761).
      Route    : Boolean;
      Fixes    : Fix_Admission;
      Shown_By : Evidence;
      --  The rule the code enforces, in one line.  Documentation, not prose
      --  a user reads: the message at the raise site is what a user reads.
      Rule     : Rule_Text;
   end record;

   function "+" (Text : String) return Rule_Text is (new String'(Text));

   --  The catalogue.  A named aggregate with no `others`, so a code with
   --  no row, or a row with a column left out, does not compile.  The
   --  rows run in Code_Name's order.
   Table : constant array (Code_Name) of Row :=
     [
      --  Retired when the frontend was wired to the driver, so nothing raises
      --  this any more. It keeps its original source-attached shape, and the
      --  row stays so its number can never be handed to another rule.
      No_Frontend =>
        (Code => "L0001", Level => Error, State => Retired,
         Source => True, Bytes => False,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Invocation,
         Rule => +"a source was read and no frontend is wired to the driver"),
      Unknown_Option =>
        (Code => "L0002", Level => Error, State => Live,
         Source => False, Bytes => False,
         Least => 0, Most => 0, Notes => 0, Route => False,
         Fixes => No_Fix, Shown_By => Invocation,
         Rule => +"an option or argument the driver does not define"),
      Unreadable_Source =>
        (Code => "L0003", Level => Error, State => Live,
         Source => False, Bytes => False,
         Least => 0, Most => 0, Notes => 0, Route => False,
         Fixes => No_Fix, Shown_By => Invocation,
         Rule => +"a source that is missing or cannot be read"),
      Unknown_Target =>
        (Code => "L0004", Level => Error, State => Live,
         Source => False, Bytes => False,
         Least => 0, Most => 0, Notes => 0, Route => False,
         Fixes => No_Fix, Shown_By => Invocation,
         Rule => +"a target no description names"),
      Unwritable_Output =>
        (Code => "L0005", Level => Error, State => Live,
         Source => False, Bytes => False,
         Least => 0, Most => 0, Notes => 0, Route => False,
         Fixes => No_Fix, Shown_By => Invocation,
         Rule => +"an output file that cannot be written"),
      --  [1420]'s import, offered the module directories it is near.
      Module_Not_Found =>
        (Code => "L0006", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => May_Fix, Shown_By => Negative_Fixture,
         Rule => +("[1420]: no ordered import root contains the requested"
                   & " module")),
      Module_Directory_Invalid =>
        (Code => "L0007", Level => Error, State => Live,
         Source => False, Bytes => False,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[1410], [1420]: a module directory is invalid or"
                   & " unreadable")),
      Module_Unavailable_For_Target =>
        (Code => "L0015", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("D267: an imported source namespace is unavailable for"
                   & " the target")),
      Root_Holds_Library_Module =>
        (Code => "L0016", Level => Warning, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("D275: a project root holds a module the compiler's"
                   & " library supplies instead")),
      Empty_Module_Hides_Root =>
        (Code => "L0532", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("D563: an import's first directory holds no source and a"
                   & " later root holds its module")),
      Import_Of_Named_Entry =>
        (Code => "L0616", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("D1055: an import selects the directory of a source the"
                   & " request named as the entry module")),
      --  The first line out of the layout, which may be one whose only fault
      --  is its missing line end, and so empty; the note is what a reader runs
      --  to put the file right.
      Not_Formatted =>
        (Code => "L0008", Level => Error, State => Live,
         Source => True, Bytes => False,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Invocation,
         Rule => +("D252: a source `refine fmt --check` finds out of the"
                   & " layout")),
      --  L0008 and L0009 refuse no program: their evidence is the driver cases
      --  that check a file out of the layout and name a level another family
      --  has.
      Unknown_Level =>
        (Code => "L0009", Level => Error, State => Live,
         Source => False, Bytes => False,
         Least => 0, Most => 0, Notes => 0, Route => False,
         Fixes => No_Fix, Shown_By => Invocation,
         Rule => +("D255: a CPU feature level the selected target does not"
                   & " have")),
      --  [1830] promises a diagnostic that names the construct and says what
      --  it is, which is two facts and so two notes.
      Construct_Not_Enabled =>
        (Code => "L0010", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 2, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +"[1830]: the tour describes this and the kernel omits it"),
      Malformed_Integer =>
        (Code => "L0011", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[1770]: an integer with missing digits, misplaced"
                   & " underscores, an invalid base digit, or an adjacent"
                   & " name")),
      Unknown_Bytes =>
        (Code => "L0012", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[1750]/[1760]: a run of bytes no rule spells, or a word"
                   & " with a capital")),
      Unterminated_Comment =>
        (Code => "L0013", Level => Error, State => Live,
         Source => True, Bytes => False,
         Least => 1, Most => 1, Notes => 0, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +"[1780]: a block comment that is never closed"),
      Unterminated_Literal =>
        (Code => "L0014", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 1, Most => 1, Notes => 0, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[0250]/[0260]/[0280]: a quoted or raw literal that is"
                   & " never closed")),
      Name_Expected =>
        (Code => "L0100", Level => Error, State => Live,
         Source => True, Bytes => False,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => May_Fix, Shown_By => Negative_Fixture,
         Rule => +("[1760]: a name position holds something that is not a"
                   & " name")),
      --  The parser's absences point between two bytes. Each of these is only
      --  readable next to a second place: the opener that was never closed,
      --  the name that was declared, the first comparison of a chain, the
      --  return it may not carry a value for, the function the `public` is
      --  inside. A keyword that was required and a name near it written, and
      --  D261's smallest repair of a refused statement, are offered as fixes.
      Type_Expected =>
        (Code => "L0101", Level => Error, State => Live,
         Source => True, Bytes => False,
         Least => 1, Most => 1, Notes => 1, Route => False,
         Fixes => May_Fix, Shown_By => Negative_Fixture,
         Rule => +"[1790]: a type position holds no type the kernel enables"),
      Expression_Expected =>
        (Code => "L0102", Level => Error, State => Live,
         Source => True, Bytes => False,
         Least => 0, Most => 1, Notes => 1, Route => False,
         Fixes => May_Fix, Shown_By => Negative_Fixture,
         Rule => +"[1820]: an expression was required and none begins here"),
      Token_Expected =>
        (Code => "L0103", Level => Error, State => Live,
         Source => True, Bytes => False,
         Least => 0, Most => 1, Notes => 1, Route => False,
         Fixes => May_Fix, Shown_By => Negative_Fixture,
         Rule => +"[1810]: a terminal the production spells is absent"),
      Unclosed_Construct =>
        (Code => "L0104", Level => Error, State => Live,
         Source => True, Bytes => False,
         Least => 1, Most => 1, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +"[1800]: a construct whose closing `end` never arrives"),
      --  [0390]'s `=` inside an expression, offered `==`.
      Assignment_In_Expression =>
        (Code => "L0105", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => May_Fix, Shown_By => Negative_Fixture,
         Rule => +"[0390]: assignment is a statement, never an expression"),
      Comparison_Chained =>
        (Code => "L0106", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 1, Most => 1, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +"[1820]: comparison takes at most one operator"),
      Return_Carries_Value =>
        (Code => "L0107", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 1, Most => 1, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[1810]: `return` carries no value; assign the named"
                   & " return")),
      Public_On_Statement =>
        (Code => "L0108", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 1, Most => 1, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +"[1740]: `public` rides on a declaration, not a statement"),
      --  [1800]'s closing name, which can only be the declared one.
      End_Name_Mismatch =>
        (Code => "L0109", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 1, Most => 1, Notes => 1, Route => False,
         Fixes => May_Fix, Shown_By => Negative_Fixture,
         Rule => +"[1800]: the name on `end` is not the name declared"),
      Stray_Token =>
        (Code => "L0110", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => May_Fix, Shown_By => Negative_Fixture,
         Rule => +("[1740]: a run of tokens beginning no declaration or"
                   & " statement")),
      --  An implementation limit, met only by a program too large to keep in
      --  the corpus, so its owner is the unit case that generates one at and
      --  past the limit.
      Nesting_Too_Deep =>
        (Code => "L0111", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 1, Most => 1, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Implementation_Limit,
         Rule => +"an implementation limit on how deeply a construct nests"),
      Positional_After_Named =>
        (Code => "L0112", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[0980]: a positional call argument precedes every named"
                   & " argument")),
      --  A name that is duplicated or unknown is written down: there is a
      --  lexeme to point at, and it is the name itself. The earlier
      --  declaration is the whole complaint and may be in another file.
      Duplicate_Declaration =>
        (Code => "L0200", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 1, Most => 1, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +"[1850]: one scope gives one name to one thing"),
      --  An unresolved name has no second place by definition, and [1860]'s
      --  misspelling is offered the names it is near. D381: a qualified name
      --  whose prefix reached a local that hides an import points at that
      --  local, the one second place an unresolved name can have.
      Unresolved_Name =>
        (Code => "L0201", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 1, Notes => 1, Route => False,
         Fixes => May_Fix, Shown_By => Negative_Fixture,
         Rule => +"[1860]: a name used and declared in no visible scope"),
      Inaccessible_Name =>
        (Code => "L0202", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 1, Most => 1, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[1410]: a module-internal declaration used across"
                   & " modules")),
      Reserved_Tool_Name =>
        (Code => "L0203", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[1560]: a builtin tool namespace binding or use is"
                   & " unavailable")),
      --  Every checker row points at something a program wrote. A direct
      --  literal or fold out of range has no second place: the type it did not
      --  fit is named in the sentence, because a defaulted literal [0200] has
      --  no annotation to point at. A substitution-dependent fold is primary
      --  at the application and may relate the template expression.
      Literal_Out_Of_Range =>
        (Code => "L0300", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 1, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("a compile-time magnitude its context or target does not"
                   & " hold")),
      Register_Reserved_Bits =>
        (Code => "L0398", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[0740]: a known register image violates its reserved-bit"
                   & " write policy")),
      --  A mismatch is only readable next to the place that stated the
      --  requirement.
      Type_Mismatch =>
        (Code => "L0301", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 1, Most => 1, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[1890]: a value's type is not the one its context or"
                   & " operation requires")),
      Not_Definitely_Assigned =>
        (Code => "L0302", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 1, Most => 1, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[1910], [0910], [0930]: a place unassigned at a read or"
                   & " exit")),
      --  An unwritable place is only readable next to its declaration, and
      --  [1900]'s written binding is offered `mut`.
      Immutable_Target =>
        (Code => "L0303", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 1, Most => 1, Notes => 1, Route => False,
         Fixes => May_Fix, Shown_By => Negative_Fixture,
         Rule => +"[1900]: a place that may not be written"),
      --  [1830]'s two facts, the same two L0010 carries: which construct this
      --  is, and what it is. A substitution-dependent use may relate the
      --  template, and a refusal that knows the form to write instead says
      --  so in a third note (D761).
      Unsupported_Use =>
        (Code => "L0304", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 1, Notes => 2, Route => True,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[1830]: a known form used where the language does not"
                   & " permit it")),
      --  A module value of a range subtype has bounds to point at, and an
      --  erased pair has the site that asked for the image.
      Not_Known_At_Compile_Time =>
        (Code => "L0305", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 1, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[1940]/D136/D202: a required static value or initial"
                   & " image that the compiler cannot establish before"
                   & " runtime")),
      --  A direct operand is written down and is the only place to point at:
      --  [1950] says the report names it and not the operator. The template
      --  operand is admitted when an application is the primary place.
      Impossible_Operand =>
        (Code => "L0306", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 1, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[1950]: an operand the operation cannot take, where the"
                   & " compiler knows it")),
      Compile_Time_Assertion_Failed =>
        (Code => "L0324", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +"[1510]: a compile-time assertion is false"),
      Cyclic_Type_Alias =>
        (Code => "L0307", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +"[1795]: a chain of aliases that reaches no type"),
      --  [0750]'s field by name, offered the fields it is near.
      Unresolved_Field =>
        (Code => "L0308", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => May_Fix, Shown_By => Negative_Fixture,
         Rule => +"[0750]: a field a struct was not declared with"),
      Field_Named_Twice =>
        (Code => "L0309", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 1, Most => 1, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[0670]/[0710]/D74/D76: each field is named at most once"
                   & " in a struct declaration or literal, or a variant case"
                   & " declaration or construction")),
      Field_Not_Given =>
        (Code => "L0310", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[0710]/D76: every field in a struct literal or variant"
                   & " case construction is named or covered by `of`")),
      Variant_Case_Named_Twice =>
        (Code => "L0311", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 1, Most => 1, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +"[1210]: a match names each variant case at most once"),
      Variant_Case_Not_Matched =>
        (Code => "L0312", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +"[1210]: an exhaustive match names every variant case"),
      Recursive_Nominal_Value =>
        (Code => "L0313", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 1, Most => 1, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("D137: a nominal value layout cannot contain itself by"
                   & " value")),
      Reference_Escapes =>
        (Code => "L0314", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 1, Most => 1, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[0770]/[0780]: retention requires live storage and"
                   & " permission from the reference's origin")),
      Borrowed_Place =>
        (Code => "L0315", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 1, Most => 1, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[0800]/[0830]: a live derived view keeps its source"
                   & " still")),
      Return_Sources_Disagree =>
        (Code => "L0316", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 1, Most => 1, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[0790]: a returned reference derives from exactly its"
                   & " declared source parameters")),
      Conformance_Collision =>
        (Code => "L0317", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 1, Most => 1, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +"a whole-program conformance key has two declarations"),
      Unsatisfied_Constraint =>
        (Code => "L0318", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 1, Most => 1, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("a concrete type actual lacks the required concept"
                   & " conformance")),
      Compiler_Conformance_Reserved =>
        (Code => "L0319", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("a user attempts to declare the compiler-owned concept or"
                   & " one of its supplied conformances")),
      Malformed_Text_Literal =>
        (Code => "L0320", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[0270] [1750]: a text literal contains a malformed"
                   & " escape or invalid source encoding")),
      Malformed_Float_Literal =>
        (Code => "L0321", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[0210] [0220] [0230] [1770]: a float has a complete"
                   & " fraction and exponent when required, and ends before"
                   & " a name")),
      Malformed_Character_Literal =>
        (Code => "L0322", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[0250] [0270]: a character literal spells exactly one"
                   & " Unicode scalar value")),
      Malformed_Raw_Literal =>
        (Code => "L0323", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[0280] [1750]: raw content is UTF-8 and every nonblank"
                   & " line has the closing delimiter's indentation")),
      --  An implementation limit (D247): a routine over the bound is its name
      --  alone; a struct or case over it points at its first unheld field and
      --  relates the body that holds it.
      Size_Limit_Exceeded =>
        (Code => "L0325", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 1, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Implementation_Limit,
         Rule => +("D247: an implementation limit on declarations in a"
                   & " routine or fields in a struct body or variant case")),
      Invalid_Option_Declaration =>
        (Code => "L0390", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[1530]/D202: an option must be unconditional, have an"
                   & " available name and use a supported scalar type")),
      Invalid_Tool_Directive =>
        (Code => "L0391", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[1510]/[1590]/D202: a tool directive needs one argument;"
                   & " linker.library needs a quoted portable library name")),
      --  D251: the judgement is the compiler's and not the language's, and the
      --  note says so; the observation is separate from a safe source edit.
      Mutable_Never_Written =>
        (Code => "L0326", Level => Warning, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => May_Fix, Shown_By => Negative_Fixture,
         Rule => +"D251: a local declared `mut` that nothing writes"),
      --  [0980]'s argument label, offered the parameters it is near. The row
      --  admits a fix; only that one occurrence offers one.
      Call_Argument_Match =>
        (Code => "L0327", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 1, Most => 1, Notes => 1, Route => False,
         Fixes => May_Fix, Shown_By => Negative_Fixture,
         Rule => +("[1920]/D138: call arguments match the parameters and the"
                   & " callee's static formals")),
      Zero_Image_Unavailable =>
        (Code => "L0328", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 1, Most => 1, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[0540]: zeroed or an implicit initializer has no"
                   & " complete zero image")),
      Error_Contract_Violated =>
        (Code => "L0329", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 1, Most => 1, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[0940]/[0960]: failures obey the declared error set and"
                   & " call handling")),
      Assembly_Block_Contract =>
        (Code => "L0330", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 1, Most => 1, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[1630]/[1990]: assembly operands, registers and template"
                   & " slots obey the block contract")),
      --  D376: a value after a `none` call's `else`, offered `none`.
      Result_Use =>
        (Code => "L0331", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 1, Most => 1, Notes => 1, Route => False,
         Fixes => May_Fix, Shown_By => Negative_Fixture,
         Rule => +("[1020]/[1930]/[0990]: a call's results are used,"
                   & " discarded or bound as the signature allows")),
      Control_Value =>
        (Code => "L0332", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 1, Most => 1, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[1180]/[1190]/D124: a break carries a value exactly when"
                   & " its target needs one; value-producing fallthroughs"
                   & " supply one")),
      Match_Arm_Form =>
        (Code => "L0333", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 1, Most => 1, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[1210]/[0480]/[0640]: each match arm names a case of its"
                   & " subject in an admitted form")),
      Aggregate_Form =>
        (Code => "L0334", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 1, Most => 1, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[0700]/[0720]: struct, variant and array values are"
                   & " built and used in their admitted forms")),
      Pointer_Union_Use =>
        (Code => "L0335", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 1, Most => 1, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[0480]: a pointer union is matched before its pointer is"
                   & " read")),
      Packed_Image =>
        (Code => "L0336", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 1, Most => 1, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[0730]: a packed image is used through its fields and"
                   & " declared layout")),
      Place_Required =>
        (Code => "L0337", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 1, Most => 1, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[0430]/[0900]/[0910]: an operation needing a distinct"
                   & " addressable place lacks one")),
      Type_Declaration_Form =>
        (Code => "L0338", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 1, Most => 1, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[1795]/[1350]: a type position or declaration is not"
                   & " well formed")),
      Signature_Form =>
        (Code => "L0339", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 1, Most => 1, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[0790]/[0980]/[0990]/D192: a written signature is not"
                   & " well formed")),
      Generic_Deduction =>
        (Code => "L0340", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 1, Most => 1, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("D138: a generic call deduces and instantiates one"
                   & " concrete routine")),
      Conformance_Form =>
        (Code => "L0341", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 1, Most => 1, Notes => 1, Route => False,
         Fixes => May_Fix, Shown_By => Negative_Fixture,
         Rule => +("[1230]-[1270]: a concept or conformance declaration is"
                   & " not well formed")),
      Erased_Contract =>
        (Code => "L0342", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 1, Most => 1, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[1370]-[1390]/D145-D147: an `any` value or dispatch"
                   & " outside its erased contract")),
      Noreturn_Contract =>
        (Code => "L0343", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 1, Most => 1, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[0890]: a noreturn routine is infallible and never"
                   & " returns")),
      Memory_Contract =>
        (Code => "L0344", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 1, Most => 1, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[1620]/D227: a memory intrinsic outside its explicit"
                   & " contract")),
      Machine_Entry_Contract =>
        (Code => "L0345", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 1, Most => 1, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[1570]: an interrupt or naked routine outside its"
                   & " machine-entry contract")),
      Foreign_Boundary =>
        (Code => "L0346", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 1, Most => 1, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[1580]: a C boundary signature, layout or variadic call"
                   & " the C ABI cannot carry")),
      Linkage_Contract =>
        (Code => "L0347", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 1, Most => 1, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[1610]/[1640]: a link symbol, helper import or placement"
                   & " outside its contract")),
      Traversal_Source =>
        (Code => "L0348", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 1, Most => 1, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[1150]/D180: a for source is a range, a traversable"
                   & " value or one exact iterable conformance")),
      --  D542-D547: a description and a placement in its regions. The note
      --  says what to write instead, and for a broken contract the clause it
      --  states.
      Invalid_Description_Directive =>
        (Code => "L0399", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("D542: a device description directive whose arguments are"
                   & " not the forms its row says")),
      Description_Structure =>
        (Code => "L0513", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("D542/D543: a description directive outside one"
                   & " description, a repeated or missing one, or a second"
                   & " description")),
      Description_Layout =>
        (Code => "L0514", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("D543: regions that overlap, or a placement, vector table"
                   & " or stack its regions cannot hold")),
      Description_Core_Mismatch =>
        (Code => "L0515", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("D543: a description whose core is not the request's"
                   & " target and level")),
      --  Retired by D683, which built the last reserved boot kind.
      Boot_Kind_Reserved =>
        (Code => "L0516", Level => Error, State => Retired,
         Source => False, Bytes => False,
         Least => 0, Most => 0, Notes => 0, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +"retired: a reserved boot image kind refine did not build"),
      Region_Placement =>
        (Code => "L0517", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("D547: a link(region: ...) the selected description"
                   & " cannot hold")),
      --  D543: raised at a placement, or by the driver for a request, and only
      --  where the library holds no reference description, which every corpus
      --  run has; its evidence is the Cortex ABI cases and the descriptions
      --  lane.
      No_Description =>
        (Code => "L0518", Level => Error, State => Live,
         Source => False, Bytes => False,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Invocation,
         Rule => +("D543: firmware or a placement that needs a profile, with"
                   & " no description reached and none in the library")),
      --  D587: the boot stage's place in the description, which says
      --  what to write instead.
      Boot_Stage_Form =>
        (Code => "L0533", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("D587: link(boot_stage) on anything but a naked routine"
                   & " with no other link attribute")),
      Boot_Stage_Outside =>
        (Code => "L0534", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("D587: a boot stage outside the device description the"
                   & " program selects")),
      Boot_Stage_Unwanted =>
        (Code => "L0535", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("D587: a boot stage in a description whose boot kind"
                   & " takes none")),
      Boot_Stage_Repeated =>
        (Code => "L0536", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +"D587: a second boot stage in one description"),
      Boot_Stage_Missing =>
        (Code => "L0537", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("D587: a description whose boot kind begins with a"
                   & " second stage, holding none")),
      --  D615: the float unit a description names, and the level it
      --  needs, each saying what refine builds.
      Float_Unit_Unsupported =>
        (Code => "L0545", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("D615: a float unit refine does not build, or one the"
                   & " description's core cannot have")),
      Float_Unit_Level =>
        (Code => "L0546", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("D615: a description with a float unit, built at a"
                   & " level whose architecture lacks it")),
      --  D971: the cache a description names and its line, each saying
      --  what refine builds.
      Cache_Unsupported =>
        (Code => "L0610", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("D971: a cache refine does not build, or one the"
                   & " description's core cannot have")),
      Cache_Line_Wrong =>
        (Code => "L0611", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("D971: a described cache whose line is not its"
                   & " core's")),
      Reset_Stage_Return =>
        (Code => "L0560", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("D653: a vector-table description's stage that does"
                   & " not name compiler-owned reset")),
      Reset_Stage_Stack =>
        (Code => "L0561", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("D653: a vector-table description's stage that uses the"
                   & " stack")),
      Boot_Kind_Family =>
        (Code => "L0576", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("D681: a boot image kind another family's boot ROM"
                   & " reads")),
      RAM_Code_Unplaceable =>
        (Code => "L0578", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 1, Most => 1, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("D688: a .ramtext routine in a profile whose data region"
                   & " code does not run in")),
      ESP_Image_Facts =>
        (Code => "L0575", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("D683: an esp-app-image description without"
                   & " compiler.esp_image, or compiler.esp_image without an"
                   & " esp-app-image")),
      --  D251, as for Mutable_Never_Written.
      Unused_Pure_Local =>
        (Code => "L0349", Level => Warning, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => May_Fix, Shown_By => Negative_Fixture,
         Rule => +("D251: an unused local with an effect-free literal"
                   & " initializer")),
      --  The literal is the one place: the conversion around it is what
      --  the message names, and the note gives both routes.
      Literal_Rounded_Away =>
        (Code => "L0350", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("D760: an untyped float literal converted to an integer"
                   & " that its f32 rounding changes")),
      Unvalidated_Text_Checked =>
        (Code => "L0600", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("D949: compiler.utf8_unvalidated outside an unchecked"
                   & " region")),
      Bidirectional_Control =>
        (Code => "L0628", Level => Warning, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("D1077: a bidirectional control character in a comment"
                   & " or a literal")),
      --  The backend's reports need not have a source. A missing entry uses an
      --  entry-module anchor when available, but permits a point in an empty
      --  file or a source-free fallback. L0500 is the one diagnostic here a
      --  user is stuck on rather than informed by, so it owes them the way
      --  out: which program was looked for, and how to name another.
      No_Toolchain =>
        (Code => "L0500", Level => Error, State => Live,
         Source => False, Bytes => False,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Invocation,
         Rule => +("[1550]: the requested output cannot be made with the"
                   & " target, settings or available toolchain")),
      Toolchain_Failed =>
        (Code => "L0501", Level => Error, State => Live,
         Source => False, Bytes => False,
         Least => 0, Most => 0, Notes => 0, Route => False,
         Fixes => No_Fix, Shown_By => Invocation,
         Rule => +("[1550]: assembler or linker refusal, or executable"
                   & " output lifecycle failure")),
      Entry_Point_Missing =>
        (Code => "L0502", Level => Error, State => Live,
         Source => False, Bytes => False,
         Least => 0, Most => 0, Notes => 0, Route => False,
         Fixes => No_Fix, Shown_By => Invocation,
         Rule => +("[1970] [1990]: a missing or invalid hosted main or"
                   & " explicitly selected firmware entry")),
      --  Retired by the internal scalar convention, which places every
      --  argument after the sixth in an aligned stack run.
      Argument_Not_In_A_Register =>
        (Code => "L0503", Level => Error, State => Retired,
         Source => False, Bytes => False,
         Least => 0, Most => 0, Notes => 0, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +"retired: the register-only internal calling limit"),
      Frame_Not_Addressable =>
        (Code => "L0504", Level => Error, State => Live,
         Source => False, Bytes => False,
         Least => 0, Most => 0, Notes => 0, Route => False,
         Fixes => No_Fix, Shown_By => Invocation,
         Rule => +("a verified frame larger than the target's backend can"
                   & " address")),
      Image_Budget_Exceeded =>
        (Code => "L0505", Level => Error, State => Live,
         Source => False, Bytes => False,
         Least => 0, Most => 0, Notes => 0, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("D537: static images exceed the image budget of the"
                   & " target or the firmware profile")),
      Panic_Contract_Invalid =>
        (Code => "L0506", Level => Error, State => Live,
         Source => False, Bytes => False,
         Least => 0, Most => 0, Notes => 0, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[1670]: invalid panic handler or unrepresentable site"
                   & " space")),
      Firmware_Frame_Exceeds_Stack =>
        (Code => "L0507", Level => Error, State => Live,
         Source => False, Bytes => False,
         Least => 0, Most => 0, Notes => 0, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[1990]: one firmware frame exceeds the selected stack"
                   & " reservation")),
      Handler_Exceeds_Stack_Margin =>
        (Code => "L0508", Level => Error, State => Live,
         Source => False, Bytes => False,
         Least => 0, Most => 0, Notes => 0, Route => False,
         Fixes => No_Fix, Shown_By => Negative_Fixture,
         Rule => +("[1670]: a selected panic handler in a program that"
                   & " prepares a stack exceeds or cannot be measured"
                   & " against the target's stack margin")),
      --  D525: a library is asked for by its directive, always, and the note
      --  says how to name where it is. Only a failed link raises it, so its
      --  evidence is end-to-end/link-missing-library and the driver case.
      Library_Not_Found =>
        (Code => "L0509", Level => Error, State => Live,
         Source => True, Bytes => True,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Invocation,
         Rule => +("[1590]/D525: a failed link's library that no named"
                   & " directory and none of the C driver's own holds")),
      --  D546: about a linked image, raised by the descriptions lane.
      Linker_Script_Contract =>
        (Code => "L0519", Level => Error, State => Live,
         Source => False, Bytes => False,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Invocation,
         Rule => +("D546: a linked firmware image that breaks a clause of"
                   & " the linker script contract")),
      --  D588: about an assembled object, raised by the driver before the
      --  link, and shown by the cortex ABI cases and the descriptions
      --  lane.
      Boot_Stage_Object =>
        (Code => "L0538", Level => Error, State => Live,
         Source => False, Bytes => False,
         Least => 0, Most => 0, Notes => 0, Route => False,
         Fixes => No_Fix, Shown_By => Invocation,
         Rule => +("D588: an assembled boot stage that outgrows its slot or"
                   & " that a relocation reaches")),
      --  D638: about an assembled object, raised by the driver before the
      --  link, and shown by the cortex ABI cases.
      Image_Block_Object =>
        (Code => "L0555", Level => Error, State => Live,
         Source => False, Bytes => False,
         Least => 0, Most => 0, Notes => 0, Route => False,
         Fixes => No_Fix, Shown_By => Invocation,
         Rule => +("D638: an assembled image block that is not the IMAGE_DEF"
                   & " block its boot kind gives, or that a relocation"
                   & " reaches")),
      --  D685: about the image refine writes from the linked executable,
      --  raised by the driver after the link, and shown by the RV32
      --  firmware cases.
      ESP_Image_Object =>
        (Code => "L0577", Level => Error, State => Live,
         Source => False, Bytes => False,
         Least => 0, Most => 0, Notes => 0, Route => False,
         Fixes => No_Fix, Shown_By => Invocation,
         Rule => +("D685: a linked image no ESP application image can hold,"
                   & " or one whose written bytes do not read back")),
      --  D558: `refine svd` raises these for an SVD, its policy or its
      --  outputs, and the devices suite owns them. The SVD or the policy is
      --  the source a fault is in, and a fault points at the element or byte
      --  it is at, or at the start when it is the whole file's; an output in
      --  the way is in neither.
      Svd_Malformed =>
        (Code => "L0525", Level => Error, State => Live,
         Source => True, Bytes => False,
         Least => 0, Most => 0, Notes => 0, Route => False,
         Fixes => No_Fix, Shown_By => Invocation,
         Rule => +("D555: an SVD that is not XML in the subset refine svd"
                   & " reads")),
      Svd_Policy_Invalid =>
        (Code => "L0526", Level => Error, State => Live,
         Source => True, Bytes => False,
         Least => 0, Most => 0, Notes => 0, Route => False,
         Fixes => No_Fix, Shown_By => Invocation,
         Rule => +"D556: a selection policy refine svd cannot read"),
      Svd_Input_Mismatch =>
        (Code => "L0527", Level => Error, State => Live,
         Source => True, Bytes => False,
         Least => 0, Most => 0, Notes => 0, Route => False,
         Fixes => No_Fix, Shown_By => Invocation,
         Rule => +("D556: an SVD that is not the one its policy was reviewed"
                   & " against")),
      Svd_Form_Unsupported =>
        (Code => "L0528", Level => Error, State => Live,
         Source => True, Bytes => False,
         Least => 0, Most => 0, Notes => 0, Route => False,
         Fixes => No_Fix, Shown_By => Invocation,
         Rule => +("D557: an SVD form refine svd does not read, for a"
                   & " selected register")),
      Svd_Device_Inconsistent =>
        (Code => "L0529", Level => Error, State => Live,
         Source => True, Bytes => False,
         Least => 0, Most => 0, Notes => 0, Route => False,
         Fixes => No_Fix, Shown_By => Invocation,
         Rule => +("D557: a selected register the SVD describes in a way"
                   & " that cannot be generated as it says")),
      Svd_Not_Found =>
        (Code => "L0530", Level => Error, State => Live,
         Source => True, Bytes => False,
         Least => 0, Most => 0, Notes => 0, Route => False,
         Fixes => No_Fix, Shown_By => Invocation,
         Rule => +"D556: a policy that selects what its SVD does not have"),
      Svd_Output_Refused =>
        (Code => "L0531", Level => Error, State => Live,
         Source => False, Bytes => False,
         Least => 0, Most => 0, Notes => 0, Route => False,
         Fixes => No_Fix, Shown_By => Invocation,
         Rule => +"D558: outputs refine svd will not replace"),
      --  D820: `refine bindings` raises these for its policy, for what
      --  Clang answers, for a selected declaration and for its outputs,
      --  and the bindings suite owns them.  None is in a Landin source.
      Bindings_Policy_Invalid =>
        (Code => "L0579", Level => Error, State => Live,
         Source => False, Bytes => False,
         Least => 0, Most => 0, Notes => 0, Route => False,
         Fixes => No_Fix, Shown_By => Invocation,
         Rule => +"D820: a binding policy refine bindings cannot read"),
      Bindings_Clang_Refused =>
        (Code => "L0580", Level => Error, State => Live,
         Source => False, Bytes => False,
         Least => 0, Most => 0, Notes => 0, Route => False,
         Fixes => No_Fix, Shown_By => Invocation,
         Rule => +("D820: a Clang that cannot be run as asked, fails, or"
                   & " describes another ABI")),
      Bindings_Declaration_Refused =>
        (Code => "L0581", Level => Error, State => Live,
         Source => False, Bytes => False,
         Least => 0, Most => 0, Notes => 0, Route => False,
         Fixes => No_Fix, Shown_By => Invocation,
         Rule => +("D820: a selected C declaration, or its policy, that"
                   & " cannot be bound")),
      Bindings_Output_Refused =>
        (Code => "L0582", Level => Error, State => Live,
         Source => False, Bytes => False,
         Least => 0, Most => 0, Notes => 0, Route => False,
         Fixes => No_Fix, Shown_By => Invocation,
         Rule => +"D820: outputs refine bindings will not replace"),
      Firmware_Foreign_Section =>
        (Code => "L0587", Level => Error, State => Live,
         Source => False, Bytes => False,
         Least => 0, Most => 0, Notes => 1, Route => False,
         Fixes => No_Fix, Shown_By => Invocation,
         Rule => +("D924: a firmware image whose C archives bring"
                   & " constructors, thread-local storage or a dynamic"
                   & " linkage"))];

   ------------------------------------------------------------------
   --  The columns, read out of the table
   --
   --  The row states the shape; the fixture states where. Both are checked,
   --  and neither is prose.
   ------------------------------------------------------------------

   function Code (Of_Code : Code_Name) return Code_String
     is (Table (Of_Code).Code);

   function Level (Of_Code : Code_Name) return Severity
     is (Table (Of_Code).Level);

   function State (Of_Code : Code_Name) return Disposition
     is (Table (Of_Code).State);

   function Rule (Of_Code : Code_Name) return String
     is (Table (Of_Code).Rule.all);

   function Needs_Non_Empty_Span (Of_Code : Code_Name) return Boolean
     is (Table (Of_Code).Bytes);

   function Minimum_Secondaries (Of_Code : Code_Name) return Natural
     is (Table (Of_Code).Least);

   function Maximum_Secondaries (Of_Code : Code_Name) return Natural
     is (Table (Of_Code).Most);

   function Required_Notes (Of_Code : Code_Name) return Natural
     is (Table (Of_Code).Notes);

   --  Whether an occurrence carrying Count notes carries what its row
   --  promises: the required notes, and the route where one is admitted.
   function Admits_Notes (Of_Code : Code_Name; Count : Natural)
     return Boolean
     is (Count = Table (Of_Code).Notes
         or else (Table (Of_Code).Route
                  and then Count = Table (Of_Code).Notes + 1));

   function Warning_Enabled_By_Default (Of_Code : Code_Name) return Boolean
     is (Table (Of_Code).Level = Warning);

   function Fixes (Of_Code : Code_Name) return Fix_Admission
     is (Table (Of_Code).Fixes);

   function Count return Natural
     is (Code_Name'Pos (Code_Name'Last) - Code_Name'Pos (Code_Name'First) + 1);

   --  Which name a code string belongs to, for a test that starts from the
   --  number. Raises Compiler_Defect on a code no row holds, because a code
   --  outside the catalogue is the defect this package exists to prevent.
   function Named (Text : Code_String) return Code_Name;

   --  Whether some row holds the code.  A stage test may report a code of
   --  its own invention to exercise transport; nothing in `src/` can,
   --  because check.py refuses a code written outside this file.
   function Holds (Text : Code_String) return Boolean
     is (for some Candidate in Code_Name => Code (Candidate) = Text);

end Landin.Diagnostics.Catalogue;
