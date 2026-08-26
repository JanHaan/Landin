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
   use type Landin.IR.Item_Id;
   use type Landin.IR.Opcode;
   use type Landin.IR.Part_Position;
   use type Landin.IR.Slot_Id;
   use type Landin.IR.Storage_Kind;
   use type Landin.IR.Value_Id;
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
                     Landin.Types.Fixed_Array, Site);
         Landin.IR.Set_Array (Unit, Datum, Landin.Types.U32, 4);
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
                     (Unit, Routine, Datum, Index, Landin.Types.U32, Site);
         Landin.IR.Emit_Store_Element
           (Unit, Routine, Datum, Index, Stored, Site);
         Store := Landin.IR.Nth_Value (Unit, Routine, Block, 4);

         Landin.Testing.Check
           (Item,
            Landin.IR.Op_Of (Unit, Routine, Loaded)
              = Landin.IR.Load_Element
            and then Landin.IR.Datum_Of (Unit, Routine, Loaded) = Datum
            and then Landin.IR.Operand_Count (Unit, Routine, Loaded) = 1
            and then Landin.IR.Nth_Operand (Unit, Routine, Loaded, 1) = Index,
            "a load carries its array and runtime index");
         Landin.Testing.Check
           (Item,
            Landin.IR.Op_Of (Unit, Routine, Store)
              = Landin.IR.Store_Element
            and then Landin.IR.Datum_Of (Unit, Routine, Store) = Datum
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
         Copy    : Landin.IR.Value_Id;
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
            (Kind => Landin.IR.Frame_Slot, Slot => Slot), Site);
         Copy := Landin.IR.Nth_Value (Unit, Routine, Block, 1);

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
            and then Landin.IR.Destination_Of (Unit, Routine, Copy).Kind
              = Landin.IR.Frame_Slot
            and then Landin.IR.Destination_Of
                       (Unit, Routine, Copy).Slot = Slot,
            "its discriminated endpoints retain datum and slot identities");
         Landin.Testing.Check_Equal
           (Item, Landin.IR.Operand_Count (Unit, Routine, Copy), 0,
            "its metadata does not grow with the array length");

         declare
            Text : constant String := Landin.IR.Dump.Text
              (Unit, Landin.Stages.Meanings (Work).all,
               Landin.Stages.Identities (Work).all);
         begin
            Landin.Testing.Check
              (Item,
               Ada.Strings.Fixed.Index
                 (Text, "COPY_ARRAY from datum 1 f to slot 1") /= 0,
               "the dump names both kinds of storage endpoint");
         end;
      end;
   end An_Array_Copy_Carries_Two_Compact_Places;

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
        (Into, "ir", "a slot element reaches the frame",
         A_Slot_Element_Reaches_The_Frame'Access);
   end Register;

end Landin.Tests.IR_Suite;
