with Ada.Strings.Fixed;

package body Landin.Backend.RiscV_Instructions is

   use type Landin.Targets.Bit_Width;

   function Trimmed (Text : String) return String
     is (Ada.Strings.Fixed.Trim (Text, Ada.Strings.Both));

   function Register (Number : Register_Number) return String
     is ("x" & Trimmed (Register_Number'Image (Number)));

   function Immediate
     (Destination : Register_Number; Value : Pattern;
      Width : Machine_Width) return String
   is
      Mask : constant Pattern :=
        (if Width = 64 then Pattern'Last else 2 ** 32 - 1);
      Bits : constant Pattern := Value and Mask;
      Sign : constant Pattern := 2 ** (Natural (Width) - 1);
      Magnitude : constant Pattern :=
        (if (Bits and Sign) = 0 then Bits else (0 - Bits) and Mask);
   begin
      return "li " & Register (Destination) & ", "
        & (if (Bits and Sign) = 0 then "" else "-")
        & Trimmed (Pattern'Image (Magnitude));
   end Immediate;

   function Memory
     (Store : Boolean; Size : Landin.Targets.Scalar_Size;
      Value, Base : Register_Number; Width : Machine_Width;
      Offset : Integer := 0; Signed : Boolean := False) return String
   is
      Mnemonic : constant String :=
        (case Size is
            when Landin.Targets.Byte_1 =>
              (if Store then "sb" elsif Signed then "lb" else "lbu"),
            when Landin.Targets.Byte_2 =>
              (if Store then "sh" elsif Signed then "lh" else "lhu"),
            when Landin.Targets.Byte_4 =>
              (if Store then "sw" elsif Signed or Width = 32
               then "lw" else "lwu"),
            when Landin.Targets.Byte_8 => (if Store then "sd" else "ld"),
            when Landin.Targets.Byte_16 =>
              raise Compiler_Defect with "RISC-V scalar exceeds XLEN");
   begin
      --  Keep release builds honest even when contract checking is disabled.
      if Landin.Targets.Bytes (Size) > Integer (Width) / 8
        or else Offset not in -2048 .. 2047
      then
         raise Compiler_Defect with "RISC-V memory operand is unencodable";
      end if;
      return Mnemonic & " " & Register (Value) & ", "
        & Trimmed (Integer'Image (Offset)) & "(" & Register (Base) & ")";
   end Memory;

   function Indexed_Address
     (Destination, Base, Index, Scratch : Register_Number;
      Shift : Natural; Width : Machine_Width;
      Zba, Xtheadba : Boolean) return String
   is
      Count : constant String := Trimmed (Natural'Image (Shift));
   begin
      if Shift >= Natural (Width)
        or else Scratch = Base or else Scratch = Index or else Scratch = 0
      then
         raise Compiler_Defect with "RISC-V indexed address has bad operands";
      end if;
      if Shift = 0 then
         return "add " & Register (Destination) & ", " & Register (Base)
           & ", " & Register (Index);
      elsif Shift <= 3 and then Zba then
         return "sh" & Count & "add " & Register (Destination) & ", "
           & Register (Index) & ", " & Register (Base);
      elsif Shift <= 3 and then Xtheadba then
         return "th.addsl " & Register (Destination) & ", " & Register (Base)
           & ", " & Register (Index) & ", " & Count;
      else
         return "slli " & Register (Scratch) & ", " & Register (Index)
           & ", " & Count & Character'Val (10) & "add "
           & Register (Destination) & ", " & Register (Base) & ", "
           & Register (Scratch);
      end if;
   end Indexed_Address;

   function Assembles_Below
     (Text : String; Reach : Landin.Targets.Byte_Count) return Boolean
   is
      use type Landin.Targets.Byte_Count;
      Total : Landin.Targets.Byte_Count := 0;
      Start : Positive := Text'First;

      function Is_Space (C : Character) return Boolean
        is (C = ' ' or else C = Character'Val (9));

      --  The most bytes Line, without its end, can assemble to, or Reach
      --  where that is not bounded.
      function Most (Line : String) return Landin.Targets.Byte_Count;
      function Most (Line : String) return Landin.Targets.Byte_Count is
         First : Positive := Line'First;
         Last : Natural;
      begin
         while First <= Line'Last and then Is_Space (Line (First)) loop
            First := First + 1;
         end loop;
         if First > Line'Last then
            return 0;
         end if;
         Last := First;
         while Last < Line'Last and then not Is_Space (Line (Last + 1)) loop
            Last := Last + 1;
         end loop;
         declare
            Word : constant String := Line (First .. Last);
            Rest : constant String :=
              Trimmed (Line (Last + 1 .. Line'Last));
         begin
            if Ada.Strings.Fixed.Index (Line, ";") /= 0 then
               return Reach;
            elsif Word (Word'Last) = ':' then
               return Most (Rest);
            elsif Word (Word'First) /= '.' then
               return (if Word = "li" then 32 else 8);
            elsif Word in ".loc" | ".file" | ".type" | ".size" | ".globl"
              | ".global" | ".local" | ".hidden"
              or else (Word'Length > 5
                       and then Word (Word'First .. Word'First + 4) = ".cfi_")
            then
               return 0;
            elsif Word = ".p2align" and then Rest'Length in 1 .. 2
              and then (for all C of Rest => C in '0' .. '9')
              and then Natural'Value (Rest) <= 20
            then
               return 2 ** Natural'Value (Rest);
            else
               return Reach;
            end if;
         end;
      end Most;
   begin
      for Index in Text'Range loop
         if Text (Index) = Character'Val (10) or else Index = Text'Last then
            Total := Total + Most
              (Text (Start .. (if Text (Index) = Character'Val (10)
                               then Index - 1 else Index)));
            if Total >= Reach then
               return False;
            end if;
            Start := Index + 1;
         end if;
      end loop;
      return True;
   end Assembles_Below;

end Landin.Backend.RiscV_Instructions;
