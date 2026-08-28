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

   use type IR.Field_Shape;
   use type IR.Field_Shape_Kind;
   use type IR.Field_Image_Form;

   use type IR.Block_Id;
   use type IR.Element_Total;
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
   use type Landin.Types.Folded;
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

   --  D39 lowers contextual scalar `zeroed` through D10's existing scalar
   --  zero operations, so no new IR value form or runtime initialization is
   --  introduced.  The alias has already settled to its scalar here.
   procedure A_Zeroed_Module_Scalar_Reuses_The_Zero_IR
     (Item : in out Landin.Testing.Context);

   procedure A_Zeroed_Module_Scalar_Reuses_The_Zero_IR
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "word: type = u32" & LF
         & "number: word = zeroed" & LF
         & "flag: bool = zeroed" & LF,
         Ran);

      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "typed scalar zeroed initializers lower");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
      begin
         Landin.Testing.Check
           (Item, IR.Op_Of (Unit, 1, 1) = IR.Number
                  and then IR.Number_Of (Unit, 1, 1) = 0,
            "the integer initializer is D10's zero number");
         Landin.Testing.Check
           (Item, IR.Op_Of (Unit, 2, 1) = IR.Truth
                  and then not IR.Truth_Of (Unit, 2, 1),
            "the bool initializer is D10's false truth");
         Check_Terminators (Item, Unit, "two zeroed scalar datums");
      end;
   end A_Zeroed_Module_Scalar_Reuses_The_Zero_IR;

   --  D40 uses the existing scalar constant/store path for a local: integers
   --  become zero Numbers, bool becomes false Truth, and each is stored in its
   --  ordinary frame slot.  The alias is settled before lowering.
   procedure Local_Scalar_Zeroed_Uses_The_Constant_Store_Path
     (Item : in out Landin.Testing.Context);

   procedure Local_Scalar_Zeroed_Uses_The_Constant_Store_Path
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "word: type = u32" & LF
         & "f: () -> (result: u32) =" & LF
         & "    number: word = zeroed" & LF
         & "    flag: bool = zeroed" & LF
         & "    if flag then" & LF
         & "        result = 1" & LF
         & "    else" & LF
         & "        result = number" & LF
         & "    end if" & LF
         & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "typed local scalar zeroed initializers lower");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         One  : constant IR.Item_Id := 1;
      begin
         Landin.Testing.Check
           (Item, IR.Op_Of (Unit, One, 1) = IR.Number
                  and then IR.Number_Of (Unit, One, 1) = 0
                  and then IR.Op_Of (Unit, One, 2) = IR.Store,
            "the integer initializer is zero followed by its slot store");
         Landin.Testing.Check
           (Item, IR.Op_Of (Unit, One, 3) = IR.Truth
                  and then not IR.Truth_Of (Unit, One, 3)
                  and then IR.Op_Of (Unit, One, 4) = IR.Store,
            "the bool initializer is false followed by its slot store");
         Check_Terminators (Item, Unit, "local scalar zeroed initializers");
      end;
   end Local_Scalar_Zeroed_Uses_The_Constant_Store_Path;

   --  D41 lowers assignment-context `zeroed` as the existing typed zero or
   --  false constant followed by the destination's ordinary scalar store.
   procedure Scalar_Zeroed_Assignment_Uses_Ordinary_Stores
     (Item : in out Landin.Testing.Context);

   procedure Scalar_Zeroed_Assignment_Uses_Ordinary_Stores
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "word: type = u32" & LF
         & "truth: type = bool" & LF
         & "mut number: word" & LF
         & "f: () -> none =" & LF
         & "    mut flag: truth" & LF
         & "    number = zeroed" & LF
         & "    flag = zeroed" & LF
         & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "scalar zeroed assignments lower");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Routine : constant IR.Item_Id := 2;
      begin
         Landin.Testing.Check
           (Item, IR.Op_Of (Unit, Routine, 1) = IR.Number
                  and then IR.Number_Of (Unit, Routine, 1) = 0
                  and then IR.Op_Of (Unit, Routine, 2) = IR.Store_Datum
                  and then IR.Datum_Of (Unit, Routine, 2) = 1,
            "typed integer zero feeds the ordinary module datum store");
         Landin.Testing.Check
           (Item, IR.Op_Of (Unit, Routine, 3) = IR.Truth
                  and then not IR.Truth_Of (Unit, Routine, 3)
                  and then IR.Op_Of (Unit, Routine, 4) = IR.Store
                  and then IR.Slot_Of (Unit, Routine, 4) = 1,
            "typed false feeds the ordinary local slot store");
         Check_Terminators (Item, Unit, "scalar zeroed assignments");
      end;
   end Scalar_Zeroed_Assignment_Uses_Ordinary_Stores;

   --  D43 lowers named-return `zeroed` through the named return's existing
   --  slot Store path before the ordinary return load and Leave.
   procedure Named_Return_Zeroed_Uses_The_Ordinary_Store
     (Item : in out Landin.Testing.Context);

   procedure Named_Return_Zeroed_Uses_The_Ordinary_Store
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "truth: type = bool" & LF
         & "f: () -> (result: truth) =" & LF
         & "    result = zeroed" & LF
         & "    return" & LF
         & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "named-return zeroed assignment lowers");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         One  : constant IR.Item_Id := 1;
      begin
         Landin.Testing.Check
           (Item, IR.Value_Count (Unit, One) = 4
                  and then IR.Op_Of (Unit, One, 1) = IR.Truth
                  and then not IR.Truth_Of (Unit, One, 1)
                  and then IR.Op_Of (Unit, One, 2) = IR.Store
                  and then IR.Slot_Of (Unit, One, 2)
                    = IR.Result_Slot (Unit, One)
                  and then IR.Op_Of (Unit, One, 3) = IR.Load
                  and then IR.Op_Of (Unit, One, 4) = IR.Leave,
            "false uses the named-return Store path before return");
         Check_Terminators (Item, Unit, "named-return zeroed assignment");
      end;
   end Named_Return_Zeroed_Uses_The_Ordinary_Store;

   --  D42 reuses the ordinary subobject store paths.  D62 reaches the same
   --  Store_Element through a D48 array field and carries its positive field
   --  identity.  The selected scalar type chooses false or zero; a computed
   --  destination index is evaluated once before the contextual RHS is formed.
   procedure Scalar_Subobject_Zeroed_Uses_Ordinary_Stores
     (Item : in out Landin.Testing.Context);

   procedure Scalar_Subobject_Zeroed_Uses_Ordinary_Stores
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "truth: type = bool" & LF
         & "flags: type = struct" & LF
         & "    ready: truth" & LF
         & "end flags" & LF
         & "holder: type = struct" & LF
         & "    flags: [1]truth" & LF
         & "    words: [2]u32" & LF
         & "end holder" & LF
         & "mut state: flags" & LF
         & "mut row: [2]u32" & LF
         & "mut packet: holder" & LF
         & "set: (at: usize) -> none =" & LF
         & "    state.ready = zeroed" & LF
         & "    row[at] = zeroed" & LF
         & "end set" & LF
         & "set_field: () -> none =" & LF
         & "    packet.flags[0] = zeroed" & LF
         & "    packet.words[1] = zeroed" & LF
         & "end set_field" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "scalar subobject zeroed assignments lower");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Set_Routine : constant IR.Item_Id := 4;
         Field_Routine : constant IR.Item_Id := 5;
         Field_Store, Element_Store : IR.Value_Id := IR.No_Value;
         Bool_Field_Element, Integer_Field_Element : IR.Value_Id :=
           IR.No_Value;
         First_Index_Load : IR.Value_Id := IR.No_Value;
         Index_Loads : Natural := 0;
      begin
         for V in 1 .. IR.Value_Count (Unit, Set_Routine) loop
            declare
               Value : constant IR.Value_Id := IR.Value_Id (V);
               Op : constant IR.Opcode :=
                 IR.Op_Of (Unit, Set_Routine, Value);
            begin
               if Op = IR.Store_Field then
                  Field_Store := Value;
               elsif Op = IR.Store_Element then
                  Element_Store := Value;
               elsif Op = IR.Load then
                  Index_Loads := Index_Loads + 1;
                  if First_Index_Load = IR.No_Value then
                     First_Index_Load := Value;
                  end if;
               end if;
            end;
         end loop;

         for V in 1 .. IR.Value_Count (Unit, Field_Routine) loop
            declare
               Value : constant IR.Value_Id := IR.Value_Id (V);
            begin
               if IR.Op_Of (Unit, Field_Routine, Value) = IR.Store_Element
               then
                  case IR.Element_Field_Of (Unit, Field_Routine, Value) is
                     when 1 => Bool_Field_Element := Value;
                     when 2 => Integer_Field_Element := Value;
                     when others => null;
                  end case;
               end if;
            end;
         end loop;

         Landin.Testing.Check
           (Item,
            Field_Store /= IR.No_Value
            and then IR.Op_Of (Unit, Set_Routine, Field_Store - 1) = IR.Truth
            and then not IR.Truth_Of
                           (Unit, Set_Routine, Field_Store - 1)
            and then IR.Nth_Operand
                       (Unit, Set_Routine, Field_Store, 1) = Field_Store - 1,
            "typed false feeds the existing Store_Field path");
         Landin.Testing.Check
           (Item,
            Element_Store /= IR.No_Value
            and then IR.Op_Of
                       (Unit, Set_Routine,
                        IR.Nth_Operand (Unit, Set_Routine, Element_Store, 2))
                     = IR.Number
            and then IR.Number_Of
                       (Unit, Set_Routine,
                        IR.Nth_Operand
                          (Unit, Set_Routine, Element_Store, 2)) = 0,
            "typed integer zero feeds the existing Store_Element path");
         Landin.Testing.Check
           (Item,
            Bool_Field_Element /= IR.No_Value
            and then IR.Op_Of
              (Unit, Field_Routine,
               IR.Nth_Operand
                 (Unit, Field_Routine, Bool_Field_Element, 2)) = IR.Truth
            and then not IR.Truth_Of
              (Unit, Field_Routine,
               IR.Nth_Operand
                 (Unit, Field_Routine, Bool_Field_Element, 2)),
            "typed false reaches Store_Element through array field one");
         Landin.Testing.Check
           (Item,
            Integer_Field_Element /= IR.No_Value
            and then IR.Op_Of
              (Unit, Field_Routine,
               IR.Nth_Operand
                 (Unit, Field_Routine, Integer_Field_Element, 2)) = IR.Number
            and then IR.Number_Of
              (Unit, Field_Routine,
               IR.Nth_Operand
                 (Unit, Field_Routine, Integer_Field_Element, 2)) = 0,
            "typed zero reaches Store_Element through array field two");
         Landin.Testing.Check
           (Item, Index_Loads = 2,
            "the destination index is evaluated once and carried once");
         Landin.Testing.Check
           (Item,
            First_Index_Load /= IR.No_Value
            and then First_Index_Load
              < IR.Nth_Operand (Unit, Set_Routine, Element_Store, 2),
            "the destination index evaluation precedes the zero RHS");
         Check_Terminators (Item, Unit, "scalar subobject zeroed assignments");
      end;
   end Scalar_Subobject_Zeroed_Uses_Ordinary_Stores;

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

   --  [0670]'s state carries each field's compact target-neutral shape and
   --  no value at all: D10, D59's explicit spelling and D60/D61's typed and
   --  inferred direct-name image chains share the same zero image, and where
   --  each field sits needs a target this stage lacks.  Every declaration
   --  remains a distinct datum.
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
         & "    words: [2]usize" & LF
         & "    ready: bool" & LF
         & "end counters" & LF
         & "mut state: counters = zeroed" & LF
         & "copy: counters = state" & LF
         & "mut inferred := copy" & LF,
         Ran);

      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work), "the program is accepted");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
      begin
         Landin.Testing.Check_Equal
           (Item, IR.Item_Count (Unit), 3,
            "the three bindings own distinct datums");

         for Datum in IR.Item_Id'(1) .. IR.Item_Id'(3) loop
            Landin.Testing.Check
              (Item, IR.Kind_Of (Unit, Datum) = IR.Datum,
               "each module binding is a datum");
            Landin.Testing.Check
              (Item, IR.Result_Of (Unit, Datum) = Landin.Types.Aggregate,
               "each datum keeps the declared aggregate type");
            Landin.Testing.Check_Equal
              (Item, IR.Field_Count (Unit, Datum), 3,
               "all fields are carried");
            Landin.Testing.Check
              (Item, IR.Nth_Field (Unit, Datum, 1) = Landin.Types.U32,
               "the first field keeps its type");
            Landin.Testing.Check
              (Item,
               IR.Nth_Field_Shape (Unit, Datum, 2)
                 = (Kind    => IR.Array_Field_Shape,
                    Element => Landin.Types.Usize,
                    Length  => 2,
                    others  => <>),
               "the array field keeps its shape without a target");
            Landin.Testing.Check
              (Item, IR.Nth_Field (Unit, Datum, 3) = Landin.Types.Bool,
               "the last scalar keeps its type and order");
            Landin.Testing.Check_Equal
              (Item, IR.Value_Count (Unit, Datum), 1,
               "each datum has a leave and nothing else");
            Landin.Testing.Check
              (Item, IR.Op_Of (Unit, Datum, 1) = IR.Leave,
               "the sole value is the leave");
            Landin.Testing.Check_Equal
              (Item, IR.Operand_Count (Unit, Datum, 1), 0,
               "static struct images record no runtime-producing value");
         end loop;

         Check_Terminators (Item, Unit, "three struct states");
      end;
   end A_Struct_State_Carries_Its_Fields;

   ------------------------------------------------------------------

   --  D47 gives [1810]'s declaration-only local the same compact field
   --  shapes as D46's datum, but in one aggregate slot rather than one
   --  module item.  This stage still carries no target offsets.
   procedure A_Struct_Local_Carries_Its_Field_Shapes
     (Item : in out Landin.Testing.Context);

   procedure A_Struct_Local_Carries_Its_Field_Shapes
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "holder: type = struct" & LF
         & "    tag: u8" & LF
         & "    words: [2]usize" & LF
         & "    tail: u16" & LF
         & "end holder" & LF
         & "f: () -> none =" & LF
         & "    mut local: holder" & LF
         & "    local.tag = 1" & LF
         & "    local.tail = 2" & LF
         & "end f" & LF,
         Ran);

      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work), "the program is accepted");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Slot : constant IR.Slot_Id := 1;
      begin
         Landin.Testing.Check_Equal
           (Item, IR.Item_Count (Unit), 1, "the function is the one item");
         Landin.Testing.Check
           (Item, IR.Is_Aggregate (Unit, 1, Slot),
            "the local is one aggregate slot");
         Landin.Testing.Check_Equal
           (Item, IR.Slot_Field_Count (Unit, 1, Slot), 3,
            "all source fields are carried");
         Landin.Testing.Check
           (Item, IR.Nth_Slot_Field (Unit, 1, Slot, 1) = Landin.Types.U8,
            "the first scalar keeps its type");
         Landin.Testing.Check
           (Item,
            IR.Nth_Slot_Field_Shape (Unit, 1, Slot, 2)
              = (Kind    => IR.Array_Field_Shape,
                 Element => Landin.Types.Usize,
                 Length  => 2,
                 others  => <>),
            "the array field remains one target-neutral shape");
         Landin.Testing.Check
           (Item, IR.Nth_Slot_Field (Unit, 1, Slot, 3) = Landin.Types.U16,
            "the trailing scalar keeps its type and order");
      end;
   end A_Struct_Local_Carries_Its_Field_Shapes;

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

   --  D36 lowers the finite prefix as ordered scalar stores, then evaluates
   --  the repeated expression once and fills only the remaining suffix.
   procedure A_Mixed_Repetition_Becomes_Prefix_Stores_And_One_Fill
     (Item : in out Landin.Testing.Context);

   procedure A_Mixed_Repetition_Becomes_Prefix_Stores_And_One_Fill
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "f: () -> none =" & LF
         & "    row: [5]u32 = [7, 8, of 9]" & LF
         & "end f" & LF,
         Ran);

      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "the explicitly typed local mixed repetition is accepted");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
      begin
         Landin.Testing.Check_Equal
           (Item, IR.Slot_Count (Unit, 1), 1,
            "the mixed form owns no hidden array temporary");
         Landin.Testing.Check
           (Item,
            IR.Op_Of (Unit, 1, 1) = IR.Number
            and then IR.Op_Of (Unit, 1, 2) = IR.Store_Field
            and then IR.Field_Of (Unit, 1, 2) = 1
            and then IR.Op_Of (Unit, 1, 3) = IR.Number
            and then IR.Op_Of (Unit, 1, 4) = IR.Store_Field
            and then IR.Field_Of (Unit, 1, 4) = 2,
            "the two prefix expressions are stored in source order");
         Landin.Testing.Check
           (Item,
            IR.Op_Of (Unit, 1, 5) = IR.Number
            and then IR.Op_Of (Unit, 1, 6) = IR.Fill_Array
            and then IR.First_Part_Of (Unit, 1, 6) = 3
            and then IR.Nth_Operand (Unit, 1, 6, 1) = 5,
            "one scalar evaluation feeds one compact suffix fill");
         Landin.Testing.Check_Equal
           (Item, IR.Value_Count (Unit, 1), 7,
            "only prefix pairs, one value, one fill and return are emitted");
      end;
   end A_Mixed_Repetition_Becomes_Prefix_Stores_And_One_Fill;

   --  D37 reaches the assignment destination first, then stores each prefix
   --  expression in source order and evaluates one scalar for one compact
   --  suffix fill.  The same lowering serves frame slots and module datums.
   procedure Mixed_Assignment_Becomes_Prefix_Stores_And_One_Fill
     (Item : in out Landin.Testing.Context);

   procedure Mixed_Assignment_Becomes_Prefix_Stores_And_One_Fill
     (Item : in out Landin.Testing.Context)
   is
      use type IR.Storage_Kind;

      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "mut state: [4]u32" & LF
         & "f: () -> none =" & LF
         & "    mut row: [5]u32" & LF
         & "    row = [7, 8, of 9]" & LF
         & "    state = [10, of 11]" & LF
         & "end f" & LF,
         Ran);

      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "both mixed-repetition assignments are accepted");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
      begin
         Landin.Testing.Check_Equal
           (Item, IR.Slot_Count (Unit, 2), 1,
            "the destination is the only frame slot");
         Landin.Testing.Check_Equal
           (Item, IR.Value_Count (Unit, 2), 11,
            "ordered stores, two compact fills and return are emitted");
         Landin.Testing.Check
           (Item,
            IR.Op_Of (Unit, 2, 1) = IR.Number
            and then IR.Op_Of (Unit, 2, 2) = IR.Store_Field
            and then IR.Reaches_A_Slot (Unit, 2, 2)
            and then IR.Slot_Of (Unit, 2, 2) = 1
            and then IR.Field_Of (Unit, 2, 2) = 1
            and then IR.Op_Of (Unit, 2, 3) = IR.Number
            and then IR.Op_Of (Unit, 2, 4) = IR.Store_Field
            and then IR.Reaches_A_Slot (Unit, 2, 4)
            and then IR.Slot_Of (Unit, 2, 4) = 1
            and then IR.Field_Of (Unit, 2, 4) = 2,
            "local prefix values are immediately stored left to right");
         Landin.Testing.Check
           (Item,
            IR.Op_Of (Unit, 2, 5) = IR.Number
            and then IR.Op_Of (Unit, 2, 6) = IR.Fill_Array
            and then IR.First_Part_Of (Unit, 2, 6) = 3
            and then IR.Destination_Of (Unit, 2, 6).Kind = IR.Frame_Slot
            and then IR.Destination_Of (Unit, 2, 6).Slot = 1
            and then IR.Nth_Operand (Unit, 2, 6, 1) = 5,
            "one local scalar evaluation feeds the suffix fill");
         Landin.Testing.Check
           (Item,
            IR.Op_Of (Unit, 2, 7) = IR.Number
            and then IR.Op_Of (Unit, 2, 8) = IR.Store_Field
            and then not IR.Reaches_A_Slot (Unit, 2, 8)
            and then IR.Datum_Of (Unit, 2, 8) = 1
            and then IR.Field_Of (Unit, 2, 8) = 1,
            "the module prefix is stored in its datum");
         Landin.Testing.Check
           (Item,
            IR.Op_Of (Unit, 2, 9) = IR.Number
            and then IR.Op_Of (Unit, 2, 10) = IR.Fill_Array
            and then IR.First_Part_Of (Unit, 2, 10) = 2
            and then IR.Destination_Of (Unit, 2, 10).Kind = IR.Module_Datum
            and then IR.Destination_Of (Unit, 2, 10).Datum = 1
            and then IR.Nth_Operand (Unit, 2, 10, 1) = 9,
            "one module scalar evaluation feeds its suffix fill");
      end;
   end Mixed_Assignment_Becomes_Prefix_Stores_And_One_Fill;

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
   --  destination-only Clear_Array operation D28 introduced.  D58 reuses
   --  field zero for the padded whole of module and local aggregate storage.
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
         & "holder: type = struct" & LF
         & "    tag: u8" & LF
         & "    row: [2]u32" & LF
         & "    tail: u16" & LF
         & "end holder" & LF
         & "mut structure: holder" & LF
         & "f: () -> none =" & LF
         & "    mut row: [3]u16" & LF
         & "    mut local: holder" & LF
         & "    row = zeroed" & LF
         & "    state = zeroed" & LF
         & "    local = zeroed" & LF
         & "    structure = zeroed" & LF
         & "end f" & LF,
         Ran);

      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "both zeroed assignments are accepted");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Routine : constant IR.Item_Id := 3;
      begin
         Landin.Testing.Check_Equal
           (Item, IR.Value_Count (Unit, Routine), 5,
            "four clears and the leave are the complete instruction run");
         Landin.Testing.Check
           (Item, IR.Op_Of (Unit, Routine, 1) = IR.Clear_Array
                  and then IR.Destination_Of (Unit, Routine, 1).Kind
                             = IR.Frame_Slot
                  and then IR.Destination_Of (Unit, Routine, 1).Slot = 1
                  and then IR.Element_Field_Of (Unit, Routine, 1) = 0,
            "the first clear names the local array slot");
         Landin.Testing.Check
           (Item, IR.Op_Of (Unit, Routine, 2) = IR.Clear_Array
                  and then IR.Destination_Of (Unit, Routine, 2).Kind
                             = IR.Module_Datum
                  and then IR.Destination_Of (Unit, Routine, 2).Datum = 1
                  and then IR.Element_Field_Of (Unit, Routine, 2) = 0,
            "the second clear names the module array datum");
         Landin.Testing.Check
           (Item, IR.Op_Of (Unit, Routine, 3) = IR.Clear_Array
                  and then IR.Destination_Of (Unit, Routine, 3).Kind
                             = IR.Frame_Slot
                  and then IR.Destination_Of (Unit, Routine, 3).Slot = 2
                  and then IR.Element_Field_Of (Unit, Routine, 3) = 0,
            "the third clear names the local aggregate slot");
         Landin.Testing.Check
           (Item, IR.Op_Of (Unit, Routine, 4) = IR.Clear_Array
                  and then IR.Destination_Of (Unit, Routine, 4).Kind
                             = IR.Module_Datum
                  and then IR.Destination_Of (Unit, Routine, 4).Datum = 2
                  and then IR.Element_Field_Of (Unit, Routine, 4) = 0,
            "the fourth clear names the module aggregate datum");
         Landin.Testing.Check
           (Item, IR.Verifier.Check (Unit).Kind = IR.Verifier.Nothing_Wrong,
            "array and aggregate whole-storage clears verify together");
      end;
   end Zeroed_Assignment_Clears_Either_Storage_Kind;

   --  D49 lowers a whole array-field clear through the same compact
   --  operation, carrying the declaration-order field rather than a target
   --  byte offset for both module and frame storage.
   procedure Zeroed_Array_Field_Carries_Its_Containing_Field
     (Item : in out Landin.Testing.Context);

   procedure Zeroed_Array_Field_Carries_Its_Containing_Field
     (Item : in out Landin.Testing.Context)
   is
      use type IR.Storage_Kind;

      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "holder: type = struct" & LF
         & "    tag: u8" & LF
         & "    row: [2]u32" & LF
         & "end holder" & LF
         & "mut state: holder" & LF
         & "f: () -> none =" & LF
         & "    mut local: holder" & LF
         & "    local.row = zeroed" & LF
         & "    state.row = zeroed" & LF
         & "end f" & LF,
         Ran);

      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "module and local array-field clears are accepted and verified");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
      begin
         Landin.Testing.Check_Equal
           (Item, IR.Value_Count (Unit, 2), 3,
            "two field clears and the leave are the instruction run");
         Landin.Testing.Check
           (Item, IR.Op_Of (Unit, 2, 1) = IR.Clear_Array
                  and then IR.Destination_Of (Unit, 2, 1).Kind
                             = IR.Frame_Slot
                  and then IR.Destination_Of (Unit, 2, 1).Slot = 1
                  and then IR.Element_Field_Of (Unit, 2, 1) = 2,
            "the local clear carries its aggregate slot and field");
         Landin.Testing.Check
           (Item, IR.Op_Of (Unit, 2, 2) = IR.Clear_Array
                  and then IR.Destination_Of (Unit, 2, 2).Kind
                             = IR.Module_Datum
                  and then IR.Destination_Of (Unit, 2, 2).Datum = 1
                  and then IR.Element_Field_Of (Unit, 2, 2) = 2,
            "the module clear carries its aggregate datum and field");
      end;
   end Zeroed_Array_Field_Carries_Its_Containing_Field;

   --  D50 carries an independent declaration-order field for each compact
   --  Copy_Array endpoint.  Zero keeps the direct-array spelling, so all
   --  field/name and module/frame combinations use the same operation.
   procedure Array_Field_Copy_Carries_Both_Endpoint_Fields
     (Item : in out Landin.Testing.Context);

   procedure Array_Field_Copy_Carries_Both_Endpoint_Fields
     (Item : in out Landin.Testing.Context)
   is
      use type IR.Storage_Kind;

      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "holder: type = struct" & LF
         & "    tag: u8" & LF
         & "    row: [2]u32" & LF
         & "end holder" & LF
         & "mut source: holder" & LF
         & "mut destination: holder" & LF
         & "mut words: [2]u32" & LF
         & "f: () -> none =" & LF
         & "    destination.row = source.row" & LF
         & "    words = destination.row" & LF
         & "    destination.row = words" & LF
         & "    mut left: holder" & LF
         & "    mut right: holder" & LF
         & "    mut local_words: [2]u32" & LF
         & "    left.row = zeroed" & LF
         & "    right.row = left.row" & LF
         & "    local_words = right.row" & LF
         & "    right.row = local_words" & LF
         & "end f" & LF,
         Ran);

      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "field and direct-array copies are accepted and verified");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Routine : constant IR.Item_Id := 4;
      begin
         Landin.Testing.Check_Equal
           (Item, IR.Value_Count (Unit, Routine), 8,
            "six copies, one clear and the leave are the instruction run");
         Landin.Testing.Check
           (Item,
            IR.Op_Of (Unit, Routine, 1) = IR.Copy_Array
            and then IR.Source_Of (Unit, Routine, 1).Kind = IR.Module_Datum
            and then IR.Destination_Of (Unit, Routine, 1).Kind
                       = IR.Module_Datum
            and then IR.Source_Field_Of (Unit, Routine, 1) = 2
            and then IR.Element_Field_Of (Unit, Routine, 1) = 2,
            "a module field copies directly to a module field");
         Landin.Testing.Check
           (Item,
            IR.Source_Field_Of (Unit, Routine, 2) = 2
            and then IR.Element_Field_Of (Unit, Routine, 2) = 0
            and then IR.Source_Field_Of (Unit, Routine, 3) = 0
            and then IR.Element_Field_Of (Unit, Routine, 3) = 2,
            "module field and direct-array endpoints keep zero distinct");
         Landin.Testing.Check
           (Item,
            IR.Op_Of (Unit, Routine, 5) = IR.Copy_Array
            and then IR.Source_Of (Unit, Routine, 5).Kind = IR.Frame_Slot
            and then IR.Destination_Of (Unit, Routine, 5).Kind
                       = IR.Frame_Slot
            and then IR.Source_Field_Of (Unit, Routine, 5) = 2
            and then IR.Element_Field_Of (Unit, Routine, 5) = 2,
            "a frame field copies directly to a frame field");
         Landin.Testing.Check
           (Item,
            IR.Source_Field_Of (Unit, Routine, 6) = 2
            and then IR.Element_Field_Of (Unit, Routine, 6) = 0
            and then IR.Source_Field_Of (Unit, Routine, 7) = 0
            and then IR.Element_Field_Of (Unit, Routine, 7) = 2,
            "frame field and direct-array endpoints keep zero distinct");
      end;
   end Array_Field_Copy_Carries_Both_Endpoint_Fields;

   --  D51 lowers both typed and inferred local initializers from a selected
   --  array field through D21's Copy_Array.  The source keeps D50's field
   --  identity and the fresh destination slot remains field zero.
   procedure Array_Field_Initializer_Carries_Its_Source_Field
     (Item : in out Landin.Testing.Context);

   procedure Array_Field_Initializer_Carries_Its_Source_Field
     (Item : in out Landin.Testing.Context)
   is
      use type IR.Storage_Kind;

      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "holder: type = struct" & LF
         & "    tag: u8" & LF
         & "    row: [2]u32" & LF
         & "end holder" & LF
         & "state: holder" & LF
         & "f: () -> none =" & LF
         & "    module_typed: [2]u32 = state.row" & LF
         & "    module_inferred := state.row" & LF
         & "    mut local: holder" & LF
         & "    local.row = zeroed" & LF
         & "    local_typed: [2]u32 = local.row" & LF
         & "    local_inferred := local.row" & LF
         & "end f" & LF,
         Ran);

      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "field initializers are accepted, lowered and verified");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Routine : constant IR.Item_Id := 2;
      begin
         Landin.Testing.Check_Equal
           (Item, IR.Value_Count (Unit, Routine), 6,
            "four copies, one clear and the leave are the instruction run");
         Landin.Testing.Check
           (Item,
            IR.Op_Of (Unit, Routine, 1) = IR.Copy_Array
            and then IR.Source_Of (Unit, Routine, 1).Kind = IR.Module_Datum
            and then IR.Source_Field_Of (Unit, Routine, 1) = 2
            and then IR.Element_Field_Of (Unit, Routine, 1) = 0
            and then IR.Op_Of (Unit, Routine, 2) = IR.Copy_Array
            and then IR.Source_Field_Of (Unit, Routine, 2) = 2
            and then IR.Element_Field_Of (Unit, Routine, 2) = 0,
            "typed and inferred module fields copy into direct slots");
         Landin.Testing.Check
           (Item,
            IR.Op_Of (Unit, Routine, 4) = IR.Copy_Array
            and then IR.Source_Of (Unit, Routine, 4).Kind = IR.Frame_Slot
            and then IR.Source_Field_Of (Unit, Routine, 4) = 2
            and then IR.Element_Field_Of (Unit, Routine, 4) = 0
            and then IR.Op_Of (Unit, Routine, 5) = IR.Copy_Array
            and then IR.Source_Field_Of (Unit, Routine, 5) = 2
            and then IR.Element_Field_Of (Unit, Routine, 5) = 0,
            "typed and inferred frame fields copy into direct slots");
      end;
   end Array_Field_Initializer_Carries_Its_Source_Field;

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

   --  D70 resolves a module struct image before copying one selected
   --  fixed-array field into a typed or inferred array datum.  Every D67/D68
   --  descriptor form becomes the corresponding ordinary array image, and a
   --  later D21 link treats that destination like any other array datum.
   procedure A_Module_Array_Copies_A_Struct_Field_Image
     (Item : in out Landin.Testing.Context);

   procedure A_Module_Array_Copies_A_Struct_Field_Image
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "holder: type = struct" & LF
         & "    finite: [2]u16" & LF
         & "    repeated: [3]u8" & LF
         & "    hybrid: [3]u8" & LF
         & "    zero_repeat: [2]u8" & LF
         & "    omitted: [2]u8" & LF
         & "end holder" & LF
         & "state: holder = (finite: [11, 13], repeated: [of 17],"
         & " hybrid: [19, of 23], zero_repeat: [of 0], of zeroed)" & LF
         & "finite_copy: [2]u16 = state.finite" & LF
         & "repeated_copy := state.repeated" & LF
         & "hybrid_copy: [3]u8 = state.hybrid" & LF
         & "zero_copy := state.zero_repeat" & LF
         & "omitted_copy: [2]u8 = state.omitted" & LF
         & "downstream := hybrid_copy" & LF,
         Ran);

      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "typed and inferred selected-field images are accepted");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
      begin
         Landin.Testing.Check
           (Item,
            IR.Has_Image (Unit, 2)
            and then IR.Image_Length (Unit, 2) = 2
            and then IR.Nth_Image (Unit, 2, 1) = 11
            and then IR.Nth_Image (Unit, 2, 2) = 13,
            "a finite field becomes a finite array image");
         Landin.Testing.Check
           (Item,
            IR.Has_Image (Unit, 3)
            and then IR.Is_Repeated_Image (Unit, 3)
            and then IR.Image_Prefix_Length (Unit, 3) = 0
            and then IR.Repeated_Image_Value (Unit, 3) = 17,
            "a repeated field stays compact");
         Landin.Testing.Check
           (Item,
            IR.Has_Image (Unit, 4)
            and then IR.Is_Repeated_Image (Unit, 4)
            and then IR.Image_Prefix_Length (Unit, 4) = 1
            and then IR.Nth_Image (Unit, 4, 1) = 19
            and then IR.Repeated_Image_Value (Unit, 4) = 23,
            "a hybrid field preserves its prefix and suffix");
         Landin.Testing.Check
           (Item,
            not IR.Has_Image (Unit, 5)
            and then not IR.Has_Image (Unit, 6),
            "zero-pattern and omitted fields stay absent");
         Landin.Testing.Check
           (Item,
            IR.Has_Image (Unit, 7)
            and then IR.Is_Repeated_Image (Unit, 7)
            and then IR.Image_Prefix_Length (Unit, 7) = 1
            and then IR.Nth_Image (Unit, 7, 1) = 19
            and then IR.Repeated_Image_Value (Unit, 7) = 23,
            "a downstream array chain copies the selected field image");
      end;
   end A_Module_Array_Copies_A_Struct_Field_Image;

   --  D71 copies a selected aggregate field descriptor into another module
   --  struct image, rebasing its finite prefix at the destination's compact
   --  element cursor.  Aggregate chains reuse the same descriptor copier.
   procedure A_Module_Struct_Field_Copies_A_Struct_Field_Image
     (Item : in out Landin.Testing.Context);

   procedure A_Module_Struct_Field_Copies_A_Struct_Field_Image
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "holder: type = struct" & LF
         & "    finite: [2]u16" & LF
         & "    repeated: [3]u8" & LF
         & "    hybrid: [3]u8" & LF
         & "    zero_repeat: [2]u8" & LF
         & "    omitted: [2]u8" & LF
         & "end holder" & LF
         & "source: holder = (finite: [11, 13], repeated: [of 17],"
         & " hybrid: [19, of 23], zero_repeat: [of 0], of zeroed)" & LF
         & "copy: holder = (finite: source.finite,"
         & " repeated: source.repeated, hybrid: source.hybrid,"
         & " zero_repeat: source.zero_repeat, omitted: source.omitted)" & LF
         & "through: holder = copy" & LF,
         Ran);

      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "selected field descriptors and their aggregate chain lower");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
      begin
         for Datum in IR.Item_Id range 2 .. 3 loop
            Landin.Testing.Check
              (Item,
               IR.Has_Image (Unit, Datum)
               and then IR.Image_Length (Unit, Datum) = 8
               and then IR.Field_Image_Of
                 (Unit, Datum, 1).Form = IR.Finite
               and then IR.Nth_Field_Element
                 (Unit, Datum, 1, 1) = 11
               and then IR.Nth_Field_Element
                 (Unit, Datum, 1, 2) = 13,
               "the finite selected field is rebased and copied");
            Landin.Testing.Check
              (Item,
               IR.Field_Image_Of (Unit, Datum, 2).Form = IR.Repeated
               and then IR.Field_Image_Of (Unit, Datum, 2).Count = 0
               and then IR.Field_Image_Of (Unit, Datum, 2).Value = 17
               and then IR.Field_Image_Of
                 (Unit, Datum, 3).Form = IR.Hybrid
               and then IR.Field_Image_Of (Unit, Datum, 3).Offset = 2
               and then IR.Field_Image_Of (Unit, Datum, 3).Count = 1
               and then IR.Nth_Field_Element
                 (Unit, Datum, 3, 1) = 19
               and then IR.Field_Image_Of (Unit, Datum, 3).Value = 23,
               "repeated and hybrid selected fields stay canonical");
            Landin.Testing.Check
              (Item,
               IR.Field_Image_Of (Unit, Datum, 4).Form = IR.Absent
               and then IR.Field_Image_Of
                 (Unit, Datum, 5).Form = IR.Absent,
               "zero-pattern and omitted selected fields stay absent");
         end loop;
      end;
   end A_Module_Struct_Field_Copies_A_Struct_Field_Image;

   --  D66--D71 extend D60/D61's module struct image chain with scalar folds,
   --  compact finite, repeated and hybrid array-field segments, and direct or
   --  selected array sources.  D81--D83 carry the same forms inside a selected
   --  variant case, including direct and selected module array sources.  Every
   --  destination gets its own run; a zero repetition keeps an absent field.
   procedure A_Module_Struct_Literal_Records_And_Copies_Its_Image
     (Item : in out Landin.Testing.Context);

   procedure A_Module_Struct_Literal_Records_And_Copies_Its_Image
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "holder: type = struct" & LF
         & "    tag: u8" & LF
         & "    count: usize" & LF
         & "    row: [2]u16" & LF
         & "    repeated: [2]u8" & LF
         & "    zero_repeat: [2]u8" & LF
         & "    mixed: [3]u16" & LF
         & "    copied_finite: [2]u16" & LF
         & "    copied_repeated: [2]u8" & LF
         & "    copied_zero: [2]u8" & LF
         & "    copied_hybrid: [3]u16" & LF
         & "end holder" & LF
         & "finite_source: [2]u16 = [29, 31]" & LF
         & "repeated_source: [2]u8 = [of 37]" & LF
         & "zero_source: [2]u8 = [of 0]" & LF
         & "hybrid_source: [3]u16 = [41, of 43]" & LF
         & "mut origin: holder = (count: 7, row: [11, 13], tag: 5,"
         & " repeated: [of 7], zero_repeat: [of 0],"
         & " mixed: [17, of 0], copied_finite: finite_source,"
         & " copied_repeated: repeated_source, copied_zero: zero_source,"
         & " copied_hybrid: hybrid_source)" & LF
         & "copy: holder = origin" & LF
         & "inferred := copy" & LF
         & "blank: holder = zeroed" & LF
         & "choice: type = struct" & LF
         & "    kind: variant" & LF
         & "        leaf |" & LF
         & "        pair: (first: u8, second: u16) |" & LF
         & "        arrays: (finite: [2]u8, repeated: [2]u16,"
         & " hybrid: [3]u8, blank: [2]bool)" & LF
         & "    end kind" & LF
         & "end choice" & LF
         & "selected: choice = choice(kind: pair(first: 11,"
         & " second: 13))" & LF
         & "selected_copy: choice = selected" & LF
         & "selected_inferred := choice(kind: leaf)" & LF
         & "array_selected: choice = choice(kind: arrays("
         & "finite: [17, 19], repeated: [of 23],"
         & " hybrid: [29, of 31], blank: zeroed))" & LF
         & "array_selected_copy: choice = array_selected" & LF
         & "payload_holder: type = struct" & LF
         & "    repeated: [2]u16" & LF
         & "    blank: [2]bool" & LF
         & "end payload_holder" & LF
         & "array_copied: choice = choice(kind: arrays("
         & "finite: variant_finite_source,"
         & " repeated: variant_payload_fields.repeated,"
         & " hybrid: variant_hybrid_source,"
         & " blank: variant_payload_fields.blank))" & LF
         & "array_copied_copy: choice = array_copied" & LF
         & "variant_finite_source: [2]u8 = [43, 47]" & LF
         & "variant_hybrid_source: [3]u8 = [53, of 59]" & LF
         & "variant_payload_fields: payload_holder = ("
         & "repeated: [of 61], blank: [of false])" & LF,
         Ran);

      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "the aggregate image chain is accepted");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
      begin
         for Datum in IR.Item_Id range 5 .. 7 loop
            Landin.Testing.Check
              (Item,
               IR.Result_Of (Unit, Datum) = Landin.Types.Aggregate
               and then IR.Has_Image (Unit, Datum),
               "each nonzero struct destination owns an image");
            Landin.Testing.Check
              (Item,
               IR.Image_Length (Unit, Datum) = 16
               and then IR.Nth_Field_Image (Unit, Datum, 1) = 5
               and then IR.Nth_Field_Image (Unit, Datum, 2) = 7
               and then IR.Nth_Field_Image (Unit, Datum, 3) = 0
               and then IR.Nth_Field_Image (Unit, Datum, 4) = 0
               and then IR.Nth_Field_Image (Unit, Datum, 5) = 0
               and then IR.Nth_Field_Image (Unit, Datum, 6) = 0
               and then IR.Nth_Field_Image (Unit, Datum, 7) = 0
               and then IR.Nth_Field_Image (Unit, Datum, 8) = 0
               and then IR.Nth_Field_Image (Unit, Datum, 9) = 0
               and then IR.Nth_Field_Image (Unit, Datum, 10) = 0,
               "the chain carries scalar folds and the array placeholder");
            Landin.Testing.Check
              (Item,
               IR.Field_Image_Of (Unit, Datum, 3).Form = IR.Finite
               and then IR.Nth_Field_Element (Unit, Datum, 3, 1) = 11
               and then IR.Nth_Field_Element (Unit, Datum, 3, 2) = 13,
               "the chain copies the finite array-field image");
            Landin.Testing.Check
              (Item,
               IR.Field_Image_Of (Unit, Datum, 4).Form = IR.Repeated
               and then IR.Field_Image_Of (Unit, Datum, 4).Value = 7
               and then IR.Field_Image_Of (Unit, Datum, 5).Form = IR.Absent
               and then IR.Field_Image_Of (Unit, Datum, 6).Form = IR.Hybrid
               and then IR.Nth_Field_Element (Unit, Datum, 6, 1) = 17
               and then IR.Field_Image_Of (Unit, Datum, 6).Value = 0,
               "the chain copies repetition and canonical zero patterns");
            Landin.Testing.Check
              (Item,
               IR.Field_Image_Of (Unit, Datum, 7).Form = IR.Finite
               and then IR.Nth_Field_Element (Unit, Datum, 7, 1) = 29
               and then IR.Nth_Field_Element (Unit, Datum, 7, 2) = 31
               and then IR.Field_Image_Of (Unit, Datum, 8).Form = IR.Repeated
               and then IR.Field_Image_Of (Unit, Datum, 8).Value = 37
               and then IR.Field_Image_Of (Unit, Datum, 9).Form = IR.Absent
               and then IR.Field_Image_Of (Unit, Datum, 10).Form = IR.Hybrid
               and then IR.Nth_Field_Element (Unit, Datum, 10, 1) = 41
               and then IR.Field_Image_Of (Unit, Datum, 10).Value = 43,
               "direct array labels copy every canonical image form");
         end loop;

         Landin.Testing.Check
           (Item,
            IR.Result_Of (Unit, 8) = Landin.Types.Aggregate
            and then not IR.Has_Image (Unit, 8),
            "the whole-zero aggregate still has no written image");

         for Datum in IR.Item_Id range 9 .. 10 loop
            Landin.Testing.Check
              (Item,
               IR.Has_Image (Unit, Datum)
               and then IR.Field_Image_Of
                 (Unit, Datum, 1).Form = IR.Selected
               and then IR.Field_Image_Of
                 (Unit, Datum, 1).Value = 2
               and then IR.Variant_Payload_Image_Of
                 (Unit, Datum, 1, 1).Value = 11
               and then IR.Variant_Payload_Image_Of
                 (Unit, Datum, 1, 2).Value = 13,
               "a selected variant image and its copy carry payload folds");
         end loop;
         Landin.Testing.Check
           (Item,
            IR.Has_Image (Unit, 11)
            and then IR.Field_Image_Of
              (Unit, 11, 1).Form = IR.Selected
            and then IR.Field_Image_Of (Unit, 11, 1).Value = 1
            and then IR.Field_Image_Of (Unit, 11, 1).Count = 0,
            "an inferred bare case remains an explicit selected image");

         for Datum in IR.Item_Id range 12 .. 13 loop
            Landin.Testing.Check
              (Item,
               IR.Has_Image (Unit, Datum)
               and then IR.Field_Image_Of
                 (Unit, Datum, 1).Form = IR.Selected
               and then IR.Field_Image_Of (Unit, Datum, 1).Value = 3
               and then IR.Variant_Payload_Image_Of
                 (Unit, Datum, 1, 1).Form = IR.Finite
               and then IR.Nth_Variant_Field_Element
                 (Unit, Datum, 1, 1, 1) = 17
               and then IR.Nth_Variant_Field_Element
                 (Unit, Datum, 1, 1, 2) = 19
               and then IR.Variant_Payload_Image_Of
                 (Unit, Datum, 1, 2).Form = IR.Repeated
               and then IR.Variant_Payload_Image_Of
                 (Unit, Datum, 1, 2).Value = 23
               and then IR.Variant_Payload_Image_Of
                 (Unit, Datum, 1, 3).Form = IR.Hybrid
               and then IR.Nth_Variant_Field_Element
                 (Unit, Datum, 1, 3, 1) = 29
               and then IR.Variant_Payload_Image_Of
                 (Unit, Datum, 1, 3).Value = 31
               and then IR.Variant_Payload_Image_Of
                 (Unit, Datum, 1, 4).Form = IR.Absent,
               "a selected array payload and its copy keep every form");
         end loop;

         for Datum in IR.Item_Id range 14 .. 15 loop
            Landin.Testing.Check
              (Item,
               IR.Has_Image (Unit, Datum)
               and then IR.Field_Image_Of
                 (Unit, Datum, 1).Form = IR.Selected
               and then IR.Field_Image_Of (Unit, Datum, 1).Value = 3
               and then IR.Variant_Payload_Image_Of
                 (Unit, Datum, 1, 1).Form = IR.Finite
               and then IR.Nth_Variant_Field_Element
                 (Unit, Datum, 1, 1, 1) = 43
               and then IR.Nth_Variant_Field_Element
                 (Unit, Datum, 1, 1, 2) = 47
               and then IR.Variant_Payload_Image_Of
                 (Unit, Datum, 1, 2).Form = IR.Repeated
               and then IR.Variant_Payload_Image_Of
                 (Unit, Datum, 1, 2).Value = 61
               and then IR.Variant_Payload_Image_Of
                 (Unit, Datum, 1, 3).Form = IR.Hybrid
               and then IR.Nth_Variant_Field_Element
                 (Unit, Datum, 1, 3, 1) = 53
               and then IR.Variant_Payload_Image_Of
                 (Unit, Datum, 1, 3).Value = 59
               and then IR.Variant_Payload_Image_Of
                 (Unit, Datum, 1, 4).Form = IR.Absent,
               "variant payload image sources are resolved and rebased");
         end loop;
      end;
   end A_Module_Struct_Literal_Records_And_Copies_Its_Image;

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
         & "mut zero: [3]u32 = [of 0]" & LF
         & "mut hybrid: [4294967295]u8 = [1, 2, of 0]" & LF
         & "mut hybrid_through: [4294967295]u8 = hybrid" & LF,
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
         for Datum in IR.Item_Id range 6 .. 7 loop
            Landin.Testing.Check
              (Item,
               IR.Is_Repeated_Image (Unit, Datum)
               and then IR.Image_Prefix_Length (Unit, Datum) = 2
               and then IR.Image_Length (Unit, Datum)
                          = IR.Element_Total'(4_294_967_295)
               and then Landin.Types."="
                 (IR.Nth_Image (Unit, Datum, 1), 1)
               and then Landin.Types."="
                 (IR.Nth_Image (Unit, Datum, 2), 2)
               and then Landin.Types."="
                 (IR.Repeated_Image_Value (Unit, Datum), 0),
               "a zero-suffix hybrid and its name copy stay compact"
               & " and present");
         end loop;
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

   procedure An_Array_Field_Element_Carries_Its_Containing_Field
     (Item : in out Landin.Testing.Context);

   procedure An_Array_Field_Element_Carries_Its_Containing_Field
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "holder: type = struct" & LF
         & "    tag: u8" & LF
         & "    row: [2]u32" & LF
         & "end holder" & LF
         & "state: holder" & LF
         & "f: (at: usize) -> none =" & LF
         & "    mut local: holder" & LF
         & "    local.row[at] = state.row[at]" & LF
         & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");
      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Module_Loads, Local_Stores : Natural := 0;
      begin
         for I in 1 .. IR.Item_Count (Unit) loop
            declare
               Owner : constant IR.Item_Id := IR.Item_Id (I);
            begin
               for V in 1 .. IR.Value_Count (Unit, Owner) loop
                  declare
                     Value : constant IR.Value_Id := IR.Value_Id (V);
                     Op : constant IR.Opcode :=
                       IR.Op_Of (Unit, Owner, Value);
                  begin
                     if Op = IR.Load_Element
                       and then not IR.Reaches_A_Slot (Unit, Owner, Value)
                       and then IR.Element_Field_Of (Unit, Owner, Value) = 2
                     then
                        Module_Loads := Module_Loads + 1;
                     elsif Op = IR.Store_Element
                       and then IR.Reaches_A_Slot (Unit, Owner, Value)
                       and then IR.Element_Field_Of (Unit, Owner, Value) = 2
                     then
                        Local_Stores := Local_Stores + 1;
                     end if;
                  end;
               end loop;
            end;
         end loop;

         Landin.Testing.Check_Equal
           (Item, Module_Loads, 1,
            "the module read carries its containing field");
         Landin.Testing.Check_Equal
           (Item, Local_Stores, 1,
            "the local write carries the same containing field");
         Landin.Testing.Check
           (Item, IR.Verifier.Check (Unit).Kind
                    = IR.Verifier.Nothing_Wrong,
            "the field-qualified element operations verify");
      end;
   end An_Array_Field_Element_Carries_Its_Containing_Field;

   --  D52 keeps D29's direct-array Store_Field run unchanged, but an
   --  element inside a selected field needs D48's two-level identity:
   --  containing field plus zero-based element index.
   procedure Array_Field_Literals_Become_Field_Qualified_Element_Stores
     (Item : in out Landin.Testing.Context);

   procedure Array_Field_Literals_Become_Field_Qualified_Element_Stores
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "holder: type = struct" & LF
         & "    tag: u8" & LF
         & "    row: [2]u32" & LF
         & "end holder" & LF
         & "mut state: holder" & LF
         & "f: () -> none =" & LF
         & "    state.row = [20, 22]" & LF
         & "    mut local: holder" & LF
         & "    local.row = [30, 12]" & LF
         & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "module and local field literals lower");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Routine : constant IR.Item_Id := 2;
      begin
         Landin.Testing.Check_Equal
           (Item, IR.Value_Count (Unit, Routine), 13,
            "four value-index-store triples precede the return");

         for Position in 1 .. 4 loop
            declare
               Element : constant IR.Value_Id :=
                 IR.Value_Id (3 * Position - 2);
               Index : constant IR.Value_Id := IR.Value_Id (3 * Position - 1);
               Store : constant IR.Value_Id := IR.Value_Id (3 * Position);
               Expected_Index : constant Landin.Types.Magnitude :=
                 Landin.Types.Magnitude ((Position - 1) mod 2);
            begin
               Landin.Testing.Check
                 (Item,
                  IR.Op_Of (Unit, Routine, Element) = IR.Number
                  and then IR.Op_Of (Unit, Routine, Index) = IR.Number
                  and then IR.Number_Of (Unit, Routine, Index)
                             = Expected_Index
                  and then IR.Op_Of (Unit, Routine, Store) = IR.Store_Element
                  and then IR.Element_Field_Of (Unit, Routine, Store) = 2
                  and then IR.Nth_Operand (Unit, Routine, Store, 1) = Index
                  and then IR.Nth_Operand (Unit, Routine, Store, 2) = Element,
                  "each expression precedes its index and element store");

               if Position <= 2 then
                  Landin.Testing.Check
                    (Item, not IR.Reaches_A_Slot (Unit, Routine, Store)
                           and then IR.Datum_Of (Unit, Routine, Store) = 1,
                     "the first literal reaches the module field");
               else
                  Landin.Testing.Check
                    (Item, IR.Reaches_A_Slot (Unit, Routine, Store)
                           and then IR.Slot_Of (Unit, Routine, Store) = 1,
                     "the second literal reaches the local field");
               end if;
            end;
         end loop;

         Landin.Testing.Check
           (Item, IR.Verifier.Check (Unit).Kind = IR.Verifier.Nothing_Wrong,
            "the field-qualified literal stores verify");
      end;
   end Array_Field_Literals_Become_Field_Qualified_Element_Stores;

   --  D53 keeps the direct-array D32/D37 lowering unchanged.  A selected
   --  field qualifies D37's prefix stores and the one compact suffix fill
   --  with the same declaration-order field identity D48 introduced.
   procedure Array_Field_Repetitions_Become_Qualified_Fills
     (Item : in out Landin.Testing.Context);

   procedure Array_Field_Repetitions_Become_Qualified_Fills
     (Item : in out Landin.Testing.Context)
   is
      use type IR.Storage_Kind;

      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "holder: type = struct" & LF
         & "    tag: u8" & LF
         & "    row: [4]u32" & LF
         & "end holder" & LF
         & "mut state: holder" & LF
         & "f: () -> none =" & LF
         & "    state.row = [4 of 10]" & LF
         & "    state.row = [11, 12, of 13]" & LF
         & "    mut local: holder" & LF
         & "    local.row = [of 20]" & LF
         & "    local.row = [21, 22, of 23]" & LF
         & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "module and local field repetitions lower");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Full_Fills, Suffix_Fills : Natural := 0;
         Module_Fills, Local_Fills : Natural := 0;
         Module_Prefixes, Local_Prefixes : Natural := 0;
      begin
         for I in 1 .. IR.Item_Count (Unit) loop
            declare
               Owner : constant IR.Item_Id := IR.Item_Id (I);
            begin
               for V in 1 .. IR.Value_Count (Unit, Owner) loop
                  declare
                     Value : constant IR.Value_Id := IR.Value_Id (V);
                     Op : constant IR.Opcode :=
                       IR.Op_Of (Unit, Owner, Value);
                  begin
                     if Op = IR.Fill_Array
                       and then IR.Element_Field_Of
                                  (Unit, Owner, Value) = 2
                     then
                        if IR.First_Part_Of (Unit, Owner, Value) = 1 then
                           Full_Fills := Full_Fills + 1;
                        elsif IR.First_Part_Of (Unit, Owner, Value) = 3 then
                           Suffix_Fills := Suffix_Fills + 1;
                        end if;
                        if IR.Destination_Of (Unit, Owner, Value).Kind
                             = IR.Frame_Slot
                        then
                           Local_Fills := Local_Fills + 1;
                        else
                           Module_Fills := Module_Fills + 1;
                        end if;
                     elsif Op = IR.Store_Element
                       and then IR.Element_Field_Of
                                  (Unit, Owner, Value) = 2
                     then
                        if IR.Reaches_A_Slot (Unit, Owner, Value) then
                           Local_Prefixes := Local_Prefixes + 1;
                        else
                           Module_Prefixes := Module_Prefixes + 1;
                        end if;
                     end if;
                  end;
               end loop;
            end;
         end loop;

         Landin.Testing.Check
           (Item,
            Full_Fills = 2 and then Suffix_Fills = 2
            and then Module_Fills = 2 and then Local_Fills = 2,
            "each storage class has one full and one suffix fill");
         Landin.Testing.Check
           (Item, Module_Prefixes = 2 and then Local_Prefixes = 2,
            "each mixed prefix uses two field-qualified element stores");
         Landin.Testing.Check
           (Item, IR.Verifier.Check (Unit).Kind = IR.Verifier.Nothing_Wrong,
            "the field-qualified repetition operations verify");
      end;
   end Array_Field_Repetitions_Become_Qualified_Fills;

   --  D54 keeps scalar fields on their existing load/store pair and uses
   --  one D50 Copy_Array for each fixed-array field.  The instruction run
   --  remains declaration ordered and target-neutral for every endpoint.
   procedure Array_Bearing_Struct_Copy_Uses_Compact_Field_Operations
     (Item : in out Landin.Testing.Context);

   procedure Array_Bearing_Struct_Copy_Uses_Compact_Field_Operations
     (Item : in out Landin.Testing.Context)
   is
      use type IR.Storage_Kind;

      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "holder: type = struct" & LF
         & "    tag: u8" & LF
         & "    row: [2]u32" & LF
         & "    tail: u16" & LF
         & "end holder" & LF
         & "mut left: holder" & LF
         & "mut right: holder" & LF
         & "copy: () -> none =" & LF
         & "    mut first: holder" & LF
         & "    mut second: holder" & LF
         & "    first = left" & LF
         & "    second = first" & LF
         & "    right = second" & LF
         & "    left = right" & LF
         & "end copy" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "all module and local whole-copy endpoint pairs lower");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Routine : constant IR.Item_Id := 3;
      begin
         Landin.Testing.Check_Equal
           (Item, IR.Value_Count (Unit, Routine), 21,
            "four five-operation field runs precede the return");

         for Copy in 0 .. 3 loop
            declare
               First : constant IR.Value_Id := IR.Value_Id (5 * Copy + 1);
               Array_Copy : constant IR.Value_Id := First + 2;
               Source : constant IR.Storage :=
                 IR.Source_Of (Unit, Routine, Array_Copy);
               Destination : constant IR.Storage :=
                 IR.Destination_Of (Unit, Routine, Array_Copy);
            begin
               Landin.Testing.Check
                 (Item,
                  IR.Op_Of (Unit, Routine, First) = IR.Load_Field
                  and then IR.Op_Of (Unit, Routine, First + 1)
                             = IR.Store_Field
                  and then IR.Op_Of (Unit, Routine, Array_Copy)
                             = IR.Copy_Array
                  and then IR.Source_Field_Of
                             (Unit, Routine, Array_Copy) = 2
                  and then IR.Element_Field_Of
                             (Unit, Routine, Array_Copy) = 2
                  and then IR.Op_Of (Unit, Routine, First + 3)
                             = IR.Load_Field
                  and then IR.Op_Of (Unit, Routine, First + 4)
                             = IR.Store_Field,
                  "each copy visits scalar, array and scalar fields in order");

               case Copy is
                  when 0 =>
                     Landin.Testing.Check
                       (Item, Source.Kind = IR.Module_Datum
                              and then Destination.Kind = IR.Frame_Slot,
                        "the first copy goes from module to frame");
                  when 1 =>
                     Landin.Testing.Check
                       (Item, Source.Kind = IR.Frame_Slot
                              and then Destination.Kind = IR.Frame_Slot,
                        "the second copy stays within the frame");
                  when 2 =>
                     Landin.Testing.Check
                       (Item, Source.Kind = IR.Frame_Slot
                              and then Destination.Kind = IR.Module_Datum,
                        "the third copy goes from frame to module");
                  when 3 =>
                     Landin.Testing.Check
                       (Item, Source.Kind = IR.Module_Datum
                              and then Destination.Kind = IR.Module_Datum,
                        "the fourth copy stays in module storage");
               end case;
            end;
         end loop;

         Landin.Testing.Check
           (Item, IR.Verifier.Check (Unit).Kind = IR.Verifier.Nothing_Wrong,
            "the mixed scalar and compact array field runs verify");
      end;
   end Array_Bearing_Struct_Copy_Uses_Compact_Field_Operations;

   --  D55 lowers a typed local struct initializer as D54's declaration-
   --  ordered field run into the fresh aggregate slot.  No aggregate value
   --  or initializer-specific opcode crosses the IR boundary.
   procedure Local_Struct_Initializer_Copies_Into_Its_Fresh_Slot
     (Item : in out Landin.Testing.Context);

   procedure Local_Struct_Initializer_Copies_Into_Its_Fresh_Slot
     (Item : in out Landin.Testing.Context)
   is
      use type IR.Storage_Kind;

      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "holder: type = struct" & LF
         & "    tag: u8" & LF
         & "    row: [2]u32" & LF
         & "    tail: u16" & LF
         & "end holder" & LF
         & "source: holder" & LF
         & "copy: () -> none =" & LF
         & "    first: holder = source" & LF
         & "    second: holder = first" & LF
         & "    empty: holder = zeroed" & LF
         & "end copy" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "module and local names initialize fresh struct slots");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Routine : constant IR.Item_Id := 2;
      begin
         Landin.Testing.Check_Equal
           (Item, IR.Slot_Count (Unit, Routine), 3,
            "each initialized struct owns one aggregate slot");
         Landin.Testing.Check_Equal
           (Item, IR.Value_Count (Unit, Routine), 12,
            "two field copies and one whole clear precede the return");

         for Copy in 0 .. 1 loop
            declare
               First : constant IR.Value_Id := IR.Value_Id (5 * Copy + 1);
               Array_Copy : constant IR.Value_Id := First + 2;
               Source : constant IR.Storage :=
                 IR.Source_Of (Unit, Routine, Array_Copy);
               Destination : constant IR.Storage :=
                 IR.Destination_Of (Unit, Routine, Array_Copy);
            begin
               Landin.Testing.Check
                 (Item,
                  IR.Op_Of (Unit, Routine, First) = IR.Load_Field
                  and then IR.Op_Of (Unit, Routine, First + 1)
                             = IR.Store_Field
                  and then IR.Op_Of (Unit, Routine, Array_Copy)
                             = IR.Copy_Array
                  and then IR.Source_Field_Of
                             (Unit, Routine, Array_Copy) = 2
                  and then IR.Element_Field_Of
                             (Unit, Routine, Array_Copy) = 2
                  and then IR.Op_Of (Unit, Routine, First + 3)
                             = IR.Load_Field
                  and then IR.Op_Of (Unit, Routine, First + 4)
                             = IR.Store_Field,
                  "each initializer copies scalar, array and scalar fields");
               Landin.Testing.Check
                 (Item,
                  Destination.Kind = IR.Frame_Slot
                  and then Destination.Slot = IR.Slot_Id (Copy + 1)
                  and then
                    (if Copy = 0
                     then Source.Kind = IR.Module_Datum
                     else Source.Kind = IR.Frame_Slot
                       and then Source.Slot = 1),
                  "the source feeds the initializer's own fresh slot");
            end;
         end loop;

         Landin.Testing.Check
           (Item,
            IR.Op_Of (Unit, Routine, 11) = IR.Clear_Array
            and then IR.Destination_Of (Unit, Routine, 11).Kind
                       = IR.Frame_Slot
            and then IR.Destination_Of (Unit, Routine, 11).Slot = 3
            and then IR.Element_Field_Of (Unit, Routine, 11) = 0,
            "zeroed is one whole clear of its fresh aggregate slot");

         Landin.Testing.Check
           (Item, IR.Verifier.Check (Unit).Kind = IR.Verifier.Nothing_Wrong,
            "the initializer field runs verify");
      end;
   end Local_Struct_Initializer_Copies_Into_Its_Fresh_Slot;

   --  D56 reaches D55's lowering through an inferred declaration whose body
   --  came from its source.  The same compact field run must target the new
   --  aggregate slot without introducing an aggregate value.
   procedure Inferred_Local_Struct_Copies_Into_Its_Fresh_Slot
     (Item : in out Landin.Testing.Context);

   procedure Inferred_Local_Struct_Copies_Into_Its_Fresh_Slot
     (Item : in out Landin.Testing.Context)
   is
      use type IR.Storage_Kind;

      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "holder: type = struct" & LF
         & "    tag: u8" & LF
         & "    row: [2]u32" & LF
         & "    tail: u16" & LF
         & "end holder" & LF
         & "source: holder" & LF
         & "copy: () -> none =" & LF
         & "    first := source" & LF
         & "    second := first" & LF
         & "end copy" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "module and local names infer fresh struct slots");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Routine : constant IR.Item_Id := 2;
      begin
         Landin.Testing.Check_Equal
           (Item, IR.Slot_Count (Unit, Routine), 2,
            "each inferred struct owns one aggregate slot");
         Landin.Testing.Check_Equal
           (Item, IR.Value_Count (Unit, Routine), 11,
            "two inferred five-operation field copies precede the return");

         for Copy in 0 .. 1 loop
            declare
               First : constant IR.Value_Id := IR.Value_Id (5 * Copy + 1);
               Array_Copy : constant IR.Value_Id := First + 2;
               Source : constant IR.Storage :=
                 IR.Source_Of (Unit, Routine, Array_Copy);
               Destination : constant IR.Storage :=
                 IR.Destination_Of (Unit, Routine, Array_Copy);
            begin
               Landin.Testing.Check
                 (Item,
                  IR.Op_Of (Unit, Routine, First) = IR.Load_Field
                  and then IR.Op_Of (Unit, Routine, First + 1)
                             = IR.Store_Field
                  and then IR.Op_Of (Unit, Routine, Array_Copy)
                             = IR.Copy_Array
                  and then IR.Source_Field_Of
                             (Unit, Routine, Array_Copy) = 2
                  and then IR.Element_Field_Of
                             (Unit, Routine, Array_Copy) = 2
                  and then IR.Op_Of (Unit, Routine, First + 3)
                             = IR.Load_Field
                  and then IR.Op_Of (Unit, Routine, First + 4)
                             = IR.Store_Field,
                  "each inferred initializer uses one compact field run");
               Landin.Testing.Check
                 (Item,
                  Destination.Kind = IR.Frame_Slot
                  and then Destination.Slot = IR.Slot_Id (Copy + 1)
                  and then
                    (if Copy = 0
                     then Source.Kind = IR.Module_Datum
                     else Source.Kind = IR.Frame_Slot
                       and then Source.Slot = 1),
                  "each source feeds the inferred local's fresh slot");
            end;
         end loop;

         Landin.Testing.Check
           (Item, IR.Verifier.Check (Unit).Kind = IR.Verifier.Nothing_Wrong,
            "the inferred initializer field runs verify");
      end;
   end Inferred_Local_Struct_Copies_Into_Its_Fresh_Slot;

   ------------------------------------------------------------------
   --  A named aggregate measurement
   ------------------------------------------------------------------

   procedure A_Struct_Measurement_Carries_Its_Scalar_Fields
     (Item : in out Landin.Testing.Context);

   procedure A_Struct_Measurement_Carries_Its_Scalar_Fields
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "header: type = struct" & LF
         & "    tag: u8" & LF
         & "    address: usize" & LF
         & "    tail: u16" & LF
         & "end header" & LF
         & "alias: type = header" & LF
         & "size: usize = sizeof alias" & LF
         & "align: usize = alignof header" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "direct and aliased struct measurements are accepted");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
      begin
         for Datum in IR.Item_Id'(1) .. 2 loop
            declare
               First : constant IR.Field_Shape :=
                 IR.Nth_Measurement_Field (Unit, Datum, 1, 1);
               Second : constant IR.Field_Shape :=
                 IR.Nth_Measurement_Field (Unit, Datum, 1, 2);
               Third : constant IR.Field_Shape :=
                 IR.Nth_Measurement_Field (Unit, Datum, 1, 3);
            begin
               Landin.Testing.Check
                 (Item,
                  IR.Op_Of (Unit, Datum, 1)
                    in IR.Measure_Size | IR.Measure_Align
                    and then IR.Is_Aggregate_Measurement (Unit, Datum, 1)
                    and then IR.Measurement_Field_Count (Unit, Datum, 1) = 3
                    and then First.Kind = IR.Scalar_Field_Shape
                    and then First.Element = Landin.Types.U8
                    and then Second.Kind = IR.Scalar_Field_Shape
                    and then Second.Element = Landin.Types.Usize
                    and then Third.Kind = IR.Scalar_Field_Shape
                    and then Third.Element = Landin.Types.U16,
                  "each measurement carries declaration-order scalar"
                  & " types");
            end;
         end loop;
         Landin.Testing.Check
           (Item,
            Landin.IR.Verifier.Check (Unit).Kind
              = Landin.IR.Verifier.Nothing_Wrong,
            "the verifier accepts target-neutral aggregate measurements");
      end;
   end A_Struct_Measurement_Carries_Its_Scalar_Fields;

   --  D45: a fixed array remains one measurement field, regardless of its
   --  length.  The backend receives the element and count and derives the
   --  field extent and alignment from its own target facts.
   procedure A_Struct_Measurement_Carries_A_Compact_Array_Field
     (Item : in out Landin.Testing.Context);

   procedure A_Struct_Measurement_Carries_A_Compact_Array_Field
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "header: type = struct" & LF
         & "    tag: u8" & LF
         & "    words: [4294967295]usize" & LF
         & "    tail: u16" & LF
         & "end header" & LF
         & "alias: type = header" & LF
         & "size: usize = sizeof alias" & LF
         & "align: usize = alignof header" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "a target-sized fixed-array field is accepted compactly");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
      begin
         for Datum in IR.Item_Id'(1) .. 2 loop
            declare
               First : constant IR.Field_Shape :=
                 IR.Nth_Measurement_Field (Unit, Datum, 1, 1);
               Array_Field : constant IR.Field_Shape :=
                 IR.Nth_Measurement_Field (Unit, Datum, 1, 2);
               Last : constant IR.Field_Shape :=
                 IR.Nth_Measurement_Field (Unit, Datum, 1, 3);
            begin
               Landin.Testing.Check
                 (Item,
                  IR.Is_Aggregate_Measurement (Unit, Datum, 1)
                    and then IR.Measurement_Field_Count (Unit, Datum, 1) = 3
                    and then First.Kind = IR.Scalar_Field_Shape
                    and then First.Element = Landin.Types.U8
                    and then Array_Field.Kind = IR.Array_Field_Shape
                    and then Array_Field.Element = Landin.Types.Usize
                    and then Array_Field.Length = 4_294_967_295
                    and then Last.Kind = IR.Scalar_Field_Shape
                    and then Last.Element = Landin.Types.U16,
                  "the declaration-order run contains one compact array"
                  & " shape");
            end;
         end loop;
         Landin.Testing.Check
           (Item,
            Landin.IR.Verifier.Check (Unit).Kind
              = Landin.IR.Verifier.Nothing_Wrong,
            "the verifier accepts the compact aggregate measurement");
      end;
   end A_Struct_Measurement_Carries_A_Compact_Array_Field;

   --  D74 first carries the unfolded tag and each case's compact payload
   --  shapes on aggregate measurements; D75 reuses that carrier for storage.
   procedure A_Struct_Measurement_Carries_Variant_Cases
     (Item : in out Landin.Testing.Context);

   procedure A_Struct_Measurement_Carries_Variant_Cases
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "choice: type = struct" & LF
         & "    prefix: u8" & LF
         & "    kind: variant" & LF
         & "        leaf |" & LF
         & "        wide: (word: usize, byte: u8) |" & LF
         & "        row: (values: [3]u16)" & LF
         & "    end kind" & LF
         & "    tail: u16" & LF
         & "end choice" & LF
         & "size: usize = sizeof choice" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "a variant-bearing declaration can be measured");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Shape : constant IR.Field_Shape :=
           IR.Nth_Measurement_Field (Unit, 1, 1, 2);
         Wide_First : constant IR.Field_Shape :=
           IR.Nth_Variant_Case_Field (Unit, Shape, 2, 1);
         Wide_Second : constant IR.Field_Shape :=
           IR.Nth_Variant_Case_Field (Unit, Shape, 2, 2);
         Array_Only : constant IR.Field_Shape :=
           IR.Nth_Variant_Case_Field (Unit, Shape, 3, 1);
      begin
         Landin.Testing.Check
           (Item,
            IR.Is_Aggregate_Measurement (Unit, 1, 1)
              and then IR.Measurement_Field_Count (Unit, 1, 1) = 3
              and then Shape.Kind = IR.Variant_Field_Shape
              and then Shape.Element = Landin.Types.U8
              and then Shape.Cases = 3
              and then IR.Variant_Case_Field_Count (Unit, Shape, 1) = 0
              and then IR.Variant_Case_Field_Count (Unit, Shape, 2) = 2
              and then IR.Variant_Case_Field_Count (Unit, Shape, 3) = 1,
            "the measurement carries one tag and three case runs");
         Landin.Testing.Check
           (Item,
            Wide_First.Kind = IR.Scalar_Field_Shape
              and then Wide_First.Element = Landin.Types.Usize
              and then Wide_Second.Kind = IR.Scalar_Field_Shape
              and then Wide_Second.Element = Landin.Types.U8
              and then Array_Only.Kind = IR.Array_Field_Shape
              and then Array_Only.Element = Landin.Types.U16
              and then Array_Only.Length = 3,
            "payload leaves retain declaration order and compact shapes");
         Landin.Testing.Check
           (Item, IR.Verifier.Check (Unit).Kind = IR.Verifier.Nothing_Wrong,
            "the verifier accepts the shared variant carrier");
      end;
   end A_Struct_Measurement_Carries_Variant_Cases;

   --  D86 carries one named child struct as a measurement-only field run.
   --  The child remains target-neutral: the backend replays these leaves
   --  rather than receiving the checker's target byte size.
   procedure A_Struct_Measurement_Carries_A_Nested_Field
     (Item : in out Landin.Testing.Context);

   procedure A_Struct_Measurement_Carries_A_Nested_Field
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "inner: type = struct" & LF
         & "    byte: u8" & LF
         & "    word: usize" & LF
         & "    row: [3]u16" & LF
         & "end inner" & LF
         & "outer: type = struct" & LF
         & "    prefix: u16" & LF
         & "    nested: inner" & LF
         & "    tail: u8" & LF
         & "end outer" & LF
         & "size: usize = sizeof outer" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "a nested-struct declaration can be measured");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Shape : constant IR.Field_Shape :=
           IR.Nth_Measurement_Field (Unit, 1, 1, 2);
         Byte_Field : constant IR.Field_Shape :=
           IR.Nth_Aggregate_Field (Unit, Shape, 1);
         Word_Field : constant IR.Field_Shape :=
           IR.Nth_Aggregate_Field (Unit, Shape, 2);
         Row_Field : constant IR.Field_Shape :=
           IR.Nth_Aggregate_Field (Unit, Shape, 3);
      begin
         Landin.Testing.Check
           (Item,
            Shape.Kind = IR.Aggregate_Field_Shape
              and then IR.Aggregate_Field_Run_Is_Valid (Unit, Shape)
              and then IR.Aggregate_Field_Count (Unit, Shape) = 3
              and then Byte_Field.Kind = IR.Scalar_Field_Shape
              and then Byte_Field.Element = Landin.Types.U8
              and then Word_Field.Kind = IR.Scalar_Field_Shape
              and then Word_Field.Element = Landin.Types.Usize
              and then Row_Field.Kind = IR.Array_Field_Shape
              and then Row_Field.Element = Landin.Types.U16
              and then Row_Field.Length = 3,
            "the child keeps its declaration-order target-neutral leaves");
         Landin.Testing.Check
           (Item,
            Landin.IR.Verifier.Check (Unit).Kind
              = Landin.IR.Verifier.Nothing_Wrong,
            "the verifier accepts the nested measurement run");
      end;
   end A_Struct_Measurement_Carries_A_Nested_Field;

   --  D87 gives D86's child run to both runtime storage kinds.  A complete
   --  zero image remains one whole-storage clear; the child does not become
   --  one flattened sequence of parent fields.
   procedure Nested_Struct_Storage_Carries_A_Child_Run
     (Item : in out Landin.Testing.Context);

   procedure Nested_Struct_Storage_Carries_A_Child_Run
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "inner: type = struct" & LF
         & "    byte: u8" & LF
         & "    word: usize" & LF
         & "    row: [3]u16" & LF
         & "end inner" & LF
         & "outer: type = struct" & LF
         & "    prefix: u16" & LF
         & "    nested: inner" & LF
         & "    tail: u8" & LF
         & "end outer" & LF
         & "mut state: outer" & LF
         & "clear: () -> none =" & LF
         & "    mut local: outer = zeroed" & LF
         & "    state = zeroed" & LF
         & "end clear" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "nested module and local storage are accepted");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Datum_Shape : constant IR.Field_Shape :=
           IR.Nth_Field_Shape (Unit, 1, 2);
         Slot_Shape : constant IR.Field_Shape :=
           IR.Nth_Slot_Field_Shape (Unit, 2, 1, 2);
         Datum_Row : constant IR.Field_Shape :=
           IR.Nth_Aggregate_Field (Unit, Datum_Shape, 3);
         Slot_Word : constant IR.Field_Shape :=
           IR.Nth_Aggregate_Field (Unit, Slot_Shape, 2);
         Clears : Natural := 0;
         Datum_Clear, Slot_Clear : Boolean := False;
      begin
         Landin.Testing.Check
           (Item,
            Datum_Shape.Kind = IR.Aggregate_Field_Shape
              and then IR.Aggregate_Field_Count (Unit, Datum_Shape) = 3
              and then Datum_Row.Kind = IR.Array_Field_Shape
              and then Datum_Row.Element = Landin.Types.U16
              and then Datum_Row.Length = 3,
            "the datum retains the child's compact declaration-order run");
         Landin.Testing.Check
           (Item,
            Slot_Shape.Kind = IR.Aggregate_Field_Shape
              and then IR.Aggregate_Field_Count (Unit, Slot_Shape) = 3
              and then Slot_Word.Kind = IR.Scalar_Field_Shape
              and then Slot_Word.Element = Landin.Types.Usize,
            "the frame slot carries the same target-neutral child run");

         for Value in 1 .. IR.Value_Count (Unit, 2) loop
            if IR.Op_Of (Unit, 2, IR.Value_Id (Value)) = IR.Clear_Array then
               Clears := Clears + 1;
               case IR.Destination_Of
                 (Unit, 2, IR.Value_Id (Value)).Kind
               is
                  when IR.Frame_Slot => Slot_Clear := True;
                  when IR.Module_Datum => Datum_Clear := True;
               end case;
            end if;
         end loop;
         Landin.Testing.Check
           (Item, Clears = 2 and then Slot_Clear and then Datum_Clear,
            "each explicit zero image is one whole-storage clear");
         Landin.Testing.Check
           (Item, IR.Verifier.Check (Unit).Kind = IR.Verifier.Nothing_Wrong,
            "the verifier accepts nested datum and slot shapes");
      end;
   end Nested_Struct_Storage_Carries_A_Child_Run;

   --  D88 keeps both source-order identities on a scalar operation through
   --  D87's ordinary child.  The target offset remains absent from the IR.
   procedure Nested_Scalar_Fields_Carry_Both_Identities
     (Item : in out Landin.Testing.Context);

   procedure Nested_Scalar_Fields_Carry_Both_Identities
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "inner: type = struct" & LF
         & "    lead: u8" & LF
         & "    value: i32" & LF
         & "end inner" & LF
         & "outer: type = struct" & LF
         & "    prefix: u16" & LF
         & "    nested: inner" & LF
         & "    tail: u8" & LF
         & "end outer" & LF
         & "mut state: outer = zeroed" & LF
         & "use: () -> (r: i32) =" & LF
         & "    mut local: outer" & LF
         & "    state.nested.value = 19" & LF
         & "    local.nested.value = 23" & LF
         & "    r = state.nested.value + local.nested.value" & LF
         & "end use" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "nested scalar reads and writes are accepted");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Loads, Stores : Natural := 0;
         Datum_Load, Slot_Load, Datum_Store, Slot_Store : Boolean := False;
      begin
         for Position in 1 .. IR.Value_Count (Unit, 2) loop
            declare
               Value : constant IR.Value_Id := IR.Value_Id (Position);
               Op : constant IR.Opcode := IR.Op_Of (Unit, 2, Value);
            begin
               if Op in IR.Load_Field | IR.Store_Field
                 and then IR.Nested_Field_Of (Unit, 2, Value) > 0
               then
                  Landin.Testing.Check
                    (Item,
                     IR.Field_Of (Unit, 2, Value) = 2
                       and then IR.Nested_Field_Of (Unit, 2, Value) = 2,
                     "the operation carries parent and child identities");
                  if Op = IR.Load_Field then
                     Loads := Loads + 1;
                     if IR.Reaches_A_Slot (Unit, 2, Value) then
                        Slot_Load := True;
                     else
                        Datum_Load := True;
                     end if;
                  else
                     Stores := Stores + 1;
                     if IR.Reaches_A_Slot (Unit, 2, Value) then
                        Slot_Store := True;
                     else
                        Datum_Store := True;
                     end if;
                  end if;
               end if;
            end;
         end loop;
         Landin.Testing.Check
           (Item,
            Loads = 2 and then Stores = 2
              and then Datum_Load and then Slot_Load
              and then Datum_Store and then Slot_Store,
            "both storage classes carry one nested read and write");
         Landin.Testing.Check
           (Item, IR.Verifier.Check (Unit).Kind = IR.Verifier.Nothing_Wrong,
            "the verifier accepts both nested scalar paths");
      end;
   end Nested_Scalar_Fields_Carry_Both_Identities;

   --  D89 gives an element operation the same two source identities without
   --  flattening the child or recording a target-derived byte offset.
   procedure Nested_Array_Elements_Carry_Both_Identities
     (Item : in out Landin.Testing.Context);

   procedure Nested_Array_Elements_Carry_Both_Identities
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "inner: type = struct" & LF
         & "    lead: u8" & LF
         & "    word: usize" & LF
         & "    row: [3]i32" & LF
         & "end inner" & LF
         & "outer: type = struct" & LF
         & "    prefix: u16" & LF
         & "    nested: inner" & LF
         & "end outer" & LF
         & "mut state: outer = zeroed" & LF
         & "use: (index: usize) -> (r: i32) =" & LF
         & "    mut local: outer = zeroed" & LF
         & "    state.nested.row[index] = 19" & LF
         & "    local.nested.row[index] = 23" & LF
         & "    r = state.nested.row[index]" & LF
         & "      + local.nested.row[index]" & LF
         & "end use" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "nested fixed-array elements are accepted");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Loads, Stores : Natural := 0;
         Datum_Load, Slot_Load, Datum_Store, Slot_Store : Boolean := False;
      begin
         for Position in 1 .. IR.Value_Count (Unit, 2) loop
            declare
               Value : constant IR.Value_Id := IR.Value_Id (Position);
               Op : constant IR.Opcode := IR.Op_Of (Unit, 2, Value);
            begin
               if Op in IR.Load_Element | IR.Store_Element
                 and then IR.Nested_Field_Of (Unit, 2, Value) > 0
               then
                  Landin.Testing.Check
                    (Item,
                     IR.Element_Field_Of (Unit, 2, Value) = 2
                       and then IR.Nested_Field_Of (Unit, 2, Value) = 3,
                     "the operation carries parent and child identities");
                  if Op = IR.Load_Element then
                     Loads := Loads + 1;
                     if IR.Reaches_A_Slot (Unit, 2, Value) then
                        Slot_Load := True;
                        Landin.Testing.Check
                          (Item,
                           IR.Slot_Element_Shape_Is_Valid (Unit, 2, Value)
                           and then IR.Slot_Element_Length
                             (Unit, 2, Value) = 3
                           and then IR.Slot_Element_Type
                             (Unit, 2, Value) = Landin.Types.I32,
                           "the slot accessor follows the child run");
                     else
                        Datum_Load := True;
                     end if;
                  else
                     Stores := Stores + 1;
                     if IR.Reaches_A_Slot (Unit, 2, Value) then
                        Slot_Store := True;
                        Landin.Testing.Check
                          (Item,
                           IR.Slot_Element_Shape_Is_Valid (Unit, 2, Value)
                           and then IR.Slot_Element_Length
                             (Unit, 2, Value) = 3
                           and then IR.Slot_Element_Type
                             (Unit, 2, Value) = Landin.Types.I32,
                           "the slot store accessor follows the child run");
                     else
                        Datum_Store := True;
                     end if;
                  end if;
               end if;
            end;
         end loop;
         Landin.Testing.Check
           (Item,
            Loads = 2 and then Stores = 2
              and then Datum_Load and then Slot_Load
              and then Datum_Store and then Slot_Store,
            "both storage classes carry one nested element read and write");
         Landin.Testing.Check
           (Item, IR.Verifier.Check (Unit).Kind = IR.Verifier.Nothing_Wrong,
            "the verifier accepts both nested array paths");
      end;
   end Nested_Array_Elements_Carry_Both_Identities;

   --  D90 extends D89's two-identity carrier to each contextual whole-array
   --  operation while keeping source and destination paths independent.
   procedure Nested_Array_Values_Carry_Both_Identities
     (Item : in out Landin.Testing.Context);

   procedure Nested_Array_Values_Carry_Both_Identities
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "inner: type = struct" & LF
         & "    lead: u8" & LF
         & "    row: [3]i32" & LF
         & "end inner" & LF
         & "outer: type = struct" & LF
         & "    prefix: u16" & LF
         & "    nested: inner" & LF
         & "end outer" & LF
         & "mut left: outer = zeroed" & LF
         & "mut right: outer = zeroed" & LF
         & "use: () -> none =" & LF
         & "    left.nested.row = [1, 2, 3]" & LF
         & "    right.nested.row = left.nested.row" & LF
         & "    left.nested.row = [of 4]" & LF
         & "    right.nested.row = zeroed" & LF
         & "end use" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "nested contextual array values are accepted");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Stores, Copies, Fills, Clears : Natural := 0;
      begin
         for Position in 1 .. IR.Value_Count (Unit, 3) loop
            declare
               Value : constant IR.Value_Id := IR.Value_Id (Position);
               Op : constant IR.Opcode := IR.Op_Of (Unit, 3, Value);
            begin
               if Op in IR.Store_Element | IR.Copy_Array
                        | IR.Fill_Array | IR.Clear_Array
                 and then IR.Nested_Field_Of (Unit, 3, Value) > 0
               then
                  Landin.Testing.Check
                    (Item,
                     IR.Element_Field_Of (Unit, 3, Value) = 2
                       and then IR.Nested_Field_Of (Unit, 3, Value) = 2,
                     "the destination keeps its parent and child fields");
                  case Op is
                     when IR.Store_Element => Stores := Stores + 1;
                     when IR.Copy_Array =>
                        Copies := Copies + 1;
                        Landin.Testing.Check
                          (Item,
                           IR.Source_Field_Of (Unit, 3, Value) = 2
                           and then IR.Source_Nested_Field_Of
                             (Unit, 3, Value) = 2,
                           "the copy source keeps both field identities");
                     when IR.Fill_Array => Fills := Fills + 1;
                     when IR.Clear_Array => Clears := Clears + 1;
                     when others => null;
                  end case;
               end if;
            end;
         end loop;
         Landin.Testing.Check
           (Item,
            Stores = 3 and then Copies = 1
              and then Fills = 1 and then Clears = 1,
            "literal copy fill and clear use nested array operations");
         Landin.Testing.Check
           (Item, IR.Verifier.Check (Unit).Kind = IR.Verifier.Nothing_Wrong,
            "the verifier accepts every nested whole-array operation");
      end;
   end Nested_Array_Values_Carry_Both_Identities;

   --  D91 uses D87's child shape as a contextual aggregate place.  Scalar
   --  and array leaves retain the parent identity independently at each copy
   --  endpoint; clearing the child remains one compact operation.
   procedure Nested_Child_Values_Keep_Their_Parent
     (Item : in out Landin.Testing.Context);

   procedure Nested_Child_Values_Keep_Their_Parent
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "inner: type = struct" & LF
         & "    value: i32" & LF
         & "    row: [2]i32" & LF
         & "end inner" & LF
         & "outer: type = struct" & LF
         & "    prefix: u16" & LF
         & "    nested: inner" & LF
         & "end outer" & LF
         & "template: inner = (value: 7, row: [3, 4])" & LF
         & "mut left: outer = zeroed" & LF
         & "mut right: outer = zeroed" & LF
         & "use: () -> none =" & LF
         & "    left.nested = zeroed" & LF
         & "    right.nested = (value: 5, row: [1, 2])" & LF
         & "    left.nested = right.nested" & LF
         & "    right.nested = template" & LF
         & "    child_copy: inner = left.nested" & LF
         & "    row_copy: [2]i32 = right.nested.row" & LF
         & "    inferred_child := left.nested" & LF
         & "    inferred_row := right.nested.row" & LF
         & "end use" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "nested child construction and copies are accepted");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Clear, Scalar_Stores, Array_Stores, Array_Copies : Natural := 0;
         Initializer_Copies : Natural := 0;
      begin
         for Position in 1 .. IR.Value_Count (Unit, 4) loop
            declare
               Value : constant IR.Value_Id := IR.Value_Id (Position);
               Op : constant IR.Opcode := IR.Op_Of (Unit, 4, Value);
            begin
               if Op = IR.Clear_Array
                 and then IR.Element_Field_Of (Unit, 4, Value) = 2
               then
                  Clear := Clear + 1;
               elsif Op = IR.Store_Field
                 and then IR.Field_Of (Unit, 4, Value) = 2
                 and then IR.Nested_Field_Of (Unit, 4, Value) = 1
               then
                  Scalar_Stores := Scalar_Stores + 1;
               elsif Op = IR.Store_Element
                 and then IR.Element_Field_Of (Unit, 4, Value) = 2
                 and then IR.Nested_Field_Of (Unit, 4, Value) = 2
               then
                  Array_Stores := Array_Stores + 1;
               elsif Op = IR.Copy_Array
                 and then IR.Element_Field_Of (Unit, 4, Value) = 2
                 and then IR.Nested_Field_Of (Unit, 4, Value) = 2
               then
                  Array_Copies := Array_Copies + 1;
                  Landin.Testing.Check
                    (Item,
                     IR.Source_Field_Of (Unit, 4, Value) = 2
                     and then IR.Source_Nested_Field_Of
                       (Unit, 4, Value) in 0 | 2,
                     "each array source keeps its own parent path");
               elsif Op = IR.Copy_Array
                 and then IR.Source_Nested_Field_Of
                   (Unit, 4, Value) = 2
               then
                  Initializer_Copies := Initializer_Copies + 1;
               end if;
            end;
         end loop;
         Landin.Testing.Check
           (Item,
            Clear = 1 and then Scalar_Stores = 3
              and then Array_Stores = 2 and then Array_Copies = 2
              and then Initializer_Copies = 4,
            "assignments and initializers keep child-qualified IR");
         Landin.Testing.Check
           (Item, IR.Verifier.Check (Unit).Kind = IR.Verifier.Nothing_Wrong,
            "the verifier accepts contextual ordinary-child operations");
      end;
   end Nested_Child_Values_Keep_Their_Parent;

   --  D94 carries a complete aggregate argument as a storage identity and
   --  gives the callee one shaped aggregate parameter slot.
   procedure Struct_Arguments_Carry_Storage_Identity
     (Item : in out Landin.Testing.Context);

   procedure Struct_Arguments_Carry_Storage_Identity
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "pair: type = struct" & LF
         & "    left: i32" & LF
         & "    right: i32" & LF
         & "end pair" & LF
         & "take: (prefix: i32, value: pair) -> (answer: i32) =" & LF
         & "    answer = prefix + value.left + value.right" & LF
         & "end take" & LF
         & "use: () -> (answer: i32) =" & LF
         & "    mut value: pair" & LF
         & "    value.left = 2" & LF
         & "    value.right = 3" & LF
         & "    answer = take(1, value)" & LF
         & "end use" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "a direct ordinary-struct argument is accepted");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Parameter : constant IR.Slot_Id := IR.Nth_Parameter (Unit, 1, 2);
         Addresses, Calls : Natural := 0;
      begin
         Landin.Testing.Check
           (Item,
            IR.Is_Aggregate (Unit, 1, Parameter)
              and then IR.Slot_Field_Count (Unit, 1, Parameter) = 2,
            "the callee parameter keeps its target-neutral shape");
         for Position in 1 .. IR.Value_Count (Unit, 2) loop
            declare
               Value : constant IR.Value_Id := IR.Value_Id (Position);
            begin
               if IR.Op_Of (Unit, 2, Value) = IR.Storage_Address then
                  Addresses := Addresses + 1;
               elsif IR.Op_Of (Unit, 2, Value) = IR.Call then
                  Calls := Calls + 1;
                  Landin.Testing.Check
                    (Item, IR.Operand_Count (Unit, 2, Value) = 2,
                     "the aggregate occupies one source argument position");
               end if;
            end;
         end loop;
         Landin.Testing.Check
           (Item, Addresses = 1 and then Calls = 1,
            "the caller carries one complete storage address");
         Landin.Testing.Check
           (Item, IR.Verifier.Check (Unit).Kind = IR.Verifier.Nothing_Wrong,
            "the verifier accepts the internal aggregate carrier");
      end;
   end Struct_Arguments_Carry_Storage_Identity;

   --  D75 gives D74's target-neutral carrier to both module and frame
   --  storage.  The zero image remains one whole-storage clear, not one
   --  instruction per tag, payload field, or padding byte.
   procedure Variant_Storage_Carries_Cases_And_One_Clear
     (Item : in out Landin.Testing.Context);

   procedure Variant_Storage_Carries_Cases_And_One_Clear
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "choice: type = struct" & LF
         & "    prefix: u8" & LF
         & "    kind: variant" & LF
         & "        leaf |" & LF
         & "        wide: (word: usize, byte: u8) |" & LF
         & "        row: (values: [3]u16)" & LF
         & "    end kind" & LF
         & "    tail: u16" & LF
         & "end choice" & LF
         & "mut state: choice" & LF
         & "clear: () -> none =" & LF
         & "    mut local: choice = zeroed" & LF
         & "    state = zeroed" & LF
         & "end clear" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "variant-bearing module and local storage are accepted");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Datum_Shape : constant IR.Field_Shape :=
           IR.Nth_Field_Shape (Unit, 1, 2);
         Slot_Shape : constant IR.Field_Shape :=
           IR.Nth_Slot_Field_Shape (Unit, 2, 1, 2);
         Clears : Natural := 0;
         Datum_Clear, Slot_Clear : Boolean := False;
      begin
         Landin.Testing.Check
           (Item,
            Datum_Shape.Kind = IR.Variant_Field_Shape
              and then Datum_Shape.Cases = 3
              and then IR.Variant_Case_Field_Count
                (Unit, Datum_Shape, 1) = 0
              and then IR.Variant_Case_Field_Count
                (Unit, Datum_Shape, 2) = 2
              and then IR.Variant_Case_Field_Count
                (Unit, Datum_Shape, 3) = 1,
            "the datum carries every compact case payload");
         Landin.Testing.Check
           (Item,
            Slot_Shape.Kind = IR.Variant_Field_Shape
              and then Slot_Shape.Cases = 3
              and then IR.Nth_Variant_Case_Field
                (Unit, Slot_Shape, 3, 1).Kind = IR.Array_Field_Shape
              and then IR.Nth_Variant_Case_Field
                (Unit, Slot_Shape, 3, 1).Length = 3,
            "the frame slot carries the same variant shape");

         for Value in 1 .. IR.Value_Count (Unit, 2) loop
            if IR.Op_Of (Unit, 2, IR.Value_Id (Value)) = IR.Clear_Array then
               Clears := Clears + 1;
               declare
                  Destination : constant IR.Storage :=
                    IR.Destination_Of (Unit, 2, IR.Value_Id (Value));
               begin
                  case Destination.Kind is
                     when IR.Frame_Slot => Slot_Clear := True;
                     when IR.Module_Datum => Datum_Clear := True;
                  end case;
               end;
            end if;
         end loop;
         Landin.Testing.Check
           (Item, Clears = 2 and then Slot_Clear and then Datum_Clear,
            "each explicit zero image is one whole-storage clear");
         Landin.Testing.Check
           (Item, IR.Verifier.Check (Unit).Kind = IR.Verifier.Nothing_Wrong,
            "the verifier accepts both runtime variant carriers");
      end;
   end Variant_Storage_Carries_Cases_And_One_Clear;

   --  D76 keeps case construction contextual: selection clears one complete
   --  part and writes its source-order tag, while each labelled scalar
   --  payload field is a separate ordered write into that selected case.
   procedure Variant_Case_Construction_Carries_Its_Identity
     (Item : in out Landin.Testing.Context);

   procedure Variant_Case_Construction_Carries_Its_Identity
     (Item : in out Landin.Testing.Context)
   is
      use type IR.Storage_Kind;

      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "choice: type = struct" & LF
         & "    prefix: u8" & LF
         & "    kind: variant" & LF
         & "        leaf |" & LF
         & "        pair: (first: u8, second: u16) |" & LF
         & "        row: (finite: [2]u32, repeated: [2]u32,"
         & " copied: [2]u32)" & LF
         & "    end kind" & LF
         & "end choice" & LF
         & "mut state: choice" & LF
         & "construct: () -> none =" & LF
         & "    mut words: [2]u32 = [7, 8]" & LF
         & "    mut local: choice = (prefix: 1, kind: leaf)" & LF
         & "    mut inferred := choice(prefix: 4,"
         & " kind: pair(first: 5, second: 6))" & LF
         & "    local.kind = row(finite: [9, 10],"
         & " repeated: [2 of 11], copied: words)" & LF
         & "    state.kind = pair(first: 2, second: 3)" & LF
         & "    match local.kind" & LF
         & "        leaf: _ = 1" & LF
         & "        pair(first, inout second): if true then" & LF
         & "            _ = first" & LF
         & "            second = second" & LF
         & "        end if" & LF
         & "        row(finite, repeated, inout copied): if true then" & LF
         & "            _ = finite[0]" & LF
         & "            _ = repeated[1]" & LF
         & "            copied[0] = finite[1]" & LF
         & "        end if" & LF
         & "    end match" & LF
         & "    match state.kind" & LF
         & "        leaf: _ = 1" & LF
         & "        pair: _ = 2" & LF
         & "        row(finite, repeated, inout copied): if true then" & LF
         & "            _ = finite[0]" & LF
         & "            copied[1] = repeated[0]" & LF
         & "        end if" & LF
         & "    end match" & LF
         & "end construct" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "variant case construction is accepted");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Selects, Stores, Tag_Loads, Payload_Loads : Natural := 0;
         Array_Loads, Array_Stores, Array_Fills, Array_Copies : Natural := 0;
         Slot_Row, Slot_Pair, Datum_Pair, Wide_Payload : Boolean := False;
         Slot_Tag, Datum_Tag : Boolean := False;
         Nested_Store, Nested_Fill, Nested_Copy : Boolean := False;
         Nested_Slot_Load, Nested_Datum_Load : Boolean := False;
         Nested_Alias_Slot_Store, Nested_Alias_Datum_Store : Boolean := False;
      begin
         for Value in 1 .. IR.Value_Count (Unit, 2) loop
            declare
               Id : constant IR.Value_Id := IR.Value_Id (Value);
               Op : constant IR.Opcode := IR.Op_Of (Unit, 2, Id);
            begin
               if Op = IR.Select_Variant then
                  Selects := Selects + 1;
                  declare
                     Destination : constant IR.Storage :=
                       IR.Destination_Of (Unit, 2, Id);
                  begin
                     Slot_Row := Slot_Row or else
                       (Destination.Kind = IR.Frame_Slot
                        and then IR.Element_Field_Of (Unit, 2, Id) = 2
                        and then IR.Variant_Case_Of (Unit, 2, Id) = 3);
                     Slot_Pair := Slot_Pair or else
                       (Destination.Kind = IR.Frame_Slot
                        and then IR.Element_Field_Of (Unit, 2, Id) = 2
                        and then IR.Variant_Case_Of (Unit, 2, Id) = 2);
                     Datum_Pair := Datum_Pair or else
                       (Destination.Kind = IR.Module_Datum
                        and then Destination.Datum = 1
                        and then IR.Element_Field_Of (Unit, 2, Id) = 2
                        and then IR.Variant_Case_Of (Unit, 2, Id) = 2);
                  end;
               elsif Op = IR.Store_Variant_Field then
                  Stores := Stores + 1;
                  Wide_Payload := Wide_Payload or else
                    (IR.Destination_Of (Unit, 2, Id).Kind = IR.Module_Datum
                     and then IR.Variant_Case_Of (Unit, 2, Id) = 2
                     and then IR.Variant_Payload_Field_Of
                       (Unit, 2, Id) = 2
                     and then IR.Result_Of
                       (Unit, 2, IR.Nth_Operand (Unit, 2, Id, 1))
                         = Landin.Types.U16);
               elsif Op = IR.Load_Variant_Tag then
                  Tag_Loads := Tag_Loads + 1;
                  declare
                     Source : constant IR.Storage :=
                       IR.Source_Of (Unit, 2, Id);
                  begin
                     Slot_Tag := Slot_Tag or else
                       (Source.Kind = IR.Frame_Slot
                        and then IR.Element_Field_Of (Unit, 2, Id) = 2
                        and then IR.Result_Of (Unit, 2, Id)
                          = Landin.Types.U8);
                     Datum_Tag := Datum_Tag or else
                       (Source.Kind = IR.Module_Datum
                        and then Source.Datum = 1
                        and then IR.Element_Field_Of (Unit, 2, Id) = 2
                        and then IR.Result_Of (Unit, 2, Id)
                          = Landin.Types.U8);
                  end;
               elsif Op = IR.Load_Variant_Field then
                  Payload_Loads := Payload_Loads + 1;
                  Landin.Testing.Check
                    (Item,
                     IR.Source_Of (Unit, 2, Id).Kind = IR.Frame_Slot
                     and then IR.Element_Field_Of (Unit, 2, Id) = 2
                     and then IR.Variant_Case_Of (Unit, 2, Id) = 2
                     and then IR.Variant_Payload_Field_Of
                       (Unit, 2, Id) in 1 | 2,
                     "payload aliases carry their selected source");
               elsif Op = IR.Load_Element then
                  Array_Loads := Array_Loads + 1;
                  Nested_Slot_Load := Nested_Slot_Load or else
                    (IR.Reaches_A_Slot (Unit, 2, Id)
                     and then IR.Element_Field_Of (Unit, 2, Id) = 2
                     and then IR.Variant_Case_Of (Unit, 2, Id) = 3
                     and then IR.Variant_Payload_Field_Of
                       (Unit, 2, Id) in 1 | 2);
                  Nested_Datum_Load := Nested_Datum_Load or else
                    (not IR.Reaches_A_Slot (Unit, 2, Id)
                     and then IR.Datum_Of (Unit, 2, Id) = 1
                     and then IR.Element_Field_Of (Unit, 2, Id) = 2
                     and then IR.Variant_Case_Of (Unit, 2, Id) = 3
                     and then IR.Variant_Payload_Field_Of
                       (Unit, 2, Id) in 1 | 2);
               elsif Op = IR.Store_Element then
                  Array_Stores := Array_Stores + 1;
                  Nested_Store := Nested_Store or else
                    (IR.Reaches_A_Slot (Unit, 2, Id)
                     and then IR.Element_Field_Of (Unit, 2, Id) = 2
                     and then IR.Variant_Case_Of (Unit, 2, Id) = 3
                     and then IR.Variant_Payload_Field_Of
                       (Unit, 2, Id) = 1);
                  Nested_Alias_Slot_Store := Nested_Alias_Slot_Store or else
                    (IR.Reaches_A_Slot (Unit, 2, Id)
                     and then IR.Element_Field_Of (Unit, 2, Id) = 2
                     and then IR.Variant_Case_Of (Unit, 2, Id) = 3
                     and then IR.Variant_Payload_Field_Of
                       (Unit, 2, Id) = 3);
                  Nested_Alias_Datum_Store :=
                    Nested_Alias_Datum_Store or else
                    (not IR.Reaches_A_Slot (Unit, 2, Id)
                     and then IR.Datum_Of (Unit, 2, Id) = 1
                     and then IR.Element_Field_Of (Unit, 2, Id) = 2
                     and then IR.Variant_Case_Of (Unit, 2, Id) = 3
                     and then IR.Variant_Payload_Field_Of
                       (Unit, 2, Id) = 3);
               elsif Op = IR.Fill_Array then
                  Array_Fills := Array_Fills + 1;
                  Nested_Fill := Nested_Fill or else
                    (IR.Destination_Of (Unit, 2, Id).Kind = IR.Frame_Slot
                     and then IR.Element_Field_Of (Unit, 2, Id) = 2
                     and then IR.Variant_Case_Of (Unit, 2, Id) = 3
                     and then IR.Variant_Payload_Field_Of
                       (Unit, 2, Id) = 2);
               elsif Op = IR.Copy_Array then
                  Array_Copies := Array_Copies + 1;
                  Nested_Copy := Nested_Copy or else
                    (IR.Destination_Of (Unit, 2, Id).Kind = IR.Frame_Slot
                     and then IR.Source_Of (Unit, 2, Id).Kind = IR.Frame_Slot
                     and then IR.Element_Field_Of (Unit, 2, Id) = 2
                     and then IR.Variant_Case_Of (Unit, 2, Id) = 3
                     and then IR.Variant_Payload_Field_Of
                       (Unit, 2, Id) = 3
                     and then IR.Source_Field_Of (Unit, 2, Id) = 0);
               end if;
            end;
         end loop;

         Landin.Testing.Check
           (Item, Selects = 4 and then Stores = 5,
            "case construction and inout aliases write scalar payloads");
         Landin.Testing.Check_Equal
           (Item, Payload_Loads, 2,
            "each referenced payload alias loads from matched storage");
         Landin.Testing.Check
           (Item,
            Slot_Row and then Slot_Pair and then Datum_Pair
              and then Wide_Payload,
            "storage, part, case, payload and scalar type all survive");
         Landin.Testing.Check
           (Item, Tag_Loads = 2 and then Slot_Tag and then Datum_Tag,
            "each match loads its source storage and field exactly once");
         Landin.Testing.Check
           (Item,
            Array_Loads = 5 and then Array_Stores = 4
              and then Array_Fills = 1
              and then Array_Copies = 1 and then Nested_Store
              and then Nested_Fill and then Nested_Copy,
            "array writes carry top field, case and payload identities");
         Landin.Testing.Check
           (Item,
            Nested_Slot_Load and then Nested_Datum_Load
              and then Nested_Alias_Slot_Store
              and then Nested_Alias_Datum_Store,
            "array payload aliases retain both selected storage kinds");
         Landin.Testing.Check
           (Item, IR.Verifier.Check (Unit).Kind = IR.Verifier.Nothing_Wrong,
            "the verifier accepts lowered variant operations");
      end;
   end Variant_Case_Construction_Carries_Its_Identity;

   --  D80 keeps whole variant-bearing copies contextual to storage.  Each
   --  common scalar or array field retains its old operation, while the
   --  complete unfolded variant part travels as one Copy_Variant identity.
   procedure Variant_Whole_Copy_Carries_One_Compact_Part
     (Item : in out Landin.Testing.Context);

   procedure Variant_Whole_Copy_Carries_One_Compact_Part
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "choice: type = struct" & LF
         & "    prefix: u8" & LF
         & "    values: [2]u16" & LF
         & "    kind: variant" & LF
         & "        leaf |" & LF
         & "        pair: (first: u8, second: u16)" & LF
         & "    end kind" & LF
         & "end choice" & LF
         & "mut state: choice" & LF
         & "copy: () -> none =" & LF
         & "    mut source := choice(prefix: 1, values: zeroed,"
         & " kind: pair(first: 2, second: 3))" & LF
         & "    mut typed: choice = source" & LF
         & "    mut inferred := source" & LF
         & "    state = typed" & LF
         & "    typed = inferred" & LF
         & "end copy" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "typed, inferred and assigned whole copies are accepted");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Variant_Copies, Array_Copies : Natural := 0;
      begin
         for Value in 1 .. IR.Value_Count (Unit, 2) loop
            declare
               Id : constant IR.Value_Id := IR.Value_Id (Value);
            begin
               case IR.Op_Of (Unit, 2, Id) is
                  when IR.Copy_Variant =>
                     Variant_Copies := Variant_Copies + 1;
                     Landin.Testing.Check
                       (Item,
                        IR.Source_Field_Of (Unit, 2, Id) = 3
                          and then IR.Element_Field_Of (Unit, 2, Id) = 3,
                        "the complete variant part keeps its field identity");
                  when IR.Copy_Array =>
                     Array_Copies := Array_Copies + 1;
                     Landin.Testing.Check
                       (Item,
                        IR.Source_Field_Of (Unit, 2, Id) = 2
                          and then IR.Element_Field_Of (Unit, 2, Id) = 2,
                        "the common fixed array keeps D54's copy operation");
                  when others =>
                     null;
               end case;
            end;
         end loop;
         Landin.Testing.Check
           (Item, Variant_Copies = 4 and then Array_Copies = 4,
            "each whole copy moves one array and one variant part");
         Landin.Testing.Check
           (Item, IR.Verifier.Check (Unit).Kind = IR.Verifier.Nothing_Wrong,
            "the verifier accepts every lowered whole copy");
      end;
   end Variant_Whole_Copy_Carries_One_Compact_Part;

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

   --  D64 commits labelled scalar fields in source order, then writes the
   --  omitted fields in declaration order.  D72's nominal spelling reaches
   --  the same direct-destination path.  A fixed-array omission reuses D49's
   --  field-qualified clear rather than expanding the array extent.
   procedure A_Struct_Literal_Becomes_Ordered_Field_Writes
     (Item : in out Landin.Testing.Context);

   procedure A_Struct_Literal_Becomes_Ordered_Field_Writes
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "holder: type = struct" & LF
         & "    first: i32" & LF
         & "    row: [2]usize" & LF
         & "    second: i32" & LF
         & "    ready: bool" & LF
         & "end holder" & LF
         & "mut state: holder" & LF
         & "f: () -> none =" & LF
         & "    state = holder(second: state.first + 1, first: 10,"
         & " of zeroed)" & LF
         & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "the contextual struct literal lowers");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Routine : IR.Item_Id := IR.No_Item;
         type Part_List is array (Positive range <>) of IR.Part_Position;
         Parts : Part_List (1 .. 3) := [others => 1];
         Stores : Natural := 0;
         Clears : Natural := 0;
      begin
         for Which in 1 .. IR.Item_Count (Unit) loop
            if IR.Kind_Of (Unit, IR.Item_Id (Which)) = IR.Routine then
               Routine := IR.Item_Id (Which);
            end if;
         end loop;

         Landin.Testing.Check
           (Item, Routine /= IR.No_Item, "the function is a routine");

         if Routine /= IR.No_Item then
            for V in 1 .. IR.Value_Count (Unit, Routine) loop
               declare
                  Value : constant IR.Value_Id := IR.Value_Id (V);
                  Op : constant IR.Opcode := IR.Op_Of (Unit, Routine, Value);
               begin
                  if Op = IR.Store_Field then
                     Stores := Stores + 1;
                     if Stores <= Parts'Length then
                        Parts (Stores) :=
                          IR.Field_Of (Unit, Routine, Value);
                     end if;
                  elsif Op = IR.Clear_Array then
                     Clears := Clears + 1;
                     Landin.Testing.Check_Equal
                       (Item, IR.Element_Field_Of (Unit, Routine, Value), 2,
                        "the omitted array is cleared as field two");
                  end if;
               end;
            end loop;
         end if;

         Landin.Testing.Check_Equal
           (Item, Stores, 3, "two labelled and one filled scalar are stored");
         Landin.Testing.Check
           (Item, Parts = Part_List'(3, 1, 4),
            "labelled stores keep source order before declaration-order fill");
         Landin.Testing.Check_Equal
           (Item, Clears, 1, "one compact array-field clear is emitted");
         Check_Terminators (Item, Unit, "a struct literal");
      end;
   end A_Struct_Literal_Becomes_Ordered_Field_Writes;

   --  D65 reuses the field-qualified D49--D53 operations for each labelled
   --  fixed-array field; a scalar `zeroed` label takes the existing typed
   --  scalar store path.  No aggregate or array temporary is introduced.
   procedure Struct_Literal_Array_Labels_Use_Field_Operations
     (Item : in out Landin.Testing.Context);

   procedure Struct_Literal_Array_Labels_Use_Field_Operations
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "holder: type = struct" & LF
         & "    row: [2]usize" & LF
         & "    other: [2]usize" & LF
         & "    ready: bool" & LF
         & "end holder" & LF
         & "source: [2]usize = [1, 2]" & LF
         & "mut state: holder" & LF
         & "f: () -> none =" & LF
         & "    state = (row: [3, 4], other: source,"
         & " ready: zeroed)" & LF
         & "    state = (row: [2 of 5], other: zeroed, ready: true)" & LF
         & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "every contextual field form lowers");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Routine : IR.Item_Id := IR.No_Item;
         Element_Stores : Natural := 0;
         Copy, Fill, Clear : IR.Value_Id := IR.No_Value;
         False_Store : IR.Value_Id := IR.No_Value;
      begin
         for Which in 1 .. IR.Item_Count (Unit) loop
            if IR.Kind_Of (Unit, IR.Item_Id (Which)) = IR.Routine then
               Routine := IR.Item_Id (Which);
            end if;
         end loop;

         Landin.Testing.Check
           (Item, Routine /= IR.No_Item, "the function is a routine");

         if Routine /= IR.No_Item then
            for V in 1 .. IR.Value_Count (Unit, Routine) loop
               declare
                  Value : constant IR.Value_Id := IR.Value_Id (V);
                  Op : constant IR.Opcode := IR.Op_Of (Unit, Routine, Value);
               begin
                  case Op is
                     when IR.Store_Element =>
                        if IR.Element_Field_Of (Unit, Routine, Value) = 1
                        then
                           Element_Stores := Element_Stores + 1;
                        end if;
                     when IR.Copy_Array =>
                        Copy := Value;
                     when IR.Fill_Array =>
                        Fill := Value;
                     when IR.Clear_Array =>
                        Clear := Value;
                     when IR.Store_Field =>
                        if IR.Field_Of (Unit, Routine, Value) = 3
                          and then IR.Op_Of
                            (Unit, Routine,
                             IR.Nth_Operand (Unit, Routine, Value, 1))
                              = IR.Truth
                          and then not IR.Truth_Of
                            (Unit, Routine,
                             IR.Nth_Operand (Unit, Routine, Value, 1))
                        then
                           False_Store := Value;
                        end if;
                     when others =>
                        null;
                  end case;
               end;
            end loop;
         end if;

         Landin.Testing.Check_Equal
           (Item, Element_Stores, 2,
            "the literal writes two elements through field one");
         Landin.Testing.Check
           (Item,
            Copy /= IR.No_Value
            and then IR.Source_Field_Of (Unit, Routine, Copy) = 0
            and then IR.Element_Field_Of (Unit, Routine, Copy) = 2,
            "the direct source copies into field two");
         Landin.Testing.Check
           (Item,
            Fill /= IR.No_Value
            and then IR.Element_Field_Of (Unit, Routine, Fill) = 1,
            "repetition fills field one");
         Landin.Testing.Check
           (Item,
            Clear /= IR.No_Value
            and then IR.Element_Field_Of (Unit, Routine, Clear) = 2,
            "zeroed clears field two");
         Landin.Testing.Check
           (Item, False_Store /= IR.No_Value,
            "scalar zeroed stores typed false in field three");
         Check_Terminators (Item, Unit, "struct literal array labels");
      end;
   end Struct_Literal_Array_Labels_Use_Field_Operations;

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
        (Into, "lowering", "a zeroed module scalar reuses zero IR",
         A_Zeroed_Module_Scalar_Reuses_The_Zero_IR'Access);
      Landin.Testing.Register
        (Into, "lowering", "local scalar zeroed uses constant stores",
         Local_Scalar_Zeroed_Uses_The_Constant_Store_Path'Access);
      Landin.Testing.Register
        (Into, "lowering", "scalar zeroed assignment uses ordinary stores",
         Scalar_Zeroed_Assignment_Uses_Ordinary_Stores'Access);
      Landin.Testing.Register
        (Into, "lowering", "named return zeroed uses ordinary store",
         Named_Return_Zeroed_Uses_The_Ordinary_Store'Access);
      Landin.Testing.Register
        (Into, "lowering", "subobject zeroed uses ordinary stores",
         Scalar_Subobject_Zeroed_Uses_Ordinary_Stores'Access);
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
        (Into, "lowering", "a struct local carries its field shapes",
         A_Struct_Local_Carries_Its_Field_Shapes'Access);
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
        (Into, "lowering", "a mixed repetition becomes stores and one fill",
         A_Mixed_Repetition_Becomes_Prefix_Stores_And_One_Fill'Access);
      Landin.Testing.Register
        (Into, "lowering", "mixed assignment becomes stores and one fill",
         Mixed_Assignment_Becomes_Prefix_Stores_And_One_Fill'Access);
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
        (Into, "lowering", "zeroed array field carries its field",
         Zeroed_Array_Field_Carries_Its_Containing_Field'Access);
      Landin.Testing.Register
        (Into, "lowering", "array field copy carries both fields",
         Array_Field_Copy_Carries_Both_Endpoint_Fields'Access);
      Landin.Testing.Register
        (Into, "lowering", "array field initializer carries source field",
         Array_Field_Initializer_Carries_Its_Source_Field'Access);
      Landin.Testing.Register
        (Into, "lowering", "a module array literal records its image",
         A_Module_Array_Literal_Records_Its_Image'Access);
      Landin.Testing.Register
        (Into, "lowering",
         "a module array chain copies the terminal image",
         A_Module_Array_Chain_Copies_The_Terminal_Image'Access);
      Landin.Testing.Register
        (Into, "lowering",
         "a module array copies a struct field image",
         A_Module_Array_Copies_A_Struct_Field_Image'Access);
      Landin.Testing.Register
        (Into, "lowering",
         "a struct field copies a struct field image",
         A_Module_Struct_Field_Copies_A_Struct_Field_Image'Access);
      Landin.Testing.Register
        (Into, "lowering",
         "a module struct literal records and copies its image",
         A_Module_Struct_Literal_Records_And_Copies_Its_Image'Access);
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
         "an array field element carries its containing field",
         An_Array_Field_Element_Carries_Its_Containing_Field'Access);
      Landin.Testing.Register
        (Into, "lowering",
         "array field literals become field-qualified element stores",
         Array_Field_Literals_Become_Field_Qualified_Element_Stores'Access);
      Landin.Testing.Register
        (Into, "lowering", "array field repetitions become qualified fills",
         Array_Field_Repetitions_Become_Qualified_Fills'Access);
      Landin.Testing.Register
        (Into, "lowering",
         "array-bearing struct copy uses compact field operations",
         Array_Bearing_Struct_Copy_Uses_Compact_Field_Operations'Access);
      Landin.Testing.Register
        (Into, "lowering", "local struct initializer copies to fresh slot",
         Local_Struct_Initializer_Copies_Into_Its_Fresh_Slot'Access);
      Landin.Testing.Register
        (Into, "lowering", "inferred local struct copies to fresh slot",
         Inferred_Local_Struct_Copies_Into_Its_Fresh_Slot'Access);
      Landin.Testing.Register
        (Into, "lowering",
         "a struct measurement carries its scalar fields",
         A_Struct_Measurement_Carries_Its_Scalar_Fields'Access);
      Landin.Testing.Register
        (Into, "lowering",
         "a struct measurement keeps an array compact",
         A_Struct_Measurement_Carries_A_Compact_Array_Field'Access);
      Landin.Testing.Register
        (Into, "lowering",
         "a struct measurement carries variant case runs",
         A_Struct_Measurement_Carries_Variant_Cases'Access);
      Landin.Testing.Register
        (Into, "lowering",
         "a struct measurement carries a nested field run",
         A_Struct_Measurement_Carries_A_Nested_Field'Access);
      Landin.Testing.Register
        (Into, "lowering",
         "nested struct storage carries a child field run",
         Nested_Struct_Storage_Carries_A_Child_Run'Access);
      Landin.Testing.Register
        (Into, "lowering",
         "nested scalar fields carry both identities",
         Nested_Scalar_Fields_Carry_Both_Identities'Access);
      Landin.Testing.Register
        (Into, "lowering",
         "nested array elements carry both identities",
         Nested_Array_Elements_Carry_Both_Identities'Access);
      Landin.Testing.Register
        (Into, "lowering",
         "nested array values carry both identities",
         Nested_Array_Values_Carry_Both_Identities'Access);
      Landin.Testing.Register
        (Into, "lowering",
         "nested child values keep their parent",
         Nested_Child_Values_Keep_Their_Parent'Access);
      Landin.Testing.Register
        (Into, "lowering",
         "struct arguments carry storage identity",
         Struct_Arguments_Carry_Storage_Identity'Access);
      Landin.Testing.Register
        (Into, "lowering",
         "variant storage carries cases and one clear",
         Variant_Storage_Carries_Cases_And_One_Clear'Access);
      Landin.Testing.Register
        (Into, "lowering",
         "variant case construction carries its identity",
         Variant_Case_Construction_Carries_Its_Identity'Access);
      Landin.Testing.Register
        (Into, "lowering",
         "variant whole copy carries one compact part",
         Variant_Whole_Copy_Carries_One_Compact_Part'Access);
      Landin.Testing.Register
        (Into, "lowering",
         "an internal empty array has identity measurements",
         An_Internal_Empty_Array_Has_Identity_Measurements'Access);
      Landin.Testing.Register
        (Into, "lowering", "a struct literal becomes ordered field writes",
         A_Struct_Literal_Becomes_Ordered_Field_Writes'Access);
      Landin.Testing.Register
        (Into, "lowering",
         "struct literal array labels use field operations",
         Struct_Literal_Array_Labels_Use_Field_Operations'Access);
      Landin.Testing.Register
        (Into, "lowering", "the recorded corpus is current",
         The_Recorded_Corpus_Is_Current'Access);
   end Register;

end Landin.Tests.Lowering_Suite;
