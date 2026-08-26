--  R1.70's exit evidence: malformed IR is rejected.
--
--  Every case here builds a shape the builder accepts and the verifier
--  must not.  That set is not arbitrary: Landin.IR's preconditions are
--  structural on purpose, so that a wrong-arity call and a mid-block
--  terminator stay constructible and therefore testable.  A rule whose
--  shape cannot be built is a rule whose test cannot fail, and the
--  verifier's own header says which rules were left out for that reason.
--
--  The frontend runs only to get a resolution table for Prepare and
--  Declaration_Ids for Add_Item; the sources are strings in memory.

with Landin.IR.Verifier;
with Landin.Provenance;
with Landin.Resolution;
with Landin.Source;
with Landin.Stages.Checking;
with Landin.Stages.Resolution;
with Landin.Stages.Syntax;
with Landin.Targets;
with Landin.Types;

package body Landin.Tests.Verifier_Suite is

   package IR renames Landin.IR;
   package V  renames Landin.IR.Verifier;

   use type IR.Value_Id;
   use type V.Fault_Kind;

   Frontend : aliased Landin.Stages.Syntax.Instance;
   Names    : aliased Landin.Stages.Resolution.Instance;
   Checker  : aliased Landin.Stages.Checking.Instance;

   LF : constant Character := Character'Val (10);

   --  Four declarations and then a fifth, which is what an item that is
   --  not a routine is built against below.
   Program : constant String :=
     "f: () -> (r: u32) = r = 1 end f" & LF
     & "g: () -> (r: u32) = r = 2 end g" & LF
     & "h: u32 = 3" & LF;

   procedure Ready
     (Work : in out Landin.Stages.Compilation;
      Site : out Landin.Provenance.Origin);

   procedure Ready
     (Work : in out Landin.Stages.Compilation;
      Site : out Landin.Provenance.Origin)
   is
      Order   : Landin.Stages.Pipeline;
      Ran     : Natural;
      Written : constant Landin.Source.Source_Id :=
        Landin.Stages.Add_Source (Work, "v.ldn", Program);
   begin
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);
      pragma Assert (Ran = 3);
      Site := (Source => Written, Where => Landin.Source.Empty_Span);
   end Ready;

   procedure Expect
     (Item  : in out Landin.Testing.Context;
      Found : V.Fault;
      Kind  : V.Fault_Kind;
      What  : String);

   procedure Expect
     (Item  : in out Landin.Testing.Context;
      Found : V.Fault;
      Kind  : V.Fault_Kind;
      What  : String) is
   begin
      Landin.Testing.Check_Equal
        (Item, V.Describe (Found.Kind), V.Describe (Kind), What);
   end Expect;

   ------------------------------------------------------------------

   procedure A_Sound_Unit_Is_Accepted
     (Item : in out Landin.Testing.Context);

   procedure A_Sound_Unit_Is_Accepted
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Site : Landin.Provenance.Origin;
   begin
      Ready (Work, Site);

      declare
         Meanings : constant not null access Landin.Resolution.Table :=
           Landin.Stages.Meanings (Work);
         Unit : IR.Unit;
         A    : IR.Item_Id;
         S    : IR.Slot_Id;
         B    : IR.Block_Id;
         N    : IR.Value_Id;
      begin
         IR.Prepare (Unit, Meanings.all);
         A := IR.Add_Item (Unit, IR.Routine, 1, Landin.Types.U32, Site);
         S := IR.Add_Slot (Unit, A, Landin.Types.U32, 2, Site);
         IR.Set_Result_Slot (Unit, A, S);
         B := IR.Add_Block (Unit, A, Landin.Resolution.Program_Scope,
                            Site);
         IR.Enter (Unit, A, B);
         N := IR.Emit_Number (Unit, A, Landin.Types.U32, 1, False, Site);
         IR.Emit_Store (Unit, A, S, N, Site);
         N := IR.Emit_Load (Unit, A, S, Site);
         IR.Emit_Leave (Unit, A, N, Site);
         IR.Leave_Block (Unit, A);

         Expect (Item, V.Check (Unit), V.Nothing_Wrong,
                 "a unit built by the book is accepted");
      end;
   end A_Sound_Unit_Is_Accepted;

   ------------------------------------------------------------------
   --  One damaged shape per case.
   ------------------------------------------------------------------

   type Damage is
     (No_Terminator,
      Terminator_In_The_Middle,
      No_Block_At_All,
      Left_Open,
      Operand_From_Another_Block,
      Result_Of_The_Wrong_Type,
      Operands_Of_Two_Types,
      Store_Of_The_Wrong_Type,
      Store_To_A_Parameter,
      Callee_Is_A_Datum,
      Datum_Load_Names_A_Routine,
      Datum_Load_Names_An_Aggregate,
      Condition_Is_A_Number,
      Call_Missing_An_Argument,
      Unreachable_Block,
      Leave_Of_The_Wrong_Type);

   function Built (Unit : in out IR.Unit;
                   Site : Landin.Provenance.Origin;
                   Harm : Damage) return V.Fault;

   function Built (Unit : in out IR.Unit;
                   Site : Landin.Provenance.Origin;
                   Harm : Damage) return V.Fault
   is
      A, D, G : IR.Item_Id;
      S, P : IR.Slot_Id;
      B, C : IR.Block_Id;
      N, M : IR.Value_Id;
   begin
      A := IR.Add_Item (Unit, IR.Routine, 1, Landin.Types.U32, Site);
      D := IR.Add_Item (Unit, IR.Datum, 3, Landin.Types.U32, Site);
      G := IR.Add_Item (Unit, IR.Datum, 5, Landin.Types.Aggregate, Site);
      IR.Add_Field (Unit, G, Landin.Types.U32);

      if Harm = No_Block_At_All then
         return V.Check (Unit);
      end if;

      P := IR.Add_Parameter (Unit, A, Landin.Types.U32, 2, Site);
      S := IR.Add_Slot (Unit, A, Landin.Types.U32, 4, Site);
      IR.Set_Result_Slot (Unit, A, S);
      B := IR.Add_Block (Unit, A, Landin.Resolution.Program_Scope, Site);
      IR.Enter (Unit, A, B);

      case Harm is
         when No_Terminator =>
            N := IR.Emit_Number
                   (Unit, A, Landin.Types.U32, 1, False, Site);
            pragma Assert (N /= IR.No_Value);
            IR.Leave_Block (Unit, A);

         when Terminator_In_The_Middle =>
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            N := IR.Emit_Number
                   (Unit, A, Landin.Types.U32, 1, False, Site);
            IR.Leave_Block (Unit, A);

         when Left_Open =>
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            --  and no Leave_Block

         when Operand_From_Another_Block =>
            C := IR.Add_Block
                   (Unit, A, Landin.Resolution.Program_Scope, Site);
            N := IR.Emit_Number
                   (Unit, A, Landin.Types.U32, 1, False, Site);
            IR.Emit_Jump (Unit, A, C, Site);
            IR.Leave_Block (Unit, A);
            IR.Enter (Unit, A, C);
            --  N belongs to B, and operands are block-local.
            IR.Emit_Store (Unit, A, S, N, Site);
            M := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, M, Site);
            IR.Leave_Block (Unit, A);

         when Result_Of_The_Wrong_Type =>
            N := IR.Emit_Number
                   (Unit, A, Landin.Types.U32, 1, False, Site);
            M := IR.Emit_Binary
                   (Unit, A, IR.Add, N, N, Landin.Types.U16, Site);
            pragma Assert (M /= IR.No_Value);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Operands_Of_Two_Types =>
            N := IR.Emit_Number
                   (Unit, A, Landin.Types.U32, 1, False, Site);
            M := IR.Emit_Number
                   (Unit, A, Landin.Types.U16, 1, False, Site);
            M := IR.Emit_Binary
                   (Unit, A, IR.Add, N, M, Landin.Types.U32, Site);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Store_Of_The_Wrong_Type =>
            N := IR.Emit_Truth (Unit, A, True, Site);
            IR.Emit_Store (Unit, A, S, N, Site);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Store_To_A_Parameter =>
            N := IR.Emit_Number
                   (Unit, A, Landin.Types.U32, 1, False, Site);
            IR.Emit_Store (Unit, A, P, N, Site);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Callee_Is_A_Datum =>
            N := IR.Emit_Call (Unit, A, D, Landin.Types.U32, Site);
            pragma Assert (N /= IR.No_Value);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Datum_Load_Names_A_Routine =>
            N := IR.Emit_Load_Datum (Unit, A, A, Site);
            pragma Assert (N /= IR.No_Value);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Datum_Load_Names_An_Aggregate =>
            N := IR.Emit_Load_Datum (Unit, A, G, Site);
            pragma Assert (N /= IR.No_Value);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Condition_Is_A_Number =>
            C := IR.Add_Block
                   (Unit, A, Landin.Resolution.Program_Scope, Site);
            N := IR.Emit_Number
                   (Unit, A, Landin.Types.U32, 1, False, Site);
            IR.Emit_Branch (Unit, A, N, C, C, Site);
            IR.Leave_Block (Unit, A);
            IR.Enter (Unit, A, C);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Call_Missing_An_Argument =>
            --  A takes one parameter, and this call gives it none.
            N := IR.Emit_Call (Unit, A, A, Landin.Types.U32, Site);
            pragma Assert (N /= IR.No_Value);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Unreachable_Block =>
            C := IR.Add_Block
                   (Unit, A, Landin.Resolution.Program_Scope, Site);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);
            --  Entered and terminated, and nothing jumps to it.
            IR.Enter (Unit, A, C);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Leave_Of_The_Wrong_Type =>
            N := IR.Emit_Truth (Unit, A, True, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when No_Block_At_All =>
            null;
      end case;

      return V.Check (Unit);
   end Built;

   procedure Malformed_Shapes_Are_Rejected
     (Item : in out Landin.Testing.Context);

   procedure Malformed_Shapes_Are_Rejected
     (Item : in out Landin.Testing.Context)
   is
      type Row is record
         Harm : Damage;
         Kind : V.Fault_Kind;
      end record;

      Wanted : constant array (Positive range <>) of Row :=
        [(No_Terminator,              V.Block_Without_A_Terminator),
         (Terminator_In_The_Middle,   V.Terminator_Inside_A_Block),
         (No_Block_At_All,            V.Item_Without_A_Block),
         (Left_Open,                  V.Item_Still_Building),
         (Operand_From_Another_Block, V.Operand_In_Another_Block),
         (Result_Of_The_Wrong_Type,   V.Result_Disagrees),
         (Operands_Of_Two_Types,      V.Operands_Disagree),
         (Store_Of_The_Wrong_Type,    V.Store_Disagrees_With_Slot),
         (Store_To_A_Parameter,       V.Store_To_A_Parameter),
         (Callee_Is_A_Datum,          V.Callee_Is_Not_A_Routine),
         (Datum_Load_Names_A_Routine, V.Named_Item_Is_Not_A_Datum),
         (Datum_Load_Names_An_Aggregate,
          V.Aggregate_Datum_Is_Not_A_Value),
         (Condition_Is_A_Number,      V.Condition_Is_Not_A_Bool),
         (Call_Missing_An_Argument,   V.Wrong_Operand_Count),
         (Unreachable_Block,          V.Block_Unreachable),
         (Leave_Of_The_Wrong_Type,    V.Leave_Disagrees_With_Item)];
   begin
      for Each of Wanted loop
         declare
            Work : Landin.Stages.Compilation :=
              Landin.Stages.Create (Landin.Targets.Linux_X86_64);
            Site : Landin.Provenance.Origin;
            Unit : IR.Unit;
         begin
            Ready (Work, Site);
            IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
            Expect
              (Item, Built (Unit, Site, Each.Harm), Each.Kind,
               Damage'Image (Each.Harm) & " is rejected");
         end;
      end loop;
   end Malformed_Shapes_Are_Rejected;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "verifier", "a sound unit is accepted",
         A_Sound_Unit_Is_Accepted'Access);
      Landin.Testing.Register
        (Into, "verifier", "malformed shapes are rejected",
         Malformed_Shapes_Are_Rejected'Access);
   end Register;

end Landin.Tests.Verifier_Suite;
