with Landin.Source.Names;

--  Source-level machine conventions, independent of physical registers.
package Landin.Machine is
   type Convention is (Ordinary, Interrupt_Handler, Naked_Routine);
   type Placement is record
      Section : Landin.Source.Names.Name_Id := Landin.Source.Names.No_Name;
      Alignment : Natural := 0;
      Vector : Natural := 0;
      --  CPU line zero is a real Xtensa interrupt identity.
      Vector_Present : Boolean := False;
      Keep : Boolean := False;
      --  D547: `link(region: "NAME")`, the region of the selected
      --  description the declaration is placed in.
      Region : Landin.Source.Names.Name_Id := Landin.Source.Names.No_Name;
      --  D587: `link(boot_stage)`, the description's second-stage boot
      --  routine, which the backend emits at the start of the boot kind's
      --  slot rather than in a section of its own.
      Boot_Stage : Boolean := False;
   end record;
end Landin.Machine;
