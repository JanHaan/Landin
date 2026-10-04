--  Where the trees of one compilation live.
--
--  The first parser dropped every tree as soon as it was parsed and recorded
--  why: a vector of a limited type is not a thing Ada has, so the answer had
--  to be a decision rather than a guess.  This is the decision, and it is the
--  one Landin.Source.Sets made one level down.  The trees are on the heap,
--  one per source, and the owning forest frees them when it is finalized.
--  A server may transfer an unchanged tree to its stand-in compilation;
--  the old slot is then empty and must not be read again.  Tree_Of takes
--  the forest as an aliased parameter, so its reference cannot be kept
--  anywhere that outlives the forest,
--  and a diagnostic holds a span and a source number rather than a tree.
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
--  parse is its only writer, and resolved names, checked types and IR values
--  are each an array indexed by Node_Id rather than a field a stage adds to a
--  node.

private with Ada.Containers.Vectors;
private with Ada.Finalization;

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

   --  Move an unchanged source's tree into the next compilation.  Its
   --  Source_Id and every interned Name_Id must have the same meaning there.
   procedure Transfer_Next (From : in out Table; Into : in out Table)
     with Pre => Count (From) > Count (Into),
          Post => Count (Into) = Count (Into)'Old + 1;

   --  Copy an immutable parse into another compilation.  Re-intern names
   --  because a Name_Id only has meaning in the table that issued it.
   procedure Copy_Add
     (Into       : in out Table;
      From       : aliased Table;
      Id         : Landin.Source.Source_Id;
      From_Names : Landin.Source.Names.Table;
      Into_Names : in out Landin.Source.Names.Table)
     with Pre  => Contains (From, Id),
          Post => Count (Into) = Count (Into)'Old + 1;

   --  The tree a source was parsed into, by reference and read only.
   function Tree_Of (Of_Forest : aliased Table; Id : Landin.Source.Source_Id)
     return not null access constant Tree
     with Pre  => Contains (Of_Forest, Id),
          Post => Source_Of (Tree_Of'Result.all) = Id;

private

   --  Freed with the forest that owns it; see the header.  The access
   --  type is private, so nothing outside can hold an owned tree past it.
   type Tree_Access is access Tree;

   package Tree_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Tree_Access);

   type Held is new Ada.Finalization.Limited_Controlled with record
      Items : Tree_Vectors.Vector;
   end record;

   overriding procedure Finalize (Owned : in out Held);

   type Table is tagged limited record
      Owned : Held;
   end record;

end Landin.Syntax.Forest;
