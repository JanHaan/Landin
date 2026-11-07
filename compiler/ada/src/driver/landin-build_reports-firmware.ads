with Ada.Strings.Unbounded;
with Landin.Backend.Firmware;
with Landin.Platform;
with Landin.Targets.Firmware;

--  Post-link firmware evidence, Cortex-M's and RV32's. The ELF load
--  extents, rather than section payload sums or the ELF file length,
--  determine occupied capacity, and the selected profile (D543) says what
--  the capacity is and where.
package Landin.Build_Reports.Firmware is
   --  STAGE is the source name of the description's second-stage routine
   --  (D587), which the report names beside what it reads of the stage
   --  from the linked image: its length, its slot, and the checksum and
   --  the address it is written at (D588).  For an image block it reads
   --  the block's address, length and words (D638).  ESP_IMAGE is what the
   --  driver recorded of the application image it wrote beside an
   --  `esp-app-image` executable (D685), the members of `esp_image`.
   procedure Measure
     (Host : Landin.Platform.Filesystem'Class;
      Executable, Link_Map : String;
      Profile : Landin.Targets.Firmware.Profile;
      Stage : String;
      Result : out Ada.Strings.Unbounded.Unbounded_String;
      Valid : out Boolean;
      ESP_Image : String := "");

   --  The report of a request that writes the derived linker script alone
   --  (D589): the selected profile's facts and capacities, the stack's
   --  top, and no figure a linked image would give.
   function Limits (Profile : Landin.Targets.Firmware.Profile) return String;

   --  D546: the clause of the linker script contract a linked image
   --  breaks, named as the message gives it, or "" when it keeps them all:
   --  1, the vector table at the profile's boot address with its whole
   --  length and its first two words, on RV32 the entry word before it
   --  jumping to reset or the stage (D686), and the second stage or the
   --  image block its boot kind gives; 2, every `_landin_firmware_*`
   --  symbol startup reads; 3, the stack in a writable region, of the
   --  description's size and clear of the image's RAM; 4, each
   --  initialized image's load address in the region text is placed in.
   function Contract_Fault
     (Host : Landin.Platform.Filesystem'Class;
      Executable : String;
      Profile : Landin.Targets.Firmware.Profile;
      Used : Landin.Backend.Firmware.Region_Use) return String;

   --  D924: what an image linked with C archives holds that compiler-owned
   --  startup cannot honour, read from its section headers: C constructors
   --  (an init or preinit array, or `.ctors`), thread-local storage (a TLS
   --  section) or a dynamic linkage (a dynamic section, its symbols or an
   --  interpreter), each allocated and not empty; and the first section
   --  that holds it.  None for an image that holds none, or one that is
   --  not ELF, whose other checks name that.
   type Foreign_Kind is
     (No_Foreign, Constructors, Thread_Storage, Dynamic_Linkage);
   type Foreign_Section is record
      Kind : Foreign_Kind := No_Foreign;
      Name : Ada.Strings.Unbounded.Unbounded_String;
   end record;
   function Foreign_Section_Of
     (Host : Landin.Platform.Filesystem'Class; Executable : String)
      return Foreign_Section;
end Landin.Build_Reports.Firmware;
