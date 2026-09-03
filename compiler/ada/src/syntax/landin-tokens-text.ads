--  D161: the bytes a text literal [0260] spells.  The scanner keeps the
--  lexeme whole and calls this to reject malformed spelling; the checker
--  calls it to distinguish a codepoint escape from its enabled byte
--  context; lowering calls it to lay the bytes down.  All three read this
--  one function so they cannot disagree about an escape.
--
--  The escape set is [0270]'s and closed: `\n \r \t \e \\ \" \'`, `\xNN`
--  with exactly two hex digits, and `\u{...}`.  The last spells a codepoint
--  and is only valid where text is meant; the kernel's only text context is
--  `[]u8`, where bytes are meant, so it is reported rather than encoded.

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
      --  A non-ASCII source-byte run that is not shortest-form UTF-8.
      Invalid_UTF8_Source,
      --  A backslash as the last byte before the closing quote.
      Dangling_Backslash);

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

end Landin.Tokens.Text;
