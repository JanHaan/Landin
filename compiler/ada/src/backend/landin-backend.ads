--  What a routine's frame holds, and where.
--
--  `tour.md` [1550] says the frame pointer is always set up, and
--  `Landin.IR`'s header says a slot "has no address, no offset and no
--  size" because "where it lives is the backend's frame question".  This
--  is
--  that answer, and it is deliberately target-neutral: an offset here is
--  a count of target bytes and nothing below asks the host how wide a
--  thing is.  Which register the frame pointer is, and how a store to
--  one of these offsets is spelt, is a child's.
--
--  The reference layout gives every scalar value a separate cell.  The
--  allocation-driven overload instead consumes explicit storage needs:
--  pinned slots, reusable spill homes and callee-save homes.  Register
--  identities and the proof that two values can reuse storage belong to
--  the target child; this parent validates capacities and places bytes.
--  Neither representation expands a compact array into per-element cells.
--
--  Offsets grow downward and are reported as positive distances *below*
--  the frame pointer, because that is how every caller has to spell one
--  and a signed offset would make each of them negate it again.  A cell
--  is placed at the first distance that is at least its own size and a
--  multiple of its alignment, which is what makes the address it names
--  aligned rather than merely the count that reaches it.
--
--  bool is one byte here.  [0150] says a one-bit field outside a packed
--  struct "occupies the next machine width", and the next machine width
--  above one bit is a byte.  The target's data layout owns layout in
--  general and has more to say about a bool inside an aggregate; a frame
--  cell is not an aggregate, and a frame cannot be laid out without an
--  answer.

private with Ada.Containers.Indefinite_Hashed_Maps;
private with Ada.Containers.Vectors;
private with Ada.Strings.Hash;

with Landin.IR;
with Landin.IR.Shape_Measurement;
with Landin.Targets;
with Landin.Layouts;
with Landin.Resolution;
with Landin.Source.Names;
with Landin.Targets.Assembly;
with Landin.Targets.Layouts;
with Landin.Types;

package Landin.Backend is

   type Frame is private;

   --  Expected exhaustion of a frame or C argument stack budget. Invalid
   --  shapes, homes and alignments remain compiler defects.
   Stack_Limit_Exceeded : exception;

   --  Slots first, in slot order, then values, in value order.  Both are
   --  functions of the lowering order alone, so the same source yields
   --  the same frame on any host -- the property `Landin.IR` argues for
   --  its own numbering, kept here rather than re-earned.
   function Laid_Out
     (Of_Unit : Landin.IR.Unit;
      Item    : Landin.IR.Item_Id;
      Facts   : Landin.Targets.Target_Facts;
      Maximum : Landin.Targets.Byte_Count :=
        Landin.Targets.Byte_Count'Last) return Frame
     with Pre => Landin.IR.Holds (Of_Unit, Item);

   --  The same reference frame with Saves eight-byte homes after it, for
   --  callee-saved registers a routine saves itself.
   function Laid_Out
     (Of_Unit : Landin.IR.Unit;
      Item    : Landin.IR.Item_Id;
      Facts   : Landin.Targets.Target_Facts;
      Maximum : Landin.Targets.Byte_Count;
      Saves   : Positive) return Frame
     with Pre => Landin.IR.Holds (Of_Unit, Item);

   --  Indexes are source slot/value positions, starting at one.  False
   --  slots and zero value assignments reserve no storage.  Positive value
   --  assignments select an explicit spill home; disjoint live intervals
   --  may name the same home.  Homes and saves are placed in supplied order
   --  after pinned slots, with alignment checked against the target stack.
   type Home_Mask is array (Positive range <>) of Boolean;
   type Spill_Assignments is array (Positive range <>) of Natural;

   function Laid_Out
     (Of_Unit : Landin.IR.Unit;
      Item    : Landin.IR.Item_Id;
      Facts   : Landin.Targets.Target_Facts;
      Slots   : Home_Mask;
      Values  : Spill_Assignments;
      Spills  : Landin.Targets.Layouts.Field_Extent_Array;
      Saves   : Landin.Targets.Layouts.Field_Extent_Array;
      Maximum : Landin.Targets.Byte_Count :=
        Landin.Targets.Byte_Count'Last) return Frame;

   function Has_Slot_Home
     (Of_Frame : Frame; Slot : Landin.IR.Slot_Id) return Boolean;
   function Has_Value_Home
     (Of_Frame : Frame; Value : Landin.IR.Value_Id) return Boolean;
   function Spill_Offset
     (Of_Frame : Frame; Home : Positive) return Landin.Targets.Byte_Count;
   function Save_Offset
     (Of_Frame : Frame; Home : Positive) return Landin.Targets.Byte_Count;

   --  Sum of requested home extents, excluding inter-home/final padding.
   function Spill_Bytes (Of_Frame : Frame) return Landin.Targets.Byte_Count;
   function Spill_Count (Of_Frame : Frame) return Natural;
   function Save_Bytes (Of_Frame : Frame) return Landin.Targets.Byte_Count;

   --  What the prologue subtracts: the whole extent, rounded up to the
   --  target's stack alignment so the frame leaves the stack as aligned
   --  as it found it.
   function Extent (Of_Frame : Frame) return Landin.Targets.Byte_Count;

   --  Adjacent direct and erased evidence identities can name one physical
   --  table when the represented shape and provider words are identical.
   function Shares_Evidence_Table
     (Of_Unit : Landin.IR.Unit;
      Direct, Erased : Landin.IR.Evidence_Id) return Boolean
     with Pre => Landin.IR.Holds (Of_Unit, Direct)
                 and then Landin.IR.Holds (Of_Unit, Erased);

   --  D374: which evidence-table entries an emitted table names.  Entry N
   --  of a table is kept when code that can run projects entry N from a
   --  table of the same family (Landin.IR.Evidence_Family), direct and
   --  erased families apart, since a projection's table at runtime may be
   --  any table of its concept.  A routine that can run is a root or one
   --  that a routine that can run calls, takes the address of, names in
   --  an `assembler.block`'s text, or names in a kept entry.  A root has
   --  a reference no call makes: an image, an exposure, an import or
   --  export, a link name, a placement, a non-ordinary convention or the
   --  C ABI; or it has no parameters, as a firmware entry has; or it is
   --  Handler, the panic handler the backend calls.  A routine only
   --  another routine calls is no root, so one that only a left-out
   --  entry's target calls cannot run and projects nothing.  A block
   --  names a routine when the routine's name or link name, either one
   --  also with a leading `_`, is a run of symbol characters in its text,
   --  the words D296 roots; its operands are integers and name nothing.
   --  Meanings and Names spell both.  A table without a family keeps
   --  every entry.  An entry left out is a zero word in its place, so a
   --  table's layout never changes, and the routine it named is linked
   --  only if something else reaches it.  The two identities of one
   --  physical table (see Shares_Evidence_Table) answer alike.  Every
   --  target asks this, so every target links the same routines.
   type Kept_Entries is private;

   function Kept_Evidence_Entries
     (Of_Unit  : Landin.IR.Unit;
      Handler  : Landin.IR.Item_Id;
      Meanings : Landin.Resolution.Table;
      Names    : Landin.Source.Names.Table) return Kept_Entries;

   function Is_Kept
     (Of_Kept : Kept_Entries;
      Id      : Landin.IR.Evidence_Id;
      Which   : Positive) return Boolean;

   function Slot_Offset
     (Of_Frame : Frame; Slot : Landin.IR.Slot_Id)
     return Landin.Targets.Byte_Count;

   --  Where one field of an aggregate slot sits, as a distance below the
   --  frame pointer like any other cell.  A cell grows downward while
   --  aggregate fields grow upward from its base.  Subtract the selected
   --  source field's physical offset from the cell's downward distance;
   --  an explicit optimal layout may place that field out of source order.
   function Field_Offset
     (Of_Unit  : Landin.IR.Unit;
      Item     : Landin.IR.Item_Id;
      Of_Frame : Frame;
      Slot     : Landin.IR.Slot_Id;
      Field    : Landin.IR.Part_Position;
      Facts    : Landin.Targets.Target_Facts)
     return Landin.Targets.Byte_Count
     with Pre => Landin.IR.Holds (Of_Unit, Item)
                 and then Landin.IR.Holds (Of_Unit, Item, Slot)
                 and then (Landin.IR.Is_Aggregate (Of_Unit, Item, Slot)
                           or else Landin.IR.Is_Array
                                     (Of_Unit, Item, Slot))
                 and then Landin.IR."<="
                            (Landin.IR.Element_Total (Field),
                             Landin.IR.Slot_Part_Count
                               (Of_Unit, Item, Slot));

   --  How much room an aggregate slot takes, and how it must be aligned:
   --  [0750]'s whole placement over the slot's own field run.
   procedure Aggregate_Extent
     (Of_Unit   : Landin.IR.Unit;
      Item      : Landin.IR.Item_Id;
      Slot      : Landin.IR.Slot_Id;
      Facts     : Landin.Targets.Target_Facts;
      Size      : out Landin.Targets.Byte_Count;
      Alignment : out Landin.Targets.Byte_Alignment)
     with Pre => Landin.IR.Holds (Of_Unit, Item)
                 and then Landin.IR.Holds (Of_Unit, Item, Slot)
                 and then (Landin.IR.Is_Aggregate (Of_Unit, Item, Slot)
                           or else Landin.IR.Is_Array
                                     (Of_Unit, Item, Slot));

   --  Shared physical placement for all consumers, including datum image
   --  replay.  Order contains source field positions in physical order;
   --  Offsets is indexed by source position.  Nested fields apply their own
   --  policy, and variants retain their tag-first/source-order payloads.
   function Fields_Layout
     (Of_Unit : Landin.IR.Unit;
      Fields  : Landin.IR.Field_Shape_Array;
      Policy  : Landin.Layouts.Policy;
      Facts   : Landin.Targets.Target_Facts)
      return Landin.Targets.Layouts.Plan;

   function Aggregate_Layout
     (Of_Unit : Landin.IR.Unit;
      Shape   : Landin.IR.Field_Shape;
      Facts   : Landin.Targets.Target_Facts)
      return Landin.Targets.Layouts.Plan;

   --  The common physical interpretation of an immutable subobject path.
   --  Machine addresses and off-target debug locations use the same walk.
   --  Reuse aggregate plans across paths in one immutable unit and target.
   --  Keep Cache local to an emission of that unit/target.
   function Path_Offset
     (Of_Unit : Landin.IR.Unit;
      Shape : Landin.IR.Field_Shape;
      Path : Landin.IR.Path_Step_Array;
      Facts : Landin.Targets.Target_Facts;
      Cache : in out Landin.IR.Shape_Measurement.Layout_Cache)
      return Landin.Targets.Byte_Count;

   function Nominal_Layout
     (Of_Unit : Landin.IR.Unit;
      Nominal : Landin.IR.Nominal_Type_Id;
      Facts   : Landin.Targets.Target_Facts)
      return Landin.Targets.Layouts.Plan;

   function Slot_Layout
     (Of_Unit : Landin.IR.Unit;
      Item    : Landin.IR.Item_Id;
      Slot    : Landin.IR.Slot_Id;
      Facts   : Landin.Targets.Target_Facts)
      return Landin.Targets.Layouts.Plan;

   function Datum_Layout
     (Of_Unit : Landin.IR.Unit;
      Item    : Landin.IR.Item_Id;
      Facts   : Landin.Targets.Target_Facts)
      return Landin.Targets.Layouts.Plan;

   function Measurement_Layout
     (Of_Unit : Landin.IR.Unit;
      Item    : Landin.IR.Item_Id;
      Value   : Landin.IR.Value_Id;
      Facts   : Landin.Targets.Target_Facts)
      return Landin.Targets.Layouts.Plan;

   --  The target extent of one neutral field shape.  D86 recursively replays
   --  a measurement-only aggregate run; runtime datum and slot runs retain
   --  the scalar, fixed-array and unfolded-variant shapes.
   procedure Field_Extent
     (Of_Unit   : Landin.IR.Unit;
      Shape     : Landin.IR.Field_Shape;
      Facts     : Landin.Targets.Target_Facts;
      Size      : out Landin.Targets.Byte_Count;
      Alignment : out Landin.Targets.Byte_Alignment);

   --  Selecting a case zeroes only its own payload.  The returned offset
   --  includes the tag-to-payload gap; Size is zero for a bare case.
   procedure Variant_Selected_Payload_Extent
     (Of_Unit : Landin.IR.Unit;
      Shape   : Landin.IR.Field_Shape;
      Which   : Positive;
      Facts   : Landin.Targets.Target_Facts;
      Offset  : out Landin.Targets.Byte_Count;
      Size    : out Landin.Targets.Byte_Count)
     with Pre => Landin.IR."="
                   (Shape.Kind, Landin.IR.Variant_Field_Shape)
                 and then Which <= Shape.Cases
                 and then Landin.IR.Variant_Case_Run_Is_Valid
                   (Of_Unit, Shape, Which);

   --  D76's scalar payload write reaches one field inside one selected
   --  case.  The offset is relative to the start of the variant part and
   --  is replayed from the same tag-first/max-payload rule as Field_Extent;
   --  no target byte offset enters Landin.IR.
   function Variant_Payload_Field_Offset
     (Of_Unit       : Landin.IR.Unit;
      Shape         : Landin.IR.Field_Shape;
      Which         : Positive;
      Payload_Field : Positive;
      Facts         : Landin.Targets.Target_Facts)
      return Landin.Targets.Byte_Count
     with Pre => Landin.IR."="
                   (Shape.Kind, Landin.IR.Variant_Field_Shape)
                 and then Which <= Shape.Cases
                 and then Landin.IR.Variant_Case_Run_Is_Valid
                   (Of_Unit, Shape, Which)
                 and then Payload_Field <=
                   Landin.IR.Variant_Case_Field_Count
                     (Of_Unit, Shape, Which);

   --  Routine and datum emission reuse this query for every selected field.
   function Variant_Payload_Field_Offset
     (Of_Unit       : Landin.IR.Unit;
      Shape         : Landin.IR.Field_Shape;
      Which         : Positive;
      Payload_Field : Positive;
      Facts         : Landin.Targets.Target_Facts;
      Cache         : in out Landin.IR.Shape_Measurement.Layout_Cache)
      return Landin.Targets.Byte_Count
     with Pre => Landin.IR."="
                   (Shape.Kind, Landin.IR.Variant_Field_Shape)
                 and then Which <= Shape.Cases
                 and then Landin.IR.Variant_Case_Run_Is_Valid
                   (Of_Unit, Shape, Which)
                 and then Payload_Field <=
                   Landin.IR.Variant_Case_Field_Count
                     (Of_Unit, Shape, Which);

   --  Answer one target-neutral measurement instruction.  Aggregate
   --  measurements carry declaration-order scalar or compact fixed-array
   --  fields and D74/D75's shared variant case runs; this
   --  target-owning seam derives their padded placement with Landin.Targets.
   --  D411: a Measure_Offset answers its offset as Size, alignment one.
   procedure Measurement_Extent
     (Of_Unit   : Landin.IR.Unit;
      Item      : Landin.IR.Item_Id;
      Value     : Landin.IR.Value_Id;
      Facts     : Landin.Targets.Target_Facts;
      Size      : out Landin.Targets.Byte_Count;
      Alignment : out Landin.Targets.Byte_Alignment)
     with Pre => Landin.IR.Holds (Of_Unit, Item, Value)
                 and then Landin.IR.Op_Of (Of_Unit, Item, Value)
                          in Landin.IR.Measurement_Kind;

   --  The number one measurement instruction stands for on this target:
   --  a size, an alignment, or D411's byte offset of a field path, which
   --  is the run's placement of the path's first field plus the offsets
   --  the rest of the path replays inside it.
   function Measurement_Answer
     (Of_Unit : Landin.IR.Unit;
      Item    : Landin.IR.Item_Id;
      Value   : Landin.IR.Value_Id;
      Facts   : Landin.Targets.Target_Facts)
      return Landin.Targets.Byte_Count
     with Pre => Landin.IR.Holds (Of_Unit, Item, Value)
                 and then Landin.IR.Op_Of (Of_Unit, Item, Value)
                          in Landin.IR.Measurement_Kind;

   function Value_Offset
     (Of_Frame : Frame; Value : Landin.IR.Value_Id)
     return Landin.Targets.Byte_Count;

   --  What a backend needs to fold an indexed address into the one
   --  indirect access that uses it.  Uses counts the operands naming each
   --  value; References counts the instructions naming each slot, and
   --  [1630]'s text, which may name any, counts twice against every one.
   type Use_Counts is array (Positive range <>) of Natural;

   procedure Count_Uses
     (Of_Unit : Landin.IR.Unit;
      Item : Landin.IR.Item_Id;
      Uses : out Use_Counts;
      References : out Use_Counts)
     with Pre => Uses'First = 1
                 and then Uses'Last = Landin.IR.Value_Count (Of_Unit, Item)
                 and then References'First = 1
                 and then References'Last
                   = Landin.IR.Slot_Count (Of_Unit, Item);

   --  The Load_Indirect or Store_Indirect an address reaches as its one
   --  use, either as the very next instruction or through the address
   --  slot lowering carries it in as the access's type witness: the next
   --  instruction stores it there, the one after loads it back, and the
   --  access follows, when the slot is an undeclared temporary that no
   --  other instruction names.  Store and Load are that pair, which then
   --  moves nothing a folded access needs.  Access is No_Value when the
   --  address has to be formed.
   type Address_Fold is record
      Access_Value : Landin.IR.Value_Id := Landin.IR.No_Value;
      Store, Load : Landin.IR.Value_Id := Landin.IR.No_Value;
   end record;

   function Fold_Of
     (Of_Unit : Landin.IR.Unit;
      Item : Landin.IR.Item_Id;
      Block : Landin.IR.Block_Id;
      Position : Positive;
      Uses : Use_Counts;
      References : Use_Counts) return Address_Fold
     with Pre => Position <= Landin.IR.Length (Of_Unit, Item, Block);

   --  The same pair seen from its store at Position, whatever else uses
   --  the address stored: the access may then read through the stored
   --  address where it lives rather than a copy in the slot.
   function Carried
     (Of_Unit : Landin.IR.Unit;
      Item : Landin.IR.Item_Id;
      Block : Landin.IR.Block_Id;
      Position : Positive;
      Uses : Use_Counts;
      References : Use_Counts) return Address_Fold
     with Pre => Position <= Landin.IR.Length (Of_Unit, Item, Block);

   --  How much room one of [1790]'s scalars needs.  Not a width: a width
   --  is bits and comes from Landin.Types, and bool has none.
   function Size_Of
     (Item : Landin.Types.Scalar_Name;
      Facts : Landin.Targets.Target_Facts)
     return Landin.Targets.Scalar_Size;

   --  An atom's code: its rank among the declarations some atom set of the
   --  unit names, in declaration-identity order, counting from one so that
   --  zero stays the successful half of a failing call's carrier.  Every
   --  backend and the panic plan spell an atom this way; ranking once per
   --  unit keeps a use from walking every set of the program again.
   type Atom_Codes is private;

   function Ranked (Of_Unit : Landin.IR.Unit) return Atom_Codes;

   function Atom_Code
     (Of_Codes : Atom_Codes; Identity : Landin.IR.Declaration_Id)
      return Positive;

   --  An atom set's codes as runs of consecutive codes, ascending.  A set
   --  declared together, as an errno set of a hundred and fifty atoms is,
   --  is one run, so a membership check tests each run's two bounds rather
   --  than comparing with every atom.
   type Code_Run is record
      Low, High : Positive;
   end record;

   type Code_Runs is array (Positive range <>) of Code_Run;

   function Runs_Of
     (Of_Unit  : Landin.IR.Unit;
      Of_Codes : Atom_Codes;
      Set      : Landin.IR.Atom_Set_Id) return Code_Runs;

   --  How many of a unit's items hold each linker spelling.  Symbol
   --  allocation asks whether a candidate is held by any item but the one
   --  choosing; counting spellings answers that without walking every
   --  item for every candidate.  The empty spelling counts like any other.
   type Spelling_Counts is private;

   procedure Add (Into : in out Spelling_Counts; Spelling : String);

   procedure Remove (Into : in out Spelling_Counts; Spelling : String)
     with Pre => Count (Into, Spelling) > 0;

   function Count
     (Of_Counts : Spelling_Counts; Spelling : String) return Natural;

   --  D415: whether Item is a global symbol.  `public` alone is not an
   --  export.  Global are the hosted or firmware entry, an import, an item
   --  with a link symbol -- an explicit `link(symbol: ...)`, or the
   --  spelling the checker notes for a public C definition -- a public
   --  definition in a machine convention, platform/linux's naked
   --  `_landin_start` among them, and a Cortex-M placement.  Every other
   --  routine and datum is a local symbol under its own name, so no C
   --  library or linked object can collide with it.
   function Is_Exported
     (Of_Unit        : Landin.IR.Unit;
      Meanings       : Landin.Resolution.Table;
      Item           : Landin.IR.Item_Id;
      Hosted_Entry   : Landin.IR.Item_Id;
      Firmware_Entry : Landin.IR.Item_Id := Landin.IR.No_Item)
      return Boolean;

   --  D417: the symbol an item takes when another item of the program
   --  holds its own spelling.  Its module's logical path with every `/`
   --  a `.`, or `main` for the entry module, then `.` and the spelling:
   --  `core.arena.reset`.  An identifier holds no `.`, so only an explicit
   --  link name can hold this too; then, as for a second instance of one
   --  generic routine, the caller appends `.1`, `.2` and so on.
   function Qualified_Symbol
     (Meanings : Landin.Resolution.Table;
      Declared : Landin.IR.Declaration_Id;
      Spelling : String) return String;

   --  The declaration an item's symbol is spelled from: its own, or, for a
   --  generic routine's instance, which declares nothing of its own, the
   --  generic routine it was made from.  An instance is therefore a local
   --  symbol named after its routine, as a profiler and `nm` show it, and
   --  a second instance of one routine is qualified as D417 says.  An
   --  evidence provider binding an instance's evidence is named after the
   --  same routine (Landin.IR.Named_After).  No declaration only for an
   --  anonymous function.
   function Symbol_Declaration
     (Of_Unit : Landin.IR.Unit;
      Item    : Landin.IR.Item_Id) return Landin.IR.Declaration_Id;

   --  [1630]: one block's operands with every `general` register chosen,
   --  each at the width its type selects.  Every backend emits the same
   --  choice, so the text a target assembles is a function of the IR and
   --  the target alone.
   function Assembly_Registers
     (Of_Unit : Landin.IR.Unit;
      Item    : Landin.IR.Item_Id;
      Value   : Landin.IR.Value_Id;
      Names   : Landin.Source.Names.Table;
      Facts   : Landin.Targets.Target_Facts)
      return Landin.Targets.Assembly.Operand_Register_Array;

   --  The block's text as the target's assembler reads it, one element
   --  per line, with every `{name}` filled.
   function Assembly_Text
     (Of_Unit : Landin.IR.Unit;
      Item    : Landin.IR.Item_Id;
      Value   : Landin.IR.Value_Id;
      Names   : Landin.Source.Names.Table;
      Facts   : Landin.Targets.Target_Facts) return String;

private

   package Spelling_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type => String, Element_Type => Positive,
      Hash => Ada.Strings.Hash, Equivalent_Keys => "=");

   type Spelling_Counts is record
      Held : Spelling_Maps.Map;
   end record;

   --  Module data with an all-zero image are laid out smallest first,
   --  ties in item order.  Every hosted backend reaches a datum through a
   --  bounded PC-relative distance, and an object as large as that reach
   --  admits would otherwise push every datum after it out of reach: the
   --  platform/linux roots a static Linux link adds after the program's own
   --  among them.  Extents (N) is Items (N)'s target extent.
   type Item_Array is array (Positive range <>) of Landin.IR.Item_Id;
   type Extent_Array is
     array (Positive range <>) of Landin.Targets.Byte_Count;

   function Smallest_First
     (Items : Item_Array; Extents : Extent_Array) return Item_Array
   with Pre => Items'First = 1 and then Extents'First = 1
     and then Items'Length = Extents'Length;

   --  Shared checked stack arithmetic. The limit is never exceeded even
   --  transiently; invalid alignment is not a budget failure.
   function Stack_Add
     (Left, Right, Maximum : Landin.Targets.Byte_Count)
      return Landin.Targets.Byte_Count;
   function Stack_Align
     (Offset : Landin.Targets.Byte_Count;
      Alignment : Landin.Targets.Byte_Alignment;
      Maximum : Landin.Targets.Byte_Count) return Landin.Targets.Byte_Count;

   --  D471: a program that prepares a stack checks, in the prologue of
   --  every ordinary routine it has, the stack pointer less the frame
   --  against one cell holding the current stack's limit.  Whether the
   --  unit holds a `compiler.stack_prepare`: no other program pays for a
   --  check or a cell.
   function Prepares_Stacks (Of_Unit : Landin.IR.Unit) return Boolean;

   --  D471: whether Item's body makes no call of any kind: no direct or
   --  indirect call, no stack builtin and no assembly, whose text may
   --  call.  A trap's call of the handler is not counted; the margin
   --  pays for it.
   function Call_Free
     (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id) return Boolean;

   --  D471 and D472: what the limit `compiler.stack_prepare` lays keeps
   --  above a prepared stack's lowest byte, and the largest frame of a
   --  call-free routine, or call area, that is not checked, on Facts'
   --  backend.  Zero for a target without a native backend.
   function Stack_Limit_Margin
     (Facts : Landin.Targets.Target_Facts) return Landin.Targets.Byte_Count;
   function Unchecked_Stack_Bytes
     (Facts : Landin.Targets.Target_Facts) return Landin.Targets.Byte_Count;

   --  D472's worst before a selected handler's own frames, which the
   --  margin pays first: two unchecked figures, the frame record a callee
   --  pushes before its check and the call of the handler, and on
   --  Cortex-M0 D461's exception frame.  What the margin leaves after it
   --  is what a handler and its calls may take (D474).  Zero for a target
   --  without a native backend.
   function Handler_Entry_Bytes
     (Facts : Landin.Targets.Target_Facts) return Landin.Targets.Byte_Count;

   package Offset_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Landin.Targets.Byte_Count,
      "="          => Landin.Targets."=");

   package Home_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Boolean);

   package Code_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Natural);

   --  Indexed by declaration identity; zero for one no set names.
   type Atom_Codes is record
      Codes : Code_Vectors.Vector;
   end record;

   --  First (T) is how many entries the tables before T hold; Kept is
   --  indexed by that count plus the entry's position.
   type Kept_Entries is record
      First : Code_Vectors.Vector;
      Kept  : Home_Vectors.Vector;
   end record;

   type Frame is record
      Slots         : Offset_Vectors.Vector;
      --  One-based start of a placed aggregate slot's source offsets;
      --  zero for a scalar, array or slot without a home.
      Slot_Fields   : Code_Vectors.Vector;
      Field_Offsets : Offset_Vectors.Vector;
      Values        : Offset_Vectors.Vector;
      Slot_Homes    : Home_Vectors.Vector;
      Spills        : Offset_Vectors.Vector;
      Saves         : Offset_Vectors.Vector;
      Spill_Total   : Landin.Targets.Byte_Count := 0;
      Save_Total    : Landin.Targets.Byte_Count := 0;
      Size          : Landin.Targets.Byte_Count := 0;
   end record;

end Landin.Backend;
