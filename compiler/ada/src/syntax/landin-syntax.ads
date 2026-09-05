--  The syntax representation.
--
--  `spec.md` [1740]-[1830] is the authority, and this is that grammar made
--  addressable.  A parse produces one Tree per source file: a dense table of
--  nodes, each node a kind, an extent, an anchor and a run of slots naming
--  its children.  It is a table and not a pointer structure on purpose, and
--  the reason is the four stages that read it.
--
--  R1.50 resolves names, R1.60 checks, R1.70 lowers and R4.60 needs the
--  provenance in debug information.  Each of those wants to say something
--  about every node -- which declaration a name resolves to, what type an
--  expression has, which IR value a node produced -- and none of them may
--  add a field here, because this package must not know that types or
--  values exist.  A Node_Id is an integer in 1 .. Node_Count, so each of
--  them says it in an array of its own, sized once, indexed in constant
--  time, with no map, no hashing and no order that depends on where the
--  host put an object.  A tree of tagged records would have made those side
--  tables maps keyed on access values, and an access value is not something
--  a deterministic report can be ordered by.
--
--  Two invariants come out of building the table bottom up, and both are
--  stated as contracts rather than described in a paragraph.  A child's
--  index is lower than its parent's, so 1 .. Node_Count is a post-order and
--  a stage that only synthesises -- typing an expression, lowering one --
--  is one forward loop with no recursion and no work list.  And a child's
--  extent lies inside its parent's, because a parent's extent is the union
--  of its own tokens and its children's, so a span taken here still names
--  bytes inside the construct that R4.60 will attribute code to.
--
--  What it costs, said plainly.  Every node has one Ada type, so nothing
--  stops a caller passing a statement where an expression is wanted; the
--  bands below and the preconditions on the accessors catch that in a debug
--  build, where `TOOLCHAIN.md` makes contracts load-bearing, and not at
--  compile time.  That is the trade: Ada's checking of node shapes is given
--  up to buy dense side tables and a deterministic order.  It is the trade
--  Landin.Tokens already made one level down, where a Token is one record
--  with a Kind and accessors that state which kinds they answer for.
--
--  Nothing here is a diagnostic.  A node that stands for something the
--  parser could not read is an Error node, and the diagnostic that explains
--  it was raised where the reading failed: R1.40's codes are the catalogue's
--  and Landin.Diagnostics.Syntactic's, never this package's.  An ill-formed
--  program is data.
--
--  Nothing here asks the host anything, and nothing here is a language
--  decision this package is allowed to make.  The scalar spellings
--  are not enumerated: [1760] says u32 and bool are ordinary declared names
--  the kernel predeclares, so a type is a Type_Name node carrying an
--  interned name, and what names a type may have belongs to the stage that
--  resolves names.

private with Ada.Containers.Vectors;

with Landin.Provenance;
with Landin.Source;
with Landin.Source.Names;
with Landin.Tokens;

package Landin.Syntax is

   ------------------------------------------------------------------
   --  Kinds
   ------------------------------------------------------------------

   --  One literal per production the kernel grammar has, and one per
   --  operator rather than one operator field: [1820]'s table is a fixed
   --  set of signs, so a case over the operators is exhaustive and a
   --  missing one is a compile error under `-gnatwe`.  This is the same
   --  reason Landin.Diagnostics.Catalogue makes every column a case.
   --
   --  Four literals are not productions.  Block is the statement run of a
   --  body or a branch: [1810] writes it as a repetition, and a repetition
   --  that has an extent and will have a scope is a node.  If_Arm is one
   --  `if` or `elsif` and its block, so an `if` has arms and at most one
   --  else rather than a flat list whose parity has to be decoded.
   --  Parameter and Named_Return are the named parts of a signature.
   --  Return_List holds the ordered latter run.  None changes the grammar;
   --  they are how the
   --  grammar is held.
   --
   --  Four more stand for what could not be read, one per band, so that a
   --  case over a band still covers the hole instead of falling out of it.
   type Node_Kind is
     (Program,
      --  A file begins with a per-file import prelude.  An import retains
      --  its ordered path segment nodes and is never a module declaration.
      Import_Declaration,
      Import_Segment,
      --  Above: the file [1740] itself and its imports, none declarations.
      --  Below: declarations [1740].
      Error_Declaration,
      --  D139's module-only declaration splice.  Its trailing run is
      --  Fixed_Arm nodes; an arm has a condition (or No_Node for `else`)
      --  followed by its declaration run and opens no lexical scope.
      Fixed_Conditional,
      Function_Declaration,
      --  [0630].  One declaration introduces the atom's value and its
      --  singleton type together; it has no initializer or storage.
      Atom_Declaration,
      --  [1795].  A declaration and not a binding: what it names is a
      --  type rather than a value, and [1790]'s `mut` and `:=` forms
      --  have nothing to say about one.  Its trailing run is D135's
      --  type and fixed formals.
      Type_Declaration,
      --  [1230]'s requirement bundle and [1240]'s registration are module
      --  declarations of their own.  Neither is a type alias or a binding:
      --  later semantic stages collect their source facts without treating
      --  either as a runtime value.
      Concept_Declaration,
      Conformance_Declaration,
      Binding,
      --  [0990]'s by-name local binding of selected fields from one
      --  anonymous result aggregate.  Its fixed slot is the source value;
      --  its trailing run contains Destructured_Field or Result_Wildcard.
      Destructuring_Binding,
      --  Statements [1810].  Binding is one of these too, because [1810]
      --  uses [1790]'s rule unchanged and only [1740] may put `public` on
      --  it; the bands below overlap rather than the node being doubled.
      Error_Statement,
      Assignment,
      Increment,
      Decrement,
      Discard,
      --  [1100].  Its one child is the call registered at this source
      --  position and evaluated only when an applicable edge leaves the
      --  lexical block.
      Defer_Statement,
      --  [1110].  It has the same registered-call shape as defer, but its
      --  cleanup kind is selected only by failure propagation.
      Undo_Statement,
      Return_Statement,
      --  [0970]'s second early exit.  Its first slot is the atom and its
      --  second the optional `when` condition.
      Fail_Statement,
      --  R4.10's loop control.  A break carries its optional `with` value,
      --  both transfers carry an optional `when` guard and target label in
      --  Name, and a loop carries its optional label, condition, body and
      --  `complete` block separately.
      Break_Statement,
      Continue_Statement,
      Loop_Statement,
      While_Statement,
      --  [1150]'s traversal.  The first two slots are its source/lower
      --  expression and optional range upper bound, the next two are the
      --  element and optional index bindings, then body and completion.
      --  Fill distinguishes `..` from `..<` when an upper bound is present.
      For_Statement,
      --  [1050], D124: the same nodes stand in statement and expression
      --  positions.  A control expression carries its answer in the final
      --  expression of each child Block.  Checking decides whether the
      --  surrounding position consumes it, since final calls and nested
      --  controls overlap statement syntax.
      If_Statement,
      Match_Statement,
      --  [1080]'s unlabelled `begin` block.  Its one child is a Block, so
      --  the lexical scope and the value-bearing fallthrough edge remain
      --  distinct nodes.
      Bare_Block,
      --  An application with at least one labelled argument remains neutral
      --  until resolution has classified its complete callee.  Its first slot
      --  is the direct name or indexed selection and its trailing run is
      --  Call_Argument; the optional Recovery_Clause is carried beside the
      --  slots just as it is for Call.  Only a direct name can classify as
      --  construction; stored and selected values are runtime calls.
      Labeled_Application,
      --  A purely positional call is the existing node unchanged [1810].
      --  Its first fixed slot is the callee; arguments follow it, and its
      --  optional Recovery_Clause is carried beside those slots.
      Call,
      --  [0960]'s explicit propagation expression.
      Try_Expression,
      --  Expressions [1820].  [1010]'s anonymous function carries the same
      --  signature/body slots as a declaration but declares no module name.
      Anonymous_Function,
      Error_Expression,
      Name_Reference,
      --  [0420]'s ordinary member selection.  It carries what it selects
      --  from and the selected name; the parser does not distinguish a
      --  struct field from [0430]'s `val` pointee.  The name is not a
      --  Name_Reference because no lexical scope [1090] answers for it --
      --  its meaning depends on the type of what stands to its left.
      Member_Selection,
      --  [0570]'s index, which takes what a selection named and one
      --  expression inside the brackets.  Two slots: what is indexed and
      --  the index, which D18 gives `usize` context -- [1950] says what
      --  happens when the compiler knows it and when it does not.
      Element_Index,
      --  [0570]'s two range-selection forms.  Both retain the selected
      --  storage, lower bound and upper bound; the kind says whether the
      --  upper endpoint is included.
      Inclusive_Slice,
      Half_Open_Slice,
      --  [0520]'s value form.  Its elements are its trailing run, in the
      --  order [0410] says they are evaluated.
      Array_Literal,
      --  [0560]'s full-array scalar repetition.  Two fixed slots: an
      --  optional written count and the one expression to evaluate.
      Array_Repetition,
      --  D36's mixed-prefix repetition.  Its one fixed slot is the repeated
      --  expression; its trailing run is the nonempty literal prefix.
      Mixed_Array_Repetition,
      --  [0710]'s contextual ordinary-struct image.  Its first fixed slot is
      --  [0720]'s optional `of` expression; D72's second is the optional
      --  nominal type node supplied by [0700]'s construction.  Its
      --  trailing run is Field_Value in written order.  A label is the
      --  Field_Value node's own name and not a Name_Reference that resolution
      --  should bind.
      Struct_Literal,
      Integer_Literal,
      --  [0210]/[0230]'s contextual IEEE value.  Its scanner-validated
      --  decimal or hexadecimal spelling is retained in Anchor, then
      --  decoded once checking knows whether its context is f32 or f64.
      Float_Literal,
      --  [0250]'s Unicode scalar value, fixed as `u32`.  Like text, the
      --  node keeps its source span and the shared decoder reads it later.
      Character_Literal,
      --  [0260]'s quoted bytes.  The node keeps only its span; D161's
      --  shared decoder reads the escapes from source again where the
      --  context that decides whether they mean bytes is known.
      Text_Literal,
      --  [0280]'s unescaped, indentation-normalized text.  It keeps its
      --  source span for D164's shared decoder just as Text_Literal does.
      Raw_Literal,
      True_Literal,
      False_Literal,
      --  [0540]'s contextual all-bits-zero image.
      Zeroed_Literal,
      --  [0580]'s contextual empty slice.  Its aligned non-null base is
      --  derived from the destination element type by lowering/backend.
      Empty_Slice_Literal,
      --  [0370]'s measurements.  They take a type where every other
      --  expression takes an expression, which is why they are their own
      --  node kind and not a call: the kernel has no way to pass a type
      --  to anything else.
      Size_Of,
      Align_Of,
      --  [0370]'s array-length query.  Its one operand is deliberately only
      --  a direct name in the first R2.20 slice.
      Len_Of,
      --  [0380]/[0430]'s address expression.  Its child is the ordinary
      --  place syntax whose address is taken; lifetime and addressability
      --  are later R2.50 checking facts, not parser classifications.
      Address_Of,
      --  [0460]/[0470]'s context-typed integer-to-pointer conversion.
      Pointer_Conversion,
      --  [1380]'s explicit erasure of one concrete pointer into contextual
      --  `any C`; checking supplies the conformance table and origin.
      Any_Construction,
      Negation,
      Complement,
      Logical_Not,
      Multiply,
      Divide,
      Remainder,
      Wrapping_Multiply,
      Add,
      Subtract,
      Wrapping_Add,
      Wrapping_Subtract,
      Shift_Left,
      Shift_Right,
      Bitwise_And,
      Bitwise_Xor,
      Bitwise_Or,
      Equal_To,
      Not_Equal_To,
      Less_Than,
      Less_Or_Equal,
      Greater_Than,
      Greater_Or_Equal,
      Logical_And,
      Logical_Or,
      --  One labelled value inside Struct_Literal.  This is syntax carried
      --  by an expression rather than an expression on its own, so it sits
      --  outside Expression_Kind while its one child remains ordinary.
      Field_Value,
      --  One source argument of Labeled_Application.  Its own name is the
      --  optional label (No_Name for a leading positional argument) and its
      --  one child is a compact, immutable RHS.  Projection accessors below
      --  can expose that same child as expression syntax, type syntax, or
      --  both; no second semantic subtree is inserted into the post-order.
      Call_Argument,
      --  Types [1790].  A name, not a closed set: see the header.
      Error_Type,
      Type_Name,
      --  A type the program declared [1795].  Told apart from the built-in
      --  the kernel predeclares because those are known to the parser and
      --  this one is a name only resolution can answer for.
      Type_Reference,
      --  D135's positional application of a parameterized type.  Its
      --  first slot names the applied type; its trailing run is the written
      --  type and fixed arguments in order.
      Type_Application,
      --  [0640]'s nonempty union of atom types.  Its trailing run is the
      --  referenced atom or atom-union names in written order; checking
      --  turns that run into a set, so order is not type identity.
      Atom_Union_Type,
      --  `! ...` on a private function before inference has finalized it.
      Inferred_Error_Set,
      --  [0520]'s array, whose length is part of it.  Two slots: D136's
      --  fixed bound expression and the element type.  The syntax retains
      --  the expression; no instantiated answer is written back here.
      Array_Type,
      --  [0430]'s pointer and [0570]'s slice each retain one referenced
      --  type and the shallow permission written by their optional `mut`.
      Pointer_Type,
      Slice_Type,
      --  [1370]'s erased data-pointer/evidence-table pair.  Its child is
      --  the concept reference that gives this structural type identity.
      Any_Type,
      --  D117's written infallible function type.  Its first slot is the
      --  named Return_List, or No_Node for `none`; its trailing run is the
      --  parameter descriptions in source order.  It has no body and its
      --  parameter names declare nothing.
      Function_Type,
      --  [0670]'s block form, which a type declaration may give instead
      --  of a name, and one of its fields.  A field is a binding without
      --  a value [0750] and keeps the position it was written in,
      --  because that position is the layout.
      Struct_Body,
      --  A contextual `is` names a concept rather than a type.  Keeping the
      --  direct source reference distinct lets concept parents, constraints
      --  and conformances retain that fact before collection exists.
      Concept_Reference,
      Field,
      --  [0680]'s contextual variant member and one of its cases.  The
      --  part's trailing run is Variant_Case in source order; a case's
      --  trailing run is its labelled payload Fields.  Case names are
      --  declarations, while the part and payload field names are labels.
      Variant_Part,
      Variant_Case,
      --  The parts that are none of the above.  D135's formals are
      --  declarations inside a type declaration's own scope.  A type formal
      --  has one optional direct Concept_Reference child, while a fixed
      --  formal retains its declared type child.
      Type_Formal,
      Fixed_Formal,
      --  A concept body retains one ordered run of its formals, parents and
      --  signature-only entries.
      Concept_Body,
      --  A named requirement has a signature but no body.  The first two
      --  slots are its return list and error set, then parameters follow.
      Concept_Entry,
      --  One labelled conformance RHS, retained neutrally until collection
      --  decides whether it denotes a type actual or a supplying function.
      Conformance_Entry,
      Parameter,
      Named_Return,
      --  One source named by [0790]'s `from` clause.  It is a signature
      --  label rather than a lexical Name_Reference; resolution associates
      --  it with a runtime parameter position in a separate fact table.
      Return_Source,
      If_Arm,
      Fixed_Arm,
      Match_Arm,
      Match_Binding,
      --  One named selection in a destructuring binding, carrying the
      --  source result label as its own name and a Destructured_Name child.
      --  Result_Wildcard is [0990]'s `_`, and Return_List holds [0920]'s
      --  ordered one-or-more Named_Return nodes.
      Destructured_Field,
      Destructured_Name,
      Result_Wildcard,
      Return_List,
      --  [1030]'s optional error name and recovery body.
      Recovery_Clause,
      Block);

   --  The bands overlap where the grammar reuses a rule in two places, and
   --  every band is contiguous so that a case over one is exhaustive.
   subtype Declaration_Kind is Node_Kind
     range Error_Declaration .. Binding;

   subtype Statement_Kind is Node_Kind
     range Binding .. Call;

   subtype Expression_Kind is Node_Kind range If_Statement .. Logical_Or;

   subtype Type_Reference_Kind is Node_Kind
     range Error_Type .. Function_Type;

   --  What a type declaration may name: a type, or a body of its own.
   subtype Type_Body_Kind is Node_Kind range Error_Type .. Struct_Body;

   subtype Unary_Kind is Node_Kind range Len_Of .. Logical_Not;

   subtype Binary_Kind is Node_Kind range Multiply .. Logical_Or;

   subtype Literal_Kind is
     Node_Kind range Integer_Literal .. Empty_Slice_Literal;

   --  A hole: the parser needed a construct of that band here and could not
   --  read one.  Not a band of its own, because one per band is the point.
   function Is_Error (Of_Kind : Node_Kind) return Boolean
     is (Of_Kind in Error_Declaration | Error_Statement
                    | Error_Expression | Error_Type);

   --  Which kinds carry a name at all, so Name's precondition is written
   --  once.  A declaration's own name is a field of the declaring node; a
   --  use of a name is always a Name_Reference node of its own, which is
   --  what makes R1.50 a scan for one kind rather than a walk looking for
   --  identifiers in seven positions.
   function Has_Name (Of_Kind : Node_Kind) return Boolean
     is (Of_Kind in Function_Declaration | Atom_Declaration | Binding
                    | Parameter | Named_Return | Name_Reference | Type_Name
                    | Type_Declaration | Concept_Declaration
                    | Type_Reference | Concept_Reference | Type_Formal
                    | Fixed_Formal | Concept_Entry | Conformance_Entry
                    | Field | Variant_Part | Variant_Case
                    | Destructured_Field
                    | Destructured_Name | Recovery_Clause | Match_Binding
                    | Return_Source | Member_Selection | Field_Value
                    | Import_Segment
                    | Call_Argument | Break_Statement | Continue_Statement
                    | Loop_Statement | While_Statement | For_Statement);

   ------------------------------------------------------------------
   --  Trees
   ------------------------------------------------------------------

   --  Visible, and deliberately an ordinary integer type: a side table
   --  indexed by an opaque identity is not a side table.  A caller can
   --  therefore invent one, which is what Contains is for -- the same
   --  bargain Landin.Provenance already struck with Declaration_Id.
   type Node_Id is range 0 .. Integer'Last;

   No_Node : constant Node_Id := 0;

   --  Unconstrained and limited: a Tree can only come from a parse, and
   --  cannot be copied out from under the compilation that owns it.  That
   --  is what lets Root's postcondition below be unconditional.
   type Tree (<>) is limited private;

   function Source_Of (Of_Tree : Tree) return Landin.Source.Source_Id;

   --  How many nodes there are, which is the size a side table needs.
   function Node_Count (Of_Tree : Tree) return Natural;

   --  The highest index in use, so a stage writes
   --  `for Id in 1 .. Last_Node (T) loop` and gets every node once, in
   --  post-order, without a traversal.
   function Last_Node (Of_Tree : Tree) return Node_Id
     with Post => Natural (Last_Node'Result) = Node_Count (Of_Tree);

   function Contains (Of_Tree : Tree; Id : Node_Id) return Boolean
     is (Id /= No_Node and then Id <= Last_Node (Of_Tree));

   function Kind (Of_Tree : Tree; Id : Node_Id) return Node_Kind
     with Pre => Contains (Of_Tree, Id);

   function Root (Of_Tree : Tree) return Node_Id
     with Post => Contains (Of_Tree, Root'Result)
                  and then Kind (Of_Tree, Root'Result) = Program;

   ------------------------------------------------------------------
   --  Where a node is
   ------------------------------------------------------------------

   --  The extent: every byte the construct is written with, its children's
   --  bytes included.  Half open, a byte offset into the snapshot named by
   --  Source_Of, like every other span in the compiler.
   function Where (Of_Tree : Tree; Id : Node_Id) return Landin.Source.Span
     with Pre => Contains (Of_Tree, Id);

   --  The one token that decides what this node is: the operator of a
   --  binary node, the `if` of a branch, the declared name of a binding or
   --  a function, the literal itself.  Two readers want this and not the
   --  extent: a diagnostic puts its caret here, and R4.60 puts a line-table
   --  row here, because a statement spanning four lines is attributed to
   --  one of them and this is the one.  For a declaration it is also where
   --  the declared name is written, which is the span R1.50's duplicate
   --  report has to point at.
   --
   --  Empty only for an Error node that stands for something absent: there
   --  is no token to point at, and an empty span pointing between two bytes
   --  is what Landin.Diagnostics already means by that.
   function Anchor (Of_Tree : Tree; Id : Node_Id) return Landin.Source.Span
     with Pre  => Contains (Of_Tree, Id),
          Post => Landin.Source.Contains
                    (Where (Of_Tree, Id), Anchor'Result);

   --  The pair R0.40 built for this: source identity and span together, in
   --  the form the IR and the debug stages already carry.  Nothing here
   --  writes to a Landin.Provenance.Table; see the header.
   function Origin (Of_Tree : Tree; Id : Node_Id)
     return Landin.Provenance.Origin
     with Pre  => Contains (Of_Tree, Id),
          Post => Landin.Provenance.Is_Known (Origin'Result);

   ------------------------------------------------------------------
   --  What a node says
   ------------------------------------------------------------------

   --  Identity, not bytes: interned by the scan, so R1.50 compares two
   --  integers.
   function Name (Of_Tree : Tree; Id : Node_Id)
     return Landin.Source.Names.Name_Id
     with Pre => Contains (Of_Tree, Id)
                 and then Has_Name (Kind (Of_Tree, Id));

   --  The base and the digits of an integer literal, carried over from the
   --  token rather than re-derived: a base prefix is a lexical fact and
   --  Landin.Tokens owns it.  The value is still not computed, because an
   --  integer literal is untyped [0190] until R1.60 gives it a context.
   function Base (Of_Tree : Tree; Id : Node_Id)
     return Landin.Tokens.Integer_Base
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Integer_Literal;

   function Digit_Span (Of_Tree : Tree; Id : Node_Id)
     return Landin.Source.Span
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Integer_Literal;

   --  `=` or the arithmetic/bitwise operation selected by [0390]'s
   --  updating assignment spelling.
   function Assignment_Operation (Of_Tree : Tree; Id : Node_Id)
     return Landin.Tokens.Assignment_Operator
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Assignment;

   --  `public` rides on a named declaration and never on a statement [1740].
   --  A Binding inside a body is the same kind of node, and this answers
   --  False for it: the parser refused the `public` and said so.
   function Is_Public (Of_Tree : Tree; Id : Node_Id) return Boolean
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id)
                          in Function_Declaration | Atom_Declaration
                             | Binding | Type_Declaration
                             | Concept_Declaration
                             | Conformance_Declaration;

   --  `extern(c)` is an imported C routine declaration.  It retains the
   --  ordinary declared signature but has no Landin body [1570] [1580].
   function Is_External (Of_Tree : Tree; Id : Node_Id) return Boolean
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Function_Declaration;

   function Is_Mutable (Of_Tree : Tree; Id : Node_Id) return Boolean
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) in Binding | Match_Binding;

   --  [0900]'s convention.  Explicit `in` is retained apart from the
   --  omitted default so this syntax table does not erase source spelling.
   type Parameter_Convention is
     (Implicit_In, Explicit_In, Inout_Convention, Sink_Convention);

   function Convention_Of (Of_Tree : Tree; Id : Node_Id)
     return Parameter_Convention
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Parameter;

   function Is_Escaping (Of_Tree : Tree; Id : Node_Id) return Boolean
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Parameter;

   --  D186's compiler-filled call-site parameter.  It remains an ordinary
   --  runtime parameter in the callee and in the internal ABI; only source
   --  call matching omits it or accepts a named forward from another caller
   --  parameter.
   function Is_Caller (Of_Tree : Tree; Id : Node_Id) return Boolean
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Parameter;

   --  Shallow write permission belongs to a reference type [0430] [0570],
   --  independently of the mutability of a binding that holds it.
   function Is_Referent_Mutable (Of_Tree : Tree; Id : Node_Id) return Boolean
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id)
                            in Pointer_Type | Slice_Type;

   --  No Error node anywhere in this subtree, so R1.60 may check it and
   --  R1.70 may lower it.  A hole poisons every node above it, which is how
   --  a syntax error produces one diagnostic instead of a cascade of type
   --  errors about a hole.
   function Is_Sound (Of_Tree : Tree; Id : Node_Id) return Boolean
     with Pre => Contains (Of_Tree, Id);

   function Is_Sound (Of_Tree : Tree) return Boolean;

   ------------------------------------------------------------------
   --  Walking
   ------------------------------------------------------------------

   --  A node's children, in the order they were written, without saying
   --  what they are.  This is the whole representation-free walk, and it is
   --  what a dumper, an origin sweep or a well-formedness audit uses.
   --
   --  A slot may be No_Node, and that is information rather than an
   --  absence to be skipped silently: the grammar allows a child there and
   --  this program did not write one.  `-> none` is a Function_Declaration
   --  whose return slot is No_Node, which is exactly [1800]'s reading.
   --
   --  Every kind has a fixed number of leading slots and then at most one
   --  trailing run of same-shaped ones, and the named accessors below are
   --  the only place a slot position is written.
   function Slot_Count (Of_Tree : Tree; Id : Node_Id) return Natural
     with Pre => Contains (Of_Tree, Id);

   function Slot (Of_Tree : Tree; Id : Node_Id; Index : Positive)
     return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Index <= Slot_Count (Of_Tree, Id),
          Post => Slot'Result < Id
                  and then (Slot'Result = No_Node
                            or else Landin.Source.Contains
                                      (Where (Of_Tree, Id),
                                       Where (Of_Tree, Slot'Result)));

   ------------------------------------------------------------------
   --  The named positions
   --
   --  One accessor per position the grammar names, reused wherever the
   --  grammar reuses the position.  Each answers No_Node exactly where its
   --  production writes `?`.
   ------------------------------------------------------------------

   --  `source_file ::= import_declaration* declaration*` [1740].  Imports
   --  are a file-local ordered prelude; declarations form their module set.
   function Import_Count (Of_Tree : Tree) return Natural;

   function Nth_Import (Of_Tree : Tree; Index : Positive) return Node_Id
     with Pre  => Index <= Import_Count (Of_Tree),
          Post => Contains (Of_Tree, Nth_Import'Result)
                  and then Kind (Of_Tree, Nth_Import'Result)
                             = Import_Declaration;

   function Import_Segment_Count
     (Of_Tree : Tree; Id : Node_Id) return Natural
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Import_Declaration;

   function Nth_Import_Segment
     (Of_Tree : Tree; Id : Node_Id; Index : Positive) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) = Import_Declaration
                  and then Index <= Import_Segment_Count (Of_Tree, Id),
          Post => Contains (Of_Tree, Nth_Import_Segment'Result)
                  and then Kind (Of_Tree, Nth_Import_Segment'Result)
                             = Import_Segment;

   function Declaration_Count (Of_Tree : Tree) return Natural;

   function Nth_Declaration (Of_Tree : Tree; Index : Positive)
     return Node_Id
     with Pre  => Index <= Declaration_Count (Of_Tree),
          Post => Contains (Of_Tree, Nth_Declaration'Result);

   --  `type` of a binding, a parameter or a named return [1790] [1800],
   --  and the type a type declaration names [1795].  No_Node for [1790]'s
   --  `:=` form, where there is no type to point at.
   function Declared_Type (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id)
                          in Binding | Parameter | Named_Return
                             | Type_Declaration | Fixed_Formal | Field;

   --  [1230]'s direct type-formal constraint.  No_Node is the unconstrained
   --  spelling; a present node is Concept_Reference, not an inferred fact.
   function Constraint_Of (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Type_Formal;

   --  A concept declaration has its own formal run, distinct from a type
   --  alias's: the latter is a template identity while the former binds the
   --  requirement signatures and parent names below.
   function Concept_Body_Of (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) = Concept_Declaration,
          Post => Contains (Of_Tree, Concept_Body_Of'Result)
                  and then Kind (Of_Tree, Concept_Body_Of'Result)
                             = Concept_Body;

   function Concept_Formal_Count (Of_Tree : Tree; Id : Node_Id) return Natural
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Concept_Declaration;

   function Nth_Concept_Formal
     (Of_Tree : Tree; Id : Node_Id; Index : Positive) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) = Concept_Declaration
                  and then Index <= Concept_Formal_Count (Of_Tree, Id),
          Post => Contains (Of_Tree, Nth_Concept_Formal'Result)
                  and then Kind (Of_Tree, Nth_Concept_Formal'Result)
                             in Type_Formal | Fixed_Formal;

   --  Parent concepts and signature-only entries are ordered source runs.
   function Concept_Parent_Count (Of_Tree : Tree; Id : Node_Id) return Natural
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Concept_Declaration;

   function Nth_Concept_Parent
     (Of_Tree : Tree; Id : Node_Id; Index : Positive) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) = Concept_Declaration
                  and then Index <= Concept_Parent_Count (Of_Tree, Id),
          Post => Contains (Of_Tree, Nth_Concept_Parent'Result)
                  and then Kind (Of_Tree, Nth_Concept_Parent'Result)
                             in Concept_Reference | Member_Selection;

   function Concept_Entry_Count (Of_Tree : Tree; Id : Node_Id) return Natural
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Concept_Declaration;

   function Nth_Concept_Entry
     (Of_Tree : Tree; Id : Node_Id; Index : Positive) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) = Concept_Declaration
                  and then Index <= Concept_Entry_Count (Of_Tree, Id),
          Post => Contains (Of_Tree, Nth_Concept_Entry'Result)
                  and then Kind (Of_Tree, Nth_Concept_Entry'Result)
                             = Concept_Entry;

   --  D135's ordered formals are visible to the declared type or struct body
   --  of a parameterized type declaration.  D138 extends the same two
   --  compile-time-only binders to a declared routine signature. Type_Formal
   --  and Fixed_Formal distinguish the two source forms; only the latter has
   --  Declared_Type.
   function Type_Formal_Count (Of_Tree : Tree; Id : Node_Id) return Natural
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Type_Declaration;

   function Nth_Type_Formal
     (Of_Tree : Tree; Id : Node_Id; Index : Positive) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) = Type_Declaration
                  and then Index <= Type_Formal_Count (Of_Tree, Id),
          Post => Contains (Of_Tree, Nth_Type_Formal'Result)
                  and then Kind (Of_Tree, Nth_Type_Formal'Result)
                             in Type_Formal | Fixed_Formal;

   --  The value a binding is given, a place is assigned, a discard throws
   --  away, or a labelled struct field supplies.  No_Node for a binding
   --  declared without one [1790].
   function Value_Of (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id)
                          in Binding | Destructuring_Binding | Assignment
                             | Discard | Field_Value | Fail_Statement;

   --  [1100]/[1110]'s registered call.  This is deliberately not Value_Of:
   --  reaching either cleanup statement records syntax and evaluates no
   --  value at that point.
   function Cleanup_Call (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id)
                             in Defer_Statement | Undo_Statement,
          Post => Contains (Of_Tree, Cleanup_Call'Result)
                  and then Kind (Of_Tree, Cleanup_Call'Result) = Call;

   --  The construct-specific views keep callers that care which policy was
   --  registered from having to treat the common slot layout as public.
   function Deferred_Call (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) = Defer_Statement,
          Post => Contains (Of_Tree, Deferred_Call'Result)
                  and then Kind (Of_Tree, Deferred_Call'Result) = Call;

   function Undo_Call (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) = Undo_Statement,
          Post => Contains (Of_Tree, Undo_Call'Result)
                  and then Kind (Of_Tree, Undo_Call'Result) = Call;

   --  `place` [1810], the one an assignment writes or an increment steps,
   --  and what a selection [1820] selects from.
   function Target_Of (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id)
                          in Assignment | Increment | Decrement
                             | Member_Selection | Element_Index
                             | Inclusive_Slice | Half_Open_Slice;

   --  The expression between the brackets [0570].
   function Index_Of (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) = Element_Index,
          Post => Contains (Of_Tree, Index_Of'Result);

   function Slice_Lower (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id)
                    in Inclusive_Slice | Half_Open_Slice,
          Post => Contains (Of_Tree, Slice_Lower'Result);

   function Slice_Upper (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id)
                    in Inclusive_Slice | Half_Open_Slice,
          Post => Contains (Of_Tree, Slice_Upper'Result);

   --  The condition of a branch [1810], or an exit's `when` guard.  D185's
   --  branch and while condition may be an initialized Binding; its Value_Of
   --  is the bool tested after the binding has been stored.  No_Node for a
   --  bare `return`.
   function Condition_Of (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id)
                          in If_Arm | Return_Statement | Fail_Statement
                             | Break_Statement | Continue_Statement
                             | While_Statement;

   --  [1190]'s value carried by `break with`; No_Node for a valueless break.
   function Transfer_Value (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Break_Statement;

   --  R4.10's loop body.  It is a Block and therefore owns the same lexical
   --  cleanup and scope rules as a branch body.
   function Loop_Body (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id)
                             in Loop_Statement | While_Statement
                                | For_Statement,
          Post => Contains (Of_Tree, Loop_Body'Result)
                  and then Kind (Of_Tree, Loop_Body'Result) = Block;

   --  [1170]'s block on the natural-completion edge.  No_Node when no
   --  `complete` clause was written.
   function Complete_Body (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id)
                            in Loop_Statement | While_Statement
                               | For_Statement;

   function Traversal_Lower (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) = For_Statement,
          Post => Contains (Of_Tree, Traversal_Lower'Result);

   function Traversal_Upper (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = For_Statement;

   function Traversal_Element (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) = For_Statement,
          Post => Contains (Of_Tree, Traversal_Element'Result)
                  and then Kind (Of_Tree, Traversal_Element'Result) = Binding;

   function Traversal_Index (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = For_Statement;

   function Traversal_Is_Inclusive
     (Of_Tree : Tree; Id : Node_Id) return Boolean
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = For_Statement;

   --  D139's declaration conditional and its arms.  An arm's first slot is
   --  its condition, or No_Node for `else`; the remaining slots are ordinary
   --  declarations that configuration selects without mutating syntax.
   function Fixed_Arm_Count (Of_Tree : Tree; Id : Node_Id) return Natural
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Fixed_Conditional,
          Post => Fixed_Arm_Count'Result >= 1;

   function Nth_Fixed_Arm
     (Of_Tree : Tree; Id : Node_Id; Index : Positive) return Node_Id
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Fixed_Conditional
                 and then Index <= Fixed_Arm_Count (Of_Tree, Id),
          Post => Contains (Of_Tree, Nth_Fixed_Arm'Result)
                  and then Kind (Of_Tree, Nth_Fixed_Arm'Result) = Fixed_Arm;

   function Fixed_Condition (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Fixed_Arm;

   function Fixed_Declaration_Count (Of_Tree : Tree; Id : Node_Id)
     return Natural
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Fixed_Arm;

   function Nth_Fixed_Declaration
     (Of_Tree : Tree; Id : Node_Id; Index : Positive) return Node_Id
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Fixed_Arm
                 and then Index <= Fixed_Declaration_Count (Of_Tree, Id),
          Post => Contains (Of_Tree, Nth_Fixed_Declaration'Result);

   --  What a function, branch, match arm or bare block runs.  A Block for a
   --  statement body, and
   --  the expression itself for [1800]'s expression form -- two different
   --  things that this deliberately does not flatten into one.  An arm's is
   --  always a Block.
   function Body_Of (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id)
                           in Function_Declaration | Anonymous_Function
                              | If_Arm | Match_Arm | Bare_Block,
          Post => Contains (Of_Tree, Body_Of'Result);

   --  `returns` [1800].  No_Node is `-> none`; otherwise this is a
   --  Return_List whose trailing run is [0920]'s ordered named returns.  A
   --  written Function_Type carries the same signature positions without a
   --  body.  A Concept_Entry has the same written signature positions.
   function Returns_Of (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id)
                            in Function_Declaration | Anonymous_Function
                               | Function_Type | Concept_Entry;

   function Return_Count (Of_Tree : Tree; Id : Node_Id) return Natural
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id)
                            in Function_Declaration | Anonymous_Function
                               | Function_Type | Concept_Entry;

   function Nth_Return
     (Of_Tree : Tree; Id : Node_Id; Index : Positive) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id)
                             in Function_Declaration | Anonymous_Function
                                | Function_Type | Concept_Entry
                  and then Index <= Return_Count (Of_Tree, Id),
          Post => Contains (Of_Tree, Nth_Return'Result)
                  and then Kind (Of_Tree, Nth_Return'Result) = Named_Return;

   --  [0790]'s ordered `from` names on one named return.  The declared type
   --  is its fixed slot and this is the trailing run.
   function Return_Source_Count
     (Of_Tree : Tree; Id : Node_Id) return Natural
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Named_Return;

   function Nth_Return_Source
     (Of_Tree : Tree; Id : Node_Id; Index : Positive) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) = Named_Return
                  and then Index <= Return_Source_Count (Of_Tree, Id),
          Post => Contains (Of_Tree, Nth_Return_Source'Result)
                  and then Kind (Of_Tree, Nth_Return_Source'Result)
                             = Return_Source;

   --  The optional declared error set after `!`; No_Node is infallible.
   function Error_Set_Of (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id)
                            in Function_Declaration | Anonymous_Function
                               | Function_Type | Concept_Entry;

   --  An application's optional [1030] clause; No_Node when none was written.
   function Recovery_Of (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id)
                            in Call | Labeled_Application;

   --  Runtime parameters only. D138's type and fixed formals share the
   --  declaration's trailing signature run but never enter this ABI-facing
   --  view.
   function Parameter_Count (Of_Tree : Tree; Id : Node_Id) return Natural
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id)
                            in Function_Declaration | Anonymous_Function
                               | Function_Type | Concept_Entry;

   function Nth_Parameter
     (Of_Tree : Tree; Id : Node_Id; Index : Positive) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id)
                             in Function_Declaration | Anonymous_Function
                                | Function_Type | Concept_Entry
                  and then Index <= Parameter_Count (Of_Tree, Id),
          Post => Contains (Of_Tree, Nth_Parameter'Result)
                  and then Kind (Of_Tree, Nth_Parameter'Result) = Parameter;

   --  D138's compile-time-only routine formals, in their source order. They
   --  are deliberately separate from Parameter_Count so no runtime consumer
   --  can accidentally treat one as an ABI position.
   function Generic_Formal_Count (Of_Tree : Tree; Id : Node_Id) return Natural
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Function_Declaration;

   function Nth_Generic_Formal
     (Of_Tree : Tree; Id : Node_Id; Index : Positive) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) = Function_Declaration
                  and then Index <= Generic_Formal_Count (Of_Tree, Id),
          Post => Contains (Of_Tree, Nth_Generic_Formal'Result)
                  and then Kind (Of_Tree, Nth_Generic_Formal'Result)
                             in Type_Formal | Fixed_Formal;

   --  [1240]'s one target type, direct concept name and ordered labelled
   --  source RHS run.  The binder uses the existing type/fixed formal forms.
   function Conforming_Type (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Conformance_Declaration;

   function Conforming_Concept (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) = Conformance_Declaration,
          Post => Contains (Of_Tree, Conforming_Concept'Result)
                  and then Kind (Of_Tree, Conforming_Concept'Result)
                             in Concept_Reference | Member_Selection;

   function Conformance_Binder_Count
     (Of_Tree : Tree; Id : Node_Id) return Natural
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Conformance_Declaration;

   function Nth_Conformance_Binder
     (Of_Tree : Tree; Id : Node_Id; Index : Positive) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) = Conformance_Declaration
                  and then Index <= Conformance_Binder_Count (Of_Tree, Id),
          Post => Contains (Of_Tree, Nth_Conformance_Binder'Result)
                  and then Kind (Of_Tree, Nth_Conformance_Binder'Result)
                             in Type_Formal | Fixed_Formal;

   function Conformance_Entry_Count
     (Of_Tree : Tree; Id : Node_Id) return Natural
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Conformance_Declaration;

   function Nth_Conformance_Entry
     (Of_Tree : Tree; Id : Node_Id; Index : Positive) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) = Conformance_Declaration
                  and then Index <= Conformance_Entry_Count (Of_Tree, Id),
          Post => Contains (Of_Tree, Nth_Conformance_Entry'Result)
                  and then Kind (Of_Tree, Nth_Conformance_Entry'Result)
                             = Conformance_Entry;

   function Conformance_RHS (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) = Conformance_Entry,
          Post => Contains (Of_Tree, Conformance_RHS'Result);

   --  `else` [1810].  No_Node when the branch has none.
   function Else_Body (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id)
                   in If_Statement | Recovery_Clause;

   function Arm_Count (Of_Tree : Tree; Id : Node_Id) return Natural
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) = If_Statement,
          Post => Arm_Count'Result >= 1;

   function Nth_Arm (Of_Tree : Tree; Id : Node_Id; Index : Positive)
     return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) = If_Statement
                  and then Index <= Arm_Count (Of_Tree, Id),
          Post => Contains (Of_Tree, Nth_Arm'Result);

   function Match_Subject (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) = Match_Statement,
          Post => Contains (Of_Tree, Match_Subject'Result);

   function Match_Arm_Count (Of_Tree : Tree; Id : Node_Id) return Natural
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) = Match_Statement,
          Post => Match_Arm_Count'Result >= 1;

   function Nth_Match_Arm
     (Of_Tree : Tree; Id : Node_Id; Index : Positive) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) = Match_Statement
                  and then Index <= Match_Arm_Count (Of_Tree, Id),
          Post => Contains (Of_Tree, Nth_Match_Arm'Result);

   function Match_Pattern (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) = Match_Arm,
          Post => Contains (Of_Tree, Match_Pattern'Result);

   function Match_Binding_Count
     (Of_Tree : Tree; Id : Node_Id) return Natural
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Match_Arm;

   function Nth_Match_Binding
     (Of_Tree : Tree; Id : Node_Id; Index : Positive) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) = Match_Arm
                  and then Index <= Match_Binding_Count (Of_Tree, Id),
          Post => Contains (Of_Tree, Nth_Match_Binding'Result)
                  and then Kind (Of_Tree, Nth_Match_Binding'Result)
                           = Match_Binding;

   function Statement_Count (Of_Tree : Tree; Id : Node_Id) return Natural
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Block;

   function Nth_Statement
     (Of_Tree : Tree; Id : Node_Id; Index : Positive) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) = Block
                  and then Index <= Statement_Count (Of_Tree, Id),
          Post => Contains (Of_Tree, Nth_Statement'Result);

   --  [0990]'s destructuring binding.  Each named field has one local child;
   --  a Result_Wildcard has none and explicitly ignores every unbound field.
   function Destructured_Value (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) = Destructuring_Binding,
          Post => Contains (Of_Tree, Destructured_Value'Result);

   function Destructured_Field_Count
     (Of_Tree : Tree; Id : Node_Id) return Natural
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Destructuring_Binding;

   function Nth_Destructured_Field
     (Of_Tree : Tree; Id : Node_Id; Index : Positive) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) = Destructuring_Binding
                  and then Index <= Destructured_Field_Count (Of_Tree, Id),
          Post => Contains (Of_Tree, Nth_Destructured_Field'Result)
                  and then Kind (Of_Tree, Nth_Destructured_Field'Result)
                    in Destructured_Field | Result_Wildcard;

   function Destructured_Local (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Destructured_Field;

   --  [1080]: the value-producing expression on a Block's fallthrough
   --  edge.  No_Node means the block has statements only; it is valid for
   --  an expression arm only when every reachable edge returns first.
   function Block_Value (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Block;

   --  `call ::= indexed "(" arguments? ")"` [1820].  A direct callee stays
   --  one Name_Reference; D131 also carries a complete field selection here.
   --  Labeled_Application deliberately shares this slot while resolution
   --  decides whether a direct name denotes a callable or type, or retains a
   --  complete selected/function-valued runtime callee.
   function Callee_Of (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id)
                             in Call | Labeled_Application,
          Post => Contains (Of_Tree, Callee_Of'Result);

   function Argument_Count (Of_Tree : Tree; Id : Node_Id) return Natural
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id)
                            in Call | Labeled_Application;

   --  A positional Call returns its expression child unchanged.  A labelled
   --  application returns the Call_Argument wrapper, preserving its label and
   --  both projections for callee-first classification.
   function Nth_Argument
     (Of_Tree : Tree; Id : Node_Id; Index : Positive) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id)
                             in Call | Labeled_Application
                  and then Index <= Argument_Count (Of_Tree, Id),
          Post => Contains (Of_Tree, Nth_Argument'Result)
                  and then
                    (if Kind (Of_Tree, Id) = Labeled_Application
                     then Kind (Of_Tree, Nth_Argument'Result) = Call_Argument);

   function Argument_Label (Of_Tree : Tree; Id : Node_Id)
     return Landin.Source.Names.Name_Id
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Call_Argument;

   --  True only for [0720]'s colonless trailing `of expression`.  Keeping
   --  this lexical fact on the same neutral argument node lets resolution
   --  assign the fill role after it has classified construction, while
   --  `of: expression` remains an ordinary labelled call argument.
   function Is_Fill_Argument (Of_Tree : Tree; Id : Node_Id) return Boolean
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Call_Argument;

   --  The source RHS, before either semantic interpretation is selected.
   function Argument_RHS (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) = Call_Argument,
          Post => Contains (Of_Tree, Argument_RHS'Result);

   --  These are projections, not owned children.  When both are present they
   --  are the same Node_Id: an identifier, integer, or direct positional
   --  application has one compact syntax tree and resolution selects how to
   --  read it.  This preserves the global post-order and prevents a labelled
   --  argument from duplicating every semantic descendant merely to retain
   --  two possible views.  No_Node means the RHS cannot have that grammar.
   function Expression_Projection (Of_Tree : Tree; Id : Node_Id)
     return Node_Id
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Call_Argument;

   function Type_Projection (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Call_Argument;

   --  D135's applied alias and its positional type/fixed argument run.
   function Applied_Type (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) = Type_Application,
          Post => Contains (Of_Tree, Applied_Type'Result)
                  and then Kind (Of_Tree, Applied_Type'Result)
                             in Type_Name | Type_Reference | Type_Application
                                | Member_Selection;

   function Type_Argument_Count (Of_Tree : Tree; Id : Node_Id) return Natural
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Type_Application;

   function Nth_Type_Argument
     (Of_Tree : Tree; Id : Node_Id; Index : Positive) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) = Type_Application
                  and then Index <= Type_Argument_Count (Of_Tree, Id),
          Post => Contains (Of_Tree, Nth_Type_Argument'Result);

   function Atom_Member_Count
     (Of_Tree : Tree; Id : Node_Id) return Natural
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Atom_Union_Type;

   function Nth_Atom_Member
     (Of_Tree : Tree; Id : Node_Id; Index : Positive) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) = Atom_Union_Type
                  and then Index <= Atom_Member_Count (Of_Tree, Id),
          Post => Contains (Of_Tree, Nth_Atom_Member'Result)
                  and then Kind (Of_Tree, Nth_Atom_Member'Result)
                             in Type_Reference | Member_Selection;

   function Element_Count (Of_Tree : Tree; Id : Node_Id) return Natural
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id)
                            in Array_Literal | Mixed_Array_Repetition;

   function Nth_Element
     (Of_Tree : Tree; Id : Node_Id; Index : Positive) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id)
                             in Array_Literal | Mixed_Array_Repetition
                  and then Index <= Element_Count (Of_Tree, Id),
          Post => Contains (Of_Tree, Nth_Element'Result);

   --  [0710]'s written field run, [0720]'s optional trailing fill and D72's
   --  optional nominal type.  Constructed_Type is No_Node for a bare literal.
   function Struct_Fill (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Struct_Literal;

   function Constructed_Type (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Struct_Literal;

   function Field_Value_Count (Of_Tree : Tree; Id : Node_Id) return Natural
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Struct_Literal;

   function Nth_Field_Value
     (Of_Tree : Tree; Id : Node_Id; Index : Positive) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) = Struct_Literal
                  and then Index <= Field_Value_Count (Of_Tree, Id),
          Post => Contains (Of_Tree, Nth_Field_Value'Result)
                  and then Kind (Of_Tree, Nth_Field_Value'Result)
                             = Field_Value;

   --  The explicit count in `[N of value]`, or No_Node for contextual
   --  `[of value]`, and the scalar expression evaluated once [0560].
   function Repetition_Count (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Array_Repetition;

   function Repeated_Element (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id)
                             in Array_Repetition | Mixed_Array_Repetition,
          Post => Contains (Of_Tree, Repeated_Element'Result);

   function Operand_Of (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id)
                           in Unary_Kind | Try_Expression,
          Post => Contains (Of_Tree, Operand_Of'Result);

   --  The type [0370] is asked about.  A type and not an expression, which
   --  is why it is not Operand_Of.
   --  [0670]'s members, in the order they were written, which [0750]
   --  makes the order they are laid out in.  Field_Count keeps its old
   --  name because a variant part occupies one field position in the
   --  containing layout.
   function Field_Count (Of_Tree : Tree; Id : Node_Id) return Natural
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Struct_Body;

   function Nth_Field
     (Of_Tree : Tree; Id : Node_Id; Index : Positive) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) = Struct_Body
                  and then Index <= Field_Count (Of_Tree, Id),
          Post => Contains (Of_Tree, Nth_Field'Result)
                  and then Kind (Of_Tree, Nth_Field'Result)
                             in Field | Variant_Part;

   function Case_Count (Of_Tree : Tree; Id : Node_Id) return Natural
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Variant_Part;

   function Nth_Case
     (Of_Tree : Tree; Id : Node_Id; Index : Positive) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) = Variant_Part
                  and then Index <= Case_Count (Of_Tree, Id),
          Post => Contains (Of_Tree, Nth_Case'Result)
                  and then Kind (Of_Tree, Nth_Case'Result) = Variant_Case;

   function Payload_Field_Count
     (Of_Tree : Tree; Id : Node_Id) return Natural
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Variant_Case;

   function Nth_Payload_Field
     (Of_Tree : Tree; Id : Node_Id; Index : Positive) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) = Variant_Case
                  and then Index <= Payload_Field_Count (Of_Tree, Id),
          Post => Contains (Of_Tree, Nth_Payload_Field'Result)
                  and then Kind (Of_Tree, Nth_Payload_Field'Result) = Field;

   --  [0520]'s length, as the integer literal the program wrote, and the
   --  type of one element.  The length is a node and not a number here for
   --  Landin.Syntax's own reason: what a literal means is [1880]'s and the
   --  span it was written at is what a report about it points to.
   --  D136's fixed expression between an array type's brackets.
   function Bound_Of (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) = Array_Type,
          Post => Contains (Of_Tree, Bound_Of'Result);

   function Element_Of (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) = Array_Type,
          Post => Contains (Of_Tree, Element_Of'Result);

   function Referenced_Type (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id)
                             in Pointer_Type | Slice_Type,
          Post => Contains (Of_Tree, Referenced_Type'Result);

   function Any_Concept (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) = Any_Type,
          Post => Contains (Of_Tree, Any_Concept'Result)
                  and then Kind (Of_Tree, Any_Concept'Result)
                    in Concept_Reference | Member_Selection;

   function Measured_Type (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) in Size_Of | Align_Of,
          Post => Contains (Of_Tree, Measured_Type'Result);

   function Left_Of (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) in Binary_Kind,
          Post => Contains (Of_Tree, Left_Of'Result);

   function Right_Of (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) in Binary_Kind,
          Post => Contains (Of_Tree, Right_Of'Result);

private

   --  One record per node, no variant part.  A variant would make the
   --  element type indefinite, and would fix a node's shape at the moment
   --  it is created, which a parser that has to turn a half-read construct
   --  into a hole cannot promise.  The payload fields are the union of what
   --  any one kind needs, which is a fixed size of about six words that is
   --  never copied out of the table.
   type Node is record
      Kind       : Node_Kind := Error_Expression;
      Extent     : Landin.Source.Span := Landin.Source.Empty_Span;
      Anchor     : Landin.Source.Span := Landin.Source.Empty_Span;
      Name       : Landin.Source.Names.Name_Id :=
                     Landin.Source.Names.No_Name;
      Base       : Landin.Tokens.Integer_Base := Landin.Tokens.Decimal;
      Digit_Run  : Landin.Source.Span := Landin.Source.Empty_Span;
      Assignment_Op : Landin.Tokens.Assignment_Operator :=
        Landin.Tokens.Plain_Assignment;
      First_Slot : Natural := 0;
      Slots      : Natural := 0;
      Sound      : Boolean := True;
      Exported   : Boolean := False;
      External   : Boolean := False;
      Mutable    : Boolean := False;
      Escaping   : Boolean := False;
      Caller     : Boolean := False;
      Convention : Parameter_Convention := Implicit_In;
      Fill       : Boolean := False;
      Recovery   : Node_Id := No_Node;
   end record;

   package Node_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Node);

   --  Every node's children, end to end, so a node's slots are a run and
   --  Slot is an index rather than a chase.  A parser that finishes a
   --  parent after its children appends the run when it builds the parent,
   --  which is also why an index is greater than every index below it.
   package Slot_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Node_Id);

   type Tree is limited record
      Source : Landin.Source.Source_Id := Landin.Source.No_Source;
      Items  : Node_Vectors.Vector;
      Links  : Slot_Vectors.Vector;
   end record;

end Landin.Syntax;
