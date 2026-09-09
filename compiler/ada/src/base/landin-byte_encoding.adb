package body Landin.Byte_Encoding is

   function Hex (Value : String) return String is
      Hex_Digits : constant String := "0123456789abcdef";
      Result : String (1 .. Value'Length * 2);
      Next : Positive := 1;
   begin
      for Byte of Value loop
         Result (Next) := Hex_Digits (Character'Pos (Byte) / 16 + 1);
         Result (Next + 1) := Hex_Digits (Character'Pos (Byte) mod 16 + 1);
         Next := Next + 2;
      end loop;
      return Result;
   end Hex;
end Landin.Byte_Encoding;
