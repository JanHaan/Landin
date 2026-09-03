--  The scanner, and the agreement it has to keep.
--
--  The last case reads compiler/tests/lexical.tokens, which check.py wrote
--  from its own tokeniser, and lexes every file it names.  Two
--  implementations of one grammar, compared token for token: a boundary
--  either side gets wrong shows up here, and check.py's own run says which
--  side moved by refusing a stale dump.

with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Landin.Platform.Native;
with Landin.Source.Names;
with Landin.Source.Sets;
with Landin.Source;
with Landin.Tokens.Lexer;
with Landin.Tokens.Text;
with Landin.Tokens;

package body Landin.Tests.Lexer_Suite is

   package Unbounded renames Ada.Strings.Unbounded;

   use type Landin.Platform.Read_Status;
   use type Landin.Source.Byte_Offset;
   use type Landin.Tokens.Token_Kind;
   use type Landin.Tokens.Integer_Base;
   use type Landin.Tokens.Token_Index;
   use type Landin.Tokens.Fault_Kind;
   use type Landin.Tokens.Text.Problem;

   LF : constant Character := Character'Val (10);

   --  Relative to compiler/ada, which is where the harness runs.
   Corpus : constant String := "../tests";

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
         Landin.Testing.Check_Equal
           (Item, Landin.Tokens.Doc_Comment_Count (Doc), 1,
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

   --  [1770] gives each base its own digits, enables text, and [1830]
   --  refuses a float.
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
         "and the digit span skips the prefix, so R1.60 need not");

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
            "a hexadecimal float remains one deferred lexeme");
         Landin.Testing.Check
           (Item,
            Landin.Tokens.Refused (Landin.Tokens.Nth_Fault (Hex_Float, 1))
            = Landin.Tokens.Hex_Float_Literal,
            "and the fault says which construct it was");
         Landin.Testing.Check_Equal
           (Item,
            Landin.Tokens.Construct
              (Landin.Tokens.Hex_Float_Literal), "[0230]",
            "which names the tour construct that describes it");
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

   --  D161 keeps escape decoding shared by checking and lowering.  Exercise
   --  the byte result and the failures that source text cannot conveniently
   --  carry as an invalid UTF-8 file in the repository.
   procedure Text_Literal_Decoding
     (Item : in out Landin.Testing.Context);

   procedure Text_Literal_Decoding
     (Item : in out Landin.Testing.Context)
   is
      Bytes : String (1 .. 32);
      Length : Natural;
      Fault : Landin.Tokens.Text.Problem;
      First, Last : Natural;

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

   --  Every deferred kind has to be reachable.  Declared and never
   --  produced is dead vocabulary, which is the same defect as an
   --  unreachable rule in the grammar.  Text left this table in D161,
   --  character in D163 and raw text in D164 as each became enabled.
   procedure Every_Deferred_Kind_Is_Reachable
     (Item : in out Landin.Testing.Context);

   procedure Every_Deferred_Kind_Is_Reachable
     (Item : in out Landin.Testing.Context)
   is
      Sources : Landin.Source.Sets.Source_Set;
      Names   : Landin.Source.Names.Table;
      Seen    : array (Landin.Tokens.Deferred_Kind) of Boolean :=
        [others => False];

      procedure Note (Text : String);

      procedure Note (Text : String) is
         Stream : Landin.Tokens.Token_Stream;
      begin
         Lex_Text (Text, Sources, Names, Stream);
         for Index in 1 .. Landin.Tokens.Count (Stream) loop
            declare
               Kind : constant Landin.Tokens.Token_Kind :=
                 Landin.Tokens.Kind (Stream, Index);
            begin
               if Kind in Landin.Tokens.Deferred_Kind then
                  Seen (Kind) := True;
               end if;
            end;
         end loop;
      end Note;

   begin
      Note ("f: () -> (r: i32) ! oops = 1 end");   --  Bang
      Note ("a.b");                                --  Dot
      Note ("0..9");                               --  Dot_Dot
      Note ("0..<9");                              --  Dot_Dot_Less
      Note ("try f() ...");                        --  Dot_Dot_Dot
      Note ("xs[0]");                              --  the brackets
      Note ("r: f32 = 0x1.0p0");                  --  Hex_Float_Literal

      for Kind in Landin.Tokens.Deferred_Kind loop
         Landin.Testing.Check
           (Item, Seen (Kind),
            "the scanner produces " & Kind'Image);
      end loop;
   end Every_Deferred_Kind_Is_Reachable;

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
        (Into, "lexer", "kinds and spans", Kinds_And_Spans'Access);
      Landin.Testing.Register
        (Into, "lexer", "longest token wins", Longest_Token_Wins'Access);
      Landin.Testing.Register
        (Into, "lexer", "comments are space", Comments_Are_Space'Access);
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
        (Into, "lexer", "every deferred kind is reachable",
         Every_Deferred_Kind_Is_Reachable'Access);
      Landin.Testing.Register
        (Into, "lexer", "unterminated literals are faults",
         Unterminated_Literals_Are_Faults'Access);
      Landin.Testing.Register
        (Into, "lexer", "agrees with the corpus",
         Agrees_With_The_Corpus'Access);
   end Register;

end Landin.Tests.Lexer_Suite;
