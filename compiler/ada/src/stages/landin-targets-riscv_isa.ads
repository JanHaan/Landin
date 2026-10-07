--  Supported RISC-V ISA strings and their independent extension sets.
--  GC includes I, M, A, F, D, Zicsr, Zifencei and C. The optional address
--  extensions combine freely; no ordering between ISA strings is defined.
package Landin.Targets.RiscV_ISA is

   type Extension is (I, M, A, F, D, C, Zicsr, Zifencei, Zba, Xtheadba);
   type Instruction_Set is private;

   function Is_Supported (Name : String) return Boolean;
   function Named (Name : String) return Instruction_Set
     with Pre => Is_Supported (Name);
   function Name (ISA : Instruction_Set) return String;
   function Has (ISA : Instruction_Set; Wanted : Extension) return Boolean;

private

   type Extension_Set is array (Extension) of Boolean;
   type Instruction_Set is record
      Extensions : Extension_Set;
   end record;

end Landin.Targets.RiscV_ISA;
