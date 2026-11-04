with Ada.Containers.Vectors;
with Ada.Strings.Fixed;
with GNAT.SHA256;
with Landin.Backend.Firmware;

package body Landin.Driver.ESP_Image is
   package US renames Ada.Strings.Unbounded;
   package Firmware renames Landin.Targets.Firmware;
   use type Landin.Targets.Byte_Count;

   subtype Address is Landin.Targets.Byte_Count;
   --  The checksum: the exclusive or of bytes.
   type Octet is mod 256;

   --  A loaded segment with bytes in the file: its load address and where
   --  its bytes are in the executable, 1-based.
   type Segment is record
      Load : Address;
      First : Positive;
      Size : Natural;
   end record;
   package Segment_Vectors is new Ada.Containers.Vectors
     (Positive, Segment);

   type Loaded is record
      Segments : Segment_Vectors.Vector;
      Entry_At : Address := 0;
      Fault : US.Unbounded_String;
   end record;

   function Image (Value : Address) return String is
     (Ada.Strings.Fixed.Trim (Value'Image, Ada.Strings.Both));

   function Padded (Size : Natural) return Natural is
     ((Size + 3) / 4 * 4);

   --  The little-endian number of WIDTH bytes at 0-based offset POSITION
   --  of DATA.
   function Number
     (Data : String; Position : Natural; Width : Positive) return Address;
   function Number
     (Data : String; Position : Natural; Width : Positive) return Address
   is
      Value : Address := 0;
   begin
      if Position > Data'Length or else Width > Data'Length - Position then
         raise Constraint_Error;
      end if;
      for Offset in reverse 0 .. Width - 1 loop
         Value := Value * 256
           + Character'Pos (Data (Data'First + Position + Offset));
      end loop;
      return Value;
   end Number;

   function Bytes_Of (Value : Address; Width : Positive) return String;
   function Bytes_Of (Value : Address; Width : Positive) return String is
      Result : String (1 .. Width);
      Rest : Address := Value;
   begin
      for Index in Result'Range loop
         Result (Index) := Character'Val (Natural (Rest mod 256));
         Rest := Rest / 256;
      end loop;
      return Result;
   end Bytes_Of;

   --  The SHA-256 of TEXT as its 32 bytes, and as hexadecimal.
   function Hash (Text : String) return String is
     (String (GNAT.SHA256.Message_Digest'(GNAT.SHA256.Digest (Text))));
   function Hash_Bytes (Text : String) return String;
   function Hash_Bytes (Text : String) return String is
      Hex : constant String := Hash (Text);
      Result : String (1 .. 32);
      function Digit (C : Character) return Natural is
        (if C in '0' .. '9' then Character'Pos (C) - Character'Pos ('0')
         else Character'Pos (C) - Character'Pos ('a') + 10);
   begin
      for Index in Result'Range loop
         Result (Index) := Character'Val
           (16 * Digit (Hex (Hex'First + 2 * (Index - 1)))
            + Digit (Hex (Hex'First + 2 * (Index - 1) + 1)));
      end loop;
      return Result;
   end Hash_Bytes;

   --  The extended header the ROM checks before it loads anything: no
   --  write-protect pin, default drive strengths, the chip, the legacy
   --  minimum revision as zero, the full revisions, four reserved bytes
   --  and the flag that says a SHA-256 follows the checksum.
   function Extended (Profile : Firmware.Profile) return String is
     (Character'Val (Firmware.ESP_No_WP_Pin) & [1 .. 3 => ASCII.NUL]
      & Bytes_Of (Address (Profile.ESP_Chip), 2) & ASCII.NUL
      & Bytes_Of (Address (Profile.ESP_Minimum), 2)
      & Bytes_Of (Address (Profile.ESP_Maximum), 2)
      & [1 .. 4 => ASCII.NUL] & Character'Val (1));

   function Load
     (Data : String; Profile : Firmware.Profile) return Loaded;
   function Load
     (Data : String; Profile : Firmware.Profile) return Loaded
   is
      Result : Loaded;

      function Word (Position : Natural) return Address is
        (Number (Data, Position, 4));
      function Half (Position : Natural) return Address is
        (Number (Data, Position, 2));

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

      function In_Region (First : Address; Size : Natural) return Boolean is
        (for some Index in 1 .. Profile.Count =>
           First >= Profile.Regions (Index).Origin
           and then First + Address (Size)
             <= Profile.Regions (Index).Origin
                + Profile.Regions (Index).Length);

      Entry_Symbol : Address := 0;
      Has_Entry : Boolean := False;

      --  D685: whether an allocated section with bytes in the file begins,
      --  or ends, at file offset AT, so that a segment holds the image's
      --  sections and nothing before or after them: not the ELF's own
      --  headers, which a script may let the linker map.
      function Section_Edge (At_Offset : Natural; Ending : Boolean)
        return Boolean;
      function Section_Edge (At_Offset : Natural; Ending : Boolean)
        return Boolean
      is
         Sections : constant Natural := Natural (Word (32));
         Size : constant Natural := Natural (Half (46));
      begin
         for Index in 0 .. Natural (Half (48)) - 1 loop
            declare
               Header : constant Natural := Sections + Index * Size;
               Offset : constant Natural := Natural (Word (Header + 16));
               Length : constant Natural := Natural (Word (Header + 20));
            begin
               if (Word (Header + 8) / 2) mod 2 = 1
                 and then Word (Header + 4) /= 8
                 and then Length > 0
                 and then (if Ending then Offset + Length = At_Offset
                           else Offset = At_Offset)
               then
                  return True;
               end if;
            end;
         end loop;
         return False;
      end Section_Edge;
   begin
      if Data'Length < 52
        or else Data (Data'First .. Data'First + 5)
          /= Character'Val (127) & "ELF" & Character'Val (1)
            & Character'Val (1)
        or else Half (16) /= 2
        or else Address (Half (18)) /= Address (Firmware.ELF_Machine (Profile.Core))
        or else Half (42) /= 32
      then
         Result.Fault := US.To_Unbounded_String
           ("the linked image is not a 32-bit little-endian "
            & (if Profile.Core in Firmware.Xtensa_Core then "Xtensa"
               else "RISC-V") & " executable");
         return Result;
      end if;
      Result.Entry_At := Word (24);
      declare
         Headers : constant Natural := Natural (Word (28));
      begin
         for Index in 0 .. Natural (Half (44)) - 1 loop
            declare
               At_Entry : constant Natural := Headers + 32 * Index;
               File_At : constant Natural := Natural (Word (At_Entry + 4));
               Physical : constant Address := Word (At_Entry + 12);
               File_Size : constant Natural := Natural (Word (At_Entry + 16));
            begin
               if Word (At_Entry) = 1 and then File_Size > 0 then
                  if File_At > Data'Length
                    or else File_Size > Data'Length - File_At
                  then
                     raise Constraint_Error;
                  elsif not Section_Edge (File_At, Ending => False)
                    or else not Section_Edge
                      (File_At + File_Size, Ending => True)
                  then
                     Result.Fault := US.To_Unbounded_String
                       ("the segment loaded at "
                        & Landin.Backend.Firmware.Hex (Physical) & ", "
                        & Image (Address (File_Size)) & " bytes, holds"
                        & " bytes no allocated section does, such as the"
                        & " ELF's own headers, and the ROM would write them"
                        & " there");
                     return Result;
                  elsif not In_Region (Physical, File_Size) then
                     Result.Fault := US.To_Unbounded_String
                       ("the segment loaded at "
                        & Landin.Backend.Firmware.Hex (Physical) & ", "
                        & Image (Address (File_Size)) & " bytes, lies in no"
                        & " region of " & Firmware.Spelling (Profile.Device)
                        & ", and the ROM loads every segment where it is"
                        & " linked");
                     return Result;
                  end if;
                  Result.Segments.Append
                    (Segment'(Load => Physical,
                              First => Data'First + File_At,
                              Size => File_Size));
               end if;
            end;
         end loop;
      end;
      if Result.Segments.Is_Empty then
         Result.Fault := US.To_Unbounded_String
           ("the linked image loads nothing");
         return Result;
      elsif Natural (Result.Segments.Length) > Firmware.ESP_Segment_Limit
      then
         Result.Fault := US.To_Unbounded_String
           ("the linked image loads"
            & Natural'Image (Natural (Result.Segments.Length))
            & " segments, and an ESP application image holds at most"
            & Natural'Image (Firmware.ESP_Segment_Limit));
         return Result;
      end if;
      declare
         Sections : constant Natural := Natural (Word (32));
         Size : constant Natural := Natural (Half (46));
         Named : constant String := "_landin_firmware_entry";
      begin
         for Index in 0 .. Natural (Half (48)) - 1 loop
            declare
               Header : constant Natural := Sections + Index * Size;
            begin
               if Word (Header + 4) = 2 then
                  declare
                     Table : constant Natural := Natural (Word (Header + 16));
                     Strings : constant Natural := Natural (Word
                       (Sections + Natural (Word (Header + 24)) * Size
                        + 16));
                  begin
                     for Symbol in 1 .. Natural (Word (Header + 20)) / 16 - 1
                     loop
                        if not Has_Entry
                          and then Text_At
                            (Strings + Natural (Word (Table + Symbol * 16)))
                              = Named
                        then
                           Has_Entry := True;
                           Entry_Symbol := Word (Table + Symbol * 16 + 4);
                        end if;
                     end loop;
                  end;
               end if;
            end;
         end loop;
      end;
      if not Has_Entry or else Entry_Symbol /= Result.Entry_At then
         Result.Fault := US.To_Unbounded_String
           ("the linked image's entry is "
            & Landin.Backend.Firmware.Hex (Result.Entry_At)
            & (if Has_Entry
               then ", not _landin_firmware_entry at "
                 & Landin.Backend.Firmware.Hex (Entry_Symbol)
               else ", and it defines no _landin_firmware_entry")
            & ", where the ROM must enter it");
      end if;
      return Result;
   exception
      when Constraint_Error =>
         Result.Fault := US.To_Unbounded_String
           ("the linked image is not a well-formed ELF executable");
         return Result;
   end Load;

   function Make
     (Executable : String;
      Profile : Landin.Targets.Firmware.Profile) return Made
   is
      Found : constant Loaded := Load (Executable, Profile);
      Result : Made;
      Bytes, Segments : US.Unbounded_String;
      Sum : Octet := Firmware.ESP_Checksum_Seed;
   begin
      if US.Length (Found.Fault) > 0 then
         Result.Fault := Found.Fault;
         return Result;
      end if;
      US.Append (Bytes, Character'Val (Firmware.ESP_Magic)
        & Character'Val (Natural (Found.Segments.Length))
        & Character'Val (Firmware.ESP_Flash_Mode)
        & Character'Val (Firmware.ESP_Flash_Size_Frequency)
        & Bytes_Of (Found.Entry_At, 4)
        & Extended (Profile));
      for Part of Found.Segments loop
         declare
            Content : constant String :=
              Executable (Part.First .. Part.First + Part.Size - 1);
         begin
            US.Append (Bytes, Bytes_Of (Part.Load, 4)
              & Bytes_Of (Address (Padded (Part.Size)), 4)
              & Content
              & [1 .. Padded (Part.Size) - Part.Size => ASCII.NUL]);
            for C of Content loop
               Sum := Sum xor Octet (Character'Pos (C));
            end loop;
            US.Append (Segments,
              (if US.Length (Segments) = 0 then "" else ",")
              & "{""address"":" & Image (Part.Load)
              & ",""bytes"":" & Image (Address (Padded (Part.Size))) & "}");
         end;
      end loop;
      US.Append (Bytes, [1 .. 15 - US.Length (Bytes) mod 16 => ASCII.NUL]
        & Character'Val (Natural (Sum)));
      declare
         Checked : constant String := US.To_String (Bytes);
      begin
         Result.Image := US.To_Unbounded_String
           (Checked & Hash_Bytes (Checked));
         Result.Report := US.To_Unbounded_String
           ("""offset"":" & Image (Profile.ESP_Offset)
            & ",""entry"":" & Image (Found.Entry_At)
            & ",""chip"":" & Image (Address (Profile.ESP_Chip))
            & ",""min_revision"":" & Image (Address (Profile.ESP_Minimum))
            & ",""max_revision"":" & Image (Address (Profile.ESP_Maximum))
            & ",""segments"":[" & US.To_String (Segments) & "]"
            & ",""checksum"":" & Image (Address (Sum))
            & ",""sha256"":""" & Hash (Checked) & """"
            & ",""bytes"":" & Image (Address (US.Length (Result.Image))));
      end;
      return Result;
   end Make;

   function Read_Back_Fault
     (Image, Executable : String;
      Profile : Landin.Targets.Firmware.Profile) return String
   is
      Found : constant Loaded := Load (Executable, Profile);
      Cursor : Natural := 0;
      Sum : Octet := Firmware.ESP_Checksum_Seed;

      function Byte (Position : Natural) return Address is
        (Number (Image, Position, 1));
   begin
      if US.Length (Found.Fault) > 0 then
         return US.To_String (Found.Fault);
      elsif Image'Length < Firmware.ESP_Header_Bytes then
         return "the image is shorter than its header";
      elsif Byte (0) /= Firmware.ESP_Magic then
         return "the image does not begin with the magic byte 0xe9";
      elsif Byte (1) /= Address (Found.Segments.Length) then
         return "the image's header gives" & Address'Image (Byte (1))
           & " segments, and the executable loads"
           & Natural'Image (Natural (Found.Segments.Length));
      elsif Byte (2) /= Firmware.ESP_Flash_Mode
        or else Byte (3) /= Firmware.ESP_Flash_Size_Frequency
      then
         return "the image's flash mode, size or frequency byte is not the"
           & " boot kind's";
      elsif Number (Image, 4, 4) /= Found.Entry_At then
         return "the image's entry is "
           & Landin.Backend.Firmware.Hex (Number (Image, 4, 4))
           & ", not the executable's "
           & Landin.Backend.Firmware.Hex (Found.Entry_At);
      elsif Image (Image'First + 8 .. Image'First + 23) /= Extended (Profile)
      then
         return "the image's extended header does not name chip"
           & Natural'Image (Profile.ESP_Chip) & " and revisions"
           & Natural'Image (Profile.ESP_Minimum) & " to"
           & Natural'Image (Profile.ESP_Maximum) & " with its hash flag";
      end if;
      Cursor := Firmware.ESP_Header_Bytes;
      for Index in 1 .. Natural (Found.Segments.Length) loop
         declare
            Part : constant Segment := Found.Segments (Index);
            Length : constant Address := Number (Image, Cursor + 4, 4);
         begin
            if Number (Image, Cursor, 4) /= Part.Load
              or else Length /= Address (Padded (Part.Size))
            then
               return "the image's segment" & Natural'Image (Index)
                 & " is at "
                 & Landin.Backend.Firmware.Hex (Number (Image, Cursor, 4))
                 & " of" & Address'Image (Length)
                 & " bytes, and the executable loads "
                 & Landin.Backend.Firmware.Hex (Part.Load) & " of"
                 & Natural'Image (Padded (Part.Size));
            end if;
            Cursor := Cursor + 8;
            if Cursor + Natural (Length) > Image'Length then
               return "the image ends inside its segment"
                 & Natural'Image (Index);
            end if;
            for Offset in 0 .. Natural (Length) - 1 loop
               if Offset < Part.Size
                 and then Image (Image'First + Cursor + Offset)
                   /= Executable (Part.First + Offset)
               then
                  return "the image's segment" & Natural'Image (Index)
                    & " differs from the executable's at "
                    & Landin.Backend.Firmware.Hex
                        (Part.Load + Address (Offset));
               elsif Offset >= Part.Size
                 and then Image (Image'First + Cursor + Offset) /= ASCII.NUL
               then
                  return "the image's segment" & Natural'Image (Index)
                    & " is not padded with zeros";
               end if;
               Sum := Sum xor Octet (Byte (Cursor + Offset));
            end loop;
            Cursor := Cursor + Natural (Length);
         end;
      end loop;
      while Cursor mod 16 /= 15 loop
         if Cursor >= Image'Length or else Byte (Cursor) /= 0 then
            return "the image is not padded with zeros to its checksum";
         end if;
         Cursor := Cursor + 1;
      end loop;
      if Cursor >= Image'Length or else Byte (Cursor) /= Address (Sum) then
         return "the image's checksum is not the exclusive or of its"
           & " segments' bytes seeded 0xef";
      elsif Image'Length - (Cursor + 1) /= 32
        or else Image (Image'First + Cursor + 1 .. Image'Last)
          /= Hash_Bytes (Image (Image'First .. Image'First + Cursor))
      then
         return "the image does not end with the SHA-256 of what precedes"
           & " it";
      end if;
      return "";
   exception
      when Constraint_Error =>
         return "the image is not well formed";
   end Read_Back_Fault;

end Landin.Driver.ESP_Image;
