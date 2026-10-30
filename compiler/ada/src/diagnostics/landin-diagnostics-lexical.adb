with Ada.Characters.Handling;

with Landin.Tokens.Lexer;

package body Landin.Diagnostics.Lexical is

   package Rows renames Landin.Diagnostics.Catalogue;

   use type Landin.Source.Byte_Offset;
   use type Landin.Tokens.Fault_Kind;

   --  The sentence a user reads.  Prose lives where a diagnostic is
   --  raised, never in the catalogue: one rule can be violated in two ways
   --  worth wording differently, and splitting a code for a wording reason
   --  is the worst reason to spend a stable identifier.
   function Sentence (Fault : Landin.Tokens.Fault) return String;

   function Sentence (Fault : Landin.Tokens.Fault) return String
     is (case Landin.Tokens.Kind (Fault) is
            when Landin.Tokens.Malformed_Integer_Run =>
               "this is not an integer any base spells",
            when Landin.Tokens.Malformed_Float_Literal_Run =>
               "this is not a well-formed floating-point literal",
            when Landin.Tokens.Malformed_Character_Literal_Run =>
               "this character literal does not spell one codepoint",
            when Landin.Tokens.Malformed_Raw_Literal_Run =>
               "this raw literal has invalid source bytes or indentation",
            when Landin.Tokens.Malformed_Text_Literal_Run =>
               "this text literal contains malformed bytes or an escape",
            when Landin.Tokens.Invalid_Comment_Encoding =>
               "this comment contains malformed UTF-8",
            when Landin.Tokens.Unknown_Byte_Run =>
               "no rule spells these bytes",
            when Landin.Tokens.Capitalised_Identifier =>
               "identifiers use lower-case letters",
            when Landin.Tokens.Unterminated_Block_Comment =>
               "this block comment is never closed",
            when Landin.Tokens.Unterminated_Literal =>
               "this literal is never closed");

   function Code_For (Fault : Landin.Tokens.Fault_Kind)
     return Rows.Code_Name
     is (case Fault is
            when Landin.Tokens.Malformed_Integer_Run      =>
               Rows.Malformed_Integer,
            when Landin.Tokens.Malformed_Float_Literal_Run =>
               Rows.Malformed_Float_Literal,
            when Landin.Tokens.Malformed_Character_Literal_Run =>
               Rows.Malformed_Character_Literal,
            when Landin.Tokens.Malformed_Raw_Literal_Run =>
               Rows.Malformed_Raw_Literal,
            when Landin.Tokens.Malformed_Text_Literal_Run =>
               Rows.Malformed_Text_Literal,
            when Landin.Tokens.Unknown_Byte_Run
               | Landin.Tokens.Capitalised_Identifier
               | Landin.Tokens.Invalid_Comment_Encoding =>
               Rows.Unknown_Bytes,
            when Landin.Tokens.Unterminated_Block_Comment =>
               Rows.Unterminated_Comment,
            when Landin.Tokens.Unterminated_Literal       =>
               Rows.Unterminated_Literal);

   --  The row this code carries is checked against the diagnostic just
   --  built, and only then is it appended.  A code whose occurrences do not
   --  carry what it promises is worse than no code at all.
   procedure Deliver
     (Named  : Rows.Code_Name;
      Report : Diagnostic;
      Where  : Landin.Source.Span;
      Into   : in out Diagnostic_List);

   procedure Deliver
     (Named  : Rows.Code_Name;
      Report : Diagnostic;
      Where  : Landin.Source.Span;
      Into   : in out Diagnostic_List)
   is
      Text : constant Code_String := Rows.Code (Named);
   begin
      if Rows.Required_Notes (Named) /= Note_Count (Report)
        or else Label_Count (Report) < Rows.Minimum_Secondaries (Named)
        or else Label_Count (Report) > Rows.Maximum_Secondaries (Named)
      then
         raise Compiler_Defect
           with "the catalogue row for " & Text
                & " and the diagnostic built for it disagree";
      end if;

      if Rows.Needs_Non_Empty_Span (Named)
        and then Landin.Source.Length (Where) = 0
      then
         raise Compiler_Defect
           with Text & " requires a span with bytes in it";
      end if;

      Append (Into, Report);
   end Deliver;

   procedure Report
     (Stream : Landin.Tokens.Token_Stream;
      Into   : in out Diagnostic_List)
   is
      Source : constant Landin.Source.Source_Id :=
        Landin.Tokens.Source_Of (Stream);
   begin
      for Index in 1 .. Landin.Tokens.Fault_Count (Stream) loop
         declare
            Fault : constant Landin.Tokens.Fault :=
              Landin.Tokens.Nth_Fault (Stream, Index);
            Kind  : constant Landin.Tokens.Fault_Kind :=
              Landin.Tokens.Kind (Fault);
            Named : constant Rows.Code_Name := Code_For (Kind);
            Where : constant Landin.Source.Span :=
              Landin.Tokens.Where (Fault);
            Report : Diagnostic :=
              Make (Code    => Rows.Code (Named),
                    Level   => Rows.Level (Named),
                    Source  => Source,
                    Where   => Where,
                    Message => Sentence (Fault));
         begin
            case Kind is
               when Landin.Tokens.Unterminated_Literal =>
                  Add_Label
                    (Report,
                     Make_Label (Source,
                                 Landin.Tokens.Opened_At (Fault),
                                 "opened here"));

               when Landin.Tokens.Unterminated_Block_Comment =>
                  Add_Label
                    (Report,
                     Make_Label (Source,
                                 Landin.Tokens.Opened_At (Fault),
                                 "opened here and never closed"));

               when Landin.Tokens.Malformed_Integer_Run =>
                  Add_Note
                    (Report,
                     "use digits of the selected base and underscores; start"
                     & " and end the digit run with a digit [1770]");

               when Landin.Tokens.Malformed_Float_Literal_Run =>
                  Add_Note
                    (Report,
                     "a float has digits on both sides of its dot and a"
                     & " complete exponent when one is required, and no"
                     & " name runs straight into it"
                     & " [0210] [0220] [0230] [1770]");

               when Landin.Tokens.Malformed_Character_Literal_Run =>
                  Add_Note
                    (Report,
                     "write one source scalar, a simple escape, or"
                     & " `\\u{...}` [0250] [0270]");

               when Landin.Tokens.Malformed_Raw_Literal_Run =>
                  Add_Note
                    (Report,
                     "use matching quote counts and the exact indentation"
                     & " of a line-leading closer [0280]");

               when Landin.Tokens.Malformed_Text_Literal_Run =>
                  Add_Note
                    (Report,
                     "the escapes are `\n`, `\r`, `\t`, `\e`, `\\`, `\""`,"
                     & " `\'`, `\xNN` and `\u{...}`, and no others [0270]");

               when Landin.Tokens.Invalid_Comment_Encoding =>
                  Add_Note
                    (Report,
                     "[1750]: comment text must be shortest-form UTF-8");

               when Landin.Tokens.Unknown_Byte_Run =>
                  Add_Note
                    (Report,
                     "no rule of the grammar spells these bytes [1750]");

               when Landin.Tokens.Capitalised_Identifier =>
                  --  D528: Report_Word words it once the parse has said
                  --  what the word names.
                  null;
            end case;

            if Kind /= Landin.Tokens.Capitalised_Identifier then
               Deliver (Named, Report, Where, Into);
            end if;
         end;
      end loop;
   end Report;

   function Lower_Spelling (Word : String) return String is
      function Upper (At_Byte : Integer) return Boolean
        is (At_Byte in Word'Range and then Word (At_Byte) in 'A' .. 'Z');

      function Lower_Or_Digit (At_Byte : Integer) return Boolean
        is (At_Byte in Word'Range
            and then Word (At_Byte) in 'a' .. 'z' | '0' .. '9');

      function Lower (At_Byte : Integer) return Boolean
        is (At_Byte in Word'Range and then Word (At_Byte) in 'a' .. 'z');

      Result : String (1 .. 2 * Word'Length);
      Length : Natural := 0;
   begin
      for At_Byte in Word'Range loop
         --  A capital begins a part after a lower-case letter or a digit,
         --  `initWindow`, and as the last of a run of capitals that a
         --  lower-case letter follows, `HTTPServer`.
         if Upper (At_Byte)
           and then (Lower_Or_Digit (At_Byte - 1)
                     or else (Upper (At_Byte - 1)
                              and then Lower (At_Byte + 1)))
         then
            Length := Length + 1;
            Result (Length) := '_';
         end if;
         Length := Length + 1;
         Result (Length) := Ada.Characters.Handling.To_Lower (Word (At_Byte));
      end loop;
      return Result (1 .. Length);
   end Lower_Spelling;

   procedure Report_Word
     (Source   : Landin.Source.Source_Id;
      Fault    : Landin.Tokens.Fault;
      Spelling : String;
      C_Name   : Boolean;
      Into     : in out Diagnostic_List)
   is
      Named  : constant Rows.Code_Name :=
        Code_For (Landin.Tokens.Capitalised_Identifier);
      Where  : constant Landin.Source.Span := Landin.Tokens.Where (Fault);
      Lower  : constant String := Lower_Spelling (Spelling);
      Taken  : constant Boolean := Landin.Tokens.Lexer.Is_Reserved (Lower);
      Report : Diagnostic :=
        Make (Code    => Rows.Code (Named),
              Level   => Rows.Level (Named),
              Source  => Source,
              Where   => Where,
              Message => Sentence (Fault));
   begin
      if C_Name then
         --  [1610]: C's symbol keeps C's spelling in the annotation and the
         --  routine takes a Landin name of the program's own.
         Add_Note
           (Report,
            "[1610]: a C function Landin cannot spell is linked by its"
            & " symbol under a lower-case name: `extern(c) link(symbol: """
            & Spelling & """) "
            & (if Taken
               then "NAME: ...`, where `" & Lower & "` is reserved"
               else Lower & ": ...`, called as `" & Lower & "`"));
      else
         Add_Note
           (Report,
            "[1760]: identifier letters are lower-case ASCII"
            & (if Taken then ", and `" & Lower & "` is reserved"
               else "; write `" & Lower & "`"));
      end if;
      Deliver (Named, Report, Where, Into);
   end Report_Word;

end Landin.Diagnostics.Lexical;
