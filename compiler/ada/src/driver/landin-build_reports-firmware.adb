with Ada.Containers.Indefinite_Ordered_Sets;
with Ada.Strings.Fixed;
with Landin.Targets.Firmware;

package body Landin.Build_Reports.Firmware is
   package US renames Ada.Strings.Unbounded;
   package Members is new Ada.Containers.Indefinite_Ordered_Sets (String);
   use type Landin.Platform.Read_Status;
   use type Landin.Targets.Byte_Count;

   function Image (Value : Landin.Targets.Byte_Count) return String is
     (Ada.Strings.Fixed.Trim (Value'Image, Ada.Strings.Both));

   procedure Measure
     (Host : Landin.Platform.Filesystem'Class;
      Executable, Link_Map : String;
      Result : out US.Unbounded_String;
      Valid : out Boolean)
   is
      ELF, Map : US.Unbounded_String;
      Status : Landin.Platform.Read_Status;
      Flash_End : Landin.Targets.Byte_Count := 0;
      RAM_End : Landin.Targets.Byte_Count :=
        Landin.Targets.Firmware.RAM_Base;
      Selected : Members.Set;
      Prefix : constant String := "libgcc.a(";
   begin
      Result := US.Null_Unbounded_String;
      Valid := False;
      Host.Read_File (Executable, ELF, Status);
      if Status /= Landin.Platform.Read_Ok then
         return;
      end if;
      Host.Read_File (Link_Map, Map, Status);
      if Status /= Landin.Platform.Read_Ok then
         return;
      end if;

      declare
         Data : constant String := US.To_String (ELF);
         Mapping : constant String := US.To_String (Map);

         function Number (Position : Natural; Width : Positive)
           return Landin.Targets.Byte_Count;

         function Number (Position : Natural; Width : Positive)
           return Landin.Targets.Byte_Count is
            Value : Landin.Targets.Byte_Count := 0;
         begin
            if Position > Data'Length
              or else Width > Data'Length - Position
            then
               raise Constraint_Error;
            end if;
            for Offset in reverse 0 .. Width - 1 loop
               Value := Value * 256
                 + Character'Pos (Data (Position + Offset + 1));
            end loop;
            return Value;
         end Number;

         function Word (Position : Natural) return Landin.Targets.Byte_Count is
           (Number (Position, 4));
      begin
         if Mapping'Length = 0
           or else Data'Length < 52
           or else Data (1 .. 6) /= Character'Val (127) & "ELF"
             & Character'Val (1) & Character'Val (1)
           or else Number (16, 2) /= 2
           or else Number (18, 2) /= 40
           or else Word (20) /= 1
           or else Number (40, 2) /= 52
           or else Number (42, 2) /= 32
         then
            return;
         end if;
         declare
            Header : constant Natural := Natural (Word (28));
            Count : constant Natural := Natural (Number (44, 2));
         begin
            if Count = 0 or else Header > Data'Length
              or else Count > (Data'Length - Header) / 32
            then
               return;
            end if;
            for Index in 0 .. Count - 1 loop
               declare
                  Position : constant Natural := Header + Index * 32;
                  Kind : constant Landin.Targets.Byte_Count := Word (Position);
                  File_At : constant Landin.Targets.Byte_Count :=
                    Word (Position + 4);
                  Virtual : constant Landin.Targets.Byte_Count :=
                    Word (Position + 8);
                  Physical : constant Landin.Targets.Byte_Count :=
                    Word (Position + 12);
                  File_Size : constant Landin.Targets.Byte_Count :=
                    Word (Position + 16);
                  Memory_Size : constant Landin.Targets.Byte_Count :=
                    Word (Position + 20);
               begin
                  if Kind = 1 then
                     if File_Size > Memory_Size
                       or else File_At > Landin.Targets.Byte_Count
                         (Data'Length)
                       or else File_Size > Landin.Targets.Byte_Count
                         (Data'Length) - File_At
                     then
                        return;
                     end if;
                     if Virtual < Landin.Targets.Firmware.Flash_Size then
                        if Virtual + Memory_Size >
                          Landin.Targets.Firmware.Flash_Size
                        then
                           return;
                        end if;
                     elsif Virtual >= Landin.Targets.Firmware.RAM_Base
                       and then Virtual + Memory_Size <=
                         Landin.Targets.Firmware.RAM_Base
                           + Landin.Targets.Firmware.RAM_Size
                           - Landin.Targets.Firmware.Stack_Size
                     then
                        RAM_End := Landin.Targets.Byte_Count'Max
                          (RAM_End, Virtual + Memory_Size);
                     else
                        return;
                     end if;
                     if File_Size > 0 then
                        if Physical + File_Size >
                          Landin.Targets.Firmware.Flash_Size
                        then
                           return;
                        end if;
                        Flash_End := Landin.Targets.Byte_Count'Max
                          (Flash_End, Physical + File_Size);
                     end if;
                  end if;
               end;
            end loop;
         end;
         if Flash_End = 0 then
            return;
         end if;

         --  Every occurrence is a selected archive member in GNU ld's map.
         --  Strip the toolchain path so equivalent builds retain equal JSON.
         declare
            Cursor : Positive := Mapping'First;
         begin
            loop
               declare
                  Found : constant Natural :=
                    Ada.Strings.Fixed.Index (Mapping, Prefix, From => Cursor);
               begin
                  exit when Found = 0;
                  declare
                     First : constant Positive := Found + Prefix'Length;
                     Last : constant Natural :=
                       Ada.Strings.Fixed.Index (Mapping, ")", From => First);
                  begin
                     if Last = 0 or else Last = First then
                        return;
                     end if;
                     for Index in First .. Last - 1 loop
                        if Mapping (Index) not in 'A' .. 'Z'
                          and then Mapping (Index) not in 'a' .. 'z'
                          and then Mapping (Index) not in '0' .. '9'
                          and then Mapping (Index) not in '_' | '-' | '.' | '+'
                        then
                           return;
                        end if;
                     end loop;
                     Selected.Include (Mapping (First .. Last - 1));
                     exit when Last = Mapping'Last;
                     Cursor := Last + 1;
                  end;
               end;
            end loop;
         end;
      end;

      US.Append (Result, "{""flash_used"":" & Image (Flash_End)
        & ",""flash_limit"":"
        & Image (Landin.Targets.Firmware.Flash_Size)
        & ",""flash_remaining"":"
        & Image (Landin.Targets.Firmware.Flash_Size - Flash_End)
        & ",""static_ram_used"":"
        & Image (RAM_End - Landin.Targets.Firmware.RAM_Base)
        & ",""static_ram_limit"":"
        & Image (Landin.Targets.Firmware.RAM_Size
          - Landin.Targets.Firmware.Stack_Size)
        & ",""static_ram_remaining"":"
        & Image (Landin.Targets.Firmware.RAM_Base
          + Landin.Targets.Firmware.RAM_Size
          - Landin.Targets.Firmware.Stack_Size - RAM_End)
        & ",""stack_reserved"":"
        & Image (Landin.Targets.Firmware.Stack_Size)
        & ",""runtime_members"":[");
      for Member of Selected loop
         if Member /= Selected.First_Element then
            US.Append (Result, ",");
         end if;
         US.Append (Result, """" & Member & """");
      end loop;
      US.Append (Result, "]}");
      Valid := True;
   exception
      when Constraint_Error =>
         Result := US.Null_Unbounded_String;
         Valid := False;
   end Measure;
end Landin.Build_Reports.Firmware;
