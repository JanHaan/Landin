package body Landin.Targets.Capabilities is

   function Memory_Access
     (Facts : Target_Facts; Op : Landin.Memory.Operation;
      Width : Scalar_Size) return Boolean
   is
      use all type Landin.Memory.Operation;
   begin
      if Op = No_Operation or else Width = Byte_16 then
         return False;
      end if;
      case Architecture_Of (Facts) is
         when X86_64 | Arm64 | RV64 =>
            return True;
         when Cortex_M0 =>
            return Width /= Byte_8
              and then Op not in Atomic_Exchange | Atomic_Add
                | Atomic_Compare_Exchange;
         when Synthetic_32_Architecture =>
            return False;
      end case;
   end Memory_Access;


   function C_Signatures (Facts : Target_Facts) return Boolean is
     (case C_ABI_Of (Facts) is
         when SysV_AMD64_LP64 | Darwin_AAPCS64_LP64 | AAPCS64_LP64
            | RiscV_LP64D => True,
         when No_C_ABI | Arm_AAPCS32_Soft => False);

   function C_Records (Facts : Target_Facts) return Boolean is
     (case C_ABI_Of (Facts) is
         when SysV_AMD64_LP64 | Darwin_AAPCS64_LP64 | AAPCS64_LP64
            | RiscV_LP64D => True,
         when No_C_ABI | Arm_AAPCS32_Soft => False);

   function C_Variadic_Calls (Facts : Target_Facts) return Boolean is
     (case C_ABI_Of (Facts) is
         when SysV_AMD64_LP64 | Darwin_AAPCS64_LP64 | AAPCS64_LP64
            | RiscV_LP64D => True,
         when No_C_ABI | Arm_AAPCS32_Soft => False);

   function Object_Format_Of (Facts : Target_Facts) return Object_Format is
   begin
      if Facts = Linux_X86_64 or else Facts = FreeBSD_X86_64 then
         return ELF;
      elsif Facts = Darwin_Arm64 then
         return Mach_O;
      elsif Facts = Linux_Arm64 or else Facts = FreeBSD_Arm64 then
         return ELF;
      elsif Facts = Linux_RV64 or else Facts = Cortex_M then
         return ELF;
      elsif Facts = Synthetic_32 then
         return No_Object_Format;
      else
         raise Compiler_Defect with "target has no stated object format";
      end if;
   end Object_Format_Of;

   function Debug_Format_Of (Facts : Target_Facts) return Debug_Format is
     (case Backend_For (Facts) is
         when X86_64_ELF => ELF_DWARF,
         when Darwin_Arm64_Mach_O => Mach_O_DWARF,
         when Arm64_ELF | RV64_ELF => ELF_DWARF,
         when Cortex_M0_ELF => ELF_DWARF_Lines,
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
      if Facts = Linux_X86_64 or else Facts = FreeBSD_X86_64 then
         return X86_64_ELF;
      elsif Facts = Darwin_Arm64 then
         return Darwin_Arm64_Mach_O;
      elsif Facts = Linux_Arm64 or else Facts = FreeBSD_Arm64 then
         return Arm64_ELF;
      elsif Facts = Linux_RV64 then
         return RV64_ELF;
      elsif Facts = Cortex_M then
         return Cortex_M0_ELF;
      elsif Facts = Synthetic_32 then
         return No_Backend;
      else
         raise Compiler_Defect
           with "target has no stated backend capability";
      end if;
   end Backend_For;

   function Hosted_System_Of (Facts : Target_Facts) return Hosted_System is
   begin
      if Facts = Linux_X86_64 or else Facts = Linux_Arm64
        or else Facts = Linux_RV64
      then
         return Linux;
      elsif Facts = Darwin_Arm64 then
         return Darwin;
      elsif Facts = FreeBSD_X86_64 or else Facts = FreeBSD_Arm64 then
         return FreeBSD;
      else
         return No_Hosted_System;
      end if;
   end Hosted_System_Of;

   function Triplet (Facts : Target_Facts) return String is
   begin
      if Facts = FreeBSD_X86_64 then
         return "x86_64-unknown-freebsd14.4";
      elsif Facts = FreeBSD_Arm64 then
         return "aarch64-unknown-freebsd14.4";
      elsif Facts = Linux_X86_64 then
         return "x86_64-pc-linux-gnu";
      elsif Facts = Darwin_Arm64 then
         return "arm64-apple-darwin";
      elsif Facts = Linux_Arm64 then
         return "aarch64-linux-gnu";
      elsif Facts = Linux_RV64 then
         return "riscv64-linux-gnu";
      elsif Facts = Cortex_M then
         return "arm-none-eabi";
      elsif Facts = Synthetic_32 then
         return "";
      else
         raise Compiler_Defect
           with "target has no stated toolchain triplet";
      end if;
   end Triplet;

end Landin.Targets.Capabilities;
