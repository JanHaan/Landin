with Ada.Strings.Unbounded;

package body Landin.Targets.Capabilities is

   function Memory_Access
     (Facts : Target_Facts; Level : Landin.Targets.Levels.Feature_Level;
      Op : Landin.Memory.Operation; Width : Scalar_Size) return Boolean
   is
      use all type Landin.Memory.Operation;
   begin
      if Op in Landin.Memory.Stack_Operation then
         return Stack_Switching (Facts);
      elsif Op = No_Operation or else Width = Byte_16 then
         return False;
      end if;
      case Architecture_Of (Facts) is
         when X86_64 | Arm64 | RV64 =>
            return True;
         when Cortex_M0 | Xtensa =>
            --  ARMv6-M has no exclusive pair, and no Thumb-2 level's is
            --  lowered yet, so no level admits a read-modify-write.
            return Width /= Byte_8
              and then Op not in Atomic_Exchange | Atomic_Add
                | Atomic_Compare_Exchange;
         when RV32 =>
            --  A's AMOs and LR/SC are four bytes wide; the narrower
            --  read-modify-writes are their masked word.
            return Width /= Byte_8
              and then (Op not in Atomic_Exchange | Atomic_Add
                          | Atomic_Compare_Exchange
                        or else Landin.Targets.Levels.Has
                          (Level, Landin.Targets.Levels.A));
         when Synthetic_32_Architecture =>
            return False;
      end case;
   end Memory_Access;

   function Memory_Access_At_Some_Level
     (Facts : Target_Facts; Op : Landin.Memory.Operation;
      Width : Scalar_Size) return Boolean
   is
     (for some Level of Landin.Targets.Levels.Family_Levels (Facts) =>
         Memory_Access (Facts, Level, Op, Width));

   function Levels_Admitting
     (Facts : Target_Facts; Op : Landin.Memory.Operation;
      Width : Scalar_Size) return String
   is
      Result : Ada.Strings.Unbounded.Unbounded_String;
   begin
      for Level of Landin.Targets.Levels.Family_Levels (Facts) loop
         if Memory_Access (Facts, Level, Op, Width) then
            if Ada.Strings.Unbounded.Length (Result) > 0 then
               Ada.Strings.Unbounded.Append (Result, ", ");
            end if;
            Ada.Strings.Unbounded.Append
              (Result, Landin.Targets.Levels.Name (Level));
         end if;
      end loop;
      return Ada.Strings.Unbounded.To_String (Result);
   end Levels_Admitting;

   function Critical_Section (Facts : Target_Facts) return String
     is (case Architecture_Of (Facts) is
            when Cortex_M0 =>
               "platform/cortex_m's critical section, disable_interrupts to"
               & " restore_interrupts",
            when RV32 =>
               "platform/riscv's critical section, disable_interrupts to"
               & " restore_interrupts",
            when Xtensa =>
               "platform/xtensa's critical section, disable_interrupts to"
               & " restore_interrupts",
            when X86_64 | Arm64 | RV64 | Synthetic_32_Architecture => "");

   --  Every native backend emits both: x86-64 for Linux and FreeBSD, arm64
   --  for Linux, FreeBSD and Darwin, RV64 for Linux, Cortex-M0, where a
   --  prepared stack runs on the process stack pointer, and RV32, RV64's
   --  switch at XLEN 32 (D675).
   function Stack_Switching (Facts : Target_Facts) return Boolean is
     (case Backend_For (Facts) is
         when X86_64_ELF | Darwin_Arm64_Mach_O | Arm64_ELF | RV64_ELF
            | Cortex_M0_ELF | RV32_ELF => True,
         when Xtensa_ELF => True,
         when No_Backend => False);


   --  D920: AAPCS32's signatures and records go through
   --  Backend.Arm32_ABI at either variant.  RV32's ilp32 is planned
   --  (D677) and Xtensa's windowed ABI described, but neither is enabled.
   function C_Signatures (Facts : Target_Facts) return Boolean is
     (case C_ABI_Of (Facts) is
         when SysV_AMD64_LP64 | Darwin_AAPCS64_LP64 | AAPCS64_LP64
            | RiscV_LP64D | Arm_AAPCS32_Soft => True,
         when No_C_ABI | RiscV_ILP32 | Xtensa_Windowed_ILP32 => False);

   function C_Records (Facts : Target_Facts) return Boolean is
     (case C_ABI_Of (Facts) is
         when SysV_AMD64_LP64 | Darwin_AAPCS64_LP64 | AAPCS64_LP64
            | RiscV_LP64D | Arm_AAPCS32_Soft => True,
         when No_C_ABI | RiscV_ILP32 | Xtensa_Windowed_ILP32 => False);

   --  D922: AAPCS32's planner places a variadic call, but no firmware
   --  program has needed one, so none is enabled until one does.
   function C_Variadic_Calls (Facts : Target_Facts) return Boolean is
     (case C_ABI_Of (Facts) is
         when SysV_AMD64_LP64 | Darwin_AAPCS64_LP64 | AAPCS64_LP64
            | RiscV_LP64D => True,
         when No_C_ABI | Arm_AAPCS32_Soft | RiscV_ILP32
            | Xtensa_Windowed_ILP32 => False);

   function Object_Format_Of (Facts : Target_Facts) return Object_Format is
   begin
      if Facts = Linux_X86_64 or else Facts = FreeBSD_X86_64 then
         return ELF;
      elsif Facts = Darwin_Arm64 then
         return Mach_O;
      elsif Facts = Linux_Arm64 or else Facts = FreeBSD_Arm64 then
         return ELF;
      elsif Facts = Linux_RV64 or else Facts = Cortex_M
        or else Facts = RV32 or else Facts = Xtensa
      then
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
         when Cortex_M0_ELF | RV32_ELF | Xtensa_ELF => ELF_DWARF_Lines,
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
      elsif Facts = RV32 then
         return RV32_ELF;
      elsif Facts = Xtensa then
         return Xtensa_ELF;
      elsif Facts = Synthetic_32 then
         return No_Backend;
      else
         raise Compiler_Defect
           with "target has no stated backend capability";
      end if;
   end Backend_For;

   function Image_Reach (Facts : Target_Facts) return Byte_Count is
     (case Backend_For (Facts) is
         when X86_64_ELF | Darwin_Arm64_Mach_O | RV64_ELF => 2 ** 31,
         when Arm64_ELF => 2 ** 32,
         when Cortex_M0_ELF | RV32_ELF | Xtensa_ELF =>
            Maximum_Object_Size (Facts),
         when No_Backend =>
            raise Compiler_Defect with "no backend, so no reach");

   function Reach_Source (Facts : Target_Facts) return String is
     (case Backend_For (Facts) is
         when X86_64_ELF => "x86-64's small code model reaches",
         when Darwin_Arm64_Mach_O => "a Darwin static image holds",
         when Arm64_ELF => "arm64's ADRP reaches",
         when RV64_ELF => "RV64's AUIPC reaches",
         when Cortex_M0_ELF | RV32_ELF | Xtensa_ELF =>
            "the 32-bit address space holds",
         when No_Backend =>
            raise Compiler_Defect with "no backend, so no reach");

   function Image_Reach_Source (Facts : Target_Facts) return String is
     (Reach_Source (Facts) & " on " & Name (Facts));

   function Image_Budget_Of (Facts : Target_Facts) return Image_Budget is
     ((Initialized => Image_Reach (Facts),
       Writable    => Image_Reach (Facts),
       Reserved    => Maximum_Object_Size (Facts)));

   function Writes_Zero_Constants (Facts : Target_Facts) return Boolean is
     (Backend_For (Facts) in Cortex_M0_ELF | RV32_ELF | Xtensa_ELF);

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
         return "arm-eabi";
      elsif Facts = RV32 then
         return "riscv64-elf";
      elsif Facts = Xtensa then
         return "xtensa-esp32-elf";
      elsif Facts = Synthetic_32 then
         return "";
      else
         raise Compiler_Defect
           with "target has no stated toolchain triplet";
      end if;
   end Triplet;

end Landin.Targets.Capabilities;
