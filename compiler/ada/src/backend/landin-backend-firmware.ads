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

   --  D684: what precedes a description's boot stage on RV32, which the
   --  entry word enters before reset: its section and its label.
   function RV32_Stage_Label return String;

   --  The bytes an RV32 interrupt stub keeps below the interrupted stack:
   --  ra, t0-t6 and a0-a7, and with a limit cell its word, padded to the
   --  sixteen bytes the psABI keeps sp aligned to.
   function RV32_Trap_Frame (Keeps_Limit : Boolean) return Natural
     is (if Keeps_Limit then 80 else 64);

   --  An address as a reader compares it with a datasheet: 0x10000100.
   function Hex (Value : Landin.Targets.Byte_Count) return String;

   --  D545: the derived script, which the driver writes as OUT.ld.
   function Linker_Script
     (Profile : Landin.Targets.Firmware.Profile; Used : Region_Use)
      return String;
end Landin.Backend.Firmware;
