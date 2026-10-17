with Ada.Strings.Fixed;

package body Landin.Backend.Arm64.Selection is

   package Reciprocals renames Landin.Backend.Reciprocals;
   use type Ada.Strings.Unbounded.Unbounded_String;

   LF : constant Character := Character'Val (10);

   function Image (Value : Word) return String
     is (Ada.Strings.Fixed.Trim (Word'Image (Value), Ada.Strings.Both));

   function Image (Value : Natural) return String
     is (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   function Immediate (Register : String; Value : Word) return String is
      Zero_Chunks : Natural := 0;
      Ones_Chunks : Natural := 0;
      Use_Movn : Boolean;
      Fill : Word;
      Seeded : Boolean := False;
      Lines : Ada.Strings.Unbounded.Unbounded_String;
   begin
      for Index in 0 .. 3 loop
         declare
            Chunk : constant Word := Value / 2 ** (Index * 16) and 65535;
         begin
            if Chunk = 0 then
               Zero_Chunks := Zero_Chunks + 1;
            elsif Chunk = 65535 then
               Ones_Chunks := Ones_Chunks + 1;
            end if;
         end;
      end loop;

      --  A move-wide seed supplies every untouched chunk.  Use the
      --  complement seed only when it leaves fewer chunks for MOVK.
      Use_Movn := Ones_Chunks > Zero_Chunks;
      Fill := (if Use_Movn then 65535 else 0);
      for Index in 0 .. 3 loop
         declare
            Chunk : constant Word := Value / 2 ** (Index * 16) and 65535;
            Shift : constant String :=
              (if Index = 0 then "" else ", lsl #" & Image (Index * 16));
         begin
            if Chunk /= Fill then
               if Lines /= Ada.Strings.Unbounded.Null_Unbounded_String then
                  Ada.Strings.Unbounded.Append (Lines, LF);
               end if;
               if not Seeded then
                  Ada.Strings.Unbounded.Append
                    (Lines, (if Use_Movn then "movn " else "movz ")
                     & Register & ", #"
                     & Image (if Use_Movn then 65535 - Chunk else Chunk)
                     & Shift);
                  Seeded := True;
               else
                  Ada.Strings.Unbounded.Append
                    (Lines, "movk " & Register & ", #" & Image (Chunk)
                     & Shift);
               end if;
            end if;
         end;
      end loop;
      if not Seeded then
         return (if Use_Movn then "movn " else "movz ") & Register & ", #0";
      end if;
      return Ada.Strings.Unbounded.To_String (Lines);
   end Immediate;

   function Arithmetic_Immediate (Value : Word) return String is
     (if Value <= 4095 then "#" & Image (Value)
      elsif Value mod 4096 = 0 and then Value / 4096 <= 4095
      then "#" & Image (Value / 4096) & ", lsl #12"
      else "");

   function Is_Logical_Immediate (Value : Word; Bits : Positive)
     return Boolean
   is
      --  A 32-bit operand is the same pattern twice in 64 bits.
      Whole : constant Word :=
        (if Bits = 32 then (Value and 16#FFFF_FFFF#) * (2 ** 32 + 1)
         else Value);
      Size : Natural := 64;
   begin
      if Whole = 0 or else Whole = Word'Last then
         return False;
      end if;
      --  The narrowest element the pattern repeats.
      while Size > 2 loop
         declare
            Half : constant Natural := Size / 2;
            Mask : constant Word := 2 ** Half - 1;
         begin
            exit when (Whole and Mask) /= (Whole / 2 ** Half and Mask);
            Size := Half;
         end;
      end loop;
      declare
         Mask : constant Word :=
           (if Size = 64 then Word'Last else 2 ** Size - 1);
         Element : constant Word := Whole and Mask;
         Ones : Natural := 0;
      begin
         for Bit in 0 .. Size - 1 loop
            if (Element / 2 ** Bit and 1) = 1 then
               Ones := Ones + 1;
            end if;
         end loop;
         --  Some rotation of the element is its ones at the bottom.
         for Rotation in 0 .. Size - 1 loop
            declare
               Rotated : constant Word :=
                 (if Rotation = 0 then Element
                  else (Element / 2 ** Rotation
                        or Element * 2 ** (Size - Rotation)) and Mask);
            begin
               if Rotated = 2 ** Ones - 1 then
                  return True;
               end if;
            end;
         end loop;
         return False;
      end;
   end Is_Logical_Immediate;

   function Hexadecimal (Value : Word) return String is
      Digit : constant String := "0123456789abcdef";
      Text : String (1 .. 16);
      First : Positive := Text'Last;
      Rest : Word := Value;
   begin
      for Index in reverse Text'Range loop
         Text (Index) := Digit (Natural (Rest mod 16) + 1);
         Rest := Rest / 16;
         if Text (Index) /= '0' then
            First := Index;
         end if;
      end loop;
      return "#0x" & Text (First .. Text'Last);
   end Hexadecimal;

   --  VFPExpandImm's inverse.  An f64 immediate abcdefgh is the pattern
   --  a, not b, b eight times, cd, efgh and 48 zero bits; an f32 one has
   --  b five times and 19 zero bits.  Its value is plus or minus
   --  (16 + efgh) / 16 times two to an exponent from -3 to 4, which is a
   --  whole number of 128ths and so an exact short decimal.
   function Float_Immediate (Value : Word; Single : Boolean) return String
   is
      Fraction_Bits : constant Natural := (if Single then 23 else 52);
      Exponent_Bits : constant Natural := (if Single then 8 else 11);
      Bias : constant Natural := (if Single then 127 else 1023);
      Sign : constant Word := Value / 2 ** (Fraction_Bits + Exponent_Bits);
      Exponent : constant Word :=
        Value / 2 ** Fraction_Bits and (2 ** Exponent_Bits - 1);
      Fraction : constant Word := Value and (2 ** Fraction_Bits - 1);
   begin
      if (Single and then Value >= 2 ** 32)
        or else Fraction mod 2 ** (Fraction_Bits - 4) /= 0
        or else Exponent + 3 < Word (Bias)
        or else Exponent > Word (Bias) + 4
      then
         return "";
      end if;
      declare
         Sixteenths : constant Word :=
           16 + Fraction / 2 ** (Fraction_Bits - 4);
         --  The value times 128.
         Scaled : constant Word :=
           Sixteenths * 2 ** Natural (Exponent + 3 - Word (Bias));
         Decimals : constant String :=
           Image (10_000_000 + Scaled mod 128 * 78_125);
         Last : Natural := Decimals'Last;
      begin
         while Last > Decimals'First + 1 and then Decimals (Last) = '0' loop
            Last := Last - 1;
         end loop;
         return "#" & (if Sign = 1 then "-" else "")
           & Image (Scaled / 128) & "."
           & Decimals (Decimals'First + 1 .. Last);
      end;
   end Float_Immediate;

   procedure Divide_By_Constant
     (Bits : Landin.Backend.Reciprocals.Dividend_Bits;
      Signed : Boolean;
      Remainder : Boolean;
      Magnitude : Word;
      Negative : Boolean;
      Dividend, Result : String;
      Lines : out Ada.Strings.Unbounded.Unbounded_String;
      Extended : out Boolean)
   is
      --  A signed dividend narrower than the register is sign-extended
      --  into x9 first, and every step works on all 64 bits.
      Wide : constant String :=
        (if Signed and then Bits < 64 then "x9" else Dividend);
      --  A quotient is worked out in Result itself when nothing reads the
      --  dividend after Result is first written.
      Quotient : constant String :=
        (if not Remainder and then not Negative and then Result /= Wide
         then Result else "x11");
      Shift : Natural := 0;

      procedure Line (Text : String);

      procedure Line (Text : String) is
      begin
         if Lines /= Ada.Strings.Unbounded.Null_Unbounded_String then
            Ada.Strings.Unbounded.Append (Lines, LF);
         end if;
         Ada.Strings.Unbounded.Append (Lines, Text);
      end Line;

      --  The quotient's last step, from Quotient into Result.
      procedure Finish;

      procedure Finish is
      begin
         if Remainder then
            Line (Immediate ("x14", Magnitude));
            Line ("msub " & Result & ", x11, x14, " & Wide);
         elsif Negative then
            Line ("neg " & Result & ", x11");
         elsif Quotient /= Result then
            Line ("mov " & Result & ", x11");
         end if;
      end Finish;
   begin
      Lines := Ada.Strings.Unbounded.Null_Unbounded_String;
      Extended := not Signed or else Bits = 64;
      if Signed and then Bits < 64 and then Magnitude /= 1 then
         Line ((case Bits is
                   when 8 => "sxtb ",
                   when 16 => "sxth ",
                   when others => "sxtw ")
               & "x9, w" & Dividend (Dividend'First + 1 .. Dividend'Last));
      end if;
      while Shift < 64 and then 2 ** Shift < Magnitude loop
         Shift := Shift + 1;
      end loop;

      if Reciprocals.Is_Power_Of_Two (Magnitude) and then Shift = 0 then
         --  One: the dividend itself, and nothing over.  A signed minus
         --  one never arrives here.
         Extended := True;
         Line (if Remainder then "movz " & Result & ", #0"
               else "mov " & Result & ", " & Dividend);
      elsif Reciprocals.Is_Power_Of_Two (Magnitude) and then not Signed then
         Line (if Remainder
               then "and " & Result & ", " & Dividend & ", "
                 & Hexadecimal (Magnitude - 1)
               else "lsr " & Result & ", " & Dividend & ", #"
                 & Image (Shift));
      elsif Reciprocals.Is_Power_Of_Two (Magnitude) then
         --  A negative dividend is biased by the divisor less one before
         --  it is shifted, so that the quotient truncates toward zero:
         --  its sign bits, shifted down, are that bias.
         Line ("asr x11, " & Wide & ", #63");
         Line ("add x11, " & Wide & ", x11, lsr #" & Image (64 - Shift));
         if Remainder then
            Line ("and x11, x11, " & Hexadecimal (not (Magnitude - 1)));
            Line ("sub " & Result & ", " & Wide & ", x11");
         else
            Line ("asr " & Quotient & ", x11, #" & Image (Shift));
            Finish;
         end if;
      elsif not Signed then
         declare
            Inverse : constant Reciprocals.Reciprocal :=
              Reciprocals.Unsigned_Reciprocal (Magnitude, Bits);
            Last : constant Boolean :=
              not Inverse.Add and then Inverse.Shift = 0;
         begin
            Line (Immediate ("x14", Inverse.Multiplier));
            Line ("umulh " & (if Last then Quotient else "x11") & ", "
                  & Wide & ", x14");
            if Inverse.Add then
               --  (N - T) / 2 + T is (N + T) / 2 without the 65th bit.
               Line ("sub x12, " & Wide & ", x11");
               Line ("add " & (if Inverse.Shift = 0 then Quotient else "x11")
                     & ", x11, x12, lsr #1");
            end if;
            if Inverse.Shift > 0 then
               Line ("lsr " & Quotient & ", x11, #"
                     & Image (Inverse.Shift));
            end if;
            Finish;
         end;
      else
         declare
            Inverse : constant Reciprocals.Reciprocal :=
              Reciprocals.Signed_Reciprocal (Magnitude, Bits);
         begin
            Line (Immediate ("x14", Inverse.Multiplier));
            Line ("smulh x11, " & Wide & ", x14");
            if Inverse.Add then
               Line ("add x11, x11, " & Wide);
            end if;
            if Inverse.Shift > 0 then
               Line ("asr x11, x11, #" & Image (Inverse.Shift));
            end if;
            --  Floor to truncation: a negative quotient is one too low.
            Line ("add " & Quotient & ", x11, x11, lsr #63");
            Finish;
         end;
      end if;
   end Divide_By_Constant;

end Landin.Backend.Arm64.Selection;
