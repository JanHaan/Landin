--  Which declared names a misspelling is near.
--
--  A report that a name names nothing [1860] can say which names it is
--  near, because a name that is not in scope is a misspelling and the
--  stage that raised it knows what is in scope.  This package decides only
--  nearness and order; which names are candidates is the stage's, because
--  only it knows what the position could have named, and a candidate that
--  names something out of scope or inaccessible is a candidate the stage
--  must not offer.
--
--  Nearness is the optimal-string-alignment distance: insert, delete or
--  replace one byte, or swap two adjacent ones.  A name is ASCII [1760],
--  so a byte is a character.  The bound is a third of the written name's
--  length and at least one, and a candidate must also be longer than the
--  distance: `c` is one edit from `b` and not a misspelling of it.
--
--  The order is total, so the same program always gets the same
--  suggestions: nearest first, then the innermost scope first -- the order
--  [0140]'s search would have found them in -- then by spelling.  Only
--  the candidates at the nearest distance are kept, and at most three.

private with Ada.Containers.Indefinite_Vectors;

package Landin.Diagnostics.Suggestions is

   Most : constant := 3;

   function Distance (Left, Right : String) return Natural;

   function Bound (Written : String) return Natural
     is (Natural'Max (1, Written'Length / 3));

   --  Whether Candidate is near enough to Written to be offered for it.
   function Near (Written, Candidate : String) return Boolean;

   type Ranking is private;

   --  Depth is how many scopes outward the candidate was found, zero for
   --  the innermost.  A spelling offered twice keeps its innermost depth,
   --  and Written itself is never a candidate.
   procedure Consider
     (Into      : in out Ranking;
      Written   : String;
      Candidate : String;
      Depth     : Natural := 0);

   function Count (Of_Ranking : Ranking) return Natural;

   function Nth (Of_Ranking : Ranking; Index : Positive) return String
     with Pre => Index <= Count (Of_Ranking);

private

   type Entry_Kind (Length : Natural) is record
      Distance : Natural;
      Depth    : Natural;
      Spelling : String (1 .. Length);
   end record;

   package Entry_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => Entry_Kind);

   type Ranking is record
      Kept : Entry_Vectors.Vector;
   end record;

end Landin.Diagnostics.Suggestions;
