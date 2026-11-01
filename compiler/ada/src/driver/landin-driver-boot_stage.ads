with Ada.Strings.Unbounded;

--  D588: an assembled rp2040-boot2 object's second stage, checked and
--  sealed.  refine has no assembler of its own, so the checksum a boot ROM
--  verifies can be computed only over the bytes the assembler wrote.  This
--  reads a 32-bit little-endian Arm relocatable object, finds its `.boot2`
--  section, refuses one that is not the slot's 256 bytes or that a
--  relocation reaches, and writes the CRC-32 of its first 252 bytes into
--  its last four, little-endian, in place.  It is computation on bytes: the
--  driver reads and writes the object.
package Landin.Driver.Boot_Stage is

   --  On success Fault is "" and Object holds the checksum; on a refusal
   --  Fault says what is wrong, naming the stage's size or the relocation,
   --  and Object is unchanged.
   procedure Seal
     (Object : in out Ada.Strings.Unbounded.Unbounded_String;
      Fault : out Ada.Strings.Unbounded.Unbounded_String);

end Landin.Driver.Boot_Stage;
