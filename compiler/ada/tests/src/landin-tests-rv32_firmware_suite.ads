with Landin.Testing;

--  RV32's compiler-owned firmware: its profiles' scripts and reports, its
--  boot kinds and the objects and images the driver reads back (D680-D687).
package Landin.Tests.RV32_Firmware_Suite is
   procedure Register (Into : in out Landin.Testing.Registry);
end Landin.Tests.RV32_Firmware_Suite;
