--  Cortex-M firmware profiles, in target bytes, and source assembly
--  admission.
--
--  A profile is what a device description selects (D542/D543): its core,
--  its vector table, its memory regions and where each part of the image
--  goes, and how the image begins.  The compiler holds the cores, their
--  architectural vector slots and the closed set of boot image kinds; it
--  holds no device.  A profile is built by configuration from the one
--  description a program reaches, the constrained reference among them,
--  and read by checking, the IR, the backend and the driver.
with Landin.Targets.Levels;
package Landin.Targets.Firmware is

   --  D543: the library module that describes the constrained reference
   --  profile, which a Cortex-M program that reaches no other description
   --  is given.
   Reference_Module : constant String := "platform/cortex_m/reference";

   --  A description's name: a device, a region or an interrupt.
   Name_Capacity : constant := 64;
   type Name_Text is private;
   function To_Name (Text : String) return Name_Text
     with Pre => Text'Length <= Name_Capacity;
   function Spelling (Name : Name_Text) return String;

   --  The five cores a description may name, each with its architecture.
   type Core_Kind is
     (Cortex_M0, Cortex_M0plus, Cortex_M3, Cortex_M4, Cortex_M7);
   function Is_Core_Name (Text : String) return Boolean;
   function Core_Named (Text : String) return Core_Kind
     with Pre => Is_Core_Name (Text);
   function Spelling (Core : Core_Kind) return String;
   --  The feature level a core executes, as Landin.Targets.Levels names it.
   function Level_Name (Core : Core_Kind) return String;
   function Is_Armv6_M (Core : Core_Kind) return Boolean
     is (Core in Cortex_M0 | Cortex_M0plus);
   --  The longest vector table the core's architecture allows, in words:
   --  ARMv6-M's 16 + 32 and ARMv7-M's 16 + 496.
   function Vector_Limit (Core : Core_Kind) return Positive
     is (if Is_Armv6_M (Core) then 48 else 512);
   --  The architecture's own exception slots a handler may take: NMI,
   --  HardFault, SVCall, PendSV and SysTick, and on ARMv7-M MemManage,
   --  BusFault, UsageFault and DebugMonitor.  Slots 0 and 1 are the
   --  compiler's initial SP and reset.
   function Core_Slot (Core : Core_Kind; Slot : Natural) return Boolean
     is (Slot in 2 | 3 | 11 | 14 | 15
         or else (not Is_Armv6_M (Core) and then Slot in 4 .. 6 | 12));

   --  D545's closed set.  The last two are reserved names: a description
   --  that selects one is refused until the compiler builds that image.
   type Boot_Kind is
     (Vector_Table, RP2040_Boot2, RP2350_Image_Block, ESP_App_Image);
   function Is_Boot_Name (Text : String) return Boolean;
   function Boot_Named (Text : String) return Boot_Kind
     with Pre => Is_Boot_Name (Text);
   function Spelling (Boot : Boot_Kind) return String;
   function Implemented (Boot : Boot_Kind) return Boolean
     is (Boot in Vector_Table | RP2040_Boot2);
   --  The bytes a boot kind reserves at the start of the vectors' region,
   --  before the vector table: RP2040's 256-byte second stage.
   function Boot_Prefix (Boot : Boot_Kind) return Byte_Count
     is (if Boot = RP2040_Boot2 then 256 else 0);

   type Section_Kind is (Vectors, Text, Rodata, Data, BSS, Stack);
   function Is_Section_Name (Word : String) return Boolean;
   function Section_Named (Word : String) return Section_Kind
     with Pre => Is_Section_Name (Word);
   function Spelling (Section : Section_Kind) return String;

   type Access_Kind is (Read_Execute, Read_Write, Read_Write_Execute);
   function Is_Access_Name (Text : String) return Boolean
     is (Text in "rx" | "rw" | "rwx");
   function Access_Named (Text : String) return Access_Kind
     with Pre => Is_Access_Name (Text);
   function Spelling (Mode : Access_Kind) return String
     is (case Mode is
           when Read_Execute => "rx",
           when Read_Write => "rw",
           when Read_Write_Execute => "rwx");
   function Writable (Mode : Access_Kind) return Boolean
     is (Mode /= Read_Execute);
   function Executable (Mode : Access_Kind) return Boolean
     is (Mode /= Read_Write);

   Region_Capacity : constant := 16;
   subtype Region_Count is Natural range 0 .. Region_Capacity;
   subtype Region_Index is Region_Count range 1 .. Region_Capacity;
   type Region is record
      Name : Name_Text;
      Origin, Length : Byte_Count := 0;
      Mode : Access_Kind := Read_Execute;
   end record;
   type Region_Array is array (Region_Index) of Region;

   Slot_Capacity : constant := 512;
   type Slot_Set is array (0 .. Slot_Capacity - 1) of Boolean
     with Pack;
   type Placements is array (Section_Kind) of Region_Count;

   type Profile is record
      --  False until configuration has selected a description.
      Present : Boolean := False;
      --  The library's constrained reference, platform/cortex_m/reference,
      --  which applies at every level of the Cortex-M target (D543).
      Reference : Boolean := False;
      Device : Name_Text;
      Core : Core_Kind := Cortex_M0;
      Vector_Count : Natural := 0;
      --  Slot 16 + n for each implemented external interrupt n.
      Interrupts : Slot_Set := [others => False];
      Boot : Boot_Kind := Vector_Table;
      Regions : Region_Array;
      Count : Region_Count := 0;
      Placed : Placements := [others => 0];
      Stack_Size : Byte_Count := 0;
   end record;

   --  Whether a handler may take absolute slot SLOT: a core slot of the
   --  description's core or an implemented interrupt, below its count.
   function Admits (Of_Profile : Profile; Slot : Natural) return Boolean
     is (Of_Profile.Present and then Slot < Of_Profile.Vector_Count
         and then (Core_Slot (Of_Profile.Core, Slot)
                   or else (Slot >= 16 and then Slot < Slot_Capacity
                            and then Of_Profile.Interrupts (Slot))));

   --  0 when no region has the name.
   function Region_Named
     (Of_Profile : Profile; Name : String) return Region_Count;

   function Placed_Region
     (Of_Profile : Profile; Section : Section_Kind) return Region
     with Pre => Of_Profile.Placed (Section) /= 0;

   --  The vector table's bytes and its alignment: its length rounded up to
   --  a power of two, and no less than 128, which ARMv7-M's VTOR needs.
   function Vector_Bytes (Of_Profile : Profile) return Byte_Count
     is (Byte_Count (Of_Profile.Vector_Count) * 4);
   function Vector_Alignment (Of_Profile : Profile) return Byte_Count;
   --  Where the table is: its region's origin past the boot kind's prefix.
   function Vector_Address (Of_Profile : Profile) return Byte_Count
     with Pre => Of_Profile.Placed (Vectors) /= 0;

   --  The flash an image may use and the RAM static data may use: the
   --  text region's length, and the data region's less the stack when the
   --  stack shares it.
   function Flash_Capacity (Of_Profile : Profile) return Byte_Count;
   function Static_RAM_Capacity (Of_Profile : Profile) return Byte_Count;

   function Assembly_Error
     (Text : String; Naked : Boolean;
      Level : Landin.Targets.Levels.Feature_Level) return String;

private
   type Name_Text is record
      Length : Natural range 0 .. Name_Capacity := 0;
      Text : String (1 .. Name_Capacity) := [others => ' '];
   end record;
end Landin.Targets.Firmware;
