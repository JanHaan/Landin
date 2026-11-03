with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Containers.Indefinite_Ordered_Sets;
with Ada.Strings.Fixed;

package body Landin.Build_Reports.Firmware is
   package US renames Ada.Strings.Unbounded;
   package Members is new Ada.Containers.Indefinite_Ordered_Sets (String);
   use type Landin.Platform.Read_Status;
   use type Landin.Targets.Byte_Count;
   use type Landin.Targets.Firmware.Layout_Kind;

   function Image (Value : Landin.Targets.Byte_Count) return String is
     (Ada.Strings.Fixed.Trim (Value'Image, Ada.Strings.Both));

   --  D543: what the description selected, so that a check can compare
   --  each fact with one recorded apart from the compiler.
   function Facts (Profile : Landin.Targets.Firmware.Profile) return String;
   function Facts (Profile : Landin.Targets.Firmware.Profile) return String
   is
      package Firmware renames Landin.Targets.Firmware;
      use type Firmware.Section_Kind;
      Result : US.Unbounded_String;
   begin
      US.Append (Result, """device"":"""
        & Firmware.Spelling (Profile.Device)
        & """,""core"":""" & Firmware.Spelling (Profile.Core)
        & """,""float_unit"":""" & Firmware.Spelling (Profile.Float)
        & """,""layout"":""" & Firmware.Spelling (Profile.Layout)
        & """,""described_boot"":"""
        & Firmware.Spelling (Profile.Described_Boot)
        & """,""boot"":""" & Firmware.Spelling (Profile.Boot)
        & """,""vector_address"":" & Image (Firmware.Vector_Address (Profile))
        & ",""vector_words"":" & Image
          (Landin.Targets.Byte_Count (Profile.Vector_Count))
        & ",""boot_prefix"":" & Image (Firmware.Boot_Prefix (Profile.Boot))
        & ",""boot_suffix"":" & Image (Firmware.Boot_Suffix (Profile.Boot))
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
      US.Append (Result, "},""code_limit"":"
        & Image (Firmware.Flash_Capacity (Profile))
        & ",""ram_layout_limit"":" & Image (Firmware.RAM_Capacity (Profile)));
      return US.To_String (Result);
   end Facts;

   function Limits (Profile : Landin.Targets.Firmware.Profile) return String
   is
      package Firmware renames Landin.Targets.Firmware;
      Stack : constant Firmware.Region :=
        Firmware.Placed_Region (Profile, Firmware.Stack);
   begin
      return "{""flash_limit"":"
        & Image (if Profile.Layout = Firmware.RAM_Layout then 0
                 else Firmware.Flash_Capacity (Profile))
        & ",""static_ram_limit"":"
        & Image (Firmware.Static_RAM_Capacity (Profile))
        & ",""stack_reserved"":" & Image (Profile.Stack_Size)
        & ",""stack_top"":" & Image (Stack.Origin + Stack.Length)
        & "," & Facts (Profile)
        & (if Firmware.Takes_Stage (Profile.Boot)
           then ",""boot_stage"":{""slot"":"
             & Image (Landin.Targets.Byte_Count (Firmware.Stage_Slot))
             & ",""checksum_address"":"
             & Image (Firmware.Placed_Region (Profile, Firmware.Vectors).Origin
               + Landin.Targets.Byte_Count (Firmware.Stage_Limit)) & "}"
           else "")
        & (if Firmware.Takes_Image_Block (Profile.Boot)
           then ",""image_block"":{""address"":"
             & Image (Firmware.Vector_Address (Profile)
               + Firmware.Vector_Bytes (Profile))
             & ",""bytes"":" & Image (Firmware.Image_Block_Bytes) & "}"
           else "")
        & (if Firmware.Takes_ESP_Image (Profile.Boot)
           then ",""esp_image"":{""offset"":" & Image (Profile.ESP_Offset)
             & ",""chip"":" & Image
               (Landin.Targets.Byte_Count (Profile.ESP_Chip))
             & ",""min_revision"":" & Image
               (Landin.Targets.Byte_Count (Profile.ESP_Minimum))
             & ",""max_revision"":" & Image
               (Landin.Targets.Byte_Count (Profile.ESP_Maximum)) & "}"
           else "")
        & "}";
   end Limits;

   procedure Measure
     (Host : Landin.Platform.Filesystem'Class;
      Executable, Link_Map : String;
      Profile : Landin.Targets.Firmware.Profile;
      Stage : String;
      Result : out US.Unbounded_String;
      Valid : out Boolean;
      ESP_Image : String := "")
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
      --  D588: the second stage as the linked image holds it.
      Stage_At, Stage_Bytes, Stage_Sum : Landin.Targets.Byte_Count := 0;
      --  D638: the image block as the linked image holds it.
      Block_At, Block_Bytes : Landin.Targets.Byte_Count := 0;
      Block_Words, Load_Segments : US.Unbounded_String;
      RAM_Used : Landin.Targets.Byte_Count := 0;
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

         --  The value and size of the symbol named WANTED.
         procedure Find
           (Wanted : String; Found : out Boolean;
            Value, Size : out Landin.Targets.Byte_Count);
         procedure Find
           (Wanted : String; Found : out Boolean;
            Value, Size : out Landin.Targets.Byte_Count)
         is
            Sections : constant Natural := Natural (Word (32));
            Entry_Size : constant Natural := Natural (Number (46, 2));
            Named : constant String := Wanted & ASCII.NUL;
         begin
            Found := False;
            Value := 0;
            Size := 0;
            for Index in 0 .. Natural (Number (48, 2)) - 1 loop
               declare
                  Header : constant Natural := Sections + Index * Entry_Size;
               begin
                  if Word (Header + 4) = 2 then
                     declare
                        Table : constant Natural :=
                          Natural (Word (Header + 16));
                        Strings : constant Natural := Natural (Word
                          (Sections + Natural (Word (Header + 24))
                           * Entry_Size + 16));
                     begin
                        for Symbol in 1 .. Natural (Word (Header + 20))
                          / 16 - 1
                        loop
                           declare
                              Name : constant Natural := Strings + Natural
                                (Word (Table + Symbol * 16));
                           begin
                              if not Found
                                and then Name + Named'Length <= Data'Length
                                and then Data (Name + 1
                                  .. Name + Named'Length) = Named
                              then
                                 Found := True;
                                 Value := Word (Table + Symbol * 16 + 4);
                                 Size := Word (Table + Symbol * 16 + 8);
                              end if;
                           end;
                        end loop;
                     end;
                  end if;
               end;
            end loop;
         end Find;

         --  The file offset of load address ADDRESS, holding SIZE bytes of
         --  file content, or Natural'Last when no segment does.
         function Loaded (Address, Size : Landin.Targets.Byte_Count)
           return Natural;
         function Loaded (Address, Size : Landin.Targets.Byte_Count)
           return Natural
         is
            Header : constant Natural := Natural (Word (28));
         begin
            for Index in 0 .. Natural (Number (44, 2)) - 1 loop
               declare
                  At_Entry : constant Natural := Header + Index * 32;
                  Physical : constant Landin.Targets.Byte_Count :=
                    Word (At_Entry + 12);
               begin
                  if Word (At_Entry) = 1
                    and then Address >= Physical
                    and then Address + Size <= Physical + Word (At_Entry + 16)
                  then
                     return Natural
                       (Word (At_Entry + 4) + (Address - Physical));
                  end if;
               end;
            end loop;
            return Natural'Last;
         end Loaded;
      begin
         if Mapping'Length = 0
           or else Data'Length < 52
           or else Data (1 .. 6) /= Character'Val (127) & "ELF"
             & Character'Val (1) & Character'Val (1)
           or else Number (16, 2) /= 2
           or else Number (18, 2)
             /= (if Profile.Core in Firmware.RISC_V_Core then 243 else 40)
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
                  --  An empty segment, which an RV32 script's named
                  --  segments leave when their sections are (D686), loads
                  --  nothing.
                  if Kind = 1 and then Memory_Size > 0 then
                     if File_Size > Memory_Size
                       or else File_At > Landin.Targets.Byte_Count
                         (Data'Length)
                       or else File_Size > Landin.Targets.Byte_Count
                         (Data'Length) - File_At
                     then
                        return;
                     end if;
                     if Firmware.RAM_Only (Profile) then
                        RAM_Used := RAM_Used + Memory_Size;
                     end if;
                     if File_Size > 0 then
                        US.Append (Load_Segments,
                          (if US.Length (Load_Segments) = 0 then "" else ",")
                          & "{""address"":" & Image (Physical)
                          & ",""runtime_address"":" & Image (Virtual)
                          & ",""file_bytes"":" & Image (File_Size)
                          & ",""memory_bytes"":" & Image (Memory_Size)
                          & "}");
                     end if;
                     --  A segment in the data region is static RAM, even
                     --  where text shares the region, as on an ESP32's
                     --  SRAM (D685).
                     if Region_Of (Virtual, Memory_Size)
                       = Profile.Placed (Firmware.Data)
                     then
                        if Virtual + Memory_Size > RAM.Origin + RAM_Limit
                        then
                           return;
                        end if;
                        RAM_End := Landin.Targets.Byte_Count'Max
                          (RAM_End, Virtual + Memory_Size);
                     elsif Region_Of (Virtual, Memory_Size)
                       = Profile.Placed (Firmware.Text)
                     then
                        null;
                     elsif Region_Of (Virtual, Memory_Size) = 0 then
                        return;
                     end if;
                     if File_Size > 0 then
                        --  An ESP32's ROM loads every segment into RAM, so
                        --  its image is written to writable memory.
                        if Region_Of (Physical, File_Size) = 0
                          or else (Firmware.Writable
                                     (Profile.Regions
                                        (Region_Of (Physical, File_Size)).Mode)
                                   and then not Firmware.RAM_Only (Profile))
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
         if Firmware.Takes_Stage (Profile.Boot) then
            declare
               Found : Boolean;
               At_File : Natural;
            begin
               Find ("_landin_firmware_boot2", Found, Stage_At, Stage_Bytes);
               if not Found then
                  return;
               end if;
               --  The checksum's word, through the segment that loads it.
               At_File := Loaded
                 (Stage_At + Landin.Targets.Byte_Count (Firmware.Stage_Limit),
                  4);
               if At_File = Natural'Last then
                  return;
               end if;
               Stage_Sum := Word (At_File);
            end;
         end if;
         --  D638: the image block, through the segment that loads it.
         if Firmware.Takes_Image_Block (Profile.Boot) then
            declare
               Found : Boolean;
               At_File : Natural;
            begin
               Find ("_landin_firmware_image_block", Found, Block_At,
                     Block_Bytes);
               if not Found or else Block_Bytes mod 4 /= 0 then
                  return;
               end if;
               At_File := Loaded (Block_At, Block_Bytes);
               if At_File = Natural'Last then
                  return;
               end if;
               for Index in 0 .. Natural (Block_Bytes) / 4 - 1 loop
                  US.Append (Block_Words, (if Index = 0 then "" else ",")
                    & Image (Word (At_File + 4 * Index)));
               end loop;
            end;
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

      US.Append (Result, "{""flash_used"":"
        & Image (if Profile.Layout = Firmware.RAM_Layout then 0
                 else Flash_End - Flash.Origin)
        & ",""flash_limit"":"
        & Image (if Profile.Layout = Firmware.RAM_Layout then 0
                 else Flash.Length)
        & ",""flash_remaining"":"
        & Image (if Profile.Layout = Firmware.RAM_Layout then 0
                 else Flash.Origin + Flash.Length - Flash_End)
        & ",""code_used"":" & Image (Flash_End - Flash.Origin)
        & ",""ram_layout_used"":" & Image (RAM_Used)
        & ",""load_segments"":[" & US.To_String (Load_Segments) & "]"
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
      US.Append (Result, "]," & Facts (Profile));
      if Firmware.Takes_Stage (Profile.Boot) then
         US.Append (Result, ",""boot_stage"":{""routine"":"""
           & Stage & """,""address"":" & Image (Stage_At)
           & ",""bytes"":" & Image (Stage_Bytes)
           & ",""slot"":" & Image
             (Landin.Targets.Byte_Count (Firmware.Stage_Slot))
           & ",""checksum"":" & Image (Stage_Sum)
           & ",""checksum_address"":" & Image
             (Stage_At + Landin.Targets.Byte_Count (Firmware.Stage_Limit))
           & "}");
      end if;
      if Firmware.Takes_Image_Block (Profile.Boot) then
         US.Append (Result, ",""image_block"":{""address"":" & Image (Block_At)
           & ",""bytes"":" & Image (Block_Bytes)
           & ",""words"":[" & US.To_String (Block_Words) & "]}");
      end if;
      if Firmware.Takes_ESP_Image (Profile.Boot) then
         if ESP_Image = "" then
            return;
         end if;
         US.Append (Result, ",""esp_image"":{" & ESP_Image & "}");
      end if;
      US.Append (Result, "}");
      Valid := True;
   exception
      when Constraint_Error =>
         Result := US.Null_Unbounded_String;
         Valid := False;
   end Measure;
   --  Where WORD, at address AT_ADDRESS, jumps, when it is RISC-V's
   --  `jal x0`, the `j` an RV32 entry word is (D686); otherwise 0.
   function Jump_Target
     (Word, At_Address : Landin.Targets.Byte_Count)
      return Landin.Targets.Byte_Count;
   function Jump_Target
     (Word, At_Address : Landin.Targets.Byte_Count)
      return Landin.Targets.Byte_Count
   is
      subtype Count is Landin.Targets.Byte_Count;
      function Bits (Low, Width : Natural) return Count is
        ((Word / 2 ** Low) mod 2 ** Width);
      Offset : constant Count :=
        Bits (31, 1) * 2 ** 20 + Bits (12, 8) * 2 ** 12
        + Bits (20, 1) * 2 ** 11 + Bits (21, 10) * 2;
   begin
      if Word mod 128 /= 16#6F# or else Bits (7, 5) /= 0 then
         return 0;
      end if;
      --  The offset is 21 bits, two's complement.
      return (At_Address + Offset + 2 ** 32 - Bits (31, 1) * 2 ** 21)
        mod 2 ** 32;
   end Jump_Target;

   function Contract_Fault
     (Host : Landin.Platform.Filesystem'Class;
      Executable : String;
      Profile : Landin.Targets.Firmware.Profile;
      Used : Landin.Backend.Firmware.Region_Use) return String
   is
      package Firmware renames Landin.Targets.Firmware;
      type Word_List is array (Positive range <>) of access constant String;
      Load : aliased constant String := "load";
      Start : aliased constant String := "start";
      Finish : aliased constant String := "end";
      Data_Stem : aliased constant String := "data";
      Ramtext_Stem : aliased constant String := "ramtext";
      BSS_Stem : aliased constant String := "bss";
      Image_Parts : constant Word_List :=
        [Load'Access, Start'Access, Finish'Access];
      Ram_Images : constant Word_List :=
        [Data_Stem'Access, Ramtext_Stem'Access, BSS_Stem'Access];
      package Symbol_Maps is new Ada.Containers.Indefinite_Ordered_Maps
        (Key_Type => String, Element_Type => Landin.Targets.Byte_Count);
      use type Firmware.Boot_Kind;
      ELF : US.Unbounded_String;
      Status : Landin.Platform.Read_Status;
      Symbols : Symbol_Maps.Map;
      RV32 : constant Boolean := Profile.Core in Firmware.RISC_V_Core;
   begin
      Host.Read_File (Executable, ELF, Status);
      if Status /= Landin.Platform.Read_Ok then
         return "the linked image cannot be read: " & Executable;
      end if;
      declare
         Data : constant String := US.To_String (ELF);

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

         function Word (Position : Natural) return Landin.Targets.Byte_Count
           is (Number (Position, 4));

         function Text_At (Position : Natural) return String;
         function Text_At (Position : Natural) return String is
            Last : Natural := Position;
         begin
            while Last < Data'Length and then Data (Last + 1) /= ASCII.NUL
            loop
               Last := Last + 1;
            end loop;
            return Data (Position + 1 .. Last);
         end Text_At;

         --  The file offset of load address ADDRESS, holding SIZE bytes
         --  of file content, or Natural'Last when no segment does.
         function Loaded (Address, Size : Landin.Targets.Byte_Count)
           return Natural;
         function Loaded (Address, Size : Landin.Targets.Byte_Count)
           return Natural
         is
            Header : constant Natural := Natural (Word (28));
         begin
            for Index in 0 .. Natural (Number (44, 2)) - 1 loop
               declare
                  At_Entry : constant Natural := Header + Index * 32;
                  Physical : constant Landin.Targets.Byte_Count :=
                    Word (At_Entry + 12);
                  File_Size : constant Landin.Targets.Byte_Count :=
                    Word (At_Entry + 16);
               begin
                  if Word (At_Entry) = 1
                    and then Address >= Physical
                    and then Address + Size <= Physical + File_Size
                  then
                     return Natural (Word (At_Entry + 4)
                       + (Address - Physical));
                  end if;
               end;
            end loop;
            return Natural'Last;
         end Loaded;

         function Has (Name : String) return Boolean
           is (Symbols.Contains (Name));
         function Value (Name : String) return Landin.Targets.Byte_Count
           is (Symbols.Element (Name));

         function Within
           (First, Size : Landin.Targets.Byte_Count;
            Of_Region : Firmware.Region) return Boolean
           is (First >= Of_Region.Origin
               and then First + Size <= Of_Region.Origin + Of_Region.Length);

         function RAM_Range_Fault
           (First, Size : Landin.Targets.Byte_Count; Name : String)
            return String;
         function RAM_Range_Fault
           (First, Size : Landin.Targets.Byte_Count; Name : String)
            return String is
         begin
            if Size = 0 then
               return "";
            elsif First < Value ("_landin_firmware_stack_top")
              and then First + Size > Value ("_landin_firmware_stack_bottom")
            then
               return "clause 3, the stack: " & Name
                 & " overlaps the reserved stack";
            elsif not (for some Region in 1 .. Profile.Count =>
              Firmware.RAM_Region (Profile, Region)
              and then Within (First, Size, Profile.Regions (Region)))
            then
               return "clause 4, the RAM layout: " & Name
                 & " must stay in SRAM; use --firmware-layout=boot"
                 & " for the board boot check";
            end if;
            return "";
         end RAM_Range_Fault;

         function BSS_Fault (Stem : String) return String;
         function BSS_Fault (Stem : String) return String is
            First : constant Landin.Targets.Byte_Count :=
              Value (Stem & "_bss_start");
            Last : constant Landin.Targets.Byte_Count :=
              Value (Stem & "_bss_end");
         begin
            if Last < First then
               return "clause 4, the RAM layout: " & Stem
                 & "_bss_end precedes its start";
            end if;
            return RAM_Range_Fault (First, Last - First, Stem & " BSS range");
         end BSS_Fault;

         Required : US.Unbounded_String;
         Missing : US.Unbounded_String;

         procedure Need (Name : String);
         procedure Need (Name : String) is
         begin
            US.Append (Required, Name & " ");
            if not Has (Name) then
               US.Append (Missing, (if US.Length (Missing) = 0 then ""
                                     else ", ") & Name);
            end if;
         end Need;

         --  D546's fourth clause for one load image.
         function Image_Fault (Name, Load, First, Last : String)
           return String;
         function Image_Fault (Name, Load, First, Last : String)
           return String
         is
            Size : constant Landin.Targets.Byte_Count :=
              (if Value (Last) >= Value (First)
               then Value (Last) - Value (First) else 0);
         begin
            if Value (Last) < Value (First) then
               return "clause 4, the initialized images: " & Name
                 & " ends before it begins";
            elsif Size > 0 and then Profile.Layout = Firmware.RAM_Layout
              and then Value (Load) /= Value (First)
            then
               return "clause 4, the RAM layout: " & Name
                 & " must load at its runtime address";
            elsif Size > 0 and then Profile.Layout /= Firmware.RAM_Layout
              and then not Within
              (Value (Load), Size,
               Firmware.Placed_Region (Profile, Firmware.Text))
            then
               return "clause 4, the initialized images: " & Name
                 & "'s load image at "
                 & Landin.Backend.Firmware.Hex (Value (Load))
                 & " is not in "
                 & Firmware.Spelling
                     (Firmware.Placed_Region (Profile, Firmware.Text).Name)
                 & ", where text is placed";
            elsif Size > 0 and then Loaded (Value (Load), Size)
              = Natural'Last
            then
               return "clause 4, the initialized images: " & Name
                 & "'s load image holds no file content";
            end if;
            return "";
         end Image_Fault;
      begin
         if Data'Length < 52
           or else Data (1 .. 6) /= Character'Val (127) & "ELF"
             & Character'Val (1) & Character'Val (1)
           or else Number (16, 2) /= 2
           or else Number (18, 2) /= (if RV32 then 243 else 40)
         then
            return "the linked image is not a 32-bit little-endian "
              & (if RV32 then "RISC-V" else "Arm") & " executable";
         end if;
         declare
            Sections : constant Natural := Natural (Word (32));
            Size : constant Natural := Natural (Number (46, 2));
         begin
            for Index in 0 .. Natural (Number (48, 2)) - 1 loop
               declare
                  Header : constant Natural := Sections + Index * Size;
               begin
                  if Word (Header + 4) = 2 then
                     declare
                        Table : constant Natural :=
                          Natural (Word (Header + 16));
                        Count : constant Natural :=
                          Natural (Word (Header + 20)) / 16;
                        Strings_Header : constant Natural :=
                          Sections + Natural (Word (Header + 24)) * Size;
                        Strings : constant Natural :=
                          Natural (Word (Strings_Header + 16));
                     begin
                        for Symbol in 1 .. Count - 1 loop
                           declare
                              Name : constant String := Text_At
                                (Strings + Natural
                                   (Word (Table + Symbol * 16)));
                           begin
                              if Name'Length > 17
                                and then Name (Name'First .. Name'First + 16)
                                  = "_landin_firmware_"
                                and then not Symbols.Contains (Name)
                              then
                                 Symbols.Insert
                                   (Name, Word (Table + Symbol * 16 + 4));
                              end if;
                           end;
                        end loop;
                     end;
                  end if;
               end;
            end loop;
         end;

         --  Clause 2: the startup symbols.
         if RV32 then
            Need ("_landin_firmware_entry");
         end if;
         Need ("_landin_firmware_reset");
         if Profile.Has_Stage
           and then Firmware.Stage_Before_Reset (Profile.Boot)
         then
            Need (Firmware.Reset_Stage_Symbol);
         end if;
         Need ("_landin_firmware_unhandled");
         Need ("_landin_firmware_vectors");
         Need ("_landin_firmware_stack_top");
         Need ("_landin_firmware_stack_bottom");
         for Part of Image_Parts loop
            Need ("_landin_firmware_data_" & Part.all);
            Need ("_landin_firmware_ramtext_" & Part.all);
         end loop;
         Need ("_landin_firmware_bss_start");
         Need ("_landin_firmware_bss_end");
         if Profile.Boot = Firmware.RP2040_Boot2 then
            Need ("_landin_firmware_boot2");
         end if;
         if Firmware.Takes_Image_Block (Profile.Boot) then
            Need ("_landin_firmware_image_block");
         end if;
         for Index in 1 .. Profile.Count loop
            if Used (Index)
              and then Firmware.Writable (Profile.Regions (Index).Mode)
            then
               for Part of Image_Parts loop
                  Need ("_landin_firmware_region_"
                    & Firmware.Spelling (Profile.Regions (Index).Name)
                    & "_data_" & Part.all);
               end loop;
               Need ("_landin_firmware_region_"
                 & Firmware.Spelling (Profile.Regions (Index).Name)
                 & "_bss_start");
               Need ("_landin_firmware_region_"
                 & Firmware.Spelling (Profile.Regions (Index).Name)
                 & "_bss_end");
            end if;
         end loop;
         if US.Length (Missing) > 0 then
            return "clause 2, the startup symbols: the image defines no "
              & US.To_String (Missing);
         end if;

         --  Clause 1: the vector table at the boot address, whole.
         declare
            Address : constant Landin.Targets.Byte_Count :=
              Firmware.Vector_Address (Profile);
            Bytes : constant Landin.Targets.Byte_Count :=
              Firmware.Vector_Bytes (Profile);
            At_File : constant Natural := Loaded (Address, Bytes);
            Reset : constant String :=
              (if Profile.Has_Stage
                 and then Firmware.Stage_Before_Reset (Profile.Boot)
               then Firmware.Reset_Stage_Symbol else Firmware.Reset_Symbol);
         begin
            if Value ("_landin_firmware_vectors") /= Address then
               return "clause 1, the vector table: it is at "
                 & Landin.Backend.Firmware.Hex
                     (Value ("_landin_firmware_vectors"))
                 & " and " & Firmware.Spelling (Profile.Device)
                 & "'s boot address is "
                 & Landin.Backend.Firmware.Hex (Address);
            elsif At_File = Natural'Last then
               return "clause 1, the vector table: the image does not hold"
                 & " its" & Landin.Targets.Byte_Count'Image (Bytes)
                 & " bytes at its address";
            elsif not RV32
              and then
                (Word (At_File) /= Value ("_landin_firmware_stack_top")
                 or else Word (At_File + 4)
                   /= (Value (Reset) / 2) * 2 + 1)
            then
               return "clause 1, the vector table: its first words are not"
                 & " the initial stack pointer and reset";
            elsif RV32 then
               --  D686: the entry word at the image's start, a jump to the
               --  stage or to reset.
               declare
                  Origin : constant Landin.Targets.Byte_Count :=
                    Firmware.Placed_Region (Profile, Firmware.Vectors).Origin
                    + Firmware.Boot_Prefix (Profile.Boot);
                  Entry_File : constant Natural := Loaded
                    (Origin, Firmware.Entry_Word_Bytes);
                  Goes_To : constant String :=
                    (if Profile.Has_Stage
                       and then Firmware.Stage_Before_Reset (Profile.Boot)
                     then Firmware.Reset_Stage_Symbol
                     else Firmware.Reset_Symbol);
               begin
                  if Value ("_landin_firmware_entry") /= Origin
                    or else Entry_File = Natural'Last
                  then
                     return "clause 1, the vector table: the entry word is"
                       & " not at "
                       & Landin.Backend.Firmware.Hex (Origin)
                       & ", where the image begins";
                  elsif not Has (Goes_To)
                    or else Jump_Target (Word (Entry_File), Origin)
                      /= Value (Goes_To)
                  then
                     return "clause 1, the vector table: the entry word is"
                       & " not a jump to " & Goes_To;
                  end if;
               end;
            elsif Profile.Boot = Firmware.RP2040_Boot2
              and then Value ("_landin_firmware_boot2")
                /= Firmware.Placed_Region (Profile, Firmware.Vectors).Origin
            then
               return "clause 1, the vector table: the second stage is not"
                 & " at the start of "
                 & Firmware.Spelling
                     (Firmware.Placed_Region (Profile, Firmware.Vectors).Name);
            elsif Firmware.Takes_Stage (Profile.Boot) then
               --  D588: the stage the boot ROM copies, with the checksum
               --  refine wrote into its object.
               declare
                  use type Firmware.Checksum;
                  Slot : constant Natural := Loaded
                    (Value ("_landin_firmware_boot2"),
                     Landin.Targets.Byte_Count (Firmware.Stage_Slot));
               begin
                  if Slot = Natural'Last then
                     return "clause 1, the vector table: the image does not"
                       & " hold the second stage's"
                       & Natural'Image (Firmware.Stage_Slot)
                       & " bytes at its address";
                  elsif Firmware.Checksum
                      (Word (Slot + Firmware.Stage_Limit))
                    /= Firmware.Stage_Checksum
                      (Data (Slot + 1 .. Slot + Firmware.Stage_Limit))
                  then
                     return "clause 1, the vector table: the second stage's"
                       & " checksum is not the CRC-32 of its first"
                       & Natural'Image (Firmware.Stage_Limit) & " bytes";
                  end if;
               end;
            elsif Firmware.Takes_Image_Block (Profile.Boot) then
               --  D638: the block refine assembled, where the boot ROM
               --  searches for it.
               declare
                  Block : constant Landin.Targets.Byte_Count :=
                    Value ("_landin_firmware_image_block");
                  Window : constant Landin.Targets.Byte_Count :=
                    Firmware.Placed_Region (Profile, Firmware.Vectors).Origin
                    + Firmware.Image_Block_Window;
                  At_File : constant Natural :=
                    Loaded (Block, Firmware.Image_Block_Bytes);
               begin
                  if At_File = Natural'Last then
                     return "clause 1, the vector table: the image does not"
                       & " hold the image block's"
                       & Natural'Image (Firmware.Image_Block_Bytes)
                       & " bytes at its address";
                  elsif Block + Firmware.Image_Block_Bytes > Window then
                     return "clause 1, the vector table: the image block at "
                       & Landin.Backend.Firmware.Hex (Block)
                       & " ends past the first 4 KiB of "
                       & Firmware.Spelling
                           (Firmware.Placed_Region
                              (Profile, Firmware.Vectors).Name)
                       & ", where the boot ROM searches for it";
                  end if;
                  declare
                     Fault : constant String := Firmware.Image_Block_Fault
                       (Data (At_File + 1
                              .. At_File + Firmware.Image_Block_Bytes));
                  begin
                     if Fault /= "" then
                        return "clause 1, the vector table: the image block"
                          & " at " & Landin.Backend.Firmware.Hex (Block)
                          & " is not the one refine assembled: " & Fault;
                     end if;
                  end;
               end;
            end if;
         end;

         --  Clause 3: the stack, in a writable region, of its size.
         declare
            Top : constant Landin.Targets.Byte_Count :=
              Value ("_landin_firmware_stack_top");
            Bottom : constant Landin.Targets.Byte_Count :=
              Value ("_landin_firmware_stack_bottom");
            Held : Boolean := False;
         begin
            for Index in 1 .. Profile.Count loop
               Held := Held or else
                 (Firmware.Writable (Profile.Regions (Index).Mode)
                  and then Bottom <= Top
                  and then Within (Bottom, Top - Bottom,
                                   Profile.Regions (Index)));
            end loop;
            if Top mod (if RV32 then 16 else 8) /= 0 then
               return "clause 3, the stack: its top is not aligned to "
                 & (if RV32 then "sixteen" else "eight") & " bytes";
            elsif not Held then
               return "clause 3, the stack: it does not lie in a writable"
                 & " region of " & Firmware.Spelling (Profile.Device);
            elsif Top - Bottom /= Profile.Stack_Size then
               return "clause 3, the stack: it holds"
                 & Landin.Targets.Byte_Count'Image (Top - Bottom)
                 & " bytes and the description reserves"
                 & Landin.Targets.Byte_Count'Image (Profile.Stack_Size);
            end if;
            for Stem of Ram_Images loop
               declare
                  Name : constant String :=
                    "_landin_firmware_" & Stem.all & "_end";
                  First : constant String :=
                    "_landin_firmware_" & Stem.all & "_start";
               begin
                  if Value (Name) > Value (First)
                    and then Value (First) < Top
                    and then Value (Name) > Bottom
                  then
                     return "clause 3, the stack: ." & Stem.all
                       & " overlaps it";
                  end if;
               end;
            end loop;
         end;

         --  D900: a RAM run loads only described SRAM, at its execution
         --  address. This includes custom sections beyond startup's symbols.
         if Profile.Layout = Firmware.RAM_Layout then
            declare
               Header : constant Natural := Natural (Word (28));
            begin
               for Index in 0 .. Natural (Number (44, 2)) - 1 loop
                  declare
                     At_Entry : constant Natural := Header + Index * 32;
                     First : constant Landin.Targets.Byte_Count :=
                       Word (At_Entry + 8);
                     Physical : constant Landin.Targets.Byte_Count :=
                       Word (At_Entry + 12);
                     File_Size : constant Landin.Targets.Byte_Count :=
                       Word (At_Entry + 16);
                     Memory_Size : constant Landin.Targets.Byte_Count :=
                       Word (At_Entry + 20);
                  begin
                     if Word (At_Entry) = 1 and then Memory_Size > 0
                       and then First < Value ("_landin_firmware_stack_top")
                       and then First + Memory_Size
                         > Value ("_landin_firmware_stack_bottom")
                     then
                        return "clause 3, the stack: a RAM segment overlaps"
                          & " the reserved stack; use --firmware-layout=boot"
                          & " for the board boot check";
                     end if;
                     if Word (At_Entry) = 1 and then Memory_Size > 0
                       and then
                         (not (for some Region in 1 .. Profile.Count =>
                            Firmware.RAM_Region (Profile, Region)
                            and then Within
                              (First, Memory_Size, Profile.Regions (Region)))
                          or else (File_Size > 0 and then Physical /= First))
                     then
                        return "clause 4, the RAM layout: every loaded"
                          & " segment must stay in SRAM with load address"
                          & " equal to runtime address; use"
                          & " --firmware-layout=boot for the board boot check";
                     end if;
                  end;
               end loop;
            end;
            declare
               Sections : constant Natural := Natural (Word (32));
               Section_Size : constant Natural := Natural (Number (46, 2));
               Programs : constant Natural := Natural (Word (28));
               Program_Size : constant Natural := Natural (Number (42, 2));
            begin
               if Section_Size < 40 or else Program_Size /= 32 then
                  return "the linked image is not a well-formed ELF"
                    & " executable";
               end if;
               for Index in 0 .. Natural (Number (48, 2)) - 1 loop
                  declare
                     Header : constant Natural :=
                       Sections + Index * Section_Size;
                     First : constant Landin.Targets.Byte_Count :=
                       Word (Header + 12);
                     Size : constant Landin.Targets.Byte_Count :=
                       Word (Header + 20);
                     Offset : constant Landin.Targets.Byte_Count :=
                       Word (Header + 16);
                     Covered : Boolean := False;
                  begin
                     --  SHF_ALLOC, including SHT_NOBITS excluded from the
                     --  program headers by a developer's :NONE placement.
                     --  Nonallocated symbol/debug tables are ELF metadata.
                     if (Word (Header + 8) / 2) mod 2 = 1 and then Size > 0
                     then
                        declare
                           Fault : constant String := RAM_Range_Fault
                             (First, Size, "an allocated RAM section");
                        begin
                           if Fault /= "" then
                              return Fault;
                           end if;
                        end;
                        if Word (Header + 4) /= 8 then
                           for Part in 0 .. Natural (Number (44, 2)) - 1 loop
                              declare
                                 Program : constant Natural :=
                                   Programs + Part * Program_Size;
                                 Address : constant
                                   Landin.Targets.Byte_Count :=
                                     Word (Program + 8);
                                 File_At : constant
                                   Landin.Targets.Byte_Count :=
                                     Word (Program + 4);
                                 File_Size : constant
                                   Landin.Targets.Byte_Count :=
                                     Word (Program + 16);
                              begin
                                 Covered := Covered or else
                                   (Word (Program) = 1
                                    and then File_Size <=
                                      Word (Program + 20)
                                    and then First >= Address
                                    and then First + Size <=
                                      Address + File_Size
                                    and then Offset =
                                      File_At + First - Address
                                    and then Offset + Size <=
                                      Landin.Targets.Byte_Count (Data'Length));
                              end;
                           end loop;
                           if not Covered then
                              return "clause 4, the RAM layout: an allocated"
                                & " file-backed section has no matching load"
                                & " segment";
                           end if;
                        end if;
                     end if;
                  end;
               end loop;
            end;
            --  Startup follows symbols, which a script can rebind without
            --  moving the section itself. Check every span it will clear.
            declare
               Fault : constant String := BSS_Fault ("_landin_firmware");
            begin
               if Fault /= "" then
                  return Fault;
               end if;
            end;
            for Index in 1 .. Profile.Count loop
               if Used (Index)
                 and then Firmware.Writable (Profile.Regions (Index).Mode)
               then
                  declare
                     Fault : constant String := BSS_Fault
                       ("_landin_firmware_region_"
                        & Firmware.Spelling (Profile.Regions (Index).Name));
                  begin
                     if Fault /= "" then
                        return Fault;
                     end if;
                  end;
               end if;
            end loop;
         end if;

         --  Clause 4: each initialized image loads from flash.
         declare
            Fault : constant String := Image_Fault
              (".data", "_landin_firmware_data_load",
               "_landin_firmware_data_start", "_landin_firmware_data_end");
         begin
            if Fault /= "" then
               return Fault;
            end if;
         end;
         declare
            Fault : constant String := Image_Fault
              (".ramtext", "_landin_firmware_ramtext_load",
               "_landin_firmware_ramtext_start",
               "_landin_firmware_ramtext_end");
         begin
            if Fault /= "" then
               return Fault;
            end if;
         end;
         for Index in 1 .. Profile.Count loop
            if Used (Index)
              and then Firmware.Writable (Profile.Regions (Index).Mode)
            then
               declare
                  Stem : constant String := "_landin_firmware_region_"
                    & Firmware.Spelling (Profile.Regions (Index).Name);
                  Fault : constant String := Image_Fault
                    (Firmware.Spelling (Profile.Regions (Index).Name),
                     Stem & "_data_load", Stem & "_data_start",
                     Stem & "_data_end");
               begin
                  if Fault /= "" then
                     return Fault;
                  end if;
               end;
            end if;
         end loop;
         return "";
      end;
   exception
      when Constraint_Error =>
         return "the linked image is not a well-formed ELF executable";
   end Contract_Fault;

end Landin.Build_Reports.Firmware;
