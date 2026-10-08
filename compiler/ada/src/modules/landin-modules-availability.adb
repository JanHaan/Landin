with Landin.Targets.Capabilities;

package body Landin.Modules.Availability is

   use type Landin.Targets.Architecture;
   use type Landin.Targets.Capabilities.Hosted_System;

   function Under (Logical, Root : String) return Boolean is
     (Logical = Root or else
      (Logical'Length > Root'Length
       and then Logical (Logical'First .. Logical'First + Root'Length) =
         Root & "/"));

   function Permitted
     (Logical : String; Facts : Landin.Targets.Target_Facts) return Boolean
   is
   begin
      if Under (Logical, "hosted") then
         return Landin.Targets.Capabilities.Hosted_System_Of (Facts) /=
           Landin.Targets.Capabilities.No_Hosted_System;
      elsif Under (Logical, "platform/cpu") then
         return Landin.Targets.Architecture_Of (Facts) =
           Landin.Targets.Cortex_M0;
      elsif Under (Logical, "platform/c") then
         case Landin.Targets.C_ABI_Of (Facts) is
            when Landin.Targets.SysV_AMD64_LP64
               | Landin.Targets.Darwin_AAPCS64_LP64
               | Landin.Targets.AAPCS64_LP64
               | Landin.Targets.RiscV_LP64D =>
               return Landin.Targets.Capabilities.C_Signatures (Facts);
            when Landin.Targets.No_C_ABI
               | Landin.Targets.Arm_AAPCS32_Soft => return False;
         end case;
      end if;
      return True;
   end Permitted;

   function Requirement (Logical : String) return String is
   begin
      if Under (Logical, "hosted") then
         return "D267: hosted modules require a hosted target";
      elsif Under (Logical, "platform/cpu") then
         return "D267: platform/cpu requires an M-profile target";
      else
         return "D267: platform/c requires an enabled LP64 C ABI";
      end if;
   end Requirement;

end Landin.Modules.Availability;
