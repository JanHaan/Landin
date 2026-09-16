--  Target storage for the packed image algebra; no instruction selection.
with Landin.Packed;

package Landin.Targets.Packed is

   type Layout is record
      Fits      : Boolean := False;
      Size      : Byte_Count := 0;
      Alignment : Byte_Alignment := 1;
      Claimed   : Landin.Packed.Image := 0;
   end record;

   function Measure
     (Facts : Target_Facts;
      Fields : Landin.Packed.Field_Array;
      Bits : Landin.Packed.Width) return Layout;

   --  Storage layout availability never implies a device access capability.
   --  In particular M0 has ordinary eight-byte images but no eight-byte
   --  volatile transaction. Synthetic-32 supplies layout only.
   function Access_Supported
     (Facts : Target_Facts;
      Contract : Landin.Packed.Register_Contract;
      Form : Landin.Packed.Access_Form) return Boolean;

end Landin.Targets.Packed;
