--  What arm64 assembly spells differently per object format.
--
--  Instruction selection is the same on every arm64 target; the text
--  around the instructions is not.  Mach-O names a page and its offset with
--  `@PAGE` and `@PAGEOFF`, ELF with `:lo12:`; Mach-O fills zeros with
--  `.zerofill` into a named section, ELF with `.zero` in `.bss`; Mach-O
--  wants `.subsections_via_symbols` and ELF a non-executable stack note.
--  Each function here returns the directive or operand text alone, and the
--  backend writes it with its own line discipline.  The operating system's
--  libc spellings are `Landin.Backend.Hosted_ABI`'s and the C transport is
--  `Landin.Backend.AAPCS64_ABI`'s; this is the object format only.

with Landin.Targets.Capabilities;

package Landin.Backend.Arm64.Platform is

   subtype Object_Format is Landin.Targets.Capabilities.Object_Format;

   use all type Landin.Targets.Capabilities.Object_Format;

   subtype Arm64_Format is Object_Format range
     Landin.Targets.Capabilities.ELF .. Landin.Targets.Capabilities.Mach_O;

   --  The seed a backend extends until no explicit link spelling begins
   --  with it.  ELF's `.L` stays out of the symbol table; on Mach-O every
   --  external name gains an underscore, so `L` cannot meet one.
   function Local_Prefix_Seed (Format : Arm64_Format) return String;

   --  The two operands of `adrp` and of the instruction that completes the
   --  address: the 4 KiB page holding NAME, and NAME's offset inside it.
   --  Imported names go through the global offset table, whose entry holds
   --  the address, so the second instruction is a load rather than an add.
   function Page (Format : Arm64_Format; Name : String; Imported : Boolean)
     return String;

   function Page_Offset
     (Format : Arm64_Format; Name : String; Imported : Boolean)
     return String;

   function Read_Only_Section (Format : Arm64_Format) return String;

   --  A table of code addresses: read-only once relocated.
   function Relocated_Read_Only_Section (Format : Arm64_Format) return String;

   --  Visibility for a bridge: linked against, never exported.
   function Private_Extern (Format : Arm64_Format; Symbol : String)
     return String;

   --  Directives that open and close a function or an object symbol.  Both
   --  are empty on Mach-O, which types and sizes nothing.
   function Begin_Function (Format : Arm64_Format; Symbol : String)
     return String;

   function End_Function (Format : Arm64_Format; Symbol : String)
     return String;

   function Begin_Object (Format : Arm64_Format; Symbol : String)
     return String;

   function End_Object
     (Format : Arm64_Format; Symbol : String; Bytes : String) return String;

   --  The last directive of the unit.
   function Trailer (Format : Arm64_Format) return String;

end Landin.Backend.Arm64.Platform;
