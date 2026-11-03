with Ada.Unchecked_Deallocation;
with System.Storage_Elements;

package body Landin.IR.Scratch_Arrays is

   procedure Free is new Ada.Unchecked_Deallocation
     (Object => Elements, Name => Elements_Access);

   overriding procedure Finalize (Value : in out Owner) is
   begin
      Free (Value.Data);
   end Finalize;

   function Create (Count : Natural) return Owner is
      use System.Storage_Elements;
      Width : constant Storage_Count :=
        Element'Object_Size / System.Storage_Unit;
   begin
      if Width /= 0 and then Storage_Count (Count)
        > Storage_Count'Last / Width
      then
         raise Storage_Error with
           "optimizer scratch size is not representable";
      end if;
      return Result : Owner do
         --  Initialize in owned heap storage, without an input-sized
         --  aggregate or return temporary on the compiler's stack.
         Result.Data := new Elements (1 .. Count);
         for Held of Result.Data.all loop
            Held := Initial;
         end loop;
      end return;
   end Create;

end Landin.IR.Scratch_Arrays;
