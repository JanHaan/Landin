--  What Landin.IR promises about where an item's entities live.
--
--  Every case here builds a Unit by hand, because nothing in the compiler
--  calls Landin.IR yet: R1.70 landed the representation and the lowering
--  is still to come, so a defect in it can only be found by a test that
--  drives the builder directly.  Two were, and both corrupted a Unit
--  silently in a release build.
--
--  The frontend is run for one reason only: Prepare needs a resolution
--  table and Add_Item needs a Declaration_Id that table holds.  The
--  sources are strings in memory and no host effect is asked for, which is
--  what keeps this case inside the rule that every stage case runs against
--  a fake filesystem.

with Ada.Strings.Fixed;

with Landin.IR;
with Landin.IR.Dump;
with Landin.IR.Verifier;
with Landin.Provenance;
with Landin.Resolution;
with Landin.Source;
with Landin.Stages.Checking;
with Landin.Stages.Resolution;
with Landin.Stages.Syntax;
with Landin.Targets;
with Landin.Types;

package body Landin.Tests.IR_Suite is

   use type Landin.IR.Element_Total;
   use type Landin.IR.Field_Image_Form;
   use type Landin.IR.Item_Id;
   use type Landin.IR.Opcode;
   use type Landin.IR.Part_Position;
   use type Landin.IR.Slot_Id;
   use type Landin.IR.Storage_Kind;
   use type Landin.IR.Value_Id;
   use type Landin.IR.Verifier.Fault_Kind;
   use type Landin.Types.Folded;
   use type Landin.Types.Type_Kind;

   --  Library-level, because Landin.Stages.Stage_Reference is a
   --  library-level access type and a stage may not be a local of one
   --  compilation.
   Frontend : aliased Landin.Stages.Syntax.Instance;
   Names    : aliased Landin.Stages.Resolution.Instance;
   Checker  : aliased Landin.Stages.Checking.Instance;

   LF : constant Character := Character'Val (10);

   --  Two functions, so the resolution table holds enough declarations for
   --  two items.
   Program : constant String :=
     "f: () -> (r: u32) = r = 1 end f" & LF
     & "g: () -> (r: u32) = r = 2 end g" & LF;

   procedure Frontend_Over
     (Work : in out Landin.Stages.Compilation;
      Site : out Landin.Provenance.Origin);

   procedure Frontend_Over
     (Work : in out Landin.Stages.Compilation;
      Site : out Landin.Provenance.Origin)
   is
      Order   : Landin.Stages.Pipeline;
      Ran     : Natural;
      Written : constant Landin.Source.Source_Id :=
        Landin.Stages.Add_Source (Work, "ir.ldn", Program);
   begin
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);
      pragma Assert (Ran = 3);
      Site := (Source => Written, Where => Landin.Source.Empty_Span);
   end Frontend_Over;

   ------------------------------------------------------------------
   --  A run's base belongs to the item that opened it
   ------------------------------------------------------------------

   --  [1740] makes a module a set, so `f` may call `g` written below it,
   --  and Emit_Call's `Holds (Into, Callee)` therefore forces a lowering
   --  to create every item before it fills any.  Add_Item used to take
   --  each run's base at creation, so every item got the same one and the
   --  second item's slots read back as the first's.
   procedure Items_Do_Not_Share_A_Run
     (Item : in out Landin.Testing.Context);

   procedure Items_Do_Not_Share_A_Run
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Site : Landin.Provenance.Origin;
   begin
      Frontend_Over (Work, Site);

      declare
         Meanings : constant not null access Landin.Resolution.Table :=
           Landin.Stages.Meanings (Work);
         Unit   : Landin.IR.Unit;
         A, B   : Landin.IR.Item_Id;
         S1, S2 : Landin.IR.Slot_Id;
      begin
         Landin.IR.Prepare (Unit, Meanings.all);

         A := Landin.IR.Add_Item
                (Unit, Landin.IR.Routine, 1, Landin.Types.U32, Site);
         B := Landin.IR.Add_Item
                (Unit, Landin.IR.Routine, 2, Landin.Types.U32, Site);

         S1 := Landin.IR.Add_Slot
                 (Unit, A, Landin.Types.U32, 1, Site);
         S2 := Landin.IR.Add_Slot
                 (Unit, B, Landin.Types.Bool, 2, Site);

         Landin.Testing.Check
           (Item, Landin.IR.Type_Of (Unit, A, S1) = Landin.Types.U32,
            "the first item's slot keeps the type it was given");
         Landin.Testing.Check
           (Item, Landin.IR.Type_Of (Unit, B, S2) = Landin.Types.Bool,
            "the second item's slot is its own and not the first's");
         Landin.Testing.Check_Equal
           (Item, Landin.IR.Slot_Count (Unit, A), 1,
            "the first item has one slot");
         Landin.Testing.Check_Equal
           (Item, Landin.IR.Slot_Count (Unit, B), 1,
            "the second item has one slot");
      end;
   end Items_Do_Not_Share_A_Run;

   ------------------------------------------------------------------
   --  A block reports its own instructions
   ------------------------------------------------------------------

   --  Landin.IR's header says blocks are created out of fill order -- "an
   --  `if`'s else-entry is created before the then-arm's inner blocks and
   --  filled after them".  Add_Block used to take the block's first value
   --  at creation, so every block but the first reported the instructions
   --  of whichever block was filled first.
   procedure A_Block_Reports_Its_Own_Instructions
     (Item : in out Landin.Testing.Context);

   procedure A_Block_Reports_Its_Own_Instructions
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Site : Landin.Provenance.Origin;
   begin
      Frontend_Over (Work, Site);

      declare
         Meanings : constant not null access Landin.Resolution.Table :=
           Landin.Stages.Meanings (Work);
         Unit       : Landin.IR.Unit;
         A          : Landin.IR.Item_Id;
         B1, B2, B3 : Landin.IR.Block_Id;
         V1, V2, V3 : Landin.IR.Value_Id;
         Scope      : constant Landin.IR.Scope_Id :=
           Landin.Resolution.Program_Scope;
      begin
         Landin.IR.Prepare (Unit, Meanings.all);
         A := Landin.IR.Add_Item
                (Unit, Landin.IR.Routine, 1, Landin.Types.U32, Site);

         --  All three before any is filled, which is the order an `if`
         --  produces them in.
         B1 := Landin.IR.Add_Block (Unit, A, Scope, Site);
         B2 := Landin.IR.Add_Block (Unit, A, Scope, Site);
         B3 := Landin.IR.Add_Block (Unit, A, Scope, Site);

         Landin.IR.Enter (Unit, A, B1);
         V1 := Landin.IR.Emit_Truth (Unit, A, True, Site);
         V2 := Landin.IR.Emit_Truth (Unit, A, False, Site);
         Landin.IR.Emit_Jump (Unit, A, B2, Site);
         Landin.IR.Leave_Block (Unit, A);

         Landin.IR.Enter (Unit, A, B2);
         V3 := Landin.IR.Emit_Truth (Unit, A, True, Site);
         Landin.IR.Emit_Jump (Unit, A, B3, Site);
         Landin.IR.Leave_Block (Unit, A);

         --  A value is its own position, so these are 1, 2 and 4 and the
         --  jump between them is 3.
         Landin.Testing.Check
           (Item,
            Natural (V1) = 1 and then Natural (V2) = 2
            and then Natural (V3) = 4,
            "a value's identity is the position of its instruction");

         Landin.Testing.Check_Equal
           (Item, Landin.IR.Value_Count (Unit, A), 5,
            "five instructions were emitted");
         Landin.Testing.Check_Equal
           (Item, Landin.IR.Length (Unit, A, B1), 3,
            "the first block holds the three it was given");
         Landin.Testing.Check_Equal
           (Item, Natural (Landin.IR.Nth_Value (Unit, A, B1, 1)), 1,
            "the first block starts at the first instruction");
         Landin.Testing.Check_Equal
           (Item, Landin.IR.Length (Unit, A, B2), 2,
            "the second block holds the two it was given");
         Landin.Testing.Check_Equal
           (Item, Natural (Landin.IR.Nth_Value (Unit, A, B2, 1)), 4,
            "the second block starts after the first, not at its own"
            & " creation point");
      end;
   end A_Block_Reports_Its_Own_Instructions;

   ------------------------------------------------------------------
   --  Two items filled at once are refused
   ------------------------------------------------------------------

   --  A Run is a base and a count, so an item's entities have to be
   --  contiguous.  Going back to an item after starting another would
   --  interleave two runs and leave both wrong, and no precondition says
   --  so, which is why the body says it in every mode.
   procedure Interleaved_Fill_Is_Refused
     (Item : in out Landin.Testing.Context);

   procedure Interleaved_Fill_Is_Refused
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Site : Landin.Provenance.Origin;
   begin
      Frontend_Over (Work, Site);

      declare
         Meanings : constant not null access Landin.Resolution.Table :=
           Landin.Stages.Meanings (Work);
         Unit    : Landin.IR.Unit;
         A, B    : Landin.IR.Item_Id;
         Ignored : Landin.IR.Slot_Id;
      begin
         Landin.IR.Prepare (Unit, Meanings.all);
         A := Landin.IR.Add_Item
                (Unit, Landin.IR.Routine, 1, Landin.Types.U32, Site);
         B := Landin.IR.Add_Item
                (Unit, Landin.IR.Routine, 2, Landin.Types.U32, Site);

         Ignored := Landin.IR.Add_Slot
                      (Unit, A, Landin.Types.U32, 1, Site);
         Ignored := Landin.IR.Add_Slot
                      (Unit, B, Landin.Types.U32, 2, Site);

         --  Back to A, whose run is no longer at the end.
         Ignored := Landin.IR.Add_Slot
                      (Unit, A, Landin.Types.U32, 3, Site);

         Landin.Testing.Fail
           (Item, "going back to an item should have been refused");
         pragma Assert (Ignored /= Landin.IR.No_Slot);
      exception
         when Landin.Compiler_Defect =>
            Landin.Testing.Check
              (Item, True, "two items filled at once are refused");
      end;
   end Interleaved_Fill_Is_Refused;

   --  An aggregate slot's fields are a run of the same kind, so going
   --  back to one after another has started is refused the same way.
   --  Without this, a slot's recorded run would take in the next slot's
   --  field and leave its own last one orphaned, and the layout and every
   --  access would then read the wrong type at the wrong offset.
   procedure Interleaved_Slot_Fields_Are_Refused
     (Item : in out Landin.Testing.Context);

   procedure Interleaved_Slot_Fields_Are_Refused
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Site : Landin.Provenance.Origin;
   begin
      Frontend_Over (Work, Site);

      declare
         Meanings : constant not null access Landin.Resolution.Table :=
           Landin.Stages.Meanings (Work);
         Unit : Landin.IR.Unit;
         A    : Landin.IR.Item_Id;
         P, Q : Landin.IR.Slot_Id;
      begin
         Landin.IR.Prepare (Unit, Meanings.all);
         A := Landin.IR.Add_Item
                (Unit, Landin.IR.Routine, 1, Landin.Types.U32, Site);

         P := Landin.IR.Add_Aggregate_Slot (Unit, A, 1, Site);
         Q := Landin.IR.Add_Aggregate_Slot (Unit, A, 2, Site);

         Landin.IR.Add_Slot_Field (Unit, A, P, Landin.Types.U32);
         Landin.IR.Add_Slot_Field (Unit, A, Q, Landin.Types.Bool);

         --  Back to P, whose field run is no longer at the end.
         Landin.IR.Add_Slot_Field (Unit, A, P, Landin.Types.U32);

         Landin.Testing.Fail
           (Item, "going back to a slot should have been refused");
      exception
         when Landin.Compiler_Defect =>
            Landin.Testing.Check
              (Item, True, "two slots filled at once are refused");
      end;
   end Interleaved_Slot_Fields_Are_Refused;

   ------------------------------------------------------------------
   --  A call's arguments are its own
   ------------------------------------------------------------------

   --  The operand vector is the fifth run and the one Open_Run did not
   --  reach when it was written.  Every other instruction records its
   --  operands in the same call that creates them, so those runs cannot
   --  interleave; a call's arguments arrive afterwards, and Enter asks
   --  only that *this* item has no open block -- so another item can be
   --  filled in between.  Before Add_Argument opened its own run, the
   --  call below was handed one value and read back the other item's, in
   --  debug and in release, with every precondition satisfied.
   procedure A_Call_Reads_Its_Own_Arguments
     (Item : in out Landin.Testing.Context);

   procedure A_Call_Reads_Its_Own_Arguments
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Site : Landin.Provenance.Origin;
   begin
      Frontend_Over (Work, Site);

      declare
         Meanings : constant not null access Landin.Resolution.Table :=
           Landin.Stages.Meanings (Work);
         Unit   : Landin.IR.Unit;
         A, B   : Landin.IR.Item_Id;
         Ba, Bb : Landin.IR.Block_Id;
         Ignored, Wanted, Made, X, Y, Sum : Landin.IR.Value_Id;
         Scope  : constant Landin.IR.Scope_Id :=
           Landin.Resolution.Program_Scope;
      begin
         Landin.IR.Prepare (Unit, Meanings.all);
         A := Landin.IR.Add_Item
                (Unit, Landin.IR.Routine, 1, Landin.Types.U32, Site);
         B := Landin.IR.Add_Item
                (Unit, Landin.IR.Routine, 3, Landin.Types.U32, Site);
         Ba := Landin.IR.Add_Block (Unit, A, Scope, Site);
         Bb := Landin.IR.Add_Block (Unit, B, Scope, Site);

         Landin.IR.Enter (Unit, A, Ba);
         Ignored := Landin.IR.Emit_Number
                      (Unit, A, Landin.Types.U32, 7, False, Site);
         Wanted := Landin.IR.Emit_Number
                     (Unit, A, Landin.Types.U32, 8, False, Site);
         Made := Landin.IR.Emit_Call
                   (Unit, A, B, Landin.Types.U32, Site);

         --  A second item, open at the same time, putting its own
         --  operands on the vector between the call and its argument.
         Landin.IR.Enter (Unit, B, Bb);
         X := Landin.IR.Emit_Number
                (Unit, B, Landin.Types.U32, 100, False, Site);
         Y := Landin.IR.Emit_Number
                (Unit, B, Landin.Types.U32, 200, False, Site);
         Sum := Landin.IR.Emit_Binary
                  (Unit, B, Landin.IR.Add, X, Y, Landin.Types.U32, Site);

         Landin.IR.Add_Argument (Unit, A, Made, Wanted);

         Landin.Testing.Check_Equal
           (Item, Landin.IR.Operand_Count (Unit, A, Made), 1,
            "the call carries the one argument it was given");
         Landin.Testing.Check
           (Item,
            Landin.IR.Nth_Operand (Unit, A, Made, 1) = Wanted,
            "the call reads its own argument and not the other item's");
         Landin.Testing.Check
           (Item, Ignored /= Wanted and then Sum /= Landin.IR.No_Value,
            "the two items really did both emit");
      end;
   end A_Call_Reads_Its_Own_Arguments;

   ------------------------------------------------------------------
   --  A runtime element carries its index before its stored value
   ------------------------------------------------------------------

   procedure An_Element_Carries_Its_Operands
     (Item : in out Landin.Testing.Context);

   procedure An_Element_Carries_Its_Operands
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Site : Landin.Provenance.Origin;
   begin
      Frontend_Over (Work, Site);

      declare
         Meanings : constant not null access Landin.Resolution.Table :=
           Landin.Stages.Meanings (Work);
         Unit : Landin.IR.Unit;
         Datum, Routine : Landin.IR.Item_Id;
         Block : Landin.IR.Block_Id;
         Index, Stored, Loaded, Store : Landin.IR.Value_Id;
      begin
         Landin.IR.Prepare (Unit, Meanings.all);
         Datum := Landin.IR.Add_Item
                    (Unit, Landin.IR.Datum, 1,
                     Landin.Types.Aggregate, Site);
         Landin.IR.Add_Field (Unit, Datum, Landin.Types.U8);
         Landin.IR.Add_Field
           (Unit, Datum,
            (Kind    => Landin.IR.Array_Field_Shape,
             Element => Landin.Types.U32,
             Length  => 4,
             others  => <>));
         Routine := Landin.IR.Add_Item
                      (Unit, Landin.IR.Routine, 2, Landin.Types.U32, Site);
         Block := Landin.IR.Add_Block
                    (Unit, Routine, Landin.Resolution.Program_Scope, Site);
         Landin.IR.Enter (Unit, Routine, Block);
         Index := Landin.IR.Emit_Number
                    (Unit, Routine, Landin.Types.Usize, 2, False, Site);
         Stored := Landin.IR.Emit_Number
                     (Unit, Routine, Landin.Types.U32, 9, False, Site);
         Loaded := Landin.IR.Emit_Load_Element
                     (Unit, Routine, Datum, Index, Landin.Types.U32, Site,
                      Field => 2);
         Landin.IR.Emit_Store_Element
           (Unit, Routine, Datum, Index, Stored, Site, Field => 2);
         Store := Landin.IR.Nth_Value (Unit, Routine, Block, 4);

         Landin.Testing.Check
           (Item,
            Landin.IR.Op_Of (Unit, Routine, Loaded)
              = Landin.IR.Load_Element
            and then Landin.IR.Datum_Of (Unit, Routine, Loaded) = Datum
            and then Landin.IR.Element_Field_Of (Unit, Routine, Loaded) = 2
            and then Landin.IR.Operand_Count (Unit, Routine, Loaded) = 1
            and then Landin.IR.Nth_Operand (Unit, Routine, Loaded, 1) = Index,
            "a load carries its array and runtime index");
         Landin.Testing.Check
           (Item,
            Landin.IR.Op_Of (Unit, Routine, Store)
              = Landin.IR.Store_Element
            and then Landin.IR.Datum_Of (Unit, Routine, Store) = Datum
            and then Landin.IR.Element_Field_Of (Unit, Routine, Store) = 2
            and then Landin.IR.Operand_Count (Unit, Routine, Store) = 2
            and then Landin.IR.Nth_Operand (Unit, Routine, Store, 1) = Index
            and then Landin.IR.Nth_Operand (Unit, Routine, Store, 2) = Stored,
            "a store carries its index before the value");
      end;
   end An_Element_Carries_Its_Operands;

   procedure An_Array_Slot_Has_A_Compact_Shape
     (Item : in out Landin.Testing.Context);

   procedure An_Array_Slot_Has_A_Compact_Shape
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Site : Landin.Provenance.Origin;
   begin
      Frontend_Over (Work, Site);
      declare
         Unit : Landin.IR.Unit;
         Routine : Landin.IR.Item_Id;
         Slot : Landin.IR.Slot_Id;
      begin
         Landin.IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
         Routine := Landin.IR.Add_Item
           (Unit, Landin.IR.Routine, 1, Landin.Types.U32, Site);
         Slot := Landin.IR.Add_Array_Slot
           (Unit, Routine, Landin.Types.U16, 2 ** 32 - 1, 2, Site);

         Landin.Testing.Check
           (Item, Landin.IR.Is_Array (Unit, Routine, Slot),
            "the slot records an array shape");
         Landin.Testing.Check
           (Item,
            Landin.IR.Slot_Array_Length (Unit, Routine, Slot) = 2 ** 32 - 1
            and then Landin.IR.Slot_Part_Count (Unit, Routine, Slot)
                       = 2 ** 32 - 1,
            "the target-width length is kept without a field run");
         Landin.Testing.Check
           (Item,
            Landin.IR.Nth_Slot_Part
              (Unit, Routine, Slot, 2 ** 32 - 1) = Landin.Types.U16,
            "the last part derives its type from the compact element");
         Landin.Testing.Check_Equal
           (Item, Landin.IR.Slot_Field_Count (Unit, Routine, Slot), 0,
            "an array slot allocates no per-element field entries");
      end;
   end An_Array_Slot_Has_A_Compact_Shape;

   procedure An_Array_Copy_Carries_Two_Compact_Places
     (Item : in out Landin.Testing.Context);

   procedure An_Array_Copy_Carries_Two_Compact_Places
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Site : Landin.Provenance.Origin;
   begin
      Frontend_Over (Work, Site);
      declare
         Unit    : Landin.IR.Unit;
         Datum   : Landin.IR.Item_Id;
         Routine : Landin.IR.Item_Id;
         Slot    : Landin.IR.Slot_Id;
         Block   : Landin.IR.Block_Id;
         Copy       : Landin.IR.Value_Id;
         Clear      : Landin.IR.Value_Id;
         Fill_Value : Landin.IR.Value_Id;
         Fill       : Landin.IR.Value_Id;
      begin
         Landin.IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
         Datum := Landin.IR.Add_Item
           (Unit, Landin.IR.Datum, 1, Landin.Types.Fixed_Array, Site);
         Landin.IR.Set_Array
           (Unit, Datum, Landin.Types.U16, 2 ** 32 - 1);
         Routine := Landin.IR.Add_Item
           (Unit, Landin.IR.Routine, 2, Landin.Types.U32, Site);
         Slot := Landin.IR.Add_Array_Slot
           (Unit, Routine, Landin.Types.U16, 2 ** 32 - 1,
            Landin.IR.No_Declaration, Site);
         Block := Landin.IR.Add_Block
           (Unit, Routine, Landin.Resolution.Program_Scope, Site);
         Landin.IR.Enter (Unit, Routine, Block);
         Landin.IR.Emit_Array_Copy
           (Unit, Routine,
            (Kind => Landin.IR.Module_Datum, Datum => Datum),
            (Kind => Landin.IR.Frame_Slot, Slot => Slot), Site,
            Source_Field => 5, Destination_Field => 6);
         Copy := Landin.IR.Nth_Value (Unit, Routine, Block, 1);
         --  This seam pins transport only; the verifier owns whether field 7
         --  exists and has an array shape in a particular destination.
         Landin.IR.Emit_Array_Clear
           (Unit, Routine,
            (Kind => Landin.IR.Frame_Slot, Slot => Slot), Site,
            Field => 7);
         Clear := Landin.IR.Nth_Value (Unit, Routine, Block, 2);
         Fill_Value := Landin.IR.Emit_Number
           (Unit, Routine, Landin.Types.U16, 7, False, Site);
         Landin.IR.Emit_Array_Fill
           (Unit, Routine,
            (Kind => Landin.IR.Frame_Slot, Slot => Slot), 3, Fill_Value, Site,
            Field => 8);
         Fill := Landin.IR.Nth_Value (Unit, Routine, Block, 4);

         Landin.Testing.Check
           (Item,
            Landin.IR.Op_Of (Unit, Routine, Copy) = Landin.IR.Copy_Array
            and then Landin.IR.Defines_Nothing (Landin.IR.Copy_Array)
            and then Landin.IR.Result_Of (Unit, Routine, Copy)
                       = Landin.Types.Not_Typed,
            "a whole-array copy is one instruction defining no value");
         Landin.Testing.Check
           (Item,
            Landin.IR.Source_Of (Unit, Routine, Copy).Kind
              = Landin.IR.Module_Datum
            and then Landin.IR.Source_Of (Unit, Routine, Copy).Datum = Datum
            and then Landin.IR.Source_Field_Of
                       (Unit, Routine, Copy) = 5
            and then Landin.IR.Destination_Of (Unit, Routine, Copy).Kind
              = Landin.IR.Frame_Slot
            and then Landin.IR.Destination_Of
                       (Unit, Routine, Copy).Slot = Slot
            and then Landin.IR.Element_Field_Of
                       (Unit, Routine, Copy) = 6,
            "its endpoints retain storage and field identities");
         Landin.Testing.Check_Equal
           (Item, Landin.IR.Operand_Count (Unit, Routine, Copy), 0,
            "its metadata does not grow with the array length");
         Landin.Testing.Check
           (Item,
            Landin.IR.Op_Of (Unit, Routine, Clear) = Landin.IR.Clear_Array
            and then Landin.IR.Defines_Nothing (Landin.IR.Clear_Array)
            and then Landin.IR.Result_Of (Unit, Routine, Clear)
                       = Landin.Types.Not_Typed
            and then Landin.IR.Destination_Of
                       (Unit, Routine, Clear).Kind = Landin.IR.Frame_Slot
            and then Landin.IR.Destination_Of
                       (Unit, Routine, Clear).Slot = Slot
            and then Landin.IR.Element_Field_Of
                       (Unit, Routine, Clear) = 7,
            "an array clear carries its compact destination and field");
         Landin.Testing.Check_Equal
           (Item, Landin.IR.Operand_Count (Unit, Routine, Clear), 0,
            "clear metadata also stays constant at the target-width length");
         Landin.Testing.Check
           (Item,
            Landin.IR.Op_Of (Unit, Routine, Fill) = Landin.IR.Fill_Array
            and then Landin.IR.Defines_Nothing (Landin.IR.Fill_Array)
            and then Landin.IR.Result_Of (Unit, Routine, Fill)
                       = Landin.Types.Not_Typed
            and then Landin.IR.Destination_Of
                       (Unit, Routine, Fill).Kind = Landin.IR.Frame_Slot
            and then Landin.IR.Destination_Of
                       (Unit, Routine, Fill).Slot = Slot
            and then Landin.IR.Element_Field_Of
                       (Unit, Routine, Fill) = 8
            and then Landin.IR.First_Part_Of (Unit, Routine, Fill) = 3,
            "an array fill carries a compact destination, field and start");
         Landin.Testing.Check
           (Item,
            Landin.IR.Operand_Count (Unit, Routine, Fill) = 1
            and then Landin.IR.Nth_Operand (Unit, Routine, Fill, 1)
                       = Fill_Value,
            "fill carries one scalar rather than one value per element");

         declare
            Text : constant String := Landin.IR.Dump.Text
              (Unit, Landin.Stages.Meanings (Work).all,
               Landin.Stages.Identities (Work).all);
         begin
            Landin.Testing.Check
              (Item,
               Ada.Strings.Fixed.Index
                 (Text, "COPY_ARRAY from datum 1 f field 5 to slot 1"
                        & " field 6") /= 0,
               "the dump names both storage and field endpoints");
            Landin.Testing.Check
              (Item,
               Ada.Strings.Fixed.Index
                 (Text, "CLEAR_ARRAY destination slot 1") /= 0,
               "the dump names the clear destination");
            Landin.Testing.Check
              (Item,
               Ada.Strings.Fixed.Index
                 (Text,
                  "FILL_ARRAY destination slot 1 field 8 first 3 <- 3") /= 0,
               "the dump names the fill destination, first part and operand");
         end;
      end;
   end An_Array_Copy_Carries_Two_Compact_Places;

   procedure Variant_Operations_Carry_Compact_Identities
     (Item : in out Landin.Testing.Context);

   procedure Variant_Operations_Carry_Compact_Identities
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Site : Landin.Provenance.Origin;
   begin
      Frontend_Over (Work, Site);
      declare
         Unit : Landin.IR.Unit;
         Routine : Landin.IR.Item_Id;
         Slot : Landin.IR.Slot_Id;
         Block : Landin.IR.Block_Id;
         Value, Loaded, Selected, Store : Landin.IR.Value_Id;
      begin
         Landin.IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
         Routine := Landin.IR.Add_Item
           (Unit, Landin.IR.Routine, 1, Landin.Types.U32, Site);
         Slot := Landin.IR.Add_Aggregate_Slot
           (Unit, Routine, Landin.IR.No_Declaration, Site);
         Landin.IR.Add_Slot_Field
           (Unit, Routine, Slot,
            (Kind           => Landin.IR.Variant_Field_Shape,
             Element        => Landin.Types.U8,
             Length         => 1,
             Cases          => 2,
             Payloads_First => 1),
            Cases => [(First => 0, Count => 0),
                      (First => 1, Count => 1)],
            Payloads =>
              [(Kind    => Landin.IR.Scalar_Field_Shape,
                Element => Landin.Types.U16,
                Length  => 1,
                others  => <>)]);
         Block := Landin.IR.Add_Block
           (Unit, Routine, Landin.Resolution.Program_Scope, Site);
         Landin.IR.Enter (Unit, Routine, Block);
         Loaded := Landin.IR.Emit_Variant_Tag_Load
           (Unit, Routine, (Kind => Landin.IR.Frame_Slot, Slot => Slot),
            1, Landin.Types.U8, Site);
         Landin.IR.Emit_Variant_Select
           (Unit, Routine, (Kind => Landin.IR.Frame_Slot, Slot => Slot),
            1, 2, Site);
         Selected := Landin.IR.Nth_Value (Unit, Routine, Block, 2);
         Value := Landin.IR.Emit_Number
           (Unit, Routine, Landin.Types.U16, 7, False, Site);
         Landin.IR.Emit_Variant_Field_Store
           (Unit, Routine, (Kind => Landin.IR.Frame_Slot, Slot => Slot),
            1, 2, 1, Value, Site);
         Store := Landin.IR.Nth_Value (Unit, Routine, Block, 4);

         Landin.Testing.Check
           (Item,
            Landin.IR.Op_Of (Unit, Routine, Loaded)
              = Landin.IR.Load_Variant_Tag
              and then not Landin.IR.Defines_Nothing
                (Landin.IR.Load_Variant_Tag)
              and then Landin.IR.Source_Of
                (Unit, Routine, Loaded).Slot = Slot
              and then Landin.IR.Element_Field_Of
                (Unit, Routine, Loaded) = 1
              and then Landin.IR.Result_Of
                (Unit, Routine, Loaded) = Landin.Types.U8,
            "a tag load carries source storage, field and scalar type");

         Landin.Testing.Check
           (Item,
            Landin.IR.Op_Of (Unit, Routine, Selected)
              = Landin.IR.Select_Variant
              and then Landin.IR.Defines_Nothing (Landin.IR.Select_Variant)
              and then Landin.IR.Operand_Count
                (Unit, Routine, Selected) = 0
              and then Landin.IR.Destination_Of
                (Unit, Routine, Selected).Slot = Slot
              and then Landin.IR.Element_Field_Of
                (Unit, Routine, Selected) = 1
              and then Landin.IR.Variant_Case_Of
                (Unit, Routine, Selected) = 2,
            "case selection carries storage, field and case identities");
         Landin.Testing.Check
           (Item,
            Landin.IR.Op_Of (Unit, Routine, Store)
              = Landin.IR.Store_Variant_Field
              and then Landin.IR.Defines_Nothing
                (Landin.IR.Store_Variant_Field)
              and then Landin.IR.Variant_Case_Of
                (Unit, Routine, Store) = 2
              and then Landin.IR.Variant_Payload_Field_Of
                (Unit, Routine, Store) = 1
              and then Landin.IR.Operand_Count
                (Unit, Routine, Store) = 1
              and then Landin.IR.Nth_Operand
                (Unit, Routine, Store, 1) = Value,
            "a scalar payload store carries one value and no offsets");

         declare
            Text : constant String := Landin.IR.Dump.Text
              (Unit, Landin.Stages.Meanings (Work).all,
               Landin.Stages.Identities (Work).all);
         begin
            Landin.Testing.Check
              (Item,
               Ada.Strings.Fixed.Index
                 (Text, "LOAD_VARIANT_TAG u8 from slot 1 field 1") /= 0
               and then Ada.Strings.Fixed.Index
                 (Text, "SELECT_VARIANT destination slot 1 field 1 case 2")
                   /= 0
               and then Ada.Strings.Fixed.Index
                 (Text, "STORE_VARIANT_FIELD destination slot 1 field 1"
                        & " case 2 payload field 1 <- 3") /= 0,
               "the dump spells only target-neutral identities");
         end;
      end;
   end Variant_Operations_Carry_Compact_Identities;

   --  D24: an array datum records its source-order image as one Folded
   --  value per position without allocating a run for an omitted-image
   --  datum, and the verifier holds the length to the array's length.
   procedure An_Array_Datum_Image_Is_Compact
     (Item : in out Landin.Testing.Context);

   procedure An_Array_Datum_Image_Is_Compact
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Site : Landin.Provenance.Origin;
   begin
      Frontend_Over (Work, Site);

      declare
         Meanings : constant not null access Landin.Resolution.Table :=
           Landin.Stages.Meanings (Work);
         Unit     : Landin.IR.Unit;
         Loaded   : Landin.IR.Item_Id;
         Repeated : Landin.IR.Item_Id;
         Hybrid   : Landin.IR.Item_Id;
         Blank    : Landin.IR.Item_Id;
         Block    : Landin.IR.Block_Id;
      begin
         Landin.IR.Prepare (Unit, Meanings.all);

         Loaded := Landin.IR.Add_Item
           (Unit, Landin.IR.Datum, 1, Landin.Types.Fixed_Array, Site);
         Landin.IR.Set_Array (Unit, Loaded, Landin.Types.U32, 3);
         Landin.IR.Set_Array_Image
           (Unit, Loaded, Landin.Types.Folded_Array'(10, -1, 30));
         Block := Landin.IR.Add_Block
           (Unit, Loaded, Landin.Resolution.Program_Scope, Site);
         Landin.IR.Enter (Unit, Loaded, Block);
         Landin.IR.Emit_Leave (Unit, Loaded, Landin.IR.No_Value, Site);
         Landin.IR.Leave_Block (Unit, Loaded);

         Repeated := Landin.IR.Add_Item
           (Unit, Landin.IR.Datum, 2, Landin.Types.Fixed_Array, Site);
         Landin.IR.Set_Array
           (Unit, Repeated, Landin.Types.U64, Landin.IR.Element_Total'Last);
         Landin.IR.Set_Repeated_Array_Image
           (Unit, Repeated, -81_985_529_216_486_896);
         Block := Landin.IR.Add_Block
           (Unit, Repeated, Landin.Resolution.Program_Scope, Site);
         Landin.IR.Enter (Unit, Repeated, Block);
         Landin.IR.Emit_Leave (Unit, Repeated, Landin.IR.No_Value, Site);
         Landin.IR.Leave_Block (Unit, Repeated);

         Hybrid := Landin.IR.Add_Item
           (Unit, Landin.IR.Datum, 4, Landin.Types.Fixed_Array, Site);
         Landin.IR.Set_Array
           (Unit, Hybrid, Landin.Types.U64, Landin.IR.Element_Total'Last);
         Landin.IR.Set_Hybrid_Array_Image
           (Unit, Hybrid,
            Landin.Types.Folded_Array'(16#1234_5678_9ABC_DEF0#,
                                       -81_985_529_216_486_896),
            0);
         Block := Landin.IR.Add_Block
           (Unit, Hybrid, Landin.Resolution.Program_Scope, Site);
         Landin.IR.Enter (Unit, Hybrid, Block);
         Landin.IR.Emit_Leave (Unit, Hybrid, Landin.IR.No_Value, Site);
         Landin.IR.Leave_Block (Unit, Hybrid);

         Blank := Landin.IR.Add_Item
           (Unit, Landin.IR.Datum, 3, Landin.Types.Fixed_Array, Site);
         Landin.IR.Set_Array (Unit, Blank, Landin.Types.U32, 3);
         Block := Landin.IR.Add_Block
           (Unit, Blank, Landin.Resolution.Program_Scope, Site);
         Landin.IR.Enter (Unit, Blank, Block);
         Landin.IR.Emit_Leave (Unit, Blank, Landin.IR.No_Value, Site);
         Landin.IR.Leave_Block (Unit, Blank);

         Landin.Testing.Check
           (Item, Landin.IR.Has_Image (Unit, Loaded),
            "a datum given an image reports it");
         Landin.Testing.Check_Equal
           (Item, Natural (Landin.IR.Image_Length (Unit, Loaded)), 3,
            "and its image is one value per declared element");
         Landin.Testing.Check_Equal
           (Item,
            Integer (Landin.IR.Nth_Image (Unit, Loaded, 1)),
            Integer'(10),
            "the first image value is source-order position one");
         Landin.Testing.Check_Equal
           (Item,
            Integer (Landin.IR.Nth_Image (Unit, Loaded, 2)),
            Integer'(-1),
            "a negative folded value survives the image");
         Landin.Testing.Check
           (Item, Landin.IR.Is_Repeated_Image (Unit, Repeated),
            "a repeated image keeps its compact representation");
         Landin.Testing.Check
           (Item,
            Landin.IR.Image_Length (Unit, Repeated)
              = Landin.IR.Element_Total'Last,
            "a repeated image reports the target-sized declared extent");
         Landin.Testing.Check
           (Item,
            Landin.IR.Repeated_Image_Value (Unit, Repeated)
              = Landin.Types.Folded'(-81_985_529_216_486_896),
            "a repeated image carries one complete 64-bit pattern");
         Landin.Testing.Check_Equal
           (Item, Natural (Landin.IR.Image_Prefix_Length (Unit, Hybrid)), 2,
            "a hybrid records only its finite prefix length");
         Landin.Testing.Check
           (Item,
            Landin.IR.Image_Length (Unit, Hybrid)
              = Landin.IR.Element_Total'Last
              and then Landin.IR.Nth_Image (Unit, Hybrid, 1)
                         = Landin.Types.Folded'(16#1234_5678_9ABC_DEF0#)
              and then Landin.IR.Nth_Image (Unit, Hybrid, 3) = 0,
            "a target-sized hybrid keeps prefix and one zero suffix value");
         Landin.Testing.Check
           (Item, not Landin.IR.Has_Image (Unit, Blank),
            "a datum whose image was never set stays without one");
         Landin.Testing.Check
           (Item,
            Landin.IR.Verifier.Check (Unit).Kind
              = Landin.IR.Verifier.Nothing_Wrong,
            "the verifier accepts a well-formed image");
      end;
   end An_Array_Datum_Image_Is_Compact;

   --  D66: an aggregate image is one folded value per declaration-order
   --  field.  Its run remains target-neutral: scalar widths and every byte
   --  of array storage and padding are absent from the IR.
   procedure An_Aggregate_Datum_Image_Is_Compact
     (Item : in out Landin.Testing.Context);

   procedure An_Aggregate_Datum_Image_Is_Compact
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Site : Landin.Provenance.Origin;
   begin
      Frontend_Over (Work, Site);

      declare
         Unit : Landin.IR.Unit;
         Datum : Landin.IR.Item_Id;
         Block : Landin.IR.Block_Id;
      begin
         Landin.IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
         Datum := Landin.IR.Add_Item
           (Unit, Landin.IR.Datum, 1, Landin.Types.Aggregate, Site);
         Landin.IR.Add_Field (Unit, Datum, Landin.Types.U8);
         Landin.IR.Add_Field
           (Unit, Datum,
            (Kind    => Landin.IR.Array_Field_Shape,
             Element => Landin.Types.U16,
             Length  => 2,
             others  => <>));
         Landin.IR.Add_Field (Unit, Datum, Landin.Types.I32);
         Landin.IR.Add_Field
           (Unit, Datum,
            (Kind    => Landin.IR.Array_Field_Shape,
             Element => Landin.Types.U8,
             Length  => 3,
             others  => <>));
         Landin.IR.Add_Field
           (Unit, Datum,
            (Kind    => Landin.IR.Array_Field_Shape,
             Element => Landin.Types.U16,
             Length  => 4,
             others  => <>));
         Landin.IR.Set_Aggregate_Image
           (Unit, Datum,
            Landin.Types.Folded_Array'(5, 0, -3, 0, 0),
            Landin.IR.Aggregate_Field_Image_Array'
              (1 => (others => <>),
               2 => (Form => Landin.IR.Finite,
                     Offset => 0, Count => 2, Value => 0),
               3 => (Form => Landin.IR.Absent,
                     Offset => 2, Count => 0, Value => 0),
               4 => (Form => Landin.IR.Repeated,
                     Offset => 2, Count => 0, Value => 7),
               5 => (Form => Landin.IR.Hybrid,
                     Offset => 2, Count => 2, Value => 23)),
            Landin.Types.Folded_Array'(11, 13, 17, 19));
         Block := Landin.IR.Add_Block
           (Unit, Datum, Landin.Resolution.Program_Scope, Site);
         Landin.IR.Enter (Unit, Datum, Block);
         Landin.IR.Emit_Leave (Unit, Datum, Landin.IR.No_Value, Site);
         Landin.IR.Leave_Block (Unit, Datum);

         Landin.Testing.Check
           (Item,
            Landin.IR.Has_Image (Unit, Datum)
            and then Landin.IR.Image_Length (Unit, Datum) = 9,
            "an aggregate image has flat fields and compact elements");
         Landin.Testing.Check
           (Item,
            Landin.IR.Nth_Field_Image (Unit, Datum, 1) = 5
            and then Landin.IR.Nth_Field_Image (Unit, Datum, 2) = 0
            and then Landin.IR.Nth_Field_Image (Unit, Datum, 3) = -3
            and then Landin.IR.Nth_Field_Image (Unit, Datum, 4) = 0
            and then Landin.IR.Nth_Field_Image (Unit, Datum, 5) = 0,
            "field folds keep declaration order and the array placeholder");
         Landin.Testing.Check
           (Item,
            Landin.IR.Field_Image_Of (Unit, Datum, 2).Form
              = Landin.IR.Finite
            and then Landin.IR.Nth_Field_Element (Unit, Datum, 2, 1) = 11
            and then Landin.IR.Nth_Field_Element (Unit, Datum, 2, 2) = 13,
            "a finite array-field image keeps its source-order folds");
         Landin.Testing.Check
           (Item,
            Landin.IR.Field_Image_Of (Unit, Datum, 4).Form
              = Landin.IR.Repeated
            and then Landin.IR.Field_Image_Of (Unit, Datum, 4).Value = 7
            and then Landin.IR.Field_Image_Of (Unit, Datum, 5).Form
              = Landin.IR.Hybrid
            and then Landin.IR.Nth_Field_Element (Unit, Datum, 5, 1) = 17
            and then Landin.IR.Nth_Field_Element (Unit, Datum, 5, 2) = 19
            and then Landin.IR.Field_Image_Of (Unit, Datum, 5).Value = 23,
            "repeated and hybrid field images keep their compact patterns");
         Landin.Testing.Check
           (Item,
            Ada.Strings.Fixed.Index
              (Landin.IR.Dump.Text
                 (Unit, Landin.Stages.Meanings (Work).all,
                  Landin.Stages.Identities (Work).all),
               "  image 5 0 -3 0 0") /= 0,
            "the dump prints flat folds rather than target bytes");
         Landin.Testing.Check
           (Item,
            Ada.Strings.Fixed.Index
              (Landin.IR.Dump.Text
                 (Unit, Landin.Stages.Meanings (Work).all,
                  Landin.Stages.Identities (Work).all),
               "  field 2 image 11 13") /= 0,
            "the dump prints a finite field segment separately");
         Landin.Testing.Check
           (Item,
            Ada.Strings.Fixed.Index
              (Landin.IR.Dump.Text
                 (Unit, Landin.Stages.Meanings (Work).all,
                  Landin.Stages.Identities (Work).all),
               "  field 4 image repeat 7") /= 0
            and then Ada.Strings.Fixed.Index
              (Landin.IR.Dump.Text
                 (Unit, Landin.Stages.Meanings (Work).all,
                  Landin.Stages.Identities (Work).all),
               "  field 5 image 17 19 repeat 23") /= 0,
            "the dump distinguishes repeated and hybrid field patterns");
         Landin.Testing.Check
           (Item,
            Landin.IR.Verifier.Check (Unit).Kind
              = Landin.IR.Verifier.Nothing_Wrong,
            "the verifier accepts a canonical aggregate image");
      end;
   end An_Aggregate_Datum_Image_Is_Compact;

   ------------------------------------------------------------------
   --  D22: a slot-reaching element operation
   ------------------------------------------------------------------

   procedure A_Slot_Element_Reaches_The_Frame
     (Item : in out Landin.Testing.Context);

   procedure A_Slot_Element_Reaches_The_Frame
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Site : Landin.Provenance.Origin;
   begin
      Frontend_Over (Work, Site);

      declare
         Meanings : constant not null access Landin.Resolution.Table :=
           Landin.Stages.Meanings (Work);
         Unit : Landin.IR.Unit;
         Routine : Landin.IR.Item_Id;
         Slot : Landin.IR.Slot_Id;
         Block : Landin.IR.Block_Id;
         Index, Stored, Loaded, Store : Landin.IR.Value_Id;
      begin
         Landin.IR.Prepare (Unit, Meanings.all);
         Routine := Landin.IR.Add_Item
                      (Unit, Landin.IR.Routine, 1, Landin.Types.U32, Site);
         Slot := Landin.IR.Add_Array_Slot
                   (Unit, Routine, Landin.Types.U32, 4,
                    Landin.IR.No_Declaration, Site);
         Block := Landin.IR.Add_Block
                    (Unit, Routine, Landin.Resolution.Program_Scope, Site);
         Landin.IR.Enter (Unit, Routine, Block);
         Index := Landin.IR.Emit_Number
                    (Unit, Routine, Landin.Types.Usize, 2, False, Site);
         Stored := Landin.IR.Emit_Number
                     (Unit, Routine, Landin.Types.U32, 9, False, Site);
         Loaded := Landin.IR.Emit_Load_Slot_Element
                     (Unit, Routine, Slot, Index, Landin.Types.U32, Site);
         Landin.IR.Emit_Store_Slot_Element
           (Unit, Routine, Slot, Index, Stored, Site);
         Store := Landin.IR.Nth_Value (Unit, Routine, Block, 4);

         Landin.Testing.Check
           (Item,
            Landin.IR.Op_Of (Unit, Routine, Loaded)
              = Landin.IR.Load_Element
            and then Landin.IR.Reaches_A_Slot (Unit, Routine, Loaded)
            and then Landin.IR.Slot_Of (Unit, Routine, Loaded) = Slot
            and then Landin.IR.Slot_Element_Length (Unit, Routine, Loaded)
                       = 4
            and then Landin.IR.Slot_Element_Type (Unit, Routine, Loaded)
                       = Landin.Types.U32
            and then Landin.IR.Nth_Operand (Unit, Routine, Loaded, 1)
                       = Index,
            "a slot element load carries its slot and its runtime index");
         Landin.Testing.Check
           (Item,
            Landin.IR.Op_Of (Unit, Routine, Store)
              = Landin.IR.Store_Element
            and then Landin.IR.Reaches_A_Slot (Unit, Routine, Store)
            and then Landin.IR.Slot_Of (Unit, Routine, Store) = Slot
            and then Landin.IR.Nth_Operand (Unit, Routine, Store, 1) = Index
            and then Landin.IR.Nth_Operand (Unit, Routine, Store, 2) = Stored,
            "a slot element store carries its index before the value");

         declare
            Text : constant String :=
              Landin.IR.Dump.Text
                (Unit, Meanings.all,
                 Landin.Stages.Identities (Work).all);
         begin
            Landin.Testing.Check
              (Item,
               Ada.Strings.Fixed.Index (Text, "LOAD_ELEMENT u32 slot 1") /= 0
               and then Ada.Strings.Fixed.Index
                          (Text, "STORE_ELEMENT slot 1") /= 0,
               "the dump prints the slot form of an element operation");
         end;
      end;
   end A_Slot_Element_Reaches_The_Frame;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "ir", "items do not share a run",
         Items_Do_Not_Share_A_Run'Access);
      Landin.Testing.Register
        (Into, "ir", "a block reports its own instructions",
         A_Block_Reports_Its_Own_Instructions'Access);
      Landin.Testing.Register
        (Into, "ir", "interleaved fill is refused",
         Interleaved_Fill_Is_Refused'Access);
      Landin.Testing.Register
        (Into, "ir", "interleaved slot fields are refused",
         Interleaved_Slot_Fields_Are_Refused'Access);
      Landin.Testing.Register
        (Into, "ir", "a call reads its own arguments",
         A_Call_Reads_Its_Own_Arguments'Access);
      Landin.Testing.Register
        (Into, "ir", "an element carries its operands",
         An_Element_Carries_Its_Operands'Access);
      Landin.Testing.Register
        (Into, "ir", "an array slot has a compact shape",
         An_Array_Slot_Has_A_Compact_Shape'Access);
      Landin.Testing.Register
        (Into, "ir", "an array copy carries two compact places",
         An_Array_Copy_Carries_Two_Compact_Places'Access);
      Landin.Testing.Register
        (Into, "ir", "variant operations carry compact identities",
         Variant_Operations_Carry_Compact_Identities'Access);
      Landin.Testing.Register
        (Into, "ir", "an array datum image is compact",
         An_Array_Datum_Image_Is_Compact'Access);
      Landin.Testing.Register
        (Into, "ir", "an aggregate datum image is compact",
         An_Aggregate_Datum_Image_Is_Compact'Access);
      Landin.Testing.Register
        (Into, "ir", "a slot element reaches the frame",
         A_Slot_Element_Reaches_The_Frame'Access);
   end Register;

end Landin.Tests.IR_Suite;
