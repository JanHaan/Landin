with Ada.Strings.Unbounded;
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
end Landin.Build_Reports.Firmware;
