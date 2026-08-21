package body Landin.Tokens.Lexer is

   subtype Offset is Landin.Source.Byte_Offset;

   Tab : constant Character := Character'Val (9);
   LF  : constant Character := Character'Val (10);
   CR  : constant Character := Character'Val (13);

   --  The byte classes, spelled out.  Ada's own Is_Lower would answer for a
   --  Latin-1 letter, and [1750] allows UTF-8 in a comment and nowhere
   --  else, so a scanner that used it would swallow a byte it must report.
   function Is_Lower (Item : Character) return Boolean
     is (Item in 'a' .. 'z');

   function Is_Digit (Item : Character) return Boolean
     is (Item in '0' .. '9');

   function Is_Hex (Item : Character) return Boolean
     is (Is_Digit (Item)
         or else Item in 'a' .. 'f'
         or else Item in 'A' .. 'F');

   function Is_Name_Byte (Item : Character) return Boolean
     is (Is_Lower (Item) or else Is_Digit (Item) or else Item = '_');

   procedure Lex
     (From   : Landin.Source.Snapshot;
      Names  : in out Landin.Source.Names.Table;
      Into   : out Token_Stream)
   is
      Text  : constant String := Landin.Source.Text (From);
      Last  : constant Natural := Text'Last;
      Position   : Natural := Text'First;

      function Span (First, Stop : Natural) return Landin.Source.Span
        is (First => Offset (First - Text'First),
            Last  => Offset (Stop - Text'First + 1));

      procedure Emit (Kind : Token_Kind; First, Stop : Natural);

      procedure Emit (Kind : Token_Kind; First, Stop : Natural) is
      begin
         Into.Items.Append
           (Token'(Kind      => Kind,
                   Where     => Span (First, Stop),
                   Name      => Landin.Source.Names.No_Name,
                   Base      => Decimal,
                   Digit_Run => Landin.Source.Empty_Span));
      end Emit;

      procedure Complain
        (Kind   : Fault_Kind;
         First  : Natural;
         Stop   : Natural;
         Opened : Landin.Source.Span := Landin.Source.Empty_Span;
         Refused : Token_Kind := Bang);

      procedure Complain
        (Kind   : Fault_Kind;
         First  : Natural;
         Stop   : Natural;
         Opened : Landin.Source.Span := Landin.Source.Empty_Span;
         Refused : Token_Kind := Bang)
      is
      begin
         Into.Faults.Append
           (Fault'(Kind    => Kind,
                   Where   => Span (First, Stop),
                   Opened  => Opened,
                   Refused => Refused));
      end Complain;

      --  A sign, longest first, so `<=` is never `<` and `=`.  The table is
      --  Landin.Tokens' Spelling read backwards, and check.py holds the two
      --  to each other.
      function Sign_At (First : Natural; Length : out Natural)
        return Token_Kind;

      function Sign_At (First : Natural; Length : out Natural)
        return Token_Kind
      is
         Three : constant Boolean := First + 2 <= Last;
         Two   : constant Boolean := First + 1 <= Last;

         function Ahead (Count : Natural) return String
           is (Text (First .. First + Count - 1));
      begin
         if Three and then Ahead (3) in "..." | "..<" then
            Length := 3;
            return (if Ahead (3) = "..." then Dot_Dot_Dot else Dot_Dot_Less);
         end if;

         if Two then
            declare
               Pair : constant String := Ahead (2);
            begin
               Length := 2;
               if Pair = ":=" then
                  return Colon_Equal;
               elsif Pair = "==" then
                  return Equal_Equal;
               elsif Pair = "<>" then
                  return Less_Greater;
               elsif Pair = "<=" then
                  return Less_Equal;
               elsif Pair = ">=" then
                  return Greater_Equal;
               elsif Pair = "<<" then
                  return Less_Less;
               elsif Pair = ">>" then
                  return Greater_Greater;
               elsif Pair = "->" then
                  return Minus_Greater;
               elsif Pair = "+%" then
                  return Plus_Percent;
               elsif Pair = "-%" then
                  return Minus_Percent;
               elsif Pair = "*%" then
                  return Star_Percent;
               elsif Pair = ".." then
                  return Dot_Dot;
               --  [0390]'s compound assignments are one lexeme each, so
               --  enabling them later cannot change how a file that never
               --  used one was read.
               elsif Pair in "+=" | "-=" | "*=" | "/=" | "%=" | "&=" | "|="
                            | "^="
               then
                  return Compound_Assign;
               end if;
            end;
         end if;

         Length := 1;
         case Text (First) is
            when '&' => return Ampersand;
            when '|' => return Bar;
            when '^' => return Caret;
            when ':' => return Colon;
            when ',' => return Comma;
            when '=' => return Equal;
            when '>' => return Greater;
            when '(' => return Left_Paren;
            when '<' => return Less;
            when '-' => return Minus;
            when '%' => return Percent;
            when '+' => return Plus;
            when ')' => return Right_Paren;
            when '/' => return Slash;
            when '*' => return Star;
            when '~' => return Tilde;
            when '_' => return Underscore;
            when '!' => return Bang;
            when '.' => return Dot;
            when '[' => return Left_Bracket;
            when ']' => return Right_Bracket;
            when others =>
               Length := 0;
               return Unknown_Bytes;
         end case;
      end Sign_At;

      --  Whether a byte is a digit of this base.  [1770] gives each base
      --  its own digit rule, and a byte outside it makes the run
      --  malformed rather than ending it: `0b102` is one wrong literal,
      --  not a literal and a stray 2.
      function Digit_Of (Base : Integer_Base; Item : Character)
        return Boolean
        is (case Base is
               when Binary      => Item in '0' | '1',
               when Octal       => Item in '0' .. '7',
               when Decimal     => Is_Digit (Item),
               when Hexadecimal => Is_Hex (Item));

      procedure Scan_Integer;

      procedure Scan_Integer is
         First       : constant Natural := Position;
         Base        : Integer_Base := Decimal;
         Digits_From : Natural := Position;
         Prefixed    : Boolean := False;
      begin
         if Text (Position) = '0' and then Position + 1 <= Last
           and then Text (Position + 1) in 'b' | 'o' | 'x'
         then
            Base := (case Text (Position + 1) is
                        when 'b'    => Binary,
                        when 'o'    => Octal,
                        when others => Hexadecimal);
            Position := Position + 2;
            Digits_From := Position;
            Prefixed := True;
         end if;

         while Position <= Last
           and then (Is_Hex (Text (Position)) or else Text (Position) = '_')
         loop
            Position := Position + 1;
         end loop;

         --  A float is one lexeme, named, so [1830] can refuse it rather
         --  than report a stray dot [0210].
         if not Prefixed and then Position + 1 <= Last
           and then Text (Position) = '.'
           and then Is_Digit (Text (Position + 1))
         then
            Position := Position + 1;
            while Position <= Last
              and then (Is_Digit (Text (Position))
                        or else Text (Position) = '_')
            loop
               Position := Position + 1;
            end loop;
            Emit (Float_Literal, First, Position - 1);
            Complain (Not_Enabled, First, Position - 1,
                      Refused => Float_Literal);
            return;
         end if;

         declare
            Run  : constant String := Text (Digits_From .. Position - 1);
            Good : Boolean := Run'Length > 0
              and then Run (Run'First) /= '_'
              and then Run (Run'Last) /= '_';
         begin
            for Index in Run'Range loop
               exit when not Good;
               Good := Run (Index) = '_'
                 or else Digit_Of (Base, Run (Index));
            end loop;

            if Good then
               Into.Items.Append
                 (Token'(Kind      => Integer_Literal,
                         Where     => Span (First, Position - 1),
                         Name      => Landin.Source.Names.No_Name,
                         Base      => Base,
                         Digit_Run => Span (Digits_From, Position - 1)));
            else
               Emit (Malformed_Integer, First, Position - 1);
               Complain (Malformed_Integer_Run, First, Position - 1);
            end if;
         end;
      end Scan_Integer;

      function Ahead (Text_To_Match : String) return Boolean
        is (Position + Text_To_Match'Length - 1 <= Last
            and then Text (Position .. Position + Text_To_Match'Length - 1)
                     = Text_To_Match);

      procedure Scan_Comment;

      --  [1780]: the longest opener decides the form, and the form decides
      --  where the comment ends rather than the general longest-token rule.
      procedure Scan_Comment is
         First : constant Natural := Position;
      begin
         if Ahead ("--(") then
            declare
               Depth : Natural := 1;
            begin
               Position := Position + 3;
               while Position <= Last and then Depth > 0 loop
                  if Ahead ("--(")
                  then
                     Depth := Depth + 1;
                     Position := Position + 3;
                  elsif Ahead (")--") then
                     Depth := Depth - 1;
                     Position := Position + 3;
                  else
                     Position := Position + 1;
                  end if;
               end loop;

               if Depth > 0 then
                  --  The opener and the end of the file are the two places
                  --  a reader looks.
                  Complain (Unterminated_Block_Comment,
                            First  => Last,
                            Stop   => Last,
                            Opened => Span (First, First + 2));
               end if;
            end;
            return;
         end if;

         --  A doc comment attaches to what follows [0030], so its span is
         --  kept even though it produces no token.
         declare
            Doc : constant Boolean := Ahead ("---");
         begin
            while Position <= Last and then Text (Position) /= LF
              and then Text (Position) /= CR
            loop
               Position := Position + 1;
            end loop;

            if Doc then
               Into.Docs.Append (Span (First, Position - 1));
            end if;
         end;
      end Scan_Comment;

   begin
      --  A stream is built from empty.  Into is limited and passed by
      --  reference, so a caller reusing one would otherwise get this
      --  file's tokens appended to the last file's.
      Into.Items.Clear;
      Into.Faults.Clear;
      Into.Docs.Clear;
      Into.Source := Landin.Source.Id (From);

      while Position <= Last loop
         declare
            Here : constant Character := Text (Position);
         begin
            if Here = ' ' or else Here = Tab or else Here = LF
              or else Here = CR
            then
               Position := Position + 1;

            elsif Ahead ("--") then
               Scan_Comment;

            elsif Is_Digit (Here) then
               Scan_Integer;

            elsif Is_Lower (Here) or else Here = '_' then
               declare
                  First : constant Natural := Position;
               begin
                  while Position <= Last
                    and then Is_Name_Byte (Text (Position))
                  loop
                     Position := Position + 1;
                  end loop;

                  declare
                     Run  : constant String := Text (First .. Position - 1);
                     Word : Token_Kind := Identifier;
                  begin
                     --  A lone '_' is the discard of [1020], which the
                     --  identifier rule refuses on purpose [1760].
                     if Run = "_" then
                        Emit (Underscore, First, Position - 1);
                     else
                        for Reserved in Reserved_Word loop
                           if Spelling (Reserved) = Run then
                              Word := Reserved;
                           end if;
                        end loop;

                        if Word = Identifier then
                           Into.Items.Append
                             (Token'(Kind      => Identifier,
                                     Where     => Span (First, Position - 1),
                                     Name      =>
                                       Landin.Source.Names.Intern
                                         (Names, Run),
                                     Base      => Decimal,
                                     Digit_Run =>
                                       Landin.Source.Empty_Span));
                        else
                           Emit (Word, First, Position - 1);
                        end if;
                     end if;
                  end;
               end;

            else
               declare
                  Length : Natural;
                  Kind   : constant Token_Kind := Sign_At (Position, Length);
                  First  : constant Natural := Position;
               begin
                  if Length = 0 then
                     --  A run of unspellable bytes is one token, so a
                     --  parser has something standing in the hole.  It
                     --  ends at the first byte that could start a token,
                     --  or it would swallow the rest of the file.
                     while Position <= Last loop
                        exit when Text (Position) = ' '
                          or else Text (Position) = Tab
                          or else Text (Position) = LF
                          or else Text (Position) = CR
                          or else Is_Lower (Text (Position))
                          or else Is_Digit (Text (Position))
                          or else Text (Position) = '_';
                        declare
                           Ahead_Length : Natural;
                           Ahead_Kind   : constant Token_Kind :=
                             Sign_At (Position, Ahead_Length);
                        begin
                           exit when Ahead_Length > 0;
                           pragma Assert (Ahead_Kind = Unknown_Bytes);
                        end;
                        Position := Position + 1;
                     end loop;
                     Emit (Unknown_Bytes, First, Position - 1);
                     Complain (Unknown_Byte_Run, First, Position - 1);
                  else
                     Position := Position + Length;
                     Emit (Kind, First, Position - 1);
                     if Kind in Deferred_Kind then
                        Complain (Not_Enabled, First, Position - 1,
                                  Refused => Kind);
                     end if;
                  end if;
               end;
            end if;
         end;
      end loop;

      Emit (End_Of_Input, Last + 1, Last);
   end Lex;

end Landin.Tokens.Lexer;
