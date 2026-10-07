with Ada.Containers.Vectors;

with Landin.Diagnostics.Catalogue;
with Landin.Diagnostics.Fixes;
with Landin.Diagnostics.Lexical;
with Landin.Source.Names;
with Landin.Source.Sets;
with Landin.Syntax.Parser;
with Landin.Tokens.Lexer;

package body Landin.Syntax.Repairs is

   package Diag renames Landin.Diagnostics;
   package Rows renames Landin.Diagnostics.Catalogue;
   package Tok renames Landin.Tokens;

   use type Diag.Severity;
   use type Rows.Code_Name;
   use type Landin.Source.Byte_Offset;
   use type Landin.Source.Source_Id;
   use type Landin.Source.Span;
   use type Landin.Source.Line_Number;
   use type Tok.Token_Index;
   use type Tok.Token_Kind;

   --  A line with more tokens than this is not tried: the trials grow
   --  with its length, and a line that long is not one a person mistypes
   --  one token of.
   Token_Limit : constant := 40;

   --  The words a trial inserts where the parser asked for one, and the
   --  stand-ins it inserts where it asked for a name, a value or a type.
   type Wanted is (Want_Then, Want_Do, Want_End, Want_Equal, Want_Colon,
                   Want_Close_Paren, Want_Close_Bracket, Want_Comma,
                   Want_In, Want_Name, Want_Value, Want_Type);

   function Spelling (Item : Wanted) return String
     is (case Item is
            when Want_Then          => "then",
            when Want_Do            => "do",
            when Want_End           => "end",
            when Want_Equal         => "=",
            when Want_Colon         => ":",
            when Want_Close_Paren   => ")",
            when Want_Close_Bracket => "]",
            when Want_Comma         => ",",
            when Want_In            => "in",
            when Want_Name          => "name",
            when Want_Value         => "0",
            when Want_Type          => "u32");

   --  Whether a stand-in is the repair, which a person must still fill.
   function Is_Placeholder (Item : Wanted) return Boolean
     is (Item in Want_Name | Want_Value | Want_Type);

   type Piece is record
      First, Last : Natural := 0;     --  bytes of Text, 1-based, inclusive
      Kind        : Tok.Token_Kind := Tok.End_Of_Input;
   end record;

   package Piece_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Piece);

   --  In the order they are preferred: a change that keeps every token
   --  written comes before one that drops one, and that before one that
   --  writes one the program did not.
   type Change is
     (Swapped, Moved, Deleted, Doubled, Inserted, Appended, Called);

   type Trial is record
      Kind   : Change := Deleted;
      At_Token : Positive := 1;
      Insert : Wanted := Want_Then;
   end record;

   package Trial_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Trial);

   --  Whether Text, with Body_Text standing for one routine body, parses
   --  with no report.  A line that ends its block may be the block's
   --  value, and only there does the stub return one; a line with more of
   --  its block after it is a statement.  The loop around it makes `break`
   --  and `continue` mean what they mean in a loop.
   function Parses
     (Body_Text : String; Loops : Boolean; Value : Boolean) return Boolean;

   function Parses
     (Body_Text : String; Loops : Boolean; Value : Boolean) return Boolean
   is
      LF : constant Character := Character'Val (10);
      Text : constant String :=
        (if Value then "repair_stub: () -> (r: i32) ="
         else "repair_stub: () -> none =") & LF
        & (if Loops then "loop do" & LF else "")
        & Body_Text & LF
        & (if Loops then "end loop" & LF else "")
        & "end repair_stub" & LF;
      Sources : Landin.Source.Sets.Source_Set;
      Names   : Landin.Source.Names.Table;
      Stream  : Tok.Token_Stream;
      Found   : Diag.Diagnostic_List;
      Id      : constant Landin.Source.Source_Id :=
        Sources.Add ("repair", Text);
   begin
      Tok.Lexer.Lex (Sources.Get (Id), Names, Stream);
      Landin.Diagnostics.Lexical.Report (Stream, Found);
      if Diag.Has_Errors (Found) then
         return False;
      end if;
      declare
         Parsed : constant Landin.Syntax.Tree :=
           Landin.Syntax.Parser.Parse (Stream, Names, Found);
         Runs : Landin.Syntax.Node_Id;
         Items : Natural := 0;
      begin
         if Diag.Has_Errors (Found)
           or else Landin.Syntax.Declaration_Count (Parsed) /= 1
         then
            return False;
         end if;
         --  The line is one statement, or one value: a repair that leaves
         --  two things on it has not found what the line was meant to say.
         Runs := Landin.Syntax.Body_Of
           (Parsed, Landin.Syntax.Nth_Declaration (Parsed, 1));
         if Loops
           or else Landin.Syntax.Kind (Parsed, Runs) /= Landin.Syntax.Block
         then
            return True;
         end if;
         for Position in 1 .. Landin.Syntax.Slot_Count (Parsed, Runs) loop
            if Landin.Syntax.Slot (Parsed, Runs, Position)
              /= Landin.Syntax.No_Node
            then
               Items := Items + 1;
            end if;
         end loop;
         return Items <= 1;
      end;
   end Parses;

   --  Text without blanks or tabs at all: what a line says in tokens,
   --  however it is spaced.  Only compared, never shown, and two tokens
   --  that would run together are told apart by the lexer's own rule
   --  before this is asked, since a trial joins them with a blank.
   function Unspaced (Text : String) return String;

   function Unspaced (Text : String) return String is
      Kept   : String (1 .. Text'Length) := [others => ' '];
      Length : Natural := 0;
   begin
      for Byte of Text loop
         if Byte not in ' ' | ASCII.HT then
            Length := Length + 1;
            Kept (Length) := Byte;
         end if;
      end loop;
      return Kept (1 .. Length);
   end Unspaced;

   --  A line as it would be written, without its indentation or the
   --  blanks it ends with.
   function Unindented (Text : String) return String;

   function Unindented (Text : String) return String is
      First : Natural := Text'First;
      Last  : Natural := Text'Last;
   begin
      while First <= Last and then Text (First) in ' ' | ASCII.HT loop
         First := First + 1;
      end loop;
      while Last >= First and then Text (Last) in ' ' | ASCII.HT loop
         Last := Last - 1;
      end loop;
      return Text (First .. Last);
   end Unindented;

   --  Text with every run of blanks one blank and none at either end, so
   --  two changes that write the same tokens are seen to be one.
   function Squeezed (Text : String) return String;

   function Squeezed (Text : String) return String is
      Kept   : String (1 .. Text'Length);
      Length : Natural := 0;
      Blank  : Boolean := True;
   begin
      for Byte of Text loop
         if Byte in ' ' | ASCII.HT then
            if not Blank then
               Length := Length + 1;
               Kept (Length) := ' ';
               Blank := True;
            end if;
         else
            Length := Length + 1;
            Kept (Length) := Byte;
            Blank := False;
         end if;
      end loop;
      if Length > 0 and then Kept (Length) = ' ' then
         Length := Length - 1;
      end if;
      return Kept (1 .. Length);
   end Squeezed;

   --  Left and Right side by side, with a blank between them where their
   --  touching bytes would otherwise run together into one token.
   function Joined (Left, Right : String) return String;

   function Joined (Left, Right : String) return String is
      function Wordlike (Byte : Character) return Boolean
        is (Byte in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_');
   begin
      if Left'Length > 0 and then Right'Length > 0
        and then Wordlike (Left (Left'Last))
        and then Wordlike (Right (Right'First))
      then
         return Left & " " & Right;
      end if;
      return Left & Right;
   end Joined;

   function Restated
     (Snapshot : Landin.Source.Snapshot;
      Parsed   : Landin.Syntax.Tree;
      Found    : Landin.Diagnostics.Diagnostic_List)
      return Landin.Diagnostics.Diagnostic_List
   is
      --  The routine whose body holds Where, by its own name being on an
      --  earlier line than Where's, and whether it returns a value.  A
      --  report on the line a routine's signature is written on is not
      --  tried: a trial of that line would reach into the signature.
      Returns_Value : Boolean := False;
      Routine_First, Routine_Last, Body_First : Natural := 0;

      function In_A_Body (Where : Landin.Source.Span) return Boolean;

      --  Every routine with a body, in source order, read once: asking
      --  for the one a report is in is then a binary search, so a file
      --  with a mistake in every routine costs no more than its length.
      type Routine is record
         Whole, Runs, Name : Landin.Source.Span;
         Returns : Boolean := False;
      end record;

      package Routine_Vectors is new Ada.Containers.Vectors
        (Index_Type => Positive, Element_Type => Routine);

      Routines : Routine_Vectors.Vector;
      Routines_Ready : Boolean := False;

      --  The start of every error report, in order, for counting the
      --  ones after a line.
      package Offset_Vectors is new Ada.Containers.Vectors
        (Index_Type => Positive, Element_Type => Natural);

      Error_Starts : Offset_Vectors.Vector;

      package Offset_Sorting is new Offset_Vectors.Generic_Sorting;

      --  How many errors begin in First .. Last.
      function Errors_Between (First, Last : Natural) return Natural;

      function Errors_Between (First, Last : Natural) return Natural is
         --  The count of entries below Bound.
         function Below (Bound : Natural) return Natural;

         function Below (Bound : Natural) return Natural is
            Low  : Natural := 0;
            High : Natural := Natural (Error_Starts.Length);
         begin
            while Low < High loop
               declare
                  Middle : constant Positive := Low + (High - Low) / 2 + 1;
               begin
                  if Error_Starts (Middle) < Bound then
                     Low := Middle;
                  else
                     High := Middle - 1;
                  end if;
               end;
            end loop;
            return Low;
         end Below;
      begin
         if Last < First then
            return 0;
         end if;
         return Below (Last + 1) - Below (First);
      end Errors_Between;

      function In_A_Body (Where : Landin.Source.Span) return Boolean is
      begin
         if not Routines_Ready then
            for Node in Landin.Syntax.Node_Id'(1)
                        .. Landin.Syntax.Last_Node (Parsed)
            loop
               if Landin.Syntax.Kind (Parsed, Node)
                    = Landin.Syntax.Function_Declaration
                 and then not Landin.Syntax.Is_External (Parsed, Node)
               then
                  Routines.Append
                    (Routine'(Whole   => Landin.Syntax.Where (Parsed, Node),
                      Runs    => Landin.Syntax.Where
                                   (Parsed,
                                    Landin.Syntax.Body_Of (Parsed, Node)),
                      Name    => Landin.Syntax.Anchor (Parsed, Node),
                      Returns => Landin.Syntax.Returns_Of (Parsed, Node)
                                   /= Landin.Syntax.No_Node));
               end if;
            end loop;
            Routines_Ready := True;
         end if;

         --  Routine declarations do not nest, and a post-order lists them
         --  in source order, so the one that can hold Where is the last
         --  that begins at or before it.
         declare
            Low  : Natural := 0;
            High : Natural := Natural (Routines.Length);
         begin
            while Low < High loop
               declare
                  Middle : constant Positive := Low + (High - Low) / 2 + 1;
               begin
                  if Routines (Middle).Whole.First <= Where.First then
                     Low := Middle;
                  else
                     High := Middle - 1;
                  end if;
               end;
            end loop;
            if Low = 0 then
               return False;
            end if;
            declare
               One : constant Routine := Routines (Low);
            begin
               --  The body runs from where it begins to the routine's
               --  closer: a body the parser read only part of has an
               --  extent that stops where it stopped.
               if Where.First >= One.Runs.First
                 and then Where.First < One.Whole.Last
               then
                  Returns_Value := One.Returns;
                  Routine_First := Natural (One.Whole.First) + 1;
                  Routine_Last := Natural (One.Whole.Last);
                  Body_First := Natural (One.Runs.First) + 1;
                  return Landin.Source.Position_Of
                      (Snapshot, One.Name.First).Line
                    < Landin.Source.Position_Of
                        (Snapshot, Where.First).Line;
               end if;
            end;
         end;
         return False;
      end In_A_Body;

      Text   : constant String := Landin.Source.Text (Snapshot);
      Bytes  : constant String (1 .. Text'Length) := Text;
      Source : constant Landin.Source.Source_Id := Landin.Source.Id (Snapshot);
      Result : Diag.Diagnostic_List;
      Last_Line : Natural := 0;

      --  The tokens of the line holding byte Offset, from the line's own
      --  scan.  A line whose scan reports anything is not tried.
      procedure Line_Tokens
        (Line_First, Line_Last : Natural;
         Into : out Piece_Vectors.Vector;
         Clean : out Boolean);

      procedure Line_Tokens
        (Line_First, Line_Last : Natural;
         Into : out Piece_Vectors.Vector;
         Clean : out Boolean)
      is
         Sources : Landin.Source.Sets.Source_Set;
         Names   : Landin.Source.Names.Table;
         Stream  : Tok.Token_Stream;
         Faults  : Diag.Diagnostic_List;
         Id      : constant Landin.Source.Source_Id :=
           Sources.Add ("line", Bytes (Line_First .. Line_Last));
      begin
         Into.Clear;
         Tok.Lexer.Lex (Sources.Get (Id), Names, Stream);
         Landin.Diagnostics.Lexical.Report (Stream, Faults);
         Clean := not Diag.Has_Errors (Faults);
         for Position in 1 .. Tok.Count (Stream) - 1 loop
            declare
               Where : constant Landin.Source.Span :=
                 Tok.Where (Stream, Position);
            begin
               Into.Append
                 (Piece'(First => Line_First + Natural (Where.First),
                   Last  => Line_First + Natural (Where.Last) - 1,
                   Kind  => Tok.Kind (Stream, Position)));
            end;
         end loop;
      end Line_Tokens;

      --  The line with one change applied.
      function Applied
        (Pieces : Piece_Vectors.Vector;
         Line_First, Line_Last : Natural;
         One : Trial) return String;

      function Applied
        (Pieces : Piece_Vectors.Vector;
         Line_First, Line_Last : Natural;
         One : Trial) return String
      is
         Here : constant Piece := Pieces (One.At_Token);
         Before : constant String := Bytes (Line_First .. Here.First - 1);
         Word : constant String := Bytes (Here.First .. Here.Last);
         After : constant String := Bytes (Here.Last + 1 .. Line_Last);
      begin
         case One.Kind is
            when Deleted =>
               --  The word goes with the blank that set it apart and no
               --  other, so the line keeps the spacing its writer gave it:
               --  a word with blanks on both sides takes the one after it,
               --  one written against what precedes it takes none.
               if After'Length > 0 and then After (After'First) = ' '
                 and then Before'Length > 0
                 and then Before (Before'Last) = ' '
               then
                  return Joined
                    (Before, After (After'First + 1 .. After'Last));
               elsif Before'Length > 0 and then Before (Before'Last) = ' '
                 and then (After'Length = 0
                           or else After (After'First) in ')' | ']' | ',')
               then
                  return Joined
                    (Before (Before'First .. Before'Last - 1), After);
               end if;
               return Joined (Before, After);
            when Doubled =>
               return Before & Word & " " & Word & After;
            when Swapped =>
               declare
                  Next : constant Piece := Pieces (One.At_Token + 1);
               begin
                  return Joined
                    (Joined (Before, Bytes (Next.First .. Next.Last))
                     & Bytes (Here.Last + 1 .. Next.First - 1)
                     & Word, Bytes (Next.Last + 1 .. Line_Last));
               end;
            when Moved =>
               declare
                  Start : constant Piece := Pieces (1);
                  --  The word leaves its place with the blank after it,
                  --  as a deletion does, and is written first.
                  Rest : constant String :=
                    Bytes (Here.Last + 1 .. Line_Last);
               begin
                  return Bytes (Line_First .. Start.First - 1) & Word & " "
                    & Joined
                        (Bytes (Start.First .. Here.First - 1),
                         (if Rest'Length > 0 and then Rest (Rest'First) = ' '
                          then Rest (Rest'First + 1 .. Rest'Last)
                          else Rest));
               end;
            when Inserted =>
               --  `:`, `,` and a closer hug what they follow, as written.
               if One.Insert in Want_Colon | Want_Comma | Want_Close_Paren
                                | Want_Close_Bracket
                 and then Before'Length > 0
                 and then Before (Before'Last) = ' '
               then
                  return Before (Before'First .. Before'Last - 1)
                    & Spelling (One.Insert) & " " & Word & After;
               end if;
               return Joined (Before, Spelling (One.Insert))
                 & (if Word in ")" | "]" | "," | ":" then "" else " ")
                 & Word & After;
            when Called =>
               --  `name operand` becomes `name(operand)`: the operand is
               --  the token after the name, and the blank between goes.
               declare
                  Next : constant Piece := Pieces (One.At_Token + 1);
               begin
                  return Before & Word & "("
                    & Bytes (Next.First .. Next.Last) & ")"
                    & Bytes (Next.Last + 1 .. Line_Last);
               end;
            when Appended =>
               declare
                  --  Written after the line's last token, not after the
                  --  blanks a line may end with.
                  Kept : constant String :=
                    Bytes (Line_First .. Pieces.Last_Element.Last);
               begin
                  return Kept
                    & (if One.Insert in Want_Colon | Want_Comma
                         | Want_Close_Paren | Want_Close_Bracket
                         or else Pieces.Last_Element.Kind = Tok.Dot
                       then "" else " ")
                    & Spelling (One.Insert)
                    & Bytes (Pieces.Last_Element.Last + 1 .. Line_Last);
               end;
         end case;
      end Applied;

      --  The fix one trial is, against the file's own offsets: the bytes
      --  of the line from its first changed token to its last, replaced
      --  by what the trial wrote there, so the fix and the line it was
      --  tried as are the same bytes.
      function Fix_Of
        (Pieces : Piece_Vectors.Vector;
         Line_First, Line_Last : Natural;
         One    : Trial;
         Level  : Diag.Applicability) return Diag.Fix;

      function Fix_Of
        (Pieces : Piece_Vectors.Vector;
         Line_First, Line_Last : Natural;
         One    : Trial;
         Level  : Diag.Applicability) return Diag.Fix
      is
         Here : constant Piece := Pieces (One.At_Token);
         Word : constant String := Bytes (Here.First .. Here.Last);
         Old_Line : constant String := Bytes (Line_First .. Line_Last);
         New_Line : constant String :=
           Applied (Pieces, Line_First, Line_Last, One);
         --  The common prefix and suffix of the two lines are left alone.
         Prefix : Natural := 0;
         Suffix : Natural := 0;
         function Span (First, Last : Natural) return Landin.Source.Span
           is (First => Landin.Source.Byte_Offset (First - 1),
               Last  => Landin.Source.Byte_Offset (Last));
      begin
         while Prefix < Old_Line'Length and then Prefix < New_Line'Length
           and then Old_Line (Old_Line'First + Prefix)
             = New_Line (New_Line'First + Prefix)
         loop
            Prefix := Prefix + 1;
         end loop;
         while Suffix < Old_Line'Length - Prefix
           and then Suffix < New_Line'Length - Prefix
           and then Old_Line (Old_Line'Last - Suffix)
             = New_Line (New_Line'Last - Suffix)
         loop
            Suffix := Suffix + 1;
         end loop;
         declare
            Where : constant Landin.Source.Span :=
              Span (Line_First + Prefix, Line_Last - Suffix);
            Written : constant String :=
              New_Line (New_Line'First + Prefix .. New_Line'Last - Suffix);
         begin
            case One.Kind is
               when Deleted =>
                  return Landin.Diagnostics.Fixes.Delete_Token
                    (Source, Where, Written, Word, Level);
               when Doubled =>
                  return Landin.Diagnostics.Fixes.Insert_Token
                    (Source, Where, Written, Word, Level);
               when Swapped =>
                  return Landin.Diagnostics.Fixes.Swap_Tokens
                    (Source, Where, Written, Word,
                     Bytes (Pieces (One.At_Token + 1).First
                            .. Pieces (One.At_Token + 1).Last),
                     Level);
               when Moved =>
                  return Landin.Diagnostics.Fixes.Move_Token
                    (Source, Where, Written, Word, Level);
               when Called =>
                  return Landin.Diagnostics.Fixes.Call_With
                    (Source, Where, Written, Word, Level);
               when Inserted | Appended =>
                  return Landin.Diagnostics.Fixes.Insert_Token
                    (Source, Where, Written, Spelling (One.Insert),
                     (if Is_Placeholder (One.Insert) then Diag.Likely
                      else Level),
                     Placeholder => Is_Placeholder (One.Insert),
                     Neighbour   =>
                       (if One.Kind = Appended or else One.At_Token = 1
                        then Word
                        else Bytes (Pieces (One.At_Token - 1).First
                                    .. Pieces (One.At_Token - 1).Last)),
                     After       => One.Kind = Appended
                                    or else One.At_Token > 1);
            end case;
         end;
      end Fix_Of;

      --  The words the parser's report says belong where it points.
      function Asked_For (Item : Diag.Diagnostic) return Wanted;

      function Asked_For (Item : Diag.Diagnostic) return Wanted
      is
         Said : constant String :=
           Diag.Message (Diag.Primary (Item));
         function Has (Part : String) return Boolean
           is (for some Position in Said'First
                  .. Said'Last - Part'Length + 1 =>
                 Said (Position .. Position + Part'Length - 1) = Part);
      begin
         if Has ("`then`") then
            return Want_Then;
         elsif Has ("`do`") then
            return Want_Do;
         elsif Has ("`in`") then
            return Want_In;
         elsif Has ("`)`") or else Has ("never closed") then
            return Want_Close_Paren;
         elsif Has ("`]`") then
            return Want_Close_Bracket;
         elsif Has ("after `:`") or else Has ("`:`") then
            return Want_Colon;
         elsif Has ("`=`") then
            return Want_Equal;
         elsif Has ("a name belongs") then
            return Want_Name;
         elsif Has ("a type belongs") then
            return Want_Type;
         end if;
         return Want_Value;
      end Asked_For;

      --  Whether a trial removes one copy of a word written twice in a row.
      function Removes_A_Copy
        (One : Trial; Pieces : Piece_Vectors.Vector) return Boolean;

      function Removes_A_Copy
        (One : Trial; Pieces : Piece_Vectors.Vector) return Boolean
      is
         function Word (Position : Positive) return String
           is (Bytes (Pieces (Position).First .. Pieces (Position).Last));
      begin
         return One.Kind = Deleted
           and then
             ((One.At_Token > 1
               and then Word (One.At_Token) = Word (One.At_Token - 1))
              or else
                (One.At_Token < Natural (Pieces.Length)
                 and then Word (One.At_Token) = Word (One.At_Token + 1)));
      end Removes_A_Copy;

      --  What a repair says the mistake was.
      function Said
        (One : Trial; Pieces : Piece_Vectors.Vector) return String;

      function Said
        (One : Trial; Pieces : Piece_Vectors.Vector) return String
      is
         Here : constant Piece := Pieces (One.At_Token);
         Word : constant String := Bytes (Here.First .. Here.Last);
      begin
         case One.Kind is
            when Deleted =>
               return "`" & Word & "` does not belong here";
            when Doubled =>
               return "`" & Word & "` is written once too few";
            when Swapped =>
               declare
                  Next : constant Piece := Pieces (One.At_Token + 1);
               begin
                  return "`" & Word & "` and `"
                    & Bytes (Next.First .. Next.Last)
                    & "` are written the wrong way round";
               end;
            when Moved =>
               return "`" & Word & "` begins the statement, not here";
            when Inserted =>
               return
                 (if Is_Placeholder (One.Insert)
                  then (case One.Insert is
                          when Want_Name  => "a name",
                          when Want_Type  => "a type",
                          when others     => "a value")
                       & " belongs before `" & Word & "`"
                  else "`" & Spelling (One.Insert)
                       & "` belongs before `" & Word & "`");
            when Called =>
               return "a call of `" & Word & "` puts its operand in"
                 & " parentheses";
            when Appended =>
               return
                 (if Is_Placeholder (One.Insert)
                  then (case One.Insert is
                          when Want_Name  => "a name",
                          when Want_Type  => "a type",
                          when others     => "a value")
                       & " belongs after `" & Word & "`"
                  else "`" & Spelling (One.Insert)
                       & "` belongs after `" & Word & "`");
         end case;
      end Said;

      --  Whether the word at First, up to Last, is Word and nothing more.
      function Starts_With (First, Last : Natural; Word : String)
        return Boolean;

      function Starts_With (First, Last : Natural; Word : String)
        return Boolean
        is (First + Word'Length - 1 <= Last
            and then Bytes (First .. First + Word'Length - 1) = Word
            and then (First + Word'Length > Last
                      or else Bytes (First + Word'Length)
                        not in 'a' .. 'z' | '0' .. '9' | '_'));

      --  Whether Given, a routine with one line changed, reports nothing
      --  that begins before the end of the line starting at First: the
      --  change mended the line without breaking anything before it.
      --  What follows may still hold the routine's other mistakes.
      function Mends_File (Given : String; First : Natural) return Boolean;

      --  How many errors the parser reported in the routine after the line
      --  being tried: a trial that reports more there made them.
      Errors_After : Natural := 0;

      function Mends_File (Given : String; First : Natural) return Boolean
      is
         Whole   : constant String (1 .. Given'Length) := Given;
         Sources : Landin.Source.Sets.Source_Set;
         Names   : Landin.Source.Names.Table;
         Stream  : Tok.Token_Stream;
         Reports : Diag.Diagnostic_List;
         Id      : constant Landin.Source.Source_Id :=
           Sources.Add ("repair", Whole);
         Line_End : Natural := First;
         After    : Natural := 0;
      begin
         while Line_End <= Whole'Last and then Whole (Line_End) /= ASCII.LF
         loop
            Line_End := Line_End + 1;
         end loop;
         Tok.Lexer.Lex (Sources.Get (Id), Names, Stream);
         Landin.Diagnostics.Lexical.Report (Stream, Reports);
         declare
            Parsed_Again : constant Landin.Syntax.Tree :=
              Landin.Syntax.Parser.Parse (Stream, Names, Reports);
            pragma Unreferenced (Parsed_Again);
         begin
            for Index in 1 .. Diag.Count (Reports) loop
               declare
                  At_Report : constant Landin.Source.Span :=
                    Diag.Span_Of (Diag.Primary (Diag.Get (Reports, Index)));
               begin
                  --  A report before the line's end is one the change
                  --  did not mend; one after it is counted.
                  if Diag.Level (Diag.Get (Reports, Index)) = Diag.Error
                  then
                     if Natural (At_Report.First) < Line_End then
                        return False;
                     end if;
                     After := After + 1;
                  end if;
               end;
            end loop;
         end;
         --  A change that leaves more wrong after the line than there was
         --  has made a mistake of its own.
         return After <= Errors_After;
      end Mends_File;

      --  Whether the line beginning at First is inside a `match`: the
      --  nearest line above it that begins with a word less indented
      --  opens one.
      function In_A_Match (First : Natural) return Boolean;

      function In_A_Match (First : Natural) return Boolean is
         function Indent (At_Line : Natural) return Natural;

         function Indent (At_Line : Natural) return Natural is
            Position : Natural := At_Line;
         begin
            while Position <= Bytes'Last and then Bytes (Position) = ' ' loop
               Position := Position + 1;
            end loop;
            return Position - At_Line;
         end Indent;
         Mine : constant Natural := Indent (First);
         Line : Natural := First;
      begin
         while Line > 2 loop
            Line := Line - 1;   --  the line end before this line
            while Line > 1 and then Bytes (Line - 1) /= ASCII.LF loop
               Line := Line - 1;
            end loop;
            declare
               Theirs : constant Natural := Indent (Line);
               Word   : constant Natural := Line + Theirs;
            begin
               if Word <= Bytes'Last and then Bytes (Word) /= ASCII.LF
                 and then Theirs < Mine
               then
                  return Starts_With (Word, Bytes'Last, "match");
               end if;
            end;
         end loop;
         return False;
      end In_A_Match;

      --  Whether the line beginning at First continues an expression or
      --  a list the line above it left open.
      function Continues (First : Natural) return Boolean;

      function Continues (First : Natural) return Boolean is
         Position : Natural := First;
      begin
         --  The last byte before this line that is not space.
         loop
            exit when Position <= 1;
            Position := Position - 1;
            exit when Bytes (Position) not in ' ' | ASCII.HT | ASCII.LF
                                               | ASCII.CR;
         end loop;
         --  The `=` that opens the routine's body ends a line too, and
         --  continues nothing.
         if Position < 1 or else Position < Body_First then
            return False;
         end if;
         if Bytes (Position) in ',' | '(' | '[' | '+' | '-' | '*' | '/'
                                | '=' | '|' | '&' | '<' | '>' | '.'
         then
            return True;
         end if;
         --  A word that asks for the value after it: an exit's `when`,
         --  `addr`, and the logical words.
         declare
            Word_First : Natural := Position;
         begin
            while Word_First > 1
              and then Bytes (Word_First - 1) in 'a' .. 'z' | '_'
            loop
               Word_First := Word_First - 1;
            end loop;
            if Word_First > 1
              and then Bytes (Word_First - 1)
                in 'A' .. 'Z' | '0' .. '9'
            then
               return False;
            end if;
            declare
               Word : constant String := Bytes (Word_First .. Position);
            begin
               return Word = "when" or else Word = "addr"
                 or else Word = "not" or else Word = "and"
                 or else Word = "or";
            end;
         end;
      end Continues;

      --  Whether the next line that holds anything begins with a word that
      --  ends a block, so the line ending at Last is its block's last.
      function Ends_Block (Last : Natural) return Boolean;

      function Ends_Block (Last : Natural) return Boolean is
         Position : Natural := Last + 1;
      begin
         while Position <= Bytes'Last
           and then Bytes (Position) in ' ' | ASCII.HT | ASCII.LF | ASCII.CR
         loop
            Position := Position + 1;
         end loop;
         return Position > Bytes'Last
           or else Starts_With (Position, Bytes'Last, "end")
           or else Starts_With (Position, Bytes'Last, "else")
           or else Starts_With (Position, Bytes'Last, "elsif")
           or else Starts_With (Position, Bytes'Last, "complete");
      end Ends_Block;

      --  The token of the line the report's primary span begins at, or 0.
      function Stop_Token
        (Item : Diag.Diagnostic; Pieces : Piece_Vectors.Vector)
         return Natural;

      function Stop_Token
        (Item : Diag.Diagnostic; Pieces : Piece_Vectors.Vector)
         return Natural
      is
         At_Byte : constant Natural :=
           Natural (Diag.Span_Of (Diag.Primary (Item)).First) + 1;
      begin
         for Position in 1 .. Natural (Pieces.Length) loop
            if Pieces (Position).First = At_Byte then
               return Position;
            end if;
         end loop;
         return 0;
      end Stop_Token;

      --  Whether the report points past the line's last token.
      function Stop_At_End
        (Item : Diag.Diagnostic; Pieces : Piece_Vectors.Vector)
         return Boolean
        is (not Pieces.Is_Empty
            and then Natural (Diag.Span_Of (Diag.Primary (Item)).First)
              >= Pieces.Last_Element.Last);

      --  Whether the line above the one beginning at First begins with
      --  `match`.
      function Above_Begins_Match (First : Natural) return Boolean;

      function Above_Begins_Match (First : Natural) return Boolean is
         Above : Natural := First - 1;
      begin
         if First <= 2 then
            return False;
         end if;
         while Above > 1 and then Bytes (Above - 1) /= ASCII.LF loop
            Above := Above - 1;
         end loop;
         while Above < First - 1 and then Bytes (Above) in ' ' | ASCII.HT
         loop
            Above := Above + 1;
         end loop;
         return Starts_With (Above, First - 2, "match");
      end Above_Begins_Match;

      --  Whether a line opens more brackets than it closes.
      function Opens_More (Pieces : Piece_Vectors.Vector) return Boolean;

      function Opens_More (Pieces : Piece_Vectors.Vector) return Boolean is
         Depth : Integer := 0;
      begin
         for One of Pieces loop
            if One.Kind in Tok.Left_Paren | Tok.Left_Bracket then
               Depth := Depth + 1;
            elsif One.Kind in Tok.Right_Paren | Tok.Right_Bracket then
               Depth := Depth - 1;
            end if;
         end loop;
         return Depth > 0;
      end Opens_More;

      --  Whether a message begins with Part.
      function Starts_Said (Message, Part : String) return Boolean
        is (Message'Length >= Part'Length
            and then Message (Message'First
                              .. Message'First + Part'Length - 1) = Part);

      --  The first error on a line inside a routine body: try every change
      --  in order and keep those that make the line parse.
      procedure Try_Line (Item : Diag.Diagnostic);

      procedure Try_Line (Item : Diag.Diagnostic) is
         Where : constant Landin.Source.Span :=
           Diag.Span_Of (Diag.Primary (Item));
         --  A report at a line's end points at its line end byte, which
         --  belongs to the line it ends.
         At_Byte : constant Positive :=
           Natural'Min (Natural (Where.First) + 1, Bytes'Last);
         Line_First : Positive :=
           (if Bytes (At_Byte) = ASCII.LF and then At_Byte > 1
            then At_Byte - 1 else At_Byte);
         Line_Last  : Natural := Line_First;
         Pieces : Piece_Vectors.Vector;
         Clean  : Boolean;
         Found_Trials : Trial_Vectors.Vector;
         Loops  : Boolean := False;
         Value  : Boolean;
         Asked  : constant Wanted := Asked_For (Item);
         --  Whether the tried line is the one above the report, broken
         --  before the value it asked for (Broken_At is the reported
         --  line's first byte).
         Broken    : Boolean := False;
         Broken_At : Natural := 0;
      begin
         while Line_First > 1 and then Bytes (Line_First - 1) /= ASCII.LF
         loop
            Line_First := Line_First - 1;
         end loop;
         while Line_Last < Bytes'Last and then Bytes (Line_Last) /= ASCII.LF
         loop
            Line_Last := Line_Last + 1;
         end loop;
         if Bytes (Line_Last) = ASCII.LF then
            Line_Last := Line_Last - 1;
         end if;
         --  A report at a closer or a divider that begins its line is
         --  about the statement before it, which the closer cut short.
         declare
            First_Word : Natural := Line_First;
         begin
            while First_Word <= Line_Last
              and then Bytes (First_Word) in ' ' | ASCII.HT
            loop
               First_Word := First_Word + 1;
            end loop;
            if At_Byte = First_Word
              and then Line_First > 2
              and then
                (Starts_With (First_Word, Line_Last, "end")
                 or else Starts_With (First_Word, Line_Last, "else")
                 or else Starts_With (First_Word, Line_Last, "elsif")
                 or else Starts_With (First_Word, Line_Last, "complete"))
            then
               Line_Last := Line_First - 2;
               Line_First := Line_Last;
               while Line_First > 1
                 and then Bytes (Line_First - 1) /= ASCII.LF
               loop
                  Line_First := Line_First - 1;
               end loop;
            end if;
         end;
         if Line_Last < Line_First then
            Result.Append (Item);
            return;
         end if;

         Line_Tokens (Line_First, Line_Last, Pieces, Clean);
         Value := Returns_Value and then Ends_Block (Line_Last);
         Errors_After := Errors_Between (Line_Last + 1, Routine_Last - 1);
         --  A report that spans more than one token was written for the
         --  construct it spans, and says more than a repair would.
         if Where.Last > Where.First
           and then Diag.Label_Count (Item) > 0
           and then Rows.Named (Diag.Code (Item)) = Rows.Expression_Expected
           and then Natural (Where.First) + 1 >= Line_First
           and then Natural (Where.Last) <= Line_Last
           and then not (for some One of Pieces =>
                           Natural (Where.First) + 1 = One.First
                           and then Natural (Where.Last) = One.Last)
         then
            Result.Append (Item);
            return;
         end if;

         --  A line the grammar read as continuing the one above may be a
         --  statement of its own, with the value the line above asked for
         --  left out at its end: `local =` then `r = local`.  The line
         --  above is tried instead, with a value written at its end; the
         --  repair counts only if this line then parses unchanged as the
         --  statement it begins.  A program that parses is never tried,
         --  so a continuation the grammar accepts keeps its meaning.
         if Clean and then not Pieces.Is_Empty
           and then Continues (Line_First)
           and then Line_First > 2
           and then Pieces (1).Kind not in Tok.Kw_End | Tok.Kw_Else
             | Tok.Kw_Elsif | Tok.Kw_Complete | Tok.Right_Paren
             | Tok.Right_Bracket | Tok.Comma
           and then
             (Parses (Bytes (Line_First .. Line_Last), False, Value)
              --  A statement that goes on past its line, such as a call
              --  whose argument is a block, is left to the routine's
              --  reparse below to judge.
              or else (Pieces (1).Kind in Tok.Kw_Defer | Tok.Kw_Undo
                         | Tok.Kw_Mut | Tok.Identifier | Tok.Underscore
                         | Tok.Kw_Return | Tok.Kw_If | Tok.Kw_Match
                         | Tok.Kw_Loop | Tok.Kw_While | Tok.Kw_For
                       and then Opens_More (Pieces))
              --  The first arm under a `match` head is an arm, which no
              --  statement parses as.
              or else (Natural (Pieces.Length) >= 2
                       and then Pieces (1).Kind
                         in Tok.Identifier | Tok.Underscore
                       and then Pieces (2).Kind = Tok.Colon
                       and then Above_Begins_Match (Line_First)))
         then
            declare
               Above_Last  : constant Natural := Line_First - 2;
               Above_First : Natural := Above_Last;
            begin
               while Above_First > 1
                 and then Bytes (Above_First - 1) /= ASCII.LF
               loop
                  Above_First := Above_First - 1;
               end loop;
               if Above_Last >= Body_First
                 and then not Continues (Above_First)
               then
                  Broken := True;
                  Broken_At := Line_First;
                  Line_First := Above_First;
                  Line_Last := Above_Last;
                  Line_Tokens (Line_First, Line_Last, Pieces, Clean);
                  Value := False;
               end if;
            end;
         end if;

         --  A report the parser made at a measure or an address names
         --  what `lenof` and `addr` take; mending the line by removing the
         --  word would change what it does, so the report stands.
         if (for some Position in 1 .. Natural (Pieces.Length) =>
               Natural (Where.First) + 1 = Pieces (Position).First
               and then (Pieces (Position).Kind = Tok.Kw_Addr
                         or else Bytes (Pieces (Position).First
                                        .. Pieces (Position).Last) = "lenof"
                         --  A measure whose operand goes on past its
                         --  name, `lenof p.val`: removing a token there
                         --  turns `lenof` into a name and the line into
                         --  something no one wrote.
                         or else (Position > 2
                                  and then Bytes
                                    (Pieces (Position - 2).First
                                     .. Pieces (Position - 2).Last)
                                    = "lenof"
                                  and then Pieces (Position - 1).Kind
                                    = Tok.Identifier
                                  and then Pieces (Position).Kind
                                    in Tok.Dot | Tok.Left_Bracket)))
           or else Starts_Said (Diag.Message (Diag.Primary (Item)),
                                "`addr` takes")
         then
            Result.Append (Item);
            return;
         end if;

         --  A statement written where a value belongs is the parser's to
         --  say: removing its word changes what the line does.
         if not Broken
           and then Rows.Named (Diag.Code (Item)) = Rows.Expression_Expected
           and then (for some One of Pieces =>
                       Natural (Where.First) + 1 = One.First
                       and then One.Kind in Tok.Kw_Inc | Tok.Kw_Dec
                         | Tok.Kw_Return | Tok.Kw_Fail | Tok.Kw_Loop
                         | Tok.Kw_While | Tok.Kw_For)
         then
            Result.Append (Item);
            return;
         end if;

         --  A report that carries its own fix keeps it unless the line
         --  break was the mistake.  There its fix is for a statement that
         --  was never written -- `==` in `local = r = local` leaves the
         --  line refused -- so the repair replaces it; anywhere else the
         --  fix's own rule stands.
         if Diag.Fix_Count (Item) > 0 and then not Broken then
            Result.Append (Item);
            return;
         end if;

         --  Only a line that is one whole statement is tried: not a
         --  closer or a divider, not a match arm, whose pattern is no
         --  statement, and not a line that continues the one above it.
         if Broken then
            if not Clean or else Pieces.Is_Empty
              or else Natural (Pieces.Length) > Token_Limit
            then
               Result.Append (Item);
               return;
            end if;
         elsif not Clean or else Pieces.Is_Empty
           or else Natural (Pieces.Length) > Token_Limit
           or else Pieces (1).Kind in Tok.Kw_End | Tok.Kw_Else
             | Tok.Kw_Elsif | Tok.Kw_Complete | Tok.Right_Paren
             | Tok.Right_Bracket | Tok.Comma
           or else (In_A_Match (Line_First)
                    and then Natural (Pieces.Length) > 1
                    and then Pieces (2).Kind in Tok.Colon | Tok.Left_Paren)
           or else Continues (Line_First)
           or else Parses (Bytes (Line_First .. Line_Last), False, Value)
         then
            Result.Append (Item);
            return;
         end if;
         --  `break` and `continue` parse only in a loop.
         for One of Pieces loop
            if One.Kind in Tok.Kw_Break | Tok.Kw_Continue then
               Loops := True;
            end if;
         end loop;

         declare
            procedure Consider (One : Trial);

            --  Two changes that write the same line are one repair.
            procedure Consider (One : Trial) is
               Written : constant String :=
                 Applied (Pieces, Line_First, Line_Last, One);
            begin
               --  Two changes that write the same tokens are one repair,
               --  however the blanks between them fall.
               for Earlier of Found_Trials loop
                  if Earlier = One
                    or else Unspaced
                      (Applied (Pieces, Line_First, Line_Last, Earlier))
                      = Unspaced (Written)
                  then
                     return;
                  end if;
               end loop;
               --  The line alone, then its routine with it: a repair must
               --  parse where it is written, which a line read alone cannot
               --  show for an arm of a `match`, a labelled block or a loop.
               --  The routine is as far as a trial reads.
               --  A broken line may be the head of a construct whose body
               --  follows, which only the routine's reparse can judge.
               if Squeezed (Written) /= ""
                 and then (Broken or else Parses (Written, Loops, Value))
                 and then Mends_File
                   (Bytes (Routine_First .. Line_First - 1) & Written
                    & Bytes (Line_Last + 1 .. Routine_Last),
                    Line_First - Routine_First + 1)
               then
                  Found_Trials.Append (One);
               end if;
            end Consider;
            Stopped : constant Natural :=
              (if Broken then 0 else Stop_Token (Item, Pieces));
         begin
            if Broken then
               Consider
                 ((Appended, Natural (Pieces.Length),
                   (if Pieces.Last_Element.Kind in Tok.Dot | Tok.Kw_Addr
                    then Want_Name else Want_Value)));
               goto Tried;
            end if;
            --  The order is the order the repairs are offered in: those
            --  that keep every token written come first.  A word written
            --  twice in a row is the one removal that keeps what was meant,
            --  so it leads.  Then a word moved to the statement's start or
            --  two neighbours swapped; then the token the parser asked for,
            --  where it stopped, and anywhere else; and last, a token
            --  removed, which discards something the person wrote.
            for Position in 2 .. Natural (Pieces.Length) loop
               if Bytes (Pieces (Position).First .. Pieces (Position).Last)
                 = Bytes (Pieces (Position - 1).First
                          .. Pieces (Position - 1).Last)
               then
                  Consider ((Deleted, Position, Asked));
               end if;
            end loop;
            for Position in 2 .. Natural (Pieces.Length) loop
               if Pieces (Position).Kind in Tok.Kw_Mut | Tok.Kw_Public
                 | Tok.Kw_Try | Tok.Kw_Inc | Tok.Kw_Dec
               then
                  Consider ((Moved, Position, Asked));
               end if;
            end loop;
            for Position in 1 .. Natural (Pieces.Length) - 1 loop
               Consider ((Swapped, Position, Asked));
            end loop;
            --  A name followed by one operand, as a conversion written
            --  without its parentheses: `i32 x` for `i32(x)`.
            for Position in 1 .. Natural (Pieces.Length) - 1 loop
               if Pieces (Position).Kind = Tok.Identifier
                 and then (Pieces (Position + 1).Kind = Tok.Identifier
                           or else Tok.Is_Literal
                             (Pieces (Position + 1).Kind))
               then
                  Consider ((Called, Position, Asked));
               end if;
            end loop;
            --  A binding whose `:` was left out: `x u32 = 1`.  The one
            --  insertion besides what the parser asked for, because a
            --  line that begins with a name and another word is a binding
            --  more often than anything else the grammar has.
            if Natural (Pieces.Length) >= 2
              and then Pieces (1).Kind = Tok.Identifier
              and then Pieces (2).Kind /= Tok.Colon
            then
               Consider ((Inserted, 2, Want_Colon));
            end if;
            if Stopped /= 0 then
               Consider ((Inserted, Stopped, Asked));
            elsif Stop_At_End (Item, Pieces) then
               Consider ((Appended, Natural (Pieces.Length), Asked));
            end if;
            for Position in 1 .. Natural (Pieces.Length) loop
               Consider ((Inserted, Position, Asked));
            end loop;
            Consider ((Appended, Natural (Pieces.Length), Asked));
            --  A word that says what a statement or an operand does is
            --  never removed to mend it: the line would parse and mean
            --  something else, which no repair may do quietly.
            for Position in 1 .. Natural (Pieces.Length) loop
               if Pieces (Position).Kind not in Tok.Kw_In | Tok.Kw_Inout
                 | Tok.Kw_Inc | Tok.Kw_Dec | Tok.Kw_Return
                 | Tok.Kw_Fail | Tok.Kw_Defer | Tok.Kw_Undo | Tok.Kw_Addr
                 and then Bytes (Pieces (Position).First
                                 .. Pieces (Position).Last) /= "lenof"
               then
                  Consider ((Deleted, Position, Asked));
               end if;
            end loop;
            <<Tried>>
            null;
         end;

         if Found_Trials.Is_Empty then
            Result.Append (Item);
            return;
         end if;

         --  The report is about the first repair, on the token it changes.
         declare
            Best   : constant Trial := Found_Trials.First_Element;
            --  Exact means a tool may apply the repair unasked.  A change
            --  that only makes the line parse guesses what was meant, even
            --  when it is the only one found.  It is Exact only when every
            --  change that mends the line writes the same line, and that
            --  line is the one a word written twice in a row gives with one
            --  copy removed: either copy gives it, so nothing is guessed.
            --  Changes that write the same tokens were merged as they were
            --  found, so one entry is every change that mends the line.
            Level  : constant Diag.Applicability :=
              (if Natural (Found_Trials.Length) = 1
                 and then Removes_A_Copy (Found_Trials.First_Element, Pieces)
               then Diag.Exact
               else Diag.Likely);
            Here   : constant Piece := Pieces (Best.At_Token);
            --  A value left out before a line break is a missing value,
            --  whatever the parser made of the line it took for one.
            Restated_Report : Diag.Diagnostic := Diag.Make
              (Code    =>
                 (if Broken and then Pieces.Last_Element.Kind = Tok.Dot
                  then Rows.Code (Rows.Name_Expected)
                  elsif Broken
                  then Rows.Code (Rows.Expression_Expected)
                  else Diag.Code (Item)),
               Level   => Diag.Level (Item),
               Source  => Source,
               Where   =>
                 (First => Landin.Source.Byte_Offset (Here.First - 1),
                  Last  => Landin.Source.Byte_Offset (Here.Last)),
               Message => Said (Best, Pieces));
         begin
            --  The code's row fixes how many labels it carries, so the
            --  parser's label stays, unless it is now the primary's span,
            --  when it says what that token is for.  A broken line's one
            --  label is the statement the next line begins.
            --  L0100's row takes no second place; the name is the
            --  whole complaint.
            if Broken and then Pieces.Last_Element.Kind /= Tok.Dot then
               declare
                  Next : Natural := Broken_At;
                  Last_Byte : Natural;
               begin
                  while Bytes (Next) in ' ' | ASCII.HT loop
                     Next := Next + 1;
                  end loop;
                  Last_Byte := Next;
                  while Last_Byte < Bytes'Last
                    and then Bytes (Last_Byte + 1)
                      in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_'
                  loop
                     Last_Byte := Last_Byte + 1;
                  end loop;
                  Diag.Add_Label
                    (Restated_Report,
                     Diag.Make_Label
                       (Source,
                        (First => Landin.Source.Byte_Offset (Next - 1),
                         Last  => Landin.Source.Byte_Offset (Last_Byte)),
                        "this begins the next statement"));
               end;
            end if;
            for Position in 1 .. (if Broken then 0
                                  else Diag.Label_Count (Item)) loop
               declare
                  Other : constant Diag.Label :=
                    Diag.Nth_Label (Item, Position);
               begin
                  if Diag.Span_Of (Other)
                    /= Diag.Span_Of (Diag.Primary (Restated_Report))
                  then
                     Diag.Add_Label (Restated_Report, Other);
                  else
                     Diag.Add_Label
                       (Restated_Report,
                        Diag.Make_Label
                          (Source,
                           Diag.Span_Of (Diag.Primary (Item)),
                           "where the parse stopped"));
                  end if;
               end;
            end loop;
            --  The parser's note is the rule of the construct it was in,
            --  which is not the rule this mistake broke.  The statement as
            --  it parses is what a reader compares with what they wrote.
            --  The code's row fixes how many notes there are.
            for Position in 1 .. (if Broken then 1
                                  else Diag.Note_Count (Item)) loop
               if Position = 1 then
                  Diag.Add_Note
                    (Restated_Report,
                     "written as `"
                     & Unindented
                         (Applied (Pieces, Line_First, Line_Last, Best))
                     & (if Broken then "` the routine parses"
                        else "` the line parses"));
               else
                  Diag.Add_Note
                    (Restated_Report, Diag.Nth_Note (Item, Position));
               end if;
            end loop;
            for Position in 1 .. Natural (Found_Trials.Length) loop
               exit when Position > 3;
               Diag.Add_Fix
                 (Restated_Report,
                  Fix_Of (Pieces, Line_First, Line_Last,
                          Found_Trials (Position), Level));
            end loop;
            Result.Append (Restated_Report);
         end;
      end Try_Line;
   begin
      for Index in 1 .. Diag.Count (Found) loop
         if Diag.Level (Diag.Get (Found, Index)) = Diag.Error then
            Error_Starts.Append
              (Natural (Diag.Span_Of
                 (Diag.Primary (Diag.Get (Found, Index))).First));
         end if;
      end loop;
      Offset_Sorting.Sort (Error_Starts);

      for Index in 1 .. Diag.Count (Found) loop
         declare
            Item : constant Diag.Diagnostic := Diag.Get (Found, Index);
            Where : constant Landin.Source.Span :=
              Diag.Span_Of (Diag.Primary (Item));
            Line : constant Natural :=
              (if Diag.Source_Of (Diag.Primary (Item)) = Source
                 and then Where.First <= Landin.Source.Length (Snapshot)
               then Natural (Landin.Source.Position_Of
                               (Snapshot, Where.First).Line)
               else 0);
         begin
            if Line = 0 or else Line = Last_Line
              or else not In_A_Body (Where)
              or else Diag.Level (Item) /= Diag.Error
              or else (Diag.Fix_Count (Item) > 0
                       and then Rows.Named (Diag.Code (Item))
                         /= Rows.Assignment_In_Expression)
              or else Rows.Named (Diag.Code (Item))
                not in Rows.Name_Expected | Rows.Type_Expected
                     | Rows.Expression_Expected | Rows.Token_Expected
                     | Rows.Stray_Token | Rows.Assignment_In_Expression
            then
               Result.Append (Item);
            else
               Try_Line (Item);
            end if;
            if Line /= 0 then
               Last_Line := Line;
            end if;
         end;
      end loop;
      return Result;
   end Restated;

end Landin.Syntax.Repairs;
