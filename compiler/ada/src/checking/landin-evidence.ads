--  Target-neutral semantic positions in an evidence table.
--
--  These positions describe meaning, not representation.  In particular,
--  this package deliberately does not know a target byte width or an offset.

package Landin.Evidence is

   type Semantic_Position is range 0 .. Natural'Last;

   Size_Position      : constant Semantic_Position := 0;
   Alignment_Position : constant Semantic_Position := 1;

   --  Concept functions follow the two scalar entries in declaration order.
   function Function_Position
     (Declaration_Order : Positive) return Semantic_Position
     is (Semantic_Position (Declaration_Order) + 1);

   function Entry_Count
     (Function_Count : Natural) return Semantic_Position
     is (Semantic_Position (Function_Count) + 2);

end Landin.Evidence;
