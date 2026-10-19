--  Explicit source representation policy, independent of machine placement.
--  Nested types keep their own policy; field identities stay source ordered.
package Landin.Layouts is

   --  C_Packed is D410's `layout(c, packed)`: C's field order with every
   --  field at alignment one and no padding, as `__attribute__((packed))`
   --  lays a record out.  It is a C representation, unlike Packed, which
   --  is D228's register image of bits.
   type Policy is (Natural, C, Optimal, Packed, C_Packed);

   --  Whether a record of this policy follows the selected target's C
   --  rules for its field placement: both C layouts do.
   function Is_C (Of_Policy : Policy) return Boolean
     is (Of_Policy in C | C_Packed);

end Landin.Layouts;
