with Ada.Strings.Unbounded;
with Landin.Platform;

--  Post-link Cortex evidence. The ELF load extents, rather than section
--  payload sums or the ELF file length, determine occupied capacity.
package Landin.Build_Reports.Firmware is
   procedure Measure
     (Host : Landin.Platform.Filesystem'Class;
      Executable, Link_Map : String;
      Result : out Ada.Strings.Unbounded.Unbounded_String;
      Valid : out Boolean);
end Landin.Build_Reports.Firmware;
