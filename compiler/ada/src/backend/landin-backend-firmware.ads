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

   --  An address as a reader compares it with a datasheet: 0x10000100.
   function Hex (Value : Landin.Targets.Byte_Count) return String;

   --  D545: the derived script, which the driver writes as OUT.ld.
   function Linker_Script
     (Profile : Landin.Targets.Firmware.Profile; Used : Region_Use)
      return String;
end Landin.Backend.Firmware;
