--  The fixes the compiler knows how to offer, one constructor each.
--
--  A fix's sentence is written here and nowhere else, for the reason the
--  catalogue keeps its rows free of prose and the stages free of codes: a
--  stage says what it found and where, and this says what the repair is.
--  Each constructor also decides the repair's kind and applicability, so no
--  stage can offer a guess as an exact repair.

with Landin.Diagnostics.Suggestions;
with Landin.Source;

package Landin.Diagnostics.Fixes is

   use type Landin.Source.Byte_Offset;

   --  The written name at Where becomes Spelling, a name the position
   --  could have meant.  Likely: which name was meant is a guess.
   function Respell
     (Source   : Landin.Source.Source_Id;
      Where    : Landin.Source.Span;
      Spelling : String) return Fix
     with Pre => Landin.Source.Length (Where) > 0;

   --  One Respell per name the ranking kept, nearest first; none when it
   --  kept none.
   function Respellings
     (Source  : Landin.Source.Source_Id;
      Where   : Landin.Source.Span;
      Offered : Landin.Diagnostics.Suggestions.Ranking) return Fix_List;

end Landin.Diagnostics.Fixes;
