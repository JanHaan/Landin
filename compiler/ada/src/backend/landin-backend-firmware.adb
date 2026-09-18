with Ada.Strings.Fixed;
with Landin.Targets.Firmware;

package body Landin.Backend.Firmware is
   use type Landin.Targets.Byte_Count;
   use type Landin.IR.Item_Kind;
   use type Landin.Types.Type_Kind;

   function Materialization_Fits (Of_Unit : Landin.IR.Unit) return Boolean is
      Budget : Landin.Targets.Byte_Count := 8 * 1024 * 1024;
   begin
      for Index in 1 .. Landin.IR.Item_Count (Of_Unit) loop
         declare
            Item : constant Landin.IR.Item_Id := Landin.IR.Item_Id (Index);
            Bytes : Landin.Targets.Byte_Count;
            Alignment : Landin.Targets.Byte_Alignment;
         begin
            if Landin.IR.Kind_Of (Of_Unit, Item) = Landin.IR.Datum then
               if Landin.IR.Result_Of (Of_Unit, Item) = Landin.Types.Aggregate
               then
                  Bytes := Datum_Layout
                    (Of_Unit, Item, Landin.Targets.Cortex_M).Size;
               elsif Landin.IR.Result_Of (Of_Unit, Item)
                 = Landin.Types.Fixed_Array
               then
                  Field_Extent
                    (Of_Unit, Landin.IR.Whole_Array_Shape (Of_Unit, Item),
                     Landin.Targets.Cortex_M, Bytes, Alignment);
               else
                  Bytes := Landin.Targets.Byte_Count
                    (Landin.Targets.Bytes (Landin.Types.Storage_Size
                      (Landin.IR.Result_Of (Of_Unit, Item),
                       Landin.Targets.Cortex_M)));
               end if;
               if Bytes > Budget then
                  return False;
               end if;
               Budget := Budget - Bytes;
            end if;
         end;
      end loop;
      return True;
   end Materialization_Fits;

   LF : constant Character := Character'Val (10);

   function Number (Value : Landin.Targets.Byte_Count) return String is
     (Ada.Strings.Fixed.Trim (Value'Image, Ada.Strings.Both));

   function Startup
     (Entry_Symbol : String; Returned : String := "udf #1") return String is
     (".section .text.landin_firmware_reset,""ax"",%progbits" & LF
      & ".balign 2" & LF
      & ".globl _landin_firmware_reset" & LF
      & ".type _landin_firmware_reset,%function" & LF
      & ".thumb_func" & LF
      & "_landin_firmware_reset:" & LF
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
      & "dsb sy" & LF
      & "isb sy" & LF
      & "cpsie i" & LF
      & "bl " & Entry_Symbol & "" & LF
      & ".globl _landin_firmware_returned" & LF
      & "_landin_firmware_returned:" & LF
      & Returned & LF
      & "b _landin_firmware_returned" & LF
      & ".ltorg" & LF
      & ".size _landin_firmware_reset, .-_landin_firmware_reset" & LF
      & ".section .text.landin_firmware_unhandled,""ax"",%progbits" & LF
      & ".balign 2" & LF
      & ".globl _landin_firmware_unhandled" & LF
      & ".type _landin_firmware_unhandled,%function" & LF
      & ".thumb_func" & LF
      & "_landin_firmware_unhandled:" & LF
      & "cpsid i" & LF
      & "5:" & LF
      & "wfi" & LF
      & "b 5b" & LF
      & ".size _landin_firmware_unhandled, .-_landin_firmware_unhandled" & LF);

   function Linker_Script return String is
     ("OUTPUT_FORMAT(""elf32-littlearm"")" & LF
      & "OUTPUT_ARCH(arm)" & LF
      & "ENTRY(_landin_firmware_reset)" & LF
      & "MEMORY {" & LF
      & "  FLASH (rx) : ORIGIN = "
        & Number (Landin.Targets.Firmware.Flash_Base)
        & ", LENGTH = "
        & Number (Landin.Targets.Firmware.Flash_Size)
        & "" & LF
      & "  RAM (rwx) : ORIGIN = "
        & Number (Landin.Targets.Firmware.RAM_Base)
        & ", LENGTH = "
        & Number (Landin.Targets.Firmware.RAM_Size)
        & "" & LF
      & "}" & LF
      & "_landin_firmware_stack_top = ORIGIN(RAM) + LENGTH(RAM);" & LF
      & "_landin_firmware_stack_bottom = _landin_firmware_stack_top - "
        & Number (Landin.Targets.Firmware.Stack_Size)
        & ";" & LF
      & "SECTIONS {" & LF
      & "  .isr_vector ORIGIN(FLASH) : { KEEP(*(.isr_vector)) } > FLASH" & LF
      & "  .text : { *(.text .text.*) } > FLASH" & LF
      & "  .rodata : { *(.rodata .rodata.*) } > FLASH" & LF
      & "  .ARM.extab : { *(.ARM.extab*) } > FLASH" & LF
      & "  .ARM.exidx : { *(.ARM.exidx*) } > FLASH" & LF
      & "  .data : ALIGN(8) {" & LF
      & "    _landin_firmware_data_start = .;" & LF
      & "    *(.data .data.*)" & LF
      & "    _landin_firmware_data_end = .;" & LF
      & "  } > RAM AT> FLASH" & LF
      & "  _landin_firmware_data_load = LOADADDR(.data);" & LF
      & "  .ramtext : ALIGN(8) {" & LF
      & "    _landin_firmware_ramtext_start = .;" & LF
      & "    *(.ramtext.*)" & LF
      & "    _landin_firmware_ramtext_end = .;" & LF
      & "  } > RAM AT> FLASH" & LF
      & "  _landin_firmware_ramtext_load = LOADADDR(.ramtext);" & LF
      & "  .bss (NOLOAD) : ALIGN(8) {" & LF
      & "    _landin_firmware_bss_start = .;" & LF
      & "    *(.bss .bss.* COMMON)" & LF
      & "    _landin_firmware_bss_end = .;" & LF
      & "  } > RAM" & LF
      & "  /DISCARD/ : { *(.comment .note.GNU-stack) }" & LF
      & "}" & LF
      & "ASSERT(ADDR(.isr_vector) == 0, ""vectors must start at zero"")" & LF
      & "ASSERT(SIZEOF(.isr_vector) == 192, ""vectors must contai"
        & "n 48 words"")" & LF
      & "ASSERT((_landin_firmware_stack_top & 7) == 0, ""unaligne"
        & "d initial stack"")" & LF
      & "ASSERT(_landin_firmware_bss_end <= _landin_firmware_sta"
        & "ck_bottom," & LF
      & "       ""RAM image overlaps the reserved 4 KiB stack"")" & LF
      & "ASSERT(LOADADDR(.ramtext) + SIZEOF(.ramtext) <= "
        & "ORIGIN(FLASH) + LENGTH(FLASH)," & LF
      & "       ""initialized image exceeds flash"")" & LF);
end Landin.Backend.Firmware;
