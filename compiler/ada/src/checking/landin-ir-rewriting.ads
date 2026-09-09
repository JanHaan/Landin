--  Shared arena rebuild for verified transforms.  Slot, signature, shape,
--  image and semantic instance identities remain unchanged.
private package Landin.IR.Rewriting is
   type Keep_Array is array (Positive range <>) of Boolean;
   procedure Compact (Into : in out Unit; Keep : Keep_Array);
end Landin.IR.Rewriting;
