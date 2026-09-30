--  The scanner, and the agreement it has to keep.
--
--  The last case reads compiler/tests/lexical.tokens, which check.py wrote
--  from its own tokeniser, and lexes every file it names.  Two
--  implementations of one grammar, compared token for token: a boundary
--  either side gets wrong shows up here, and check.py's own run says which
--  side moved by refusing a stale dump.

with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Landin.Diagnostics.Lexical;
with Landin.Diagnostics;
with Landin.Platform.Native;
with Landin.Source.Names;
with Landin.Source.Sets;
with Landin.Source;
with Landin.Stages.Syntax;
with Landin.Stages;
with Landin.Targets;
with Landin.Testing.Layout;
with Landin.Tokens.Spacing;
with Landin.Tokens.Lexer;
with Landin.Tokens.Text;
with Landin.Tokens;

package body Landin.Tests.Lexer_Suite is

   package Unbounded renames Ada.Strings.Unbounded;

   use type Landin.Platform.List_Status;
   use type Landin.Platform.Read_Status;
   use type Landin.Source.Byte_Offset;
   use type Landin.Tokens.Token_Kind;
   use type Landin.Tokens.Integer_Base;
   use type Landin.Tokens.Token_Index;
   use type Landin.Tokens.Fault_Kind;
   use type Landin.Tokens.Space;
   use type Landin.Tokens.Space_Kind;
   use type Landin.Tokens.Text.Code_Unit;
   use type Landin.Tokens.Text.Problem;

   LF : constant Character := Character'Val (10);

   --  Relative to compiler/ada, which is where the harness runs.
   Corpus : constant String := "../tests";

   Frontend : aliased Landin.Stages.Syntax.Instance;

   ------------------------------------------------------------------
   --  Lexing a string, without a filesystem
   ------------------------------------------------------------------

   procedure Lex_Text
     (Text    : String;
      Sources : in out Landin.Source.Sets.Source_Set;
      Names   : in out Landin.Source.Names.Table;
      Stream  : out Landin.Tokens.Token_Stream);

   procedure Lex_Text
     (Text    : String;
      Sources : in out Landin.Source.Sets.Source_Set;
      Names   : in out Landin.Source.Names.Table;
      Stream  : out Landin.Tokens.Token_Stream)
   is
      Id : constant Landin.Source.Source_Id :=
        Sources.Add ("probe.ldn", Text);
   begin
      Landin.Tokens.Lexer.Lex (Sources.Get (Id), Names, Stream);
   end Lex_Text;

   procedure Kinds_And_Spans (Item : in out Landin.Testing.Context);

   procedure Kinds_And_Spans (Item : in out Landin.Testing.Context) is
      Sources : Landin.Source.Sets.Source_Set;
      Names   : Landin.Source.Names.Table;
      Stream  : Landin.Tokens.Token_Stream;
   begin
      Lex_Text ("mut count: u32 = 0", Sources, Names, Stream);

      Landin.Testing.Check_Equal
        (Item, Natural (Landin.Tokens.Count (Stream)), 7,
         "six tokens and the end of input");
      Landin.Testing.Check
        (Item, Landin.Tokens.Kind (Stream, 1) = Landin.Tokens.Kw_Mut,
         "a reserved word is not an identifier");
      Landin.Testing.Check
        (Item, Landin.Tokens.Kind (Stream, 2) = Landin.Tokens.Identifier,
         "a name is a name");
      Landin.Testing.Check
        (Item, Landin.Tokens.Kind (Stream, 6)
               = Landin.Tokens.Integer_Literal,
         "a digit run is an integer");
      Landin.Testing.Check
        (Item, Landin.Tokens.Kind (Stream, 7)
               = Landin.Tokens.End_Of_Input,
         "the stream ends with the end of input");
      Landin.Testing.Check
        (Item, Landin.Tokens.Where (Stream, 2).First = 4
               and then Landin.Tokens.Where (Stream, 2).Last = 9,
         "the span of 'count' is its own bytes");
   end Kinds_And_Spans;

   --  [1750]: a token is as long as it can be, so these run together.
   procedure Longest_Token_Wins (Item : in out Landin.Testing.Context);

   procedure Longest_Token_Wins (Item : in out Landin.Testing.Context) is
      Sources : Landin.Source.Sets.Source_Set;
      Names   : Landin.Source.Names.Table;
      Joined  : Landin.Tokens.Token_Stream;
      Apart   : Landin.Tokens.Token_Stream;
   begin
      Lex_Text ("incx", Sources, Names, Joined);
      Landin.Testing.Check
        (Item, Landin.Tokens.Kind (Joined, 1) = Landin.Tokens.Identifier,
         "'incx' is one name, not 'inc' and 'x'");
      Landin.Testing.Check_Equal
        (Item, Natural (Landin.Tokens.Count (Joined)), 2,
         "and it is one token");

      Lex_Text ("inc x", Sources, Names, Apart);
      Landin.Testing.Check
        (Item, Landin.Tokens.Kind (Apart, 1) = Landin.Tokens.Kw_Inc,
         "'inc x' is the keyword and a name");
      Landin.Testing.Check_Equal
        (Item, Natural (Landin.Tokens.Count (Apart)), 3,
         "which is two tokens");

      --  The signs, longest first: '<=' is never '<' then '='.
      declare
         Signs : Landin.Tokens.Token_Stream;
      begin
         Lex_Text ("<= << <> := == -> +%", Sources, Names, Signs);
         Landin.Testing.Check
           (Item, Landin.Tokens.Kind (Signs, 1) = Landin.Tokens.Less_Equal
            and then Landin.Tokens.Kind (Signs, 2) = Landin.Tokens.Less_Less
            and then Landin.Tokens.Kind (Signs, 3)
                     = Landin.Tokens.Less_Greater
            and then Landin.Tokens.Kind (Signs, 4)
                     = Landin.Tokens.Colon_Equal
            and then Landin.Tokens.Kind (Signs, 5)
                     = Landin.Tokens.Equal_Equal
            and then Landin.Tokens.Kind (Signs, 6)
                     = Landin.Tokens.Minus_Greater
            and then Landin.Tokens.Kind (Signs, 7)
                     = Landin.Tokens.Plus_Percent,
            "every two-byte sign is one token");
      end;
   end Longest_Token_Wins;

   --  [1780]: the opener decides the form, and a block comment nests.
   procedure Comments_Are_Space (Item : in out Landin.Testing.Context);

   procedure Comments_Are_Space (Item : in out Landin.Testing.Context) is
      Sources : Landin.Source.Sets.Source_Set;
      Names   : Landin.Source.Names.Table;
      Stream  : Landin.Tokens.Token_Stream;
   begin
      Lex_Text ("a --( x --( y )-- z )-- b", Sources, Names, Stream);
      Landin.Testing.Check_Equal
        (Item, Natural (Landin.Tokens.Count (Stream)), 3,
         "a nested block comment is space, however deep");

      declare
         Inline : Landin.Tokens.Token_Stream;
      begin
         Lex_Text ("1 --( here )-- + 2", Sources, Names, Inline);
         Landin.Testing.Check_Equal
           (Item, Natural (Landin.Tokens.Count (Inline)), 4,
            "a block comment may sit between two tokens on one line");
      end;

      declare
         Doc : Landin.Tokens.Token_Stream;
      begin
         Lex_Text ("--- a doc" & LF & "a: u32 = 1", Sources, Names, Doc);
         Landin.Testing.Check
           (Item, Landin.Tokens.Space_Count (Doc) >= 1
            and then Landin.Tokens.Kind (Landin.Tokens.Nth_Space (Doc, 1))
                     = Landin.Tokens.Doc_Comment
            and then Landin.Tokens.Where
                       (Landin.Tokens.Nth_Space (Doc, 1)).Last = 9,
            "a doc comment keeps its span for [0030] to attach later");
         Landin.Testing.Check_Equal
           (Item, Landin.Tokens.Fault_Count (Doc), 0,
            "and is not a fault");
      end;

      declare
         Unclosed : Landin.Tokens.Token_Stream;
      begin
         Lex_Text ("--( never closed", Sources, Names, Unclosed);
         Landin.Testing.Check_Equal
           (Item, Landin.Tokens.Fault_Count (Unclosed), 1,
            "a block comment never closed is one fault");
         Landin.Testing.Check
           (Item,
            Landin.Tokens.Kind (Landin.Tokens.Nth_Fault (Unclosed, 1))
            = Landin.Tokens.Unterminated_Block_Comment,
            "and it says which fault it is");
         Landin.Testing.Check
           (Item,
            Landin.Tokens.Opened_At
              (Landin.Tokens.Nth_Fault (Unclosed, 1)).First = 0,
            "and points at the opener as well as the end");
      end;
   end Comments_Are_Space;

   procedure Comments_Require_UTF8 (Item : in out Landin.Testing.Context);

   procedure Comments_Require_UTF8 (Item : in out Landin.Testing.Context) is
      function B (Value : Natural) return Character is
        (Character'Val (Value));

      procedure Check
        (Label, Text : String; Bad : Boolean := True;
         Fault_At : Natural := 5; Tokens : Natural := 3;
         Unclosed : Boolean := False);

      procedure Check
        (Label, Text : String; Bad : Boolean := True;
         Fault_At : Natural := 5; Tokens : Natural := 3;
         Unclosed : Boolean := False)
      is
         Sources : Landin.Source.Sets.Source_Set;
         Names : Landin.Source.Names.Table;
         Stream : Landin.Tokens.Token_Stream;
         Reports : Landin.Diagnostics.Diagnostic_List;
      begin
         Lex_Text (Text, Sources, Names, Stream);
         Landin.Diagnostics.Lexical.Report (Stream, Reports);
         Landin.Testing.Check_Equal
           (Item, Natural (Landin.Tokens.Count (Stream)), Tokens,
            Label & " retains the surrounding token count");
         Landin.Testing.Check_Equal
           (Item, Landin.Testing.Layout.Problem (Text, Stream), "",
            Label & " keeps every byte of the comment");
         Landin.Testing.Check
           (Item, Landin.Tokens.Kind (Stream, 1) = Landin.Tokens.Identifier
            and then (if Tokens = 3 then
              Landin.Tokens.Kind (Stream, 2) = Landin.Tokens.Identifier),
            Label & " keeps ordinary names outside the comment");
         Landin.Testing.Check_Equal
           (Item, Landin.Diagnostics.Count (Reports),
            Boolean'Pos (Bad) + Boolean'Pos (Unclosed),
            Label & " has one encoding report per comment");
         if Bad and then Landin.Diagnostics.Count (Reports) > 0 then
            declare
               Report : constant Landin.Diagnostics.Diagnostic :=
                 Landin.Diagnostics.Get (Reports, 1);
               Where : constant Landin.Source.Span :=
                 Landin.Diagnostics.Span_Of
                   (Landin.Diagnostics.Primary (Report));
            begin
               Landin.Testing.Check
                 (Item, Landin.Diagnostics.Code (Report) = "L0012"
                  and then Where.First = Landin.Source.Byte_Offset (Fault_At)
                  and then Where.Last = Where.First + 1
                  and then Landin.Diagnostics.Note_Count (Report) = 1
                  and then Landin.Diagnostics.Nth_Note (Report, 1) =
                    "[1750]: comment text must be shortest-form UTF-8",
                  Label & " identifies the first invalid byte and rule");
            end;
         end if;
         if Unclosed and then Landin.Diagnostics.Count (Reports) = 2 then
            Landin.Testing.Check_Equal
              (Item, Landin.Diagnostics.Code
                 (Landin.Diagnostics.Get (Reports, 2)), "L0013",
               Label & " also reports the missing block closer");
         end if;
      end Check;
   begin
      Check ("line truncation", "a -- " & B (16#C3#), Tokens => 2);
      Check ("doc truncation", "a ---" & B (16#C3#) & LF & "b");
      Check ("block delimiter", "a --(" & B (16#C3#) & ")-- b");
      Check ("stray continuation", "a -- " & B (16#80#) & LF & "b");
      Check ("overlong", "a -- " & B (16#C0#) & B (16#AF#) & LF & "b");
      Check ("surrogate", "a -- " & B (16#ED#) & B (16#A0#)
             & B (16#80#) & LF & "b");
      Check ("out of range", "a -- " & B (16#F4#) & B (16#90#)
             & B (16#80#) & B (16#80#) & LF & "b");
      Check ("bad lead", "a -- " & B (16#FF#) & LF & "b");
      Check ("nested invalid", "a --(--(" & B (16#C3#) & ")--)-- b",
             Fault_At => 8);
      Check ("unclosed invalid", "a --(" & B (16#C3#),
             Tokens => 2, Unclosed => True);
      Check ("valid two bytes", "a -- " & B (16#C3#) & B (16#A9#)
             & LF & "b", Bad => False);
      Check ("valid three bytes", "a ---" & B (16#E2#) & B (16#98#)
             & B (16#83#) & LF & "b", Bad => False);
      Check ("valid four bytes", "a --(" & B (16#F0#) & B (16#9F#)
             & B (16#98#) & B (16#80#) & ")-- b", Bad => False);
      Check ("plain bytes", "a --(ascii)-- b", Bad => False);
   end Comments_Require_UTF8;

   --  [1770] gives each base its own digits, enables text, and [1830]
   --  refuses a float.
   procedure Float_Digit_Runs_Have_Both_Boundaries
     (Item : in out Landin.Testing.Context);

   procedure Float_Digit_Runs_Have_Both_Boundaries
     (Item : in out Landin.Testing.Context)
   is
      Sources : Landin.Source.Sets.Source_Set;
      Names   : Landin.Source.Names.Table;

      procedure Check (Text : String; Expected : Landin.Tokens.Token_Kind);

      procedure Check (Text : String; Expected : Landin.Tokens.Token_Kind) is
         Stream : Landin.Tokens.Token_Stream;
         Bad : constant Boolean := Expected = Landin.Tokens.Malformed_Float;
      begin
         Lex_Text (Text & " tail", Sources, Names, Stream);
         Landin.Testing.Check
           (Item, Landin.Tokens.Count (Stream) = 3
            and then Landin.Tokens.Kind (Stream, 1) = Expected,
            Text & " remains one complete float run");
         Landin.Testing.Check_Equal
           (Item, Landin.Tokens.Fault_Count (Stream), (if Bad then 1 else 0),
            Text & " keeps its exact fault count");
         Landin.Testing.Check
           (Item, Landin.Tokens.Where (Stream, 1).First = 0
            and then Landin.Tokens.Where (Stream, 1).Last
                       = Landin.Source.Byte_Offset (Text'Length),
            Text & " keeps the entire spelling in its token span");
         Landin.Testing.Check
           (Item, Landin.Tokens.Kind (Stream, 2) = Landin.Tokens.Identifier
            and then Landin.Tokens.Where (Stream, 2).First
                       = Landin.Source.Byte_Offset (Text'Length + 1),
            Text & " preserves the following token");
         if Bad then
            Landin.Testing.Check
              (Item, Landin.Tokens.Kind (Landin.Tokens.Nth_Fault (Stream, 1))
                       = Landin.Tokens.Malformed_Float_Literal_Run,
               Text & " retains the floating-point diagnostic category");
         end if;
      end Check;
   begin
      Check ("1_.5", Landin.Tokens.Malformed_Float);
      Check ("1__.5", Landin.Tokens.Malformed_Float);
      Check ("0x1_.8p0", Landin.Tokens.Malformed_Float);
      Check ("0x_1.8p0", Landin.Tokens.Malformed_Float);
      Check ("0x.8p0", Landin.Tokens.Malformed_Float);
      Check ("0x_.8p0", Landin.Tokens.Malformed_Float);
      Check ("1.5_", Landin.Tokens.Malformed_Float);
      Check ("1.5e1_", Landin.Tokens.Malformed_Float);
      Check ("1.5e_1", Landin.Tokens.Malformed_Float);
      Check ("0x1.8_p0", Landin.Tokens.Malformed_Float);
      Check ("0x1.8p1_", Landin.Tokens.Malformed_Float);
      Check ("0x1.8p_1", Landin.Tokens.Malformed_Float);
      Check ("1.5", Landin.Tokens.Float_Literal);
      Check ("1__0.5__0e+1__0", Landin.Tokens.Float_Literal);
      Check ("0x1__A.F__0p-1__0", Landin.Tokens.Hex_Float_Literal);
      Check ("0x0.0p0", Landin.Tokens.Hex_Float_Literal);
      Check ("1.5e-0", Landin.Tokens.Float_Literal);
      Check ("0xA.0P+1", Landin.Tokens.Hex_Float_Literal);
   end Float_Digit_Runs_Have_Both_Boundaries;

   --  D245: a number ends where its spelling ends.  A letter, digit or
   --  underscore directly after it is part of one malformed literal, so
   --  `1u64` is one refusal rather than `1` and an undeclared `u64`.
   procedure Numbers_Run_To_The_End_Of_Their_Spelling
     (Item : in out Landin.Testing.Context);

   procedure Numbers_Run_To_The_End_Of_Their_Spelling
     (Item : in out Landin.Testing.Context)
   is
      Sources : Landin.Source.Sets.Source_Set;
      Names   : Landin.Source.Names.Table;

      procedure Check (Text : String; Expected : Landin.Tokens.Token_Kind);

      procedure Check (Text : String; Expected : Landin.Tokens.Token_Kind) is
         Stream : Landin.Tokens.Token_Stream;
         Fault  : constant Landin.Tokens.Fault_Kind :=
           (if Expected = Landin.Tokens.Malformed_Float
            then Landin.Tokens.Malformed_Float_Literal_Run
            else Landin.Tokens.Malformed_Integer_Run);
      begin
         Lex_Text (Text & " tail", Sources, Names, Stream);
         Landin.Testing.Check
           (Item, Landin.Tokens.Count (Stream) = 3
            and then Landin.Tokens.Kind (Stream, 1) = Expected
            and then Landin.Tokens.Where (Stream, 1).Last
                       = Landin.Source.Byte_Offset (Text'Length),
            Text & " is one literal spanning its whole spelling");
         Landin.Testing.Check_Equal
           (Item, Landin.Tokens.Fault_Count (Stream), 1,
            Text & " makes exactly one fault");
         Landin.Testing.Check
           (Item, Landin.Tokens.Fault_Count (Stream) = 1
            and then Landin.Tokens.Kind (Landin.Tokens.Nth_Fault (Stream, 1))
                       = Fault,
            Text & " keeps its literal's diagnostic category");
      end Check;
   begin
      Check ("1u64", Landin.Tokens.Malformed_Integer);
      Check ("1_000u8", Landin.Tokens.Malformed_Integer);
      Check ("12abc", Landin.Tokens.Malformed_Integer);
      Check ("1U", Landin.Tokens.Malformed_Integer);
      Check ("0xffg", Landin.Tokens.Malformed_Integer);
      Check ("0x1p3", Landin.Tokens.Malformed_Integer);
      Check ("0o17z", Landin.Tokens.Malformed_Integer);
      Check ("0b1012", Landin.Tokens.Malformed_Integer);
      Check ("1e5", Landin.Tokens.Malformed_Float);
      Check ("1e5x", Landin.Tokens.Malformed_Float);
      Check ("1.5f32", Landin.Tokens.Malformed_Float);
      Check ("1.5e3x", Landin.Tokens.Malformed_Float);
      Check ("0x1.8p3q", Landin.Tokens.Malformed_Float);
   end Numbers_Run_To_The_End_Of_Their_Spelling;

   procedure Literals_And_Refusals (Item : in out Landin.Testing.Context);

   procedure Literals_And_Refusals (Item : in out Landin.Testing.Context) is
      Sources : Landin.Source.Sets.Source_Set;
      Names   : Landin.Source.Names.Table;
      Stream  : Landin.Tokens.Token_Stream;
   begin
      Lex_Text ("0xDEAD_BEEF 0o755 0b1010 1_000", Sources, Names, Stream);
      Landin.Testing.Check_Equal
        (Item, Landin.Tokens.Fault_Count (Stream), 0,
         "every base the kernel spells is accepted");
      Landin.Testing.Check
        (Item, Landin.Tokens.Base (Landin.Tokens.Token_At (Stream, 1))
               = Landin.Tokens.Hexadecimal,
         "a base prefix is remembered");
      Landin.Testing.Check
        (Item,
         Landin.Tokens.Digit_Span
           (Landin.Tokens.Token_At (Stream, 1)).First = 2,
         "and the digit span skips the prefix, so the checker need not");

      declare
         Wrong : Landin.Tokens.Token_Stream;
      begin
         Lex_Text ("0b102", Sources, Names, Wrong);
         Landin.Testing.Check
           (Item, Landin.Tokens.Kind (Wrong, 1)
                  = Landin.Tokens.Malformed_Integer,
            "a digit outside the base makes one wrong literal");
         Landin.Testing.Check_Equal
           (Item, Landin.Tokens.Fault_Count (Wrong), 1,
            "and one fault, not a literal and a stray digit");
      end;

      declare
         Float_Text : Landin.Tokens.Token_Stream;
      begin
         Lex_Text ("ratio: f32 = 1.5", Sources, Names, Float_Text);
         Landin.Testing.Check
           (Item, Landin.Tokens.Kind (Float_Text, 5)
                  = Landin.Tokens.Float_Literal,
            "a decimal float is one enabled lexeme");
         Landin.Testing.Check_Equal
           (Item, Landin.Tokens.Fault_Count (Float_Text), 0,
            "an enabled decimal float carries no lexical refusal");
      end;

      declare
         Hex_Float : Landin.Tokens.Token_Stream;
      begin
         Lex_Text ("ratio: f64 = 0x1.8p+1", Sources, Names, Hex_Float);
         Landin.Testing.Check
           (Item, Landin.Tokens.Kind (Hex_Float, 5)
                  = Landin.Tokens.Hex_Float_Literal,
            "a hexadecimal float is one enabled lexeme");
         Landin.Testing.Check_Equal
           (Item,
            Landin.Tokens.Fault_Count (Hex_Float), 0,
            "an enabled hexadecimal float carries no lexical refusal");
      end;

      declare
         Binary_Fraction : Landin.Tokens.Token_Stream;
      begin
         Lex_Text ("0b1.1p0", Sources, Names, Binary_Fraction);
         Landin.Testing.Check
           (Item, Landin.Tokens.Kind (Binary_Fraction, 1)
                  = Landin.Tokens.Integer_Literal,
            "a binary prefix does not acquire hexadecimal float syntax");
      end;

      declare
         Malformed : Landin.Tokens.Token_Stream;
      begin
         Lex_Text ("ratio := 1.0e-", Sources, Names, Malformed);
         Landin.Testing.Check
           (Item, Landin.Tokens.Kind (Malformed, 3)
                  = Landin.Tokens.Malformed_Float,
            "an incomplete exponent remains one malformed float");
         Landin.Testing.Check
           (Item,
            Landin.Tokens.Kind (Landin.Tokens.Nth_Fault (Malformed, 1))
              = Landin.Tokens.Malformed_Float_Literal_Run,
            "and its fault identifies the malformed float spelling");
      end;

      declare
         Quoted : Landin.Tokens.Token_Stream;
      begin
         Lex_Text ("""a\""b""", Sources, Names, Quoted);
         Landin.Testing.Check_Equal
           (Item, Landin.Tokens.Fault_Count (Quoted), 0,
            "an escaped quote does not close a text literal");
         Landin.Testing.Check
           (Item, Landin.Tokens.Kind (Quoted, 1)
                  = Landin.Tokens.Text_Literal,
            "an enabled text literal is one token");
      end;

      declare
         Characters : Landin.Tokens.Token_Stream;
      begin
         Lex_Text ("'a' '\u{2603}'", Sources, Names, Characters);
         Landin.Testing.Check_Equal
           (Item, Landin.Tokens.Fault_Count (Characters), 0,
            "raw and escaped character literals carry no lexical fault");
         Landin.Testing.Check
           (Item, Landin.Tokens.Kind (Characters, 1)
                  = Landin.Tokens.Character_Literal
             and then Landin.Tokens.Kind (Characters, 2)
                        = Landin.Tokens.Character_Literal,
            "each character literal is one enabled token");
      end;

      declare
         Malformed : Landin.Tokens.Token_Stream;
         Where : Landin.Source.Span;
      begin
         Lex_Text ("""bad\q""", Sources, Names, Malformed);
         Landin.Testing.Check_Equal
           (Item, Landin.Tokens.Fault_Count (Malformed), 1,
            "an unknown text escape is one lexical fault");
         Landin.Testing.Check
           (Item,
            Landin.Tokens.Kind (Landin.Tokens.Nth_Fault (Malformed, 1))
              = Landin.Tokens.Malformed_Text_Literal_Run,
            "and the fault identifies malformed text");
         Where := Landin.Tokens.Where
           (Landin.Tokens.Nth_Fault (Malformed, 1));
         Landin.Testing.Check
           (Item, Where.First = 4 and then Where.Last = 6,
            "and its span covers the offending escape");
      end;
   end Literals_And_Refusals;

   --  D161/D181 keep escape decoding shared by checking and lowering.
   --  Exercise byte, UTF-8 and UTF-16 results, including failures that
   --  source text cannot conveniently carry as an invalid UTF-8 file.
   procedure Text_Literal_Decoding
     (Item : in out Landin.Testing.Context);

   procedure Text_Literal_Decoding
     (Item : in out Landin.Testing.Context)
   is
      Bytes : String (1 .. 32);
      Length : Natural;
      Fault : Landin.Tokens.Text.Problem;
      First, Last : Natural;
      Units : Landin.Tokens.Text.Code_Unit_Array (1 .. 32);

      procedure Decode (Lexeme : String);

      procedure Decode (Lexeme : String) is
      begin
         Landin.Tokens.Text.Decode
           (Lexeme, Bytes, Length, Fault, First, Last);
      end Decode;
   begin
      Decode ("""A\t\x42""");
      Landin.Testing.Check
        (Item,
         Fault = Landin.Tokens.Text.Well_Formed
           and then Length = 3
           and then Bytes (1) = 'A'
           and then Character'Pos (Bytes (2)) = 9
           and then Bytes (3) = 'B',
         "simple and hexadecimal escapes decode to their bytes");

      Decode
        ('"' & Character'Val (16#E2#) & Character'Val (16#98#)
         & Character'Val (16#83#) & '"');
      Landin.Testing.Check
        (Item,
         Fault = Landin.Tokens.Text.Well_Formed and then Length = 3,
         "a shortest-form UTF-8 source run is retained byte for byte");

      Decode ('"' & Character'Val (16#C0#) & '"');
      Landin.Testing.Check
        (Item,
         Fault = Landin.Tokens.Text.Invalid_UTF8_Source
           and then First = 1 and then Last = 2,
         "an invalid UTF-8 source byte names its half-open span");

      Decode ("""\u{}""");
      Landin.Testing.Check
        (Item,
         Fault = Landin.Tokens.Text.Malformed_Codepoint_Escape,
         "an empty codepoint escape is malformed");

      Landin.Tokens.Text.Decode_View
        ("""\u{1f600}""", False, Landin.Tokens.Text.UTF8_Units,
         Units, Length, Fault, First, Last);
      Landin.Testing.Check
        (Item,
         Fault = Landin.Tokens.Text.Well_Formed
           and then Length = 4
           and then Units (1) = 16#F0#
           and then Units (2) = 16#9F#
           and then Units (3) = 16#98#
           and then Units (4) = 16#80#,
         "a scalar escape is encoded as shortest-form UTF-8");

      Landin.Tokens.Text.Decode_View
        ("""A\u{2603}\u{1f600}""", False,
         Landin.Tokens.Text.UTF16_Units,
         Units, Length, Fault, First, Last);
      Landin.Testing.Check
        (Item,
         Fault = Landin.Tokens.Text.Well_Formed
           and then Length = 4
           and then Units (1) = Character'Pos ('A')
           and then Units (2) = 16#2603#
           and then Units (3) = 16#D83D#
           and then Units (4) = 16#DE00#,
         "UTF-16 uses code units and a surrogate pair for a large scalar");

      Landin.Tokens.Text.Decode_View
        ("""\x41""", False, Landin.Tokens.Text.UTF8_Units,
         Units, Length, Fault, First, Last);
      Landin.Testing.Check
        (Item, Fault = Landin.Tokens.Text.Byte_Where_Text_Is_Meant,
         "a byte escape is not a Unicode scalar in a text context");

      Landin.Tokens.Text.Decode_View
        ("""\u{41}""", False, Landin.Tokens.Text.Byte_Units,
         Units, Length, Fault, First, Last);
      Landin.Testing.Check
        (Item, Fault = Landin.Tokens.Text.Codepoint_Where_Bytes_Are_Meant,
         "a scalar escape is not accepted in a byte context");

      --  A literal that may still be text is read to its end, so an escape
      --  after `\u{...}` is judged, and the codepoint answer points at the
      --  first codepoint escape.
      Decode ("""\u{41}\q""");
      Landin.Testing.Check
        (Item, Fault = Landin.Tokens.Text.Unknown_Escape,
         "an unknown escape after a codepoint escape is the fault");
      Decode ("""\u{41}\x4""");
      Landin.Testing.Check
        (Item, Fault = Landin.Tokens.Text.Short_Byte_Escape,
         "a short byte escape after a codepoint escape is the fault");
      Decode ("""\u{41}\x41\u{42}""");
      Landin.Testing.Check
        (Item,
         Fault = Landin.Tokens.Text.Codepoint_Where_Bytes_Are_Meant
           and then First = 1 and then Last = 7,
         "a well-formed literal with codepoints answers with its first one");
   end Text_Literal_Decoding;

   --  D163 uses the same decoder in lexing, checking and lowering.  Hold
   --  both raw UTF-8 and escaped scalar values at that seam.
   procedure Character_Literal_Decoding
     (Item : in out Landin.Testing.Context);

   procedure Character_Literal_Decoding
     (Item : in out Landin.Testing.Context)
   is
      Value, First, Last : Natural;
      Fault : Landin.Tokens.Text.Problem;

      procedure Decode (Lexeme : String);

      procedure Decode (Lexeme : String) is
      begin
         Landin.Tokens.Text.Decode_Character
           (Lexeme, Value, Fault, First, Last);
      end Decode;
   begin
      Decode
        ("'" & Character'Val (16#E2#) & Character'Val (16#98#)
         & Character'Val (16#83#) & "'");
      Landin.Testing.Check
        (Item,
         Fault = Landin.Tokens.Text.Well_Formed and then Value = 16#2603#,
         "one shortest-form UTF-8 scalar decodes to its codepoint");

      Decode ("'\u{1F600}'");
      Landin.Testing.Check
        (Item,
         Fault = Landin.Tokens.Text.Well_Formed and then Value = 16#1F600#,
         "a codepoint escape decodes to one scalar");

      Decode ("'\x41'");
      Landin.Testing.Check
        (Item, Fault = Landin.Tokens.Text.Byte_Where_Codepoint_Is_Meant,
         "a byte escape is not a character escape");

      Decode ("'ab'");
      Landin.Testing.Check
        (Item, Fault = Landin.Tokens.Text.Multiple_Characters,
         "two source scalars are not one character literal");
   end Character_Literal_Decoding;

   --  D164's decoder owns both the variable delimiter and the exact
   --  indentation removal shared by checking and lowering.
   procedure Raw_Delimiters_Use_The_Maximal_Opener
     (Item : in out Landin.Testing.Context);

   procedure Raw_Delimiters_Use_The_Maximal_Opener
     (Item : in out Landin.Testing.Context)
   is
      Three : constant String (1 .. 3) := [others => '"'];
      Six : constant String (1 .. 6) := [others => '"'];
      Sources : Landin.Source.Sets.Source_Set;
      Names : Landin.Source.Names.Table;
      Stream : Landin.Tokens.Token_Stream;
      Bytes : String (1 .. 32);
      Length, First, Last : Natural;
      Fault : Landin.Tokens.Text.Problem;
   begin
      Lex_Text (Six, Sources, Names, Stream);
      Landin.Testing.Check
        (Item, Landin.Tokens.Count (Stream) = 2
         and then Landin.Tokens.Kind (Stream, 1) = Landin.Tokens.Raw_Literal
         and then Landin.Tokens.Where (Stream, 1).Last = 6,
         "six adjacent quotes form one six-quote raw opener");
      Landin.Testing.Check
        (Item, Landin.Tokens.Fault_Count (Stream) = 1
         and then Landin.Tokens.Kind (Landin.Tokens.Nth_Fault (Stream, 1))
                    = Landin.Tokens.Unterminated_Literal,
         "adjacent quotes do not split into an empty raw literal");
      Lex_Text (Six & LF & Six, Sources, Names, Stream);
      Landin.Testing.Check
        (Item, Landin.Tokens.Count (Stream) = 2
         and then Landin.Tokens.Fault_Count (Stream) = 0
         and then Landin.Tokens.Kind (Stream, 1) = Landin.Tokens.Raw_Literal,
         "a later complete six-quote closer closes the token");
      Landin.Tokens.Text.Decode_Raw
        (Six & LF & Six, Bytes, Length, Fault, First, Last);
      Landin.Testing.Check
        (Item, Fault = Landin.Tokens.Text.Well_Formed
         and then Length = 1 and then Bytes (1) = LF,
         "the intervening line ending is content");
      Lex_Text (Six & "a" & Three, Sources, Names, Stream);
      Landin.Testing.Check
        (Item, Landin.Tokens.Fault_Count (Stream) = 1
         and then Landin.Tokens.Kind (Landin.Tokens.Nth_Fault (Stream, 1))
                    = Landin.Tokens.Unterminated_Literal,
         "a shorter quote run cannot close the longer opener");
      Lex_Text ("""""", Sources, Names, Stream);
      Landin.Testing.Check
        (Item, Landin.Tokens.Fault_Count (Stream) = 0
         and then Landin.Tokens.Kind (Stream, 1) = Landin.Tokens.Text_Literal,
         "two quotes retain ordinary empty text");
   end Raw_Delimiters_Use_The_Maximal_Opener;

   procedure Raw_Literal_Decoding
     (Item : in out Landin.Testing.Context);

   procedure Raw_Literal_Decoding
     (Item : in out Landin.Testing.Context)
   is
      Three : constant String (1 .. 3) := [others => '"'];
      Four  : constant String (1 .. 4) := [others => '"'];
      Bytes : String (1 .. 64);
      Length, First, Last : Natural;
      Fault : Landin.Tokens.Text.Problem;

      procedure Decode (Lexeme : String);

      procedure Decode (Lexeme : String) is
      begin
         Landin.Tokens.Text.Decode_Raw
           (Lexeme, Bytes, Length, Fault, First, Last);
      end Decode;
   begin
      Decode
        (Three & LF & "  one" & LF & "    two" & LF & "  " & Three);
      Landin.Testing.Check
        (Item,
         Fault = Landin.Tokens.Text.Well_Formed
           and then Bytes (1 .. Length) = LF & "one" & LF & "  two" & LF,
         "the closer's exact indentation is removed from every line");

      Decode (Three & "\n" & Three);
      Landin.Testing.Check
        (Item,
         Fault = Landin.Tokens.Text.Well_Formed
           and then Length = 2
           and then Bytes (1 .. Length) = "\n",
         "a raw apparent escape remains two bytes");

      Decode (Three & "   " & Three);
      Landin.Testing.Check
        (Item,
         Fault = Landin.Tokens.Text.Well_Formed
           and then Bytes (1 .. Length) = "   ",
         "inline horizontal bytes are content rather than indentation");

      Decode (Four & "a" & Three & "b" & Four);
      Landin.Testing.Check
        (Item,
         Fault = Landin.Tokens.Text.Well_Formed
           and then Bytes (1 .. Length) = "a" & Three & "b",
         "a quote run shorter than the opener remains content");

      Decode (Three & LF & "  one" & LF & " short" & LF & "  " & Three);
      Landin.Testing.Check
        (Item, Fault = Landin.Tokens.Text.Inconsistent_Raw_Indentation,
         "a nonblank line must carry the closer's exact prefix");

      Decode (Three & Character'Val (16#C0#) & Three);
      Landin.Testing.Check
        (Item, Fault = Landin.Tokens.Text.Invalid_UTF8_Source,
         "raw source content is shortest-form UTF-8");
   end Raw_Literal_Decoding;

   procedure Unterminated_Literals_Are_Faults
     (Item : in out Landin.Testing.Context);

   procedure Unterminated_Literals_Are_Faults
     (Item : in out Landin.Testing.Context)
   is
      Sources : Landin.Source.Sets.Source_Set;
      Names   : Landin.Source.Names.Table;
      Stream  : Landin.Tokens.Token_Stream;
   begin
      Lex_Text ("t: utf8 = ""never closed" & LF & "a: u32 = 1",
                Sources, Names, Stream);

      Landin.Testing.Check_Equal
        (Item, Landin.Tokens.Fault_Count (Stream), 1,
         "a text literal that runs to the line end is one fault");
      Landin.Testing.Check
        (Item,
         Landin.Tokens.Kind (Landin.Tokens.Nth_Fault (Stream, 1))
         = Landin.Tokens.Unterminated_Literal,
         "and says it was never closed");
      Landin.Testing.Check
        (Item,
         Landin.Tokens.Refused (Landin.Tokens.Nth_Fault (Stream, 1))
         = Landin.Tokens.Text_Literal,
         "and still says which construct it was");
      Landin.Testing.Check
        (Item,
         Landin.Tokens.Kind (Stream, Landin.Tokens.Count (Stream) - 1)
         = Landin.Tokens.Integer_Literal,
         "and the scan carries on at the next line");
   end Unterminated_Literals_Are_Faults;

   procedure Unknown_Bytes_Recover (Item : in out Landin.Testing.Context);

   procedure Unknown_Bytes_Recover (Item : in out Landin.Testing.Context) is
      Sources : Landin.Source.Sets.Source_Set;
      Names   : Landin.Source.Names.Table;
      Stream  : Landin.Tokens.Token_Stream;
   begin
      Lex_Text ("a: u32 = 1;" & LF & "b: u32 = 2", Sources, Names, Stream);
      Landin.Testing.Check_Equal
        (Item, Landin.Tokens.Fault_Count (Stream), 1,
         "an unspellable byte is one fault");
      Landin.Testing.Check
        (Item, Landin.Tokens.Kind (Stream, 6)
               = Landin.Tokens.Unknown_Bytes,
         "and one token, so a parser has something in the hole");
      Landin.Testing.Check
        (Item,
         Landin.Tokens.Kind (Stream, 7) = Landin.Tokens.Identifier,
         "and the scan carries on at the next byte");

      declare
         Wanted : Landin.Tokens.Kind_Set :=
           [others => False];
      begin
         Wanted (Landin.Tokens.End_Of_Input) := True;
         Wanted (Landin.Tokens.Kw_End) := True;
         Landin.Testing.Check
           (Item,
            Landin.Tokens.Skip_To (Stream, 1, Wanted)
            = Landin.Tokens.Count (Stream),
            "a forward scan for a recovery point always stops");
      end;
   end Unknown_Bytes_Recover;

   procedure Uppercase_Faults_Keep_Byte_Boundaries
     (Item : in out Landin.Testing.Context);

   procedure Uppercase_Faults_Keep_Byte_Boundaries
     (Item : in out Landin.Testing.Context)
   is
      Sources : Landin.Source.Sets.Source_Set;
      Names   : Landin.Source.Names.Table;
      Stream  : Landin.Tokens.Token_Stream;
   begin
      Lex_Text ("A ABC A;B", Sources, Names, Stream);
      Landin.Testing.Check
        (Item, Landin.Tokens.Count (Stream) = 4
           and then Landin.Tokens.Fault_Count (Stream) = 3,
         "uppercase classification preserves tokens and fault runs");
      Landin.Testing.Check
        (Item,
         (for all Index in Landin.Tokens.Token_Index'(1) .. 3 =>
            Landin.Tokens.Kind (Stream, Index) = Landin.Tokens.Unknown_Bytes)
         and then Landin.Tokens.Kind (Stream, 4) = Landin.Tokens.End_Of_Input,
         "the parser receives its existing unknown-byte tokens and end");
      Landin.Testing.Check
        (Item,
         Landin.Tokens.Kind (Landin.Tokens.Nth_Fault (Stream, 1))
           = Landin.Tokens.Uppercase_Byte_Run
         and then Landin.Tokens.Kind (Landin.Tokens.Nth_Fault (Stream, 2))
           = Landin.Tokens.Uppercase_Byte_Run
         and then Landin.Tokens.Kind (Landin.Tokens.Nth_Fault (Stream, 3))
           = Landin.Tokens.Unknown_Byte_Run,
         "only runs consisting entirely of uppercase ASCII specialize");
      Landin.Testing.Check
        (Item,
         Landin.Tokens.Where (Landin.Tokens.Nth_Fault (Stream, 1)).First = 0
         and then
           Landin.Tokens.Where (Landin.Tokens.Nth_Fault (Stream, 1)).Last = 1
         and then
           Landin.Tokens.Where (Landin.Tokens.Nth_Fault (Stream, 2)).First = 2
         and then
           Landin.Tokens.Where (Landin.Tokens.Nth_Fault (Stream, 2)).Last = 5
         and then
           Landin.Tokens.Where (Landin.Tokens.Nth_Fault (Stream, 3)).First = 6
         and then
           Landin.Tokens.Where (Landin.Tokens.Nth_Fault (Stream, 3)).Last = 9,
         "single, multiple and mixed bytes retain their exact spans");
   end Uppercase_Faults_Keep_Byte_Boundaries;

   ------------------------------------------------------------------
   --  Space, kept
   ------------------------------------------------------------------

   --  [1750] and [1780] piece by piece: what each form of space is kept
   --  as, and that the tokens and the pieces are the whole file however it
   --  ends, even when it ends inside something.
   procedure Space_Is_Kept (Item : in out Landin.Testing.Context);

   procedure Space_Is_Kept (Item : in out Landin.Testing.Context) is
      Tab : constant Character := Character'Val (9);
      CR  : constant Character := Character'Val (13);
      FF  : constant Character := Character'Val (12);

      function B (Value : Natural) return Character is
        (Character'Val (Value));

      --  Lexes Text, requires it back, and returns its pieces' kinds as
      --  one letter each: b, n, l, d and c.
      function Kinds (Label, Text : String) return String;

      function Kinds (Label, Text : String) return String is
         Sources : Landin.Source.Sets.Source_Set;
         Names   : Landin.Source.Names.Table;
         Stream  : Landin.Tokens.Token_Stream;
         Letters : Unbounded.Unbounded_String;
      begin
         Lex_Text (Text, Sources, Names, Stream);
         Landin.Testing.Check_Equal
           (Item, Landin.Testing.Layout.Problem (Text, Stream), "",
            Label & " is reproduced from its tokens and its space");
         for Index in 1 .. Landin.Tokens.Space_Count (Stream) loop
            Unbounded.Append
              (Letters,
               (case Landin.Tokens.Kind
                       (Landin.Tokens.Nth_Space (Stream, Index)) is
                   when Landin.Tokens.Blanks        => 'b',
                   when Landin.Tokens.Line_End      => 'n',
                   when Landin.Tokens.Line_Comment  => 'l',
                   when Landin.Tokens.Doc_Comment   => 'd',
                   when Landin.Tokens.Block_Comment => 'c'));
         end loop;
         return Unbounded.To_String (Letters);
      end Kinds;

      procedure Expect (Label, Text, Pieces : String);

      procedure Expect (Label, Text, Pieces : String) is
      begin
         Landin.Testing.Check_Equal
           (Item, Kinds (Label, Text), Pieces, Label & " keeps its pieces");
      end Expect;
   begin
      Expect ("an empty file", "", "");
      Expect ("a file of only space", " " & Tab & " " & LF & LF, "bnn");
      Expect ("a run of spaces and tabs", "a " & Tab & " b", "b");
      Expect ("LF", "a" & LF & "b", "n");
      Expect ("CR LF, which is one line end", "a" & CR & LF & "b", "n");
      Expect ("a lone CR", "a" & CR & "b", "n");
      Expect ("CR then CR LF", "a" & CR & CR & LF & "b", "nn");
      Expect ("LF then CR", "a" & LF & CR & "b", "nn");
      Expect ("a CR that ends the file", "a" & CR, "n");
      Expect ("no final line end", "a b", "b");
      Expect ("trailing blanks", "a  " & LF & "  ", "bnb");
      Expect ("blanks after a line comment are not the comment's",
              "a -- note " & Tab & LF & "b", "blbn");
      Expect ("blanks after a doc comment at the end of the file",
              "--- doc  ", "db");
      Expect ("a line comment of two dashes and a blank", "--  ", "lb");
      Expect ("a line comment and its line end",
              "a -- note" & CR & LF & "b", "bln");
      Expect ("a doc comment and its line end", "--- doc" & LF & "a", "dn");
      Expect ("a comment of two dashes only", "a --" & LF, "bln");
      Expect ("a block comment on one line", "a --( x )-- b", "bcb");
      Expect ("a nested block comment across lines",
              "a --( x" & LF & " --( y )-- " & CR & ")-- b", "bcb");
      Expect ("a block comment closed by a longer run",
              "a --( x )--- b", "bcb");
      Expect ("the end of the file inside a line comment",
              "a -- note", "bl");
      Expect ("the end of the file inside a doc comment",
              "a --- doc", "bd");
      Expect ("the end of the file inside a nested block comment",
              "a --( x --( y )-- z" & LF, "bc");
      Expect ("invalid UTF-8 inside a line comment",
              "a -- " & B (16#E9#) & LF & "b", "bln");
      Expect ("invalid UTF-8 inside a block comment",
              "a --(" & B (16#C3#) & ")-- b", "bcb");

      --  None of these is space: each is a token no rule spells, and the
      --  pieces are only what surrounds it.
      Expect ("a byte-order mark",
              B (16#EF#) & B (16#BB#) & B (16#BF#) & "a" & LF, "n");
      Expect ("a form feed", "a" & LF & FF & LF & "b", "nn");
      Expect ("a NUL byte", "a " & B (0) & " b", "bb");
      Expect ("invalid UTF-8 in a name", "caf" & B (16#E9#) & LF, "n");
      Expect ("an unclosed text literal", """open" & LF & "b", "n");
      Expect ("an unclosed raw literal",
              "a """"""" & LF & "never closed" & LF, "b");

      --  Which token each piece leads.
      declare
         Sources : Landin.Source.Sets.Source_Set;
         Names   : Landin.Source.Names.Table;
         Stream  : Landin.Tokens.Token_Stream;
         Text    : constant String :=
           "  --- doc" & LF & "a --( x )-- b" & LF & "-- tail";
      begin
         Lex_Text (Text, Sources, Names, Stream);
         Landin.Testing.Check
           (Item, Landin.Tokens.Leading (Stream, 1).First = 1
            and then Landin.Tokens.Leading (Stream, 1).Last = 3,
            "the first token is led by the space before it");
         Landin.Testing.Check
           (Item, Landin.Tokens.Leading (Stream, 2).First = 4
            and then Landin.Tokens.Leading (Stream, 2).Last = 6,
            "a token is led by the space since the token before it");
         Landin.Testing.Check
           (Item, Landin.Tokens.Kind (Stream, 3) = Landin.Tokens.End_Of_Input
            and then Landin.Tokens.Leading (Stream, 3).First = 7
            and then Landin.Tokens.Leading (Stream, 3).Last = 8,
            "and the end of input is led by the tail of the file");
      end;

      declare
         Sources : Landin.Source.Sets.Source_Set;
         Names   : Landin.Source.Names.Table;
         Stream  : Landin.Tokens.Token_Stream;
      begin
         Lex_Text ("a+b", Sources, Names, Stream);
         Landin.Testing.Check
           (Item, Landin.Tokens.Space_Count (Stream) = 0
            and then Landin.Tokens.Leading (Stream, 2).Last
                     < Landin.Tokens.Leading (Stream, 2).First
            and then Landin.Tokens.Leading (Stream, 4).Last
                     < Landin.Tokens.Leading (Stream, 4).First,
            "tokens that touch are led by nothing");
      end;

      --  The check itself has to refuse a stream that is not the file, or
      --  every use of it above proves nothing.
      declare
         Sources : Landin.Source.Sets.Source_Set;
         Names   : Landin.Source.Names.Table;
         Stream  : Landin.Tokens.Token_Stream;
      begin
         Lex_Text ("a -- b" & LF, Sources, Names, Stream);
         Landin.Testing.Check
           (Item, Landin.Testing.Layout.Problem ("a -- b" & LF & LF, Stream)
                  /= ""
            and then Landin.Testing.Layout.Problem ("a    b" & LF, Stream)
                     /= ""
            and then Landin.Testing.Layout.Problem ("ab-- b" & LF, Stream)
                     /= "",
            "a stream is not taken for a file it was not read from");
      end;
   end Space_Is_Kept;

   --  Every Landin source in the repository, read as bytes and written back
   --  from its tokens and its space.  Deliberate real-host exception: the
   --  files on disk are what is under test, faulty ones included, since the
   --  scan never fails and every byte of a refused file is still a token or
   --  a piece.  The build tree holds copies the suites wrote and is not
   --  walked, and neither is anything whose name starts with a dot.
   procedure Every_Source_Is_Reproduced
     (Item : in out Landin.Testing.Context);

   procedure Every_Source_Is_Reproduced
     (Item : in out Landin.Testing.Context)
   is
      Host     : Landin.Platform.Native.Native_Filesystem;
      Root     : constant String := "../..";
      Build    : constant String := Root & "/compiler/ada/build";
      Files    : Natural := 0;
      Faulty   : Natural := 0;
      Pieces   : Natural := 0;
      Unclosed : Natural := 0;

      --  Files whose shape the corpus holds once or twice, named so that
      --  deleting one fails here instead of shrinking what this proves.
      Named : constant Landin.Platform.Path_List :=
        ["/positive/line-ends-mixed/program.ldn",
         "/positive/line-ends-lone-cr/program.ldn",
         "/positive/line-ends-crlf/program.ldn",
         "/positive/no-final-line-end/program.ldn",
         "/positive/comment-forms/program.ldn",
         "/positive/space-forms/program.ldn",
         "/negative/latin1-byte-in-name/program.ldn",
         "/negative/unclosed-block-comment/program.ldn"];
      Seen : array (1 .. Natural (Named.Length)) of Boolean :=
        [others => False];

      function Ends_With (Text, Suffix : String) return Boolean
        is (Text'Length >= Suffix'Length
            and then Text (Text'Last - Suffix'Length + 1 .. Text'Last)
                     = Suffix);

      procedure Walk (Directory : String);

      procedure Walk (Directory : String) is
         Entries : Landin.Platform.Path_List;
         Status  : Landin.Platform.List_Status;
      begin
         Host.List_Directory (Directory, Entries, Status);
         if Status /= Landin.Platform.List_Ok then
            Landin.Testing.Fail (Item, Directory & " cannot be listed");
            return;
         end if;

         for Name of Entries loop
            declare
               Path : constant String := Directory & "/" & Name;
            begin
               if Name'Length = 0 or else Name (Name'First) = '.'
                 or else Path = Build
               then
                  null;
               elsif Host.Is_Directory (Path) then
                  Walk (Path);
               elsif Ends_With (Name, ".ldn") then
                  declare
                     Content : Unbounded.Unbounded_String;
                     Read    : Landin.Platform.Read_Status;
                  begin
                     Host.Read_File (Path, Content, Read);
                     if Read /= Landin.Platform.Read_Ok then
                        Landin.Testing.Fail (Item, Path & " is unreadable");
                     else
                        declare
                           Text    : constant String :=
                             Unbounded.To_String (Content);
                           Sources : Landin.Source.Sets.Source_Set;
                           Names   : Landin.Source.Names.Table;
                           Stream  : Landin.Tokens.Token_Stream;
                           Problem : Unbounded.Unbounded_String;
                        begin
                           Lex_Text (Text, Sources, Names, Stream);
                           Problem := Unbounded.To_Unbounded_String
                             (Landin.Testing.Layout.Problem (Text, Stream));
                           if Unbounded.Length (Problem) > 0 then
                              Landin.Testing.Fail
                                (Item, Path & ": "
                                 & Unbounded.To_String (Problem));
                           end if;

                           Files := Files + 1;
                           Pieces := Pieces
                             + Landin.Tokens.Space_Count (Stream);
                           if Landin.Tokens.Fault_Count (Stream) > 0 then
                              Faulty := Faulty + 1;
                           end if;
                           for Index in 1 .. Landin.Tokens.Fault_Count
                                               (Stream)
                           loop
                              if Landin.Tokens.Kind
                                   (Landin.Tokens.Nth_Fault (Stream, Index))
                                 = Landin.Tokens.Unterminated_Block_Comment
                              then
                                 Unclosed := Unclosed + 1;
                              end if;
                           end loop;
                           for Index in Seen'Range loop
                              if Ends_With (Path, Named (Index)) then
                                 Seen (Index) := True;
                              end if;
                           end loop;
                        end;
                     end if;
                  end;
               end if;
            end;
         end loop;
      end Walk;
   begin
      Walk (Root);

      Landin.Testing.Check
        (Item, Files >= 2_000,
         "every Landin source in the repository was read, and"
         & Files'Image & " were");
      Landin.Testing.Check
        (Item, Faulty > 0 and then Unclosed > 0,
         "sources that fail to scan are among them");
      Landin.Testing.Check
        (Item, Pieces > Files,
         "and the space they hold was kept");
      for Index in Seen'Range loop
         Landin.Testing.Check
           (Item, Seen (Index), Named (Index) & " was among them");
      end loop;
   end Every_Source_Is_Reproduced;

   --  The stream ends with the syntax stage's loop, and what it kept has to
   --  be in the compilation afterwards, source by source, under the
   --  identity the forest uses: the same pieces, in the same order, and
   --  found by extent.  In-memory sources; no host.
   procedure A_Compilation_Keeps_Its_Space
     (Item : in out Landin.Testing.Context);

   procedure A_Compilation_Keeps_Its_Space
     (Item : in out Landin.Testing.Context)
   is
      CR : constant Character := Character'Val (13);

      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Texts : constant array (1 .. 3) of Unbounded.Unbounded_String :=
        [Unbounded.To_Unbounded_String
           ("--- the answer" & LF & "answer: u32 = 42 -- kept" & LF),
         Unbounded.To_Unbounded_String
           ("--( a block" & CR & LF & "comment )--" & CR & LF
            & "other: u8 = 1"),
         Unbounded.To_Unbounded_String ("")];
      Ids : array (Texts'Range) of Landin.Source.Source_Id;
      Ran : Natural;
   begin
      for Index in Texts'Range loop
         Ids (Index) := Landin.Stages.Add_Source
           (Work, "space" & Index'Image (2 .. 2) & ".ldn",
            Unbounded.To_String (Texts (Index)));
      end loop;
      Landin.Stages.Append (Order, Frontend'Access);
      Ran := Landin.Stages.Run (Order, Work);
      Landin.Testing.Check
        (Item, Ran = 1 and then not Landin.Stages.Failed (Work),
         "the sources scan and parse cleanly");

      declare
         Kept : constant not null access Landin.Tokens.Spacing.Table :=
           Landin.Stages.Spacing (Work);
      begin
         Landin.Testing.Check_Equal
           (Item, Kept.Count, Texts'Length,
            "one row of space per source");

         for Index in Texts'Range loop
            declare
               Text    : constant String :=
                 Unbounded.To_String (Texts (Index));
               Sources : Landin.Source.Sets.Source_Set;
               Names   : Landin.Source.Names.Table;
               Stream  : Landin.Tokens.Token_Stream;
               Same    : Boolean;
            begin
               Lex_Text (Text, Sources, Names, Stream);
               Same := Kept.Space_Count (Ids (Index))
                 = Landin.Tokens.Space_Count (Stream);
               if Same then
                  for Piece in 1 .. Landin.Tokens.Space_Count (Stream) loop
                     if Kept.Nth_Space (Ids (Index), Piece)
                       /= Landin.Tokens.Nth_Space (Stream, Piece)
                     then
                        Same := False;
                     end if;
                  end loop;
               end if;
               Landin.Testing.Check
                 (Item, Same,
                  "source" & Index'Image
                  & " keeps the pieces its stream had");
            end;
         end loop;

         --  Found by extent: everything in the first source's first line,
         --  which is its doc comment, and nothing that starts before an
         --  extent or ends after it.
         declare
            Doc : constant Landin.Tokens.Space_Range :=
              Kept.Within (Ids (1), (First => 0, Last => 14));
            Declaration : constant Landin.Tokens.Space_Range :=
              Kept.Within (Ids (1), (First => 15, Last => 31));
            Straddling : constant Landin.Tokens.Space_Range :=
              Kept.Within (Ids (1), (First => 5, Last => 20));
         begin
            Landin.Testing.Check
              (Item, Doc.First = 1 and then Doc.Last = 1
               and then Landin.Tokens.Kind (Kept.Nth_Space (Ids (1), 1))
                        = Landin.Tokens.Doc_Comment,
               "the doc comment is the one piece in its own extent");
            Landin.Testing.Check
              (Item, Declaration.First = 3 and then Declaration.Last = 5,
               "a declaration's extent holds the blanks between its tokens");
            Landin.Testing.Check
              (Item, Straddling.First = 2 and then Straddling.Last = 2,
               "and a piece is within an extent only if wholly inside it");
         end;
      end;
   end A_Compilation_Keeps_Its_Space;

   ------------------------------------------------------------------
   --  The agreement
   ------------------------------------------------------------------

   procedure Agrees_With_The_Corpus (Item : in out Landin.Testing.Context);

   procedure Agrees_With_The_Corpus (Item : in out Landin.Testing.Context) is
      Host    : Landin.Platform.Native.Native_Filesystem;
      Dump    : Unbounded.Unbounded_String;
      Status  : Landin.Platform.Read_Status;
      Files   : Natural := 0;
      Checked : Natural := 0;
      Refused : Natural := 0;
   begin
      Host.Read_File (Corpus & "/lexical.tokens", Dump, Status);

      if Status /= Landin.Platform.Read_Ok then
         Landin.Testing.Fail
           (Item, "compiler/tests/lexical.tokens is unreadable; "
                  & "regenerate it with python3 check.py --tokens");
         return;
      end if;

      declare
         Text  : constant String := Unbounded.To_String (Dump);
         First : Natural := Text'First;

         Sources : Landin.Source.Sets.Source_Set;
         Names   : Landin.Source.Names.Table;
         Stream  : Landin.Tokens.Token_Stream;
         Index   : Landin.Tokens.Token_Index := 1;
         Live    : Boolean := False;
         Label   : Unbounded.Unbounded_String;
      begin
         for Scan in Text'Range loop
            if Text (Scan) = LF then
               declare
                  Line : constant String := Text (First .. Scan - 1);
               begin
                  First := Scan + 1;

                  if Line'Length = 0 or else Line (Line'First) = '#' then
                     null;

                  elsif Line'Length > 5
                    and then Line (Line'First .. Line'First + 4) = "file "
                  then
                     declare
                        Rest : constant String :=
                          Line (Line'First + 5 .. Line'Last);
                        Gap  : constant Natural :=
                          Ada.Strings.Fixed.Index (Rest, " ");
                        Name : constant String :=
                          Rest (Rest'First .. Gap - 1);
                        Kind : constant String :=
                          Rest (Gap + 1 .. Rest'Last);
                        Body_Text : Unbounded.Unbounded_String;
                        Read : Landin.Platform.Read_Status;
                     begin
                        Files := Files + 1;
                        Label := Unbounded.To_Unbounded_String (Name);
                        Live := Kind'Length > 6
                          and then Kind (Kind'First .. Kind'First + 5)
                                   = "tokens";

                        --  A file check.py refused is one its tokeniser
                        --  stopped at.  This scanner never stops, so the
                        --  agreement there is weaker but not absent: it
                        --  must have found a fault where the other found
                        --  one, or the two disagree about the file being
                        --  ill-formed at all.
                        if not Live then
                           Host.Read_File
                             (Corpus & "/fixtures/" & Name, Body_Text, Read);
                           if Read = Landin.Platform.Read_Ok then
                              Lex_Text (Unbounded.To_String (Body_Text),
                                        Sources, Names, Stream);
                              Refused := Refused + 1;
                              if Landin.Tokens.Fault_Count (Stream) = 0 then
                                 Landin.Testing.Fail
                                   (Item, Name & ": check.py refused this "
                                    & "and the scanner found no fault");
                              end if;
                           end if;
                        end if;

                        if Live then
                           Host.Read_File
                             (Corpus & "/fixtures/" & Name, Body_Text, Read);
                           if Read /= Landin.Platform.Read_Ok then
                              Landin.Testing.Fail
                                (Item, Name & " is unreadable");
                              Live := False;
                           else
                              Lex_Text (Unbounded.To_String (Body_Text),
                                        Sources, Names, Stream);
                              Index := 1;
                           end if;
                        end if;
                     end;

                  elsif Live and then Line (Line'First) = ' ' then
                     declare
                        Body_Line : constant String :=
                          Ada.Strings.Fixed.Trim
                            (Line, Ada.Strings.Both);
                        One : constant Natural :=
                          Ada.Strings.Fixed.Index (Body_Line, " ");
                        Two : constant Natural :=
                          Ada.Strings.Fixed.Index
                            (Body_Line (One + 1 .. Body_Line'Last), " ");
                        Want_First : constant Landin.Source.Byte_Offset :=
                          Landin.Source.Byte_Offset'Value
                            (Body_Line (Body_Line'First .. One - 1));
                        Want_Last : constant Landin.Source.Byte_Offset :=
                          Landin.Source.Byte_Offset'Value
                            (Body_Line (One + 1 .. Two - 1));
                     begin
                        Checked := Checked + 1;

                        if Index > Landin.Tokens.Count (Stream) then
                           Landin.Testing.Fail
                             (Item, Unbounded.To_String (Label)
                              & ": the scanner ran out of tokens");
                        else
                           declare
                              Got : constant Landin.Source.Span :=
                                Landin.Tokens.Where (Stream, Index);
                           begin
                              if Got.First /= Want_First
                                or else Got.Last /= Want_Last
                              then
                                 Landin.Testing.Fail
                                   (Item, Unbounded.To_String (Label)
                                    & ": token" & Landin.Tokens.Token_Index'
                                        Image (Index)
                                    & " spans"
                                    & Landin.Source.Byte_Offset'Image
                                        (Got.First)
                                    & " .."
                                    & Landin.Source.Byte_Offset'Image
                                        (Got.Last)
                                    & " and the dump says"
                                    & Landin.Source.Byte_Offset'Image
                                        (Want_First)
                                    & " .."
                                    & Landin.Source.Byte_Offset'Image
                                        (Want_Last));
                              end if;
                           end;
                           Index := Index + 1;
                        end if;
                     end;
                  end if;
               end;
            end if;
         end loop;

         Landin.Testing.Check
           (Item, Files >= 60,
            "the dump names the whole corpus");
         Landin.Testing.Check
           (Item, Checked >= 900,
            "and the scanner was held to every token in it");
         Landin.Testing.Check
           (Item, Refused >= 5,
            "and to finding a fault in every file the other refused");
      end;
   end Agrees_With_The_Corpus;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "lexer", "raw delimiters use the maximal opener",
         Raw_Delimiters_Use_The_Maximal_Opener'Access);
      Landin.Testing.Register
        (Into, "lexer", "float digit runs have both boundaries",
         Float_Digit_Runs_Have_Both_Boundaries'Access);
      Landin.Testing.Register
        (Into, "lexer", "numbers run to the end of their spelling",
         Numbers_Run_To_The_End_Of_Their_Spelling'Access);
      Landin.Testing.Register
        (Into, "lexer", "kinds and spans", Kinds_And_Spans'Access);
      Landin.Testing.Register
        (Into, "lexer", "longest token wins", Longest_Token_Wins'Access);
      Landin.Testing.Register
        (Into, "lexer", "comments are space", Comments_Are_Space'Access);
      Landin.Testing.Register
        (Into, "lexer", "comments require UTF-8",
         Comments_Require_UTF8'Access);
      Landin.Testing.Register
        (Into, "lexer", "literals and refusals",
         Literals_And_Refusals'Access);
      Landin.Testing.Register
        (Into, "lexer", "text literal decoding",
         Text_Literal_Decoding'Access);
      Landin.Testing.Register
        (Into, "lexer", "character literal decoding",
         Character_Literal_Decoding'Access);
      Landin.Testing.Register
        (Into, "lexer", "raw literal decoding",
         Raw_Literal_Decoding'Access);
      Landin.Testing.Register
        (Into, "lexer", "unknown bytes recover",
         Unknown_Bytes_Recover'Access);
      Landin.Testing.Register
        (Into, "lexer", "uppercase faults keep byte boundaries",
         Uppercase_Faults_Keep_Byte_Boundaries'Access);
      Landin.Testing.Register
        (Into, "lexer", "unterminated literals are faults",
         Unterminated_Literals_Are_Faults'Access);
      Landin.Testing.Register
        (Into, "lexer", "space is kept", Space_Is_Kept'Access);
      Landin.Testing.Register
        (Into, "lexer", "a compilation keeps its space",
         A_Compilation_Keeps_Its_Space'Access);
      Landin.Testing.Register
        (Into, "lexer", "every source is reproduced",
         Every_Source_Is_Reproduced'Access);
      Landin.Testing.Register
        (Into, "lexer", "agrees with the corpus",
         Agrees_With_The_Corpus'Access);
   end Register;

end Landin.Tests.Lexer_Suite;
