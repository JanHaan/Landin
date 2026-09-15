package body Landin.Hosted is

   function Helper_Of (Symbol : String) return Host_Helper is
   begin
      for Helper in Initialize_Arguments .. Heap_Release loop
         if Symbol = Helper_Name (Helper) then
            return Helper;
         end if;
      end loop;
      return No_Host_Helper;
   end Helper_Of;

end Landin.Hosted;
