package body Landin.Tokens.Text is

   function Hex_Value (Item : Character) return Integer
     is (case Item is
            when '0' .. '9' => Character'Pos (Item) - Character'Pos ('0'),
            when 'a' .. 'f' => Character'Pos (Item) - Character'Pos ('a') + 10,
            when 'A' .. 'F' => Character'Pos (Item) - Character'Pos ('A') + 10,
            when others     => -1);

   function Is_Continuation (Item : Character) return Boolean
     is (Character'Pos (Item) in 16#80# .. 16#BF#);

   function UTF8_Length
     (Lexeme : String; At_Byte : Positive; Last : Natural) return Natural;

   function UTF8_Length
     (Lexeme : String; At_Byte : Positive; Last : Natural) return Natural
   is
      Lead : constant Natural := Character'Pos (Lexeme (At_Byte));

      function Byte (Offset : Natural) return Natural
        is (Character'Pos (Lexeme (At_Byte + Offset)));

      function Has (Count : Positive) return Boolean
        is (At_Byte + Count - 1 <= Last);
   begin
      if Lead <= 16#7F# then
         return 1;
      elsif Lead in 16#C2# .. 16#DF# then
         return
           (if Has (2) and then Is_Continuation (Lexeme (At_Byte + 1))
            then 2 else 0);
      elsif Lead in 16#E0# .. 16#EF# then
         return
           (if Has (3)
              and then
                (if Lead = 16#E0# then Byte (1) in 16#A0# .. 16#BF#
                 elsif Lead = 16#ED# then Byte (1) in 16#80# .. 16#9F#
                 else Is_Continuation (Lexeme (At_Byte + 1)))
              and then Is_Continuation (Lexeme (At_Byte + 2))
            then 3 else 0);
      elsif Lead in 16#F0# .. 16#F4# then
         return
           (if Has (4)
              and then
                (if Lead = 16#F0# then Byte (1) in 16#90# .. 16#BF#
                 elsif Lead = 16#F4# then Byte (1) in 16#80# .. 16#8F#
                 else Is_Continuation (Lexeme (At_Byte + 1)))
              and then Is_Continuation (Lexeme (At_Byte + 2))
              and then Is_Continuation (Lexeme (At_Byte + 3))
            then 4 else 0);
      end if;
      return 0;
   end UTF8_Length;

   function UTF8_Value
     (Lexeme : String; At_Byte : Positive; Count : Positive) return Natural;

   function UTF8_Value
     (Lexeme : String; At_Byte : Positive; Count : Positive) return Natural
   is
      function Byte (Offset : Natural) return Natural
        is (Character'Pos (Lexeme (At_Byte + Offset)));
   begin
      return
        (case Count is
            when 1 => Byte (0),
            when 2 => (Byte (0) - 16#C0#) * 64
                      + Byte (1) - 16#80#,
            when 3 => (Byte (0) - 16#E0#) * 4_096
                      + (Byte (1) - 16#80#) * 64
                      + Byte (2) - 16#80#,
            when 4 => (Byte (0) - 16#F0#) * 262_144
                      + (Byte (1) - 16#80#) * 4_096
                      + (Byte (2) - 16#80#) * 64
                      + Byte (3) - 16#80#,
            when others => raise Program_Error);
   end UTF8_Value;

   procedure Decode
     (Lexeme      : String;
      Bytes       : out String;
      Length      : out Natural;
      Fault       : out Problem;
      Fault_First : out Natural;
      Fault_Last  : out Natural)
   is
      --  The content sits between the quotes.  An unterminated literal
      --  never reaches here: the scanner reported it and the parser has no
      --  node for it.
      First : constant Positive := Lexeme'First + 1;
      Last  : constant Natural  := Lexeme'Last - 1;
      At_Byte : Positive := First;

      procedure Keep (Item : Character);

      procedure Keep (Item : Character) is
      begin
         Length := Length + 1;
         Bytes (Bytes'First + Length - 1) := Item;
      end Keep;

      procedure Fail (Which : Problem; Stop : Natural);

      procedure Fail (Which : Problem; Stop : Natural) is
      begin
         Fault := Which;
         Fault_First := At_Byte - Lexeme'First;
         Fault_Last := Stop - Lexeme'First + 1;
      end Fail;
   begin
      Length := 0;
      Fault := Well_Formed;
      Fault_First := 0;
      Fault_Last := 0;
      Bytes := [others => ' '];

      while At_Byte <= Last loop
         if Lexeme (At_Byte) /= '\' then
            declare
               Count : constant Natural :=
                 UTF8_Length (Lexeme, At_Byte, Last);
            begin
               if Count = 0 then
                  Fail (Invalid_UTF8_Source, At_Byte);
                  return;
               end if;
               for Offset in 0 .. Count - 1 loop
                  Keep (Lexeme (At_Byte + Offset));
               end loop;
               At_Byte := At_Byte + Count;
            end;
         elsif At_Byte = Last then
            Fail (Dangling_Backslash, At_Byte);
            return;
         else
            case Lexeme (At_Byte + 1) is
               when 'n' => Keep (Character'Val (10));
               when 'r' => Keep (Character'Val (13));
               when 't' => Keep (Character'Val (9));
               when 'e' => Keep (Character'Val (27));
               when '\' => Keep ('\');
               when '"' => Keep ('"');
               when ''' => Keep (''');
               when 'x' =>
                  if At_Byte + 3 > Last
                    or else Hex_Value (Lexeme (At_Byte + 2)) < 0
                    or else Hex_Value (Lexeme (At_Byte + 3)) < 0
                  then
                     Fail (Short_Byte_Escape, Natural'Min (Last, At_Byte + 3));
                     return;
                  end if;
                  Keep
                    (Character'Val
                       (Hex_Value (Lexeme (At_Byte + 2)) * 16
                        + Hex_Value (Lexeme (At_Byte + 3))));
                  At_Byte := At_Byte + 2;
               when 'u' =>
                  declare
                     Stop : Natural := At_Byte + 2;
                     Value : Natural := 0;
                     Digit_Count : Natural := 0;
                  begin
                     if Stop > Last or else Lexeme (Stop) /= '{' then
                        Fail
                          (Malformed_Codepoint_Escape,
                           Natural'Min (Last, Stop));
                        return;
                     end if;
                     Stop := Stop + 1;
                     while Stop <= Last and then Lexeme (Stop) /= '}' loop
                        declare
                           Digit : constant Integer :=
                             Hex_Value (Lexeme (Stop));
                        begin
                           if Digit < 0
                             or else Value > (16#10_FFFF# - Digit) / 16
                           then
                              Fail (Malformed_Codepoint_Escape, Stop);
                              return;
                           end if;
                           Value := Value * 16 + Digit;
                           Digit_Count := Digit_Count + 1;
                        end;
                        Stop := Stop + 1;
                     end loop;
                     if Stop > Last
                       or else Digit_Count = 0
                       or else Value in 16#D800# .. 16#DFFF#
                     then
                        Fail
                          (Malformed_Codepoint_Escape,
                           Natural'Min (Last, Stop));
                        return;
                     end if;
                     Fail (Codepoint_Where_Bytes_Are_Meant, Stop);
                     return;
                  end;
               when others =>
                  Fail (Unknown_Escape, At_Byte + 1);
                  return;
            end case;
            At_Byte := At_Byte + 2;
         end if;
      end loop;
   end Decode;

   procedure Decode_Character
     (Lexeme      : String;
      Value       : out Natural;
      Fault       : out Problem;
      Fault_First : out Natural;
      Fault_Last  : out Natural)
   is
      First   : constant Positive := Lexeme'First + 1;
      Last    : constant Natural  := Lexeme'Last - 1;
      At_Byte : Positive := First;

      procedure Fail (Which : Problem; Stop : Natural);

      procedure Fail (Which : Problem; Stop : Natural) is
      begin
         Fault := Which;
         Fault_First := At_Byte - Lexeme'First;
         Fault_Last := Stop - Lexeme'First + 1;
      end Fail;
   begin
      Value := 0;
      Fault := Well_Formed;
      Fault_First := 0;
      Fault_Last := 0;

      if First > Last then
         Fault := Empty_Character;
         Fault_First := 0;
         Fault_Last := Lexeme'Length;
         return;
      end if;

      if Lexeme (At_Byte) /= '\' then
         declare
            Count : constant Natural :=
              UTF8_Length (Lexeme, At_Byte, Last);
         begin
            if Count = 0 then
               Fail (Invalid_UTF8_Source, At_Byte);
               return;
            end if;
            Value := UTF8_Value (Lexeme, At_Byte, Count);
            At_Byte := At_Byte + Count;
         end;
      elsif At_Byte = Last then
         Fail (Dangling_Backslash, At_Byte);
         return;
      else
         case Lexeme (At_Byte + 1) is
            when 'n' => Value := 10;
            when 'r' => Value := 13;
            when 't' => Value := 9;
            when 'e' => Value := 27;
            when '\' => Value := Character'Pos ('\');
            when '"' => Value := Character'Pos ('"');
            when ''' => Value := Character'Pos (''');
            when 'x' =>
               Fail
                 (Byte_Where_Codepoint_Is_Meant,
                  Natural'Min (Last, At_Byte + 3));
               return;
            when 'u' =>
               declare
                  Stop        : Natural := At_Byte + 2;
                  Codepoint   : Natural := 0;
                  Digit_Count : Natural := 0;
               begin
                  if Stop > Last or else Lexeme (Stop) /= '{' then
                     Fail
                       (Malformed_Codepoint_Escape,
                        Natural'Min (Last, Stop));
                     return;
                  end if;
                  Stop := Stop + 1;
                  while Stop <= Last and then Lexeme (Stop) /= '}' loop
                     declare
                        Digit : constant Integer := Hex_Value (Lexeme (Stop));
                     begin
                        if Digit < 0
                          or else Codepoint > (16#10_FFFF# - Digit) / 16
                        then
                           Fail (Malformed_Codepoint_Escape, Stop);
                           return;
                        end if;
                        Codepoint := Codepoint * 16 + Digit;
                        Digit_Count := Digit_Count + 1;
                     end;
                     Stop := Stop + 1;
                  end loop;
                  if Stop > Last
                    or else Digit_Count = 0
                    or else Codepoint in 16#D800# .. 16#DFFF#
                  then
                     Fail
                       (Malformed_Codepoint_Escape,
                        Natural'Min (Last, Stop));
                     return;
                  end if;
                  Value := Codepoint;
                  At_Byte := Stop + 1;
                  if At_Byte <= Last then
                     Fail (Multiple_Characters, Last);
                  end if;
                  return;
               end;
            when others =>
               Fail (Unknown_Escape, At_Byte + 1);
               return;
         end case;
         At_Byte := At_Byte + 2;
      end if;

      if At_Byte <= Last then
         Fail (Multiple_Characters, Last);
      end if;
   end Decode_Character;

   procedure Decode_Raw
     (Lexeme      : String;
      Bytes       : out String;
      Length      : out Natural;
      Fault       : out Problem;
      Fault_First : out Natural;
      Fault_Last  : out Natural)
   is
      Opening_Quotes : Natural := 0;
      Cursor : Natural := Lexeme'First;

      procedure Keep (Item : Character);

      procedure Keep (Item : Character) is
      begin
         Length := Length + 1;
         Bytes (Bytes'First + Length - 1) := Item;
      end Keep;
   begin
      Length := 0;
      Fault := Well_Formed;
      Fault_First := 0;
      Fault_Last := 0;
      Bytes := [others => ' '];

      while Cursor <= Lexeme'Last and then Lexeme (Cursor) = '"' loop
         Opening_Quotes := Opening_Quotes + 1;
         Cursor := Cursor + 1;
      end loop;

      if Opening_Quotes < 3 then
         raise Program_Error with "a non-raw token reached raw decoding";
      end if;

      declare
         Content_First : constant Positive :=
           Lexeme'First + Opening_Quotes;
         Close_First : constant Positive :=
           Lexeme'Last - Opening_Quotes + 1;
         Content_Last : constant Natural := Close_First - 1;
         Line_First : Positive := Close_First;
         Indent_Length : Natural;
         At_Byte : Positive := Content_First;
         At_Line_Start : Boolean := False;

         procedure Fail (Which : Problem; Stop : Natural);

         procedure Fail (Which : Problem; Stop : Natural) is
         begin
            Fault := Which;
            Fault_First := At_Byte - Lexeme'First;
            Fault_Last := Stop - Lexeme'First + 1;
         end Fail;

         function Is_Horizontal (Item : Character) return Boolean
           is (Item in ' ' | Character'Val (9));
      begin
         while Line_First > Content_First
           and then Lexeme (Line_First - 1) not in Character'Val (10)
                                                   | Character'Val (13)
         loop
            Line_First := Line_First - 1;
         end loop;

         Indent_Length :=
           (if Line_First = Content_First
            then 0
            else Close_First - Line_First);
         for Position in Line_First .. Close_First - 1 loop
            if not Is_Horizontal (Lexeme (Position)) then
               Indent_Length := 0;
               exit;
            end if;
         end loop;

         while At_Byte <= Content_Last loop
            if At_Line_Start and then Indent_Length > 0 then
               declare
                  Line_Last : Natural := At_Byte;
                  Prefix    : Natural := 0;
               begin
                  while Line_Last <= Content_Last
                    and then Lexeme (Line_Last) not in Character'Val (10)
                                                     | Character'Val (13)
                  loop
                     Line_Last := Line_Last + 1;
                  end loop;

                  while At_Byte + Prefix < Line_Last
                    and then Is_Horizontal (Lexeme (At_Byte + Prefix))
                  loop
                     Prefix := Prefix + 1;
                  end loop;

                  if At_Byte + Prefix = Line_Last then
                     --  A blank line carries no observable indentation.
                     At_Byte := At_Byte + Prefix;
                  elsif Prefix < Indent_Length
                    or else Lexeme
                      (At_Byte .. At_Byte + Indent_Length - 1)
                        /= Lexeme (Line_First .. Close_First - 1)
                  then
                     Fail
                       (Inconsistent_Raw_Indentation,
                        Natural'Min (Content_Last,
                                     At_Byte + Indent_Length - 1));
                     return;
                  else
                     At_Byte := At_Byte + Indent_Length;
                  end if;
               end;
               At_Line_Start := False;
            end if;

            exit when At_Byte > Content_Last;

            declare
               Count : constant Natural :=
                 UTF8_Length (Lexeme, At_Byte, Content_Last);
            begin
               if Count = 0 then
                  Fail (Invalid_UTF8_Source, At_Byte);
                  return;
               end if;
               for Offset in 0 .. Count - 1 loop
                  Keep (Lexeme (At_Byte + Offset));
               end loop;
               At_Line_Start := Lexeme (At_Byte) in Character'Val (10)
                                                   | Character'Val (13);
               At_Byte := At_Byte + Count;
            end;
         end loop;
      end;
   end Decode_Raw;

   procedure Decode_View
     (Lexeme      : String;
      Raw         : Boolean;
      Encoding    : Literal_Encoding;
      Units       : out Code_Unit_Array;
      Length      : out Natural;
      Fault       : out Problem;
      Fault_First : out Natural;
      Fault_Last  : out Natural)
   is
      procedure Keep (Item : Code_Unit);
      procedure Keep_Codepoint (Value : Natural);

      procedure Keep (Item : Code_Unit) is
      begin
         Length := Length + 1;
         Units (Units'First + Length - 1) := Item;
      end Keep;

      procedure Keep_Codepoint (Value : Natural) is
      begin
         if Encoding = UTF16_Units then
            if Value <= 16#FFFF# then
               Keep (Code_Unit (Value));
            else
               declare
                  Rest : constant Natural := Value - 16#1_0000#;
               begin
                  Keep (Code_Unit (16#D800# + Rest / 1_024));
                  Keep (Code_Unit (16#DC00# + Rest mod 1_024));
               end;
            end if;
         elsif Value <= 16#7F# then
            Keep (Code_Unit (Value));
         elsif Value <= 16#7FF# then
            Keep (Code_Unit (16#C0# + Value / 64));
            Keep (Code_Unit (16#80# + Value mod 64));
         elsif Value <= 16#FFFF# then
            Keep (Code_Unit (16#E0# + Value / 4_096));
            Keep (Code_Unit (16#80# + Value / 64 mod 64));
            Keep (Code_Unit (16#80# + Value mod 64));
         else
            Keep (Code_Unit (16#F0# + Value / 262_144));
            Keep (Code_Unit (16#80# + Value / 4_096 mod 64));
            Keep (Code_Unit (16#80# + Value / 64 mod 64));
            Keep (Code_Unit (16#80# + Value mod 64));
         end if;
      end Keep_Codepoint;
   begin
      Length := 0;
      Fault := Well_Formed;
      Fault_First := 0;
      Fault_Last := 0;
      Units := [others => 0];

      if Raw then
         declare
            Bytes : String (1 .. Lexeme'Length);
            Byte_Length : Natural;
            At_Byte : Positive := 1;
         begin
            Decode_Raw
              (Lexeme, Bytes, Byte_Length, Fault, Fault_First, Fault_Last);
            if Fault /= Well_Formed then
               return;
            end if;

            while At_Byte <= Byte_Length loop
               declare
                  Count : constant Natural :=
                    UTF8_Length (Bytes, At_Byte, Byte_Length);
               begin
                  if Count = 0 then
                     raise Program_Error with
                       "raw text changed after UTF-8 validation";
                  elsif Encoding = UTF16_Units then
                     Keep_Codepoint (UTF8_Value (Bytes, At_Byte, Count));
                  else
                     for Offset in 0 .. Count - 1 loop
                        Keep
                          (Code_Unit
                             (Character'Pos (Bytes (At_Byte + Offset))));
                     end loop;
                  end if;
                  At_Byte := At_Byte + Count;
               end;
            end loop;
            return;
         end;
      end if;

      declare
         First : constant Positive := Lexeme'First + 1;
         Last  : constant Natural  := Lexeme'Last - 1;
         At_Byte : Positive := First;

         procedure Fail (Which : Problem; Stop : Natural);

         procedure Fail (Which : Problem; Stop : Natural) is
         begin
            Fault := Which;
            Fault_First := At_Byte - Lexeme'First;
            Fault_Last := Stop - Lexeme'First + 1;
         end Fail;
      begin
         while At_Byte <= Last loop
            if Lexeme (At_Byte) /= '\' then
               declare
                  Count : constant Natural :=
                    UTF8_Length (Lexeme, At_Byte, Last);
               begin
                  if Count = 0 then
                     Fail (Invalid_UTF8_Source, At_Byte);
                     return;
                  elsif Encoding = UTF16_Units then
                     Keep_Codepoint
                       (UTF8_Value (Lexeme, At_Byte, Count));
                  else
                     for Offset in 0 .. Count - 1 loop
                        Keep
                          (Code_Unit
                             (Character'Pos
                                (Lexeme (At_Byte + Offset))));
                     end loop;
                  end if;
                  At_Byte := At_Byte + Count;
               end;
            elsif At_Byte = Last then
               Fail (Dangling_Backslash, At_Byte);
               return;
            else
               case Lexeme (At_Byte + 1) is
                  when 'n' => Keep_Codepoint (10);
                  when 'r' => Keep_Codepoint (13);
                  when 't' => Keep_Codepoint (9);
                  when 'e' => Keep_Codepoint (27);
                  when '\' => Keep_Codepoint (Character'Pos ('\'));
                  when '"' => Keep_Codepoint (Character'Pos ('"'));
                  when ''' => Keep_Codepoint (Character'Pos ('''));
                  when 'x' =>
                     if At_Byte + 3 > Last
                       or else Hex_Value (Lexeme (At_Byte + 2)) < 0
                       or else Hex_Value (Lexeme (At_Byte + 3)) < 0
                     then
                        Fail
                          (Short_Byte_Escape,
                           Natural'Min (Last, At_Byte + 3));
                        return;
                     elsif Encoding /= Byte_Units then
                        Fail (Byte_Where_Text_Is_Meant, At_Byte + 3);
                        return;
                     end if;
                     Keep
                       (Code_Unit
                          (Hex_Value (Lexeme (At_Byte + 2)) * 16
                           + Hex_Value (Lexeme (At_Byte + 3))));
                     At_Byte := At_Byte + 2;
                  when 'u' =>
                     declare
                        Stop : Natural := At_Byte + 2;
                        Value : Natural := 0;
                        Digit_Count : Natural := 0;
                     begin
                        if Stop > Last or else Lexeme (Stop) /= '{' then
                           Fail
                             (Malformed_Codepoint_Escape,
                              Natural'Min (Last, Stop));
                           return;
                        end if;
                        Stop := Stop + 1;
                        while Stop <= Last and then Lexeme (Stop) /= '}' loop
                           declare
                              Digit : constant Integer :=
                                Hex_Value (Lexeme (Stop));
                           begin
                              if Digit < 0
                                or else Value > (16#10_FFFF# - Digit) / 16
                              then
                                 Fail (Malformed_Codepoint_Escape, Stop);
                                 return;
                              end if;
                              Value := Value * 16 + Digit;
                              Digit_Count := Digit_Count + 1;
                           end;
                           Stop := Stop + 1;
                        end loop;
                        if Stop > Last
                          or else Digit_Count = 0
                          or else Value in 16#D800# .. 16#DFFF#
                        then
                           Fail
                             (Malformed_Codepoint_Escape,
                              Natural'Min (Last, Stop));
                           return;
                        elsif Encoding = Byte_Units then
                           Fail (Codepoint_Where_Bytes_Are_Meant, Stop);
                           return;
                        end if;
                        Keep_Codepoint (Value);
                        At_Byte := Stop + 1;
                        goto Continue_Decode;
                     end;
                  when others =>
                     Fail (Unknown_Escape, At_Byte + 1);
                     return;
               end case;
               At_Byte := At_Byte + 2;
            end if;
            <<Continue_Decode>>
            null;
         end loop;
      end;
   end Decode_View;

end Landin.Tokens.Text;
