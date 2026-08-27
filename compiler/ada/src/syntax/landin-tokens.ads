--  The vocabulary a Landin program is written in, and the result of reading
--  one file of it.
--
--  `spec.md` [1740]-[1830] is the authority. Its lexical layer says that
--  identifier, keyword and literal each produce one token and that space and
--  comments produce none, and Token_Kind is that division made enumerable:
--  one literal per reserved word, one per sign. A hand-written parser then
--  branches on a value whose coverage the Ada compiler checks.
--
--  Two bands are not the kernel's, and both are tokens on purpose.
--  Deferred_Kind is a lexeme the tour describes and the grammar omits,
--  refused by [1830]: `1.5`, `"text"`, `!` and `+=` are read as one thing
--  each and named, rather than falling apart into signs that happen to be
--  enabled. That also fixes the reading of a program now, because enabling
--  compound assignment later cannot change how a file that never used it was
--  tokenised. Malformed_Kind is a run of bytes no rule spells at all: a
--  parser that recovers needs something standing in the hole, because a hole
--  is not something to resume from.
--
--  Nothing here is a diagnostic. A Fault carries a kind and spans, no code
--  and no prose: R1.30 owns the catalogue and depends on this item, so this
--  item may not pre-empt it. An ill-formed program is data.
--
--  Nothing here asks the host anything. A span is a byte offset into the
--  snapshot it was read from, an integer literal keeps its base and not its
--  value, and how wide that value may be is Landin.Targets' question, asked
--  at R1.60.

private with Ada.Containers.Vectors;

with Landin.Source;
with Landin.Source.Names;

package Landin.Tokens is

   ------------------------------------------------------------------
   --  Kinds
   ------------------------------------------------------------------

   --  A reserved word's letters are written once, here: Spelling derives
   --  the bytes from the enumeration literal's image, so there is no second
   --  keyword list to drift from [1760]. check.py holds this list to the
   --  grammar's own `keyword` production -- never to its own KEYWORDS set,
   --  which is about the whole language and about colour.
   --
   --  Signs are named after their bytes and never after their meaning: `<>`
   --  is Less_Greater and `->` is Minus_Greater, because the grammar decides
   --  that one compares and the other introduces a return, while this
   --  package decides only that each is one token.
   type Token_Kind is
     (End_Of_Input,
      Identifier,
      Integer_Literal,
      --  The twenty-two words [1760] reserves.
      Kw_Alignof, Kw_And, Kw_Dec, Kw_Else, Kw_Elsif, Kw_End, Kw_False,
      Kw_If, Kw_Inc, Kw_Mut, Kw_None, Kw_Not, Kw_Or, Kw_Public,
      Kw_Return, Kw_Sizeof, Kw_Struct, Kw_Then, Kw_True, Kw_Type,
      Kw_When, Kw_Zeroed,
      --  The signs the kernel productions spell.
      Ampersand, Bar, Caret, Colon, Colon_Equal, Comma, Dot, Equal,
      Equal_Equal, Greater, Greater_Equal, Greater_Greater, Left_Bracket,
      Left_Paren, Less, Less_Equal, Less_Greater, Less_Less, Minus,
      Minus_Greater, Minus_Percent, Percent, Plus, Plus_Percent,
      Right_Bracket, Right_Paren, Slash, Star, Star_Percent, Tilde,
      Underscore,
      --  Signs the tour spells and the kernel omits.
      Bang, Dot_Dot, Dot_Dot_Dot, Dot_Dot_Less,
      --  Lexemes with more than one spelling that the kernel omits.
      Compound_Assign, Character_Literal, Float_Literal, Raw_Literal,
      Text_Literal,
      --  Bytes that spell nothing at all.
      Malformed_Integer, Unknown_Bytes);

   --  Everything the kernel grammar can derive. A stream of only these is a
   --  stream the parser may take at face value.
   subtype Kernel_Kind is Token_Kind range End_Of_Input .. Underscore;

   subtype Reserved_Word is Token_Kind range Kw_Alignof .. Kw_Zeroed;

   subtype Punctuation is Token_Kind range Ampersand .. Underscore;

   --  Described by the tour, omitted by the grammar, refused by [1830].
   subtype Deferred_Kind is Token_Kind range Bang .. Text_Literal;

   subtype Malformed_Kind is
     Token_Kind range Malformed_Integer .. Unknown_Bytes;

   --  One spelling each, which is what makes Spelling total here and absent
   --  elsewhere: Compound_Assign covers thirteen spellings [0390], and a
   --  literal has as many as there are programs.
   subtype Spelled_Kind is Token_Kind range Kw_Alignof .. Dot_Dot_Less;

   --  `literal ::= integer | "true" | "false" | "zeroed"` [1770].  The
   --  three words are reserved and literals at once, so this is a predicate
   --  rather than a band of the enumeration.
   function Is_Literal (Of_Kind : Token_Kind) return Boolean
     is (Of_Kind in Integer_Literal | Kw_True | Kw_False | Kw_Zeroed);

   --  The bytes of a kind that has only one spelling.  `alignof` is the
   --  longest, at seven.
   function Spelling (Of_Kind : Spelled_Kind) return String
     with Post => Spelling'Result'Length in 1 .. 7;

   subtype Construct_Reference is String (1 .. 6);

   function Is_Valid_Construct (Text : String) return Boolean
     is (Text'Length = 6
         and then Text (Text'First) = '['
         and then Text (Text'Last) = ']'
         and then (for all Index in Text'First + 1 .. Text'Last - 1 =>
                     Text (Index) in '0' .. '9'));

   --  Which construct in the tour a refused lexeme belongs to, so a
   --  diagnostic can name it rather than call it a syntax error [1830].
   --  Which roadmap item enables it is not answered here: ROADMAP.md is the
   --  authority for that, and R1.30's catalogue is where it is read.
   function Construct (Of_Kind : Deferred_Kind) return Construct_Reference
     with Post => Is_Valid_Construct (Construct'Result);

   --  A set of kinds, for the one operation that scans a stream forward.
   type Kind_Set is array (Token_Kind) of Boolean with Pack;

   ------------------------------------------------------------------
   --  Tokens
   ------------------------------------------------------------------

   --  Private, with no constructor in this part at all. A token can only be
   --  built by the one unit that reads bytes, and Ada says so with a child
   --  unit rather than with a comment asking politely.
   type Token is private;

   function Kind (Item : Token) return Token_Kind;

   --  Byte offsets into the snapshot the stream was read from, half open
   --  like every other span: this is what a diagnostic points at and what
   --  debug information will carry.
   function Where (Item : Token) return Landin.Source.Span;

   --  Identity, not bytes. The parser compares the name after `end` with
   --  the one before `:` [1800] by comparing two of these.
   function Name (Item : Token) return Landin.Source.Names.Name_Id
     with Pre => Kind (Item) = Identifier;

   --  The four bases of [1770], named after the rules that spell them.
   type Integer_Base is (Binary, Decimal, Hexadecimal, Octal);

   function Base (Item : Token) return Integer_Base
     with Pre => Kind (Item) = Integer_Literal;

   --  The digits and separators without the `0x`, `0o` or `0b`, so that
   --  whoever converts the value at R1.60 need not know a base prefix is
   --  two bytes long. The value is not computed here: an integer literal is
   --  untyped [0190], and what it must fit in is not known until its
   --  context is.
   function Digit_Span (Item : Token) return Landin.Source.Span
     with Pre => Kind (Item) = Integer_Literal;

   ------------------------------------------------------------------
   --  Faults
   ------------------------------------------------------------------

   type Fault_Kind is
     (Malformed_Integer_Run,
      Not_Enabled,
      Unknown_Byte_Run,
      Unterminated_Block_Comment,
      Unterminated_Literal);

   subtype Unterminated_Fault is Fault_Kind
     range Unterminated_Block_Comment .. Unterminated_Literal;

   type Fault is private;

   function Kind (Item : Fault) return Fault_Kind;

   function Where (Item : Fault) return Landin.Source.Span;

   --  Where the thing that was never closed was opened. A block comment
   --  nests [1780], so this is the outermost opener while Where is the end
   --  of the file: those are the two places a reader looks.
   function Opened_At (Item : Fault) return Landin.Source.Span
     with Pre => Kind (Item) in Unterminated_Fault;

   --  Which construct was refused. An unterminated literal is refused as
   --  well as unclosed, so both kinds carry it.
   function Refused (Item : Fault) return Deferred_Kind
     with Pre => Kind (Item) in Not_Enabled | Unterminated_Literal;

   ------------------------------------------------------------------
   --  Streams
   ------------------------------------------------------------------

   type Token_Index is range 1 .. Integer'Last;

   --  The whole file, read. Limited, so a stage cannot copy one out from
   --  under the compilation that owns it.
   --
   --  Two invariants hold by construction rather than by assertion: the
   --  last token is End_Of_Input and nothing follows it, so a forward scan
   --  needs no index test; and every span lies inside the snapshot named by
   --  Source_Of, so a caller can resolve any of them against that file.
   type Token_Stream is limited private;

   function Source_Of (Of_Stream : Token_Stream)
     return Landin.Source.Source_Id;

   function Count (Of_Stream : Token_Stream) return Token_Index;

   function Kind (Of_Stream : Token_Stream; At_Index : Token_Index)
     return Token_Kind
     with Pre => At_Index <= Count (Of_Stream);

   function Token_At (Of_Stream : Token_Stream; At_Index : Token_Index)
     return Token
     with Pre => At_Index <= Count (Of_Stream);

   function Where (Of_Stream : Token_Stream; At_Index : Token_Index)
     return Landin.Source.Span
     with Pre => At_Index <= Count (Of_Stream);

   --  The first index at or after From whose kind is wanted. This is the
   --  operation the design is for: recovery is a forward scan, and the
   --  precondition that End_Of_Input is wanted is the proof it stops.
   function Skip_To
     (Of_Stream : Token_Stream;
      From      : Token_Index;
      Wanted    : Kind_Set) return Token_Index
     with Pre  => From <= Count (Of_Stream)
                  and then Wanted (End_Of_Input),
          Post => Skip_To'Result in From .. Count (Of_Stream)
                  and then Wanted (Kind (Of_Stream, Skip_To'Result));

   function Fault_Count (Of_Stream : Token_Stream) return Natural;

   --  In nondecreasing span order, because the scan produced them left to
   --  right. Reporting order is still Landin.Diagnostics' to decide.
   function Nth_Fault (Of_Stream : Token_Stream; Index : Positive)
     return Fault
     with Pre => Index <= Fault_Count (Of_Stream);

   --  A comment is space and produces no token [1750], so a doc comment
   --  cannot be one. Its span is kept anyway, because [0030] attaches it to
   --  the declaration that follows and only the parser knows what that is.
   function Doc_Comment_Count (Of_Stream : Token_Stream) return Natural;

   function Nth_Doc_Comment (Of_Stream : Token_Stream; Index : Positive)
     return Landin.Source.Span
     with Pre => Index <= Doc_Comment_Count (Of_Stream);

private

   type Token is record
      Kind    : Token_Kind := End_Of_Input;
      Where   : Landin.Source.Span := Landin.Source.Empty_Span;
      Name    : Landin.Source.Names.Name_Id :=
        Landin.Source.Names.No_Name;
      Base    : Integer_Base := Decimal;
      Digit_Run : Landin.Source.Span := Landin.Source.Empty_Span;
   end record;

   type Fault is record
      Kind    : Fault_Kind := Unknown_Byte_Run;
      Where   : Landin.Source.Span := Landin.Source.Empty_Span;
      Opened  : Landin.Source.Span := Landin.Source.Empty_Span;
      Refused : Token_Kind := Bang;
   end record;

   package Token_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Token);

   package Fault_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Fault);

   package Span_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Landin.Source.Span,
      "="          => Landin.Source."=");

   type Token_Stream is limited record
      Source  : Landin.Source.Source_Id := Landin.Source.No_Source;
      Items   : Token_Vectors.Vector;
      Faults  : Fault_Vectors.Vector;
      Docs    : Span_Vectors.Vector;
   end record;

end Landin.Tokens;
