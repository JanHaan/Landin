with Landin.Diagnostics.Lexical;
with Landin.Source.Names;
with Landin.Syntax;
with Landin.Syntax.Parser;
with Landin.Tokens;
with Landin.Tokens.Lexer;

package body Landin.Formatting is

   package Syn renames Landin.Syntax;
   package Tok renames Landin.Tokens;
   package US renames Ada.Strings.Unbounded;

   use type Landin.Source.Byte_Offset;
   use type Syn.Node_Id;
   use type Syn.Node_Kind;
   use type Tok.Space_Kind;
   use type Tok.Token_Kind;

   LF : constant Character := Character'Val (10);
   CR : constant Character := Character'Val (13);

   package Natural_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Natural);

   package Node_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Syn.Node_Id);

   --  One thing a line is made of: a token, or a comment, which is space
   --  to the language and never moves relative to the tokens around it.
   --  Gap is the space before it, back to the thing before it or the start
   --  of the file, and Breaks the line ends in that gap.
   type Thing is record
      Token  : Natural := 0;
      Where  : Landin.Source.Span;
      Gap    : Landin.Source.Span;
      Breaks : Natural := 0;
      Line   : Positive := 1;
   end record;

   package Thing_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Thing);

   --  The constructs whose `end`, and whose `else`, `elsif`, `complete`,
   --  `then` and `do` when one begins a line, stand where the construct
   --  began.  An if arm and a fixed arm answer for the conditional they
   --  belong to.
   function Is_Construct (Of_Kind : Syn.Node_Kind) return Boolean
     is (Of_Kind in Syn.Function_Declaration | Syn.Anonymous_Function
                  | Syn.If_Statement | Syn.If_Arm | Syn.Fixed_Conditional
                  | Syn.Fixed_Arm | Syn.While_Statement | Syn.For_Statement
                  | Syn.Loop_Statement | Syn.Match_Statement | Syn.Bare_Block
                  | Syn.Recovery_Clause | Syn.Struct_Body | Syn.Variant_Part
                  | Syn.Concept_Body);

   procedure Lay_Out
     (Bytes  : String;
      Id     : Landin.Source.Source_Id;
      Stream : Tok.Token_Stream;
      Tree   : Syn.Tree;
      Answer : in out Result);

   --  Whether Text scans to the same tokens and the same comments, in the
   --  same order, as Before did.
   function Same_Things
     (Before : Thing_Vectors.Vector;
      Bytes  : String;
      Text   : String) return Boolean;

   ---------------------------------------------------------------------
   --  Format
   ---------------------------------------------------------------------

   function Format
     (Sources : in out Landin.Source.Sets.Source_Set;
      Name    : String;
      Text    : String) return Result
   is
      Answer : Result;
      Names  : Landin.Source.Names.Table;
      Stream : Tok.Token_Stream;
      --  Offsets count from zero and a caller's string need not start at
      --  one, so the bytes are read through a copy that does.
      Bytes  : constant String (1 .. Text'Length) := Text;
   begin
      Answer.Id := Sources.Add (Name, Text);
      Answer.Text := US.To_Unbounded_String (Text);
      Tok.Lexer.Lex (Sources.Get (Answer.Id), Names, Stream);
      Landin.Diagnostics.Lexical.Report (Stream, Answer.Found);
      declare
         Tree : constant Syn.Tree :=
           Syn.Parser.Parse (Stream, Names, Answer.Found);
      begin
         if Answer.Found.Has_Errors then
            Answer.Found := Landin.Diagnostics.Sorted (Answer.Found);
            return Answer;
         end if;
         Lay_Out (Bytes, Answer.Id, Stream, Tree, Answer);
      end;
      return Answer;
   end Format;

   ---------------------------------------------------------------------
   --  The layout
   ---------------------------------------------------------------------

   procedure Lay_Out
     (Bytes  : String;
      Id     : Landin.Source.Source_Id;
      Stream : Tok.Token_Stream;
      Tree   : Syn.Tree;
      Answer : in out Result)
   is
      subtype Offset is Landin.Source.Byte_Offset;

      --  The stream's last token is End_Of_Input, which is no thing.
      Count : constant Natural := Natural (Tok.Count (Stream)) - 1;
      Last  : constant Syn.Node_Id := Syn.Last_Node (Tree);

      function Kind (T : Positive) return Tok.Token_Kind
        is (Tok.Kind (Stream, Tok.Token_Index (T)));

      function Start (T : Positive) return Offset
        is (Tok.Where (Stream, Tok.Token_Index (T)).First);

      function Slice (Where : Landin.Source.Span) return String
        is (Bytes (Natural (Where.First) + 1 .. Natural (Where.Last)));

      function Node_Kind (N : Syn.Node_Id) return Syn.Node_Kind
        is (Syn.Kind (Tree, N));

      Things : Thing_Vectors.Vector;
      Tail   : Landin.Source.Span;

      --  Per token.
      Thing_Of  : Natural_Vectors.Vector;
      Owner     : Node_Vectors.Vector;
      Starts    : Node_Vectors.Vector;
      Matching  : Natural_Vectors.Vector;
      Enclosing : Natural_Vectors.Vector;
      Column    : Natural_Vectors.Vector;

      --  Per node.
      Parent    : Node_Vectors.Vector;
      Container : Node_Vectors.Vector;
      First_Of  : Natural_Vectors.Vector;

      --  Per line.
      Head   : Natural_Vectors.Vector;
      Indent : Natural_Vectors.Vector;

      function Line_Of (T : Positive) return Positive
        is (Things (Thing_Of (T)).Line);

      function Line_Indent (T : Positive) return Natural
        is (Indent (Line_Of (T)));

      function Is_Head (T : Positive) return Boolean
        is (Head (Line_Of (T)) = T);

      function First (N : Syn.Node_Id) return Positive
        is (First_Of (Positive (N)));

      --  The first token at or after an offset, or Count + 1 when none is.
      --  Every node begins at a token, so for a node's extent this is its
      --  first token.
      function Token_At (Where : Offset) return Positive;

      function Token_At (Where : Offset) return Positive is
         Low  : Positive := 1;
         High : Natural := Count;
      begin
         while Low <= High loop
            declare
               Middle : constant Positive := (Low + High) / 2;
            begin
               if Start (Middle) < Where then
                  Low := Middle + 1;
               else
                  High := Middle - 1;
               end if;
            end;
         end loop;
         return Low;
      end Token_At;

      --  A struct body written `struct ... end` holds its fields one per
      --  line; one written `( ... )` is a list, laid out as one.
      function Is_Block_Struct (N : Syn.Node_Id) return Boolean
        is (Kind (Token_At (Syn.Where (Tree, N).Last) - 1) /= Tok.Right_Paren);

      ------------------------------------------------------------------
      --  The things, the lines and the facts every rule reads
      ------------------------------------------------------------------

      procedure Gather;

      procedure Gather is
         Gap_First : Offset := 0;
         Breaks    : Natural := 0;
         Line      : Positive := 1;

         procedure Add (Token : Natural; Where : Landin.Source.Span);

         procedure Add (Token : Natural; Where : Landin.Source.Span) is
         begin
            if not Things.Is_Empty and then Breaks > 0 then
               Line := Line + 1;
            end if;
            Things.Append
              (Thing'(Token  => Token,
                      Where  => Where,
                      Gap    => (First => Gap_First, Last => Where.First),
                      Breaks => Breaks,
                      Line   => Line));
            Gap_First := Where.Last;
            Breaks := 0;
         end Add;
      begin
         for Index in 1 .. Count + 1 loop
            declare
               Leading : constant Tok.Space_Range :=
                 Tok.Leading (Stream, Tok.Token_Index (Index));
            begin
               for Piece in Leading.First .. Leading.Last loop
                  declare
                     Item : constant Tok.Space :=
                       Tok.Nth_Space (Stream, Piece);
                  begin
                     case Tok.Kind (Item) is
                        when Tok.Blanks =>
                           null;
                        when Tok.Line_End =>
                           Breaks := Breaks + 1;
                        when Tok.Line_Comment | Tok.Doc_Comment
                           | Tok.Block_Comment =>
                           Add (0, Tok.Where (Item));
                     end case;
                  end;
               end loop;
            end;
            if Index <= Count then
               Add (Index, Tok.Where (Stream, Tok.Token_Index (Index)));
               Thing_Of.Append (Natural (Things.Length));
            end if;
         end loop;
         Tail := (First => Gap_First, Last => Bytes'Length);

         Head.Append (0, Count => Ada.Containers.Count_Type (Line));
         Indent.Append (0, Count => Ada.Containers.Count_Type (Line));
         for Each of Things loop
            if Each.Token /= 0 and then Head (Each.Line) = 0 then
               Head (Each.Line) := Each.Token;
            end if;
         end loop;
      end Gather;

      procedure Relate;

      procedure Relate is
         Nodes : constant Natural := Natural (Last);
         Open  : Natural_Vectors.Vector;
      begin
         Parent.Append (Syn.No_Node, Ada.Containers.Count_Type (Nodes));
         Container.Append (Syn.No_Node, Ada.Containers.Count_Type (Nodes));
         First_Of.Append (1, Ada.Containers.Count_Type (Nodes));

         --  A recovery clause is carried beside its call's slots, and is
         --  the call's all the same.
         for N in 1 .. Last loop
            First_Of (Positive (N)) := Positive'Min
              (Token_At (Syn.Where (Tree, N).First), Positive'Max (Count, 1));
            for Position in 1 .. Syn.Slot_Count (Tree, N) loop
               declare
                  Child : constant Syn.Node_Id := Syn.Slot (Tree, N, Position);
               begin
                  if Child /= Syn.No_Node then
                     Parent (Positive (Child)) := N;
                  end if;
               end;
            end loop;
            if Node_Kind (N) in Syn.Call | Syn.Labeled_Application
              and then Syn.Recovery_Of (Tree, N) /= Syn.No_Node
            then
               Parent (Positive (Syn.Recovery_Of (Tree, N))) := N;
            end if;
         end loop;

         --  Which node holds each token: the innermost whose extent
         --  contains it.  The nodes in the order their extents open, the
         --  outer of two equal extents first, swept beside the tokens.
         declare
            function Before (Left, Right : Syn.Node_Id) return Boolean;

            function Before (Left, Right : Syn.Node_Id) return Boolean is
               L : constant Landin.Source.Span := Syn.Where (Tree, Left);
               R : constant Landin.Source.Span := Syn.Where (Tree, Right);
            begin
               return L.First < R.First
                 or else (L.First = R.First
                          and then (L.Last > R.Last
                                    or else (L.Last = R.Last
                                             and then Left > Right)));
            end Before;

            package Sorting is new Node_Vectors.Generic_Sorting (Before);

            Order : Node_Vectors.Vector;
            Stack : Node_Vectors.Vector;
            Next  : Positive := 1;
         begin
            for N in 1 .. Last loop
               if Landin.Source.Length (Syn.Where (Tree, N)) > 0 then
                  Order.Append (N);
               end if;
            end loop;
            Sorting.Sort (Order);

            for T in 1 .. Count loop
               while Next <= Natural (Order.Length)
                 and then Syn.Where (Tree, Order (Next)).First <= Start (T)
               loop
                  while not Stack.Is_Empty
                    and then Syn.Where (Tree, Stack.Last_Element).Last
                             <= Syn.Where (Tree, Order (Next)).First
                  loop
                     Stack.Delete_Last;
                  end loop;
                  Stack.Append (Order (Next));
                  Next := Next + 1;
               end loop;
               while not Stack.Is_Empty
                 and then Syn.Where (Tree, Stack.Last_Element).Last
                          <= Start (T)
               loop
                  Stack.Delete_Last;
               end loop;
               Owner.Append
                 (if Stack.Is_Empty then Syn.Root (Tree)
                  else Stack.Last_Element);
            end loop;
         end;

         --  What begins a line of a list: a declaration, a statement, a
         --  field, a variant case, a concept entry, a match arm.  Outer
         --  lists first, so a token that begins two items belongs to the
         --  one a reader sees begin there.
         Starts.Append (Syn.No_Node, Ada.Containers.Count_Type (Count));
         for N in reverse 1 .. Last loop
            declare
               Of_Kind : constant Syn.Node_Kind := Node_Kind (N);
            begin
               if Of_Kind in Syn.Program | Syn.Block | Syn.Variant_Part
                    | Syn.Concept_Body | Syn.Match_Statement | Syn.Fixed_Arm
                 or else (Of_Kind = Syn.Struct_Body
                          and then Is_Block_Struct (N))
               then
                  for Position in 1 .. Syn.Slot_Count (Tree, N) loop
                     declare
                        Child : constant Syn.Node_Id :=
                          Syn.Slot (Tree, N, Position);
                     begin
                        if Child /= Syn.No_Node
                          and then Landin.Source.Length
                                     (Syn.Where (Tree, Child)) > 0
                          and then
                            (case Of_Kind is
                               when Syn.Concept_Body =>
                                 Node_Kind (Child) = Syn.Concept_Entry,
                               when Syn.Match_Statement =>
                                 Node_Kind (Child) = Syn.Match_Arm,
                               when Syn.Fixed_Arm => Position > 1,
                               when others => True)
                        then
                           Container (Positive (Child)) := N;
                           if Starts (First (Child)) = Syn.No_Node then
                              Starts (First (Child)) := Child;
                           end if;
                        end if;
                     end;
                  end loop;
               end if;
            end;
         end loop;

         --  Brackets, matched, and the one each token is inside.
         Matching.Append (0, Ada.Containers.Count_Type (Count));
         for T in 1 .. Count loop
            Enclosing.Append
              (if Open.Is_Empty then 0 else Open.Last_Element);
            if Kind (T) in Tok.Left_Paren | Tok.Left_Bracket then
               Open.Append (T);
            elsif Kind (T) in Tok.Right_Paren | Tok.Right_Bracket
              and then not Open.Is_Empty
            then
               Matching (T) := Open.Last_Element;
               Matching (Open.Last_Element) := T;
               Open.Delete_Last;
            end if;
         end loop;
      end Relate;

      ------------------------------------------------------------------
      --  Space inside a line
      ------------------------------------------------------------------

      --  A sign that stands before its operand rather than between two.
      function Is_Prefix (T : Positive) return Boolean
        is (Kind (T) in Tok.Minus | Tok.Tilde
            and then Node_Kind (Owner (T)) in Syn.Negation | Syn.Complement
            and then Syn.Anchor (Tree, Owner (T)).First = Start (T));

      --  `link` and `layout` are names the grammar spells as words in
      --  front of a declaration or a struct body, and write their
      --  attributes as a call does.
      function Is_Attribute (T : Positive) return Boolean
        is (Node_Kind (Owner (T)) not in Syn.Name_Reference
                                        | Syn.Type_Reference
            and then Slice (Tok.Where (Stream, Tok.Token_Index (T)))
                     in "link" | "layout");

      --  Whether the tokens From .. To are only what may stand in front of
      --  a declaration: `public`, a `link (...)` and an `extern (...)`.
      function Is_Prefix_Run (From, To : Positive) return Boolean;

      function Is_Prefix_Run (From, To : Positive) return Boolean is
         T : Positive := From;
      begin
         while T <= To loop
            if Kind (T) = Tok.Kw_Public then
               T := T + 1;
            elsif ((Kind (T) = Tok.Identifier and then Is_Attribute (T))
                   or else Kind (T) = Tok.Kw_Extern)
              and then T < To and then Kind (T + 1) = Tok.Left_Paren
              and then Matching (T + 1) /= 0
            then
               T := Matching (T + 1) + 1;
            else
               return False;
            end if;
         end loop;
         return T = To + 1;
      end Is_Prefix_Run;

      --  A match arm's block begins where the arm does, so its pattern's
      --  tokens are the block's; they are the arm's to a reader.
      function Arm_Or_Owner (T : Positive) return Syn.Node_Id
        is (if Node_Kind (Owner (T)) = Syn.Block
              and then Parent (Positive (Owner (T))) /= Syn.No_Node
              and then Node_Kind (Parent (Positive (Owner (T))))
                         = Syn.Match_Arm
            then Parent (Positive (Owner (T))) else Owner (T));

      --  How many blanks separate two neighbouring tokens on one line.
      function Blanks (Left, Right : Positive) return Natural;

      function Blanks (Left, Right : Positive) return Natural is
         L : constant Tok.Token_Kind := Kind (Left);
         R : constant Tok.Token_Kind := Kind (Right);
      begin
         if R in Tok.Right_Paren | Tok.Right_Bracket | Tok.Comma | Tok.Colon
                | Tok.Dot
           or else L in Tok.Left_Paren | Tok.Left_Bracket | Tok.Dot
           or else L in Tok.Dot_Dot | Tok.Dot_Dot_Less
           or else R in Tok.Dot_Dot | Tok.Dot_Dot_Less
         then
            return 0;

         --  `- -x` keeps its blank: `--` would open a comment.
         elsif Is_Prefix (Left) then
            return (if Bytes (Natural (Start (Right)) + 1) = '-' then 1
                    else 0);

         --  An import path is one name with `/` inside it.
         elsif L = Tok.Slash or else R = Tok.Slash then
            return
              (if Node_Kind (Owner (if L = Tok.Slash then Left else Right))
                    = Syn.Import_Declaration
               then 0 else 1);

         --  `[4]u8` and `[]mut u8`: the brackets and what they hold.
         elsif L = Tok.Right_Bracket
           and then Node_Kind (Owner (Left)) in Syn.Array_Type
                                               | Syn.Slice_Type
         then
            return 0;

         --  A call, an application, a conversion, a convention and a
         --  variant's pattern touch their parenthesis.  Type and concept
         --  formals, a conformance's entries, a pointer arm's binding and
         --  a parenthesized operand stand apart from what precedes them.
         elsif R = Tok.Left_Paren then
            if L in Tok.Identifier | Tok.Right_Paren | Tok.Right_Bracket
              | Tok.Kw_None
              and then Node_Kind (Arm_Or_Owner (Right))
                         in Syn.Call | Syn.Labeled_Application
                          | Syn.Type_Application | Syn.Tool_Directive
                          | Syn.Match_Arm | Syn.Function_Declaration
                          | Syn.Binding | Syn.Struct_Body
            then
               return 0;
            elsif (L = Tok.Identifier and then Is_Attribute (Left))
              or else (L = Tok.Kw_Ptr
                       and then Node_Kind (Owner (Right))
                                  = Syn.Pointer_Conversion)
              or else (L = Tok.Kw_Any
                       and then Node_Kind (Owner (Right))
                                  = Syn.Any_Construction)
              or else L = Tok.Kw_Extern
            then
               return 0;
            end if;
            return 1;

         --  An index or a slice touches what it selects from.
         elsif R = Tok.Left_Bracket then
            return
              (if Node_Kind (Owner (Right))
                    in Syn.Element_Index | Syn.Inclusive_Slice
                     | Syn.Half_Open_Slice
                 and then Syn.Anchor (Tree, Owner (Right)).First
                          = Start (Right)
               then 0 else 1);
         end if;
         return 1;
      end Blanks;

      ------------------------------------------------------------------
      --  Indentation
      ------------------------------------------------------------------

      --  An `if` written mid-line with its first arm's value on the same
      --  line is a table: its `elsif`, `else` and `end if` stand under it.
      function Is_Table (C : Syn.Node_Id) return Boolean;

      function Is_Table (C : Syn.Node_Id) return Boolean is
         Opening : constant Positive := First (C);
         Arm     : constant Syn.Node_Id := Syn.Nth_Arm (Tree, C, 1);
         Body_Of : constant Syn.Node_Id := Syn.Body_Of (Tree, Arm);
      begin
         if Is_Head (Opening) then
            return False;
         end if;
         for Position in 1 .. Syn.Slot_Count (Tree, Body_Of) loop
            if Syn.Slot (Tree, Body_Of, Position) /= Syn.No_Node then
               return Line_Of (First (Body_Of)) = Line_Of (Opening)
                 and then First (Body_Of) > Opening;
            end if;
         end loop;
         return False;
      end Is_Table;

      --  Where a construct's body is indented from, and where its `end`
      --  stands: the line it begins on.  A recovery clause begins where
      --  its call does, and a table where its `if` is.
      function Base (C : Syn.Node_Id) return Integer;

      function Base (C : Syn.Node_Id) return Integer is
      begin
         if C = Syn.No_Node then
            return 0;
         end if;
         case Node_Kind (C) is
            when Syn.Program =>
               return -4;
            when Syn.If_Arm | Syn.Fixed_Arm =>
               return Base (Parent (Positive (C)));
            when Syn.Recovery_Clause =>
               return (if Parent (Positive (C)) = Syn.No_Node then 0
                       else Line_Indent (First (Parent (Positive (C)))));
            when Syn.If_Statement =>
               return (if Is_Table (C) then Column (First (C))
                       else Line_Indent (First (C)));
            when others =>
               return Line_Indent (First (C));
         end case;
      end Base;

      --  The binary operation a line beginning with H continues: H is its
      --  operator, or the first token of its right operand, and its left
      --  operand began before H.  No_Node when H continues none.
      function Continued (H : Positive) return Syn.Node_Id;

      function Continued (H : Positive) return Syn.Node_Id is
         Walk : Syn.Node_Id := Owner (H);
      begin
         while Walk /= Syn.No_Node loop
            if Node_Kind (Walk) in Syn.Binary_Kind and then First (Walk) < H
            then
               return
                 (if Syn.Anchor (Tree, Walk).First = Start (H)
                    or else First (Syn.Right_Of (Tree, Walk)) = H
                  then Walk else Syn.No_Node);
            elsif First (Walk) < H then
               return Syn.No_Node;
            end if;
            Walk := Parent (Positive (Walk));
         end loop;
         return Syn.No_Node;
      end Continued;

      --  Where the line beginning with token H stands, and whether H
      --  closes a construct (which a comment above it is inside).
      function Rule (H : Positive; Closing : out Boolean) return Integer;

      function Rule (H : Positive; Closing : out Boolean) return Integer is
         Held : constant Syn.Node_Id := Owner (H);
      begin
         Closing := False;

         --  The first token of a declaration, statement, field, case,
         --  entry or arm: one step inside the construct that holds it.
         if Starts (H) /= Syn.No_Node then
            declare
               Holder : constant Syn.Node_Id :=
                 Container (Positive (Starts (H)));
            begin
               return (if Node_Kind (Holder) = Syn.Block
                       then Base (Parent (Positive (Holder)))
                       else Base (Holder)) + 4;
            end;
         end if;

         --  What closes or divides a construct stands where it began.
         if Kind (H) in Tok.Kw_End | Tok.Kw_Else | Tok.Kw_Elsif
                      | Tok.Kw_Complete | Tok.Kw_Then | Tok.Kw_Do
           and then Is_Construct (Node_Kind (Held))
           and then not (Node_Kind (Held) = Syn.Recovery_Clause
                         and then First (Held) = H)
         then
            Closing := Kind (H) not in Tok.Kw_Then | Tok.Kw_Do;
            return Base (Held);
         end if;

         --  A signature's `->` and `!` stand under its parameter list's
         --  `(`, and each further `|` of an error set under the `!`.
         if Kind (H) = Tok.Minus_Greater and then H > 1
           and then Kind (H - 1) = Tok.Right_Paren
           and then Matching (H - 1) /= 0
         then
            return Column (Matching (H - 1));
         end if;
         if Kind (H) = Tok.Bang and then H > 2 then
            declare
               Arrow : constant Natural :=
                 (if Kind (H - 1) = Tok.Right_Paren
                    and then Matching (H - 1) > 1
                  then Matching (H - 1) - 1 else H - 2);
            begin
               if Arrow > 1 and then Kind (Arrow) = Tok.Minus_Greater
                 and then Kind (Arrow - 1) = Tok.Right_Paren
                 and then Matching (Arrow - 1) /= 0
               then
                  return Column (Matching (Arrow - 1));
               end if;
            end;
         end if;
         if Kind (H) = Tok.Bar
           and then Node_Kind (Held) = Syn.Atom_Union_Type
           and then Kind (First (Held)) = Tok.Bang
         then
            return Column (First (Held));
         end if;

         --  A line that continues an operation, with its operator or with
         --  the operand after one, stands under the operation's left
         --  operand; in a condition, two steps in from the line the
         --  condition is on.
         declare
            Operation : constant Syn.Node_Id := Continued (H);
         begin
            if Operation /= Syn.No_Node then
               declare
                  Left : constant Positive := First (Operation);
               begin
                  if Left > 1
                    and then Kind (Left - 1) in Tok.Kw_If | Tok.Kw_Elsif
                                             | Tok.Kw_While | Tok.Kw_When
                  then
                     return Line_Indent (Left) + 2;
                  end if;
                  return Column (Left);
               end;
            end if;
         end;

         --  Inside a list: under its first entry when that shares the
         --  bracket's line, one step in when the list hangs.  A closing
         --  bracket stands where its line began.  Parentheses that only
         --  group are not a list.
         if Enclosing (H) /= 0 then
            declare
               Opening : constant Positive := Enclosing (H);
               Before  : constant Tok.Token_Kind :=
                 (if Opening > 1 then Kind (Opening - 1) else Tok.Comma);
               Groups  : constant Boolean :=
                 Kind (Opening) = Tok.Left_Paren
                 and then Syn.Where (Tree, Owner (Opening)).First
                          /= Start (Opening)
                 and then Before not in Tok.Identifier | Tok.Right_Paren
                                     | Tok.Right_Bracket | Tok.Colon
                                     | Tok.Kw_Ptr | Tok.Kw_Any
                                     | Tok.Kw_Extern | Tok.Kw_Type
                                     | Tok.Kw_Else;
            begin
               if Kind (H) in Tok.Right_Paren | Tok.Right_Bracket then
                  return Line_Indent (Opening);
               elsif not Groups then
                  return
                    (if Line_Of (Opening + 1) = Line_Of (Opening)
                     then Column (Opening) + 1
                     else Line_Indent (Opening) + 4);
               end if;
            end;
         end if;

         --  Anything else continues the declaration or statement it is
         --  part of, one step in from the line that began it.
         declare
            Walk : Syn.Node_Id := Held;
         begin
            while Walk /= Syn.No_Node
              and then Container (Positive (Walk)) = Syn.No_Node
            loop
               Walk := Parent (Positive (Walk));
            end loop;
            if Walk = Syn.No_Node then
               return 4;
            end if;
            --  A declaration written below its own attributes begins
            --  where they do.
            return Line_Indent (First (Walk))
              + (if Is_Prefix_Run (First (Walk), H - 1) then 0 else 4);
         end;
      end Rule;

      procedure Indent_Lines;

      procedure Indent_Lines is
         Pending : Natural_Vectors.Vector;
         Cursor  : Positive := 1;
      begin
         for Line in 1 .. Natural (Head.Length) loop
            --  The line's things, from Cursor.
            declare
               First_Thing : constant Positive := Cursor;
            begin
               while Cursor <= Natural (Things.Length)
                 and then Things (Cursor).Line = Line
               loop
                  Cursor := Cursor + 1;
               end loop;

               if Head (Line) = 0 then
                  Pending.Append (Line);
               else
                  declare
                     Closing : Boolean;
                     Where   : constant Integer :=
                       Rule (Head (Line), Closing);
                     At_Column : Natural;
                  begin
                     Indent (Line) := Natural'Max (Where, 0);
                     for Each of Pending loop
                        Indent (Each) :=
                          Indent (Line) + (if Closing then 4 else 0);
                     end loop;
                     Pending.Clear;

                     --  Where each token of the line will stand.
                     At_Column := Indent (Line);
                     for K in First_Thing .. Cursor - 1 loop
                        declare
                           Item : constant Thing := Things (K);
                           Text : constant String := Slice (Item.Where);
                        begin
                           if K > First_Thing then
                              At_Column := At_Column
                                + (if Item.Token /= 0
                                     and then Things (K - 1).Token /= 0
                                   then Blanks (Things (K - 1).Token,
                                                Item.Token)
                                   else 1);
                           end if;
                           if Item.Token /= 0 then
                              Column (Item.Token) := At_Column;
                           end if;
                           At_Column := At_Column + Text'Length;
                           for At_Byte in reverse Text'Range loop
                              if Text (At_Byte) in LF | CR then
                                 At_Column := Text'Last - At_Byte;
                                 exit;
                              end if;
                           end loop;
                        end;
                     end loop;
                  end;
               end if;
            end;
         end loop;
         --  Comments after the last token stand at the margin.
         for Each of Pending loop
            Indent (Each) := 0;
         end loop;
      end Indent_Lines;

      ------------------------------------------------------------------
      --  The edits
      ------------------------------------------------------------------

      Output : US.Unbounded_String;

      procedure Replace (Gap : Landin.Source.Span; Text : String);

      procedure Replace (Gap : Landin.Source.Span; Text : String) is
      begin
         if Slice (Gap) /= Text then
            Answer.Edits.Append (Landin.Diagnostics.Make_Edit (Id, Gap, Text));
         end if;
         US.Append (Output, Text);
      end Replace;

   begin
      Gather;
      Relate;
      Column.Append (0, Ada.Containers.Count_Type (Count));
      Indent_Lines;

      for K in 1 .. Natural (Things.Length) loop
         declare
            Item   : constant Thing := Things (K);
            Margin : constant String (1 .. Indent (Item.Line)) :=
              [others => ' '];
         begin
            if K = 1 then
               Replace (Item.Gap, Margin);
            elsif Item.Breaks > 0 then
               Replace
                 (Item.Gap,
                  (if Item.Breaks > 1 then LF & LF else [LF]) & Margin);
            elsif Item.Token /= 0 and then Things (K - 1).Token /= 0 then
               Replace
                 (Item.Gap,
                  [1 .. Blanks (Things (K - 1).Token, Item.Token) => ' ']);
            else
               Replace (Item.Gap, " ");
            end if;
            US.Append (Output, Slice (Item.Where));
         end;
      end loop;
      Replace (Tail, (if Things.Is_Empty then "" else [LF]));

      --  Identical bytes have the same tokens and comments as the input
      --  already scanned by Format.  Changed output still needs a scan.
      if US.To_String (Output) /= Bytes
        and then not Same_Things (Things, Bytes, US.To_String (Output))
      then
         raise Landin.Compiler_Defect
           with "formatting changed a token or a comment";
      end if;
      Answer.Outcome := Formatted;
      Answer.Text := Output;
   end Lay_Out;

   ---------------------------------------------------------------------
   --  The check
   ---------------------------------------------------------------------

   function Same_Things
     (Before : Thing_Vectors.Vector;
      Bytes  : String;
      Text   : String) return Boolean
   is
      Sources : Landin.Source.Sets.Source_Set;
      Names   : Landin.Source.Names.Table;
      Stream  : Tok.Token_Stream;
      Again   : constant String (1 .. Text'Length) := Text;
      Next    : Positive := 1;

      function Matches (Where : Landin.Source.Span) return Boolean;

      --  The next thing before, spelled the same as Where is now.
      function Matches (Where : Landin.Source.Span) return Boolean is
      begin
         if Next > Natural (Before.Length) then
            return False;
         end if;
         declare
            Was : constant Landin.Source.Span := Before (Next).Where;
         begin
            Next := Next + 1;
            return Bytes (Natural (Was.First) + 1 .. Natural (Was.Last))
              = Again (Natural (Where.First) + 1 .. Natural (Where.Last));
         end;
      end Matches;
   begin
      Tok.Lexer.Lex
        (Sources.Get (Sources.Add ("formatted", Text)), Names, Stream);
      if Tok.Fault_Count (Stream) > 0 then
         return False;
      end if;
      for Index in 1 .. Tok.Count (Stream) loop
         declare
            Leading : constant Tok.Space_Range := Tok.Leading (Stream, Index);
         begin
            for Piece in Leading.First .. Leading.Last loop
               declare
                  Item : constant Tok.Space := Tok.Nth_Space (Stream, Piece);
               begin
                  if Tok.Kind (Item) not in Tok.Blanks | Tok.Line_End
                    and then (not Matches (Tok.Where (Item))
                              or else Before (Next - 1).Token /= 0)
                  then
                     return False;
                  end if;
               end;
            end loop;
            if Tok.Kind (Stream, Index) /= Tok.End_Of_Input
              and then (not Matches (Tok.Where (Stream, Index))
                        or else Before (Next - 1).Token = 0)
            then
               return False;
            end if;
         end;
      end loop;
      return Next = Natural (Before.Length) + 1;
   end Same_Things;

end Landin.Formatting;
