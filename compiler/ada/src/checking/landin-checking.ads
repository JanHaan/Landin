--  What type everything in a program has.
--
--  `spec.md` [1790] gives the kernel eleven types, [0190] says an integer
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
--  A declaration's type is the type of the VALUE its name denotes.  D113
--  makes a function name and an inferred Function_Value; D117 adds a written
--  function type and D118 carries recursively nested descriptors through
--  storage, parameters, results and anonymous routines.  Type_Kind says that
--  category and this table carries the complete signature descriptor beside
--  each relevant node and declaration.  It never substitutes the declaration
--  of one possible callee for that type evidence.  A call's type is its
--  descriptor's named result; `-> none` is No_Value.
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
with Landin.Targets;
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

   --  Which declaration wrote the aggregate a node or a declaration has
   --  the type of.  [0710]: two are one type when this answers the same
   --  declaration for both, and never otherwise.
   function Body_Of
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id)
     return Landin.Provenance.Declaration_Id
     with Pre => Is_Prepared (Of_Table)
                 and then Covers (Of_Table, Of_Tree)
                 and then Landin.Syntax.Contains (Of_Tree, Node);

   function Body_Of
     (Of_Table : Table; Id : Landin.Provenance.Declaration_Id)
     return Landin.Provenance.Declaration_Id
     with Pre => Is_Prepared (Of_Table)
                 and then Natural (Id) <= Declaration_Limit (Of_Table);

   procedure Note_Body
     (Into    : in out Table;
      Of_Tree : Landin.Syntax.Tree;
      Node    : Landin.Syntax.Node_Id;
      Wrote   : Landin.Provenance.Declaration_Id)
     with Pre  => Is_Prepared (Into)
                  and then Covers (Into, Of_Tree)
                  and then Landin.Syntax.Contains (Of_Tree, Node)
                  and then Wrote /= No_Declaration
                  and then Natural (Wrote) <= Declaration_Limit (Into),
          Post => Body_Of (Into, Of_Tree, Node) = Wrote;

   procedure Note_Body
     (Into  : in out Table;
      Id    : Landin.Provenance.Declaration_Id;
      Wrote : Landin.Provenance.Declaration_Id)
     with Pre  => Is_Prepared (Into)
                  and then Id /= No_Declaration
                  and then Wrote /= No_Declaration
                  and then Natural (Id) <= Declaration_Limit (Into)
                  and then Natural (Wrote) <= Declaration_Limit (Into),
          Post => Body_Of (Into, Id) = Wrote;

   ------------------------------------------------------------------
   --  How an aggregate is laid out
   ------------------------------------------------------------------

   --  A length is a count of elements and not of bytes, so it is not a
   --  Byte_Count: [0520] makes the length part of the type and [0370]'s
   --  `lenof` asks for it, while how many bytes that comes to needs a
   --  target.  Its range holds every enabled target's `usize`; D18 applies
   --  the particular target's byte-extent limit before one is recorded.
   type Element_Count is range 0 .. 2 ** 64 - 1;

   ------------------------------------------------------------------
   --  Function signatures
   ------------------------------------------------------------------

   --  D117: a function value carries a signature descriptor, never the
   --  declaration of one routine that happened to supply it.  The identity
   --  is dense within one compilation.  Each part retains only language
   --  type identity: a scalar name, [0710]'s nominal aggregate body, D17's
   --  array shape, or another structural signature for a function-valued
   --  position.  No width, offset, register or target byte appears here.
   type Signature_Id is range 0 .. Integer'Last;
   No_Signature : constant Signature_Id := 0;

   type Signature_Part is record
      Kind    : Landin.Types.Type_Kind := Landin.Types.No_Value;
      Aggregate_Body : Declaration_Id  := No_Declaration;
      Length  : Element_Count          := 0;
      Element : Landin.Types.Scalar_Name := Landin.Types.Bool;
      Signature : Signature_Id         := No_Signature;
      Site    : Landin.Provenance.Origin := Landin.Provenance.No_Origin;
   end record;

   type Signature_Part_Array is
     array (Positive range <>) of Signature_Part;

   No_Signature_Parts : constant Signature_Part_Array (1 .. 0) := [];

   function Signature_Count (Of_Table : Table) return Natural
     with Pre => Is_Prepared (Of_Table);

   function Holds (Of_Table : Table; Id : Signature_Id) return Boolean
     is (Is_Prepared (Of_Table)
         and then Id /= No_Signature
         and then Natural (Id) <= Signature_Count (Of_Table));

   function Add_Signature
     (Into       : in out Table;
      Parameters : Signature_Part_Array;
      Result     : Signature_Part;
      Site       : Landin.Provenance.Origin) return Signature_Id
     with Pre  => Is_Prepared (Into)
                  and then Landin.Provenance.Is_Known (Site),
          Post => Signature_Count (Into) = Signature_Count (Into)'Old + 1
                  and then Holds (Into, Add_Signature'Result);

   function Signature_Of
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Signature_Id
     with Pre => Is_Prepared (Of_Table)
                 and then Covers (Of_Table, Of_Tree)
                 and then Landin.Syntax.Contains (Of_Tree, Node);

   function Signature_Of
     (Of_Table : Table; Id : Declaration_Id) return Signature_Id
     with Pre => Is_Prepared (Of_Table)
                 and then Natural (Id) <= Declaration_Limit (Of_Table);

   procedure Note_Signature
     (Into    : in out Table;
      Of_Tree : Landin.Syntax.Tree;
      Node    : Landin.Syntax.Node_Id;
      Signature : Signature_Id)
     with Pre  => Is_Prepared (Into)
                  and then Covers (Into, Of_Tree)
                  and then Landin.Syntax.Contains (Of_Tree, Node)
                  and then Holds (Into, Signature),
          Post => Signature_Of (Into, Of_Tree, Node) = Signature;

   procedure Note_Signature
     (Into      : in out Table;
      Id        : Declaration_Id;
      Signature : Signature_Id)
     with Pre  => Is_Prepared (Into)
                  and then Id /= No_Declaration
                  and then Natural (Id) <= Declaration_Limit (Into)
                  and then Holds (Into, Signature),
          Post => Signature_Of (Into, Id) = Signature;

   function Signature_Parameter_Count
     (Of_Table : Table; Signature : Signature_Id) return Natural
     with Pre => Holds (Of_Table, Signature);

   function Nth_Signature_Parameter
     (Of_Table : Table; Signature : Signature_Id; Index : Positive)
      return Signature_Part
     with Pre => Holds (Of_Table, Signature)
                 and then Index <= Signature_Parameter_Count
                                     (Of_Table, Signature);

   function Signature_Result
     (Of_Table : Table; Signature : Signature_Id) return Signature_Part
     with Pre => Holds (Of_Table, Signature);

   function Signature_Origin
     (Of_Table : Table; Signature : Signature_Id)
      return Landin.Provenance.Origin
     with Pre => Holds (Of_Table, Signature);

   --  Descriptor identity is deliberately not equality: a written type and
   --  a declaration may describe the same signature at different source
   --  sites.  Agreement ignores those sites and compares only language type
   --  identity.
   function Signatures_Agree
     (Of_Table : Table; Left, Right : Signature_Id) return Boolean
     with Pre => Holds (Of_Table, Left) and then Holds (Of_Table, Right);

   --  Field order is declaration order [0750].  D45 adds one compact
   --  fixed-array leaf, D74 an unfolded variant part, and D86 a
   --  measurement-only named ordinary child.  The child keeps its nominal
   --  body; no target offset or byte extent is stored here.
   type Field_Kind is
     (Scalar_Field, Fixed_Array_Field, Aggregate_Field, Variant_Field);

   type Field_Shape is record
      Kind    : Field_Kind               := Scalar_Field;
      Element : Landin.Types.Scalar_Name := Landin.Types.Bool;
      Length  : Element_Count            := 1;
      Cases   : Natural                  := 0;
      Payloads_First : Natural           := 0;
      --  The child's body for an Aggregate_Field, and since D121 the
      --  element's body for a Fixed_Array_Field whose elements are an
      --  ordinary struct.  Both answer the same question -- which
      --  declaration wrote the struct this field is made of.
      Aggregate_Body : Declaration_Id    := No_Declaration;
   end record;

   type Field_Shape_Array is
     array (Positive range <>) of Field_Shape;

   --  One case's payload is a slice of the payload Field_Shape array
   --  supplied to Lay_Out.  A bare case has Count = 0.  These are source
   --  identities only; target offsets are deliberately absent.
   type Case_Run is record
      First : Natural := 0;
      Count : Natural := 0;
   end record;

   type Case_Run_Array is array (Positive range <>) of Case_Run;

   No_Field_Shapes : constant Field_Shape_Array (1 .. 0) := [];
   No_Case_Runs    : constant Case_Run_Array (1 .. 0) := [];

   --  Every query accepts either the body declaration or any alias of it;
   --  Body_Of is the canonical key, just as it is for nominal equality.
   function Has_Layout (Of_Table : Table; Id : Declaration_Id)
     return Boolean
     with Pre => Is_Prepared (Of_Table)
                 and then Contains (Of_Table, Id);

   function Layout_Field_Count (Of_Table : Table; Id : Declaration_Id)
     return Natural
     with Pre => Is_Prepared (Of_Table)
                 and then Contains (Of_Table, Id)
                 and then Has_Layout (Of_Table, Id);

   procedure Lay_Out
     (Into  : in out Table;
      Id    : Declaration_Id;
      Fields : Field_Shape_Array;
      Facts : Landin.Targets.Target_Facts;
      Fits  : out Boolean;
      Cases : Case_Run_Array := No_Case_Runs;
      Payloads : Field_Shape_Array := No_Field_Shapes)
     with Pre  => Is_Prepared (Into)
                  and then Contains (Into, Id)
                  and then Body_Of (Into, Id) = Id
                  and then not Has_Layout (Into, Id),
          Post => Has_Layout (Into, Id) = Fits
                  and then (if Fits then Layout_Field_Count (Into, Id)
                                         = Fields'Length);

   function Has_Variant_Part (Of_Table : Table; Id : Declaration_Id)
     return Boolean
     with Pre => Is_Prepared (Of_Table)
                 and then Contains (Of_Table, Id)
                 and then Has_Layout (Of_Table, Id);

   function Has_Aggregate_Field (Of_Table : Table; Id : Declaration_Id)
     return Boolean
     with Pre => Is_Prepared (Of_Table)
                 and then Contains (Of_Table, Id)
                 and then Has_Layout (Of_Table, Id);

   function Field_Shape_Of
     (Of_Table : Table; Id : Declaration_Id; Field : Positive)
      return Field_Shape
     with Pre => Is_Prepared (Of_Table)
                 and then Contains (Of_Table, Id)
                 and then Has_Layout (Of_Table, Id)
                 and then Field <= Layout_Field_Count (Of_Table, Id);

   function Variant_Case_Field_Count
     (Of_Table : Table;
      Id       : Declaration_Id;
      Field    : Positive;
      Which    : Positive) return Natural
     with Pre => Is_Prepared (Of_Table)
                 and then Contains (Of_Table, Id)
                 and then Has_Layout (Of_Table, Id)
                 and then Field <= Layout_Field_Count (Of_Table, Id)
                 and then Field_Shape_Of (Of_Table, Id, Field).Kind
                            = Variant_Field
                 and then Which <= Field_Shape_Of
                   (Of_Table, Id, Field).Cases;

   function Nth_Variant_Case_Field
     (Of_Table : Table;
      Id       : Declaration_Id;
      Field    : Positive;
      Which    : Positive;
      Payload_Field : Positive) return Field_Shape
     with Pre => Is_Prepared (Of_Table)
                 and then Contains (Of_Table, Id)
                 and then Has_Layout (Of_Table, Id)
                 and then Field <= Layout_Field_Count (Of_Table, Id)
                 and then Field_Shape_Of (Of_Table, Id, Field).Kind
                            = Variant_Field
                 and then Which <= Field_Shape_Of
                   (Of_Table, Id, Field).Cases
                 and then Payload_Field <= Variant_Case_Field_Count
                   (Of_Table, Id, Field, Which);

   function Field_Offset
     (Of_Table : Table;
      Id       : Declaration_Id;
      Field    : Positive) return Landin.Targets.Byte_Count
     with Pre => Is_Prepared (Of_Table)
                 and then Contains (Of_Table, Id)
                 and then Has_Layout (Of_Table, Id)
                 and then Field <= Layout_Field_Count (Of_Table, Id);

   function Field_Kind_Of
     (Of_Table : Table;
      Id       : Declaration_Id;
      Field    : Positive) return Field_Kind
     with Pre => Is_Prepared (Of_Table)
                 and then Contains (Of_Table, Id)
                 and then Has_Layout (Of_Table, Id)
                 and then Field <= Layout_Field_Count (Of_Table, Id);

   --  What a scalar field holds, kept beside where it sits so that a stage
   --  which has neither the tree nor a target can still lower the currently
   --  enabled runtime aggregate family.
   function Field_Type
     (Of_Table : Table;
      Id       : Declaration_Id;
      Field    : Positive) return Landin.Types.Scalar_Name
     with Pre => Is_Prepared (Of_Table)
                 and then Contains (Of_Table, Id)
                 and then Has_Layout (Of_Table, Id)
                 and then Field <= Layout_Field_Count (Of_Table, Id)
                 and then Field_Kind_Of (Of_Table, Id, Field)
                            = Scalar_Field;

   function Field_Array_Length
     (Of_Table : Table;
      Id       : Declaration_Id;
      Field    : Positive) return Element_Count
     with Pre => Is_Prepared (Of_Table)
                 and then Contains (Of_Table, Id)
                 and then Has_Layout (Of_Table, Id)
                 and then Field <= Layout_Field_Count (Of_Table, Id)
                 and then Field_Kind_Of (Of_Table, Id, Field)
                            = Fixed_Array_Field;

   function Field_Array_Element
     (Of_Table : Table;
      Id       : Declaration_Id;
      Field    : Positive) return Landin.Types.Scalar_Name
     with Pre => Is_Prepared (Of_Table)
                 and then Contains (Of_Table, Id)
                 and then Has_Layout (Of_Table, Id)
                 and then Field <= Layout_Field_Count (Of_Table, Id)
                 and then Field_Kind_Of (Of_Table, Id, Field)
                            = Fixed_Array_Field;

   function Layout_Extent (Of_Table : Table; Id : Declaration_Id)
     return Landin.Targets.Byte_Count
     with Pre => Is_Prepared (Of_Table)
                 and then Contains (Of_Table, Id)
                 and then Has_Layout (Of_Table, Id);

   function Layout_Alignment (Of_Table : Table; Id : Declaration_Id)
     return Landin.Targets.Byte_Alignment
     with Pre => Is_Prepared (Of_Table)
                 and then Contains (Of_Table, Id)
                 and then Has_Layout (Of_Table, Id);

   function Layout_Size (Of_Table : Table; Id : Declaration_Id)
     return Landin.Targets.Byte_Count
     with Pre => Is_Prepared (Of_Table)
                 and then Contains (Of_Table, Id)
                 and then Has_Layout (Of_Table, Id);

   --  Which field of its target a selection [1820] names, by [0750]'s
   --  order, or zero for every other node.  Recorded here for the reason
   --  the aggregate's identity is: the lookup is by name against a struct
   --  body, the checker is the stage that does it, and a later stage that
   --  redid it would be a second authority on the same question.
   function Field_Index
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Natural
     with Pre => Is_Prepared (Of_Table)
                 and then Covers (Of_Table, Of_Tree)
                 and then Landin.Syntax.Contains (Of_Tree, Node);

   procedure Note_Field
     (Into    : in out Table;
      Of_Tree : Landin.Syntax.Tree;
      Node    : Landin.Syntax.Node_Id;
      Which   : Positive)
     with Pre  => Is_Prepared (Into)
                  and then Covers (Into, Of_Tree)
                  and then Landin.Syntax.Contains (Of_Tree, Node),
          Post => Field_Index (Into, Of_Tree, Node) = Which;

   ------------------------------------------------------------------
   --  What an array is
   ------------------------------------------------------------------

   --  D17 makes an array structural, so its identity is what it is made
   --  of: a length and an element type.  Both are kept per node, beside
   --  what type the node has, for the reason a struct's declaration
   --  identity is -- a Type_Kind says the category and never which one.
   --
   function Array_Length
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Element_Count
     with Pre => Is_Prepared (Of_Table)
                 and then Covers (Of_Table, Of_Tree)
                 and then Landin.Syntax.Contains (Of_Tree, Node);

   function Array_Element
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Landin.Types.Scalar_Name
     with Pre => Is_Prepared (Of_Table)
                 and then Covers (Of_Table, Of_Tree)
                 and then Landin.Syntax.Contains (Of_Tree, Node);

   --  D121: which declaration wrote the ordinary struct an array's
   --  elements are, or No_Declaration when the element is one of [1790]'s
   --  scalars.  It sits beside the length and the scalar element for the
   --  reason the aggregate's body does: a Type_Kind says the category and
   --  never which one.
   function Array_Element_Body
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Declaration_Id
     with Pre => Is_Prepared (Of_Table)
                 and then Covers (Of_Table, Of_Tree)
                 and then Landin.Syntax.Contains (Of_Tree, Node);

   function Array_Element_Body
     (Of_Table : Table; Id : Declaration_Id) return Declaration_Id
     with Pre => Is_Prepared (Of_Table) and then Contains (Of_Table, Id);

   procedure Note_Array_Element_Body
     (Into    : in out Table;
      Of_Tree : Landin.Syntax.Tree;
      Node    : Landin.Syntax.Node_Id;
      Wrote   : Declaration_Id)
     with Pre  => Is_Prepared (Into)
                  and then Covers (Into, Of_Tree)
                  and then Landin.Syntax.Contains (Of_Tree, Node),
          Post => Array_Element_Body (Into, Of_Tree, Node) = Wrote;

   procedure Note_Array_Element_Body
     (Into  : in out Table;
      Id    : Declaration_Id;
      Wrote : Declaration_Id)
     with Pre  => Is_Prepared (Into) and then Contains (Into, Id),
          Post => Array_Element_Body (Into, Id) = Wrote;

   procedure Note_Array
     (Into    : in out Table;
      Of_Tree : Landin.Syntax.Tree;
      Node    : Landin.Syntax.Node_Id;
      Length  : Element_Count;
      Element : Landin.Types.Scalar_Name)
     with Pre  => Is_Prepared (Into)
                  and then Covers (Into, Of_Tree)
                  and then Landin.Syntax.Contains (Of_Tree, Node),
          Post => Array_Length (Into, Of_Tree, Node) = Length
                  and then Array_Element (Into, Of_Tree, Node) = Element;

   --  The same, for a declaration whose type is an array.
   function Array_Length
     (Of_Table : Table; Id : Declaration_Id) return Element_Count
     with Pre => Is_Prepared (Of_Table) and then Contains (Of_Table, Id);

   function Array_Element
     (Of_Table : Table; Id : Declaration_Id)
     return Landin.Types.Scalar_Name
     with Pre => Is_Prepared (Of_Table) and then Contains (Of_Table, Id);

   procedure Note_Array
     (Into    : in out Table;
      Id      : Declaration_Id;
      Length  : Element_Count;
      Element : Landin.Types.Scalar_Name)
     with Pre  => Is_Prepared (Into) and then Contains (Into, Id),
          Post => Array_Length (Into, Id) = Length
                  and then Array_Element (Into, Id) = Element;

   --  How much room one takes and how it must be aligned.  [0520] says an
   --  array is a value and [0750] lays its elements out end to end, so
   --  this is the element's own size repeated and the element's own
   --  alignment; a length of zero takes no room and aligns to a byte.
   procedure Array_Extent
     (Length    : Element_Count;
      Element   : Landin.Types.Scalar_Name;
      Facts     : Landin.Targets.Target_Facts;
      Size      : out Landin.Targets.Byte_Count;
      Alignment : out Landin.Targets.Byte_Alignment);

   --  D121's aggregate element.  Its extent is the element body's own
   --  padded layout, which is already computed by the time an array of it
   --  can be written: a struct is laid out before anything may hold one.
   procedure Array_Extent
     (Of_Table  : Table;
      Length    : Element_Count;
      Element   : Declaration_Id;
      Size      : out Landin.Targets.Byte_Count;
      Alignment : out Landin.Targets.Byte_Alignment)
     with Pre => Is_Prepared (Of_Table)
                 and then Contains (Of_Table, Element)
                 and then Has_Layout (Of_Table, Element);

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

   --  Marks a declaration while its type is being worked out.  [1790]'s
   --  `:=` may name another inferred module binding, and [1795]'s alias may
   --  name another alias; in either case reaching an Underway declaration
   --  is the cycle rather than recursion without an end.
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

   package Body_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Landin.Provenance.Declaration_Id,
      "="          => Landin.Provenance."=");

   package Signature_Id_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Signature_Id);

   package Signature_Part_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Signature_Part);

   package Offset_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Landin.Targets.Byte_Count,
      "="          => Landin.Targets."=");

   package Index_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Natural);

   --  What an array is made of, or a length of zero and a default element
   --  where the node is not one.  A record and not two vectors, because
   --  the two are one answer and are always written together.
   type Array_Shape is record
      Length  : Element_Count            := 0;
      Element : Landin.Types.Scalar_Name := Landin.Types.Bool;
      --  D121: which declaration wrote the ordinary struct the elements
      --  are, when they are not one of [1790]'s scalars.
      Element_Body : Declaration_Id      := No_Declaration;
   end record;

   package Shape_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Array_Shape);

   package Field_Shape_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Field_Shape);

   package Case_Run_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Case_Run);

   type Signature_Record is record
      Parameters : Run;
      Result     : Signature_Part;
      Site       : Landin.Provenance.Origin := Landin.Provenance.No_Origin;
   end record;

   package Signature_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Signature_Record);

   type Aggregate_Layout is record
      Ready  : Boolean := False;
      --  Payload shapes share Field_Shapes but have no top-level offset.
      --  Keep the two run starts distinct once a variant contributes those
      --  extra shapes between ordinary aggregate layouts.
      Shape_First : Natural := 0;
      First  : Natural := 0;
      Count  : Natural := 0;
      Placed : Landin.Targets.Placement := Landin.Targets.Empty_Placement;
   end record;

   package Layout_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Aggregate_Layout);

   type Table is tagged limited record
      Ready        : Boolean := False;
      Node_Types   : Type_Vectors.Vector;
      --  Which declaration an Aggregate node's type came from.  Empty for
      --  every other node, and the reason it is a side table rather than
      --  part of Landin.Types: what a type *is* has no room for which one
      --  it is, and [0710] makes two aggregates one type exactly when
      --  they came from one declaration.
      Node_Bodies  : Body_Vectors.Vector;
      Node_Signatures : Signature_Id_Vectors.Vector;
      --  Which field a selection node names, in the same run.
      Node_Fields  : Index_Vectors.Vector;
      Node_Shapes  : Shape_Vectors.Vector;
      Shapes       : Shape_Vectors.Vector;
      Runs         : Run_Vectors.Vector;
      Declarations : Settlement_Vectors.Vector;
      Bodies       : Body_Vectors.Vector;
      Declaration_Signatures : Signature_Id_Vectors.Vector;
      Signatures   : Signature_Vectors.Vector;
      Signature_Parts : Signature_Part_Vectors.Vector;
      Layouts      : Layout_Vectors.Vector;
      Field_Offsets : Offset_Vectors.Vector;
      Field_Shapes : Field_Shape_Vectors.Vector;
      Case_Runs    : Case_Run_Vectors.Vector;
      Scalars      : Scalar_Identities :=
        [others => Landin.Source.Names.No_Name];
   end record;

end Landin.Checking;
