with Landin.Backend.ELF;

package body Landin.Backend.Arm64.Platform is

   package Spelling renames Landin.Backend.ELF;
   package Formats renames Landin.Targets.Capabilities;

   function Local_Prefix_Seed (Format : Arm64_Format) return String
     is (case Format is
            when Formats.ELF => Spelling.Local_Prefix,
            when Formats.Mach_O => "L");

   function Page (Format : Arm64_Format; Name : String; Imported : Boolean)
     return String
     is (case Format is
            when Formats.ELF => (if Imported then ":got:" & Name else Name),
            when Formats.Mach_O =>
               Name & (if Imported then "@GOTPAGE" else "@PAGE"));

   function Page_Offset
     (Format : Arm64_Format; Name : String; Imported : Boolean)
     return String
     is (case Format is
            when Formats.ELF =>
               (if Imported then ":got_lo12:" else ":lo12:") & Name,
            when Formats.Mach_O =>
               Name & (if Imported then "@GOTPAGEOFF" else "@PAGEOFF"));

   function Read_Only_Section (Format : Arm64_Format) return String
     is (case Format is
            when Formats.ELF => Spelling.Read_Only_Section,
            when Formats.Mach_O => ".section __TEXT,__const");

   function Relocated_Read_Only_Section (Format : Arm64_Format) return String
     is (case Format is
            when Formats.ELF => Spelling.Relocated_Read_Only_Section,
            when Formats.Mach_O => ".section __DATA_CONST,__const");

   function Private_Extern (Format : Arm64_Format; Symbol : String)
     return String
     is (case Format is
            when Formats.ELF => Spelling.Hidden (Symbol),
            when Formats.Mach_O => ".private_extern " & Symbol);

   function Begin_Function (Format : Arm64_Format; Symbol : String)
     return String
     is (case Format is
            when Formats.ELF => Spelling.Function_Type (Symbol),
            when Formats.Mach_O => "");

   function End_Function (Format : Arm64_Format; Symbol : String)
     return String
     is (case Format is
            when Formats.ELF => Spelling.Size_To_Here (Symbol),
            when Formats.Mach_O => "");

   function Begin_Object (Format : Arm64_Format; Symbol : String)
     return String
     is (case Format is
            when Formats.ELF => Spelling.Object_Type (Symbol),
            when Formats.Mach_O => "");

   function End_Object
     (Format : Arm64_Format; Symbol : String; Bytes : String) return String
     is (case Format is
            when Formats.ELF => Spelling.Size (Symbol, Bytes),
            when Formats.Mach_O => "");

   function Trailer (Format : Arm64_Format) return String
     is (case Format is
            when Formats.ELF => Spelling.No_Executable_Stack,
            when Formats.Mach_O => ".subsections_via_symbols");

end Landin.Backend.Arm64.Platform;
