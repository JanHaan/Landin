with Landin.Diagnostics.Syntactic;
with Landin.Syntax.Precedence;

package body Landin.Syntax.Parser is

   package Tok renames Landin.Tokens;
   package Syn renames Landin.Diagnostics.Syntactic;
   package Pre renames Landin.Syntax.Precedence;

   use type Landin.Source.Byte_Offset;
   use type Landin.Source.Names.Name_Id;
   use type Landin.Source.Span;
   use type Tok.Token_Index;
   use type Pre.Level;
   use type Pre.Associativity;
   use type Tok.Token_Kind;

   ------------------------------------------------------------------
   --  The declared recovery boundaries
   --
   --  Every one contains End_Of_Input, which is what Skip_To's
   --  precondition turns into a termination proof.  Each is the first set
   --  of a repetition in the grammar, so resuming at one is resuming where
   --  the grammar says a new item may begin.
   ------------------------------------------------------------------

   --  `source_file ::= import_declaration* declaration*` [1740].
   Declaration_Anchor : constant Tok.Kind_Set :=
     [Tok.Kw_Import | Tok.Kw_Public | Tok.Kw_Mut | Tok.Kw_Fixed
        | Tok.Identifier
        | Tok.Left_Paren | Tok.End_Of_Input => True,
      others => False];

   --  `block ::= statement* | value_statement* expression` [1800].  The
   --  closers are
   --  in it deliberately: a broken statement must resume at the next
   --  branch or at the body's `end` rather than run past it.
   Statement_Anchor : constant Tok.Kind_Set :=
     [Tok.Kw_Mut | Tok.Identifier | Tok.Underscore | Tok.Left_Paren
        | Tok.Kw_Inc | Tok.Kw_Dec | Tok.Kw_Return | Tok.Kw_Fail | Tok.Kw_Try
        | Tok.Kw_If | Tok.Kw_Elsif
        | Tok.Kw_Else | Tok.Kw_End | Tok.Kw_Public
        | Tok.End_Of_Input => True,
      others => False];

   --  `parameters`, `arguments`, `returns`.  Landing outside the list
   --  means the parenthesis was never closed.
   List_Anchor : constant Tok.Kind_Set :=
     [Tok.Comma | Tok.Right_Paren | Tok.Kw_End | Tok.Kw_Public
        | Tok.Kw_Mut | Tok.End_Of_Input => True,
      others => False];

   ------------------------------------------------------------------
   --  The words the tour spells and the kernel does not reserve
   --
   --  [1760] reserves thirty-three words, and none of them is `loop`,
   --  `while`, `for`, `break` or `continue`.
   --  Every one of those lexes as an ordinary identifier, so
   --  the scan cannot refuse it and only the parser can: at a statement
   --  position, an identifier that is one of these is the construct the
   --  tour describes and not a name someone forgot a colon after. Enabled
   --  contextual words such as `match`, `begin`, `defer` and `undo` are
   --  recognised separately and therefore do not belong in this table.
   --
   --  This is the other half of what Landin.Tokens.Construct does for the
   --  deferred signs, and it is derived rather than guessed: check.py
   --  holds every spelling here to a keyword the tour actually writes and
   --  every construct to a paragraph that actually exists.
   ------------------------------------------------------------------

   type Refused_Word is
     (Word_None,
      Word_Distinct);

   subtype Real_Word is Refused_Word range Word_Distinct .. Word_Distinct;

   function Spelling (Item : Real_Word) return String
     is (case Item is
            when Word_Distinct => "distinct");

   function Refusal (Item : Real_Word) return Syn.Refused_Construct
     is (case Item is
            when Word_Distinct => Syn.Distinct_Type);

   --  The scalar names [1790].  These are the types the kernel predeclares,
   --  not keywords, which is why they are compared by interned identity
   --  rather than by kind.  Arrays and function types have syntax of their
   --  own, and other names resolve to declarations.
   type Scalar_Name is
     (Type_U8, Type_U16, Type_U32, Type_U64,
      Type_I8, Type_I16, Type_I32, Type_I64,
      Type_Usize, Type_Isize, Type_F32, Type_F64, Type_Bool);

   function Spelling (Item : Scalar_Name) return String
     is (case Item is
            when Type_U8    => "u8",
            when Type_U16   => "u16",
            when Type_U32   => "u32",
            when Type_U64   => "u64",
            when Type_I8    => "i8",
            when Type_I16   => "i16",
            when Type_I32   => "i32",
            when Type_I64   => "i64",
            when Type_Usize => "usize",
            when Type_Isize => "isize",
            when Type_F32   => "f32",
            when Type_F64   => "f64",
            when Type_Bool  => "bool");

   ------------------------------------------------------------------

   type Slot_List is array (Positive range <>) of Node_Id;

   No_Slots : constant Slot_List (1 .. 0) := [];

   --  What the enclosing function is, for the diagnostics that can only be
   --  read next to it: a `public` inside a body, a `return` carrying a
   --  value, an `end` whose name does not match.
   type Frame is record
      Owner   : Landin.Source.Span := Landin.Source.Empty_Span;
      Result  : Landin.Source.Span := Landin.Source.Empty_Span;
      Returns : Boolean            := False;
   end record;

   function Parse
     (From   : Landin.Tokens.Token_Stream;
      Names  : in out Landin.Source.Names.Table;
      Report : in out Landin.Diagnostics.Diagnostic_List) return Tree is
   begin
      return Result : Tree do
         declare
            Origin_Of : constant Landin.Source.Source_Id :=
              Tok.Source_Of (From);
            Last      : constant Tok.Token_Index := Tok.Count (From);

            Index : Tok.Token_Index := 1;

            --  P3: the parser reports only for a token index strictly
            --  greater than this, which is what keeps one mistake from
            --  producing a cascade at the same place and what keeps the
            --  parser from doubling a complaint the scanner already made.
            Reported : Natural := 0;

            Depth     : Natural := 0;
            Nest_Root : Landin.Source.Span := Landin.Source.Empty_Span;
            --  Expression parsing is shared by module values and function
            --  bodies.  Control expressions may contain `return`, whose
            --  parser diagnostic points back to the active signature.
            Active_Frame : Frame;
            --  A call and its enclosing `if` both use `else`.  At the direct
            --  end of a then/elsif arm the enclosing branch wins; wrapping a
            --  recovered call in parentheses makes its inner `else` explicit.
            Else_Closes_Arm : Boolean := False;
            --  `complete` is contextual and closes only the body of the
            --  loop currently being parsed.
            Complete_Closes_Block : Boolean := False;
            --  Transfers are contextual identifiers.  Keeping the nesting
            --  count here lets a stray `break` or `continue` remain a source
            --  diagnostic instead of reaching lowering without a target.
            Loop_Depth : Natural := 0;
            Loop_Labels : array (1 .. Nesting_Limit)
              of Landin.Source.Names.Name_Id :=
                [others => Landin.Source.Names.No_Name];
            --  A labelled RHS keeps direct positional applications neutral:
            --  their own arguments may recursively be type-only syntax.
            --  Outside that one parse, positional Call uses the unchanged
            --  expression-only argument production.
            In_Argument_RHS : Boolean := False;

            --  Set by Parse_Type when it refused a construct rather than
            --  failing to read one.  A binding whose type is a construct
            --  the kernel omits has a value the kernel cannot read either
            --  -- `point: type = (x: i32, y: i32)` is one mistake, and
            --  reading on would report the struct literal three more
            --  times -- so the declaration ends at the refusal.
            Type_Refused : Boolean := False;

            Word_Id : constant array (Real_Word)
              of Landin.Source.Names.Name_Id :=
                [for W in Real_Word =>
                   Landin.Source.Names.Intern (Names, Spelling (W))];

            Lenof_Id : constant Landin.Source.Names.Name_Id :=
              Landin.Source.Names.Intern (Names, "lenof");

            Of_Id : constant Landin.Source.Names.Name_Id :=
              Landin.Source.Names.Intern (Names, "of");

            Variant_Id : constant Landin.Source.Names.Name_Id :=
              Landin.Source.Names.Intern (Names, "variant");

            Match_Id : constant Landin.Source.Names.Name_Id :=
              Landin.Source.Names.Intern (Names, "match");

            Begin_Id : constant Landin.Source.Names.Name_Id :=
              Landin.Source.Names.Intern (Names, "begin");

            Defer_Id : constant Landin.Source.Names.Name_Id :=
              Landin.Source.Names.Intern (Names, "defer");

            Undo_Id : constant Landin.Source.Names.Name_Id :=
              Landin.Source.Names.Intern (Names, "undo");

            Loop_Id : constant Landin.Source.Names.Name_Id :=
              Landin.Source.Names.Intern (Names, "loop");

            While_Id : constant Landin.Source.Names.Name_Id :=
              Landin.Source.Names.Intern (Names, "while");

            For_Id : constant Landin.Source.Names.Name_Id :=
              Landin.Source.Names.Intern (Names, "for");

            Break_Id : constant Landin.Source.Names.Name_Id :=
              Landin.Source.Names.Intern (Names, "break");

            Continue_Id : constant Landin.Source.Names.Name_Id :=
              Landin.Source.Names.Intern (Names, "continue");

            Do_Id : constant Landin.Source.Names.Name_Id :=
              Landin.Source.Names.Intern (Names, "do");

            Complete_Id : constant Landin.Source.Names.Name_Id :=
              Landin.Source.Names.Intern (Names, "complete");

            With_Id : constant Landin.Source.Names.Name_Id :=
              Landin.Source.Names.Intern (Names, "with");

            --  These remain ordinary identifiers except in the three
            --  contextual productions below.
            Concept_Id : constant Landin.Source.Names.Name_Id :=
              Landin.Source.Names.Intern (Names, "concept");

            Is_Id : constant Landin.Source.Names.Name_Id :=
              Landin.Source.Names.Intern (Names, "is");

            As_Id : constant Landin.Source.Names.Name_Id :=
              Landin.Source.Names.Intern (Names, "as");

            --  [1480] takes this bare toolchain root.  D139 recognizes it
            --  only as the fixed-condition intrinsic, not as a declaration.
            Compiler_Id : constant Landin.Source.Names.Name_Id :=
              Landin.Source.Names.Intern (Names, "compiler");

            Scalar_Id : constant array (Scalar_Name)
              of Landin.Source.Names.Name_Id :=
                [for S in Scalar_Name =>
                   Landin.Source.Names.Intern (Names, Spelling (S))];

            ------------------------------------------------------------
            --  Reading the stream
            ------------------------------------------------------------

            function Peek return Tok.Token_Kind;
            function Ahead (Distance : Tok.Token_Index)
              return Tok.Token_Kind;
            function After_Selectors return Tok.Token_Kind;
            function Starts_Destructuring return Boolean;
            function Here return Landin.Source.Span;
            function Point return Landin.Source.Span;
            function After_Previous return Landin.Source.Span;
            function Named_Here return Landin.Source.Names.Name_Id;
            function Named_Ahead (Distance : Tok.Token_Index)
              return Landin.Source.Names.Name_Id;
            procedure Advance;
            procedure Mark_Reported;

            ------------------------------------------------------------
            --  Building the table
            ------------------------------------------------------------

            function Join (Left, Right : Landin.Source.Span)
              return Landin.Source.Span;

            function Add
              (Of_Kind   : Node_Kind;
               At_Token  : Landin.Source.Span;
               Extent    : Landin.Source.Span := Landin.Source.Empty_Span;
               Children  : Slot_List := No_Slots;
               Named     : Landin.Source.Names.Name_Id :=
                             Landin.Source.Names.No_Name;
               Radix     : Tok.Integer_Base := Tok.Decimal;
               Digits_At : Landin.Source.Span := Landin.Source.Empty_Span;
               Exported  : Boolean := False;
               External  : Boolean := False;
               Mutable   : Boolean := False;
               Escapes   : Boolean := False;
               Convention : Parameter_Convention := Implicit_In;
               Fills     : Boolean := False;
               Recovers  : Node_Id := No_Node) return Node_Id;

            function Extent_Of (Nodes : Slot_List)
              return Landin.Source.Span;

            ------------------------------------------------------------
            --  Reporting and recovering
            ------------------------------------------------------------

            procedure Complain
              (Item    : Syn.Failure;
               Where   : Landin.Source.Span;
               Message : String;
               Note    : String := "";
               Related : Landin.Source.Span := Landin.Source.Empty_Span;
               Because : String := "";
               Refused : Syn.Refused_Construct := Syn.Declared_Type;
               Gate    : Boolean := True);

            procedure Refuse
              (Item : Syn.Refused_Construct;
               Where : Landin.Source.Span;
               Message : String);

            function Expect
              (Wanted  : Tok.Token_Kind;
               Message : String;
               Note    : String;
               Related : Landin.Source.Span;
               Because : String) return Boolean;

            procedure Resync (Wanted : Tok.Kind_Set);
            procedure Resync_Declaration;
            procedure Resync_Statement;
            function Skip_Past_Closer
              (Word : Landin.Source.Names.Name_Id) return Boolean;
            function Too_Deep (Opener : Landin.Source.Span) return Boolean;
            function Word_At_Hand return Refused_Word;

            ------------------------------------------------------------
            --  The productions
            ------------------------------------------------------------

            function To_List (Items : Slot_Vectors.Vector)
              return Slot_List;
            procedure Resync_Parentheses;
            function Parse_Program return Node_Id;
            function Parse_Import (Late : Boolean := False) return Node_Id;
            function Parse_Declaration return Node_Id;
            function Parse_Fixed_Conditional return Node_Id;
            function Parse_Atom_Declaration
              (Exported  : Boolean;
               Public_At : Landin.Source.Span) return Node_Id;
            function Parse_Type_Declaration
              (Exported  : Boolean;
               Public_At : Landin.Source.Span) return Node_Id;
            function Parse_Concept_Body
              (Named   : Landin.Source.Names.Name_Id;
               At_Name : Landin.Source.Span) return Node_Id;
            function Parse_Conformance
              (Exported  : Boolean;
               Public_At : Landin.Source.Span) return Node_Id;
            function Parse_Struct_Body
              (Named   : Landin.Source.Names.Name_Id;
               At_Name : Landin.Source.Span) return Node_Id;
            function Parse_Binding
              (Exported  : Boolean;
               Public_At : Landin.Source.Span) return Node_Id;
            function Parse_Destructuring return Node_Id;
            function Parse_Function
              (Exported  : Boolean;
               Public_At : Landin.Source.Span;
               External  : Boolean := False;
               Extern_At : Landin.Source.Span := Landin.Source.Empty_Span)
               return Node_Id;
            function Parse_Anonymous_Function return Node_Id;
            function Parse_Parameter
              (Allow_Static : Boolean := False) return Node_Id;
            function Parse_Returns
              (Declared_At : Landin.Source.Span;
               Returns_At  : out Landin.Source.Span) return Node_Id;
            function Parse_Errors
              (Declared_At : Landin.Source.Span) return Node_Id;
            procedure Parse_Type_Formals
              (Declared_At : Landin.Source.Span;
               Into        : in out Slot_Vectors.Vector;
               Closed      : out Boolean);
            function Parse_Type_Application
              (Target : Node_Id;
               Starts : Landin.Source.Span) return Node_Id;
            function Parse_Type
              (In_Parameter : Boolean;
               Declared_At  : Landin.Source.Span) return Node_Id;
            function Parse_Declared_Name
              (Named : out Landin.Source.Names.Name_Id)
              return Landin.Source.Span;
            function Parse_Qualified_Reference
              (Of_Kind : Node_Kind) return Node_Id;
            function Parse_Place return Node_Id;
            function Parse_Body (Context : Frame) return Node_Id;
            function Parse_Block
              (Context     : Frame;
               Seed        : Node_Id := No_Node;
               Allow_Value : Boolean := False) return Node_Id;
            function Parse_Statement (Context : Frame) return Node_Id;
            function Parse_Loop
              (Context : Frame;
               Starts  : Landin.Source.Span := Landin.Source.Empty_Span;
               Label   : Landin.Source.Names.Name_Id :=
                 Landin.Source.Names.No_Name) return Node_Id;
            function Parse_For
              (Context : Frame;
               Starts  : Landin.Source.Span := Landin.Source.Empty_Span;
               Label   : Landin.Source.Names.Name_Id :=
                 Landin.Source.Names.No_Name) return Node_Id;
            function Parse_Loop_Transfer return Node_Id;
            function Parse_If (Context : Frame) return Node_Id;
            function Parse_Match (Context : Frame) return Node_Id;
            function Parse_Bare_Block (Context : Frame) return Node_Id;
            function Parse_Expression
              (Min : Pre.Level := Pre.Level_Expression) return Node_Id;
            function Parse_Expression_From
              (Seed : Node_Id;
               Min  : Pre.Level := Pre.Level_Expression) return Node_Id;
            function Parse_Unary return Node_Id;
            function Parse_Primary return Node_Id;
            function Parse_Struct_Literal
              (Nominal : Node_Id;
               Starts  : Landin.Source.Span) return Node_Id;
            function Begins_Argument_Type return Boolean;
            function Parse_Argument_RHS return Node_Id;
            function Parse_Call
              (Name_At : Landin.Source.Span;
               Named   : Landin.Source.Names.Name_Id) return Node_Id;
            function Parse_Call
              (Callee : Node_Id;
               Starts : Landin.Source.Span) return Node_Id;
            function Previous return Landin.Source.Span;

            ------------------------------------------------------------

            function Peek return Tok.Token_Kind
              is (Tok.Kind (From, Index));

            function Ahead (Distance : Tok.Token_Index)
              return Tok.Token_Kind
              is (if Index + Distance <= Last
                  then Tok.Kind (From, Index + Distance)
                  else Tok.End_Of_Input);

            --  What follows the selection [1820] beginning at the token
            --  in hand.  A name and a name with fields selected from it
            --  are the same production, so what tells a place from an
            --  expression is the token after the whole chain and never
            --  the one after the name.
            function Starts_Signature return Boolean;
            function Starts_Conformance return Boolean;

            --  A parenthesized expression, a struct literal and a function
            --  signature share `(`.  The arrow after the balanced list is
            --  the unambiguous discriminator, including nested function
            --  types inside the list.
            function Starts_Signature return Boolean is
               Step  : Tok.Token_Index := 1;
               Level : Positive := 1;
            begin
               while Ahead (Step) /= Tok.End_Of_Input loop
                  if Ahead (Step) = Tok.Left_Paren then
                     Level := Level + 1;
                  elsif Ahead (Step) = Tok.Right_Paren then
                     if Level = 1 then
                        return Ahead (Step + 1) = Tok.Minus_Greater;
                     end if;
                     Level := Level - 1;
                  end if;
                  Step := Step + 1;
               end loop;
               return False;
            end Starts_Signature;

            --  A module-level parenthesized prefix is a conformance binder
            --  only when a direct contextual `is` follows its target type.
            --  This lookahead neither parses nor interprets the type; it
            --  merely balances type delimiters so `is` stays an ordinary name
            --  in a nested signature or application.
            function Starts_Conformance return Boolean is
               Step        : Tok.Token_Index := 1;
               Parentheses : Natural :=
                 (if Peek = Tok.Left_Paren then 1 else 0);
               Brackets    : Natural :=
                 (if Peek = Tok.Left_Bracket then 1 else 0);
            begin
               loop
                  exit when Ahead (Step) = Tok.End_Of_Input;
                  exit when Parentheses = 0 and then Brackets = 0
                    and then Ahead (Step) in Tok.Equal | Tok.Colon;

                  if Parentheses = 0 and then Brackets = 0
                    and then Ahead (Step) = Tok.Identifier
                    and then Named_Ahead (Step) = Is_Id
                  then
                     return True;
                  end if;

                  case Ahead (Step) is
                     when Tok.Left_Paren => Parentheses := Parentheses + 1;
                     when Tok.Right_Paren =>
                        if Parentheses = 0 then
                           return False;
                        end if;
                        Parentheses := Parentheses - 1;
                     when Tok.Left_Bracket => Brackets := Brackets + 1;
                     when Tok.Right_Bracket =>
                        if Brackets > 0 then
                           Brackets := Brackets - 1;
                        end if;
                     when others => null;
                  end case;
                  Step := Step + 1;
               end loop;
               return False;
            end Starts_Conformance;

            --  Whether a labelled argument's RHS begins one of the type-only
            --  shapes that ordinary expression parsing cannot consume.  This
            --  lookahead only balances the outer brackets; it creates no
            --  nodes, interprets no identifiers, and never moves Index.  The
            --  RHS itself is consequently parsed exactly once, without a
            --  failed expression parse, rewind, or scalar-name heuristic.
            function Begins_Argument_Type return Boolean is
               Step  : Tok.Token_Index := 1;
               Level : Natural := 0;
            begin
               if Peek = Tok.Left_Paren then
                  return Starts_Signature;
               elsif Peek = Tok.Kw_Any then
                  return True;
               elsif Peek = Tok.Kw_Ptr then
                  return Ahead (1) /= Tok.Left_Paren;
               elsif Peek /= Tok.Left_Bracket then
                  return False;
               end if;

               Level := 1;
               while Ahead (Step) /= Tok.End_Of_Input loop
                  if Ahead (Step) = Tok.Left_Bracket then
                     Level := Level + 1;
                  elsif Ahead (Step) = Tok.Right_Bracket then
                     Level := Level - 1;
                     if Level = 0 then
                        return Ahead (Step + 1)
                          in Tok.Identifier | Tok.Left_Bracket
                             | Tok.Left_Paren | Tok.Kw_Any | Tok.Kw_Ptr;
                     end if;
                  end if;
                  Step := Step + 1;
               end loop;
               return False;
            end Begins_Argument_Type;

            --  [0990]'s destructuring binding is the only statement that
            --  begins with `(`.  Its contents are labels and optional local
            --  names, never expressions, and the `:=` after the balanced
            --  list distinguishes it from every parenthesized value.
            function Starts_Destructuring return Boolean is
               Step : Tok.Token_Index := 1;
            begin
               if Peek /= Tok.Left_Paren then
                  return False;
               end if;

               loop
                  if Ahead (Step) = Tok.Underscore then
                     Step := Step + 1;
                  elsif Ahead (Step) = Tok.Identifier then
                     Step := Step + 1;
                     if Ahead (Step) = Tok.Colon then
                        Step := Step + 1;
                        if Ahead (Step) not in Tok.Identifier | Tok.Underscore
                        then
                           return False;
                        end if;
                        Step := Step + 1;
                     end if;
                  else
                     return False;
                  end if;

                  if Ahead (Step) = Tok.Comma then
                     Step := Step + 1;
                  elsif Ahead (Step) = Tok.Right_Paren then
                     return Ahead (Step + 1) = Tok.Colon_Equal;
                  else
                     return False;
                  end if;
               end loop;
            end Starts_Destructuring;

            function After_Selectors return Tok.Token_Kind is
               Step  : Tok.Token_Index := 1;
               Depth : Natural := 0;
            begin
               loop
                  if Ahead (Step) = Tok.Dot
                    and then Ahead (Step + 1) = Tok.Identifier
                  then
                     Step := Step + 2;

                  elsif Ahead (Step) = Tok.Left_Bracket then
                     --  Past the whole index, however it nests, because
                     --  what makes `a[i] = 1` an assignment is the `=`
                     --  after the brackets and not the `[` before them.
                     Depth := 1;
                     Step := Step + 1;

                     while Depth > 0
                       and then Ahead (Step) /= Tok.End_Of_Input
                     loop
                        if Ahead (Step) = Tok.Left_Bracket then
                           Depth := Depth + 1;
                        elsif Ahead (Step) = Tok.Right_Bracket then
                           Depth := Depth - 1;
                        end if;

                        Step := Step + 1;
                     end loop;

                  else
                     exit;
                  end if;
               end loop;

               return Ahead (Step);
            end After_Selectors;

            function Here return Landin.Source.Span
              is (Tok.Where (From, Index));

            function Point return Landin.Source.Span
              is (First => Here.First, Last => Here.First);

            --  Where a token that is not there would have gone: between
            --  the last token read and this one.  The catalogue allows an
            --  empty primary for exactly these four codes.
            function After_Previous return Landin.Source.Span
              is (if Index = 1 then Point
                  else (First => Tok.Where (From, Index - 1).Last,
                        Last  => Tok.Where (From, Index - 1).Last));

            function Named_Here return Landin.Source.Names.Name_Id
              is (Tok.Name (Tok.Token_At (From, Index)));

            function Named_Ahead (Distance : Tok.Token_Index)
              return Landin.Source.Names.Name_Id
              is (if Index + Distance <= Last
                  then Tok.Name (Tok.Token_At (From, Index + Distance))
                  else Landin.Source.Names.No_Name);

            --  Never past End_Of_Input, which no production consumes.
            procedure Advance is
            begin
               if Index < Last then
                  Index := Index + 1;
               end if;
            end Advance;

            procedure Mark_Reported is
            begin
               Reported := Natural'Max (Reported, Natural (Index));
            end Mark_Reported;

            --  Empty_Span and a point span at offset zero are the same
            --  bytes, so a span with no length at offset zero is treated
            --  as absent.  A hole at the first byte of a file is the only
            --  place that matters, and there the union is the same value.
            function Join (Left, Right : Landin.Source.Span)
              return Landin.Source.Span
              is (if Left = Landin.Source.Empty_Span then Right
                  elsif Right = Landin.Source.Empty_Span then Left
                  else (First => Landin.Source.Byte_Offset'Min
                                   (Left.First, Right.First),
                        Last  => Landin.Source.Byte_Offset'Max
                                   (Left.Last, Right.Last)));

            function Extent_Of (Nodes : Slot_List)
              return Landin.Source.Span
            is
               Total : Landin.Source.Span := Landin.Source.Empty_Span;
            begin
               for Item of Nodes loop
                  if Item /= No_Node then
                     Total :=
                       Join (Total, Result.Items (Positive (Item)).Extent);
                  end if;
               end loop;
               return Total;
            end Extent_Of;

            --  A parent's extent is the union of its own tokens and its
            --  children's, which is what makes Slot's containment
            --  postcondition a theorem rather than a hope.
            function Add
              (Of_Kind   : Node_Kind;
               At_Token  : Landin.Source.Span;
               Extent    : Landin.Source.Span := Landin.Source.Empty_Span;
               Children  : Slot_List := No_Slots;
               Named     : Landin.Source.Names.Name_Id :=
                             Landin.Source.Names.No_Name;
               Radix     : Tok.Integer_Base := Tok.Decimal;
               Digits_At : Landin.Source.Span := Landin.Source.Empty_Span;
               Exported  : Boolean := False;
               External  : Boolean := False;
               Mutable   : Boolean := False;
               Escapes   : Boolean := False;
               Convention : Parameter_Convention := Implicit_In;
               Fills     : Boolean := False;
               Recovers  : Node_Id := No_Node) return Node_Id
            is
               Total : Landin.Source.Span :=
                 Join (Join (Extent, At_Token), Extent_Of (Children));
               Sound : Boolean := not Is_Error (Of_Kind);
            begin
               for Item of Children loop
                  if Item /= No_Node then
                     Sound :=
                       Sound
                       and then Result.Items (Positive (Item)).Sound;
                  end if;
                  Result.Links.Append (Item);
               end loop;

               if Recovers /= No_Node then
                  Sound := Sound
                    and then Result.Items (Positive (Recovers)).Sound;
               end if;

               if Total = Landin.Source.Empty_Span then
                  Total := At_Token;
               end if;

               Result.Items.Append
                 (Node'(Kind  => Of_Kind,
                   Extent     => Total,
                   Anchor     => At_Token,
                   Name       => Named,
                   Base       => Radix,
                   Digit_Run  => Digits_At,
                   First_Slot => Result.Links.Last_Index - Children'Length,
                   Slots      => Children'Length,
                   Sound      => Sound,
                   Exported   => Exported,
                   External   => External,
                   Mutable    => Mutable,
                   Escaping   => Escapes,
                   Convention => Convention,
                   Fill       => Fills,
                   Recovery   => Recovers));

               return Node_Id (Result.Items.Last_Index);
            end Add;

            procedure Complain
              (Item    : Syn.Failure;
               Where   : Landin.Source.Span;
               Message : String;
               Note    : String := "";
               Related : Landin.Source.Span := Landin.Source.Empty_Span;
               Because : String := "";
               Refused : Syn.Refused_Construct := Syn.Declared_Type;
               Gate    : Boolean := True) is
            begin
               --  Unclosed_Construct is the one exemption from P3: it is
               --  identified by the construct it could not close and not
               --  by a position, so two constructs unclosed at the same
               --  end of input are two reports.
               if Gate and then Natural (Index) <= Reported then
                  return;
               end if;

               Mark_Reported;

               Syn.Report
                 (Item    => Item,
                  Source  => Origin_Of,
                  Where   => Where,
                  Message => Message,
                  Note    => Note,
                  Related => Related,
                  Because => Because,
                  Refused => Refused,
                  Into    => Report);
            end Complain;

            procedure Refuse
              (Item    : Syn.Refused_Construct;
               Where   : Landin.Source.Span;
               Message : String) is
            begin
               Complain
                 (Item    => Syn.Construct_Not_Enabled,
                  Where   => Where,
                  Message => Message,
                  Refused => Item);
            end Refuse;

            --  P2: a token no kernel rule spells, where a terminal is
            --  required, is skipped silently and the requirement retried.
            --  The scanner already reported it, and doubling a complaint
            --  is worse than saying nothing.
            function Expect
              (Wanted  : Tok.Token_Kind;
               Message : String;
               Note    : String;
               Related : Landin.Source.Span;
               Because : String) return Boolean
            is
               Skipped : Boolean := False;
            begin
               while Peek not in Tok.Kernel_Kind loop
                  Mark_Reported;
                  Skipped := True;
                  Advance;
               end loop;

               if Peek = Wanted then
                  Advance;
                  return True;
               end if;

               --  A lexeme the scanner refused takes the rest of its own
               --  construct with it: `! not_found` is one error channel
               --  [0940], and the `!` is the whole of what the parser can
               --  be told about it.  So when a refused lexeme stood here,
               --  the terminal is looked for past it rather than reported
               --  missing, and one refusal stays one report.  Gated on
               --  Skipped, so it can only ever follow a complaint the
               --  scanner already made.
               if Skipped then
                  declare
                     Scan : Tok.Token_Index := Index;
                  begin
                     while Scan < Last
                       and then Tok.Kind (From, Scan) not in Tok.Kw_End
                                  | Tok.Kw_Public | Tok.End_Of_Input
                     loop
                        if Tok.Kind (From, Scan) = Wanted then
                           Index := Scan;
                           Advance;
                           return True;
                        end if;

                        Scan := Scan + 1;
                     end loop;
                  end;
               end if;

               Complain
                 (Item    => Syn.Token_Expected,
                  Where   => After_Previous,
                  Message => Message,
                  Note    => Note,
                  Related => Related,
                  Because => Because);
               return False;
            end Expect;

            --  Always from Index + 1, never from Index: Skip_To may return
            --  where it started, which is the one way to write a parser
            --  that spins.
            procedure Resync (Wanted : Tok.Kind_Set) is
            begin
               if Index < Last then
                  Index := Tok.Skip_To (From, Index + 1, Wanted);
               end if;
            end Resync;

            --  At an Identifier the anchor is confirmed only by the next
            --  token, because `program ::= declaration*` reaches an
            --  identifier through a binding or a function and both spell a
            --  colon after the name.
            --  Skip_To finds the next candidate; the walk to it counts
            --  parentheses, because no declaration begins inside a
            --  parenthesised list and landing in one turns a single
            --  mistake into a report for every item of the list.
            procedure Resync_Declaration is
               Nesting : Natural := 0;
            begin
               while Index < Last loop
                  declare
                     Start : constant Tok.Token_Index := Index;
                     Found : constant Tok.Token_Index :=
                       Tok.Skip_To (From, Index + 1, Declaration_Anchor);
                  begin
                     for Step in Start .. Found - 1 loop
                        case Tok.Kind (From, Step) is
                           when Tok.Left_Paren =>
                              Nesting := Nesting + 1;

                           when Tok.Right_Paren =>
                              if Nesting > 0 then
                                 Nesting := Nesting - 1;
                              end if;

                           when others =>
                              null;
                        end case;
                     end loop;

                     Index := Found;
                  end;

                  exit when Peek = Tok.End_Of_Input;
                  exit when Nesting = 0
                            and then (Peek /= Tok.Identifier
                                      or else Ahead (1) in Tok.Colon
                                                | Tok.Colon_Equal);
               end loop;
            end Resync_Declaration;

            procedure Resync_Statement is
            begin
               while Index < Last loop
                  Index := Tok.Skip_To (From, Index + 1, Statement_Anchor);
                  exit when Peek = Tok.End_Of_Input;
                  exit when Peek not in Tok.Identifier | Tok.Underscore;
                  exit when Peek = Tok.Underscore
                            and then Ahead (1) = Tok.Equal;
                  exit when Peek = Tok.Identifier
                            and then Ahead (1) in Tok.Colon
                                     | Tok.Colon_Equal | Tok.Equal
                                     | Tok.Left_Paren;
               end loop;
            end Resync_Statement;

            --  A refused construct closes itself: `end loop` closes a
            --  loop and `end match` a match, so swallowing the construct's
            --  own closer keeps its `end` from being read as the enclosing
            --  function's and turning one refusal into three reports.
            function Skip_Past_Closer
              (Word : Landin.Source.Names.Name_Id) return Boolean
            is
               Scan : Tok.Token_Index := Index;
            begin
               while Scan < Last loop
                  if Tok.Kind (From, Scan) = Tok.Kw_End
                    and then Scan + 1 <= Last
                    and then Tok.Kind (From, Scan + 1) = Tok.Identifier
                    and then Tok.Name (Tok.Token_At (From, Scan + 1)) = Word
                  then
                     Index := (if Scan + 2 <= Last then Scan + 2 else Last);
                     return True;
                  end if;
                  Scan := Scan + 1;
               end loop;
               return False;
            end Skip_Past_Closer;

            --  Recursive descent over a hostile file needs a floor: the
            --  grammar's nesting is unbounded and the host's stack is not,
            --  and Storage_Error is not a diagnostic.
            function Too_Deep (Opener : Landin.Source.Span) return Boolean is
            begin
               if Depth = 0 then
                  Nest_Root := Opener;
               end if;

               if Depth >= Nesting_Limit then
                  Complain
                    (Item    => Syn.Nesting_Too_Deep,
                     Where   => Here,
                     Message => "this nests deeper than the compiler reads",
                     Note    => "an implementation limit, not a rule of the"
                                & " language",
                     Related => Nest_Root,
                     Because => "the outermost of the nest");
                  return True;
               end if;

               return False;
            end Too_Deep;

            function Word_At_Hand return Refused_Word is
            begin
               if Peek /= Tok.Identifier then
                  return Word_None;
               end if;

               for W in Real_Word loop
                  if Word_Id (W) = Named_Here then
                     return W;
                  end if;
               end loop;

               return Word_None;
            end Word_At_Hand;

            function Previous return Landin.Source.Span
              is (if Index = 1 then Here
                  else Tok.Where (From, Index - 1));

            function To_List (Items : Slot_Vectors.Vector)
              return Slot_List
            is
               Made : Slot_List (1 .. Natural (Items.Length)) :=
                 [others => No_Node];
            begin
               for Position in Made'Range loop
                  Made (Position) := Items (Position);
               end loop;
               return Made;
            end To_List;

            ------------------------------------------------------------
            --  source_file ::= import_declaration* declaration* [1740]
            ------------------------------------------------------------

            function Parse_Program return Node_Id is
               Items : Slot_Vectors.Vector;
            begin
               while Peek = Tok.Kw_Import loop
                  Items.Append (Parse_Import);
               end loop;

               while Peek /= Tok.End_Of_Input loop
                  declare
                     Before : constant Tok.Token_Index := Index;
                  begin
                     if Peek = Tok.Kw_Import then
                        Items.Append (Parse_Import (Late => True));
                     elsif Peek not in Tok.Kernel_Kind
                       and then Ahead (1) not in Tok.Colon
                                  | Tok.Colon_Equal
                     then
                        --  Nothing begins here and the scanner already
                        --  said so, so this says nothing at all.
                        Mark_Reported;
                        Advance;
                     elsif Pre.Begins_Declaration (Peek)
                       or else Peek = Tok.Left_Paren
                       or else Peek = Tok.Kw_Fixed
                       or else Peek not in Tok.Kernel_Kind
                       or else Ahead (1) in Tok.Colon | Tok.Colon_Equal
                     then
                        Items.Append (Parse_Declaration);
                     else
                        --  L0110 is the only broad code, and it fires only
                        --  at a boundary: inside a construct the grammar
                        --  names what is required and a narrower code says
                        --  so.  One report per run, never one per token.
                        declare
                           Start : constant Landin.Source.Span := Here;
                        begin
                           Resync_Declaration;
                           Complain
                             (Item    => Syn.Stray_Token,
                              Where   => Join (Start, After_Previous),
                              Message => "this begins no declaration",
                              Note    => "[1740]: a file is declarations,"
                                         & " each a binding or a function",
                              Gate    => False);
                        end;
                     end if;

                     if Index = Before then
                        raise Compiler_Defect
                          with "the parser did not advance over a"
                               & " declaration";
                     end if;
                  end;
               end loop;

               return Add
                 (Of_Kind  => Program,
                  At_Token => Tok.Where (From, 1),
                  Children => To_List (Items));
            end Parse_Program;

            --  import_declaration ::= "import" import_path       [1740]
            --  import_path ::= identifier ("/" identifier)*      [1740]
            function Parse_Import (Late : Boolean := False) return Node_Id is
               At_Import : constant Landin.Source.Span := Here;
               Segments  : Slot_Vectors.Vector;
            begin
               pragma Assert (Peek = Tok.Kw_Import);
               Advance;

               if Late then
                  Complain
                    (Item    => Syn.Token_Expected,
                     Where   => At_Import,
                     Message => "an import belongs before every declaration",
                     Note    => "[1450]: imports are a per-file prelude");
               end if;

               loop
                  declare
                     Named   : Landin.Source.Names.Name_Id;
                     At_Name : constant Landin.Source.Span :=
                       Parse_Declared_Name (Named);
                  begin
                     Segments.Append
                       (Add (Import_Segment, At_Name, Named => Named));
                  end;

                  exit when Peek /= Tok.Slash;
                  Advance;
               end loop;

               --  [1430] and [1440] are deliberately still deferred.  Both
               --  shapes are recognized here so [1830] names the construct
               --  instead of reporting unrelated trailing tokens.
               if Peek = Tok.Identifier
                 and then Named_Here = As_Id
                 and then Ahead (1) = Tok.Identifier
               then
                  Refuse
                    (Item    => Syn.Import_Alias,
                     Where   => Here,
                     Message => "import aliases are not enabled yet");
                  Advance;
                  Advance;
               elsif Peek = Tok.Left_Paren then
                  Refuse
                    (Item    => Syn.Selected_Import,
                     Where   => Here,
                     Message => "selected imports are not enabled yet");
                  Advance;
                  Resync_Parentheses;
               end if;

               if Late then
                  return Add
                    (Error_Declaration, At_Import,
                     Extent => Join (At_Import, After_Previous));
               end if;

               return Add
                 (Import_Declaration, At_Import,
                  Extent   => Join (At_Import, After_Previous),
                  Children => To_List (Segments));
            end Parse_Import;

            --  declaration ::= "public"? (binding | function)     [1740]
            --
            --  `identifier ":"` then `(` opens a signature and anything
            --  else is a type, so two tokens past the name decide.  That
            --  is [1800]'s own rule read one position earlier.
            function Parse_Declaration return Node_Id is
               Exported  : Boolean := False;
               Public_At : Landin.Source.Span := Landin.Source.Empty_Span;
            begin
               if Peek = Tok.Kw_Public then
                  Exported := True;
                  Public_At := Here;
                  Advance;
               end if;

               if Peek = Tok.Kw_Import then
                  Complain
                     (Item    => Syn.Token_Expected,
                      Where   => Public_At,
                      Message => "`public` cannot modify an import",
                      Note    => "[1450]: an import is a per-file prelude,"
                                 & " not a declaration");
                  return Parse_Import (Late => True);
               end if;

               --  D139 is deliberately module-declaration syntax.  `fixed`
               --  is reserved for it and type formals; `public fixed` is
               --  parsed for recovery but is not a valid declaration.
               if Peek = Tok.Kw_Fixed then
                  if Exported then
                     Complain
                       (Item    => Syn.Token_Expected,
                        Where   => Public_At,
                        Message => "`public` cannot modify a fixed"
                                   & " conditional",
                        Note    => "D139: a fixed conditional selects module"
                                   & " declarations; it is not a declaration"
                                   & " with an export modifier");
                  end if;
                  return Parse_Fixed_Conditional;
               end if;

               --  R3.50's imported boundary is deliberately one explicit
               --  convention and no body: `extern(c) name: signature`.
               if Peek = Tok.Kw_Extern then
                  declare
                     Extern_At : constant Landin.Source.Span := Here;
                  begin
                     Advance;

                     if Expect
                       (Wanted  => Tok.Left_Paren,
                        Message => "`extern` names its convention in `(`",
                        Note    => "[1580]: `extern(c)` imports a C routine",
                        Related => Extern_At,
                        Because => "introduced here")
                     then
                        if Peek /= Tok.Identifier
                          or else Landin.Source.Names.Spelling
                                    (Names, Named_Here) /= "c"
                        then
                           Complain
                             (Item    => Syn.Token_Expected,
                              Where   => Here,
                              Message => "the hosted boundary supports the"
                                         & " `c` convention",
                              Note    => "[1580]: write `extern(c)`",
                              Related => Extern_At,
                              Because => "introduced here");
                        end if;

                        if Peek = Tok.Identifier then
                           Advance;
                        end if;

                        if not Expect
                          (Wanted  => Tok.Right_Paren,
                           Message => "the external convention is never"
                                      & " closed",
                           Note    => "[1580]: write `extern(c)`",
                           Related => Extern_At,
                           Because => "opened here")
                        then
                           Resync_Declaration;
                        end if;
                     end if;

                     return Parse_Function
                       (Exported, Public_At, External => True,
                        Extern_At => Extern_At);
                  end;
               end if;

               if Peek in Tok.Left_Paren | Tok.Left_Bracket | Tok.Kw_Ptr
                 or else (Peek = Tok.Identifier and then Starts_Conformance)
               then
                  return Parse_Conformance (Exported, Public_At);
               end if;

               if Peek = Tok.Identifier then
                  declare
                     Step : Tok.Token_Index := 1;
                  begin
                     while Ahead (Step) = Tok.Comma
                       and then Ahead (Step + 1) = Tok.Identifier
                     loop
                        Step := Step + 2;
                     end loop;
                     if Ahead (Step) = Tok.Colon
                       and then Ahead (Step + 1) = Tok.Kw_Atom
                     then
                        return Parse_Atom_Declaration
                          (Exported, Public_At);
                     end if;
                  end;
               end if;

               if Peek = Tok.Identifier
                 and then Ahead (1) = Tok.Colon
                 and then Ahead (2) = Tok.Left_Paren
               then
                  return Parse_Function (Exported, Public_At);
               end if;

               --  [1795]: `identifier ":" "type" "=" type`.  Decided the
               --  same way a function is, by what follows the colon.
               if Peek = Tok.Identifier
                 and then Ahead (1) = Tok.Colon
                 and then Ahead (2) = Tok.Kw_Type
               then
                  return Parse_Type_Declaration (Exported, Public_At);
               end if;

               return Parse_Binding (Exported, Public_At);
            end Parse_Declaration;

            --  D139: a fixed conditional is a declaration-list splice, not
            --  a block.  Parse every arm so scanner/parser faults survive
            --  selection; configuration later decides which arm's ordinary
            --  declarations are visible to semantic stages.
            function Parse_Fixed_Conditional return Node_Id is
               At_Fixed : constant Landin.Source.Span := Here;
               Arms     : Slot_Vectors.Vector;
               Is_Else  : Boolean := False;
            begin
               if Too_Deep (At_Fixed) then
                  Advance;
                  Resync_Declaration;
                  return Add
                    (Error_Declaration, At_Fixed,
                     Join (At_Fixed, After_Previous));
               end if;

               Depth := Depth + 1;
               Advance;
               if Peek /= Tok.Kw_If then
                  declare
                     Ignored : constant Boolean := Expect
                       (Wanted  => Tok.Kw_If,
                        Message => "`fixed` conditional is followed by `if`",
                        Note    => "D139: fixed if expression then"
                                   & " declaration* end if",
                        Related => At_Fixed,
                        Because => "this `fixed`");
                  begin
                     pragma Unreferenced (Ignored);
                  end;
               end if;

               loop
                  declare
                     At_Arm : constant Landin.Source.Span :=
                       (if Is_Else then Previous else Here);
                     Condition : Node_Id := No_Node;
                     Items : Slot_Vectors.Vector;
                  begin
                     if not Is_Else then
                        --  The first arm arrives at `if`; later ones at
                        --  `elsif`.  Both words are consumed here.
                        Advance;
                        Condition := Parse_Expression;
                        declare
                           Kept : constant Boolean := Expect
                             (Wanted  => Tok.Kw_Then,
                              Message => "a fixed conditional condition is"
                                         & " followed by `then`",
                              Note    => "D139: fixed if expression then"
                                         & " declaration*",
                              Related => At_Fixed,
                              Because => "this fixed conditional arm");
                        begin
                           pragma Unreferenced (Kept);
                        end;
                     end if;

                     while Peek not in Tok.Kw_Elsif | Tok.Kw_Else | Tok.Kw_End
                       and then Peek /= Tok.End_Of_Input
                     loop
                        declare
                           Before : constant Tok.Token_Index := Index;
                        begin
                           if Pre.Begins_Declaration (Peek)
                             or else Peek = Tok.Kw_Fixed
                           then
                              Items.Append (Parse_Declaration);
                           else
                              Complain
                                (Item    => Syn.Stray_Token,
                                 Where   => Here,
                                 Message => "this begins no declaration in a"
                                            & " fixed conditional arm",
                                 Note    => "D139: an arm contains only"
                                            & " module declarations");
                              Advance;
                           end if;
                           if Index = Before then
                              raise Compiler_Defect
                                with "the parser did not advance in a fixed"
                                     & " conditional arm";
                           end if;
                        end;
                     end loop;

                     Arms.Append
                       (Add
                          (Of_Kind  => Fixed_Arm,
                           At_Token => At_Arm,
                           Extent   => Join (At_Arm, After_Previous),
                           Children => [Condition] & To_List (Items)));
                  end;

                  exit when Is_Else or else Peek /= Tok.Kw_Elsif;
                  Is_Else := False;
                  --  Leave `elsif` in hand for the arm's common reader.
                  --  The next loop consumes it as it does the first `if`.
               end loop;

               if Peek = Tok.Kw_Else then
                  Advance;
                  Is_Else := True;
                  declare
                     Items : Slot_Vectors.Vector;
                     At_Else : constant Landin.Source.Span := Previous;
                  begin
                     while Peek not in Tok.Kw_End | Tok.End_Of_Input loop
                        declare
                           Before : constant Tok.Token_Index := Index;
                        begin
                           if Pre.Begins_Declaration (Peek)
                             or else Peek = Tok.Kw_Fixed
                           then
                              Items.Append (Parse_Declaration);
                           else
                              Complain
                                (Item    => Syn.Stray_Token,
                                 Where   => Here,
                                 Message => "this begins no declaration in a"
                                            & " fixed conditional else arm",
                                 Note    => "D139: an arm contains only"
                                            & " module declarations");
                              Advance;
                           end if;
                           if Index = Before then
                              raise Compiler_Defect
                                with "the parser did not advance in a fixed"
                                     & " conditional else arm";
                           end if;
                        end;
                     end loop;
                     Arms.Append
                       (Add
                          (Of_Kind  => Fixed_Arm,
                           At_Token => At_Else,
                           Extent   => Join (At_Else, After_Previous),
                           Children => [No_Node] & To_List (Items)));
                  end;
               end if;

               Depth := Depth - 1;
               if Peek = Tok.Kw_End and then Ahead (1) = Tok.Kw_If then
                  Advance;
                  Advance;
               else
                  Complain
                    (Item    => Syn.Unclosed_Construct,
                     Where   => After_Previous,
                     Message => "this fixed conditional is never closed",
                     Note    => "D139: a fixed conditional closes with `end`"
                                & " `if`",
                     Related => At_Fixed,
                     Because => "opened here",
                     Gate    => False);
               end if;

               return Add
                 (Of_Kind  => Fixed_Conditional,
                  At_Token => At_Fixed,
                  Extent   => Join (At_Fixed, After_Previous),
                  Children => To_List (Arms));
            end Parse_Fixed_Conditional;

            ------------------------------------------------------------
            --  Names, types, bindings                     [1760] [1790]
            ------------------------------------------------------------

            --  Every position the grammar spells `identifier` in comes
            --  through here, so [1760]'s two narrowings are stated once:
            --  a word the keyword rule spells is that keyword, and the
            --  lone `_` is [1020]'s discard.
            function Parse_Declared_Name
              (Named : out Landin.Source.Names.Name_Id)
              return Landin.Source.Span
            is
               At_Name : constant Landin.Source.Span := Here;
            begin
               Named := Landin.Source.Names.No_Name;

               --  P1: a token no kernel rule spells stands in for the
               --  name, silently.  The scanner already reported it, and a
               --  second complaint about the same bytes is noise.
               if Peek not in Tok.Kernel_Kind then
                  Mark_Reported;
                  Advance;
                  return At_Name;
               end if;

               if Peek = Tok.Identifier then
                  Named := Named_Here;
                  Advance;
                  if Named = Compiler_Id then
                     Complain
                       (Item    => Syn.Name_Expected,
                        Where   => At_Name,
                        Message => "`compiler` is reserved for the"
                                   & " toolchain intrinsic root",
                        Note    => "[1480]: bare toolchain module names are"
                                   & " not available to declarations");
                     Named := Landin.Source.Names.No_Name;
                  end if;
                  return At_Name;
               end if;

               Complain
                 (Item    => Syn.Name_Expected,
                  Where   => (if Peek = Tok.End_Of_Input
                              then After_Previous else At_Name),
                  Message =>
                    (if Peek in Tok.Reserved_Word
                     then "`" & Tok.Spelling (Peek)
                          & "` is a keyword, and no keyword is available"
                          & " as a name"
                     elsif Peek = Tok.Underscore
                     then "`_` on its own is the discard, and nothing may"
                          & " be called it"
                     else "a name belongs here"),
                  Note    => "[1760]: a name is lower case, and a word the"
                             & " keyword rule spells is that keyword");

               if Peek /= Tok.End_Of_Input then
                  Advance;
               end if;

               return At_Name;
            end Parse_Declared_Name;

            --  A module qualifier is the same left-to-right selection node
            --  in value, type and concept positions.  Resolution decides
            --  whether the leading name is this file's imported namespace;
            --  the parser only retains each selected spelling.
            function Parse_Qualified_Reference
              (Of_Kind : Node_Kind) return Node_Id
            is
               Named  : Landin.Source.Names.Name_Id;
               At_Name : constant Landin.Source.Span :=
                 Parse_Declared_Name (Named);
               Result : Node_Id := Add (Of_Kind, At_Name, Named => Named);
            begin
               while Peek = Tok.Dot loop
                  Advance;
                  declare
                     Member : Landin.Source.Names.Name_Id;
                     At_Member : constant Landin.Source.Span :=
                       Parse_Declared_Name (Member);
                  begin
                     Result := Add
                       (Member_Selection, At_Member,
                        Children => [1 => Result],
                        Named    => Member);
                  end;
               end loop;
               return Result;
            end Parse_Qualified_Reference;

            --  [1820]'s `indexed`, read after whatever named the thing:
            --  the dots first and then the brackets, left to right, so
            --  `a.b[i]` indexes what `a.b` named.  A selected name is
            --  carried on the node rather than being a Name_Reference,
            --  because no scope [1090] answers for a field.
            function Parse_Selectors (From : Node_Id) return Node_Id;

            --  Steps over a refused bracketed run so one report does not
            --  become three: the brackets are kernel tokens now, so what
            --  is between them parses as ordinary tokens and only the
            --  nesting says where it ends.
            procedure Resync_Brackets;

            --  [0570]'s index, wherever one can be written.  Separate
            --  from the selection loop because a call is not a selection
            --  in [1820] -- `size().x` derives in no rule this grammar
            --  spells -- while `size()[0]` is an index like any other and
            --  has to name itself rather than becoming a stray token.
            procedure Refuse_Any_Index;

            procedure Refuse_Any_Index is
            begin
               if Peek = Tok.Left_Bracket then
                  Refuse
                    (Item    => Syn.Indexing,
                     Where   => Here,
                     Message => "indexing is not enabled yet");
                  Resync_Brackets;
               end if;
            end Refuse_Any_Index;

            procedure Resync_Brackets is
               Depth : Natural := 0;
            begin
               while Peek /= Tok.End_Of_Input loop
                  if Peek = Tok.Left_Bracket then
                     Depth := Depth + 1;
                  elsif Peek = Tok.Right_Bracket then
                     Depth := Depth - 1;
                     Advance;
                     exit when Depth = 0;
                     goto Continue;
                  end if;

                  Advance;
                  <<Continue>>
               end loop;
            end Resync_Brackets;

            procedure Resync_Parentheses is
               Depth : Natural := 1;
            begin
               while Peek /= Tok.End_Of_Input loop
                  if Peek = Tok.Left_Paren then
                     Depth := Depth + 1;
                  elsif Peek = Tok.Right_Paren then
                     Depth := Depth - 1;
                     Advance;
                     exit when Depth = 0;
                     goto Continue;
                  end if;

                  Advance;
                  <<Continue>>
               end loop;
            end Resync_Parentheses;

            function Parse_Selectors (From : Node_Id) return Node_Id is
               Selected : Node_Id := From;
            begin
               --  [1820] spells `selection (("[" expression "]")
               --  | ("." identifier))*`, so a dot and a bracket may follow
               --  each other in either order and as often as the source
               --  writes them -- which is what the tour writes at
               --  `w.items[i].x`.  A call and a parenthesis are each their
               --  own production and neither reaches this loop, so what it
               --  reads is exactly what `indexed` derives.
               loop
                  --  indexed ::= selection (("[" expression "]")
                  --                            | ("." identifier))*  [1820]
                  if Peek = Tok.Left_Bracket then
                     declare
                        At_Open : constant Landin.Source.Span := Here;
                        Index   : Node_Id;
                     begin
                        Advance;
                        Index := Parse_Expression;

                        if Peek in Tok.Dot_Dot | Tok.Dot_Dot_Less then
                           declare
                              Form : constant Node_Kind :=
                                (if Peek = Tok.Dot_Dot
                                 then Inclusive_Slice else Half_Open_Slice);
                              Upper : Node_Id;
                           begin
                              Advance;
                              Upper := Parse_Expression;
                              if not Expect
                                (Wanted  => Tok.Right_Bracket,
                                 Message => "a slice is closed with `]`",
                                 Note    => "[0570]: a range between the"
                                            & " brackets selects a slice",
                                 Related => At_Open,
                                 Because => "opened here")
                              then
                                 return Add
                                   (Form, At_Open,
                                    Extent => Join
                                      (At_Open, After_Previous),
                                    Children => [Selected, Index, Upper]);
                              end if;
                              Selected := Add
                                (Form, At_Open,
                                 Extent => Join (At_Open, After_Previous),
                                 Children => [Selected, Index, Upper]);
                           end;
                        else
                           if not Expect
                                    (Wanted  => Tok.Right_Bracket,
                                     Message => "an index is closed with `]`",
                                     Note    => "[1820]: `[` opens an index"
                                                & " and `]` closes it",
                                     Related => At_Open,
                                     Because => "opened here")
                           then
                              return Add
                                (Element_Index, At_Open,
                                 Extent   => Join (At_Open, After_Previous),
                                 Children => [Selected, Index]);
                           end if;

                           Selected :=
                             Add (Element_Index, At_Open,
                                  Extent   => Join (At_Open, After_Previous),
                                  Children => [Selected, Index]);
                        end if;
                     end;

                     goto Next;
                  end if;

                  exit when Peek /= Tok.Dot;

                  declare
                     Named   : Landin.Source.Names.Name_Id;
                     At_Name : Landin.Source.Span;
                  begin
                     Advance;

                     --  The anchor is the field's own name, because that
                     --  is what a report about the selection points at.
                     At_Name := Parse_Declared_Name (Named);
                     Selected :=
                       Add (Member_Selection, At_Name,
                            Children => [Selected],
                            Named    => Named);
                  end;

                  <<Next>>
               end loop;

               return Selected;
            end Parse_Selectors;

            --  place ::= selection                                [1810]
            --
            --  The same rule an expression reads, because a field is
            --  written exactly as it is read and [1900] decides which
            --  places may be written rather than this production.
            function Parse_Place return Node_Id is
               Named   : Landin.Source.Names.Name_Id;
               At_Name : constant Landin.Source.Span :=
                 Parse_Declared_Name (Named);
               Place : constant Node_Id :=
                 Parse_Selectors
                   (Add (Name_Reference, At_Name, Named => Named));
            begin
               return Place;
            end Parse_Place;

            --  D135's parenthesized positional application.  It is a type
            --  production, not a call: its operands are types or fixed
            --  integer arguments, and no expression can reach this reader.
            function Parse_Type_Application
              (Target : Node_Id;
               Starts : Landin.Source.Span) return Node_Id
            is
               Arguments : Slot_Vectors.Vector;
            begin
               pragma Assert (Peek = Tok.Left_Paren);
               Advance;

               loop
                  if Peek = Tok.Integer_Literal then
                     declare
                        Item : constant Tok.Token :=
                          Tok.Token_At (From, Index);
                     begin
                        Arguments.Append
                          (Add (Integer_Literal, Here,
                                Radix     => Tok.Base (Item),
                                Digits_At => Tok.Digit_Span (Item)));
                     end;
                     Advance;
                  elsif Peek in Tok.Identifier | Tok.Left_Bracket
                               | Tok.Left_Paren | Tok.Kw_Any | Tok.Kw_Ptr
                  then
                     Arguments.Append (Parse_Type (False, Starts));
                  else
                     Complain
                       (Item    => Syn.Type_Expected,
                        Where   => (if Peek = Tok.End_Of_Input
                                    then After_Previous else Here),
                        Message => "a type or fixed integer belongs in a"
                                   & " type application",
                        Note    => "D135: type arguments are positional",
                        Related => Starts,
                        Because => "the applied type");
                     Arguments.Append (Add (Error_Type, After_Previous));
                     exit;
                  end if;

                  exit when Peek /= Tok.Comma;
                  Advance;
               end loop;

               if not Expect
                 (Wanted  => Tok.Right_Paren,
                  Message => "a type application's arguments close with `)`",
                  Note    => "D135: `(` opens the positional arguments",
                  Related => Starts,
                  Because => "the applied type")
               then
                  Resync (List_Anchor);
                  if Peek = Tok.Right_Paren then
                     Advance;
                  end if;
               end if;

               declare
                  Head : constant Slot_List (1 .. 1) := [Target];
               begin
                  return Add
                    (Of_Kind  => Type_Application,
                     At_Token => Starts,
                     Extent   => Join (Starts, After_Previous),
                     Children => Head & To_List (Arguments));
               end;
            end Parse_Type_Application;

            --  type ::= the scalar names                          [1790]
            --
            --  Not a closed set of keywords: [1760] says u32 and bool are
            --  ordinary declared names the kernel predeclares, so this
            --  compares interned identities and not token kinds.
            function Parse_Type
              (In_Parameter : Boolean;
               Declared_At  : Landin.Source.Span) return Node_Id
            is
               At_Type : constant Landin.Source.Span := Here;

            begin
               Type_Refused := False;

               --  [1795] makes `type` a keyword, so a type position that
               --  holds one is met here by kind rather than by spelling.
               --  In a parameter it is [1290]'s type parameter and
               --  elsewhere it is [0120]'s declaration written where a
               --  type belongs; naming which is the difference between
               --  "not enabled yet" and "not a type".
               if Peek = Tok.Kw_Type then
                  Type_Refused := True;
                  Refuse
                    (Item    => (if In_Parameter then Syn.Type_Parameter
                                 else Syn.Declared_Type),
                     Where   => At_Type,
                     Message => "`type` is not enabled yet");
                  Advance;
                  return Add (Error_Type, At_Type);
               end if;

               --  D117: the infallible signature syntax is also one written
               --  type.  Parameter and return names describe the signature;
               --  they do not introduce declarations at the use site.
               if Peek = Tok.Left_Paren then
                  if Starts_Signature then
                     declare
                        Params       : Slot_Vectors.Vector;
                        Returns_Node : Node_Id := No_Node;
                        Returns_At   : Landin.Source.Span :=
                          Landin.Source.Empty_Span;
                        Errors_Node  : Node_Id := No_Node;
                     begin
                        Advance;

                        if Peek /= Tok.Right_Paren then
                           loop
                              declare
                                 Before : constant Tok.Token_Index := Index;
                              begin
                                 Params.Append (Parse_Parameter);
                                 exit when Index = Before;
                              end;

                              exit when Peek /= Tok.Comma;
                              Advance;
                           end loop;
                        end if;

                        if not Expect
                          (Wanted  => Tok.Right_Paren,
                           Message => "the function type's parameter list"
                                      & " is never closed",
                           Note    => "D117: a function type is `(`"
                                      & " parameters? `)` `->` returns",
                           Related => Declared_At,
                           Because => "the type written here")
                        then
                           Resync (List_Anchor);
                           if Peek = Tok.Right_Paren then
                              Advance;
                           end if;
                        end if;

                        if Expect
                          (Wanted  => Tok.Minus_Greater,
                           Message => "a function type says what it returns"
                                      & " after `->`",
                           Note    => "D117: a function type is `(`"
                                      & " parameters? `)` `->` returns",
                           Related => Declared_At,
                           Because => "the type written here")
                        then
                           Returns_Node :=
                             Parse_Returns (Declared_At, Returns_At);
                        end if;

                        Errors_Node := Parse_Errors (Declared_At);

                        declare
                           Head : constant Slot_List (1 .. 2) :=
                             [Returns_Node, Errors_Node];
                        begin
                           return Add
                             (Of_Kind  => Function_Type,
                              At_Token => At_Type,
                              Extent   => Join (At_Type, After_Previous),
                              Children => Head & To_List (Params));
                        end;
                     end;
                  end if;

                  --  [0670]'s inline form is also a parameter, return and
                  --  payload list.  Without a following arrow it remains a
                  --  struct and retains the existing refusal and recovery.
                  Type_Refused := True;
                  Refuse
                    (Item    => Syn.Struct_Type,
                     Where   => At_Type,
                     Message => "a struct is not enabled yet");
                  --  The `(` is left where it is: Resync_Declaration
                  --  counts nesting from here, and skipping it first
                  --  would leave `x: i32` looking like the next
                  --  declaration.
                  return Add (Error_Type, At_Type);
               end if;

               if Peek not in Tok.Kernel_Kind then
                  Mark_Reported;
                  Advance;
                  return Add (Error_Type, At_Type);
               end if;

               --  any_type ::= "any" concept_reference            [1790]
               if Peek = Tok.Kw_Any then
                  Advance;
                  if Peek /= Tok.Identifier then
                     Complain
                       (Item    => Syn.Type_Expected,
                        Where   => (if Peek = Tok.End_Of_Input
                                    then After_Previous else Here),
                        Message => "`any` requires one concept name",
                        Note    => "[1370]: `any C` erases one value behind"
                                   & " concept C",
                        Related => At_Type,
                        Because => "the runtime-dispatch type");
                     return Add
                       (Any_Type, At_Type,
                        Children => [1 => Add (Error_Type, Point)]);
                  end if;
                  declare
                     Concept : constant Node_Id :=
                       Parse_Qualified_Reference (Concept_Reference);
                  begin
                     return Add
                       (Any_Type, At_Type,
                        Extent => Join (At_Type, After_Previous),
                        Children => [1 => Concept]);
                  end;
               end if;

               --  pointer_type ::= "ptr" "mut"? type             [1790]
               --
               --  Permission is a retained syntax fact.  Whether the target
               --  is a legal pointee and how it is represented belong to the
               --  later R2.50 checking and layout increments.
               if Peek = Tok.Kw_Ptr then
                  declare
                     Writable : Boolean := False;
                     Target   : Node_Id;
                  begin
                     Advance;
                     if Peek = Tok.Kw_Mut then
                        Writable := True;
                        Advance;
                     end if;
                     Target := Parse_Type (In_Parameter, Declared_At);
                     return Add
                       (Pointer_Type, At_Type,
                        Extent   => Join (At_Type, After_Previous),
                        Children => [1 => Target],
                        Mutable  => Writable);
                  end;
               end if;

               --  array_type ::= "[" expression "]" type         [1790]
               --  slice_type ::= "[" "]" "mut"? type             [1790]
               --
               --  D136 gives an array bound expression its closed fixed fold.
               --  Parse
               --  the ordinary expression grammar here so a call remains
               --  syntactically valid and the checker can reject it for not
               --  being fixed without ever executing the routine.
               --  The element is a type like any other, so this recurses
               --  and `[2][3]u8` derives; which elements the kernel can
               --  lay out is the checker's to say, not this stage's.
               if Peek = Tok.Left_Bracket then
                  --  [0570]'s slice is a view and not an array: nothing
                  --  between the brackets distinguishes it without a
                  --  lookahead or a checker decision.
                  if Ahead (1) = Tok.Right_Bracket then
                     declare
                        Writable : Boolean := False;
                        Element  : Node_Id;
                     begin
                        Advance;
                        Advance;
                        if Peek = Tok.Kw_Mut then
                           Writable := True;
                           Advance;
                        end if;
                        Element := Parse_Type (In_Parameter, Declared_At);
                        return Add
                          (Slice_Type, At_Type,
                           Extent   => Join (At_Type, After_Previous),
                           Children => [1 => Element],
                           Mutable  => Writable);
                     end;
                  end if;

                  declare
                     Bound   : Node_Id := No_Node;
                     Element : Node_Id := No_Node;
                  begin
                     Advance;

                     if Pre.Begins_Expression (Peek) then
                        Bound := Parse_Expression;
                     else
                        Complain
                          (Item    => Syn.Expression_Expected,
                           Where   => (if Peek = Tok.End_Of_Input
                                       then After_Previous else Here),
                           Message => "an array's fixed length belongs here",
                           Note    => "[1790]: the bound is an expression"
                                      & " and the length is part of the"
                                      & " type [0520]",
                           Related => At_Type,
                           Because => "this array");
                        Bound := Add (Error_Expression, Point);
                     end if;

                     if not Expect
                              (Wanted  => Tok.Right_Bracket,
                               Message => "an array's length is closed"
                                          & " with `]`",
                               Note    => "[1790]: `[` opens the length"
                                          & " and `]` closes it",
                               Related => At_Type,
                               Because => "opened here")
                     then
                        return Add
                          (Array_Type, At_Type,
                           Extent   => Join (At_Type, After_Previous),
                           Children => [Bound, Add (Error_Type, Point)]);
                     end if;

                     Element := Parse_Type (In_Parameter, Declared_At);
                     return Add
                       (Array_Type, At_Type,
                        Extent   => Join (At_Type, After_Previous),
                        Children => [Bound, Element]);
                  end;
               end if;

               --  [0650]'s `distinct` is not reserved, so only the parser
               --  can meet it, and [1795] made a type position somewhere a
               --  name may stand -- without this it reads as a type name
               --  and the report is about the token after it.
               if Word_At_Hand = Word_Distinct then
                  Type_Refused := True;
                  Refuse
                    (Item    => Syn.Distinct_Type,
                     Where   => At_Type,
                     Message => "`distinct` is not enabled yet");
                  Advance;
                  return Add (Error_Type, At_Type);
               end if;

               if Peek = Tok.Identifier then
                  declare
                     Spelled : constant Landin.Source.Names.Name_Id :=
                       Named_Here;
                  begin
                     for Item in Scalar_Name loop
                        if Scalar_Id (Item) = Spelled then
                           Advance;
                           declare
                              Base : constant Node_Id :=
                                Add (Type_Name, At_Type, Named => Spelled);
                           begin
                              return
                                (if Peek = Tok.Left_Paren
                                 then Parse_Type_Application (Base, At_Type)
                                 else Base);
                           end;
                        end if;
                     end loop;

                     --  [1795] lets a program declare a type, so a name
                     --  that is not one of the built-in scalars is no
                     --  longer wrong
                     --  here: whether it names one is resolution's to
                     --  answer, and this stage stops guessing.
                     declare
                        Base : constant Node_Id :=
                          Parse_Qualified_Reference (Type_Reference);
                     begin
                        return
                          (if Peek = Tok.Left_Paren
                           then Parse_Type_Application (Base, At_Type)
                           else Base);
                     end;
                  end;
               end if;

               --  A token the enclosing construct can still use means the
               --  type is simply absent, and nothing is consumed; anything
               --  else is a wrong type and is consumed so the parse moves.
               if Peek in Tok.Equal | Tok.Colon_Equal | Tok.Comma
                          | Tok.Right_Paren | Tok.Minus_Greater
                          | Tok.End_Of_Input | Tok.Kw_Public | Tok.Kw_Mut
                          | Tok.Kw_End | Tok.Kw_Return | Tok.Kw_If
                          | Tok.Kw_Inc | Tok.Kw_Dec | Tok.Underscore
               then
                  Complain
                    (Item    => Syn.Type_Expected,
                     Where   => After_Previous,
                     Message => "a type belongs here",
                     Note    => "[1790]: the kernel's types are the scalar"
                                & " names only",
                     Related => Declared_At,
                     Because => "declared here");
                  return Add (Error_Type, After_Previous);
               end if;

               Complain
                 (Item    => Syn.Type_Expected,
                  Where   => At_Type,
                  Message => "this is not a type",
                  Note    => "[1790]: the kernel's types are the scalar"
                             & " names only",
                  Related => Declared_At,
                  Because => "declared here");
               Advance;
               return Add (Error_Type, At_Type);
            end Parse_Type;

            --  atom_declaration ::= identifiers ":" "atom"      [0630]
            --  identifiers ::= identifier ("," identifier)*
            function Parse_Atom_Declaration
              (Exported  : Boolean;
               Public_At : Landin.Source.Span) return Node_Id
            is
               Start : constant Landin.Source.Span :=
                 (if Exported then Public_At else Here);
               Named   : Landin.Source.Names.Name_Id;
               At_Name : constant Landin.Source.Span :=
                 Parse_Declared_Name (Named);
               More : Slot_Vectors.Vector;
            begin
               while Peek = Tok.Comma loop
                  Advance;
                  declare
                     Next_Name : Landin.Source.Names.Name_Id;
                     At_Next : constant Landin.Source.Span :=
                       Parse_Declared_Name (Next_Name);
                  begin
                     More.Append
                       (Add (Of_Kind  => Atom_Declaration,
                             At_Token => At_Next,
                             Named    => Next_Name,
                             Exported => Exported));
                  end;
               end loop;

               --  The lookahead in Parse_Declaration established both.
               Advance;
               Advance;
               return Add
                 (Of_Kind  => Atom_Declaration,
                  At_Token => At_Name,
                  Extent   => Join (Start, After_Previous),
                  Children => To_List (More),
                  Named    => Named,
                  Exported => Exported);
            end Parse_Atom_Declaration;

            --  D135's parameters are parsed only after a type declaration's
            --  `type`, never after a function's leading `(`.  `fixed` is a
            --  reserved word so a normal declaration cannot quietly use it.
            procedure Parse_Type_Formals
              (Declared_At : Landin.Source.Span;
               Into        : in out Slot_Vectors.Vector;
               Closed      : out Boolean)
            is
               Opened : constant Landin.Source.Span := Here;
            begin
               pragma Assert (Peek = Tok.Left_Paren);
               Closed := False;
               Advance;

               if Peek = Tok.Right_Paren then
                  Complain
                    (Item    => Syn.Type_Expected,
                     Where   => After_Previous,
                     Message => "a parameterized alias has at least one"
                                & " formal",
                     Note    => "D135: type_formals is a nonempty list",
                     Related => Opened,
                     Because => "opened here");
               end if;

               while Peek /= Tok.Right_Paren
                 and then Peek /= Tok.End_Of_Input
               loop
                  declare
                     Fixed : constant Boolean := Peek = Tok.Kw_Fixed;
                     Starts : constant Landin.Source.Span := Here;
                     Named : Landin.Source.Names.Name_Id;
                     At_Name : Landin.Source.Span;
                     Of_Type : Node_Id := No_Node;
                     Constraint : Node_Id := No_Node;
                  begin
                     if Fixed then
                        Advance;
                     end if;

                     At_Name := Parse_Declared_Name (Named);
                     if Expect
                       (Wanted  => Tok.Colon,
                        Message => "a type formal names its type after `:`",
                        Note    => "D135: a formal is `name: type` or"
                                   & " `fixed name: type`",
                        Related => Declared_At,
                        Because => "the type declaration")
                     then
                        if Fixed then
                           Of_Type := Parse_Type (False, At_Name);
                        elsif Peek = Tok.Kw_Type then
                           Advance;
                           if Peek = Tok.Identifier
                             and then Named_Here = Is_Id
                           then
                              Advance;
                              if Peek = Tok.Identifier then
                                 Constraint := Parse_Qualified_Reference
                                   (Concept_Reference);
                              else
                                 Complain
                                   (Item    => Syn.Name_Expected,
                                    Where   => (if Peek = Tok.End_Of_Input
                                                then After_Previous
                                                else Here),
                                    Message => "a type constraint names a"
                                               & " concept after `is`",
                                    Note    => "[1290]: a type formal may"
                                               & " name one direct concept");
                                 Constraint := Add
                                   (Error_Type, After_Previous);
                              end if;
                           end if;
                        else
                           Complain
                             (Item    => Syn.Type_Expected,
                              Where   => (if Peek = Tok.End_Of_Input
                                          then After_Previous else Here),
                              Message => "a type formal is declared with"
                                         & " `type`",
                              Note    => "D135: `name: type` declares a"
                                         & " type formal",
                              Related => At_Name,
                              Because => "the formal named here");
                           Of_Type := Add (Error_Type, After_Previous);
                        end if;
                     else
                        Of_Type := Add (Error_Type, After_Previous);
                     end if;

                     Into.Append
                       (Add
                          (Of_Kind  =>
                             (if Fixed then Fixed_Formal else Type_Formal),
                           At_Token => (if Fixed then Starts else At_Name),
                           Extent   => Join (Starts, After_Previous),
                           Children =>
                             (if Fixed then [Of_Type] else [Constraint]),
                           Named    => Named));
                  end;

                  exit when Peek /= Tok.Comma;
                  Advance;
               end loop;

               Closed := Expect
                 (Wanted  => Tok.Right_Paren,
                  Message => "a type declaration's formals close with `)`",
                  Note    => "D135: `(` opens the type formal list",
                  Related => Opened,
                  Because => "opened here");
               if not Closed then
                  --  If the list ended at a declaration opener, it belongs
                  --  to the program loop, not this failed formal list.
                  if not Declaration_Anchor (Peek) then
                     Resync_Declaration;
                  end if;
               end if;
            end Parse_Type_Formals;

            --  binding ::= "mut"? identifier ":" type ("=" expression)?
            --            | "mut"? identifier ":=" expression      [1790]
            --  `identifier ":" "type" "=" type` [1795].  The name is
            --  parsed the way every declared name is, so [1760]'s two
            --  narrowings hold for a type name unchanged.
            function Parse_Type_Declaration
              (Exported  : Boolean;
               Public_At : Landin.Source.Span) return Node_Id
            is
               Start : constant Landin.Source.Span :=
                 (if Exported then Public_At else Here);
               Named   : Landin.Source.Names.Name_Id;
               At_Name : constant Landin.Source.Span :=
                 Parse_Declared_Name (Named);
               Aliased_Type : Node_Id := No_Node;
               Formals : Slot_Vectors.Vector;
               Formals_Closed : Boolean := True;
            begin
               --  The colon and the word are what brought us here.
               Advance;
               Advance;

               if Peek = Tok.Left_Paren then
                  Parse_Type_Formals (At_Name, Formals, Formals_Closed);
               end if;

               if not Formals_Closed then
                  --  Parse_Type_Formals has already reported the missing
                  --  closer.  Leave a following declaration opener untouched
                  --  for Parse_Program rather than consuming it while looking
                  --  for this declaration's `=` and body.
                  Aliased_Type := Add (Error_Type, After_Previous);
               elsif Expect
                    (Wanted  => Tok.Equal,
                     Message => "a type declaration names a type after `=`",
                     Note    => "[1795]: name `:` `type` `=` type",
                     Related => At_Name,
                     Because => "declared here")
               then
                  --  `concept` is contextual, so an ordinary declaration
                  --  named concept remains legal; only this exact position
                  --  opens [1230]'s body and its post-keyword formal list.
                  if Formals.Is_Empty
                    and then Peek = Tok.Identifier
                    and then Named_Here = Concept_Id
                  then
                     declare
                        Concept_Node : constant Node_Id :=
                          Parse_Concept_Body (Named, At_Name);
                     begin
                        return Add
                          (Of_Kind  => Concept_Declaration,
                           At_Token => At_Name,
                           Extent   => Join (Start, After_Previous),
                           Children => [Concept_Node],
                           Named    => Named,
                           Exported => Exported);
                     end;

                  --  [1795] permits a name, or [0670]'s block form, after
                  --  either a bare declaration or D135's formal list.  The
                  --  latter carries syntax and resolution only in this slice;
                  --  checking decides its later nominal meaning.
                  elsif Peek = Tok.Kw_Struct then
                     Aliased_Type := Parse_Struct_Body (Named, At_Name);
                  else
                     Aliased_Type := Parse_Type (False, At_Name);

                     --  [0640]: a union is a nonempty run of atom type
                     --  names.  Parse_Type read the first name; only a type
                     --  declaration admits the following bars, so ordinary
                     --  expression precedence remains untouched.
                     if not Type_Refused
                       and then Peek = Tok.Bar
                       and then not Formals.Is_Empty
                     then
                        --  D135 admits a parameterized alias or struct.  An
                        --  atom union is a separate declaration alternative in
                        --  [1795], not a `type` body, so retaining an
                        --  Atom_Union_Type here would accept syntax the
                        --  grammar excludes.
                        Type_Refused := True;
                        Refuse
                          (Item    => Syn.Parameterized_Atom_Union,
                           Where   => Here,
                           Message => "a parameterized atom union is not"
                                      & " enabled");
                        Resync_Declaration;
                     elsif not Type_Refused and then Peek = Tok.Bar then
                        declare
                           Members : Slot_Vectors.Vector;
                           Starts  : constant Landin.Source.Span :=
                             Where (Result, Aliased_Type);
                        begin
                           Members.Append (Aliased_Type);
                           while Peek = Tok.Bar loop
                              Advance;
                              if Peek = Tok.Identifier then
                                 declare
                                    At_Member : constant Landin.Source.Span :=
                                      Here;
                                    Named_Member : constant
                                      Landin.Source.Names.Name_Id :=
                                        Named_Here;
                                 begin
                                    Advance;
                                    Members.Append
                                      (Add (Type_Reference, At_Member,
                                            Named => Named_Member));
                                 end;
                              else
                                 Complain
                                   (Item    => Syn.Type_Expected,
                                    Where   =>
                                      (if Peek = Tok.End_Of_Input
                                       then After_Previous else Here),
                                    Message => "an atom type name belongs"
                                               & " after `|`",
                                    Note    => "[0640]: an atom union is a"
                                               & " nonempty run of atom"
                                               & " type names",
                                    Related => At_Name,
                                    Because => "the type declared here");
                                 exit;
                              end if;
                           end loop;
                           Aliased_Type := Add
                             (Of_Kind  => Atom_Union_Type,
                              At_Token => Starts,
                              Extent   => Join (Starts, After_Previous),
                              Children => To_List (Members));
                        end;
                     elsif Type_Refused then
                        Resync_Declaration;
                     end if;
                  end if;
               else
                  Resync_Declaration;
               end if;

               return Add
                 (Of_Kind  => Type_Declaration,
                  At_Token => At_Name,
                  Extent   => Join (Start, After_Previous),
                  Children => [Aliased_Type] & To_List (Formals),
                  Named    => Named,
                  Exported => Exported);
            end Parse_Type_Declaration;

            --  [1230]'s contextual concept body.  Its requirement entries
            --  deliberately reuse the ordinary signature parts but never a
            --  routine declaration: they have no body and create no value.
            function Parse_Concept_Body
              (Named   : Landin.Source.Names.Name_Id;
               At_Name : Landin.Source.Span) return Node_Id
            is
               At_Concept : constant Landin.Source.Span := Here;
               Items      : Slot_Vectors.Vector;
               Closed     : Boolean := True;

               function Parse_Entry return Node_Id;

               function Parse_Entry return Node_Id is
                  Entry_Name : Landin.Source.Names.Name_Id;
                  At_Entry   : constant Landin.Source.Span :=
                    Parse_Declared_Name (Entry_Name);
                  Params     : Slot_Vectors.Vector;
                  Returns    : Node_Id := No_Node;
                  Returns_At : Landin.Source.Span :=
                    Landin.Source.Empty_Span;
                  Errors     : Node_Id := No_Node;
               begin
                  if Expect
                    (Wanted  => Tok.Colon,
                     Message => "a concept entry names its signature after"
                                & " `:`",
                     Note    => "[1230]: a concept body contains named"
                                & " signature-only entries",
                     Related => At_Entry,
                     Because => "the entry named here")
                    and then Expect
                      (Wanted  => Tok.Left_Paren,
                       Message => "a concept entry signature opens with `(`",
                       Note    => "[1230]: a requirement is a named"
                                  & " signature without `=` or a body",
                       Related => At_Entry,
                       Because => "the entry named here")
                  then
                     if Peek /= Tok.Right_Paren then
                        loop
                           declare
                              Before : constant Tok.Token_Index := Index;
                           begin
                              Params.Append (Parse_Parameter);
                              exit when Index = Before;
                           end;
                           exit when Peek /= Tok.Comma;
                           Advance;
                        end loop;
                     end if;

                     if not Expect
                       (Wanted  => Tok.Right_Paren,
                        Message => "a concept entry's parameters close with"
                                   & " `)`",
                        Note    => "[1230]: the signature has an ordinary"
                                   & " parameter list",
                        Related => At_Entry,
                        Because => "the entry named here")
                     then
                        Resync (List_Anchor);
                        if Peek = Tok.Right_Paren then
                           Advance;
                        end if;
                     end if;
                  end if;

                  if Expect
                    (Wanted  => Tok.Minus_Greater,
                     Message => "a concept entry says what it returns after"
                                & " `->`",
                     Note    => "[1230]: a requirement retains a complete"
                                & " routine signature",
                     Related => At_Entry,
                     Because => "the entry named here")
                  then
                     Returns := Parse_Returns (At_Entry, Returns_At);
                  end if;
                  Errors := Parse_Errors (At_Entry);

                  declare
                     Head : constant Slot_List (1 .. 2) := [Returns, Errors];
                  begin
                     return Add
                       (Of_Kind  => Concept_Entry,
                        At_Token => At_Entry,
                        Extent   => Join (At_Entry, After_Previous),
                        Children => Head & To_List (Params),
                        Named    => Entry_Name);
                  end;
               end Parse_Entry;
            begin
               pragma Unreferenced (At_Name);
               --  Parse_Type_Declaration identified this contextual word.
               Advance;

               if Peek = Tok.Left_Paren then
                  Parse_Type_Formals (At_Concept, Items, Closed);
               else
                  Closed := Expect
                    (Wanted  => Tok.Left_Paren,
                     Message => "a concept names its type formals in `(`"
                                & " `)`",
                     Note    => "[1230]: concept (T: type, ...) is its"
                                & " requirement signature",
                     Related => At_Concept,
                     Because => "this concept");
               end if;

               if Closed and then Peek = Tok.Identifier
                 and then Named_Here = Is_Id
               then
                  Advance;
                  loop
                     if Peek = Tok.Identifier then
                        Items.Append
                          (Parse_Qualified_Reference (Concept_Reference));
                     else
                        Complain
                          (Item    => Syn.Name_Expected,
                           Where   => (if Peek = Tok.End_Of_Input
                                       then After_Previous else Here),
                           Message => "a concept parent belongs after `is`",
                           Note    => "[1340]: parent concepts are direct"
                                      & " names");
                        exit;
                     end if;
                     exit when Peek /= Tok.Comma;
                     Advance;
                  end loop;
               end if;

               --  An entry has `name: (`; that lookahead leaves an ordinary
               --  following declaration in hand when a missing `end` ends
               --  this body, instead of absorbing it as a broken entry.
               while Peek = Tok.Identifier and then Ahead (1) = Tok.Colon
                 and then Ahead (2) = Tok.Left_Paren
               loop
                  Items.Append (Parse_Entry);
               end loop;

               if Peek = Tok.Kw_End then
                  Advance;
                  if Peek = Tok.Identifier then
                     if Named_Here /= Named then
                        Complain
                          (Item    => Syn.End_Name_Mismatch,
                           Where   => Here,
                           Message => "this name does not close the concept",
                           Note    => "[1230]: `end` may repeat the concept"
                                      & " name",
                           Related => At_Concept,
                           Because => "opened here");
                     end if;
                     Advance;
                  end if;
               else
                  Complain
                    (Item    => Syn.Unclosed_Construct,
                     Where   => After_Previous,
                     Message => "this concept is never closed",
                     Note    => "[1230]: a concept closes with `end` and an"
                                & " optional matching name",
                     Related => At_Concept,
                     Because => "opened here",
                     Gate    => False);
               end if;

               return Add
                 (Of_Kind  => Concept_Body,
                  At_Token => At_Concept,
                  Extent   => Join (At_Concept, After_Previous),
                  Children => To_List (Items));
            end Parse_Concept_Body;

            --  [1240]'s optional generic binder, target type, direct
            --  contextual concept name and labelled source RHS run.
            function Parse_Conformance
              (Exported  : Boolean;
               Public_At : Landin.Source.Span) return Node_Id
            is
               Start    : constant Landin.Source.Span :=
                 (if Exported then Public_At else Here);
               Binders  : Slot_Vectors.Vector;
               Closed   : Boolean := True;
               Target   : Node_Id := No_Node;
               Concept  : Node_Id := No_Node;
               Entries  : Slot_Vectors.Vector;
            begin
               if Exported then
                  Complain
                    (Item    => Syn.Token_Expected,
                     Where   => Public_At,
                     Message => "`public` cannot modify a conformance",
                     Note    => "[1280]: every reached conformance belongs"
                                & " to the whole-program register");
               end if;

               if Peek = Tok.Left_Paren and then not Starts_Signature then
                  Parse_Type_Formals (Start, Binders, Closed);
               end if;

               if Closed then
                  Target := Parse_Type (False, Start);
               else
                  Target := Add (Error_Type, After_Previous);
               end if;

               if Peek = Tok.Identifier and then Named_Here = Is_Id then
                  Advance;
                  if Peek = Tok.Identifier then
                     Concept := Parse_Qualified_Reference
                       (Concept_Reference);
                  else
                     Complain
                       (Item    => Syn.Name_Expected,
                        Where   => (if Peek = Tok.End_Of_Input
                                    then After_Previous else Here),
                        Message => "a conformance names its concept after"
                                   & " `is`",
                        Note    => "[1240]: a conformance has one direct"
                                   & " concept name");
                     Concept := Add (Concept_Reference, After_Previous);
                  end if;
               else
                  Complain
                    (Item    => Syn.Token_Expected,
                     Where   => After_Previous,
                     Message => "a conformance puts `is` after its target"
                                & " type",
                     Note    => "[1240]: target_type is concept_name"
                                & " (label: RHS, ...)",
                     Related => Start,
                     Because => "this conformance");
                  Concept := Add (Concept_Reference, After_Previous);
               end if;

               if Expect
                 (Wanted  => Tok.Left_Paren,
                  Message => "a conformance opens its entries with `(`",
                  Note    => "[1240]: a conformance supplies labelled"
                             & " source RHS entries",
                  Related => Start,
                  Because => "this conformance")
               then
                  while Peek /= Tok.Right_Paren
                    and then Peek /= Tok.End_Of_Input
                  loop
                     if Peek /= Tok.Identifier then
                        Complain
                          (Item    => Syn.Name_Expected,
                           Where   => Here,
                           Message => "a conformance entry begins with a"
                                      & " label",
                           Note    => "[1240]: entries are `label: RHS`");
                        Resync (List_Anchor);
                        exit;
                     end if;

                     declare
                        Label : constant Landin.Source.Names.Name_Id :=
                          Named_Here;
                        At_Label : constant Landin.Source.Span := Here;
                        RHS : Node_Id;
                     begin
                        Advance;
                        if Expect
                          (Wanted  => Tok.Colon,
                           Message => "a conformance label has a RHS after"
                                      & " `:`",
                           Note    => "[1240]: entries are `label: RHS`",
                           Related => At_Label,
                           Because => "the label named here")
                        then
                           RHS := Parse_Argument_RHS;
                        else
                           RHS := Add (Error_Expression, After_Previous);
                        end if;
                        Entries.Append
                          (Add
                             (Of_Kind  => Conformance_Entry,
                              At_Token => At_Label,
                              Extent   => Join (At_Label, After_Previous),
                              Children => [RHS],
                              Named    => Label));
                     end;

                     exit when Peek /= Tok.Comma;
                     Advance;
                  end loop;

                  if not Expect
                    (Wanted  => Tok.Right_Paren,
                     Message => "a conformance's entries close with `)`",
                     Note    => "[1240]: `(` opens the labelled entry run",
                     Related => Start,
                     Because => "this conformance")
                  then
                     Resync_Declaration;
                  end if;
               end if;

               declare
                  Head : constant Slot_List (1 .. 2) := [Target, Concept];
               begin
                  return Add
                    (Of_Kind  => Conformance_Declaration,
                     At_Token => Start,
                     Extent   => Join (Start, After_Previous),
                     Children => Head & To_List (Binders) & To_List (Entries),
                     Exported => False);
               end;
            end Parse_Conformance;

            --  `"struct" field+ "end" identifier?` [1795], where a
            --  field is `identifier ":" type` [0750].  The closing name
            --  is checked the way a function's is, because a body that
            --  ends with the wrong name is a reader's mistake worth
            --  naming rather than a parse that quietly succeeded.
            function Parse_Struct_Body
              (Named   : Landin.Source.Names.Name_Id;
               At_Name : Landin.Source.Span) return Node_Id
            is
               Opened : constant Landin.Source.Span := Here;
               Fields : Slot_Vectors.Vector;
               Had_Field : Boolean := False;

               function Payload_Case_Begins_Part
                 (Part_Name : Landin.Source.Names.Name_Id) return Boolean;

               function Parse_Variant_Part
                 (Part_Name : Landin.Source.Names.Name_Id;
                  At_Part   : Landin.Source.Span) return Node_Id;

               --  A separately refused inline struct field may follow a
               --  perfectly ordinary field whose type is named `variant`.
               --  Looking through the first payload's parentheses to its
               --  `|` or matching closer keeps that second mistake with
               --  [0670], rather than misnaming the first field as [0680].
               function Payload_Case_Begins_Part
                 (Part_Name : Landin.Source.Names.Name_Id) return Boolean
               is
                  Scan    : Tok.Token_Index := Index + 3;
                  Nesting : Natural := 0;
               begin
                  if Ahead (1) /= Tok.Identifier
                    or else Ahead (2) /= Tok.Colon
                    or else Ahead (3) /= Tok.Left_Paren
                  then
                     return False;
                  end if;

                  while Scan <= Last loop
                     case Tok.Kind (From, Scan) is
                        when Tok.Left_Paren =>
                           Nesting := Nesting + 1;

                        when Tok.Right_Paren =>
                           if Nesting = 0 then
                              return False;
                           end if;

                           Nesting := Nesting - 1;
                           if Nesting = 0 then
                              return
                                (Scan + 1 <= Last
                                 and then
                                   (Tok.Kind (From, Scan + 1) = Tok.Bar
                                    or else
                                      (Scan + 2 <= Last
                                       and then Tok.Kind (From, Scan + 1)
                                                    = Tok.Kw_End
                                       and then Tok.Kind (From, Scan + 2)
                                                    = Tok.Identifier
                                       and then Tok.Name
                                         (Tok.Token_At (From, Scan + 2))
                                                    = Part_Name)));
                           end if;

                        when others =>
                           null;
                     end case;

                     Scan := Scan + 1;
                  end loop;

                  return False;
               end Payload_Case_Begins_Part;

               --  variant_part ::= identifier ":" "variant"
               --                   variant_case ("|" variant_case)*
               --                   "end" identifier              [0680]
               --  variant_case ::= identifier
               --                   ("(" field ("," field)* ")")?
               function Parse_Variant_Part
                 (Part_Name : Landin.Source.Names.Name_Id;
                  At_Part   : Landin.Source.Span) return Node_Id
               is
                  Cases : Slot_Vectors.Vector;
                  Last_At : Landin.Source.Span := At_Part;
               begin
                  --  The contextual word was the lookahead's proof.
                  Advance;

                  if Peek = Tok.Kw_End then
                     Complain
                       (Item    => Syn.Type_Expected,
                        Where   => Here,
                        Message => "a variant needs at least one case",
                        Note    => "[0680]: a variant part is one or more"
                                   & " named cases",
                        Related => At_Part,
                        Because => "the variant part named here");
                  end if;

                  while Peek = Tok.Identifier loop
                     declare
                        Case_Name : Landin.Source.Names.Name_Id;
                        At_Case   : constant Landin.Source.Span :=
                          Parse_Declared_Name (Case_Name);
                        Payload   : Slot_Vectors.Vector;
                     begin
                        Last_At := At_Case;

                        if Peek = Tok.Colon then
                           Advance;
                           if Expect
                                (Wanted  => Tok.Left_Paren,
                                 Message => "a variant payload opens with"
                                            & " `(`",
                                 Note    => "[0680]: a payload is a"
                                            & " parenthesized field list",
                                 Related => At_Case,
                                 Because => "the case named here")
                           then
                              if Peek = Tok.Right_Paren then
                                 Complain
                                   (Item    => Syn.Type_Expected,
                                    Where   => Here,
                                    Message => "a payload needs at least"
                                               & " one field",
                                    Note    => "[0690]: a case with no"
                                               & " payload is written bare",
                                    Related => At_Case,
                                    Because => "the case named here");
                              end if;

                              while Peek = Tok.Identifier loop
                                 declare
                                    Field_Name : Landin.Source.Names.Name_Id;
                                    At_Field : constant Landin.Source.Span :=
                                      Parse_Declared_Name (Field_Name);
                                    Of_Type : Node_Id := No_Node;
                                 begin
                                    if Expect
                                         (Wanted  => Tok.Colon,
                                          Message => "a payload field names"
                                                     & " its type after `:`",
                                          Note    => "[0680]: a payload is"
                                                     & " a field list",
                                          Related => At_Field,
                                          Because => "the field named here")
                                    then
                                       Of_Type := Parse_Type
                                         (False, At_Field);
                                    else
                                       Of_Type := Add
                                         (Error_Type, After_Previous);
                                    end if;

                                    Payload.Append
                                      (Add
                                         (Of_Kind  => Field,
                                          At_Token => At_Field,
                                          Extent   => Join
                                            (At_Field, After_Previous),
                                          Children => [1 => Of_Type],
                                          Named    => Field_Name));
                                 end;

                                 exit when Peek /= Tok.Comma;
                                 Advance;
                              end loop;

                              if not Expect
                                  (Wanted  => Tok.Right_Paren,
                                   Message => "a variant payload is closed"
                                              & " with `)`",
                                   Note    => "[0680]: `(` opens a payload"
                                              & " and `)` closes it",
                                   Related => At_Case,
                                   Because => "the case named here")
                              then
                                 Resync (List_Anchor);
                                 if Peek = Tok.Right_Paren then
                                    Advance;
                                 end if;
                              end if;
                           end if;
                        end if;

                        Cases.Append
                          (Add
                             (Of_Kind  => Variant_Case,
                              At_Token => At_Case,
                              Extent   => Join (At_Case, After_Previous),
                              Children => To_List (Payload),
                              Named    => Case_Name));
                     end;

                     exit when Peek /= Tok.Bar;
                     Advance;
                     if Peek /= Tok.Identifier then
                        Complain
                          (Item    => Syn.Name_Expected,
                           Where   => (if Peek = Tok.End_Of_Input
                                       then After_Previous else Here),
                           Message => "a case name belongs after `|`",
                           Note    => "[0680]: `|` separates named cases");
                        exit;
                     end if;
                  end loop;

                  if Expect
                       (Wanted  => Tok.Kw_End,
                        Message => "a variant part ends with `end` and its"
                                   & " name",
                        Note    => "[0680]: `end name` closes the part",
                        Related => At_Part,
                        Because => "the variant part opened here")
                  then
                     if Peek = Tok.Identifier then
                        if Named_Here /= Part_Name then
                           Complain
                             (Item    => Syn.End_Name_Mismatch,
                              Where   => Here,
                              Message => "this name does not close the"
                                         & " variant part",
                              Note    => "[0680]: `end` repeats the part's"
                                         & " name",
                              Related => At_Part,
                              Because => "the variant part named here");
                        end if;
                        Last_At := Here;
                        Advance;
                     else
                        Complain
                          (Item    => Syn.Name_Expected,
                           Where   => (if Peek = Tok.End_Of_Input
                                       then After_Previous else Here),
                           Message => "the variant part's name belongs"
                                      & " after `end`",
                           Note    => "[0680]: `end name` closes the part");
                     end if;
                  end if;

                  return Add
                    (Of_Kind  => Variant_Part,
                     At_Token => At_Part,
                     Extent   => Join (At_Part, Last_At),
                     Children => To_List (Cases),
                     Named    => Part_Name);
               end Parse_Variant_Part;
            begin
               Advance;

               while Peek = Tok.Identifier loop
                  declare
                     Field_Named : Landin.Source.Names.Name_Id;
                     At_Field    : constant Landin.Source.Span :=
                       Parse_Declared_Name (Field_Named);
                     Of_Type     : Node_Id := No_Node;
                     Is_Variant_Part : Boolean := False;
                  begin
                     if Expect
                          (Wanted  => Tok.Colon,
                           Message => "a field names its type after `:`",
                           Note    => "[0750]: a field is a name and a"
                                      & " type, in the order the layout"
                                      & " keeps them",
                           Related => At_Field,
                           Because => "the field named here")
                     then
                        --  [0680] writes `variant` contextually after the
                        --  part name.  It remains an ordinary user type
                        --  everywhere else, including before another
                        --  ordinary field, so the first case has to prove
                        --  the shape rather than the word alone.
                        Is_Variant_Part :=
                          Peek = Tok.Identifier
                          and then Named_Here = Variant_Id
                          and then
                            (Payload_Case_Begins_Part (Field_Named)
                             or else
                               (Ahead (1) = Tok.Identifier
                                and then Ahead (2) = Tok.Bar)
                             or else
                               (Ahead (1) = Tok.Identifier
                                and then Ahead (2) = Tok.Kw_End
                                and then Ahead (3) = Tok.Identifier)
                             or else
                               (Ahead (1) = Tok.Kw_End
                                and then Ahead (2) = Tok.Identifier
                                and then Named_Ahead (2) = Field_Named));

                        if Is_Variant_Part then
                           Fields.Append
                             (Parse_Variant_Part (Field_Named, At_Field));
                           Had_Field := True;
                        else
                           Of_Type := Parse_Type (False, At_Field);

                           if Type_Refused then
                              Resync_Declaration;
                              exit;
                           end if;
                        end if;
                     end if;

                     if not Is_Variant_Part then
                        Fields.Append
                          (Add
                             (Of_Kind  => Field,
                              At_Token => At_Field,
                              Extent   => Join (At_Field, After_Previous),
                              Children => [1 => Of_Type],
                              Named    => Field_Named));
                        Had_Field := True;
                     end if;
                  end;
               end loop;

               if not Had_Field then
                  Complain
                    (Item    => Syn.Type_Expected,
                     Where   => Here,
                     Message => "a struct needs at least one field",
                     Note    => "[0670]: a struct is its fields, and one"
                                & " with none has no value to describe",
                     Related => At_Name,
                     Because => "declared here");
               end if;

               if Skip_Past_Closer (Named) then
                  null;
               end if;

               return Add
                 (Of_Kind  => Struct_Body,
                  At_Token => Opened,
                  Extent   => Join (Opened, After_Previous),
                  Children => To_List (Fields));
            end Parse_Struct_Body;

            function Parse_Binding
              (Exported  : Boolean;
               Public_At : Landin.Source.Span) return Node_Id
            is
               Start : constant Landin.Source.Span :=
                 (if Exported then Public_At else Here);
               Mutable   : Boolean := False;
               Named     : Landin.Source.Names.Name_Id;
               At_Name   : Landin.Source.Span;
               Type_Node : Node_Id := No_Node;
               Value     : Node_Id := No_Node;
            begin
               if Peek = Tok.Kw_Mut then
                  Mutable := True;
                  Advance;
               end if;

               At_Name := Parse_Declared_Name (Named);

               if Peek = Tok.Colon_Equal then
                  Advance;
                  Value := Parse_Expression;
               elsif Expect
                       (Wanted  => Tok.Colon,
                        Message => "a binding names its type after `:`",
                        Note    => "[1790]: `mut`? name `:` type, or name"
                                   & " `:=` expression",
                        Related => At_Name,
                        Because => "declared here")
               then
                  Type_Node := Parse_Type (False, At_Name);

                  if Type_Refused then
                     Resync_Declaration;
                  elsif Peek = Tok.Equal then
                     Advance;
                     Value := Parse_Expression;
                  elsif Peek = Tok.Colon_Equal then
                     Complain
                       (Item    => Syn.Token_Expected,
                        Where   => After_Previous,
                        Message => "a binding that names its type takes"
                                   & " its value after `=`",
                        Note    => "[1790]: `:=` is the form that infers"
                                   & " the type, and it names none",
                        Related => At_Name,
                        Because => "declared here");
                     Advance;
                     Value := Parse_Expression;
                  end if;
               end if;

               return Add
                 (Of_Kind  => Binding,
                  At_Token => At_Name,
                  Extent   => Join (Start, After_Previous),
                  Children => [Type_Node, Value],
                  Named    => Named,
                  Exported => Exported,
                  Mutable  => Mutable);
            end Parse_Binding;

            --  destructuring_binding ::= "(" destructured_field
            --    ("," destructured_field)* ")" ":=" expression [0990]
            --  destructured_field ::= identifier (":" (identifier | "_"))?
            --                       | "_"
            function Parse_Destructuring return Node_Id is
               Start  : constant Landin.Source.Span := Here;
               Fields : Slot_Vectors.Vector;
               Value  : Node_Id := No_Node;
               Kept   : Boolean;
            begin
               Advance;
               loop
                  if Peek = Tok.Underscore then
                     declare
                        At_Under : constant Landin.Source.Span := Here;
                     begin
                        Advance;
                        Fields.Append
                          (Add
                             (Of_Kind  => Result_Wildcard,
                              At_Token => At_Under,
                              Extent   => At_Under));
                     end;
                  elsif Peek = Tok.Identifier then
                     declare
                        At_Field : constant Landin.Source.Span := Here;
                        Field_Name : constant Landin.Source.Names.Name_Id :=
                          Named_Here;
                        Local : Node_Id := No_Node;
                        Local_Name : Landin.Source.Names.Name_Id := Field_Name;
                        Local_At : Landin.Source.Span := At_Field;
                     begin
                        Advance;
                        if Peek = Tok.Colon then
                           Advance;
                           if Peek = Tok.Underscore then
                              Advance;
                              Local_Name := Landin.Source.Names.No_Name;
                           elsif Peek = Tok.Identifier then
                              Local_At := Here;
                              Local_Name := Named_Here;
                              Advance;
                           else
                              Complain
                                (Item    => Syn.Name_Expected,
                                 Where   => Here,
                                 Message => "a renamed result field needs a"
                                            & " local name or `_`",
                                 Note    => "[0990]: binding is by result"
                                            & " name, optionally renamed");
                              Local_Name := Landin.Source.Names.No_Name;
                           end if;
                        end if;

                        if Local_Name /= Landin.Source.Names.No_Name then
                           Local := Add
                             (Of_Kind  => Destructured_Name,
                              At_Token => Local_At,
                              Extent   => Local_At,
                              Named    => Local_Name);
                        end if;
                        Fields.Append
                          (Add
                             (Of_Kind  => Destructured_Field,
                              At_Token => At_Field,
                              Extent   => Join (At_Field, After_Previous),
                              Children => [Local],
                              Named    => Field_Name));
                     end;
                  else
                     Complain
                       (Item    => Syn.Name_Expected,
                        Where   => Here,
                        Message => "a result binding names a returned field"
                                   & " or writes `_`",
                        Note    => "[0990]: result destructuring binds by"
                                   & " name, never by position");
                     Resync (List_Anchor);
                     exit;
                  end if;

                  exit when Peek /= Tok.Comma;
                  Advance;
               end loop;

               Kept := Expect
                 (Wanted  => Tok.Right_Paren,
                  Message => "a result binding closes its names with `)`",
                  Note    => "[0990]: `(name: local, _) := result`",
                  Related => Start,
                  Because => "opened here");
               pragma Unreferenced (Kept);

               if Expect
                 (Wanted  => Tok.Colon_Equal,
                  Message => "a result binding reads its value after `:=`",
                  Note    => "[0990]: `(name: local, _) := result`",
                  Related => Start,
                  Because => "this result binding")
               then
                  Value := Parse_Expression;
               end if;

               declare
                  Head : constant Slot_List (1 .. 1) := [Value];
               begin
                  return Add
                    (Of_Kind  => Destructuring_Binding,
                     At_Token => Start,
                     Extent   => Join (Start, After_Previous),
                     Children => Head & To_List (Fields));
               end;
            end Parse_Destructuring;

            ------------------------------------------------------------
            --  Functions                                        [1800]
            ------------------------------------------------------------

            --  parameter ::= "escaping"? parameter_convention?
            --                identifier ":" type                  [1800]
            --  D140 fixes that modifier order and retains explicit `in`
            --  separately from the implicit default.  D138's type and fixed
            --  formals remain distinct nodes, so neither runtime modifier can
            --  accidentally give a static formal an ABI position.
            function Parse_Parameter
              (Allow_Static : Boolean := False) return Node_Id
            is
               Start       : constant Landin.Source.Span := Here;
               Fixed       : constant Boolean := Peek = Tok.Kw_Fixed;
               Escaping    : Boolean := False;
               Convention  : Parameter_Convention := Implicit_In;
               Named       : Landin.Source.Names.Name_Id;
               At_Name     : Landin.Source.Span;
               Type_Node   : Node_Id := No_Node;
               Constraint  : Node_Id := No_Node;
            begin
               if Fixed then
                  if not Allow_Static then
                     Refuse
                       (Item    => Syn.Type_Parameter,
                        Where   => Here,
                        Message => "fixed parameters are only enabled on"
                                   & " declared routines");
                  end if;
                  Advance;
               else
                  if Peek = Tok.Kw_Escaping then
                     Escaping := True;
                     Advance;
                  end if;

                  case Peek is
                     when Tok.Kw_In =>
                        Convention := Explicit_In;
                        Advance;
                     when Tok.Kw_Inout =>
                        Convention := Inout_Convention;
                        Advance;
                     when Tok.Kw_Sink =>
                        Convention := Sink_Convention;
                        Advance;
                     when others =>
                        null;
                  end case;
               end if;

               At_Name := Parse_Declared_Name (Named);

               if Expect
                    (Wanted  => Tok.Colon,
                     Message => "a parameter names its type after `:`",
                     Note    => "[1800]: modifiers precede `name: type`",
                     Related => At_Name,
                     Because => "declared here")
               then
                  if Allow_Static and then not Fixed
                    and then not Escaping
                    and then Convention = Implicit_In
                    and then Peek = Tok.Kw_Type
                  then
                     Advance;
                     if Peek = Tok.Identifier and then Named_Here = Is_Id then
                        Advance;
                        if Peek = Tok.Identifier then
                           Constraint := Parse_Qualified_Reference
                             (Concept_Reference);
                        else
                           Complain
                             (Item    => Syn.Name_Expected,
                              Where   => (if Peek = Tok.End_Of_Input
                                          then After_Previous else Here),
                              Message => "a type constraint names a"
                                         & " concept after `is`",
                              Note    => "[1290]: a type formal may name"
                                         & " one direct concept");
                           Constraint := Add (Error_Type, After_Previous);
                        end if;
                     end if;
                     return Add
                       (Of_Kind  => Type_Formal,
                        At_Token => At_Name,
                        Extent   => Join (Start, After_Previous),
                        Children => [Constraint],
                        Named    => Named);
                  end if;
                  Type_Node := Parse_Type (True, At_Name);
               else
                  Type_Node := Add (Error_Type, After_Previous);
               end if;

               if Fixed then
                  return Add
                    (Of_Kind  => Fixed_Formal,
                     At_Token => Start,
                     Extent   => Join (Start, After_Previous),
                     Children => [Type_Node],
                     Named    => Named);
               end if;

               return Add
                 (Of_Kind   => Parameter,
                  At_Token  => At_Name,
                  Extent    => Join (Start, After_Previous),
                  Children  => [Type_Node],
                  Named     => Named,
                  Escapes   => Escaping,
                  Convention => Convention);
            end Parse_Parameter;

            --  returns ::= "(" named_return ("," named_return)* ")"
            --              | "none"                              [1800]
            --  named_return ::= identifier ":" type
            --                   ("from" identifier ("," identifier)*)?
            --
            --  No_Node is `none`.  Every nonempty return list has its own
            --  node so signatures can carry [0920]'s ordered positions
            --  without confusing them with the trailing parameter run.
            function Parse_Returns
              (Declared_At : Landin.Source.Span;
               Returns_At  : out Landin.Source.Span) return Node_Id
            is
               Start   : constant Landin.Source.Span := Here;
               Results : Slot_Vectors.Vector;
            begin
               Returns_At := Start;

               if Peek = Tok.Kw_None then
                  Advance;
                  return No_Node;
               end if;

               if not Expect
                        (Wanted  => Tok.Left_Paren,
                         Message => "returns are named, or `none`",
                         Note    => "[1800]: returns ::= `(` named_return"
                                    & " (`,` named_return)* `)` | `none`",
                         Related => Declared_At,
                         Because => "declared here")
               then
                  return No_Node;
               end if;

               loop
                  declare
                     Named     : Landin.Source.Names.Name_Id;
                     At_Name   : constant Landin.Source.Span :=
                       Parse_Declared_Name (Named);
                     Type_Node : Node_Id;
                     Sources   : Slot_Vectors.Vector;
                  begin
                     if Expect
                          (Wanted  => Tok.Colon,
                           Message => "a named return names its type after"
                                      & " `:`",
                           Note    => "[1800]: named_return ::= identifier"
                                      & " `:` type",
                           Related => At_Name,
                           Because => "the return")
                     then
                        Type_Node := Parse_Type (False, At_Name);
                     else
                        Type_Node := Add (Error_Type, After_Previous);
                     end if;

                     if Peek = Tok.Kw_From then
                        Advance;
                        loop
                           if Peek /= Tok.Identifier then
                              Complain
                                (Item    => Syn.Name_Expected,
                                 Where   => (if Peek = Tok.End_Of_Input
                                             then After_Previous else Here),
                                 Message => "a `from` clause names at least"
                                            & " one parameter",
                                 Note    => "[0790]: returned references"
                                            & " name their sources");
                              exit;
                           end if;

                           declare
                              Source_At : constant Landin.Source.Span := Here;
                              Source_Name : constant
                                Landin.Source.Names.Name_Id := Named_Here;
                           begin
                              Advance;
                              Sources.Append
                                (Add (Return_Source, Source_At,
                                      Named => Source_Name));
                           end;

                           --  A comma followed by `name:` begins the next
                           --  named return.  Any other comma continues this
                           --  return's source list; the grammar deliberately
                           --  admits both uses and this is its local split.
                           exit when Peek /= Tok.Comma
                             or else (Ahead (1) = Tok.Identifier
                                      and then Ahead (2) = Tok.Colon);
                           Advance;
                        end loop;
                     end if;

                     declare
                        Head : constant Slot_List (1 .. 1) := [Type_Node];
                     begin
                        Results.Append
                          (Add
                             (Of_Kind  => Named_Return,
                              At_Token => At_Name,
                              Extent   => Join (At_Name, After_Previous),
                              Children => Head & To_List (Sources),
                              Named    => Named));
                     end;
                  end;

                  exit when Peek /= Tok.Comma;
                  Advance;
               end loop;

               if not Expect
                        (Wanted  => Tok.Right_Paren,
                         Message => "the named returns close with `)`",
                         Note    => "[1800]: returns ::= `(` named_return"
                                    & " (`,` named_return)* `)` | `none`",
                         Related => Start,
                         Because => "opened here")
               then
                  Resync (List_Anchor);
                  if Peek = Tok.Right_Paren then
                     Advance;
                  end if;
               end if;

               Returns_At := Join (Start, After_Previous);
               return Add
                 (Of_Kind  => Return_List,
                  At_Token => Start,
                  Extent   => Returns_At,
                  Children => To_List (Results));
            end Parse_Returns;

            --  errors ::= "!" ("..." | identifier ("|" identifier)*)
            --  [0940] [0960].  The concrete form reuses Atom_Union_Type:
            --  both spell one structural set of atom declaration identities.
            function Parse_Errors
              (Declared_At : Landin.Source.Span) return Node_Id
            is
               pragma Unreferenced (Declared_At);
               At_Bang : constant Landin.Source.Span := Here;
               Members : Slot_Vectors.Vector;
            begin
               if Peek /= Tok.Bang then
                  return No_Node;
               end if;
               Advance;

               if Peek = Tok.Dot_Dot_Dot then
                  declare
                     At_Inferred : constant Landin.Source.Span := Here;
                  begin
                     Advance;
                     return Add
                       (Inferred_Error_Set, At_Inferred,
                        Join (At_Bang, At_Inferred));
                  end;
               end if;

               loop
                  if Peek /= Tok.Identifier then
                     Complain
                       (Item    => Syn.Name_Expected,
                        Where   => Here,
                        Message => "an error set names at least one atom",
                        Note    => "[0940]: `!` is followed by atom names");
                     return Add
                       (Error_Type, At_Bang,
                        Join (At_Bang, After_Previous));
                  end if;

                  Members.Append
                    (Parse_Qualified_Reference (Type_Reference));

                  exit when Peek /= Tok.Bar;
                  Advance;
               end loop;

               return Add
                 (Of_Kind  => Atom_Union_Type,
                  At_Token => At_Bang,
                  Extent   => Join (At_Bang, After_Previous),
                  Children => To_List (Members));
            end Parse_Errors;

            --  body ::= block                                     [1800]
            --
            --  One token past a leading name decides, and the one shape
            --  that needs more is `identifier "("`: a call is a statement
            --  as well as an expression [1810], so the token *after* the
            --  call decides which this one is -- and the node is the same
            --  either way, so nothing is re-parsed to find out.
            --  A source consisting only of a control form remains ambiguous
            --  after its closing words: the old statement and the new value
            --  form have the same token boundary.  A final expression in any
            --  arm settles it as a value.  This is also used while building
            --  nested blocks, so a statement `if` is never accidentally put
            --  in the Block's value position merely because it meets a
            --  closer.
            function Control_Offers_Value
              (Control : Node_Id) return Boolean;

            function Control_Offers_Value
              (Control : Node_Id) return Boolean
            is
               function Loop_Block_Offers_Value
                 (Block  : Node_Id;
                  Target : Landin.Source.Names.Name_Id;
                  Nested : Boolean := False) return Boolean;

               function Loop_Block_Offers_Value
                 (Block  : Node_Id;
                  Target : Landin.Source.Names.Name_Id;
                  Nested : Boolean := False) return Boolean
               is
                  function Statement_Offers_Value
                    (Statement : Node_Id) return Boolean;

                  function Statement_Offers_Value
                    (Statement : Node_Id) return Boolean
                  is
                  begin
                     case Kind (Result, Statement) is
                        when Break_Statement =>
                           return Transfer_Value (Result, Statement) /= No_Node
                             and then
                               (if Name (Result, Statement) =
                                     Landin.Source.Names.No_Name
                                then not Nested
                                else Name (Result, Statement) = Target);
                        when Loop_Statement | While_Statement
                           | For_Statement =>
                           if Target = Landin.Source.Names.No_Name
                             or else Name (Result, Statement) = Target
                           then
                              return False;
                           end if;
                           return Loop_Block_Offers_Value
                             (Loop_Body (Result, Statement), Target, True)
                             or else
                               (Complete_Body (Result, Statement) /= No_Node
                                and then Loop_Block_Offers_Value
                                  (Complete_Body (Result, Statement),
                                   Target, True));
                        when If_Statement =>
                           for Index in 1 .. Arm_Count (Result, Statement) loop
                              if Loop_Block_Offers_Value
                                (Body_Of
                                   (Result,
                                    Nth_Arm (Result, Statement, Index)),
                                 Target, Nested)
                              then
                                 return True;
                              end if;
                           end loop;
                           return Else_Body (Result, Statement) /= No_Node
                             and then Loop_Block_Offers_Value
                               (Else_Body (Result, Statement), Target, Nested);
                        when Match_Statement =>
                           for Index in 1 .. Match_Arm_Count
                             (Result, Statement)
                           loop
                              if Loop_Block_Offers_Value
                                (Body_Of
                                   (Result, Nth_Match_Arm
                                      (Result, Statement, Index)),
                                 Target, Nested)
                              then
                                 return True;
                              end if;
                           end loop;
                           return False;
                        when Bare_Block =>
                           return Loop_Block_Offers_Value
                             (Body_Of (Result, Statement), Target, Nested);
                        when others =>
                           return False;
                     end case;
                  end Statement_Offers_Value;
               begin
                  for Index in 1 .. Statement_Count (Result, Block) loop
                     if Statement_Offers_Value
                       (Nth_Statement (Result, Block, Index))
                     then
                        return True;
                     end if;
                  end loop;
                  return False;
               end Loop_Block_Offers_Value;
            begin
               case Kind (Result, Control) is
                  when If_Statement =>
                     for Index in 1 .. Arm_Count (Result, Control) loop
                        if Block_Value
                             (Result,
                              Body_Of
                                (Result,
                                 Nth_Arm (Result, Control, Index)))
                           /= No_Node
                        then
                           return True;
                        end if;
                     end loop;

                     return Else_Body (Result, Control) /= No_Node
                       and then Block_Value
                         (Result, Else_Body (Result, Control)) /= No_Node;

                  when Match_Statement =>
                     for Index in 1 .. Match_Arm_Count
                       (Result, Control)
                     loop
                        if Block_Value
                             (Result,
                              Body_Of
                                (Result,
                                 Nth_Match_Arm
                                   (Result, Control, Index)))
                           /= No_Node
                        then
                           return True;
                        end if;
                     end loop;

                     return False;

                  when Bare_Block =>
                     return Block_Value
                       (Result, Body_Of (Result, Control)) /= No_Node;

                  when Loop_Statement | While_Statement | For_Statement =>
                     return Loop_Block_Offers_Value
                       (Loop_Body (Result, Control), Name (Result, Control))
                       or else
                         (Complete_Body (Result, Control) /= No_Node
                          and then Loop_Block_Offers_Value
                            (Complete_Body (Result, Control),
                             Name (Result, Control)));

                  when others =>
                     return False;
               end case;
            end Control_Offers_Value;

            function Parse_Body (Context : Frame) return Node_Id is
            begin
               if Context.Returns then
                  if Peek = Tok.Identifier
                    and then Named_Here in Defer_Id | Undo_Id
                  then
                     return Parse_Block (Context);
                  end if;

                  --  Control forms overlap statements and expressions.  A
                  --  sole one is [1800]'s expression body; when another
                  --  statement follows, it seeds the ordinary statement
                  --  block just as the call-shaped ambiguity below does.
                  if Peek = Tok.Kw_If
                    or else
                      (Peek = Tok.Identifier
                       and then
                         (Named_Here in Match_Id | Begin_Id
                            | Loop_Id | While_Id | For_Id
                          or else
                            (Ahead (1) = Tok.Colon
                             and then Ahead (2) = Tok.Identifier
                             and then Named_Ahead (2)
                               in Loop_Id | While_Id | For_Id)))
                  then
                     declare
                        Control : constant Node_Id := Parse_Expression;
                     begin
                        if Peek = Tok.Kw_End
                          and then Control_Offers_Value (Control)
                        then
                           return Control;
                        elsif Kind (Result, Control)
                                in If_Statement | Match_Statement
                                   | Bare_Block | Loop_Statement
                                   | While_Statement | For_Statement
                        then
                           return Parse_Block (Context, Seed => Control);
                        else
                           return Control;
                        end if;
                     end;
                  end if;

                  --  `try call` has the same expression/statement overlap
                  --  as the direct call handled below.  At the function
                  --  closer it supplies the body value; with another block
                  --  item behind it, it is the first statement and its
                  --  successful value is discarded [1810].
                  if Peek = Tok.Kw_Try then
                     declare
                        Tried : constant Node_Id := Parse_Expression;
                     begin
                        if Peek = Tok.Kw_End then
                           return Tried;
                        end if;

                        return Parse_Block (Context, Seed => Tried);
                     end;
                  end if;

                  --  [1800]'s expression body takes any expression, so
                  --  this asks the same question [1820]'s first set does
                  --  rather than keeping a second list beside it: a token
                  --  that begins an expression and is not a name begins
                  --  one here.  A name is the case below, where it may
                  --  instead begin a binding or an assignment.
                  if Pre.Begins_Expression (Peek)
                    and then Peek not in Tok.Identifier | Tok.Kw_If
                  then
                     return Parse_Expression;
                  end if;

                  --  A selection [1820] is an expression and a place at
                  --  once, so the `=` after the whole chain is what says
                  --  this is an assignment rather than the expression
                  --  body [1800] offers instead of a block.
                  if Peek = Tok.Identifier
                    and then Word_At_Hand = Word_None
                    and then Ahead (1) not in Tok.Colon | Tok.Colon_Equal
                    and then After_Selectors /= Tok.Equal
                  then
                     if Ahead (1) /= Tok.Left_Paren then
                        return Parse_Expression;
                     end if;

                     declare
                        At_Name : constant Landin.Source.Span := Here;
                        Named   : constant Landin.Source.Names.Name_Id :=
                          Named_Here;
                        Called  : Node_Id;
                     begin
                        Advance;
                        Called := Parse_Call (At_Name, Named);

                        if Peek = Tok.Kw_End then
                           return Called;
                        elsif Pre.Is_Binary (Peek) then
                           return Parse_Expression_From (Called);
                        end if;

                        return Parse_Block (Context, Seed => Called);
                     end;
                  end if;
               end if;

               return Parse_Block (Context);
            end Parse_Body;

            --  function ::= identifier ":" signature "=" body
            --               "end" identifier?                     [1800]
            function Parse_Function
              (Exported  : Boolean;
               Public_At : Landin.Source.Span;
               External  : Boolean := False;
               Extern_At : Landin.Source.Span := Landin.Source.Empty_Span)
               return Node_Id
            is
               Start : constant Landin.Source.Span :=
                 (if Exported then Public_At
                  elsif External then Extern_At
                  else Here);
               Named        : Landin.Source.Names.Name_Id;
               At_Name      : Landin.Source.Span;
               Params       : Slot_Vectors.Vector;
               Returns_Node : Node_Id := No_Node;
               Returns_At   : Landin.Source.Span :=
                 Landin.Source.Empty_Span;
               Errors_Node  : Node_Id := No_Node;
               Body_Node    : Node_Id := No_Node;
               Context      : Frame;
            begin
               At_Name := Parse_Declared_Name (Named);

               if not Expect
                        (Wanted  => Tok.Colon,
                         Message => "a function names its signature after"
                                    & " `:`",
                         Note    => "[1800]: identifier `:` signature `=`"
                                    & " body `end`",
                         Related => At_Name,
                         Because => "declared here")
               then
                  Resync_Declaration;
                  return Add
                    (Error_Declaration, At_Name,
                     Join (Start, After_Previous));
               end if;

               --  signature ::= "(" parameters? ")" "->" returns
               if Expect
                    (Wanted  => Tok.Left_Paren,
                     Message => "a signature opens with `(`",
                     Note    => "[1800]: signature ::= `(` parameters? `)`"
                                & " `->` returns",
                     Related => At_Name,
                     Because => "declared here")
               then
                  if Peek /= Tok.Right_Paren then
                     loop
                        declare
                           Before : constant Tok.Token_Index := Index;
                        begin
                           Params.Append
                             (Parse_Parameter (Allow_Static => True));
                           exit when Index = Before;
                        end;

                        exit when Peek /= Tok.Comma;
                        Advance;
                     end loop;
                  end if;

                  if not Expect
                           (Wanted  => Tok.Right_Paren,
                            Message => "the parameter list is never"
                                       & " closed",
                            Note    => "[1800]: signature ::= `(`"
                                       & " parameters? `)` `->` returns",
                            Related => At_Name,
                            Because => "declared here")
                  then
                     Resync (List_Anchor);

                     if Peek = Tok.Right_Paren then
                        Advance;
                     end if;
                  end if;
               end if;

               if Expect
                    (Wanted  => Tok.Minus_Greater,
                     Message => "a signature says what it returns after"
                                & " `->`",
                     Note    => "[1800]: signature ::= `(` parameters? `)`"
                                & " `->` returns",
                     Related => At_Name,
                     Because => "declared here")
               then
                  Returns_Node := Parse_Returns (At_Name, Returns_At);
               end if;

               Errors_Node := Parse_Errors (At_Name);

               Context :=
                 (Owner   => At_Name,
                  Result  => Returns_At,
                  Returns => Returns_Node /= No_Node);

               if External then
                  --  Keep Body_Of total for every function node while later
                  --  stages use the explicit flag to avoid treating this
                  --  placeholder as a Landin definition.
                  Body_Node := Add
                    (Of_Kind  => Block,
                     At_Token => At_Name,
                     Children => [1 => No_Node]);
               elsif Expect
                    (Wanted  => Tok.Equal,
                     Message => "a body opens with `=`",
                     Note    => "[1800]: `=` opens the body and `end`"
                                & " closes it",
                     Related => At_Name,
                     Because => "declared here")
               then
                  Active_Frame := Context;
                  Body_Node := Parse_Body (Context);
                  Active_Frame := (others => <>);
               else
                  Body_Node := Add (Error_Statement, After_Previous);
               end if;

               if External then
                  null;
               elsif Peek = Tok.Kw_End then
                  Advance;

                  if Peek = Tok.Identifier then
                     if Named /= Landin.Source.Names.No_Name
                       and then Named_Here /= Named
                     then
                        Complain
                          (Item    => Syn.End_Name_Mismatch,
                           Where   => Here,
                           Message => "`"
                                      & Landin.Source.Names.Spelling
                                          (Names, Named_Here)
                                      & "` is not the name this function"
                                      & " declares",
                           Note    => "[1800]: `end` may repeat the"
                                      & " function's name, and must name"
                                      & " no other",
                           Related => At_Name,
                           Because => "declared here");
                     end if;

                     Advance;
                  end if;
               else
                  Complain
                    (Item    => Syn.Unclosed_Construct,
                     Where   => After_Previous,
                     Message => "this function is never closed",
                     Note    => "[1800]: `=` opens the body and `end`"
                                & " closes it",
                     Related => At_Name,
                     Because => "opened here",
                     Gate    => False);
               end if;

               declare
                  Head : constant Slot_List (1 .. 3) :=
                    [Returns_Node, Errors_Node, Body_Node];
               begin
                  return Add
                    (Of_Kind  => Function_Declaration,
                     At_Token => At_Name,
                     Extent   => Join (Start, After_Previous),
                     Children => Head & To_List (Params),
                     Named    => Named,
                     Exported => Exported,
                     External => External);
               end;
            end Parse_Function;

            --  anonymous_function ::= signature `=` body `end`   [1010]
            --
            --  The arrow after the balanced opening list distinguishes this
            --  from a parenthesized expression and a labelled struct literal.
            function Parse_Anonymous_Function return Node_Id is
               Start        : constant Landin.Source.Span := Here;
               Params       : Slot_Vectors.Vector;
               Returns_Node : Node_Id := No_Node;
               Returns_At   : Landin.Source.Span :=
                 Landin.Source.Empty_Span;
               Errors_Node  : Node_Id := No_Node;
               Body_Node    : Node_Id := No_Node;
               Context      : Frame;
            begin
               if Too_Deep (Start) then
                  Advance;
                  Resync (List_Anchor);
                  return Add (Error_Expression, Start,
                              Join (Start, After_Previous));
               end if;

               Depth := Depth + 1;
               Advance;
               if Peek /= Tok.Right_Paren then
                  loop
                     declare
                        Before : constant Tok.Token_Index := Index;
                     begin
                        Params.Append (Parse_Parameter);
                        exit when Index = Before;
                     end;
                     exit when Peek /= Tok.Comma;
                     Advance;
                  end loop;
               end if;

               if not Expect
                 (Wanted  => Tok.Right_Paren,
                  Message => "the anonymous function's parameter list is"
                             & " never closed",
                  Note    => "[1010]: an anonymous function begins with its"
                             & " complete signature",
                  Related => Start,
                  Because => "opened here")
               then
                  Resync (List_Anchor);
                  if Peek = Tok.Right_Paren then
                     Advance;
                  end if;
               end if;

               if Expect
                 (Wanted  => Tok.Minus_Greater,
                  Message => "an anonymous function says what it returns"
                             & " after `->`",
                  Note    => "[1010]: the signature precedes `=` and the body",
                  Related => Start,
                  Because => "the anonymous function")
               then
                  Returns_Node := Parse_Returns (Start, Returns_At);
               end if;

               Errors_Node := Parse_Errors (Start);

               Context :=
                 (Owner   => Start,
                  Result  => Returns_At,
                  Returns => Returns_Node /= No_Node);

               if Expect
                 (Wanted  => Tok.Equal,
                  Message => "an anonymous function's body opens with `=`",
                  Note    => "[1010]: `=` opens the body and `end` closes it",
                  Related => Start,
                  Because => "the anonymous function")
               then
                  Body_Node := Parse_Body (Context);
               else
                  Body_Node := Add (Error_Statement, After_Previous);
               end if;

               if Peek = Tok.Kw_End then
                  Advance;
               else
                  Complain
                    (Item    => Syn.Unclosed_Construct,
                     Where   => After_Previous,
                     Message => "this anonymous function is never closed",
                     Note    => "[1010]: an anonymous function closes with"
                                & " `end`",
                     Related => Start,
                     Because => "opened here",
                     Gate    => False);
               end if;

               Depth := Depth - 1;
               declare
                  Head : constant Slot_List (1 .. 3) :=
                    [Returns_Node, Errors_Node, Body_Node];
               begin
                  return Add
                    (Of_Kind  => Anonymous_Function,
                     At_Token => Start,
                     Extent   => Join (Start, After_Previous),
                     Children => Head & To_List (Params));
               end;
            end Parse_Anonymous_Function;

            ------------------------------------------------------------
            --  Statements                                       [1810]
            ------------------------------------------------------------

            function Parse_Block
              (Context     : Frame;
               Seed        : Node_Id := No_Node;
               Allow_Value : Boolean := False) return Node_Id
            is
               Start : constant Landin.Source.Span := Point;
               Items : Slot_Vectors.Vector;
               Value : Node_Id := No_Node;

               function At_Closer return Boolean;
               function Clearly_A_Statement return Boolean;

               function At_Closer return Boolean
                 is (Peek in Tok.End_Of_Input | Tok.Kw_End
                                 | Tok.Kw_Elsif | Tok.Kw_Else
                     or else
                       (Complete_Closes_Block
                        and then Peek = Tok.Identifier
                        and then Named_Here = Complete_Id));

               --  A name beginning a declaration or assignment is not the
               --  final expression [1080].  Every other expression first
               --  is read as an expression.  Calls and control constructs
               --  overlap Statement_Kind; when more source follows in the
               --  block they remain statements, and at the closer they are
               --  the block value.  This is the same ambiguity Parse_Body
               --  already resolves for a direct call, made local to every
               --  value-bearing block.
               function Clearly_A_Statement return Boolean is
               begin
                  if Starts_Destructuring then
                     return True;
                  end if;

                  if Peek in Tok.Kw_Mut | Tok.Kw_Inc | Tok.Kw_Dec
                             | Tok.Underscore | Tok.Kw_Return | Tok.Kw_Fail
                             | Tok.Kw_Public
                  then
                     return True;
                  end if;

                  if Peek /= Tok.Identifier then
                     return False;
                  end if;

                  if Ahead (1) = Tok.Colon
                    and then Ahead (2) = Tok.Identifier
                    and then Named_Ahead (2) in Loop_Id | While_Id | For_Id
                  then
                     return False;
                  end if;

                  return Named_Here in Defer_Id | Undo_Id
                    | Break_Id | Continue_Id
                    or else Word_At_Hand /= Word_None
                    or else Ahead (1) in Tok.Colon | Tok.Colon_Equal
                    or else After_Selectors = Tok.Equal;
               end Clearly_A_Statement;
            begin
               if Seed /= No_Node then
                  Items.Append (Seed);
               end if;

               loop
                  exit when At_Closer;

                  declare
                     Before : constant Tok.Token_Index := Index;
                  begin
                     if Allow_Value
                       and then Pre.Begins_Expression (Peek)
                       and then not Clearly_A_Statement
                     then
                        declare
                           Candidate : constant Node_Id := Parse_Expression;
                        begin
                           if At_Closer
                             and then Kind (Result, Candidate)
                                      in If_Statement | Match_Statement
                                         | Bare_Block | Loop_Statement
                                         | While_Statement
                             and then not Control_Offers_Value (Candidate)
                           then
                              Items.Append (Candidate);
                              exit;
                           elsif At_Closer then
                              Value := Candidate;
                              exit;
                           elsif Kind (Result, Candidate)
                                   in If_Statement | Match_Statement
                                      | Bare_Block | Loop_Statement
                                      | While_Statement | Call
                                      | Try_Expression
                           then
                              Items.Append (Candidate);
                           else
                              --  No separator can turn an ordinary
                              --  expression into a statement.  Leave the
                              --  following token to the enclosing closer's
                              --  diagnostic instead of swallowing it.
                              Value := Candidate;
                              exit;
                           end if;
                        end;
                     elsif Peek not in Tok.Kernel_Kind
                       and then Ahead (1) not in Tok.Colon
                                  | Tok.Colon_Equal | Tok.Equal
                     then
                        Mark_Reported;
                        Advance;
                     elsif Pre.Begins_Statement (Peek)
                       or else Starts_Destructuring
                       or else Peek = Tok.Kw_Public
                       or else Peek not in Tok.Kernel_Kind
                     then
                        Items.Append (Parse_Statement (Context));
                     else
                        declare
                           From_Here : constant Landin.Source.Span := Here;
                        begin
                           Resync_Statement;
                           Complain
                             (Item    => Syn.Stray_Token,
                              Where   => Join (From_Here, After_Previous),
                              Message => "this begins no statement",
                              Note    => "[1810]: a statement is a"
                                         & " binding, an assignment, an"
                                         & " `inc` or `dec`, a discard, a"
                                         & " call, a `return` or a"
                                         & " control expression",
                              Gate    => False);
                        end;
                     end if;

                     if Index = Before then
                        raise Compiler_Defect
                          with "the parser did not advance over a"
                               & " block item";
                     end if;
                  end;
               end loop;

               declare
                  Head : constant Slot_List (1 .. 1) := [Value];
               begin
                  return Add
                    (Of_Kind  => Block,
                     At_Token => Start,
                     Extent   => Join (Start, After_Previous),
                     Children => Head & To_List (Items));
               end;
            end Parse_Block;

            function Parse_Statement (Context : Frame) return Node_Id is
               Start : constant Landin.Source.Span := Here;
            begin
               --  P1, one level up: a token no kernel rule spells stands
               --  in for the statement it broke, and says nothing.
               if Peek not in Tok.Kernel_Kind then
                  Mark_Reported;
                  Advance;
                  return Add (Error_Statement, Start);
               end if;

               case Peek is
                  when Tok.Kw_Public =>
                     Complain
                       (Item    => Syn.Public_On_Statement,
                        Where   => Here,
                        Message => "`public` rides on a declaration, not"
                                   & " on a statement",
                        Note    => "[1740]: what a module exports is"
                                   & " decided where the module is"
                                   & " written, never inside a body",
                        Related => Context.Owner,
                        Because => "this function's body");
                     Advance;
                     return Parse_Statement (Context);

                  when Tok.Kw_If =>
                     return Parse_If (Context);

                  when Tok.Kw_Try =>
                     return Parse_Expression;

                  when Tok.Kw_Fail =>
                     declare
                        At_Fail : constant Landin.Source.Span := Here;
                        Error   : Node_Id;
                        Guard   : Node_Id := No_Node;
                     begin
                        Advance;
                        Error := Parse_Expression;
                        if Peek = Tok.Kw_When then
                           Advance;
                           Guard := Parse_Expression;
                        end if;
                        return Add
                          (Of_Kind  => Fail_Statement,
                           At_Token => At_Fail,
                           Extent   => Join (Start, After_Previous),
                           Children => [Error, Guard]);
                     end;

                  when Tok.Kw_Return =>
                     declare
                        At_Return : constant Landin.Source.Span := Here;
                        Guard     : Node_Id := No_Node;
                     begin
                        Advance;

                        if Peek = Tok.Kw_When then
                           Advance;
                           Guard := Parse_Expression;
                        elsif Tok.Is_Literal (Peek)
                          or else Peek = Tok.Left_Paren
                          or else Pre.Is_Prefix (Peek)
                        then
                           --  [1810]: `return` carries no value.  The
                           --  value is parsed and thrown away so the rest
                           --  of the body is still read.
                           Complain
                             (Item    => Syn.Return_Carries_Value,
                              Where   => Here,
                              Message => "`return` carries no value",
                              Note    => "[0930]: assign the named"
                                         & " return, then `return`",
                              Related => Context.Result,
                              Because => "the return it fills");
                           Guard := No_Node;
                           declare
                              Thrown : constant Node_Id :=
                                Parse_Expression;
                           begin
                              pragma Unreferenced (Thrown);
                           end;
                        end if;

                        return Add
                          (Of_Kind  => Return_Statement,
                           At_Token => At_Return,
                           Extent   => Join (Start, After_Previous),
                           Children => [Guard]);
                     end;

                  when Tok.Kw_Inc | Tok.Kw_Dec =>
                     declare
                        At_Op    : constant Landin.Source.Span := Here;
                        Stepping : constant Node_Kind :=
                          (if Peek = Tok.Kw_Inc then Increment
                           else Decrement);
                        Target   : Node_Id;
                     begin
                        Advance;
                        Target := Parse_Place;
                        return Add
                          (Of_Kind  => Stepping,
                           At_Token => At_Op,
                           Extent   => Join (Start, After_Previous),
                           Children => [Target]);
                     end;

                  when Tok.Underscore =>
                     declare
                        At_Under : constant Landin.Source.Span := Here;
                        Value    : Node_Id := No_Node;
                     begin
                        Advance;

                        if Expect
                             (Wanted  => Tok.Equal,
                              Message => "a discard throws a value away"
                                         & " with `=`",
                              Note    => "[1020]: discarding a result is"
                                         & " written out",
                              Related => At_Under,
                              Because => "the discard")
                        then
                           Value := Parse_Expression;
                        end if;

                        return Add
                          (Of_Kind  => Discard,
                           At_Token => At_Under,
                           Extent   => Join (Start, After_Previous),
                           Children => [Value]);
                     end;

                  when Tok.Kw_Mut =>
                     return Parse_Binding
                       (False, Landin.Source.Empty_Span);

                  when Tok.Left_Paren =>
                     if Starts_Destructuring then
                        return Parse_Destructuring;
                     end if;
                     Advance;
                     Resync_Statement;
                     return Add
                       (Error_Statement, Start,
                        Join (Start, After_Previous));

                  when Tok.Identifier =>
                     if Ahead (1) = Tok.Colon
                       and then Ahead (2) = Tok.Identifier
                       and then Named_Ahead (2) in Loop_Id | While_Id | For_Id
                     then
                        declare
                           Label : constant Landin.Source.Names.Name_Id :=
                             Named_Here;
                           Label_At : constant Landin.Source.Span := Here;
                           Is_For : constant Boolean :=
                             Named_Ahead (2) = For_Id;
                        begin
                           Advance;
                           Advance;
                           if Is_For then
                              return Parse_For
                                (Context, Starts => Label_At, Label => Label);
                           else
                              return Parse_Loop
                                (Context, Starts => Label_At, Label => Label);
                           end if;
                        end;
                     elsif Named_Here in Loop_Id | While_Id | For_Id
                     then
                        if Named_Here = For_Id then
                           return Parse_For (Context);
                        else
                           return Parse_Loop (Context);
                        end if;
                     elsif Named_Here in Break_Id | Continue_Id
                     then
                        return Parse_Loop_Transfer;
                     elsif Named_Here in Defer_Id | Undo_Id then
                        declare
                           Is_Undo : constant Boolean :=
                             Named_Here = Undo_Id;
                           At_Cleanup : constant Landin.Source.Span := Here;
                           Call_Node : Node_Id := No_Node;

                           function Cleanup_Name return String
                             is (if Is_Undo then "undo" else "defer");

                           function Cleanup_Paragraph return String
                             is (if Is_Undo then "[1110]" else "[1100]");

                           function Execution_Note return String
                             is (if Is_Undo
                                 then " when failure propagates"
                                 else " when its block is left");
                        begin
                           Advance;

                           if Peek = Tok.Identifier then
                              --  A cleanup delays the complete callee
                              --  expression, not only a direct name.  Reuse
                              --  the ordinary primary walk so a selected
                              --  function field and its indexes retain the
                              --  same call syntax and source order.
                              Call_Node := Parse_Primary;
                           else
                              Complain
                                (Item    => Syn.Expression_Expected,
                                 Where   => (if Peek = Tok.End_Of_Input
                                             then After_Previous else Here),
                                 Message => "`" & Cleanup_Name
                                            & "` registers a call here",
                                 Note    => Cleanup_Paragraph
                                            & ": the call is evaluated"
                                            & Execution_Note,
                                 Related => At_Cleanup,
                                 Because => "the " & Cleanup_Name);
                              Call_Node := Add (Error_Expression, Point);
                           end if;

                           if Kind (Result, Call_Node) /= Call then
                              if Kind (Result, Call_Node)
                                   /= Error_Expression
                              then
                                 Complain
                                   (Item    =>
                                      (if Kind (Result, Call_Node)
                                            in Name_Reference
                                               | Member_Selection
                                       then Syn.Token_Expected
                                       else Syn.Expression_Expected),
                                    Where   => Where (Result, Call_Node),
                                    Message => "`" & Cleanup_Name
                                               & "` registers a call, not a"
                                               & " constructed value",
                                    Note    => Cleanup_Paragraph
                                               & ": write the call that runs"
                                               & Execution_Note,
                                    Related => At_Cleanup,
                                    Because => "the " & Cleanup_Name);
                              end if;
                              return Add
                                (Error_Statement, At_Cleanup,
                                 Join (Start, After_Previous), [Call_Node]);
                           end if;

                           return Add
                             (Of_Kind  =>
                                (if Is_Undo
                                 then Undo_Statement else Defer_Statement),
                              At_Token => At_Cleanup,
                              Extent   => Join (Start, After_Previous),
                              Children => [Call_Node]);
                        end;
                     elsif Named_Here = Match_Id then
                        return Parse_Match (Context);
                     elsif Named_Here = Begin_Id then
                        return Parse_Bare_Block (Context);
                     end if;

                     declare
                        Word : constant Refused_Word := Word_At_Hand;
                     begin
                        if Word /= Word_None then
                           declare
                              At_Word : constant Landin.Source.Span :=
                                Here;
                              Closer  : constant
                                Landin.Source.Names.Name_Id := Named_Here;
                           begin
                              Refuse
                                (Item    => Refusal (Word),
                                 Where   => At_Word,
                                 Message => "`" & Spelling (Word)
                                            & "` is not enabled yet");

                              --  A refused construct closes itself, so
                              --  swallowing its own `end` keeps that
                              --  `end` from being read as the enclosing
                              --  function's and turning one refusal into
                              --  three reports.
                              if not Skip_Past_Closer (Closer) then
                                 Resync_Statement;
                              end if;

                              return Add
                                (Error_Statement, At_Word,
                                 Join (Start, After_Previous));
                           end;
                        end if;
                     end;

                     if Ahead (1) in Tok.Colon | Tok.Colon_Equal then
                        return Parse_Binding
                          (False, Landin.Source.Empty_Span);
                     end if;

                     --  A place is [1820]'s indexed selection [1810], so
                     --  what follows the whole of it -- every dot and
                     --  every bracket group -- is what makes this an
                     --  assignment.
                     if After_Selectors = Tok.Equal then
                        declare
                           Target : constant Node_Id := Parse_Place;
                           At_Op  : Landin.Source.Span;
                           Value  : Node_Id := No_Node;
                        begin
                           At_Op := Here;

                           if Expect
                                (Wanted  => Tok.Equal,
                                 Message => "an assignment writes a place"
                                            & " with `=`",
                                 Note    => "[1810]: `=` assigns and `==`"
                                            & " compares [0390]",
                                 Related => Start,
                                 Because => "the place written")
                           then
                              Value := Parse_Expression;
                           end if;

                           return Add
                             (Of_Kind  => Assignment,
                              At_Token => At_Op,
                              Extent   => Join (Start, After_Previous),
                              Children => [Target, Value]);
                        end;
                     end if;

                     if Ahead (1) = Tok.Left_Paren then
                        declare
                           At_Name : constant Landin.Source.Span := Here;
                           Named   : constant
                             Landin.Source.Names.Name_Id := Named_Here;
                        begin
                           Advance;
                           return Parse_Call (At_Name, Named);
                        end;
                     end if;

                     if After_Selectors = Tok.Left_Paren then
                        declare
                           Called : constant Node_Id := Parse_Primary;
                        begin
                           if Kind (Result, Called) = Call then
                              return Called;
                           end if;

                           Complain
                             (Item    => Syn.Expression_Expected,
                              Where   => Where (Result, Called),
                              Message => "this statement must be a call",
                              Note    => "[1810]: a selected callee keeps"
                                         & " the same statement form as a"
                                         & " direct callee",
                              Related => Start,
                              Because => "the statement starts here");
                           return Add
                             (Error_Statement, Start,
                              Join (Start, After_Previous), [Called]);
                        end;
                     end if;

                     declare
                        At_Name : constant Landin.Source.Span := Here;
                     begin
                        Complain
                          (Item    => Syn.Token_Expected,
                           Where   => After_Previous,
                           Message => "a statement that begins with a"
                                      & " name is a binding, an"
                                      & " assignment or a call",
                           Note    => "[1810]: `:` or `:=` opens a"
                                      & " binding, `=` an assignment and"
                                      & " `(` a call",
                           Related => At_Name,
                           Because => "this name");
                        Advance;
                        Resync_Statement;
                        return Add
                          (Error_Statement, At_Name,
                           Join (Start, After_Previous));
                     end;

                  when others =>
                     declare
                        At_Bad : constant Landin.Source.Span := Here;
                     begin
                        Advance;
                        Resync_Statement;
                        return Add
                          (Error_Statement, At_Bad,
                           Join (Start, After_Previous));
                     end;
               end case;
            end Parse_Statement;

            --  loop_statement ::= "loop" "do" block "end" "loop"
            --  while_statement ::= "while" expression "do" block
            --                       "end" "while"                [1130/1140]
            function Parse_Loop
              (Context : Frame;
               Starts  : Landin.Source.Span := Landin.Source.Empty_Span;
               Label   : Landin.Source.Names.Name_Id :=
                 Landin.Source.Names.No_Name) return Node_Id
            is
               Opened : constant Landin.Source.Span :=
                 (if Starts = Landin.Source.Empty_Span then Here else Starts);
               Is_While : constant Boolean :=
                 Named_Here = While_Id;
               Test : Node_Id := No_Node;
               Runs : Node_Id;
               Completed : Node_Id := No_Node;
               Kept : Boolean;
               Saved_Complete : constant Boolean := Complete_Closes_Block;
            begin
               if Too_Deep (Opened) then
                  Advance;
                  Resync_Statement;
                  return Add
                    (Error_Statement, Opened, Join (Opened, After_Previous));
               end if;

               Depth := Depth + 1;
               Advance;
               if Is_While then
                  Test := Parse_Expression;
               end if;

               if Peek = Tok.Identifier and then Named_Here = Do_Id then
                  Advance;
               else
                  Complain
                    (Item    => Syn.Token_Expected,
                     Where   => (if Peek = Tok.End_Of_Input
                                 then After_Previous else Here),
                     Message => "a loop body opens with `do`",
                     Note    => (if Is_While
                                 then "[1140]: `while condition do`"
                                 else "[1130]: `loop do`"),
                     Related => Opened,
                     Because => "this loop");
               end if;

               Loop_Depth := Loop_Depth + 1;
               Loop_Labels (Loop_Depth) := Label;
               Complete_Closes_Block := True;
               Runs := Parse_Block (Context);
               Complete_Closes_Block := Saved_Complete;

               if Peek = Tok.Identifier
                 and then Named_Here = Complete_Id
               then
                  if not Is_While then
                     Complain
                       (Item    => Syn.Stray_Token,
                        Where   => Here,
                        Message => "an unconditional loop cannot complete",
                        Note    => "[1170]: `complete` is the edge where a"
                          & " finite loop runs out",
                        Related => Opened,
                        Because => "this unconditional loop");
                  end if;
                  Advance;
                  Completed := Parse_Block (Context);
               end if;

               Loop_Labels (Loop_Depth) := Landin.Source.Names.No_Name;
               Loop_Depth := Loop_Depth - 1;

               Kept := Expect
                 (Wanted  => Tok.Kw_End,
                  Message => "this loop is never closed",
                  Note    => (if Is_While
                              then "[1140]: a while loop closes with"
                                & " `end while`"
                              else "[1130]: a loop closes with `end loop`"),
                  Related => Opened,
                  Because => "opened here");
               if Kept then
                  if Peek = Tok.Identifier
                    and then Named_Here =
                      (if Label /= Landin.Source.Names.No_Name
                       then Label
                       elsif Is_While then While_Id else Loop_Id)
                  then
                     Advance;
                  else
                     Complain
                       (Item    => Syn.Token_Expected,
                        Where   => (if Peek = Tok.End_Of_Input
                                    then After_Previous else Here),
                        Message => (if Is_While
                                    then "a while loop closes with"
                                      & " `end while`"
                                    else "an unconditional loop closes"
                                      & " with `end loop`"),
                        Note    => (if Is_While then "[1140]" else "[1130]"),
                        Related => Opened,
                        Because => "this loop");
                  end if;
               end if;
               Depth := Depth - 1;

               if Is_While then
                  return Add
                    (Of_Kind  => While_Statement,
                     At_Token => Opened,
                     Extent   => Join (Opened, After_Previous),
                     Children => [Test, Runs, Completed],
                     Named    => Label);
               else
                  return Add
                    (Of_Kind  => Loop_Statement,
                     At_Token => Opened,
                     Extent   => Join (Opened, After_Previous),
                     Children => [Runs, Completed],
                     Named    => Label);
               end if;
            end Parse_Loop;

            --  for_statement ::= label? "for" identifier
            --    ("," identifier)? "in" expression
            --    ((".." | "..<") expression)? "do" block
            --    ("complete" block)? "end" (label | "for")       [1150]
            function Parse_For
              (Context : Frame;
               Starts  : Landin.Source.Span := Landin.Source.Empty_Span;
               Label   : Landin.Source.Names.Name_Id :=
                 Landin.Source.Names.No_Name) return Node_Id
            is
               Opened : constant Landin.Source.Span :=
                 (if Starts = Landin.Source.Empty_Span then Here else Starts);
               Element : Node_Id;
               Index : Node_Id := No_Node;
               Lower : Node_Id := No_Node;
               Upper : Node_Id := No_Node;
               Inclusive : Boolean := False;
               Runs : Node_Id;
               Completed : Node_Id := No_Node;
               Kept : Boolean;
               Saved_Complete : constant Boolean := Complete_Closes_Block;

               function Parse_Traversal_Binding
                 (Role : String) return Node_Id;

               function Parse_Traversal_Binding
                 (Role : String) return Node_Id
               is
                  At_Name : constant Landin.Source.Span :=
                    (if Peek = Tok.End_Of_Input then After_Previous else Here);
                  Named : Landin.Source.Names.Name_Id :=
                    Landin.Source.Names.No_Name;
               begin
                  if Peek = Tok.Identifier then
                     Named := Named_Here;
                     Advance;
                  else
                     Complain
                       (Item    => Syn.Token_Expected,
                        Where   => At_Name,
                        Message => "a for loop names its " & Role,
                        Note    => "[1150]: `for item, idx in source do`",
                        Related => Opened,
                        Because => "this traversal");
                  end if;
                  return Add
                    (Of_Kind  => Binding,
                     At_Token => At_Name,
                     Extent   => At_Name,
                     Children => [No_Node, No_Node],
                     Named    => Named);
               end Parse_Traversal_Binding;
            begin
               if Too_Deep (Opened) then
                  Advance;
                  Resync_Statement;
                  return Add
                    (Error_Statement, Opened, Join (Opened, After_Previous));
               end if;

               Depth := Depth + 1;
               Advance;
               Element := Parse_Traversal_Binding ("element binding");
               if Peek = Tok.Comma then
                  Advance;
                  Index := Parse_Traversal_Binding ("index binding");
               end if;

               if Expect
                 (Wanted  => Tok.Kw_In,
                  Message => "a for loop traverses with `in`",
                  Note    => "[1150]: `for item in source do`",
                  Related => Opened,
                  Because => "this traversal")
               then
                  Lower := Parse_Expression;
                  if Peek in Tok.Dot_Dot | Tok.Dot_Dot_Less then
                     Inclusive := Peek = Tok.Dot_Dot;
                     Advance;
                     Upper := Parse_Expression;
                  end if;
               end if;

               if Peek = Tok.Identifier and then Named_Here = Do_Id then
                  Advance;
               else
                  Complain
                    (Item    => Syn.Token_Expected,
                     Where   => (if Peek = Tok.End_Of_Input
                                 then After_Previous else Here),
                     Message => "a for loop body opens with `do`",
                     Note    => "[1150]: `for item in source do`",
                     Related => Opened,
                     Because => "this traversal");
               end if;

               Loop_Depth := Loop_Depth + 1;
               Loop_Labels (Loop_Depth) := Label;
               Complete_Closes_Block := True;
               Runs := Parse_Block (Context);
               Complete_Closes_Block := Saved_Complete;

               if Peek = Tok.Identifier
                 and then Named_Here = Complete_Id
               then
                  Advance;
                  Completed := Parse_Block (Context);
               end if;

               Loop_Labels (Loop_Depth) := Landin.Source.Names.No_Name;
               Loop_Depth := Loop_Depth - 1;

               Kept := Expect
                 (Wanted  => Tok.Kw_End,
                  Message => "this for loop is never closed",
                  Note    => "[1150]: a for loop closes with `end for`",
                  Related => Opened,
                  Because => "opened here");
               if Kept then
                  if Peek = Tok.Identifier
                    and then Named_Here =
                      (if Label /= Landin.Source.Names.No_Name
                       then Label else For_Id)
                  then
                     Advance;
                  else
                     Complain
                       (Item    => Syn.Token_Expected,
                        Where   => (if Peek = Tok.End_Of_Input
                                    then After_Previous else Here),
                        Message => "a for loop closes with `end "
                                   & (if Label /= Landin.Source.Names.No_Name
                                      then "<label>`" else "for`"),
                        Note    => "[1150]",
                        Related => Opened,
                        Because => "this traversal");
                  end if;
               end if;
               Depth := Depth - 1;

               return Add
                 (Of_Kind  => For_Statement,
                  At_Token => Opened,
                  Extent   => Join (Opened, After_Previous),
                  Children =>
                    [Lower, Upper, Element, Index, Runs, Completed],
                  Named    => Label,
                  Fills    => Inclusive);
            end Parse_For;

            --  transfer ::= "break" identifier? ("with" expression)?
            --               ("when" expression)?
            --             | "continue" identifier? ("when" expression)?
            function Parse_Loop_Transfer return Node_Id is
               Starts : constant Landin.Source.Span := Here;
               Is_Break : constant Boolean :=
                 Named_Here = Break_Id;
               Guard : Node_Id := No_Node;
               Value : Node_Id := No_Node;
               Target : Landin.Source.Names.Name_Id :=
                 Landin.Source.Names.No_Name;
               Targeted : Boolean := False;
            begin
               Advance;
               if Peek = Tok.Identifier and then Named_Here /= With_Id then
                  Target := Named_Here;
                  Advance;
               end if;
               if Peek = Tok.Identifier and then Named_Here = With_Id then
                  if not Is_Break then
                     Complain
                       (Item    => Syn.Stray_Token,
                        Where   => Here,
                        Message => "`continue` cannot carry a value",
                        Note    => "[1190]: only `break` uses `with`",
                        Related => Starts,
                        Because => "this loop transfer");
                  end if;
                  Advance;
                  Value := Parse_Expression;
               end if;
               if Peek = Tok.Kw_When then
                  Advance;
                  Guard := Parse_Expression;
               end if;

               if Target = Landin.Source.Names.No_Name then
                  Targeted := Loop_Depth > 0;
               else
                  for Index in reverse 1 .. Loop_Depth loop
                     if Loop_Labels (Index) = Target then
                        Targeted := True;
                        exit;
                     end if;
                  end loop;
               end if;

               if not Targeted then
                  Complain
                    (Item    => Syn.Stray_Token,
                     Where   => Starts,
                     Message => (if Is_Break
                                 then "`break` has no matching enclosing loop"
                                 else "`continue` has no matching enclosing"
                                   & " loop"),
                     Note    => "[1180]/[1190]: a loop transfer targets"
                       & " an enclosing loop");
                  return Add
                    (Error_Statement, Starts, Join (Starts, After_Previous));
               end if;

               return Add
                 (Of_Kind  =>
                    (if Is_Break then Break_Statement
                     else Continue_Statement),
                  At_Token => Starts,
                  Extent   => Join (Starts, After_Previous),
                  Children =>
                    (if Is_Break then Slot_List'[Value, Guard]
                     else Slot_List'[1 => Guard]),
                  Named    => Target);
            end Parse_Loop_Transfer;

            --  if ::= "if" expression "then" block
            --         ("elsif" expression "then" block)*
            --         ("else" block)? "end" "if"                  [1810]
            function Parse_If (Context : Frame) return Node_Id is
               At_If     : constant Landin.Source.Span := Here;
               Arms      : Slot_Vectors.Vector;
               Else_Node : Node_Id := No_Node;
            begin
               if Too_Deep (At_If) then
                  Advance;
                  Resync_Statement;
                  return Add
                    (Error_Statement, At_If, Join (At_If, After_Previous));
               end if;

               Depth := Depth + 1;

               loop
                  declare
                     At_Arm    : constant Landin.Source.Span := Here;
                     Condition : Node_Id;
                     Arm_Body  : Node_Id;
                     Kept      : Boolean;
                  begin
                     Advance;
                     Condition := Parse_Expression;
                     Kept := Expect
                       (Wanted  => Tok.Kw_Then,
                        Message => "a branch's condition is followed by"
                                   & " `then`",
                        Note    => "[1810]: if expression `then` block",
                        Related => At_If,
                        Because => "this branch");
                     pragma Unreferenced (Kept);
                     declare
                        Saved : constant Boolean := Else_Closes_Arm;
                     begin
                        Else_Closes_Arm := True;
                        Arm_Body := Parse_Block
                          (Context, Allow_Value => True);
                        Else_Closes_Arm := Saved;
                     end;
                     Arms.Append
                       (Add (Of_Kind  => If_Arm,
                             At_Token => At_Arm,
                             Extent   => Join (At_Arm, After_Previous),
                             Children => [Condition, Arm_Body]));
                  end;

                  exit when Peek /= Tok.Kw_Elsif;
               end loop;

               if Peek = Tok.Kw_Else then
                  Advance;
                  Else_Node := Parse_Block
                    (Context, Allow_Value => True);
               end if;

               Depth := Depth - 1;

               --  P4: an `end` that is not this branch's is left where it
               --  is, for whatever construct needs it, so one missing
               --  `end` is one report rather than two.
               if Peek = Tok.Kw_End and then Ahead (1) = Tok.Kw_If then
                  Advance;
                  Advance;
               else
                  Complain
                    (Item    => Syn.Unclosed_Construct,
                     Where   => After_Previous,
                     Message => "this branch is never closed",
                     Note    => "[1810]: a branch closes with `end` `if`",
                     Related => At_If,
                     Because => "opened here",
                     Gate    => False);
               end if;

               declare
                  Head : constant Slot_List (1 .. 1) := [Else_Node];
               begin
                  return Add
                    (Of_Kind  => If_Statement,
                     At_Token => At_If,
                     Extent   => Join (At_If, After_Previous),
                     Children => Head & To_List (Arms));
               end;
            end Parse_If;

            --  bare_block ::= "begin" block "end"              [1080]
            --
            --  `begin` remains contextual like `match`: it is an ordinary
            --  identifier everywhere except the expression/statement first
            --  position that gives this production its shape.  The Block
            --  owns the lexical scope; this wrapper owns the expression.
            function Parse_Bare_Block (Context : Frame) return Node_Id is
               At_Begin : constant Landin.Source.Span := Here;
               Runs     : Node_Id;
            begin
               if Too_Deep (At_Begin) then
                  Advance;
                  Resync_Statement;
                  return Add
                    (Error_Expression, At_Begin,
                     Join (At_Begin, After_Previous));
               end if;

               Depth := Depth + 1;
               Advance;
               Runs := Parse_Block (Context, Allow_Value => True);
               Depth := Depth - 1;

               --  Do not steal the two-word closer of an enclosing control
               --  construct when this block's own `end` is missing.
               if Peek = Tok.Kw_End
                 and then Ahead (1) /= Tok.Kw_If
                 and then not
                   (Ahead (1) = Tok.Identifier
                    and then Named_Ahead (1) = Match_Id)
               then
                  Advance;
               else
                  Complain
                    (Item    => Syn.Unclosed_Construct,
                     Where   => After_Previous,
                     Message => "this bare block is never closed",
                     Note    => "[1080]: a bare block closes with `end`",
                     Related => At_Begin,
                     Because => "opened here",
                     Gate    => False);
               end if;

               return Add
                 (Of_Kind  => Bare_Block,
                  At_Token => At_Begin,
                  Extent   => Join (At_Begin, After_Previous),
                  Children => [Runs]);
            end Parse_Bare_Block;

            --  match ::= "match" expression match_arm+ "end" "match"
            --  match_arm ::= identifier ("(" match_binding
            --                ("," match_binding)* ")")?
            --                ":" (statement | expression)
            --  match_binding ::= "inout"? identifier                D78
            --
            --  One statement or expression per arm is the executable
            --  boundary and is deliberately independent of indentation.  A
            --  bare block carries a multi-statement value.  D78's bindings
            --  are positional aliases for that case's payload.
            function Parse_Match (Context : Frame) return Node_Id is
               At_Match : constant Landin.Source.Span := Here;
               Subject  : Node_Id;
               Arms     : Slot_Vectors.Vector;
            begin
               if Too_Deep (At_Match) then
                  Advance;
                  Resync_Statement;
                  return Add
                    (Error_Statement, At_Match,
                     Join (At_Match, After_Previous));
               end if;

               Depth := Depth + 1;
               Advance;
               Subject := Parse_Expression;

               while not (Peek = Tok.Kw_End
                           and then Ahead (1) = Tok.Identifier
                           and then Named_Ahead (1) = Match_Id)
                 and then Peek /= Tok.End_Of_Input
               loop
                  if Peek not in Tok.Identifier | Tok.Underscore then
                     Complain
                       (Item    => Syn.Name_Expected,
                        Where   => Here,
                        Message => "a match arm begins with a case name",
                        Note    => "D77: match expression case `:`"
                                   & " arm `end match`");
                     Resync_Statement;
                     exit;
                  end if;

                  declare
                     At_Case : constant Landin.Source.Span := Here;
                     Named   : constant Landin.Source.Names.Name_Id :=
                       (if Peek = Tok.Underscore
                        then Landin.Source.Names.No_Name else Named_Here);
                     Pattern, Runs : Node_Id;
                     Bindings : Slot_Vectors.Vector;
                     Kept : Boolean;
                  begin
                     if Peek = Tok.Underscore then
                        Advance;
                        Pattern := Add
                          (Of_Kind  => Name_Reference,
                           At_Token => At_Case,
                           Named    => Named);
                     else
                        Pattern := Parse_Qualified_Reference
                          (Name_Reference);
                     end if;

                     if Peek = Tok.Left_Paren then
                        Advance;
                        loop
                           declare
                              Mutable : Boolean := False;
                              At_Name : Landin.Source.Span;
                              Bound   : Landin.Source.Names.Name_Id;
                           begin
                              if Peek = Tok.Kw_Inout then
                                 Mutable := True;
                                 Advance;
                              end if;

                              if Peek /= Tok.Identifier then
                                 Complain
                                   (Item    => Syn.Name_Expected,
                                    Where   => Here,
                                    Message => "a payload binding needs a"
                                               & " name",
                                    Note    => "D78: case(name, inout name)"
                                               & " `:` statement");
                                 Resync (List_Anchor);
                                 exit;
                              end if;

                              At_Name := Here;
                              Bound := Named_Here;
                              Advance;
                              Bindings.Append
                                (Add (Of_Kind  => Match_Binding,
                                      At_Token => At_Name,
                                      Named    => Bound,
                                      Mutable  => Mutable));
                           end;

                           exit when Peek /= Tok.Comma;
                           Advance;
                        end loop;

                        Kept := Expect
                          (Wanted  => Tok.Right_Paren,
                           Message => "payload bindings end with `)`",
                           Note    => "D78: case(name, inout name)"
                                      & " `:` statement",
                           Related => At_Case,
                           Because => "this match arm");
                     end if;

                     Kept := Expect
                       (Wanted  => Tok.Colon,
                        Message => "a match arm puts `:` after its case",
                        Note    => "D77: case `:` statement",
                        Related => At_Case,
                        Because => "this case");
                     pragma Unreferenced (Kept);

                     declare
                        Value      : Node_Id := No_Node;
                        Statement  : Node_Id := No_Node;
                        Body_Items : Slot_Vectors.Vector;
                        Is_Statement : constant Boolean :=
                          Peek in Tok.Kw_Mut | Tok.Kw_Inc | Tok.Kw_Dec
                                  | Tok.Underscore | Tok.Kw_Return
                                  | Tok.Kw_Fail | Tok.Kw_Public
                          or else
                            (Peek = Tok.Identifier
                             and then
                               (Named_Here in Defer_Id | Undo_Id
                                or else
                                  (Named_Here not in Match_Id | Begin_Id
                                     | Loop_Id | While_Id | For_Id
                                   and then not
                                     (Ahead (1) = Tok.Colon
                                      and then Ahead (2) = Tok.Identifier
                                      and then Named_Ahead (2)
                                        in Loop_Id | While_Id | For_Id)
                                   and then
                                     (Word_At_Hand /= Word_None
                                      or else Ahead (1)
                                        in Tok.Colon | Tok.Colon_Equal
                                      or else After_Selectors = Tok.Equal))));
                     begin
                        if Pre.Begins_Expression (Peek)
                          and then not Is_Statement
                        then
                           Value := Parse_Expression;

                           if Kind (Result, Value)
                                in If_Statement | Match_Statement
                                   | Bare_Block | Loop_Statement
                                   | While_Statement
                             and then not Control_Offers_Value (Value)
                           then
                              Body_Items.Append (Value);
                              Value := No_Node;
                           end if;
                        else
                           Statement := Parse_Statement (Context);
                           Body_Items.Append (Statement);
                        end if;

                        declare
                           Head : constant Slot_List (1 .. 1) := [Value];
                        begin
                           Runs := Add
                             (Of_Kind  => Block,
                              At_Token => At_Case,
                              Extent   => Join (At_Case, After_Previous),
                              Children => Head & To_List (Body_Items));
                        end;
                     end;
                     Arms.Append
                       (Add (Of_Kind  => Match_Arm,
                             At_Token => At_Case,
                             Extent   => Join (At_Case, After_Previous),
                             Children => [Pattern, Runs]
                                         & To_List (Bindings)));
                  end;
               end loop;

               Depth := Depth - 1;
               if Peek = Tok.Kw_End
                 and then Ahead (1) = Tok.Identifier
                 and then Named_Ahead (1) = Match_Id
               then
                  Advance;
                  Advance;
               else
                  Complain
                    (Item    => Syn.Unclosed_Construct,
                     Where   => After_Previous,
                     Message => "this match is never closed",
                     Note    => "D77: a match closes with `end match`",
                     Related => At_Match,
                     Because => "opened here",
                     Gate    => False);
               end if;

               if Arms.Is_Empty then
                  Complain
                    (Item    => Syn.Name_Expected,
                     Where   => At_Match,
                     Message => "a match needs at least one case arm",
                     Note    => "[1210]: a missing case is a compile error");
                  Arms.Append
                    (Add (Of_Kind  => Match_Arm,
                          At_Token => At_Match,
                          Children =>
                            [Add (Error_Expression, At_Match),
                             Add (Block, At_Match,
                                  Children => [No_Node])]));
               end if;

               declare
                  Head : constant Slot_List (1 .. 1) := [Subject];
               begin
                  return Add
                    (Of_Kind  => Match_Statement,
                     At_Token => At_Match,
                     Extent   => Join (At_Match, After_Previous),
                     Children => Head & To_List (Arms));
               end;
            end Parse_Match;

            ------------------------------------------------------------
            --  Expressions                                      [1820]
            ------------------------------------------------------------

            --  Ten binary levels, one loop.  Levels are declared loosest
            --  first, so "tighter" is "greater", and recursing at
            --  Level'Succ is what makes every level left associative.
            function Parse_Expression
              (Min : Pre.Level := Pre.Level_Expression) return Node_Id
            is
            begin
               return Parse_Expression_From (Parse_Unary, Min);
            end Parse_Expression;

            function Parse_Expression_From
              (Seed : Node_Id;
               Min  : Pre.Level := Pre.Level_Expression) return Node_Id
            is
               Left    : Node_Id := Seed;
               Chained : Boolean := False;
               First   : Landin.Source.Span := Landin.Source.Empty_Span;
            begin
               loop
                  declare
                     Op : constant Tok.Token_Kind := Peek;
                  begin
                     exit when not Pre.Is_Binary (Op);

                     declare
                        Rank  : constant Pre.Level := Pre.Binary_Level (Op);
                        At_Op : constant Landin.Source.Span := Here;
                        Right : Node_Id;
                     begin
                        exit when Rank < Min;

                        --  [1820] writes comparison with `?` where every
                        --  other level is written with `*`, so this is a
                        --  table value and not a special case.
                        if Pre.Fold (Rank) = Pre.Non_Associative
                          and then Chained
                        then
                           Complain
                             (Item    => Syn.Comparison_Chained,
                              Where   => At_Op,
                              Message => "comparison takes at most one"
                                         & " operator",
                              Note    => "[1820]: a chain read left to"
                                         & " right would compare a bool"
                                         & " with a number, and [0310]"
                                         & " refuses that anyway",
                              Related => First,
                              Because => "the first comparison");
                        end if;

                        Advance;
                        if Pre.Begins_Expression (Peek) then
                           Right := Parse_Expression (Pre.Level'Succ (Rank));
                        else
                           --  Keep a closer in hand for its owning construct.
                           --  In `[1 + ]u8`, consuming `]` here would turn one
                           --  missing operand into a missing bracket and lose
                           --  the valid element type that follows it.
                           Complain
                             (Item    => Syn.Expression_Expected,
                              Where   => (if Peek = Tok.End_Of_Input
                                          then After_Previous else Here),
                              Message => "an expression belongs after this"
                                         & " operator",
                              Note    => "[1820]: every binary operator has"
                                         & " a right operand",
                              Related => At_Op,
                              Because => "the operator");
                           Right := Add (Error_Expression, Point);
                        end if;
                        Left := Add
                          (Of_Kind  => Pre.Binary_Node (Op),
                           At_Token => At_Op,
                           Children => [Left, Right]);

                        if Pre.Fold (Rank) = Pre.Non_Associative then
                           Chained := True;

                           if First = Landin.Source.Empty_Span then
                              First := At_Op;
                           end if;
                        end if;
                     end;
                  end;
               end loop;

               --  [0390]: an `=` where an operator or a closer was
               --  expected is assignment used as an expression, which is
               --  a named rule with its own recovery -- swallow it -- and
               --  not a token nothing allows.
               if Min = Pre.Level_Expression
                 and then Peek in Tok.Equal | Tok.Colon_Equal
               then
                  declare
                     At_Op : constant Landin.Source.Span := Here;
                     Right : Node_Id;
                  begin
                     Complain
                       (Item    => Syn.Assignment_In_Expression,
                        Where   => At_Op,
                        Message => "assignment is a statement, never an"
                                   & " expression",
                        Note    => "[0390]: `==` compares; an assignment"
                                   & " stands on its own");
                     Advance;
                     Right := Parse_Expression;
                     Left := Add
                       (Of_Kind  => Error_Expression,
                        At_Token => At_Op,
                        Children => [Left, Right]);
                  end;
               end if;

               return Left;
            end Parse_Expression_From;

            --  unary ::= ("-" | "~" | "not")* primary             [1820]
            function Parse_Unary return Node_Id is
            begin
               if Peek = Tok.Kw_Try then
                  declare
                     At_Try : constant Landin.Source.Span := Here;
                     Operand : Node_Id;
                  begin
                     if Too_Deep (At_Try) then
                        Advance;
                        return Add (Error_Expression, At_Try);
                     end if;
                     Depth := Depth + 1;
                     Advance;
                     Operand := Parse_Unary;
                     Depth := Depth - 1;
                     return Add
                       (Of_Kind  => Try_Expression,
                        At_Token => At_Try,
                        Extent   => Join (At_Try, After_Previous),
                        Children => [Operand]);
                  end;
               end if;

               if not Pre.Is_Prefix (Peek) then
                  return Parse_Primary;
               end if;

               declare
                  At_Op   : constant Landin.Source.Span := Here;
                  Op      : constant Tok.Token_Kind := Peek;
                  Operand : Node_Id;
               begin
                  if Too_Deep (At_Op) then
                     Advance;
                     return Add (Error_Expression, At_Op);
                  end if;

                  Depth := Depth + 1;
                  Advance;
                  Operand := Parse_Unary;
                  Depth := Depth - 1;

                  return Add
                    (Of_Kind  => Pre.Unary_Node (Op),
                     At_Token => At_Op,
                     Children => [Operand]);
               end;
            end Parse_Unary;

            --  [1810]'s primary expression forms, including literals,
            --  names, calls, measurements and parenthesized expressions.
            function Parse_Primary return Node_Id is
               At_Item : constant Landin.Source.Span := Here;
            begin
               if Peek not in Tok.Kernel_Kind then
                  Mark_Reported;
                  Advance;
                  return Add (Error_Expression, At_Item);
               end if;

               --  D124 moves the existing control nodes into the expression
               --  band.  `if` is reserved; `match`, `begin` and the loop
               --  forms are contextual identifiers and are intercepted
               --  before the ordinary name/call path below.
               if Peek = Tok.Kw_If then
                  return Parse_If (Active_Frame);
               elsif Peek = Tok.Identifier and then Named_Here = Match_Id
               then
                  return Parse_Match (Active_Frame);
               elsif Peek = Tok.Identifier and then Named_Here = Begin_Id
               then
                  return Parse_Bare_Block (Active_Frame);
               elsif Peek = Tok.Identifier
                 and then Ahead (1) = Tok.Colon
                 and then Ahead (2) = Tok.Identifier
                 and then Named_Ahead (2) in Loop_Id | While_Id | For_Id
               then
                  declare
                     Label : constant Landin.Source.Names.Name_Id :=
                       Named_Here;
                     Label_At : constant Landin.Source.Span := Here;
                     Is_For : constant Boolean :=
                       Named_Ahead (2) = For_Id;
                  begin
                     Advance;
                     Advance;
                     if Is_For then
                        return Parse_For
                          (Active_Frame, Starts => Label_At, Label => Label);
                     else
                        return Parse_Loop
                          (Active_Frame, Starts => Label_At, Label => Label);
                     end if;
                  end;
               elsif Peek = Tok.Identifier
                 and then Named_Here in Loop_Id | While_Id | For_Id
               then
                  if Named_Here = For_Id then
                     return Parse_For (Active_Frame);
                  else
                     return Parse_Loop (Active_Frame);
                  end if;
               end if;

               --  [0520]'s literal is one or more expressions in source
               --  order.  Empty arrays remain outside this slice, as does
               --  [0560]'s contextual `of` repetition.
               if Peek = Tok.Left_Bracket then
                  declare
                     Items : Slot_Vectors.Vector;

                     procedure Skip_Remaining;
                     function Finish_Repetition
                       (Count : Node_Id; At_Of : Landin.Source.Span)
                        return Node_Id;

                     procedure Skip_Remaining is
                        Level : Natural := 1;
                     begin
                        while Peek /= Tok.End_Of_Input loop
                           if Peek = Tok.Left_Bracket then
                              Level := Level + 1;
                           elsif Peek = Tok.Right_Bracket then
                              Level := Level - 1;
                              Advance;
                              exit when Level = 0;
                              goto Continue;
                           end if;

                           Advance;
                           <<Continue>>
                        end loop;
                     end Skip_Remaining;

                     function Finish_Repetition
                       (Count : Node_Id; At_Of : Landin.Source.Span)
                        return Node_Id
                     is
                        Value : constant Node_Id := Parse_Expression;
                     begin
                        if not Expect
                                 (Wanted  => Tok.Right_Bracket,
                                  Message => "array repetition is closed with"
                                             & " `]`",
                                  Note    => "[0560]: repetition stays between"
                                             & " its brackets",
                                  Related => At_Item,
                                  Because => "opened here")
                        then
                           Resync (List_Anchor);

                           if Peek = Tok.Right_Bracket then
                              Advance;
                           end if;
                        end if;

                        Depth := Depth - 1;
                        return Add
                          (Of_Kind  => Array_Repetition,
                           At_Token => At_Of,
                           Extent   => Join (At_Item, After_Previous),
                           Children => [Count, Value]);
                     end Finish_Repetition;
                  begin
                     if Too_Deep (At_Item) then
                        Resync_Brackets;
                        return Add (Error_Expression, At_Item);
                     end if;

                     Depth := Depth + 1;
                     Advance;

                     --  [0560]'s contextual count takes the destination's
                     --  fixed-array shape rather than spelling one here.
                     if Peek = Tok.Identifier
                       and then Named_Here = Of_Id
                       and then Pre.Begins_Expression (Ahead (1))
                     then
                        declare
                           At_Of : constant Landin.Source.Span := Here;
                        begin
                           Advance;
                           return Finish_Repetition (No_Node, At_Of);
                        end;
                     end if;

                     if Peek = Tok.Right_Bracket then
                        Advance;
                        Depth := Depth - 1;
                        return Add
                          (Empty_Slice_Literal, At_Item,
                           Join (At_Item, After_Previous));
                     end if;

                     loop
                        --  D36 keeps `of` contextual: only the spelling after
                        --  a comma and before something that can begin an
                        --  expression ends the nonempty literal prefix.
                        if not Items.Is_Empty
                          and then Peek = Tok.Identifier
                          and then Named_Here = Of_Id
                          and then Pre.Begins_Expression (Ahead (1))
                        then
                           declare
                              At_Of : constant Landin.Source.Span := Here;
                              Value : Node_Id;
                           begin
                              Advance;
                              Value := Parse_Expression;

                              if not Expect
                                (Wanted  => Tok.Right_Bracket,
                                 Message => "mixed array repetition is closed"
                                            & " with `]`",
                                 Note    => "D36: the repeated suffix stays"
                                            & " between its brackets",
                                 Related => At_Item,
                                 Because => "opened here")
                              then
                                 Resync (List_Anchor);

                                 if Peek = Tok.Right_Bracket then
                                    Advance;
                                 end if;
                              end if;

                              Depth := Depth - 1;
                              return Add
                                (Of_Kind  => Mixed_Array_Repetition,
                                 At_Token => At_Of,
                                 Extent   => Join (At_Item, After_Previous),
                                 Children => [Value] & To_List (Items));
                           end;
                        end if;

                        Items.Append (Parse_Expression);

                        if Peek = Tok.Identifier
                          and then Named_Here = Of_Id
                        then
                           declare
                              At_Of : constant Landin.Source.Span := Here;
                           begin
                              if Natural (Items.Length) = 1
                                and then Kind
                                  (Result, Items.First_Element)
                                    = Integer_Literal
                              then
                                 Advance;
                                 return Finish_Repetition
                                          (Items.First_Element, At_Of);
                              end if;

                              Refuse
                                (Item    => Syn.Array_Repetition,
                                 Where   => At_Of,
                                 Message => "only a literal count may stand"
                                            & " before `of` in this kernel");
                              Skip_Remaining;
                              Depth := Depth - 1;
                              return Add
                                (Error_Expression, At_Item,
                                 Join (At_Item, After_Previous),
                                 To_List (Items));
                           end;
                        end if;

                        exit when Peek /= Tok.Comma;
                        Advance;
                     end loop;

                     Depth := Depth - 1;
                     if not Expect
                              (Wanted  => Tok.Right_Bracket,
                               Message => "an array literal is closed with"
                                          & " `]`",
                               Note    => "[0520]: array literal ::= `[`"
                                          & " expression (`,' expression)*"
                                          & " `]`",
                               Related => At_Item,
                               Because => "opened here")
                     then
                        Resync (List_Anchor);

                        if Peek = Tok.Right_Bracket then
                           Advance;
                        end if;
                     end if;

                     return Add
                       (Of_Kind  => Array_Literal,
                        At_Token => At_Item,
                        Extent   => Join (At_Item, After_Previous),
                        Children => To_List (Items));
                  end;
               end if;

               if Peek = Tok.Integer_Literal then
                  declare
                     Item : constant Tok.Token :=
                       Tok.Token_At (From, Index);
                  begin
                     Advance;
                     return Add
                       (Of_Kind   => Integer_Literal,
                        At_Token  => At_Item,
                        Radix     => Tok.Base (Item),
                        Digits_At => Tok.Digit_Span (Item));
                  end;
               end if;

               if Peek = Tok.Float_Literal then
                  Advance;
                  return Add (Of_Kind => Float_Literal, At_Token => At_Item);
               end if;

               if Peek = Tok.Character_Literal then
                  Advance;
                  return Add
                    (Of_Kind => Character_Literal, At_Token => At_Item);
               end if;

               if Peek = Tok.Text_Literal then
                  Advance;
                  return Add (Of_Kind => Text_Literal, At_Token => At_Item);
               end if;

               if Peek = Tok.Raw_Literal then
                  Advance;
                  return Add (Of_Kind => Raw_Literal, At_Token => At_Item);
               end if;

               --  [1380]: `any(pointer)` is explicit but takes its concept
               --  type from context.  The checker resolves the concrete
               --  conformance and retains the pointer's origin/permission.
               if Peek = Tok.Kw_Any then
                  Advance;
                  if not Expect
                    (Wanted  => Tok.Left_Paren,
                     Message => "`any` opens its pointer with `(`",
                     Note    => "[1380]: construction is `any(pointer)`",
                     Related => At_Item,
                     Because => "the erased value construction")
                  then
                     return Add (Error_Expression, At_Item);
                  end if;
                  declare
                     Value : constant Node_Id := Parse_Expression;
                  begin
                     if not Expect
                       (Wanted  => Tok.Right_Paren,
                        Message => "`any` closes its pointer with `)`",
                        Note    => "[1380]: the pointer stays between the"
                                   & " parentheses",
                        Related => At_Item,
                        Because => "opened here")
                     then
                        return Add
                          (Any_Construction, At_Item, Children => [Value]);
                     end if;
                     return Add
                       (Any_Construction, At_Item,
                        Extent => Join (At_Item, After_Previous),
                        Children => [Value]);
                  end;
               end if;

               --  [0460]/[0470]: `ptr(integer)` takes its complete pointer
               --  type from context.  It is its own node rather than a call:
               --  `ptr` is reserved and no runtime declaration is involved.
               if Peek = Tok.Kw_Ptr then
                  Advance;
                  if not Expect
                    (Wanted  => Tok.Left_Paren,
                     Message => "`ptr` opens its integer with `(`",
                     Note    => "[0460]: `ptr(integer)` is an address literal",
                     Related => At_Item,
                     Because => "the pointer conversion")
                  then
                     return Add (Error_Expression, At_Item);
                  end if;
                  declare
                     Value : constant Node_Id := Parse_Expression;
                  begin
                     if not Expect
                       (Wanted  => Tok.Right_Paren,
                        Message => "`ptr` closes its integer with `)`",
                        Note    => "[0460]: `ptr(integer)` keeps the value"
                                   & " between parentheses",
                        Related => At_Item,
                        Because => "opened here")
                     then
                        return Add
                          (Pointer_Conversion, At_Item, Children => [Value]);
                     end if;
                     return Add
                       (Pointer_Conversion, At_Item,
                        Extent => Join (At_Item, After_Previous),
                        Children => [Value]);
                  end;
               end if;

               --  [0380]/[0430]: `addr` takes the ordinary place syntax.
               --  The parser retains that place without deciding whether it
               --  is addressable; later R2.50 checking owns that question.
               if Peek = Tok.Kw_Addr then
                  Advance;
                  declare
                     Place : constant Node_Id := Parse_Place;
                  begin
                     return Add
                       (Address_Of, At_Item,
                        Extent   => Join (At_Item, After_Previous),
                        Children => [1 => Place]);
                  end;
               end if;

               --  [0370]'s third measurement.  `lenof` stays contextual:
               --  only this expression position meets its spelling.  D31's
               --  literal is parenthesized so an ordinary binding named
               --  `lenof` keeps [0570]'s `lenof[index]` spelling.
               if Peek = Tok.Identifier
                 and then Named_Here = Lenof_Id
                 and then
                   (Ahead (1) = Tok.Identifier
                    or else
                      (Ahead (1) = Tok.Left_Paren
                       and then Ahead (2) = Tok.Left_Bracket))
               then
                  Advance;

                  if Peek = Tok.Left_Paren then
                     return Add
                       (Len_Of, At_Item,
                        Children => [1 => Parse_Primary]);
                  end if;

                  declare
                     At_Name : constant Landin.Source.Span := Here;
                     Named   : constant Landin.Source.Names.Name_Id :=
                       Named_Here;
                  begin
                     Advance;
                     return Add
                       (Len_Of, At_Item,
                        Children =>
                          [1 => Add
                             (Name_Reference, At_Name, Named => Named)]);
                  end;
               end if;

               --  [0370]: `sizeof` and `alignof` take a type where every
               --  other expression takes an expression.  Parse_Type is
               --  reused rather than a second reading of the same rule,
               --  so a type the kernel omits is refused by name here as
               --  it is anywhere else a type may be written.
               if Peek in Tok.Kw_Sizeof | Tok.Kw_Alignof then
                  declare
                     Measuring : constant Node_Kind :=
                       (if Peek = Tok.Kw_Sizeof then Size_Of else Align_Of);
                  begin
                     Advance;
                     return Add
                       (Of_Kind  => Measuring,
                        At_Token => At_Item,
                        Children =>
                          [1 => Parse_Type (False, At_Item)]);
                  end;
               end if;

               if Peek = Tok.Kw_True then
                  Advance;
                  return Add (True_Literal, At_Item);
               end if;

               if Peek = Tok.Kw_False then
                  Advance;
                  return Add (False_Literal, At_Item);
               end if;

               if Peek = Tok.Kw_Zeroed then
                  Advance;
                  return Add (Zeroed_Literal, At_Item);
               end if;

               if Peek = Tok.Left_Paren then
                  if Starts_Signature then
                     return Parse_Anonymous_Function;
                  end if;

                  --  D64 replaces D63's labelled refusal with [0710]'s real
                  --  field-value run.  The all-`of` form remains outside the
                  --  grammar; `of` is contextual just as it is in [0560].
                  if Ahead (1) = Tok.Identifier
                    and then Ahead (2) = Tok.Colon
                  then
                     return Parse_Struct_Literal (No_Node, At_Item);
                  elsif Ahead (1) = Tok.Identifier
                    and then Named_Ahead (1) = Of_Id
                    and then Pre.Begins_Expression (Ahead (2))
                    and then not Pre.Is_Binary (Ahead (2))
                  then
                     Refuse
                       (Item    => Syn.Struct_All_Of,
                        Where   => At_Item,
                        Message => "an all-`of` struct literal is not"
                                   & " enabled yet");
                     Advance;
                     Resync_Parentheses;

                     while Peek = Tok.Left_Bracket loop
                        Resync_Brackets;
                     end loop;

                     return Add
                       (Error_Expression, At_Item,
                        Join (At_Item, After_Previous));
                  end if;

                  if Too_Deep (At_Item) then
                     Advance;
                     Resync (List_Anchor);
                     return Add
                       (Error_Expression, At_Item,
                        Join (At_Item, After_Previous));
                  end if;

                  Depth := Depth + 1;
                  Advance;

                  declare
                     Saved : constant Boolean := Else_Closes_Arm;
                     Inner : Node_Id;
                     Kept  : Boolean;
                  begin
                     Else_Closes_Arm := False;
                     Inner := Parse_Expression;
                     Else_Closes_Arm := Saved;
                     Depth := Depth - 1;
                     Kept := Expect
                       (Wanted  => Tok.Right_Paren,
                        Message => "a parenthesised expression is closed"
                                   & " with `)`",
                        Note    => "[1810]: a parenthesized expression is"
                                   & " one primary expression",
                        Related => At_Item,
                        Because => "opened here");

                     if not Kept then
                        Resync (List_Anchor);

                        if Peek = Tok.Right_Paren then
                           Advance;
                        end if;
                     end if;

                     --  Nothing indexes a parenthesised expression: [1820]
                     --  indexes what a selection named, and a call and a
                     --  parenthesis are each their own production.
                     Refuse_Any_Index;
                     return Inner;
                  end;
               end if;

               if Peek = Tok.Identifier then
                  --  `:` never follows an expression: it appears in four
                  --  productions and in each it follows a name being
                  --  declared.  So an identifier followed by `:` or `:=`
                  --  begins a declaration and is not an operand, and
                  --  saying so here is what lets the rest of a file's
                  --  mistakes be reported instead of swallowed.
                  if Ahead (1) in Tok.Colon | Tok.Colon_Equal then
                     Complain
                       (Item    => Syn.Expression_Expected,
                        Where   => After_Previous,
                        Message => "an expression belongs here",
                        Note    => "[1820]: a literal, a name, a call or"
                                   & " a parenthesised expression",
                        Related => Previous,
                        Because => "required by this");
                     return Add (Error_Expression, Point);
                  end if;

                  declare
                     Named : constant Landin.Source.Names.Name_Id :=
                       Named_Here;
                  begin
                     Advance;

                     --  A call is its own production [1820] and nothing
                     --  selects from one, so only the index is refused
                     --  here: routing a call through the selection loop
                     --  would make `size().x` derive where the grammar
                     --  spells no rule for it.
                     if Peek = Tok.Left_Paren then
                        declare
                           Called : constant Node_Id :=
                             Parse_Call (At_Item, Named);
                        begin
                           Refuse_Any_Index;
                           return Called;
                        end;
                     end if;

                     --  A selected function field is still a runtime value.
                     --  Parentheses after the complete selection call that
                     --  value; construction remains the direct-name branch
                     --  above because a field cannot name a type.
                     declare
                        Selected : constant Node_Id :=
                          Parse_Selectors
                            (Add
                               (Name_Reference, At_Item, Named => Named));
                     begin
                        if Peek = Tok.Left_Paren then
                           return Parse_Call (Selected, At_Item);
                        end if;
                        return Selected;
                     end;
                  end;
               end if;

               Complain
                 (Item    => Syn.Expression_Expected,
                  Where   => (if Peek = Tok.End_Of_Input
                              then After_Previous else At_Item),
                  Message => "an expression belongs here",
                  Note    => "[1820]: a literal, a name, a call or a"
                             & " parenthesised expression",
                  Related => Previous,
                  Because => "required by this");

               --  Consumed only when it cannot begin something the
               --  enclosing construct still wants, so a missing operand
               --  does not eat the statement after it.
               if Peek /= Tok.End_Of_Input
                 and then not Pre.Begins_Statement (Peek)
                 and then Peek /= Tok.Kw_End
               then
                  Advance;
               end if;

               return Add (Error_Expression, At_Item);
            end Parse_Primary;

            --  struct_literal ::= "(" field_value ("," field_value)*
            --                     ("," "of" expression)? ")"       [1810]
            --  field_value ::= identifier ":" expression
            function Parse_Struct_Literal
              (Nominal : Node_Id;
               Starts  : Landin.Source.Span) return Node_Id
            is
               At_Paren : constant Landin.Source.Span := Here;
               Fields  : Slot_Vectors.Vector;
               Fill    : Node_Id := No_Node;
               Failed  : Boolean := False;
            begin
               if Too_Deep (At_Paren) then
                  Advance;
                  Resync_Parentheses;
                  return Add
                    (Error_Expression, Starts,
                     Join (Starts, After_Previous));
               end if;

               Depth := Depth + 1;
               Advance;

               loop
                  if Peek /= Tok.Identifier then
                     Complain
                       (Item    => Syn.Name_Expected,
                        Where   => (if Peek = Tok.End_Of_Input
                                    then After_Previous else Here),
                        Message => "a struct literal field name belongs here",
                        Note    => "[1810]: field_value ::= identifier `:`"
                                   & " expression");
                     Failed := True;
                     exit;
                  end if;

                  declare
                     At_Field : constant Landin.Source.Span := Here;
                     Named    : constant Landin.Source.Names.Name_Id :=
                       Named_Here;
                     Value    : Node_Id;
                  begin
                     Advance;
                     if not Expect
                       (Wanted  => Tok.Colon,
                        Message => "a struct literal field separates its"
                                   & " name and value with `:`",
                        Note    => "[1810]: field_value ::= identifier `:`"
                                   & " expression",
                        Related => At_Field,
                        Because => "the field named here")
                     then
                        Failed := True;
                        exit;
                     end if;

                     Value := Parse_Expression;
                     Fields.Append
                       (Add
                          (Of_Kind  => Field_Value,
                           At_Token => At_Field,
                           Extent   => Join
                             (At_Field, Extent_Of ([Value])),
                           Children => [Value],
                           Named    => Named));
                  end;

                  exit when Peek /= Tok.Comma;
                  Advance;

                  if Peek = Tok.Identifier
                    and then Named_Here = Of_Id
                    and then Ahead (1) /= Tok.Colon
                    and then Pre.Begins_Expression (Ahead (1))
                  then
                     Advance;
                     Fill := Parse_Expression;
                     exit;
                  end if;
               end loop;

               Depth := Depth - 1;
               if not Expect
                 (Wanted  => Tok.Right_Paren,
                  Message => "a struct literal is closed with `)`",
                  Note    => "[1810]: struct_literal keeps its fields"
                             & " between parentheses",
                  Related => At_Paren,
                  Because => "opened here")
               then
                  Failed := True;
                  Resync (List_Anchor);

                  if Peek = Tok.Right_Paren then
                     Advance;
                  end if;
               end if;

               if Failed then
                  return Add
                    (Error_Expression, Starts,
                     Join (Starts, After_Previous));
               end if;

               declare
                  Head : constant Slot_List (1 .. 2) := [Fill, Nominal];
                  Made : constant Node_Id :=
                    Add
                      (Of_Kind  => Struct_Literal,
                       At_Token => Starts,
                       Extent   => Join (Starts, After_Previous),
                       Children => Head & To_List (Fields));
               begin
                  --  Indexing a real literal is now its own refused shape,
                  --  rather than recovery from D63's literal refusal.
                  Refuse_Any_Index;
                  return Made;
               end;
            end Parse_Struct_Literal;

            --  A labelled argument RHS has one compact syntax tree.  The
            --  alternatives outside expression grammar are fixed-array,
            --  pointer, slice and function types; identifiers and positional
            --  direct applications first use the ordinary expression nodes,
            --  Syntax.Type_Projection exposes those ambiguous roots without
            --  cloning their descendants.
            function Parse_Argument_RHS return Node_Id is
               Saved  : constant Boolean := In_Argument_RHS;
               Result : Node_Id;
            begin
               In_Argument_RHS := True;
               if Begins_Argument_Type then
                  Result := Parse_Type (False, Here);
               else
                  Result := Parse_Expression;
               end if;
               In_Argument_RHS := Saved;
               return Result;
            end Parse_Argument_RHS;

            --  call ::= indexed "(" arguments? ")"                [1820]
            --
            --  A direct callee remains a Name_Reference.  D131 also lets the
            --  complete selection be a function value, without resolving a
            --  field name in lexical scope or selecting from the call itself.
            --  Unlike D72's old parser split, this entry never decides that a
            --  labelled application is construction merely from its colon.
            function Parse_Call
              (Name_At : Landin.Source.Span;
               Named   : Landin.Source.Names.Name_Id) return Node_Id
            is
            begin
               return Parse_Call
                 (Add (Name_Reference, Name_At, Named => Named), Name_At);
            end Parse_Call;

            function Parse_Call
              (Callee : Node_Id;
               Starts : Landin.Source.Span) return Node_Id
            is
               Recovery         : Node_Id := No_Node;
               Args             : Slot_Vectors.Vector;
               Named_Seen       : Boolean := False;
               Order_Complained : Boolean := False;
               Direct           : constant Boolean :=
                 Kind (Result, Callee) = Name_Reference;
            begin
               if not Expect
                        (Wanted  => Tok.Left_Paren,
                         Message => "a call opens its arguments with `(`",
                         Note    => "[1820]: call ::= callable `(`"
                                    & " arguments? `)`",
                         Related => Starts,
                         Because => "the value called")
               then
                  return Add
                    (Error_Expression, Starts, Children => [Callee]);
               end if;

               --  The all-`of` spelling remains the same named refusal as a
               --  bare all-`of` literal.  It carries no labelled field from
               --  which D72's construction grammar could begin.
               if Direct
                 and then Peek = Tok.Identifier
                 and then Named_Here = Of_Id
                 and then Pre.Begins_Expression (Ahead (1))
                 and then not Pre.Is_Binary (Ahead (1))
               then
                  Refuse
                    (Item    => Syn.Struct_All_Of,
                     Where   => Starts,
                     Message => "an all-`of` construction is not enabled"
                                & " yet");
                  Resync_Parentheses;

                  while Peek = Tok.Left_Bracket loop
                     Resync_Brackets;
                  end loop;

                  return Add
                    (Error_Expression, Starts,
                     Join (Starts, After_Previous), [Callee]);
               end if;

               if Peek /= Tok.Right_Paren then
                  loop
                     declare
                        Before : constant Tok.Token_Index := Index;
                     begin
                        if Peek = Tok.Identifier
                          and then
                            (Ahead (1) = Tok.Colon
                             or else
                               (Direct
                                and then Named_Seen
                                and then Named_Here = Of_Id
                                and then Pre.Begins_Expression (Ahead (1))))
                        then
                           declare
                              At_Label : constant Landin.Source.Span := Here;
                              Label : constant
                                Landin.Source.Names.Name_Id := Named_Here;
                              Is_Fill : constant Boolean :=
                                Ahead (1) /= Tok.Colon;
                              RHS : Node_Id;
                           begin
                              if not Named_Seen then
                                 --  Once a label appears every earlier
                                 --  positional child acquires the same
                                 --  argument wrapper.  The original child is
                                 --  moved under that wrapper, not copied, so
                                 --  post-order still visits it exactly once.
                                 for Position in 1 .. Natural (Args.Length)
                                 loop
                                    declare
                                       Existing : constant Node_Id :=
                                         Args.Element (Position);
                                    begin
                                       Args.Replace_Element
                                         (Position,
                                          Add
                                            (Of_Kind  => Call_Argument,
                                             At_Token => Anchor
                                               (Result, Existing),
                                             Extent   => Where
                                               (Result, Existing),
                                             Children => [1 => Existing]));
                                    end;
                                 end loop;
                                 Named_Seen := True;
                              end if;

                              Advance;
                              if not Is_Fill then
                                 Advance;
                              end if;
                              RHS := Parse_Argument_RHS;
                              Args.Append
                                (Add
                                   (Of_Kind  => Call_Argument,
                                    At_Token => At_Label,
                                    Extent   => Join
                                      (At_Label, Where (Result, RHS)),
                                    Children => [1 => RHS],
                                    Named    => Label,
                                    Fills    => Is_Fill));
                           end;
                        else
                           declare
                              At_Argument : constant Landin.Source.Span :=
                                Here;
                              RHS : constant Node_Id :=
                                (if In_Argument_RHS
                                 then Parse_Argument_RHS
                                 else Parse_Expression);
                           begin
                              if Named_Seen then
                                 if not Order_Complained then
                                    Complain
                                      (Item    => Syn.Positional_After_Named,
                                       Where   => At_Argument,
                                       Message => "a positional argument"
                                                  & " cannot follow a named"
                                                  & " argument",
                                       Note    => "[0980]: positional"
                                                  & " arguments come first");
                                    Order_Complained := True;
                                 end if;

                                 Args.Append
                                   (Add
                                      (Of_Kind  => Call_Argument,
                                       At_Token => At_Argument,
                                       Extent   => Where (Result, RHS),
                                       Children => [1 => RHS]));
                              else
                                 Args.Append (RHS);
                              end if;
                           end;
                        end if;
                        exit when Index = Before;
                     end;

                     exit when Peek /= Tok.Comma;
                     Advance;
                  end loop;
               end if;

               if not Expect
                        (Wanted  => Tok.Right_Paren,
                         Message => "a call's arguments are never closed",
                         Note    => "[1820]: call ::= callable `(`"
                                    & " arguments? `)`",
                         Related => Starts,
                         Because => "the value called")
               then
                  Resync (List_Anchor);

                  if Peek = Tok.Right_Paren then
                     Advance;
                  end if;
               end if;

               if Peek = Tok.Kw_Else and then not Else_Closes_Arm then
                  declare
                     At_Else : constant Landin.Source.Span := Here;
                     Error_Name : Landin.Source.Names.Name_Id :=
                       Landin.Source.Names.No_Name;
                     Recovery_Body : Node_Id;
                  begin
                     Advance;
                     if Peek = Tok.Left_Paren
                       and then Ahead (1) = Tok.Identifier
                       and then Ahead (2) = Tok.Right_Paren
                     then
                        Advance;
                        Error_Name := Named_Here;
                        Advance;
                        declare
                           Closed : constant Boolean :=
                             Expect
                               (Wanted  => Tok.Right_Paren,
                                Message => "an error binding closes with `)`",
                                Note    => "[1030]: `else (error)` binds"
                                           & " the failed atom",
                                Related => At_Else,
                                Because => "this recovery clause");
                        begin
                           pragma Unreferenced (Closed);
                        end;

                        Recovery_Body := Parse_Block
                          (Active_Frame, Allow_Value => True);
                        if Peek = Tok.Kw_End then
                           Advance;
                        else
                           Complain
                             (Item    => Syn.Unclosed_Construct,
                              Where   => After_Previous,
                              Message => "this recovery clause is never"
                                         & " closed",
                              Note    => "[1030]: a bound `else` clause"
                                         & " closes with `end`",
                              Related => At_Else,
                              Because => "opened here",
                              Gate    => False);
                        end if;
                     else
                        declare
                           Value : constant Node_Id := Parse_Expression;
                        begin
                           --  A one-expression `else` is the same value block
                           --  as the bound multiline form, represented by the
                           --  Block node every contextual consumer already
                           --  understands.
                           Recovery_Body := Add
                             (Of_Kind  => Block,
                              At_Token => At_Else,
                              Extent   => Join (At_Else, After_Previous),
                              Children => [1 => Value]);
                        end;
                     end if;

                     Recovery := Add
                       (Of_Kind  => Recovery_Clause,
                        At_Token => At_Else,
                        Extent   => Join (At_Else, After_Previous),
                        Children => [Recovery_Body],
                        Named    => Error_Name);
                  end;
               end if;

               declare
                  Head : constant Slot_List (1 .. 1) := [1 => Callee];
               begin
                  return Add
                    (Of_Kind  =>
                       (if Named_Seen then Labeled_Application else Call),
                     At_Token => Starts,
                     Extent   => Join (Starts, After_Previous),
                     Children => Head & To_List (Args),
                     Recovers => Recovery);
               end;
            end Parse_Call;

         begin
            Result.Source := Origin_Of;

            if Parse_Program /= Root (Result) then
               raise Compiler_Defect
                 with "the program is not the last node in the table";
            end if;
         end;
      end return;
   end Parse;

end Landin.Syntax.Parser;
