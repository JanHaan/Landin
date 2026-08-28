--  The target-neutral intermediate representation.
--
--  `tour.md` [1550] is the authority for its existence -- "a verified,
--  target-neutral intermediate representation takes QBE's IL as a design
--  influence without freezing one flat or serialised stage shape before
--  implementation evidence exists" -- and [1740]-[1940] is the authority
--  for what it has to hold.  Nothing here is a language decision: every
--  opcode below is an operator [1820] already spells, and every rule a
--  comment cites is one a paragraph states.
--
--  Blocks with an explicit terminator, and not something flatter.  The
--  frontend already owns a structured form: Landin.Syntax is the grammar
--  made addressable and Landin.Checking says what type each of its nodes
--  has, so an IR that kept `if` as a nested construct would be that pair
--  under new names and would buy nothing.  What it earns by being blocks
--  is three things a tree cannot give.  A backend walks a run of
--  instructions and needs one label per block and one transfer per
--  terminator, which is R1.80's shape and not this one's.  [0410] fixes
--  evaluation order, and a linear run of instructions *is* that order,
--  so nothing downstream may reorder by accident.  And "exactly one
--  terminator, in last position" is a property a tree cannot violate and
--  therefore a tree cannot test, while R1.70's exit evidence asks for
--  malformed IR to be rejected.
--
--  No phi and no block parameter, and that is a fact about the kernel
--  rather than a deferral.  Two paragraphs decide it.  [1820]'s `primary`
--  spells literal, identifier, call and a parenthesised expression and no
--  `if`, so a branch is never an expression whose value is wanted --
--  [1080]'s reading of one is described in the tour and is not enabled.
--  And [1840] says "a name declared in one arm is not visible in another
--  and not after the branch closes", so nothing declared inside an arm
--  can be read below it.  Between them: the only thing that survives a
--  merge is a name declared outside the branch, and a name is a slot.
--  When R2.30 enables [1080] a value crosses a merge for the first time,
--  and that is the evidence that makes a merge mechanism necessary.  Not
--  the absence of loops, which R4.10 owns: a loop needs a back edge and
--  changes nothing about what crosses a merge.
--
--  Values are block-local, which is the same decision said from the
--  other side.  [0410] makes `and` and `or` short-circuit, and [0300]
--  makes that observable -- `x <> 0 and 100 / x > 1` traps or does not
--  depending on it -- so the logical words are control flow here and not
--  opcodes.  Their result therefore crosses a merge, and it crosses it
--  through a slot the lowering introduces, exactly as a declared name
--  does.  So an operand names a value defined in the same block, above
--  the instruction using it, and that is a rule one comparison checks
--  rather than a dominance relation over a graph.  It is the invariant
--  Landin.Syntax already chose one level up -- "a child's index is lower
--  than its parent's" -- and it survives R4.10, because a loop does not
--  make a value cross a block.
--
--  What it costs, said plainly: a store and a load per short-circuit and
--  per merged name, which is unoptimised code.  Promoting a slot to a
--  value is R4.50's, where a register allocator is being written and the
--  roadmap already puts "deterministic baseline code generation before
--  competitive optimization".
--
--  A value's identity is the position, inside its item, of the
--  instruction that defines it.  There is no second numbering: a
--  Value_Id names an instruction and the value it defines, because an
--  instruction defines at most one value and defines it exactly once.
--  So "every value has one definition" is not a rule to be checked; it
--  is the shape of the table, the way post-order is a consequence of
--  Landin.Syntax being built bottom up.  What makes it stable is that
--  the number is a position in a lowering order that is a function of
--  the source text alone -- the sources in the order they were given,
--  the declarations in the order they were written, the operands in
--  [0410]'s order -- so the same bytes yield the same numbers on macOS
--  arm64 and in the pinned linux/amd64 container.  It is Node_Id's and
--  Declaration_Id's bargain again: dense, source-ordered, never a hash
--  and never an address.
--
--  Nothing here asks the host how wide anything is, and nothing here
--  names a machine.  A value's type is one of [1790]'s eleven, so usize
--  stays usize: [1870] says "usize is not u64 on a machine whose pointer
--  is eight bytes wide", and an IR that collapsed the two would have
--  encoded a target's pointer width in a language fact.  A Number
--  carries [1770]'s magnitude and [1880]'s unary minus separately, not a
--  two's-complement pattern, because forming the pattern needs the width
--  and a width comes only from Landin.Types.Width against a
--  Landin.Targets.Target_Facts.  Shift_Right on a signed type is
--  [0320]'s sign-keeping shift with an amount "not bounded by the width"
--  [1890]; that x86 masks a shift count, and therefore needs a guard, is
--  R1.80's to know and not this package's.
--
--  Scopes are referred to and not carried.  R1.50 built
--  Landin.Resolution.Scope_Id with a parent link and a sort, and every
--  slot here names a Declaration_Id whose scope that table already
--  answers, so a scope tree here would be a second authority on a
--  question R1.50 answered once -- the argument Landin.Resolution itself
--  makes for not resolving type names.  What R4.60 cannot get by asking
--  is which instructions a scope covers, so a block names its scope and
--  that is the whole of it.  The kernel has no bare block [1090], so a
--  block's scope is a function body, an arm, an `else`, or the scope
--  enclosing a merge.
--
--  What is deliberately not here.  There is no array from Node_Id to
--  Value_Id: R1.40 anticipated one, and the lowering wants a value only
--  while it is building the parent expression, while R4.60 wants the
--  other direction, which is the Origin every instruction carries.  There
--  is no textual reader: a dump is a recorded artefact the way
--  `compiler/tests/lexical.tokens` is, and a reader would be both a
--  second constructor of an IR and the first half of the serialised
--  stage protocol R0.60 refused to freeze.  There is no conversion
--  opcode, because [0700]'s conversion is refused by name [1830].  There
--  is no Discard: [1930] throws a result away and an unused value is how
--  that is spelt, so no rule here says every value is used.  And there is
--  no Increment: [1900] says `inc` says what `x += 1` says, which is a
--  Load, a Number, a trapping Add and a Store.
--
--  A datum's body never runs.  [1460] says "Nothing runs before the
--  entry point" and [1940] says a module value is a literal, an operator
--  of [1820] over literals, or another module binding -- so a datum's
--  block describes its value and is not code.  It is carried as
--  instructions rather than as one folded constant for a narrower reason
--  than it first looks.  [1940] now says a module value is folded and
--  refused when no type holds the answer, and the checker does that -- so
--  a datum that reaches here has a value the compiler knows.  But the
--  checker declines to fold the bitwise and shift levels, because
--  [0320]'s zero-fill beyond the width needs a width and a width needs a
--  target; so `k: u32 = 1 << 40` arrives folded by nobody.  Carrying
--  instructions covers that case without this package learning what a
--  width is.

private with Ada.Containers.Vectors;

with Landin.Provenance;
with Landin.Resolution;
with Landin.Types;

package Landin.IR is

   use type Landin.Provenance.Declaration_Id;
   use type Landin.Resolution.Scope_Id;
   use type Landin.Types.Type_Kind;

   subtype Declaration_Id is Landin.Provenance.Declaration_Id;

   No_Declaration : constant Declaration_Id :=
     Landin.Provenance.No_Declaration;

   subtype Scope_Id is Landin.Resolution.Scope_Id;

   --  A count of parts, and a position among them.  As wide as every
   --  enabled target's `usize` rather than a host Natural: D18 admits an
   --  array of 2**64-1 byte elements on a 64-bit target, and counting parts
   --  in one must not make its declared length the host's business.
   --  One-based, like every other run here.
   type Element_Total is range 0 .. 2 ** 64 - 1;

   --  One past the last is not a position: the longest array has
   --  2**64-1 elements, so every actual one-based position is in this range
   --  and a malformed part reaches the verifier as a verdict rather than as
   --  a range check.
   type Part_Position is range 1 .. 2 ** 64 - 1;


   ------------------------------------------------------------------
   --  Opcodes
   ------------------------------------------------------------------

   --  One per operator [1820] spells, in the order Landin.Syntax spells
   --  them, so the two columns can be read side by side and a check can
   --  compare them.  Two of that table's operators are absent and named
   --  here rather than forgotten: Logical_And and Logical_Or are control
   --  flow, because [0410] short-circuits them.
   --
   --  Every band is contiguous, which is what makes a case over one
   --  exhaustive and a forgotten opcode a compile error under -gnatwe.
   --  That is Landin.Syntax.Node_Kind's argument and Landin.Types'.
   --  [1770]'s two kinds of literal value open it, each carrying its own
   --  payload rather than one opcode carrying both.  A Truth is `false`
   --  or `true` [1870] and not a zero or a one: how a bool is stored is
   --  [0150]'s question and R2.10 owns it.
   type Opcode is
     (Number,
      Truth,
      --  A slot read and written.  A slot is the only thing that
      --  crosses a block boundary; see the header.
      Load,
      Store,
      --  A module value [1940] read and written.  Written, because
      --  [1900] lets a mutable binding be a place and [1740] lets a
      --  module binding carry `mut`.
      Load_Datum,
      Store_Datum,
      --  One field of [0670]'s module state read.  It carries which
      --  field and never where the field sits: an offset needs a target
      --  and this package has none, which is Measure_Size's reason and
      --  the reason an aggregate item carries its fields' types.
      Load_Field,
      Store_Field,
      --  An element selected by a runtime `usize`.  Unlike Load_Field, the
      --  position is an operand because [1950] checks its value at runtime.
      --  D22 lets this reach either [1740]'s module array or [1810]'s
      --  local array in this item's own frame; D48 additionally carries
      --  a containing aggregate field.  Which storage class is reached is
      --  Reaches_A_Slot's answer.
      Load_Element,
      Store_Element,
      --  One whole [0520] array copied between two storage places or D50
      --  fields, cleared in one place or D49 field for [0540], or filled in
      --  one place or D53 field for [0560].  D57 also gives a field-zero
      --  clear the complete padded extent of aggregate storage.  Storage and
      --  field identities never carry one entry per part, so each operation
      --  remains compact for D18's target-sized extent.
      Copy_Array,
      --  D80 copies one complete unfolded variant part between aggregate
      --  storage places.  Field identities are target-neutral; the backend
      --  derives the padded part extent.
      Copy_Variant,
      Clear_Array,
      Fill_Array,
      --  D77 reads the source-order tag of an unfolded variant field.  D78
      --  reads one scalar payload alias.  D76 selects one source-order case
      --  and writes any labelled scalar leaves of that case.  D84 gives the
      --  existing array operations the same case/payload identities for a
      --  fixed-array leaf.  All carry source identities only: the backend
      --  derives target offsets from the aggregate's neutral shape.
      Load_Variant_Tag,
      Load_Variant_Field,
      Select_Variant,
      Store_Variant_Field,
      --  [0370]'s measurements.  The type they ask about is carried, not
      --  the answer: a size needs a width and a width needs a target, so
      --  the answer belongs to whoever has one.  This is the same seam
      --  the bitwise and shift levels of a module fold already sit on.
      Measure_Size,
      Measure_Align,
      --  [1820]'s prefix operators.
      Negation,
      Complement,
      Logical_Not,
      --  [1890]: one integer type in, that type back.
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
      --  [1890]: one type on both sides, and a bool back.
      Equal_To,
      Not_Equal_To,
      Less_Than,
      Less_Or_Equal,
      Greater_Than,
      Greater_Or_Equal,
      --  [1920]: every parameter named once and in order, and the type
      --  of the named return, or no value at all.
      Call,
      --  The terminators.  Leave is [1810]'s `return`, which "carries no
      --  value" in the source because the named return is a place
      --  [0930]; here it carries what that place held, because what a
      --  function hands back is what a backend has to be told.  For a
      --  datum it carries the value the datum has.
      Jump,
      Branch,
      Leave);

   subtype Constant_Kind is Opcode range Number .. Truth;

   subtype Unary_Kind is Opcode range Negation .. Logical_Not;

   subtype Integer_Kind is Opcode range Multiply .. Bitwise_Or;

   subtype Comparison_Kind is Opcode range Equal_To .. Greater_Or_Equal;

   subtype Binary_Kind is Opcode range Multiply .. Greater_Or_Equal;

   subtype Terminator_Kind is Opcode range Jump .. Leave;

   --  Which opcodes never define a value.  A Call is not one of them: it
   --  defines a value exactly when its callee has a result [1920], so the
   --  instruction's own Result answers that and an opcode cannot.
   function Defines_Nothing (Of_Code : Opcode) return Boolean
     is (Of_Code in Store | Store_Datum | Store_Field | Store_Element
                    | Copy_Array | Copy_Variant | Clear_Array | Fill_Array
                    | Select_Variant | Store_Variant_Field
                    | Terminator_Kind);

   ------------------------------------------------------------------
   --  Identities
   ------------------------------------------------------------------

   --  Visible and ordinary integers, the bargain Node_Id and
   --  Declaration_Id already struck: a caller can invent one, which is
   --  what the Holds and Contains predicates are for.
   --
   --  An Item_Id is dense in one unit.  A Slot_Id, a Block_Id and a
   --  Value_Id are dense in one item, and restart at 1 in the next one,
   --  so adding a function does not renumber the values of the function
   --  after it and a recorded dump changes only where the program did.
   type Item_Id  is range 0 .. Integer'Last;
   type Slot_Id  is range 0 .. Integer'Last;
   type Block_Id is range 0 .. Integer'Last;
   type Value_Id is range 0 .. Integer'Last;

   --  One target-neutral aggregate field shape.  D44 needs the scalar form,
   --  D45 adds the compact fixed-scalar-array form for measurement, D46
   --  uses that input for module storage, D74 adds the unfolded variant,
   --  D86 adds a nested aggregate field run for measurement, and D87 carries
   --  that run into runtime storage.  Item and measurement runs remain
   --  separate APIs and vectors.
   type Field_Shape_Kind is
     (Scalar_Field_Shape, Array_Field_Shape, Aggregate_Field_Shape,
      Variant_Field_Shape);

   type Field_Shape is record
      Kind    : Field_Shape_Kind          := Scalar_Field_Shape;
      Element : Landin.Types.Scalar_Name    := Landin.Types.Bool;
      Length  : Element_Total               := 1;
      Cases   : Natural                     := 0;
      Payloads_First : Natural              := 0;
   end record;

   type Field_Shape_Array is array (Positive range <>) of Field_Shape;

   type Case_Run is record
      First : Natural := 0;
      Count : Natural := 0;
   end record;

   type Case_Run_Array is array (Positive range <>) of Case_Run;

   No_Field_Shapes : constant Field_Shape_Array (1 .. 0) := [];
   No_Case_Runs    : constant Case_Run_Array (1 .. 0) := [];

   No_Item  : constant Item_Id  := 0;
   No_Slot  : constant Slot_Id  := 0;
   No_Block : constant Block_Id := 0;
   No_Value : constant Value_Id := 0;

   --  An array copy reaches either a module datum or a slot in the frame of
   --  the item containing the instruction.  A discriminant prevents an
   --  Item_Id and a Slot_Id from becoming interchangeable integers.
   type Storage_Kind is (Module_Datum, Frame_Slot);

   type Storage (Kind : Storage_Kind := Module_Datum) is record
      case Kind is
         when Module_Datum =>
            Datum : Item_Id := No_Item;
         when Frame_Slot =>
            Slot : Slot_Id := No_Slot;
      end case;
   end record;

   --  Block 1 of every item is where it starts.  Named, so no caller
   --  writes the 1, exactly as Landin.Resolution names Program_Scope.
   First_Block : constant Block_Id := 1;

   --  [1800]'s function and [1790]'s module binding.  Derived from
   --  Landin.Resolution.Sort_Of when the item is added and never asked
   --  again, which is what Landin.Resolution does with Declaration_Sort.
   type Item_Kind is (Routine, Datum);

   type Unit is tagged limited private;

   ------------------------------------------------------------------
   --  Building
   ------------------------------------------------------------------

   function Is_Prepared (Of_Unit : Unit) return Boolean;

   --  Sizes the map from a declaration to the item that stands for it,
   --  once, because the declarations are complete when resolution is.
   --  That is Landin.Resolution.Prepare's reason and Landin.Checking's.
   procedure Prepare
     (Into : in out Unit; Meanings : Landin.Resolution.Table)
     with Pre  => not Is_Prepared (Into)
                  and then Landin.Resolution.Is_Prepared (Meanings),
          Post => Is_Prepared (Into) and then Item_Count (Into) = 0;

   function Declaration_Limit (Of_Unit : Unit) return Natural
     with Pre => Is_Prepared (Of_Unit);

   ------------------------------------------------------------------
   --  Items
   ------------------------------------------------------------------

   function Item_Count (Of_Unit : Unit) return Natural;

   function Holds (Of_Unit : Unit; Id : Item_Id) return Boolean
     is (Id /= No_Item and then Natural (Id) <= Item_Count (Of_Unit));

   --  One item per module declaration, in the order the declarations
   --  were recorded, which R1.50 made the order the sources were added
   --  and then the order the declarations were written.
   --
   --  Result is [1800]'s returns for a Routine -- one of [1790]'s eleven,
   --  or Landin.Types.No_Value for `-> none` -- and the declared type for
   --  a Datum.  No_Value is not a new spelling: Landin.Types already
   --  means by it "what a call to a `-> none` function hands back".
   --
   --  A Datum may also be [0670]'s aggregate, whose fields are added
   --  below, or [0520]'s array, whose shape is set below.  A Routine may
   --  not: passing or returning one is an ABI rule and its own slice.
   function Add_Item
     (Into     : in out Unit;
      Kind     : Item_Kind;
      Declares : Declaration_Id;
      Result   : Landin.Types.Type_Kind;
      Site     : Landin.Provenance.Origin) return Item_Id
     with Pre  => Is_Prepared (Into)
                  and then Declares /= No_Declaration
                  and then Natural (Declares)
                           <= Declaration_Limit (Into)
                  and then Item_For (Into, Declares) = No_Item
                  and then (Result in Landin.Types.Scalar_Name
                            or else (Kind = Routine
                                     and then Result
                                              = Landin.Types.No_Value)
                            or else (Kind = Datum
                                     and then Result
                                              in Landin.Types.Aggregate
                                                 | Landin.Types.Fixed_Array))
                  and then Landin.Provenance.Is_Known (Site),
          Post => Item_Count (Into) = Item_Count (Into)'Old + 1
                  and then Holds (Into, Add_Item'Result)
                  and then Item_For (Into, Declares) = Add_Item'Result
                  and then Kind_Of (Into, Add_Item'Result) = Kind
                  and then Result_Of (Into, Add_Item'Result) = Result;

   function Kind_Of (Of_Unit : Unit; Id : Item_Id) return Item_Kind
     with Pre => Holds (Of_Unit, Id);

   function Declares (Of_Unit : Unit; Id : Item_Id) return Declaration_Id
     with Pre  => Holds (Of_Unit, Id),
          Post => Declares'Result /= No_Declaration;

   function Result_Of (Of_Unit : Unit; Id : Item_Id)
     return Landin.Types.Type_Kind
     with Pre => Holds (Of_Unit, Id);

   function Origin_Of (Of_Unit : Unit; Id : Item_Id)
     return Landin.Provenance.Origin
     with Pre => Holds (Of_Unit, Id);

   --  Which item stands for a declaration, so a call and a module read
   --  cost one index.  No_Item for a declaration that is not a module
   --  one: a parameter, a named return and a local binding are slots of
   --  an item and not items.
   function Item_For (Of_Unit : Unit; Declared : Declaration_Id)
     return Item_Id
     with Pre => Is_Prepared (Of_Unit)
                 and then Natural (Declared) <= Declaration_Limit (Of_Unit);

   ------------------------------------------------------------------
   --  An aggregate item's fields
   ------------------------------------------------------------------

   --  [0750]: an aggregate datum's fields, in the order they were written.
   --  D46 permits scalar and compact fixed-scalar-array shapes; D75 adds
   --  the unfolded variant shape already used by D74's measurements.  Shapes
   --  and not offsets are carried, for the reason
   --  Measure_Size carries a type rather than an answer: an offset needs
   --  a target and this package has none.  Whoever holds a description
   --  lays them out with Landin.Targets.Placement and gets what the
   --  checker got, because it is the same arithmetic over the same run.
   function Field_Count (Of_Unit : Unit; Item : Item_Id) return Natural
     with Pre => Holds (Of_Unit, Item);

   procedure Add_Field
     (Into    : in out Unit;
      Item    : Item_Id;
      Of_Type : Landin.Types.Scalar_Name)
     with Pre  => Holds (Into, Item)
                  and then Result_Of (Into, Item) = Landin.Types.Aggregate,
          Post => Field_Count (Into, Item)
                    = Field_Count (Into, Item)'Old + 1
                  and then Nth_Field
                             (Into, Item, Field_Count (Into, Item))
                           = Of_Type;

   procedure Add_Field
     (Into : in out Unit;
      Item : Item_Id;
      Shape : Field_Shape)
     with Pre  => Holds (Into, Item)
                  and then Result_Of (Into, Item) = Landin.Types.Aggregate,
          Post => Field_Count (Into, Item)
                    = Field_Count (Into, Item)'Old + 1
                  and then Nth_Field_Shape
                    (Into, Item, Field_Count (Into, Item)) = Shape;

   --  D75 carries a variant field's target-neutral case payloads beside
   --  runtime storage as well as beside D74's measurements.  D87 carries
   --  D86's depth-one ordinary-struct run through the same vectors.  The
   --  top-level shape names the supplied run; neither contains target
   --  offsets.
   procedure Add_Field
     (Into    : in out Unit;
      Item    : Item_Id;
      Shape   : Field_Shape;
      Cases   : Case_Run_Array;
      Payloads : Field_Shape_Array)
     with Pre  => Holds (Into, Item)
                  and then Result_Of (Into, Item) = Landin.Types.Aggregate
                  and then Shape.Kind in
                    Variant_Field_Shape | Aggregate_Field_Shape
                  and then Shape.Payloads_First = 1
                  and then
                    (if Shape.Kind = Variant_Field_Shape
                     then Shape.Cases = Cases'Length
                     else Cases'Length = 0
                       and then Shape.Cases = Payloads'Length),
          Post => Field_Count (Into, Item)
                    = Field_Count (Into, Item)'Old + 1;

   function Nth_Field_Shape
     (Of_Unit : Unit; Item : Item_Id; Index : Positive)
      return Field_Shape
     with Pre => Holds (Of_Unit, Item)
                 and then Index <= Field_Count (Of_Unit, Item);

   function Nth_Field
     (Of_Unit : Unit; Item : Item_Id; Index : Positive)
     return Landin.Types.Scalar_Name
     with Pre => Holds (Of_Unit, Item)
                 and then Index <= Field_Count (Of_Unit, Item)
                 and then Nth_Field_Shape (Of_Unit, Item, Index).Kind
                            = Scalar_Field_Shape;

   --  How many parts an aggregate item has, and what one holds, whether
   --  it is [0670]'s struct or [0520]'s array.  A field and an element
   --  are one question to everything downstream: which one, by position,
   --  and what type it is.  Only how they are recorded differs, because
   --  a struct's fields each have their own type and an array's do not.
   function Part_Count (Of_Unit : Unit; Item : Item_Id) return Element_Total
     with Pre => Holds (Of_Unit, Item);

   function Part_Is_Scalar
     (Of_Unit : Unit; Item : Item_Id; Index : Part_Position) return Boolean
     with Pre => Holds (Of_Unit, Item)
                 and then Element_Total (Index) <= Part_Count (Of_Unit, Item);

   function Nth_Part
     (Of_Unit : Unit; Item : Item_Id; Index : Part_Position)
     return Landin.Types.Scalar_Name
     with Pre => Holds (Of_Unit, Item)
                 and then Element_Total (Index) <= Part_Count (Of_Unit, Item)
                 and then Part_Is_Scalar (Of_Unit, Item, Index);

   ------------------------------------------------------------------
   --  An array item's shape
   ------------------------------------------------------------------

   --  [0520]'s array is its element repeated, so it is carried as one
   --  element and a count rather than as a run of them.  D17 makes that
   --  the whole of its identity, and the count reaches 2**32-1: a run
   --  would be four billion entries for a type whose layout is one
   --  multiplication.
   procedure Set_Array
     (Into    : in out Unit;
      Item    : Item_Id;
      Of_Type : Landin.Types.Scalar_Name;
      Length  : Element_Total)
     with Pre  => Holds (Into, Item)
                  and then Result_Of (Into, Item)
                           = Landin.Types.Fixed_Array,
          Post => Array_Element (Into, Item) = Of_Type
                  and then Array_Length (Into, Item) = Length;

   function Array_Element
     (Of_Unit : Unit; Item : Item_Id) return Landin.Types.Scalar_Name
     with Pre => Holds (Of_Unit, Item)
                 and then Result_Of (Of_Unit, Item)
                          = Landin.Types.Fixed_Array;

   function Array_Length
     (Of_Unit : Unit; Item : Item_Id) return Element_Total
     with Pre => Holds (Of_Unit, Item)
                 and then Result_Of (Of_Unit, Item)
                          = Landin.Types.Fixed_Array;

   type Field_Image_Form is (Absent, Finite, Repeated, Hybrid, Selected);

   --  D67: the target-neutral image carried beside one aggregate field.
   --  Offset and Count select a finite run concatenated after D66's one flat
   --  fold per field.  Absent is the field's zero image; Finite is enabled by
   --  D67.  D68 uses Repeated for one nonzero full pattern and Hybrid for a
   --  finite prefix followed by one suffix pattern.  Selected is D81's
   --  variant image: Value is the one-based case, while Offset and Count
   --  select its declaration-order payload descriptors from the same item
   --  run after the aggregate's top-level descriptors.
   type Aggregate_Field_Image is record
      Form   : Field_Image_Form     := Absent;
      Offset : Natural              := 0;
      Count  : Natural              := 0;
      Value  : Landin.Types.Folded  := 0;
   end record;

   type Aggregate_Field_Image_Array is
     array (Positive range <>) of Aggregate_Field_Image;

   function Field_Image_Element_Count
     (Fields : Aggregate_Field_Image_Array) return Element_Total;

   --  D66: a nonzero module struct image starts with one target-neutral
   --  folded value per declaration-order field.  Scalar entries are the
   --  values a backend writes at its own widths; an array field keeps zero as
   --  that flat placeholder.  Padding is never represented here: it belongs
   --  to target layout and is emitted as zero by the backend.
   procedure Set_Aggregate_Image
     (Into   : in out Unit;
      Item   : Item_Id;
      Fields : Landin.Types.Folded_Array)
     with Pre  => Holds (Into, Item)
                  and then Result_Of (Into, Item)
                           = Landin.Types.Aggregate
                  and then not Has_Image (Into, Item)
                  and then Fields'Length = Field_Count (Into, Item)
                  and then Fields'Length > 0,
          Post => Has_Image (Into, Item)
                  and then Image_Length (Into, Item)
                           = Element_Total (Fields'Length);

   --  D67's complete aggregate image: the flat D66 run, one descriptor per
   --  field, and the concatenated finite array elements in field order.  The
   --  offsets are relative to Elements, never target bytes.
   procedure Set_Aggregate_Image
     (Into    : in out Unit;
      Item    : Item_Id;
      Fields  : Landin.Types.Folded_Array;
      Arrays  : Aggregate_Field_Image_Array;
      Elements : Landin.Types.Folded_Array)
     with Pre  => Holds (Into, Item)
                  and then Result_Of (Into, Item)
                           = Landin.Types.Aggregate
                  and then not Has_Image (Into, Item)
                  and then Fields'Length = Field_Count (Into, Item)
                  and then Arrays'Length = Field_Count (Into, Item)
                  and then Fields'Length > 0
                  and then Field_Image_Element_Count (Arrays)
                           = Element_Total (Elements'Length),
          Post => Has_Image (Into, Item)
                  and then Image_Length (Into, Item)
                           = Element_Total
                               (Fields'Length + Elements'Length);

   --  D81 appends one descriptor per selected variant payload field after
   --  the top-level descriptors.  Array elements from either level share
   --  Elements; every offset is relative to that one fold run.
   procedure Set_Aggregate_Image
     (Into     : in out Unit;
      Item     : Item_Id;
      Fields   : Landin.Types.Folded_Array;
      Images   : Aggregate_Field_Image_Array;
      Payloads : Aggregate_Field_Image_Array;
      Elements : Landin.Types.Folded_Array)
     with Pre  => Holds (Into, Item)
                  and then Result_Of (Into, Item)
                           = Landin.Types.Aggregate
                  and then not Has_Image (Into, Item)
                  and then Fields'Length = Field_Count (Into, Item)
                  and then Images'Length = Field_Count (Into, Item)
                  and then Fields'Length > 0
                  and then Field_Image_Element_Count (Images)
                             + Field_Image_Element_Count (Payloads)
                           = Element_Total (Elements'Length),
          Post => Has_Image (Into, Item)
                  and then Image_Length (Into, Item)
                           = Element_Total
                               (Fields'Length + Elements'Length);

   function Aggregate_Field_Image_Count
     (Of_Unit : Unit; Item : Item_Id) return Natural
     with Pre => Holds (Of_Unit, Item)
                 and then Result_Of (Of_Unit, Item)
                          = Landin.Types.Aggregate
                 and then Has_Image (Of_Unit, Item);

   function Field_Image_Of
     (Of_Unit : Unit; Item : Item_Id; Field : Positive)
      return Aggregate_Field_Image
     with Pre => Holds (Of_Unit, Item)
                 and then Result_Of (Of_Unit, Item)
                          = Landin.Types.Aggregate
                 and then Has_Image (Of_Unit, Item)
                 and then Field <= Aggregate_Field_Image_Count
                                      (Of_Unit, Item);

   function Nth_Field_Element
     (Of_Unit : Unit;
      Item    : Item_Id;
      Field   : Positive;
      Position : Part_Position) return Landin.Types.Folded
     with Pre => Holds (Of_Unit, Item)
                 and then Result_Of (Of_Unit, Item)
                          = Landin.Types.Aggregate
                 and then Has_Image (Of_Unit, Item)
                 and then Field <= Aggregate_Field_Image_Count
                                      (Of_Unit, Item)
                 and then Field_Image_Of (Of_Unit, Item, Field).Form
                          in Finite | Hybrid
                 and then Element_Total (Position)
                          <= Element_Total
                               (Field_Image_Of
                                  (Of_Unit, Item, Field).Count)
                 and then Element_Total (Field_Count (Of_Unit, Item))
                            + Element_Total
                                (Field_Image_Of
                                   (Of_Unit, Item, Field).Offset)
                            + Element_Total (Position)
                          <= Image_Length (Of_Unit, Item);

   function Variant_Payload_Image_Of
     (Of_Unit : Unit;
      Item    : Item_Id;
      Field   : Positive;
      Payload : Positive) return Aggregate_Field_Image
     with Pre => Holds (Of_Unit, Item)
                 and then Result_Of (Of_Unit, Item)
                          = Landin.Types.Aggregate
                 and then Has_Image (Of_Unit, Item)
                 and then Field <= Field_Count (Of_Unit, Item)
                 and then Field_Image_Of (Of_Unit, Item, Field).Form
                          = Selected
                 and then Payload
                          <= Field_Image_Of
                               (Of_Unit, Item, Field).Count
                 and then Field_Count (Of_Unit, Item)
                            + Field_Image_Of
                                (Of_Unit, Item, Field).Offset
                            + Payload
                          <= Aggregate_Field_Image_Count (Of_Unit, Item);

   function Nth_Variant_Field_Element
     (Of_Unit : Unit;
      Item    : Item_Id;
      Field   : Positive;
      Payload : Positive;
      Position : Part_Position) return Landin.Types.Folded
     with Pre => Holds (Of_Unit, Item)
                 and then Result_Of (Of_Unit, Item)
                          = Landin.Types.Aggregate
                 and then Has_Image (Of_Unit, Item)
                 and then Field <= Field_Count (Of_Unit, Item)
                 and then Field_Image_Of (Of_Unit, Item, Field).Form
                          = Selected
                 and then Payload
                          <= Field_Image_Of
                               (Of_Unit, Item, Field).Count
                 and then Variant_Payload_Image_Of
                   (Of_Unit, Item, Field, Payload).Form in Finite | Hybrid
                 and then Element_Total (Position)
                          <= Element_Total
                               (Variant_Payload_Image_Of
                                  (Of_Unit, Item, Field, Payload).Count)
                 and then Element_Total (Field_Count (Of_Unit, Item))
                            + Element_Total
                                (Variant_Payload_Image_Of
                                   (Of_Unit, Item, Field, Payload).Offset)
                            + Element_Total (Position)
                          <= Image_Length (Of_Unit, Item);

   function Nth_Field_Image
     (Of_Unit : Unit; Item : Item_Id; Field : Positive)
      return Landin.Types.Folded
     with Pre => Holds (Of_Unit, Item)
                 and then Result_Of (Of_Unit, Item)
                          = Landin.Types.Aggregate
                 and then Has_Image (Of_Unit, Item)
                 and then Field <= Field_Count (Of_Unit, Item)
                 and then Element_Total (Field)
                          <= Image_Length (Of_Unit, Item);

   --  D24: the source-order static image of an array literal datum, one
   --  folded value per position.  An array item with no image is D10's
   --  all-zero storage (or D34's zero-pattern repetition): the backend
   --  reserves it in `.bss` and this package allocates no run for it.  A
   --  literal image reaches `.data`, one directive per position.  A run and
   --  not one operand per element, because [1940] admits a literal, an
   --  operator of [1820] over literals, and a name bound to another module
   --  binding -- and each of those already folds to a single Folded value
   --  the backend can materialise.  Requires the count to match the array's
   --  declared length, so the reader is spared having to guess.
   procedure Set_Array_Image
     (Into     : in out Unit;
      Item     : Item_Id;
      Elements : Landin.Types.Folded_Array)
     with Pre  => Holds (Into, Item)
                  and then Result_Of (Into, Item)
                           = Landin.Types.Fixed_Array
                  and then not Has_Image (Into, Item)
                  and then Element_Total (Elements'Length)
                           = Array_Length (Into, Item)
                  and then Elements'Length > 0,
          Post => Has_Image (Into, Item)
                  and then Image_Length (Into, Item)
                           = Element_Total (Elements'Length);

   --  D34's repetition image is one folded scalar plus the array shape,
   --  never a run proportional to a target-sized extent.  A zero pattern is
   --  represented by no image instead and remains loader-zeroed storage.
   procedure Set_Repeated_Array_Image
     (Into  : in out Unit;
      Item  : Item_Id;
      Value : Landin.Types.Folded)
     with Pre  => Holds (Into, Item)
                  and then Result_Of (Into, Item)
                           = Landin.Types.Fixed_Array
                  and then Array_Length (Into, Item) > 0
                  and then not Has_Image (Into, Item)
                  and then Landin.Types."/=" (Value, 0),
          Post => Has_Image (Into, Item)
                  and then Is_Repeated_Image (Into, Item)
                  and then Image_Prefix_Length (Into, Item) = 0
                  and then Landin.Types."="
                             (Repeated_Image_Value (Into, Item), Value);

   --  D38's hybrid image is the finite source prefix followed by one scalar
   --  repeated through the rest of the declared shape.  The repeated value is
   --  present even when zero: unlike a full zero repetition, a nonempty prefix
   --  makes this `.data`, and neither this run nor its readers expand N - k.
   procedure Set_Hybrid_Array_Image
     (Into   : in out Unit;
      Item   : Item_Id;
      Prefix : Landin.Types.Folded_Array;
      Value  : Landin.Types.Folded)
     with Pre  => Holds (Into, Item)
                  and then Result_Of (Into, Item)
                           = Landin.Types.Fixed_Array
                  and then Prefix'Length > 0
                  and then Element_Total (Prefix'Length)
                           < Array_Length (Into, Item)
                  and then not Has_Image (Into, Item),
          Post => Has_Image (Into, Item)
                  and then Is_Repeated_Image (Into, Item)
                  and then Image_Prefix_Length (Into, Item)
                           = Element_Total (Prefix'Length)
                  and then Landin.Types."="
                             (Repeated_Image_Value (Into, Item), Value);

   function Has_Image (Of_Unit : Unit; Item : Item_Id) return Boolean
     with Pre => Holds (Of_Unit, Item)
                 and then Result_Of (Of_Unit, Item)
                          in Landin.Types.Fixed_Array
                             | Landin.Types.Aggregate;

   function Is_Repeated_Image
     (Of_Unit : Unit; Item : Item_Id) return Boolean
     with Pre => Holds (Of_Unit, Item)
                 and then Result_Of (Of_Unit, Item)
                          = Landin.Types.Fixed_Array;

   function Image_Prefix_Length
     (Of_Unit : Unit; Item : Item_Id) return Element_Total
     with Pre => Holds (Of_Unit, Item)
                 and then Result_Of (Of_Unit, Item)
                          = Landin.Types.Fixed_Array
                 and then Is_Repeated_Image (Of_Unit, Item);

   function Repeated_Image_Value
     (Of_Unit : Unit; Item : Item_Id) return Landin.Types.Folded
     with Pre => Holds (Of_Unit, Item)
                 and then Result_Of (Of_Unit, Item)
                          = Landin.Types.Fixed_Array
                 and then Is_Repeated_Image (Of_Unit, Item);

   function Image_Length
     (Of_Unit : Unit; Item : Item_Id) return Element_Total
     with Pre => Holds (Of_Unit, Item)
                 and then Result_Of (Of_Unit, Item)
                          in Landin.Types.Fixed_Array
                             | Landin.Types.Aggregate
                 and then Has_Image (Of_Unit, Item);

   function Nth_Image
     (Of_Unit : Unit; Item : Item_Id; Index : Part_Position)
     return Landin.Types.Folded
     with Pre => Holds (Of_Unit, Item)
                 and then Result_Of (Of_Unit, Item)
                          = Landin.Types.Fixed_Array
                 and then Has_Image (Of_Unit, Item)
                 and then Element_Total (Index)
                          <= Image_Length (Of_Unit, Item);

   ------------------------------------------------------------------
   --  Slots
   ------------------------------------------------------------------

   --  A named cell of one of [1790]'s eleven types, and the only thing
   --  that crosses a block boundary.  Five kinds of thing become one:
   --  [1800]'s parameter, its named return, [1810]'s local binding, a cell
   --  the lowering introduces for a short-circuit's result, and a temporary
   --  that carries an earlier call or binary operand past the blocks a later
   --  operand can make.  The last two have no declaration; the first three
   --  carry theirs, which is how R4.60 puts a name on one and how
   --  Landin.Resolution answers which scope it is in.
   --
   --  A slot has no address, no offset and no size.  Where it lives is
   --  R1.80's frame question and how wide it is comes from
   --  Landin.Types.Width against a target description.
   --
   --  A slot may also hold [0670]'s aggregate, and then it carries its
   --  fields' types the way an aggregate item does and for the same
   --  reason: where each one sits needs a target and this package has
   --  none.  Only a local binding [1810] is one today, because a
   --  parameter and a named return are an ABI question R2.30 owns.
   function Slot_Count (Of_Unit : Unit; Item : Item_Id) return Natural
     with Pre => Holds (Of_Unit, Item);

   function Holds
     (Of_Unit : Unit; Item : Item_Id; Slot : Slot_Id) return Boolean
     is (Holds (Of_Unit, Item)
         and then Slot /= No_Slot
         and then Natural (Slot) <= Slot_Count (Of_Unit, Item));

   function Add_Slot
     (Into     : in out Unit;
      Item     : Item_Id;
      Of_Type  : Landin.Types.Scalar_Name;
      Declares : Declaration_Id;
      Site     : Landin.Provenance.Origin) return Slot_Id
     with Pre  => Holds (Into, Item)
                  and then Landin.Provenance.Is_Known (Site),
          Post => Slot_Count (Into, Item)
                    = Slot_Count (Into, Item)'Old + 1
                  and then Holds (Into, Item, Add_Slot'Result)
                  and then Type_Of (Into, Item, Add_Slot'Result) = Of_Type;

   --  A cell holding [0670]'s aggregate.  Its fields are added below, in
   --  the order [0750] wrote them, and it has no scalar type at all:
   --  Type_Of is the wrong question to ask one, which its precondition
   --  says rather than answering Bool by default.
   function Add_Aggregate_Slot
     (Into     : in out Unit;
      Item     : Item_Id;
      Declares : Declaration_Id;
      Site     : Landin.Provenance.Origin) return Slot_Id
     with Pre  => Holds (Into, Item)
                  and then Landin.Provenance.Is_Known (Site),
          Post => Slot_Count (Into, Item)
                    = Slot_Count (Into, Item)'Old + 1
                  and then Holds (Into, Item, Add_Aggregate_Slot'Result)
                  and then Is_Aggregate
                             (Into, Item, Add_Aggregate_Slot'Result);

   function Is_Aggregate
     (Of_Unit : Unit; Item : Item_Id; Slot : Slot_Id) return Boolean
     with Pre => Holds (Of_Unit, Item) and then Holds (Of_Unit, Item, Slot);

   --  A fixed-array cell carries the repeated element once and its target-
   --  width length, never a length-sized field run.
   function Add_Array_Slot
     (Into     : in out Unit;
      Item     : Item_Id;
      Of_Type  : Landin.Types.Scalar_Name;
      Length   : Element_Total;
      Declares : Declaration_Id;
      Site     : Landin.Provenance.Origin) return Slot_Id
     with Pre  => Holds (Into, Item)
                  and then Landin.Provenance.Is_Known (Site),
          Post => Slot_Count (Into, Item) = Slot_Count (Into, Item)'Old + 1
                  and then Holds (Into, Item, Add_Array_Slot'Result)
                  and then Is_Array (Into, Item, Add_Array_Slot'Result)
                  and then Slot_Array_Element
                             (Into, Item, Add_Array_Slot'Result) = Of_Type
                  and then Slot_Array_Length
                             (Into, Item, Add_Array_Slot'Result) = Length;

   function Is_Array
     (Of_Unit : Unit; Item : Item_Id; Slot : Slot_Id) return Boolean
     with Pre => Holds (Of_Unit, Item) and then Holds (Of_Unit, Item, Slot);

   function Slot_Array_Element
     (Of_Unit : Unit; Item : Item_Id; Slot : Slot_Id)
      return Landin.Types.Scalar_Name
     with Pre => Holds (Of_Unit, Item, Slot)
                 and then Is_Array (Of_Unit, Item, Slot);

   function Slot_Array_Length
     (Of_Unit : Unit; Item : Item_Id; Slot : Slot_Id) return Element_Total
     with Pre => Holds (Of_Unit, Item, Slot)
                 and then Is_Array (Of_Unit, Item, Slot);

   function Slot_Part_Count
     (Of_Unit : Unit; Item : Item_Id; Slot : Slot_Id) return Element_Total
     with Pre => Holds (Of_Unit, Item, Slot);

   function Slot_Part_Is_Scalar
     (Of_Unit : Unit; Item : Item_Id; Slot : Slot_Id;
      Index : Part_Position) return Boolean
     with Pre => Holds (Of_Unit, Item, Slot)
                 and then Element_Total (Index)
                            <= Slot_Part_Count (Of_Unit, Item, Slot);

   function Nth_Slot_Part
     (Of_Unit : Unit; Item : Item_Id; Slot : Slot_Id;
      Index : Part_Position) return Landin.Types.Scalar_Name
     with Pre => Holds (Of_Unit, Item, Slot)
                 and then Element_Total (Index)
                            <= Slot_Part_Count (Of_Unit, Item, Slot)
                 and then Slot_Part_Is_Scalar
                            (Of_Unit, Item, Slot, Index);

   function Slot_Field_Count
     (Of_Unit : Unit; Item : Item_Id; Slot : Slot_Id) return Natural
     with Pre => Holds (Of_Unit, Item) and then Holds (Of_Unit, Item, Slot);

   procedure Add_Slot_Field
     (Into    : in out Unit;
      Item    : Item_Id;
      Slot    : Slot_Id;
      Of_Type : Landin.Types.Scalar_Name)
     with Pre  => Holds (Into, Item)
                  and then Holds (Into, Item, Slot)
                  and then Is_Aggregate (Into, Item, Slot),
          Post => Slot_Field_Count (Into, Item, Slot)
                    = Slot_Field_Count (Into, Item, Slot)'Old + 1;

   procedure Add_Slot_Field
     (Into : in out Unit;
      Item : Item_Id;
      Slot : Slot_Id;
      Shape : Field_Shape)
     with Pre  => Holds (Into, Item)
                  and then Holds (Into, Item, Slot)
                  and then Is_Aggregate (Into, Item, Slot),
          Post => Slot_Field_Count (Into, Item, Slot)
                    = Slot_Field_Count (Into, Item, Slot)'Old + 1
                  and then Nth_Slot_Field_Shape
                    (Into, Item, Slot,
                     Slot_Field_Count (Into, Item, Slot)) = Shape;

   procedure Add_Slot_Field
     (Into     : in out Unit;
      Item     : Item_Id;
      Slot     : Slot_Id;
      Shape    : Field_Shape;
      Cases    : Case_Run_Array;
      Payloads : Field_Shape_Array)
     with Pre  => Holds (Into, Item)
                  and then Holds (Into, Item, Slot)
                  and then Is_Aggregate (Into, Item, Slot)
                  and then Shape.Kind in
                    Variant_Field_Shape | Aggregate_Field_Shape
                  and then Shape.Payloads_First = 1
                  and then
                    (if Shape.Kind = Variant_Field_Shape
                     then Shape.Cases = Cases'Length
                     else Cases'Length = 0
                       and then Shape.Cases = Payloads'Length),
          Post => Slot_Field_Count (Into, Item, Slot)
                    = Slot_Field_Count (Into, Item, Slot)'Old + 1;

   function Nth_Slot_Field_Shape
     (Of_Unit : Unit;
      Item    : Item_Id;
      Slot    : Slot_Id;
      Index   : Positive) return Field_Shape
     with Pre => Holds (Of_Unit, Item)
                 and then Holds (Of_Unit, Item, Slot)
                 and then Index <= Slot_Field_Count (Of_Unit, Item, Slot);

   function Nth_Slot_Field
     (Of_Unit : Unit;
      Item    : Item_Id;
      Slot    : Slot_Id;
      Index   : Positive) return Landin.Types.Scalar_Name
     with Pre => Holds (Of_Unit, Item)
                 and then Holds (Of_Unit, Item, Slot)
                 and then Index <= Slot_Field_Count (Of_Unit, Item, Slot)
                 and then Nth_Slot_Field_Shape
                   (Of_Unit, Item, Slot, Index).Kind = Scalar_Field_Shape;

   --  Adds a slot and makes it the next parameter [1800].  A parameter
   --  is a slot the caller filled, so the ABI has somewhere to put an
   --  incoming argument and [1900]'s rule that a parameter may not be
   --  written is a rule about Store and not about the prologue.
   function Add_Parameter
     (Into     : in out Unit;
      Item     : Item_Id;
      Of_Type  : Landin.Types.Scalar_Name;
      Declares : Declaration_Id;
      Site     : Landin.Provenance.Origin) return Slot_Id
     with Pre  => Holds (Into, Item)
                  and then Kind_Of (Into, Item) = Routine
                  and then Declares /= No_Declaration
                  and then Landin.Provenance.Is_Known (Site),
          Post => Parameter_Count (Into, Item)
                    = Parameter_Count (Into, Item)'Old + 1
                  and then Holds (Into, Item, Add_Parameter'Result)
                  and then Nth_Parameter
                             (Into, Item,
                              Parameter_Count (Into, Item))
                           = Add_Parameter'Result;

   function Parameter_Count (Of_Unit : Unit; Item : Item_Id) return Natural
     with Pre => Holds (Of_Unit, Item);

   function Nth_Parameter
     (Of_Unit : Unit; Item : Item_Id; Index : Positive) return Slot_Id
     with Pre  => Holds (Of_Unit, Item)
                  and then Index <= Parameter_Count (Of_Unit, Item),
          Post => Holds (Of_Unit, Item, Nth_Parameter'Result);

   --  Which slot is [1800]'s named return.  No_Slot for `-> none` and
   --  for a datum.
   procedure Set_Result_Slot
     (Into : in out Unit; Item : Item_Id; Slot : Slot_Id)
     with Pre  => Holds (Into, Item)
                  and then Kind_Of (Into, Item) = Routine
                  and then Holds (Into, Item, Slot)
                  and then Result_Slot (Into, Item) = No_Slot
                  and then Type_Of (Into, Item, Slot)
                           = Result_Of (Into, Item),
          Post => Result_Slot (Into, Item) = Slot;

   function Result_Slot (Of_Unit : Unit; Item : Item_Id) return Slot_Id
     with Pre => Holds (Of_Unit, Item);

   function Type_Of (Of_Unit : Unit; Item : Item_Id; Slot : Slot_Id)
     return Landin.Types.Scalar_Name
     with Pre => Holds (Of_Unit, Item)
                 and then Holds (Of_Unit, Item, Slot)
                 and then not Is_Aggregate (Of_Unit, Item, Slot)
                 and then not Is_Array (Of_Unit, Item, Slot);

   function Declares
     (Of_Unit : Unit; Item : Item_Id; Slot : Slot_Id) return Declaration_Id
     with Pre => Holds (Of_Unit, Item) and then Holds (Of_Unit, Item, Slot);

   function Origin_Of
     (Of_Unit : Unit; Item : Item_Id; Slot : Slot_Id)
     return Landin.Provenance.Origin
     with Pre => Holds (Of_Unit, Item) and then Holds (Of_Unit, Item, Slot);

   ------------------------------------------------------------------
   --  Blocks
   ------------------------------------------------------------------

   --  A block is entered once and left once, and its instructions are the
   --  contiguous run appended while it was open.  That is not a taste: a
   --  structured lowering never returns to a block it has left, so the
   --  run is contiguous without patching a terminator or numbering the
   --  instructions in a second pass -- and a run is what lets a block
   --  hold a first index and a count rather than a container of its own,
   --  which is what Landin.Syntax does with a node's children.
   --
   --  Block ids are therefore in the order blocks were created and not in
   --  the order their instructions were emitted: an `if`'s else-entry is
   --  created before the then-arm's inner blocks and filled after them.
   --  Both orders are functions of the source text, and a reader is told
   --  which one a dump prints.
   function Block_Count (Of_Unit : Unit; Item : Item_Id) return Natural
     with Pre => Holds (Of_Unit, Item);

   function Holds
     (Of_Unit : Unit; Item : Item_Id; Block : Block_Id) return Boolean
     is (Holds (Of_Unit, Item)
         and then Block /= No_Block
         and then Natural (Block) <= Block_Count (Of_Unit, Item));

   function Add_Block
     (Into  : in out Unit;
      Item  : Item_Id;
      Scope : Scope_Id;
      Site  : Landin.Provenance.Origin) return Block_Id
     with Pre  => Holds (Into, Item)
                  and then Scope /= Landin.Resolution.No_Scope
                  and then Landin.Provenance.Is_Known (Site),
          Post => Block_Count (Into, Item)
                    = Block_Count (Into, Item)'Old + 1
                  and then Holds (Into, Item, Add_Block'Result)
                  and then Length (Into, Item, Add_Block'Result) = 0;

   --  Opens a block for emission.  Once per block, and one at a time:
   --  two open blocks would interleave two runs, and a run that is not
   --  contiguous is not a run.  This is the builder keeping the table
   --  whole, not the verifier keeping the program right; the note above
   --  the Emit subprograms below is where that line is drawn.
   procedure Enter
     (Into : in out Unit; Item : Item_Id; Block : Block_Id)
     with Pre  => Holds (Into, Item, Block)
                  and then Open_Block (Into, Item) = No_Block
                  and then Length (Into, Item, Block) = 0,
          Post => Open_Block (Into, Item) = Block;

   procedure Leave_Block (Into : in out Unit; Item : Item_Id)
     with Pre  => Holds (Into, Item)
                  and then Open_Block (Into, Item) /= No_Block,
          Post => Open_Block (Into, Item) = No_Block;

   function Open_Block (Of_Unit : Unit; Item : Item_Id) return Block_Id
     with Pre => Holds (Of_Unit, Item);

   --  The scope [1840] this block's instructions are inside, which is
   --  what R4.60 turns into a lexical block with a range of addresses.
   function Scope_Of
     (Of_Unit : Unit; Item : Item_Id; Block : Block_Id) return Scope_Id
     with Pre => Holds (Of_Unit, Item, Block);

   function Origin_Of
     (Of_Unit : Unit; Item : Item_Id; Block : Block_Id)
     return Landin.Provenance.Origin
     with Pre => Holds (Of_Unit, Item, Block);

   function Length
     (Of_Unit : Unit; Item : Item_Id; Block : Block_Id) return Natural
     with Pre => Holds (Of_Unit, Item, Block);

   function Nth_Value
     (Of_Unit : Unit;
      Item    : Item_Id;
      Block   : Block_Id;
      Index   : Positive) return Value_Id
     with Pre  => Holds (Of_Unit, Item, Block)
                  and then Index <= Length (Of_Unit, Item, Block),
          Post => Holds (Of_Unit, Item, Nth_Value'Result);

   ------------------------------------------------------------------
   --  Instructions
   ------------------------------------------------------------------

   function Value_Count (Of_Unit : Unit; Item : Item_Id) return Natural
     with Pre => Holds (Of_Unit, Item);

   function Holds
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id) return Boolean
     is (Holds (Of_Unit, Item)
         and then Value /= No_Value
         and then Natural (Value) <= Value_Count (Of_Unit, Item));

   function Op_Of
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id) return Opcode
     with Pre => Holds (Of_Unit, Item, Value);

   --  The type of the value this instruction defines, or
   --  Landin.Types.Not_Typed when it defines none.  Not_Typed is not a
   --  new spelling either: Landin.Types already means by it "a node that
   --  is not a thing with a type".
   function Result_Of
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id)
     return Landin.Types.Type_Kind
     with Pre => Holds (Of_Unit, Item, Value);

   --  Where the construct this instruction came from is written.  Taken
   --  from Landin.Syntax.Anchor and not from the extent, because that is
   --  the one token the node is attributed to and R4.60 puts a line-table
   --  row on it.
   function Origin_Of
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id)
     return Landin.Provenance.Origin
     with Pre => Holds (Of_Unit, Item, Value);

   function Block_Of
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id) return Block_Id
     with Pre  => Holds (Of_Unit, Item, Value),
          Post => Holds (Of_Unit, Item, Block_Of'Result);

   --  Every operand is in one run, whatever the opcode, so a walk over
   --  an instruction's operands is one loop and no kind hides one in a
   --  field of its own.  That is Landin.Syntax.Slot's argument.
   function Operand_Count
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id) return Natural
     with Pre => Holds (Of_Unit, Item, Value);

   function Nth_Operand
     (Of_Unit : Unit;
      Item    : Item_Id;
      Value   : Value_Id;
      Index   : Positive) return Value_Id
     with Pre => Holds (Of_Unit, Item, Value)
                 and then Index <= Operand_Count (Of_Unit, Item, Value);

   function Slot_Of
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id) return Slot_Id
     with Pre => Holds (Of_Unit, Item, Value)
                 and then (Op_Of (Of_Unit, Item, Value) in Load | Store
                           or else (Op_Of (Of_Unit, Item, Value)
                                      in Load_Field | Store_Field
                                         | Load_Element | Store_Element
                                    and then Reaches_A_Slot
                                               (Of_Unit, Item, Value)));

   function Datum_Of
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id) return Item_Id
     with Pre => Holds (Of_Unit, Item, Value)
                 and then (Op_Of (Of_Unit, Item, Value)
                             in Load_Datum | Store_Datum
                           or else (Op_Of (Of_Unit, Item, Value)
                                      in Load_Field | Store_Field
                                         | Load_Element | Store_Element
                                    and then not Reaches_A_Slot
                                                   (Of_Unit, Item, Value)));

   --  Where a field or element operation reaches: [1740]'s module state,
   --  or [1810]'s local binding in a frame.  Two spellings of one
   --  question, because a field is selected the same way in the source
   --  and it is the base that differs; D22 gives a computed element the
   --  same reach.
   function Reaches_A_Slot
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id) return Boolean
     with Pre => Holds (Of_Unit, Item, Value)
                 and then Op_Of (Of_Unit, Item, Value)
                          in Load_Field | Store_Field
                             | Load_Element | Store_Element;

   function Source_Of
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id) return Storage
     with Pre => Holds (Of_Unit, Item, Value)
                 and then Op_Of (Of_Unit, Item, Value)
                          in Copy_Array | Copy_Variant | Load_Variant_Tag
                             | Load_Variant_Field;

   --  D50's containing aggregate field for the source of an array copy.
   --  Zero means the source storage is itself a fixed array; a positive
   --  value is [0750]'s declaration-order field, never a target offset.
   function Source_Field_Of
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id) return Natural
     with Pre => Holds (Of_Unit, Item, Value)
                 and then Op_Of (Of_Unit, Item, Value)
                          in Copy_Array | Copy_Variant;

   --  D90's fixed-array field inside Source_Field_Of's ordinary child.
   --  Zero keeps D20/D50's direct source path.
   function Source_Nested_Field_Of
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id) return Natural
     with Pre => Holds (Of_Unit, Item, Value)
                 and then Op_Of (Of_Unit, Item, Value) = Copy_Array;

   function Destination_Of
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id) return Storage
     with Pre => Holds (Of_Unit, Item, Value)
                 and then Op_Of (Of_Unit, Item, Value)
                          in Copy_Array | Copy_Variant
                             | Clear_Array | Fill_Array
                             | Select_Variant | Store_Variant_Field;

   --  D76's source-order case and declaration-order payload field.  D78
   --  gives scalar loads the same identities; D84 gives them to element
   --  stores, array fills and array-copy destinations, and D85 gives them to
   --  element loads.  Neither is a target offset; a selected bare case has
   --  no payload field at all.
   function Variant_Case_Of
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id) return Natural
     with Pre => Holds (Of_Unit, Item, Value)
                 and then Op_Of (Of_Unit, Item, Value)
                          in Load_Element | Store_Element
                             | Copy_Array | Fill_Array
                             | Load_Variant_Field
                             | Select_Variant | Store_Variant_Field;

   function Variant_Payload_Field_Of
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id) return Natural
     with Pre => Holds (Of_Unit, Item, Value)
                 and then Op_Of (Of_Unit, Item, Value)
                          in Load_Element | Store_Element
                             | Copy_Array | Fill_Array
                             | Load_Variant_Field | Store_Variant_Field;

   --  The one-based first destination part of a compact array fill.  Full
   --  fills carry 1; D36 suffix fills carry the first part after the prefix.
   function First_Part_Of
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id)
      return Part_Position
     with Pre => Holds (Of_Unit, Item, Value)
                 and then Op_Of (Of_Unit, Item, Value) = Fill_Array;

   --  Which part of that base, by [0750]'s order for a struct and by
   --  [0520]'s for an array.
   function Field_Of
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id)
     return Part_Position
     with Pre => Holds (Of_Unit, Item, Value)
                 and then Op_Of (Of_Unit, Item, Value)
                          in Load_Field | Store_Field;

   --  D88's scalar field, or D89/D90's fixed-array field, inside a depth-one
   --  ordinary child. Zero keeps the direct operation; a positive identity
   --  is declaration order inside the child and never a target offset.
   function Nested_Field_Of
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id) return Natural
     with Pre => Holds (Of_Unit, Item, Value)
                 and then Op_Of (Of_Unit, Item, Value)
                          in Load_Field | Store_Field
                             | Load_Element | Store_Element
                             | Copy_Array | Clear_Array | Fill_Array;

   --  D48's containing aggregate field for an element operation, D49's
   --  destination field for a clear, D50's destination field for a copy,
   --  and D53's destination field for a fill.  D84 lets that field contain
   --  the variant whose selected payload the two identities above reach.
   --  Zero ordinarily means the
   --  reached storage is itself a fixed array; for D57's Clear_Array it may
   --  instead mean the whole padded aggregate storage.  A positive value is
   --  [0750]'s declaration-order array field.  It is an identity, never a
   --  target byte offset.
   function Element_Field_Of
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id) return Natural
     with Pre => Holds (Of_Unit, Item, Value)
                 and then Op_Of (Of_Unit, Item, Value)
                          in Load_Element | Store_Element
                             | Copy_Array | Copy_Variant
                             | Clear_Array | Fill_Array
                             | Load_Variant_Tag
                             | Load_Variant_Field
                             | Select_Variant | Store_Variant_Field;

   --  D86's bounded child-shape run.  These queries sit beside the nested
   --  element accessors because their contracts validate D89's second field
   --  identity before any accessor can index it.
   function Aggregate_Field_Run_Is_Valid
     (Of_Unit : Unit; Shape : Field_Shape) return Boolean
     with Pre => Shape.Kind = Aggregate_Field_Shape;

   function Aggregate_Field_Count
     (Of_Unit : Unit; Shape : Field_Shape) return Natural
     with Pre => Shape.Kind = Aggregate_Field_Shape;

   function Nth_Aggregate_Field
     (Of_Unit : Unit; Shape : Field_Shape; Field : Positive)
      return Field_Shape
     with Pre => Shape.Kind = Aggregate_Field_Shape
                 and then Aggregate_Field_Run_Is_Valid (Of_Unit, Shape)
                 and then Field <= Aggregate_Field_Count (Of_Unit, Shape);

   --  Which array a slot-reaching element operation names.  Only
   --  meaningful when Reaches_A_Slot is true; a computed module-array
   --  element carries no slot and asks Datum_Of instead.  The reached
   --  slot must hold an Add_Array_Slot shape rather than a scalar or an
   --  aggregate: Slot_Array_Length and Slot_Array_Element have that
   --  requirement in their own preconditions, and putting it here lets
   --  the caller be caught above the raise those two would emit.
   function Slot_Element_Shape_Is_Valid
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id) return Boolean;

   function Slot_Element_Length
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id) return Element_Total
     with Pre => Slot_Element_Shape_Is_Valid (Of_Unit, Item, Value);

   function Slot_Element_Type
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id)
     return Landin.Types.Scalar_Name
     with Pre => Slot_Element_Shape_Is_Valid (Of_Unit, Item, Value);

   function Callee_Of
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id) return Item_Id
     with Pre => Holds (Of_Unit, Item, Value)
                 and then Op_Of (Of_Unit, Item, Value) = Call;

   function Target_Of
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id) return Block_Id
     with Pre => Holds (Of_Unit, Item, Value)
                 and then Op_Of (Of_Unit, Item, Value) in Jump | Branch;

   function Alternative_Of
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id) return Block_Id
     with Pre => Holds (Of_Unit, Item, Value)
                 and then Op_Of (Of_Unit, Item, Value) = Branch;

   --  [1770]'s digits and [1880]'s unary minus, kept apart because the
   --  grammar keeps them apart: `integer` spells no sign, so no signed
   --  65-bit type is ever needed.  This is Landin.Types.Fits' pair,
   --  carried rather than folded into a pattern.
   function Is_Aggregate_Measurement
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id) return Boolean
     with Pre => Holds (Of_Unit, Item, Value)
                 and then Op_Of (Of_Unit, Item, Value)
                          in Measure_Size | Measure_Align;

   --  Which scalar type [0370] is asking about.  An aggregate measurement
   --  instead carries the declaration-order field run below.
   function Measured_Of
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id)
     return Landin.Types.Scalar_Name
     with Pre => Holds (Of_Unit, Item, Value)
                 and then Op_Of (Of_Unit, Item, Value)
                          in Measure_Size | Measure_Align
                 and then not Is_Aggregate_Measurement
                                    (Of_Unit, Item, Value);

   function Measurement_Field_Count
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id) return Natural
     with Pre => Holds (Of_Unit, Item, Value)
                 and then Op_Of (Of_Unit, Item, Value)
                          in Measure_Size | Measure_Align
                 and then Is_Aggregate_Measurement
                                    (Of_Unit, Item, Value);

   function Nth_Measurement_Field
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id; Field : Positive)
      return Field_Shape
     with Pre => Holds (Of_Unit, Item, Value)
                 and then Op_Of (Of_Unit, Item, Value)
                          in Measure_Size | Measure_Align
                 and then Is_Aggregate_Measurement (Of_Unit, Item, Value)
                 and then Field
                          <= Measurement_Field_Count (Of_Unit, Item, Value);

   function Variant_Case_Run_Count (Of_Unit : Unit) return Natural;

   function Variant_Field_Shape_Count (Of_Unit : Unit) return Natural;

   function Variant_Case_Run_Is_Valid
     (Of_Unit : Unit; Shape : Field_Shape; Which : Positive)
      return Boolean
     with Pre => Shape.Kind = Variant_Field_Shape
                 and then Shape.Cases > 0
                 and then Which <= Shape.Cases
                 and then Shape.Payloads_First > 0
                 and then Shape.Payloads_First
                            <= Variant_Case_Run_Count (Of_Unit)
                 and then Shape.Cases
                            <= Variant_Case_Run_Count (Of_Unit)
                                 - Shape.Payloads_First + 1;

   function Variant_Case_Field_Count
     (Of_Unit : Unit; Shape : Field_Shape; Which : Positive)
      return Natural
     with Pre => Shape.Kind = Variant_Field_Shape
                 and then Shape.Cases > 0
                 and then Which <= Shape.Cases
                 and then Shape.Payloads_First > 0
                 and then Shape.Payloads_First
                            <= Variant_Case_Run_Count (Of_Unit)
                 and then Shape.Cases
                            <= Variant_Case_Run_Count (Of_Unit)
                                 - Shape.Payloads_First + 1;

   function Nth_Variant_Case_Field
     (Of_Unit : Unit;
      Shape   : Field_Shape;
      Which   : Positive;
      Field   : Positive) return Field_Shape
     with Pre => Shape.Kind = Variant_Field_Shape
                 and then Shape.Cases > 0
                 and then Which <= Shape.Cases
                 and then Shape.Payloads_First > 0
                 and then Shape.Payloads_First
                            <= Variant_Case_Run_Count (Of_Unit)
                 and then Shape.Cases
                            <= Variant_Case_Run_Count (Of_Unit)
                                 - Shape.Payloads_First + 1
                 and then Variant_Case_Run_Is_Valid
                   (Of_Unit, Shape, Which)
                 and then Field <= Variant_Case_Field_Count
                   (Of_Unit, Shape, Which);

   function Emit_Measurement
     (Into     : in out Unit;
      Item     : Item_Id;
      Of_Code  : Opcode;
      Measured : Landin.Types.Scalar_Name;
      Gives    : Landin.Types.Scalar_Name;
      Site     : Landin.Provenance.Origin) return Value_Id
     with Pre  => Is_Emitting (Into, Item)
                  and then Of_Code in Measure_Size | Measure_Align
                  and then Landin.Provenance.Is_Known (Site),
          Post => Emitted (Into, Item, Emit_Measurement'Result, Of_Code)
                  and then not Is_Aggregate_Measurement
                                     (Into, Item, Emit_Measurement'Result);

   function Emit_Aggregate_Measurement
     (Into    : in out Unit;
      Item    : Item_Id;
      Of_Code : Opcode;
      Fields  : Field_Shape_Array;
      Gives   : Landin.Types.Scalar_Name;
      Site    : Landin.Provenance.Origin;
      Cases   : Case_Run_Array := No_Case_Runs;
      Payloads : Field_Shape_Array := No_Field_Shapes) return Value_Id
     with Pre  => Is_Emitting (Into, Item)
                  and then Of_Code in Measure_Size | Measure_Align
                  and then Fields'Length > 0
                  and then Landin.Provenance.Is_Known (Site),
          Post => Emitted
                    (Into, Item, Emit_Aggregate_Measurement'Result, Of_Code)
                  and then Is_Aggregate_Measurement
                    (Into, Item, Emit_Aggregate_Measurement'Result)
                  and then Measurement_Field_Count
                    (Into, Item, Emit_Aggregate_Measurement'Result)
                    = Fields'Length;

   function Number_Of
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id)
     return Landin.Types.Magnitude
     with Pre => Holds (Of_Unit, Item, Value)
                 and then Op_Of (Of_Unit, Item, Value) = Number;

   function Is_Negated
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id) return Boolean
     with Pre => Holds (Of_Unit, Item, Value)
                 and then Op_Of (Of_Unit, Item, Value) = Number;

   function Truth_Of
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id) return Boolean
     with Pre => Holds (Of_Unit, Item, Value)
                 and then Op_Of (Of_Unit, Item, Value) = Truth;

   ------------------------------------------------------------------
   --  Emitting
   --
   --  One entry point per shape, so an opcode's payload is named by the
   --  call that supplies it and there is no way to leave one out.
   --
   --  The preconditions here are structural only: they refuse what would
   --  make the table say nothing -- an operand that names no instruction
   --  of this item, a slot of another item, a block that does not exist.
   --  What they deliberately do not check is whether the program is
   --  right: a type that does not agree, a call whose arity is wrong, a
   --  terminator in the middle of a block, a block nothing reaches.  Those
   --  belong to the verifier, and a precondition here would make them
   --  unbuildable and so untestable, which is the opposite of "malformed
   --  IR is rejected".  A builder contract refuses what would corrupt the
   --  table; the verifier refuses what would corrupt the program.
   ------------------------------------------------------------------

   function Emit_Number
     (Into    : in out Unit;
      Item    : Item_Id;
      Of_Type : Landin.Types.Integer_Name;
      Value   : Landin.Types.Magnitude;
      Negated : Boolean;
      Site    : Landin.Provenance.Origin) return Value_Id
     with Pre  => Is_Emitting (Into, Item)
                  and then Landin.Provenance.Is_Known (Site),
          Post => Emitted (Into, Item, Emit_Number'Result, Number);

   function Emit_Truth
     (Into  : in out Unit;
      Item  : Item_Id;
      Value : Boolean;
      Site  : Landin.Provenance.Origin) return Value_Id
     with Pre  => Is_Emitting (Into, Item)
                  and then Landin.Provenance.Is_Known (Site),
          Post => Emitted (Into, Item, Emit_Truth'Result, Truth);

   function Emit_Load
     (Into : in out Unit;
      Item : Item_Id;
      Slot : Slot_Id;
      Site : Landin.Provenance.Origin) return Value_Id
     with Pre  => Is_Emitting (Into, Item)
                  and then Holds (Into, Item, Slot)
                  and then Landin.Provenance.Is_Known (Site),
          Post => Emitted (Into, Item, Emit_Load'Result, Load);

   procedure Emit_Store
     (Into  : in out Unit;
      Item  : Item_Id;
      Slot  : Slot_Id;
      Value : Value_Id;
      Site  : Landin.Provenance.Origin)
     with Pre => Is_Emitting (Into, Item)
                 and then Holds (Into, Item, Slot)
                 and then Holds (Into, Item, Value)
                 and then Landin.Provenance.Is_Known (Site);

   function Emit_Load_Datum
     (Into  : in out Unit;
      Item  : Item_Id;
      Datum : Item_Id;
      Site  : Landin.Provenance.Origin) return Value_Id
     with Pre  => Is_Emitting (Into, Item)
                  and then Holds (Into, Datum)
                  and then Landin.Provenance.Is_Known (Site),
          Post => Emitted (Into, Item, Emit_Load_Datum'Result, Load_Datum);

   procedure Emit_Store_Datum
     (Into  : in out Unit;
      Item  : Item_Id;
      Datum : Item_Id;
      Value : Value_Id;
      Site  : Landin.Provenance.Origin)
     with Pre => Is_Emitting (Into, Item)
                 and then Holds (Into, Datum)
                 and then Holds (Into, Item, Value)
                 and then Landin.Provenance.Is_Known (Site);

   --  [0750]'s field of [0670]'s state.  The result is the field's own
   --  type, which the caller has from the same table the field run came
   --  from, and the verifier holds the two to each other.
   function Emit_Load_Field
     (Into   : in out Unit;
      Item   : Item_Id;
      Datum  : Item_Id;
      Field  : Part_Position;
      Result : Landin.Types.Scalar_Name;
      Site   : Landin.Provenance.Origin;
      Nested_Field : Natural := 0) return Value_Id
     with Pre  => Is_Emitting (Into, Item)
                  and then Holds (Into, Datum)
                  and then Landin.Provenance.Is_Known (Site),
          Post => Emitted (Into, Item, Emit_Load_Field'Result, Load_Field);

   --  The same field of a cell in this item's own frame [1810].
   function Emit_Load_Slot_Field
     (Into   : in out Unit;
      Item   : Item_Id;
      Slot   : Slot_Id;
      Field  : Part_Position;
      Result : Landin.Types.Scalar_Name;
      Site   : Landin.Provenance.Origin;
      Nested_Field : Natural := 0) return Value_Id
     with Pre  => Is_Emitting (Into, Item)
                  and then Holds (Into, Item, Slot)
                  and then Landin.Provenance.Is_Known (Site),
          Post => Emitted
                    (Into, Item, Emit_Load_Slot_Field'Result, Load_Field);

   procedure Emit_Store_Slot_Field
     (Into  : in out Unit;
      Item  : Item_Id;
      Slot  : Slot_Id;
      Field : Part_Position;
      Value : Value_Id;
      Site  : Landin.Provenance.Origin;
      Nested_Field : Natural := 0)
     with Pre => Is_Emitting (Into, Item)
                 and then Holds (Into, Item, Slot)
                 and then Holds (Into, Item, Value)
                 and then Landin.Provenance.Is_Known (Site);
   --  That the datum is an aggregate, that it has that field, and that
   --  the result is the field's own type are the verifier's, exactly as
   --  a datum load naming a routine is: a builder checks that what it is
   --  handed exists, and the rules about agreement are checked in every
   --  build mode by Landin.IR.Verifier rather than by a precondition a
   --  release build removes.

   procedure Emit_Store_Field
     (Into  : in out Unit;
      Item  : Item_Id;
      Datum : Item_Id;
      Field : Part_Position;
      Value : Value_Id;
      Site  : Landin.Provenance.Origin;
      Nested_Field : Natural := 0)
     with Pre => Is_Emitting (Into, Item)
                 and then Holds (Into, Datum)
                 and then Holds (Into, Item, Value)
                 and then Landin.Provenance.Is_Known (Site);

   --  [1950]'s runtime-selected array element.  Index is operand one; a
   --  store's value is operand two.  The verifier holds the former to
   --  `usize`, the latter and the result to the array's element type, and
   --  Datum either to an array item, D48's named aggregate field, or D89's
   --  fixed-array leaf inside one ordinary child.
   function Emit_Load_Element
     (Into   : in out Unit;
      Item   : Item_Id;
      Datum  : Item_Id;
      Index  : Value_Id;
      Result : Landin.Types.Scalar_Name;
      Site   : Landin.Provenance.Origin;
      Field  : Natural := 0;
      Nested_Field : Natural := 0;
      Variant_Case : Natural := 0;
      Variant_Payload_Field : Natural := 0) return Value_Id
     with Pre  => Is_Emitting (Into, Item)
                  and then Holds (Into, Datum)
                  and then Holds (Into, Item, Index)
                  and then Landin.Provenance.Is_Known (Site),
          Post => Emitted
                    (Into, Item, Emit_Load_Element'Result, Load_Element);

   procedure Emit_Store_Element
     (Into  : in out Unit;
      Item  : Item_Id;
      Datum : Item_Id;
      Index : Value_Id;
      Value : Value_Id;
      Site  : Landin.Provenance.Origin;
      Field : Natural := 0;
      Nested_Field : Natural := 0;
      Variant_Case : Natural := 0;
      Variant_Payload_Field : Natural := 0)
     with Pre => Is_Emitting (Into, Item)
                 and then Holds (Into, Datum)
                 and then Holds (Into, Item, Index)
                 and then Holds (Into, Item, Value)
                 and then Landin.Provenance.Is_Known (Site);

   --  The same element operations reaching a slot in this item's own frame
   --  [1810].  Field zero names an Add_Array_Slot shape; D48's positive
   --  field names a compact fixed-array leaf of an aggregate slot, and D89's
   --  Nested_Field names that leaf inside the field's ordinary child.
   function Emit_Load_Slot_Element
     (Into   : in out Unit;
      Item   : Item_Id;
      Slot   : Slot_Id;
      Index  : Value_Id;
      Result : Landin.Types.Scalar_Name;
      Site   : Landin.Provenance.Origin;
      Field  : Natural := 0;
      Nested_Field : Natural := 0;
      Variant_Case : Natural := 0;
      Variant_Payload_Field : Natural := 0) return Value_Id
     with Pre  => Is_Emitting (Into, Item)
                  and then Holds (Into, Item, Slot)
                  and then Holds (Into, Item, Index)
                  and then Landin.Provenance.Is_Known (Site),
          Post => Emitted
                    (Into, Item, Emit_Load_Slot_Element'Result,
                     Load_Element);

   procedure Emit_Store_Slot_Element
     (Into  : in out Unit;
      Item  : Item_Id;
      Slot  : Slot_Id;
      Index : Value_Id;
      Value : Value_Id;
      Site  : Landin.Provenance.Origin;
      Field : Natural := 0;
      Nested_Field : Natural := 0;
      Variant_Case : Natural := 0;
      Variant_Payload_Field : Natural := 0)
     with Pre => Is_Emitting (Into, Item)
                 and then Holds (Into, Item, Slot)
                 and then Holds (Into, Item, Index)
                 and then Holds (Into, Item, Value)
                 and then Landin.Provenance.Is_Known (Site);

   procedure Emit_Array_Copy
     (Into       : in out Unit;
      Item       : Item_Id;
      Source     : Storage;
      Destination : Storage;
      Site       : Landin.Provenance.Origin;
      Source_Field : Natural := 0;
      Source_Nested_Field : Natural := 0;
      Destination_Field : Natural := 0;
      Destination_Nested_Field : Natural := 0;
      Destination_Variant_Case : Natural := 0;
      Destination_Variant_Payload_Field : Natural := 0)
     with Pre => Is_Emitting (Into, Item)
                 and then Landin.Provenance.Is_Known (Site);

   procedure Emit_Variant_Copy
     (Into        : in out Unit;
      Item        : Item_Id;
      Source      : Storage;
      Destination : Storage;
      Field       : Positive;
      Site        : Landin.Provenance.Origin)
     with Pre => Is_Emitting (Into, Item)
                 and then Landin.Provenance.Is_Known (Site);

   procedure Emit_Array_Clear
     (Into       : in out Unit;
      Item       : Item_Id;
      Destination : Storage;
      Site       : Landin.Provenance.Origin;
      Field      : Natural := 0;
      Nested_Field : Natural := 0)
     with Pre => Is_Emitting (Into, Item)
                 and then Landin.Provenance.Is_Known (Site);

   procedure Emit_Array_Fill
     (Into       : in out Unit;
      Item       : Item_Id;
      Destination : Storage;
      First       : Part_Position;
      Value       : Value_Id;
      Site        : Landin.Provenance.Origin;
      Field       : Natural := 0;
      Nested_Field : Natural := 0;
      Variant_Case : Natural := 0;
      Variant_Payload_Field : Natural := 0)
     with Pre => Is_Emitting (Into, Item)
                 and then Holds (Into, Item, Value)
                 and then Landin.Provenance.Is_Known (Site);

   procedure Emit_Variant_Select
     (Into       : in out Unit;
      Item       : Item_Id;
      Destination : Storage;
      Field      : Positive;
      Which      : Positive;
      Site       : Landin.Provenance.Origin)
     with Pre => Is_Emitting (Into, Item)
                 and then Landin.Provenance.Is_Known (Site);

   function Emit_Variant_Tag_Load
     (Into   : in out Unit;
      Item   : Item_Id;
      Source : Storage;
      Field  : Positive;
      Result : Landin.Types.Scalar_Name;
      Site   : Landin.Provenance.Origin) return Value_Id
     with Pre => Is_Emitting (Into, Item)
                 and then Landin.Provenance.Is_Known (Site),
          Post => Holds (Into, Item, Emit_Variant_Tag_Load'Result);

   function Emit_Variant_Field_Load
     (Into         : in out Unit;
      Item         : Item_Id;
      Source       : Storage;
      Field        : Positive;
      Which        : Positive;
      Payload_Field : Positive;
      Result       : Landin.Types.Scalar_Name;
      Site         : Landin.Provenance.Origin) return Value_Id
     with Pre => Is_Emitting (Into, Item)
                 and then Landin.Provenance.Is_Known (Site),
          Post => Holds (Into, Item, Emit_Variant_Field_Load'Result);

   procedure Emit_Variant_Field_Store
     (Into         : in out Unit;
      Item         : Item_Id;
      Destination  : Storage;
      Field        : Positive;
      Which        : Positive;
      Payload_Field : Positive;
      Value        : Value_Id;
      Site         : Landin.Provenance.Origin)
     with Pre => Is_Emitting (Into, Item)
                 and then Holds (Into, Item, Value)
                 and then Landin.Provenance.Is_Known (Site);

   --  Result is stated by the caller and not derived from the operand,
   --  so a mutation can make it disagree and the verifier can say so.
   function Emit_Unary
     (Into    : in out Unit;
      Item    : Item_Id;
      Op      : Unary_Kind;
      Operand : Value_Id;
      Result  : Landin.Types.Scalar_Name;
      Site    : Landin.Provenance.Origin) return Value_Id
     with Pre  => Is_Emitting (Into, Item)
                  and then Holds (Into, Item, Operand)
                  and then Landin.Provenance.Is_Known (Site),
          Post => Emitted (Into, Item, Emit_Unary'Result, Op);

   function Emit_Binary
     (Into   : in out Unit;
      Item   : Item_Id;
      Op     : Binary_Kind;
      Left   : Value_Id;
      Right  : Value_Id;
      Result : Landin.Types.Scalar_Name;
      Site   : Landin.Provenance.Origin) return Value_Id
     with Pre  => Is_Emitting (Into, Item)
                  and then Holds (Into, Item, Left)
                  and then Holds (Into, Item, Right)
                  and then Landin.Provenance.Is_Known (Site),
          Post => Emitted (Into, Item, Emit_Binary'Result, Op);

   --  A call with no arguments yet.  [0410] evaluates arguments left to
   --  right, and every instruction that computes one is already above
   --  this one in the block, so the run below is only the order [1920]
   --  names the parameters in.
   function Emit_Call
     (Into   : in out Unit;
      Item   : Item_Id;
      Callee : Item_Id;
      Result : Landin.Types.Type_Kind;
      Site   : Landin.Provenance.Origin) return Value_Id
     with Pre  => Is_Emitting (Into, Item)
                  and then Holds (Into, Callee)
                  and then (Result in Landin.Types.Scalar_Name
                            or else Result = Landin.Types.No_Value)
                  and then Landin.Provenance.Is_Known (Site),
          Post => Emitted (Into, Item, Emit_Call'Result, Call)
                  and then Operand_Count (Into, Item, Emit_Call'Result) = 0;

   procedure Add_Argument
     (Into  : in out Unit;
      Item  : Item_Id;
      Call  : Value_Id;
      Value : Value_Id)
     with Pre  => Holds (Into, Item, Call)
                  and then Op_Of (Into, Item, Call) = Landin.IR.Call
                  and then Holds (Into, Item, Value)
                  and then Call = Value_Id (Value_Count (Into, Item)),
          Post => Operand_Count (Into, Item, Call)
                    = Operand_Count (Into, Item, Call)'Old + 1;

   procedure Emit_Jump
     (Into   : in out Unit;
      Item   : Item_Id;
      Target : Block_Id;
      Site   : Landin.Provenance.Origin)
     with Pre => Is_Emitting (Into, Item)
                 and then Holds (Into, Item, Target)
                 and then Landin.Provenance.Is_Known (Site);

   procedure Emit_Branch
     (Into        : in out Unit;
      Item        : Item_Id;
      Condition   : Value_Id;
      Target      : Block_Id;
      Alternative : Block_Id;
      Site        : Landin.Provenance.Origin)
     with Pre => Is_Emitting (Into, Item)
                 and then Holds (Into, Item, Condition)
                 and then Holds (Into, Item, Target)
                 and then Holds (Into, Item, Alternative)
                 and then Landin.Provenance.Is_Known (Site);

   --  [1810]'s `return`, and a datum's value.  No_Value is `-> none`.
   procedure Emit_Leave
     (Into  : in out Unit;
      Item  : Item_Id;
      Value : Value_Id;
      Site  : Landin.Provenance.Origin)
     with Pre => Is_Emitting (Into, Item)
                 and then (Value = No_Value
                           or else Holds (Into, Item, Value))
                 and then Landin.Provenance.Is_Known (Site);

   --  A block of this item is open, which is the only state an Emit is
   --  allowed in: an instruction that belongs to no block is an
   --  instruction nothing can reach and nothing can print.
   function Is_Emitting (Of_Unit : Unit; Item : Item_Id) return Boolean
     is (Holds (Of_Unit, Item)
         and then Open_Block (Of_Unit, Item) /= No_Block);

   --  What every Emit that defines a value promises: the value is the
   --  next one, it carries the opcode asked for, and it is the last
   --  instruction of the block that was open.
   function Emitted
     (Of_Unit : Unit;
      Item    : Item_Id;
      Value   : Value_Id;
      Op      : Opcode) return Boolean
     is (Holds (Of_Unit, Item, Value)
         and then Value = Value_Id (Value_Count (Of_Unit, Item))
         and then Op_Of (Of_Unit, Item, Value) = Op
         and then Block_Of (Of_Unit, Item, Value)
                  = Open_Block (Of_Unit, Item))
     with Pre => Holds (Of_Unit, Item);

private

   --  The payload fields are the union of what any one opcode needs,
   --  which is Landin.Syntax.Node's decision and for its reason: a
   --  variant part would make the element type indefinite and would fix
   --  an instruction's shape when it is created.
   type Instruction is record
      Op          : Opcode                    := Jump;
      Result      : Landin.Types.Type_Kind    := Landin.Types.Not_Typed;
      Site        : Landin.Provenance.Origin  :=
                      Landin.Provenance.No_Origin;
      In_Block    : Block_Id                  := No_Block;
      First_Arg   : Natural                   := 0;
      Args        : Natural                   := 0;
      Slot        : Slot_Id                   := No_Slot;
      Named       : Item_Id                   := No_Item;
      Source      : Storage                   := (others => <>);
      Source_Field : Natural                  := 0;
      Source_Nested_Part : Natural             := 0;
      Destination : Storage                   := (others => <>);
      Target      : Block_Id                  := No_Block;
      Alternative : Block_Id                  := No_Block;
      Number      : Landin.Types.Magnitude    := 0;
      Part        : Part_Position              := 1;
      Nested_Part : Natural                    := 0;
      Element_Field : Natural                  := 0;
      Variant_Case  : Natural                  := 0;
      Variant_Payload_Field : Natural           := 0;
      Measured    : Landin.Types.Scalar_Name  := Landin.Types.Bool;
      First_Measurement_Field : Natural        := 0;
      Measurement_Field_Total : Natural        := 0;
      Aggregate_Measurement : Boolean          := False;
      Negated     : Boolean                   := False;
      Truth       : Boolean                   := False;
   end record;

   --  One run per item, end to end in one vector, which is what
   --  Landin.Syntax does with a node's children and Landin.Resolution
   --  and Landin.Checking with a node's meaning and its type.  First is
   --  where entry 1 of that item sits, so a reference is one addition.
   type Run is record
      First : Natural := 0;
      Count : Natural := 0;
   end record;

   type Slot_Record is record
      Of_Type     : Landin.Types.Scalar_Name  := Landin.Types.Bool;
      --  True when the cell holds [0670]'s aggregate, whose fields are a
      --  run of their own; Of_Type says nothing then.
      Aggregate   : Boolean                   := False;
      Array_Shape : Boolean                   := False;
      Fields      : Run;
      Element     : Landin.Types.Scalar_Name  := Landin.Types.Bool;
      Length      : Element_Total             := 0;
      Declaration : Declaration_Id            := No_Declaration;
      Site        : Landin.Provenance.Origin  :=
                      Landin.Provenance.No_Origin;
   end record;

   type Block_Record is record
      Scope       : Scope_Id                  :=
                      Landin.Resolution.No_Scope;
      Site        : Landin.Provenance.Origin  :=
                      Landin.Provenance.No_Origin;
      First_Value : Natural                   := 0;
      Values      : Natural                   := 0;
   end record;

   type Item_Record is record
      Kind        : Item_Kind                 := Datum;
      Declaration : Declaration_Id            := No_Declaration;
      Result      : Landin.Types.Type_Kind    := Landin.Types.Not_Typed;
      Site        : Landin.Provenance.Origin  :=
                      Landin.Provenance.No_Origin;
      Slots       : Run;
      Parameters  : Run;
      Returns_To  : Slot_Id                   := No_Slot;
      Blocks      : Run;
      Values      : Run;
      Fields      : Run;
      --  [0520]'s shape, when Result says the item is an array.
      Element     : Landin.Types.Scalar_Name  := Landin.Types.Bool;
      Length      : Element_Total             := 0;
      --  D24's source-order static image is one Folded value per position.
      --  D34 instead stores one value and marks it repeated; neither an
      --  absent zero image nor a repetition allocates a target-sized run.
      Image       : Run;
      Aggregate_Images : Run;
      Has_Image   : Boolean                   := False;
      Repeated_Image : Boolean                := False;
      Open        : Block_Id                  := No_Block;
   end record;

   package Item_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Item_Record);

   package Slot_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Slot_Record);

   package Block_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Block_Record);

   package Code_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Instruction);

   package Slot_Ref_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Slot_Id);

   package Value_Ref_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Value_Id);

   package Item_Ref_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Item_Id);

   package Field_Shape_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Field_Shape);

   package Case_Run_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Case_Run);

   package Image_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Landin.Types.Folded,
      "="          => Landin.Types."=");

   package Aggregate_Field_Image_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Aggregate_Field_Image);

   type Unit is tagged limited record
      Ready      : Boolean := False;
      Items      : Item_Vectors.Vector;
      Slots      : Slot_Vectors.Vector;
      Parameters : Slot_Ref_Vectors.Vector;
      Blocks     : Block_Vectors.Vector;
      Code       : Code_Vectors.Vector;
      Operands   : Value_Ref_Vectors.Vector;
      Fields     : Field_Shape_Vectors.Vector;
      Slot_Fields : Field_Shape_Vectors.Vector;
      Measurement_Fields : Field_Shape_Vectors.Vector;
      Variant_Fields : Field_Shape_Vectors.Vector;
      Variant_Cases : Case_Run_Vectors.Vector;
      Standing    : Item_Ref_Vectors.Vector;
      --  D24: one folded scalar per array-datum position, laid end to end
      --  across items so a datum with no image contributes no bytes here.
      Images      : Image_Vectors.Vector;
      Aggregate_Images : Aggregate_Field_Image_Vectors.Vector;
   end record;

end Landin.IR;
