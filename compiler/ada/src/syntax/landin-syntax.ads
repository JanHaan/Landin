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
--  decision this package is allowed to make.  The eleven scalar spellings
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
   --  Parameter and Named_Return are the two halves of a signature that
   --  declare a name.  None of them changes the grammar; they are how the
   --  grammar is held.
   --
   --  Four more stand for what could not be read, one per band, so that a
   --  case over a band still covers the hole instead of falling out of it.
   type Node_Kind is
     (Program,
      --  Above: the file [1740] itself, which is not a declaration.
      --  Below: declarations [1740].
      Error_Declaration,
      Function_Declaration,
      Binding,
      --  Statements [1810].  Binding is one of these too, because [1810]
      --  uses [1790]'s rule unchanged and only [1740] may put `public` on
      --  it; the bands below overlap rather than the node being doubled.
      Error_Statement,
      Assignment,
      Increment,
      Decrement,
      Discard,
      Return_Statement,
      If_Statement,
      --  A call is a statement as well as an expression [1810].
      Call,
      --  Expressions [1820].
      Error_Expression,
      Name_Reference,
      Integer_Literal,
      True_Literal,
      False_Literal,
      --  [0370]'s measurements.  They take a type where every other
      --  expression takes an expression, which is why they are their own
      --  node kind and not a call: the kernel has no way to pass a type
      --  to anything else.
      Size_Of,
      Align_Of,
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
      --  Types [1790].  A name, not a closed set: see the header.
      Error_Type,
      Type_Name,
      --  The parts that are none of the above.
      Parameter,
      Named_Return,
      If_Arm,
      Block);

   --  The bands overlap where the grammar reuses a rule in two places, and
   --  every band is contiguous so that a case over one is exhaustive.
   subtype Declaration_Kind is Node_Kind
     range Error_Declaration .. Binding;

   subtype Statement_Kind is Node_Kind range Binding .. Call;

   subtype Expression_Kind is Node_Kind range Call .. Logical_Or;

   subtype Type_Reference_Kind is Node_Kind range Error_Type .. Type_Name;

   subtype Unary_Kind is Node_Kind range Negation .. Logical_Not;

   subtype Binary_Kind is Node_Kind range Multiply .. Logical_Or;

   subtype Literal_Kind is Node_Kind range Integer_Literal .. False_Literal;

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
     is (Of_Kind in Function_Declaration | Binding | Parameter
                    | Named_Return | Name_Reference | Type_Name);

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

   --  `public` rides on a declaration and never on a statement [1740].  A
   --  Binding inside a body is the same kind of node, and this answers
   --  False for it: the parser refused the `public` and said so.
   function Is_Public (Of_Tree : Tree; Id : Node_Id) return Boolean
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id)
                          in Function_Declaration | Binding;

   function Is_Mutable (Of_Tree : Tree; Id : Node_Id) return Boolean
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Binding;

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

   --  `program ::= declaration*` [1740].  A file is a set and order does
   --  not matter [0130]; this is the order they were written, which is what
   --  a deterministic report needs and not what resolution may depend on.
   function Declaration_Count (Of_Tree : Tree) return Natural;

   function Nth_Declaration (Of_Tree : Tree; Index : Positive)
     return Node_Id
     with Pre  => Index <= Declaration_Count (Of_Tree),
          Post => Contains (Of_Tree, Nth_Declaration'Result);

   --  `type` of a binding, a parameter or a named return [1790] [1800].
   --  No_Node for [1790]'s `:=` form, where there is no type to point at.
   function Declared_Type (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id)
                          in Binding | Parameter | Named_Return;

   --  The value a binding is given, a place is assigned, or a discard
   --  throws away.  No_Node for a binding declared without one [1790].
   function Value_Of (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id)
                          in Binding | Assignment | Discard;

   --  `place` [1810], the one an assignment writes or an increment steps.
   function Target_Of (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id)
                          in Assignment | Increment | Decrement;

   --  The condition of a branch [1810], or an exit's `when` guard.
   --  No_Node for a bare `return`.
   function Condition_Of (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id)
                          in If_Arm | Return_Statement;

   --  What a function or a branch runs.  A Block for a statement body, and
   --  the expression itself for [1800]'s expression form -- two different
   --  things that this deliberately does not flatten into one.  An arm's is
   --  always a Block.
   function Body_Of (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id)
                           in Function_Declaration | If_Arm,
          Post => Contains (Of_Tree, Body_Of'Result);

   --  `returns` [1800].  No_Node is `-> none`, and a function with no
   --  return has no expression body for one to fill.
   function Return_Of (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Function_Declaration;

   function Parameter_Count (Of_Tree : Tree; Id : Node_Id) return Natural
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Function_Declaration;

   function Nth_Parameter
     (Of_Tree : Tree; Id : Node_Id; Index : Positive) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) = Function_Declaration
                  and then Index <= Parameter_Count (Of_Tree, Id),
          Post => Contains (Of_Tree, Nth_Parameter'Result);

   --  `else` [1810].  No_Node when the branch has none.
   function Else_Body (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = If_Statement;

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

   function Statement_Count (Of_Tree : Tree; Id : Node_Id) return Natural
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Block;

   function Nth_Statement
     (Of_Tree : Tree; Id : Node_Id; Index : Positive) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) = Block
                  and then Index <= Statement_Count (Of_Tree, Id),
          Post => Contains (Of_Tree, Nth_Statement'Result);

   --  `call ::= identifier "(" arguments? ")"` [1820].  The callee is a
   --  Name_Reference and not a field, so every use of a name is one kind of
   --  node; when R2 makes a callee an expression, nothing above changes.
   function Callee_Of (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) = Call,
          Post => Contains (Of_Tree, Callee_Of'Result);

   function Argument_Count (Of_Tree : Tree; Id : Node_Id) return Natural
     with Pre => Contains (Of_Tree, Id)
                 and then Kind (Of_Tree, Id) = Call;

   function Nth_Argument
     (Of_Tree : Tree; Id : Node_Id; Index : Positive) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) = Call
                  and then Index <= Argument_Count (Of_Tree, Id),
          Post => Contains (Of_Tree, Nth_Argument'Result);

   function Operand_Of (Of_Tree : Tree; Id : Node_Id) return Node_Id
     with Pre  => Contains (Of_Tree, Id)
                  and then Kind (Of_Tree, Id) in Unary_Kind,
          Post => Contains (Of_Tree, Operand_Of'Result);

   --  The type [0370] is asked about.  A type and not an expression, which
   --  is why it is not Operand_Of.
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
      First_Slot : Natural := 0;
      Slots      : Natural := 0;
      Sound      : Boolean := True;
      Exported   : Boolean := False;
      Mutable    : Boolean := False;
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
