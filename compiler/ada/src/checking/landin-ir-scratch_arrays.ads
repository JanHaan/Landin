--  Heap-owned scratch for an optimization pass: an array sized by the
--  unit being rewritten, initialized in place and freed when its owner
--  leaves scope, on an exceptional exit as well.  Neither the array nor
--  an initializing aggregate lives on the compiler's stack.
with Ada.Finalization;

private generic
   type Element is private;
   Initial : Element;
package Landin.IR.Scratch_Arrays is

   type Elements is array (Positive range <>) of Element;
   type Elements_Access is access Elements;
   type Owner is new Ada.Finalization.Limited_Controlled with record
      Data : Elements_Access := null;
   end record;
   overriding procedure Finalize (Value : in out Owner);

   --  Count elements, each Initial.  An array whose size in bytes is not
   --  representable raises Storage_Error rather than wrapping.
   function Create (Count : Natural) return Owner;

end Landin.IR.Scratch_Arrays;
