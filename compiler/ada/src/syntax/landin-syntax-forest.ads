--  Where the trees of one compilation live.
--
--  R1.40 dropped every tree as soon as it was parsed and recorded why: a
--  vector of a limited type is not a thing Ada has, so the answer had to be
--  a decision rather than a guess.  This is the decision, and it is the one
--  Landin.Source already made one level down.  The trees are on the heap,
--  one per source, and none is freed while the process lives: a compilation
--  owns its trees for as long as it exists, the process is short, and a
--  compiler that frees a tree while a diagnostic still points into it has
--  traded a leak for a dangling span.
--
--  Why an allocator and not a container.  A Tree is limited with unknown
--  discriminants, so it has no assignment, no default shape and no
--  constructor outside Landin.Syntax.Parser.  An initialised allocator
--  whose value is that call is the one form Ada gives for building a
--  limited object somewhere that will outlive the call, so that is the
--  form; Landin.Source.Sets.Add is the same shape one level down, where a
--  set is the only place a snapshot is created and the identity comes back.
--
--  A tree's identity is its source's, and there is no second numbering.
--  Landin.Source.Sets numbers a compilation's snapshots 1 .. N in the order
--  they were added, one stage reads them in that order, and one parse turns
--  each into exactly one tree -- Parse's own postcondition says so.  Add
--  states that as a precondition rather than trusting it, so a later stage
--  that parsed out of order is a defect at this seam instead of a wrong
--  lookup three stages further on.
--
--  Nothing here hands a tree back as a value.  Tree_Of hands out a
--  read-only reference, because a tree is finished when it arrives: the
--  parse is its only writer, and R1.50's names, R1.60's types and R1.70's
--  values are each an array indexed by Node_Id rather than a field a stage
--  adds to a node.

private with Ada.Containers.Vectors;

with Landin.Diagnostics;
with Landin.Source;
with Landin.Source.Names;
with Landin.Tokens;

package Landin.Syntax.Forest is

   use type Landin.Source.Source_Id;

   type Table is tagged limited private;

   function Count (Of_Forest : Table) return Natural;

   function Contains
     (Of_Forest : Table; Id : Landin.Source.Source_Id) return Boolean
     is (Id /= Landin.Source.No_Source
         and then Natural (Id) <= Count (Of_Forest));

   --  Parses one token stream and keeps the tree.  Names is the
   --  compilation's table and not this call's: an identity means nothing
   --  away from the table that issued it, and every tree kept here holds
   --  identities rather than bytes.
   procedure Add
     (Into   : in out Table;
      From   : Landin.Tokens.Token_Stream;
      Names  : in out Landin.Source.Names.Table;
      Report : in out Landin.Diagnostics.Diagnostic_List)
     with Pre  => Landin.Tokens.Source_Of (From)
                  = Landin.Source.Source_Id (Count (Into) + 1),
          Post => Count (Into) = Count (Into)'Old + 1
                  and then Contains (Into, Landin.Tokens.Source_Of (From));

   --  The tree a source was parsed into, by reference and read only.
   function Tree_Of (Of_Forest : Table; Id : Landin.Source.Source_Id)
     return not null access constant Tree
     with Pre  => Contains (Of_Forest, Id),
          Post => Source_Of (Tree_Of'Result.all) = Id;

private

   --  Never freed; see the header.  The access type is not visible, so
   --  nothing outside can hold a tree past the forest that owns it.
   type Tree_Access is access Tree;

   package Tree_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Tree_Access);

   type Table is tagged limited record
      Items : Tree_Vectors.Vector;
   end record;

end Landin.Syntax.Forest;
