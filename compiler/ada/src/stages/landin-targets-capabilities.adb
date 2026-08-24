package body Landin.Targets.Capabilities is

   function Backend_For (Facts : Target_Facts) return Backend_Kind is
   begin
      if Facts = Linux_X86_64 then
         return Linux_X86_64_ELF;
      elsif Facts = Synthetic_32 then
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
      elsif Facts = Synthetic_32 then
         return "";
      else
         raise Compiler_Defect
           with "target has no stated toolchain triplet";
      end if;
   end Triplet;

end Landin.Targets.Capabilities;
