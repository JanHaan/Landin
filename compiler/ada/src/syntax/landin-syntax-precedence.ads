--  [1820] as data.
--
--  The tour writes ten binary levels as ten productions of the same shape,
--  and the only thing that differs between them is the operator set and
--  whether the repetition is `*` or `?`.  Ten mutually recursive functions
--  would be ten paraphrases of one loop, and there would be nothing to
--  compare a paraphrase to.  This is a transcription instead, and
--  check.py's `check_precedence_table` holds it to the grammar it
--  transcribes: the same levels in the same order, the same operators at
--  each, the same fold, the same prefix set, the same first sets.
--
--  Three things follow from making it a table.  The expression parser is
--  one loop, so a level cannot fold the wrong way while its neighbour
--  folds correctly.  An expression nested `d` deep costs one frame per
--  actual nesting rather than eleven, which matters because `-fstack-check`
--  is on and from R3 the input is machine-generated code.  And inserting a
--  level is one enumeration literal and one arm, because every use site is
--  written against `Level'Succ` rather than against a level's number.
--
--  No body: every function here is an expression function, so there is
--  nothing between the grammar and the code for a body to hide.

with Landin.Tokens;

package Landin.Syntax.Precedence is

   --  One level per rule of [1820], loosest first, named after the rule it
   --  transcribes.  A level cannot be renamed here without renaming a
   --  production there, which is what the check compares.
   type Level is
     (Level_Expression,    --  expression  ::= logical_and ("or" ...)*
      Level_Logical_And,   --  logical_and ::= comparison ("and" ...)*
      Level_Comparison,    --  comparison  ::= alternation (( ... ))?
      Level_Alternation,   --  alternation ::= exclusion ("|" ...)*
      Level_Exclusion,     --  exclusion   ::= conjunction ("^" ...)*
      Level_Conjunction,   --  conjunction ::= shift ("&" ...)*
      Level_Shift,         --  shift       ::= sum (("<<"|">>") ...)*
      Level_Sum,           --  sum         ::= product ((...) ...)*
      Level_Product,       --  product     ::= unary ((...) ...)*
      Level_Unary,         --  unary       ::= ("-"|"~"|"not")* primary
      Level_Primary);      --  primary, which is not an operator level

   type Associativity is (Left, Non_Associative);

   --  A binary operator's level, or Level_Primary for a token that is not
   --  one.  The loop's stopping condition is "this is not an operator",
   --  and Level_Primary is that answer rather than a separate predicate.
   function Binary_Level (Of_Kind : Landin.Tokens.Token_Kind) return Level
     is (case Of_Kind is
            when Landin.Tokens.Kw_Or            => Level_Expression,
            when Landin.Tokens.Kw_And           => Level_Logical_And,
            when Landin.Tokens.Equal_Equal
               | Landin.Tokens.Less_Greater
               | Landin.Tokens.Less
               | Landin.Tokens.Less_Equal
               | Landin.Tokens.Greater
               | Landin.Tokens.Greater_Equal    => Level_Comparison,
            when Landin.Tokens.Bar              => Level_Alternation,
            when Landin.Tokens.Caret            => Level_Exclusion,
            when Landin.Tokens.Ampersand        => Level_Conjunction,
            when Landin.Tokens.Less_Less
               | Landin.Tokens.Greater_Greater  => Level_Shift,
            when Landin.Tokens.Plus
               | Landin.Tokens.Minus
               | Landin.Tokens.Plus_Percent
               | Landin.Tokens.Minus_Percent    => Level_Sum,
            when Landin.Tokens.Star
               | Landin.Tokens.Slash
               | Landin.Tokens.Percent
               | Landin.Tokens.Star_Percent     => Level_Product,
            when others                         => Level_Primary);

   function Is_Binary (Of_Kind : Landin.Tokens.Token_Kind) return Boolean
     is (Binary_Level (Of_Kind) /= Level_Primary);

   --  [1820]: "comparison takes at most one operator", written as `?`
   --  where every other level is written as `*`.  Non-associativity is a
   --  value here rather than a hand-written exception in the seventh of
   --  ten procedures.
   function Fold (Of_Level : Level) return Associativity
     is (case Of_Level is
            when Level_Comparison => Non_Associative,
            when others           => Left);

   function Is_Prefix (Of_Kind : Landin.Tokens.Token_Kind) return Boolean
     is (Of_Kind in Landin.Tokens.Minus | Landin.Tokens.Tilde
                    | Landin.Tokens.Kw_Not);

   --  The node a binary operator builds.  Separate from Binary_Level
   --  because two operators at one level are two different operations.
   function Binary_Node (Of_Kind : Landin.Tokens.Token_Kind)
     return Node_Kind
     is (case Of_Kind is
            when Landin.Tokens.Star            => Multiply,
            when Landin.Tokens.Slash           => Divide,
            when Landin.Tokens.Percent         => Remainder,
            when Landin.Tokens.Star_Percent    => Wrapping_Multiply,
            when Landin.Tokens.Plus            => Add,
            when Landin.Tokens.Minus           => Subtract,
            when Landin.Tokens.Plus_Percent    => Wrapping_Add,
            when Landin.Tokens.Minus_Percent   => Wrapping_Subtract,
            when Landin.Tokens.Less_Less       => Shift_Left,
            when Landin.Tokens.Greater_Greater => Shift_Right,
            when Landin.Tokens.Ampersand       => Bitwise_And,
            when Landin.Tokens.Caret           => Bitwise_Xor,
            when Landin.Tokens.Bar             => Bitwise_Or,
            when Landin.Tokens.Equal_Equal     => Equal_To,
            when Landin.Tokens.Less_Greater    => Not_Equal_To,
            when Landin.Tokens.Less            => Less_Than,
            when Landin.Tokens.Less_Equal      => Less_Or_Equal,
            when Landin.Tokens.Greater         => Greater_Than,
            when Landin.Tokens.Greater_Equal   => Greater_Or_Equal,
            when Landin.Tokens.Kw_And          => Logical_And,
            when Landin.Tokens.Kw_Or           => Logical_Or,
            when others                        => Error_Expression)
     with Pre => Is_Binary (Of_Kind);

   function Unary_Node (Of_Kind : Landin.Tokens.Token_Kind)
     return Node_Kind
     is (case Of_Kind is
            when Landin.Tokens.Minus  => Negation,
            when Landin.Tokens.Tilde  => Complement,
            when Landin.Tokens.Kw_Not => Logical_Not,
            when others               => Error_Expression)
     with Pre => Is_Prefix (Of_Kind);

   ------------------------------------------------------------------
   --  First sets
   --
   --  Read out of the grammar's own trees by check.py, not by eye: a token
   --  that begins an expression there and not here is a recovery bug that
   --  would be blamed on the parser.
   ------------------------------------------------------------------

   --  `primary ::= literal | array_literal | indexed | call | measurement
   --               | "(" expression ")"`, plus `unary`'s prefix operators.
   function Begins_Expression (Of_Kind : Landin.Tokens.Token_Kind)
     return Boolean
     is (Landin.Tokens.Is_Literal (Of_Kind)
         or else Of_Kind in Landin.Tokens.Identifier
                            | Landin.Tokens.Left_Paren
                            | Landin.Tokens.Left_Bracket
                            | Landin.Tokens.Kw_Sizeof
                            | Landin.Tokens.Kw_Alignof
         or else Is_Prefix (Of_Kind));

   --  `statement ::= binding | assignment | increment | discard | call
   --                 | return | if` [1810].
   function Begins_Statement (Of_Kind : Landin.Tokens.Token_Kind)
     return Boolean
     is (Of_Kind in Landin.Tokens.Kw_Mut | Landin.Tokens.Identifier
                    | Landin.Tokens.Kw_Inc | Landin.Tokens.Kw_Dec
                    | Landin.Tokens.Underscore | Landin.Tokens.Kw_Return
                    | Landin.Tokens.Kw_If);

   --  `declaration ::= "public"? (binding | function)` [1740].
   function Begins_Declaration (Of_Kind : Landin.Tokens.Token_Kind)
     return Boolean
     is (Of_Kind in Landin.Tokens.Kw_Public | Landin.Tokens.Kw_Mut
                    | Landin.Tokens.Identifier);

end Landin.Syntax.Precedence;
