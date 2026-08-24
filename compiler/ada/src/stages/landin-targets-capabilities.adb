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

end Landin.Targets.Capabilities;
