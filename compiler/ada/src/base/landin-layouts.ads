--  Explicit source representation policy, independent of machine placement.
--  Nested types keep their own policy; field identities stay source ordered.
package Landin.Layouts is

   type Policy is (Natural, C, Optimal);

end Landin.Layouts;
