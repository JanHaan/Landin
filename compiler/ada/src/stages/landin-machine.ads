with Landin.Source.Names;

--  Source-level machine conventions, independent of physical registers.
package Landin.Machine is
   type Convention is (Ordinary, Interrupt_Handler, Naked_Routine);
   type Placement is record
      Section : Landin.Source.Names.Name_Id := Landin.Source.Names.No_Name;
      Alignment : Natural := 0;
      Vector : Natural := 0;
      Keep : Boolean := False;
   end record;
end Landin.Machine;
