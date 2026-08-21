package body Landin.Diagnostics.Catalogue is

   function Named (Text : Code_String) return Code_Name is
   begin
      for Candidate in Code_Name loop
         if Code (Candidate) = Text then
            return Candidate;
         end if;
      end loop;

      raise Compiler_Defect
        with "no catalogue row holds the code " & Text;
   end Named;

end Landin.Diagnostics.Catalogue;
