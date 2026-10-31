with Ada.Containers.Indefinite_Ordered_Sets;
with Ada.Strings.Fixed;

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
      Profile : Landin.Targets.Firmware.Profile;
      Result : out US.Unbounded_String;
      Valid : out Boolean)
   is
      package Firmware renames Landin.Targets.Firmware;
      use type Firmware.Section_Kind;
      ELF, Map : US.Unbounded_String;
      Status : Landin.Platform.Read_Status;
      Flash : constant Firmware.Region :=
        Firmware.Placed_Region (Profile, Firmware.Text);
      RAM : constant Firmware.Region :=
        Firmware.Placed_Region (Profile, Firmware.Data);
      RAM_Limit : constant Landin.Targets.Byte_Count :=
        Firmware.Static_RAM_Capacity (Profile);
      Flash_End : Landin.Targets.Byte_Count := Flash.Origin;
      RAM_End : Landin.Targets.Byte_Count := RAM.Origin;

      --  Whether [FIRST, FIRST + SIZE) lies in a region of the profile,
      --  and which: a region placement (D547) is outside the two the
      --  capacity figures describe and is still the image's.
      function Region_Of
        (First, Size : Landin.Targets.Byte_Count)
         return Firmware.Region_Count;
      function Region_Of
        (First, Size : Landin.Targets.Byte_Count) return Firmware.Region_Count
      is
      begin
         for Index in 1 .. Profile.Count loop
            if First >= Profile.Regions (Index).Origin
              and then First + Size <= Profile.Regions (Index).Origin
                + Profile.Regions (Index).Length
            then
               return Index;
            end if;
         end loop;
         return 0;
      end Region_Of;
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
                     if Region_Of (Virtual, Memory_Size)
                       = Profile.Placed (Firmware.Text)
                     then
                        null;
                     elsif Region_Of (Virtual, Memory_Size)
                       = Profile.Placed (Firmware.Data)
                     then
                        if Virtual + Memory_Size > RAM.Origin + RAM_Limit
                        then
                           return;
                        end if;
                        RAM_End := Landin.Targets.Byte_Count'Max
                          (RAM_End, Virtual + Memory_Size);
                     elsif Region_Of (Virtual, Memory_Size) = 0 then
                        return;
                     end if;
                     if File_Size > 0 then
                        if Region_Of (Physical, File_Size) = 0
                          or else Firmware.Writable
                            (Profile.Regions
                               (Region_Of (Physical, File_Size)).Mode)
                        then
                           return;
                        end if;
                        if Region_Of (Physical, File_Size)
                          = Profile.Placed (Firmware.Text)
                        then
                           Flash_End := Landin.Targets.Byte_Count'Max
                             (Flash_End, Physical + File_Size);
                        end if;
                     end if;
                  end if;
               end;
            end loop;
         end;
         if Flash_End = Flash.Origin then
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

      US.Append (Result, "{""flash_used"":" & Image (Flash_End - Flash.Origin)
        & ",""flash_limit"":" & Image (Flash.Length)
        & ",""flash_remaining"":"
        & Image (Flash.Origin + Flash.Length - Flash_End)
        & ",""static_ram_used"":" & Image (RAM_End - RAM.Origin)
        & ",""static_ram_limit"":" & Image (RAM_Limit)
        & ",""static_ram_remaining"":"
        & Image (RAM.Origin + RAM_Limit - RAM_End)
        & ",""stack_reserved"":" & Image (Profile.Stack_Size)
        & ",""runtime_members"":[");
      for Member of Selected loop
         if Member /= Selected.First_Element then
            US.Append (Result, ",");
         end if;
         US.Append (Result, """" & Member & """");
      end loop;
      --  D543: what the description selected, so that a check can compare
      --  each fact with one recorded apart from the compiler.
      US.Append (Result, "],""device"":"""
        & Firmware.Spelling (Profile.Device)
        & """,""core"":""" & Firmware.Spelling (Profile.Core)
        & """,""boot"":""" & Firmware.Spelling (Profile.Boot)
        & """,""vector_address"":" & Image (Firmware.Vector_Address (Profile))
        & ",""vector_words"":" & Image
          (Landin.Targets.Byte_Count (Profile.Vector_Count))
        & ",""regions"":[");
      for Index in 1 .. Profile.Count loop
         US.Append (Result, (if Index = 1 then "" else ",")
           & "{""name"":"""
           & Firmware.Spelling (Profile.Regions (Index).Name)
           & """,""origin"":" & Image (Profile.Regions (Index).Origin)
           & ",""length"":" & Image (Profile.Regions (Index).Length)
           & ",""access"":"""
           & Firmware.Spelling (Profile.Regions (Index).Mode) & """}");
      end loop;
      US.Append (Result, "],""placed"":{");
      for Section in Firmware.Section_Kind loop
         US.Append (Result,
           (if Section = Firmware.Section_Kind'First then "" else ",")
           & """" & Firmware.Spelling (Section) & """:"""
           & Firmware.Spelling
               (Firmware.Placed_Region (Profile, Section).Name) & """");
      end loop;
      US.Append (Result, "}}");
      Valid := True;
   exception
      when Constraint_Error =>
         Result := US.Null_Unbounded_String;
         Valid := False;
   end Measure;
end Landin.Build_Reports.Firmware;
