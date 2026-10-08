--  The layout, and what it must never do.
--
--  D252 says what `refine fmt` decides and `docs/format.md` shows each rule;
--  these cases hold Landin.Formatting to both.  The rules are the page's
--  pairs, read from the page so it cannot drift from what the formatter
--  does.  The edges are the bytes no example shows.  The corpus case is
--  the item's evidence: every Landin source that scans and parses is
--  formatted into the same tokens and comments, and formatting the result
--  again offers nothing.  Sources that fail to scan or parse are refused
--  whole.  The last case is what the gate holds: `core`, the examples and
--  the running examples are formatted already.

with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Landin.Diagnostics;
with Landin.Diagnostics.Lexical;
with Landin.Formatting;
with Landin.Platform.Native;
with Landin.Source.Names;
with Landin.Source.Sets;
with Landin.Source;
with Landin.Syntax.Parser;
with Landin.Syntax;
with Landin.Tokens.Lexer;
with Landin.Tokens;

package body Landin.Tests.Formatting_Suite is

   package Unbounded renames Ada.Strings.Unbounded;

   use type Landin.Formatting.Verdict;
   use type Landin.Platform.List_Status;
   use type Landin.Platform.Read_Status;
   use type Landin.Source.Byte_Offset;
   use type Landin.Tokens.Space_Kind;

   LF  : constant Character := Character'Val (10);
   CR  : constant Character := Character'Val (13);
   Tab : constant Character := Character'Val (9);

   --  Relative to compiler/ada, which is where the harness runs.
   Root : constant String := "../..";

   function Format (Text : String) return Landin.Formatting.Result;

   function Format (Text : String) return Landin.Formatting.Result is
      Sources : Landin.Source.Sets.Source_Set;
   begin
      return Landin.Formatting.Format (Sources, "probe.ldn", Text);
   end Format;

   --  What the scan makes of Text, as one line per token and comment:
   --  the kind and the bytes.  Two texts with the same answer say the
   --  same thing and differ, if at all, in space.
   function Things (Text : String) return String;

   function Things (Text : String) return String is
      Sources : Landin.Source.Sets.Source_Set;
      Names   : Landin.Source.Names.Table;
      Stream  : Landin.Tokens.Token_Stream;
      Result  : Unbounded.Unbounded_String;
      Bytes   : constant String (1 .. Text'Length) := Text;

      function Slice (Where : Landin.Source.Span) return String
        is (Bytes (Natural (Where.First) + 1 .. Natural (Where.Last)));
   begin
      Landin.Tokens.Lexer.Lex
        (Sources.Get (Sources.Add ("probe.ldn", Text)), Names, Stream);
      for Index in 1 .. Landin.Tokens.Count (Stream) loop
         declare
            Leading : constant Landin.Tokens.Space_Range :=
              Landin.Tokens.Leading (Stream, Index);
         begin
            for Piece in Leading.First .. Leading.Last loop
               declare
                  Item : constant Landin.Tokens.Space :=
                    Landin.Tokens.Nth_Space (Stream, Piece);
               begin
                  if Landin.Tokens.Kind (Item)
                       not in Landin.Tokens.Blanks | Landin.Tokens.Line_End
                  then
                     Unbounded.Append
                       (Result, "comment " & Slice (Landin.Tokens.Where (Item))
                        & LF);
                  end if;
               end;
            end loop;
            Unbounded.Append
              (Result,
               Landin.Tokens.Token_Kind'Image
                 (Landin.Tokens.Kind (Stream, Index))
               & " " & Slice (Landin.Tokens.Where (Stream, Index)) & LF);
         end;
      end loop;
      return Unbounded.To_String (Result);
   end Things;

   --  [1750]'s line ends: CR LF is one, and a lone CR is one.
   function Line_Count (Text : String) return Natural
     is (Ada.Strings.Fixed.Count (Text, [LF])
         + Ada.Strings.Fixed.Count (Text, [CR])
         - Ada.Strings.Fixed.Count (Text, [CR, LF]));

   --  Whether the edits are what an editor accepts: in byte order, never
   --  overlapping, each inside the text, and each replacing space only.
   function Edits_Problem
     (Text : String; Edits : Landin.Formatting.Edit_List) return String;

   function Edits_Problem
     (Text : String; Edits : Landin.Formatting.Edit_List) return String
   is
      Bytes : constant String (1 .. Text'Length) := Text;
      Reach : Landin.Source.Byte_Offset := 0;
   begin
      for Each of Edits loop
         declare
            Where : constant Landin.Source.Span :=
              Landin.Diagnostics.Span_Of (Each);
         begin
            if Where.First < Reach then
               return "an edit overlaps or precedes the one before it";
            elsif Natural (Where.Last) > Bytes'Length then
               return "an edit runs past the text";
            end if;
            for At_Byte in Natural (Where.First) + 1 .. Natural (Where.Last)
            loop
               if Bytes (At_Byte) not in ' ' | LF | CR | Tab then
                  return "an edit replaces a byte that is not space";
               end if;
            end loop;
            for Written of Landin.Diagnostics.Replacement (Each) loop
               if Written not in ' ' | LF then
                  return "an edit writes a byte that is not a space or LF";
               end if;
            end loop;
            Reach := Where.Last;
         end;
      end loop;
      return "";
   end Edits_Problem;

   --  Formats Text and requires everything the layout promises of it:
   --  space-only edits, the same tokens and comments, no extra line end,
   --  one final LF after nonblank content (unless empty), and a second
   --  format that offers nothing.  Returns the formatted text, or the
   --  refused one unchanged.
   function Held
     (Item  : in out Landin.Testing.Context;
      Label : String;
      Text  : String) return String;

   function Held
     (Item  : in out Landin.Testing.Context;
      Label : String;
      Text  : String;
      Once  : Landin.Formatting.Result) return String;

   function Held
     (Item  : in out Landin.Testing.Context;
      Label : String;
      Text  : String) return String
   is
      Once : constant Landin.Formatting.Result := Format (Text);
   begin
      return Held (Item, Label, Text, Once);
   end Held;

   function Held
     (Item  : in out Landin.Testing.Context;
      Label : String;
      Text  : String;
      Once  : Landin.Formatting.Result) return String
   is
      Out_Text : constant String := Unbounded.To_String (Once.Text);
   begin
      if Once.Outcome = Landin.Formatting.Refused then
         Landin.Testing.Check
           (Item, Once.Found.Has_Errors and then Once.Edits.Is_Empty
            and then Out_Text = Text,
            Label & ": a refusal says why and edits nothing");
         return Text;
      end if;

      declare
         Problem : constant String := Edits_Problem (Text, Once.Edits);
      begin
         if Problem /= "" then
            Landin.Testing.Fail (Item, Label & ": " & Problem);
         end if;
      end;
      if Things (Out_Text) /= Things (Text) then
         Landin.Testing.Fail
           (Item, Label & ": formatting changed a token or a comment");
      end if;
      if Line_Count (Out_Text) > Line_Count (Text)
        + (if Text'Length > 0 and then Text (Text'Last) not in LF | CR
           then 1 else 0)
      then
         Landin.Testing.Fail (Item, Label & ": formatting added a line");
      end if;
      if Out_Text'Length > 0
        and then (Out_Text'Length = 1
                  or else Out_Text (Out_Text'Last) /= LF
                  or else Out_Text (Out_Text'Last - 1) in ' ' | Tab | LF | CR)
      then
         Landin.Testing.Fail
           (Item, Label & ": formatting left a blank or unterminated"
            & " final line");
      end if;

      declare
         Twice : constant Landin.Formatting.Result := Format (Out_Text);
      begin
         if Twice.Outcome /= Landin.Formatting.Formatted
           or else not Twice.Edits.Is_Empty
         then
            Landin.Testing.Fail
              (Item, Label & ": formatting a formatted file offers"
               & Natural'Image (Natural (Twice.Edits.Length)) & " edits");
         end if;
      end;
      return Out_Text;
   end Held;

   procedure Expect
     (Item : in out Landin.Testing.Context; Label, Text, Wanted : String);

   procedure Expect
     (Item : in out Landin.Testing.Context; Label, Text, Wanted : String) is
   begin
      Landin.Testing.Check_Equal
        (Item, Held (Item, Label, Text), Wanted, Label);
   end Expect;

   ------------------------------------------------------------------
   --  The page
   ------------------------------------------------------------------

   --  Every `### ` section under `## Rules` in docs/format.md holds two
   --  `landin` blocks: a program as written and as formatted.  Deliberate
   --  real-host exception: the page is what is under test.
   procedure The_Page_Is_The_Layout (Item : in out Landin.Testing.Context);

   procedure The_Page_Is_The_Layout (Item : in out Landin.Testing.Context) is
      Host    : Landin.Platform.Native.Native_Filesystem;
      Content : Unbounded.Unbounded_String;
      Status  : Landin.Platform.Read_Status;
      Rules   : Natural := 0;
   begin
      Host.Read_File (Root & "/docs/format.md", Content, Status);
      if Status /= Landin.Platform.Read_Ok then
         Landin.Testing.Fail (Item, "docs/format.md cannot be read");
         return;
      end if;

      declare
         Page    : constant String := Unbounded.To_String (Content);
         Cursor  : Natural := Page'First;
         Title   : Unbounded.Unbounded_String;
         Blocks  : array (1 .. 2) of Unbounded.Unbounded_String;
         Held_Blocks : Natural := 0;
         In_Rules : Boolean := False;
         In_Block : Boolean := False;

         procedure Finish;

         procedure Finish is
         begin
            if Unbounded.Length (Title) > 0 then
               Rules := Rules + 1;
               if Held_Blocks /= 2 then
                  Landin.Testing.Fail
                    (Item, Unbounded.To_String (Title)
                     & " has" & Held_Blocks'Image & " examples, not two");
               else
                  Expect (Item, Unbounded.To_String (Title),
                          Unbounded.To_String (Blocks (1)),
                          Unbounded.To_String (Blocks (2)));
               end if;
            end if;
            Title := Unbounded.Null_Unbounded_String;
            Held_Blocks := 0;
            Blocks := [others => Unbounded.Null_Unbounded_String];
         end Finish;
      begin
         while Cursor <= Page'Last loop
            declare
               Stop : Natural := Ada.Strings.Fixed.Index (Page, [LF], Cursor);
            begin
               if Stop = 0 then
                  Stop := Page'Last + 1;
               end if;
               declare
                  Line : constant String := Page (Cursor .. Stop - 1);
               begin
                  if In_Block then
                     if Line = "```" then
                        In_Block := False;
                     elsif Held_Blocks in Blocks'Range then
                        Unbounded.Append (Blocks (Held_Blocks), Line & LF);
                     end if;
                  elsif Line = "## Rules" then
                     In_Rules := True;
                  elsif Line'Length > 3
                    and then Line (Line'First .. Line'First + 2) = "## "
                  then
                     Finish;
                     In_Rules := False;
                  elsif In_Rules and then Line'Length > 4
                    and then Line (Line'First .. Line'First + 3) = "### "
                  then
                     Finish;
                     Title := Unbounded.To_Unbounded_String
                       (Line (Line'First + 4 .. Line'Last));
                  elsif In_Rules and then Line = "```landin" then
                     In_Block := True;
                     Held_Blocks := Held_Blocks + 1;
                  end if;
               end;
               Cursor := Stop + 1;
            end;
         end loop;
         Finish;
      end;

      Landin.Testing.Check
        (Item, Rules >= 11, "the page shows every rule, and" & Rules'Image
         & " were read");
   end The_Page_Is_The_Layout;

   ------------------------------------------------------------------
   --  The bytes no example shows
   ------------------------------------------------------------------

   procedure Space_Is_Normalized (Item : in out Landin.Testing.Context);

   procedure Space_Is_Normalized (Item : in out Landin.Testing.Context) is
   begin
      Expect (Item, "an empty file", "", "");
      Expect (Item, "a file of only space", "  " & LF & Tab & LF & LF, "");
      Expect (Item, "a file of only a comment",
              "-- note  " & LF & LF & LF, "-- note" & LF);
      Expect (Item, "CR LF becomes LF",
              "a: u32 = 1" & CR & LF & "b: u32 = 2" & CR & LF,
              "a: u32 = 1" & LF & "b: u32 = 2" & LF);
      Expect (Item, "a lone CR becomes LF",
              "a: u32 = 1" & CR & "b: u32 = 2",
              "a: u32 = 1" & LF & "b: u32 = 2" & LF);
      Expect (Item, "a missing final line end is added",
              "a: u32 = 1", "a: u32 = 1" & LF);
      Expect (Item, "trailing blanks are removed, a comment's too",
              "a: u32 = 1  " & LF & "-- note " & Tab & LF,
              "a: u32 = 1" & LF & "-- note" & LF);
      Expect (Item, "tabs become the layout's spaces",
              "f: () -> none =" & LF & Tab & "g()" & LF & "end f" & LF,
              "f: () -> none =" & LF & "    g()" & LF & "end f" & LF);
      Expect (Item, "blank lines at the edges go and runs become one",
              LF & LF & "a: u32 = 1" & LF & LF & LF & "b: u32 = 2"
              & LF & LF,
              "a: u32 = 1" & LF & LF & "b: u32 = 2" & LF);
      Expect (Item, "a prefix minus keeps its blank before another",
              "a: i32 = -  -1" & LF, "a: i32 = - -1" & LF);
      Expect (Item, "a block comment between two tokens",
              "b: bool = not--( x )--false" & LF,
              "b: bool = not --( x )-- false" & LF);
      Expect (Item, "a raw literal's lines are its own",
              "f: () -> none =" & LF
              & "  t: []u8 = """"""" & LF & "        a  " & LF
              & "          b" & LF & "        """"""" & LF & "end f" & LF,
              "f: () -> none =" & LF
              & "    t: []u8 = """"""" & LF & "        a  " & LF
              & "          b" & LF & "        """"""" & LF & "end f" & LF);
      Expect (Item, "a block comment's lines are its own",
              "--( one" & LF & "   two  " & CR & LF & ")--" & LF
              & "a: u32 = 1" & LF,
              "--( one" & LF & "   two  " & CR & LF & ")--" & LF
              & "a: u32 = 1" & LF);
      Expect (Item, "a doc comment stays above what it documents",
              "  --- the answer" & LF & "   answer: u32 = 42" & LF,
              "--- the answer" & LF & "answer: u32 = 42" & LF);
      Expect (Item, "a comment before a closer stays in the block",
              "f: () -> none =" & LF & "    g()" & LF & "-- last" & LF
              & "end f" & LF,
              "f: () -> none =" & LF & "    g()" & LF & "    -- last" & LF
              & "end f" & LF);
   end Space_Is_Normalized;

   --  What does not parse is refused and untouched; what parses and is
   --  wrong later is formatted, because nothing after the parse is read.
   procedure Only_Syntax_Decides (Item : in out Landin.Testing.Context);

   procedure Only_Syntax_Decides (Item : in out Landin.Testing.Context) is
      procedure Refused (Label, Text, Code : String);

      procedure Refused (Label, Text, Code : String) is
         Answer : constant Landin.Formatting.Result := Format (Text);
      begin
         Landin.Testing.Check
           (Item, Answer.Outcome = Landin.Formatting.Refused
            and then Answer.Edits.Is_Empty
            and then Unbounded.To_String (Answer.Text) = Text
            and then Landin.Diagnostics.Count (Answer.Found) > 0
            and then Landin.Diagnostics.Code
                       (Landin.Diagnostics.Get (Answer.Found, 1)) = Code,
            Label & " is refused with " & Code & " and not edited");
      end Refused;
   begin
      Refused ("a file that does not scan",
               "a: u32 = 1  --( never closed" & LF, "L0013");
      Refused ("a file that does not parse",
               "f: () -> none =" & LF & "   if x" & LF & "end f" & LF,
               "L0103");
      Expect (Item, "a file whose names are wrong is formatted",
              "f: () -> none =" & LF & " missing()" & LF & "end f",
              "f: () -> none =" & LF & "    missing()" & LF & "end f" & LF);
      Expect (Item, "a file whose types are wrong is formatted",
              "a:u32=true" & LF, "a: u32 = true" & LF);
   end Only_Syntax_Decides;

   ------------------------------------------------------------------
   --  The corpus
   ------------------------------------------------------------------

   --  Walks every `.ldn` under the repository, as the lexer suite's
   --  reproduction case does, and hands each to Visit.  Deliberate
   --  real-host exception: the files on disk are what is under test.  The
   --  build tree and anything whose name starts with a dot are not walked.
   procedure Walk_Sources
     (Item  : in out Landin.Testing.Context;
      Under : String;
      Visit : not null access procedure (Path, Text : String));

   procedure Walk_Sources
     (Item  : in out Landin.Testing.Context;
      Under : String;
      Visit : not null access procedure (Path, Text : String))
   is
      Host  : Landin.Platform.Native.Native_Filesystem;
      Build : constant String := Root & "/compiler/ada/build";

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
                        Visit (Path, Unbounded.To_String (Content));
                     end if;
                  end;
               end if;
            end;
         end loop;
      end Walk;
   begin
      Walk (Under);
   end Walk_Sources;

   procedure Every_Source_Keeps_What_It_Says
     (Item : in out Landin.Testing.Context);

   procedure Every_Source_Keeps_What_It_Says
     (Item : in out Landin.Testing.Context)
   is
      Files, Refused, Changed : Natural := 0;

      --  Classify the source without asking the formatter.  A formatter
      --  refusal with its own report must not turn a parseable corpus file
      --  into an acceptable refusal.
      function Parses (Text : String) return Boolean;

      function Parses (Text : String) return Boolean is
         Sources : Landin.Source.Sets.Source_Set;
         Names   : Landin.Source.Names.Table;
         Stream  : Landin.Tokens.Token_Stream;
         Found   : Landin.Diagnostics.Diagnostic_List;
      begin
         Landin.Tokens.Lexer.Lex
           (Sources.Get (Sources.Add ("probe.ldn", Text)), Names, Stream);
         Landin.Diagnostics.Lexical.Report (Stream, Found);
         declare
            Tree : constant Landin.Syntax.Tree :=
              Landin.Syntax.Parser.Parse (Stream, Names, Found);
            pragma Unreferenced (Tree);
         begin
            return not Found.Has_Errors;
         end;
      end Parses;

      --  Shapes the corpus holds once or twice, named so deleting one
      --  fails here instead of shrinking what this proves.  The first six
      --  are formatted, the last two refused.
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

      procedure Visit (Path, Text : String);

      procedure Visit (Path, Text : String) is
         Parseable : constant Boolean := Parses (Text);
         Answer : constant Landin.Formatting.Result := Format (Text);
         After  : constant String := Held (Item, Path, Text, Answer);
      begin
         Files := Files + 1;
         Landin.Testing.Check
           (Item, (Answer.Outcome = Landin.Formatting.Formatted) = Parseable,
            Path & (if Parseable then " parses but was refused"
                    else " does not parse but was formatted"));
         if Answer.Outcome = Landin.Formatting.Refused then
            Refused := Refused + 1;
         elsif After /= Text then
            Changed := Changed + 1;
         end if;
         for Index in Seen'Range loop
            if Ends_With (Path, Named.Element (Index)) then
               Seen (Index) := True;
               Landin.Testing.Check
                 (Item, (Answer.Outcome = Landin.Formatting.Refused)
                        = (Index > 6),
                  Named.Element (Index)
                  & (if Index > 6 then " is refused" else " is formatted"));
            end if;
         end loop;
      end Visit;
   begin
      Walk_Sources (Item, Root, Visit'Access);
      Landin.Testing.Check
        (Item, Files >= 2_000,
         "every Landin source in the repository was formatted, and"
         & Files'Image & " were");
      Landin.Testing.Check
        (Item, Refused > 0 and then Refused < Files / 10,
         "scan or parse refusals remain a minority, and"
         & Refused'Image & " were");
      Landin.Testing.Check
        (Item, Changed > 0, "and some were not in the layout");
      for Index in Seen'Range loop
         Landin.Testing.Check
           (Item, Seen (Index), Named.Element (Index) & " was among them");
      end loop;
   end Every_Source_Keeps_What_It_Says;

   --  What the gate holds: the library, the example programs and the
   --  running examples are formatted, so what a reader copies from them is
   --  the layout.  The running examples are read from examples.md, whose
   --  listings check.py holds to the runtime sources byte for byte.
   procedure Core_And_Examples_Are_Formatted
     (Item : in out Landin.Testing.Context);

   procedure Core_And_Examples_Are_Formatted
     (Item : in out Landin.Testing.Context)
   is
      Files    : Natural := 0;
      Listings : Natural := 0;

      procedure Visit (Path, Text : String);

      procedure Visit (Path, Text : String) is
         Answer : constant Landin.Formatting.Result := Format (Text);
      begin
         Files := Files + 1;
         Landin.Testing.Check
           (Item, Answer.Outcome = Landin.Formatting.Formatted
                  and then Answer.Edits.Is_Empty,
            Path & " is formatted; run refine fmt on it");
      end Visit;

      Host    : Landin.Platform.Native.Native_Filesystem;
      Content : Unbounded.Unbounded_String;
      Status  : Landin.Platform.Read_Status;
   begin
      Walk_Sources (Item, Root & "/core", Visit'Access);
      Walk_Sources (Item, Root & "/hosted", Visit'Access);
      Walk_Sources (Item, Root & "/platform", Visit'Access);
      Walk_Sources (Item, Root & "/examples", Visit'Access);
      Landin.Testing.Check
        (Item, Files >= 30, "core and the examples were read, and"
         & Files'Image & " sources were");

      Host.Read_File (Root & "/examples.md", Content, Status);
      if Status /= Landin.Platform.Read_Ok then
         Landin.Testing.Fail (Item, "examples.md cannot be read");
         return;
      end if;
      declare
         Page    : constant String := Unbounded.To_String (Content);
         Opening : constant String := "```landin" & LF;
         Closing : constant String := LF & "```" & LF;
         Cursor  : Natural := Page'First;
      begin
         loop
            declare
               Start : constant Natural :=
                 Ada.Strings.Fixed.Index (Page, Opening, Cursor);
               Stop  : Natural;
            begin
               exit when Start = 0;
               Stop := Ada.Strings.Fixed.Index
                 (Page, Closing, Start + Opening'Length - 1);
               exit when Stop = 0;
               Listings := Listings + 1;
               Visit ("examples.md listing" & Listings'Image,
                      Page (Start + Opening'Length .. Stop));
               Cursor := Stop + Closing'Length;
            end;
         end loop;
      end;
      Landin.Testing.Check
        (Item, Listings = 11, "every running example was read, and"
         & Listings'Image & " were");
   end Core_And_Examples_Are_Formatted;

   procedure Written_Types_Touch_Their_Values
     (Item : in out Landin.Testing.Context);

   procedure Written_Types_Touch_Their_Values
     (Item : in out Landin.Testing.Context) is
   begin
      Expect (Item, "a byte view conversion",
              "view: []u8 = [] u8 (text)" & LF,
              "view: []u8 = []u8(text)" & LF);
      Expect (Item, "a pointer representation extraction",
              "view: ptr u8 = ptr u8 (hidden)" & LF,
              "view: ptr u8 = ptr u8(hidden)" & LF);
      Expect (Item, "a callable representation extraction",
              "view := (x:i32)->(y:i32) (wrapped)" & LF,
              "view := (x: i32) -> (y: i32)(wrapped)" & LF);
      Expect (Item, "a terminal generic type",
              "view := tag (u32,7) (value)" & LF,
              "view := tag(u32, 7)(value)" & LF);
      Expect (Item, "an infallible signature without results",
              "view := () -> none (wrapped)" & LF,
              "view := () -> none(wrapped)" & LF);
      Expect (Item, "a signature with a declared error set",
              "view := () -> none ! problem (wrapped)" & LF,
              "view := () -> none ! problem(wrapped)" & LF);
   end Written_Types_Touch_Their_Values;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "formatting", "written types touch their values",
         Written_Types_Touch_Their_Values'Access);
      Landin.Testing.Register
        (Into, "formatting", "the page is the layout",
         The_Page_Is_The_Layout'Access);
      Landin.Testing.Register
        (Into, "formatting", "space is normalized",
         Space_Is_Normalized'Access);
      Landin.Testing.Register
        (Into, "formatting", "only syntax decides",
         Only_Syntax_Decides'Access);
      Landin.Testing.Register
        (Into, "formatting", "every source keeps what it says",
         Every_Source_Keeps_What_It_Says'Access);
      Landin.Testing.Register
        (Into, "formatting", "core and the examples are formatted",
         Core_And_Examples_Are_Formatted'Access);
   end Register;

end Landin.Tests.Formatting_Suite;
