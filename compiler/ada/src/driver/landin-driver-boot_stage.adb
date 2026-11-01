with Ada.Strings.Fixed;
with Landin.Targets.Firmware;

package body Landin.Driver.Boot_Stage is
   package US renames Ada.Strings.Unbounded;
   package Firmware renames Landin.Targets.Firmware;

   use type Firmware.Checksum;

   --  ELF's section types and flags this reads.
   Relocations : constant := 9;
   Addend_Relocations : constant := 4;
   Allocated : constant := 2;

   function Image (Value : Natural) return String;
   function Image (Value : Natural) return String is
     (Ada.Strings.Fixed.Trim (Value'Image, Ada.Strings.Both));

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

   procedure Seal
     (Object : in out US.Unbounded_String;
      Fault : out US.Unbounded_String)
   is
      Data : String := US.To_String (Object);
      Sum : Firmware.Checksum;

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

      Sections : Natural;
      Entry_Size : Natural;
      Count : Natural;
      Names_At : Natural;
      Stage : Natural := 0;

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

      function Symbol_Section (Table, Symbol : Natural) return Natural is
        (Number (Word (Header (Table) + 16) + Symbol * 16 + 14, 2));
   begin
      Fault := US.Null_Unbounded_String;
      if Data'Length < 52
        or else Data (Data'First .. Data'First + 5)
          /= Character'Val (127) & "ELF" & Character'Val (1)
            & Character'Val (1)
        or else Number (16, 2) /= 1
        or else Number (18, 2) /= 40
      then
         Fault := US.To_Unbounded_String
           ("the assembled object is not a 32-bit little-endian Arm"
            & " relocatable object");
         return;
      end if;
      Sections := Word (32);
      Entry_Size := Number (46, 2);
      Count := Number (48, 2);
      if Entry_Size < 40 then
         raise Constraint_Error;
      end if;
      Names_At := Word (Header (Number (50, 2)) + 16);
      for Index in 1 .. Count - 1 loop
         if Section_Name (Index) = ".boot2" then
            Stage := Index;
         end if;
      end loop;
      if Stage = 0 or else Word (Header (Stage) + 4) = 8 then
         Fault := US.To_Unbounded_String
           ("the assembled object holds no .boot2 section of the second"
            & " stage's bytes");
         return;
      end if;
      declare
         Size : constant Natural := Word (Header (Stage) + 20);
         Offset : constant Natural := Word (Header (Stage) + 16);
      begin
         if Size /= Firmware.Stage_Slot then
            Fault := US.To_Unbounded_String
              ("the second stage and its literals are "
               & Image (Natural'Max (Size, 4) - 4) & " bytes, and its"
               & " slot holds " & Image (Firmware.Stage_Limit)
               & " before the checksum: make the stage shorter");
            return;
         end if;
         for Index in 1 .. Count - 1 loop
            declare
               Kind : constant Natural := Word (Header (Index) + 4);
               Target : constant Natural := Word (Header (Index) + 28);
               Table : constant Natural := Word (Header (Index) + 24);
               Size_Of : constant Natural :=
                 (if Kind = Relocations then 8 else 12);
            begin
               if Kind in Relocations | Addend_Relocations
                 and then Target < Count
                 and then (Target = Stage
                           or else (Word (Header (Target) + 8) / Allocated)
                             mod 2 = 1)
               then
                  for Which in 0 .. Word (Header (Index) + 20) / Size_Of - 1
                  loop
                     declare
                        At_Entry : constant Natural :=
                          Word (Header (Index) + 16) + Which * Size_Of;
                        Symbol : constant Natural :=
                          Word (At_Entry + 4) / 256;
                     begin
                        if Target = Stage then
                           Fault := US.To_Unbounded_String
                             ("the second stage holds a relocation at"
                              & " offset " & Hex (Word (At_Entry))
                              & (if Symbol = 0 then " against no symbol"
                                 else " against "
                                   & Symbol_Name (Table, Symbol))
                              & ", and the boot ROM runs it from a copy at"
                              & " an address it is not linked at: write it"
                              & " with no symbol outside itself");
                           return;
                        elsif Symbol /= 0
                          and then Symbol_Section (Table, Symbol) = Stage
                        then
                           Fault := US.To_Unbounded_String
                             ("a relocation in " & Section_Name (Target)
                              & " at offset " & Hex (Word (At_Entry))
                              & " refers to the second stage through "
                              & Symbol_Name (Table, Symbol)
                              & ", which only the boot ROM enters, from a"
                              & " copy at another address: refer to it"
                              & " nowhere");
                           return;
                        end if;
                     end;
                  end loop;
               end if;
            end;
         end loop;
         if Offset > Data'Length or else Size > Data'Length - Offset then
            raise Constraint_Error;
         end if;
         Sum := Firmware.Stage_Checksum
           (Data (Data'First + Offset
                  .. Data'First + Offset + Firmware.Stage_Limit - 1));
         for Byte in 0 .. 3 loop
            Data (Data'First + Offset + Firmware.Stage_Limit + Byte) :=
              Character'Val (Natural ((Sum / 2 ** (8 * Byte)) mod 256));
         end loop;
         Object := US.To_Unbounded_String (Data);
      end;
   exception
      when Constraint_Error =>
         Fault := US.To_Unbounded_String
           ("the assembled object is not a well-formed ELF object");
   end Seal;

end Landin.Driver.Boot_Stage;
