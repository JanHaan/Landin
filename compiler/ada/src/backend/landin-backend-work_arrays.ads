--  Heap-owned backend scratch with lexical, exception-safe reclamation.
--  Array views keep placement's target-byte interface without a host-stack
--  temporary proportional to the instruction count.
with Ada.Finalization;

generic
   type Element is private;
   type Elements is array (Positive range <>) of Element;
   Default : Element;
package Landin.Backend.Work_Arrays is

   type Elements_Access is access Elements;
   type Buffer (Length : Natural) is
     new Ada.Finalization.Limited_Controlled with record
      Data : Elements_Access;
   end record;

   overriding procedure Initialize (Object : in out Buffer);
   overriding procedure Finalize (Object : in out Buffer);

end Landin.Backend.Work_Arrays;
