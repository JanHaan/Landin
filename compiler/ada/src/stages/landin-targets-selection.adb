package body Landin.Targets.Selection is

   function Is_Described (Name : String) return Boolean
     is (Name in "linux-x86-64" | "darwin-arm64" | "cortex-m0"
                | "synthetic-32");

   function Described (Name : String) return Target_Facts is
   begin
      if Name = "linux-x86-64" then
         return Linux_X86_64;
      elsif Name = "darwin-arm64" then
         return Darwin_Arm64;
      elsif Name = "cortex-m0" then
         return Cortex_M;
      elsif Name = "synthetic-32" then
         return Synthetic_32;
      else
         raise Compiler_Defect with "no target is described as " & Name;
      end if;
   end Described;

end Landin.Targets.Selection;
