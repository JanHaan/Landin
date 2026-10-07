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

end Landin.Backend.RiscV_Instructions;
