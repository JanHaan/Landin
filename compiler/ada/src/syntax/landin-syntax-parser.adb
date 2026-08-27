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

   --  `program ::= declaration*` [1740].
   Declaration_Anchor : constant Tok.Kind_Set :=
     [Tok.Kw_Public | Tok.Kw_Mut | Tok.Identifier
        | Tok.End_Of_Input => True,
      others => False];

   --  `body ::= statement*` and the arms of `if` [1810].  The closers are
   --  in it deliberately: a broken statement must resume at the next
   --  branch or at the body's `end` rather than run past it.
   Statement_Anchor : constant Tok.Kind_Set :=
     [Tok.Kw_Mut | Tok.Identifier | Tok.Underscore | Tok.Kw_Inc
        | Tok.Kw_Dec | Tok.Kw_Return | Tok.Kw_If | Tok.Kw_Elsif
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
   --  [1760] reserves seventeen words, and none of them is `loop`,
   --  `match`, `while`, `for`, `defer`, `undo`, `try`, `fail`, `break` or
   --  `continue`.  Every one of those lexes as an ordinary identifier, so
   --  the scan cannot refuse it and only the parser can: at a statement
   --  position, an identifier that is one of these is the construct the
   --  tour describes and not a name someone forgot a colon after.
   --
   --  This is the other half of what Landin.Tokens.Construct does for the
   --  deferred signs, and it is derived rather than guessed: check.py
   --  holds every spelling here to a keyword the tour actually writes and
   --  every construct to a paragraph that actually exists.
   ------------------------------------------------------------------

   type Refused_Word is
     (Word_None,
      Word_Loop, Word_While, Word_For, Word_Match, Word_Defer,
      Word_Undo, Word_Try, Word_Fail, Word_Break, Word_Continue,
      Word_Distinct);

   subtype Real_Word is Refused_Word range Word_Loop .. Word_Distinct;

   function Spelling (Item : Real_Word) return String
     is (case Item is
            when Word_Loop     => "loop",
            when Word_While    => "while",
            when Word_For      => "for",
            when Word_Match    => "match",
            when Word_Defer    => "defer",
            when Word_Undo     => "undo",
            when Word_Try      => "try",
            when Word_Fail     => "fail",
            when Word_Break    => "break",
            when Word_Continue => "continue",
            when Word_Distinct => "distinct");

   function Refusal (Item : Real_Word) return Syn.Refused_Construct
     is (case Item is
            when Word_Loop     => Syn.Loop_Statement,
            when Word_While    => Syn.While_Statement,
            when Word_For      => Syn.For_Statement,
            when Word_Match    => Syn.Match_Statement,
            when Word_Defer    => Syn.Defer_Statement,
            when Word_Undo     => Syn.Undo_Statement,
            when Word_Try      => Syn.Try_Expression,
            when Word_Fail     => Syn.Fail_Statement,
            when Word_Break    => Syn.Break_Statement,
            when Word_Continue => Syn.Continue_Statement,
            when Word_Distinct => Syn.Distinct_Type);

   --  The kernel's types are the scalar names only [1790].  These are
   --  ordinary declared names the kernel predeclares, not keywords, which
   --  is why they are compared by interned identity rather than by kind.
   type Scalar_Name is
     (Type_U8, Type_U16, Type_U32, Type_U64,
      Type_I8, Type_I16, Type_I32, Type_I64,
      Type_Usize, Type_Isize, Type_Bool);

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
            when Type_Bool  => "bool");

   --  The three parameter conventions [0900].  A convention is written
   --  before the name, so `inout x: i32` is an identifier followed by an
   --  identifier, which `parameter ::= identifier ":" type` cannot derive.
   type Convention is (By_In, By_Inout, By_Sink);

   function Spelling (Item : Convention) return String
     is (case Item is
            when By_In    => "in",
            when By_Inout => "inout",
            when By_Sink  => "sink");

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

            Scalar_Id : constant array (Scalar_Name)
              of Landin.Source.Names.Name_Id :=
                [for S in Scalar_Name =>
                   Landin.Source.Names.Intern (Names, Spelling (S))];

            Convention_Id : constant array (Convention)
              of Landin.Source.Names.Name_Id :=
                [for C in Convention =>
                   Landin.Source.Names.Intern (Names, Spelling (C))];

            ------------------------------------------------------------
            --  Reading the stream
            ------------------------------------------------------------

            function Peek return Tok.Token_Kind;
            function Ahead (Distance : Tok.Token_Index)
              return Tok.Token_Kind;
            function After_Selectors return Tok.Token_Kind;
            function Here return Landin.Source.Span;
            function Point return Landin.Source.Span;
            function After_Previous return Landin.Source.Span;
            function Named_Here return Landin.Source.Names.Name_Id;
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
               Mutable   : Boolean := False) return Node_Id;

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
            function Parse_Program return Node_Id;
            function Parse_Declaration return Node_Id;
            function Parse_Type_Declaration
              (Exported  : Boolean;
               Public_At : Landin.Source.Span) return Node_Id;
            function Parse_Struct_Body
              (Named   : Landin.Source.Names.Name_Id;
               At_Name : Landin.Source.Span) return Node_Id;
            function Parse_Binding
              (Exported  : Boolean;
               Public_At : Landin.Source.Span) return Node_Id;
            function Parse_Function
              (Exported  : Boolean;
               Public_At : Landin.Source.Span) return Node_Id;
            function Parse_Parameter return Node_Id;
            function Parse_Returns
              (Declared_At : Landin.Source.Span;
               Returns_At  : out Landin.Source.Span) return Node_Id;
            function Parse_Type
              (In_Parameter : Boolean;
               Declared_At  : Landin.Source.Span) return Node_Id;
            function Parse_Declared_Name
              (Named : out Landin.Source.Names.Name_Id)
              return Landin.Source.Span;
            function Parse_Place return Node_Id;
            function Parse_Body (Context : Frame) return Node_Id;
            function Parse_Block
              (Context : Frame; Seed : Node_Id := No_Node) return Node_Id;
            function Parse_Statement (Context : Frame) return Node_Id;
            function Parse_If (Context : Frame) return Node_Id;
            function Parse_Expression
              (Min : Pre.Level := Pre.Level_Expression) return Node_Id;
            function Parse_Unary return Node_Id;
            function Parse_Primary return Node_Id;
            function Parse_Call
              (Name_At : Landin.Source.Span;
               Named   : Landin.Source.Names.Name_Id) return Node_Id;
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
               Mutable   : Boolean := False) return Node_Id
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
                   Mutable    => Mutable));

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
            --  program ::= declaration*                          [1740]
            ------------------------------------------------------------

            function Parse_Program return Node_Id is
               Items : Slot_Vectors.Vector;
            begin
               while Peek /= Tok.End_Of_Input loop
                  declare
                     Before : constant Tok.Token_Index := Index;
                  begin
                     if Peek not in Tok.Kernel_Kind
                       and then Ahead (1) not in Tok.Colon
                                  | Tok.Colon_Equal
                     then
                        --  Nothing begins here and the scanner already
                        --  said so, so this says nothing at all.
                        Mark_Reported;
                        Advance;
                     elsif Pre.Begins_Declaration (Peek)
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

            function Parse_Selectors (From : Node_Id) return Node_Id is
               Selected : Node_Id := From;

               --  [1820] spells `selection ("[" expression "]")*`, so the
               --  brackets come after the whole selection and nothing
               --  derives a dot after one.  Once a bracket has been read
               --  the dots are over, and saying so here is what keeps the
               --  parser and the grammar agreeing about legal source.
               Indexed : Boolean := False;
            begin
               --  [1820]'s order: the dots, then the brackets, and no
               --  dot after a bracket.  A call and a parenthesis are each
               --  their own production and neither reaches this loop, so
               --  what it reads is exactly what `indexed` derives.
               loop
                  --  indexed ::= selection ("[" expression "]")*  [1820]
                  if Peek = Tok.Left_Bracket then
                     declare
                        At_Open : constant Landin.Source.Span := Here;
                        Index   : Node_Id;
                     begin
                        Advance;
                        Index := Parse_Expression;

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
                     end;

                     Indexed := True;
                     goto Next;
                  end if;

                  exit when Peek /= Tok.Dot;

                  if Indexed then
                     Refuse
                       (Item    => Syn.Selection_From_An_Index,
                        Where   => Here,
                        Message => "selecting from an index is not"
                                   & " enabled yet");
                     Advance;

                     if Peek = Tok.Identifier then
                        Advance;
                     end if;

                     return Selected;
                  end if;

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

            --  type ::= the eleven scalar names                   [1790]
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

               --  [0670]'s inline form is also the parameter, return and
               --  payload list, so a `(` where a type belongs is a struct
               --  and is named as one.  [1795] made this reachable: the
               --  declaration around it is enabled now and its body is
               --  what is not.
               if Peek = Tok.Left_Paren then
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

               --  array_type ::= "[" integer "]" type            [1790]
               --
               --  The element is a type like any other, so this recurses
               --  and `[2][3]u8` derives; which elements the kernel can
               --  lay out is the checker's to say, not this stage's.
               if Peek = Tok.Left_Bracket then
                  --  [0570]'s slice is a view and not an array: it is
                  --  written with nothing between the brackets, so the
                  --  parser can tell the two apart and name this one
                  --  rather than reporting a length that is missing.
                  if Ahead (1) = Tok.Right_Bracket then
                     Type_Refused := True;
                     Refuse
                       (Item    => Syn.Slice_Type,
                        Where   => At_Type,
                        Message => "a slice is not enabled yet");
                     Advance;
                     Advance;
                     declare
                        Ignored : constant Node_Id :=
                          Parse_Type (In_Parameter, Declared_At);
                     begin
                        pragma Unreferenced (Ignored);
                     end;

                     return Add (Error_Type, At_Type);
                  end if;

                  declare
                     Bound   : Node_Id := No_Node;
                     Element : Node_Id := No_Node;
                  begin
                     Advance;

                     if Peek = Tok.Integer_Literal then
                        declare
                           Item : constant Tok.Token :=
                             Tok.Token_At (From, Index);
                        begin
                           Bound :=
                             Add (Integer_Literal, Here,
                                  Radix     => Tok.Base (Item),
                                  Digits_At => Tok.Digit_Span (Item));
                        end;

                        Advance;
                     else
                        Complain
                          (Item    => Syn.Type_Expected,
                           Where   => (if Peek = Tok.End_Of_Input
                                       then After_Previous else Here),
                           Message => "an array's length belongs here",
                           Note    => "[1790]: the bound is an integer"
                                      & " literal and the length is part"
                                      & " of the type [0520]",
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
                           return Add
                             (Type_Name, At_Type, Named => Spelled);
                        end if;
                     end loop;

                     --  [1795] lets a program declare a type, so a name
                     --  that is not one of the eleven is no longer wrong
                     --  here: whether it names one is resolution's to
                     --  answer, and this stage stops guessing.
                     Advance;
                     return Add
                       (Type_Reference, At_Type, Named => Spelled);
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
            begin
               --  The colon and the word are what brought us here.
               Advance;
               Advance;

               if Expect
                    (Wanted  => Tok.Equal,
                     Message => "a type declaration names a type after `=`",
                     Note    => "[1795]: name `:` `type` `=` type",
                     Related => At_Name,
                     Because => "declared here")
               then
                  --  [1795]: a name, or [0670]'s block form.
                  if Peek = Tok.Kw_Struct then
                     Aliased_Type := Parse_Struct_Body (Named, At_Name);
                  else
                     Aliased_Type := Parse_Type (False, At_Name);

                     if Type_Refused then
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
                  Children => [1 => Aliased_Type],
                  Named    => Named,
                  Exported => Exported);
            end Parse_Type_Declaration;

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
            begin
               Advance;

               while Peek = Tok.Identifier loop
                  declare
                     Field_Named : Landin.Source.Names.Name_Id;
                     At_Field    : constant Landin.Source.Span :=
                       Parse_Declared_Name (Field_Named);
                     Of_Type     : Node_Id := No_Node;
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
                        Of_Type := Parse_Type (False, At_Field);

                        if Type_Refused then
                           Resync_Declaration;
                           exit;
                        end if;
                     end if;

                     Fields.Append
                       (Add
                          (Of_Kind  => Field,
                           At_Token => At_Field,
                           Extent   => Join (At_Field, After_Previous),
                           Children => [1 => Of_Type],
                           Named    => Field_Named));
                  end;
               end loop;

               if Natural (Fields.Length) = 0 then
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

            ------------------------------------------------------------
            --  Functions                                        [1800]
            ------------------------------------------------------------

            --  parameter ::= identifier ":" type                  [1800]
            function Parse_Parameter return Node_Id is
               Start     : constant Landin.Source.Span := Here;
               Named     : Landin.Source.Names.Name_Id;
               At_Name   : Landin.Source.Span;
               Type_Node : Node_Id;
            begin
               --  [0900]: a convention is written before the name, so
               --  `inout x: i32` is two identifiers in a row, which
               --  `parameter ::= identifier ":" type` cannot derive.
               if Peek = Tok.Identifier
                 and then Ahead (1) = Tok.Identifier
               then
                  for Item in Convention loop
                     if Convention_Id (Item) = Named_Here then
                        Refuse
                          (Item    => Syn.Parameter_Convention,
                           Where   => Here,
                           Message => "`" & Spelling (Item)
                                      & "` is a parameter convention, and"
                                      & " the conventions are not enabled"
                                      & " yet");
                        Advance;
                        exit;
                     end if;
                  end loop;
               end if;

               At_Name := Parse_Declared_Name (Named);

               if Expect
                    (Wanted  => Tok.Colon,
                     Message => "a parameter names its type after `:`",
                     Note    => "[1800]: parameter ::= identifier `:` type",
                     Related => At_Name,
                     Because => "declared here")
               then
                  Type_Node := Parse_Type (True, At_Name);
               else
                  Type_Node := Add (Error_Type, After_Previous);
               end if;

               return Add
                 (Of_Kind  => Parameter,
                  At_Token => At_Name,
                  Extent   => Join (Start, After_Previous),
                  Children => [Type_Node],
                  Named    => Named);
            end Parse_Parameter;

            --  returns ::= "(" identifier ":" type ")" | "none"   [1800]
            --
            --  No_Node is `none`, which is [1800]'s reading: a function
            --  returning none has no return for an expression body to
            --  fill.  Returns_At is where a reader looks when `return`
            --  carries a value it may not.
            function Parse_Returns
              (Declared_At : Landin.Source.Span;
               Returns_At  : out Landin.Source.Span) return Node_Id
            is
               Start : constant Landin.Source.Span := Here;
            begin
               Returns_At := Start;

               if Peek = Tok.Kw_None then
                  Advance;
                  return No_Node;
               end if;

               if not Expect
                        (Wanted  => Tok.Left_Paren,
                         Message => "a return is named, or `none`",
                         Note    => "[1800]: returns ::= `(` identifier"
                                    & " `:` type `)` | `none`",
                         Related => Declared_At,
                         Because => "declared here")
               then
                  return No_Node;
               end if;

               declare
                  Named     : Landin.Source.Names.Name_Id;
                  At_Name   : constant Landin.Source.Span :=
                    Parse_Declared_Name (Named);
                  Type_Node : Node_Id;
               begin
                  if Expect
                       (Wanted  => Tok.Colon,
                        Message => "a named return names its type after"
                                   & " `:`",
                        Note    => "[1800]: returns ::= `(` identifier"
                                   & " `:` type `)` | `none`",
                        Related => At_Name,
                        Because => "the return")
                  then
                     Type_Node := Parse_Type (False, At_Name);
                  else
                     Type_Node := Add (Error_Type, After_Previous);
                  end if;

                  --  [0920]: multiple named returns are described in the
                  --  tour and this grammar takes one return or none.
                  if Peek = Tok.Comma then
                     Refuse
                       (Item    => Syn.Multiple_Returns,
                        Where   => Here,
                        Message => "a second named return belongs to"
                                   & " multiple returns");

                     while Peek = Tok.Comma loop
                        Advance;
                        Resync (List_Anchor);
                     end loop;
                  end if;

                  if not Expect
                           (Wanted  => Tok.Right_Paren,
                            Message => "a named return is closed with `)`",
                            Note    => "[1800]: returns ::= `(` identifier"
                                       & " `:` type `)` | `none`",
                            Related => At_Name,
                            Because => "the return")
                  then
                     Resync (List_Anchor);

                     if Peek = Tok.Right_Paren then
                        Advance;
                     end if;
                  end if;

                  Returns_At := Join (Start, After_Previous);

                  return Add
                    (Of_Kind  => Named_Return,
                     At_Token => At_Name,
                     Extent   => Returns_At,
                     Children => [Type_Node],
                     Named    => Named);
               end;
            end Parse_Returns;

            --  body ::= statement* | expression                   [1800]
            --
            --  One token past a leading name decides, and the one shape
            --  that needs more is `identifier "("`: a call is a statement
            --  as well as an expression [1810], so the token *after* the
            --  call decides which this one is -- and the node is the same
            --  either way, so nothing is re-parsed to find out.
            function Parse_Body (Context : Frame) return Node_Id is
            begin
               if Context.Returns then
                  --  [1800]'s expression body takes any expression, so
                  --  this asks the same question [1820]'s first set does
                  --  rather than keeping a second list beside it: a token
                  --  that begins an expression and is not a name begins
                  --  one here.  A name is the case below, where it may
                  --  instead begin a binding or an assignment.
                  if Pre.Begins_Expression (Peek)
                    and then Peek /= Tok.Identifier
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
               Public_At : Landin.Source.Span) return Node_Id
            is
               Start : constant Landin.Source.Span :=
                 (if Exported then Public_At else Here);
               Named        : Landin.Source.Names.Name_Id;
               At_Name      : Landin.Source.Span;
               Params       : Slot_Vectors.Vector;
               Returns_Node : Node_Id := No_Node;
               Returns_At   : Landin.Source.Span :=
                 Landin.Source.Empty_Span;
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
                           Params.Append (Parse_Parameter);
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

               Context :=
                 (Owner   => At_Name,
                  Result  => Returns_At,
                  Returns => Returns_Node /= No_Node);

               if Expect
                    (Wanted  => Tok.Equal,
                     Message => "a body opens with `=`",
                     Note    => "[1800]: `=` opens the body and `end`"
                                & " closes it",
                     Related => At_Name,
                     Because => "declared here")
               then
                  Body_Node := Parse_Body (Context);
               else
                  Body_Node := Add (Error_Statement, After_Previous);
               end if;

               if Peek = Tok.Kw_End then
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
                  Head : constant Slot_List (1 .. 2) :=
                    [Returns_Node, Body_Node];
               begin
                  return Add
                    (Of_Kind  => Function_Declaration,
                     At_Token => At_Name,
                     Extent   => Join (Start, After_Previous),
                     Children => Head & To_List (Params),
                     Named    => Named,
                     Exported => Exported);
               end;
            end Parse_Function;

            ------------------------------------------------------------
            --  Statements                                       [1810]
            ------------------------------------------------------------

            function Parse_Block
              (Context : Frame; Seed : Node_Id := No_Node) return Node_Id
            is
               Start : constant Landin.Source.Span := Point;
               Items : Slot_Vectors.Vector;
            begin
               if Seed /= No_Node then
                  Items.Append (Seed);
               end if;

               loop
                  exit when Peek in Tok.End_Of_Input | Tok.Kw_End
                                    | Tok.Kw_Elsif | Tok.Kw_Else;

                  declare
                     Before : constant Tok.Token_Index := Index;
                  begin
                     if Peek not in Tok.Kernel_Kind
                       and then Ahead (1) not in Tok.Colon
                                  | Tok.Colon_Equal | Tok.Equal
                     then
                        Mark_Reported;
                        Advance;
                     elsif Pre.Begins_Statement (Peek)
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
                                         & " call, a `return` or an `if`",
                              Gate    => False);
                        end;
                     end if;

                     if Index = Before then
                        raise Compiler_Defect
                          with "the parser did not advance over a"
                               & " statement";
                     end if;
                  end;
               end loop;

               return Add
                 (Of_Kind  => Block,
                  At_Token => Start,
                  Extent   => Join (Start, After_Previous),
                  Children => To_List (Items));
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

                  when Tok.Identifier =>
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

            --  if ::= "if" expression "then" statement*
            --         ("elsif" expression "then" statement*)*
            --         ("else" statement*)? "end" "if"             [1810]
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
                        Note    => "[1810]: if expression `then`"
                                   & " statement*",
                        Related => At_If,
                        Because => "this branch");
                     pragma Unreferenced (Kept);
                     Arm_Body := Parse_Block (Context);
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
                  Else_Node := Parse_Block (Context);
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

            ------------------------------------------------------------
            --  Expressions                                      [1820]
            ------------------------------------------------------------

            --  Ten binary levels, one loop.  Levels are declared loosest
            --  first, so "tighter" is "greater", and recursing at
            --  Level'Succ is what makes every level left associative.
            function Parse_Expression
              (Min : Pre.Level := Pre.Level_Expression) return Node_Id
            is
               Left    : Node_Id := Parse_Unary;
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
                        Right := Parse_Expression (Pre.Level'Succ (Rank));
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
            end Parse_Expression;

            --  unary ::= ("-" | "~" | "not")* primary             [1820]
            function Parse_Unary return Node_Id is
            begin
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

            --  primary ::= literal | identifier | call
            --            | "(" expression ")"                     [1820]
            function Parse_Primary return Node_Id is
               At_Item : constant Landin.Source.Span := Here;
            begin
               if Peek not in Tok.Kernel_Kind then
                  Mark_Reported;
                  Advance;
                  return Add (Error_Expression, At_Item);
               end if;

               --  [0520]'s literal is one or more expressions in source
               --  order.  Empty arrays remain outside this slice, as does
               --  [0560]'s contextual `of` repetition.
               if Peek = Tok.Left_Bracket then
                  declare
                     Items : Slot_Vectors.Vector;

                     procedure Skip_Remaining;

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
                  begin
                     if Too_Deep (At_Item) then
                        Resync_Brackets;
                        return Add (Error_Expression, At_Item);
                     end if;

                     Depth := Depth + 1;
                     Advance;

                     if Peek = Tok.Right_Bracket then
                        Complain
                          (Item    => Syn.Expression_Expected,
                           Where   => Here,
                           Message => "an array literal has at least one"
                                      & " element",
                           Note    => "[0520]: an array literal writes its"
                                      & " elements between the brackets");
                        Advance;
                        Depth := Depth - 1;
                        return Add
                          (Error_Expression, At_Item,
                           Join (At_Item, After_Previous));
                     end if;

                     loop
                        Items.Append (Parse_Expression);

                        if Peek = Tok.Identifier
                          and then Named_Here = Of_Id
                        then
                           Refuse
                             (Item    => Syn.Array_Repetition,
                              Where   => Here,
                              Message => "array repetition is not enabled"
                                         & " yet");
                           Skip_Remaining;
                           Depth := Depth - 1;
                           return Add
                             (Error_Expression, At_Item,
                              Join (At_Item, After_Previous),
                              To_List (Items));
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
                     Inner : constant Node_Id := Parse_Expression;
                     Kept  : Boolean;
                  begin
                     Depth := Depth - 1;
                     Kept := Expect
                       (Wanted  => Tok.Right_Paren,
                        Message => "a parenthesised expression is closed"
                                   & " with `)`",
                        Note    => "[1820]: primary ::= literal |"
                                   & " identifier | call | `(` expression"
                                   & " `)`",
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
                  if Word_At_Hand = Word_Try then
                     Refuse
                       (Item    => Syn.Try_Expression,
                        Where   => At_Item,
                        Message => "`try` is not enabled yet");
                     Advance;
                     return Add (Error_Expression, At_Item);
                  end if;

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

                     --  selection ::= identifier ("." identifier)*
                     return Parse_Selectors
                       (Add (Name_Reference, At_Item, Named => Named));
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

            --  call ::= identifier "(" arguments? ")"             [1820]
            --
            --  The callee is a Name_Reference and not a field, so every
            --  use of a name is one kind of node and R1.50 resolves by
            --  filtering one kind rather than walking seven positions.
            function Parse_Call
              (Name_At : Landin.Source.Span;
               Named   : Landin.Source.Names.Name_Id) return Node_Id
            is
               Callee : constant Node_Id :=
                 Add (Name_Reference, Name_At, Named => Named);
               Args   : Slot_Vectors.Vector;
            begin
               if not Expect
                        (Wanted  => Tok.Left_Paren,
                         Message => "a call opens its arguments with `(`",
                         Note    => "[1820]: call ::= identifier `(`"
                                    & " arguments? `)`",
                         Related => Name_At,
                         Because => "the name called")
               then
                  return Add
                    (Error_Expression, Name_At, Children => [Callee]);
               end if;

               if Peek /= Tok.Right_Paren then
                  loop
                     declare
                        Before : constant Tok.Token_Index := Index;
                     begin
                        Args.Append (Parse_Expression);
                        exit when Index = Before;
                     end;

                     exit when Peek /= Tok.Comma;
                     Advance;
                  end loop;
               end if;

               if not Expect
                        (Wanted  => Tok.Right_Paren,
                         Message => "a call's arguments are never closed",
                         Note    => "[1820]: call ::= identifier `(`"
                                    & " arguments? `)`",
                         Related => Name_At,
                         Because => "the name called")
               then
                  Resync (List_Anchor);

                  if Peek = Tok.Right_Paren then
                     Advance;
                  end if;
               end if;

               declare
                  Head : constant Slot_List (1 .. 1) := [Callee];
               begin
                  return Add
                    (Of_Kind  => Call,
                     At_Token => Name_At,
                     Extent   => Join (Name_At, After_Previous),
                     Children => Head & To_List (Args));
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
