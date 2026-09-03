with Ada.Unchecked_Conversion;
with Interfaces;

package body Landin.Types is

   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   --  How many digits a base has, which is the only thing Evaluate needs
   --  from one.  Landin.Tokens owns the prefix that selected it, because a
   --  base prefix is a lexical fact [1770].
   function Radix (Base : Landin.Tokens.Integer_Base) return Magnitude
     is (case Base is
            when Landin.Tokens.Binary      => 2,
            when Landin.Tokens.Octal       => 8,
            when Landin.Tokens.Decimal     => 10,
            when Landin.Tokens.Hexadecimal => 16);

   ------------------
   --  Storage_Size  --
   ------------------

   function Storage_Size
     (Item  : Scalar_Name;
      Facts : Landin.Targets.Target_Facts) return Landin.Targets.Scalar_Size is
   begin
      if Item = Bool then
         return Landin.Targets.Byte_1;
      elsif Item in Float_Name then
         return
           (case Float_Name (Item) is
               when F32 => Landin.Targets.Byte_4,
               when F64 => Landin.Targets.Byte_8);
      end if;

      case Width (Item, Facts) is
         when 8      => return Landin.Targets.Byte_1;
         when 16     => return Landin.Targets.Byte_2;
         when 32     => return Landin.Targets.Byte_4;
         when 64     => return Landin.Targets.Byte_8;
         when others =>
            raise Compiler_Defect with
              "no scalar size holds this target's width";
      end case;
   end Storage_Size;

   ------------
   --  Fits  --
   ------------

   function Fits
     (Value   : Magnitude;
      Item    : Integer_Name;
      Facts   : Landin.Targets.Target_Facts;
      Negated : Boolean) return Boolean
   is
      Signed : constant Boolean := Is_Signed (Item);
      Bits   : Bit_Count;
      Usable : Bit_Count;
      Bound  : Magnitude := 0;
   begin
      --  In every build mode, not only where assertions are on: this is
      --  the rule Landin.Targets.Align_Up keeps for the same reason.  A
      --  target wider than Widest is a description this package cannot
      --  answer for, and answering anyway is how a 128-bit usize would
      --  quietly become a 64-bit one.
      if Width (Item, Facts) > Landin.Targets.Bit_Width (Widest) then
         raise Compiler_Defect with
           "a target wider than Landin.Types.Widest";
      end if;

      Bits := Bit_Count (Width (Item, Facts));
      Usable := (if Signed then Bits - 1 else Bits);

      --  2 ** Usable - 1 built one bit at a time, because forming
      --  2 ** Usable directly is one past Magnitude'Last when Usable is
      --  64, which is exactly the u64 case this has to answer.
      for Unused in 1 .. Usable loop
         Bound := Bound * 2 + 1;
      end loop;

      if not Negated then
         return Value <= Bound;
      end if;

      --  A negated literal is no unsigned type's value, except zero:
      --  [0300] says overflow traps, and -1 in a u8 is not a u8 at all.
      if not Signed then
         return Value = 0;
      end if;

      --  One further than the positive bound, which is what makes -128 an
      --  i8 and 128 not one.
      return Value <= Bound + 1;
   end Fits;

   -------------
   --  Holds  --
   -------------

   function Holds
     (Value : Folded;
      Item  : Integer_Name;
      Facts : Landin.Targets.Target_Facts) return Boolean is
   begin
      if Value < 0 then
         return Fits (Magnitude (-Value), Item, Facts, Negated => True);
      end if;

      return Fits (Magnitude (Value), Item, Facts, Negated => False);
   end Holds;

   ----------------
   --  Evaluate  --
   ----------------

   procedure Evaluate
     (Text       : String;
      Base       : Landin.Tokens.Integer_Base;
      Value      : out Magnitude;
      Overflowed : out Boolean)
   is
      Scale : constant Magnitude := Radix (Base);
   begin
      Value := 0;
      Overflowed := False;

      for Byte of Text loop
         --  [0220]'s separator carries no value and may sit anywhere the
         --  scan accepted it.
         if Byte /= '_' then
            declare
               Digit : Magnitude;
            begin
               case Byte is
                  when '0' .. '9' =>
                     Digit := Magnitude
                       (Character'Pos (Byte) - Character'Pos ('0'));

                  when 'a' .. 'f' =>
                     Digit := Magnitude
                       (Character'Pos (Byte) - Character'Pos ('a') + 10);

                  when 'A' .. 'F' =>
                     Digit := Magnitude
                       (Character'Pos (Byte) - Character'Pos ('A') + 10);

                  when others =>
                     raise Compiler_Defect with
                       "a literal byte the scan should have refused";
               end case;

               if Digit >= Scale then
                  raise Compiler_Defect with
                    "a digit outside the base the prefix selected";
               end if;

               --  Guarded rather than caught.  [0950] says to check what
               --  can be foreseen, and a literal too wide for any enabled
               --  type is entirely in the bytes being looked at.
               if Value > (Magnitude'Last - Digit) / Scale then
                  Value := 0;
                  Overflowed := True;
                  return;
               end if;

               Value := Value * Scale + Digit;
            end;
         end if;
      end loop;
   end Evaluate;

   --------------------
   --  Evaluate_Float  --
   --------------------

   procedure Evaluate_Hex_Float
     (Text       : String;
      Item       : Float_Name;
      Bits       : out Magnitude;
      Overflowed : out Boolean);

   procedure Evaluate_Hex_Float
     (Text       : String;
      Item       : Float_Name;
      Bits       : out Magnitude;
      Overflowed : out Boolean)
   is
      --  The source exponent can contain more digits than any target value
      --  needs.  This explicit scale is wide enough to combine every source
      --  position with a saturated exponent without borrowing a host float.
      type Binary_Scale is range -2 ** 63 .. 2 ** 63 - 1;

      Precision : constant Natural :=
        (case Item is when F32 => 24, when F64 => 53);
      Minimum_Exponent : constant Binary_Scale :=
        (case Item is when F32 => -126, when F64 => -1022);
      Maximum_Exponent : constant Binary_Scale :=
        (case Item is when F32 => 127, when F64 => 1023);
      Bias : constant Natural :=
        (case Item is when F32 => 127, when F64 => 1023);
      Limit : constant Binary_Scale := 2 ** 60;

      Marker             : Natural := 0;
      Fraction_Digits    : Natural := 0;
      Significant_Digits : Natural := 0;
      First_Width        : Natural := 0;
      After_Point        : Boolean := False;
      Source_Exponent    : Binary_Scale := 0;
      Negative_Exponent  : Boolean := False;

      function Hex_Value (Byte : Character) return Natural;

      function Hex_Value (Byte : Character) return Natural is
      begin
         case Byte is
            when '0' .. '9' =>
               return Character'Pos (Byte) - Character'Pos ('0');
            when 'a' .. 'f' =>
               return Character'Pos (Byte) - Character'Pos ('a') + 10;
            when 'A' .. 'F' =>
               return Character'Pos (Byte) - Character'Pos ('A') + 10;
            when others =>
               raise Compiler_Defect with
                 "a hexadecimal float byte the scan should have refused";
         end case;
      end Hex_Value;
   begin
      --  First recover only the scale and the significant bit count.  The
      --  second pass below retains at most 53 bits, so a source literal may
      --  be arbitrarily wider than Magnitude without losing its rounding
      --  decision.
      for Index in Text'First + 2 .. Text'Last loop
         declare
            Byte : constant Character := Text (Index);
         begin
            if Byte in 'p' | 'P' then
               Marker := Index;
               exit;
            elsif Byte = '.' then
               After_Point := True;
            elsif Byte /= '_' then
               declare
                  Digit : constant Natural := Hex_Value (Byte);
               begin
                  if After_Point then
                     Fraction_Digits := Fraction_Digits + 1;
                  end if;
                  if Significant_Digits > 0 then
                     Significant_Digits := Significant_Digits + 1;
                  elsif Digit > 0 then
                     Significant_Digits := 1;
                     First_Width :=
                       (if Digit >= 8 then 4
                        elsif Digit >= 4 then 3
                        elsif Digit >= 2 then 2
                        else 1);
                  end if;
               end;
            end if;
         end;
      end loop;

      if Marker = 0 then
         raise Compiler_Defect with
           "a hexadecimal float without the exponent its scan requires";
      end if;

      declare
         Index : Natural := Marker + 1;
      begin
         if Text (Index) in '+' | '-' then
            Negative_Exponent := Text (Index) = '-';
            Index := Index + 1;
         end if;
         while Index <= Text'Last loop
            if Text (Index) /= '_' and then Source_Exponent < Limit then
               declare
                  Digit : constant Binary_Scale :=
                    Binary_Scale
                      (Character'Pos (Text (Index)) - Character'Pos ('0'));
               begin
                  Source_Exponent :=
                    (if Source_Exponent > (Limit - Digit) / 10 then Limit
                     else Source_Exponent * 10 + Digit);
               end;
            end if;
            Index := Index + 1;
         end loop;
      end;

      if Negative_Exponent then
         Source_Exponent := -Source_Exponent;
      end if;

      Overflowed := False;
      if Significant_Digits = 0 then
         Bits := 0;
         return;
      end if;

      declare
         Length : constant Binary_Scale :=
           Binary_Scale (First_Width)
             + 4 * Binary_Scale (Significant_Digits - 1);
         Exponent : Binary_Scale :=
           Length - 1 + Source_Exponent
             - 4 * Binary_Scale (Fraction_Digits);
         Unit_Exponent : constant Binary_Scale :=
           Minimum_Exponent - Binary_Scale (Precision - 1);
         Retained : constant Binary_Scale :=
           (if Exponent >= Minimum_Exponent then Binary_Scale (Precision)
            else Exponent - Unit_Exponent + 1);
         Seen      : Binary_Scale := 0;
         Value     : Magnitude := 0;
         Round_Bit : Boolean := False;
         Sticky    : Boolean := False;
         Started   : Boolean := False;
      begin
         if Exponent > Maximum_Exponent then
            Bits := 0;
            Overflowed := True;
            return;
         end if;

         for Index in Text'First + 2 .. Marker - 1 loop
            if Text (Index) /= '_' and then Text (Index) /= '.' then
               declare
                  Digit : constant Natural := Hex_Value (Text (Index));
               begin
                  for Shift in reverse 0 .. 3 loop
                     declare
                        Set : constant Boolean :=
                          (Digit / (2 ** Shift)) mod 2 = 1;
                     begin
                        if Set then
                           Started := True;
                        end if;
                        if Started then
                           Seen := Seen + 1;
                           if Retained > 0 and then Seen <= Retained then
                              Value := Value * 2 + Boolean'Pos (Set);
                           elsif Retained >= 0
                             and then Seen = Retained + 1
                           then
                              Round_Bit := Set;
                           elsif Retained >= 0 and then Set then
                              Sticky := True;
                           end if;
                        end if;
                     end;
                  end loop;
               end;
            end if;
         end loop;

         if Retained > Length then
            for Unused in 1 .. Natural (Retained - Length) loop
               Value := Value * 2;
            end loop;
         end if;

         if Round_Bit and then (Sticky or else Value mod 2 = 1) then
            Value := Value + 1;
         end if;

         declare
            Hidden : constant Magnitude := 2 ** (Precision - 1);
         begin
            if Exponent < Minimum_Exponent then
               --  A rounded subnormal that reaches Hidden is precisely the
               --  minimum normal encoding, so both cases are just Value.
               Bits := Value;
            else
               if Value = 2 * Hidden then
                  Value := Hidden;
                  Exponent := Exponent + 1;
               end if;
               if Exponent > Maximum_Exponent then
                  Bits := 0;
                  Overflowed := True;
                  return;
               end if;
               Bits :=
                 Magnitude (Exponent + Binary_Scale (Bias)) * Hidden
                   + Value - Hidden;
            end if;
         end;
      end;
   end Evaluate_Hex_Float;

   procedure Evaluate_Float
     (Text       : String;
      Item       : Float_Name;
      Bits       : out Magnitude;
      Overflowed : out Boolean)
   is
      subtype F32_Value is Interfaces.IEEE_Float_32;
      subtype F64_Value is Interfaces.IEEE_Float_64;
      function Pattern_32 is new Ada.Unchecked_Conversion
        (F32_Value, Interfaces.Unsigned_32);
      function Pattern_64 is new Ada.Unchecked_Conversion
        (F64_Value, Interfaces.Unsigned_64);
      Clean : String (1 .. Text'Length);
      Last  : Natural := 0;
   begin
      if Text'Length >= 2 and then Text (Text'First + 1) = 'x' then
         Evaluate_Hex_Float (Text, Item, Bits, Overflowed);
         return;
      end if;

      for Byte of Text loop
         if Byte /= '_' then
            Last := Last + 1;
            Clean (Last) := Byte;
         end if;
      end loop;

      Overflowed := False;
      case Item is
         when F32 =>
            declare
               Pattern : constant Interfaces.Unsigned_32 :=
                 Pattern_32 (F32_Value'Value (Clean (1 .. Last)));
            begin
               Bits := Magnitude (Pattern);
               Overflowed :=
                 (Pattern and 16#7F80_0000#) = 16#7F80_0000#;
            end;
         when F64 =>
            declare
               Pattern : constant Interfaces.Unsigned_64 :=
                 Pattern_64 (F64_Value'Value (Clean (1 .. Last)));
            begin
               Bits := Magnitude (Pattern);
               Overflowed :=
                 (Pattern and 16#7FF0_0000_0000_0000#)
                   = 16#7FF0_0000_0000_0000#;
            end;
      end case;
   exception
      when Constraint_Error =>
         Bits := 0;
         Overflowed := True;
   end Evaluate_Float;

   ------------------------
   --  Float_Special_Bits  --
   ------------------------

   function Float_Special_Bits
     (Item : Float_Name; Special : Float_Special) return Magnitude
   is
   begin
      return
        (case Item is
            when F32 =>
              (case Special is
                  when Infinity => 16#7F80_0000#,
                  when Quiet_NaN => 16#7FC0_0000#),
            when F64 =>
              (case Special is
                  when Infinity => 16#7FF0_0000_0000_0000#,
                  when Quiet_NaN => 16#7FF8_0000_0000_0000#));
   end Float_Special_Bits;

   -------------------
   --  Negated_Float  --
   -------------------

   function Negated_Float
     (Bits : Magnitude; Item : Float_Name) return Magnitude
   is
      Sign : constant Magnitude :=
        (case Item is when F32 => 2 ** 31, when F64 => 2 ** 63);
   begin
      return (if Bits < Sign then Bits + Sign else Bits - Sign);
   end Negated_Float;

end Landin.Types;
