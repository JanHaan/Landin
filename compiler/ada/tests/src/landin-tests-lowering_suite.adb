--  What the lowering builds, read back out of the Unit.
--
--  The fixture suite already runs every positive fixture through the whole
--  driver, so it says the lowering does not raise on any of them.  That is
--  worth having and is not evidence that the instructions are right, since
--  nothing yet emits or executes them.  These cases read the Unit.
--
--  Until the verifier lands, "every block ends with exactly one terminator,
--  in last position" is checked here over the programs below.  It is the
--  invariant the whole block shape exists for, and Landin.IR deliberately
--  lets a lowering violate it: Emit_Jump has no precondition against a
--  mid-block terminator, on purpose, so that it can be tested.

with Ada.Strings.Unbounded;

with Landin.Checking;
with Landin.IR;
with Landin.IR.Dump;
with Landin.IR.Verifier;
with Landin.Platform;
with Landin.Platform.Native;
with Landin.Testing.Fixtures;
with Landin.Source;
with Landin.Syntax;
with Landin.Syntax.Forest;
with Landin.Stages.Checking;
with Landin.Stages.Lowering;
with Landin.Stages.Resolution;
with Landin.Stages.Syntax;
with Landin.Targets;
with Landin.Types;

package body Landin.Tests.Lowering_Suite is

   package IR renames Landin.IR;

   use type IR.Block_Id;
   use type IR.Item_Id;
   use type IR.Item_Kind;
   use type Landin.Platform.Read_Status;
   use type Landin.Platform.Write_Status;
   use type Landin.Testing.Fixtures.Fixture_Class;
   use type IR.Opcode;
   use type IR.Slot_Id;
   use type IR.Part_Position;
   use type IR.Value_Id;
   use type Landin.IR.Verifier.Fault_Kind;
   use type Landin.Source.Source_Id;
   use type Landin.Types.Magnitude;
   use type Landin.Types.Type_Kind;

   Frontend : aliased Landin.Stages.Syntax.Instance;
   Names    : aliased Landin.Stages.Resolution.Instance;
   Checker  : aliased Landin.Stages.Checking.Instance;
   Lowerer  : aliased Landin.Stages.Lowering.Instance;

   LF : constant Character := Character'Val (10);

   procedure Lower
     (Work : in out Landin.Stages.Compilation;
      Text : String;
      Ran  : out Natural);

   procedure Lower
     (Work : in out Landin.Stages.Compilation;
      Text : String;
      Ran  : out Natural)
   is
      Order   : Landin.Stages.Pipeline;
      Written : constant Landin.Source.Source_Id :=
        Landin.Stages.Add_Source (Work, "low.ldn", Text);
   begin
      pragma Assert (Written /= Landin.Source.No_Source);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Landin.Stages.Append (Order, Lowerer'Access);
      Ran := Landin.Stages.Run (Order, Work);
   end Lower;

   --  Every block of every item ends with exactly one terminator, and it
   --  is the last instruction.
   procedure Check_Terminators
     (Item : in out Landin.Testing.Context;
      Unit : IR.Unit;
      What : String);

   procedure Check_Terminators
     (Item : in out Landin.Testing.Context;
      Unit : IR.Unit;
      What : String)
   is
      Sound : Boolean := True;
   begin
      for Which in 1 .. IR.Item_Count (Unit) loop
         declare
            Id : constant IR.Item_Id := IR.Item_Id (Which);
         begin
            for B in 1 .. IR.Block_Count (Unit, Id) loop
               declare
                  Block : constant IR.Block_Id := IR.Block_Id (B);
                  Last  : constant Natural := IR.Length (Unit, Id, Block);
               begin
                  if Last = 0 then
                     Sound := False;
                  else
                     for Position in 1 .. Last loop
                        declare
                           Op : constant IR.Opcode :=
                             IR.Op_Of
                               (Unit, Id,
                                IR.Nth_Value (Unit, Id, Block, Position));
                           Ends : constant Boolean :=
                             Op in IR.Terminator_Kind;
                        begin
                           if Ends /= (Position = Last) then
                              Sound := False;
                           end if;
                        end;
                     end loop;
                  end if;
               end;
            end loop;
         end;
      end loop;

      Landin.Testing.Check
        (Item, Sound,
         What & ": every block ends with exactly one terminator");
   end Check_Terminators;

   ------------------------------------------------------------------

   procedure A_Function_Becomes_One_Routine
     (Item : in out Landin.Testing.Context);

   procedure A_Function_Becomes_One_Routine
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: () -> (r: u32) =" & LF & "    r = 1" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work), "the program is accepted");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         One  : constant IR.Item_Id := 1;
      begin
         Landin.Testing.Check_Equal
           (Item, IR.Item_Count (Unit), 1, "one item");
         Landin.Testing.Check
           (Item, IR.Kind_Of (Unit, One) = IR.Routine,
            "a function is a routine");
         Landin.Testing.Check
           (Item, IR.Result_Of (Unit, One) = Landin.Types.U32,
            "the routine gives back its named return's type");
         Landin.Testing.Check_Equal
           (Item, IR.Parameter_Count (Unit, One), 0, "no parameters");
         Landin.Testing.Check_Equal
           (Item, IR.Slot_Count (Unit, One), 1,
            "one slot, which is the named return");
         Landin.Testing.Check
           (Item, IR.Result_Slot (Unit, One) /= IR.No_Slot,
            "the result slot is set");
         Landin.Testing.Check_Equal
           (Item, IR.Block_Count (Unit, One), 1, "one block");

         --  [1810] `r = 1` is a number and a store; falling off the end
         --  is [0930]'s load of the return and a leave.
         Landin.Testing.Check_Equal
           (Item, IR.Value_Count (Unit, One), 4, "four instructions");
         Landin.Testing.Check
           (Item, IR.Op_Of (Unit, One, 1) = IR.Number, "a number");
         Landin.Testing.Check
           (Item, IR.Op_Of (Unit, One, 2) = IR.Store, "a store");
         Landin.Testing.Check
           (Item, IR.Op_Of (Unit, One, 3) = IR.Load, "a load");
         Landin.Testing.Check
           (Item, IR.Op_Of (Unit, One, 4) = IR.Leave, "a leave");

         Check_Terminators (Item, Unit, "a plain function");
      end;
   end A_Function_Becomes_One_Routine;

   ------------------------------------------------------------------

   procedure A_Branch_Becomes_Blocks
     (Item : in out Landin.Testing.Context);

   procedure A_Branch_Becomes_Blocks
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: u32) -> (r: u32) =" & LF
         & "    if a > 1 then" & LF
         & "        r = 1" & LF
         & "    else" & LF
         & "        r = 2" & LF
         & "    end if" & LF
         & "end f" & LF,
         Ran);

      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work), "the program is accepted");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         One  : constant IR.Item_Id := 1;
         Branches : Natural := 0;
      begin
         Landin.Testing.Check_Equal
           (Item, IR.Parameter_Count (Unit, One), 1, "one parameter");

         --  [0410] makes the words control flow and [1050] makes an arm a
         --  statement run, so a two-way branch is more than one block.
         Landin.Testing.Check
           (Item, IR.Block_Count (Unit, One) > 1,
            "a branch produced more than one block");

         for V in 1 .. IR.Value_Count (Unit, One) loop
            if IR.Op_Of (Unit, One, IR.Value_Id (V)) = IR.Branch then
               Branches := Branches + 1;
            end if;
         end loop;

         Landin.Testing.Check_Equal
           (Item, Branches, 1, "one branch, for the one condition");

         Check_Terminators (Item, Unit, "a branch");
      end;
   end A_Branch_Becomes_Blocks;

   ------------------------------------------------------------------

   procedure A_Short_Circuit_Crosses_A_Merge_Through_A_Slot
     (Item : in out Landin.Testing.Context);

   procedure A_Short_Circuit_Crosses_A_Merge_Through_A_Slot
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      --  [0410]: the right operand is evaluated only when the left did
      --  not settle the answer, so this is control flow and not an
      --  opcode, and the answer reaches the merge through a slot.
      Lower
        (Work,
         "f: (a: bool, b: bool) -> (r: bool) =" & LF
         & "    r = a and b" & LF
         & "end f" & LF,
         Ran);

      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work), "the program is accepted");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         One  : constant IR.Item_Id := 1;
         Branches : Natural := 0;
      begin
         --  Two parameters, the named return, and the slot the answer
         --  crosses the merge in.
         Landin.Testing.Check_Equal
           (Item, IR.Slot_Count (Unit, One), 4,
            "a slot was added for the answer, beside the three names");

         for V in 1 .. IR.Value_Count (Unit, One) loop
            if IR.Op_Of (Unit, One, IR.Value_Id (V)) = IR.Branch then
               Branches := Branches + 1;
            end if;
         end loop;

         Landin.Testing.Check_Equal
           (Item, Branches, 1, "the short circuit is one branch");
         Landin.Testing.Check
           (Item, IR.Block_Count (Unit, One) = 3,
            "an entry, the block that evaluates the right, and the join");

         Check_Terminators (Item, Unit, "a short circuit");
      end;
   end A_Short_Circuit_Crosses_A_Merge_Through_A_Slot;

   ------------------------------------------------------------------

   procedure A_Refused_Program_Is_Not_Lowered
     (Item : in out Landin.Testing.Context);

   procedure A_Refused_Program_Is_Not_Lowered
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      --  [1890]: two operands of one type, and these are two.  R1.70
      --  assigns the lowering no diagnostic code at all, and the argument
      --  for that is only sound while nothing lowers a refused program.
      Lower
        (Work,
         "f: (a: u64, b: usize) -> (r: u64) =" & LF
         & "    r = a + b" & LF
         & "end f" & LF,
         Ran);

      Landin.Testing.Check
        (Item, Landin.Stages.Failed (Work), "the program is refused");
      Landin.Testing.Check_Equal
        (Item, IR.Item_Count (Landin.Stages.Code (Work).all), 0,
         "a refused program produced no items at all");
   end A_Refused_Program_Is_Not_Lowered;

   ------------------------------------------------------------------

   procedure A_Call_Carries_Its_Arguments
     (Item : in out Landin.Testing.Context);

   procedure A_Call_Carries_Its_Arguments
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      --  [1740] makes a module a set, so `caller` names `sum` written
      --  below it: the item has to exist before the body is walked.
      Lower
        (Work,
         "caller: () -> (r: u32) =" & LF
         & "    r = sum(1, 2)" & LF
         & "end caller" & LF
         & "sum: (a: u32, b: u32) -> (r: u32) =" & LF
         & "    r = a + b" & LF
         & "end sum" & LF,
         Ran);

      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work), "the program is accepted");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         One  : constant IR.Item_Id := 1;
         Found : IR.Value_Id := IR.No_Value;
      begin
         Landin.Testing.Check_Equal
           (Item, IR.Item_Count (Unit), 2, "two routines");

         for V in 1 .. IR.Value_Count (Unit, One) loop
            if IR.Op_Of (Unit, One, IR.Value_Id (V)) = IR.Call then
               Found := IR.Value_Id (V);
            end if;
         end loop;

         Landin.Testing.Check
           (Item, Found /= IR.No_Value, "the call was emitted");

         if Found /= IR.No_Value then
            Landin.Testing.Check_Equal
              (Item, IR.Operand_Count (Unit, One, Found), 2,
               "the call carries both arguments");
         end if;

         Check_Terminators (Item, Unit, "a call");
      end;
   end A_Call_Carries_Its_Arguments;

   ------------------------------------------------------------------

   procedure A_Call_Carries_An_Earlier_Argument_Across_A_Short_Circuit
     (Item : in out Landin.Testing.Context);

   procedure A_Call_Carries_An_Earlier_Argument_Across_A_Short_Circuit
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      --  [0410] evaluates `a` before the later argument.  That argument
      --  changes blocks, so the earlier value has to cross through a slot:
      --  every operand of the eventual call remains block-local.
      Lower
        (Work,
         "caller: (a: bool, b: bool, c: bool) -> (r: bool) =" & LF
         & "    r = choose(a, b and c)" & LF
         & "end caller" & LF
         & "choose: (first: bool, second: bool) -> (r: bool) =" & LF
         & "    r = first" & LF
         & "end choose" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work), "the program is accepted");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         One  : constant IR.Item_Id := 1;
         A_Load  : IR.Value_Id := IR.No_Value;
         Saved_A : IR.Slot_Id := IR.No_Slot;
         Split   : IR.Value_Id := IR.No_Value;
         Found   : IR.Value_Id := IR.No_Value;
      begin
         for V in 1 .. IR.Value_Count (Unit, One) loop
            declare
               Value : constant IR.Value_Id := IR.Value_Id (V);
               Op    : constant IR.Opcode := IR.Op_Of (Unit, One, Value);
            begin
               if Op = IR.Load
                 and then IR.Slot_Of (Unit, One, Value)
                            = IR.Nth_Parameter (Unit, One, 1)
                 and then A_Load = IR.No_Value
               then
                  A_Load := Value;
               elsif Op = IR.Store
                 and then A_Load /= IR.No_Value
                 and then IR.Nth_Operand (Unit, One, Value, 1) = A_Load
               then
                  Saved_A := IR.Slot_Of (Unit, One, Value);
               elsif Op = IR.Branch then
                  Split := Value;
               elsif Op = IR.Call then
                  Found := Value;
               end if;
            end;
         end loop;

         Landin.Testing.Check
           (Item, A_Load /= IR.No_Value and then Split /= IR.No_Value
                  and then A_Load < Split,
            "the first argument was evaluated before the short circuit");
         Landin.Testing.Check
           (Item, Found /= IR.No_Value, "the call was emitted");

         if Found /= IR.No_Value then
            Landin.Testing.Check_Equal
              (Item, IR.Operand_Count (Unit, One, Found), 2,
               "the call carries both block-local arguments");

            if Saved_A /= IR.No_Slot then
               declare
                  Carried : constant IR.Value_Id :=
                    IR.Nth_Operand (Unit, One, Found, 1);
               begin
                  Landin.Testing.Check
                    (Item, IR.Op_Of (Unit, One, Carried) = IR.Load
                           and then IR.Slot_Of (Unit, One, Carried) = Saved_A,
                     "the first operand is the saved value of a");
               end;
            else
               Landin.Testing.Check
                 (Item, False, "the value of a was saved before the branch");
            end if;
         end if;

         Check_Terminators (Item, Unit, "a call after a short circuit");
      end;
   end A_Call_Carries_An_Earlier_Argument_Across_A_Short_Circuit;

   ------------------------------------------------------------------

   procedure A_Binary_Carries_Its_Left_Across_A_Short_Circuit
     (Item : in out Landin.Testing.Context);

   procedure A_Binary_Carries_Its_Left_Across_A_Short_Circuit
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      --  [0410] evaluates `a` before the right operand.  The nested logical
      --  expression changes blocks, so `a` must cross through a slot before
      --  both operands meet again at the comparison.
      Lower
        (Work,
         "f: (a: bool, b: bool, c: bool) -> (r: bool) =" & LF
         & "    r = a == (b and c)" & LF
         & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work), "the program is accepted");

      declare
         Unit    : IR.Unit renames Landin.Stages.Code (Work).all;
         One     : constant IR.Item_Id := 1;
         A_Load  : IR.Value_Id := IR.No_Value;
         Saved_A : IR.Slot_Id := IR.No_Slot;
         Found   : IR.Value_Id := IR.No_Value;
      begin
         for V in 1 .. IR.Value_Count (Unit, One) loop
            declare
               Value : constant IR.Value_Id := IR.Value_Id (V);
               Op    : constant IR.Opcode := IR.Op_Of (Unit, One, Value);
            begin
               if Op = IR.Load
                 and then IR.Slot_Of (Unit, One, Value)
                            = IR.Nth_Parameter (Unit, One, 1)
                 and then A_Load = IR.No_Value
               then
                  A_Load := Value;
               elsif Op = IR.Store
                 and then A_Load /= IR.No_Value
                 and then IR.Nth_Operand (Unit, One, Value, 1) = A_Load
               then
                  Saved_A := IR.Slot_Of (Unit, One, Value);
               elsif Op = IR.Equal_To then
                  Found := Value;
               end if;
            end;
         end loop;

         Landin.Testing.Check
           (Item, Found /= IR.No_Value, "the comparison was emitted");

         if Found /= IR.No_Value and then Saved_A /= IR.No_Slot then
            declare
               Carried : constant IR.Value_Id :=
                 IR.Nth_Operand (Unit, One, Found, 1);
            begin
               Landin.Testing.Check
                 (Item, IR.Op_Of (Unit, One, Carried) = IR.Load
                        and then IR.Slot_Of (Unit, One, Carried) = Saved_A,
                  "the left operand is the saved value of a");
               Landin.Testing.Check
                 (Item, IR.Block_Of (Unit, One, Carried)
                          = IR.Block_Of (Unit, One, Found),
                  "the carried left operand is block-local");
            end;
         else
            Landin.Testing.Check
              (Item, False, "the value of a crossed through a slot");
         end if;

         Check_Terminators (Item, Unit, "a binary after a short circuit");
      end;
   end A_Binary_Carries_Its_Left_Across_A_Short_Circuit;

   ------------------------------------------------------------------

   procedure A_Module_Value_Becomes_A_Datum
     (Item : in out Landin.Testing.Context);

   procedure A_Module_Value_Becomes_A_Datum
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      --  D10: the second holds zero, because [1460] leaves no moment at
      --  module level in which anything could assign it.
      Lower (Work, "limit: u32 = 4096" & LF & "later: i32" & LF, Ran);

      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work), "the program is accepted");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
      begin
         Landin.Testing.Check_Equal
           (Item, IR.Item_Count (Unit), 2, "two items");
         Landin.Testing.Check
           (Item, IR.Kind_Of (Unit, 1) = IR.Datum
                  and then IR.Kind_Of (Unit, 2) = IR.Datum,
            "a module binding is a datum");

         --  A value and a leave, both times: the block describes the
         --  value and [1460] says it never runs.
         Landin.Testing.Check_Equal
           (Item, IR.Block_Count (Unit, 1), 1, "the datum has one block");
         Landin.Testing.Check_Equal
           (Item, IR.Value_Count (Unit, 1), 2, "a number and a leave");
         Landin.Testing.Check
           (Item, IR.Op_Of (Unit, 1, 1) = IR.Number, "the value");
         Landin.Testing.Check
           (Item, IR.Op_Of (Unit, 1, 2) = IR.Leave, "and the leave");

         Landin.Testing.Check_Equal
           (Item, IR.Value_Count (Unit, 2), 2,
            "the valueless binding got a value too");
         Landin.Testing.Check
           (Item, IR.Op_Of (Unit, 2, 1) = IR.Number,
            "D10's zero is a number like any other");

         Check_Terminators (Item, Unit, "two datums");
      end;
   end A_Module_Value_Becomes_A_Datum;

   ------------------------------------------------------------------

   --  R2.20: a direct-name initial image does not alias its source.  Each
   --  declaration remains a separate fixed-array datum; the currently
   --  possible image is zero and therefore needs no run-before-main copy.
   procedure Module_Array_Images_Keep_Distinct_Datums
     (Item : in out Landin.Testing.Context);

   procedure Module_Array_Images_Keep_Distinct_Datums
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "mut typed: [2]u32 = source" & LF
         & "mut inferred := typed" & LF
         & "mut source: [2]u32" & LF,
         Ran);

      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work), "the program is accepted");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
      begin
         Landin.Testing.Check_Equal
           (Item, IR.Item_Count (Unit), 3,
            "source and both destinations are separate items");

         for Datum in IR.Item_Id range 1 .. 3 loop
            Landin.Testing.Check
              (Item, IR.Kind_Of (Unit, Datum) = IR.Datum
                       and then IR.Result_Of (Unit, Datum)
                                = Landin.Types.Fixed_Array,
               "each declaration is its own array datum");
            Landin.Testing.Check_Equal
              (Item, Natural (IR.Array_Length (Unit, Datum)), 2,
               "each datum keeps the exact length");
            Landin.Testing.Check
              (Item, IR.Array_Element (Unit, Datum) = Landin.Types.U32,
               "each datum keeps the exact element type");
         end loop;
      end;
   end Module_Array_Images_Keep_Distinct_Datums;

   ------------------------------------------------------------------

   --  [0670]'s state carries its fields' types and no value at all: D10
   --  zeroes the whole of it, and where each field sits needs a target
   --  this stage deliberately does not have.
   procedure A_Struct_State_Carries_Its_Fields
     (Item : in out Landin.Testing.Context);

   procedure A_Struct_State_Carries_Its_Fields
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "counters: type = struct" & LF
         & "    hits: u32" & LF
         & "    ready: bool" & LF
         & "end counters" & LF
         & "mut state: counters" & LF,
         Ran);

      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work), "the program is accepted");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
      begin
         Landin.Testing.Check_Equal
           (Item, IR.Item_Count (Unit), 1, "the type declares no item");
         Landin.Testing.Check
           (Item, IR.Kind_Of (Unit, 1) = IR.Datum,
            "module state is a datum");
         Landin.Testing.Check
           (Item, IR.Result_Of (Unit, 1) = Landin.Types.Aggregate,
            "and its type is the aggregate it was declared with");

         Landin.Testing.Check_Equal
           (Item, IR.Field_Count (Unit, 1), 2, "both fields are carried");
         Landin.Testing.Check
           (Item, IR.Nth_Field (Unit, 1, 1) = Landin.Types.U32,
            "the first field keeps its type");
         Landin.Testing.Check
           (Item, IR.Nth_Field (Unit, 1, 2) = Landin.Types.Bool,
            "and so does the second, in the order they were written");

         Landin.Testing.Check_Equal
           (Item, IR.Value_Count (Unit, 1), 1, "a leave and nothing else");
         Landin.Testing.Check
           (Item, IR.Op_Of (Unit, 1, 1) = IR.Leave, "which is the leave");
         Landin.Testing.Check_Equal
           (Item, IR.Operand_Count (Unit, 1, 1), 0,
            "and it hands back no value");

         Check_Terminators (Item, Unit, "one struct state");
      end;
   end A_Struct_State_Carries_Its_Fields;

   ------------------------------------------------------------------

   --  [0710]'s copy is a field read and a field write each, in [0750]'s
   --  order, and no opcode of its own: two fields make four instructions
   --  and the last of them is the store of the second field.
   procedure A_Struct_Copy_Becomes_Its_Fields
     (Item : in out Landin.Testing.Context);

   procedure A_Struct_Copy_Becomes_Its_Fields
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "point: type = struct" & LF
         & "    x: u32" & LF
         & "    on: bool" & LF
         & "end point" & LF
         & "copy: () -> none =" & LF
         & "    mut p: point" & LF
         & "    p.x = 1" & LF
         & "    p.on = true" & LF
         & "    mut q: point" & LF
         & "    q = p" & LF
         & "end copy" & LF,
         Ran);

      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work), "the program is accepted");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
      begin
         Landin.Testing.Check_Equal
           (Item, IR.Slot_Count (Unit, 1), 2, "two cells, one per local");
         Landin.Testing.Check
           (Item, IR.Is_Aggregate (Unit, 1, 1)
                  and then IR.Is_Aggregate (Unit, 1, 2),
            "and both hold a struct");

         --  Two writes of two values each, then the copy's four.
         Landin.Testing.Check
           (Item, IR.Op_Of (Unit, 1, 5) = IR.Load_Field,
            "the copy reads the first field");
         Landin.Testing.Check
           (Item, IR.Op_Of (Unit, 1, 6) = IR.Store_Field,
            "and writes it before reading the second");
         Landin.Testing.Check
           (Item, IR.Op_Of (Unit, 1, 7) = IR.Load_Field,
            "then reads the second field");
         Landin.Testing.Check
           (Item, IR.Op_Of (Unit, 1, 8) = IR.Store_Field,
            "and writes that one too");
         Landin.Testing.Check
           (Item, IR.Field_Of (Unit, 1, 7) = 2,
            "which is field two, in the order [0750] wrote them");
      end;
   end A_Struct_Copy_Becomes_Its_Fields;

   ------------------------------------------------------------------
   --  D21: a local array initialized from a whole-array name becomes one
   --  Copy_Array from the source's storage to the destination's slot.  The
   --  same instruction serves an assignment: what changes is where.
   procedure A_Local_Array_Initializer_Becomes_A_Copy
     (Item : in out Landin.Testing.Context);

   procedure A_Local_Array_Initializer_Becomes_A_Copy
     (Item : in out Landin.Testing.Context)
   is
      use type IR.Storage_Kind;

      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      --  D21 across every combination of destination mutability and source
      --  kind: module-to-mut, module-to-immutable, local-to-mut,
      --  local-to-immutable.  Each becomes one Copy_Array whose source and
      --  destination storage tell that combination apart.
      Lower
        (Work,
         "source: [2]u32" & LF
         & "f: () -> none =" & LF
         & "    mut mut_from_module := source" & LF
         & "    immutable_from_module := source" & LF
         & "    mut mut_from_local := mut_from_module" & LF
         & "    immutable_from_local := immutable_from_module" & LF
         & "    mut typed_mutable: [2]u32 = source" & LF
         & "    typed_immutable: [2]u32 = source" & LF
         & "end f" & LF,
         Ran);

      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work), "the program is accepted");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
      begin
         Landin.Testing.Check_Equal
           (Item, IR.Slot_Count (Unit, 2), 6,
            "six frame cells, one per initialized local");

         --  Module -> mutable local.
         Landin.Testing.Check
           (Item, IR.Op_Of (Unit, 2, 1) = IR.Copy_Array,
            "the mutable binding from a module is one array copy");
         Landin.Testing.Check
           (Item, IR.Source_Of (Unit, 2, 1).Kind = IR.Module_Datum
                  and then IR.Source_Of (Unit, 2, 1).Datum = 1
                  and then IR.Destination_Of (Unit, 2, 1).Kind
                             = IR.Frame_Slot
                  and then IR.Destination_Of (Unit, 2, 1).Slot = 1,
            "reading the module datum into the first slot");

         --  Module -> immutable local.
         Landin.Testing.Check
           (Item, IR.Op_Of (Unit, 2, 2) = IR.Copy_Array,
            "the immutable binding from a module is another array copy");
         Landin.Testing.Check
           (Item, IR.Source_Of (Unit, 2, 2).Kind = IR.Module_Datum
                  and then IR.Source_Of (Unit, 2, 2).Datum = 1
                  and then IR.Destination_Of (Unit, 2, 2).Kind
                             = IR.Frame_Slot
                  and then IR.Destination_Of (Unit, 2, 2).Slot = 2,
            "reading the module datum into the second slot");

         --  Prior local -> mutable local.
         Landin.Testing.Check
           (Item, IR.Op_Of (Unit, 2, 3) = IR.Copy_Array,
            "the mutable binding from a prior local is a slot-to-slot copy");
         Landin.Testing.Check
           (Item, IR.Source_Of (Unit, 2, 3).Kind = IR.Frame_Slot
                  and then IR.Source_Of (Unit, 2, 3).Slot = 1
                  and then IR.Destination_Of (Unit, 2, 3).Kind
                             = IR.Frame_Slot
                  and then IR.Destination_Of (Unit, 2, 3).Slot = 3,
            "reading slot 1 into slot 3");

         --  Prior local -> immutable local.
         Landin.Testing.Check
           (Item, IR.Op_Of (Unit, 2, 4) = IR.Copy_Array,
            "the immutable binding from a prior local is another copy");
         Landin.Testing.Check
           (Item, IR.Source_Of (Unit, 2, 4).Kind = IR.Frame_Slot
                  and then IR.Source_Of (Unit, 2, 4).Slot = 2
                  and then IR.Destination_Of (Unit, 2, 4).Kind
                             = IR.Frame_Slot
                  and then IR.Destination_Of (Unit, 2, 4).Slot = 4,
            "reading slot 2 into slot 4");

         --  The earlier explicitly typed forms remain the same Copy_Array.
         Landin.Testing.Check
           (Item, IR.Op_Of (Unit, 2, 5) = IR.Copy_Array
                  and then IR.Op_Of (Unit, 2, 6) = IR.Copy_Array,
            "typed mutable and immutable bindings remain array copies");
         Landin.Testing.Check
           (Item, IR.Source_Of (Unit, 2, 5).Kind = IR.Module_Datum
                  and then IR.Destination_Of (Unit, 2, 5).Kind = IR.Frame_Slot
                  and then IR.Destination_Of (Unit, 2, 5).Slot = 5
                  and then IR.Source_Of (Unit, 2, 6).Kind = IR.Module_Datum
                  and then IR.Destination_Of (Unit, 2, 6).Kind = IR.Frame_Slot
                  and then IR.Destination_Of (Unit, 2, 6).Slot = 6,
            "typed destinations keep their own compact storage");
      end;
   end A_Local_Array_Initializer_Becomes_A_Copy;

   --  D23 lowers a finite source run directly into the one compact local
   --  array slot, keeping each expression immediately before its store.
   procedure A_Local_Array_Literal_Becomes_Ordered_Stores
     (Item : in out Landin.Testing.Context);

   procedure A_Local_Array_Literal_Becomes_Ordered_Stores
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: () -> none =" & LF
         & "    row: [3]u32 = [7, 8, 9]" & LF
         & "end f" & LF,
         Ran);

      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work), "the literal is accepted");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
      begin
         Landin.Testing.Check_Equal
           (Item, IR.Slot_Count (Unit, 1), 1,
            "the literal owns one compact array slot");
         Landin.Testing.Check_Equal
           (Item, IR.Value_Count (Unit, 1), 7,
            "three number-store pairs precede the return");

         for Position in 1 .. 3 loop
            declare
               Number : constant IR.Value_Id := IR.Value_Id (2 * Position - 1);
               Store  : constant IR.Value_Id := IR.Value_Id (2 * Position);
            begin
               Landin.Testing.Check
                 (Item, IR.Op_Of (Unit, 1, Number) = IR.Number,
                  "the element is lowered before its store");
               Landin.Testing.Check_Equal
                 (Item, Natural (IR.Number_Of (Unit, 1, Number)),
                  Position + 6, "the source element keeps its value");
               Landin.Testing.Check
                 (Item, IR.Op_Of (Unit, 1, Store) = IR.Store_Field
                        and then IR.Reaches_A_Slot (Unit, 1, Store)
                        and then IR.Slot_Of (Unit, 1, Store) = 1
                        and then IR.Field_Of (Unit, 1, Store)
                                   = IR.Part_Position (Position)
                        and then IR.Nth_Operand (Unit, 1, Store, 1) = Number,
                  "the value is stored at its own one-based position");
            end;
         end loop;
      end;
   end A_Local_Array_Literal_Becomes_Ordered_Stores;

   --  D29 forms a contextual assignment literal directly in its destination,
   --  preserving one expression-store pair per source element for both local
   --  and module storage rather than introducing a hidden array temporary.
   procedure An_Array_Literal_Assignment_Becomes_Ordered_Stores
     (Item : in out Landin.Testing.Context);

   procedure An_Array_Literal_Assignment_Becomes_Ordered_Stores
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "mut state: [2]u32" & LF
         & "f: () -> none =" & LF
         & "    mut row: [2]u32" & LF
         & "    row = [7, 8]" & LF
         & "    state = [9, 10]" & LF
         & "end f" & LF,
         Ran);

      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "both assignment literals are accepted");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
      begin
         Landin.Testing.Check_Equal
           (Item, IR.Slot_Count (Unit, 2), 1,
            "the local destination remains the only frame cell");
         Landin.Testing.Check_Equal
           (Item, IR.Value_Count (Unit, 2), 9,
            "four number-store pairs precede the return");

         for Position in 1 .. 4 loop
            declare
               Number : constant IR.Value_Id := IR.Value_Id (2 * Position - 1);
               Store  : constant IR.Value_Id := IR.Value_Id (2 * Position);
               Part   : constant IR.Part_Position :=
                 IR.Part_Position (((Position - 1) mod 2) + 1);
            begin
               Landin.Testing.Check
                 (Item, IR.Op_Of (Unit, 2, Number) = IR.Number
                        and then IR.Op_Of (Unit, 2, Store) = IR.Store_Field
                        and then IR.Field_Of (Unit, 2, Store) = Part
                        and then IR.Nth_Operand (Unit, 2, Store, 1) = Number,
                  "each source value is immediately stored in its position");

               if Position <= 2 then
                  Landin.Testing.Check
                    (Item, IR.Reaches_A_Slot (Unit, 2, Store)
                           and then IR.Slot_Of (Unit, 2, Store) = 1,
                     "the first literal writes the local array slot");
               else
                  Landin.Testing.Check
                    (Item, not IR.Reaches_A_Slot (Unit, 2, Store)
                           and then IR.Datum_Of (Unit, 2, Store) = 1,
                     "the second literal writes the module array datum");
               end if;
            end;
         end loop;
      end;
   end An_Array_Literal_Assignment_Becomes_Ordered_Stores;

   --  D28 clears a complete local array with one storage operation rather
   --  than one instruction per element of its target-sized extent.
   procedure A_Local_Zeroed_Array_Becomes_One_Clear
     (Item : in out Landin.Testing.Context);

   procedure A_Local_Zeroed_Array_Becomes_One_Clear
     (Item : in out Landin.Testing.Context)
   is
      use type IR.Storage_Kind;

      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: () -> none =" & LF
         & "    row: [3]u32 = zeroed" & LF
         & "end f" & LF,
         Ran);

      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work), "zeroed is accepted locally");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
      begin
         Landin.Testing.Check_Equal
           (Item, IR.Value_Count (Unit, 1), 2,
            "one clear and the leave are the complete instruction run");
         Landin.Testing.Check
           (Item, IR.Op_Of (Unit, 1, 1) = IR.Clear_Array
                  and then IR.Destination_Of (Unit, 1, 1).Kind
                             = IR.Frame_Slot
                  and then IR.Destination_Of (Unit, 1, 1).Slot = 1,
            "the clear names the one compact array slot");
      end;
   end A_Local_Zeroed_Array_Becomes_One_Clear;

   --  D30 lowers assignment to local and module arrays through the same
   --  destination-only Clear_Array operation D28 introduced.
   procedure Zeroed_Assignment_Clears_Either_Storage_Kind
     (Item : in out Landin.Testing.Context);

   procedure Zeroed_Assignment_Clears_Either_Storage_Kind
     (Item : in out Landin.Testing.Context)
   is
      use type IR.Storage_Kind;

      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "mut state: [2]u32" & LF
         & "f: () -> none =" & LF
         & "    mut row: [3]u16" & LF
         & "    row = zeroed" & LF
         & "    state = zeroed" & LF
         & "end f" & LF,
         Ran);

      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "both zeroed assignments are accepted");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
      begin
         Landin.Testing.Check_Equal
           (Item, IR.Value_Count (Unit, 2), 3,
            "two clears and the leave are the complete instruction run");
         Landin.Testing.Check
           (Item, IR.Op_Of (Unit, 2, 1) = IR.Clear_Array
                  and then IR.Destination_Of (Unit, 2, 1).Kind
                             = IR.Frame_Slot
                  and then IR.Destination_Of (Unit, 2, 1).Slot = 1,
            "the first clear names the local frame slot");
         Landin.Testing.Check
           (Item, IR.Op_Of (Unit, 2, 2) = IR.Clear_Array
                  and then IR.Destination_Of (Unit, 2, 2).Kind
                             = IR.Module_Datum
                  and then IR.Destination_Of (Unit, 2, 2).Datum = 1,
            "the second clear names the module datum");
      end;
   end Zeroed_Assignment_Clears_Either_Storage_Kind;

   ------------------------------------------------------------------

   --  D24: a module array literal folds each element to a Folded value
   --  and records the source-order image against the datum item, so a
   --  target loader can consume it byte for byte.  A datum with no image
   --  is D10 zero and stays reserved storage; D27's explicit `zeroed`
   --  initializer deliberately has that same absent image.
   procedure A_Module_Array_Literal_Records_Its_Image
     (Item : in out Landin.Testing.Context);

   procedure A_Module_Array_Literal_Records_Its_Image
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "mut numbers: [4]u32 = [10, 20 + 1, base, base + 100]" & LF
         & "base: u32 = 100" & LF
         & "mut reserved: [2]u16" & LF
         & "mut cleared: [3]bool = zeroed" & LF,
         Ran);

      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "the module literal is accepted");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
      begin
         Landin.Testing.Check
           (Item, IR.Has_Image (Unit, 1),
            "the literal-initialized module array records an image");
         Landin.Testing.Check_Equal
           (Item, Natural (IR.Image_Length (Unit, 1)), 4,
            "one folded value per source-order position");
         Landin.Testing.Check_Equal
           (Item, Integer (IR.Nth_Image (Unit, 1, 1)),
            Integer'(10), "position one is the first literal");
         Landin.Testing.Check_Equal
           (Item, Integer (IR.Nth_Image (Unit, 1, 2)),
            Integer'(21), "position two folds the sum");
         Landin.Testing.Check_Equal
           (Item, Integer (IR.Nth_Image (Unit, 1, 3)),
            Integer'(100),
            "position three reaches a forward module scalar reference");
         Landin.Testing.Check_Equal
           (Item, Integer (IR.Nth_Image (Unit, 1, 4)),
            Integer'(200), "position four folds the same reference");

         Landin.Testing.Check
           (Item, not IR.Has_Image (Unit, 3),
            "an omitted-initializer array datum has no image and stays"
            & " zero storage");
         Landin.Testing.Check
           (Item, not IR.Has_Image (Unit, 4),
            "an explicitly zeroed array datum also keeps its image absent");
      end;
   end A_Module_Array_Literal_Records_Its_Image;

   --  D24 also settles D21's chain: a destination initialized from a
   --  direct module storage name copies its terminal image, and the two
   --  storage places remain distinct.  A chain that terminates at D10
   --  zero keeps every destination without an image.
   procedure A_Module_Array_Chain_Copies_The_Terminal_Image
     (Item : in out Landin.Testing.Context);

   procedure A_Module_Array_Chain_Copies_The_Terminal_Image
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "mut typed: [3]u32 = literal" & LF
         & "mut inferred := typed" & LF
         & "mut literal: [3]u32 = [7, 8, 9]" & LF
         & "mut zero_typed: [2]u16 = zero_source" & LF
         & "mut zero_source: [2]u16" & LF,
         Ran);

      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "the chain is accepted");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
      begin
         for Datum in IR.Item_Id range 1 .. 3 loop
            Landin.Testing.Check
              (Item, IR.Has_Image (Unit, Datum),
               "every destination on the chain has its own image");
            Landin.Testing.Check_Equal
              (Item, Natural (IR.Image_Length (Unit, Datum)), 3,
               "and its length equals the source length");
            Landin.Testing.Check_Equal
              (Item, Integer (IR.Nth_Image (Unit, Datum, 1)),
               Integer'(7), "first element carried");
            Landin.Testing.Check_Equal
              (Item, Integer (IR.Nth_Image (Unit, Datum, 2)),
               Integer'(8), "second element carried");
            Landin.Testing.Check_Equal
              (Item, Integer (IR.Nth_Image (Unit, Datum, 3)),
               Integer'(9), "third element carried");
         end loop;

         Landin.Testing.Check
           (Item, not IR.Has_Image (Unit, 4)
                    and then not IR.Has_Image (Unit, 5),
            "a chain terminating at D10 zero leaves both without an image");
      end;
   end A_Module_Array_Chain_Copies_The_Terminal_Image;

   --  D34: a repetition folds one scalar and carries that one pattern through
   --  direct-name chains, regardless of the target-sized declared extent.  A
   --  zero pattern remains the absent image used for loader-zeroed storage.
   procedure Module_Repetition_Images_Stay_Compact
     (Item : in out Landin.Testing.Context);

   procedure Module_Repetition_Images_Stay_Compact
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "mut through: [4294967295]u8 = huge" & LF
         & "mut huge: [4294967295]u8 = [of base + 5]" & LF
         & "base: u8 = 160" & LF
         & "mut wide: [2]u64 = [2 of 0x123456789ABCDEF0]" & LF
         & "mut zero: [3]u32 = [of 0]" & LF,
         Ran);

      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "module repetitions and their through chain are accepted");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
      begin
         for Datum in IR.Item_Id range 1 .. 2 loop
            Landin.Testing.Check
              (Item, IR.Is_Repeated_Image (Unit, Datum),
               "the huge source and destination carry a repetition image");
            Landin.Testing.Check
              (Item,
               IR."="
                 (IR.Image_Length (Unit, Datum),
                  IR.Element_Total'(4_294_967_295))
               and then Landin.Types."="
                 (IR.Repeated_Image_Value (Unit, Datum), 165),
               "the chain keeps one folded pattern and the complete extent");
         end loop;

         Landin.Testing.Check
           (Item,
            IR.Is_Repeated_Image (Unit, 4)
            and then Landin.Types."="
              (IR.Repeated_Image_Value (Unit, 4),
               Landin.Types.Folded'(16#1234_5678_9ABC_DEF0#)),
            "all eight bytes of a wide repeated pattern survive lowering");
         Landin.Testing.Check
           (Item, not IR.Has_Image (Unit, 5),
            "a zero-pattern repetition remains an absent image");
      end;
   end Module_Repetition_Images_Stay_Compact;

   --  D35 reuses D34's compact module image after the count and scalar have
   --  supplied an inferred shape, including through chains and zero patterns.
   procedure Inferred_Module_Repetition_Images_Stay_Compact
     (Item : in out Landin.Testing.Context);

   procedure Inferred_Module_Repetition_Images_Stay_Compact
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "seed: u8 = 160" & LF
         & "mut inferred := [4294967295 of seed + 5]" & LF
         & "mut through: [4294967295]u8 = inferred" & LF
         & "wide_pattern: u64 = 0x123456789ABCDEF0" & LF
         & "mut wide := [2 of wide_pattern]" & LF
         & "mut zero := [3 of 0]" & LF,
         Ran);

      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "inferred module repetitions and their through chain are accepted");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
      begin
         for Datum in IR.Item_Id range 2 .. 3 loop
            Landin.Testing.Check
              (Item,
               IR.Is_Repeated_Image (Unit, Datum)
               and then IR."="
                 (IR.Image_Length (Unit, Datum),
                  IR.Element_Total'(4_294_967_295))
               and then Landin.Types."="
                 (IR.Repeated_Image_Value (Unit, Datum), 165),
               "the inferred source and chain keep one pattern"
               & " and the extent");
         end loop;

         Landin.Testing.Check
           (Item,
            IR.Is_Repeated_Image (Unit, 5)
            and then Landin.Types."="
              (IR.Repeated_Image_Value (Unit, 5),
               Landin.Types.Folded'(16#1234_5678_9ABC_DEF0#)),
            "an inferred wide pattern keeps all eight bytes");
         Landin.Testing.Check
           (Item, not IR.Has_Image (Unit, 6),
            "an inferred zero pattern remains an absent image");
      end;
   end Inferred_Module_Repetition_Images_Stay_Compact;

   ------------------------------------------------------------------

   procedure A_Logical_Module_Value_Becomes_Blocks
     (Item : in out Landin.Testing.Context);

   procedure A_Logical_Module_Value_Becomes_Blocks
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      --  [1940] admits an operator of [1820] over literals, and [0410]
      --  makes the logical words short-circuit, so a module value can
      --  contain the one construct Landin.IR has no opcode for.  It gets
      --  the same blocks a body would: the alternative was a second
      --  constant folder beside the checker's, over the whole operator
      --  set including the widths, and two authorities on one question is
      --  what this compiler refuses everywhere else.
      Lower (Work, "k: bool = true and false" & LF, Ran);

      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work), "the program is accepted");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Branches : Natural := 0;
      begin
         Landin.Testing.Check
           (Item, IR.Block_Count (Unit, 1) = 3,
            "the short circuit gave the datum its blocks");

         for V in 1 .. IR.Value_Count (Unit, 1) loop
            if IR.Op_Of (Unit, 1, IR.Value_Id (V)) = IR.Branch then
               Branches := Branches + 1;
            end if;
         end loop;

         Landin.Testing.Check_Equal
           (Item, Branches, 1, "one branch");

         Check_Terminators (Item, Unit, "a logical module value");
      end;
   end A_Logical_Module_Value_Becomes_Blocks;

   ------------------------------------------------------------------
   --  A computed destination is evaluated in source order
   ------------------------------------------------------------------

   procedure A_Computed_Destination_Precedes_Its_Value
     (Item : in out Landin.Testing.Context);

   procedure A_Computed_Destination_Precedes_Its_Value
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "mut flags: [4]bool" & LF
         & "index: () -> (r: usize) = r = 0 end index" & LF
         & "left: () -> (r: bool) = r = true end left" & LF
         & "right: () -> (r: bool) = r = false end right" & LF
         & "set: () -> none =" & LF
         & "    flags[index()] = left() and right()" & LF
         & "end set" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Setter : constant IR.Item_Id := 5;
         First, Second, Third : IR.Value_Id := IR.No_Value;
      begin
         for V in 1 .. IR.Value_Count (Unit, Setter) loop
            declare
               Value : constant IR.Value_Id := IR.Value_Id (V);
            begin
               if IR.Op_Of (Unit, Setter, Value) = IR.Call then
                  if First = IR.No_Value then
                     First := Value;
                  elsif Second = IR.No_Value then
                     Second := Value;
                  else
                     Third := Value;
                  end if;
               end if;
            end;
         end loop;

         Landin.Testing.Check
           (Item,
            First /= IR.No_Value and then Second /= IR.No_Value
            and then Third /= IR.No_Value
            and then IR.Callee_Of (Unit, Setter, First) = 2
            and then IR.Callee_Of (Unit, Setter, Second) = 3
            and then IR.Callee_Of (Unit, Setter, Third) = 4
            and then First < Second and then Second < Third,
            "the destination index call precedes both right-hand-side calls");
         Landin.Testing.Check
           (Item,
            Landin.IR.Verifier.Check (Unit).Kind
              = Landin.IR.Verifier.Nothing_Wrong,
            "the saved destination index remains local to the final block");
         Check_Terminators (Item, Unit, "a computed destination");
      end;
   end A_Computed_Destination_Precedes_Its_Value;

   --  An increment reads and writes one source place.  The index expression
   --  is therefore lowered once and the same value names both element
   --  instructions rather than evaluating the place a second time.
   procedure An_Element_Update_Evaluates_Its_Index_Once
     (Item : in out Landin.Testing.Context);

   procedure An_Element_Update_Evaluates_Its_Index_Once
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "mut words: [4]u32" & LF
         & "bump: (i: usize) -> none = inc words[i] end bump" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Bump : constant IR.Item_Id := 2;
         Index, Loaded, Stored : IR.Value_Id := IR.No_Value;
         Index_Loads, Element_Loads, Element_Stores : Natural := 0;
      begin
         for V in 1 .. IR.Value_Count (Unit, Bump) loop
            declare
               Value : constant IR.Value_Id := IR.Value_Id (V);
               Op : constant IR.Opcode := IR.Op_Of (Unit, Bump, Value);
            begin
               case Op is
                  when IR.Load =>
                     Index_Loads := Index_Loads + 1;
                     Index := Value;
                  when IR.Load_Element =>
                     Element_Loads := Element_Loads + 1;
                     Loaded := Value;
                  when IR.Store_Element =>
                     Element_Stores := Element_Stores + 1;
                     Stored := Value;
                  when others =>
                     null;
               end case;
            end;
         end loop;

         Landin.Testing.Check
           (Item,
            Index_Loads = 1 and then Element_Loads = 1
            and then Element_Stores = 1,
            "one index load feeds one element load and one element store");
         Landin.Testing.Check
           (Item,
            Index /= IR.No_Value and then Loaded /= IR.No_Value
            and then Stored /= IR.No_Value
            and then IR.Nth_Operand (Unit, Bump, Loaded, 1) = Index
            and then IR.Nth_Operand (Unit, Bump, Stored, 1) = Index
            and then Index < Loaded and then Loaded < Stored,
            "the update reuses its one evaluated index in source order");
         Check_Terminators (Item, Unit, "an element update");
      end;
   end An_Element_Update_Evaluates_Its_Index_Once;

   ------------------------------------------------------------------
   --  D22: a computed local array element reaches its frame slot
   ------------------------------------------------------------------

   procedure A_Computed_Local_Element_Reaches_Its_Slot
     (Item : in out Landin.Testing.Context);

   procedure A_Computed_Local_Element_Reaches_Its_Slot
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "source: [4]u32" & LF
         & "f: (at: usize, value: u32) -> (r: u32) =" & LF
         & "    mut words: [4]u32" & LF
         & "    words = source" & LF
         & "    words[at] = value" & LF
         & "    r = words[at]" & LF
         & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "D22 accepts the computed local read after a whole copy");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         F : constant IR.Item_Id := 2;
         Loads, Stores : Natural := 0;
         All_Slot : Boolean := True;
      begin
         for V in 1 .. IR.Value_Count (Unit, F) loop
            declare
               Value : constant IR.Value_Id := IR.Value_Id (V);
               Op : constant IR.Opcode := IR.Op_Of (Unit, F, Value);
            begin
               if Op = IR.Load_Element then
                  Loads := Loads + 1;
                  if not IR.Reaches_A_Slot (Unit, F, Value) then
                     All_Slot := False;
                  end if;
               elsif Op = IR.Store_Element then
                  Stores := Stores + 1;
                  if not IR.Reaches_A_Slot (Unit, F, Value) then
                     All_Slot := False;
                  end if;
               end if;
            end;
         end loop;

         Landin.Testing.Check_Equal
           (Item, Loads, 1,
            "the computed local read becomes one element load");
         Landin.Testing.Check_Equal
           (Item, Stores, 1,
            "the computed local write becomes one element store");
         Landin.Testing.Check
           (Item, All_Slot,
            "every element operation on a local reaches its own frame slot");
         Landin.Testing.Check
           (Item,
            Landin.IR.Verifier.Check (Unit).Kind
              = Landin.IR.Verifier.Nothing_Wrong,
            "the verifier accepts a slot-reaching element operation");
         Check_Terminators
           (Item, Unit, "a computed local element");
      end;
   end A_Computed_Local_Element_Reaches_Its_Slot;

   ------------------------------------------------------------------
   --  An internal array shape the source does not pin
   ------------------------------------------------------------------

   --  D17's checked table represents a zero-element shape, while source
   --  legality for `[0]T` remains deliberately undecided.  Start from source
   --  the frontend accepts, then use that public table seam to ask lowering
   --  the internal question without making `[0]T` a corpus fixture.
   procedure An_Internal_Empty_Array_Has_Identity_Measurements
     (Item : in out Landin.Testing.Context);

   procedure An_Internal_Empty_Array_Has_Identity_Measurements
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Front : Landin.Stages.Pipeline;
      Back  : Landin.Stages.Pipeline;
      Src   : constant Landin.Source.Source_Id :=
        Landin.Stages.Add_Source
          (Work, "empty-measurement.ldn",
           "array_align: usize = alignof [2]u16" & LF
           & "array_size: usize = sizeof [2]u16" & LF);
      Ran : Natural;
   begin
      Landin.Stages.Append (Front, Frontend'Access);
      Landin.Stages.Append (Front, Names'Access);
      Landin.Stages.Append (Front, Checker'Access);
      Ran := Landin.Stages.Run (Front, Work);

      Landin.Testing.Check_Equal (Item, Ran, 3, "three stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "the nonempty source measurements are accepted");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
         Align_Type : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Measured_Type
             (Of_Tree.all,
              Landin.Syntax.Value_Of
                (Of_Tree.all,
                 Landin.Syntax.Nth_Declaration (Of_Tree.all, 1)));
         Size_Type : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Measured_Type
             (Of_Tree.all,
              Landin.Syntax.Value_Of
                (Of_Tree.all,
                 Landin.Syntax.Nth_Declaration (Of_Tree.all, 2)));
      begin
         Landin.Checking.Note_Array
           (Types.all, Of_Tree.all, Align_Type, 0,
            Landin.Checking.Array_Element
              (Types.all, Of_Tree.all, Align_Type));
         Landin.Checking.Note_Array
           (Types.all, Of_Tree.all, Size_Type, 0,
            Landin.Checking.Array_Element
              (Types.all, Of_Tree.all, Size_Type));
      end;

      Landin.Stages.Append (Back, Lowerer'Access);
      Ran := Landin.Stages.Run (Back, Work);
      Landin.Testing.Check_Equal (Item, Ran, 1, "lowering ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "the internal empty shapes are lowered");

      declare
         Unit  : IR.Unit renames Landin.Stages.Code (Work).all;
         Align : constant IR.Item_Id := 1;
         Size  : constant IR.Item_Id := 2;
      begin
         Landin.Testing.Check
           (Item, IR.Result_Of (Unit, Align) = Landin.Types.Usize,
            "empty-array alignment remains usize");
         Landin.Testing.Check
           (Item, IR.Value_Count (Unit, Align) = 2
                  and then IR.Op_Of (Unit, Align, 1) = IR.Number
                  and then IR.Number_Of (Unit, Align, 1) = 1,
            "empty-array alignment is Number usize one with no measurement");
         Landin.Testing.Check
           (Item, IR.Result_Of (Unit, Size) = Landin.Types.Usize,
            "empty-array size remains usize");
         Landin.Testing.Check
           (Item, IR.Value_Count (Unit, Size) = 4
                  and then IR.Op_Of (Unit, Size, 1) = IR.Measure_Size
                  and then IR.Op_Of (Unit, Size, 2) = IR.Number
                  and then IR.Number_Of (Unit, Size, 2) = 0
                  and then IR.Op_Of (Unit, Size, 3) = IR.Multiply,
            "empty-array size multiplies its element measurement by zero");
      end;
   end An_Internal_Empty_Array_Has_Identity_Measurements;

   ------------------------------------------------------------------
   --  The recorded artefact
   ------------------------------------------------------------------

   --  Every positive fixture, lowered and rendered, in the order
   --  Discover returns them -- which is by class then by name, over a
   --  List_Directory that sorts, so two hosts agree.
   --
   --  This reads the repository's real fixture tree through the real
   --  filesystem, which is a deliberate exception to the rule that every
   --  stage case runs against a fake: a recorded expectation about the
   --  corpus cannot be recorded against an invented one.  The same
   --  exception `Landin.Tests.Fixture_Execution_Suite` already names.
   Fixture_Root : constant String := "../tests/fixtures";

   function Corpus_Text
     (Host : Landin.Platform.Filesystem'Class) return String;

   function Corpus_Text
     (Host : Landin.Platform.Filesystem'Class) return String
   is
      package Unbounded renames Ada.Strings.Unbounded;
      package Fixtures renames Landin.Testing.Fixtures;

      Found : Fixtures.Catalogue;
      Text  : Unbounded.Unbounded_String;
   begin
      Fixtures.Discover (Found, Fixture_Root, Host);

      Unbounded.Append
        (Text,
         "# Generated by landin_tests --record.  Do not edit." & LF
         & "# Every positive fixture, lowered to Landin.IR and rendered"
         & " by Landin.IR.Dump." & LF
         & "# Target: linux-x86-64.  Not a stable interface; see"
         & " landin-ir-dump.ads." & LF);

      for Index in 1 .. Fixtures.Count (Found) loop
         declare
            Each : constant Fixtures.Fixture := Fixtures.Nth (Found, Index);
         begin
            if Fixtures.Class (Each) = Fixtures.Positive_Program
              and then Fixtures.Program (Each) /= ""
            then
               declare
                  Where : constant String :=
                    Fixture_Root & "/positive/" & Fixtures.Name (Each)
                    & "/" & Fixtures.Program (Each);
                  Body_Text : Unbounded.Unbounded_String;
                  Status : Landin.Platform.Read_Status;
               begin
                  Host.Read_File (Where, Body_Text, Status);

                  if Status = Landin.Platform.Read_Ok then
                     declare
                        Work : Landin.Stages.Compilation :=
                          Landin.Stages.Create
                            (Landin.Targets.Linux_X86_64);
                        Ran : Natural;
                     begin
                        Lower
                          (Work, Unbounded.To_String (Body_Text), Ran);

                        if not Landin.Stages.Failed (Work) then
                           Unbounded.Append
                             (Text,
                              "file positive/" & Fixtures.Name (Each)
                              & "/" & Fixtures.Program (Each) & LF);
                           Unbounded.Append
                             (Text,
                              Landin.IR.Dump.Text
                                (Landin.Stages.Code (Work).all,
                                 Landin.Stages.Meanings (Work).all,
                                 Landin.Stages.Identities (Work).all));
                        end if;
                     end;
                  end if;
               end;
            end if;
         end;
      end loop;

      return Unbounded.To_String (Text);
   end Corpus_Text;

   procedure Record_Artefact (Path : String; Wrote : out Boolean) is
      Host   : Landin.Platform.Native.Native_Filesystem;
      Status : Landin.Platform.Write_Status;
   begin
      --  Through Write_File, which is byte exact.  Ada.Text_IO.Put would
      --  append a second line feed at close, which a golden would carry
      --  for ever.
      Host.Write_File (Path, Corpus_Text (Host), Status);
      Wrote := Status = Landin.Platform.Write_Ok;
   end Record_Artefact;

   procedure The_Recorded_Corpus_Is_Current
     (Item : in out Landin.Testing.Context);

   procedure The_Recorded_Corpus_Is_Current
     (Item : in out Landin.Testing.Context)
   is
      package Unbounded renames Ada.Strings.Unbounded;
      Host     : Landin.Platform.Native.Native_Filesystem;
      Recorded : Unbounded.Unbounded_String;
      Status   : Landin.Platform.Read_Status;
      Path     : constant String := "../tests/lowering.ir";
   begin
      Host.Read_File (Path, Recorded, Status);

      if Status /= Landin.Platform.Read_Ok then
         Landin.Testing.Fail
           (Item,
            "the recorded IR is missing; regenerate it with"
            & " ./scripts/test.sh --record");
         return;
      end if;

      Landin.Testing.Check
        (Item, Unbounded.To_String (Recorded) = Corpus_Text (Host),
         "the recorded IR is what the lowering produces now"
         & " (regenerate with ./scripts/test.sh --record)");
   end The_Recorded_Corpus_Is_Current;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "lowering", "a function becomes one routine",
         A_Function_Becomes_One_Routine'Access);
      Landin.Testing.Register
        (Into, "lowering", "a branch becomes blocks",
         A_Branch_Becomes_Blocks'Access);
      Landin.Testing.Register
        (Into, "lowering", "a short circuit crosses a merge in a slot",
         A_Short_Circuit_Crosses_A_Merge_Through_A_Slot'Access);
      Landin.Testing.Register
        (Into, "lowering", "a refused program is not lowered",
         A_Refused_Program_Is_Not_Lowered'Access);
      Landin.Testing.Register
        (Into, "lowering", "a call carries its arguments",
         A_Call_Carries_Its_Arguments'Access);
      Landin.Testing.Register
        (Into, "lowering",
         "a call carries an earlier argument across a short circuit",
         A_Call_Carries_An_Earlier_Argument_Across_A_Short_Circuit'Access);
      Landin.Testing.Register
        (Into, "lowering",
         "a binary carries its left across a short circuit",
         A_Binary_Carries_Its_Left_Across_A_Short_Circuit'Access);
      Landin.Testing.Register
        (Into, "lowering", "a module value becomes a datum",
         A_Module_Value_Becomes_A_Datum'Access);
      Landin.Testing.Register
        (Into, "lowering", "module array images keep distinct datums",
         Module_Array_Images_Keep_Distinct_Datums'Access);
      Landin.Testing.Register
        (Into, "lowering", "a logical module value becomes blocks",
         A_Logical_Module_Value_Becomes_Blocks'Access);
      Landin.Testing.Register
        (Into, "lowering", "a struct state carries its fields",
         A_Struct_State_Carries_Its_Fields'Access);
      Landin.Testing.Register
        (Into, "lowering", "a struct copy becomes its fields",
         A_Struct_Copy_Becomes_Its_Fields'Access);
      Landin.Testing.Register
        (Into, "lowering", "a local array initializer becomes a copy",
         A_Local_Array_Initializer_Becomes_A_Copy'Access);
      Landin.Testing.Register
        (Into, "lowering", "a local array literal becomes ordered stores",
         A_Local_Array_Literal_Becomes_Ordered_Stores'Access);
      Landin.Testing.Register
        (Into, "lowering",
         "an array literal assignment becomes ordered stores",
         An_Array_Literal_Assignment_Becomes_Ordered_Stores'Access);
      Landin.Testing.Register
        (Into, "lowering", "a local zeroed array becomes one clear",
         A_Local_Zeroed_Array_Becomes_One_Clear'Access);
      Landin.Testing.Register
        (Into, "lowering", "zeroed assignment clears either storage kind",
         Zeroed_Assignment_Clears_Either_Storage_Kind'Access);
      Landin.Testing.Register
        (Into, "lowering", "a module array literal records its image",
         A_Module_Array_Literal_Records_Its_Image'Access);
      Landin.Testing.Register
        (Into, "lowering",
         "a module array chain copies the terminal image",
         A_Module_Array_Chain_Copies_The_Terminal_Image'Access);
      Landin.Testing.Register
        (Into, "lowering", "module repetition images stay compact",
         Module_Repetition_Images_Stay_Compact'Access);
      Landin.Testing.Register
        (Into, "lowering", "inferred module repetitions stay compact",
         Inferred_Module_Repetition_Images_Stay_Compact'Access);
      Landin.Testing.Register
        (Into, "lowering", "a computed destination precedes its value",
         A_Computed_Destination_Precedes_Its_Value'Access);
      Landin.Testing.Register
        (Into, "lowering", "an element update evaluates its index once",
         An_Element_Update_Evaluates_Its_Index_Once'Access);
      Landin.Testing.Register
        (Into, "lowering",
         "a computed local element reaches its slot",
         A_Computed_Local_Element_Reaches_Its_Slot'Access);
      Landin.Testing.Register
        (Into, "lowering",
         "an internal empty array has identity measurements",
         An_Internal_Empty_Array_Has_Identity_Measurements'Access);
      Landin.Testing.Register
        (Into, "lowering", "the recorded corpus is current",
         The_Recorded_Corpus_Is_Current'Access);
   end Register;

end Landin.Tests.Lowering_Suite;
