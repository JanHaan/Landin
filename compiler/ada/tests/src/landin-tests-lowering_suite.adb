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

with Landin.IR;
with Landin.IR.Dump;
with Landin.Platform;
with Landin.Platform.Native;
with Landin.Testing.Fixtures;
with Landin.Source;
with Landin.Stages.Checking;
with Landin.Stages.Lowering;
with Landin.Stages.Resolution;
with Landin.Stages.Syntax;
with Landin.Targets;
with Landin.Types;

package body Landin.Tests.Lowering_Suite is

   package IR renames Landin.IR;

   use type IR.Block_Id;
   use type IR.Item_Kind;
   use type Landin.Platform.Read_Status;
   use type Landin.Platform.Write_Status;
   use type Landin.Testing.Fixtures.Fixture_Class;
   use type IR.Opcode;
   use type IR.Slot_Id;
   use type IR.Part_Position;
   use type IR.Value_Id;
   use type Landin.Source.Source_Id;
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
        (Into, "lowering", "a logical module value becomes blocks",
         A_Logical_Module_Value_Becomes_Blocks'Access);
      Landin.Testing.Register
        (Into, "lowering", "a struct state carries its fields",
         A_Struct_State_Carries_Its_Fields'Access);
      Landin.Testing.Register
        (Into, "lowering", "a struct copy becomes its fields",
         A_Struct_Copy_Becomes_Its_Fields'Access);
      Landin.Testing.Register
        (Into, "lowering", "the recorded corpus is current",
         The_Recorded_Corpus_Is_Current'Access);
   end Register;

end Landin.Tests.Lowering_Suite;
