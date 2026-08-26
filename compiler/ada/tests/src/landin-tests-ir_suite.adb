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

with Landin.IR;
with Landin.Provenance;
with Landin.Resolution;
with Landin.Source;
with Landin.Stages.Checking;
with Landin.Stages.Resolution;
with Landin.Stages.Syntax;
with Landin.Targets;
with Landin.Types;

package body Landin.Tests.IR_Suite is

   use type Landin.IR.Slot_Id;
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
   end Register;

end Landin.Tests.IR_Suite;
