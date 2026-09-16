package body Landin.Targets.Capabilities is

   function C_Signatures (Facts : Target_Facts) return Boolean is
     (case C_ABI_Of (Facts) is
         when SysV_AMD64_LP64 | Darwin_AAPCS64_LP64 => True,
         when No_C_ABI | Arm_AAPCS32_Soft => False);

   function C_Records (Facts : Target_Facts) return Boolean is
     (case C_ABI_Of (Facts) is
         when SysV_AMD64_LP64 | Darwin_AAPCS64_LP64 => True,
         when No_C_ABI | Arm_AAPCS32_Soft => False);

   function C_Variadic_Calls (Facts : Target_Facts) return Boolean is
     (case C_ABI_Of (Facts) is
         when SysV_AMD64_LP64 | Darwin_AAPCS64_LP64 => True,
         when No_C_ABI | Arm_AAPCS32_Soft => False);

   function Object_Format_Of (Facts : Target_Facts) return Object_Format is
   begin
      if Facts = Linux_X86_64 then
         return ELF;
      elsif Facts = Darwin_Arm64 then
         return Mach_O;
      elsif Facts = Synthetic_32 or else Facts = Cortex_M then
         return No_Object_Format;
      else
         raise Compiler_Defect with "target has no stated object format";
      end if;
   end Object_Format_Of;

   function Debug_Format_Of (Facts : Target_Facts) return Debug_Format is
     (case Backend_For (Facts) is
         when Linux_X86_64_ELF => ELF_DWARF,
         when Darwin_Arm64_Mach_O => Mach_O_DWARF,
         when No_Backend => No_Debug_Format);

   function Link_Symbol (Facts : Target_Facts; Name : String) return String is
   begin
      if Name = "" then
         raise Compiler_Defect with "an external symbol is empty";
      end if;
      case Object_Format_Of (Facts) is
         when ELF => return Name;
         when Mach_O => return "_" & Name;
         when No_Object_Format =>
            raise Compiler_Defect with "target has no object symbol spelling";
      end case;
   end Link_Symbol;

   function Backend_For (Facts : Target_Facts) return Backend_Kind is
   begin
      if Facts = Linux_X86_64 then
         return Linux_X86_64_ELF;
      elsif Facts = Darwin_Arm64 then
         return Darwin_Arm64_Mach_O;
      elsif Facts = Synthetic_32 or else Facts = Cortex_M then
         return No_Backend;
      else
         raise Compiler_Defect
           with "target has no stated backend capability";
      end if;
   end Backend_For;

   function Triplet (Facts : Target_Facts) return String is
   begin
      if Facts = Linux_X86_64 then
         return "x86_64-pc-linux-gnu";
      elsif Facts = Darwin_Arm64 then
         return "arm64-apple-darwin";
      elsif Facts = Synthetic_32 or else Facts = Cortex_M then
         return "";
      else
         raise Compiler_Defect
           with "target has no stated toolchain triplet";
      end if;
   end Triplet;

end Landin.Targets.Capabilities;
