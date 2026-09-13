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

with Ada.Containers.Vectors;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Landin.Checking;
with Landin.Configuration;
with Landin.IR;
with Landin.IR.Dump;
with Landin.IR.Verifier;
with Landin.Modules;
with Landin.Platform;
with Landin.Platform.Native;
with Landin.Testing.Fixtures;
with Landin.Resolution;
with Landin.Source;
with Landin.Source.Names;
with Landin.Syntax;
with Landin.Syntax.Forest;
with Landin.Stages.Checking;
with Landin.Stages.Configuration;
with Landin.Stages.Lowering;
with Landin.Stages.Resolution;
with Landin.Stages.Syntax;
with Landin.Targets;
with Landin.Types;

package body Landin.Tests.Lowering_Suite is

   package IR renames Landin.IR;

   use type IR.Aggregate_Field_Image;
   use type IR.Field_Shape;
   use type IR.Field_Shape_Kind;
   use type IR.Field_Image_Form;

   use type IR.Block_Id;
   use type IR.Declaration_Id;
   use type IR.Element_Total;
   use type IR.Item_Id;
   use type IR.Item_Kind;
   use type IR.Nominal_Type_Id;
   use type Landin.Modules.Module_Id;
   use type Landin.Platform.List_Status;
   use type Landin.Platform.Read_Status;
   use type Landin.Platform.Write_Status;
   use type Landin.Testing.Fixtures.Fixture_Class;
   use type IR.Opcode;
   use type IR.Signature_Id;
   use type IR.Slot_Id;
   use type IR.Part_Position;
   use type IR.Value_Id;
   use type Landin.IR.Verifier.Fault_Kind;
   use type Landin.Source.Source_Id;
   use type Landin.Types.Folded;
   use type Landin.Types.Magnitude;
   use type Landin.Types.Type_Kind;
   use type IR.Path_Step_Array;

   --  D118: the path one depth-one child identity spells, so a case can
   --  ask for it without writing the run out at every comparison.
   function Below (Child : Natural) return IR.Path_Step_Array
     is (if Child = 0 then IR.No_Path_Steps
         else [1 => (Field      => IR.Part_Position (Child),
                     Case_Index => 0)]);

   function Below
     (Parent : Positive; Child : Positive) return IR.Path_Step_Array
     is [1 => (Field      => IR.Part_Position (Parent),
               Case_Index => 0),
         2 => (Field      => IR.Part_Position (Child),
               Case_Index => 0)];

   function In_Case
     (Which : Positive; Child : Positive) return IR.Path_Step_Array
     is [1 => (Field      => IR.Part_Position (Child),
               Case_Index => Which)];

   function In_Case
     (Which   : Positive;
      Child   : Positive;
      Element : Positive) return IR.Path_Step_Array
     is [1 => (Field      => IR.Part_Position (Child),
               Case_Index => Which),
         2 => (Field      => IR.Part_Position (Element),
               Case_Index => 0)];

   --  A Number value keeps its magnitude and unary-minus marker in separate
   --  IR fields; assertions compare the complete signed folded value.
   function Folded_Number_Of
     (Of_Unit : IR.Unit; Item : IR.Item_Id; Value : IR.Value_Id)
      return Landin.Types.Folded
   is (if IR.Is_Negated (Of_Unit, Item, Value)
       then -Landin.Types.Folded
              (IR.Number_Of (Of_Unit, Item, Value))
       else Landin.Types.Folded
              (IR.Number_Of (Of_Unit, Item, Value)));

   Frontend : aliased Landin.Stages.Syntax.Instance;
   Names    : aliased Landin.Stages.Resolution.Instance;
   Configurer : aliased Landin.Stages.Configuration.Instance;
   Checker  : aliased Landin.Stages.Checking.Instance;
   Lowerer  : aliased Landin.Stages.Lowering.Instance;

   LF : constant Character := Character'Val (10);

   procedure Lower
     (Work       : in out Landin.Stages.Compilation;
      Text       : String;
      Ran        : out Natural;
      Additional : String := "");

   procedure Lower
     (Work       : in out Landin.Stages.Compilation;
      Text       : String;
      Ran        : out Natural;
      Additional : String := "")
   is
      Order   : Landin.Stages.Pipeline;
      Written : constant Landin.Source.Source_Id :=
        Landin.Stages.Add_Source (Work, "low.ldn", Text);
   begin
      pragma Assert (Written /= Landin.Source.No_Source);
      if Additional /= "" then
         declare
            Additional_Written : constant Landin.Source.Source_Id :=
              Landin.Stages.Add_Source (Work, "with.ldn", Additional);
         begin
            pragma Assert
              (Additional_Written /= Landin.Source.No_Source);
         end;
      end if;
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Landin.Stages.Append (Order, Lowerer'Access);
      Ran := Landin.Stages.Run (Order, Work);
   end Lower;

   function Named_Item
     (Work : in out Landin.Stages.Compilation; Name : String)
      return IR.Item_Id;

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

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
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

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
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

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
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

   --  D39 lowers contextual scalar `zeroed` through D10's existing zero
   --  representation.  D177 records the bool directly as a static image;
   --  the integer keeps its existing scalar IR fold.
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
           (Item, IR.Has_Bool_Image (Unit, 2)
                  and then IR.Bool_Image (Unit, 2) = 0
                  and then IR.Value_Count (Unit, 2) = 1
                  and then IR.Op_Of (Unit, 2, 1) = IR.Leave,
            "the bool initializer is D10's false static image");
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

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
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

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
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

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
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

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
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

   --  D135 disappears before IR construction: direct applications on module
   --  and local storage carry the existing fixed-array item and slot shapes,
   --  while the template itself creates no item.
   procedure Parameterized_Aliases_Lower_As_Ordinary_Arrays
     (Item : in out Landin.Testing.Context);

   procedure Generic_Routine_Instances_Lower_Once_Per_Key
     (Item : in out Landin.Testing.Context);

   procedure Parameterized_Aliases_Lower_As_Ordinary_Arrays
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "bytes: type (t: type, fixed n: u64) = [n * 2]t" & LF
         & "mut module: bytes(u16, 3)" & LF
         & "f: () -> none =" & LF
         & "    local: bytes(u8, 5)" & LF
         & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work), "the program is accepted");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Local : constant IR.Slot_Id := IR.Slot_Id'(1);
      begin
         Landin.Testing.Check_Equal
           (Item, IR.Item_Count (Unit), 2,
            "the compile-time template creates no IR item");
         Landin.Testing.Check
           (Item, IR.Kind_Of (Unit, 1) = IR.Datum
             and then IR.Result_Of (Unit, 1) = Landin.Types.Fixed_Array
             and then IR.Array_Length (Unit, 1) = 6
             and then IR.Array_Element (Unit, 1) = Landin.Types.U16,
            "the module application is an ordinary array datum");
         Landin.Testing.Check
           (Item, IR.Kind_Of (Unit, 2) = IR.Routine
             and then IR.Slot_Count (Unit, 2) = 1
             and then IR.Is_Array (Unit, 2, Local)
             and then IR.Slot_Array_Length (Unit, 2, Local) = 10
             and then IR.Slot_Array_Element (Unit, 2, Local)
                        = Landin.Types.U8,
            "the local application is an ordinary array slot");
         Check_Terminators (Item, Unit, "parameterized alias erasure");
      end;
   end Parameterized_Aliases_Lower_As_Ordinary_Arrays;

   procedure Generic_Routine_Instances_Lower_Once_Per_Key
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "identity: (t: type, value: t) -> (result: t) = value end identity"
         & LF
         & "array_identity: (fixed n: u32, t: type, value: [n]t)"
         & " -> (result: [n]t) =" & LF
         & "    result = value" & LF
         & "end array_identity" & LF
         & "use: (small: u8, wide: i32) -> (result: i32) =" & LF
         & "    small_copy: u8 = identity(small)" & LF
         & "    wide_copy: i32 = identity(wide)" & LF
         & "    wide_again: i32 = identity(wide_copy)" & LF
         & "    source: [2]i32 = [1, 2]" & LF
         & "    array_copy: [2]i32 = array_identity(source)" & LF
         & "    result = wide_again" & LF
         & "end use" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work), "generic calls are accepted");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Use_Item : constant IR.Item_Id := 1;
         Small_Item : constant IR.Item_Id := 2;
         Wide_Item : constant IR.Item_Id := 3;
         Array_Item : constant IR.Item_Id := 4;
         Calls : Natural := 0;
         Small_Calls : Natural := 0;
         Wide_Calls : Natural := 0;
         Array_Calls : Natural := 0;
      begin
         for Value in 1 .. IR.Value_Count (Unit, Use_Item) loop
            if IR.Op_Of (Unit, Use_Item, IR.Value_Id (Value)) = IR.Call then
               Calls := Calls + 1;
               if IR.Callee_Of (Unit, Use_Item, IR.Value_Id (Value))
                 = Small_Item
               then
                  Small_Calls := Small_Calls + 1;
               elsif IR.Callee_Of (Unit, Use_Item, IR.Value_Id (Value))
                 = Wide_Item
               then
                  Wide_Calls := Wide_Calls + 1;
               elsif IR.Callee_Of (Unit, Use_Item, IR.Value_Id (Value))
                 = Array_Item
               then
                  Array_Calls := Array_Calls + 1;
               end if;
            end if;
         end loop;

         Landin.Testing.Check
           (Item,
            IR.Item_Count (Unit) = 4
              and then IR.Declares (Unit, Small_Item) = IR.No_Declaration
              and then IR.Declares (Unit, Wide_Item) = IR.No_Declaration
              and then IR.Generic_Template_Of (Unit, Small_Item)
                = IR.Generic_Template_Of (Unit, Wide_Item),
            "one template emits two local routine items for two keys");
         Landin.Testing.Check
           (Item,
            Calls = 4 and then Small_Calls = 1 and then Wide_Calls = 2
              and then Array_Calls = 1,
            "equal i32 keys reuse one target while other keys stay distinct");
         Landin.Testing.Check
           (Item,
            IR.Parameter_Count (Unit, Small_Item) = 1
              and then IR.Parameter_Count (Unit, Wide_Item) = 1
              and then IR.Slot_Count (Unit, Small_Item) = 2
              and then IR.Slot_Count (Unit, Wide_Item) = 2
              and then IR.Parameter_Count (Unit, Array_Item) = 2
              and then IR.Slot_Count (Unit, Array_Item) = 3,
            "static formals occupy no ABI or frame position");
         Check_Terminators (Item, Unit, "generic routine instances");
      end;
   end Generic_Routine_Instances_Lower_Once_Per_Key;

   ------------------------------------------------------------------

   procedure Parameterized_Structs_Lower_As_Concrete_Nominals
     (Item : in out Landin.Testing.Context);

   procedure Parameterized_Structs_Lower_As_Concrete_Nominals
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "box: type (item: type) = struct" & LF
         & "    value: item" & LF
         & "end box" & LF
         & "small: box(u8)" & LF
         & "wide: box(u16)" & LF
         & "convert: (arg: box(u8)) -> (result: box(u16)) =" & LF
         & "    result = zeroed" & LF
         & "end convert" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work), "the program is accepted");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Small : constant IR.Nominal_Type_Id :=
           IR.Nth_Nominal_Type (Unit, 1);
         Wide : constant IR.Nominal_Type_Id :=
           IR.Nth_Nominal_Type (Unit, 2);
         Small_Field : constant IR.Field_Shape :=
           IR.Nth_Field_Shape (Unit, 1, 1);
         Wide_Field : constant IR.Field_Shape :=
           IR.Nth_Field_Shape (Unit, 2, 1);
         Routine : constant IR.Item_Id := 3;
         Parameter : constant IR.Slot_Id :=
           IR.Nth_Parameter (Unit, Routine, 2);
         Result : constant IR.Slot_Id := IR.Result_Slot (Unit, Routine);
      begin
         Landin.Testing.Check
           (Item, IR.Nominal_Type_Count (Unit) = 2
             and then Small /= Wide
             and then IR.Template_Of (Unit, Small)
                        = IR.Template_Of (Unit, Wide),
            "two actual tuples map to distinct IR identities for one"
            & " template");
         Landin.Testing.Check
           (Item, IR.Item_Count (Unit) = 3
             and then Small_Field.Kind = IR.Scalar_Field_Shape
             and then Small_Field.Element = Landin.Types.U8
             and then Wide_Field.Kind = IR.Scalar_Field_Shape
             and then Wide_Field.Element = Landin.Types.U16,
            "only concrete datums carry their instantiated field shapes");
         Landin.Testing.Check
           (Item, IR.Nominal_Of (Unit, 1) = Small
             and then IR.Nominal_Of (Unit, 2) = Wide
             and then IR.Nominal_Of (Unit, Routine, Parameter) = Small
             and then IR.Nominal_Of (Unit, Routine, Result) = Wide,
            "storage and ABI metadata retain concrete nominal identities");
         Check_Terminators (Item, Unit, "parameterized nominal lowering");
      end;
   end Parameterized_Structs_Lower_As_Concrete_Nominals;

   ------------------------------------------------------------------

   procedure Nominal_Identity_Maps_Through_The_Public_IR_Seam
     (Item : in out Landin.Testing.Context);

   procedure Nominal_Identity_Maps_Through_The_Public_IR_Seam
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "left: type = struct" & LF
         & "    value: u32" & LF
         & "end left" & LF
         & "right: type = struct" & LF
         & "    value: u32" & LF
         & "end right" & LF
         & "same: type = left" & LF
         & "nested: type = struct" & LF
         & "    child: same" & LF
         & "    rows: [2]right" & LF
         & "end nested" & LF
         & "state: nested" & LF
         & "convert: (arg: left) -> (result: right) =" & LF
         & "    result = zeroed" & LF
         & "end convert" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work), "the program is accepted");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Left : constant IR.Nominal_Type_Id :=
           IR.Nth_Nominal_Type (Unit, 1);
         Right : constant IR.Nominal_Type_Id :=
           IR.Nth_Nominal_Type (Unit, 2);
         Nested : constant IR.Nominal_Type_Id :=
           IR.Nth_Nominal_Type (Unit, 3);
         State : constant IR.Item_Id := 1;
         Convert : constant IR.Item_Id := 2;
         Child : constant IR.Field_Shape :=
           IR.Nth_Field_Shape (Unit, State, 1);
         Rows : constant IR.Field_Shape :=
           IR.Nth_Field_Shape (Unit, State, 2);
         Row : constant IR.Field_Shape :=
           IR.Array_Element_Shape (Unit, Rows);
         Signature : constant IR.Signature_Id :=
           IR.Signature_Of (Unit, Convert);
         Parameter : constant IR.Slot_Id :=
           IR.Nth_Parameter (Unit, Convert, 2);
         Result : constant IR.Slot_Id := IR.Result_Slot (Unit, Convert);
      begin
         Landin.Testing.Check_Equal
           (Item, IR.Nominal_Type_Count (Unit), 3,
            "three struct templates map in deterministic source order");
         Landin.Testing.Check
           (Item, Left /= Right
             and then IR.Template_Of (Unit, Left)
                        /= IR.Template_Of (Unit, Right),
            "same-layout structs remain nominally unequal in neutral IR");
         Landin.Testing.Check_Equal
           (Item, IR.Item_Count (Unit), 2,
            "three templates and one alias create no IR items");
         Landin.Testing.Check
           (Item, IR.Nominal_Of (Unit, State) = Nested
             and then Child.Nominal = Left
             and then Rows.Nominal = Right
             and then Row.Nominal = Right
             and then not IR.Same_Shape (Unit, Child, Row),
            "nested fields and array elements retain nominal identity");
         Landin.Testing.Check
           (Item, IR.Nominal_Of (Unit, Convert) = Right
             and then IR.Nominal_Of (Unit, Convert, Parameter) = Left
             and then IR.Nominal_Of (Unit, Convert, Result) = Right,
            "routine, parameter and result storage retain identity");
         Landin.Testing.Check
           (Item,
            IR.Nth_Signature_Parameter (Unit, Signature, 1).Nominal = Left
            and then IR.Nth_Signature_Result
              (Unit, Signature, 1).Nominal = Right,
            "the recursive signature descriptor retains both identities");
         Check_Terminators (Item, Unit, "nominal identity mapping");
      end;
   end Nominal_Identity_Maps_Through_The_Public_IR_Seam;

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
   --  descriptor form becomes the exact recursive array root, and a later D21
   --  link clones that root and its fold run like any other array datum.
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
            and then IR.Result_Of (Unit, 2) = Landin.Types.Fixed_Array
            and then IR.Array_Length (Unit, 2) = 2
            and then IR.Array_Element (Unit, 2) = Landin.Types.U16
            and then IR.Has_Recursive_Array_Image (Unit, 2)
            and then IR.Image_Root_Count (Unit, 2) = 1
            and then IR.Aggregate_Field_Image_Count (Unit, 2) = 1
            and then IR.Image_Length (Unit, 2) = 2
            and then IR.Array_Image_Of (Unit, 2)
              = (Form   => IR.Finite,
                 Offset => 0,
                 Count  => 2,
                 Value  => 0,
                 others => <>)
            and then IR.Nth_Descriptor_Element
              (Unit, 2, IR.Array_Image_Of (Unit, 2), 1) = 11
            and then IR.Nth_Descriptor_Element
              (Unit, 2, IR.Array_Image_Of (Unit, 2), 2) = 13,
            "a finite field becomes an exact recursive array image");
         Landin.Testing.Check
           (Item,
            IR.Has_Image (Unit, 3)
            and then IR.Result_Of (Unit, 3) = Landin.Types.Fixed_Array
            and then IR.Array_Length (Unit, 3) = 3
            and then IR.Array_Element (Unit, 3) = Landin.Types.U8
            and then IR.Has_Recursive_Array_Image (Unit, 3)
            and then IR.Image_Root_Count (Unit, 3) = 1
            and then IR.Aggregate_Field_Image_Count (Unit, 3) = 1
            and then IR.Image_Length (Unit, 3) = 0
            and then IR.Array_Image_Of (Unit, 3)
              = (Form   => IR.Repeated,
                 Offset => 0,
                 Count  => 0,
                 Value  => 17,
                 others => <>),
            "a repeated field stays compact in its exact root");
         Landin.Testing.Check
           (Item,
            IR.Has_Image (Unit, 4)
            and then IR.Result_Of (Unit, 4) = Landin.Types.Fixed_Array
            and then IR.Array_Length (Unit, 4) = 3
            and then IR.Array_Element (Unit, 4) = Landin.Types.U8
            and then IR.Has_Recursive_Array_Image (Unit, 4)
            and then IR.Image_Root_Count (Unit, 4) = 1
            and then IR.Aggregate_Field_Image_Count (Unit, 4) = 1
            and then IR.Image_Length (Unit, 4) = 1
            and then IR.Array_Image_Of (Unit, 4)
              = (Form   => IR.Hybrid,
                 Offset => 0,
                 Count  => 1,
                 Value  => 23,
                 others => <>)
            and then IR.Nth_Descriptor_Element
              (Unit, 4, IR.Array_Image_Of (Unit, 4), 1) = 19,
            "a hybrid field preserves its exact prefix and suffix");
         Landin.Testing.Check
           (Item,
            IR.Result_Of (Unit, 5) = Landin.Types.Fixed_Array
            and then IR.Array_Length (Unit, 5) = 2
            and then IR.Array_Element (Unit, 5) = Landin.Types.U8
            and then not IR.Has_Image (Unit, 5)
            and then not IR.Has_Recursive_Array_Image (Unit, 5)
            and then IR.Result_Of (Unit, 6) = Landin.Types.Fixed_Array
            and then IR.Array_Length (Unit, 6) = 2
            and then IR.Array_Element (Unit, 6) = Landin.Types.U8
            and then not IR.Has_Image (Unit, 6)
            and then not IR.Has_Recursive_Array_Image (Unit, 6),
            "zero-pattern and omitted fields stay absent");
         Landin.Testing.Check
           (Item,
            IR.Has_Image (Unit, 7)
            and then IR.Result_Of (Unit, 7) = Landin.Types.Fixed_Array
            and then IR.Array_Length (Unit, 7) = 3
            and then IR.Array_Element (Unit, 7) = Landin.Types.U8
            and then IR.Has_Recursive_Array_Image (Unit, 7)
            and then IR.Image_Root_Count (Unit, 7) = 1
            and then IR.Aggregate_Field_Image_Count (Unit, 7) = 1
            and then IR.Image_Length (Unit, 7) = 1
            and then IR.Array_Image_Of (Unit, 7)
              = (Form   => IR.Hybrid,
                 Offset => 0,
                 Count  => 1,
                 Value  => 23,
                 others => <>)
            and then IR.Nth_Descriptor_Element
              (Unit, 7, IR.Array_Image_Of (Unit, 7), 1) = 19,
            "a downstream chain clones the exact selected field image");
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

   --  D132 keeps ordinary-child and ordinary-payload images as recursively
   --  indexed descriptor runs.  Scalar folds stay source values while every
   --  descriptor offset names another descriptor or fold, never target bytes.
   procedure A_Recursive_Module_Image_Carries_Descriptors
     (Item : in out Landin.Testing.Context);

   procedure A_Recursive_Module_Image_Carries_Descriptors
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "word: type = struct" & LF
         & "    value: usize" & LF
         & "    code: u8" & LF
         & "end word" & LF
         & "packet: type = struct" & LF
         & "    head: u8" & LF
         & "    child: word" & LF
         & "    tail: u16" & LF
         & "end packet" & LF
         & "choice: type = struct" & LF
         & "    kind: variant" & LF
         & "        empty |" & LF
         & "        carry: (data: packet)" & LF
         & "    end kind" & LF
         & "end choice" & LF
         & "source: word = word(value: 42, code: 7)" & LF
         & "packet_image: packet = packet(head: 11, child: source,"
         & " tail: 13)" & LF
         & "selected: choice = choice(kind: carry(data: packet_image))"
         & LF
         & "copy: choice = selected" & LF,
         Ran);

      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "recursive module images are accepted");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
      begin
         Landin.Testing.Check
           (Item,
            IR.Has_Image (Unit, 2)
            and then IR.Aggregate_Field_Image_Count (Unit, 2) = 5
            and then IR.Field_Image_Of (Unit, 2, 2).Form = IR.Nested
            and then IR.Field_Image_Of (Unit, 2, 2).Offset = 0
            and then IR.Field_Image_Of (Unit, 2, 2).Count = 2
            and then IR.Nth_Image_Descriptor (Unit, 2, 4).Value = 42
            and then IR.Nth_Image_Descriptor (Unit, 2, 5).Value = 7,
            "an ordinary child points at its declaration-order descriptors");

         for Datum in IR.Item_Id range 3 .. 4 loop
            Landin.Testing.Check
              (Item,
               IR.Has_Image (Unit, Datum)
               and then IR.Aggregate_Field_Image_Count (Unit, Datum) = 7
               and then IR.Field_Image_Of
                 (Unit, Datum, 1).Form = IR.Selected
               and then IR.Field_Image_Of (Unit, Datum, 1).Offset = 0
               and then IR.Nth_Image_Descriptor
                 (Unit, Datum, 2).Form = IR.Nested
               and then IR.Nth_Image_Descriptor
                 (Unit, Datum, 2).Offset = 1
               and then IR.Nth_Image_Descriptor
                 (Unit, Datum, 4).Form = IR.Nested
               and then IR.Nth_Image_Descriptor
                 (Unit, Datum, 6).Value = 42
               and then IR.Nth_Image_Descriptor
                 (Unit, Datum, 7).Value = 7,
               "aggregate payload descriptors recurse and copy unchanged");
         end loop;
      end;
   end A_Recursive_Module_Image_Carries_Descriptors;

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

   procedure Module_Bools_Become_Static_Images
     (Item : in out Landin.Testing.Context);

   procedure Module_Bools_Become_Static_Images
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      --  [1940] admits every [1820] operator over module-known values, D24
      --  already folds the logical words into aggregate images, and [0410]
      --  makes `and` and `or` short-circuit.  D177 gives scalar bool datums
      --  that same static-image path: no initializer runs and routine CFG
      --  cannot escape into data emission.
      Lower
        (Work,
         "sample: type = struct" & LF
         & "    first: bool" & LF
         & "    second: bool" & LF
         & "end sample" & LF
         & "forward: bool = later and true" & LF
         & "chain: bool = forward" & LF
         & "literal: bool = not false" & LF
         & "comparison: bool = 3 < 4" & LF
         & "later: bool = false or true" & LF
         & "values: [6]bool = [not true, true and false," & LF
         & "    false or true, chain and comparison, 7 == 7, 9 < 2]" & LF
         & "record: sample = sample(" & LF
         & "    first: not chain," & LF
         & "    second: forward and comparison)" & LF,
         Ran);

      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work), "the program is accepted");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Branches : Natural := 0;
      begin
         for Datum in IR.Item_Id range 1 .. 5 loop
            Landin.Testing.Check
              (Item,
               IR.Has_Bool_Image (Unit, Datum)
               and then IR.Bool_Image (Unit, Datum) = 1
               and then IR.Block_Count (Unit, Datum) = 1
               and then IR.Value_Count (Unit, Datum) = 1
               and then IR.Op_Of (Unit, Datum, 1) = IR.Leave,
               "each scalar bool is one true static image without code");
         end loop;

         for Datum in IR.Item_Id range 1 .. IR.Item_Id
           (IR.Item_Count (Unit))
         loop
            for V in 1 .. IR.Value_Count (Unit, Datum) loop
               if IR.Op_Of (Unit, Datum, IR.Value_Id (V)) = IR.Branch then
                  Branches := Branches + 1;
               end if;
            end loop;
         end loop;

         Landin.Testing.Check_Equal
           (Item, Branches, 0, "no datum carries a CFG branch");

         Landin.Testing.Check
           (Item,
            IR.Has_Image (Unit, 6)
            and then IR.Nth_Image (Unit, 6, 1) = 0
            and then IR.Nth_Image (Unit, 6, 2) = 0
            and then IR.Nth_Image (Unit, 6, 3) = 1
            and then IR.Nth_Image (Unit, 6, 4) = 1
            and then IR.Nth_Image (Unit, 6, 5) = 1
            and then IR.Nth_Image (Unit, 6, 6) = 0,
            "array leaves fold not, and, or, names and comparisons");

         Landin.Testing.Check
           (Item,
            IR.Has_Image (Unit, 7)
            and then IR.Nth_Field_Image (Unit, 7, 1) = 0
            and then IR.Nth_Field_Image (Unit, 7, 2) = 1,
            "struct leaves use the same module bool fold");

         Check_Terminators (Item, Unit, "module bool images");
      end;
   end Module_Bools_Become_Static_Images;

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

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

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

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");

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

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
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

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
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
   --  containing field plus its one-based constant child position.
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

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "module and local field literals lower");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Routine : constant IR.Item_Id := 2;
      begin
         Landin.Testing.Check_Equal
           (Item, IR.Value_Count (Unit, Routine), 9,
            "four ordered value/store pairs precede the return");

         for Position in 1 .. 4 loop
            declare
               Element : constant IR.Value_Id :=
                 IR.Value_Id (2 * Position - 1);
               Store : constant IR.Value_Id := IR.Value_Id (2 * Position);
               Expected_Value : constant Landin.Types.Folded :=
                 (case Position is
                     when 1 => 20, when 2 => 22,
                     when 3 => 30, when 4 => 12);
               Expected_Part : constant Positive := (Position - 1) mod 2 + 1;
            begin
               Landin.Testing.Check
                 (Item,
                  IR.Op_Of (Unit, Routine, Element) = IR.Number
                  and then IR.Result_Of (Unit, Routine, Element)
                             = Landin.Types.U32
                  and then Folded_Number_Of (Unit, Routine, Element)
                             = Expected_Value
                  and then IR.Op_Of (Unit, Routine, Store) = IR.Store_Field
                  and then IR.Field_Of (Unit, Routine, Store) = 2
                  and then IR.Path_Of (Unit, Routine, Store)
                             = Below (Expected_Part)
                  and then IR.Operand_Count (Unit, Routine, Store) = 1
                  and then IR.Nth_Operand (Unit, Routine, Store, 1) = Element,
                  "each typed expression immediately precedes its path store");

               if Position <= 2 then
                  Landin.Testing.Check
                    (Item, not IR.Reaches_A_Slot (Unit, Routine, Store)
                           and then IR.Datum_Of (Unit, Routine, Store) = 1,
                     "the first literal reaches the exact module root");
               else
                  Landin.Testing.Check
                    (Item, IR.Reaches_A_Slot (Unit, Routine, Store)
                           and then IR.Slot_Of (Unit, Routine, Store) = 1,
                     "the second literal reaches the exact local root");
               end if;
            end;
         end loop;

         Landin.Testing.Check
           (Item, IR.Op_Of (Unit, Routine, 9) = IR.Leave,
            "the return follows every literal store");
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

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "module and local field repetitions lower");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Routine : constant IR.Item_Id := 2;
         type Value_List is array (Positive range <>) of IR.Value_Id;
         type Folded_List is
           array (Positive range <>) of Landin.Types.Folded;
         type Part_List is array (Positive range <>) of IR.Part_Position;
         Fill_Ids : constant Value_List := [2, 8, 10, 16];
         Fill_Values : constant Folded_List := [10, 13, 20, 23];
         Fill_Starts : constant Part_List := [1, 3, 1, 3];
         Prefix_Ids : constant Value_List := [4, 6, 12, 14];
         Prefix_Values : constant Folded_List := [11, 12, 21, 22];
         Prefix_Parts : constant Part_List := [1, 2, 1, 2];
      begin
         Landin.Testing.Check_Equal
           (Item, IR.Value_Count (Unit, Routine), 17,
            "four bounded repetitions and their prefixes precede the return");

         for Position in Fill_Ids'Range loop
            declare
               Fill : constant IR.Value_Id := Fill_Ids (Position);
               Value : constant IR.Value_Id := Fill - 1;
               Destination : constant IR.Storage :=
                 IR.Destination_Of (Unit, Routine, Fill);
            begin
               Landin.Testing.Check
                 (Item,
                  IR.Op_Of (Unit, Routine, Value) = IR.Number
                  and then IR.Result_Of (Unit, Routine, Value)
                             = Landin.Types.U32
                  and then Folded_Number_Of (Unit, Routine, Value)
                             = Fill_Values (Position)
                  and then IR.Op_Of (Unit, Routine, Fill) = IR.Fill_Array
                  and then IR.Element_Field_Of (Unit, Routine, Fill) = 2
                  and then IR.Path_Of (Unit, Routine, Fill)
                             = IR.No_Path_Steps
                  and then IR.First_Part_Of (Unit, Routine, Fill)
                             = Fill_Starts (Position)
                  and then IR.Operand_Count (Unit, Routine, Fill) = 1
                  and then IR.Nth_Operand (Unit, Routine, Fill, 1) = Value,
                  "each typed repeated value immediately precedes its fill");
               Landin.Testing.Check
                 (Item,
                  (if Position <= 2
                   then Destination.Kind = IR.Module_Datum
                        and then Destination.Datum = 1
                   else Destination.Kind = IR.Frame_Slot
                        and then Destination.Slot = 1),
                  "each fill retains its exact storage root");
            end;
         end loop;

         for Position in Prefix_Ids'Range loop
            declare
               Store : constant IR.Value_Id := Prefix_Ids (Position);
               Value : constant IR.Value_Id := Store - 1;
            begin
               Landin.Testing.Check
                 (Item,
                  IR.Op_Of (Unit, Routine, Value) = IR.Number
                  and then IR.Result_Of (Unit, Routine, Value)
                             = Landin.Types.U32
                  and then Folded_Number_Of (Unit, Routine, Value)
                             = Prefix_Values (Position)
                  and then IR.Op_Of (Unit, Routine, Store) = IR.Store_Field
                  and then IR.Field_Of (Unit, Routine, Store) = 2
                  and then IR.Path_Of (Unit, Routine, Store)
                             = Below (Positive (Prefix_Parts (Position)))
                  and then IR.Operand_Count (Unit, Routine, Store) = 1
                  and then IR.Nth_Operand (Unit, Routine, Store, 1) = Value,
                  "mixed prefixes are ordered typed path stores");
               Landin.Testing.Check
                 (Item,
                  (if Position <= 2
                   then not IR.Reaches_A_Slot (Unit, Routine, Store)
                        and then IR.Datum_Of (Unit, Routine, Store) = 1
                   else IR.Reaches_A_Slot (Unit, Routine, Store)
                        and then IR.Slot_Of (Unit, Routine, Store) = 1),
                  "each prefix retains its exact storage root");
            end;
         end loop;

         Landin.Testing.Check
           (Item, IR.Op_Of (Unit, Routine, 17) = IR.Leave,
            "the return follows every repetition write");
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

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
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

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
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

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
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

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
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

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
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

   --  D121 applies inside a measurement too: the repeated element is the
   --  named aggregate shape, not only the array record's scalar fallback.
   procedure An_Array_Of_Struct_Measurement_Keeps_Its_Nominal
     (Item : in out Landin.Testing.Context);

   procedure An_Array_Of_Struct_Measurement_Keeps_Its_Nominal
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "inner: type = layout(c) struct" & LF
         & "    value: i32" & LF
         & "end inner" & LF
         & "outer: type = layout(c) struct" & LF
         & "    prefix: i32" & LF
         & "    rows: [3]inner" & LF
         & "end outer" & LF
         & "size: usize = sizeof outer" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "an array-of-struct declaration can be measured");
      if Landin.Stages.Failed (Work) then
         return;
      end if;

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Inner : constant IR.Nominal_Type_Id :=
           IR.Nth_Nominal_Type (Unit, 1);
         Outer : constant IR.Nominal_Type_Id :=
           IR.Nth_Nominal_Type (Unit, 2);
         Rows : constant IR.Field_Shape :=
           IR.Nth_Measurement_Field (Unit, 1, 1, 2);
      begin
         Landin.Testing.Check
           (Item,
            IR.Nominal_Type_Count (Unit) = 2
              and then IR.Has_C_Layout (Unit, Inner)
              and then IR.Has_C_Layout (Unit, Outer),
            "both source structs retain their C layout identities");
         Landin.Testing.Check
           (Item,
            IR.Is_Aggregate_Measurement (Unit, 1, 1)
              and then IR.Measurement_Field_Count (Unit, 1, 1) = 2
              and then Rows.Kind = IR.Array_Field_Shape
              and then Rows.Length = 3
              and then Rows.Nominal = Inner
              and then IR.Array_Element_Is_Aggregate (Unit, Rows),
            "the measured array retains its nominal aggregate element");

         if Rows.Kind = IR.Array_Field_Shape then
            declare
               Element : constant IR.Field_Shape :=
                 IR.Array_Element_Shape (Unit, Rows);
            begin
               Landin.Testing.Check
                 (Item,
                  Element.Kind = IR.Aggregate_Field_Shape
                    and then Element.Nominal = Inner
                    and then IR.Aggregate_Field_Run_Is_Valid (Unit, Element)
                    and then IR.Aggregate_Field_Count (Unit, Element) = 1,
                  "the element names the complete inner field run");
               if Element.Kind = IR.Aggregate_Field_Shape
                 and then IR.Aggregate_Field_Run_Is_Valid (Unit, Element)
               then
                  declare
                     Value : constant IR.Field_Shape :=
                       IR.Nth_Aggregate_Field (Unit, Element, 1);
                  begin
                     Landin.Testing.Check
                       (Item,
                        Value.Kind = IR.Scalar_Field_Shape
                          and then Value.Element = Landin.Types.I32,
                        "the recursive element run retains its actual field");
                  end;
               end if;
            end;
         end if;

         Landin.Testing.Check
           (Item, IR.Verifier.Check (Unit).Kind = IR.Verifier.Nothing_Wrong,
            "the verifier accepts the nominal array measurement");
      end;
   end An_Array_Of_Struct_Measurement_Keeps_Its_Nominal;

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

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
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

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
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

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
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
                  when IR.Runtime_Address => null;
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

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
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
                 and then IR.Path_Depth_Of (Unit, 2, Value) > 0
               then
                  Landin.Testing.Check
                    (Item,
                     IR.Field_Of (Unit, 2, Value) = 2
                       and then IR.Path_Of (Unit, 2, Value) = Below (2),
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

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
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
                 and then IR.Path_Depth_Of (Unit, 2, Value) > 0
               then
                  Landin.Testing.Check
                    (Item,
                     IR.Element_Field_Of (Unit, 2, Value) = 2
                       and then IR.Path_Of (Unit, 2, Value) = Below (3),
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
      use type IR.Storage_Kind;

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

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "nested contextual array values are accepted");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         type Value_List is array (Positive range <>) of IR.Value_Id;
         type Folded_List is
           array (Positive range <>) of Landin.Types.Folded;
         Store_Ids : constant Value_List := [2, 4, 6];
         Stored_Values : constant Folded_List := [1, 2, 3];
         Copy : constant IR.Value_Id := 7;
         Repeated : constant IR.Value_Id := 8;
         Fill : constant IR.Value_Id := 9;
         Clear : constant IR.Value_Id := 10;
      begin
         Landin.Testing.Check_Equal
           (Item, IR.Value_Count (Unit, 3), 11,
            "literal, copy, fill and clear retain source order");
         for Position in Store_Ids'Range loop
            declare
               Store : constant IR.Value_Id := Store_Ids (Position);
               Value : constant IR.Value_Id := Store - 1;
            begin
               Landin.Testing.Check
                 (Item,
                  IR.Op_Of (Unit, 3, Value) = IR.Number
                  and then IR.Result_Of (Unit, 3, Value) = Landin.Types.I32
                  and then Folded_Number_Of (Unit, 3, Value)
                             = Stored_Values (Position)
                  and then IR.Op_Of (Unit, 3, Store) = IR.Store_Field
                  and then not IR.Reaches_A_Slot (Unit, 3, Store)
                  and then IR.Datum_Of (Unit, 3, Store) = 1
                  and then IR.Field_Of (Unit, 3, Store) = 2
                  and then IR.Path_Of (Unit, 3, Store)
                             = Below (2, Position)
                  and then IR.Operand_Count (Unit, 3, Store) = 1
                  and then IR.Nth_Operand (Unit, 3, Store, 1) = Value,
                  "each typed literal leaf reaches its exact nested path");
            end;
         end loop;
         Landin.Testing.Check
           (Item,
            IR.Op_Of (Unit, 3, Copy) = IR.Copy_Array
              and then IR.Source_Of (Unit, 3, Copy).Kind = IR.Module_Datum
              and then IR.Source_Of (Unit, 3, Copy).Datum = 1
              and then IR.Source_Field_Of (Unit, 3, Copy) = 2
              and then IR.Source_Path_Of (Unit, 3, Copy) = Below (2)
              and then IR.Destination_Of (Unit, 3, Copy).Kind
                         = IR.Module_Datum
              and then IR.Destination_Of (Unit, 3, Copy).Datum = 2
              and then IR.Element_Field_Of (Unit, 3, Copy) = 2
              and then IR.Path_Of (Unit, 3, Copy) = Below (2),
            "the copy keeps both exact nested roots and paths");
         Landin.Testing.Check
           (Item,
            IR.Op_Of (Unit, 3, Repeated) = IR.Number
              and then IR.Result_Of (Unit, 3, Repeated) = Landin.Types.I32
              and then IR.Number_Of (Unit, 3, Repeated) = 4
              and then IR.Op_Of (Unit, 3, Fill) = IR.Fill_Array
              and then IR.Destination_Of (Unit, 3, Fill).Kind
                         = IR.Module_Datum
              and then IR.Destination_Of (Unit, 3, Fill).Datum = 1
              and then IR.Element_Field_Of (Unit, 3, Fill) = 2
              and then IR.Path_Of (Unit, 3, Fill) = Below (2)
              and then IR.First_Part_Of (Unit, 3, Fill) = 1
              and then IR.Nth_Operand (Unit, 3, Fill, 1) = Repeated,
            "the typed fill retains its exact nested destination");
         Landin.Testing.Check
           (Item,
            IR.Op_Of (Unit, 3, Clear) = IR.Clear_Array
              and then IR.Destination_Of (Unit, 3, Clear).Kind
                         = IR.Module_Datum
              and then IR.Destination_Of (Unit, 3, Clear).Datum = 2
              and then IR.Element_Field_Of (Unit, 3, Clear) = 2
              and then IR.Path_Of (Unit, 3, Clear) = Below (2),
            "the clear retains its exact nested destination");
         Landin.Testing.Check
           (Item, IR.Op_Of (Unit, 3, 11) = IR.Leave,
            "the return follows every nested array operation");
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

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
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
                 and then IR.Path_Of (Unit, 4, Value) = Below (1)
               then
                  Scalar_Stores := Scalar_Stores + 1;
               elsif Op = IR.Store_Field
                 and then IR.Field_Of (Unit, 4, Value) = 2
                 and then (IR.Path_Of (Unit, 4, Value) = Below (2, 1)
                           or else IR.Path_Of (Unit, 4, Value) = Below (2, 2))
               then
                  Array_Stores := Array_Stores + 1;
                  declare
                     Stored : constant IR.Value_Id :=
                       IR.Nth_Operand (Unit, 4, Value, 1);
                  begin
                     Landin.Testing.Check
                       (Item,
                        Array_Stores in 1 .. 2
                          and then not IR.Reaches_A_Slot (Unit, 4, Value)
                          and then IR.Datum_Of (Unit, 4, Value) = 3
                          and then IR.Path_Of (Unit, 4, Value)
                                     = Below (2, Array_Stores)
                          and then Stored = Value - 1
                          and then IR.Op_Of (Unit, 4, Stored) = IR.Number
                          and then IR.Result_Of (Unit, 4, Stored)
                                     = Landin.Types.I32
                          and then Folded_Number_Of (Unit, 4, Stored)
                                     = Landin.Types.Folded (Array_Stores),
                        "literal array leaves keep root, path, type and"
                        & " order");
                  end;
               elsif Op = IR.Copy_Array
                 and then IR.Element_Field_Of (Unit, 4, Value) = 2
                 and then IR.Path_Of (Unit, 4, Value) = Below (2)
               then
                  Array_Copies := Array_Copies + 1;
                  Landin.Testing.Check
                    (Item,
                     IR.Source_Field_Of (Unit, 4, Value) = 2
                     and then (IR.Source_Path_Of (Unit, 4, Value)
                                 = IR.No_Path_Steps
                               or else IR.Source_Path_Of (Unit, 4, Value)
                                         = Below (2)),
                     "each array source keeps its own parent path");
               elsif Op = IR.Copy_Array
                 and then IR.Source_Path_Of (Unit, 4, Value) = Below (2)
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

   --  D92 admits a nested child selection only as a local storage-copy
   --  initializer.  At module scope the same source remains L0304 rather than
   --  becoming a static image edge.
   procedure Nested_Child_Module_Initializer_Is_Refused
     (Item : in out Landin.Testing.Context);

   procedure Nested_Child_Module_Initializer_Is_Refused
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "inner: type = struct value: i32 end inner" & LF
         & "outer: type = struct nested: inner end outer" & LF
         & "source: outer = outer(nested: inner(value: 7))" & LF
         & "copy: inner = source.nested" & LF,
         Ran);

      Landin.Testing.Check_Equal
        (Item, Ran, 4, "the checker stops the nested module source");
      Landin.Testing.Check
        (Item, Landin.Stages.Failed (Work)
         and then Ada.Strings.Fixed.Index
           (Landin.Stages.Rendered_Report (Work), "L0304") > 0,
         "a nested child cannot become a module image source");
      Landin.Testing.Check_Equal
        (Item, IR.Item_Count (Landin.Stages.Code (Work).all), 0,
         "the refused module source produces no IR items");
   end Nested_Child_Module_Initializer_Is_Refused;

   --  D94 carries a complete aggregate argument as a storage identity and
   --  gives the callee one shaped aggregate parameter slot.
   procedure Aggregate_Arguments_Carry_Storage_Identity
     (Item : in out Landin.Testing.Context);

   procedure Aggregate_Arguments_Carry_Storage_Identity
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
         & "    row: [2]i32" & LF
         & "    right: i32" & LF
         & "end pair" & LF
         & "take: (prefix: i32, value: pair) -> (answer: i32) =" & LF
         & "    answer = prefix + value.left + value.row[0]" & LF
         & "             + value.row[1] + value.right" & LF
         & "end take" & LF
         & "use: () -> (answer: i32) =" & LF
         & "    mut value: pair" & LF
         & "    value.left = 2" & LF
         & "    value.row = [4, 5]" & LF
         & "    value.right = 3" & LF
         & "    row: [2]i32 = [4, 5]" & LF
         & "    answer = take(1, value) + take_array(row)" & LF
         & "             + take(0, zeroed) + take_array(zeroed)" & LF
         & "             + take_array([6, 7])" & LF
         & "             + take_array([2 of 8])" & LF
         & "             + take_array([9, of 10])" & LF
         & "             + score((x: 11, y: 12))" & LF
         & "             + score(point(y: 13, of zeroed))" & LF
         & "             + take(0, (left: 1, row: [2, 3], right: 4))" & LF
         & "             + take(0, pair(left: 1, row: [2 of 3],"
         & " right: 4))" & LF
         & "end use" & LF
         & "take_array: (value: [2]i32) -> (answer: i32) =" & LF
         & "    answer = value[0] + value[1]" & LF
         & "end take_array" & LF
         & "point: type = struct" & LF
         & "    x: i32" & LF
         & "    y: i32" & LF
         & "end point" & LF
         & "score: (value: point) -> (answer: i32) =" & LF
         & "    answer = value.x + value.y" & LF
         & "end score" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "a direct ordinary-struct argument is accepted");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Parameter : constant IR.Slot_Id := IR.Nth_Parameter (Unit, 1, 2);
         Array_Parameter : constant IR.Slot_Id :=
           IR.Nth_Parameter (Unit, 3, 1);
         Addresses, Calls, Clears, Fills : Natural := 0;
      begin
         Landin.Testing.Check
           (Item,
            IR.Is_Aggregate (Unit, 1, Parameter)
              and then IR.Slot_Field_Count (Unit, 1, Parameter) = 3,
            "the struct parameter keeps its target-neutral shape");
         Landin.Testing.Check
           (Item,
            IR.Is_Array (Unit, 3, Array_Parameter)
              and then IR.Slot_Array_Length
                (Unit, 3, Array_Parameter) = 2,
            "the array parameter keeps its target-neutral shape");
         for Position in 1 .. IR.Value_Count (Unit, 2) loop
            declare
               Value : constant IR.Value_Id := IR.Value_Id (Position);
            begin
               if IR.Op_Of (Unit, 2, Value) = IR.Storage_Address then
                  Addresses := Addresses + 1;
               elsif IR.Op_Of (Unit, 2, Value) = IR.Call then
                  Calls := Calls + 1;
                  Landin.Testing.Check
                    (Item, IR.Operand_Count (Unit, 2, Value) in 1 | 2,
                     "each aggregate occupies one source argument position");
               elsif IR.Op_Of (Unit, 2, Value) = IR.Clear_Array then
                  Clears := Clears + 1;
               elsif IR.Op_Of (Unit, 2, Value) = IR.Fill_Array then
                  Fills := Fills + 1;
               end if;
            end;
         end loop;
         Landin.Testing.Check
           (Item,
            Addresses = 11 and then Calls = 11 and then Clears = 2
              and then Fills = 3,
            "contextual arguments use compact shaped caller temporaries");
         Landin.Testing.Check
           (Item, IR.Verifier.Check (Unit).Kind = IR.Verifier.Nothing_Wrong,
            "the verifier accepts the internal aggregate carrier");
      end;
   end Aggregate_Arguments_Carry_Storage_Identity;

   --  D96 keeps the outer and child declaration-order identities on an
   --  address carrier, just as D90 keeps them on compact array operations.
   procedure Nested_Arguments_Carry_Both_Identities
     (Item : in out Landin.Testing.Context);

   procedure Nested_Arguments_Carry_Both_Identities
     (Item : in out Landin.Testing.Context)
   is
      use type IR.Storage_Kind;

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
         & "    prefix: u8" & LF
         & "    nested: inner" & LF
         & "end outer" & LF
         & "take: (child: inner, row: [2]i32) -> none =" & LF
         & "end take" & LF
         & "use: () -> none =" & LF
         & "    mut state: outer = zeroed" & LF
         & "    take(state.nested, state.nested.row)" & LF
         & "    take_outer(state)" & LF
         & "    take_outer(zeroed)" & LF
         & "    take_outer((prefix: 1," & LF
         & "                nested: (value: 2, row: [3, 4])))" & LF
         & "end use" & LF
         & "take_outer: (value: outer) -> none =" & LF
         & "end take_outer" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "nested aggregate argument paths are accepted");
      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Outer_Parameter : constant IR.Slot_Id :=
           IR.Nth_Parameter (Unit, 3, 1);
         Outer_Child : constant IR.Field_Shape :=
           IR.Nth_Slot_Field_Shape (Unit, 3, Outer_Parameter, 2);
         type Folded_List is
           array (Positive range <>) of Landin.Types.Folded;
         Expected_Values : constant Folded_List := [2, 3, 4];
         Child, Row, Nested_Writes : Natural := 0;
         Nested_Root : IR.Slot_Id := IR.No_Slot;
         Literal_Address : IR.Value_Id := IR.No_Value;
      begin
         for Position in 1 .. IR.Value_Count (Unit, 2) loop
            declare
               Value : constant IR.Value_Id := IR.Value_Id (Position);
               Op : constant IR.Opcode := IR.Op_Of (Unit, 2, Value);
            begin
               if Op = IR.Storage_Address
                 and then IR.Element_Field_Of (Unit, 2, Value) = 2
               then
                  Landin.Testing.Check
                    (Item,
                     IR.Destination_Of (Unit, 2, Value).Kind = IR.Frame_Slot
                       and then IR.Destination_Of (Unit, 2, Value).Slot = 1,
                     "selected arguments retain their exact local root");
                  if IR.Path_Depth_Of (Unit, 2, Value) = 0 then
                     Child := Child + 1;
                  elsif IR.Path_Of (Unit, 2, Value) = Below (2) then
                     Row := Row + 1;
                  end if;
               elsif Op = IR.Call
                 and then IR.Callee_Of (Unit, 2, Value) = 3
               then
                  Literal_Address := IR.Nth_Operand (Unit, 2, Value, 1);
               elsif Op = IR.Store_Field
                 and then IR.Field_Of (Unit, 2, Value) = 2
                 and then IR.Path_Depth_Of (Unit, 2, Value) > 0
               then
                  Nested_Writes := Nested_Writes + 1;
                  if Nested_Writes <= Expected_Values'Length then
                     declare
                        Stored : constant IR.Value_Id :=
                          IR.Nth_Operand (Unit, 2, Value, 1);
                        Expected_Path : constant IR.Path_Step_Array :=
                          (if Nested_Writes = 1 then Below (1)
                           else Below (2, Nested_Writes - 1));
                     begin
                        Landin.Testing.Check
                          (Item,
                           IR.Reaches_A_Slot (Unit, 2, Value)
                             and then Stored = Value - 1
                             and then IR.Op_Of (Unit, 2, Stored) = IR.Number
                             and then IR.Result_Of (Unit, 2, Stored)
                                        = Landin.Types.I32
                             and then Folded_Number_Of (Unit, 2, Stored)
                                        = Expected_Values (Nested_Writes)
                             and then IR.Path_Of (Unit, 2, Value)
                                        = Expected_Path,
                           "nested literal leaves keep type, value and path");
                        if Nested_Root = IR.No_Slot then
                           Nested_Root := IR.Slot_Of (Unit, 2, Value);
                        else
                           Landin.Testing.Check
                             (Item,
                              IR.Slot_Of (Unit, 2, Value) = Nested_Root,
                              "every nested literal leaf keeps one root");
                        end if;
                     end;
                  end if;
               end if;
            end;
         end loop;
         Landin.Testing.Check
           (Item, Child = 1 and then Row = 1,
            "child and array arguments retain both path identities");
         Landin.Testing.Check
           (Item,
            IR.Is_Aggregate (Unit, 3, Outer_Parameter)
              and then Outer_Child.Kind = IR.Aggregate_Field_Shape
              and then Outer_Child.Cases = 2,
            "the nested parameter retains its compact child field run");
         Landin.Testing.Check
           (Item, Nested_Writes = 3,
            "the nested literal writes every scalar leaf in source order");
         Landin.Testing.Check
           (Item,
            Literal_Address /= IR.No_Value
              and then IR.Op_Of (Unit, 2, Literal_Address)
                         = IR.Storage_Address
              and then IR.Destination_Of (Unit, 2, Literal_Address).Kind
                         = IR.Frame_Slot
              and then IR.Destination_Of (Unit, 2, Literal_Address).Slot
                         = Nested_Root
              and then IR.Element_Field_Of (Unit, 2, Literal_Address) = 0
              and then IR.Path_Of (Unit, 2, Literal_Address)
                         = IR.No_Path_Steps,
            "the call carries the exact root written by its nested literal");
         Landin.Testing.Check
           (Item, IR.Verifier.Check (Unit).Kind = IR.Verifier.Nothing_Wrong,
            "the verifier accepts nested storage-address carriers");
      end;
   end Nested_Arguments_Carry_Both_Identities;

   --  D102 keeps D74's complete variant shape on a by-value parameter slot;
   --  the caller still transports one opaque storage address.
   procedure Variant_Arguments_Keep_Their_Shape
     (Item : in out Landin.Testing.Context);

   procedure Variant_Arguments_Keep_Their_Shape
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
         & "        pair: (first: u8, second: u8)" & LF
         & "    end kind" & LF
         & "end choice" & LF
         & "take: (value: choice) -> none =" & LF
         & "end take" & LF
         & "use: () -> none =" & LF
         & "    take(zeroed)" & LF
         & "    take((prefix: 1, kind: pair(first: 2, second: 3)))" & LF
         & "end use" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "a variant-bearing struct parameter is accepted");
      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Parameter : constant IR.Slot_Id := IR.Nth_Parameter (Unit, 1, 1);
         Shape : constant IR.Field_Shape :=
           IR.Nth_Slot_Field_Shape (Unit, 1, Parameter, 2);
         type Folded_List is
           array (Positive range <>) of Landin.Types.Folded;
         Expected_Values : constant Folded_List := [2, 3];
         Selects, Stores : Natural := 0;
         Selected_Root : IR.Slot_Id := IR.No_Slot;
         Argument_Address : IR.Value_Id := IR.No_Value;
      begin
         Landin.Testing.Check
           (Item,
            IR.Is_Aggregate (Unit, 1, Parameter)
              and then Shape.Kind = IR.Variant_Field_Shape
              and then Shape.Cases = 2,
            "the parameter retains its variant cases and payload run");
         for Position in 1 .. IR.Value_Count (Unit, 2) loop
            declare
               Value : constant IR.Value_Id := IR.Value_Id (Position);
               Op : constant IR.Opcode := IR.Op_Of (Unit, 2, Value);
            begin
               if Op = IR.Select_Variant then
                  Selects := Selects + 1;
                  Landin.Testing.Check
                    (Item,
                     IR.Destination_Of (Unit, 2, Value).Kind = IR.Frame_Slot
                       and then IR.Element_Field_Of (Unit, 2, Value) = 2
                       and then IR.Path_Of (Unit, 2, Value)
                                  = IR.No_Path_Steps
                       and then IR.Variant_Case_Of (Unit, 2, Value) = 2,
                     "selection keeps its exact root, field and case");
                  Selected_Root :=
                    IR.Destination_Of (Unit, 2, Value).Slot;
               elsif Op = IR.Store_Field
                 and then IR.Field_Of (Unit, 2, Value) = 2
                 and then IR.Path_Depth_Of (Unit, 2, Value) > 0
               then
                  Stores := Stores + 1;
                  if Stores <= Expected_Values'Length then
                     declare
                        Stored : constant IR.Value_Id :=
                          IR.Nth_Operand (Unit, 2, Value, 1);
                     begin
                        Landin.Testing.Check
                          (Item,
                           IR.Reaches_A_Slot (Unit, 2, Value)
                             and then IR.Slot_Of (Unit, 2, Value)
                                        = Selected_Root
                             and then IR.Path_Of (Unit, 2, Value)
                                        = In_Case (2, Stores)
                             and then Stored = Value - 1
                             and then IR.Op_Of (Unit, 2, Stored) = IR.Number
                             and then IR.Result_Of (Unit, 2, Stored)
                                        = Landin.Types.U8
                             and then Folded_Number_Of (Unit, 2, Stored)
                                        = Expected_Values (Stores),
                           "payload leaves keep source order, type and path");
                     end;
                  end if;
               elsif Op = IR.Call
                 and then IR.Callee_Of (Unit, 2, Value) = 1
               then
                  Argument_Address := IR.Nth_Operand (Unit, 2, Value, 1);
               end if;
            end;
         end loop;
         Landin.Testing.Check
           (Item, Selects = 1 and then Stores = 2,
            "the caller constructs both selected payload leaves by path");
         Landin.Testing.Check
           (Item,
            Argument_Address /= IR.No_Value
              and then IR.Op_Of (Unit, 2, Argument_Address)
                         = IR.Storage_Address
              and then IR.Destination_Of (Unit, 2, Argument_Address).Kind
                         = IR.Frame_Slot
              and then IR.Destination_Of (Unit, 2, Argument_Address).Slot
                         = Selected_Root
              and then IR.Element_Field_Of (Unit, 2, Argument_Address) = 0
              and then IR.Path_Of (Unit, 2, Argument_Address)
                         = IR.No_Path_Steps,
            "the call carries the exact constructed temporary root");
         Landin.Testing.Check
           (Item, IR.Verifier.Check (Unit).Kind = IR.Verifier.Nothing_Wrong,
            "the verifier accepts the variant-bearing parameter carrier");
      end;
   end Variant_Arguments_Keep_Their_Shape;

   --  D106 uses one unspellable Usize parameter for caller-owned aggregate
   --  result storage.  The source result shape remains on its named slot.
   procedure Aggregate_Returns_Use_A_Hidden_Destination
     (Item : in out Landin.Testing.Context);

   procedure Aggregate_Returns_Use_A_Hidden_Destination
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
         & "make: () -> (result: pair) =" & LF
         & "    result = (left: 19, right: 23)" & LF
         & "end make" & LF
         & "use: () -> none =" & LF
         & "    mut answer: pair = make()" & LF
         & "end use" & LF
         & "make_row: () -> (result: [2]i32) =" & LF
         & "    result = [19, 23]" & LF
         & "end make_row" & LF
         & "use_row: () -> none =" & LF
         & "    mut answer: [2]i32 = make_row()" & LF
         & "end use_row" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "a struct result and typed call initializer are accepted");
      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Hidden : constant IR.Slot_Id := IR.Nth_Parameter (Unit, 1, 1);
         Call : IR.Value_Id := IR.No_Value;
      begin
         for Position in 1 .. IR.Value_Count (Unit, 2) loop
            if IR.Op_Of (Unit, 2, IR.Value_Id (Position)) = IR.Call then
               Call := IR.Value_Id (Position);
            end if;
         end loop;
         Landin.Testing.Check
           (Item,
            IR.Result_Of (Unit, 1) = Landin.Types.Aggregate
              and then IR.Parameter_Count (Unit, 1) = 1
              and then IR.Type_Of (Unit, 1, Hidden) = Landin.Types.Usize
              and then IR.Is_Aggregate
                (Unit, 1, IR.Result_Slot (Unit, 1)),
            "the routine retains its shape and hidden destination");
         Landin.Testing.Check
           (Item,
            Call /= IR.No_Value
              and then IR.Result_Of (Unit, 2, Call) = Landin.Types.No_Value
              and then IR.Operand_Count (Unit, 2, Call) = 1,
            "the call transports no aggregate as an IR value");
         Landin.Testing.Check
           (Item,
            IR.Result_Of (Unit, 3) = Landin.Types.Fixed_Array
              and then IR.Parameter_Count (Unit, 3) = 1
              and then IR.Is_Array
                (Unit, 3, IR.Result_Slot (Unit, 3)),
            "the same hidden convention retains a fixed-array result shape");
         Landin.Testing.Check
           (Item, IR.Verifier.Check (Unit).Kind = IR.Verifier.Nothing_Wrong,
            "the verifier accepts the aggregate result convention");
      end;
   end Aggregate_Returns_Use_A_Hidden_Destination;

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

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
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
                     when IR.Runtime_Address => null;
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
   --  part and writes its source-order tag.  Direct scalar payloads retain
   --  Store_Variant_Field, while scalar leaves below an array retain their
   --  complete one-based path into the selected case.
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

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "variant case construction is accepted");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         type Folded_List is
           array (Positive range <>) of Landin.Types.Folded;
         type Scalar_List is
           array (Positive range <>) of Landin.Types.Scalar_Name;
         Expected_Values : constant Folded_List := [5, 6, 9, 10, 2, 3];
         Expected_Types : constant Scalar_List :=
           [Landin.Types.U8, Landin.Types.U16,
            Landin.Types.U32, Landin.Types.U32,
            Landin.Types.U8, Landin.Types.U16];
         Selects, Alias_Stores, Path_Stores, Variant_Stores : Natural := 0;
         Construction_Stores : Natural := 0;
         Tag_Loads, Payload_Loads : Natural := 0;
         Array_Loads, Array_Stores, Array_Fills, Array_Copies : Natural := 0;
         Nested_Finite : Natural := 0;
         Slot_Row, Slot_Pair, Datum_Pair, Wide_Payload : Boolean := False;
         Slot_Tag, Datum_Tag : Boolean := False;
         Nested_Fill, Nested_Copy : Boolean := False;
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
               elsif Op = IR.Store_Variant_Field
                 and then IR.Destination_Of (Unit, 2, Id).Kind = IR.Frame_Slot
               then
                  Alias_Stores := Alias_Stores + 1;
                  declare
                     Stored : constant IR.Value_Id :=
                       IR.Nth_Operand (Unit, 2, Id, 1);
                  begin
                     Landin.Testing.Check
                       (Item,
                        IR.Destination_Of (Unit, 2, Id).Slot = 2
                          and then IR.Element_Field_Of (Unit, 2, Id) = 2
                          and then IR.Path_Of (Unit, 2, Id) = IR.No_Path_Steps
                          and then IR.Variant_Case_Of (Unit, 2, Id) = 2
                          and then IR.Variant_Payload_Field_Of
                            (Unit, 2, Id) = 2
                          and then IR.Op_Of (Unit, 2, Stored)
                            = IR.Load_Variant_Field
                          and then IR.Source_Of (Unit, 2, Stored).Kind
                            = IR.Frame_Slot
                          and then IR.Source_Of (Unit, 2, Stored).Slot = 2
                          and then IR.Element_Field_Of (Unit, 2, Stored) = 2
                          and then IR.Path_Of (Unit, 2, Stored)
                            = IR.No_Path_Steps
                          and then IR.Variant_Case_Of (Unit, 2, Stored) = 2
                          and then IR.Variant_Payload_Field_Of
                            (Unit, 2, Stored) = 2
                          and then IR.Result_Of (Unit, 2, Stored)
                            = Landin.Types.U16
                          and then Stored < Id,
                        "the inout alias reads and writes the same typed"
                        & " selected payload");
                  end;
               elsif Op = IR.Store_Variant_Field
                 or else
                   (Op = IR.Store_Field
                    and then IR.Field_Of (Unit, 2, Id) = 2
                    and then
                      (IR.Path_Of (Unit, 2, Id) = In_Case (2, 1)
                       or else IR.Path_Of (Unit, 2, Id) = In_Case (2, 2)
                       or else IR.Path_Of (Unit, 2, Id) = In_Case (3, 1, 1)
                       or else
                         IR.Path_Of (Unit, 2, Id) = In_Case (3, 1, 2)))
               then
                  Construction_Stores := Construction_Stores + 1;
                  if Op = IR.Store_Variant_Field then
                     Variant_Stores := Variant_Stores + 1;
                  else
                     Path_Stores := Path_Stores + 1;
                  end if;
                  if Construction_Stores <= Expected_Values'Length then
                     declare
                        Stored : constant IR.Value_Id :=
                          IR.Nth_Operand (Unit, 2, Id, 1);
                        Destination_Is_Exact : constant Boolean :=
                          (case Construction_Stores is
                              when 1 =>
                                Op = IR.Store_Field
                                and then IR.Reaches_A_Slot (Unit, 2, Id)
                                and then IR.Slot_Of (Unit, 2, Id) = 3
                                and then IR.Field_Of (Unit, 2, Id) = 2
                                and then IR.Path_Of (Unit, 2, Id)
                                  = In_Case (2, 1),
                              when 2 =>
                                Op = IR.Store_Field
                                and then IR.Reaches_A_Slot (Unit, 2, Id)
                                and then IR.Slot_Of (Unit, 2, Id) = 3
                                and then IR.Field_Of (Unit, 2, Id) = 2
                                and then IR.Path_Of (Unit, 2, Id)
                                  = In_Case (2, 2),
                              when 3 =>
                                Op = IR.Store_Field
                                and then IR.Reaches_A_Slot (Unit, 2, Id)
                                and then IR.Slot_Of (Unit, 2, Id) = 2
                                and then IR.Field_Of (Unit, 2, Id) = 2
                                and then IR.Path_Of (Unit, 2, Id)
                                  = In_Case (3, 1, 1),
                              when 4 =>
                                Op = IR.Store_Field
                                and then IR.Reaches_A_Slot (Unit, 2, Id)
                                and then IR.Slot_Of (Unit, 2, Id) = 2
                                and then IR.Field_Of (Unit, 2, Id) = 2
                                and then IR.Path_Of (Unit, 2, Id)
                                  = In_Case (3, 1, 2),
                              when 5 =>
                                Op = IR.Store_Variant_Field
                                and then
                                  IR.Destination_Of (Unit, 2, Id).Kind
                                    = IR.Module_Datum
                                and then
                                  IR.Destination_Of (Unit, 2, Id).Datum = 1
                                and then
                                  IR.Element_Field_Of (Unit, 2, Id) = 2
                                and then IR.Path_Of (Unit, 2, Id)
                                  = IR.No_Path_Steps
                                and then
                                  IR.Variant_Case_Of (Unit, 2, Id) = 2
                                and then IR.Variant_Payload_Field_Of
                                  (Unit, 2, Id) = 1,
                              when 6 =>
                                Op = IR.Store_Variant_Field
                                and then
                                  IR.Destination_Of (Unit, 2, Id).Kind
                                    = IR.Module_Datum
                                and then
                                  IR.Destination_Of (Unit, 2, Id).Datum = 1
                                and then
                                  IR.Element_Field_Of (Unit, 2, Id) = 2
                                and then IR.Path_Of (Unit, 2, Id)
                                  = IR.No_Path_Steps
                                and then
                                  IR.Variant_Case_Of (Unit, 2, Id) = 2
                                and then IR.Variant_Payload_Field_Of
                                  (Unit, 2, Id) = 2,
                              when others => False);
                     begin
                        Landin.Testing.Check
                          (Item,
                           Stored = Id - 1
                             and then IR.Op_Of (Unit, 2, Stored) = IR.Number
                             and then IR.Result_Of (Unit, 2, Stored)
                               = Expected_Types (Construction_Stores)
                             and then Folded_Number_Of (Unit, 2, Stored)
                               = Expected_Values (Construction_Stores)
                             and then Destination_Is_Exact,
                           "constructed leaves keep opcode, root, identity,"
                           & " type and global source order");
                        if Construction_Stores in 3 | 4 then
                           Nested_Finite := Nested_Finite + 1;
                        elsif Construction_Stores = 6 then
                           Wide_Payload := True;
                        end if;
                     end;
                  end if;
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
                     and then IR.Destination_Of (Unit, 2, Id).Slot = 2
                     and then IR.Element_Field_Of (Unit, 2, Id) = 2
                     and then IR.Path_Of (Unit, 2, Id) = In_Case (3, 2)
                     and then IR.Variant_Case_Of (Unit, 2, Id) = 0
                     and then IR.Variant_Payload_Field_Of
                       (Unit, 2, Id) = 0
                     and then IR.First_Part_Of (Unit, 2, Id) = 1
                     and then IR.Result_Of
                       (Unit, 2, IR.Nth_Operand (Unit, 2, Id, 1))
                         = Landin.Types.U32
                     and then Folded_Number_Of
                       (Unit, 2, IR.Nth_Operand (Unit, 2, Id, 1)) = 11);
               elsif Op = IR.Copy_Array then
                  Array_Copies := Array_Copies + 1;
                  Nested_Copy := Nested_Copy or else
                    (IR.Destination_Of (Unit, 2, Id).Kind = IR.Frame_Slot
                     and then IR.Destination_Of (Unit, 2, Id).Slot = 2
                     and then IR.Source_Of (Unit, 2, Id).Kind = IR.Frame_Slot
                     and then IR.Source_Of (Unit, 2, Id).Slot = 1
                     and then IR.Element_Field_Of (Unit, 2, Id) = 2
                     and then IR.Path_Of (Unit, 2, Id) = In_Case (3, 3)
                     and then IR.Variant_Case_Of (Unit, 2, Id) = 0
                     and then IR.Variant_Payload_Field_Of
                       (Unit, 2, Id) = 0
                     and then IR.Source_Field_Of (Unit, 2, Id) = 0
                     and then IR.Source_Path_Of (Unit, 2, Id)
                       = IR.No_Path_Steps);
               end if;
            end;
         end loop;

         Landin.Testing.Check
           (Item,
            Selects = 4 and then Variant_Stores = 2
              and then Path_Stores = 4 and then Construction_Stores = 6
              and then Alias_Stores = 1,
            "case construction keeps all six selected leaves"
            & " and one typed alias store");
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
            Array_Loads = 5 and then Array_Stores = 2
              and then Array_Fills = 1
              and then Array_Copies = 1 and then Nested_Finite = 2
              and then Nested_Fill and then Nested_Copy,
            "array writes keep finite paths and dynamic selected operations");
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

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
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

   --  D136 admits D17's zero-element source shape. This older public-table
   --  seam still asks lowering the same representation question independently
   --  of parsing and checking the direct `[0]T` corpus fixtures.
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
      Landin.Stages.Append (Front, Configurer'Access);
      Landin.Stages.Append (Front, Names'Access);
      Landin.Stages.Append (Front, Checker'Access);
      Ran := Landin.Stages.Run (Front, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");
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

   --  D125 makes the enclosing operation own the storage through which a
   --  control value crosses its join.  Scalar and function storage stay in
   --  scalar IR slots, the latter retaining its signature; arrays and
   --  aggregates retain their complete target-neutral shape.
   procedure Control_Values_Use_Caller_Owned_Join_Slots
     (Item : in out Landin.Testing.Context);

   procedure Control_Values_Use_Caller_Owned_Join_Slots
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
         & "choice: type = struct" & LF
         & "    kind: variant" & LF
         & "        left |" & LF
         & "        right" & LF
         & "    end kind" & LF
         & "end choice" & LF
         & "take_pair: (value: pair) -> (result: i32) =" & LF
         & "    result = value.left + value.right" & LF
         & "end take_pair" & LF
         & "take_row: (value: [2]i32) -> (result: i32) =" & LF
         & "    result = value[0] + value[1]" & LF
         & "end take_row" & LF
         & "take_int: (value: i32) -> (result: i32) =" & LF
         & "    result = value" & LF
         & "end take_int" & LF
         & "unary: type = (value: i32) -> (result: i32)" & LF
         & "identity: (value: i32) -> (result: i32) =" & LF
         & "    result = value" & LF
         & "end identity" & LF
         & "take_function: (candidate: unary) -> (result: i32) =" & LF
         & "    result = candidate(42)" & LF
         & "end take_function" & LF
         & "use: (flag: bool, selected: choice) -> (result: i32) =" & LF
         & "    result = take_pair(if flag then" & LF
         & "        pair(left: 19, right: 23)" & LF
         & "    else" & LF
         & "        pair(left: 21, right: 21)" & LF
         & "    end if)" & LF
         & "    + take_row(begin" & LF
         & "        if flag then [19, 23] else [21, 21] end if" & LF
         & "    end)" & LF
         & "    + take_int(match selected.kind" & LF
         & "        left: if flag then 19 else 21 end if" & LF
         & "        right: 23" & LF
         & "    end match)" & LF
         & "    + take_function(" & LF
         & "        if flag then take_int else identity end if)" & LF
         & "end use" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "scalar, function and stored control values are lowered");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Use_Item : constant IR.Item_Id := 6;
         Scalar_Joins    : Natural := 0;
         Function_Joins  : Natural := 0;
         Aggregate_Joins : Natural := 0;
         Array_Joins     : Natural := 0;
         Aggregate_Shape : Boolean := False;
         Array_Shape     : Boolean := False;
      begin
         for Which in 1 .. IR.Slot_Count (Unit, Use_Item) loop
            declare
               Slot : constant IR.Slot_Id := IR.Slot_Id (Which);
            begin
               if IR.Declares (Unit, Use_Item, Slot) = IR.No_Declaration then
                  if IR.Is_Aggregate (Unit, Use_Item, Slot) then
                     Aggregate_Joins := Aggregate_Joins + 1;
                     Aggregate_Shape :=
                       IR.Slot_Field_Count (Unit, Use_Item, Slot) = 2;
                  elsif IR.Is_Array (Unit, Use_Item, Slot) then
                     Array_Joins := Array_Joins + 1;
                     Array_Shape :=
                       IR.Slot_Array_Element (Unit, Use_Item, Slot)
                           = Landin.Types.I32
                       and then IR.Slot_Array_Length
                         (Unit, Use_Item, Slot) = 2;
                  elsif IR.Type_Of (Unit, Use_Item, Slot)
                          = Landin.Types.Usize
                    and then IR.Signature_Of (Unit, Use_Item, Slot)
                               /= IR.No_Signature
                  then
                     Function_Joins := Function_Joins + 1;
                  elsif IR.Type_Of (Unit, Use_Item, Slot)
                          = Landin.Types.I32
                  then
                     Scalar_Joins := Scalar_Joins + 1;
                  end if;
               end if;
            end;
         end loop;

         Landin.Testing.Check
           (Item,
            Scalar_Joins >= 1
              and then Function_Joins = 1
              and then Aggregate_Joins = 1
              and then Array_Joins = 1,
            "every value shape gets unnamed caller-owned join storage");
         Landin.Testing.Check
           (Item, Aggregate_Shape and then Array_Shape,
            "stored joins retain aggregate fields and fixed-array extent");
         Check_Terminators (Item, Unit, "control expression values");
         Landin.Testing.Check
           (Item, IR.Verifier.Check (Unit).Kind = IR.Verifier.Nothing_Wrong,
            "the verifier accepts caller-owned control joins");
      end;
   end Control_Values_Use_Caller_Owned_Join_Slots;

   --  A final call overlaps the parser's statement and value shapes.  Once
   --  checking learns that it returns none, every control form must preserve
   --  the statement path instead of asking that call for a joined value.
   procedure Statement_Controls_Keep_Final_None_Calls
     (Item : in out Landin.Testing.Context);

   procedure Statement_Controls_Keep_Final_None_Calls
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "choice: type = struct" & LF
         & "    kind: variant" & LF
         & "        left |" & LF
         & "        right" & LF
         & "    end kind" & LF
         & "end choice" & LF
         & "step: () -> none =" & LF
         & "end step" & LF
         & "use: (flag: bool, selected: choice) -> none =" & LF
         & "    if flag then step() else step() end if" & LF
         & "    match selected.kind" & LF
         & "        left: step()" & LF
         & "        right: step()" & LF
         & "    end match" & LF
         & "    begin" & LF
         & "        step()" & LF
         & "    end" & LF
         & "end use" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "final none calls remain statements in every control form");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Calls : Natural := 0;
      begin
         for Which in 1 .. IR.Value_Count (Unit, 2) loop
            if IR.Op_Of (Unit, 2, IR.Value_Id (Which)) = IR.Call then
               Calls := Calls + 1;
            end if;
         end loop;
         Landin.Testing.Check_Equal
           (Item, Calls, 5, "every selected final call is lowered normally");
         Check_Terminators (Item, Unit, "statement control final calls");
         Landin.Testing.Check
           (Item, IR.Verifier.Check (Unit).Kind = IR.Verifier.Nothing_Wrong,
            "the verifier accepts statement controls with final none calls");
      end;
   end Statement_Controls_Keep_Final_None_Calls;

   --  D124 permits a control value whose every reachable edge returns.  It
   --  has no answer to carry and no continuing predecessor, so D125 must not
   --  leave an unreachable merge block merely to give lowering somewhere to
   --  continue.  The verifier's reachability rule pins that boundary.
   procedure All_Return_Controls_Create_No_Join_Block
     (Item : in out Landin.Testing.Context);

   procedure All_Return_Controls_Create_No_Join_Block
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "choice: type = struct" & LF
         & "    kind: variant" & LF
         & "        left |" & LF
         & "        right" & LF
         & "    end kind" & LF
         & "end choice" & LF
         & "if_exit: (flag: bool) -> (result: i32) =" & LF
         & "    result = 42" & LF
         & "    result = if flag then" & LF
         & "        return" & LF
         & "    else" & LF
         & "        return" & LF
         & "    end if" & LF
         & "end if_exit" & LF
         & "bare_exit: () -> (result: i32) =" & LF
         & "    result = 42" & LF
         & "    result = begin" & LF
         & "        return" & LF
         & "    end" & LF
         & "end bare_exit" & LF
         & "match_exit: (selected: choice) -> (result: i32) =" & LF
         & "    result = 42" & LF
         & "    result = match selected.kind" & LF
         & "        left: return" & LF
         & "        right: return" & LF
         & "    end match" & LF
         & "end match_exit" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "all-return controls are lowered without a placeholder answer");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
      begin
         Landin.Testing.Check_Equal
           (Item, IR.Block_Count (Unit, 1), 4,
            "the if has only its reached test, arm and else blocks");
         Landin.Testing.Check_Equal
           (Item, IR.Block_Count (Unit, 2), 2,
            "the bare block has only its entry and reached body");
         Landin.Testing.Check_Equal
           (Item, IR.Block_Count (Unit, 3), 4,
            "the match has only its reached dispatch and arm blocks");
         Check_Terminators (Item, Unit, "all-return control expressions");
         Landin.Testing.Check
           (Item, IR.Verifier.Check (Unit).Kind = IR.Verifier.Nothing_Wrong,
            "the verifier sees no orphan join after an all-return control");
      end;
   end All_Return_Controls_Create_No_Join_Block;

   --  [1100]'s stack disappears during lowering: each selected exit contains
   --  ordinary target-neutral calls in reverse registration order.  The
   --  inner block falls through before the outer explicit return, and the
   --  verifier must see no new cleanup instruction or exceptional edge.
   procedure Deferred_Exits_Become_Ordinary_Reverse_Calls
     (Item : in out Landin.Testing.Context);

   procedure Deferred_Exits_Become_Ordinary_Reverse_Calls
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "mark: (value: i32) -> none = _ = value end mark" & LF
         & "f: () -> (result: i32) =" & LF
         & "    defer mark(1)" & LF
         & "    begin" & LF
         & "        defer mark(2)" & LF
         & "    end" & LF
         & "    result = 42" & LF
         & "    return" & LF
         & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "nested fallthrough and return cleanups are lowered");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Routine : constant IR.Item_Id := 2;
         Calls : Natural := 0;
         Values : array (1 .. 2) of Landin.Types.Magnitude := [others => 0];
      begin
         for Which in 1 .. IR.Value_Count (Unit, Routine) loop
            declare
               Value : constant IR.Value_Id := IR.Value_Id (Which);
            begin
               if IR.Op_Of (Unit, Routine, Value) = IR.Call
                 and then IR.Callee_Of (Unit, Routine, Value) = 1
               then
                  Calls := Calls + 1;
                  if Calls <= Values'Last
                    and then IR.Operand_Count (Unit, Routine, Value) = 1
                  then
                     declare
                        Argument : constant IR.Value_Id :=
                          IR.Nth_Operand (Unit, Routine, Value, 1);
                     begin
                        if IR.Op_Of (Unit, Routine, Argument) = IR.Number then
                           Values (Calls) :=
                             IR.Number_Of (Unit, Routine, Argument);
                        end if;
                     end;
                  end if;
               end if;
            end;
         end loop;

         Landin.Testing.Check_Equal
           (Item, Calls, 2, "both lexical cleanups become direct calls");
         Landin.Testing.Check
           (Item, Values = [2, 1],
            "the inner fallthrough call precedes the outer return call");
         Check_Terminators (Item, Unit, "deferred cleanup calls");
         Landin.Testing.Check
           (Item, IR.Verifier.Check (Unit).Kind = IR.Verifier.Nothing_Wrong,
            "the verifier accepts cleanup lowered as ordinary calls");
      end;
   end Deferred_Exits_Become_Ordinary_Reverse_Calls;

   --  [1110] shares defer's lexical stack but not its selector.  The
   --  propagated branch contains the mixed stack in reverse registration
   --  order; the possible success branch and an explicit return contain
   --  only defer.  All remain ordinary calls in verifier-visible IR.
   procedure Undo_Exits_Become_Selected_Reverse_Calls
     (Item : in out Landin.Testing.Context);

   procedure Undo_Exits_Become_Selected_Reverse_Calls
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "bad: atom" & LF
         & "problem: type = bad" & LF
         & "mark: (value: i32) -> none = _ = value end mark" & LF
         & "failure: () -> none ! problem = fail bad end failure" & LF
         & "fails: () -> none ! ... =" & LF
         & "    defer mark(1)" & LF
         & "    undo mark(2)" & LF
         & "    begin" & LF
         & "        defer mark(3)" & LF
         & "        undo mark(4)" & LF
         & "        try failure()" & LF
         & "    end" & LF
         & "end fails" & LF
         & "succeeds: () -> none ! problem =" & LF
         & "    undo mark(5)" & LF
         & "    defer mark(6)" & LF
         & "    return" & LF
         & "end succeeds" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "mixed failure-only and deferred cleanups are lowered");

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Fails_Routine : constant IR.Item_Id := 3;
         Success_Routine : constant IR.Item_Id := 4;
         type Magnitude_Array is
           array (Positive range <>) of Landin.Types.Magnitude;
         Failed_Calls : Natural := 0;
         Failed_Values : Magnitude_Array (1 .. 6) :=
           [others => 0];
         Success_Calls : Natural := 0;
         Success_Value : Landin.Types.Magnitude := 0;

         procedure Read_Mark_Calls
           (Routine : IR.Item_Id;
            Count   : in out Natural;
            Values  : in out Magnitude_Array);

         procedure Read_Mark_Calls
           (Routine : IR.Item_Id;
            Count   : in out Natural;
            Values  : in out Magnitude_Array)
         is
         begin
            for Which in 1 .. IR.Value_Count (Unit, Routine) loop
               declare
                  Value : constant IR.Value_Id := IR.Value_Id (Which);
               begin
                  if IR.Op_Of (Unit, Routine, Value) = IR.Call
                    and then IR.Callee_Of (Unit, Routine, Value) = 1
                  then
                     Count := Count + 1;
                     if Count <= Values'Length
                       and then IR.Operand_Count (Unit, Routine, Value) = 1
                     then
                        declare
                           Argument : constant IR.Value_Id :=
                             IR.Nth_Operand (Unit, Routine, Value, 1);
                        begin
                           if IR.Op_Of (Unit, Routine, Argument) = IR.Number
                           then
                              Values (Values'First + Count - 1) :=
                                IR.Number_Of (Unit, Routine, Argument);
                           end if;
                        end;
                     end if;
                  end if;
               end;
            end loop;
         end Read_Mark_Calls;
      begin
         Read_Mark_Calls
           (Fails_Routine, Failed_Calls, Failed_Values);
         declare
            One : Magnitude_Array (1 .. 1) := [others => 0];
         begin
            Read_Mark_Calls (Success_Routine, Success_Calls, One);
            Success_Value := One (1);
         end;

         Landin.Testing.Check_Equal
           (Item, Failed_Calls, 6,
            "failure and possible success paths contain six selected calls");
         Landin.Testing.Check
           (Item, Failed_Values = [4, 3, 2, 1, 3, 1],
            "failure selects mixed LIFO while success selects defer alone");
         Landin.Testing.Check_Equal
           (Item, Success_Calls, 1,
            "a successful return skips its registered undo");
         Landin.Testing.Check
           (Item, Success_Value = 6,
            "the successful return retains its ordinary defer");
         Check_Terminators (Item, Unit, "failure-only cleanup calls");
         Landin.Testing.Check
           (Item, IR.Verifier.Check (Unit).Kind = IR.Verifier.Nothing_Wrong,
            "the verifier accepts undo lowered as ordinary failure calls");
      end;
   end Undo_Exits_Become_Selected_Reverse_Calls;

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

   --  Driver.Execute does not expose its Compilation, which the IR dump needs.
   --  Follow its reachable-module route here: parse each newly loaded suffix,
   --  record the same module graph, then run the ordinary five-stage pipeline.
   procedure Lower_Rooted_Fixture
     (Work    : in out Landin.Stages.Compilation;
      Each    : Landin.Testing.Fixtures.Fixture;
      Host    : Landin.Platform.Filesystem'Class;
      Ran     : out Natural;
      Loaded  : out Boolean;
      Problem : out Ada.Strings.Unbounded.Unbounded_String);

   procedure Lower_Rooted_Fixture
     (Work    : in out Landin.Stages.Compilation;
      Each    : Landin.Testing.Fixtures.Fixture;
      Host    : Landin.Platform.Filesystem'Class;
      Ran     : out Natural;
      Loaded  : out Boolean;
      Problem : out Ada.Strings.Unbounded.Unbounded_String)
   is
      package Unbounded renames Ada.Strings.Unbounded;
      package Fixtures renames Landin.Testing.Fixtures;
      package Module_Vectors is new Ada.Containers.Vectors
        (Index_Type => Positive, Element_Type => Landin.Modules.Module_Id);

      Root_Prefix : constant String := "--root=";
      Arguments   : Landin.Platform.Path_List;
      Roots       : Landin.Platform.Path_List;
      Entry_Directory : Unbounded.Unbounded_String;
      Program_Path : Unbounded.Unbounded_String;
      Program_Loaded : Boolean := False;
      Graph       : constant not null access Landin.Modules.Table :=
        Landin.Stages.Modules (Work);
      Queue       : Module_Vectors.Vector;
      Next        : Positive := 1;

      procedure Refuse (Why : String);
      function Joined_Path (Directory, Child : String) return String;
      function Is_Source_Name (Name : String) return Boolean;
      function Import_Path
        (Of_Tree : Landin.Syntax.Tree;
         Node    : Landin.Syntax.Node_Id) return String;
      function Select_Module_Directory
        (Of_Tree : Landin.Syntax.Tree;
         Node    : Landin.Syntax.Node_Id;
         Root_At : out Natural) return String;

      procedure Refuse (Why : String) is
      begin
         if Unbounded.Length (Problem) = 0 then
            Problem := Unbounded.To_Unbounded_String (Why);
         end if;
         Loaded := False;
      end Refuse;

      function Joined_Path (Directory, Child : String) return String is
        (if Directory'Length > 0
             and then Directory (Directory'Last) = '/'
         then Directory & Child
         else Directory & "/" & Child);

      function Is_Source_Name (Name : String) return Boolean is
        (Name'Length > 4
         and then Name (Name'Last - 3 .. Name'Last) = ".ldn");

      function Import_Path
        (Of_Tree : Landin.Syntax.Tree;
         Node    : Landin.Syntax.Node_Id) return String
      is
         Built : Unbounded.Unbounded_String;
      begin
         for Position in
           1 .. Landin.Syntax.Import_Segment_Count (Of_Tree, Node)
         loop
            if Position > 1 then
               Unbounded.Append (Built, "/");
            end if;
            Unbounded.Append
              (Built,
               Landin.Source.Names.Spelling
                 (Landin.Stages.Identities (Work).all,
                  Landin.Syntax.Name
                    (Of_Tree,
                     Landin.Syntax.Nth_Import_Segment
                       (Of_Tree, Node, Position))));
         end loop;
         return Unbounded.To_String (Built);
      end Import_Path;

      function Select_Module_Directory
        (Of_Tree : Landin.Syntax.Tree;
         Node    : Landin.Syntax.Node_Id;
         Root_At : out Natural) return String
      is
      begin
         Root_At := 0;
         for Root_Index in 1 .. Natural (Roots.Length) loop
            declare
               Current : Unbounded.Unbounded_String :=
                 Unbounded.To_Unbounded_String (Roots.Element (Root_Index));
               Matched : Boolean := True;
            begin
               for Position in
                 1 .. Landin.Syntax.Import_Segment_Count (Of_Tree, Node)
               loop
                  declare
                     Segment : constant String :=
                       Landin.Source.Names.Spelling
                         (Landin.Stages.Identities (Work).all,
                          Landin.Syntax.Name
                            (Of_Tree,
                             Landin.Syntax.Nth_Import_Segment
                               (Of_Tree, Node, Position)));
                     Entries : Landin.Platform.Path_List;
                     Status  : Landin.Platform.List_Status;
                     Found   : Boolean := False;
                  begin
                     Host.List_Directory
                       (Unbounded.To_String (Current), Entries, Status);
                     if Status /= Landin.Platform.List_Ok then
                        Matched := False;
                        exit;
                     end if;
                     for Child_Name of Entries loop
                        if Child_Name = Segment then
                           Found := True;
                           exit;
                        end if;
                     end loop;
                     if not Found then
                        Matched := False;
                        exit;
                     end if;
                     Current := Unbounded.To_Unbounded_String
                       (Joined_Path
                          (Unbounded.To_String (Current), Segment));
                     if not Host.Is_Directory
                       (Unbounded.To_String (Current))
                     then
                        Matched := False;
                        exit;
                     end if;
                  end;
               end loop;
               if Matched then
                  Root_At := Root_Index;
                  return Unbounded.To_String (Current);
               end if;
            end;
         end loop;
         return "";
      end Select_Module_Directory;

   begin
      Ran := 0;
      Loaded := True;
      Problem := Unbounded.Null_Unbounded_String;

      --  Use the same metadata-to-driver argument boundary as positive,
      --  runtime, ABI and parser-corpus execution.  The real repository host
      --  is deliberate here: an IR golden for a rooted fixture must include
      --  its actual reachable modules.  Unrooted fixtures keep the isolated
      --  source-text lowering seam below.
      Fixtures.Append_Module_Arguments (Each, Fixture_Root, Arguments);
      if Natural (Arguments.Length) /= 2 then
         Refuse
           ("rooted fixture did not produce one root and one entry module: "
            & Fixtures.Name (Each));
         return;
      end if;

      declare
         Root_Option : constant String := Arguments.Element (1);
      begin
         if Root_Option'Length <= Root_Prefix'Length
           or else Root_Option
             (Root_Option'First
              .. Root_Option'First + Root_Prefix'Length - 1) /= Root_Prefix
         then
            Refuse
              ("rooted fixture produced an invalid root argument: "
               & Fixtures.Name (Each));
            return;
         end if;
         Roots.Append
           (Root_Option
              (Root_Option'First + Root_Prefix'Length .. Root_Option'Last));
      end;
      Entry_Directory := Unbounded.To_Unbounded_String (Arguments.Element (2));
      Program_Path := Unbounded.To_Unbounded_String
        (Joined_Path
           (Unbounded.To_String (Entry_Directory), Fixtures.Program (Each)));

      if not Host.Is_Directory (Unbounded.To_String (Entry_Directory)) then
         Refuse
           ("entry module is not a directory while recording: "
            & Unbounded.To_String (Entry_Directory));
         return;
      end if;

      Landin.Modules.Set_Entry_Directory
        (Graph.all, Unbounded.To_String (Entry_Directory));
      Queue.Append (Landin.Modules.Entry_Module);

      while Loaded and then Next <= Natural (Queue.Length) loop
         declare
            Module : constant Landin.Modules.Module_Id := Queue.Element (Next);
            Directory : constant String :=
              Landin.Modules.Directory_Path (Graph.all, Module);
            Entries   : Landin.Platform.Path_List;
            Listed    : Landin.Platform.List_Status;
            First_New : constant Natural :=
              Landin.Stages.Source_Count (Work) + 1;
         begin
            Host.List_Directory (Directory, Entries, Listed);
            if Listed /= Landin.Platform.List_Ok then
               Refuse
                 ("module directory cannot be listed while recording: "
                  & Directory);
            else
               for Child_Name of Entries loop
                  declare
                     Path : constant String :=
                       Joined_Path (Directory, Child_Name);
                  begin
                     if Is_Source_Name (Child_Name)
                       and then not Host.Is_Directory (Path)
                     then
                        declare
                           Content : Unbounded.Unbounded_String;
                           Status  : Landin.Platform.Read_Status;
                        begin
                           Host.Read_File (Path, Content, Status);
                           if Status = Landin.Platform.Read_Ok then
                              if Path = Unbounded.To_String (Program_Path) then
                                 Program_Loaded := True;
                              end if;
                              declare
                                 Id : constant Landin.Source.Source_Id :=
                                   Landin.Stages.Add_Source
                                     (Work, Module, Path,
                                      Unbounded.To_String (Content));
                                 pragma Unreferenced (Id);
                              begin
                                 null;
                              end;
                           else
                              Refuse
                                ("module source cannot be read while"
                                 & " recording: " & Path);
                              exit;
                           end if;
                        end;
                     end if;
                  end;
               end loop;

               if Loaded
                 and then Landin.Stages.Source_Count (Work) >= First_New
               then
                  declare
                     Outcome : Landin.Stages.Stage_Outcome;
                  begin
                     Frontend.Run (Work, Outcome);
                  end;
                  if Landin.Stages.Failed (Work) then
                     Refuse
                       ("syntax failed while discovering rooted fixture "
                        & Fixtures.Name (Each));
                  end if;
               end if;

               if Loaded then
                  for Source_Index in First_New
                    .. Landin.Stages.Source_Count (Work)
                  loop
                     declare
                        Source_Id : constant Landin.Source.Source_Id :=
                          Landin.Stages.Nth_Source (Work, Source_Index);
                        Tree : constant not null access constant
                          Landin.Syntax.Tree :=
                            Landin.Syntax.Forest.Tree_Of
                              (Landin.Stages.Trees (Work).all, Source_Id);
                     begin
                        for Import_Index in
                          1 .. Landin.Syntax.Import_Count (Tree.all)
                        loop
                           declare
                              Import_Node : constant Landin.Syntax.Node_Id :=
                                Landin.Syntax.Nth_Import
                                  (Tree.all, Import_Index);
                              Logical : constant String :=
                                Import_Path (Tree.all, Import_Node);
                              Target : Landin.Modules.Module_Id :=
                                Landin.Modules.Find_Logical
                                  (Graph.all, Logical);
                           begin
                              if Landin.Configuration.Is_Builtin_Import
                                (Landin.Stages.Identities (Work).all,
                                 Tree.all, Import_Node)
                              then
                                 null;
                              elsif Target = Landin.Modules.No_Module then
                                 declare
                                    Selected_Root : Natural;
                                    Selected : constant String :=
                                      Select_Module_Directory
                                        (Tree.all, Import_Node,
                                         Selected_Root);
                                 begin
                                    if Selected = "" then
                                       Refuse
                                         ("module not found while recording "
                                          & Fixtures.Name (Each) & ": "
                                          & Logical);
                                    else
                                       Target :=
                                         Landin.Modules.Find_Directory
                                           (Graph.all, Selected);
                                       if Target = Landin.Modules.No_Module
                                       then
                                          Target := Landin.Modules.Add_Module
                                            (Graph.all, Logical, Selected,
                                             Positive (Selected_Root));
                                          Queue.Append (Target);
                                       end if;
                                    end if;
                                 end;
                              end if;

                              if Loaded
                                and then Target /= Landin.Modules.No_Module
                              then
                                 Landin.Modules.Record_Import
                                   (Graph.all, Source_Id, Import_Node, Target);
                              end if;
                              exit when not Loaded;
                           end;
                        end loop;
                        exit when not Loaded;
                     end;
                  end loop;
               end if;
            end if;
         end;
         Next := Next + 1;
      end loop;

      if Loaded and then not Program_Loaded then
         Refuse
           ("rooted fixture program was not loaded while recording: "
            & Unbounded.To_String (Program_Path));
      end if;

      if Loaded and then Landin.Stages.Source_Count (Work) > 0 then
         declare
            Order : Landin.Stages.Pipeline;
         begin
            Landin.Stages.Append (Order, Frontend'Access);
            Landin.Stages.Append (Order, Configurer'Access);
            Landin.Stages.Append (Order, Names'Access);
            Landin.Stages.Append (Order, Checker'Access);
            Landin.Stages.Append (Order, Lowerer'Access);
            Ran := Landin.Stages.Run (Order, Work);
         end;
      elsif Loaded then
         Refuse
           ("rooted fixture contains no source while recording: "
            & Fixtures.Name (Each));
      end if;
   end Lower_Rooted_Fixture;

   type Corpus_Build is record
      Text     : Ada.Strings.Unbounded.Unbounded_String;
      Problems : Ada.Strings.Unbounded.Unbounded_String;
      Complete : Boolean := True;
   end record;

   function Corpus_Text
     (Host : Landin.Platform.Filesystem'Class) return Corpus_Build;

   function Corpus_Text
     (Host : Landin.Platform.Filesystem'Class) return Corpus_Build
   is
      package Unbounded renames Ada.Strings.Unbounded;
      package Fixtures renames Landin.Testing.Fixtures;

      type Additional_Build is record
         Text     : Unbounded.Unbounded_String;
         Problem  : Unbounded.Unbounded_String;
         Complete : Boolean := True;
      end record;

      Found       : Fixtures.Catalogue;
      Built       : Corpus_Build;
      Expected    : Natural := 0;
      Represented : Natural := 0;

      procedure Report_Problem (Why : String);
      function Additional_For
        (Each : Fixtures.Fixture) return Additional_Build;

      procedure Report_Problem (Why : String) is
      begin
         Built.Complete := False;
         if Unbounded.Length (Built.Problems) > 0 then
            Unbounded.Append (Built.Problems, LF);
         end if;
         Unbounded.Append (Built.Problems, Why);
      end Report_Problem;

      function Additional_For
        (Each : Fixtures.Fixture) return Additional_Build
      is
         Rest   : constant String := Fixtures.With_Sources (Each);
         Result : Additional_Build;
         First  : Integer := Rest'First;

         procedure Append_One (Named : String);

         procedure Append_One (Named : String) is
            Trimmed : constant String :=
              Ada.Strings.Fixed.Trim (Named, Ada.Strings.Both);
            Contents : Unbounded.Unbounded_String;
            Status   : Landin.Platform.Read_Status;
            Path     : constant String :=
              Fixture_Root & "/positive/" & Fixtures.Name (Each)
              & "/" & Trimmed;
         begin
            if Trimmed = "" then
               Result.Complete := False;
               Result.Problem := Unbounded.To_Unbounded_String
                 ("empty with source while recording positive/"
                  & Fixtures.Name (Each));
            else
               Host.Read_File (Path, Contents, Status);
               if Status = Landin.Platform.Read_Ok then
                  Unbounded.Append
                    (Result.Text, Unbounded.To_String (Contents));
               else
                  Result.Complete := False;
                  Result.Problem := Unbounded.To_Unbounded_String
                    ("with source cannot be read while recording: " & Path);
               end if;
            end if;
         end Append_One;
      begin
         for Index in Rest'Range loop
            if Rest (Index) = ',' then
               Append_One (Rest (First .. Index - 1));
               First := Index + 1;
            end if;
         end loop;
         if First <= Rest'Last then
            Append_One (Rest (First .. Rest'Last));
         end if;
         return Result;
      end Additional_For;
   begin
      Fixtures.Discover (Found, Fixture_Root, Host);

      for Index in 1 .. Fixtures.Problem_Count (Found) loop
         Report_Problem
           ("fixture discovery failed while recording: "
            & Fixtures.Nth_Problem (Found, Index));
      end loop;

      Unbounded.Append
        (Built.Text,
         "# Generated by landin_tests --record.  Do not edit." & LF
         & "# Every positive fixture, lowered to Landin.IR and rendered"
         & " by Landin.IR.Dump." & LF
         & "# Target: linux-x86-64.  Not a stable interface; see"
         & " landin-ir-dump.ads." & LF);

      for Index in 1 .. Fixtures.Count (Found) loop
         declare
            Each : constant Fixtures.Fixture := Fixtures.Nth (Found, Index);
         begin
            if Fixtures.Class (Each) = Fixtures.Positive_Program then
               Expected := Expected + 1;
               if Fixtures.Program (Each) = "" then
                  Report_Problem
                    ("positive fixture has no corpus source while recording: "
                     & Fixtures.Name (Each));
               else
                  declare
                     Work : Landin.Stages.Compilation :=
                       Landin.Stages.Create (Landin.Targets.Linux_X86_64);
                     Ran     : Natural := 0;
                     Ready   : Boolean := True;
                     Problem : Unbounded.Unbounded_String;
                  begin
                     if Fixtures.Module_Root (Each) /= "" then
                        Lower_Rooted_Fixture
                          (Work, Each, Host, Ran, Ready, Problem);
                        if not Ready then
                           Report_Problem (Unbounded.To_String (Problem));
                        end if;
                     else
                        declare
                           Where : constant String :=
                             Fixture_Root & "/positive/"
                             & Fixtures.Name (Each) & "/"
                             & Fixtures.Program (Each);
                           Body_Text  : Unbounded.Unbounded_String;
                           Status     : Landin.Platform.Read_Status;
                           Additional : constant Additional_Build :=
                             Additional_For (Each);
                        begin
                           Host.Read_File (Where, Body_Text, Status);
                           if Status /= Landin.Platform.Read_Ok then
                              Ready := False;
                              Report_Problem
                                ("positive source cannot be read while"
                                 & " recording: " & Where);
                           elsif not Additional.Complete then
                              Ready := False;
                              Report_Problem
                                (Unbounded.To_String (Additional.Problem));
                           else
                              --  Preserve the original isolated source seam:
                              --  nonroot programs and their `with` text are
                              --  added directly, without exposing the host to
                              --  any stage.
                              Lower
                                (Work, Unbounded.To_String (Body_Text), Ran,
                                 Unbounded.To_String (Additional.Text));
                           end if;
                        end;
                     end if;

                     if Ready then
                        if Landin.Stages.Failed (Work) then
                           declare
                              Report : constant String :=
                                Landin.Stages.Rendered_Report (Work);
                           begin
                              Report_Problem
                                ("positive/" & Fixtures.Name (Each)
                                 & " failed to lower"
                                 & (if Report = "" then "" else LF & Report));
                           end;
                        elsif Ran /= 5 then
                           Report_Problem
                             ("positive/" & Fixtures.Name (Each)
                              & " did not run all five lowering stages");
                        else
                           Unbounded.Append
                             (Built.Text,
                              "file positive/" & Fixtures.Name (Each)
                              & "/" & Fixtures.Program (Each) & LF);
                           Unbounded.Append
                             (Built.Text,
                              Landin.IR.Dump.Text
                                (Landin.Stages.Code (Work).all,
                                 Landin.Stages.Meanings (Work).all,
                                 Landin.Stages.Identities (Work).all));
                           Represented := Represented + 1;
                        end if;
                     end if;
                  end;
               end if;
            end if;
         end;
      end loop;

      if Represented /= Expected then
         Report_Problem
           ("positive corpus represented" & Natural'Image (Represented)
            & " of" & Natural'Image (Expected) & " admitted fixtures");
      end if;

      return Built;
   end Corpus_Text;

   procedure Record_Artefact (Path : String; Wrote : out Boolean) is
      package Unbounded renames Ada.Strings.Unbounded;
      Host   : Landin.Platform.Native.Native_Filesystem;
      Built  : constant Corpus_Build := Corpus_Text (Host);
      Status : Landin.Platform.Write_Status;
   begin
      --  Never replace a complete golden with a partial corpus.  The ordinary
      --  test case renders Built.Problems; record mode reports failure through
      --  its existing Wrote boundary.
      if not Built.Complete then
         Wrote := False;
         return;
      end if;

      --  Through Write_File, which is byte exact.  Ada.Text_IO.Put would
      --  append a second line feed at close, which a golden would carry
      --  for ever.
      Host.Write_File (Path, Unbounded.To_String (Built.Text), Status);
      Wrote := Status = Landin.Platform.Write_Ok;
   end Record_Artefact;

   procedure The_Recorded_Corpus_Is_Current
     (Item : in out Landin.Testing.Context);

   procedure The_Recorded_Corpus_Is_Current
     (Item : in out Landin.Testing.Context)
   is
      package Unbounded renames Ada.Strings.Unbounded;
      Host     : Landin.Platform.Native.Native_Filesystem;
      Built    : constant Corpus_Build := Corpus_Text (Host);
      Recorded : Unbounded.Unbounded_String;
      Status   : Landin.Platform.Read_Status;
      Path     : constant String := "../tests/lowering.ir";
      Alias_Marker : constant String :=
        "file positive/r440-c-aliases/main.ldn" & LF;
   begin
      if not Built.Complete then
         Landin.Testing.Fail
           (Item,
            "the positive corpus could not be lowered completely" & LF
            & Unbounded.To_String (Built.Problems));
         return;
      end if;

      Landin.Testing.Check
        (Item,
         Ada.Strings.Fixed.Index
           (Unbounded.To_String (Built.Text), Alias_Marker) > 0,
         "the rooted r440-c-aliases fixture reaches generated IR");

      Host.Read_File (Path, Recorded, Status);

      if Status /= Landin.Platform.Read_Ok then
         Landin.Testing.Fail
           (Item,
            "the recorded IR is missing; regenerate it with"
            & " ./scripts/test.sh --record");
         return;
      end if;

      Landin.Testing.Check
        (Item,
         Ada.Strings.Fixed.Index
           (Unbounded.To_String (Recorded), Alias_Marker) > 0,
         "the recorded IR contains the rooted r440-c-aliases fixture");
      Landin.Testing.Check
        (Item,
         Unbounded.To_String (Recorded) = Unbounded.To_String (Built.Text),
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

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
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
      use type IR.Storage_Kind;

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

      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
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
                     when IR.Copy_Array =>
                        Copy := Value;
                     when IR.Fill_Array =>
                        Fill := Value;
                     when IR.Clear_Array =>
                        Clear := Value;
                     when IR.Store_Field =>
                        if IR.Field_Of (Unit, Routine, Value) = 1
                          and then IR.Path_Depth_Of (Unit, Routine, Value) > 0
                        then
                           Element_Stores := Element_Stores + 1;
                           declare
                              Stored : constant IR.Value_Id :=
                                IR.Nth_Operand (Unit, Routine, Value, 1);
                           begin
                              Landin.Testing.Check
                                (Item,
                                 Element_Stores in 1 .. 2
                                   and then not IR.Reaches_A_Slot
                                     (Unit, Routine, Value)
                                   and then IR.Datum_Of
                                     (Unit, Routine, Value) = 2
                                   and then IR.Path_Of
                                     (Unit, Routine, Value)
                                       = Below (Element_Stores)
                                   and then Stored = Value - 1
                                   and then IR.Op_Of
                                     (Unit, Routine, Stored) = IR.Number
                                   and then IR.Result_Of
                                     (Unit, Routine, Stored)
                                       = Landin.Types.Usize
                                   and then Folded_Number_Of
                                     (Unit, Routine, Stored)
                                       = Landin.Types.Folded
                                           (Element_Stores + 2),
                                 "literal leaves retain root, path, type and"
                                 & " order");
                           end;
                        elsif IR.Field_Of (Unit, Routine, Value) = 3
                          and then IR.Path_Of (Unit, Routine, Value)
                                     = IR.No_Path_Steps
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
            "the literal writes two path-qualified leaves through field one");
         Landin.Testing.Check
           (Item,
            Copy /= IR.No_Value
            and then IR.Source_Of (Unit, Routine, Copy).Kind = IR.Module_Datum
            and then IR.Source_Of (Unit, Routine, Copy).Datum = 1
            and then IR.Source_Field_Of (Unit, Routine, Copy) = 0
            and then IR.Source_Path_Of (Unit, Routine, Copy)
                       = IR.No_Path_Steps
            and then IR.Destination_Of (Unit, Routine, Copy).Kind
                       = IR.Module_Datum
            and then IR.Destination_Of (Unit, Routine, Copy).Datum = 2
            and then IR.Element_Field_Of (Unit, Routine, Copy) = 2
            and then IR.Path_Of (Unit, Routine, Copy) = IR.No_Path_Steps,
            "the exact direct source copies into field two");
         Landin.Testing.Check
           (Item,
            Fill /= IR.No_Value
            and then IR.Destination_Of (Unit, Routine, Fill).Kind
                       = IR.Module_Datum
            and then IR.Destination_Of (Unit, Routine, Fill).Datum = 2
            and then IR.Element_Field_Of (Unit, Routine, Fill) = 1
            and then IR.Path_Of (Unit, Routine, Fill) = IR.No_Path_Steps
            and then IR.First_Part_Of (Unit, Routine, Fill) = 1,
            "repetition fills the exact field-one root");
         Landin.Testing.Check
           (Item,
            Clear /= IR.No_Value
            and then IR.Destination_Of (Unit, Routine, Clear).Kind
                       = IR.Module_Datum
            and then IR.Destination_Of (Unit, Routine, Clear).Datum = 2
            and then IR.Element_Field_Of (Unit, Routine, Clear) = 2
            and then IR.Path_Of (Unit, Routine, Clear) = IR.No_Path_Steps,
            "zeroed clears the exact field-two root");
         Landin.Testing.Check
           (Item, False_Store /= IR.No_Value
            and then not IR.Reaches_A_Slot (Unit, Routine, False_Store)
            and then IR.Datum_Of (Unit, Routine, False_Store) = 2
            and then IR.Field_Of (Unit, Routine, False_Store) = 3
            and then IR.Path_Of (Unit, Routine, False_Store)
                       = IR.No_Path_Steps,
            "scalar zeroed stores typed false in the exact field-three root");
         Check_Terminators (Item, Unit, "struct literal array labels");
      end;
   end Struct_Literal_Array_Labels_Use_Field_Operations;

   procedure Fixed_Conditional_Selection_Reaches_IR
     (Item : in out Landin.Testing.Context);

   procedure Fixed_Conditional_Selection_Reaches_IR
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "fixed if compiler.arch == x86_64 then" & LF
         & "public main: () -> (code: i32) =" & LF
         & "    code = 42" & LF
         & "end main" & LF
         & "else" & LF
         & "public wrong: () -> (code: i32) =" & LF
         & "    code = 1" & LF
         & "end wrong" & LF
         & "end if" & LF,
         Ran);
      Landin.Testing.Check_Equal
        (Item, Ran, 5, "the configuration pipeline reached lowering");
      Landin.Testing.Check_Equal
        (Item, IR.Item_Count (Landin.Stages.Code (Work).all), 1,
         "only the selected routine reaches target-neutral IR");
   end Fixed_Conditional_Selection_Reaches_IR;

   procedure Fixed_Conditional_Uses_The_Typed_Target_Architecture
     (Item : in out Landin.Testing.Context);

   procedure Fixed_Conditional_Uses_The_Typed_Target_Architecture
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Synthetic_32);
      Ran : Natural;
   begin
      Lower
        (Work,
         "fixed if compiler.arch == synthetic_32 then" & LF
         & "selected: i32 = 42" & LF
         & "else" & LF
         & "wrong: missing = unknown" & LF
         & "end if" & LF,
         Ran);
      Landin.Testing.Check_Equal
        (Item, Ran, 5,
         "the synthetic target's typed architecture selects its declaration");
      Landin.Testing.Check_Equal
        (Item, IR.Item_Count (Landin.Stages.Code (Work).all), 1,
         "the synthetic selection does not read a target label");
   end Fixed_Conditional_Uses_The_Typed_Target_Architecture;

   procedure Fixed_Conditional_Generic_Instance_Reaches_IR
     (Item : in out Landin.Testing.Context);

   procedure Fixed_Conditional_Generic_Instance_Reaches_IR
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "fixed if compiler.arch == x86_64 then" & LF
         & "copy: (t: type, value: t) -> (result: t) = value end copy" & LF
         & "else" & LF
         & "wrong: (t: type, value: t) -> (result: t) = value end wrong" & LF
         & "end if" & LF
         & "public main: () -> (code: i32) =" & LF
         & "    code = copy(42)" & LF
         & "end main" & LF,
         Ran);
      Landin.Testing.Check_Equal
        (Item, Ran, 5,
         "the configuration-selected generic reaches every lowering stage");
      Landin.Testing.Check_Equal
        (Item, IR.Item_Count (Landin.Stages.Code (Work).all), 2,
         "the selected template creates one instance item and no"
         & " template item");
   end Fixed_Conditional_Generic_Instance_Reaches_IR;

   procedure C_Imports_Retain_Canonical_Metadata
     (Item : in out Landin.Testing.Context);

   procedure C_Imports_Retain_Canonical_Metadata
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "box: type = layout(c) struct" & LF
         & "    value: i32" & LF
         & "end box" & LF
         & "extern(c) link(symbol: ""c_box"") imported:"
         & " (value: box) -> (result: box)" & LF
         & "absent: atom" & LF
         & "maybe: type = absent | ptr mut u8" & LF
         & "extern(c) optional: (value: maybe)"
         & " -> (result: maybe from value)" & LF,
         Ran);
      Landin.Testing.Check_Equal
        (Item, Ran, 5, "imported-only C shapes reach lowering");
      if Landin.Stages.Failed (Work) then
         return;
      end if;
      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Text : constant String := IR.Dump.Text
           (Unit, Landin.Stages.Meanings (Work).all,
            Landin.Stages.Identities (Work).all);
         Aggregates, Nullable : Natural := 0;
      begin
         for Which in 1 .. IR.Item_Count (Unit) loop
            declare
               Id : constant IR.Item_Id := IR.Item_Id (Which);
               Signature : constant IR.Signature_Id := IR.Signature_Of
                 (Unit, Id);
            begin
               Landin.Testing.Check
                 (Item, IR.Is_External (Unit, Id)
                  and then IR.Signature_Uses_C_ABI (Unit, Signature)
                  and then IR.Slot_Count (Unit, Id) = 0
                  and then IR.Result_Slot (Unit, Id) = IR.No_Slot,
                  "bodyless C imports have signatures but no frame storage");
               if IR.Result_Of (Unit, Id) = Landin.Types.Aggregate then
                  Aggregates := Aggregates + 1;
                  Landin.Testing.Check
                    (Item, IR.Has_C_Layout (Unit, IR.Nominal_Of (Unit, Id))
                     and then IR.Nominal_Field_Count
                       (Unit, IR.Nominal_Of (Unit, Id)) = 1,
                     "an imported-only result has its canonical C body");
               elsif IR.Result_Of (Unit, Id) = Landin.Types.Usize then
                  Nullable := Nullable + 1;
                  Landin.Testing.Check
                    (Item, IR.Nth_Signature_Parameter
                       (Unit, Signature, 1).Kind = Landin.Types.Usize,
                     "nullable pointer unions use scalar address carriers");
               end if;
            end;
         end loop;
         Landin.Testing.Check_Equal
           (Item, Aggregates, 1, "one imported aggregate result");
         Landin.Testing.Check_Equal
           (Item, Nullable, 1, "one imported nullable pointer result");
         Landin.Testing.Check
           (Item, Ada.Strings.Fixed.Index (Text, "layout(c)") > 0
            and then Ada.Strings.Fixed.Index (Text, "extern(c) (") > 0
            and then Ada.Strings.Fixed.Index (Text, "link c_box") > 0,
            "the canonical dump exposes layout, convention and link identity");
         Landin.Testing.Check
           (Item, IR.Verifier.Check (Unit, Landin.Targets.Linux_X86_64).Kind
              = IR.Verifier.Nothing_Wrong,
            "the target verifier accepts bodyless aggregate/nullable imports");
      end;
   end C_Imports_Retain_Canonical_Metadata;

   procedure C_Variadic_Actuals_Keep_Promoted_Types
     (Item : in out Landin.Testing.Context);

   procedure C_Variadic_Actuals_Keep_Promoted_Types
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
      Direct, Indirect : Natural := 0;
   begin
      Lower
        (Work,
         "variadic: type = extern(c) (prefix: i32, ...) -> (result: i32)" & LF
         & "extern(c) imported: (prefix: i32, ...) -> (result: i32)" & LF
         & "invoke: (callback: variadic, flag: bool) -> (result: i32) =" & LF
         & "    first: i32 = imported(1, true, i8(2), u16(3)," & LF
         & "        if flag then f32(4) else f32(5) end if)" & LF
         & "    result = callback(first, false, u8(2), i16(3), f32(4))" & LF
         & "end invoke" & LF,
         Ran);
      Landin.Testing.Check_Equal
        (Item, Ran, 5, "direct and indirect variadic calls reach lowering");
      if Landin.Stages.Failed (Work) then
         return;
      end if;
      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Text : constant String := IR.Dump.Text
           (Unit, Landin.Stages.Meanings (Work).all,
            Landin.Stages.Identities (Work).all);
      begin
         for Which in 1 .. IR.Item_Count (Unit) loop
            declare
               Id : constant IR.Item_Id := IR.Item_Id (Which);
            begin
               for Index in 1 .. IR.Value_Count (Unit, Id) loop
                  declare
                     Value : constant IR.Value_Id := IR.Value_Id (Index);
                     Op : constant IR.Opcode := IR.Op_Of (Unit, Id, Value);
                  begin
                     if Op in IR.Call | IR.Indirect_Call then
                        declare
                           Signature : constant IR.Signature_Id :=
                             IR.Call_Signature (Unit, Id, Value);
                           Offset : constant Natural :=
                             (if Op = IR.Indirect_Call then 1 else 0);
                        begin
                           if Op = IR.Call then
                              Direct := Direct + 1;
                           else
                              Indirect := Indirect + 1;
                           end if;
                           Landin.Testing.Check
                             (Item, IR.Signature_Uses_C_ABI (Unit, Signature)
                              and then IR.Signature_Is_Variadic
                                (Unit, Signature)
                              and then IR.Signature_Parameter_Count
                                (Unit, Signature) = 1,
                              "call identity retains only the fixed prefix");
                           Landin.Testing.Check_Equal
                             (Item, IR.Operand_Count (Unit, Id, Value),
                              5 + Offset, "all promoted actuals are operands");
                           for Actual in 1 .. 5 loop
                              Landin.Testing.Check
                                (Item, IR.Result_Of
                                   (Unit, Id, IR.Nth_Operand
                                      (Unit, Id, Value, Actual + Offset))
                                 = (if Actual = 5 then Landin.Types.F64
                                    else Landin.Types.I32),
                                 "promotions survive the saved-actual path");
                           end loop;
                        end;
                     end if;
                  end;
               end loop;
            end;
         end loop;
         Landin.Testing.Check_Equal (Item, Direct, 1, "one direct call");
         Landin.Testing.Check_Equal (Item, Indirect, 1, "one indirect call");
         Landin.Testing.Check
           (Item, Ada.Strings.Fixed.Index (Text, ", ...)") > 0,
            "the dump records a variadic prototype");
         Landin.Testing.Check
           (Item, IR.Verifier.Check (Unit, Landin.Targets.Linux_X86_64).Kind
              = IR.Verifier.Nothing_Wrong,
            "the target verifier accepts promoted scalar tails");
      end;
   end C_Variadic_Actuals_Keep_Promoted_Types;

   procedure Unchecked_Pointer_Conversions_Keep_Null_Checks
     (Item : in out Landin.Testing.Context);

   procedure Unchecked_Pointer_Conversions_Keep_Null_Checks
     (Item : in out Landin.Testing.Context)
   is
   begin
      for Small in Boolean loop
         declare
            Facts : constant Landin.Targets.Target_Facts :=
              (if Small then Landin.Targets.Synthetic_32
               else Landin.Targets.Linux_X86_64);
            Work : Landin.Stages.Compilation := Landin.Stages.Create (Facts);
            Ran, Checks : Natural := 0;
         begin
            Lower
              (Work,
               "convert: (address: u64) -> (result: usize) =" & LF
               & "    unchecked begin" & LF
               & "        pointer: ptr mut u8 = ptr(address)" & LF
               & "        result = usize(pointer)" & LF
               & "    end unchecked" & LF
               & "end convert" & LF,
               Ran);
            Landin.Testing.Check_Equal
              (Item, Ran, 5, "unchecked pointer conversion reaches lowering");
            if not Landin.Stages.Failed (Work) then
               declare
                  Unit : IR.Unit renames Landin.Stages.Code (Work).all;
               begin
                  for Which in 1 .. IR.Item_Count (Unit) loop
                     declare
                        Id : constant IR.Item_Id := IR.Item_Id (Which);
                     begin
                        for Index in 1 .. IR.Value_Count (Unit, Id) loop
                           declare
                              Value : constant IR.Value_Id :=
                                IR.Value_Id (Index);
                           begin
                              if IR.Op_Of (Unit, Id, Value) = IR.Range_Check
                              then
                                 Checks := Checks + 1;
                                 Landin.Testing.Check
                                   (Item, not IR.Is_Unchecked (Unit, Id, Value)
                                    and then IR.Range_Lower
                                      (Unit, Id, Value) = 1
                                    and then IR.Range_Upper
                                      (Unit, Id, Value) = Landin.Types.Folded
                                        (Landin.Targets.Maximum_Object_Size
                                           (Facts))
                                    and then IR.Result_Of
                                      (Unit, Id, IR.Nth_Operand
                                         (Unit, Id, Value, 1))
                                        = Landin.Types.Usize,
                                    "nonzero is checked after narrowing to"
                                    & " the target address carrier");
                              end if;
                           end;
                        end loop;
                     end;
                  end loop;
               end;
            end if;
            Landin.Testing.Check_Equal
              (Item, Checks, 1, "one mandatory null check per conversion");
         end;
      end loop;
   end Unchecked_Pointer_Conversions_Keep_Null_Checks;

   procedure C_Aggregate_Entries_And_Calls_Keep_Logical_Carriers
     (Item : in out Landin.Testing.Context);

   procedure C_Aggregate_Entries_And_Calls_Keep_Logical_Carriers
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran, Calls, Definitions, Saved : Natural := 0;
   begin
      Lower
        (Work,
         "box: type = layout(c) struct" & LF
         & "    value: i32" & LF
         & "end box" & LF
         & "combine: type = extern(c) (left: box, right: box)"
         & " -> (result: box)" & LF
         & "extern(c) imported: (left: box, right: box) -> (result: box)" & LF
         & "public extern(c) exported: (value: box, flag: bool)"
         & " -> (result: box) =" & LF
         & "    result = imported(value," & LF
         & "        if flag then value else value end if)" & LF
         & "end exported" & LF
         & "invoke: (callback: combine, value: box, flag: bool)"
         & " -> (result: box) =" & LF
         & "    result = callback(value," & LF
         & "        if flag then value else value end if)" & LF
         & "end invoke" & LF,
         Ran);
      Landin.Testing.Check_Equal
        (Item, Ran, 5, "aggregate C definitions and calls reach lowering");
      if Landin.Stages.Failed (Work) then
         return;
      end if;
      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
      begin
         for Which in 1 .. IR.Item_Count (Unit) loop
            declare
               Id : constant IR.Item_Id := IR.Item_Id (Which);
               Signature : constant IR.Signature_Id :=
                 IR.Signature_Of (Unit, Id);
            begin
               if IR.Signature_Uses_C_ABI (Unit, Signature)
                 and then not IR.Is_External (Unit, Id)
               then
                  Definitions := Definitions + 1;
                  Landin.Testing.Check
                    (Item, IR.Parameter_Count (Unit, Id) = 3
                     and then IR.Type_Of
                       (Unit, Id, IR.Nth_Parameter (Unit, Id, 1))
                         = Landin.Types.Usize
                     and then IR.Is_Aggregate
                       (Unit, Id, IR.Nth_Parameter (Unit, Id, 2))
                     and then IR.Result_Slot (Unit, Id) /= IR.No_Slot,
                     "the logical result address precedes source parameters");
               end if;
               for Index in 1 .. IR.Value_Count (Unit, Id) loop
                  declare
                     Value : constant IR.Value_Id := IR.Value_Id (Index);
                     Op : constant IR.Opcode := IR.Op_Of (Unit, Id, Value);
                  begin
                     if Op in IR.Call | IR.Indirect_Call then
                        declare
                           Offset : constant Natural :=
                             (if Op = IR.Indirect_Call then 1 else 0);
                        begin
                           Calls := Calls + 1;
                           Landin.Testing.Check_Equal
                             (Item, IR.Operand_Count (Unit, Id, Value),
                              3 + Offset,
                              "callee then result address then two actuals");
                           Landin.Testing.Check
                             (Item, IR.Op_Of
                                (Unit, Id, IR.Nth_Operand
                                   (Unit, Id, Value, 1 + Offset))
                                  = IR.Storage_Address,
                              "the logical result destination names storage");
                           declare
                              Actual : constant IR.Value_Id :=
                                IR.Nth_Operand (Unit, Id, Value, 2 + Offset);
                           begin
                              if IR.Op_Of (Unit, Id, Actual) = IR.Load
                                and then IR.Is_Address
                                  (Unit, Id, IR.Slot_Of (Unit, Id, Actual))
                              then
                                 Saved := Saved + 1;
                              end if;
                           end;
                        end;
                     end if;
                  end;
               end loop;
            end;
         end loop;
         Landin.Testing.Check_Equal (Item, Calls, 2, "two aggregate calls");
         Landin.Testing.Check_Equal
           (Item, Definitions, 1, "one C-convention receiving definition");
         Landin.Testing.Check_Equal
           (Item, Saved, 2, "saved aggregates retain typed address slots");
         Landin.Testing.Check
           (Item, IR.Verifier.Check (Unit, Landin.Targets.Linux_X86_64).Kind
              = IR.Verifier.Nothing_Wrong,
            "logical aggregate carriers verify before ABI classification");
      end;
   end C_Aggregate_Entries_And_Calls_Keep_Logical_Carriers;

   function Named_Item
     (Work : in out Landin.Stages.Compilation; Name : String)
      return IR.Item_Id
   is
      Unit : IR.Unit renames Landin.Stages.Code (Work).all;
   begin
      for Which in 1 .. IR.Item_Count (Unit) loop
         declare
            Id : constant IR.Item_Id := IR.Item_Id (Which);
            Declared : constant IR.Declaration_Id := IR.Declares (Unit, Id);
         begin
            if Declared /= IR.No_Declaration
              and then Landin.Source.Names.Spelling
                (Landin.Stages.Identities (Work).all,
                 Landin.Resolution.Name_Of
                   (Landin.Stages.Meanings (Work).all, Declared)) = Name
            then
               return Id;
            end if;
         end;
      end loop;
      raise Landin.Compiler_Defect with "missing lowered test item " & Name;
   end Named_Item;

   procedure Recursive_C_Fixture_Lowers
     (Item : in out Landin.Testing.Context; Callbacks : Boolean);

   procedure Recursive_C_Fixture_Lowers
     (Item : in out Landin.Testing.Context; Callbacks : Boolean)
   is
      --  Deliberate native-host exception: read the actual ABI source, not
      --  a smaller substitute.  This case never assembles, links or executes.
      Host : Landin.Platform.Native.Native_Filesystem;
      Text : Ada.Strings.Unbounded.Unbounded_String;
      Status : Landin.Platform.Read_Status;
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran, Images, Relocations, Folds, Witnesses : Natural := 0;
      Entries, Direct, Indirect : Natural := 0;
      Name : constant String :=
        (if Callbacks then "r440-native-callback-array-fields"
         else "r440-native-recursive-array-fields");
   begin
      Host.Read_File
        (Fixture_Root & "/abi/" & Name & "/program.ldn", Text, Status);
      Landin.Testing.Check
        (Item, Status = Landin.Platform.Read_Ok, "the real ABI source exists");
      if Status /= Landin.Platform.Read_Ok then
         return;
      end if;
      Lower (Work, Ada.Strings.Unbounded.To_String (Text), Ran);
      Landin.Testing.Check_Equal (Item, Ran, 5, Name & " reaches lowering");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work), Name & " is accepted");
      if Landin.Stages.Failed (Work) then
         return;
      end if;
      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
      begin
         for Which in 1 .. IR.Item_Count (Unit) loop
            declare
               Id : constant IR.Item_Id := IR.Item_Id (Which);
               Signature : constant IR.Signature_Id :=
                 IR.Signature_Of (Unit, Id);
               Local_Relocations : Natural := 0;
            begin
               if IR.Kind_Of (Unit, Id) = IR.Datum
                 and then IR.Result_Of (Unit, Id) = Landin.Types.Aggregate
               then
                  Images := Images + 1;
                  Landin.Testing.Check
                    (Item, IR.Has_Image (Unit, Id)
                     and then IR.Has_C_Layout (Unit, IR.Nominal_Of (Unit, Id)),
                     "every named image retains its canonical C body");
                  for Position in 1 .. IR.Field_Count (Unit, Id) loop
                     Landin.Testing.Check
                       (Item, IR.Nth_Field_Shape (Unit, Id, Position)
                        = IR.Nth_Nominal_Field
                          (Unit, IR.Nominal_Of (Unit, Id), Position),
                        "storage is a view of the canonical nominal shape");
                  end loop;
                  Folds := Folds + Natural (IR.Image_Length (Unit, Id))
                    - IR.Field_Count (Unit, Id);
                  for Position in 1 ..
                    Natural (IR.Image_Length (Unit, Id))
                      - IR.Field_Count (Unit, Id)
                  loop
                     Landin.Testing.Check
                       (Item, IR.Nth_Aggregate_Image_Element
                          (Unit, Id, IR.Part_Position (Position)) /= 0,
                        "each numeric fixture leaf retains its nonzero bits");
                  end loop;
                  for Position in 1 ..
                    IR.Aggregate_Field_Image_Count (Unit, Id)
                  loop
                     declare
                        Image : constant IR.Aggregate_Field_Image :=
                          IR.Nth_Image_Descriptor (Unit, Id, Position);
                     begin
                        if Image.Target /= IR.No_Item then
                           Relocations := Relocations + 1;
                           Local_Relocations := Local_Relocations + 1;
                           Landin.Testing.Check
                             (Item, Local_Relocations <= 4
                              and then Image.Target = Named_Item
                                (Work, (case Local_Relocations is
                                   when 1 => "add_ten",
                                   when 2 => "add_twenty",
                                   when 3 => "add_thirty",
                                   when others => "add_forty")),
                              "fixture callback leaves retain source order");
                           Landin.Testing.Check
                             (Item, IR.Kind_Of (Unit, Image.Target)
                              = IR.Routine
                              and then IR.Signature_Uses_C_ABI
                                (Unit, IR.Signature_Of (Unit, Image.Target)),
                              "each callback leaf names a C routine");
                        end if;
                     end;
                  end loop;
               end if;
               if IR.Kind_Of (Unit, Id) = IR.Routine
                 and then IR.Result_Of (Unit, Id) = Landin.Types.Aggregate
               then
                  Landin.Testing.Check
                    (Item, IR.Signature_Result (Unit, Signature).Nominal
                     = IR.Nominal_Of (Unit, Id)
                     and then IR.Has_C_Layout (Unit, IR.Nominal_Of (Unit, Id)),
                     "C imports and definitions share result identity");
                  if not IR.Is_External (Unit, Id) then
                     Entries := Entries + 1;
                     Landin.Testing.Check
                       (Item, IR.Parameter_Count (Unit, Id)
                        = IR.Signature_Parameter_Count (Unit, Signature) + 1
                        and then IR.Type_Of
                          (Unit, Id, IR.Nth_Parameter (Unit, Id, 1))
                            = Landin.Types.Usize
                        and then IR.Result_Slot (Unit, Id) /= IR.No_Slot,
                        "register and MEMORY results have logical storage");
                  end if;
               end if;
               for Position in 1 .. IR.Value_Count (Unit, Id) loop
                  declare
                     Value : constant IR.Value_Id := IR.Value_Id (Position);
                     Op : constant IR.Opcode := IR.Op_Of (Unit, Id, Value);
                  begin
                     if Op in IR.Load_Indirect | IR.Store_Indirect then
                        declare
                           Address : constant IR.Slot_Id :=
                             IR.Indirect_Address_Slot (Unit, Id, Value);
                        begin
                           if Address /= IR.No_Slot then
                              Witnesses := Witnesses + 1;
                              declare
                                 Source : constant IR.Value_Id :=
                                   (if Op = IR.Load_Indirect then Value
                                    else IR.Nth_Operand (Unit, Id, Value, 2));
                                 Shape : constant IR.Field_Shape :=
                                   IR.Address_Shape (Unit, Id, Address);
                              begin
                                 Landin.Testing.Check
                                   (Item, IR.Result_Of (Unit, Id, Source)
                                    = Shape.Element
                                    and then
                                      (if Shape.Signature = IR.No_Signature
                                       then IR.Signature_Of (Unit, Id, Source)
                                         = IR.No_Signature
                                       else IR.Signatures_Agree
                                         (Unit, IR.Signature_Of
                                            (Unit, Id, Source),
                                          Shape.Signature)),
                                    "indirect leaves retain typed witnesses");
                              end;
                           end if;
                        end;
                     elsif Op in IR.Call | IR.Indirect_Call then
                        declare
                           Callable : constant IR.Signature_Id :=
                             IR.Call_Signature (Unit, Id, Value);
                           Offset : constant Natural :=
                             (if Op = IR.Indirect_Call then 1 else 0);
                        begin
                           if IR.Signature_Result (Unit, Callable).Kind
                             = Landin.Types.Aggregate
                           then
                              if Op = IR.Call then
                                 Direct := Direct + 1;
                              else
                                 Indirect := Indirect + 1;
                              end if;
                              Landin.Testing.Check
                                (Item, IR.Operand_Count (Unit, Id, Value)
                                 = IR.Signature_Parameter_Count
                                   (Unit, Callable) + 1 + Offset
                                 and then IR.Op_Of
                                   (Unit, Id, IR.Nth_Operand
                                      (Unit, Id, Value, 1 + Offset))
                                        = IR.Storage_Address,
                                 "callee, logical destination, then actuals");
                           end if;
                        end;
                     end if;
                  end;
               end loop;
            end;
         end loop;
         Landin.Testing.Check_Equal (Item, Images, 3, "three static C images");
         Landin.Testing.Check_Equal
           (Item, Relocations, (if Callbacks then 9 else 0),
            "exactly one relocation for each source callback leaf");
         Landin.Testing.Check_Equal
           (Item, Folds, (if Callbacks then 0 else 10),
            "numeric leaves are folds; callbacks are never zero placeholders");
         Landin.Testing.Check
           (Item, Entries >= 3 and then Direct >= 3 and then Indirect = 3
            and then Witnesses > 0,
            "recursive entries, direct/indirect calls and typed access occur");
         Check_Terminators (Item, Unit, Name);
      end;
   end Recursive_C_Fixture_Lowers;

   procedure Recursive_Numeric_ABI_Source_Lowers
     (Item : in out Landin.Testing.Context);

   procedure Recursive_Numeric_ABI_Source_Lowers
     (Item : in out Landin.Testing.Context) is
   begin
      Recursive_C_Fixture_Lowers (Item, Callbacks => False);
   end Recursive_Numeric_ABI_Source_Lowers;

   procedure Recursive_Callback_ABI_Source_Lowers
     (Item : in out Landin.Testing.Context);

   procedure Recursive_Callback_ABI_Source_Lowers
     (Item : in out Landin.Testing.Context) is
   begin
      Recursive_C_Fixture_Lowers (Item, Callbacks => True);
   end Recursive_Callback_ABI_Source_Lowers;

   procedure Recursive_Static_Selections_Rebase_Images
     (Item : in out Landin.Testing.Context);

   procedure Recursive_Static_Selections_Rebase_Images
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "handler: type = extern(c) (value: i32) -> (result: i32)" & LF
         & "board: type = layout(c) struct values: [2][2]u16 end board" & LF
         & "codes: type = layout(c) struct" & LF
         & "    handlers: [2][2]handler" & LF & "end codes" & LF
         & "numeric_record: type = struct" & LF
         & "    first: [2]u16" & LF & "    second: [2]u16" & LF
         & "end numeric_record" & LF
         & "numeric_box: type = struct nested: numeric_record"
         & " end numeric_box" & LF
         & "callback_record: type = struct" & LF
         & "    picked: handler" & LF & "    row: [2]handler" & LF
         & "end callback_record" & LF
         & "callback_box: type = struct" & LF
         & "    nested: callback_record" & LF & "end callback_box" & LF
         & "picked: handler = c_second" & LF
         & "alias: handler = picked" & LF
         & "direct: handler = c_first" & LF
         & "row: [2]u16 = numeric_leaf.second" & LF
         & "matrix: [2][2]u16 = original.values" & LF
         & "whole: board = original" & LF
         & "rebuilt: board = board(values: [row," & LF
         & "    numeric_leaf.first])" & LF
         & "huge: [4294967296][2]u16 =" & LF
         & "    [numeric_leaf.first," & LF
         & "     of numeric_leaf.second]" & LF
         & "suffix: [2]u16 = numeric_leaf.second" & LF
         & "callback_row: [2]handler = callback_leaf.row" & LF
         & "callback_copy: [2][2]handler = callbacks.handlers" & LF
         & "chosen: [3]handler = [picked, direct, of alias]" & LF
         & "single_suffix: [2]handler = [picked, of alias]" & LF
         & "original: board = board(values: [[11, 12], [21, 22]])" & LF
         & "numeric_leaf: numeric_record = numeric_record(" & LF
         & "    first: [11, 12], second: [21, 22])" & LF
         & "numeric_choices: numeric_box = numeric_box(nested:" & LF
         & "    numeric_record(first: [11, 12], second: [21, 22]))" & LF
         & "callbacks: codes = codes(handlers:" & LF
         & "    [[c_first, c_second], [c_second, c_first]])" & LF
         & "callback_leaf: callback_record = callback_record(" & LF
         & "    picked: c_second, row: [c_second, c_first])" & LF
         & "callback_choices: callback_box = callback_box(nested:" & LF
         & "    callback_record(picked: c_second,"
         & " row: [c_second, c_first]))" & LF
         & "extern(c) c_first: (value: i32) -> (result: i32)" & LF
         & "extern(c) c_second: (value: i32) -> (result: i32)" & LF
         & "native_handler: type = () -> (result: i32)" & LF
         & "anonymous: native_handler = () -> (result: i32) = 7 end" & LF
         & "choice: type = struct" & LF
         & "    kind: variant empty | full: (value: u16) end kind" & LF
         & "end choice" & LF
         & "wrapper: type = struct" & LF
         & "    values: [2][2]u16" & LF & "    selected: choice" & LF
         & "end wrapper" & LF
         & "empty_choice: choice = choice(kind: empty)" & LF
         & "wrapped: wrapper = wrapper(" & LF
         & "    values: original.values, selected: empty_choice)" & LF
         & "read: (value: board, outer: usize, inner: usize)" & LF
         & "    -> (result: u16) =" & LF
         & "    result = value.values[outer][inner]" & LF
         & "end read" & LF,
         Ran);
      Landin.Testing.Check_Equal
        (Item, Ran, 5, "recursive forward selections reach lowering");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "direct field selections coexist with recursive static images");
      if Landin.Stages.Failed (Work) then
         return;
      end if;
      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         First : constant IR.Item_Id := Named_Item (Work, "c_first");
         Second : constant IR.Item_Id := Named_Item (Work, "c_second");
         Original : constant IR.Item_Id := Named_Item (Work, "original");
         Whole : constant IR.Item_Id := Named_Item (Work, "whole");
         Rebuilt : constant IR.Item_Id := Named_Item (Work, "rebuilt");
         Matrix : constant IR.Item_Id := Named_Item (Work, "matrix");
         Huge : constant IR.Item_Id := Named_Item (Work, "huge");
         Root : constant IR.Aggregate_Field_Image :=
           IR.Array_Image_Of (Unit, Huge);
         type Item_List is array (Positive range <>) of IR.Item_Id;
         Copies : constant Item_List :=
           [Named_Item (Work, "row"), Named_Item (Work, "suffix")];
         Aliases : constant Item_List :=
           [Named_Item (Work, "picked"), Named_Item (Work, "alias")];
         Empty_Selections : Natural := 0;
      begin
         for Id of Aliases loop
            Landin.Testing.Check
              (Item, IR.Function_Target (Unit, Id) = Second
               and then IR.Block_Count (Unit, Id) = 1
               and then IR.Op_Of (Unit, Id, 1) = IR.Function_Address
               and then IR.Callee_Of (Unit, Id, 1) = Second,
               "callback aliases resolve the later direct relocation");
         end loop;
         Landin.Testing.Check
           (Item, IR.Function_Target (Unit, Named_Item (Work, "direct"))
            = First
            and then IR.Function_Target
              (Unit, Named_Item (Work, "anonymous")) /= IR.No_Item,
            "direct names and anonymous callback data keep their targets");
         for Id of Copies loop
            Landin.Testing.Check
              (Item, IR.Has_Recursive_Array_Image (Unit, Id)
               and then IR.Image_Length (Unit, Id) = 2
               and then IR.Nth_Descriptor_Element
                 (Unit, Id, IR.Array_Image_Of (Unit, Id), 1) = 21
               and then IR.Nth_Descriptor_Element
                 (Unit, Id, IR.Array_Image_Of (Unit, Id), 2) = 22,
               "a selected numeric row rebases its finite fold prefix");
         end loop;
         Landin.Testing.Check
           (Item, IR.Nominal_Of (Unit, Original) = IR.Nominal_Of (Unit, Whole)
            and then IR.Image_Length (Unit, Original)
              = IR.Image_Length (Unit, Whole),
            "whole image cloning retains nominal identity and stored length");
         for Position in 1 ..
           IR.Aggregate_Field_Image_Count (Unit, Original)
         loop
            Landin.Testing.Check
              (Item, IR.Nth_Image_Descriptor (Unit, Original, Position)
               = IR.Nth_Image_Descriptor (Unit, Whole, Position),
               "whole copies preserve item-relative descriptor runs");
         end loop;
         for Position in 1 .. 4 loop
            Landin.Testing.Check
              (Item, IR.Nth_Aggregate_Image_Element
                 (Unit, Original, IR.Part_Position (Position))
               = IR.Nth_Aggregate_Image_Element
                   (Unit, Whole, IR.Part_Position (Position)),
               "whole copies retain each nonzero numeric leaf");
         end loop;
         declare
            Source : constant IR.Item_Id := Named_Item (Work, "callbacks");
            Copy : constant IR.Item_Id := Named_Item (Work, "callback_copy");
         begin
            Landin.Testing.Check
              (Item, IR.Aggregate_Field_Image_Count (Unit, Copy) = 7
               and then IR.Image_Length (Unit, Copy) = 0
               and then IR.Field_Count (Unit, Copy) = 0,
               "a callback matrix copy has seven descriptors and no folds");
            for Position in 1 .. 7 loop
               Landin.Testing.Check
                 (Item, IR.Nth_Image_Descriptor (Unit, Source, Position)
                  = IR.Nth_Image_Descriptor (Unit, Copy, Position),
                  "matrix extraction retains all ordered callback targets");
            end loop;
         end;
         Landin.Testing.Check
           (Item, IR.Image_Root_Count (Unit, Matrix) = 1
            and then IR.Field_Count (Unit, Matrix) = 0
            and then IR.Image_Length (Unit, Matrix) = 4
            and then IR.Nth_Aggregate_Image_Element (Unit, Matrix, 1) = 11
            and then IR.Nth_Aggregate_Image_Element (Unit, Matrix, 4) = 22,
            "extracting an array removes the aggregate numeric field prefix");
         Landin.Testing.Check
           (Item, IR.Nth_Aggregate_Image_Element (Unit, Rebuilt, 1) = 21
            and then IR.Nth_Aggregate_Image_Element (Unit, Rebuilt, 2) = 22
            and then IR.Nth_Aggregate_Image_Element (Unit, Rebuilt, 3) = 11
            and then IR.Nth_Aggregate_Image_Element (Unit, Rebuilt, 4) = 12,
            "independent selected rows append and rebase their own folds");
         Landin.Testing.Check
           (Item, Root.Form = IR.Element_Sequence and then Root.Count = 2
            and then Root.Value = 4_294_967_295
            and then IR.Aggregate_Field_Image_Count (Unit, Huge) = 3
            and then IR.Image_Length (Unit, Huge) = 4,
            "four billion rows keep two stored children and four folds");
         declare
            Row : constant IR.Item_Id := Named_Item (Work, "callback_row");
            Chosen : constant IR.Item_Id := Named_Item (Work, "chosen");
            Single : constant IR.Item_Id :=
              Named_Item (Work, "single_suffix");
         begin
            Landin.Testing.Check
              (Item, IR.Descendant_Image_Of
                 (Unit, Row, IR.Array_Image_Of (Unit, Row), 1).Target = Second
               and then IR.Descendant_Image_Of
                 (Unit, Row, IR.Array_Image_Of (Unit, Row), 2).Target = First,
               "selected callback rows keep ordered code relocations");
            Landin.Testing.Check
              (Item, IR.Descendant_Image_Of
                 (Unit, Chosen, IR.Array_Image_Of (Unit, Chosen), 3).Target
                   = Second
               and then IR.Image_Length (Unit, Chosen) = 0
               and then IR.Array_Image_Of (Unit, Single).Count = 2
               and then IR.Array_Image_Of (Unit, Single).Value = 1
               and then IR.Descendant_Image_Of
                 (Unit, Single, IR.Array_Image_Of (Unit, Single), 1).Target
                   = Second
               and then IR.Descendant_Image_Of
                 (Unit, Single, IR.Array_Image_Of (Unit, Single), 2).Target
                   = Second,
               "callback suffixes retain both evaluated descriptors");
         end;
         declare
            Wrapped : constant IR.Item_Id := Named_Item (Work, "wrapped");
         begin
            for Position in 1 ..
              IR.Aggregate_Field_Image_Count (Unit, Wrapped)
            loop
               declare
                  Image : constant IR.Aggregate_Field_Image :=
                    IR.Nth_Image_Descriptor (Unit, Wrapped, Position);
               begin
                  if Image.Form = IR.Selected and then Image.Count = 0 then
                     Empty_Selections := Empty_Selections + 1;
                  end if;
               end;
            end loop;
         end;
         Landin.Testing.Check_Equal
           (Item, Empty_Selections, 1, "a payloadless clone stays empty");
         Check_Terminators (Item, Unit, "recursive static images");
      end;
   end Recursive_Static_Selections_Rebase_Images;

   procedure Recursive_Repetition_Stays_Compact
     (Item : in out Landin.Testing.Context);

   procedure Recursive_Repetition_Stays_Compact
     (Item : in out Landin.Testing.Context)
   is
      First_Values, First_Blocks, First_Shapes : Natural := 0;
   begin
      for Large in Boolean loop
         declare
            Work : Landin.Stages.Compilation :=
              Landin.Stages.Create (Landin.Targets.Linux_X86_64);
            Size : constant String := (if Large then "1000000" else "2");
            Ran : Natural;
         begin
            Lower
              (Work,
               "handler: type = extern(c) (value: i32) -> (result: i32)" & LF
               & "extern(c) one: (value: i32) -> (result: i32)" & LF
               & "extern(c) two: (value: i32) -> (result: i32)" & LF
               & "mut count: u16" & LF
               & "make: () -> (result: [2]u16) =" & LF
               & "    count = count + 1" & LF
               & "    result = [count, count + 1]" & LF & "end make" & LF
               & "fill: () -> none =" & LF
               & "    mut numbers: [" & Size & "][2]u16 = [of make()]" & LF
               & "    numbers = [[9, 10], of make()]" & LF
               & "    codes: [" & Size & "][2]handler = [of [one, two]]" & LF
               & "end fill" & LF
               & "single_suffix: () -> none =" & LF
               & "    row: [2][2]u16 = [[1, 2], of make()]" & LF
               & "end single_suffix" & LF,
               Ran);
            Landin.Testing.Check_Equal
              (Item, Ran, 5, "compound repetition reaches lowering");
            if Landin.Stages.Failed (Work) then
               return;
            end if;
            declare
               Unit : IR.Unit renames Landin.Stages.Code (Work).all;
               Fill : constant IR.Item_Id := Named_Item (Work, "fill");
               Single : constant IR.Item_Id :=
                 Named_Item (Work, "single_suffix");
               Make : constant IR.Item_Id := Named_Item (Work, "make");
               Calls, Copies, Branches, Single_Calls, Single_Branches :
                 Natural := 0;
            begin
               for Position in 1 .. IR.Value_Count (Unit, Fill) loop
                  declare
                     Value : constant IR.Value_Id := IR.Value_Id (Position);
                     Op : constant IR.Opcode := IR.Op_Of (Unit, Fill, Value);
                  begin
                     if Op = IR.Call
                       and then IR.Callee_Of (Unit, Fill, Value) = Make
                     then
                        Calls := Calls + 1;
                     elsif Op = IR.Copy_Array then
                        Copies := Copies + 1;
                     elsif Op = IR.Branch then
                        Branches := Branches + 1;
                     end if;
                  end;
               end loop;
               for Position in 1 .. IR.Value_Count (Unit, Single) loop
                  declare
                     Value : constant IR.Value_Id := IR.Value_Id (Position);
                     Op : constant IR.Opcode := IR.Op_Of (Unit, Single, Value);
                  begin
                     if Op = IR.Call
                       and then IR.Callee_Of (Unit, Single, Value) = Make
                     then
                        Single_Calls := Single_Calls + 1;
                     elsif Op = IR.Branch then
                        Single_Branches := Single_Branches + 1;
                     end if;
                  end;
               end loop;
               Landin.Testing.Check_Equal
                 (Item, Calls, 2, "each repeated row is evaluated once");
               Landin.Testing.Check
                 (Item, Copies >= 3 and then Branches = 3,
                  "two numeric and one callback repetition use copying loops");
               Landin.Testing.Check
                 (Item, Single_Calls = 1 and then Single_Branches = 1,
                  "a one-row suffix evaluates once and uses one copying loop");
               if Large then
                  Landin.Testing.Check
                    (Item, IR.Value_Count (Unit, Fill) = First_Values
                     and then IR.Block_Count (Unit, Fill) = First_Blocks
                     and then IR.Variant_Field_Shape_Count (Unit)
                       = First_Shapes,
                     "a million rows require exactly the same bounded IR");
               else
                  First_Values := IR.Value_Count (Unit, Fill);
                  First_Blocks := IR.Block_Count (Unit, Fill);
                  First_Shapes := IR.Variant_Field_Shape_Count (Unit);
               end if;
               Check_Terminators (Item, Unit, "compound repetition");
            end;
         end;
      end loop;
   end Recursive_Repetition_Stays_Compact;

   procedure R470_Field_Ranges_Lower_Recursive_Shapes
     (Item : in out Landin.Testing.Context);

   procedure R470_Field_Ranges_Lower_Recursive_Shapes
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "node: type = struct value: i32 end node" & LF
         & "holder: type = struct" & LF
         & "    deep: [2][3][4]i32" & LF
         & "    empty: [2][0][3]i32" & LF
         & "    refs: [2][3][]mut i32" & LF
         & "    nominal: [2][3]node" & LF
         & "end holder" & LF
         & "inspect: (inout value: holder) -> none =" & LF
         & "    deep := value.deep[0..<2]" & LF
         & "    empty := value.empty[0..<2]" & LF
         & "    refs := value.refs[0..<2]" & LF
         & "    nominal := value.nominal[0..<2]" & LF
         & "    _ = lenof deep + lenof empty + lenof refs + lenof nominal" & LF
         & "end inspect" & LF,
         Ran);
      Landin.Testing.Check_Equal
        (Item, Ran, 5, "recursive field ranges reach lowering");
      if Landin.Stages.Failed (Work) then
         return;
      end if;

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Inspect : constant IR.Item_Id := Named_Item (Work, "inspect");
         Seen, Deep, Empty, References, Nominals : Natural := 0;
      begin
         for Position in 1 .. IR.Value_Count (Unit, Inspect) loop
            declare
               Value : constant IR.Value_Id := IR.Value_Id (Position);
            begin
               if IR.Op_Of (Unit, Inspect, Value) = IR.Slice_Address then
                  Seen := Seen + 1;
                  declare
                     Shape : constant IR.Field_Shape :=
                       IR.Slice_Element_Shape (Unit, Inspect, Value);
                     Child : IR.Field_Shape;
                  begin
                     Landin.Testing.Check
                       (Item, Shape.Kind = IR.Array_Field_Shape,
                        "a nested range lowers as a recursive array shape");
                     if Shape.Kind = IR.Array_Field_Shape then
                        Child := IR.Array_Element_Shape (Unit, Shape);
                        if Shape.Length = 0 then
                           Empty := Empty + 1;
                           Landin.Testing.Check
                             (Item, Child.Kind = IR.Array_Field_Shape
                              and then Child.Length = 3
                              and then IR.Array_Element_Shape
                                (Unit, Child).Kind = IR.Scalar_Field_Shape
                              and then IR.Array_Element_Shape
                                (Unit, Child).Element = Landin.Types.I32,
                              "a zero child keeps its scalar grandchild");
                        elsif Child.Kind = IR.Array_Field_Shape
                          and then Child.Length = 4
                        then
                           Deep := Deep + 1;
                           Landin.Testing.Check
                             (Item, IR.Array_Element_Shape
                                (Unit, Child).Kind = IR.Scalar_Field_Shape
                              and then IR.Array_Element_Shape
                                (Unit, Child).Element = Landin.Types.I32,
                              "deep scalar array identity remains recursive");
                        elsif Child.Kind = IR.Array_Field_Shape
                          and then Child.Length = 2
                        then
                           References := References + 1;
                           Landin.Testing.Check
                             (Item, Child.Element = Landin.Types.Usize,
                              "a slice child keeps its two-word carrier");
                        elsif Child.Kind = IR.Aggregate_Field_Shape then
                           Nominals := Nominals + 1;
                           Landin.Testing.Check
                             (Item, Child.Nominal /= IR.No_Nominal_Type,
                              "a nominal child keeps its nominal body");
                        end if;
                     end if;
                  end;
               end if;
            end;
         end loop;
         Landin.Testing.Check
           (Item, Seen = 4 and then Deep = 1 and then Empty = 1
            and then References = 1 and then Nominals = 1,
            "all four recursive slice pointees reached target-neutral IR");
         Landin.Testing.Check
           (Item, IR.Verifier.Check (Unit).Kind = IR.Verifier.Nothing_Wrong,
            "the verifier accepts every recursive range shape");
      end;
   end R470_Field_Ranges_Lower_Recursive_Shapes;

   procedure R470_Direct_Array_Inout_Uses_One_Address
     (Item : in out Landin.Testing.Context);

   procedure R470_Direct_Array_Inout_Uses_One_Address
     (Item : in out Landin.Testing.Context)
   is
      use type IR.Storage_Kind;

      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "forward: (inout values: [7]u8, index: usize) -> none =" & LF
         & "    values[index] = values[index] + 1" & LF
         & "end forward" & LF
         & "operate: (inout values: [7]u8, left: usize, right: usize)"
         & " -> none =" & LF
         & "    saved: u8 = values[left]" & LF
         & "    values[left] = values[right]" & LF
         & "    values[right] = saved" & LF
         & "    mut shadow: [7]u8 = values" & LF
         & "    values = shadow" & LF
         & "    forward(values, left)" & LF
         & "end operate" & LF
         & "exercise: () -> none =" & LF
         & "    mut values: [7]u8 = [0, 1, 2, 3, 4, 5, 6]" & LF
         & "    operate(values, 1, 5)" & LF
         & "end exercise" & LF,
         Ran);
      Landin.Testing.Check_Equal
        (Item, Ran, 5, "direct fixed-array inout reaches lowering");
      if Landin.Stages.Failed (Work) then
         return;
      end if;

      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Operate : constant IR.Item_Id := Named_Item (Work, "operate");
         Forward : constant IR.Item_Id := Named_Item (Work, "forward");
         Parameter : constant IR.Slot_Id :=
           IR.Nth_Parameter (Unit, Operate, 1);
         Forward_Parameter : constant IR.Slot_Id :=
           IR.Nth_Parameter (Unit, Forward, 1);
         Shape : constant IR.Field_Shape :=
           IR.Address_Shape (Unit, Operate, Parameter);
         Child : IR.Field_Shape;
         Runtime_Indexes, Copies, Forwarded, Place_Addresses : Natural := 0;
      begin
         Landin.Testing.Check
           (Item, IR.Is_Address (Unit, Operate, Parameter)
            and then IR.Is_Address (Unit, Forward, Forward_Parameter)
            and then Shape.Kind = IR.Array_Field_Shape
            and then Shape.Length = 7,
            "each direct array parameter is one whole-array address slot");
         Child := IR.Array_Element_Shape (Unit, Shape);
         Landin.Testing.Check
           (Item, Child.Kind = IR.Scalar_Field_Shape
            and then Child.Element = Landin.Types.U8,
            "the address slot points at seven u8 elements");

         for Position in 1 .. IR.Value_Count (Unit, Operate) loop
            declare
               Value : constant IR.Value_Id := IR.Value_Id (Position);
               Op : constant IR.Opcode := IR.Op_Of (Unit, Operate, Value);
            begin
               if Op = IR.Place_Address then
                  Place_Addresses := Place_Addresses + 1;
               elsif Op = IR.Storage_Address
                 and then IR.Destination_Of
                   (Unit, Operate, Value).Kind = IR.Runtime_Address
               then
                  Runtime_Indexes := Runtime_Indexes + 1;
                  Landin.Testing.Check
                    (Item, IR.Destination_Of
                       (Unit, Operate, Value).Address = Parameter
                     and then IR.Storage_Address_Has_Index
                       (Unit, Operate, Value),
                     "computed access starts at the incoming array address");
               elsif Op = IR.Copy_Array then
                  Copies := Copies + 1;
                  Landin.Testing.Check
                    (Item,
                     (IR.Source_Of (Unit, Operate, Value).Kind
                        = IR.Runtime_Address
                      and then IR.Source_Of
                        (Unit, Operate, Value).Address = Parameter)
                     or else
                       (IR.Destination_Of (Unit, Operate, Value).Kind
                          = IR.Runtime_Address
                        and then IR.Destination_Of
                          (Unit, Operate, Value).Address = Parameter),
                     "each whole copy has the direct parameter as one"
                     & " endpoint");
               elsif Op = IR.Call
                 and then IR.Callee_Of (Unit, Operate, Value) = Forward
               then
                  Forwarded := Forwarded + 1;
                  declare
                     Actual : constant IR.Value_Id :=
                       IR.Nth_Operand (Unit, Operate, Value, 1);
                     Saved : IR.Value_Id := IR.No_Value;
                     Source : IR.Value_Id := IR.No_Value;
                  begin
                     if IR.Op_Of (Unit, Operate, Actual) = IR.Load then
                        for Prior in 1 .. Natural (Actual) - 1 loop
                           declare
                              Candidate : constant IR.Value_Id :=
                                IR.Value_Id (Prior);
                           begin
                              if IR.Op_Of
                                   (Unit, Operate, Candidate) = IR.Store
                                and then IR.Slot_Of
                                  (Unit, Operate, Candidate) = IR.Slot_Of
                                    (Unit, Operate, Actual)
                              then
                                 Saved := Candidate;
                                 Source := IR.Nth_Operand
                                   (Unit, Operate, Candidate, 1);
                              end if;
                           end;
                        end loop;
                     end if;
                     Landin.Testing.Check
                       (Item, Saved /= IR.No_Value
                        and then Source /= IR.No_Value
                        and then IR.Op_Of
                          (Unit, Operate, Source) = IR.Load
                        and then IR.Slot_Of
                          (Unit, Operate, Source) = Parameter,
                        "forwarding spills the incoming address itself");
                  end;
               end if;
            end;
         end loop;
         Landin.Testing.Check
           (Item, Runtime_Indexes = 4 and then Copies = 2
            and then Forwarded = 1 and then Place_Addresses = 0,
            "reads, writes, swaps, copies and forwarding add no indirection");
         Landin.Testing.Check
           (Item, IR.Verifier.Check (Unit).Kind = IR.Verifier.Nothing_Wrong,
            "the verifier accepts the direct array address operations");
      end;
   end R470_Direct_Array_Inout_Uses_One_Address;

   procedure Callback_Slices_And_Inout_Keep_Metadata
     (Item : in out Landin.Testing.Context);

   procedure Callback_Slices_And_Inout_Keep_Metadata
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran, Loads, Stores, Slices : Natural := 0;
   begin
      Lower
        (Work,
         "handler: type = extern(c) (value: i32) -> (result: i32)" & LF
         & "extern(c) one: (value: i32) -> (result: i32)" & LF
         & "extern(c) two: (value: i32) -> (result: i32)" & LF
         & "replace: (inout current: handler, next: handler)" & LF
         & "    -> (result: i32) =" & LF
         & "    result = current(5)" & LF
         & "    current = next" & LF & "end replace" & LF
         & "visit: (items: []mut handler, index: usize, next: handler)" & LF
         & "    -> (result: i32) =" & LF
         & "    result = replace(items[index], next)" & LF
         & "    result = result + items[index](6)" & LF
         & "    items[index] = next" & LF & "end visit" & LF
         & "exercise: () -> (result: i32) =" & LF
         & "    mut values: [2]handler = [one, two]" & LF
         & "    view: []mut handler = values[0..<2]" & LF
         & "    result = visit(view, 1, one)" & LF & "end exercise" & LF,
         Ran);
      Landin.Testing.Check_Equal
        (Item, Ran, 5, "callable slices and inout reach lowering");
      if Landin.Stages.Failed (Work) then
         return;
      end if;
      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Expected : constant IR.Signature_Id :=
           IR.Signature_Of (Unit, Named_Item (Work, "one"));
         Replace : constant IR.Item_Id := Named_Item (Work, "replace");
         Parameter : constant IR.Slot_Id :=
           IR.Nth_Parameter (Unit, Replace, 1);
      begin
         Landin.Testing.Check
           (Item, IR.Is_Address (Unit, Replace, Parameter)
            and then IR.Signatures_Agree
              (Unit, IR.Address_Shape (Unit, Replace, Parameter).Signature,
               Expected),
            "an inout callback parameter is a complete typed address");
         for Which in 1 .. IR.Item_Count (Unit) loop
            declare
               Id : constant IR.Item_Id := IR.Item_Id (Which);
            begin
               for Position in 1 .. IR.Value_Count (Unit, Id) loop
                  declare
                     Value : constant IR.Value_Id := IR.Value_Id (Position);
                     Op : constant IR.Opcode := IR.Op_Of (Unit, Id, Value);
                  begin
                     if Op in IR.Load_Indirect | IR.Store_Indirect then
                        declare
                           Address : constant IR.Slot_Id :=
                             IR.Indirect_Address_Slot (Unit, Id, Value);
                           Source : constant IR.Value_Id :=
                             (if Op = IR.Load_Indirect then Value
                              else IR.Nth_Operand (Unit, Id, Value, 2));
                        begin
                           if Op = IR.Load_Indirect then
                              Loads := Loads + 1;
                           else
                              Stores := Stores + 1;
                           end if;
                           Landin.Testing.Check
                             (Item, Address /= IR.No_Slot
                              and then IR.Signatures_Agree
                                (Unit, IR.Address_Shape
                                   (Unit, Id, Address).Signature, Expected)
                              and then IR.Signatures_Agree
                                (Unit, IR.Signature_Of (Unit, Id, Source),
                                 Expected),
                              "slice and inout accesses keep callable type");
                        end;
                     elsif Op = IR.Slice_Address then
                        Slices := Slices + 1;
                        Landin.Testing.Check
                          (Item, IR.Signatures_Agree
                             (Unit, IR.Slice_Element_Shape
                                (Unit, Id, Value).Signature, Expected),
                           "slice construction retains the callback child");
                     end if;
                  end;
               end loop;
            end;
         end loop;
         Landin.Testing.Check
           (Item, Loads >= 2 and then Stores >= 2 and then Slices >= 1,
            "typed indirect loads/stores and slice construction occurred");
         Check_Terminators (Item, Unit, "callback slices and inout");
      end;
   end Callback_Slices_And_Inout_Keep_Metadata;

   procedure Recursive_Constructors_Commit_Before_Filling
     (Item : in out Landin.Testing.Context);

   procedure Recursive_Constructors_Commit_Before_Filling
     (Item : in out Landin.Testing.Context)
   is
      use type IR.Storage_Kind;

      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "part: type = struct" & LF
         & "    first: i32" & LF & "    rows: [2][2]u16" & LF
         & "    second: i32" & LF & "    ready: bool" & LF & "end part" & LF
         & "mut state: [1]part" & LF
         & "fill: () -> none =" & LF
         & "    state = [part(second: state[0].first + 1," & LF
         & "        first: 10, of zeroed)]" & LF & "end fill" & LF,
         Ran);
      Landin.Testing.Check_Equal
        (Item, Ran, 5, "nested contextual constructor reaches lowering");
      if Landin.Stages.Failed (Work) then
         return;
      end if;
      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Fill : constant IR.Item_Id := Named_Item (Work, "fill");
         State : constant IR.Item_Id := Named_Item (Work, "state");
         Writes : Natural := 0;
         Read_Old : Boolean := False;
      begin
         for Position in 1 .. IR.Value_Count (Unit, Fill) loop
            declare
               Value : constant IR.Value_Id := IR.Value_Id (Position);
               Op : constant IR.Opcode := IR.Op_Of (Unit, Fill, Value);
            begin
               if Op in IR.Store_Field | IR.Clear_Array then
                  Writes := Writes + 1;
                  Landin.Testing.Check
                    (Item, Writes <= 4,
                     "the constructor emits exactly its four ordered writes");
                  if Writes <= 4 then
                     case Writes is
                        when 1 =>
                           declare
                              Stored : constant IR.Value_Id :=
                                IR.Nth_Operand (Unit, Fill, Value, 1);
                              Old : constant IR.Value_Id :=
                                IR.Nth_Operand (Unit, Fill, Stored, 1);
                              One : constant IR.Value_Id :=
                                IR.Nth_Operand (Unit, Fill, Stored, 2);
                              Saved : IR.Value_Id := IR.No_Value;
                              Original : IR.Value_Id := IR.No_Value;
                           begin
                              --  Binary evaluation saves the left operand
                              --  before lowering the right.  Follow that
                              --  slot's last write, not an obsolete direct
                              --  edge from the add to the field load.
                              if IR.Op_Of (Unit, Fill, Old) = IR.Load then
                                 for Prior in 1 .. Natural (Old) - 1 loop
                                    declare
                                       Id : constant IR.Value_Id :=
                                         IR.Value_Id (Prior);
                                    begin
                                       if IR.Op_Of (Unit, Fill, Id) = IR.Store
                                         and then IR.Slot_Of (Unit, Fill, Id)
                                           = IR.Slot_Of (Unit, Fill, Old)
                                       then
                                          Saved := Id;
                                          Original := IR.Nth_Operand
                                            (Unit, Fill, Id, 1);
                                       end if;
                                    end;
                                 end loop;
                              end if;
                              Read_Old :=
                                Op = IR.Store_Field
                                and then
                                  not IR.Reaches_A_Slot (Unit, Fill, Value)
                                and then
                                  IR.Datum_Of (Unit, Fill, Value) = State
                                and then
                                  IR.Field_Of (Unit, Fill, Value) = 1
                                and then IR.Path_Of (Unit, Fill, Value)
                                  = Below (3)
                                and then IR.Op_Of (Unit, Fill, Stored) = IR.Add
                                and then IR.Result_Of (Unit, Fill, Stored)
                                  = Landin.Types.I32
                                and then Saved /= IR.No_Value
                                and then IR.Op_Of (Unit, Fill, Original)
                                  = IR.Load_Field
                                and then not IR.Reaches_A_Slot
                                  (Unit, Fill, Original)
                                and then IR.Datum_Of (Unit, Fill, Original)
                                  = State
                                and then IR.Field_Of (Unit, Fill, Original) = 1
                                and then IR.Path_Of (Unit, Fill, Original)
                                  = Below (1)
                                and then IR.Result_Of (Unit, Fill, Original)
                                  = Landin.Types.I32
                                and then IR.Result_Of (Unit, Fill, Old)
                                  = Landin.Types.I32
                                and then IR.Op_Of (Unit, Fill, One) = IR.Number
                                and then IR.Result_Of (Unit, Fill, One)
                                  = Landin.Types.I32
                                and then Folded_Number_Of (Unit, Fill, One) = 1
                                and then Original < Saved and then Saved < One
                                and then One < Old and then Old < Stored
                                and then Stored < Value;
                              Landin.Testing.Check
                                (Item, Read_Old,
                                 "second reads old first, adds one, then"
                                 & " writes");
                           end;
                        when 2 =>
                           declare
                              Stored : constant IR.Value_Id :=
                                IR.Nth_Operand (Unit, Fill, Value, 1);
                           begin
                              Landin.Testing.Check
                                (Item,
                                 Op = IR.Store_Field
                                   and then not IR.Reaches_A_Slot
                                     (Unit, Fill, Value)
                                   and then IR.Datum_Of
                                     (Unit, Fill, Value) = State
                                   and then IR.Field_Of
                                     (Unit, Fill, Value) = 1
                                   and then IR.Path_Of (Unit, Fill, Value)
                                     = Below (1)
                                   and then IR.Op_Of
                                     (Unit, Fill, Stored) = IR.Number
                                   and then IR.Result_Of
                                     (Unit, Fill, Stored) = Landin.Types.I32
                                   and then Folded_Number_Of
                                     (Unit, Fill, Stored) = 10,
                                 "first keeps its exact labelled value and"
                                 & " path");
                           end;
                        when 3 =>
                           declare
                              Destination : constant IR.Storage :=
                                IR.Destination_Of (Unit, Fill, Value);
                           begin
                              Landin.Testing.Check
                                (Item,
                                 Op = IR.Clear_Array
                                   and then Destination.Kind = IR.Module_Datum
                                   and then Destination.Datum = State
                                   and then IR.Element_Field_Of
                                     (Unit, Fill, Value) = 0
                                   and then IR.Path_Of (Unit, Fill, Value)
                                     = Below (1, 2),
                                 "rows clear keeps array and child"
                                 & " identities");
                           end;
                        when 4 =>
                           declare
                              Stored : constant IR.Value_Id :=
                                IR.Nth_Operand (Unit, Fill, Value, 1);
                           begin
                              Landin.Testing.Check
                                (Item,
                                 Op = IR.Store_Field
                                   and then not IR.Reaches_A_Slot
                                     (Unit, Fill, Value)
                                   and then IR.Datum_Of
                                     (Unit, Fill, Value) = State
                                   and then IR.Field_Of
                                     (Unit, Fill, Value) = 1
                                   and then IR.Path_Of (Unit, Fill, Value)
                                     = Below (4)
                                   and then IR.Op_Of
                                     (Unit, Fill, Stored) = IR.Truth
                                   and then IR.Result_Of
                                     (Unit, Fill, Stored) = Landin.Types.Bool
                                   and then not IR.Truth_Of
                                     (Unit, Fill, Stored),
                                 "ready fill is false at its exact child"
                                 & " path");
                           end;
                        when others =>
                           null;
                     end case;
                  end if;
               end if;
            end;
         end loop;
         Landin.Testing.Check
           (Item, Read_Old and then Writes = 4,
            "labels precede row and ready fills in source order");
         Check_Terminators (Item, Unit, "recursive constructor ordering");
      end;
   end Recursive_Constructors_Commit_Before_Filling;

   procedure Utf8_Indexes_Stay_Expressions_In_Recursive_Storage
     (Item : in out Landin.Testing.Context);

   procedure Utf8_Indexes_Stay_Expressions_In_Recursive_Storage
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "part: type = struct" & LF & "    bytes: []u8" & LF
         & "    rows: [2][2]u16" & LF & "end part" & LF
         & "index: (text: utf8, position: u32) -> (result: usize) =" & LF
         & "    values: [1]part = [part(bytes: text[position]," & LF
         & "        rows: [[1, 2], [3, 4]])]" & LF
         & "    slices: [1][]u8 = [text[position]]" & LF
         & "    first_view: []u8 = values[0].bytes" & LF
         & "    second_view: []u8 = slices[0]" & LF
         & "    first: usize = lenof first_view" & LF
         & "    second: usize = lenof second_view" & LF
         & "    result = first + second" & LF
         & "end index" & LF,
         Ran);
      Landin.Testing.Check_Equal
        (Item, Ran, 5, "UTF8 indexes in recursive storage reach lowering");
      if Landin.Stages.Failed (Work) then
         return;
      end if;
      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Index : constant IR.Item_Id := Named_Item (Work, "index");
         Loads, Copies : Natural := 0;
      begin
         for Position in 1 .. IR.Value_Count (Unit, Index) loop
            case IR.Op_Of (Unit, Index, IR.Value_Id (Position)) is
               when IR.Load_Indirect =>
                  Loads := Loads + 1;
               when IR.Copy_Array =>
                  Copies := Copies + 1;
               when others =>
                  null;
            end case;
         end loop;
         Landin.Testing.Check
           (Item, Loads >= 2 and then Copies >= 2
            and then IR.Value_Count (Unit, Index) < 2_000,
            "UTF8 decoding yields slice values, not recursive stored indexes");
         Check_Terminators (Item, Unit, "UTF8 contextual indexes");
      end;
   end Utf8_Indexes_Stay_Expressions_In_Recursive_Storage;

   procedure Erased_Shaped_Arguments_Keep_Spill_Types
     (Item : in out Landin.Testing.Context);

   procedure Erased_Shaped_Arguments_Keep_Spill_Types
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "reader: type = concept (t: type)" & LF
         & "    read: (self: ptr t) -> (value: i32)" & LF
         & "end reader" & LF
         & "payload: type = struct value: i32 end payload" & LF
         & "collector: type = concept (t: type)" & LF
         & "    collect: (self: ptr t, packet: payload, numbers: [2]i32," & LF
         & "              view: []i32, source: any reader, later: i32)" & LF
         & "             -> (value: i32)" & LF
         & "end collector" & LF
         & "state: type = struct value: i32 end state" & LF
         & "read_state: (self: ptr state) -> (value: i32) =" & LF
         & "    value = self.val.value" & LF
         & "end read_state" & LF
         & "collect_state: (self: ptr state, packet: payload," & LF
         & "                numbers: [2]i32, view: []i32," & LF
         & "                source: any reader, later: i32)" & LF
         & "               -> (value: i32) =" & LF
         & "    value = self.val.value + packet.value + numbers[0]" & LF
         & "        + view[0] + source.read() + later" & LF
         & "end collect_state" & LF
         & "state is reader (read: read_state)" & LF
         & "state is collector (collect: collect_state)" & LF
         & "run: (flag: bool) -> (value: i32) =" & LF
         & "    concrete: state = (value: 1)" & LF
         & "    target: any collector = any(addr concrete)" & LF
         & "    source: any reader = any(addr concrete)" & LF
         & "    packet: payload = (value: 2)" & LF
         & "    numbers: [2]i32 = [3, 4]" & LF
         & "    view: []i32 = numbers[0..<2]" & LF
         & "    value = target.collect(packet, numbers, view, source," & LF
         & "        if flag then 5 else 6 end if)" & LF
         & "end run" & LF,
         Ran);
      Landin.Testing.Check_Equal
        (Item, Ran, 5, "erased shaped arguments cross later control flow");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "erased shaped argument spills are accepted");
      if Landin.Stages.Failed (Work) then
         return;
      end if;
      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Routine : constant IR.Item_Id := Named_Item (Work, "run");
         Calls, Typed : Natural := 0;
      begin
         for Position in 1 .. IR.Value_Count (Unit, Routine) loop
            declare
               Value : constant IR.Value_Id := IR.Value_Id (Position);
            begin
               if IR.Op_Of (Unit, Routine, Value) = IR.Indirect_Call
                 and then IR.Signature_Has_Erased_Self
                   (Unit, IR.Call_Signature (Unit, Routine, Value))
               then
                  Calls := Calls + 1;
                  --  Code and self precede these four by-value carriers.
                  for Index in 3 .. 6 loop
                     declare
                        Argument : constant IR.Value_Id :=
                          IR.Nth_Operand (Unit, Routine, Value, Index);
                     begin
                        if IR.Op_Of (Unit, Routine, Argument) = IR.Load
                          and then IR.Is_Address
                            (Unit, Routine,
                             IR.Slot_Of (Unit, Routine, Argument))
                        then
                           declare
                              Shape : constant IR.Field_Shape :=
                                IR.Address_Shape
                                  (Unit, Routine,
                                   IR.Slot_Of (Unit, Routine, Argument));
                           begin
                              if (if Index = 3
                                  then Shape.Kind = IR.Aggregate_Field_Shape
                                  else Shape.Kind = IR.Array_Field_Shape
                                    and then Shape.Length = 2
                                    and then Shape.Element =
                                      (if Index = 4 then Landin.Types.I32
                                       else Landin.Types.Usize))
                              then
                                 Typed := Typed + 1;
                              end if;
                           end;
                        end if;
                     end;
                  end loop;
               end if;
            end;
         end loop;
         Landin.Testing.Check
           (Item, Calls = 1 and then Typed = 4,
            "aggregate, array, slice and any reload checked address slots");
         Landin.Testing.Check
           (Item, IR.Verifier.Check (Unit).Kind = IR.Verifier.Nothing_Wrong,
            "the lowered spills satisfy the strict erased carrier verifier");
         Check_Terminators (Item, Unit, "erased shaped argument spills");
      end;
   end Erased_Shaped_Arguments_Keep_Spill_Types;

   procedure Construction_Storage_Stays_Addressable
     (Item : in out Landin.Testing.Context);

   procedure Construction_Storage_Stays_Addressable
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran : Natural;
   begin
      Lower
        (Work,
         "choice: type = struct kind: variant"
         & " pair: (first: i32, second: i32) | empty end kind"
         & " end choice" & LF
         & "f: () -> none =" & LF
         & " mut values: [2]choice ="
         & " [(kind: pair(first: 40, second: 2)), (kind: empty)]" & LF
         & " mut nested: [1][2]choice ="
         & " [[(kind: empty), (kind: pair(first: 1, second: 2))]]" & LF
         & "end f" & LF, Ran);
      Landin.Testing.Check_Equal (Item, Ran, 5, "construction reaches IR");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "root and nested arrays retain valid variant initialization");
      declare
         Unit : IR.Unit renames Landin.Stages.Code (Work).all;
         Routine : constant IR.Item_Id := Named_Item (Work, "f");
         Selects : Natural := 0;
      begin
         for Position in 1 .. IR.Value_Count (Unit, Routine) loop
            declare
               Value : constant IR.Value_Id := IR.Value_Id (Position);
            begin
               if IR.Op_Of (Unit, Routine, Value) = IR.Select_Variant then
                  Selects := Selects + 1;
                  Landin.Testing.Check_Equal
                    (Item, IR.Element_Field_Of (Unit, Routine, Value), 1,
                     "selection names the field of a reached aggregate");
               end if;
            end;
         end loop;
         Landin.Testing.Check_Equal
           (Item, Selects, 4, "every initializer selects exactly one case");
         Landin.Testing.Check
           (Item, IR.Verifier.Check (Unit).Kind = IR.Verifier.Nothing_Wrong,
            "the verifier accepts each aggregate address and payload path");
      end;
   end Construction_Storage_Stays_Addressable;

   procedure Static_Slice_Fields_Keep_Descriptors
     (Item : in out Landin.Testing.Context);

   procedure Static_Slice_Fields_Keep_Descriptors
     (Item : in out Landin.Testing.Context)
   is
      Source : constant String :=
        "holder: type = struct value: utf8 end holder" & LF
        & "row_holder: type = struct value: []u8 end row_holder" & LF
        & "choice: type = struct kind: variant empty | text: "
        & "(value: utf8) end kind end choice" & LF
        & "outer: type = struct child: holder end outer" & LF
        & "backing: [4]u8 = [65, 66, 67, 68]" & LF
        & "source_text: utf8 = ""ABCD""" & LF
        & "view: []u8 = backing[1 ..< 3]" & LF
        & "direct: holder = (value: ""ABCD"")" & LF
        & "from_name: holder = (value: source_text)" & LF
        & "from_member: holder = (value: direct.value)" & LF
        & "choice_image: choice = (kind: text(value: ""ABCD""))" & LF
        & "choice_copy: choice = (kind: text(value: direct.value))" & LF
        & "nested: outer = (child: (value: source_text))" & LF
        & "blank: holder = (value: [])" & LF
        & "sub: row_holder = (value: view)" & LF
        & "sub_copy: row_holder = (value: sub.value)" & LF;

      procedure Check_Target (Facts : Landin.Targets.Target_Facts);

      procedure Check_Target (Facts : Landin.Targets.Target_Facts) is
         Work : Landin.Stages.Compilation := Landin.Stages.Create (Facts);
         Ran : Natural;
      begin
         Lower (Work, Source, Ran);
         Landin.Testing.Check_Equal
           (Item, Ran, 5, "the slice image source reaches lowering");
         Landin.Testing.Check
           (Item, not Landin.Stages.Failed (Work),
            "literal, copied and variant slice images lower");
         if Landin.Stages.Failed (Work) then
            return;
         end if;
         declare
            Unit : IR.Unit renames Landin.Stages.Code (Work).all;
            Direct : constant IR.Item_Id := Named_Item (Work, "direct");
            Choice : constant IR.Item_Id := Named_Item (Work, "choice_image");
            Copy : constant IR.Item_Id := Named_Item (Work, "choice_copy");
            Nested : constant IR.Item_Id := Named_Item (Work, "nested");
            Text : constant IR.Aggregate_Field_Image :=
              IR.Field_Image_Of (Unit, Direct, 1);
            Blank : constant IR.Aggregate_Field_Image :=
              IR.Field_Image_Of (Unit, Named_Item (Work, "blank"), 1);
            Sub : constant IR.Aggregate_Field_Image :=
              IR.Field_Image_Of (Unit, Named_Item (Work, "sub"), 1);

            procedure Check_Text (Image : IR.Aggregate_Field_Image);

            procedure Check_Text (Image : IR.Aggregate_Field_Image) is
            begin
               Landin.Testing.Check
                 (Item, Image.Slice and then Image.Value = 4
                    and then Image.Slice_First = 0
                    and then Image.Slice_Element.Kind = IR.Scalar_Field_Shape
                    and then Image.Slice_Element.Element = Landin.Types.U8
                    and then Image.Target /= IR.No_Item
                    and then IR.Array_Length (Unit, Image.Target) = 5
                    and then IR.Nth_Image (Unit, Image.Target, 1) = 65
                    and then IR.Nth_Image (Unit, Image.Target, 4) = 68
                    and then IR.Nth_Image (Unit, Image.Target, 5) = 0,
                  "a text descriptor retains its backing bytes and shape");
            end Check_Text;
         begin
            Check_Text (Text);
            Check_Text
              (IR.Field_Image_Of (Unit, Named_Item (Work, "from_name"), 1));
            Check_Text
              (IR.Field_Image_Of (Unit, Named_Item (Work, "from_member"), 1));
            Check_Text (IR.Variant_Payload_Image_Of (Unit, Choice, 1, 1));
            Check_Text (IR.Variant_Payload_Image_Of (Unit, Copy, 1, 1));
            Check_Text
              (IR.Descendant_Image_Of
                 (Unit, Nested, IR.Field_Image_Of (Unit, Nested, 1), 1));
            Landin.Testing.Check
              (Item, IR.Field_Image_Of (Unit, Choice, 1).Value = 2
                 and then IR.Field_Image_Of (Unit, Copy, 1).Value = 2,
               "slice payloads retain their selected variant tag");
            Landin.Testing.Check
              (Item, Blank.Slice and then Blank.Value = 0
                 and then Blank.Target = IR.No_Item
                 and then Blank.Slice_Element.Element = Landin.Types.U8,
               "the empty slice keeps a typed empty descriptor");
            Landin.Testing.Check
              (Item, Sub.Slice and then Sub.Value = 2
                 and then Sub.Slice_First = 1
                 and then Sub.Target = Named_Item (Work, "backing")
                 and then Sub.Slice_Element.Element = Landin.Types.U8
                 and then IR.Field_Image_Of
                   (Unit, Named_Item (Work, "sub_copy"), 1) = Sub,
               "slice copies retain their exact backing range");
            Landin.Testing.Check
              (Item, IR.Verifier.Check (Unit).Kind = IR.Verifier.Nothing_Wrong,
               "all slice field descriptors satisfy the verifier");
         end;
      end Check_Target;
   begin
      Check_Target (Landin.Targets.Linux_X86_64);
      Check_Target (Landin.Targets.Synthetic_32);
   end Static_Slice_Fields_Keep_Descriptors;

   procedure Calls_Respect_Resolved_Declarations
     (Item : in out Landin.Testing.Context);

   procedure Calls_Respect_Resolved_Declarations
     (Item : in out Landin.Testing.Context)
   is
      procedure Check_Source
        (Label, Text, Target : String;
         Calls, Indirect, Conversions : Natural;
         Converted : Landin.Types.Type_Kind);

      procedure Check_Source
        (Label, Text, Target : String;
         Calls, Indirect, Conversions : Natural;
         Converted : Landin.Types.Type_Kind)
      is
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Ran : Natural;
         Direct_Count, Indirect_Count, Conversion_Count : Natural := 0;
         Targets_Agree, Conversions_Agree : Boolean := True;
      begin
         Lower (Work, Text, Ran);
         Landin.Testing.Check
           (Item, Ran = 5 and then not Landin.Stages.Failed (Work),
            Label & " reaches accepted IR");
         if Landin.Stages.Failed (Work) then
            return;
         end if;
         declare
            Unit : IR.Unit renames Landin.Stages.Code (Work).all;
            Routine : constant IR.Item_Id := Named_Item (Work, "f");
            Expected : constant IR.Item_Id :=
              (if Target = "" then IR.No_Item else Named_Item (Work, Target));
         begin
            for Position in 1 .. IR.Value_Count (Unit, Routine) loop
               declare
                  Value : constant IR.Value_Id := IR.Value_Id (Position);
               begin
                  case IR.Op_Of (Unit, Routine, Value) is
                     when IR.Call =>
                        Direct_Count := Direct_Count + 1;
                        Targets_Agree := Targets_Agree and then
                          (Expected = IR.No_Item or else
                           IR.Callee_Of (Unit, Routine, Value) = Expected);
                     when IR.Indirect_Call =>
                        Indirect_Count := Indirect_Count + 1;
                     when IR.Conversion =>
                        Conversion_Count := Conversion_Count + 1;
                        Conversions_Agree := Conversions_Agree and then
                          IR.Result_Of (Unit, Routine, Value) = Converted;
                     when others => null;
                  end case;
               end;
            end loop;
            Landin.Testing.Check
              (Item, Direct_Count = Calls and then Indirect_Count = Indirect
                 and then Targets_Agree,
               Label & " retains the resolved call target and call kind");
            Landin.Testing.Check
              (Item, Conversion_Count = Conversions
                 and then Conversions_Agree,
               Label & " retains only the intended scalar conversions");
            Landin.Testing.Check
              (Item, IR.Verifier.Check (Unit).Kind = IR.Verifier.Nothing_Wrong,
               Label & " satisfies the verifier");
         end;
      end Check_Source;
   begin
      Check_Source
        ("u8 function",
         "u8: (v: i32) -> (r: i32) = r = v + 1 end u8" & LF
         & "f: (v: i32) -> (r: i32) = r = u8(v) end f" & LF,
         "u8", 1, 0, 0, Landin.Types.I32);
      Check_Source
        ("i32 function",
         "i32: (v: i32) -> (r: i32) = r = v + 1 end i32" & LF
         & "f: (v: i32) -> (r: i32) = r = i32(v) end f" & LF,
         "i32", 1, 0, 0, Landin.Types.I32);
      Check_Source
        ("bool function",
         "bool: (v: i32) -> (r: i32) = r = v + 1 end bool" & LF
         & "f: (v: i32) -> (r: i32) = r = bool(v) end f" & LF,
         "bool", 1, 0, 0, Landin.Types.I32);
      Check_Source
        ("f32 function",
         "f32: (v: i32) -> (r: i32) = r = v + 1 end f32" & LF
         & "f: (v: i32) -> (r: i32) = r = f32(v) end f" & LF,
         "f32", 1, 0, 0, Landin.Types.I32);
      Check_Source
        ("usize function",
         "usize: (v: i32) -> (r: i32) = r = v + 1 end usize" & LF
         & "f: (v: i32) -> (r: i32) = r = usize(v) end f" & LF,
         "usize", 1, 0, 0, Landin.Types.I32);
      Check_Source
        ("utf8 function",
         "utf8: (v: i32) -> (r: i32) = r = v + 1 end utf8" & LF
         & "f: (v: i32) -> (r: i32) = r = utf8(v) end f" & LF,
         "utf8", 1, 0, 0, Landin.Types.I32);
      Check_Source
        ("utf16 function",
         "utf16: (v: i32) -> (r: i32) = r = v + 1 end utf16" & LF
         & "f: (v: i32) -> (r: i32) = r = utf16(v) end f" & LF,
         "utf16", 1, 0, 0, Landin.Types.I32);
      Check_Source
        ("cstring function",
         "cstring: (v: i32) -> (r: i32) = r = v + 1 end cstring" & LF
         & "f: (v: i32) -> (r: i32) = r = cstring(v) end f" & LF,
         "cstring", 1, 0, 0, Landin.Types.I32);
      Check_Source
        ("same width shadow",
         "u8: (v: u8) -> (r: u8) = r = v +% 100 end u8" & LF
         & "f: () -> (r: i32) = r = i32(u8(41)) end f" & LF,
         "u8", 1, 0, 1, Landin.Types.I32);
      Check_Source
        ("callback parameter",
         "f: (u8: (v: i32) -> (r: i32), v: i32) -> (r: i32) = r "
         & "= u8(v) end f" & LF,
         "", 0, 1, 0, Landin.Types.I32);
      Check_Source
        ("local callback",
         "next: (v: i32) -> (r: i32) = r = v + 1 end next" & LF
         & "f: (v: i32) -> (r: i32) = utf8: (v: i32) -> (r: i32) "
         & "= next r = utf8(v) end f" & LF,
         "", 0, 1, 0, Landin.Types.I32);
      Check_Source
        ("generic function",
         "u8: (t: type, v: t) -> (r: t) = r = v end u8" & LF
         & "f: (v: i32) -> (r: i32) = r = u8(v) end f" & LF,
         "", 1, 0, 0, Landin.Types.I32);
      Check_Source
        ("builtin conversion",
         "f: (v: i32) -> (r: u8) = r = u8(v) end f" & LF,
         "", 0, 0, 1, Landin.Types.U8);
      Check_Source
        ("alias conversion",
         "byte: type = u8" & LF
         & "f: (v: i32) -> (r: byte) = r = byte(v) end f" & LF,
         "", 0, 0, 1, Landin.Types.U8);
      Check_Source
        ("builtin named alias conversion",
         "u8: type = u16" & LF
         & "f: (v: i32) -> (r: u16) = r = u8(v) end f" & LF,
         "", 0, 0, 1, Landin.Types.U16);
      Check_Source
        ("builtin text conversion",
         "f: (v: []u8) -> (r: utf8 from v) = r = utf8(v) end f" & LF,
         "", 0, 0, 0, Landin.Types.I32);
      Check_Source
        ("alias text conversion",
         "byte_view: type = []u8" & LF
         & "f: (v: utf8) -> (r: []u8 from v) =" & LF
         & "r = byte_view(v) end f" & LF,
         "", 0, 0, 0, Landin.Types.I32);
   end Calls_Respect_Resolved_Declarations;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "lowering", "calls respect resolved declarations",
         Calls_Respect_Resolved_Declarations'Access);
      Landin.Testing.Register
        (Into, "lowering", "static slice fields keep descriptors",
         Static_Slice_Fields_Keep_Descriptors'Access);
      Landin.Testing.Register
        (Into, "lowering", "construction storage stays addressable",
         Construction_Storage_Stays_Addressable'Access);
      Landin.Testing.Register
        (Into, "lowering", "R4.70 field ranges lower recursive shapes",
         R470_Field_Ranges_Lower_Recursive_Shapes'Access);
      Landin.Testing.Register
        (Into, "lowering", "R4.70 direct array inout uses one address",
         R470_Direct_Array_Inout_Uses_One_Address'Access);
      Landin.Testing.Register
        (Into, "lowering", "erased shaped arguments keep spill types",
         Erased_Shaped_Arguments_Keep_Spill_Types'Access);
      Landin.Testing.Register
        (Into, "lowering", "recursive repetition has bounded IR",
         Recursive_Repetition_Stays_Compact'Access);
      Landin.Testing.Register
        (Into, "lowering", "callback slice and inout typed metadata",
         Callback_Slices_And_Inout_Keep_Metadata'Access);
      Landin.Testing.Register
        (Into, "lowering", "recursive constructor source order before fill",
         Recursive_Constructors_Commit_Before_Filling'Access);
      Landin.Testing.Register
        (Into, "lowering", "UTF8 indexes in recursive contextual storage",
         Utf8_Indexes_Stay_Expressions_In_Recursive_Storage'Access);
      Landin.Testing.Register
        (Into, "lowering", "recursive static selections rebase images",
         Recursive_Static_Selections_Rebase_Images'Access);
      Landin.Testing.Register
        (Into, "lowering", "recursive numeric C ABI fixture source",
         Recursive_Numeric_ABI_Source_Lowers'Access);
      Landin.Testing.Register
        (Into, "lowering", "recursive callback C ABI fixture source",
         Recursive_Callback_ABI_Source_Lowers'Access);
      Landin.Testing.Register
        (Into, "lowering", "C aggregate logical entry and call carriers",
         C_Aggregate_Entries_And_Calls_Keep_Logical_Carriers'Access);
      Landin.Testing.Register
        (Into, "lowering", "C imported-only canonical metadata and dump",
         C_Imports_Retain_Canonical_Metadata'Access);
      Landin.Testing.Register
        (Into, "lowering", "C variadic actuals retain promoted types",
         C_Variadic_Actuals_Keep_Promoted_Types'Access);
      Landin.Testing.Register
        (Into, "lowering", "unchecked pointer conversions retain null checks",
         Unchecked_Pointer_Conversions_Keep_Null_Checks'Access);
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
        (Into, "lowering", "parameterized aliases lower as arrays",
         Parameterized_Aliases_Lower_As_Ordinary_Arrays'Access);
      Landin.Testing.Register
        (Into, "lowering", "generic routines lower once per key",
         Generic_Routine_Instances_Lower_Once_Per_Key'Access);
      Landin.Testing.Register
        (Into, "lowering", "parameterized structs lower as nominals",
         Parameterized_Structs_Lower_As_Concrete_Nominals'Access);
      Landin.Testing.Register
        (Into, "lowering", "nominal identity maps through public IR",
         Nominal_Identity_Maps_Through_The_Public_IR_Seam'Access);
      Landin.Testing.Register
        (Into, "lowering", "module bools become static images",
         Module_Bools_Become_Static_Images'Access);
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
        (Into, "lowering",
         "a recursive module image carries descriptors",
         A_Recursive_Module_Image_Carries_Descriptors'Access);
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
         "an array-of-struct measurement keeps its nominal",
         An_Array_Of_Struct_Measurement_Keeps_Its_Nominal'Access);
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
         "a nested child module initializer is refused",
         Nested_Child_Module_Initializer_Is_Refused'Access);
      Landin.Testing.Register
        (Into, "lowering",
         "aggregate arguments carry storage identity",
         Aggregate_Arguments_Carry_Storage_Identity'Access);
      Landin.Testing.Register
        (Into, "lowering",
         "nested arguments carry both identities",
         Nested_Arguments_Carry_Both_Identities'Access);
      Landin.Testing.Register
        (Into, "lowering",
         "variant arguments keep their shape",
         Variant_Arguments_Keep_Their_Shape'Access);
      Landin.Testing.Register
        (Into, "lowering",
         "aggregate returns use a hidden destination",
         Aggregate_Returns_Use_A_Hidden_Destination'Access);
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
        (Into, "lowering", "control values use caller-owned join slots",
         Control_Values_Use_Caller_Owned_Join_Slots'Access);
      Landin.Testing.Register
        (Into, "lowering", "statement controls keep final none calls",
         Statement_Controls_Keep_Final_None_Calls'Access);
      Landin.Testing.Register
        (Into, "lowering", "all-return controls create no join block",
         All_Return_Controls_Create_No_Join_Block'Access);
      Landin.Testing.Register
        (Into, "lowering", "deferred exits become ordinary reverse calls",
         Deferred_Exits_Become_Ordinary_Reverse_Calls'Access);
      Landin.Testing.Register
        (Into, "lowering", "undo exits become selected reverse calls",
         Undo_Exits_Become_Selected_Reverse_Calls'Access);
      Landin.Testing.Register
        (Into, "lowering", "a struct literal becomes ordered field writes",
         A_Struct_Literal_Becomes_Ordered_Field_Writes'Access);
      Landin.Testing.Register
        (Into, "lowering",
         "struct literal array labels use field operations",
         Struct_Literal_Array_Labels_Use_Field_Operations'Access);
      Landin.Testing.Register
        (Into, "lowering",
         "a fixed conditional selects the only lowered declaration",
         Fixed_Conditional_Selection_Reaches_IR'Access);
      Landin.Testing.Register
        (Into, "lowering",
         "a fixed conditional asks the typed target architecture",
         Fixed_Conditional_Uses_The_Typed_Target_Architecture'Access);
      Landin.Testing.Register
        (Into, "lowering",
         "a fixed conditional lowers its selected generic instance",
         Fixed_Conditional_Generic_Instance_Reaches_IR'Access);
      Landin.Testing.Register
        (Into, "lowering", "the recorded corpus is current",
         The_Recorded_Corpus_Is_Current'Access);
   end Register;

end Landin.Tests.Lowering_Suite;
