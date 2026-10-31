with Ada.Strings.Unbounded;
with Landin.Backend.Firmware;
with Landin.Platform;
with Landin.Targets.Firmware;

--  Post-link Cortex evidence. The ELF load extents, rather than section
--  payload sums or the ELF file length, determine occupied capacity, and
--  the selected profile (D543) says what the capacity is and where.
package Landin.Build_Reports.Firmware is
   procedure Measure
     (Host : Landin.Platform.Filesystem'Class;
      Executable, Link_Map : String;
      Profile : Landin.Targets.Firmware.Profile;
      Result : out Ada.Strings.Unbounded.Unbounded_String;
      Valid : out Boolean);

   --  D546: the clause of the linker script contract a linked image
   --  breaks, named as the message gives it, or "" when it keeps them all:
   --  1, the vector table at the profile's boot address with its whole
   --  length and its first two words; 2, every `_landin_firmware_*`
   --  symbol startup reads; 3, the stack in a writable region, of the
   --  description's size and clear of the image's RAM; 4, each
   --  initialized image's load address in the region text is placed in.
   function Contract_Fault
     (Host : Landin.Platform.Filesystem'Class;
      Executable : String;
      Profile : Landin.Targets.Firmware.Profile;
      Used : Landin.Backend.Firmware.Region_Use) return String;
end Landin.Build_Reports.Firmware;
