--  Supported RISC-V ISA strings and their independent extension sets.
--  RV64's GC includes I, M, A, F, D, Zicsr, Zifencei and C, and its
--  optional address extensions combine freely.  RV32's strings are the
--  microcontroller levels, rv32imc and rv32imac (D660), each with Zicsr and
--  Zifencei, which GCC names apart from the base since ISA spec 20191213.
--  No ordering between ISA strings is defined.
package Landin.Targets.RiscV_ISA is

   type Extension is (I, M, A, F, D, C, Zicsr, Zifencei, Zba, Xtheadba);
   type Instruction_Set is private;

   --  The width of the integer registers, which the string's prefix names.
   type XLEN is (XLEN_32, XLEN_64);

   function Is_Supported (Name : String) return Boolean;
   function Named (Name : String) return Instruction_Set
     with Pre => Is_Supported (Name);
   function Name (ISA : Instruction_Set) return String;
   function Width (ISA : Instruction_Set) return XLEN;
   function Has (ISA : Instruction_Set; Wanted : Extension) return Boolean;

private

   type Extension_Set is array (Extension) of Boolean;
   type Instruction_Set is record
      Register_Width : XLEN;
      Extensions : Extension_Set;
   end record;

end Landin.Targets.RiscV_ISA;
