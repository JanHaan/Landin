--  What a well-formed Unit is, checked before anything lowers from it.
--
--  It reports no diagnostic and raises `Landin.Compiler_Defect`, and the
--  band `L0400`-`L0499` stays unassigned for the argument the catalogue's
--  header now records: malformed IR cannot be caused by a source program,
--  because the frontend refuses every ill-formed one and
--  `Landin.Stages.Lowering` refuses to run on a program that was refused.
--  A code here would be a promise that some program can provoke it, and
--  `landin.ads` forbids exactly that promise.
--
--  Which makes the rule list load-bearing in an unusual way: a rule that
--  is wrong is a compiler that crashes on a legal program rather than a
--  test that goes red.  So a rule is here only when a paragraph or this
--  package's own header states it, and two kinds of rule are deliberately
--  absent.
--
--  Absent because the table's shape already forbids it.  A Value_Id *is*
--  the position of the instruction that defines it, so "every value has
--  exactly one definition" cannot be violated and cannot be tested; a
--  Load's result type is derived in the body from its slot, never stated
--  by a caller; a terminator's result is the record's default.  Checking
--  those would be writing tests that cannot fail.
--
--  Absent because it belongs to somebody else.  Whether a `Number` fits
--  its type needs a width, and a width belongs to `Landin.Targets`.
--  Whether a `Scope_Id` names a real scope is R1.50's answer and asking
--  it again here would be the second authority `Landin.IR`'s header
--  refuses.  Whether a name is assigned before it is read is [1910]'s and
--  the checker's.
--
--  A child of `Landin.IR` because two rules need the private part: an
--  item's four runs, and a call's operand run, have to partition their
--  vectors, and no public function can see a run.  Those two are also the
--  ones that must run first -- a run whose base is wrong makes
--  `Nth_Value` raise `Constraint_Error` before any later rule can speak.
--
--  D24's array datum image is one exception to the "width belongs to the
--  target" rule above: a per-position folded value is a concrete number
--  the backend will store into the object at a target-derived width, so
--  the verifier holds each one to fitting its own element type against
--  the compilation's target facts.  A malformed image whose 300 an u8 is
--  asked to hold, or whose 2**32 a 32-bit `usize` cannot address, is IR
--  the backend has no defined answer for and must be refused before it
--  is asked one.  Facts arrive on the entry points that need them; the
--  historical no-facts entries stay for callers whose IR carries no
--  images at all.

with Landin.Targets;

package Landin.IR.Verifier is

   type Fault_Kind is
     (Nothing_Wrong,
      --  The unit, and the runs that partition its vectors.
      Unprepared_Unit,
      Item_Runs_Overlap,
      Operand_Runs_Overlap,
      --  An item.
      Item_Without_A_Block,
      Item_Still_Building,
      --  A block [1550].
      Empty_Block,
      Block_Without_A_Terminator,
      Terminator_Inside_A_Block,
      Block_Unreachable,
      Target_Out_Of_Range,
      --  An instruction and its operands.
      Wrong_Operand_Count,
      Operand_Out_Of_Range,
      Operand_In_Another_Block,
      Operand_Not_Above_Its_Use,
      Operand_Defines_Nothing,
      Operands_Disagree,
      Result_Disagrees,
      Field_Shape_Malformed,
      Condition_Is_Not_A_Bool,
      --  Places [1900] and module values [1940].
      Slot_Out_Of_Range,
      Store_Disagrees_With_Slot,
      Store_To_A_Parameter,
      Named_Item_Is_Not_A_Datum,
      Store_Datum_Disagrees,
      Aggregate_Datum_Is_Not_A_Value,
      Field_Out_Of_Range,
      Field_Is_Not_A_Scalar,
      Element_Datum_Is_Not_An_Array,
      Element_Field_Out_Of_Range,
      Element_Field_Is_Not_An_Array,
      Element_Index_Is_Not_Usize,
      Array_Storage_Is_Not_An_Array,
      Array_Copy_Shapes_Disagree,
      Array_Copy_Inside_A_Datum,
      Array_Clear_Inside_A_Datum,
      Array_Fill_Inside_A_Datum,
      Array_Fill_Value_Disagrees,
      Array_Fill_First_Out_Of_Range,
      Array_Image_Length_Disagrees,
      Array_Image_Value_Does_Not_Fit,
      --  Calls [1920].
      Callee_Is_Not_A_Routine,
      Call_Inside_A_Datum,
      --  Leaving.
      Leave_Disagrees_With_Item);

   --  Where it went wrong, in as much detail as the rule has.  A field
   --  that the rule does not speak about is left at its no-value.
   type Fault is record
      Kind  : Fault_Kind := Nothing_Wrong;
      Item  : Item_Id    := No_Item;
      Block : Block_Id   := No_Block;
      Value : Value_Id   := No_Value;
   end record;

   Sound : constant Fault := (others => <>);

   --  The first fault, or Sound.  A value rather than an exception, so a
   --  case can assert the whole record instead of matching a message.
   function Check (Of_Unit : Unit) return Fault;

   --  The same walk with per-image value verification, which needs a
   --  target width to decide whether a Folded value fits its element
   --  type.  A caller with an image to check has target facts and passes
   --  them; a caller with none may use the no-facts entry above and skip
   --  the D24 rule.
   function Check
     (Of_Unit : Unit;
      Facts   : Landin.Targets.Target_Facts) return Fault;

   --  The same walk, raising on the first fault.  In every build mode:
   --  the builder's preconditions are gone under release, and
   --  `Landin.Targets` already learnt what that costs when a release
   --  build accepted an alignment of twelve that only a precondition had
   --  refused.
   procedure Verify (Of_Unit : Unit);

   procedure Verify
     (Of_Unit : Unit;
      Facts   : Landin.Targets.Target_Facts);

   --  For a message and for a test that wants to say which rule it meant.
   function Describe (Of_Kind : Fault_Kind) return String;

end Landin.IR.Verifier;
