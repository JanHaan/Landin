with Ada.Unchecked_Deallocation;

package body Landin.Backend.Work_Arrays is

   procedure Free is new Ada.Unchecked_Deallocation
     (Elements, Elements_Access);

   overriding procedure Initialize (Object : in out Buffer) is
   begin
      Object.Data := new Elements (1 .. Object.Length);
      for Part of Object.Data.all loop
         Part := Default;
      end loop;
   end Initialize;

   overriding procedure Finalize (Object : in out Buffer) is
   begin
      Free (Object.Data);
   end Finalize;

end Landin.Backend.Work_Arrays;
