with Ada.Strings.Unbounded;
with Landin.Targets.Firmware;

--  D638: an assembled rp2350-image-block object's IMAGE_DEF block, read
--  back from the bytes the assembler wrote.  This reads a 32-bit
--  little-endian Arm or, for a RISC-V core (D682), RISC-V relocatable
--  object, finds its `.embedded_block`
--  section and refuses one that is not the block its boot kind gives
--  (D637), naming the part that is wrong, or that a relocation is in.  It
--  is computation on bytes: the driver reads the object.
package Landin.Driver.Image_Block is

   --  "" when OBJECT holds the block as it must be; otherwise what is
   --  wrong with it, its section or the object.
   function Fault
     (Object : String;
      Core : Landin.Targets.Firmware.Core_Kind :=
        Landin.Targets.Firmware.Cortex_M33)
      return Ada.Strings.Unbounded.Unbounded_String;

end Landin.Driver.Image_Block;
