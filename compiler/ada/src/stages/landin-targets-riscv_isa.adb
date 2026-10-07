package body Landin.Targets.RiscV_ISA is

   function Is_Supported (Name : String) return Boolean
     is (Name in "rv64gc" | "rv64gc_zba" | "rv64gc_xtheadba"
               | "rv64gc_zba_xtheadba");

   function Named (Name : String) return Instruction_Set is
   begin
      if not Is_Supported (Name) then
         raise Compiler_Defect with "unsupported RISC-V ISA string";
      end if;
      return (Extensions =>
                [I .. Zifencei => True,
                 Zba => Name in "rv64gc_zba" | "rv64gc_zba_xtheadba",
                 Xtheadba => Name in "rv64gc_xtheadba"
                                  | "rv64gc_zba_xtheadba"]);
   end Named;

   function Name (ISA : Instruction_Set) return String
     is ("rv64gc" & (if ISA.Extensions (Zba) then "_zba" else "")
                 & (if ISA.Extensions (Xtheadba) then "_xtheadba" else ""));

   function Has (ISA : Instruction_Set; Wanted : Extension) return Boolean
     is (ISA.Extensions (Wanted));

end Landin.Targets.RiscV_ISA;
