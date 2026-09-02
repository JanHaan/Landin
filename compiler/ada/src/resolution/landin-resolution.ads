--  What every name in a program means.
--
--  `spec.md` [1840] is the authority: the scopes this grammar has, which
--  of them is ordered and which is a set, and where a named return is
--  declared.  It exists because [0130] and [0140] are two sentences about
--  scopes -- order inside a module does not matter, an inner scope may
--  shadow an outer name -- and a rule about an inner scope means nothing
--  until the inner ones are named.  R1.50 needed them named, so the tour
--  names them.  This package is [1840] made addressable, for the
--  constructs [1740]-[1820] enable and no others.
--
--  Three shapes, and each one is here for a reason that is not taste.
--
--  A declared thing is a Landin.Provenance.Declaration_Id and not an
--  identity of this package's own.  R1.60 will want a type per
--  declaration, R1.70 an IR value per declaration and R4.60 a debug entry
--  per declaration, and each of those is an array indexed by that number.
--  Whoever owns the numbering is depended on by all four, so it has to be
--  the package that knows nothing: Landin.Provenance holds where a
--  declaration is written and refuses to know what one means.  That is the
--  same layering Node_Id already has -- the dense integer lives with the
--  representation and the meanings live in side tables -- and it makes
--  R1.50 the first real writer of a table R0.40 built for it.
--
--  A resolution is one array of Declaration_Id per compilation, laid out
--  as one run per source with a first index, exactly as Landin.Syntax puts
--  every node's children end to end and gives each node a first slot.  A
--  Node_Id is dense inside its tree and a Source_Id is dense inside its
--  compilation, so a reference costs one addition and one index, with no
--  map, no hashing, and no order that depends on where the host put an
--  object.  What it costs is one Declaration_Id for every node rather than
--  for every name: about four bytes a node, of which only the
--  Name_Reference nodes are ever non-zero.  The alternative is a map keyed
--  on a node, which is the thing the flat tree exists to avoid.
--
--  A scope is a parent link and a sort, and visibility is the search order
--  rather than a rule applied to a result: Visible walks outward from the
--  scope it was given, so [0140]'s shadowing is what the loop does first.
--  Sequential visibility inside a body needs no field either.  What is in
--  this table when a reference is resolved is what is visible to it, so
--  [1840]'s unordered module is collecting every module declaration before
--  any body is walked, and its ordered body is declaring a local when the
--  walk reaches it.  One mechanism, two readings.
--
--  What this package does not do.  It resolves no type name: [1790] gives
--  the kernel eleven scalar spellings, and Landin.Syntax.Parser already
--  holds a Type_Name node to exactly those -- check.py compares that table
--  with the tour's own `type` rule -- so a second table here would be a
--  second authority on a question the tour has already answered once.
--  When R2.20 lets a program declare a type, a type position becomes a
--  reference like any other and nothing above changes.
--
--  It also holds no diagnostic.  A duplicate is a lookup that found
--  something and an unresolved name is one that did not; the codes belong
--  to Landin.Diagnostics.Resolution, and this package's contracts say
--  which of the two happened without spelling either.

private with Ada.Containers.Hashed_Maps;
private with Ada.Containers.Vectors;

with Landin.Provenance;
with Landin.Modules;
with Landin.Source;
with Landin.Source.Names;
with Landin.Syntax;
with Landin.Syntax.Forest;

package Landin.Resolution is

   use type Landin.Provenance.Declaration_Id;
   use type Landin.Modules.Module_Id;
   use type Landin.Source.Names.Name_Id;
   use type Landin.Source.Source_Id;
   use type Landin.Syntax.Node_Id;
   use type Landin.Syntax.Node_Kind;

   ------------------------------------------------------------------
   --  Identities
   ------------------------------------------------------------------

   subtype Declaration_Id is Landin.Provenance.Declaration_Id;

   No_Declaration : constant Declaration_Id :=
     Landin.Provenance.No_Declaration;

   --  [1840]'s program, module, file-import, signature and block scopes,
   --  plus compile-time
   --  declaration scopes for parameterized types, concepts and conformances.
   --  The module is one scope for the whole compilation,
   --  because a file is a set of declarations and there are no modules until
   --  [1410]'s directories arrive; the signature holds parameters and named
   --  returns; a type declaration holds its formals; and a block is a
   --  statement run, which is a function's body, an arm of an `if`, or an
   --  `else`.
   type Scope_Sort is
     (Program, Module_Scope, File_Imports, Signature,
      Type_Declaration, Concept_Declaration,
      Conformance_Declaration, Block);

   --  Visible and an ordinary integer, the same bargain Node_Id and
   --  Declaration_Id already struck: a caller can invent one, which is
   --  what Holds is for.
   type Scope_Id is range 0 .. Integer'Last;

   No_Scope : constant Scope_Id := 0;

   --  Opened by Prepare, so there is exactly one and nobody has to
   --  remember to make it.
   Program_Scope : constant Scope_Id := 1;

   --  What a declaration declares.  Derived from the node and the scope
   --  when it is recorded, never asked again: [1790]'s binding is one rule
   --  used by [1740] and by [1810], and which of the two it is, is which
   --  scope it is in.
   type Declaration_Sort is
     (Module_Function, Module_Atom, Module_Type, Module_Concept,
      Module_Binding, Case_Name,
      Type_Parameter, Fixed_Parameter, Parameter, Named_Return,
      Local_Binding, Pattern_Binding, Result_Binding, Error_Binding);

   --  The kinds of node that declare a name.  Not Has_Name: that answers
   --  for a Name_Reference and a Type_Name too, and neither declares
   --  anything.
   function Declares (Of_Kind : Landin.Syntax.Node_Kind) return Boolean
     is (Of_Kind in Landin.Syntax.Function_Declaration
                    | Landin.Syntax.Atom_Declaration
                    | Landin.Syntax.Type_Declaration
                    | Landin.Syntax.Concept_Declaration
                    | Landin.Syntax.Type_Formal
                    | Landin.Syntax.Fixed_Formal
                    | Landin.Syntax.Binding
                    | Landin.Syntax.Parameter
                    | Landin.Syntax.Named_Return
                    | Landin.Syntax.Variant_Case
                    | Landin.Syntax.Match_Binding
                    | Landin.Syntax.Destructured_Name
                    | Landin.Syntax.Recovery_Clause);

   type Table is tagged limited private;

   ------------------------------------------------------------------
   --  Building
   ------------------------------------------------------------------

   function Is_Prepared (Of_Table : Table) return Boolean;

   --  How many nodes this table has room for in that source's tree, which
   --  is how many that tree had when Prepare read the forest.
   function Node_Limit
     (Of_Table : Table; Id : Landin.Source.Source_Id) return Natural
     with Pre => Is_Prepared (Of_Table);

   --  True when this table was sized for that very tree, so a table
   --  prepared from another forest is a contract failure rather than an
   --  index that happens to be in range.
   function Covers (Of_Table : Table; Of_Tree : Landin.Syntax.Tree)
     return Boolean
     with Pre => Is_Prepared (Of_Table);

   --  Sizes the per-node run of every tree once, and opens [1740]'s one
   --  scope.  Once, because the forest is complete when the parse is: a
   --  table that grew as trees arrived would be a table whose size depends
   --  on when it was asked.
   procedure Prepare
     (Into   : in out Table;
      Trees  : Landin.Syntax.Forest.Table;
      Modules : Landin.Modules.Table)
     with Pre  => not Is_Prepared (Into),
          Post => Is_Prepared (Into)
                  and then Holds (Into, Program_Scope)
                  and then Sort_Of (Into, Program_Scope) = Program
                  and then Declaration_Count (Into) = 0;

   ------------------------------------------------------------------
   --  Scopes
   ------------------------------------------------------------------

   function Scope_Count (Of_Table : Table) return Natural;

   function Holds (Of_Table : Table; Scope : Scope_Id) return Boolean
     is (Scope /= No_Scope and then Natural (Scope) <= Scope_Count
                                                         (Of_Table));

   function Sort_Of (Of_Table : Table; Scope : Scope_Id) return Scope_Sort
     with Pre => Holds (Of_Table, Scope);

   function Enclosing (Of_Table : Table; Scope : Scope_Id) return Scope_Id
     with Pre  => Holds (Of_Table, Scope),
          Post => Enclosing'Result < Scope;

   function Module_Scope_Of
     (Of_Table : Table; Module : Landin.Modules.Module_Id) return Scope_Id
     with Pre  => Is_Prepared (Of_Table)
                  and then Module /= Landin.Modules.No_Module,
          Post => Holds (Of_Table, Module_Scope_Of'Result)
                  and then Sort_Of
                    (Of_Table, Module_Scope_Of'Result) = Module_Scope;

   function File_Scope_Of
     (Of_Table : Table; Source : Landin.Source.Source_Id) return Scope_Id
     with Pre  => Is_Prepared (Of_Table)
                  and then Source /= Landin.Source.No_Source,
          Post => Holds (Of_Table, File_Scope_Of'Result)
                  and then Sort_Of
                    (Of_Table, File_Scope_Of'Result) = File_Imports;

   --  A scope inside another.  Program is not openable: [1740] gives the
   --  compilation one and Prepare made it.
   function Open_Scope
     (Into : in out Table; Sort : Scope_Sort; Inside : Scope_Id)
     return Scope_Id
     with Pre  => Is_Prepared (Into)
                  and then Sort not in Program | Module_Scope | File_Imports
                  and then Holds (Into, Inside),
          Post => Scope_Count (Into) = Scope_Count (Into)'Old + 1
                  and then Holds (Into, Open_Scope'Result)
                  and then Enclosing (Into, Open_Scope'Result) = Inside
                  and then Sort_Of (Into, Open_Scope'Result) = Sort;

   ------------------------------------------------------------------
   --  Declarations
   ------------------------------------------------------------------

   function Declaration_Count (Of_Table : Table) return Natural;

   function Contains (Of_Table : Table; Id : Declaration_Id) return Boolean
     is (Id /= No_Declaration
         and then Natural (Id) <= Declaration_Count (Of_Table));

   function Name_Of (Of_Table : Table; Id : Declaration_Id)
     return Landin.Source.Names.Name_Id
     with Pre => Contains (Of_Table, Id);

   function Sort_Of (Of_Table : Table; Id : Declaration_Id)
     return Declaration_Sort
     with Pre => Contains (Of_Table, Id);

   function Scope_Of (Of_Table : Table; Id : Declaration_Id)
     return Scope_Id
     with Pre  => Contains (Of_Table, Id),
          Post => Holds (Of_Table, Scope_Of'Result);

   --  Which tree and which node declared it, so R1.60 can read the type
   --  the declaration was written with.  The source is here as well as in
   --  the site table because a Node_Id names nothing without its tree;
   --  the two cannot disagree, because Declare_Name writes both from one
   --  node.
   function Source_Of (Of_Table : Table; Id : Declaration_Id)
     return Landin.Source.Source_Id
     with Pre  => Contains (Of_Table, Id),
          Post => Source_Of'Result /= Landin.Source.No_Source;

   function Node_Of (Of_Table : Table; Id : Declaration_Id)
     return Landin.Syntax.Node_Id
     with Pre  => Contains (Of_Table, Id),
          Post => Node_Of'Result /= Landin.Syntax.No_Node;

   --  `public` as [1740] wrote it, carried so that R3.10 has it without
   --  reading the tree again.  Always False below the program scope: the
   --  parser refused the word on a statement and said so.
   function Is_Public (Of_Table : Table; Id : Declaration_Id)
     return Boolean
     with Pre => Contains (Of_Table, Id);

   --  What this scope itself gives that name, so a duplicate is something
   --  found rather than two lists compared, and No_Declaration otherwise.
   function Declared_Here
     (Of_Table : Table;
      Scope    : Scope_Id;
      Name     : Landin.Source.Names.Name_Id) return Declaration_Id
     with Pre  => Is_Prepared (Of_Table) and then Holds (Of_Table, Scope),
          Post => Declared_Here'Result = No_Declaration
                  or else (Contains (Of_Table, Declared_Here'Result)
                           and then Scope_Of
                                      (Of_Table, Declared_Here'Result)
                                    = Scope
                           and then Name_Of
                                      (Of_Table, Declared_Here'Result)
                                    = Name);

   --  What this scope or an enclosing one gives that name.  Innermost
   --  first: [0140] is the order of the search and not a rule applied to
   --  its result.
   function Visible
     (Of_Table : Table;
      Scope    : Scope_Id;
      Name     : Landin.Source.Names.Name_Id) return Declaration_Id
     with Pre  => Is_Prepared (Of_Table) and then Holds (Of_Table, Scope),
          Post => Visible'Result = No_Declaration
                  or else (Contains (Of_Table, Visible'Result)
                           and then Name_Of (Of_Table, Visible'Result)
                                    = Name);

   function Visible_Public_In_Module
     (Of_Table : Table;
      Module   : Landin.Modules.Module_Id;
      Name     : Landin.Source.Names.Name_Id) return Declaration_Id
     with Pre => Is_Prepared (Of_Table)
                 and then Module /= Landin.Modules.No_Module;

   function Imported_Module_Of
     (Of_Table : Table;
      Source   : Landin.Source.Source_Id;
      Name     : Landin.Source.Names.Name_Id)
      return Landin.Modules.Module_Id
     with Pre => Is_Prepared (Of_Table)
                 and then Source /= Landin.Source.No_Source;

   function Import_Origin
     (Of_Table : Table;
      Source   : Landin.Source.Source_Id;
      Name     : Landin.Source.Names.Name_Id) return Landin.Provenance.Origin
     with Pre => Is_Prepared (Of_Table)
                 and then Imported_Module_Of (Of_Table, Source, Name)
                            /= Landin.Modules.No_Module;

   procedure Bind_Imported_Module
     (Into  : in out Table;
      Source : Landin.Source.Source_Id;
      Name   : Landin.Source.Names.Name_Id;
      Target : Landin.Modules.Module_Id;
      Origin : Landin.Provenance.Origin)
     with Pre  => Is_Prepared (Into)
                  and then Source /= Landin.Source.No_Source
                  and then Name /= Landin.Source.Names.No_Name
                  and then Target /= Landin.Modules.No_Module
                  and then Imported_Module_Of (Into, Source, Name)
                             = Landin.Modules.No_Module,
          Post => Imported_Module_Of (Into, Source, Name) = Target;

   --  Records one declaration and returns its identity.  It takes the node
   --  that declares it rather than the parts of one, so the name, the
   --  place and the export cannot disagree with the tree it came from.
   --
   --  Sites gets the anchor and not the extent, because Landin.Syntax
   --  promises that a declaration's anchor is where its name is written,
   --  and that is the span both a duplicate report and R4.60 point at.
   --
   --  A name already declared in this scope is refused by contract rather
   --  than recorded twice.  That is the recovery as well as the rule: the
   --  first declaration keeps the name, every reference binds to it, and
   --  one duplicate produces one report instead of a second scope entry
   --  that later stages would have to choose between.
   function Declare_Name
     (Into    : in out Table;
      Sites   : in out Landin.Provenance.Table;
      Of_Tree : Landin.Syntax.Tree;
      Node    : Landin.Syntax.Node_Id;
      Inside  : Scope_Id;
      Inherits_Public : Boolean := False) return Declaration_Id
     with Pre  => Is_Prepared (Into)
                  and then Holds (Into, Inside)
                  and then Landin.Syntax.Contains (Of_Tree, Node)
                  and then Declares (Landin.Syntax.Kind (Of_Tree, Node))
                  and then Declared_Here
                             (Into, Inside,
                              Landin.Syntax.Name (Of_Tree, Node))
                           = No_Declaration,
          Post => Declaration_Count (Into)
                    = Declaration_Count (Into)'Old + 1
                  and then Contains (Into, Declare_Name'Result)
                  and then Scope_Of (Into, Declare_Name'Result) = Inside
                  and then Node_Of (Into, Declare_Name'Result) = Node
                  and then Source_Of (Into, Declare_Name'Result)
                           = Landin.Syntax.Source_Of (Of_Tree)
                  and then Name_Of (Into, Declare_Name'Result)
                           = Landin.Syntax.Name (Of_Tree, Node)
                  and then Declared_Here
                             (Into, Inside,
                              Landin.Syntax.Name (Of_Tree, Node))
                           = Declare_Name'Result
                  and then Landin.Provenance.Contains
                             (Sites, Declare_Name'Result);

   ------------------------------------------------------------------
   --  What a reference means
   ------------------------------------------------------------------

   --  Three answers and no fourth.  Unresolved is a value and not an
   --  absence, for the reason an unreadable construct is an Error node and
   --  not a gap: the program is data, and R1.60 has to be able to decline
   --  to type a node without re-deciding what kind of node it was.  One
   --  number meaning both "not a name" and "not found" is how a missing
   --  name becomes a cascade.
   --
   --  Derived rather than stored, which is what Landin.Syntax.Has_Name
   --  already does with the neighbouring question: the array holds one
   --  Declaration_Id per node, and the verdict is that number read next to
   --  the node's kind.
   type Verdict is (Not_A_Reference, Unresolved, Bound);

   function Verdict_Of
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Verdict
     with Pre => Is_Prepared (Of_Table)
                 and then Covers (Of_Table, Of_Tree)
                 and then Landin.Syntax.Contains (Of_Tree, Node);

   function Bound_To
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Declaration_Id
     with Pre  => Is_Prepared (Of_Table)
                  and then Covers (Of_Table, Of_Tree)
                  and then Landin.Syntax.Contains (Of_Tree, Node)
                  and then Verdict_Of (Of_Table, Of_Tree, Node) = Bound,
          Post => Contains (Of_Table, Bound_To'Result);

   --  Which scope a node opened, or No_Scope for the nodes that open none
   --  -- which is nearly all of them.  [1840] gives the kernel three sorts
   --  of scope and only four kinds of node open one: a function's
   --  signature and its body, an arm, and an `else`.
   --
   --  It is here and not worked out again by a later stage, and that is
   --  the point of it.  R1.70's lowering has to give every block a scope,
   --  and Landin.IR's header says why it may not derive one: "a scope tree
   --  here would be a second authority on a question R1.50 answered once".
   --  Rebuilding it is also the easy thing to get quietly wrong -- an
   --  arm's blocks landing in the function's body scope reads correctly
   --  and breaks [1840]'s sibling rule, which is what
   --  `positive/arm-scopes-are-siblings` exists to catch.  R4.60 wants the
   --  same answer, to say which instructions a scope covers.
   function Scope_At
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Scope_Id
     with Pre => Is_Prepared (Of_Table)
                 and then Covers (Of_Table, Of_Tree)
                 and then Landin.Syntax.Contains (Of_Tree, Node);

   --  Says a node opened a scope.  Once, for Bind's reason: a node that
   --  opened two scopes is a resolver that walked it twice.
   procedure Record_Scope
     (Into    : in out Table;
      Of_Tree : Landin.Syntax.Tree;
      Node    : Landin.Syntax.Node_Id;
      Opened  : Scope_Id)
     with Pre  => Is_Prepared (Into)
                  and then Covers (Into, Of_Tree)
                  and then Landin.Syntax.Contains (Of_Tree, Node)
                  and then Holds (Into, Opened)
                  and then Opened /= Program_Scope
                  and then Scope_At (Into, Of_Tree, Node) = No_Scope,
          Post => Scope_At (Into, Of_Tree, Node) = Opened;

   --  Says what one reference means.  Once: a second Bind on the same node
   --  is a contract failure, because a name that resolved twice is a
   --  resolver that walked a node twice.
   procedure Bind
     (Into    : in out Table;
      Of_Tree : Landin.Syntax.Tree;
      Node    : Landin.Syntax.Node_Id;
      To      : Declaration_Id)
     with Pre  => Is_Prepared (Into)
                  and then Covers (Into, Of_Tree)
                  and then Landin.Syntax.Contains (Of_Tree, Node)
                  and then Landin.Syntax.Kind (Of_Tree, Node)
                           in Landin.Syntax.Name_Reference
                              | Landin.Syntax.Type_Reference
                              | Landin.Syntax.Concept_Reference
                              | Landin.Syntax.Member_Selection
                  and then Contains (Into, To)
                  and then
                    (if Landin.Syntax.Kind (Of_Tree, Node)
                           = Landin.Syntax.Member_Selection
                     then Verdict_Of (Into, Of_Tree, Node) = Not_A_Reference
                     else Verdict_Of (Into, Of_Tree, Node) = Unresolved),
          Post => Verdict_Of (Into, Of_Tree, Node) = Bound
                  and then Bound_To (Into, Of_Tree, Node) = To;

   ------------------------------------------------------------------
   --  Named-return sources
   ------------------------------------------------------------------

   --  [0790]'s `from` names parameter labels in a signature, including a
   --  written function type whose labels declare nothing [1800].  Resolution
   --  therefore records a runtime position rather than inventing a lexical
   --  declaration for the label.  Zero means no matching position was found;
   --  the later R2.50 checker owns that source diagnostic and the body-to-
   --  signature agreement.
   function Source_Parameter_Position
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Source   : Landin.Syntax.Node_Id) return Natural
     with Pre => Is_Prepared (Of_Table)
                 and then Covers (Of_Table, Of_Tree)
                 and then Landin.Syntax.Contains (Of_Tree, Source)
                 and then Landin.Syntax.Kind (Of_Tree, Source)
                            = Landin.Syntax.Return_Source;

   procedure Associate_Return_Source
     (Into    : in out Table;
      Of_Tree : Landin.Syntax.Tree;
      Source  : Landin.Syntax.Node_Id;
      Position : Positive)
     with Pre  => Is_Prepared (Into)
                  and then Covers (Into, Of_Tree)
                  and then Landin.Syntax.Contains (Of_Tree, Source)
                  and then Landin.Syntax.Kind (Of_Tree, Source)
                             = Landin.Syntax.Return_Source
                  and then Source_Parameter_Position
                             (Into, Of_Tree, Source) = 0,
          Post => Source_Parameter_Position
                    (Into, Of_Tree, Source) = Position;

   ------------------------------------------------------------------
   --  Direct labelled applications
   ------------------------------------------------------------------

   --  Resolution classifies the callee before touching an argument RHS.
   --  Unclassified is retained data: checking can then diagnose a scalar,
   --  non-callable value, or unresolved alias without resolution guessing.
   type Application_Class is
     (Unclassified_Application, Function_Call, Type_Construction,
      Case_Construction);

   type Argument_Role is
     (Unmatched_Argument, Runtime_Argument, Type_Argument, Fixed_Argument,
      Field_Argument, Payload_Argument, Fill_Argument);

   --  Runtime matching is completed once the checker has the callee's
   --  structural signature.  Resolution can classify a direct declaration
   --  earlier, but selected and function-valued callees deliberately use the
   --  same final match rather than reconstructing source declarations.
   type Call_Match_State is (Call_Not_Matched, Call_Matched, Call_Rejected);

   function Class_Of
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Application_Class
     with Pre => Is_Prepared (Of_Table)
                 and then Covers (Of_Table, Of_Tree)
                 and then Landin.Syntax.Kind (Of_Tree, Node)
                            = Landin.Syntax.Labeled_Application;

   function Match_Of
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Call_Match_State
     with Pre => Is_Prepared (Of_Table)
                 and then Covers (Of_Table, Of_Tree)
                 and then Landin.Syntax.Kind (Of_Tree, Node)
                            = Landin.Syntax.Labeled_Application;

   function Role_Of
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Argument : Landin.Syntax.Node_Id) return Argument_Role
     with Pre => Is_Prepared (Of_Table)
                 and then Covers (Of_Table, Of_Tree)
                 and then Landin.Syntax.Kind (Of_Tree, Argument)
                            = Landin.Syntax.Call_Argument;

   function Formal_Of
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Argument : Landin.Syntax.Node_Id) return Declaration_Id
     with Pre => Is_Prepared (Of_Table)
                 and then Covers (Of_Table, Of_Tree)
                 and then Landin.Syntax.Kind (Of_Tree, Argument)
                            = Landin.Syntax.Call_Argument;

   function Position_Of
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Argument : Landin.Syntax.Node_Id) return Natural
     with Pre => Is_Prepared (Of_Table)
                 and then Covers (Of_Table, Of_Tree)
                 and then Landin.Syntax.Kind (Of_Tree, Argument)
                            = Landin.Syntax.Call_Argument;

   procedure Classify
     (Into    : in out Table;
      Of_Tree : Landin.Syntax.Tree;
      Node    : Landin.Syntax.Node_Id;
      As_Kind : Application_Class)
     with Pre => Is_Prepared (Into)
                 and then Covers (Into, Of_Tree)
                 and then Landin.Syntax.Kind (Of_Tree, Node)
                            = Landin.Syntax.Labeled_Application
                 and then Class_Of (Into, Of_Tree, Node)
                            = Unclassified_Application;

   procedure Match_Argument
     (Into     : in out Table;
      Of_Tree  : Landin.Syntax.Tree;
      Argument : Landin.Syntax.Node_Id;
      As_Role  : Argument_Role;
      Position : Natural;
      Formal   : Declaration_Id := No_Declaration)
     with Pre => Is_Prepared (Into)
                 and then Covers (Into, Of_Tree)
                 and then Landin.Syntax.Kind (Of_Tree, Argument)
                            = Landin.Syntax.Call_Argument
                 and then Role_Of (Into, Of_Tree, Argument)
                            = Unmatched_Argument
                 and then (Formal = No_Declaration
                           or else Contains (Into, Formal));

   --  The checker remaps runtime arguments from written order onto ABI formal
   --  positions.  A direct-resolution formal is retained when it still
   --  agrees; indirect signatures have no declaration target and keep none.
   procedure Match_Runtime_Argument
     (Into     : in out Table;
      Of_Tree  : Landin.Syntax.Tree;
      Argument : Landin.Syntax.Node_Id;
      Position : Positive)
     with Pre  => Is_Prepared (Into)
                  and then Covers (Into, Of_Tree)
                  and then Landin.Syntax.Kind (Of_Tree, Argument)
                             = Landin.Syntax.Call_Argument
                  and then Role_Of (Into, Of_Tree, Argument)
                             in Unmatched_Argument | Runtime_Argument,
          Post => Role_Of (Into, Of_Tree, Argument) = Runtime_Argument
                  and then Position_Of (Into, Of_Tree, Argument) = Position;

   procedure Finish_Call_Match
     (Into     : in out Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id;
      Accepted : Boolean)
     with Pre  => Is_Prepared (Into)
                  and then Covers (Into, Of_Tree)
                  and then Landin.Syntax.Kind (Of_Tree, Node)
                             = Landin.Syntax.Labeled_Application,
          Post => Match_Of (Into, Of_Tree, Node)
                    = (if Accepted then Call_Matched else Call_Rejected);

private

   type Declaration is record
      Sort   : Declaration_Sort            := Local_Binding;
      Name   : Landin.Source.Names.Name_Id := Landin.Source.Names.No_Name;
      Scope  : Scope_Id                    := No_Scope;
      Source : Landin.Source.Source_Id     := Landin.Source.No_Source;
      Node   : Landin.Syntax.Node_Id       := Landin.Syntax.No_Node;
      Public : Boolean                     := False;
   end record;

   package Declaration_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Declaration);

   type Scope is record
      Sort      : Scope_Sort := Program;
      Enclosing : Scope_Id   := No_Scope;
   end record;

   package Scope_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Scope);

   package Scope_Id_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Scope_Id);

   --  One run per source, end to end in one vector, which is what
   --  Landin.Syntax does with a node's children.  First is where node 1 of
   --  that source's tree sits, so a reference is one addition.
   type Run is record
      First : Natural := 0;
      Count : Natural := 0;
   end record;

   package Run_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Run);

   package Binding_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Declaration_Id);

   --  The same run per source that Bound uses, so one addition answers
   --  both and no second index exists to disagree.
   package Opened_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Scope_Id);

   package Position_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Natural);

   type Import_Binding is record
      Source : Landin.Source.Source_Id := Landin.Source.No_Source;
      Name   : Landin.Source.Names.Name_Id := Landin.Source.Names.No_Name;
      Target : Landin.Modules.Module_Id := Landin.Modules.No_Module;
      Origin : Landin.Provenance.Origin := Landin.Provenance.No_Origin;
   end record;

   package Import_Binding_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Import_Binding);

   type Application_Fact is record
      Class    : Application_Class := Unclassified_Application;
      Match    : Call_Match_State := Call_Not_Matched;
      Role     : Argument_Role := Unmatched_Argument;
      Formal   : Declaration_Id := No_Declaration;
      Position : Natural := 0;
   end record;

   package Application_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Application_Fact);

   --  Lookup is hashed and never iterated.  Landin.Source.Names publishes
   --  Hash for exactly this and states the other half of the rule: report
   --  order is never identity order.  Every report this stage's caller
   --  raises is built by walking a tree or the declaration vector, both of
   --  which are in an order the input decided.
   type Key is record
      Scope : Scope_Id;
      Name  : Landin.Source.Names.Name_Id;
   end record;

   function Hash (Item : Key) return Ada.Containers.Hash_Type;

   package Key_Maps is new Ada.Containers.Hashed_Maps
     (Key_Type        => Key,
      Element_Type    => Declaration_Id,
      Hash            => Hash,
      Equivalent_Keys => "=");

   type Table is tagged limited record
      Ready        : Boolean := False;
      Declarations : Declaration_Vectors.Vector;
      Scopes       : Scope_Vectors.Vector;
      Module_Scopes : Scope_Id_Vectors.Vector;
      File_Scopes   : Scope_Id_Vectors.Vector;
      Imports       : Import_Binding_Vectors.Vector;
      Runs         : Run_Vectors.Vector;
      Bound        : Binding_Vectors.Vector;
      Opened       : Opened_Vectors.Vector;
      Applications : Application_Vectors.Vector;
      Return_Sources : Position_Vectors.Vector;
      Index        : Key_Maps.Map;
   end record;

end Landin.Resolution;
