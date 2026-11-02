with Landin.Targets.Capabilities;

package body Landin.Modules.Availability is

   use type Landin.Targets.Architecture;
   use type Landin.Targets.Capabilities.Hosted_System;

   function Under (Logical, Root : String) return Boolean is
     (Logical = Root or else
      (Logical'Length > Root'Length
       and then Logical (Logical'First .. Logical'First + Root'Length) =
         Root & "/"));

   --  platform/linux, platform/libc, platform/kqueue and platform/posix,
   --  with their submodules.
   function POSIX_Module (Logical : String) return Boolean is
     (Under (Logical, "platform/posix")
      or else Under (Logical, "platform/linux")
      or else Under (Logical, "platform/libc")
      or else Under (Logical, "platform/kqueue"));

   function Permitted
     (Logical : String; Facts : Landin.Targets.Target_Facts) return Boolean
   is
   begin
      if Under (Logical, "hosted") then
         return Landin.Targets.Capabilities.Hosted_System_Of (Facts) /=
           Landin.Targets.Capabilities.No_Hosted_System;
      elsif POSIX_Module (Logical) then
         --  The system's own interfaces and the POSIX layer over them serve
         --  the hosted POSIX systems, and would not exist on another.
         return Landin.Targets.Capabilities.Hosted_System_Of (Facts) in
           Landin.Targets.Capabilities.Linux
           | Landin.Targets.Capabilities.Darwin
           | Landin.Targets.Capabilities.FreeBSD;
      elsif Logical = "platform/cortex_m" then
         --  D575: the module itself declares its operations only on an
         --  M-profile target, so a shared program imports it everywhere and
         --  calls it from a firmware arm.
         return True;
      elsif Under (Logical, "platform/cortex_m") then
         --  Its submodules, the reference description among them, keep
         --  D267's scope.
         return Landin.Targets.Architecture_Of (Facts) =
           Landin.Targets.Cortex_M0;
      elsif Logical = "platform/riscv" then
         --  D687: as platform/cortex_m, its operations are declared on
         --  rv32 alone, so a shared program imports it everywhere.
         return True;
      elsif Under (Logical, "platform/riscv") then
         --  D661: RV32's reference description and Hazard3's controller,
         --  on RV32 alone.
         return Landin.Targets.Architecture_Of (Facts) =
           Landin.Targets.RV32;
      elsif Under (Logical, "platform/c") then
         case Landin.Targets.C_ABI_Of (Facts) is
            when Landin.Targets.SysV_AMD64_LP64
               | Landin.Targets.Darwin_AAPCS64_LP64
               | Landin.Targets.AAPCS64_LP64
               | Landin.Targets.RiscV_LP64D =>
               return Landin.Targets.Capabilities.C_Signatures (Facts);
            when Landin.Targets.No_C_ABI
               | Landin.Targets.Arm_AAPCS32_Soft
               | Landin.Targets.RiscV_ILP32 => return False;
         end case;
      end if;
      return True;
   end Permitted;

   function Requirement (Logical : String) return String is
   begin
      if Under (Logical, "hosted") then
         return "D267: hosted modules require a hosted target";
      elsif POSIX_Module (Logical) then
         return "D267: " & Logical & " requires a hosted POSIX system:"
           & " Linux, Darwin or FreeBSD";
      elsif Under (Logical, "platform/cortex_m") then
         return "D267: " & Logical & " requires an M-profile target";
      elsif Under (Logical, "platform/riscv") then
         return "D267: " & Logical & " requires the rv32 target";
      else
         return "D267: platform/c requires an enabled LP64 C ABI";
      end if;
   end Requirement;

end Landin.Modules.Availability;
