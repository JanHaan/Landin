--  What type everything in a program has.
--
--  `tour.txt` [1790] gives the kernel eleven types, [0190] says an integer
--  literal takes the type of its context, [0200] says what it takes when
--  there is no context, and [0310] says there is no implicit conversion
--  between any two of them.  Landin.Types is those rules made addressable;
--  this is where the answer for each node and each declaration is kept.
--
--  It is R1.50's shape, and the two facts that forced that shape have not
--  changed.  Landin.Stages.Run takes Item as an `in` parameter of a
--  limited interface, so a stage cannot keep anything in itself, and a
--  Stage_Reference is library-level, so a stage object cannot be a local of
--  one compilation either.  So the compilation owns this table, exactly as
--  it owns the trees and what every name in them means.
--
--  Two runs, not one, and each earns its place.
--
--  A type per NODE is what R1.40 built the flat table for: a Node_Id is
--  dense in 1 .. Node_Count, so this is one array with one run per source
--  and a first index, and a lookup is one addition and one index with no
--  map and no order that depends on where the host put an object.  R1.70
--  lowers from it, and a lowering needs a type for every node it lowers,
--  not only for the ones a diagnostic mentioned.
--
--  A type per DECLARATION is not derivable from that, and the reason is
--  [1840].  The module scope is a set, so `f: () -> (r: u32) = later end`
--  may stand above `later: u32 = 7`, and in another file: the corpus has
--  that program.  A forward loop over one tree cannot answer it, because
--  the answer is in a tree the loop has not reached.  So every declaration
--  is settled before any body is walked, and this run is where that answer
--  is put.  It also carries Underway, which is the whole of the cycle
--  check: `a := b` and `b := a` are two module bindings whose inferred
--  types wait on each other, and without a mark that is a stack overflow
--  rather than a diagnostic.
--
--  A declaration's type is the type of the VALUE its name denotes, and a
--  function name denotes no value the kernel can spell.  A function is an
--  ordinary value of a function type [1000] and [1010] binds one to a
--  name, but [1790]'s `type` rule spells no function type, so a function's
--  name anywhere but in front of a `(` is a construct this grammar omits
--  and [1920] has [1830] refuse it by name.  A Function_Declaration
--  therefore settles as Not_Typed, and `x := f` is refused by reading that
--  rather than by a special case -- but it is refused as a construct that
--  is not enabled yet, never as a name that has no type.  A call's type is its
--  callee's named return, read through the per-node run of the callee's own
--  tree; `-> none` is No_Value.
--
--  Nothing here holds a diagnostic and nothing here decides a rule.  A
--  mismatch is two type values that are not equal; the codes belong to
--  Landin.Diagnostics.Checking, and the order the trees are walked in
--  belongs to Landin.Stages.Checking, exactly as Landin.Resolution split
--  those three ways.
--
--  Nothing here asks the host how wide anything is either.  This package
--  stores Landin.Types.Type_Kind values, which carry no width at all, and
--  a width is only ever obtained from Landin.Types.Width against the
--  compilation's own Landin.Targets.Target_Facts.

private with Ada.Containers.Vectors;

with Landin.Provenance;
with Landin.Resolution;
with Landin.Source;
with Landin.Source.Names;
with Landin.Syntax;
with Landin.Syntax.Forest;
with Landin.Types;

package Landin.Checking is

   use type Landin.Provenance.Declaration_Id;
   use type Landin.Syntax.Node_Id;
   use type Landin.Types.Type_Kind;

   subtype Declaration_Id is Landin.Provenance.Declaration_Id;

   No_Declaration : constant Declaration_Id :=
     Landin.Provenance.No_Declaration;

   --  Where a declaration's type has got to.  Untouched and Settled are
   --  the two states a caller wants; Underway exists because of the module
   --  scope and nothing else, and it is public because the stage that
   --  reports the cycle is the one that has to see it.
   type Progress is (Untouched, Underway, Settled);

   type Table is tagged limited private;

   ------------------------------------------------------------------
   --  Building
   ------------------------------------------------------------------

   function Is_Prepared (Of_Table : Table) return Boolean;

   function Node_Limit
     (Of_Table : Table; Id : Landin.Source.Source_Id) return Natural
     with Pre => Is_Prepared (Of_Table);

   function Declaration_Limit (Of_Table : Table) return Natural
     with Pre => Is_Prepared (Of_Table);

   --  True when this table was sized for that very tree, so a table
   --  prepared from another forest is a contract failure rather than an
   --  index that happens to be in range.
   function Covers (Of_Table : Table; Of_Tree : Landin.Syntax.Tree)
     return Boolean
     with Pre => Is_Prepared (Of_Table);

   --  Sizes both runs once, and interns the eleven spellings so that a
   --  Type_Name node is answered by an identity comparison rather than by
   --  bytes.  Once, for Landin.Resolution.Prepare's reason: the forest is
   --  complete when the parse is and the declarations are complete when
   --  resolution is, so a table that grew as either arrived would be a
   --  table whose size depends on when it was asked.
   procedure Prepare
     (Into      : in out Table;
      Trees     : Landin.Syntax.Forest.Table;
      Meanings  : Landin.Resolution.Table;
      Spellings : in out Landin.Source.Names.Table)
     with Pre  => not Is_Prepared (Into)
                  and then Landin.Resolution.Is_Prepared (Meanings),
          Post => Is_Prepared (Into)
                  and then Declaration_Limit (Into)
                           = Landin.Resolution.Declaration_Count (Meanings);

   ------------------------------------------------------------------
   --  The eleven, by identity
   ------------------------------------------------------------------

   --  Which type a Type_Name node names.  [1790]'s eleven are ordinary
   --  declared names the kernel predeclares [1760], so this is an interned
   --  identity and not a token kind, exactly as Landin.Syntax.Parser
   --  already reads one.  A name that is none of them cannot reach here --
   --  the parser refused it and built an Error_Type -- so the answer is
   --  Ill_Typed and an assertion, not a diagnostic.
   function Named (Of_Table : Table; Id : Landin.Source.Names.Name_Id)
     return Landin.Types.Type_Kind
     with Pre  => Is_Prepared (Of_Table),
          Post => Named'Result in Landin.Types.Scalar_Name
                  or else Named'Result = Landin.Types.Ill_Typed;

   ------------------------------------------------------------------
   --  What a node has
   ------------------------------------------------------------------

   --  Undecided until the pass reaches it, which is why Landin.Types puts
   --  that value first: it is the default of the run below and needs no
   --  second array saying which entries have been written.
   function Type_Of
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Landin.Types.Type_Kind
     with Pre => Is_Prepared (Of_Table)
                 and then Covers (Of_Table, Of_Tree)
                 and then Landin.Syntax.Contains (Of_Tree, Node);

   --  Says what a node synthesised.  Once: a second Note on one node is a
   --  pass that walked it twice, which is the defect this refuses rather
   --  than the last write silently winning.
   procedure Note
     (Into    : in out Table;
      Of_Tree : Landin.Syntax.Tree;
      Node    : Landin.Syntax.Node_Id;
      Item    : Landin.Types.Type_Kind)
     with Pre  => Is_Prepared (Into)
                  and then Covers (Into, Of_Tree)
                  and then Landin.Syntax.Contains (Of_Tree, Node)
                  and then Item /= Landin.Types.Undecided
                  and then Type_Of (Into, Of_Tree, Node)
                           = Landin.Types.Undecided,
          Post => Type_Of (Into, Of_Tree, Node) = Item;

   --  Fixes an untyped integer literal at the type its context gives it
   --  [0190], or at [0200]'s default when the context is that there is
   --  none.  Only from Untyped_Integer, and so at most once for any node:
   --  an expression has one parent, so there is one context site above it,
   --  and a second commit would mean two.
   procedure Commit
     (Into    : in out Table;
      Of_Tree : Landin.Syntax.Tree;
      Node    : Landin.Syntax.Node_Id;
      To      : Landin.Types.Scalar_Name)
     with Pre  => Is_Prepared (Into)
                  and then Covers (Into, Of_Tree)
                  and then Landin.Syntax.Contains (Of_Tree, Node)
                  and then Type_Of (Into, Of_Tree, Node)
                           = Landin.Types.Untyped_Integer,
          Post => Type_Of (Into, Of_Tree, Node) = To;

   --  Marks a node the pass refused, so that every node above it declines
   --  to complain again.  From any state, because the node it is called on
   --  may already have synthesised a type that turned out to be the wrong
   --  one -- `x: u8 = true` refuses at the binding, and the literal keeps
   --  the type it correctly had.
   procedure Refuse
     (Into    : in out Table;
      Of_Tree : Landin.Syntax.Tree;
      Node    : Landin.Syntax.Node_Id)
     with Pre  => Is_Prepared (Into)
                  and then Covers (Into, Of_Tree)
                  and then Landin.Syntax.Contains (Of_Tree, Node),
          Post => Type_Of (Into, Of_Tree, Node) = Landin.Types.Ill_Typed;

   ------------------------------------------------------------------
   --  What a declaration has
   ------------------------------------------------------------------

   function Contains (Of_Table : Table; Id : Declaration_Id) return Boolean
     is (Id /= No_Declaration
         and then Natural (Id) <= Declaration_Limit (Of_Table))
     with Pre => Is_Prepared (Of_Table);

   function State_Of (Of_Table : Table; Id : Declaration_Id)
     return Progress
     with Pre => Is_Prepared (Of_Table) and then Contains (Of_Table, Id);

   function Type_Of (Of_Table : Table; Id : Declaration_Id)
     return Landin.Types.Type_Kind
     with Pre  => Is_Prepared (Of_Table) and then Contains (Of_Table, Id),
          Post => (if State_Of (Of_Table, Id) = Settled
                   then Type_Of'Result /= Landin.Types.Undecided);

   --  Opens the inference of a module binding written with [1790]'s `:=`,
   --  whose type is its value's and whose value may name another module
   --  binding.  Nothing else needs it: every other declaration the kernel
   --  has writes its type down, so it settles without opening anything.
   procedure Begin_Inference
     (Into : in out Table; Id : Declaration_Id)
     with Pre  => Is_Prepared (Into)
                  and then Contains (Into, Id)
                  and then State_Of (Into, Id) = Untouched,
          Post => State_Of (Into, Id) = Underway;

   procedure Settle
     (Into : in out Table;
      Id   : Declaration_Id;
      Item : Landin.Types.Type_Kind)
     with Pre  => Is_Prepared (Into)
                  and then Contains (Into, Id)
                  and then State_Of (Into, Id) /= Settled
                  and then Item /= Landin.Types.Undecided,
          Post => State_Of (Into, Id) = Settled
                  and then Type_Of (Into, Id) = Item;

private

   package Type_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Landin.Types.Type_Kind);

   --  One run per source, end to end in one vector, which is what
   --  Landin.Syntax does with a node's children and Landin.Resolution with
   --  a node's meaning.  First is where node 1 of that source's tree sits,
   --  so a reference is one addition.
   type Run is record
      First : Natural := 0;
      Count : Natural := 0;
   end record;

   package Run_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Run);

   type Settlement is record
      State  : Progress               := Untouched;
      Answer : Landin.Types.Type_Kind := Landin.Types.Undecided;
   end record;

   package Settlement_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Settlement);

   --  The eleven spellings' identities, interned once by Prepare.  An
   --  array over Scalar_Name and not a map: the set is fixed and closed,
   --  so a lookup is eleven integer comparisons and there is nothing to
   --  hash and no order to depend on.
   type Scalar_Identities is
     array (Landin.Types.Scalar_Name) of Landin.Source.Names.Name_Id;

   type Table is tagged limited record
      Ready        : Boolean := False;
      Node_Types   : Type_Vectors.Vector;
      Runs         : Run_Vectors.Vector;
      Declarations : Settlement_Vectors.Vector;
      Scalars      : Scalar_Identities :=
        [others => Landin.Source.Names.No_Name];
   end record;

end Landin.Checking;
