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
--  function type and D123 carries recursively nested descriptors through
--  storage, parameters, results and anonymous routines.  D128 gives each
--  descriptor an ordered result run and gives a two-or-more result value its
--  anonymous structural shape.  D131 puts the same descriptor beside a
--  function-valued ordinary or payload field.  Type_Kind says that
--  category and this table carries the complete signature descriptor beside
--  each relevant node and declaration.  It never substitutes the declaration
--  of one possible callee for that type evidence.  A call's type is its one
--  result, its anonymous aggregate result run, or No_Value for `-> none`.
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
private with System;

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

   type Table is tagged limited private;

   --  A nominal type is a checker-owned instance identity, distinct from
   --  the source declaration that supplies its template and owns storage.
   --  Callers may compare identities and retrieve identities held by a table,
   --  but cannot construct one from an integer.  The enabled
   --  nonparameterized struct is the canonical empty-actual instance of its
   --  template declaration; D137 extends the same table with normalized
   --  ordered actual tuples for concrete parameterized struct applications.
   package Nominal_Identities is
      type Id is private;

      function None return Id;
      function Nth (Of_Table : Table; Position : Positive) return Id;
      function Holds (Of_Table : Table; Of_Id : Id) return Boolean;
      function Position (Of_Table : Table; Of_Id : Id) return Positive
        with Pre => Holds (Of_Table, Of_Id);
   private
      type Id is range 0 .. Integer'Last;
      function From_Position (Position : Positive) return Id;
   end Nominal_Identities;

   subtype Nominal_Type_Id is Nominal_Identities.Id;
   use type Nominal_Type_Id;

   function No_Nominal_Type return Nominal_Type_Id
     renames Nominal_Identities.None;

   --  A generic routine instance is checker-owned identity, keyed by its
   --  source template and complete normalized actual tuple.  It is distinct
   --  from both the source declaration and nominal type identity.  Ordinary
   --  routines remain declaration-backed and therefore use None here.
   package Routine_Identities is
      type Id is private;

      function None return Id;
      function Nth (Of_Table : Table; Position : Positive) return Id;
      function Holds (Of_Table : Table; Of_Id : Id) return Boolean;
      function Position (Of_Table : Table; Of_Id : Id) return Positive
        with Pre => Holds (Of_Table, Of_Id);
   private
      type Id is range 0 .. Integer'Last;
      function From_Position (Position : Positive) return Id;
   end Routine_Identities;

   subtype Routine_Instance_Id is Routine_Identities.Id;
   use type Routine_Instance_Id;

   function No_Routine_Instance return Routine_Instance_Id
     renames Routine_Identities.None;

   function Holds (Of_Table : Table; Id : Routine_Instance_Id)
     return Boolean;

   --  Selects the fact layer used by every node and declaration query/write.
   --  Activating an instance never mutates the global module/nongeneric facts;
   --  an unwritten instance fact falls back to that global layer.  Nested
   --  checking and lowering must restore the returned previous view.
   function Current_Routine_View (Of_Table : Table)
     return Routine_Instance_Id;

   procedure Activate_Routine_View
     (Into     : in out Table;
      Instance : Routine_Instance_Id;
      Previous : out Routine_Instance_Id)
     with Pre  => Holds (Into, Instance),
          Post => Current_Routine_View (Into) = Instance;

   procedure Restore_Routine_View
     (Into     : in out Table;
      Previous : Routine_Instance_Id)
     with Pre  => Previous = No_Routine_Instance
                  or else Holds (Into, Previous),
          Post => Current_Routine_View (Into) = Previous;

   --  Where a declaration's type has got to.  Untouched and Settled are
   --  the two states a caller wants; Underway exists because of the module
   --  scope and nothing else, and it is public because the stage that
   --  reports the cycle is the one that has to see it.
   type Progress is (Untouched, Underway, Settled);

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

   function Nominal_Type_Count (Of_Table : Table) return Natural
     with Pre => Is_Prepared (Of_Table);

   function Nth_Nominal_Type
     (Of_Table : Table; Position : Positive) return Nominal_Type_Id
     with Pre => Is_Prepared (Of_Table)
                 and then Position <= Nominal_Type_Count (Of_Table);

   function Holds (Of_Table : Table; Id : Nominal_Type_Id) return Boolean;

   --  The source declaration that supplied an instance's template.  It is
   --  provenance and storage ownership, not the nominal identity itself.
   function Template_Of
     (Of_Table : Table; Id : Nominal_Type_Id) return Declaration_Id
     with Pre => Holds (Of_Table, Id);

   --  The canonical empty-actual instance for a nonparameterized struct
   --  template, or No_Nominal_Type for every other declaration.
   function Empty_Nominal_Instance
     (Of_Table : Table; Template : Declaration_Id) return Nominal_Type_Id
     with Pre => Is_Prepared (Of_Table)
                 and then Natural (Template) <= Declaration_Limit (Of_Table);

   --  Which nominal instance a node or declaration has the type of.
   --  [0710]: two structs are one type exactly when these answers agree.
   function Nominal_Of
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Nominal_Type_Id
     with Pre => Is_Prepared (Of_Table)
                 and then Covers (Of_Table, Of_Tree)
                 and then Landin.Syntax.Contains (Of_Tree, Node);

   function Nominal_Of
     (Of_Table : Table; Id : Declaration_Id) return Nominal_Type_Id
     with Pre => Is_Prepared (Of_Table)
                 and then Natural (Id) <= Declaration_Limit (Of_Table);

   procedure Note_Nominal
     (Into    : in out Table;
      Of_Tree : Landin.Syntax.Tree;
      Node    : Landin.Syntax.Node_Id;
      Nominal : Nominal_Type_Id)
     with Pre  => Is_Prepared (Into)
                  and then Covers (Into, Of_Tree)
                  and then Landin.Syntax.Contains (Of_Tree, Node)
                  and then Holds (Into, Nominal),
          Post => Nominal_Of (Into, Of_Tree, Node) = Nominal;

   procedure Note_Nominal
     (Into   : in out Table;
      Id     : Declaration_Id;
      Nominal : Nominal_Type_Id)
     with Pre  => Is_Prepared (Into)
                  and then Id /= No_Declaration
                  and then Natural (Id) <= Declaration_Limit (Into)
                  and then Holds (Into, Nominal),
          Post => Nominal_Of (Into, Id) = Nominal;

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
   --  Atom sets
   ------------------------------------------------------------------

   --  [0630]/[0640]: an atom is one declaration identity and an atom type
   --  is a nonempty set of those identities.  Set identity is structural:
   --  source order is retained for diagnostics and dumps but neither order
   --  nor the declaration that wrote a union makes two equal sets differ.
   type Atom_Set_Id is range 0 .. Integer'Last;
   No_Atom_Set : constant Atom_Set_Id := 0;

   type Atom_Array is array (Positive range <>) of Declaration_Id;
   No_Atoms : constant Atom_Array (1 .. 0) := [];

   function Atom_Set_Count (Of_Table : Table) return Natural
     with Pre => Is_Prepared (Of_Table);

   function Holds (Of_Table : Table; Id : Atom_Set_Id) return Boolean
     is (Is_Prepared (Of_Table)
         and then Id /= No_Atom_Set
         and then Natural (Id) <= Atom_Set_Count (Of_Table));

   function Add_Atom_Set
     (Into : in out Table; Atoms : Atom_Array) return Atom_Set_Id
     with Pre  => Is_Prepared (Into)
                  and then Atoms'Length > 0
                  and then
                    (for all Atom of Atoms =>
                       Atom /= No_Declaration
                       and then Natural (Atom) <= Declaration_Limit (Into)),
          Post => Atom_Set_Count (Into) = Atom_Set_Count (Into)'Old + 1
                  and then Holds (Into, Add_Atom_Set'Result);

   function Atom_Count
     (Of_Table : Table; Set_Id : Atom_Set_Id) return Natural
     with Pre => Holds (Of_Table, Set_Id);

   function Nth_Atom
     (Of_Table : Table; Set_Id : Atom_Set_Id; Index : Positive)
      return Declaration_Id
     with Pre => Holds (Of_Table, Set_Id)
                 and then Index <= Atom_Count (Of_Table, Set_Id);

   function Contains_Atom
     (Of_Table : Table; Set_Id : Atom_Set_Id; Atom : Declaration_Id)
      return Boolean
     with Pre => Holds (Of_Table, Set_Id)
                 and then Atom /= No_Declaration;

   function Atom_Sets_Agree
     (Of_Table : Table; Left, Right : Atom_Set_Id) return Boolean
     with Pre => Holds (Of_Table, Left) and then Holds (Of_Table, Right);

   function Is_Subset
     (Of_Table : Table; Left, Right : Atom_Set_Id) return Boolean
     with Pre => Holds (Of_Table, Left) and then Holds (Of_Table, Right);

   function Atom_Set_Of
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Atom_Set_Id
     with Pre => Is_Prepared (Of_Table)
                 and then Covers (Of_Table, Of_Tree)
                 and then Landin.Syntax.Contains (Of_Tree, Node);

   function Atom_Set_Of
     (Of_Table : Table; Id : Declaration_Id) return Atom_Set_Id
     with Pre => Is_Prepared (Of_Table)
                 and then Natural (Id) <= Declaration_Limit (Of_Table);

   procedure Note_Atom_Set
     (Into    : in out Table;
      Of_Tree : Landin.Syntax.Tree;
      Node    : Landin.Syntax.Node_Id;
      Set_Id  : Atom_Set_Id)
     with Pre  => Is_Prepared (Into)
                  and then Covers (Into, Of_Tree)
                  and then Landin.Syntax.Contains (Of_Tree, Node)
                  and then Holds (Into, Set_Id),
          Post => Atom_Set_Of (Into, Of_Tree, Node) = Set_Id;

   procedure Note_Atom_Set
     (Into   : in out Table;
      Id     : Declaration_Id;
      Set_Id : Atom_Set_Id)
     with Pre  => Is_Prepared (Into)
                  and then Id /= No_Declaration
                  and then Natural (Id) <= Declaration_Limit (Into)
                  and then Holds (Into, Set_Id),
          Post => Atom_Set_Of (Into, Id) = Set_Id;

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

   --  `! ...` exists only while whole-module inference is being solved.
   --  Target-neutral IR receives Infallible or Concrete descriptors only.
   type Error_Set_Form is (Infallible, Concrete, Inferred);

   type Signature_Part is record
      Kind    : Landin.Types.Type_Kind := Landin.Types.No_Value;
      Nominal : Nominal_Type_Id := No_Nominal_Type;
      Length  : Element_Count          := 0;
      Element : Landin.Types.Scalar_Name := Landin.Types.Bool;
      Signature : Signature_Id         := No_Signature;
      --  A result label is source-level shape for [0990].  Parameter labels
      --  may be retained too, but signature agreement deliberately ignores
      --  every label [1000].
      Name    : Landin.Source.Names.Name_Id :=
        Landin.Source.Names.No_Name;
      Atoms   : Atom_Set_Id             := No_Atom_Set;
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
      Results    : Signature_Part_Array;
      Site       : Landin.Provenance.Origin;
      Errors     : Atom_Set_Id := No_Atom_Set;
      Error_Form : Error_Set_Form := Infallible) return Signature_Id
     with Pre  => Is_Prepared (Into)
                  and then Landin.Provenance.Is_Known (Site)
                  and then
                    (if Error_Form = Concrete then Holds (Into, Errors)
                     else Errors = No_Atom_Set),
          Post => Signature_Count (Into) = Signature_Count (Into)'Old + 1
                  and then Holds (Into, Add_Signature'Result);

   --  Compatibility for builders of the former zero-or-one result shape.
   --  No_Value denotes an empty result run; every other part makes one.
   function Add_Signature
     (Into       : in out Table;
      Parameters : Signature_Part_Array;
      Result     : Signature_Part;
      Site       : Landin.Provenance.Origin;
      Errors     : Atom_Set_Id := No_Atom_Set;
      Error_Form : Error_Set_Form := Infallible) return Signature_Id
     with Pre  => Is_Prepared (Into)
                  and then Landin.Provenance.Is_Known (Site)
                  and then
                    (if Error_Form = Concrete then Holds (Into, Errors)
                     else Errors = No_Atom_Set),
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

   function Signature_Result_Count
     (Of_Table : Table; Signature : Signature_Id) return Natural
     with Pre => Holds (Of_Table, Signature);

   function Nth_Signature_Result
     (Of_Table : Table; Signature : Signature_Id; Index : Positive)
      return Signature_Part
     with Pre => Holds (Of_Table, Signature)
                 and then Index <= Signature_Result_Count
                                     (Of_Table, Signature);

   --  The former zero-or-one query.  It returns No_Value for an empty run
   --  and is only valid as a language result when the count is at most one.
   function Signature_Result
     (Of_Table : Table; Signature : Signature_Id) return Signature_Part
     with Pre => Holds (Of_Table, Signature)
                 and then Signature_Result_Count (Of_Table, Signature) <= 1;

   function Signature_Origin
     (Of_Table : Table; Signature : Signature_Id)
      return Landin.Provenance.Origin
     with Pre => Holds (Of_Table, Signature);

   function Signature_Error_Form
     (Of_Table : Table; Signature : Signature_Id) return Error_Set_Form
     with Pre => Holds (Of_Table, Signature);

   function Signature_Errors
     (Of_Table : Table; Signature : Signature_Id) return Atom_Set_Id
     with Pre => Holds (Of_Table, Signature);

   procedure Finalize_Inferred_Errors
     (Into     : in out Table;
      Signature : Signature_Id;
      Errors   : Atom_Set_Id)
     with Pre  => Holds (Into, Signature)
                  and then Signature_Error_Form (Into, Signature) = Inferred
                  and then (Errors = No_Atom_Set or else Holds (Into, Errors)),
          Post => Signature_Error_Form (Into, Signature) /= Inferred
                  and then Signature_Errors (Into, Signature) = Errors;

   --  Descriptor identity is deliberately not equality: a written type and
   --  a declaration may describe the same signature at different source
   --  sites.  Agreement ignores those sites and compares only language type
   --  identity.
   function Signatures_Agree
     (Of_Table : Table; Left, Right : Signature_Id) return Boolean
     with Pre => Holds (Of_Table, Left) and then Holds (Of_Table, Right);

   --  R2.40's nominal key is one source template plus an ordered tuple of
   --  normalized actuals.  The tuple deliberately has no source names,
   --  aliases, formal types, target widths or layout facts.  A fixed actual
   --  is its checked mathematical magnitude; the template implies the
   --  formal type.  Type actuals reuse the canonical descriptors this table
   --  already owns, so atom sets and function signatures remain structural.
   --
   --  Actual_Key is opaque so a caller cannot put a declaration spelling or
   --  a target fact into an identity.  Descriptor-bearing keys are bound to
   --  the one limited Table whose IDs they hold; equal numeric IDs from a
   --  second compilation do not hold here.  Scalar identities, scalar arrays
   --  and fixed magnitudes carry no table-owned descriptor and remain
   --  portable between tables.  These constructors are the complete
   --  currently enabled concrete type surface.
   type Actual_Key is private;
   type Actual_Tuple is private;

   type Actual_Kind is (Type_Actual_Kind, Fixed_Actual_Kind);
   type Actual_Type_Form is
     (Scalar_Actual_Type,
      Atom_Set_Actual_Type,
      Fixed_Array_Actual_Type,
      Nominal_Actual_Type,
      Function_Actual_Type);
   type Array_Element_Form is
     (Scalar_Array_Element, Nominal_Array_Element);

   function Empty_Actuals return Actual_Tuple;

   procedure Append_Actual
     (Into : in out Actual_Tuple; Actual : Actual_Key);

   function Scalar_Type_Actual
     (Scalar : Landin.Types.Scalar_Name) return Actual_Key;

   function Atom_Set_Type_Actual
     (Of_Table : Table; Atoms : Atom_Set_Id) return Actual_Key
     with Pre => Holds (Of_Table, Atoms);

   function Fixed_Array_Type_Actual
     (Length  : Element_Count;
      Element : Landin.Types.Scalar_Name) return Actual_Key;

   function Fixed_Array_Type_Actual
     (Of_Table : Table;
      Length   : Element_Count;
      Element  : Nominal_Type_Id) return Actual_Key
     with Pre => Holds (Of_Table, Element);

   function Nominal_Type_Actual
     (Of_Table : Table; Nominal : Nominal_Type_Id) return Actual_Key
     with Pre => Holds (Of_Table, Nominal);

   function Function_Type_Actual
     (Of_Table : Table; Signature : Signature_Id) return Actual_Key
     with Pre => Holds (Of_Table, Signature)
                 and then Signature_Error_Form (Of_Table, Signature)
                            /= Inferred;

   function Fixed_Actual (Value : Landin.Types.Magnitude) return Actual_Key;

   --  Whether every descriptor referenced by an opaque key or tuple belongs
   --  to this table.  Scalar and fixed keys hold in every prepared table.
   function Holds (Of_Table : Table; Key : Actual_Key) return Boolean;
   function Holds (Of_Table : Table; Actuals : Actual_Tuple) return Boolean;

   function Actual_Kind_Of (Key : Actual_Key) return Actual_Kind;

   function Type_Form_Of (Key : Actual_Key) return Actual_Type_Form
     with Pre => Actual_Kind_Of (Key) = Type_Actual_Kind;

   function Scalar_Of
     (Of_Table : Table; Key : Actual_Key) return Landin.Types.Scalar_Name
     with Pre => Holds (Of_Table, Key)
                 and then Actual_Kind_Of (Key) = Type_Actual_Kind
                 and then Type_Form_Of (Key) = Scalar_Actual_Type;

   function Atom_Set_Of
     (Of_Table : Table; Key : Actual_Key) return Atom_Set_Id
     with Pre => Holds (Of_Table, Key)
                 and then Actual_Kind_Of (Key) = Type_Actual_Kind
                 and then Type_Form_Of (Key) = Atom_Set_Actual_Type;

   function Array_Length_Of
     (Of_Table : Table; Key : Actual_Key) return Element_Count
     with Pre => Holds (Of_Table, Key)
                 and then Actual_Kind_Of (Key) = Type_Actual_Kind
                 and then Type_Form_Of (Key) = Fixed_Array_Actual_Type;

   function Array_Element_Form_Of
     (Of_Table : Table; Key : Actual_Key) return Array_Element_Form
     with Pre => Holds (Of_Table, Key)
                 and then Actual_Kind_Of (Key) = Type_Actual_Kind
                 and then Type_Form_Of (Key) = Fixed_Array_Actual_Type;

   function Array_Scalar_Element_Of
     (Of_Table : Table; Key : Actual_Key) return Landin.Types.Scalar_Name
     with Pre => Holds (Of_Table, Key)
                 and then Actual_Kind_Of (Key) = Type_Actual_Kind
                 and then Type_Form_Of (Key) = Fixed_Array_Actual_Type
                 and then Array_Element_Form_Of (Of_Table, Key)
                            = Scalar_Array_Element;

   function Array_Nominal_Element_Of
     (Of_Table : Table; Key : Actual_Key) return Nominal_Type_Id
     with Pre => Holds (Of_Table, Key)
                 and then Actual_Kind_Of (Key) = Type_Actual_Kind
                 and then Type_Form_Of (Key) = Fixed_Array_Actual_Type
                 and then Array_Element_Form_Of (Of_Table, Key)
                            = Nominal_Array_Element;

   function Nominal_Of
     (Of_Table : Table; Key : Actual_Key) return Nominal_Type_Id
     with Pre => Holds (Of_Table, Key)
                 and then Actual_Kind_Of (Key) = Type_Actual_Kind
                 and then Type_Form_Of (Key) = Nominal_Actual_Type;

   function Function_Signature_Of
     (Of_Table : Table; Key : Actual_Key) return Signature_Id
     with Pre => Holds (Of_Table, Key)
                 and then Actual_Kind_Of (Key) = Type_Actual_Kind
                 and then Type_Form_Of (Key) = Function_Actual_Type;

   function Fixed_Magnitude_Of
     (Key : Actual_Key) return Landin.Types.Magnitude
     with Pre => Actual_Kind_Of (Key) = Fixed_Actual_Kind;

   function Intern_Nominal_Instance
     (Into    : in out Table;
      Template : Declaration_Id;
      Actuals : Actual_Tuple) return Nominal_Type_Id
     with Pre  => Is_Prepared (Into)
                  and then Template /= No_Declaration
                  and then Natural (Template) <= Declaration_Limit (Into)
                  and then Holds (Into, Actuals),
          Post => Holds (Into, Intern_Nominal_Instance'Result)
                  and then Template_Of
                    (Into, Intern_Nominal_Instance'Result) = Template;

   --  The generic-struct checker can reconstruct a formal binding tuple from
   --  only its canonical nominal identity.  Traversal is bounded
   --  by the stored count and returns the same opaque keys accepted above.
   function Instance_Actual_Count
     (Of_Table : Table; Id : Nominal_Type_Id) return Natural
     with Pre => Holds (Of_Table, Id);

   function Nth_Instance_Actual
     (Of_Table : Table;
      Id       : Nominal_Type_Id;
      Position : Positive) return Actual_Key
     with Pre  => Holds (Of_Table, Id)
                  and then Position <= Instance_Actual_Count (Of_Table, Id),
          Post => Holds (Of_Table, Nth_Instance_Actual'Result);

   function Intern_Routine_Instance
     (Into     : in out Table;
      Template : Declaration_Id;
      Actuals  : Actual_Tuple) return Routine_Instance_Id
     with Pre  => Is_Prepared (Into)
                  and then Template /= No_Declaration
                  and then Natural (Template) <= Declaration_Limit (Into)
                  and then Holds (Into, Actuals),
          Post => Holds (Into, Intern_Routine_Instance'Result);

   function Routine_Instance_Count (Of_Table : Table) return Natural
     with Pre => Is_Prepared (Of_Table);

   function Routine_Template_Of
     (Of_Table : Table; Id : Routine_Instance_Id) return Declaration_Id
     with Pre => Holds (Of_Table, Id);

   function Routine_Actual_Count
     (Of_Table : Table; Id : Routine_Instance_Id) return Natural
     with Pre => Holds (Of_Table, Id);

   function Nth_Routine_Actual
     (Of_Table : Table;
      Id       : Routine_Instance_Id;
      Position : Positive) return Actual_Key
     with Pre  => Holds (Of_Table, Id)
                  and then Position <= Routine_Actual_Count (Of_Table, Id),
          Post => Holds (Of_Table, Nth_Routine_Actual'Result);

   type Routine_Instance_State is
     (Routine_Unseen, Routine_Building, Routine_Ready, Routine_Invalid);

   function Routine_State_Of
     (Of_Table : Table; Id : Routine_Instance_Id)
      return Routine_Instance_State
     with Pre => Holds (Of_Table, Id);

   procedure Begin_Routine_Instance
     (Into : in out Table; Id : Routine_Instance_Id)
     with Pre  => Holds (Into, Id)
                  and then Routine_State_Of (Into, Id) = Routine_Unseen,
          Post => Routine_State_Of (Into, Id) = Routine_Building;

   procedure Publish_Routine_Signature
     (Into      : in out Table;
      Id        : Routine_Instance_Id;
      Signature : Signature_Id)
     with Pre  => Holds (Into, Id)
                  and then Routine_State_Of (Into, Id) = Routine_Building
                  and then Holds (Into, Signature)
                  and then Routine_Signature_Of (Into, Id) = No_Signature,
          Post => Routine_Signature_Of (Into, Id) = Signature;

   function Routine_Signature_Of
     (Of_Table : Table; Id : Routine_Instance_Id) return Signature_Id
     with Pre => Holds (Of_Table, Id);

   procedure Finish_Routine_Instance
     (Into : in out Table; Id : Routine_Instance_Id)
     with Pre  => Holds (Into, Id)
                  and then Routine_State_Of (Into, Id) = Routine_Building
                  and then Routine_Signature_Of (Into, Id) /= No_Signature,
          Post => Routine_State_Of (Into, Id) = Routine_Ready;

   procedure Invalidate_Routine_Instance
     (Into : in out Table; Id : Routine_Instance_Id)
     with Pre  => Holds (Into, Id)
                  and then Routine_State_Of (Into, Id) = Routine_Building,
          Post => Routine_State_Of (Into, Id) = Routine_Invalid;

   --  A direct generic call records its chosen target in its caller's fact
   --  view.  A nongeneric caller writes the global layer; a generic caller
   --  writes only that routine instance's overlay.
   function Routine_Target_Of
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Call     : Landin.Syntax.Node_Id) return Routine_Instance_Id
     with Pre => Is_Prepared (Of_Table)
                 and then Covers (Of_Table, Of_Tree)
                 and then Landin.Syntax.Contains (Of_Tree, Call);

   procedure Note_Routine_Target
     (Into    : in out Table;
      Of_Tree : Landin.Syntax.Tree;
      Call    : Landin.Syntax.Node_Id;
      Target  : Routine_Instance_Id)
     with Pre  => Is_Prepared (Into)
                  and then Covers (Into, Of_Tree)
                  and then Landin.Syntax.Contains (Of_Tree, Call)
                  and then Holds (Into, Target),
          Post => Routine_Target_Of (Into, Of_Tree, Call) = Target;

   --  Instance construction and target-dependent layout share one state
   --  slot.  Interning alone leaves a new instance Unseen.  Building is the
   --  recursion guard for a parameterized body; Ready retains the completed
   --  layout. Invalid retains no application provenance and may transition
   --  back to Building so each use replays its dependent failure. None of
   --  these states is part of the interning key.
   type Instance_State is
     (Instance_Unseen, Instance_Building, Instance_Ready, Instance_Invalid);

   function Instance_State_Of
     (Of_Table : Table; Id : Nominal_Type_Id) return Instance_State
     with Pre => Holds (Of_Table, Id);

   procedure Begin_Instance
     (Into : in out Table; Id : Nominal_Type_Id)
     with Pre  => Holds (Into, Id)
                  and then Instance_State_Of (Into, Id) = Instance_Unseen,
          Post => Instance_State_Of (Into, Id) = Instance_Building;

   procedure Invalidate_Instance
     (Into : in out Table; Id : Nominal_Type_Id)
     with Pre  => Holds (Into, Id)
                  and then Instance_State_Of (Into, Id) = Instance_Building,
          Post => Instance_State_Of (Into, Id) = Instance_Invalid;

   --  Invalid records a target-layout attempt, not a failure owned by the
   --  canonical identity.  D137 requires an actual-dependent diagnostic at
   --  every application, so the stage may replay that bounded body walk
   --  while retaining this same interned identity and actual tuple.
   procedure Retry_Instance
     (Into : in out Table; Id : Nominal_Type_Id)
     with Pre  => Holds (Into, Id)
                  and then Instance_State_Of (Into, Id) = Instance_Invalid,
          Post => Instance_State_Of (Into, Id) = Instance_Building;

   --  A call with two or more named returns has an anonymous structural
   --  aggregate shape.  This side table carries the source signature whose
   --  result run names and types are that shape; ordinary nominal aggregates
   --  continue to use Nominal_Of.
   function Result_Shape_Of
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Signature_Id
     with Pre => Is_Prepared (Of_Table)
                 and then Covers (Of_Table, Of_Tree)
                 and then Landin.Syntax.Contains (Of_Tree, Node);

   function Result_Shape_Of
     (Of_Table : Table; Id : Declaration_Id) return Signature_Id
     with Pre => Is_Prepared (Of_Table)
                 and then Natural (Id) <= Declaration_Limit (Of_Table);

   procedure Note_Result_Shape
     (Into     : in out Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id;
      Signature : Signature_Id)
     with Pre  => Is_Prepared (Into)
                  and then Covers (Into, Of_Tree)
                  and then Landin.Syntax.Contains (Of_Tree, Node)
                  and then Holds (Into, Signature)
                  and then Signature_Result_Count (Into, Signature) > 1,
          Post => Result_Shape_Of (Into, Of_Tree, Node) = Signature;

   procedure Note_Result_Shape
     (Into      : in out Table;
      Id        : Declaration_Id;
      Signature : Signature_Id)
     with Pre  => Is_Prepared (Into)
                  and then Id /= No_Declaration
                  and then Natural (Id) <= Declaration_Limit (Into)
                  and then Holds (Into, Signature)
                  and then Signature_Result_Count (Into, Signature) > 1,
          Post => Result_Shape_Of (Into, Id) = Signature;

   --  Whole anonymous result values compare names and ordered part types.
   --  Function signatures use Signatures_Agree above, which compares the
   --  same ordered types while ignoring labels [1000].
   function Result_Shapes_Agree
     (Of_Table : Table; Left, Right : Signature_Id) return Boolean
     with Pre => Holds (Of_Table, Left) and then Holds (Of_Table, Right)
                 and then Signature_Result_Count (Of_Table, Left) > 1
                 and then Signature_Result_Count (Of_Table, Right) > 1;

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
      --  ordinary struct.  Both answer the same question -- which nominal
      --  instance this field is made of.
      Nominal : Nominal_Type_Id   := No_Nominal_Type;
      --  A function-valued field is one `usize` carrier whose complete
      --  recursive type remains this target-neutral signature.  Zero means
      --  an ordinary scalar field.
      Signature : Signature_Id            := No_Signature;
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

   --  Layout is target-dependent data keyed by target-independent nominal
   --  identity.  Source declarations and aliases reach it through Nominal_Of.
   function Has_Layout (Of_Table : Table; Id : Nominal_Type_Id)
     return Boolean
     with Pre => Is_Prepared (Of_Table);

   function Layout_Field_Count (Of_Table : Table; Id : Nominal_Type_Id)
     return Natural
     with Pre => Is_Prepared (Of_Table)
                 and then Holds (Of_Table, Id)
                 and then Has_Layout (Of_Table, Id);

   procedure Lay_Out
     (Into  : in out Table;
      Id    : Nominal_Type_Id;
      Fields : Field_Shape_Array;
      Facts : Landin.Targets.Target_Facts;
      Fits  : out Boolean;
      Cases : Case_Run_Array := No_Case_Runs;
      Payloads : Field_Shape_Array := No_Field_Shapes)
     with Pre  => Is_Prepared (Into)
                  and then Holds (Into, Id)
                  and then Instance_State_Of (Into, Id)
                             in Instance_Unseen | Instance_Building,
          Post => Has_Layout (Into, Id) = Fits
                  and then Instance_State_Of (Into, Id)
                             = (if Fits then Instance_Ready
                                else Instance_Invalid)
                  and then (if Fits then Layout_Field_Count (Into, Id)
                                         = Fields'Length);

   function Has_Variant_Part (Of_Table : Table; Id : Nominal_Type_Id)
     return Boolean
     with Pre => Is_Prepared (Of_Table)
                 and then Holds (Of_Table, Id)
                 and then Has_Layout (Of_Table, Id);

   function Has_Aggregate_Field (Of_Table : Table; Id : Nominal_Type_Id)
     return Boolean
     with Pre => Is_Prepared (Of_Table)
                 and then Holds (Of_Table, Id)
                 and then Has_Layout (Of_Table, Id);

   function Field_Shape_Of
     (Of_Table : Table; Id : Nominal_Type_Id; Field : Positive)
      return Field_Shape
     with Pre => Is_Prepared (Of_Table)
                 and then Holds (Of_Table, Id)
                 and then Has_Layout (Of_Table, Id)
                 and then Field <= Layout_Field_Count (Of_Table, Id);

   function Variant_Case_Field_Count
     (Of_Table : Table;
      Id       : Nominal_Type_Id;
      Field    : Positive;
      Which    : Positive) return Natural
     with Pre => Is_Prepared (Of_Table)
                 and then Holds (Of_Table, Id)
                 and then Has_Layout (Of_Table, Id)
                 and then Field <= Layout_Field_Count (Of_Table, Id)
                 and then Field_Shape_Of (Of_Table, Id, Field).Kind
                            = Variant_Field
                 and then Which <= Field_Shape_Of
                   (Of_Table, Id, Field).Cases;

   function Nth_Variant_Case_Field
     (Of_Table : Table;
      Id       : Nominal_Type_Id;
      Field    : Positive;
      Which    : Positive;
      Payload_Field : Positive) return Field_Shape
     with Pre => Is_Prepared (Of_Table)
                 and then Holds (Of_Table, Id)
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
      Id       : Nominal_Type_Id;
      Field    : Positive) return Landin.Targets.Byte_Count
     with Pre => Is_Prepared (Of_Table)
                 and then Holds (Of_Table, Id)
                 and then Has_Layout (Of_Table, Id)
                 and then Field <= Layout_Field_Count (Of_Table, Id);

   function Field_Kind_Of
     (Of_Table : Table;
      Id       : Nominal_Type_Id;
      Field    : Positive) return Field_Kind
     with Pre => Is_Prepared (Of_Table)
                 and then Holds (Of_Table, Id)
                 and then Has_Layout (Of_Table, Id)
                 and then Field <= Layout_Field_Count (Of_Table, Id);

   --  What a scalar field holds, kept beside where it sits so that a stage
   --  which has neither the tree nor a target can still lower the currently
   --  enabled runtime aggregate family.
   function Field_Type
     (Of_Table : Table;
      Id       : Nominal_Type_Id;
      Field    : Positive) return Landin.Types.Scalar_Name
     with Pre => Is_Prepared (Of_Table)
                 and then Holds (Of_Table, Id)
                 and then Has_Layout (Of_Table, Id)
                 and then Field <= Layout_Field_Count (Of_Table, Id)
                 and then Field_Kind_Of (Of_Table, Id, Field)
                            = Scalar_Field;

   function Field_Array_Length
     (Of_Table : Table;
      Id       : Nominal_Type_Id;
      Field    : Positive) return Element_Count
     with Pre => Is_Prepared (Of_Table)
                 and then Holds (Of_Table, Id)
                 and then Has_Layout (Of_Table, Id)
                 and then Field <= Layout_Field_Count (Of_Table, Id)
                 and then Field_Kind_Of (Of_Table, Id, Field)
                            = Fixed_Array_Field;

   function Field_Array_Element
     (Of_Table : Table;
      Id       : Nominal_Type_Id;
      Field    : Positive) return Landin.Types.Scalar_Name
     with Pre => Is_Prepared (Of_Table)
                 and then Holds (Of_Table, Id)
                 and then Has_Layout (Of_Table, Id)
                 and then Field <= Layout_Field_Count (Of_Table, Id)
                 and then Field_Kind_Of (Of_Table, Id, Field)
                            = Fixed_Array_Field;

   function Layout_Extent (Of_Table : Table; Id : Nominal_Type_Id)
     return Landin.Targets.Byte_Count
     with Pre => Is_Prepared (Of_Table)
                 and then Holds (Of_Table, Id)
                 and then Has_Layout (Of_Table, Id);

   function Layout_Alignment (Of_Table : Table; Id : Nominal_Type_Id)
     return Landin.Targets.Byte_Alignment
     with Pre => Is_Prepared (Of_Table)
                 and then Holds (Of_Table, Id)
                 and then Has_Layout (Of_Table, Id);

   function Layout_Size (Of_Table : Table; Id : Nominal_Type_Id)
     return Landin.Targets.Byte_Count
     with Pre => Is_Prepared (Of_Table)
                 and then Holds (Of_Table, Id)
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

   --  D121: which nominal ordinary struct instance an array's elements
   --  have, or No_Nominal_Type when the element is one of [1790]'s
   --  scalars.  It sits beside the length and the scalar element for the
   --  reason the aggregate's body does: a Type_Kind says the category and
   --  never which one.
   function Array_Element_Nominal
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Nominal_Type_Id
     with Pre => Is_Prepared (Of_Table)
                 and then Covers (Of_Table, Of_Tree)
                 and then Landin.Syntax.Contains (Of_Tree, Node);

   function Array_Element_Nominal
     (Of_Table : Table; Id : Declaration_Id) return Nominal_Type_Id
     with Pre => Is_Prepared (Of_Table) and then Contains (Of_Table, Id);

   procedure Note_Array_Element_Nominal
     (Into    : in out Table;
      Of_Tree : Landin.Syntax.Tree;
      Node    : Landin.Syntax.Node_Id;
      Nominal : Nominal_Type_Id)
     with Pre  => Is_Prepared (Into)
                  and then Covers (Into, Of_Tree)
                  and then Landin.Syntax.Contains (Of_Tree, Node)
                  and then (Nominal = No_Nominal_Type
                            or else Holds (Into, Nominal)),
          Post => Array_Element_Nominal (Into, Of_Tree, Node) = Nominal;

   procedure Note_Array_Element_Nominal
     (Into  : in out Table;
      Id      : Declaration_Id;
      Nominal : Nominal_Type_Id)
     with Pre  => Is_Prepared (Into)
                  and then Contains (Into, Id)
                  and then (Nominal = No_Nominal_Type
                            or else Holds (Into, Nominal)),
          Post => Array_Element_Nominal (Into, Id) = Nominal;

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
      Element   : Nominal_Type_Id;
      Size      : out Landin.Targets.Byte_Count;
      Alignment : out Landin.Targets.Byte_Alignment)
     with Pre => Is_Prepared (Of_Table)
                 and then Holds (Of_Table, Element)
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

   package Nominal_Id_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Nominal_Type_Id);

   package Nominal_Template_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Declaration_Id,
      "="          => Landin.Provenance."=");

   package Routine_Id_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Routine_Instance_Id);

   type Actual_Key is record
      Kind      : Actual_Kind := Type_Actual_Kind;
      Type_Form : Actual_Type_Form := Scalar_Actual_Type;
      Owner     : System.Address := System.Null_Address;
      Scalar    : Landin.Types.Scalar_Name := Landin.Types.Bool;
      Atoms     : Atom_Set_Id := No_Atom_Set;
      Length    : Element_Count := 0;
      Nominal   : Nominal_Type_Id := No_Nominal_Type;
      Signature : Signature_Id := No_Signature;
      Value     : Landin.Types.Magnitude := 0;
   end record;

   package Actual_Key_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Actual_Key);

   type Actual_Tuple is record
      Members : Actual_Key_Vectors.Vector;
   end record;

   type Routine_Instance_Record is record
      Template  : Declaration_Id := No_Declaration;
      Actuals   : Run;
      State     : Routine_Instance_State := Routine_Unseen;
      Signature : Signature_Id := No_Signature;
   end record;

   package Routine_Instance_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Routine_Instance_Record);

   package Atom_Set_Id_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Atom_Set_Id);

   package Atom_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Declaration_Id,
      "="          => Landin.Provenance."=");

   type Atom_Set_Record is record
      Members : Run;
   end record;

   package Atom_Set_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Atom_Set_Record);

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
      --  D121: which nominal ordinary struct instance the elements have,
      --  when they are not one of [1790]'s scalars.
      Element_Nominal : Nominal_Type_Id := No_Nominal_Type;
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
      Results    : Run;
      Site       : Landin.Provenance.Origin := Landin.Provenance.No_Origin;
      Errors     : Atom_Set_Id := No_Atom_Set;
      Error_Form : Error_Set_Form := Infallible;
   end record;

   package Signature_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Signature_Record);

   type Aggregate_Layout is record
      State  : Instance_State := Instance_Unseen;
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

   type Node_Overlay is record
      Instance : Routine_Instance_Id := No_Routine_Instance;
      Where    : Positive := 1;
      Has_Type : Boolean := False;
      Answer   : Landin.Types.Type_Kind := Landin.Types.Undecided;
      Has_Nominal : Boolean := False;
      Nominal  : Nominal_Type_Id := No_Nominal_Type;
      Has_Atoms : Boolean := False;
      Atoms    : Atom_Set_Id := No_Atom_Set;
      Has_Signature : Boolean := False;
      Signature : Signature_Id := No_Signature;
      Has_Result_Shape : Boolean := False;
      Result_Shape : Signature_Id := No_Signature;
      Has_Field : Boolean := False;
      Field     : Natural := 0;
      Has_Array : Boolean := False;
      Shape     : Array_Shape;
      Has_Array_Nominal : Boolean := False;
      Array_Nominal : Nominal_Type_Id := No_Nominal_Type;
      Has_Routine_Target : Boolean := False;
      Routine_Target : Routine_Instance_Id := No_Routine_Instance;
   end record;

   package Node_Overlay_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Node_Overlay);

   type Declaration_Overlay is record
      Instance : Routine_Instance_Id := No_Routine_Instance;
      Declared : Declaration_Id := No_Declaration;
      Has_Settlement : Boolean := False;
      Settlement_Fact : Settlement;
      Has_Nominal : Boolean := False;
      Nominal  : Nominal_Type_Id := No_Nominal_Type;
      Has_Atoms : Boolean := False;
      Atoms    : Atom_Set_Id := No_Atom_Set;
      Has_Signature : Boolean := False;
      Signature : Signature_Id := No_Signature;
      Has_Result_Shape : Boolean := False;
      Result_Shape : Signature_Id := No_Signature;
      Has_Array : Boolean := False;
      Shape     : Array_Shape;
      Has_Array_Nominal : Boolean := False;
      Array_Nominal : Nominal_Type_Id := No_Nominal_Type;
   end record;

   package Declaration_Overlay_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Declaration_Overlay);

   type Table is tagged limited record
      Ready        : Boolean := False;
      Node_Types   : Type_Vectors.Vector;
      --  Which checker-owned nominal instance an Aggregate node has.  Empty
      --  for every other node; source declarations remain separate metadata.
      Node_Nominals : Nominal_Id_Vectors.Vector;
      Node_Atom_Sets : Atom_Set_Id_Vectors.Vector;
      Node_Signatures : Signature_Id_Vectors.Vector;
      Node_Result_Shapes : Signature_Id_Vectors.Vector;
      Node_Routine_Targets : Routine_Id_Vectors.Vector;
      --  Which field a selection node names, in the same run.
      Node_Fields  : Index_Vectors.Vector;
      Node_Shapes  : Shape_Vectors.Vector;
      Shapes       : Shape_Vectors.Vector;
      Runs         : Run_Vectors.Vector;
      Declarations : Settlement_Vectors.Vector;
      Declaration_Nominals : Nominal_Id_Vectors.Vector;
      Empty_Nominals : Nominal_Id_Vectors.Vector;
      Nominal_Templates : Nominal_Template_Vectors.Vector;
      Nominal_Actual_Runs : Run_Vectors.Vector;
      Nominal_Actuals : Actual_Key_Vectors.Vector;
      Routine_Instances : Routine_Instance_Vectors.Vector;
      Routine_Actuals : Actual_Key_Vectors.Vector;
      Current_Routine : Routine_Instance_Id := No_Routine_Instance;
      Node_Overlays : Node_Overlay_Vectors.Vector;
      Declaration_Overlays : Declaration_Overlay_Vectors.Vector;
      Declaration_Atom_Sets : Atom_Set_Id_Vectors.Vector;
      Atom_Sets    : Atom_Set_Vectors.Vector;
      Atoms        : Atom_Vectors.Vector;
      Declaration_Signatures : Signature_Id_Vectors.Vector;
      Declaration_Result_Shapes : Signature_Id_Vectors.Vector;
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
