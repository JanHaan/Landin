--  Where the space of one compilation lives.
--
--  A stream is a local of the syntax stage and ends with it, and only the
--  tree outlives it.  The space a stream kept is what a formatter puts back
--  and what an editor asks about -- where a comment is, which declaration a
--  doc comment sits above -- so the pieces are copied here, beside the
--  forest and numbered the same way: one row per source, added in the order
--  the sources were, with the source's identity as its key and no second
--  numbering.  Add states the order as a precondition, as the forest does.
--
--  The tokens are not kept.  A piece is a kind and a span, found by offset,
--  so a reader holding a tree asks for the pieces inside a node's extent or
--  between two of them and needs no token to do it.
--
--  Each source's pieces are one array on the heap, exactly as long as the
--  stream's, and the table frees them when it is finalized, which is when
--  the compilation that holds it ends.  Nothing is handed out by reference:
--  a piece is two offsets and a kind, and is returned by value.
--
--  Nothing here changes what a program means.  The parser never reads this
--  table, and no stage after it may decide anything by it.

private with Ada.Containers.Vectors;
private with Ada.Finalization;

with Landin.Source;

package Landin.Tokens.Spacing is

   use type Landin.Source.Source_Id;

   type Table is tagged limited private;

   --  How many sources have their space here.
   function Count (Of_Table : Table) return Natural;

   function Contains
     (Of_Table : Table; Id : Landin.Source.Source_Id) return Boolean
     is (Id /= Landin.Source.No_Source
         and then Natural (Id) <= Count (Of_Table));

   --  Keeps the space of one stream.
   procedure Add (Into : in out Table; From : Token_Stream)
     with Pre  => Source_Of (From)
                  = Landin.Source.Source_Id (Count (Into) + 1),
          Post => Count (Into) = Count (Into)'Old + 1;

   --  Move the row of an unchanged source alongside its transferred tree.
   procedure Transfer_Next (From : in out Table; Into : in out Table)
     with Pre => Count (From) > Count (Into),
          Post => Count (Into) = Count (Into)'Old + 1;

   function Space_Count
     (Of_Table : Table; Id : Landin.Source.Source_Id) return Natural
     with Pre => Contains (Of_Table, Id);

   --  In byte order, as the stream had them.
   function Nth_Space
     (Of_Table : Table;
      Id       : Landin.Source.Source_Id;
      Index    : Positive) return Space
     with Pre => Contains (Of_Table, Id)
                 and then Index <= Space_Count (Of_Table, Id);

   --  The pieces that lie wholly inside Where: every comment in a node's
   --  extent, or every piece between the end of one node and the start of
   --  the next.
   function Within
     (Of_Table : Table;
      Id       : Landin.Source.Source_Id;
      Where    : Landin.Source.Span) return Space_Range
     with Pre  => Contains (Of_Table, Id),
          Post => Within'Result.Last <= Space_Count (Of_Table, Id);

private

   type Space_Array is array (Positive range <>) of Space;

   --  Freed with the table; see the header.
   type Space_Access is access Space_Array;

   package Row_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Space_Access);

   type Held is new Ada.Finalization.Limited_Controlled with record
      Rows : Row_Vectors.Vector;
   end record;

   overriding procedure Finalize (Owned : in out Held);

   type Table is tagged limited record
      Owned : Held;
   end record;

end Landin.Tokens.Spacing;
