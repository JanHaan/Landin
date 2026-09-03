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

end Landin.Tokens.Text;
