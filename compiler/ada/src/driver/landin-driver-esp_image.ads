with Ada.Strings.Unbounded;
with Landin.Targets.Firmware;

--  D683, D685: the application image an ESP32's ROM loads from flash, made
--  from the linked executable of an `esp-app-image` profile, and read back.
--  This reads a 32-bit little-endian RISC-V executable's loaded segments
--  and writes them as the ROM reads them: the header, the extended header
--  naming the description's chip and revisions, each segment with its load
--  address and length, the checksum and the SHA-256.  It is computation on
--  bytes: the driver reads the executable and writes the image.
package Landin.Driver.ESP_Image is

   type Made is record
      --  The image's bytes, or "" when Fault says why there are none.
      Image : Ada.Strings.Unbounded.Unbounded_String;
      --  What the build report records of it: its offset in flash, its
      --  entry, each segment's address and length, the checksum and the
      --  SHA-256, as the members of one JSON object.
      Report : Ada.Strings.Unbounded.Unbounded_String;
      Fault : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  The image of EXECUTABLE, the linked executable's bytes, for PROFILE,
   --  whose boot kind is `esp-app-image`.  Each loaded segment with bytes
   --  in the file must lie in one of the profile's regions, there are at
   --  most 16 of them, and the entry must be `_landin_firmware_entry`.
   function Make
     (Executable : String;
      Profile : Landin.Targets.Firmware.Profile) return Made;

   --  "" when IMAGE, as read back from where it was written, is the image
   --  of EXECUTABLE for PROFILE: its header and extended header, every
   --  segment's address, length and bytes against the executable's, its
   --  padding, checksum and hash, and nothing after the hash.  Otherwise
   --  the first part that is not.  It parses IMAGE itself rather than
   --  comparing it with what Make returns.
   function Read_Back_Fault
     (Image, Executable : String;
      Profile : Landin.Targets.Firmware.Profile) return String;

end Landin.Driver.ESP_Image;
