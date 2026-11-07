with Landin.Source.Names;
with Landin.Targets.Firmware;

--  Compiler-owned reset and linker inputs. No filesystem or tool effects.
--  The script and the startup follow the selected profile (D545): its
--  regions, where each part of the image is placed, its vector table and
--  its boot image kind.
package Landin.Backend.Firmware is
   --  D547: which of the profile's regions a `link(region: ...)` places
   --  something in.  Only those get sections of their own in the script
   --  and loops of their own in reset.
   type Region_Use is array (Landin.Targets.Firmware.Region_Index)
     of Boolean;
   function Used_Regions
     (Of_Unit : Landin.IR.Unit; Names : Landin.Source.Names.Table)
      return Region_Use;

   function Startup
     (Entry_Symbol : String;
      Profile : Landin.Targets.Firmware.Profile;
      Used : Region_Use;
      Returned : String := "udf #1";
      Debug : Boolean := False) return String;

   --  D680: an RV32 image's compiler-owned text: the entry word, the trap
   --  table at the profile's Vector_Address, the interrupt stubs and the
   --  core's dispatch, reset and the unhandled loop, in GNU RISC-V
   --  assembly at XLEN 32.  SYMBOL spells an item as the backend does;
   --  LIMIT_CELL is the stack limit's cell (D471), "" when the program
   --  prepares no stack; RETURNED runs when the entry returns.
   function RV32_Image
     (Of_Unit : Landin.IR.Unit;
      Names : Landin.Source.Names.Table;
      Entry_Symbol : String;
      Symbol : not null access function
        (Item : Landin.IR.Item_Id) return String;
      Limit_Cell : String;
      Returned : String;
      Debug : Boolean) return String;

   --  Windowed Xtensa firmware: native exception vectors, complete
   --  physical-register interrupt context and compiler-owned reset.
   function Xtensa_Image
     (Of_Unit : Landin.IR.Unit;
      Names : Landin.Source.Names.Table;
      Entry_Symbol : String;
      Symbol : not null access function
        (Item : Landin.IR.Item_Id) return String;
      Limit_Cell : String;
      Returned : String;
      Debug : Boolean) return String;

   --  The bytes an RV32 interrupt stub keeps below the interrupted stack:
   --  ra, t0-t6 and a0-a7, and with a limit cell its word, padded to the
   --  sixteen bytes the psABI keeps sp aligned to.
   function RV32_Trap_Frame (Keeps_Limit : Boolean) return Natural
     is (if Keeps_Limit then 80 else 64);

   --  D656: the cells the RV32 unhandled entry records a trap in, in
   --  this order in `.bss.landin_firmware_trap`, a word each: mcause,
   --  mepc, mtval, the interrupted sp, and how many traps reached it.
   type Trap_Cell_Kind is (Trap_Cause, Trap_PC, Trap_Value, Trap_SP,
                           Trap_Count);
   function Trap_Cell (Cell : Trap_Cell_Kind) return String is
     (case Cell is
         when Trap_Cause => "_landin_firmware_trap_cause",
         when Trap_PC => "_landin_firmware_trap_pc",
         when Trap_Value => "_landin_firmware_trap_value",
         when Trap_SP => "_landin_firmware_trap_sp",
         when Trap_Count => "_landin_firmware_trap_count");
   function Trap_Offset (Cell : Trap_Cell_Kind) return String is
     (case Cell is
         when Trap_Cause => "0", when Trap_PC => "4",
         when Trap_Value => "8", when Trap_SP => "12",
         when Trap_Count => "16");

   --  An address as a reader compares it with a datasheet: 0x10000100.
   function Hex (Value : Landin.Targets.Byte_Count) return String;

   --  D545: the derived script, which the driver writes as OUT.ld.
   --  D924: a link with C archives also keeps their constructors, which
   --  --gc-sections would otherwise drop unseen, in an `.init_array` of
   --  their own, so that the image shows them and the driver refuses it.
   function Linker_Script
     (Profile : Landin.Targets.Firmware.Profile; Used : Region_Use;
      Archives : Boolean := False)
      return String;
end Landin.Backend.Firmware;
