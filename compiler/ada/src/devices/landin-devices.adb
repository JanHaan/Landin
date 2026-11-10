with Landin.Tokens;

package body Landin.Devices is

   use type Interfaces.Unsigned_64;

   function Is_Space (C : Character) return Boolean is
     (C in ' ' | ASCII.HT | ASCII.LF | ASCII.CR);

   function Trimmed (Text : String) return String is
      First : Integer := Text'First;
      Last : Integer := Text'Last;
   begin
      while First <= Last and then Is_Space (Text (First)) loop
         First := First + 1;
      end loop;
      while Last >= First and then Is_Space (Text (Last)) loop
         Last := Last - 1;
      end loop;
      return Text (First .. Last);
   end Trimmed;

   function Digit_Value (C : Character) return Natural is
     (case C is
         when '0' .. '9' => Character'Pos (C) - Character'Pos ('0'),
         when 'a' .. 'f' => Character'Pos (C) - Character'Pos ('a') + 10,
         when 'A' .. 'F' => Character'Pos (C) - Character'Pos ('A') + 10,
         when others => 16);

   --  The radix and where the digits begin, or zero when Text has no
   --  digits after its prefix.
   procedure Classify
     (Text : String; Radix : out Natural; First : out Integer);

   procedure Classify
     (Text : String; Radix : out Natural; First : out Integer) is
   begin
      if Text'Length > 2
        and then Text (Text'First) = '0'
        and then Text (Text'First + 1) in 'x' | 'X'
      then
         Radix := 16;
         First := Text'First + 2;
      elsif Text'Length > 1 and then Text (Text'First) = '#' then
         Radix := 2;
         First := Text'First + 1;
      elsif Text'Length > 0 then
         Radix := 10;
         First := Text'First;
      else
         Radix := 0;
         First := Text'First;
      end if;
   end Classify;

   function Is_Number (Text : String) return Boolean is
      Clean : constant String := Trimmed (Text);
      Radix : Natural;
      First : Integer;
      Value : Word := 0;
   begin
      Classify (Clean, Radix, First);
      if Radix = 0 or else First > Clean'Last then
         return False;
      end if;
      for Index in First .. Clean'Last loop
         if Digit_Value (Clean (Index)) >= Radix then
            return False;
         elsif Value > (Word'Last - Word (Digit_Value (Clean (Index))))
                         / Word (Radix)
         then
            return False;
         end if;
         Value := Value * Word (Radix) + Word (Digit_Value (Clean (Index)));
      end loop;
      return True;
   end Is_Number;

   function Number (Text : String) return Word is
      Clean : constant String := Trimmed (Text);
      Radix : Natural;
      First : Integer;
      Value : Word := 0;
   begin
      Classify (Clean, Radix, First);
      for Index in First .. Clean'Last loop
         Value := Value * Word (Radix) + Word (Digit_Value (Clean (Index)));
      end loop;
      return Value;
   end Number;

   function Is_Vendor_Name (Text : String) return Boolean is
     (Text'Length > 0
      and then Text (Text'First) in 'A' .. 'Z' | 'a' .. 'z'
      and then (for all C of Text =>
                  C in 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_'));

   function Lowered (Text : String) return String is
      Result : String := Text;
   begin
      for C of Result loop
         if C in 'A' .. 'Z' then
            C := Character'Val (Character'Pos (C) + 32);
         end if;
      end loop;
      return Result;
   end Lowered;

   --  The keywords are Landin.Tokens' reserved words, which check.py holds
   --  to the keyword production; the three namespaces are those the
   --  resolver keeps for the toolchain.
   function Is_Reserved (Name : String) return Boolean is
     (Name in "compiler" | "assembler" | "linker"
      or else (for some Word in Landin.Tokens.Reserved_Word =>
                 Landin.Tokens.Spelling (Word) = Name));

   Hex_Digits : constant String := "0123456789abcdef";

   function Hex8 (Value : Word) return String is
      Result : String (1 .. 10) := "0x00000000";
      Rest : Word := Value;
   begin
      for Index in reverse 3 .. 10 loop
         Result (Index) := Hex_Digits (Natural (Rest mod 16) + 1);
         Rest := Rest / 16;
      end loop;
      if Rest /= 0 then
         return "0x" & Hex (Value) (3 .. Hex (Value)'Last);
      end if;
      return Result;
   end Hex8;

   function Hex (Value : Word) return String is
      Buffer : String (1 .. 16);
      First : Positive := 17;
      Rest : Word := Value;
   begin
      loop
         First := First - 1;
         Buffer (First) := Hex_Digits (Natural (Rest mod 16) + 1);
         Rest := Rest / 16;
         exit when Rest = 0;
      end loop;
      return "0x" & Buffer (First .. 16);
   end Hex;

   function Decimal (Value : Word) return String is
      Buffer : String (1 .. 20);
      First : Positive := 21;
      Rest : Word := Value;
   begin
      loop
         First := First - 1;
         Buffer (First) :=
           Character'Val (Character'Pos ('0') + Natural (Rest mod 10));
         Rest := Rest / 10;
         exit when Rest = 0;
      end loop;
      return Buffer (First .. 20);
   end Decimal;

   function Is_Relative_Path (Text : String) return Boolean is
      Part_First : Integer := Text'First;
   begin
      if Text'Length = 0 or else Text (Text'First) = '/' then
         return False;
      end if;
      for Index in Text'First .. Text'Last + 1 loop
         if Index > Text'Last or else Text (Index) = '/' then
            declare
               Part : constant String := Text (Part_First .. Index - 1);
            begin
               if Part = "" or else Part = "." or else Part = ".." then
                  return False;
               end if;
            end;
            Part_First := Index + 1;
         elsif Text (Index) = '\' or else Character'Pos (Text (Index)) < 32
         then
            return False;
         end if;
      end loop;
      return True;
   end Is_Relative_Path;

end Landin.Devices;
