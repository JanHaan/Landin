package body Landin.Driver.Image_Block is
   package US renames Ada.Strings.Unbounded;
   package Firmware renames Landin.Targets.Firmware;

   --  ELF's section types this reads.
   Relocations : constant := 9;
   Addend_Relocations : constant := 4;
   No_Bits : constant := 8;

   function Hex (Value : Natural) return String;
   function Hex (Value : Natural) return String is
      Digits_Of : constant String := "0123456789abcdef";
      Result : String (1 .. 8);
      First : Positive := Result'Last + 1;
      Rest : Natural := Value;
   begin
      loop
         First := First - 1;
         Result (First) := Digits_Of (Rest mod 16 + 1);
         Rest := Rest / 16;
         exit when Rest = 0;
      end loop;
      return "0x" & Result (First .. Result'Last);
   end Hex;

   function Fault
     (Object : String;
      Core : Landin.Targets.Firmware.Core_Kind :=
        Landin.Targets.Firmware.Cortex_M33)
      return US.Unbounded_String
   is
      Data : constant String := Object;
      RISC_V : constant Boolean := Core in Firmware.RISC_V_Core;

      --  The little-endian number of WIDTH bytes at file offset POSITION.
      function Number (Position : Natural; Width : Positive) return Natural;
      function Number (Position : Natural; Width : Positive) return Natural
      is
         Value : Natural := 0;
      begin
         if Position > Data'Length or else Width > Data'Length - Position
           or else Width > 4
         then
            raise Constraint_Error;
         end if;
         for Offset in reverse 0 .. Width - 1 loop
            if Value > (Natural'Last - 255) / 256 then
               raise Constraint_Error;
            end if;
            Value := Value * 256
              + Character'Pos (Data (Data'First + Position + Offset));
         end loop;
         return Value;
      end Number;

      function Word (Position : Natural) return Natural is
        (Number (Position, 4));

      function Text_At (Position : Natural) return String;
      function Text_At (Position : Natural) return String is
         Last : Natural := Position;
      begin
         if Position > Data'Length then
            raise Constraint_Error;
         end if;
         while Last < Data'Length
           and then Data (Data'First + Last) /= ASCII.NUL
         loop
            Last := Last + 1;
         end loop;
         return Data (Data'First + Position .. Data'First + Last - 1);
      end Text_At;

      Sections, Entry_Size, Count, Names_At : Natural;
      Block : Natural := 0;

      function Header (Index : Natural) return Natural is
        (Sections + Index * Entry_Size);
      function Section_Name (Index : Natural) return String is
        (Text_At (Names_At + Word (Header (Index))));

      --  The name of symbol SYMBOL of the table in section TABLE, or of
      --  the section a section symbol stands for.
      function Symbol_Name (Table, Symbol : Natural) return String;
      function Symbol_Name (Table, Symbol : Natural) return String is
         At_Entry : constant Natural :=
           Word (Header (Table) + 16) + Symbol * 16;
         Strings : constant Natural :=
           Word (Header (Word (Header (Table) + 24)) + 16);
         Name : constant Natural := Word (At_Entry);
      begin
         if Name = 0 and then Number (At_Entry + 12, 1) mod 16 = 3 then
            return Section_Name (Number (At_Entry + 14, 2));
         end if;
         return Text_At (Strings + Name);
      end Symbol_Name;
   begin
      if Data'Length < 52
        or else Data (Data'First .. Data'First + 5)
          /= Character'Val (127) & "ELF" & Character'Val (1)
            & Character'Val (1)
        or else Number (16, 2) /= 1
        or else Number (18, 2) /= (if RISC_V then 243 else 40)
      then
         return US.To_Unbounded_String
           ("the assembled object is not a 32-bit little-endian "
            & (if RISC_V then "RISC-V" else "Arm") & " relocatable object");
      end if;
      Sections := Word (32);
      Entry_Size := Number (46, 2);
      Count := Number (48, 2);
      if Entry_Size < 40 then
         raise Constraint_Error;
      end if;
      Names_At := Word (Header (Number (50, 2)) + 16);
      for Index in 1 .. Count - 1 loop
         if Section_Name (Index) = ".embedded_block" then
            Block := Index;
         end if;
      end loop;
      if Block = 0 or else Word (Header (Block) + 4) = No_Bits then
         return US.To_Unbounded_String
           ("the assembled object holds no .embedded_block section of the"
            & " image block's bytes");
      end if;
      for Index in 1 .. Count - 1 loop
         declare
            Kind : constant Natural := Word (Header (Index) + 4);
            Size_Of : constant Natural :=
              (if Kind = Relocations then 8 else 12);
         begin
            if Kind in Relocations | Addend_Relocations
              and then Word (Header (Index) + 28) = Block
              and then Word (Header (Index) + 20) >= Size_Of
            then
               declare
                  At_Entry : constant Natural := Word (Header (Index) + 16);
                  Symbol : constant Natural := Word (At_Entry + 4) / 256;
               begin
                  return US.To_Unbounded_String
                    ("the image block holds a relocation at offset "
                     & Hex (Word (At_Entry))
                     & (if Symbol = 0 then " against no symbol"
                        else " against "
                          & Symbol_Name (Word (Header (Index) + 24), Symbol))
                     & ", and the boot ROM reads its words as the object"
                     & " gives them");
               end;
            end if;
         end;
      end loop;
      declare
         Offset : constant Natural := Word (Header (Block) + 16);
         Size : constant Natural := Word (Header (Block) + 20);
      begin
         if Offset > Data'Length or else Size > Data'Length - Offset then
            raise Constraint_Error;
         end if;
         return US.To_Unbounded_String
           (Firmware.Image_Block_Fault
              (Data (Data'First + Offset .. Data'First + Offset + Size - 1),
               Core));
      end;
   exception
      when Constraint_Error =>
         return US.To_Unbounded_String
           ("the assembled object is not a well-formed ELF object");
   end Fault;

end Landin.Driver.Image_Block;
