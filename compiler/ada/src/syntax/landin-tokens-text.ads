--  D161: the bytes a text literal [0260] spells.  The scanner keeps the
--  lexeme whole and calls this to reject malformed spelling; the checker
--  calls it to distinguish a codepoint escape from its enabled byte
--  context; lowering calls it to lay the bytes down.  All three read this
--  one function so they cannot disagree about an escape.
--
--  The escape set is [0270]'s and closed: `\n \r \t \e \\ \" \'`, `\xNN`
--  with exactly two hex digits, and `\u{...}`.  The last spells a codepoint
--  and is only valid where text is meant.  D181 adds UTF-8 and UTF-16 text
--  views while retaining D161's raw-byte context.

package Landin.Tokens.Text is

   type Problem is
     (Well_Formed,
      --  A backslash followed by a byte the set does not name.
      Unknown_Escape,
      --  `\x` without two hex digits after it.
      Short_Byte_Escape,
      --  A `\u` escape without braces, hexadecimal digits, a closing
      --  brace or a Unicode scalar value.
      Malformed_Codepoint_Escape,
      --  `\u{...}` where bytes are meant.
      Codepoint_Where_Bytes_Are_Meant,
      --  `\xNN` where a validated Unicode encoding is meant.
      Byte_Where_Text_Is_Meant,
      --  A character literal has no scalar between its quotes.
      Empty_Character,
      --  A character literal has more than one scalar or escape.
      Multiple_Characters,
      --  `\xNN` in a character literal, whose value is a codepoint rather
      --  than a byte.
      Byte_Where_Codepoint_Is_Meant,
      --  A nonblank raw-literal line does not begin with the exact
      --  indentation of its line-leading closing delimiter.
      Inconsistent_Raw_Indentation,
      --  A non-ASCII source-byte run that is not shortest-form UTF-8.
      Invalid_UTF8_Source,
      --  A backslash as the last byte before the closing quote.
      Dangling_Backslash);

   type Literal_Encoding is (Byte_Units, UTF8_Units, UTF16_Units);

   type Code_Unit is range 0 .. 16#FFFF#;
   type Code_Unit_Array is array (Positive range <>) of Code_Unit;

   --  Lexeme is the whole token, opening and closing quote included.
   --  Bytes receives the decoded content in Bytes (1 .. Length).  On a
   --  problem, Fault_First .. Fault_Last is the half-open offending run as
   --  zero-based offsets into Lexeme, and Length is what was decoded before
   --  it.
   procedure Decode
     (Lexeme      : String;
      Bytes       : out String;
      Length      : out Natural;
      Fault       : out Problem;
      Fault_First : out Natural;
      Fault_Last  : out Natural)
     with Pre  => Lexeme'Length >= 2
                  and then Bytes'Length >= Lexeme'Length,
          Post => Length <= Lexeme'Length;

   --  Decode [0250]'s whole single-quoted token.  Value is the one Unicode
   --  scalar value it spells.  Character literals admit [0270]'s simple
   --  escapes and `\u{...}`, but not the byte-only `\xNN` form.  Fault
   --  offsets have the same convention as Decode's.
   procedure Decode_Character
     (Lexeme      : String;
      Value       : out Natural;
      Fault       : out Problem;
      Fault_First : out Natural;
      Fault_Last  : out Natural)
     with Pre => Lexeme'Length >= 2;

   --  Decode [0280]'s whole raw token.  The matching quote runs are not
   --  content and no escape is interpreted.  When the closing delimiter is
   --  line-leading, its exact horizontal indentation is removed from each
   --  nonblank content line; a blank line's horizontal bytes are discarded.
   --  Source content must remain shortest-form
   --  UTF-8.  Fault offsets and Bytes follow Decode's conventions.
   procedure Decode_Raw
     (Lexeme      : String;
      Bytes       : out String;
      Length      : out Natural;
      Fault       : out Problem;
      Fault_First : out Natural;
      Fault_Last  : out Natural)
     with Pre  => Lexeme'Length >= 6
                  and then Bytes'Length >= Lexeme'Length,
          Post => Length <= Lexeme'Length;

   --  Decode a quoted or raw literal for its contextual representation.
   --  Byte_Units admits `\xNN` and refuses `\u{...}`; both Unicode forms do
   --  the reverse.  UTF8_Units returns encoded bytes as units in 0 .. 255,
   --  while UTF16_Units returns code units and forms surrogate pairs.
   procedure Decode_View
     (Lexeme      : String;
      Raw         : Boolean;
      Encoding    : Literal_Encoding;
      Units       : out Code_Unit_Array;
      Length      : out Natural;
      Fault       : out Problem;
      Fault_First : out Natural;
      Fault_Last  : out Natural)
     with Pre  => Lexeme'Length >= (if Raw then 6 else 2)
                  and then Units'Length >= Lexeme'Length,
          Post => Length <= Lexeme'Length;

end Landin.Tokens.Text;
