--  Shared arena rebuild for verified transforms.  Slot, signature, shape,
--  image and semantic instance identities remain unchanged.
with Ada.Containers.Vectors;
private package Landin.IR.Rewriting is
   package Keep_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Boolean);
   procedure Compact (Into : in out Unit; Keep : Keep_Vectors.Vector);
end Landin.IR.Rewriting;
