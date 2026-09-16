with Landin.Memory;
with Landin.Targets.Capabilities;

package body Landin.Targets.Packed is

   function Carrier (Bits : Landin.Packed.Width) return Scalar_Size;

   function Carrier (Bits : Landin.Packed.Width) return Scalar_Size is
     (if Bits <= 8 then Byte_1
      elsif Bits <= 16 then Byte_2
      elsif Bits <= 32 then Byte_4 else Byte_8);

   function Measure
     (Facts : Target_Facts;
      Fields : Landin.Packed.Field_Array;
      Bits : Landin.Packed.Width) return Layout is
   begin
      if Byte_Order (Facts) /= Little
        or else not Landin.Packed.Valid (Fields, Bits)
      then
         return (others => <>);
      end if;
      return (Fits => True,
              Size => Byte_Count (Bytes (Carrier (Bits))),
              Alignment => Alignment_Of (Facts, Carrier (Bits)),
              Claimed => Landin.Packed.Claimed (Fields, Bits));
   end Measure;

   function Access_Supported
     (Facts : Target_Facts;
      Contract : Landin.Packed.Register_Contract;
      Form : Landin.Packed.Access_Form) return Boolean
   is
      use type Landin.Packed.Access_Form;
   begin
      return Landin.Packed.Plan (Contract, Form).Allowed
        and then Capabilities.Memory_Access
          (Facts,
           (if Form = Landin.Packed.Read_Image then Landin.Memory.Volatile_Load
            else Landin.Memory.Volatile_Store), Carrier (Contract.Bits));
   end Access_Supported;

end Landin.Targets.Packed;
