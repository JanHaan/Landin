with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Landin.Machine;

package body Landin.Backend.Firmware is
   package Profiles renames Landin.Targets.Firmware;
   package US renames Ada.Strings.Unbounded;
   use type Landin.Targets.Byte_Count;
   use type Landin.Targets.Firmware.Float_Unit;
   use type Profiles.Layout_Kind;

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
                 (if Profile.Layout = Profiles.RAM_Layout then "" else
                 "ldr r0, =" & Region_Symbol (Name, "data_load") & LF
                 & "ldr r1, =" & Region_Symbol (Name, "data_start") & LF
                 & "ldr r2, =" & Region_Symbol (Name, "data_end") & LF
                 & "cmp r0, r1" & LF
                 & "beq 9f" & LF
                 & "8:" & LF
                 & "cmp r1, r2" & LF
                 & "bcs 9f" & LF
                 & "ldrb r3, [r0]" & LF
                 & "strb r3, [r1]" & LF
                 & "adds r0, #1" & LF
                 & "adds r1, #1" & LF
                 & "b 8b" & LF
                 & "9:" & LF)
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
      --  D588: an rp2040-boot2 image's 256-byte slot is the
      --  description's second stage, which the backend emits as that
      --  routine and the driver checksums once it is assembled.  D637: an
      --  rp2350-image-block image's block follows the table, which the
      --  backend emits with it.
      return
        ".section .text.landin_firmware_reset,""ax"",%progbits" & LF
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
        --  D618: CP10 and CP11 full access, before anything can execute
        --  a float instruction, which faults NOCP until then.  Lazy
        --  stacking keeps its reset default.
        & (if Profile.Float = Profiles.No_Float_Unit then ""
           else "ldr r0, =0xe000ed88" & LF
             & "ldr r1, [r0]" & LF
             & "movs r2, #15" & LF
             & "lsls r2, r2, #20" & LF
             & "orrs r1, r2" & LF
             & "str r1, [r0]" & LF
             & "dsb sy" & LF
             & "isb sy" & LF)
        & (if Profile.Layout = Profiles.RAM_Layout then "" else
        "ldr r0, =_landin_firmware_data_load" & LF
        & "ldr r1, =_landin_firmware_data_start" & LF
        & "ldr r2, =_landin_firmware_data_end" & LF
        & "cmp r0, r1" & LF
        & "beq 2f" & LF
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
        & "cmp r0, r1" & LF
        & "beq 7f" & LF
        & "6:" & LF
        & "cmp r1, r2" & LF
        & "bcs 7f" & LF
        & "ldrb r3, [r0]" & LF
        & "strb r3, [r1]" & LF
        & "adds r0, #1" & LF
        & "adds r1, #1" & LF
        & "b 6b" & LF
        & "7:" & LF)
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

   function RV32_Image
     (Of_Unit : Landin.IR.Unit;
      Names : Landin.Source.Names.Table;
      Entry_Symbol : String;
      Symbol : not null access function
        (Item : Landin.IR.Item_Id) return String;
      Limit_Cell : String;
      Returned : String;
      Debug : Boolean) return String
   is
      use type Landin.IR.Item_Id;
      use type Landin.Machine.Convention;
      use type Profiles.Interrupt_Model;
      Profile : constant Profiles.Profile :=
        Landin.IR.Firmware_Profile (Of_Unit);
      Used : constant Region_Use := Used_Regions (Of_Unit, Names);
      Model : constant Profiles.Interrupt_Model :=
        Profiles.Model_Of (Profile.Core);
      Keeps_Limit : constant Boolean := Limit_Cell /= "";
      Frame : constant String :=
        Number (Landin.Targets.Byte_Count
          (RV32_Trap_Frame (Keeps_Limit)));
      Handlers : array (0 .. Profiles.Slot_Capacity - 1)
        of Landin.IR.Item_Id := [others => Landin.IR.No_Item];
      Result, Stubs : US.Unbounded_String;
      --  Whether any slot enters the shared stub tail.
      Stubbed : Boolean := False;

      procedure Line (Into : in out US.Unbounded_String; Text : String);
      procedure Line (Into : in out US.Unbounded_String; Text : String) is
      begin
         US.Append (Into, Text & LF);
      end Line;

      function Naked (Item : Landin.IR.Item_Id) return Boolean is
        (Landin.IR.Signature_Machine
           (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item))
         = Landin.Machine.Naked_Routine);

      --  The registers a stub saves, each at its offset in the frame:
      --  the ones the psABI lets a call change, which the interrupted
      --  code did not expect to.
      type Register_List is array (Positive range <>) of access constant
        String;
      R_Ra : aliased constant String := "ra";
      R_T0 : aliased constant String := "t0";
      R_T1 : aliased constant String := "t1";
      R_T2 : aliased constant String := "t2";
      R_T3 : aliased constant String := "t3";
      R_T4 : aliased constant String := "t4";
      R_T5 : aliased constant String := "t5";
      R_T6 : aliased constant String := "t6";
      R_A0 : aliased constant String := "a0";
      R_A1 : aliased constant String := "a1";
      R_A2 : aliased constant String := "a2";
      R_A3 : aliased constant String := "a3";
      R_A4 : aliased constant String := "a4";
      R_A5 : aliased constant String := "a5";
      R_A6 : aliased constant String := "a6";
      R_A7 : aliased constant String := "a7";
      Saved : constant Register_List :=
        [R_Ra'Access, R_T0'Access, R_T1'Access, R_T2'Access, R_T3'Access,
         R_T4'Access, R_T5'Access, R_T6'Access, R_A0'Access, R_A1'Access,
         R_A2'Access, R_A3'Access, R_A4'Access, R_A5'Access, R_A6'Access,
         R_A7'Access];
      Cell_Offset : constant String := "64";

      function Offset (Index : Positive) return String is
        (Number (Landin.Targets.Byte_Count (4 * (Index - 1))));

      --  The frame below the interrupted sp, every register but those
      --  SKIP names already saved, with the unwind rules that say where
      --  each went and that the interrupted pc is mepc's.
      procedure Save
        (Into : in out US.Unbounded_String; Skip_T0 : Boolean);
      procedure Save
        (Into : in out US.Unbounded_String; Skip_T0 : Boolean) is
      begin
         if not Skip_T0 then
            Line (Into, "addi sp, sp, -" & Frame);
            if Debug then
               Line (Into, ".cfi_def_cfa_offset " & Frame);
            end if;
         end if;
         for Index in Saved'Range loop
            if not (Skip_T0 and then Saved (Index).all = "t0") then
               Line (Into, "sw " & Saved (Index).all & ", " & Offset (Index)
                 & "(sp)");
            end if;
            if Debug then
               Line (Into, ".cfi_offset " & Saved (Index).all & ", "
                 & Offset (Index) & " - " & Frame);
            end if;
         end loop;
         --  D680, [1995]: a handler and what it calls are not checked
         --  against the interrupted context's limit, which a switch may
         --  be between writing; the cell holds zero while they run.
         if Keeps_Limit then
            Line (Into, "la t1, " & Limit_Cell);
            Line (Into, "lw t2, 0(t1)");
            Line (Into, "sw t2, " & Cell_Offset & "(sp)");
            Line (Into, "sw zero, 0(t1)");
         end if;
      end Save;

      --  The frame undone, then mret, or with Returns false nothing
      --  after it, for the unhandled entry, which records the
      --  interrupted sp (D656).
      procedure Restore
        (Into : in out US.Unbounded_String; Returns : Boolean := True);
      procedure Restore
        (Into : in out US.Unbounded_String; Returns : Boolean := True) is
      begin
         if Keeps_Limit then
            Line (Into, "lw t2, " & Cell_Offset & "(sp)");
            Line (Into, "la t1, " & Limit_Cell);
            Line (Into, "sw t2, 0(t1)");
         end if;
         for Index in Saved'Range loop
            Line (Into, "lw " & Saved (Index).all & ", " & Offset (Index)
              & "(sp)");
         end loop;
         Line (Into, "addi sp, sp, " & Frame);
         if Returns then
            Line (Into, "mret");
         end if;
      end Restore;

      --  An entry the trap reaches with every register the interrupted
      --  code's: its unwind rules begin at the interrupted sp, and its
      --  return address is mepc, which nothing changes until mret.
      procedure Trap_Entry
        (Into : in out US.Unbounded_String; Name : String;
         Alignment : String := "4");
      procedure Trap_Entry
        (Into : in out US.Unbounded_String; Name : String;
         Alignment : String := "4") is
      begin
         Line (Into, ".balign " & Alignment);
         Line (Into, ".type " & Name & ", @function");
         Line (Into, Name & ":");
         if Debug then
            Line (Into, ".cfi_startproc simple");
            Line (Into, ".cfi_return_column mepc");
            Line (Into, ".cfi_def_cfa sp, 0");
            Line (Into, ".cfi_same_value mepc");
         end if;
      end Trap_Entry;

      procedure Trap_End (Into : in out US.Unbounded_String; Name : String);
      procedure Trap_End (Into : in out US.Unbounded_String; Name : String)
      is
      begin
         if Debug then
            Line (Into, ".cfi_endproc");
         end if;
         Line (Into, ".size " & Name & ", . - " & Name);
      end Trap_End;

      function Stub_Name (Slot : Natural) return String is
        ("_landin_firmware_slot_" & Number (Landin.Targets.Byte_Count (Slot)));

      --  What slot SLOT of the table jumps to.
      function Slot_Target (Slot : Natural) return String is
        (if Model = Profiles.Xh3irq and then Slot = 11
         then "_landin_firmware_external"
         elsif not Profiles.Admits (Profile, Slot)
           or else Handlers (Slot) = Landin.IR.No_Item
         then "_landin_firmware_unhandled"
         elsif Naked (Handlers (Slot))
           or else Profiles.Dispatched_Slot (Profile.Core, Slot)
         then Symbol (Handlers (Slot))
         else Stub_Name (Slot));

      --  Whether the hardware may enter slot SLOT itself, so that a stub
      --  of its own saves the frame: a slot the core's dispatch does not
      --  call, and under the CLIC every slot, since an interrupt whose
      --  `shv` the program sets is entered through mtvt's table rather
      --  than the common entry (D830).
      function Hardware_Entered (Slot : Natural) return Boolean is
        (Model = Profiles.CLIC
         or else not Profiles.Dispatched_Slot (Profile.Core, Slot));

      --  The mtvec reset writes: the table, in vectored mode, or under the
      --  CLIC its common entry, in CLIC mode.
      Trap_Base : constant String :=
        (if Model = Profiles.CLIC then "_landin_firmware_trap"
         else "_landin_firmware_vectors");
      Trap_Mode : constant String := (if Model = Profiles.CLIC then "3"
                                      else "1");

      Regions : US.Unbounded_String;

      --  Copy [START, END) from LOAD, a byte at a time, as reset does on
      --  Cortex-M.
      procedure Copy (Load, First, Last : String);
      procedure Copy (Load, First, Last : String) is
      begin
         if Profile.Layout = Profiles.RAM_Layout then
            return;
         end if;
         Line (Regions, "la a0, " & Load);
         Line (Regions, "la a1, " & First);
         Line (Regions, "la a2, " & Last);
         Line (Regions, "beq a0, a1, 2f");
         Line (Regions, "1:");
         Line (Regions, "bgeu a1, a2, 2f");
         Line (Regions, "lbu a3, 0(a0)");
         Line (Regions, "sb a3, 0(a1)");
         Line (Regions, "addi a0, a0, 1");
         Line (Regions, "addi a1, a1, 1");
         Line (Regions, "j 1b");
         Line (Regions, "2:");
      end Copy;

      procedure Clear (First, Last : String);
      procedure Clear (First, Last : String) is
      begin
         Line (Regions, "la a1, " & First);
         Line (Regions, "la a2, " & Last);
         Line (Regions, "1:");
         Line (Regions, "bgeu a1, a2, 2f");
         Line (Regions, "sb zero, 0(a1)");
         Line (Regions, "addi a1, a1, 1");
         Line (Regions, "j 1b");
         Line (Regions, "2:");
      end Clear;
   begin
      for Index in 1 .. Landin.IR.Item_Count (Of_Unit) loop
         declare
            Item : constant Landin.IR.Item_Id := Landin.IR.Item_Id (Index);
            Slot : constant Natural :=
              Landin.IR.Placement_Of (Of_Unit, Item).Vector;
         begin
            if Slot /= 0 then
               Handlers (Slot) := Item;
            end if;
         end;
      end loop;

      --  D680: the entry word, a jump the boot ROM or reset vector
      --  enters, and the table, a jump per slot.  Neither may become a
      --  compressed jump or move in a relaxation: each is one word.
      Line (Result, ".section .text.landin_entry,""ax"",@progbits");
      Line (Result, ".option push");
      Line (Result, ".option norvc");
      Line (Result, ".option norelax");
      Line (Result, ".balign 4");
      Line (Result, ".globl _landin_firmware_entry");
      Line (Result, ".type _landin_firmware_entry, @function");
      Line (Result, "_landin_firmware_entry:");
      --  D684: a description's stage runs before reset.
      Line (Result, "j " & (if Profile.Has_Stage
                               and then Profiles.Stage_Before_Reset
                                 (Profile.Boot)
                            then Profiles.Reset_Stage_Symbol
                            else Profiles.Reset_Symbol));
      Line (Result, ".size _landin_firmware_entry, 4");
      --  The script places the table at Vector_Address, which is aligned
      --  as the core needs.  The section asks only for its words', since
      --  RISC-V's assembler pads an executable section to its alignment,
      --  and a table shorter than that would outgrow its asserted size.
      Line (Result, ".section .isr_vector,""ax"",@progbits");
      Line (Result, ".balign 4");
      Line (Result, ".globl _landin_firmware_vectors");
      Line (Result, ".type _landin_firmware_vectors, @function");
      Line (Result, "_landin_firmware_vectors:");
      for Slot in 0 .. Profile.Vector_Count - 1 loop
         Line (Result, "j " & Slot_Target (Slot));
      end loop;
      Line (Result, ".size _landin_firmware_vectors, . - _landin_firmware_"
        & "vectors");
      Line (Result, ".option pop");
      if Model = Profiles.CLIC then
         --  D830: the CLIC's table of handler addresses, which mtvt
         --  names: an interrupt whose `shv` is set enters the address
         --  at mtvt + 4 * id with every register the interrupted
         --  code's, so a handled slot's is its stub and every other
         --  slot's the unhandled entry.  mtvt is aligned to 64 bytes
         --  (the C5's TRM v1.1, Register 2.10).
         Line (Result, ".section .text.landin_firmware_vector_addresses,"
           & """ax"",@progbits");
         Line (Result, ".balign 64");
         Line (Result, ".globl _landin_firmware_vector_addresses");
         Line (Result, ".type _landin_firmware_vector_addresses, @object");
         Line (Result, "_landin_firmware_vector_addresses:");
         for Slot in 0 .. Profile.Vector_Count - 1 loop
            Line (Result, ".word "
              & (if Profiles.Admits (Profile, Slot)
                   and then Handlers (Slot) /= Landin.IR.No_Item
                 then Stub_Name (Slot)
                 else "_landin_firmware_unhandled"));
         end loop;
         Line (Result, ".size _landin_firmware_vector_addresses, . - "
           & "_landin_firmware_vector_addresses");
      end if;
      if Profiles.Takes_Image_Block (Profile.Boot) then
         --  D637, D682: the IMAGE_DEF block, directly after the table.
         Line (Result, ".section .embedded_block,""a"",@progbits");
         Line (Result, ".balign 4");
         Line (Result, ".globl _landin_firmware_image_block");
         Line (Result, ".type _landin_firmware_image_block, @object");
         Line (Result, "_landin_firmware_image_block:");
         for Word of Profiles.Image_Block_Of (Profile.Core) loop
            Line (Result, ".word " & Hex (Landin.Targets.Byte_Count (Word)));
         end loop;
         Line (Result, ".size _landin_firmware_image_block, . - _landin_"
           & "firmware_image_block");
      end if;

      --  The stubs of the slots the hardware enters: t0 carries the
      --  handler to the shared tail, which saves the rest and calls it.
      for Slot in 0 .. Profile.Vector_Count - 1 loop
         if Profiles.Admits (Profile, Slot)
           and then Handlers (Slot) /= Landin.IR.No_Item
           and then not Naked (Handlers (Slot))
           and then Hardware_Entered (Slot)
         then
            Stubbed := True;
            Trap_Entry (Stubs, Stub_Name (Slot));
            Line (Stubs, "addi sp, sp, -" & Frame);
            if Debug then
               Line (Stubs, ".cfi_def_cfa_offset " & Frame);
            end if;
            Line (Stubs, "sw t0, 4(sp)");
            if Debug then
               Line (Stubs, ".cfi_offset t0, 4 - " & Frame);
            end if;
            Line (Stubs, "la t0, " & Symbol (Handlers (Slot)));
            Line (Stubs, "j _landin_firmware_interrupt");
            Trap_End (Stubs, Stub_Name (Slot));
         end if;
      end loop;
      Line (Result, ".section .text.landin_firmware_trap,""ax"",@progbits");
      US.Append (Result, US.To_String (Stubs));
      if Stubbed then
         --  Entered from a stub with the frame made, t0 saved and the
         --  handler in t0.
         Trap_Entry (Result, "_landin_firmware_interrupt");
         if Debug then
            Line (Result, ".cfi_def_cfa_offset " & Frame);
         end if;
         Save (Result, Skip_T0 => True);
         Line (Result, "jalr t0");
         Restore (Result);
         Trap_End (Result, "_landin_firmware_interrupt");
      end if;
      if Model = Profiles.CLIC then
         --  D680: CLIC mode sends every trap but a hardware vectored
         --  interrupt's (D830) to mtvec's base: an interrupt's id is
         --  mcause's low twelve bits, and its slot is called through the
         --  table.
         Trap_Entry (Result, "_landin_firmware_trap", "64");
         Save (Result, Skip_T0 => False);
         Line (Result, "csrr t0, mcause");
         Line (Result, "bgez t0, 1f");
         Line (Result, "slli t0, t0, 20");
         Line (Result, "srli t0, t0, 20");
         Line (Result, "li t1, "
           & Number (Landin.Targets.Byte_Count (Profile.Vector_Count)));
         Line (Result, "bgeu t0, t1, 1f");
         Line (Result, "slli t0, t0, 2");
         Line (Result, "la t1, _landin_firmware_vectors");
         Line (Result, "add t0, t0, t1");
         Line (Result, "jalr t0");
         Restore (Result);
         Line (Result, "1:");
         Restore (Result, Returns => False);
         Line (Result, "j _landin_firmware_unhandled");
         Trap_End (Result, "_landin_firmware_trap");
      elsif Model = Profiles.Xh3irq then
         --  D680: Hazard3's external interrupts all arrive at code 11;
         --  meinext names the highest-priority one pending and enabled,
         --  its IRQ times four, or sets bit 31 when there is none.  Each
         --  is called through slot 16 + IRQ until none is left.
         Trap_Entry (Result, "_landin_firmware_external");
         Save (Result, Skip_T0 => False);
         Line (Result, "1:");
         Line (Result, "csrr t0, 0xbe4");
         Line (Result, "bltz t0, 2f");
         Line (Result, "li t1, "
           & Number (Landin.Targets.Byte_Count
               (4 * Natural'Max (Profile.Vector_Count, 16) - 64)));
         Line (Result, "bgeu t0, t1, 3f");
         Line (Result, "la t1, _landin_firmware_vectors + 64");
         Line (Result, "add t0, t0, t1");
         Line (Result, "jalr t0");
         Line (Result, "j 1b");
         Line (Result, "2:");
         Restore (Result);
         Line (Result, "3:");
         Restore (Result, Returns => False);
         Line (Result, "j _landin_firmware_unhandled");
         Trap_End (Result, "_landin_firmware_external");
      end if;

      --  D680: reset, which the entry word or the stage enters with every
      --  register unknown.
      Copy ("_landin_firmware_data_load", "_landin_firmware_data_start",
            "_landin_firmware_data_end");
      Copy ("_landin_firmware_ramtext_load",
            "_landin_firmware_ramtext_start",
            "_landin_firmware_ramtext_end");
      Clear ("_landin_firmware_bss_start", "_landin_firmware_bss_end");
      --  D547: a writable region a placement uses, after them.
      for Index in 1 .. Profile.Count loop
         if Used (Index)
           and then Profiles.Writable (Profile.Regions (Index).Mode)
         then
            declare
               Name : constant String :=
                 Profiles.Spelling (Profile.Regions (Index).Name);
            begin
               Copy (Region_Symbol (Name, "data_load"),
                     Region_Symbol (Name, "data_start"),
                     Region_Symbol (Name, "data_end"));
               Clear (Region_Symbol (Name, "bss_start"),
                      Region_Symbol (Name, "bss_end"));
            end;
         end if;
      end loop;
      Line (Result, ".section .text.landin_reset,""ax"",@progbits");
      Line (Result, ".balign 4");
      Line (Result, ".globl " & Profiles.Reset_Symbol);
      Line (Result, ".type " & Profiles.Reset_Symbol & ", @function");
      Line (Result, Profiles.Reset_Symbol & ":");
      if Debug then
         Line (Result, ".cfi_startproc simple");
         Line (Result, ".cfi_def_cfa sp, 0");
         Line (Result, ".cfi_undefined ra");
      end if;
      Line (Result, "csrci mstatus, 8");
      Line (Result, "la t0, " & Trap_Base);
      Line (Result, "ori t0, t0, " & Trap_Mode);
      Line (Result, "csrw mtvec, t0");
      if Model = Profiles.CLIC then
         --  D830: mtvt, CSR 0x307, names the table of addresses.
         Line (Result, "la t0, _landin_firmware_vector_addresses");
         Line (Result, "csrw 0x307, t0");
      end if;
      Line (Result, "la sp, _landin_firmware_stack_top");
      US.Append (Result, US.To_String (Regions));
      --  The copies are data to every hart's loads and code to its
      --  fetches only after both fences.
      Line (Result, "fence rw, rw");
      Line (Result, "fence.i");
      Line (Result, "csrsi mstatus, 8");
      Line (Result, "call " & Entry_Symbol);
      Line (Result, ".globl _landin_firmware_returned");
      Line (Result, "_landin_firmware_returned:");
      if Returned /= "" then
         Line (Result, Returned);
      end if;
      Line (Result, "unimp");
      Line (Result, "j _landin_firmware_returned");
      if Debug then
         Line (Result, ".cfi_endproc");
      end if;
      Line (Result, ".size " & Profiles.Reset_Symbol & ", . - "
        & Profiles.Reset_Symbol);
      Line (Result, ".section .text.landin_firmware_unhandled,""ax"","
        & "@progbits");
      Line (Result, ".balign 4");
      Line (Result, ".globl _landin_firmware_unhandled");
      Line (Result, ".type _landin_firmware_unhandled, @function");
      Line (Result, "_landin_firmware_unhandled:");
      if Debug then
         Line (Result, ".cfi_startproc simple");
         Line (Result, ".cfi_def_cfa sp, 0");
         Line (Result, ".cfi_undefined ra");
      end if;
      --  D656: the trap's record, in cells any probe reads as memory,
      --  made without the stack, which may be what failed.  t0 waits in
      --  mscratch and sp, once recorded, carries each CSR; both are
      --  restored, so every other register is still the interrupted
      --  code's.  The count is written last: a reader that sees it move
      --  sees the whole record.
      Line (Result, "csrw mscratch, t0");
      Line (Result, "la t0, " & Trap_Cell (Trap_Cause));
      Line (Result, "sw sp, " & Trap_Offset (Trap_SP) & "(t0)");
      Line (Result, "csrr sp, mcause");
      Line (Result, "sw sp, " & Trap_Offset (Trap_Cause) & "(t0)");
      Line (Result, "csrr sp, mepc");
      Line (Result, "sw sp, " & Trap_Offset (Trap_PC) & "(t0)");
      Line (Result, "csrr sp, mtval");
      Line (Result, "sw sp, " & Trap_Offset (Trap_Value) & "(t0)");
      Line (Result, "lw sp, " & Trap_Offset (Trap_Count) & "(t0)");
      Line (Result, "addi sp, sp, 1");
      Line (Result, "sw sp, " & Trap_Offset (Trap_Count) & "(t0)");
      Line (Result, "lw sp, " & Trap_Offset (Trap_SP) & "(t0)");
      Line (Result, "csrr t0, mscratch");
      Line (Result, "csrci mstatus, 8");
      Line (Result, "1:");
      Line (Result, "wfi");
      Line (Result, "j 1b");
      if Debug then
         Line (Result, ".cfi_endproc");
      end if;
      Line (Result, ".size _landin_firmware_unhandled, . - _landin_firmware"
        & "_unhandled");
      Line (Result, ".section .bss.landin_firmware_trap,""aw"",@nobits");
      Line (Result, ".balign 4");
      for Cell in Trap_Cell_Kind loop
         Line (Result, ".globl " & Trap_Cell (Cell));
         Line (Result, ".type " & Trap_Cell (Cell) & ", @object");
         Line (Result, ".size " & Trap_Cell (Cell) & ", 4");
         Line (Result, Trap_Cell (Cell) & ":");
         Line (Result, ".zero 4");
      end loop;
      return US.To_String (Result);
   end RV32_Image;

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


   function Xtensa_Image
     (Of_Unit : Landin.IR.Unit;
      Names : Landin.Source.Names.Table;
      Entry_Symbol : String;
      Symbol : not null access function
        (Item : Landin.IR.Item_Id) return String;
      Limit_Cell : String;
      Returned : String;
      Debug : Boolean) return String
   is
      use type Landin.IR.Item_Id;
      Profile : constant Profiles.Profile :=
        Landin.IR.Firmware_Profile (Of_Unit);
      Used : constant Region_Use := Used_Regions (Of_Unit, Names);
      Result : US.Unbounded_String;
      Handlers : array (0 .. 31) of Landin.IR.Item_Id :=
        [others => Landin.IR.No_Item];
      Context : constant String := "_landin_firmware_interrupt_context";
      --  All 64 physical address registers, then PS, PC, window base and
      --  mask, SAR and loop state. Interrupts remain masked throughout a
      --  handler: one complete context, with no nested handler claim.
      Context_Bytes : constant := 400;
      Has_Stage : Boolean := False;
      procedure Line (Text : String);
      procedure Line (Text : String) is
      begin
         US.Append (Result, Text & LF);
      end Line;
      function N (Value : Natural) return String is
        (Number (Landin.Targets.Byte_Count (Value)));
      procedure Save_Group (Group : Natural);
      procedure Save_Group (Group : Natural) is
      begin
         --  EXCM is set and WOE clear: ROTW cannot spill or underflow.
         --  Preserve the group's a0 before using it as a context pointer.
         Line ("wsr a0, EXCSAVE2");
         Line ("rsr a0, EXCSAVE1");
         for Reg in 1 .. 15 loop
            Line ("s32i a" & N (Reg) & ", a0, " & N (Group * 64 + Reg * 4));
         end loop;
         Line ("rsr a1, EXCSAVE2");
         Line ("s32i a1, a0, " & N (Group * 64));
         Line ("rotw 4");
      end Save_Group;
   begin
      for Index in 1 .. Landin.IR.Item_Count (Of_Unit) loop
         declare
            Item : constant Landin.IR.Item_Id := Landin.IR.Item_Id (Index);
            Slot : constant Integer :=
              Landin.IR.Placement_Of (Of_Unit, Item).Vector;
         begin
            if Slot in Handlers'Range
              and then (Slot /= 0 or else
                Landin.IR.Placement_Of (Of_Unit, Item).Vector_Present)
            then
               Handlers (Slot) := Item;
            end if;
            Has_Stage := Has_Stage
              or else Landin.IR.Placement_Of (Of_Unit, Item).Boot_Stage;
         end;
      end loop;
      Line (".section .isr_vector,""ax"",@progbits");
      Line (".balign 1024");
      Line (".global _landin_firmware_vectors");
      Line ("_landin_firmware_vectors:");
      --  The architectural spill/reload sequences use the ABI's base
      --  save area and the preceding frame's recorded SP. There are
      --  distinct vectors for CALL4, CALL8 and CALL12, including helpers.
      for Count in 1 .. 3 loop
         declare
            Words : constant Natural := Count * 4;
            Next_SP : constant String := "a" & N (Words + 1);
            Scratch : constant String := "a" & N (Words - 1);
         begin
            Line (".org " & N ((Count - 1) * 128));
            Line ("_landin_firmware_window_overflow" & N (Words) & ":");
            Line ("s32e a0, " & Next_SP & ", -16");
            if Words > 4 then
               Line ("l32e a0, a1, -12");
            end if;
            for Reg in 1 .. 3 loop
               Line ("s32e a" & N (Reg) & ", " & Next_SP & ", -"
                 & N (16 - Reg * 4));
            end loop;
            for Reg in 4 .. Words - 1 loop
               Line ("s32e a" & N (Reg) & ", a0, -"
                 & N ((Words - Reg + 4) * 4));
            end loop;
            Line ("rfwo");
            Line (".org " & N ((Count - 1) * 128 + 64));
            Line ("_landin_firmware_window_underflow" & N (Words) & ":");
            for Reg in 0 .. 2 loop
               Line ("l32e a" & N (Reg) & ", " & Next_SP & ", -"
                 & N (16 - Reg * 4));
            end loop;
            if Words > 4 then
               Line ("l32e " & Scratch & ", a1, -12");
            end if;
            Line ("l32e a3, " & Next_SP & ", -4");
            for Reg in 4 .. Words - 1 loop
               Line ("l32e a" & N (Reg) & ", " & Scratch & ", -"
                 & N ((Words - Reg + 4) * 4));
            end loop;
            Line ("rfwu");
         end;
      end loop;
      --  Level one arrives through the user/kernel exception vector.
      --  Levels two to five have dedicated vectors; level six is debug.
      for Level in 2 .. 7 loop
         Line (".org " & N (16#180# + (Level - 2) * 64));
         Line ("wsr a0, EXCSAVE1");
         Line ("j _landin_firmware_interrupt_" & N (Level));
      end loop;
      for Offset in 0 .. 2 loop
         Line (".org " & N (16#300# + Offset * 64));
         Line ("wsr a0, EXCSAVE1");
         Line ("j _landin_firmware_interrupt_1");
      end loop;
      Line (".org 1024");
      Line (".section .text.landin_entry,""ax"",@progbits");
      Line (".balign 4");
      Line (".global _landin_firmware_entry");
      Line ("_landin_firmware_entry:");
      Line ("j " & (if Has_Stage
                     and then Profiles.Stage_Before_Reset (Profile.Boot)
                   then Profiles.Reset_Stage_Symbol
                   else Profiles.Reset_Symbol));
      Line (".section .text.landin_firmware_reset,""ax"",@progbits");
      Line (".balign 4");
      Line (".global " & Profiles.Reset_Symbol);
      Line (Profiles.Reset_Symbol & ":");
      if Debug then
         Line (".cfi_startproc simple");
         Line (".cfi_def_cfa a1, 0");
         Line (".cfi_undefined a0");
      end if;
      Line ("movi a0, 0x3f");
      Line ("wsr a0, PS");
      Line ("rsync");
      Line ("movi a0, 0");
      Line ("wsr a0, WINDOWBASE");
      Line ("movi a0, 1");
      Line ("wsr a0, WINDOWSTART");
      Line ("rsync");
      Line ("movi a0, 0");
      Line ("wsr a0, INTENABLE");
      Line ("wsr a0, LCOUNT");
      Line ("wsr a0, SCOMPARE1");
      --  Both pinned configurations have the single-precision FPU. The
      --  ABI uses integer carriers, but their libgcc helpers use FP state.
      Line ("movi a0, 1");
      Line ("wsr a0, CPENABLE");
      Line ("rsync");
      Line ("movi a1, _landin_firmware_stack_top");
      Line ("addi a1, a1, -32");
      Line ("movi a2, _landin_firmware_stack_top");
      Line ("s32e a2, a1, -12");
      Line ("movi a2, _landin_firmware_vectors");
      Line ("wsr a2, VECBASE");
      Line ("rsync");
      if Profile.Layout /= Profiles.RAM_Layout then
         Line ("movi a2, _landin_firmware_data_load");
         Line ("movi a3, _landin_firmware_data_start");
         Line ("movi a4, _landin_firmware_data_end");
         Line ("beq a2, a3, 2f");
         Line ("1: bgeu a3, a4, 2f");
         Line ("l8ui a5, a2, 0");
         Line ("s8i a5, a3, 0");
         Line ("addi a2, a2, 1");
         Line ("addi a3, a3, 1");
         Line ("j 1b");
         Line ("2:");
      end if;
      Line ("movi a3, _landin_firmware_bss_start");
      Line ("movi a4, _landin_firmware_bss_end");
      Line ("movi a5, 0");
      Line ("1: bgeu a3, a4, 2f");
      Line ("s8i a5, a3, 0");
      Line ("addi a3, a3, 1");
      Line ("j 1b");
      Line ("2:");
      for Index in 1 .. Profile.Count loop
         if Used (Index)
           and then Profiles.Writable (Profile.Regions (Index).Mode)
         then
            declare
               Name : constant String :=
                 Profiles.Spelling (Profile.Regions (Index).Name);
            begin
               if Profile.Layout /= Profiles.RAM_Layout then
                  Line ("movi a2, " & Region_Symbol (Name, "data_load"));
                  Line ("movi a3, " & Region_Symbol (Name, "data_start"));
                  Line ("movi a4, " & Region_Symbol (Name, "data_end"));
                  Line ("beq a2, a3, 2f");
                  Line ("1: bgeu a3, a4, 2f");
                  Line ("l8ui a5, a2, 0");
                  Line ("s8i a5, a3, 0");
                  Line ("addi a2, a2, 1");
                  Line ("addi a3, a3, 1");
                  Line ("j 1b");
                  Line ("2:");
               end if;
               Line ("movi a3, " & Region_Symbol (Name, "bss_start"));
               Line ("movi a4, " & Region_Symbol (Name, "bss_end"));
               Line ("movi a5, 0");
               Line ("1: bgeu a3, a4, 2f");
               Line ("s8i a5, a3, 0");
               Line ("addi a3, a3, 1");
               Line ("j 1b");
               Line ("2:");
            end;
         end if;
      end loop;
      if Limit_Cell /= "" then
         Line ("movi a2, " & Limit_Cell);
         Line ("movi a3, _landin_firmware_stack_bottom");
         Line ("s32i a3, a2, 0");
      end if;
      Line (".global _landin_firmware_instruction_visibility");
      Line ("_landin_firmware_instruction_visibility:");
      Line ("memw");
      Line ("isync");
      Line ("movi a2, 0x40020");
      Line ("wsr a2, PS");
      Line ("rsync");
      Line ("call8 " & Entry_Symbol);
      if Returned /= "" then
         Line (Returned);
      end if;
      Line ("j _landin_firmware_stopped");
      if Debug then
         Line (".cfi_endproc");
      end if;
      for Level in 1 .. 7 loop
         Line ("_landin_firmware_interrupt_" & N (Level) & ":");
         Line ("rsr a0, " & (if Level = 1 then "PS" else "EPS" & N (Level)));
         Line ("wsr a0, EXCSAVE2");
         Line ("movi a0, 0x3f");
         Line ("wsr a0, PS");
         Line ("rsync");
         Line ("movi a0, " & Context);
         for Reg in 1 .. 15 loop
            Line ("s32i a" & N (Reg) & ", a0, " & N (Reg * 4));
         end loop;
         Line ("rsr a1, EXCSAVE1");
         Line ("s32i a1, a0, 0");
         Line ("rsr a1, EXCSAVE2");
         if Level = 1 then
            Line ("movi a2, -17");
            Line ("and a1, a1, a2");
         end if;
         Line ("s32i a1, a0, 256");
         Line ("rsr a1, EPC" & N (Level));
         Line ("s32i a1, a0, 260");
         Line ("rsr a1, WINDOWBASE");
         Line ("s32i a1, a0, 264");
         Line ("rsr a1, WINDOWSTART");
         Line ("s32i a1, a0, 268");
         Line ("wsr a0, EXCSAVE1");
         Line ("rotw 4");
         for Group in 1 .. 3 loop
            Save_Group (Group);
         end loop;
         Line ("rsr a0, EXCSAVE1");
         Line ("movi a2, " & N (Level));
         Line ("j _landin_firmware_interrupt_saved");
      end loop;
      Line ("_landin_firmware_interrupt_saved:");
      Line ("rsr a1, SAR");
      Line ("s32i a1, a0, 272");
      Line ("rsr a1, LBEG");
      Line ("s32i a1, a0, 276");
      Line ("rsr a1, LEND");
      Line ("s32i a1, a0, 280");
      Line ("rsr a1, LCOUNT");
      Line ("s32i a1, a0, 284");
      Line ("s32i a2, a0, 288");
      for Reg in 0 .. 15 loop
         Line ("ssi f" & N (Reg) & ", a0, " & N (304 + Reg * 4));
      end loop;
      Line ("rur a1, FCR");
      Line ("s32i a1, a0, 368");
      Line ("rur a1, FSR");
      Line ("s32i a1, a0, 372");
      Line ("bnei a2, 1, 1f");
      Line ("rsr a3, EXCCAUSE");
      Line ("bnei a3, 4, _landin_firmware_unhandled");
      Line ("1:");
      Line ("movi a3, 0");
      Line ("wsr a3, WINDOWBASE");
      Line ("movi a3, 1");
      Line ("wsr a3, WINDOWSTART");
      Line ("rsync");
      Line ("rsr a8, EXCSAVE1");
      Line ("l32i a1, a8, 4");
      Line ("mov a3, a1");
      Line ("addi a1, a1, -32");
      Line ("s32e a3, a1, -12");
      Line ("movi a3, 0");
      Line ("wsr a3, LCOUNT");
      Line ("movi a3, 0x4002f");
      Line ("wsr a3, PS");
      Line ("rsync");
      Line ("l32i a3, a8, 288");
      Line ("rsr a2, INTERRUPT");
      Line ("rsr a4, INTENABLE");
      Line ("and a2, a2, a4");
      for Level in 1 .. 7 loop
         Line ("bnei a3, " & N (Level) & ", 1f");
         Line ("movi a4, " & Hex
           (Profiles.Interrupt_Level_Mask (Profile.Core, Level)));
         Line ("and a2, a2, a4");
         Line ("j 2f");
         Line ("1:");
      end loop;
      Line ("2:");
      Line ("s32i a2, a8, 296");
      for Slot in Handlers'Range loop
         --  A windowed handler may clobber a2. Retain this dispatch's
         --  pending set independently of the handler's result registers.
         Line ("movi a8, " & Context);
         Line ("l32i a2, a8, 296");
         if Handlers (Slot) /= Landin.IR.No_Item then
            Line ("bbci a2, " & N (Slot) & ", 1f");
            Line ("call8 " & Symbol (Handlers (Slot)));
            Line ("1:");
         else
            Line ("bbsi a2, " & N (Slot)
              & ", _landin_firmware_unhandled");
         end if;
      end loop;
      Line ("movi a0, 0x3f");
      Line ("wsr a0, PS");
      Line ("rsync");
      Line ("movi a0, " & Context);
      Line ("l32i a1, a0, 256");
      Line ("wsr a1, EPS2");
      Line ("l32i a1, a0, 260");
      Line ("wsr a1, EPC2");
      Line ("l32i a1, a0, 272");
      Line ("wsr a1, SAR");
      Line ("l32i a1, a0, 276");
      Line ("wsr a1, LBEG");
      Line ("l32i a1, a0, 280");
      Line ("wsr a1, LEND");
      Line ("l32i a1, a0, 284");
      Line ("wsr a1, LCOUNT");
      for Reg in 0 .. 15 loop
         Line ("lsi f" & N (Reg) & ", a0, " & N (304 + Reg * 4));
      end loop;
      Line ("l32i a1, a0, 368");
      Line ("wur a1, FCR");
      Line ("l32i a1, a0, 372");
      Line ("wur a1, FSR");
      Line ("l32i a1, a0, 268");
      Line ("wsr a1, WINDOWSTART");
      Line ("wsr a0, EXCSAVE1");
      Line ("l32i a1, a0, 264");
      Line ("wsr a1, WINDOWBASE");
      Line ("rsync");
      for Group in 0 .. 3 loop
         Line ("rsr a0, EXCSAVE1");
         for Reg in 1 .. 15 loop
            Line ("l32i a" & N (Reg) & ", a0, " & N (Group * 64 + Reg * 4));
         end loop;
         Line ("l32i a0, a0, " & N (Group * 64));
         Line ("rotw 4");
      end loop;
      Line ("rfi 2");
      Line (".global _landin_firmware_unhandled");
      Line ("_landin_firmware_unhandled:");
      Line ("movi a0, " & Trap_Cell (Trap_Cause));
      Line ("rsr a1, EXCCAUSE");
      Line ("s32i a1, a0, 0");
      Line ("movi a2, " & Context);
      Line ("l32i a1, a2, 260");
      Line ("s32i a1, a0, 4");
      Line ("rsr a1, EXCVADDR");
      Line ("s32i a1, a0, 8");
      Line ("l32i a1, a2, 4");
      Line ("s32i a1, a0, 12");
      Line ("l32i a1, a0, 16");
      Line ("addi a1, a1, 1");
      Line ("s32i a1, a0, 16");
      Line (".global _landin_firmware_stopped");
      Line ("_landin_firmware_stopped: j _landin_firmware_stopped");
      Line (".section .bss.landin_firmware_trap,""aw"",@nobits");
      Line (".balign 4");
      for Cell in Trap_Cell_Kind loop
         Line (".global " & Trap_Cell (Cell));
         Line (Trap_Cell (Cell) & ": .zero 4");
      end loop;
      Line (".balign 16");
      Line (Context & ": .zero " & N (Context_Bytes));
      return US.To_String (Result);
   end Xtensa_Image;

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
      --  D680: an RV32 image begins with its entry word, and its table is
      --  where the core's alignment puts it after that word.
      RV32 : constant Boolean := Profile.Core in Profiles.RISC_V_Core;
      Xtensa : constant Boolean := Profile.Core in Profiles.Xtensa_Core;
      Segmented : constant Boolean := RV32 or Xtensa;
      Entry_Address : constant String :=
        (if not RV32
           and then Profile.Layout = Profiles.RAM_Layout
           and then Profiles.Vector_Address (Profile)
             /= Profiles.Placed_Region (Profile, Profiles.Vectors).Origin
         then Number (Profiles.Vector_Address (Profile))
         else "ORIGIN(" & Vectors & ")"
           & (if Prefix = 0 then "" else " + " & Number (Prefix)));
      Memory, Sections, Segments : US.Unbounded_String;
      --  D686: an RV32 script names its loaded segments, one an output
      --  section begins, so that no segment carries the ELF's own headers,
      --  which a ROM that loads every segment would write where they are
      --  mapped.  NAME's is " :NAME" on RV32 and "" on Cortex-M, whose
      --  script stays D229's.
      function Segment (Name : String) return String is
        (if Segmented then " :" & Name else "");
      --  The end of the last output section in the stack's region, which
      --  must stay below the stack, and the last load image in flash.
      In_Stack_Region : US.Unbounded_String;
      Ramtext_With_Text : constant Boolean := Profiles.RAM_Only (Profile);
      RAM : constant Boolean := Profile.Layout = Profiles.RAM_Layout;
      function Load_From_Text return String is
        (if RAM or Xtensa then "" else " AT> " & Flash);
      Ramtext : constant String :=
        "  .ramtext : ALIGN(8) {" & LF
        & "    _landin_firmware_ramtext_start = .;" & LF
        & "    *(.ramtext.*)" & LF
        & "    _landin_firmware_ramtext_end = .;" & LF;
      Last_Load : US.Unbounded_String :=
        US.To_Unbounded_String
          (if Ramtext_With_Text then ".data" else ".ramtext");
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
           (if Ramtext_With_Text
            then "_landin_firmware_data_end"
            else "_landin_firmware_ramtext_end");
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
                    & "  } > " & Name & Load_From_Text
                    & Segment ("region_" & Name & "_data") & LF
                    & "  " & Region_Symbol (Name, "data_load")
                    & " = LOADADDR(" & Section & "_data);" & LF
                    & "  " & Section & "_bss (NOLOAD) : AT(ADDR(" & Section
                    & "_bss)) ALIGN(8) {" & LF
                    & "    " & Region_Symbol (Name, "bss_start")
                    & " = .;" & LF
                    & "    *(.landin_region." & Name & ".bss.*)" & LF
                    & "    " & Region_Symbol (Name, "bss_end")
                    & " = .;" & LF
                    & "  } > " & Name & Segment ("region_" & Name & "_bss")
                    & LF);
                  Last_Load := US.To_Unbounded_String (Section & "_data");
                  US.Append (Segments, "  region_" & Name & "_data PT_LOAD;"
                    & LF & "  region_" & Name & "_bss PT_LOAD;" & LF);
                  if Index = Stack_At then
                     In_Stack_Region := US.To_Unbounded_String
                       (Region_Symbol (Name, "bss_end"));
                  end if;
               else
                  US.Append (Sections,
                    "  " & Section & " : {" & LF
                    & "    *(.landin_region." & Name & ".text.*"
                    & " .landin_region." & Name & ".rodata.*)" & LF
                    & "  } > " & Name & Segment ("region_" & Name) & LF);
                  US.Append (Segments, "  region_" & Name & " PT_LOAD;"
                    & LF);
               end if;
            end;
         end if;
      end loop;
      return (if Xtensa
              then "OUTPUT_FORMAT(""elf32-xtensa-le"")" & LF
                & "OUTPUT_ARCH(xtensa)" & LF
                & "ENTRY(_landin_firmware_entry)" & LF
              elsif RV32
              then "OUTPUT_FORMAT(""elf32-littleriscv"")" & LF
                & "OUTPUT_ARCH(riscv)" & LF
                & "ENTRY(_landin_firmware_entry)" & LF
              else "OUTPUT_FORMAT(""elf32-littlearm"")" & LF
                & "OUTPUT_ARCH(arm)" & LF
                & "ENTRY(_landin_firmware_reset)" & LF)
        & "MEMORY {" & LF
        & US.To_String (Memory)
        & "}" & LF
        & (if Segmented
           then "PHDRS {" & LF & "  image PT_LOAD;" & LF
             & "  text PT_LOAD;" & LF
             & (if Profile.Placed (Profiles.Rodata)
                   = Profile.Placed (Profiles.Text)
                then "" else "  rodata PT_LOAD;" & LF)
             & "  data PT_LOAD;" & LF & "  bss PT_LOAD;" & LF
             & US.To_String (Segments) & "}" & LF
           else "")
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
        & (if Xtensa
           then "  .isr_vector "
             & Number (Profiles.Vector_Address (Profile))
           elsif RV32
           then "  .landin_entry " & Entry_Address
             & " : { KEEP(*(.text.landin_entry)) } > " & Vectors
             & Segment ("image") & LF
             & "  .isr_vector "
             & Number (Profiles.Vector_Address (Profile))
           else "  .isr_vector " & Entry_Address)
        & " : { KEEP(*(.isr_vector)) } > " & Vectors
        & (if Xtensa then Segment ("image") else "") & LF
        & (if Xtensa
           then "  .landin_entry : { KEEP(*(.text.landin_entry)) } > "
             & Vectors & Segment ("image") & LF
           else "")
        & (if Profiles.Takes_Image_Block (Profile.Boot)
           then "  .embedded_block : { KEEP(*(.embedded_block)) } > "
             & Vectors & LF
           else "")
        & "  .text : { "
        & (if Xtensa then "*(.literal .literal.*) " else "")
        & "*(.text .text.*) } > " & Flash & Segment ("text")
        & LF
        --  D900, D688: RAM code runs with text when the whole image is
        --  loaded into SRAM; a boot image otherwise copies it into data.
        & (if Ramtext_With_Text
           then Ramtext & "  } > " & Flash & Segment ("text") & LF
           else "")
        & "  .rodata : { *(.rodata .rodata.*"
        & (if RV32 then " .srodata .srodata.*" else "") & ") } > "
        & Placed (Profiles.Rodata)
        & (if Profile.Placed (Profiles.Rodata) = Profile.Placed (Profiles.Text)
           then "" else Segment ("rodata")) & LF
        & (if Segmented then ""
           else "  .ARM.extab : { *(.ARM.extab*) } > " & Flash & LF
             & "  .ARM.exidx : { *(.ARM.exidx*) } > " & Flash & LF)
        & "  .data : ALIGN(8) {" & LF
        & "    _landin_firmware_data_start = .;" & LF
        & "    *(.data .data.*" & (if RV32 then " .sdata .sdata.*" else "")
        & ")" & LF
        & "    _landin_firmware_data_end = .;" & LF
        & "  } > " & Data & Load_From_Text & Segment ("data") & LF
        & "  _landin_firmware_data_load = LOADADDR(.data);" & LF
        & (if Ramtext_With_Text then ""
           else Ramtext & "  } > " & Data & Load_From_Text & LF)
        & "  _landin_firmware_ramtext_load = LOADADDR(.ramtext);" & LF
        & "  .bss (NOLOAD) : AT(ADDR(.bss)) ALIGN(8) {" & LF
        & "    _landin_firmware_bss_start = .;" & LF
        --  D656: the trap record first, at the same address in every
        --  image of the profile.
        & (if Segmented then "    KEEP(*(.bss.landin_firmware_trap))" & LF
           else "")
        & "    *(.bss .bss.*" & (if RV32 then " .sbss .sbss.*" else "")
        & " COMMON)" & LF
        & "    _landin_firmware_bss_end = .;" & LF
        & "  } > " & Placed (Profiles.BSS) & Segment ("bss") & LF
        & US.To_String (Sections)
        & "  /DISCARD/ : { *(.comment .note.GNU-stack) }" & LF
        & "}" & LF
        & (if Profile.Boot = Profiles.RP2040_Boot2
           then "ASSERT(SIZEOF(.boot2) == 256, ""the second stage must be"
             & " 256 bytes"")" & LF
           else "")
        & (if RV32
           then "ASSERT(ADDR(.landin_entry) == " & Entry_Address
             & " && SIZEOF(.landin_entry) == "
             & Number (Profiles.Entry_Word_Bytes)
             & ", ""the image must begin with the entry word"")" & LF
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
        & (if Profiles.Takes_Image_Block (Profile.Boot)
           then "ASSERT(SIZEOF(.embedded_block) == "
             & Number (Profiles.Image_Block_Bytes)
             & ", ""the image block must be "
             & Number (Profiles.Image_Block_Bytes) & " bytes"")" & LF
             & "ASSERT(ADDR(.embedded_block) + SIZEOF(.embedded_block) <= "
             & "ORIGIN(" & Vectors & ") + "
             & Number (Profiles.Image_Block_Window) & "," & LF
             & "       ""the image block must end in the first "
             & Size_Words (Profiles.Image_Block_Window) & " of the image"")"
             & LF
           else "")
        & "ASSERT((_landin_firmware_stack_top & "
        & (if Segmented then "15" else "7") & ") == 0, ""unaligne"
        & "d initial stack"")" & LF
        & (if US.Length (In_Stack_Region) = 0 then ""
           else "ASSERT(" & US.To_String (In_Stack_Region)
             & " <= _landin_firmware_sta"
             & "ck_bottom," & LF
             & "       """ & Stack
             & (if RAM then " RAM capacity exceeded: image overlaps the"
                  & " reserved " else " image overlaps the reserved ")
             & Size_Words (Profile.Stack_Size) & " stack"
             & (if RAM then "; use --firmware-layout=boot for the board"
                  & " boot check"
                else "") & """)" & LF)
        & (if RAM then "" else "ASSERT(LOADADDR("
        & US.To_String (Last_Load) & ") + SIZEOF("
        & US.To_String (Last_Load) & ") <= "
        & "ORIGIN(" & Flash & ") + LENGTH(" & Flash & ")," & LF
        & "       ""initialized image exceeds flash"")" & LF);
   end Linker_Script;
end Landin.Backend.Firmware;
