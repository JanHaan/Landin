with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with GNAT.SHA256;
with Landin.Driver;
with Landin.Driver.ESP_Image;
with Landin.Driver.Image_Block;
with Landin.Platform;
with Landin.Targets;
with Landin.Targets.Firmware;
with Landin.Testing.Fakes;

package body Landin.Tests.RV32_Firmware_Suite is
   package U renames Ada.Strings.Unbounded;
   package Firmware renames Landin.Targets.Firmware;

   LF : constant Character := ASCII.LF;

   function Contains (Text, Needle : String) return Boolean
     is (Ada.Strings.Fixed.Index (Text, Needle) > 0);

   --  VALUE's WIDTH bytes, little-endian.
   function Bytes (Value : Long_Long_Integer; Width : Natural) return String;
   function Bytes (Value : Long_Long_Integer; Width : Natural) return String
   is
      Result : String (1 .. Width);
      Rest : Long_Long_Integer := Value;
   begin
      for Index in Result'Range loop
         Result (Index) := Character'Val (Natural (Rest mod 256));
         Rest := Rest / 256;
      end loop;
      return Result;
   end Bytes;

   function Word (Value : Long_Long_Integer) return String is
     (Bytes (Value, 4));

   --  What one request writes from a program that imports DESCRIPTION, a
   --  description's text, or none when it is "": the derived script, the
   --  build report, and the diagnostics.
   type Written is record
      Status : Natural;
      Script, Report, Said : U.Unbounded_String;
   end record;

   function Script_Of
     (Description : String; Level : String := "rv32imac";
      Program : String := "") return Written;
   function Script_Of
     (Description : String; Level : String := "rv32imac";
      Program : String := "") return Written
   is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Args : Landin.Platform.Path_List;
      Result : Written;
   begin
      Host.Add_Firmware_Library;
      Host.Add_Directory ("/w");
      Host.Add_Directory ("/w/app");
      Host.Add_Directory ("/w/devices");
      Host.Add_Directory ("/w/devices/descriptions");
      Host.Add_Directory ("/w/devices/descriptions/dev");
      Host.Add_File ("/w/app/main.ldn",
        (if Description = "" then "" else "import descriptions/dev" & LF)
        & "start: () -> none = end start" & LF & Program);
      if Description /= "" then
         Host.Add_File ("/w/devices/descriptions/dev/dev.ldn", Description);
      end if;
      Tools.Set_Result (0, "");
      Args.Append ("--root=/w/devices");
      Args.Append ("--target=rv32");
      Args.Append ("--level=" & Level);
      Args.Append ("--emit=linker-script");
      Args.Append ("--build-report=/w/q.json");
      Args.Append ("-o");
      Args.Append ("/w/q.ld");
      Args.Append ("/w/app");
      declare
         Ran : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute (Args, Host, Tools);
      begin
         Result.Status := Ran.Status;
         Result.Said := Ran.Report;
         if Host.Exists ("/w/q.ld") then
            Result.Script := U.To_Unbounded_String (Host.Written ("/w/q.ld"));
         end if;
         if Host.Exists ("/w/q.json") then
            Result.Report :=
              U.To_Unbounded_String (Host.Written ("/w/q.json"));
         end if;
      end;
      return Result;
   end Script_Of;

   --  A description of CORE with BOOT and the lines EXTRA, its one region
   --  holding everything, as a chip whose RAM runs code would be.
   function Description
     (Core, Boot : String; Vectors : Positive; Extra : String := "";
      Origin : String := "0x4038_0000") return String
   is ("compiler.device(""dev"")" & LF
       & "compiler.core(""" & Core & """)" & LF
       & "compiler.vectors(" & Ada.Strings.Fixed.Trim
           (Vectors'Image, Ada.Strings.Both) & ")" & LF
       & "compiler.boot(""" & Boot & """)" & LF
       & Extra
       & "linker.region(""SRAM"", " & Origin & ", 256 * 1024, ""rwx"")" & LF
       & "linker.place(""vectors"", ""SRAM"")" & LF
       & "linker.place(""text"", ""SRAM"")" & LF
       & "linker.place(""rodata"", ""SRAM"")" & LF
       & "linker.place(""data"", ""SRAM"")" & LF
       & "linker.place(""bss"", ""SRAM"")" & LF
       & "linker.place(""stack"", ""SRAM"", 16 * 1024)" & LF);

   --  D661, D681-D686: what each kind of RV32 profile derives, and what a
   --  description of the wrong kind is refused for.
   procedure Profiles_Are_Derived (Item : in out Landin.Testing.Context);
   procedure Profiles_Are_Derived (Item : in out Landin.Testing.Context) is
      procedure Holds (Name : String; Got : Written; Parts : String);
      --  Each LF-separated line of PARTS is in Got's script or report.
      procedure Holds (Name : String; Got : Written; Parts : String) is
         First : Positive := Parts'First;
         Both : constant String :=
           U.To_String (Got.Script) & U.To_String (Got.Report);
      begin
         Landin.Testing.Check_Equal
           (Item, Got.Status, Landin.Driver.Status_Success,
            Name & ": " & U.To_String (Got.Said));
         for Index in Parts'Range loop
            if Parts (Index) = LF then
               Landin.Testing.Check
                 (Item, Contains (Both, Parts (First .. Index - 1)),
                  Name & " holds " & Parts (First .. Index - 1) & ": "
                  & Both);
               First := Index + 1;
            end if;
         end loop;
      end Holds;

      procedure Refused (Name : String; Got : Written; Code, Text : String);
      procedure Refused (Name : String; Got : Written; Code, Text : String)
      is
      begin
         Landin.Testing.Check
           (Item, Got.Status /= Landin.Driver.Status_Success
              and then Contains (U.To_String (Got.Said),
                                 "error[" & Code & "]")
              and then Contains (U.To_String (Got.Said), Text)
              and then U.Length (Got.Script) = 0,
            Name & ": " & U.To_String (Got.Said));
      end Refused;

      ESP_Facts : constant String :=
        "compiler.esp_image(5, 3, 199, 0x0)" & LF;
   begin
      --  The reference: the entry word at the flash's origin, its 16-slot
      --  table 64 bytes in, and the psABI's sixteen-byte stack.
      Holds ("the RISC-V reference", Script_Of (""),
        "OUTPUT_FORMAT(""elf32-littleriscv"")" & LF
        & "ENTRY(_landin_firmware_entry)" & LF
        & "  .landin_entry ORIGIN(FLASH) : { KEEP(*(.text.landin_entry)) }"
        & " > FLASH" & LF
        & "  .isr_vector 541065280 : { KEEP(*(.isr_vector)) } > FLASH" & LF
        & "ASSERT(ADDR(.landin_entry) == ORIGIN(FLASH) &&"
        & " SIZEOF(.landin_entry) == 4" & LF
        & "ASSERT(ADDR(.isr_vector) == 541065280, ""vectors must start at"
        & " 0x20400040"")" & LF
        & "ASSERT((_landin_firmware_stack_top & 15) == 0" & LF
        & """device"":""riscv-reference"",""core"":""sifive-e31""" & LF
        & """vector_address"":541065280,""vector_words"":16" & LF);
      Landin.Testing.Check
        (Item, not Contains (U.To_String (Script_Of ("").Script), "ARM"),
         "an RV32 script places no Arm unwind table");
      --  D682: Hazard3's table at the first 512-byte boundary past the
      --  entry word, the block directly after it.
      Holds ("RP2350's Hazard3",
        Script_Of (Description ("hazard3", "rp2350-image-block", 68,
                                Origin => "0x1000_0000")),
        "  .isr_vector 268435968 : { KEEP(*(.isr_vector)) } > SRAM" & LF
        & "  .embedded_block : { KEEP(*(.embedded_block)) } > SRAM" & LF
        & """boot_suffix"":20" & LF
        & """image_block"":{""address"":268436240,""bytes"":20}" & LF);
      --  D683, D685: the C3's table at the next 256-byte boundary, and
      --  the image's chip facts in the report.
      Holds ("an ESP32-C3",
        Script_Of (Description ("esp-rv32imc", "esp-app-image", 32,
                                ESP_Facts), Level => "rv32imc"),
        "  .isr_vector 1077412096 : { KEEP(*(.isr_vector)) } > SRAM" & LF
        & """boot"":""esp-app-image""" & LF
        & """esp_image"":{""offset"":0,""chip"":5,""min_revision"":3,"
        & """max_revision"":199}" & LF);
      Holds ("an ESP32-C5's CLIC table",
        Script_Of (Description ("esp-rv32imac-clic", "esp-app-image", 48,
                                "compiler.esp_image(23, 100, 199, 0x2000)"
                                & LF, Origin => "0x4080_0000")),
        "  .isr_vector 1082130688 : { KEEP(*(.isr_vector)) } > SRAM" & LF
        & """esp_image"":{""offset"":8192,""chip"":23" & LF);

      Refused ("an esp-app-image without its chip",
        Script_Of (Description ("esp-rv32imc", "esp-app-image", 32),
                   Level => "rv32imc"),
        "L0575", "this description says neither");
      Refused ("chip facts without an esp-app-image",
        Script_Of (Description ("sifive-e31", "vector-table", 16,
                                ESP_Facts)),
        "L0575", "compiler.esp_image describes an esp-app-image");
      Refused ("RP2040's second stage on a RISC-V core",
        Script_Of (Description ("hazard3", "rp2040-boot2", 68)),
        "L0576", "boot kind rp2040-boot2 is read by an Arm core's boot ROM");
      Refused ("a chip id past sixteen bits",
        Script_Of (Description ("esp-rv32imc", "esp-app-image", 32,
                                "compiler.esp_image(70000, 3, 199, 0x0)"
                                & LF), Level => "rv32imc"),
        "L0399", "an ESP chip id is 0 to 65535");
      Refused ("a maximum revision below the minimum",
        Script_Of (Description ("esp-rv32imc", "esp-app-image", 32,
                                "compiler.esp_image(5, 199, 3, 0x0)"
                                & LF), Level => "rv32imc"),
        "L0399", "the maximum revision is below the minimum");
      Refused ("an offset off a 4 KiB boundary",
        Script_Of (Description ("esp-rv32imc", "esp-app-image", 32,
                                "compiler.esp_image(5, 3, 199, 0x1800)"
                                & LF), Level => "rv32imc"),
        "L0399", "not a multiple of 4096");
      Refused ("a second compiler.esp_image",
        Script_Of (Description ("esp-rv32imc", "esp-app-image", 32,
                                ESP_Facts & ESP_Facts), Level => "rv32imc"),
        "L0513", "this description says compiler.esp_image twice");
   end Profiles_Are_Derived;

   --  D682: on RV32 the block is read from an EM_RISCV object, and its
   --  image type is RISC-V's.
   procedure Image_Block_On_RV32 (Item : in out Landin.Testing.Context);
   procedure Image_Block_On_RV32 (Item : in out Landin.Testing.Context) is
      function Block (Image_Type : Long_Long_Integer) return String is
        (Word (16#FFFF_DED3#) & Word (Image_Type * 2 ** 16 + 16#0142#)
         & Word (16#0000_01FF#) & Word (0) & Word (16#AB12_3579#));

      --  A relocatable object of MACHINE holding BLOCK in .embedded_block.
      function Object (Machine : Natural; Payload : String) return String;
      function Object (Machine : Natural; Payload : String) return String is
         NUL : constant Character := ASCII.NUL;
         Names : constant String :=
           NUL & ".embedded_block" & NUL & ".shstrtab" & NUL;
         At_Names : constant Natural := 52 + Payload'Length;
         Headers : constant Natural := At_Names + Names'Length
           + (4 - (At_Names + Names'Length) mod 4) mod 4;
         function Section
           (Name_At, Kind_Of, Flags, Offset, Length : Natural) return String
         is (Word (Long_Long_Integer (Name_At))
             & Word (Long_Long_Integer (Kind_Of))
             & Word (Long_Long_Integer (Flags)) & Word (0)
             & Word (Long_Long_Integer (Offset))
             & Word (Long_Long_Integer (Length)) & Word (0) & Word (0)
             & Word (4) & Word (0));
      begin
         return Character'Val (127) & "ELF" & Character'Val (1)
           & Character'Val (1) & Character'Val (1) & Bytes (0, 9)
           & Bytes (1, 2) & Bytes (Long_Long_Integer (Machine), 2)
           & Word (1) & Word (0) & Word (0)
           & Word (Long_Long_Integer (Headers)) & Word (0)
           & Bytes (52, 2) & Bytes (0, 2) & Bytes (0, 2) & Bytes (40, 2)
           & Bytes (3, 2) & Bytes (2, 2)
           & Payload & Names
           & Bytes (0, Headers - At_Names - Names'Length)
           & Bytes (0, 40)
           & Section (1, 1, 2, 52, Payload'Length)
           & Section (17, 3, 0, At_Names, Names'Length);
      end Object;

      function Fault (Object_Bytes : String) return String is
        (U.To_String (Landin.Driver.Image_Block.Fault
           (Object_Bytes, Firmware.Hazard3)));
   begin
      Landin.Testing.Check_Equal
        (Item, Fault (Object (243, Block (16#1101#))), "",
         "Hazard3's block, image type 0x1101, is read from a RISC-V object");
      Landin.Testing.Check
        (Item, Contains (Fault (Object (243, Block (16#1021#))),
           "image type is 0x1021, not 0x1101: an executable for RISC-V"),
         "the Arm image type is refused on RV32");
      Landin.Testing.Check
        (Item, Contains (Fault (Object (40, Block (16#1101#))),
           "not a 32-bit little-endian RISC-V relocatable object"),
         "an Arm object is refused for a RISC-V core");
      Landin.Testing.Check_Equal
        (Item, U.To_String (Landin.Driver.Image_Block.Fault
           (Object (40, Block (16#1021#)))), "",
         "the Arm block is still read from an Arm object");
   end Image_Block_On_RV32;

   --  D683, D685: the image of a linked executable, made and read back.
   procedure ESP_Image_Is_Made (Item : in out Landin.Testing.Context);
   procedure ESP_Image_Is_Made (Item : in out Landin.Testing.Context) is
      NUL : constant Character := ASCII.NUL;
      Origin : constant := 16#4038_0000#;
      First_Bytes : constant String := "ABCDEFG";
      Second_Bytes : constant String := "0123456789abcdef";

      --  A 32-bit RISC-V executable entered at ENTRY_AT, whose symbol
      --  `_landin_firmware_entry` is at SYMBOL_AT, loading First_Bytes at
      --  the origin and Second_Bytes at SECOND, and a BSS segment.
      function Executable
        (Entry_At : Long_Long_Integer := Origin;
         Symbol_At : Long_Long_Integer := Origin;
         Second : Long_Long_Integer := Origin + 16#100#) return String;
      function Executable
        (Entry_At : Long_Long_Integer := Origin;
         Symbol_At : Long_Long_Integer := Origin;
         Second : Long_Long_Integer := Origin + 16#100#) return String
      is
         Strings : constant String := NUL & "_landin_firmware_entry" & NUL;
         Symbols : constant String := Bytes (0, 16)
           & Word (1) & Word (Symbol_At) & Word (4) & Bytes (16#12#, 1)
           & Bytes (0, 1) & Bytes (1, 2);
         Programs : constant Natural := 52;
         At_First : constant Natural := Programs + 3 * 32;
         At_Second : constant Natural := At_First + 8;
         At_Strings : constant Natural := At_Second + Second_Bytes'Length;
         At_Symbols : constant Natural := At_Strings + Strings'Length
           + (4 - Strings'Length mod 4) mod 4;
         Sections : constant Natural := At_Symbols + Symbols'Length;
         function N (Value : Natural) return String is
           (Word (Long_Long_Integer (Value)));
         function Segment
           (Offset : Natural; Address : Long_Long_Integer;
            File_Size, Memory_Size : Natural) return String
         is (Word (1) & N (Offset) & Word (Address) & Word (Address)
             & N (File_Size) & N (Memory_Size) & Word (5) & Word (4));
         function Section
           (Kind_Of, Offset, Length, Link, Size_Of : Natural) return String
         is (Word (0) & N (Kind_Of) & Word (0) & Word (0) & N (Offset)
             & N (Length) & N (Link) & Word (1) & Word (4) & N (Size_Of));
      begin
         return Character'Val (127) & "ELF" & Character'Val (1)
           & Character'Val (1) & Character'Val (1) & Bytes (0, 9)
           & Bytes (2, 2) & Bytes (243, 2) & Word (1) & Word (Entry_At)
           & N (Programs) & N (Sections) & Word (0)
           & Bytes (52, 2) & Bytes (32, 2) & Bytes (3, 2) & Bytes (40, 2)
           & Bytes (3, 2) & Bytes (0, 2)
           & Segment (At_First, Origin, First_Bytes'Length, 8)
           & Segment (At_Second, Second, Second_Bytes'Length, 16)
           & Segment (0, Origin + 16#1000#, 0, 64)
           & First_Bytes & NUL
           & Second_Bytes
           & Strings & Bytes (0, At_Symbols - At_Strings - Strings'Length)
           & Symbols
           & Bytes (0, 40)
           & Section (2, At_Symbols, Symbols'Length, 2, 16)
           & Section (3, At_Strings, Strings'Length, 0, 0);
      end Executable;

      Profile : Firmware.Profile;
      Made : Landin.Driver.ESP_Image.Made;
   begin
      Profile.Present := True;
      Profile.Device := Firmware.To_Name ("dev");
      Profile.Core := Firmware.ESP_RV32IMC;
      Profile.Boot := Firmware.ESP_App_Image;
      Profile.Count := 1;
      Profile.Regions (1) :=
        (Name => Firmware.To_Name ("SRAM"), Origin => Origin,
         Length => Landin.Targets.Byte_Count (64 * 1024),
         Mode => Firmware.Read_Write_Execute);
      Profile.ESP_Chip := 5;
      Profile.ESP_Minimum := 3;
      Profile.ESP_Maximum := 199;
      Made := Landin.Driver.ESP_Image.Make (Executable, Profile);
      Landin.Testing.Check_Equal
        (Item, U.To_String (Made.Fault), "", "the image is made");
      declare
         --  What the ROM reads, written out here from ESP-IDF's
         --  esp_image_header_t, esp_image_segment_header_t and the
         --  checksum and hash that follow the segments.
         Segments : constant String :=
           Word (Origin) & Word (8) & First_Bytes & NUL
           & Word (Origin + 16#100#) & Word (16) & Second_Bytes;
         Head : constant String :=
           Character'Val (16#E9#) & Character'Val (2) & Character'Val (2)
           & Character'Val (16#20#) & Word (Origin)
           & Character'Val (16#EE#) & Bytes (0, 3) & Bytes (5, 2)
           & Bytes (0, 1) & Bytes (3, 2) & Bytes (199, 2) & Bytes (0, 4)
           & Character'Val (1);
         Sum : Natural := 16#EF#;
         Checked : U.Unbounded_String;
         Payload : constant String := First_Bytes & Second_Bytes;
      begin
         for C of Payload loop
            declare
               A : Natural := Sum;
               B : Natural := Character'Pos (C);
               R : Natural := 0;
               Bit : Natural := 1;
            begin
               for Unused in 1 .. 8 loop
                  if (A mod 2) /= (B mod 2) then
                     R := R + Bit;
                  end if;
                  A := A / 2;
                  B := B / 2;
                  Bit := Bit * 2;
               end loop;
               Sum := R;
            end;
         end loop;
         Checked := U.To_Unbounded_String (Head & Segments);
         U.Append (Checked,
           Bytes (0, 15 - U.Length (Checked) mod 16) & Character'Val (Sum));
         declare
            Whole : constant String := U.To_String (Checked);
            Hex : constant String := GNAT.SHA256.Digest (Whole);
            Image : constant String := U.To_String (Made.Image);
            function Digit (C : Character) return Natural is
              (if C in '0' .. '9' then Character'Pos (C) - 48
               else Character'Pos (C) - 87);
            Hash : String (1 .. 32);

            function Broken (At_Byte : Positive; Value : Character)
              return String is
              (Image (Image'First .. At_Byte - 1) & Value
               & Image (At_Byte + 1 .. Image'Last));

            procedure Names (What, Copy, Wanted : String);
            procedure Names (What, Copy, Wanted : String) is
               Fault : constant String :=
                 Landin.Driver.ESP_Image.Read_Back_Fault
                   (Copy, Executable, Profile);
            begin
               Landin.Testing.Check
                 (Item, Contains (Fault, Wanted),
                  What & " is named: " & Fault);
            end Names;
         begin
            for Index in Hash'Range loop
               Hash (Index) := Character'Val
                 (16 * Digit (Hex (2 * Index - 1)) + Digit (Hex (2 * Index)));
            end loop;
            Landin.Testing.Check
              (Item, Image = Whole & Hash,
               "the image is ESP-IDF's format byte for byte");
            Landin.Testing.Check
              (Item, Contains (U.To_String (Made.Report),
                 """segments"":[{""address"":1077411840,""bytes"":8},"
                 & "{""address"":1077412096,""bytes"":16}]")
                 and then Contains (U.To_String (Made.Report),
                   """checksum"":" & Ada.Strings.Fixed.Trim
                     (Sum'Image, Ada.Strings.Both))
                 and then Contains (U.To_String (Made.Report),
                   """sha256"":""" & Hex & """"),
               "the report gives the segments, checksum and hash: "
               & U.To_String (Made.Report));
            Landin.Testing.Check_Equal
              (Item, Landin.Driver.ESP_Image.Read_Back_Fault
                 (Image, Executable, Profile), "",
               "the image reads back");
            Names ("the magic byte", Broken (1, 'X'), "magic byte 0xe9");
            Names ("the segment count", Broken (2, Character'Val (3)),
              "gives 3 segments, and the executable loads 2");
            Names ("the entry", Broken (5, Character'Val (4)),
              "entry is 0x40380004");
            Names ("the chip", Broken (13, Character'Val (6)),
              "does not name chip 5");
            Names ("a segment's address", Broken (25, Character'Val (4)),
              "segment 1 is at 0x40380004");
            Names ("a segment's byte", Broken (33, 'Z'),
              "differs from the executable's at 0x40380000");
            Names ("the checksum",
              Broken (Whole'Length,
                      Character'Val ((Sum + 1) mod 256)),
              "checksum is not the exclusive or");
            Names ("the hash", Broken (Image'Last, 'q'),
              "does not end with the SHA-256");
            Names ("a byte after the hash", Image & NUL,
              "does not end with the SHA-256");
         end;
      end;
      Landin.Testing.Check
        (Item, Contains (U.To_String (Landin.Driver.ESP_Image.Make
           (Executable (Second => Origin + 16#2_0000#), Profile).Fault),
           "the segment loaded at 0x403a0000, 16 bytes, lies in no region"),
         "a segment outside the description is refused");
      Landin.Testing.Check
        (Item, Contains (U.To_String (Landin.Driver.ESP_Image.Make
           (Executable (Entry_At => Origin + 4), Profile).Fault),
           "entry is 0x40380004, not _landin_firmware_entry at 0x40380000"),
         "an entry elsewhere is refused");
   end ESP_Image_Is_Made;

   --  D680: a slot the core's dispatch enters calls its handler, so a
   --  naked routine there is refused; one the hardware enters takes it.
   procedure Dispatched_Naked (Item : in out Landin.Testing.Context);
   procedure Dispatched_Naked (Item : in out Landin.Testing.Context) is
      function Naked_At (Slot : String) return String is
        ("link(vector: " & Slot & ") extern(naked) h: () -> none =" & LF
         & "    assembler.block(""mret"")" & LF & "end h" & LF);
      Handler_At_16 : constant String :=
        "link(vector: 16) extern(interrupt) h: () -> none = end h" & LF;
      Timer : constant String := "compiler.interrupt(""TIMER0"", 0)" & LF;
      Hazard3_Naked : constant Written :=
        Script_Of (Description ("hazard3", "vector-table", 68, Timer,
                                "0x1000_0000"), Program => Naked_At ("16"));
      CLIC_Naked : constant Written :=
        Script_Of (Description ("esp-rv32imac-clic", "esp-app-image", 48,
                                "compiler.esp_image(23, 100, 199, 0x2000)"
                                & LF, "0x4080_0000"),
                   Program => Naked_At ("17"));
      Hazard3_Handler : constant Written :=
        Script_Of (Description ("hazard3", "vector-table", 68, Timer,
                                "0x1000_0000"), Program => Handler_At_16);
      E31_Naked : constant Written :=
        Script_Of (Description ("sifive-e31", "vector-table", 16,
                                Origin => "0x2040_0000"),
                   Program => Naked_At ("7"));
   begin
      Landin.Testing.Check
        (Item, Contains (U.To_String (Hazard3_Naked.Said), "error[L0347]")
           and then Contains (U.To_String (Hazard3_Naked.Said),
             "vector slot 16 of a hazard3 is called from the compiler's"
             & " dispatch, so no naked routine takes it")
           and then Contains (U.To_String (Hazard3_Naked.Said), "meinext"),
         "Hazard3's slot 16 + IRQ refuses a naked routine: "
         & U.To_String (Hazard3_Naked.Said));
      Landin.Testing.Check
        (Item, Contains (U.To_String (CLIC_Naked.Said), "error[L0347]")
           and then Contains (U.To_String (CLIC_Naked.Said),
             "under the CLIC every interrupt enters one common entry"),
         "a CLIC slot refuses a naked routine: "
         & U.To_String (CLIC_Naked.Said));
      Landin.Testing.Check_Equal
        (Item, Hazard3_Handler.Status, Landin.Driver.Status_Success,
         "an interrupt routine takes Hazard3's slot 16: "
         & U.To_String (Hazard3_Handler.Said));
      Landin.Testing.Check_Equal
        (Item, E31_Naked.Status, Landin.Driver.Status_Success,
         "a naked routine takes a slot the E31's hardware enters: "
         & U.To_String (E31_Naked.Said));
   end Dispatched_Naked;

   --  D684: an RV32 description's stage ends in reset, which it names,
   --  and uses no stack, and each refusal says the RISC-V form.
   procedure Stage_Before_Reset (Item : in out Landin.Testing.Context);
   procedure Stage_Before_Reset (Item : in out Landin.Testing.Context) is
      function With_Stage (Text : String) return Written is
        (Script_Of (Description ("esp-rv32imc", "esp-app-image", 32,
                                 "compiler.esp_image(5, 3, 199, 0x0)" & LF)
                    & LF & "link(boot_stage) extern(naked) feed: () -> none ="
                    & LF & "    assembler.block(""" & Text & """)" & LF
                    & "end feed" & LF, Level => "rv32imc"));
      Ends_In_Reset : constant Written := With_Stage
        ("li t0, 1  # the watchdog's key\nj _landin_firmware_reset");
      No_Reset : constant Written := With_Stage ("li t0, 1\nj feed");
      Compressed : constant Written := With_Stage
        ("c.swsp t0, 0(sp)\nj _landin_firmware_reset");
      Named_In_A_Comment : constant Written := With_Stage
        ("li t0, 1  # then j _landin_firmware_reset\nj feed");
   begin
      Landin.Testing.Check_Equal
        (Item, Ends_In_Reset.Status, Landin.Driver.Status_Success,
         "a stage that ends in reset configures: "
         & U.To_String (Ends_In_Reset.Said));
      Landin.Testing.Check
        (Item, Contains (U.To_String (No_Reset.Said), "error[L0560]")
           and then Contains (U.To_String (No_Reset.Said),
             "finish it with j _landin_firmware_reset"),
         "a stage that does not name reset is L0560 in RISC-V's words: "
         & U.To_String (No_Reset.Said));
      Landin.Testing.Check
        (Item, Contains (U.To_String (Compressed.Said), "error[L0561]")
           and then Contains (U.To_String (Compressed.Said),
             "uses the stack, through swsp"),
         "a compressed store through sp is L0561: "
         & U.To_String (Compressed.Said));
      Landin.Testing.Check
        (Item, Contains (U.To_String (Named_In_A_Comment.Said),
                         "error[L0560]"),
         "reset named in a # comment is not named (D597): "
         & U.To_String (Named_In_A_Comment.Said));
   end Stage_Before_Reset;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "rv32 firmware", "a naked handler is refused in a dispatched"
         & " slot", Dispatched_Naked'Access);
      Landin.Testing.Register
        (Into, "rv32 firmware", "a stage runs before reset",
         Stage_Before_Reset'Access);
      Landin.Testing.Register
        (Into, "rv32 firmware", "descriptions select their profiles",
         Profiles_Are_Derived'Access);
      Landin.Testing.Register
        (Into, "rv32 firmware", "an image block is read from an rv32 object",
         Image_Block_On_RV32'Access);
      Landin.Testing.Register
        (Into, "rv32 firmware", "an ESP application image is made and read"
         & " back", ESP_Image_Is_Made'Access);
   end Register;
end Landin.Tests.RV32_Firmware_Suite;
