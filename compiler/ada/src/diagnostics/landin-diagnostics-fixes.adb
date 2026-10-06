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

   function Delete_Token
     (Source  : Landin.Source.Source_Id;
      Where   : Landin.Source.Span;
      Written : String;
      Word    : String;
      Level   : Applicability) return Fix
   is
      Result : Fix := Make_Fix
        (Delete_Token, Level, "remove `" & Word & "`");
   begin
      Add_Edit (Result, Make_Edit (Source, Where, Written));
      return Result;
   end Delete_Token;

   function Insert_Token
     (Source      : Landin.Source.Source_Id;
      Where       : Landin.Source.Span;
      Inserted    : String;
      Word        : String;
      Level       : Applicability;
      Placeholder : Boolean := False;
      Neighbour   : String := "";
      After       : Boolean := True) return Fix
   is
      Where_Said : constant String :=
        (if Neighbour = "" then " here"
         elsif After then " after `" & Neighbour & "`"
         else " before `" & Neighbour & "`");
      Result : Fix := Make_Fix
        (Insert_Token, Level,
         (if Placeholder
          then "write " & (if Word = "0" then "a value"
                           elsif Word = "u32" then "a type"
                           else "a name") & Where_Said
          else "write `" & Word & "`" & Where_Said));
   begin
      Add_Edit (Result, Make_Edit (Source, Where, Inserted));
      return Result;
   end Insert_Token;

   function Swap_Tokens
     (Source   : Landin.Source.Source_Id;
      Where    : Landin.Source.Span;
      Swapped  : String;
      First    : String;
      Second   : String;
      Level    : Applicability) return Fix
   is
      Result : Fix := Make_Fix
        (Swap_Tokens, Level,
         "write `" & Second & "` before `" & First & "`");
   begin
      Add_Edit (Result, Make_Edit (Source, Where, Swapped));
      return Result;
   end Swap_Tokens;

   function Call_With
     (Source  : Landin.Source.Source_Id;
      Where   : Landin.Source.Span;
      Written : String;
      Word    : String;
      Level   : Applicability) return Fix
   is
      Result : Fix := Make_Fix
        (Insert_Token, Level,
         "call `" & Word & "` with its operand in parentheses");
   begin
      Add_Edit (Result, Make_Edit (Source, Where, Written));
      return Result;
   end Call_With;

   function Move_Token
     (Source : Landin.Source.Source_Id;
      Where  : Landin.Source.Span;
      Moved  : String;
      Word   : String;
      Level  : Applicability) return Fix
   is
      Result : Fix := Make_Fix
        (Move_Token, Level, "`" & Word & "` goes first");
   begin
      Add_Edit (Result, Make_Edit (Source, Where, Moved));
      return Result;
   end Move_Token;

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

   function Measure_Bare
     (Source   : Landin.Source.Source_Id;
      Where    : Landin.Source.Span;
      Word     : String;
      Measured : String) return Fix
   is
      Result : Fix := Make_Fix
        (Measure_Bare, Likely,
         "write `" & Word & " " & Measured & "`");
   begin
      Add_Edit (Result, Make_Edit (Source, Where, " " & Measured));
      return Result;
   end Measure_Bare;

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
