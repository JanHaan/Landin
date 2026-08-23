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

with Landin.IR;
with Landin.Source;
with Landin.Stages.Checking;
with Landin.Stages.Lowering;
with Landin.Stages.Resolution;
with Landin.Stages.Syntax;
with Landin.Targets;
with Landin.Types;

package body Landin.Tests.Lowering_Suite is

   package IR renames Landin.IR;

   use type IR.Item_Kind;
   use type IR.Opcode;
   use type IR.Slot_Id;
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
   end Register;

end Landin.Tests.Lowering_Suite;
