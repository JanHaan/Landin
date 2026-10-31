with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

package body Landin.Backend.Firmware is
   package Profiles renames Landin.Targets.Firmware;
   package US renames Ada.Strings.Unbounded;
   use type Landin.Targets.Byte_Count;

   LF : constant Character := Character'Val (10);

   function Number (Value : Landin.Targets.Byte_Count) return String is
     (Ada.Strings.Fixed.Trim (Value'Image, Ada.Strings.Both));

   function Used_Regions
     (Of_Unit : Landin.IR.Unit; Names : Landin.Source.Names.Table)
      return Region_Use
   is
      use type Landin.Source.Names.Name_Id;
      Profile : constant Profiles.Profile :=
        Landin.IR.Firmware_Profile (Of_Unit);
      Result : Region_Use := [others => False];
   begin
      for Index in 1 .. Landin.IR.Item_Count (Of_Unit) loop
         declare
            Region : constant Landin.Source.Names.Name_Id :=
              Landin.IR.Placement_Of
                (Of_Unit, Landin.IR.Item_Id (Index)).Region;
            Which : Profiles.Region_Count;
         begin
            if Region /= Landin.Source.Names.No_Name then
               Which := Profiles.Region_Named
                 (Profile, Landin.Source.Names.Spelling (Names, Region));
               if Which /= 0 then
                  Result (Which) := True;
               end if;
            end if;
         end;
      end loop;
      return Result;
   end Used_Regions;

   --  The symbols and output sections of a region a placement uses.
   function Region_Symbol (Name, Part : String) return String is
     ("_landin_firmware_region_" & Name & "_" & Part);

   function Startup
     (Entry_Symbol : String;
      Profile : Landin.Targets.Firmware.Profile;
      Used : Region_Use;
      Returned : String := "udf #1";
      Debug : Boolean := False) return String
   is
      use type Profiles.Boot_Kind;
      Regions : US.Unbounded_String;
   begin
      --  D547: a writable region a placement uses is loaded and cleared
      --  as .data and .bss are, after them.
      for Index in 1 .. Profile.Count loop
         if Used (Index)
           and then Profiles.Writable (Profile.Regions (Index).Mode)
         then
            declare
               Name : constant String :=
                 Profiles.Spelling (Profile.Regions (Index).Name);
            begin
               US.Append (Regions,
                 "ldr r0, =" & Region_Symbol (Name, "data_load") & LF
                 & "ldr r1, =" & Region_Symbol (Name, "data_start") & LF
                 & "ldr r2, =" & Region_Symbol (Name, "data_end") & LF
                 & "8:" & LF
                 & "cmp r1, r2" & LF
                 & "bcs 9f" & LF
                 & "ldrb r3, [r0]" & LF
                 & "strb r3, [r1]" & LF
                 & "adds r0, #1" & LF
                 & "adds r1, #1" & LF
                 & "b 8b" & LF
                 & "9:" & LF
                 & "ldr r1, =" & Region_Symbol (Name, "bss_start") & LF
                 & "ldr r2, =" & Region_Symbol (Name, "bss_end") & LF
                 & "movs r3, #0" & LF
                 & "8:" & LF
                 & "cmp r1, r2" & LF
                 & "bcs 9f" & LF
                 & "strb r3, [r1]" & LF
                 & "adds r1, #1" & LF
                 & "b 8b" & LF
                 & "9:" & LF);
            end;
         end if;
      end loop;
      return
        --  D545: RP2040's boot ROM reads a 256-byte second stage at the
        --  start of flash.  Its code is not this compiler's yet, so the
        --  slot holds zeros, which fail the ROM's CRC: the ROM then does
        --  not enter the image and stays in its USB boot mode.
        (if Profile.Boot = Profiles.RP2040_Boot2
         then ".section .boot2,""a"",%progbits" & LF
           & ".globl _landin_firmware_boot2" & LF
           & "_landin_firmware_boot2:" & LF
           & ".zero 256" & LF
         else "")
        & ".section .text.landin_firmware_reset,""ax"",%progbits" & LF
        & ".balign 2" & LF
        & ".globl _landin_firmware_reset" & LF
        & ".type _landin_firmware_reset,%function" & LF
        & ".thumb_func" & LF
        & "_landin_firmware_reset:" & LF
        & (if Debug then ".cfi_startproc simple" & LF
           & ".cfi_def_cfa sp, 0" & LF & ".cfi_undefined lr" & LF else "")
        & "cpsid i" & LF
        & "movs r0, #0" & LF
        & "mov r9, r0" & LF
        & "mov r11, r0" & LF
        & "ldr r0, =_landin_firmware_data_load" & LF
        & "ldr r1, =_landin_firmware_data_start" & LF
        & "ldr r2, =_landin_firmware_data_end" & LF
        & "1:" & LF
        & "cmp r1, r2" & LF
        & "bcs 2f" & LF
        & "ldrb r3, [r0]" & LF
        & "strb r3, [r1]" & LF
        & "adds r0, #1" & LF
        & "adds r1, #1" & LF
        & "b 1b" & LF
        & "2:" & LF
        & "ldr r0, =_landin_firmware_ramtext_load" & LF
        & "ldr r1, =_landin_firmware_ramtext_start" & LF
        & "ldr r2, =_landin_firmware_ramtext_end" & LF
        & "6:" & LF
        & "cmp r1, r2" & LF
        & "bcs 7f" & LF
        & "ldrb r3, [r0]" & LF
        & "strb r3, [r1]" & LF
        & "adds r0, #1" & LF
        & "adds r1, #1" & LF
        & "b 6b" & LF
        & "7:" & LF
        & "ldr r1, =_landin_firmware_bss_start" & LF
        & "ldr r2, =_landin_firmware_bss_end" & LF
        & "movs r3, #0" & LF
        & "3:" & LF
        & "cmp r1, r2" & LF
        & "bcs 4f" & LF
        & "strb r3, [r1]" & LF
        & "adds r1, #1" & LF
        & "b 3b" & LF
        & "4:" & LF
        & US.To_String (Regions)
        & "dsb sy" & LF
        & "isb sy" & LF
        & "cpsie i" & LF
        & "bl " & Entry_Symbol & "" & LF
        & ".globl _landin_firmware_returned" & LF
        & ".thumb_func" & LF
        & "_landin_firmware_returned:" & LF
        & Returned & LF
        & "b _landin_firmware_returned" & LF
        & ".ltorg" & LF
        & (if Debug then ".cfi_endproc" & LF else "")
        & ".size _landin_firmware_reset, .-_landin_firmware_reset" & LF
        & ".section .text.landin_firmware_unhandled,""ax"",%progbits" & LF
        & ".balign 2" & LF
        & ".globl _landin_firmware_unhandled" & LF
        & ".type _landin_firmware_unhandled,%function" & LF
        & ".thumb_func" & LF
        & "_landin_firmware_unhandled:" & LF
        & (if Debug then ".cfi_startproc simple" & LF
           & ".cfi_def_cfa sp, 0" & LF & ".cfi_undefined lr" & LF else "")
        & "cpsid i" & LF
        & "5:" & LF
        & "wfi" & LF
        & "b 5b" & LF
        & (if Debug then ".cfi_endproc" & LF else "")
        & ".size _landin_firmware_unhandled, .-_landin_firmware_unhandled"
        & LF;
   end Startup;

   function Hex (Value : Landin.Targets.Byte_Count) return String is
      Digits_Of : constant String := "0123456789abcdef";
      Result : String (1 .. 16);
      First : Positive := Result'Last + 1;
      Rest : Landin.Targets.Byte_Count := Value;
   begin
      loop
         First := First - 1;
         Result (First) := Digits_Of (Natural (Rest mod 16) + 1);
         Rest := Rest / 16;
         exit when Rest = 0;
      end loop;
      return "0x" & Result (First .. Result'Last);
   end Hex;

   function Size_Words (Bytes : Landin.Targets.Byte_Count) return String is
     (if Bytes mod 1024 = 0 then Number (Bytes / 1024) & " KiB"
      else Number (Bytes) & " bytes");

   function Linker_Script
     (Profile : Landin.Targets.Firmware.Profile; Used : Region_Use)
      return String
   is
      use type Profiles.Boot_Kind;
      function Placed (Section : Profiles.Section_Kind) return String is
        (Profiles.Spelling
           (Profiles.Placed_Region (Profile, Section).Name));
      Flash : constant String := Placed (Profiles.Text);
      Data : constant String := Placed (Profiles.Data);
      Stack_At : constant Profiles.Region_Count :=
        Profile.Placed (Profiles.Stack);
      Stack : constant String := Placed (Profiles.Stack);
      Vectors : constant String := Placed (Profiles.Vectors);
      Prefix : constant Landin.Targets.Byte_Count :=
        Profiles.Boot_Prefix (Profile.Boot);
      Memory, Sections : US.Unbounded_String;
      --  The end of the last output section in the stack's region, which
      --  must stay below the stack, and the last load image in flash.
      In_Stack_Region : US.Unbounded_String;
      Last_Load : US.Unbounded_String :=
        US.To_Unbounded_String (".ramtext");
   begin
      for Index in 1 .. Profile.Count loop
         US.Append (Memory, "  "
           & Profiles.Spelling (Profile.Regions (Index).Name) & " ("
           & Profiles.Spelling (Profile.Regions (Index).Mode)
           & ") : ORIGIN = " & Number (Profile.Regions (Index).Origin)
           & ", LENGTH = " & Number (Profile.Regions (Index).Length) & LF);
      end loop;
      if Profile.Placed (Profiles.Data) = Stack_At then
         In_Stack_Region := US.To_Unbounded_String
           ("_landin_firmware_ramtext_end");
      end if;
      if Profile.Placed (Profiles.BSS) = Stack_At then
         In_Stack_Region := US.To_Unbounded_String
           ("_landin_firmware_bss_end");
      end if;
      for Index in 1 .. Profile.Count loop
         if Used (Index) then
            declare
               Name : constant String :=
                 Profiles.Spelling (Profile.Regions (Index).Name);
               Section : constant String := ".landin_region_" & Name;
            begin
               if Profiles.Writable (Profile.Regions (Index).Mode) then
                  US.Append (Sections,
                    "  " & Section & "_data : ALIGN(8) {" & LF
                    & "    " & Region_Symbol (Name, "data_start")
                    & " = .;" & LF
                    & "    *(.landin_region." & Name & ".data.*)" & LF
                    & "    " & Region_Symbol (Name, "data_end")
                    & " = .;" & LF
                    & "  } > " & Name & " AT> " & Flash & LF
                    & "  " & Region_Symbol (Name, "data_load")
                    & " = LOADADDR(" & Section & "_data);" & LF
                    & "  " & Section & "_bss (NOLOAD) : AT(ADDR(" & Section
                    & "_bss)) ALIGN(8) {" & LF
                    & "    " & Region_Symbol (Name, "bss_start")
                    & " = .;" & LF
                    & "    *(.landin_region." & Name & ".bss.*)" & LF
                    & "    " & Region_Symbol (Name, "bss_end")
                    & " = .;" & LF
                    & "  } > " & Name & LF);
                  Last_Load := US.To_Unbounded_String (Section & "_data");
                  if Index = Stack_At then
                     In_Stack_Region := US.To_Unbounded_String
                       (Region_Symbol (Name, "bss_end"));
                  end if;
               else
                  US.Append (Sections,
                    "  " & Section & " : {" & LF
                    & "    *(.landin_region." & Name & ".text.*"
                    & " .landin_region." & Name & ".rodata.*)" & LF
                    & "  } > " & Name & LF);
               end if;
            end;
         end if;
      end loop;
      return "OUTPUT_FORMAT(""elf32-littlearm"")" & LF
        & "OUTPUT_ARCH(arm)" & LF
        & "ENTRY(_landin_firmware_reset)" & LF
        & "MEMORY {" & LF
        & US.To_String (Memory)
        & "}" & LF
        & "_landin_firmware_stack_top = ORIGIN(" & Stack & ") + LENGTH("
        & Stack & ");" & LF
        & "_landin_firmware_stack_bottom = _landin_firmware_stack_top - "
        & Number (Profile.Stack_Size)
        & ";" & LF
        & "SECTIONS {" & LF
        & (if Profile.Boot = Profiles.RP2040_Boot2
           then "  .boot2 ORIGIN(" & Vectors & ") : { KEEP(*(.boot2)) } > "
             & Vectors & LF
           else "")
        & "  .isr_vector ORIGIN(" & Vectors & ")"
        & (if Prefix = 0 then "" else " + " & Number (Prefix))
        & " : { KEEP(*(.isr_vector)) } > " & Vectors & LF
        & "  .text : { *(.text .text.*) } > " & Flash & LF
        & "  .rodata : { *(.rodata .rodata.*) } > "
        & Placed (Profiles.Rodata) & LF
        & "  .ARM.extab : { *(.ARM.extab*) } > " & Flash & LF
        & "  .ARM.exidx : { *(.ARM.exidx*) } > " & Flash & LF
        & "  .data : ALIGN(8) {" & LF
        & "    _landin_firmware_data_start = .;" & LF
        & "    *(.data .data.*)" & LF
        & "    _landin_firmware_data_end = .;" & LF
        & "  } > " & Data & " AT> " & Flash & LF
        & "  _landin_firmware_data_load = LOADADDR(.data);" & LF
        & "  .ramtext : ALIGN(8) {" & LF
        & "    _landin_firmware_ramtext_start = .;" & LF
        & "    *(.ramtext.*)" & LF
        & "    _landin_firmware_ramtext_end = .;" & LF
        & "  } > " & Data & " AT> " & Flash & LF
        & "  _landin_firmware_ramtext_load = LOADADDR(.ramtext);" & LF
        & "  .bss (NOLOAD) : AT(ADDR(.bss)) ALIGN(8) {" & LF
        & "    _landin_firmware_bss_start = .;" & LF
        & "    *(.bss .bss.* COMMON)" & LF
        & "    _landin_firmware_bss_end = .;" & LF
        & "  } > " & Placed (Profiles.BSS) & LF
        & US.To_String (Sections)
        & "  /DISCARD/ : { *(.comment .note.GNU-stack) }" & LF
        & "}" & LF
        & (if Profile.Boot = Profiles.RP2040_Boot2
           then "ASSERT(SIZEOF(.boot2) == 256, ""the second stage must be"
             & " 256 bytes"")" & LF
           else "")
        & "ASSERT(ADDR(.isr_vector) == "
        & Number (Profiles.Vector_Address (Profile))
        & ", ""vectors must start at "
        & (if Profiles.Vector_Address (Profile) = 0 then "zero"
           else Hex (Profiles.Vector_Address (Profile))) & """)" & LF
        & "ASSERT(SIZEOF(.isr_vector) == "
        & Number (Profiles.Vector_Bytes (Profile))
        & ", ""vectors must contain "
        & Number (Landin.Targets.Byte_Count (Profile.Vector_Count))
        & " words"")" & LF
        & "ASSERT((_landin_firmware_stack_top & 7) == 0, ""unaligne"
        & "d initial stack"")" & LF
        & (if US.Length (In_Stack_Region) = 0 then ""
           else "ASSERT(" & US.To_String (In_Stack_Region)
             & " <= _landin_firmware_sta"
             & "ck_bottom," & LF
             & "       """ & Stack & " image overlaps the reserved "
             & Size_Words (Profile.Stack_Size) & " stack"")" & LF)
        & "ASSERT(LOADADDR(" & US.To_String (Last_Load) & ") + SIZEOF("
        & US.To_String (Last_Load) & ") <= "
        & "ORIGIN(" & Flash & ") + LENGTH(" & Flash & ")," & LF
        & "       ""initialized image exceeds flash"")" & LF;
   end Linker_Script;
end Landin.Backend.Firmware;
