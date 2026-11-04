--  Firmware profiles, in target bytes, and source assembly admission.
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

   --  D543: the library module that describes a firmware target's
   --  constrained reference profile, which a program on that target that
   --  reaches no other description is given: platform/cortex_m/reference
   --  on Cortex-M and platform/riscv/reference on RV32 (D661).  "" on a
   --  target that is not firmware.
   function Reference_Module (Facts : Target_Facts) return String
     is (case Architecture_Of (Facts) is
           when Cortex_M0 => "platform/cortex_m/reference",
           when RV32 => "platform/riscv/reference",
           when Xtensa => "platform/xtensa/reference",
           when others => "");

   --  Whether LOGICAL is a reference description of any target.
   function Is_Reference_Module (Logical : String) return Boolean
     is (Logical in "platform/cortex_m/reference"
                  | "platform/riscv/reference"
                  | "platform/xtensa/reference");

   --  A description's name: a device, a region or an interrupt.
   Name_Capacity : constant := 64;
   type Name_Text is private;
   function To_Name (Text : String) return Name_Text
     with Pre => Text'Length <= Name_Capacity;
   function Spelling (Name : Name_Text) return String;

   --  The ten cores a description may name, each with its family, the
   --  target that executes it, and its level (D543, D662).
   type Core_Kind is
     (Cortex_M0, Cortex_M0plus, Cortex_M3, Cortex_M4, Cortex_M7, Cortex_M33,
      Hazard3, SiFive_E31, ESP_RV32IMC, ESP_RV32IMAC_CLIC,
      Xtensa_LX6, Xtensa_LX7);
   subtype Arm_Core is Core_Kind range Cortex_M0 .. Cortex_M33;
   subtype RISC_V_Core is Core_Kind range Hazard3 .. ESP_RV32IMAC_CLIC;
   subtype Xtensa_Core is Core_Kind range Xtensa_LX6 .. Xtensa_LX7;
   function Is_Core_Name (Text : String) return Boolean;
   function Core_Named (Text : String) return Core_Kind
     with Pre => Is_Core_Name (Text);
   function Spelling (Core : Core_Kind) return String;
   --  The core with its article, as a sentence names it: "a cortex-m0",
   --  "an esp-rv32imc".
   function A_Core (Core : Core_Kind) return String
     is ((if Core in ESP_RV32IMC | ESP_RV32IMAC_CLIC | Xtensa_Core
          then "an " else "a ")
         & Spelling (Core));
   --  Every core's spelling, quoted, as a note lists them.
   function Core_Names return String;
   --  D542: the `cpu/name` an SVD gives CORE, from which `refine svd`
   --  writes `compiler.core`: an Arm core's CMSIS name, and "" for a
   --  RISC-V core, which no SVD the importer reads names, so its policy
   --  names it instead.  The importer reads this table and keeps none of
   --  its own.
   function Svd_Name (Core : Core_Kind) return String
     is (case Core is
           when Cortex_M0 => "CM0",
           when Cortex_M0plus => "CM0PLUS",
           when Cortex_M3 => "CM3",
           when Cortex_M4 => "CM4",
           when Cortex_M7 => "CM7",
           when Cortex_M33 => "CM33",
           when Xtensa_LX6 => "Xtensa LX6",
           when Xtensa_LX7 => "Xtensa LX7",
           when RISC_V_Core => "");
   function Is_Svd_Name (Text : String) return Boolean
     is (Text /= "" and then (for some Core in Core_Kind =>
                                Svd_Name (Core) = Text));
   function Core_Of_Svd (Text : String) return Core_Kind
     with Pre => Is_Svd_Name (Text);
   --  Every SVD name, as a refusal lists them: "CM0, ... and CM33".
   function Svd_Names return String;
   --  The target architecture whose builds run on CORE.
   function Family (Core : Core_Kind) return Architecture
     is (if Core in RISC_V_Core then RV32
         elsif Core in Xtensa_Core then Xtensa else Cortex_M0);
   --  ELF's e_machine identity for an image of this core.
   function ELF_Machine (Core : Core_Kind) return Positive
     is (if Core in Xtensa_Core then 94
         elsif Core in RISC_V_Core then 243 else 40);
   --  The feature level a core executes, as Landin.Targets.Levels names it.
   function Level_Name (Core : Core_Kind) return String;
   --  D543: whether a build at LEVEL runs on CORE: the core's own level or
   --  one it holds, armv6-m on every Arm core, armv7-m on every Thumb-2
   --  one, and rv32imc on every RISC-V one.
   function Executes (Core : Core_Kind; Level : String) return Boolean;
   --  The levels Executes admits for CORE, as a note lists them.
   function Lower_Levels (Core : Core_Kind) return String;
   function Is_Armv6_M (Core : Core_Kind) return Boolean
     is (Core in Cortex_M0 | Cortex_M0plus);

   --  D662: how the core takes an interrupt, which decides what a slot is.
   --  On the NVIC a slot is a word of the vector table, 16 + n for
   --  external interrupt n.  On RISC-V a slot is the mcause interrupt code:
   --  mtvec's vectored mode on the ESP32-C3's core and the SiFive E31,
   --  ESP32-C5's CLIC, and Hazard3's Xh3irq, whose external interrupts
   --  all arrive as code 11 and are resolved through meinext into slot
   --  16 + IRQ.
   type Interrupt_Model is (NVIC, Vectored, CLIC, Xh3irq, Xtensa_Interrupts);
   function Model_Of (Core : Core_Kind) return Interrupt_Model
     is (case Core is
           when Arm_Core => NVIC,
           when Hazard3 => Xh3irq,
           when SiFive_E31 | ESP_RV32IMC => Vectored,
           when ESP_RV32IMAC_CLIC => CLIC,
           when Xtensa_Core => Xtensa_Interrupts);
   --  Whether a description's interrupt n is slot 16 + n.  Under vectored
   --  mtvec and the CLIC a description names a peripheral source, which
   --  an interrupt matrix or a PLIC routes to a CPU line, and only the
   --  line is a slot (D662).
   function Interrupts_Are_Slots (Core : Core_Kind) return Boolean
     is (Model_Of (Core) in NVIC | Xh3irq);

   --  The pinned chip configuration's CPU lines at an interrupt level.
   --  Xtensa's level seven is the NMI; ordinary dispatch uses levels one
   --  through six and only lines whose INTENABLE bit is set.
   function Interrupt_Level_Mask
     (Core : Core_Kind; Level : Positive) return Byte_Count
     with Pre => Core in Xtensa_Core and then Level <= 7;

   --  The longest vector table the core's architecture allows, in slots:
   --  ARMv6-M's 16 + 32, ARMv7-M's 16 + 496 and ARMv8-M's 16 + 480; the
   --  sixteen standard interrupt codes of the SiFive E31, the C3's 32
   --  CPU lines, the C5's CLIC's 16 + 32, and on Hazard3 the slot set's
   --  capacity, 16 + 496 of Xh3irq's 512 IRQs (D662).
   function Vector_Limit (Core : Core_Kind) return Positive
     is (case Core is
           when Cortex_M0 | Cortex_M0plus => 48,
           when Cortex_M33 => 496,
           when Cortex_M3 | Cortex_M4 | Cortex_M7 => 512,
           when SiFive_E31 => 16,
           when ESP_RV32IMC => 32,
           when Xtensa_Core => 32,
           when ESP_RV32IMAC_CLIC => 48,
           when Hazard3 => 512);
   --  The core's own slots a handler may take.  On the NVIC the
   --  architecture's exceptions: NMI, HardFault, SVCall, PendSV and
   --  SysTick, on ARMv7-M MemManage, BusFault, UsageFault and
   --  DebugMonitor, and on a cortex-m33 the SecureFault its Security
   --  Extension raises; slots 0 and 1 are the compiler's initial SP and
   --  reset.  On RISC-V the interrupt codes the core raises itself (D662):
   --  the machine software, timer and external interrupts, 3, 7 and 11,
   --  on the E31; Hazard3's 3 and 7, its 11 being meinext's dispatch; the
   --  C3's CPU lines 1 to 31; the C5's CLIC's lines 0 to 31 at ids 16 to
   --  47.  No exception takes a slot.
   function Core_Slot (Core : Core_Kind; Slot : Natural) return Boolean
     is (case Core is
           when Arm_Core =>
              Slot in 2 | 3 | 11 | 14 | 15
              or else (not Is_Armv6_M (Core) and then Slot in 4 .. 6 | 12)
              or else (Core = Cortex_M33 and then Slot = 7),
           when SiFive_E31 => Slot in 3 | 7 | 11,
           when Hazard3 => Slot in 3 | 7,
           when ESP_RV32IMC => Slot in 1 .. 31,
           when Xtensa_Core => Slot in 0 .. 31 and then Slot /= 14,
           when ESP_RV32IMAC_CLIC => Slot in 16 .. 47);
   --  Core_Slot's slots as a note names them.
   function Core_Slots_Text (Core : Core_Kind) return String
     is (case Core is
           when Cortex_M0 | Cortex_M0plus =>
              "core slots 2, 3, 11, 14 and 15",
           when Cortex_M3 | Cortex_M4 | Cortex_M7 =>
              "core slots 2 to 6, 11, 12, 14 and 15",
           when Cortex_M33 => "core slots 2 to 7, 11, 12, 14 and 15",
           when SiFive_E31 => "interrupt codes 3, 7 and 11",
           when Hazard3 => "interrupt codes 3 and 7",
           when ESP_RV32IMC => "CPU lines 1 to 31",
           when Xtensa_Core => "CPU lines 0 to 13 and 15 to 31",
           when ESP_RV32IMAC_CLIC => "CLIC ids 16 to 47");

   --  D615: a float unit is a fact of a description, not of a level, since
   --  the unit a chip was built with changes the C ABI.  The compiler knows
   --  which unit each core may have and names no chip; it builds one,
   --  FPv5-D16, the Cortex-M7's single- and double-precision FPv5 with
   --  sixteen double registers, which needs Armv7E-M.
   type Float_Unit is (No_Float_Unit, FPv5_D16);
   function Is_Float_Unit_Name (Text : String) return Boolean
     is (Text = "fpv5-d16");
   function Float_Unit_Named (Text : String) return Float_Unit
     with Pre => Is_Float_Unit_Name (Text);
   function Spelling (Unit : Float_Unit) return String
     is (case Unit is
           when No_Float_Unit => "none",
           when FPv5_D16 => "fpv5-d16");
   --  Whether CORE may have UNIT, and the units it may have, as a note
   --  says them.
   function May_Have (Core : Core_Kind; Unit : Float_Unit) return Boolean
     is (Unit = No_Float_Unit
         or else (Core = Cortex_M7 and then Unit = FPv5_D16));
   function Float_Units_Of (Core : Core_Kind) return String
     is (if Core = Cortex_M7 then """fpv5-d16""" else "none");
   --  The one level whose architecture holds UNIT's instructions.
   function Float_Level (Unit : Float_Unit) return String
     is (if Unit = No_Float_Unit then "armv6-m" else "armv7e-m");
   --  `compiler.feature.fp` and `compiler.feature.fp_dp` (D615): whether
   --  the unit has single, and double, precision.  No level holds either,
   --  so they are false on every target without a description's unit.
   function Is_Float_Feature_Name (Word : String) return Boolean
     is (Word in "fp" | "fp_dp");
   function Single_Precision (Unit : Float_Unit) return Boolean
     is (Unit /= No_Float_Unit);
   function Double_Precision (Unit : Float_Unit) return Boolean
     is (Unit = FPv5_D16);

   --  D680: whether the core's own dispatch, rather than the hardware,
   --  enters SLOT: every slot under the CLIC, whose common entry reads
   --  mcause, and on Hazard3 every slot from 16, which meinext names.  A
   --  dispatched slot calls its handler as a routine, so it takes an
   --  interrupt routine and no naked one.  Under the CLIC the hardware
   --  enters a slot too, through mtvt's table to a stub, when the program
   --  sets its interrupt's shv (D830).
   function Dispatched_Slot (Core : Core_Kind; Slot : Natural) return Boolean
     is (case Model_Of (Core) is
           when CLIC => True,
           when Xtensa_Interrupts => True,
           when Xh3irq => Slot >= 16,
           when NVIC | Vectored => False);

   --  D545's closed set.  Every kind is built: `esp-app-image` since
   --  D683, which ended its reservation (L0516).
   type Boot_Kind is
     (Vector_Table, RP2040_Boot2, RP2350_Image_Block, ESP_App_Image);
   function Is_Boot_Name (Text : String) return Boolean;
   function Boot_Named (Text : String) return Boot_Kind
     with Pre => Is_Boot_Name (Text);
   function Spelling (Boot : Boot_Kind) return String;
   --  D681: whether CORE's family boots BOOT: `rp2040-boot2`'s second
   --  stage is Thumb code and `esp-app-image` is an RV32 ESP32's.
   function Boots (Core : Core_Kind; Boot : Boot_Kind) return Boolean
     is (case Boot is
           when Vector_Table => True,
           when RP2350_Image_Block => Core in Arm_Core | RISC_V_Core,
           when RP2040_Boot2 => Core in Arm_Core,
           when ESP_App_Image => Core in RISC_V_Core | Xtensa_Core);
   --  The bytes a boot kind reserves at the start of the vectors' region,
   --  before the vector table: RP2040's 256-byte second stage.
   function Boot_Prefix (Boot : Boot_Kind) return Byte_Count
     is (if Boot = RP2040_Boot2 then 256 else 0);

   --  D587/D588: whether a boot kind's image begins with a second stage
   --  the description supplies, as a `link(boot_stage)` naked routine.
   --  RP2040's boot ROM copies the first Stage_Slot bytes of flash to
   --  SRAM, checks a CRC-32 over the first Stage_Limit and enters the copy
   --  at its first byte; the last four bytes are that CRC, little-endian.
   function Takes_Stage (Boot : Boot_Kind) return Boolean
     is (Boot = RP2040_Boot2);

   --  D653: a boot kind whose description may hold a stage, which
   --  RP2040's requires; and one whose stage, when it holds one, the reset
   --  vector enters before compiler-owned reset writes any memory.  Such a
   --  stage runs on the stack pointer the core loads from the table, may
   --  use neither the stack nor RAM, and ends by branching to
   --  Reset_Symbol; the table's reset word is Reset_Stage_Symbol.
   --  D684: an `esp-app-image` description may hold one too, which the
   --  entry word enters before reset, as the ESP32s' watchdogs need.
   function Admits_Stage (Boot : Boot_Kind) return Boolean
     is (Boot in RP2040_Boot2 | Vector_Table | ESP_App_Image);
   function Stage_Before_Reset (Boot : Boot_Kind) return Boolean
     is (Boot in Vector_Table | ESP_App_Image);
   Reset_Symbol : constant String := "_landin_firmware_reset";
   Reset_Stage_Symbol : constant String := "_landin_firmware_reset_stage";

   --  D672: the libgcc helpers RV32's emitter calls for soft float and
   --  64-bit division, which no program's symbol may take, as Cortex-M0's
   --  `__aeabi_` ones are reserved.
   function Is_RV32_Helper (Name : String) return Boolean;
   Stage_Slot : constant := 256;
   Stage_Limit : constant := 252;

   --  The boot ROM's CRC-32 over BYTES: polynomial 16#04C1_1DB7#, initial
   --  value all ones, neither input nor output reflected and no final
   --  exclusive or, which is CRC-32/MPEG-2.
   type Checksum is mod 2 ** 32;
   function Stage_Checksum (Bytes : String) return Checksum;

   --  D637: whether a boot kind's image carries an IMAGE_DEF block, the
   --  metadata RP2350's boot ROM searches the first Image_Block_Window
   --  bytes of flash for.  The backend emits it directly after the vector
   --  table in a section of its own, `.embedded_block`, as pico-sdk names
   --  it, and the driver reads it back from the assembled object (D638).
   --  It is one block linked to itself: the start marker; an IMAGE_TYPE
   --  item, type 16#42# and one word, whose value 16#1021# is an
   --  executable that runs in Secure state, for Arm, for RP2350; the LAST
   --  item, type 16#FF#, giving the other items' one word; the link, 0,
   --  to itself; and the end marker.  It has no hash and no signature.
   function Takes_Image_Block (Boot : Boot_Kind) return Boolean
     is (Boot = RP2350_Image_Block);
   type Block_Word is mod 2 ** 32;
   type Block_Words is array (1 .. 5) of Block_Word;
   Image_Block : constant Block_Words :=
     [16#FFFF_DED3#, 16#1021_0142#, 16#0000_01FF#, 0, 16#AB12_3579#];
   --  D682: on rv32 the image type is 16#1101#, an executable for
   --  RISC-V, for RP2350, of no stated security, as the boot ROM runs
   --  Hazard3's images; the other words are the Arm block's.
   RISC_V_Image_Block : constant Block_Words :=
     [16#FFFF_DED3#, 16#1101_0142#, 16#0000_01FF#, 0, 16#AB12_3579#];
   function Image_Block_Of (Core : Core_Kind) return Block_Words
     is (if Core in RISC_V_Core then RISC_V_Image_Block else Image_Block);
   Image_Block_Bytes : constant := 20;
   Image_Block_Window : constant := 4096;
   --  The bytes a boot kind places directly after the vector table, in
   --  the same region: RP2350's IMAGE_DEF block.  With Boot_Prefix, what
   --  the build report says of the kind's layout (D545), so a harness
   --  linking its own start learns it there.
   function Boot_Suffix (Boot : Boot_Kind) return Byte_Count
     is (if Takes_Image_Block (Boot) then Image_Block_Bytes else 0);
   --  "" when BYTES are that block, word for word; otherwise what in them
   --  is not, by the part of the block it is in.
   function Image_Block_Fault
     (Bytes : String; Core : Core_Kind := Cortex_M33) return String;

   --  D683: an `esp-app-image` is what an ESP32's ROM loads from flash
   --  with no second stage: the 0xE9 header, the extended header naming
   --  the chip and the revisions it runs on, each segment as its load
   --  address, its length and its bytes, the XOR of every segment byte
   --  seeded 0xEF in the last byte of a 16-byte boundary, then the
   --  SHA-256 of all of that.  The chip's facts are the description's
   --  `compiler.esp_image`; the image and its rules are the boot kind's.
   function Takes_ESP_Image (Boot : Boot_Kind) return Boolean
     is (Boot = ESP_App_Image);
   ESP_Magic : constant := 16#E9#;
   ESP_Checksum_Seed : constant := 16#EF#;
   ESP_Header_Bytes : constant := 24;
   ESP_Segment_Limit : constant := 16;
   --  The header's flash mode, DIO, and its size and frequency byte, 4 MB
   --  at 40 MHz: what the ROMs booted the first RAM-only images with.
   --  Neither reads them to load a RAM image.
   ESP_Flash_Mode : constant := 2;
   ESP_Flash_Size_Frequency : constant := 16#20#;
   --  The extended header's write-protect pin byte: 0xEE, none.
   ESP_No_WP_Pin : constant := 16#EE#;
   subtype ESP_Number is Natural range 0 .. 65_535;
   ESP_Offset_Alignment : constant := 4096;

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

   type Layout_Kind is (Boot_Layout, RAM_Layout);
   function Spelling (Layout : Layout_Kind) return String
     is (if Layout = RAM_Layout then "ram" else "boot");

   type Profile is record
      Layout : Layout_Kind := Boot_Layout;
      Described_Boot : Boot_Kind := Vector_Table;
      --  False until configuration has selected a description.
      Present : Boolean := False;
      --  The library's constrained reference of the target, which applies
      --  at every level of it (D543).
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
      --  D587: whether the description holds its boot kind's second
      --  stage, which configuration requires exactly when Takes_Stage.
      Has_Stage : Boolean := False;
      --  D615: the description's float unit, `compiler.float_unit`.
      Float : Float_Unit := No_Float_Unit;
      --  D683: `compiler.esp_image`'s chip id, the full minimum and
      --  maximum revisions, major * 100 + minor, and the flash offset
      --  the ROM reads the image at.
      ESP_Chip, ESP_Minimum, ESP_Maximum : ESP_Number := 0;
      ESP_Offset : Byte_Count := 0;
   end record;

   --  D900: select one layout after validating the description. ESP SRAM
   --  retains its instruction window; otherwise prefer executable data,
   --  then writable text, then the first rwx region. Zero means none.
   function RAM_Text_Region (Of_Profile : Profile) return Region_Count;
   function For_Layout
     (Of_Profile : Profile; Layout : Layout_Kind) return Profile;
   function RAM_Only (Of_Profile : Profile) return Boolean
     is (Of_Profile.Layout = RAM_Layout
         or else Takes_ESP_Image (Of_Profile.Boot));
   function RAM_Region (Of_Profile : Profile; Index : Region_Index)
      return Boolean
     is (Writable (Of_Profile.Regions (Index).Mode)
         or else (Of_Profile.Described_Boot = ESP_App_Image
                  and then Index = Of_Profile.Placed (Text)));

   --  Whether a handler may take absolute slot SLOT: a core slot of the
   --  description's core or, where interrupts are slots, an implemented
   --  interrupt, below its count.
   function Admits (Of_Profile : Profile; Slot : Natural) return Boolean
     is (Of_Profile.Present and then Slot < Of_Profile.Vector_Count
         and then (Core_Slot (Of_Profile.Core, Slot)
                   or else (Interrupts_Are_Slots (Of_Profile.Core)
                            and then Slot >= 16 and then Slot < Slot_Capacity
                            and then Of_Profile.Interrupts (Slot))));

   --  0 when no region has the name.
   function Region_Named
     (Of_Profile : Profile; Name : String) return Region_Count;

   function Placed_Region
     (Of_Profile : Profile; Section : Section_Kind) return Region
     with Pre => Of_Profile.Placed (Section) /= 0;

   --  The vector table's bytes and its alignment: its length rounded up to
   --  a power of two, and no less than 128, which ARMv7-M's VTOR needs; on
   --  RISC-V no less than what the core's mtvec or mtvt needs (D662): 64
   --  bytes on the E31 and Hazard3 and under the CLIC, and 256 on the
   --  ESP32-C3, whose ESP-IDF aligns its table so.
   function Vector_Bytes (Of_Profile : Profile) return Byte_Count
     is (if Of_Profile.Core in Xtensa_Core then 1024
         else Byte_Count (Of_Profile.Vector_Count) * 4);
   function Vector_Alignment (Of_Profile : Profile) return Byte_Count;
   --  D662: a RISC-V image begins with one word, the jump to reset that a
   --  boot ROM or reset vector enters, `_landin_firmware_entry`.
   Entry_Word_Bytes : constant := 4;
   --  Where the table is: on the M profile its region's origin past the
   --  boot kind's prefix, aligned up for RAM, and on RISC-V past that and the
   --  entry word aligned as the table must be: 64 bytes in on the
   --  reference.
   function Vector_Address (Of_Profile : Profile) return Byte_Count
     with Pre => Of_Profile.Placed (Vectors) /= 0;

   --  D688: the region RAM code, `.ramtext`, runs in, or 0 when the
   --  profile has none.  An `esp-app-image`'s text region is RAM the ROM
   --  loads, so its RAM code is placed with its text and nothing is
   --  copied; otherwise the data region, when code may run there, which
   --  reset copies it into; otherwise none.
   function RAM_Code_Region (Of_Profile : Profile) return Region_Count
     is (if RAM_Only (Of_Profile)
         then Of_Profile.Placed (Text)
         elsif Of_Profile.Placed (Data) /= 0
           and then Executable
             (Of_Profile.Regions (Of_Profile.Placed (Data)).Mode)
         then Of_Profile.Placed (Data)
         else 0);

   --  The flash an image may use and the RAM static data may use: the
   --  text region's length, and the data region's less the stack when the
   --  stack shares it.
   function Flash_Capacity (Of_Profile : Profile) return Byte_Count;
   function RAM_Capacity (Of_Profile : Profile) return Byte_Count;
   function Static_RAM_Capacity (Of_Profile : Profile) return Byte_Count;

   --  D537: a profile's capacities as the image budget takes them.  The
   --  text region holds every written image and the data region every
   --  mutable one, which reset copies there; zero images are bounded by
   --  the 32-bit address space, and the linker places them in the RAM
   --  left over.  For the reference: 32 KiB and 16 KiB.
   function Budget (Of_Profile : Profile) return Image_Budget;

   --  The profile as a refusal names it, after the target's name: the
   --  "constrained reference profile", or "rp2040 profile".
   function Profile_Name (Of_Profile : Profile) return String;

   --  [1990]'s Cortex-M text rules over a block's written text, or the
   --  empty string.  Its `@` comments are removed first (D597), and each
   --  `{name}` slot reads as a register of r0-r7.
   function Assembly_Error
     (Text : String; Naked : Boolean;
      Level : Landin.Targets.Levels.Feature_Level) return String;

private
   type Name_Text is record
      Length : Natural range 0 .. Name_Capacity := 0;
      Text : String (1 .. Name_Capacity) := [others => ' '];
   end record;
end Landin.Targets.Firmware;
