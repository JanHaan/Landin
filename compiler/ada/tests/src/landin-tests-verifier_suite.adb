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

with Landin.IR.Testing_Support;
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

   use type IR.Element_Total;
   use type IR.Value_Id;
   use type Landin.Types.Folded;
   use type V.Fault_Kind;

   Frontend : aliased Landin.Stages.Syntax.Instance;
   Names    : aliased Landin.Stages.Resolution.Instance;
   Checker  : aliased Landin.Stages.Checking.Instance;

   LF : constant Character := Character'Val (10);

   --  The declarations give each hand-built routine and datum its own
   --  identity, including both aggregate shapes used by malformed accesses.
   Program : constant String :=
     "f: () -> (r: u32) = r = 1 end f" & LF
     & "g: () -> (r: u32) = r = 2 end g" & LF
     & "h: u32 = 3" & LF
     & "k: u32 = 4" & LF;

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
         S, Q, R : IR.Slot_Id;
         B       : IR.Block_Id;
         N    : IR.Value_Id;
      begin
         IR.Prepare (Unit, Meanings.all);
         A := IR.Add_Item (Unit, IR.Routine, 1, Landin.Types.U32, Site);
         S := IR.Add_Slot (Unit, A, Landin.Types.U32, 2, Site);
         Q := IR.Add_Array_Slot
           (Unit, A, Landin.Types.U16, 2 ** 32 - 1,
            IR.No_Declaration, Site);
         R := IR.Add_Array_Slot
           (Unit, A, Landin.Types.U16, 2 ** 32 - 1,
            IR.No_Declaration, Site);
         IR.Set_Result_Slot (Unit, A, S);
         B := IR.Add_Block (Unit, A, Landin.Resolution.Program_Scope,
                            Site);
         IR.Enter (Unit, A, B);
         IR.Emit_Array_Copy
           (Unit, A, (Kind => IR.Frame_Slot, Slot => Q),
            (Kind => IR.Frame_Slot, Slot => R), Site);
         N := IR.Emit_Number (Unit, A, Landin.Types.U16, 7, False, Site);
         IR.Emit_Array_Fill
           (Unit, A, (Kind => IR.Frame_Slot, Slot => Q), N, Site);
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
      Field_Beyond_The_Aggregate,
      Field_Store_Of_The_Wrong_Type,
      Local_Array_Part_Is_Out_Of_Range,
      Local_Array_Load_Has_The_Wrong_Type,
      Local_Array_Store_Has_The_Wrong_Type,
      Element_Datum_Is_Not_An_Array,
      Element_Index_Is_Not_Usize,
      Element_Load_Of_The_Wrong_Type,
      Element_Store_Of_The_Wrong_Type,
      Slot_Element_Reaches_A_Nonarray_Slot,
      Slot_Element_Load_Of_The_Wrong_Type,
      Slot_Element_Store_Of_The_Wrong_Type,
      Array_Copy_Endpoint_Is_Scalar,
      Array_Copy_Lengths_Disagree,
      Array_Copy_Elements_Disagree,
      Array_Copy_Slot_Is_Not_Owned,
      Array_Copy_Inside_A_Datum,
      Array_Clear_Destination_Is_Scalar,
      Array_Clear_Slot_Is_Not_Owned,
      Array_Clear_Inside_A_Datum,
      Array_Fill_Destination_Is_Scalar,
      Array_Fill_Slot_Is_Not_Owned,
      Array_Fill_Value_Has_The_Wrong_Type,
      Array_Fill_Inside_A_Datum,
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
      A, D, G, E : IR.Item_Id;
      S, P, Q, R : IR.Slot_Id;
      B, C : IR.Block_Id;
      N, M : IR.Value_Id;
   begin
      A := IR.Add_Item (Unit, IR.Routine, 1, Landin.Types.U32, Site);
      --  E precedes the deliberately blockless helper datums so the
      --  datum-copy case reaches the instruction it is about first.
      E := IR.Add_Item (Unit, IR.Datum, 6, Landin.Types.Fixed_Array, Site);
      IR.Set_Array (Unit, E, Landin.Types.U32, 4);
      D := IR.Add_Item (Unit, IR.Datum, 3, Landin.Types.U32, Site);
      G := IR.Add_Item (Unit, IR.Datum, 5, Landin.Types.Aggregate, Site);
      IR.Add_Field (Unit, G, Landin.Types.U32);

      if Harm = No_Block_At_All then
         return V.Check (Unit);
      end if;

      P := IR.Add_Parameter (Unit, A, Landin.Types.U32, 2, Site);
      S := IR.Add_Slot (Unit, A, Landin.Types.U32, 4, Site);
      Q := IR.Add_Array_Slot
        (Unit, A, Landin.Types.U32, 4, IR.No_Declaration, Site);
      R := IR.Add_Array_Slot
        (Unit, A,
         (if Harm = Array_Copy_Elements_Disagree
          then Landin.Types.U16 else Landin.Types.U32),
         (if Harm = Array_Copy_Lengths_Disagree then 5 else 4),
         IR.No_Declaration, Site);
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

         when Field_Beyond_The_Aggregate =>
            --  G has one field, and this names its second.
            N := IR.Emit_Load_Field
                   (Unit, A, G, 2, Landin.Types.U32, Site);
            pragma Assert (N /= IR.No_Value);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Field_Store_Of_The_Wrong_Type =>
            --  G's one field is a u32, and this writes a bool to it.
            N := IR.Emit_Truth (Unit, A, True, Site);
            IR.Emit_Store_Field (Unit, A, G, 1, N, Site);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Local_Array_Part_Is_Out_Of_Range =>
            N := IR.Emit_Load_Slot_Field
              (Unit, A, Q, 5, Landin.Types.U32, Site);
            pragma Assert (N /= IR.No_Value);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Local_Array_Load_Has_The_Wrong_Type =>
            N := IR.Emit_Load_Slot_Field
              (Unit, A, Q, 4, Landin.Types.Bool, Site);
            pragma Assert (N /= IR.No_Value);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Local_Array_Store_Has_The_Wrong_Type =>
            N := IR.Emit_Truth (Unit, A, True, Site);
            IR.Emit_Store_Slot_Field (Unit, A, Q, 4, N, Site);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Element_Datum_Is_Not_An_Array =>
            N := IR.Emit_Number
                   (Unit, A, Landin.Types.Usize, 1, False, Site);
            M := IR.Emit_Load_Element
                   (Unit, A, D, N, Landin.Types.U32, Site);
            pragma Assert (M /= IR.No_Value);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Element_Index_Is_Not_Usize =>
            N := IR.Emit_Number
                   (Unit, A, Landin.Types.U32, 1, False, Site);
            M := IR.Emit_Load_Element
                   (Unit, A, E, N, Landin.Types.U32, Site);
            pragma Assert (M /= IR.No_Value);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Element_Load_Of_The_Wrong_Type =>
            N := IR.Emit_Number
                   (Unit, A, Landin.Types.Usize, 1, False, Site);
            M := IR.Emit_Load_Element
                   (Unit, A, E, N, Landin.Types.Bool, Site);
            pragma Assert (M /= IR.No_Value);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Element_Store_Of_The_Wrong_Type =>
            N := IR.Emit_Number
                   (Unit, A, Landin.Types.Usize, 1, False, Site);
            M := IR.Emit_Truth (Unit, A, True, Site);
            IR.Emit_Store_Element (Unit, A, E, N, M, Site);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Slot_Element_Reaches_A_Nonarray_Slot =>
            --  S is a plain scalar cell.  A computed element operation
            --  on it is not a shape D22 admits.
            N := IR.Emit_Number
                   (Unit, A, Landin.Types.Usize, 1, False, Site);
            M := IR.Emit_Load_Slot_Element
                   (Unit, A, S, N, Landin.Types.U32, Site);
            pragma Assert (M /= IR.No_Value);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Slot_Element_Load_Of_The_Wrong_Type =>
            --  Q holds u32 elements; the load claims a bool.
            N := IR.Emit_Number
                   (Unit, A, Landin.Types.Usize, 1, False, Site);
            M := IR.Emit_Load_Slot_Element
                   (Unit, A, Q, N, Landin.Types.Bool, Site);
            pragma Assert (M /= IR.No_Value);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Slot_Element_Store_Of_The_Wrong_Type =>
            N := IR.Emit_Number
                   (Unit, A, Landin.Types.Usize, 1, False, Site);
            M := IR.Emit_Truth (Unit, A, True, Site);
            IR.Emit_Store_Slot_Element (Unit, A, Q, N, M, Site);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Array_Copy_Endpoint_Is_Scalar =>
            IR.Emit_Array_Copy
              (Unit, A, (Kind => IR.Module_Datum, Datum => D),
               (Kind => IR.Frame_Slot, Slot => Q), Site);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Array_Copy_Lengths_Disagree
            | Array_Copy_Elements_Disagree =>
            IR.Emit_Array_Copy
              (Unit, A, (Kind => IR.Frame_Slot, Slot => Q),
               (Kind => IR.Frame_Slot, Slot => R), Site);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Array_Copy_Slot_Is_Not_Owned =>
            IR.Emit_Array_Copy
              (Unit, A, (Kind => IR.Frame_Slot, Slot => 5),
               (Kind => IR.Frame_Slot, Slot => Q), Site);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Array_Copy_Inside_A_Datum =>
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);
            B := IR.Add_Block
              (Unit, E, Landin.Resolution.Program_Scope, Site);
            IR.Enter (Unit, E, B);
            IR.Emit_Array_Copy
              (Unit, E, (Kind => IR.Module_Datum, Datum => E),
               (Kind => IR.Module_Datum, Datum => E), Site);
            IR.Emit_Leave (Unit, E, IR.No_Value, Site);
            IR.Leave_Block (Unit, E);

         when Array_Clear_Destination_Is_Scalar =>
            IR.Emit_Array_Clear
              (Unit, A, (Kind => IR.Frame_Slot, Slot => S), Site);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Array_Clear_Slot_Is_Not_Owned =>
            IR.Emit_Array_Clear
              (Unit, A, (Kind => IR.Frame_Slot, Slot => 5), Site);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Array_Clear_Inside_A_Datum =>
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);
            B := IR.Add_Block
              (Unit, E, Landin.Resolution.Program_Scope, Site);
            IR.Enter (Unit, E, B);
            IR.Emit_Array_Clear
              (Unit, E, (Kind => IR.Module_Datum, Datum => E), Site);
            IR.Emit_Leave (Unit, E, IR.No_Value, Site);
            IR.Leave_Block (Unit, E);

         when Array_Fill_Destination_Is_Scalar =>
            N := IR.Emit_Number
              (Unit, A, Landin.Types.U32, 1, False, Site);
            IR.Emit_Array_Fill
              (Unit, A, (Kind => IR.Frame_Slot, Slot => S), N, Site);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Array_Fill_Slot_Is_Not_Owned =>
            N := IR.Emit_Number
              (Unit, A, Landin.Types.U32, 1, False, Site);
            IR.Emit_Array_Fill
              (Unit, A, (Kind => IR.Frame_Slot, Slot => 5), N, Site);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Array_Fill_Value_Has_The_Wrong_Type =>
            N := IR.Emit_Truth (Unit, A, True, Site);
            IR.Emit_Array_Fill
              (Unit, A, (Kind => IR.Frame_Slot, Slot => Q), N, Site);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Array_Fill_Inside_A_Datum =>
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);
            B := IR.Add_Block
              (Unit, E, Landin.Resolution.Program_Scope, Site);
            IR.Enter (Unit, E, B);
            N := IR.Emit_Number
              (Unit, E, Landin.Types.U32, 1, False, Site);
            IR.Emit_Array_Fill
              (Unit, E, (Kind => IR.Module_Datum, Datum => E), N, Site);
            IR.Emit_Leave (Unit, E, IR.No_Value, Site);
            IR.Leave_Block (Unit, E);

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
         (Field_Beyond_The_Aggregate, V.Field_Out_Of_Range),
         (Field_Store_Of_The_Wrong_Type, V.Store_Datum_Disagrees),
         (Local_Array_Part_Is_Out_Of_Range, V.Field_Out_Of_Range),
         (Local_Array_Load_Has_The_Wrong_Type, V.Result_Disagrees),
         (Local_Array_Store_Has_The_Wrong_Type,
          V.Store_Datum_Disagrees),
         (Element_Datum_Is_Not_An_Array,
          V.Element_Datum_Is_Not_An_Array),
         (Element_Index_Is_Not_Usize, V.Element_Index_Is_Not_Usize),
         (Element_Load_Of_The_Wrong_Type, V.Result_Disagrees),
         (Element_Store_Of_The_Wrong_Type, V.Store_Datum_Disagrees),
         (Slot_Element_Reaches_A_Nonarray_Slot,
          V.Element_Datum_Is_Not_An_Array),
         (Slot_Element_Load_Of_The_Wrong_Type, V.Result_Disagrees),
         (Slot_Element_Store_Of_The_Wrong_Type,
          V.Store_Datum_Disagrees),
         (Array_Copy_Endpoint_Is_Scalar,
          V.Array_Storage_Is_Not_An_Array),
         (Array_Copy_Lengths_Disagree, V.Array_Copy_Shapes_Disagree),
         (Array_Copy_Elements_Disagree, V.Array_Copy_Shapes_Disagree),
         (Array_Copy_Slot_Is_Not_Owned, V.Slot_Out_Of_Range),
         (Array_Copy_Inside_A_Datum, V.Array_Copy_Inside_A_Datum),
         (Array_Clear_Destination_Is_Scalar,
          V.Array_Storage_Is_Not_An_Array),
         (Array_Clear_Slot_Is_Not_Owned, V.Slot_Out_Of_Range),
         (Array_Clear_Inside_A_Datum, V.Array_Clear_Inside_A_Datum),
         (Array_Fill_Destination_Is_Scalar,
          V.Array_Storage_Is_Not_An_Array),
         (Array_Fill_Slot_Is_Not_Owned, V.Slot_Out_Of_Range),
         (Array_Fill_Value_Has_The_Wrong_Type,
          V.Array_Fill_Value_Disagrees),
         (Array_Fill_Inside_A_Datum, V.Array_Fill_Inside_A_Datum),
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

   --  D24: an array datum's per-position image has to fit its element type
   --  at the compilation's target facts.  An u8 that holds 300 or a bool
   --  that holds 2 is IR whose bytes the backend has no defined answer
   --  for, and a 32-bit `usize` cannot hold a value that overflows the
   --  target address space even when the Folded run has room for it.
   procedure Malformed_Image_Values_Are_Rejected
     (Item : in out Landin.Testing.Context);

   procedure Malformed_Image_Values_Are_Rejected
     (Item : in out Landin.Testing.Context)
   is
      type Row is record
         Element  : Landin.Types.Scalar_Name;
         Value    : Landin.Types.Folded;
         Facts    : Landin.Targets.Target_Facts;
         Rejected : Boolean;
         Label    : String (1 .. 40);
      end record;

      function Padded (Text : String) return String;

      function Padded (Text : String) return String is
         Result : String (1 .. 40) := [others => ' '];
      begin
         Result (1 .. Text'Length) := Text;
         return Result;
      end Padded;

      Cases : constant array (Positive range <>) of Row :=
        [(Landin.Types.U8, 300, Landin.Targets.Linux_X86_64, True,
          Padded ("u8 = 300")),
         (Landin.Types.U8, 255, Landin.Targets.Linux_X86_64, False,
          Padded ("u8 = 255")),
         (Landin.Types.Bool, 2, Landin.Targets.Linux_X86_64, True,
          Padded ("bool = 2")),
         (Landin.Types.Bool, 1, Landin.Targets.Linux_X86_64, False,
          Padded ("bool = 1")),
         (Landin.Types.Usize, 2 ** 32,
          Landin.Targets.Synthetic_32, True,
          Padded ("usize = 2**32 on 32-bit")),
         (Landin.Types.Usize, 2 ** 32,
          Landin.Targets.Linux_X86_64, False,
          Padded ("usize = 2**32 on 64-bit"))];
   begin
      for Each of Cases loop
         declare
            Work : Landin.Stages.Compilation :=
              Landin.Stages.Create (Each.Facts);
            Site : Landin.Provenance.Origin;
            Unit : IR.Unit;
            Datum : IR.Item_Id;
            Block : IR.Block_Id;
            Result : V.Fault;
         begin
            Ready (Work, Site);
            IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
            Datum := IR.Add_Item
              (Unit, IR.Datum, 1, Landin.Types.Fixed_Array, Site);
            IR.Set_Array (Unit, Datum, Each.Element, 1);
            IR.Set_Array_Image
              (Unit, Datum, Landin.Types.Folded_Array'(1 => Each.Value));
            Block := IR.Add_Block
              (Unit, Datum, Landin.Resolution.Program_Scope, Site);
            IR.Enter (Unit, Datum, Block);
            IR.Emit_Leave (Unit, Datum, IR.No_Value, Site);
            IR.Leave_Block (Unit, Datum);

            Result := V.Check (Unit, Each.Facts);

            if Each.Rejected then
               Landin.Testing.Check
                 (Item,
                  Result.Kind = V.Array_Image_Value_Does_Not_Fit,
                  Each.Label & ": refused as out-of-range image");
            else
               Landin.Testing.Check
                 (Item,
                  Result.Kind = V.Nothing_Wrong,
                  Each.Label & ": accepted as an in-range image");
            end if;
         end;
      end loop;
   end Malformed_Image_Values_Are_Rejected;

   --  D24: an image run has to partition the shared vector alongside
   --  Slots, Blocks, Values and Fields.  Unlike those, images are filled
   --  in chain-resolution order rather than item order, so the partition
   --  check cannot rely on Held.Image.First = previous item's endpoint.
   --  This case pins the three malformed shapes the partition still has
   --  to refuse: a base past the vector's end, two items whose runs
   --  overlap, and a vector byte no item claims.
   procedure Malformed_Image_Runs_Are_Rejected
     (Item : in out Landin.Testing.Context);

   procedure Malformed_Image_Runs_Are_Rejected
     (Item : in out Landin.Testing.Context)
   is
      procedure Ready_With_Datum
        (Work  : in out Landin.Stages.Compilation;
         Unit  : in out IR.Unit;
         Site  : out Landin.Provenance.Origin;
         Datum : out IR.Item_Id;
         Length : IR.Element_Total);

      procedure Ready_With_Datum
        (Work  : in out Landin.Stages.Compilation;
         Unit  : in out IR.Unit;
         Site  : out Landin.Provenance.Origin;
         Datum : out IR.Item_Id;
         Length : IR.Element_Total)
      is
         Block : IR.Block_Id;
      begin
         Ready (Work, Site);
         IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
         Datum := IR.Add_Item
           (Unit, IR.Datum, 1, Landin.Types.Fixed_Array, Site);
         IR.Set_Array (Unit, Datum, Landin.Types.U8, Length);
         Block := IR.Add_Block
           (Unit, Datum, Landin.Resolution.Program_Scope, Site);
         IR.Enter (Unit, Datum, Block);
         IR.Emit_Leave (Unit, Datum, IR.No_Value, Site);
         IR.Leave_Block (Unit, Datum);
      end Ready_With_Datum;
   begin
      --  Case one: a base + count that walks past the vector's end,
      --  which a Nth_Image call would otherwise turn into a
      --  Constraint_Error at read time.
      declare
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Site : Landin.Provenance.Origin;
         Unit : IR.Unit;
         Datum : IR.Item_Id;
      begin
         Ready_With_Datum (Work, Unit, Site, Datum, Length => 3);
         --  Two bytes in the vector, three claimed.
         Landin.IR.Testing_Support.Append_Image_Bytes (Unit, 2);
         Landin.IR.Testing_Support.Overwrite_Image_Run
           (Unit, Datum, First => 0, Count => 3);
         Expect
           (Item, V.Check (Unit, Landin.Targets.Linux_X86_64),
            V.Item_Runs_Overlap,
            "an image run that walks past the vector is refused");
      end;

      --  Case two: two datums whose runs overlap.  Bytes 1..3 belong
      --  to the first and 2..4 would belong to the second, so byte 2
      --  is claimed twice and the vector cannot describe a partition.
      declare
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Site : Landin.Provenance.Origin;
         Unit : IR.Unit;
         Datum, Second : IR.Item_Id;
         Block : IR.Block_Id;
      begin
         Ready_With_Datum (Work, Unit, Site, Datum, Length => 3);
         Second := IR.Add_Item
           (Unit, IR.Datum, 3, Landin.Types.Fixed_Array, Site);
         IR.Set_Array (Unit, Second, Landin.Types.U8, 3);
         Block := IR.Add_Block
           (Unit, Second, Landin.Resolution.Program_Scope, Site);
         IR.Enter (Unit, Second, Block);
         IR.Emit_Leave (Unit, Second, IR.No_Value, Site);
         IR.Leave_Block (Unit, Second);

         --  Datum owns 0..2, Second overlaps at 1..3.
         Landin.IR.Testing_Support.Append_Image_Bytes (Unit, 4);
         Landin.IR.Testing_Support.Overwrite_Image_Run
           (Unit, Datum, First => 0, Count => 3);
         Landin.IR.Testing_Support.Overwrite_Image_Run
           (Unit, Second, First => 1, Count => 3);

         Expect
           (Item, V.Check (Unit, Landin.Targets.Linux_X86_64),
            V.Item_Runs_Overlap,
            "two image runs sharing a byte are refused");
      end;

      --  Case three: a byte in the vector no item claims.  Datum owns
      --  0..1 and byte 2 is orphaned, so the partition has a gap.
      declare
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Site : Landin.Provenance.Origin;
         Unit : IR.Unit;
         Datum : IR.Item_Id;
      begin
         Ready_With_Datum (Work, Unit, Site, Datum, Length => 3);
         Landin.IR.Testing_Support.Append_Image_Bytes (Unit, 3);
         Landin.IR.Testing_Support.Overwrite_Image_Run
           (Unit, Datum, First => 0, Count => 2);

         Expect
           (Item, V.Check (Unit, Landin.Targets.Linux_X86_64),
            V.Item_Runs_Overlap,
            "a vector byte no item claims is refused");
      end;

      --  Case four: a corrupt base at Natural'Last.  The naive
      --  `First + Count > Total` overflows Natural before the walk
      --  speaks and raises Constraint_Error instead of returning a
      --  Fault.  The subtraction-safe form has to refuse this instead.
      declare
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Site : Landin.Provenance.Origin;
         Unit : IR.Unit;
         Datum : IR.Item_Id;
      begin
         Ready_With_Datum (Work, Unit, Site, Datum, Length => 3);
         Landin.IR.Testing_Support.Append_Image_Bytes (Unit, 3);
         Landin.IR.Testing_Support.Overwrite_Image_Run
           (Unit, Datum, First => Natural'Last, Count => 1);
         Expect
           (Item, V.Check (Unit, Landin.Targets.Linux_X86_64),
            V.Item_Runs_Overlap,
            "an image run at Natural'Last is refused without arithmetic"
            & " overflow");
      end;
   end Malformed_Image_Runs_Are_Rejected;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "verifier", "a sound unit is accepted",
         A_Sound_Unit_Is_Accepted'Access);
      Landin.Testing.Register
        (Into, "verifier", "malformed shapes are rejected",
         Malformed_Shapes_Are_Rejected'Access);
      Landin.Testing.Register
        (Into, "verifier", "malformed image values are rejected",
         Malformed_Image_Values_Are_Rejected'Access);
      Landin.Testing.Register
        (Into, "verifier", "malformed image runs are rejected",
         Malformed_Image_Runs_Are_Rejected'Access);
   end Register;

end Landin.Tests.Verifier_Suite;
