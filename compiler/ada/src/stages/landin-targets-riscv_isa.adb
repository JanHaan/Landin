package body Landin.Targets.RiscV_ISA is

   function Is_Supported (Name : String) return Boolean
     is (Name in "rv64gc" | "rv64gc_zba" | "rv64gc_xtheadba"
               | "rv64gc_zba_xtheadba" | "rv32imc" | "rv32imac");

   function Named (Name : String) return Instruction_Set is
   begin
      if not Is_Supported (Name) then
         raise Compiler_Defect with "unsupported RISC-V ISA string";
      elsif Name in "rv32imc" | "rv32imac" then
         return (Register_Width => XLEN_32,
                 Extensions =>
                   [I | M | C | Zicsr | Zifencei => True,
                    A => Name = "rv32imac",
                    F | D | Zba | Xtheadba => False]);
      end if;
      return (Register_Width => XLEN_64,
              Extensions =>
                [I .. Zifencei => True,
                 Zba => Name in "rv64gc_zba" | "rv64gc_zba_xtheadba",
                 Xtheadba => Name in "rv64gc_xtheadba"
                                  | "rv64gc_zba_xtheadba"]);
   end Named;

   function Name (ISA : Instruction_Set) return String
     is (case ISA.Register_Width is
            when XLEN_32 =>
              "rv32im" & (if ISA.Extensions (A) then "a" else "") & "c",
            when XLEN_64 =>
              "rv64gc" & (if ISA.Extensions (Zba) then "_zba" else "")
              & (if ISA.Extensions (Xtheadba) then "_xtheadba" else ""));

   function Width (ISA : Instruction_Set) return XLEN
     is (ISA.Register_Width);

   function Has (ISA : Instruction_Set; Wanted : Extension) return Boolean
     is (ISA.Extensions (Wanted));

end Landin.Targets.RiscV_ISA;
