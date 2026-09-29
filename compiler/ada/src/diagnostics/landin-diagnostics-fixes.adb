package body Landin.Diagnostics.Fixes is

   package Near renames Landin.Diagnostics.Suggestions;

   function Respell
     (Source   : Landin.Source.Source_Id;
      Where    : Landin.Source.Span;
      Spelling : String) return Fix
   is
      Result : Fix := Make_Fix
        (Respell, Likely, "did you mean `" & Spelling & "`?");
   begin
      Add_Edit (Result, Make_Edit (Source, Where, Spelling));
      return Result;
   end Respell;

   function Respellings
     (Source  : Landin.Source.Source_Id;
      Where   : Landin.Source.Span;
      Offered : Near.Ranking) return Fix_List
   is
      Result : Fix_List (1 .. Near.Count (Offered));
   begin
      if Landin.Source.Length (Where) = 0 then
         return No_Fixes;
      end if;
      for Index in Result'Range loop
         Result (Index) := Respell (Source, Where, Near.Nth (Offered, Index));
      end loop;
      return Result;
   end Respellings;

end Landin.Diagnostics.Fixes;
