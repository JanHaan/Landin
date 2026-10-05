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

   function Name_End
     (Source   : Landin.Source.Source_Id;
      Where    : Landin.Source.Span;
      Declared : String) return Fix
   is
      Result : Fix := Make_Fix
        (Name_End, Exact,
         (if Declared'Length > 4
            and then Declared (Declared'First .. Declared'First + 3) = "end "
          then "close it with `" & Declared & "`"
          else "close it with `end " & Declared & "`"));
   begin
      Add_Edit (Result, Make_Edit (Source, Where, Declared));
      return Result;
   end Name_End;

   function Mark_Mutable
     (Source : Landin.Source.Source_Id;
      Before : Landin.Source.Byte_Offset;
      Name   : String) return Fix
   is
      Result : Fix := Make_Fix
        (Mark_Mutable, Likely, "declare `" & Name & "` with `mut`");
   begin
      Add_Edit (Result, Make_Edit (Source, (Before, Before), "mut "));
      return Result;
   end Mark_Mutable;

   function Unmark_Mutable
     (Source : Landin.Source.Source_Id;
      Word   : Landin.Source.Span;
      Blanks : Landin.Source.Span;
      Name   : String) return Fix
   is
      Result : Fix := Make_Fix
        (Unmark_Mutable, Exact, "declare `" & Name & "` without `mut`");
   begin
      Add_Edit
        (Result, Make_Edit (Source, (Word.First, Blanks.Last), ""));
      return Result;
   end Unmark_Mutable;

   function Remove_Unused_Local
     (Source : Landin.Source.Source_Id;
      Line   : Landin.Source.Span;
      Name   : String) return Fix
   is
      Result : Fix := Make_Fix
        (Remove_Unused_Local, Exact, "remove unused `" & Name & "`");
   begin
      Add_Edit (Result, Make_Edit (Source, Line, ""));
      return Result;
   end Remove_Unused_Local;

   function Compare
     (Source : Landin.Source.Source_Id;
      Where  : Landin.Source.Span) return Fix
   is
      Result : Fix := Make_Fix (Compare, Likely, "compare with `==`");
   begin
      Add_Edit (Result, Make_Edit (Source, Where, "=="));
      return Result;
   end Compare;

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
