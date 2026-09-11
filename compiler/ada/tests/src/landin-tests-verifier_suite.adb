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

with Ada.Strings.Fixed;

with Landin.IR.Dump;
with Landin.IR.Testing_Support;
with Landin.IR.Verifier;
with Landin.Provenance;
with Landin.Resolution;
with Landin.Source;
with Landin.Stages.Checking;
with Landin.Stages.Configuration;
with Landin.Stages.Resolution;
with Landin.Stages.Syntax;
with Landin.Targets;
with Landin.Types;

package body Landin.Tests.Verifier_Suite is

   package IR renames Landin.IR;

   --  D118: the path one depth-one child identity spells, so a malformed
   --  case can name a step without writing the run out each time.
   function Below (Child : Natural) return IR.Path_Step_Array
     is (if Child = 0 then IR.No_Path_Steps
         else [1 => (Field      => IR.Part_Position (Child),
                     Case_Index => 0)]);
   package V  renames Landin.IR.Verifier;

   use type IR.Element_Total;
   use type IR.Nominal_Type_Id;
   use type IR.Parameter_Convention;
   use type IR.Value_Id;
   use type Landin.Types.Folded;
   use type V.Fault_Kind;

   Frontend : aliased Landin.Stages.Syntax.Instance;
   Names    : aliased Landin.Stages.Resolution.Instance;
   Configurer : aliased Landin.Stages.Configuration.Instance;
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
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);
      pragma Assert (Ran = 4);
      Site := (Source => Written, Where => Landin.Source.Empty_Span);
   end Ready;

   function Test_Nominal (Unit : in out IR.Unit)
     return IR.Nominal_Type_Id;

   function Test_Nominal (Unit : in out IR.Unit)
     return IR.Nominal_Type_Id
   is
   begin
      if IR.Nominal_Type_Count (Unit) = 0 then
         return IR.Add_Nominal_Type (Unit, 1);
      end if;
      return IR.Nth_Nominal_Type (Unit, 1);
   end Test_Nominal;

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

   procedure Add_Empty_Body
     (Unit : in out IR.Unit; Routine : IR.Item_Id;
      Site : Landin.Provenance.Origin);

   procedure Add_Empty_Body
     (Unit : in out IR.Unit; Routine : IR.Item_Id;
      Site : Landin.Provenance.Origin)
   is
      Block : constant IR.Block_Id := IR.Add_Block
        (Unit, Routine, Landin.Resolution.Program_Scope, Site);
   begin
      IR.Enter (Unit, Routine, Block);
      IR.Emit_Leave (Unit, Routine, IR.No_Value, Site);
      IR.Leave_Block (Unit, Routine);
   end Add_Empty_Body;

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
         A, G : IR.Item_Id;
         S, Q, R, T : IR.Slot_Id;
         B       : IR.Block_Id;
         N    : IR.Value_Id;
      begin
         IR.Prepare (Unit, Meanings.all);
         A := IR.Add_Item (Unit, IR.Routine, 1, Landin.Types.U32, Site);
         G := IR.Add_Item
           (Unit, IR.Datum, 5, Landin.Types.Aggregate, Site);
         IR.Add_Field (Unit, G, Landin.Types.U8);
         IR.Add_Field
           (Unit, G,
            (Kind    => IR.Array_Field_Shape,
             Element => Landin.Types.U16,
             Length  => 2,
             others => <>));
         IR.Add_Field
           (Unit, G,
            (Kind           => IR.Variant_Field_Shape,
             Element        => Landin.Types.U8,
             Length         => 1,
             Cases          => 2,
             Payloads_First => 1,
             others         => <>),
            Cases => [(First => 0, Count => 0),
                      (First => 1, Count => 1)],
            Payloads => [(Kind    => IR.Scalar_Field_Shape,
                          Element => Landin.Types.U32,
                          Length  => 1,
                          others  => <>)]);
         S := IR.Add_Slot (Unit, A, Landin.Types.U32, 2, Site);
         Q := IR.Add_Array_Slot
           (Unit, A, Landin.Types.U16, 2 ** 32 - 1,
            IR.No_Declaration, Site);
         R := IR.Add_Array_Slot
           (Unit, A, Landin.Types.U16, 2 ** 32 - 1,
            IR.No_Declaration, Site);
         T := IR.Add_Aggregate_Slot
           (Unit, A, IR.No_Declaration, Site);
         IR.Add_Slot_Field (Unit, A, T, Landin.Types.U8);
         IR.Add_Slot_Field
           (Unit, A, T,
            (Kind    => IR.Array_Field_Shape,
             Element => Landin.Types.U16,
             Length  => 2,
             others => <>));
         IR.Add_Slot_Field
           (Unit, A, T,
            (Kind           => IR.Variant_Field_Shape,
             Element        => Landin.Types.U8,
             Length         => 1,
             Cases          => 2,
             Payloads_First => 1,
             others         => <>),
            Cases => [(First => 0, Count => 0),
                      (First => 1, Count => 1)],
            Payloads => [(Kind    => IR.Array_Field_Shape,
                          Element => Landin.Types.U16,
                          Length  => 3,
                          others  => <>)]);
         IR.Set_Result_Slot (Unit, A, S);
         B := IR.Add_Block (Unit, A, Landin.Resolution.Program_Scope,
                            Site);
         IR.Enter (Unit, A, B);
         IR.Emit_Array_Copy
           (Unit, A, (Kind => IR.Frame_Slot, Slot => Q),
            (Kind => IR.Frame_Slot, Slot => R), Site);
         --  D57 gives field zero of the destination-only clear a second
         --  sound shape: the complete padded extent of aggregate storage.
         IR.Emit_Array_Clear
           (Unit, A, (Kind => IR.Frame_Slot, Slot => T), Site);
         --  D58 makes D57's other whole-aggregate storage class live.
         IR.Emit_Array_Clear
           (Unit, A, (Kind => IR.Module_Datum, Datum => G), Site);
         N := IR.Emit_Number (Unit, A, Landin.Types.U16, 7, False, Site);
         IR.Emit_Array_Fill
           (Unit, A, (Kind => IR.Frame_Slot, Slot => Q), 1, N, Site);
         IR.Emit_Variant_Select
           (Unit, A, (Kind => IR.Frame_Slot, Slot => T), 3, 2, Site);
         IR.Emit_Variant_Select
           (Unit, A, (Kind => IR.Module_Datum, Datum => G), 3, 2, Site);
         N := IR.Emit_Number (Unit, A, Landin.Types.U32, 9, False, Site);
         IR.Emit_Variant_Field_Store
           (Unit, A, (Kind => IR.Module_Datum, Datum => G),
            3, 2, 1, N, Site);
         N := IR.Emit_Number (Unit, A, Landin.Types.U32, 1, False, Site);
         IR.Emit_Store (Unit, A, S, N, Site);
         N := IR.Emit_Load (Unit, A, S, Site);
         IR.Emit_Leave (Unit, A, N, Site);
         IR.Leave_Block (Unit, A);

         B := IR.Add_Block
           (Unit, G, Landin.Resolution.Program_Scope, Site);
         IR.Enter (Unit, G, B);
         IR.Emit_Leave (Unit, G, IR.No_Value, Site);
         IR.Leave_Block (Unit, G);

         Expect (Item, V.Check (Unit), V.Nothing_Wrong,
                 "a unit built by the book is accepted");
      end;
   end A_Sound_Unit_Is_Accepted;

   ------------------------------------------------------------------
   --  One damaged shape per case.
   ------------------------------------------------------------------

   procedure Same_Layout_Nominals_Do_Not_Agree_In_Signatures
     (Item : in out Landin.Testing.Context);

   procedure Same_Layout_Nominals_Do_Not_Agree_In_Signatures
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
         Left, Right : IR.Nominal_Type_Id;
         Routine : IR.Item_Id;
         Parameter : IR.Slot_Id;
         Signature : IR.Signature_Id;
         Block : IR.Block_Id;
         Value : IR.Value_Id;
      begin
         IR.Prepare (Unit, Meanings.all);
         Left := IR.Add_Nominal_Type (Unit, 1);
         Right := IR.Add_Nominal_Type (Unit, 1);
         Signature := IR.Add_Signature
           (Unit,
            [1 => (Kind => Landin.Types.Aggregate,
                   Nominal => Left, others => <>)],
            (Kind => Landin.Types.U32, others => <>));
         Routine := IR.Add_Item
           (Unit, IR.Routine, 1, Landin.Types.U32, Site);
         IR.Set_Signature (Unit, Routine, Signature);
         Parameter := IR.Add_Aggregate_Parameter
           (Unit, Routine, 2, Site, Right);
         IR.Add_Slot_Field (Unit, Routine, Parameter, Landin.Types.U32);
         Block := IR.Add_Block
           (Unit, Routine, Landin.Resolution.Program_Scope, Site);
         IR.Enter (Unit, Routine, Block);
         Value := IR.Emit_Number
           (Unit, Routine, Landin.Types.U32, 1, False, Site);
         IR.Emit_Leave (Unit, Routine, Value, Site);
         IR.Leave_Block (Unit, Routine);

         Expect
           (Item, V.Check (Unit), V.Routine_Signature_Disagrees,
            "same-template same-layout instances remain unequal");
      end;
   end Same_Layout_Nominals_Do_Not_Agree_In_Signatures;

   procedure Nominal_Aggregate_Routine_Metadata_Is_Checked
     (Item : in out Landin.Testing.Context);

   procedure Nominal_Aggregate_Routine_Metadata_Is_Checked
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Site : Landin.Provenance.Origin;

      procedure Finish_Routine
        (Unit : in out IR.Unit; Routine : IR.Item_Id);

      procedure Finish_Routine
        (Unit : in out IR.Unit; Routine : IR.Item_Id)
      is
         Block : constant IR.Block_Id :=
           IR.Add_Block
             (Unit, Routine, Landin.Resolution.Program_Scope, Site);
      begin
         IR.Enter (Unit, Routine, Block);
         IR.Emit_Leave (Unit, Routine, IR.No_Value, Site);
         IR.Leave_Block (Unit, Routine);
      end Finish_Routine;
   begin
      Ready (Work, Site);
      declare
         Meanings : constant not null access Landin.Resolution.Table :=
           Landin.Stages.Meanings (Work);
      begin
         --  Exact regression: the signature and result slot say Left while
         --  the routine item says Right.  Equal field trees cannot reconcile
         --  the two nominal identities.
         declare
            Unit : IR.Unit;
            Left, Right : IR.Nominal_Type_Id;
            Signature : IR.Signature_Id;
            Routine : IR.Item_Id;
            Hidden, Result : IR.Slot_Id;
         begin
            IR.Prepare (Unit, Meanings.all);
            Left := IR.Add_Nominal_Type (Unit, 3);
            Right := IR.Add_Nominal_Type (Unit, 4);
            Signature := IR.Add_Signature
              (Unit, IR.No_Signature_Parts,
               (Kind => Landin.Types.Aggregate,
                Nominal => Left, others => <>));
            Routine := IR.Add_Item
              (Unit, IR.Routine, 1, Landin.Types.Aggregate, Site, Right);
            IR.Set_Signature (Unit, Routine, Signature);
            Hidden := IR.Add_Parameter
              (Unit, Routine, Landin.Types.Usize, 1, Site);
            pragma Unreferenced (Hidden);
            Result := IR.Add_Aggregate_Slot
              (Unit, Routine, 2, Site, Left);
            IR.Add_Slot_Field
              (Unit, Routine, Result, Landin.Types.U32);
            IR.Set_Result_Slot (Unit, Routine, Result);
            Finish_Routine (Unit, Routine);

            Expect
              (Item, V.Check (Unit), V.Routine_Signature_Disagrees,
               "a Right routine cannot carry a Left result signature"
               & " and slot");
         end;

         declare
            Unit : IR.Unit;
            Nominal : IR.Nominal_Type_Id;
            Signature : IR.Signature_Id;
            Routine : IR.Item_Id;
            Hidden, Result : IR.Slot_Id;
         begin
            IR.Prepare (Unit, Meanings.all);
            Nominal := IR.Add_Nominal_Type (Unit, 3);
            Signature := IR.Add_Signature
              (Unit, IR.No_Signature_Parts,
               (Kind => Landin.Types.Aggregate,
                Nominal => Nominal, others => <>));
            Routine := IR.Add_Item
              (Unit, IR.Routine, 1, Landin.Types.Aggregate, Site, Nominal);
            IR.Set_Signature (Unit, Routine, Signature);
            Hidden := IR.Add_Parameter
              (Unit, Routine, Landin.Types.Usize, 1, Site);
            pragma Unreferenced (Hidden);
            Result := IR.Add_Aggregate_Slot
              (Unit, Routine, 2, Site, Nominal);
            IR.Add_Slot_Field
              (Unit, Routine, Result, Landin.Types.U32);
            IR.Set_Result_Slot (Unit, Routine, Result);
            Finish_Routine (Unit, Routine);

            Expect
              (Item, V.Check (Unit), V.Nothing_Wrong,
               "one nominal aggregate result agrees across its routine,"
               & " signature and slot");
         end;

         declare
            Unit : IR.Unit;
            Signature : IR.Signature_Id;
            Routine : IR.Item_Id;
            Hidden, Result : IR.Slot_Id;
         begin
            IR.Prepare (Unit, Meanings.all);
            Signature := IR.Add_Signature_With_Results
              (Unit, IR.No_Signature_Parts,
               [(Kind => Landin.Types.U32, others => <>),
                (Kind => Landin.Types.Bool, others => <>)]);
            Routine := IR.Add_Item
              (Unit, IR.Routine, 1, Landin.Types.Aggregate, Site);
            IR.Set_Signature (Unit, Routine, Signature);
            Hidden := IR.Add_Parameter
              (Unit, Routine, Landin.Types.Usize, 1, Site);
            pragma Unreferenced (Hidden);
            Result := IR.Add_Aggregate_Slot
              (Unit, Routine, IR.No_Declaration, Site);
            IR.Add_Slot_Field
              (Unit, Routine, Result, Landin.Types.U32);
            IR.Add_Slot_Field
              (Unit, Routine, Result, Landin.Types.Bool);
            IR.Set_Result_Slot (Unit, Routine, Result);
            Finish_Routine (Unit, Routine);

            Expect
              (Item, V.Check (Unit), V.Nothing_Wrong,
               "an anonymous multiple-result aggregate remains structural");
         end;
      end;
   end Nominal_Aggregate_Routine_Metadata_Is_Checked;

   procedure Nominal_Root_Metadata_Is_Checked
     (Item : in out Landin.Testing.Context);

   procedure Nominal_Root_Metadata_Is_Checked
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
         Nominal : IR.Nominal_Type_Id;
         Routine : IR.Item_Id;
         Slot : IR.Slot_Id;
      begin
         IR.Prepare (Unit, Meanings.all);
         Nominal := IR.Add_Nominal_Type (Unit, 4);
         Landin.Testing.Check
           (Item,
            IR.Nominal_Identities.Nth (Unit, 2) = IR.No_Nominal_Type,
            "IR enumeration cannot construct an identity outside the unit");
         Routine := IR.Add_Item
           (Unit, IR.Routine, 1, Landin.Types.No_Value, Site);
         Slot := IR.Add_Slot
           (Unit, Routine, Landin.Types.U32, 2, Site);

         Landin.IR.Testing_Support.Overwrite_Item_Nominal
           (Unit, Routine, Nominal);
         Expect
           (Item, V.Check (Unit), V.Nominal_Metadata_Malformed,
            "a nonaggregate item cannot carry nominal metadata");

         Landin.IR.Testing_Support.Overwrite_Item_Nominal
           (Unit, Routine, IR.No_Nominal_Type);
         Landin.IR.Testing_Support.Overwrite_Slot_Nominal
           (Unit, Routine, Slot, Nominal);
         Expect
           (Item, V.Check (Unit), V.Nominal_Metadata_Malformed,
            "a nonaggregate slot cannot carry nominal metadata");
      end;
   end Nominal_Root_Metadata_Is_Checked;

   procedure Nominal_Shapes_Are_Canonical
     (Item : in out Landin.Testing.Context);

   procedure Nominal_Shapes_Are_Canonical
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

         procedure Finish_Datum
           (Unit : in out IR.Unit; Datum : IR.Item_Id);

         procedure Finish_Datum
           (Unit : in out IR.Unit; Datum : IR.Item_Id)
         is
            Block : constant IR.Block_Id :=
              IR.Add_Block
                (Unit, Datum, Landin.Resolution.Program_Scope, Site);
         begin
            IR.Enter (Unit, Datum, Block);
            IR.Emit_Leave (Unit, Datum, IR.No_Value, Site);
            IR.Leave_Block (Unit, Datum);
         end Finish_Datum;

         procedure Add_Nested_Field
           (Unit    : in out IR.Unit;
            Datum   : IR.Item_Id;
            Nominal : IR.Nominal_Type_Id;
            Scalar  : Landin.Types.Scalar_Name);

         procedure Add_Nested_Field
           (Unit    : in out IR.Unit;
            Datum   : IR.Item_Id;
            Nominal : IR.Nominal_Type_Id;
            Scalar  : Landin.Types.Scalar_Name) is
         begin
            IR.Add_Field
              (Unit, Datum,
               (Kind           => IR.Aggregate_Field_Shape,
                Cases          => 1,
                Payloads_First => 1,
                Nominal        => Nominal,
                others         => <>),
               Cases => IR.No_Case_Runs,
               Payloads =>
                 [1 => (Kind => IR.Scalar_Field_Shape,
                        Element => Scalar, others => <>)]);
         end Add_Nested_Field;
      begin
         declare
            Unit : IR.Unit;
            Left_Nominal, Right_Nominal : IR.Nominal_Type_Id;
            Left, Right : IR.Item_Id;
         begin
            IR.Prepare (Unit, Meanings.all);
            Left_Nominal := IR.Add_Nominal_Type (Unit, 3);
            Right_Nominal := IR.Add_Nominal_Type (Unit, 4);
            Left := IR.Add_Item
              (Unit, IR.Datum, 1, Landin.Types.Aggregate, Site,
               Left_Nominal);
            Right := IR.Add_Item
              (Unit, IR.Datum, 2, Landin.Types.Aggregate, Site,
               Right_Nominal);
            IR.Add_Field (Unit, Left, Landin.Types.U32);
            IR.Add_Field (Unit, Right, Landin.Types.U32);
            Finish_Datum (Unit, Left);
            Finish_Datum (Unit, Right);

            Expect
              (Item, V.Check (Unit), V.Nothing_Wrong,
               "unequal nominal identities may have equal field trees");
         end;

         declare
            Unit : IR.Unit;
            Nominal : IR.Nominal_Type_Id;
            Left, Right : IR.Item_Id;
         begin
            IR.Prepare (Unit, Meanings.all);
            Nominal := IR.Add_Nominal_Type (Unit, 3);
            Left := IR.Add_Item
              (Unit, IR.Datum, 1, Landin.Types.Aggregate, Site, Nominal);
            Right := IR.Add_Item
              (Unit, IR.Datum, 2, Landin.Types.Aggregate, Site, Nominal);
            IR.Add_Field (Unit, Left, Landin.Types.U8);
            IR.Add_Field (Unit, Right, Landin.Types.U16);
            Finish_Datum (Unit, Left);
            Finish_Datum (Unit, Right);

            Expect
              (Item, V.Check (Unit), V.Nominal_Shape_Disagrees,
               "one nominal identity cannot name two root field trees");
         end;

         declare
            Unit : IR.Unit;
            Nominal : IR.Nominal_Type_Id;
            Datum, Routine : IR.Item_Id;
            Slot : IR.Slot_Id;
         begin
            IR.Prepare (Unit, Meanings.all);
            Nominal := IR.Add_Nominal_Type (Unit, 3);
            Datum := IR.Add_Item
              (Unit, IR.Datum, 1, Landin.Types.Aggregate, Site, Nominal);
            Routine := IR.Add_Item
              (Unit, IR.Routine, 2, Landin.Types.No_Value, Site);
            Slot := IR.Add_Aggregate_Slot
              (Unit, Routine, IR.No_Declaration, Site, Nominal);
            IR.Add_Field (Unit, Datum, Landin.Types.U8);
            IR.Add_Slot_Field (Unit, Routine, Slot, Landin.Types.U16);
            Finish_Datum (Unit, Datum);
            Finish_Datum (Unit, Routine);

            Expect
              (Item, V.Check (Unit), V.Nominal_Shape_Disagrees,
               "item and slot roots cannot disagree for one nominal identity");
         end;

         declare
            Unit : IR.Unit;
            Parent, Child : IR.Nominal_Type_Id;
            Left, Right : IR.Item_Id;
         begin
            IR.Prepare (Unit, Meanings.all);
            Parent := IR.Add_Nominal_Type (Unit, 3);
            Child := IR.Add_Nominal_Type (Unit, 4);
            Left := IR.Add_Item
              (Unit, IR.Datum, 1, Landin.Types.Aggregate, Site, Parent);
            Right := IR.Add_Item
              (Unit, IR.Datum, 2, Landin.Types.Aggregate, Site, Parent);
            Add_Nested_Field (Unit, Left, Child, Landin.Types.U8);
            Add_Nested_Field (Unit, Right, Child, Landin.Types.U16);
            Finish_Datum (Unit, Left);
            Finish_Datum (Unit, Right);

            Expect
              (Item, V.Check (Unit), V.Nominal_Shape_Disagrees,
               "nested occurrences retain one nominal field tree");
         end;

         declare
            Unit : IR.Unit;
            Child : IR.Nominal_Type_Id;
            Left, Right : IR.Item_Id;
            Left_First, Right_First : Natural;
         begin
            IR.Prepare (Unit, Meanings.all);
            Child := IR.Add_Nominal_Type (Unit, 4);
            Left := IR.Add_Item
              (Unit, IR.Datum, 1, Landin.Types.Fixed_Array, Site);
            Right := IR.Add_Item
              (Unit, IR.Datum, 2, Landin.Types.Fixed_Array, Site);
            Left_First := IR.Add_Shape_Run
              (Unit, [1 => (Kind => IR.Scalar_Field_Shape,
                            Element => Landin.Types.U8, others => <>)]);
            IR.Set_Array
              (Unit, Left,
               (Kind           => IR.Aggregate_Field_Shape,
                Cases          => 1,
                Payloads_First => Left_First,
                Nominal        => Child,
                others         => <>),
               2);
            Right_First := IR.Add_Shape_Run
              (Unit, [1 => (Kind => IR.Scalar_Field_Shape,
                            Element => Landin.Types.U16, others => <>)]);
            IR.Set_Array
              (Unit, Right,
               (Kind           => IR.Aggregate_Field_Shape,
                Cases          => 1,
                Payloads_First => Right_First,
                Nominal        => Child,
                others         => <>),
               2);
            Finish_Datum (Unit, Left);
            Finish_Datum (Unit, Right);

            Expect
              (Item, V.Check (Unit), V.Nominal_Shape_Disagrees,
               "array element occurrences retain one nominal field tree");
         end;
      end;
   end Nominal_Shapes_Are_Canonical;

   ------------------------------------------------------------------

   type Damage is
     (No_Terminator,
      Terminator_In_The_Middle,
      No_Block_At_All,
      Left_Open,
      Operand_From_Another_Block,
      Result_Of_The_Wrong_Type,
      Measurement_Result_Is_Not_Usize,
      Scalar_Measurement_Length_Is_Not_One,
      Aggregate_Measurement_Run_Overflows,
      Variant_Measurement_Tag_Is_Signed,
      Variant_Measurement_Case_Run_Overflows,
      Variant_Datum_Tag_Is_Signed,
      Variant_Slot_Case_Run_Overflows,
      Aggregate_Scalar_Length_Is_Not_One,
      Slot_Scalar_Length_Is_Not_One,
      Operands_Of_Two_Types,
      Store_Of_The_Wrong_Type,
      Store_To_A_Parameter,
      Callee_Is_A_Datum,
      Datum_Load_Names_A_Routine,
      Datum_Load_Names_An_Aggregate,
      Storage_Address_Names_A_Scalar,
      Storage_Address_Nested_Field_Beyond_The_Child,
      Field_Beyond_The_Aggregate,
      Nested_Field_Beyond_The_Child,
      Path_Step_Below_A_Scalar_Leaf,
      Variant_Path_Reaches_A_Scalar,
      Whole_Element_Beyond_The_Array,
      Element_Path_Below_A_Scalar_Element,
      Nested_Element_Beyond_The_Child,
      Field_Operation_Names_An_Array,
      Field_Store_Names_An_Array,
      Slot_Field_Operation_Names_An_Array,
      Slot_Field_Store_Names_An_Array,
      Field_Store_Of_The_Wrong_Type,
      Local_Array_Part_Is_Out_Of_Range,
      Local_Array_Load_Has_The_Wrong_Type,
      Local_Array_Store_Has_The_Wrong_Type,
      Element_Datum_Is_Not_An_Array,
      Element_Datum_Field_Is_Out_Of_Range,
      Element_Datum_Field_Is_Not_An_Array,
      Element_Index_Is_Not_Usize,
      Element_Load_Of_The_Wrong_Type,
      Element_Store_Of_The_Wrong_Type,
      Slot_Element_Reaches_A_Nonarray_Slot,
      Slot_Element_Field_Is_Out_Of_Range,
      Slot_Element_Field_Is_Not_An_Array,
      Slot_Element_Load_Of_The_Wrong_Type,
      Slot_Element_Store_Of_The_Wrong_Type,
      Array_Copy_Endpoint_Is_Scalar,
      Array_Copy_Aggregate_Is_Not_An_Array,
      Array_Copy_Lengths_Disagree,
      Array_Copy_Elements_Disagree,
      Array_Copy_Source_Field_Is_Out_Of_Range,
      Array_Copy_Source_Field_Is_Not_An_Array,
      Nested_Array_Copy_Source_Beyond_The_Child,
      Array_Copy_Destination_Field_Is_Out_Of_Range,
      Array_Copy_Destination_Field_Is_Not_An_Array,
      Array_Copy_Field_Shape_Disagrees,
      Array_Copy_Slot_Is_Not_Owned,
      Array_Copy_Inside_A_Datum,
      Array_Clear_Destination_Is_Scalar,
      Array_Clear_Slot_Is_Not_Owned,
      Array_Clear_Datum_Field_Is_Out_Of_Range,
      Array_Clear_Datum_Field_Is_Not_An_Array,
      Array_Clear_Slot_Field_Is_Out_Of_Range,
      Array_Clear_Slot_Field_Is_Not_An_Array,
      Array_Clear_Inside_A_Datum,
      Array_Fill_Destination_Is_Scalar,
      Array_Fill_Aggregate_Is_Not_An_Array,
      Array_Fill_Slot_Is_Not_Owned,
      Array_Fill_Datum_Field_Is_Out_Of_Range,
      Array_Fill_Datum_Field_Is_Not_An_Array,
      Array_Fill_Slot_Field_Is_Out_Of_Range,
      Array_Fill_Slot_Field_Is_Not_An_Array,
      Array_Fill_Value_Has_The_Wrong_Type,
      Array_Fill_First_Is_Outside_Array,
      Array_Fill_Field_First_Is_Outside_Array,
      Array_Fill_Inside_A_Datum,
      Unchecked_Inside_A_Datum,
      Range_Check_Bound_Is_Not_A_Value_Of_The_Type,
      Condition_Is_A_Number,
      Function_Signature_Part_Is_Malformed,
      Function_Parameter_Uses_A_Different_Signature,
      Function_Datum_Uses_A_Different_Signature,
      Call_Missing_An_Argument,
      Indirect_Call_Uses_A_Different_Signature,
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
      S, P, Q, R, T : IR.Slot_Id;
      B, C : IR.Block_Id;
      N, M : IR.Value_Id;
      Parameter_Signature : IR.Signature_Id := IR.No_Signature;
   begin
      if Harm = Function_Signature_Part_Is_Malformed then
         declare
            Ignored : constant IR.Signature_Id :=
              IR.Add_Signature
                (Unit,
                 [(Kind => Landin.Types.Function_Value, others => <>)],
                 (Kind => Landin.Types.U32, others => <>));
         begin
            pragma Unreferenced (Ignored);
         end;
      end if;

      A := IR.Add_Item (Unit, IR.Routine, 1, Landin.Types.U32, Site);
      if Harm in Call_Missing_An_Argument
                   | Indirect_Call_Uses_A_Different_Signature
                   | Function_Datum_Uses_A_Different_Signature
      then
         declare
            Signature : constant IR.Signature_Id :=
              IR.Add_Signature
                (Unit,
                 [(Kind => Landin.Types.U32, others => <>)],
                 (Kind => Landin.Types.U32, others => <>));
         begin
            IR.Set_Signature (Unit, A, Signature);
         end;
      elsif Harm = Function_Parameter_Uses_A_Different_Signature then
         declare
            Expected : constant IR.Signature_Id :=
              IR.Add_Signature
                (Unit, IR.No_Signature_Parts,
                 (Kind => Landin.Types.U32, others => <>));
            Other : constant IR.Signature_Id :=
              IR.Add_Signature
                (Unit, IR.No_Signature_Parts,
                 (Kind => Landin.Types.Bool, others => <>));
            Outer : constant IR.Signature_Id :=
              IR.Add_Signature
                (Unit,
                 [(Kind      => Landin.Types.Function_Value,
                   Signature => Expected,
                   others    => <>)],
                 (Kind => Landin.Types.U32, others => <>));
         begin
            IR.Set_Signature (Unit, A, Outer);
            Parameter_Signature := Other;
         end;
      end if;
      --  E precedes the deliberately blockless helper datums so the
      --  datum-copy case reaches the instruction it is about first.
      E := IR.Add_Item
        (Unit, IR.Datum, 6,
         (if Harm = Array_Clear_Inside_A_Datum
          then Landin.Types.Aggregate else Landin.Types.Fixed_Array),
         Site);
      if Harm = Array_Clear_Inside_A_Datum then
         IR.Add_Field (Unit, E, Landin.Types.U32);
      else
         IR.Set_Array (Unit, E, Landin.Types.U32, 4);
      end if;
      D := IR.Add_Item
        (Unit, IR.Datum, 3,
         (if Harm = Function_Datum_Uses_A_Different_Signature
          then Landin.Types.Usize else Landin.Types.U32),
         Site);
      if Harm = Function_Datum_Uses_A_Different_Signature then
         declare
            Other : constant IR.Signature_Id :=
              IR.Add_Signature
                (Unit, IR.No_Signature_Parts,
                 (Kind => Landin.Types.U32, others => <>));
         begin
            IR.Set_Signature (Unit, D, Other);
            IR.Set_Function_Target (Unit, D, A);
         end;
      end if;
      G := IR.Add_Item (Unit, IR.Datum, 5, Landin.Types.Aggregate, Site);
      if Harm = Variant_Datum_Tag_Is_Signed then
         IR.Add_Field
           (Unit, G,
            (Kind           => IR.Variant_Field_Shape,
             Element        => Landin.Types.I8,
             Length         => 1,
             Cases          => 1,
             Payloads_First => 1,
             others         => <>));
      elsif Harm in Nested_Field_Beyond_The_Child
                    | Path_Step_Below_A_Scalar_Leaf
                    | Variant_Path_Reaches_A_Scalar
                    | Nested_Element_Beyond_The_Child
                    | Nested_Array_Copy_Source_Beyond_The_Child
                    | Storage_Address_Nested_Field_Beyond_The_Child
      then
         IR.Add_Field
           (Unit, G,
            (Kind           => IR.Aggregate_Field_Shape,
             Element        => Landin.Types.Bool,
             Length         => 1,
             Cases          => 1,
             Payloads_First => 1,
             Nominal        => Test_Nominal (Unit),
             others         => <>),
            IR.No_Case_Runs,
            [(Kind    => IR.Scalar_Field_Shape,
              Element => Landin.Types.U32,
              Length  => 1,
              others  => <>)]);
      elsif Harm = Aggregate_Scalar_Length_Is_Not_One then
         IR.Add_Field
           (Unit, G,
            (Kind    => IR.Scalar_Field_Shape,
             Element => Landin.Types.U32,
             Length  => 2,
             others => <>));
      elsif Harm in Field_Operation_Names_An_Array
                    | Field_Store_Names_An_Array
                    | Array_Copy_Field_Shape_Disagrees
      then
         IR.Add_Field
           (Unit, G,
            (Kind    => IR.Array_Field_Shape,
             Element => Landin.Types.U32,
             Length  => 2,
             others => <>));
      else
         IR.Add_Field (Unit, G, Landin.Types.U32);
      end if;

      if Harm = No_Block_At_All then
         return V.Check (Unit);
      end if;

      P := IR.Add_Parameter
        (Unit, A,
         (if Harm = Function_Parameter_Uses_A_Different_Signature
          then Landin.Types.Usize else Landin.Types.U32),
         2, Site, Signature => Parameter_Signature);
      S := IR.Add_Slot (Unit, A, Landin.Types.U32, 4, Site);
      Q := IR.Add_Array_Slot
        (Unit, A, Landin.Types.U32, 4, IR.No_Declaration, Site);
      R := IR.Add_Array_Slot
        (Unit, A,
         (if Harm = Array_Copy_Elements_Disagree
          then Landin.Types.U16 else Landin.Types.U32),
         (if Harm = Array_Copy_Lengths_Disagree then 5 else 4),
         IR.No_Declaration, Site);
      T := IR.Add_Aggregate_Slot
        (Unit, A, IR.No_Declaration, Site);
      if Harm = Variant_Slot_Case_Run_Overflows then
         IR.Add_Slot_Field
           (Unit, A, T,
            (Kind           => IR.Variant_Field_Shape,
             Element        => Landin.Types.U8,
             Length         => 1,
             Cases          => Natural'Last,
             Payloads_First => 1,
             others         => <>));
      elsif Harm = Slot_Scalar_Length_Is_Not_One then
         IR.Add_Slot_Field
           (Unit, A, T,
            (Kind    => IR.Scalar_Field_Shape,
             Element => Landin.Types.U32,
             Length  => 2,
             others => <>));
      elsif Harm in Slot_Field_Operation_Names_An_Array
                    | Slot_Field_Store_Names_An_Array
                    | Array_Fill_Field_First_Is_Outside_Array
      then
         IR.Add_Slot_Field
           (Unit, A, T,
            (Kind    => IR.Array_Field_Shape,
             Element => Landin.Types.U32,
             Length  => 2,
             others => <>));
      else
         IR.Add_Slot_Field (Unit, A, T, Landin.Types.U32);
      end if;
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

         when Measurement_Result_Is_Not_Usize =>
            N := IR.Emit_Aggregate_Measurement
              (Unit, A, IR.Measure_Size,
               [(Kind    => IR.Scalar_Field_Shape,
                 Element => Landin.Types.U8,
                 Length  => 1,
             others => <>),
                (Kind    => IR.Scalar_Field_Shape,
                 Element => Landin.Types.U32,
                 Length  => 1,
             others => <>)],
               Landin.Types.U32, Site);
            pragma Assert (N /= IR.No_Value);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Scalar_Measurement_Length_Is_Not_One =>
            N := IR.Emit_Aggregate_Measurement
              (Unit, A, IR.Measure_Size,
               [(Kind    => IR.Scalar_Field_Shape,
                 Element => Landin.Types.U8,
                 Length  => 2,
             others => <>)],
               Landin.Types.Usize, Site);
            pragma Assert (N /= IR.No_Value);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Aggregate_Measurement_Run_Overflows =>
            N := IR.Emit_Aggregate_Measurement
              (Unit, A, IR.Measure_Size,
               [(Kind           => IR.Aggregate_Field_Shape,
                 Element        => Landin.Types.Bool,
                 Length         => 1,
                 Cases          => Natural'Last,
                 Payloads_First => 1,
                 Nominal        => Test_Nominal (Unit),
                 others         => <>)],
               Landin.Types.Usize, Site,
               Payloads =>
                 [(Kind    => IR.Scalar_Field_Shape,
                   Element => Landin.Types.U8,
                   Length  => 1,
                   others  => <>)]);
            pragma Assert (N /= IR.No_Value);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Variant_Measurement_Tag_Is_Signed =>
            N := IR.Emit_Aggregate_Measurement
              (Unit, A, IR.Measure_Size,
               [(Kind           => IR.Variant_Field_Shape,
                 Element        => Landin.Types.I8,
                 Length         => 1,
                 Cases          => 1,
                 Payloads_First => 1,
                 others         => <>)],
               Landin.Types.Usize, Site,
               Cases => [(First => 0, Count => 0)]);
            pragma Assert (N /= IR.No_Value);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Variant_Measurement_Case_Run_Overflows =>
            N := IR.Emit_Aggregate_Measurement
              (Unit, A, IR.Measure_Size,
               [(Kind           => IR.Variant_Field_Shape,
                 Element        => Landin.Types.U8,
                 Length         => 1,
                 Cases          => Natural'Last,
                 Payloads_First => 1,
                 others         => <>)],
               Landin.Types.Usize, Site,
               Cases => [(First => 0, Count => 0)]);
            pragma Assert (N /= IR.No_Value);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Aggregate_Scalar_Length_Is_Not_One
            | Variant_Datum_Tag_Is_Signed =>
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Slot_Scalar_Length_Is_Not_One
            | Variant_Slot_Case_Run_Overflows =>
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

         when Storage_Address_Names_A_Scalar =>
            N := IR.Emit_Storage_Address
              (Unit, A, (Kind => IR.Module_Datum, Datum => D), Site);
            pragma Assert (N /= IR.No_Value);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Storage_Address_Nested_Field_Beyond_The_Child =>
            N := IR.Emit_Storage_Address
              (Unit, A, (Kind => IR.Module_Datum, Datum => G), Site,
               Field => 1, Nested => Below (2));
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

         when Nested_Field_Beyond_The_Child =>
            N := IR.Emit_Load_Field
                   (Unit, A, G, 1, Landin.Types.U32, Site,
                    Nested => Below (2));
            pragma Assert (N /= IR.No_Value);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         --  D118 lets a path have more than one step, so it also has to
         --  refuse one that keeps going below a leaf that has no run.
         when Path_Step_Below_A_Scalar_Leaf =>
            N := IR.Emit_Load_Field
                   (Unit, A, G, 1, Landin.Types.U32, Site,
                    Nested => [(Field => 1, Case_Index => 0),
                               (Field => 1, Case_Index => 0)]);
            pragma Assert (N /= IR.No_Value);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         --  D121 lets an indexed operation carry a run inside the
         --  element, so it also has to refuse one below a scalar element.
         --  E is `[4]u32`, whose element has no field to select.
         when Element_Path_Below_A_Scalar_Element =>
            N := IR.Emit_Number
                   (Unit, A, Landin.Types.Usize, 1, False, Site);
            M := IR.Emit_Load_Element
                   (Unit, A, E, N, Landin.Types.U32, Site,
                    Below => Below (1));
            pragma Assert (M /= IR.No_Value);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         --  D127 lets a run start at whole array storage, so it also has
         --  to refuse one whose first step is past the array's own length.
         --  Q is a local `[4]u32` and there is no ninth element.
         when Whole_Element_Beyond_The_Array =>
            IR.Emit_Array_Clear
              (Unit, A,
               Destination => (Kind => IR.Frame_Slot, Slot => Q),
               Site        => Site,
               Field       => 0,
               Nested      => [(Field => 9, Case_Index => 0)]);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         --  D126 lets a variant operation name its part through a run,
         --  so it also has to refuse one whose run reaches something that
         --  is not a variant part.  G's field 1 holds one U32 child.
         when Variant_Path_Reaches_A_Scalar =>
            N := IR.Emit_Variant_Tag_Load
                   (Unit, A, (Kind => IR.Module_Datum, Datum => G), 1,
                    Landin.Types.U8, Site, Nested => Below (1));
            pragma Assert (N /= IR.No_Value);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Nested_Element_Beyond_The_Child =>
            N := IR.Emit_Number
                   (Unit, A, Landin.Types.Usize, 1, False, Site);
            M := IR.Emit_Load_Element
                   (Unit, A, G, N, Landin.Types.U32, Site,
                    Field => 1, Nested => Below (2));
            pragma Assert (M /= IR.No_Value);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Field_Operation_Names_An_Array =>
            N := IR.Emit_Load_Field
                   (Unit, A, G, 1, Landin.Types.U32, Site);
            pragma Assert (N /= IR.No_Value);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Field_Store_Names_An_Array =>
            N := IR.Emit_Number
                   (Unit, A, Landin.Types.U32, 1, False, Site);
            IR.Emit_Store_Field (Unit, A, G, 1, N, Site);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Slot_Field_Operation_Names_An_Array =>
            N := IR.Emit_Load_Slot_Field
                   (Unit, A, T, 1, Landin.Types.U32, Site);
            pragma Assert (N /= IR.No_Value);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Slot_Field_Store_Names_An_Array =>
            N := IR.Emit_Number
                   (Unit, A, Landin.Types.U32, 1, False, Site);
            IR.Emit_Store_Slot_Field (Unit, A, T, 1, N, Site);
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

         when Element_Datum_Field_Is_Out_Of_Range
            | Element_Datum_Field_Is_Not_An_Array =>
            N := IR.Emit_Number
                   (Unit, A, Landin.Types.Usize, 1, False, Site);
            M := IR.Emit_Load_Element
                   (Unit, A, G, N, Landin.Types.U32, Site,
                    Field =>
                      (if Harm = Element_Datum_Field_Is_Out_Of_Range
                       then 2 else 1));
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

         when Slot_Element_Field_Is_Out_Of_Range
            | Slot_Element_Field_Is_Not_An_Array =>
            N := IR.Emit_Number
                   (Unit, A, Landin.Types.Usize, 1, False, Site);
            M := IR.Emit_Load_Slot_Element
                   (Unit, A, T, N, Landin.Types.U32, Site,
                    Field =>
                      (if Harm = Slot_Element_Field_Is_Out_Of_Range
                       then 2 else 1));
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

         when Array_Copy_Aggregate_Is_Not_An_Array =>
            IR.Emit_Array_Copy
              (Unit, A, (Kind => IR.Frame_Slot, Slot => T),
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

         when Array_Copy_Source_Field_Is_Out_Of_Range
            | Array_Copy_Source_Field_Is_Not_An_Array =>
            IR.Emit_Array_Copy
              (Unit, A, (Kind => IR.Module_Datum, Datum => G),
               (Kind => IR.Frame_Slot, Slot => Q), Site,
               Source_Field =>
                 (if Harm = Array_Copy_Source_Field_Is_Out_Of_Range
                  then 2 else 1));
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Nested_Array_Copy_Source_Beyond_The_Child =>
            IR.Emit_Array_Copy
              (Unit, A, (Kind => IR.Module_Datum, Datum => G),
               (Kind => IR.Frame_Slot, Slot => Q), Site,
               Source_Field => 1, Source_Nested => Below (2));
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Array_Copy_Destination_Field_Is_Out_Of_Range
            | Array_Copy_Destination_Field_Is_Not_An_Array =>
            IR.Emit_Array_Copy
              (Unit, A, (Kind => IR.Frame_Slot, Slot => Q),
               (Kind => IR.Frame_Slot, Slot => T), Site,
               Destination_Field =>
                 (if Harm = Array_Copy_Destination_Field_Is_Out_Of_Range
                  then 2 else 1));
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Array_Copy_Field_Shape_Disagrees =>
            IR.Emit_Array_Copy
              (Unit, A, (Kind => IR.Module_Datum, Datum => G),
               (Kind => IR.Frame_Slot, Slot => Q), Site,
               Source_Field => 1);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Array_Copy_Slot_Is_Not_Owned =>
            IR.Emit_Array_Copy
              (Unit, A, (Kind => IR.Frame_Slot, Slot => 6),
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
              (Unit, A, (Kind => IR.Frame_Slot, Slot => 6), Site);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Array_Clear_Datum_Field_Is_Out_Of_Range
            | Array_Clear_Datum_Field_Is_Not_An_Array =>
            IR.Emit_Array_Clear
              (Unit, A, (Kind => IR.Module_Datum, Datum => G), Site,
               Field =>
                 (if Harm = Array_Clear_Datum_Field_Is_Out_Of_Range
                  then 2 else 1));
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Array_Clear_Slot_Field_Is_Out_Of_Range
            | Array_Clear_Slot_Field_Is_Not_An_Array =>
            IR.Emit_Array_Clear
              (Unit, A, (Kind => IR.Frame_Slot, Slot => T), Site,
               Field =>
                 (if Harm = Array_Clear_Slot_Field_Is_Out_Of_Range
                  then 2 else 1));
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
              (Unit, A, (Kind => IR.Frame_Slot, Slot => S), 1, N, Site);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Array_Fill_Aggregate_Is_Not_An_Array =>
            N := IR.Emit_Number
              (Unit, A, Landin.Types.U32, 1, False, Site);
            IR.Emit_Array_Fill
              (Unit, A, (Kind => IR.Frame_Slot, Slot => T), 1, N, Site);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Array_Fill_Slot_Is_Not_Owned =>
            N := IR.Emit_Number
              (Unit, A, Landin.Types.U32, 1, False, Site);
            IR.Emit_Array_Fill
              (Unit, A, (Kind => IR.Frame_Slot, Slot => 6), 1, N, Site);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Array_Fill_Datum_Field_Is_Out_Of_Range
            | Array_Fill_Datum_Field_Is_Not_An_Array =>
            N := IR.Emit_Number
              (Unit, A, Landin.Types.U32, 1, False, Site);
            IR.Emit_Array_Fill
              (Unit, A, (Kind => IR.Module_Datum, Datum => G), 1, N, Site,
               Field =>
                 (if Harm = Array_Fill_Datum_Field_Is_Out_Of_Range
                  then 2 else 1));
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Array_Fill_Slot_Field_Is_Out_Of_Range
            | Array_Fill_Slot_Field_Is_Not_An_Array =>
            N := IR.Emit_Number
              (Unit, A, Landin.Types.U32, 1, False, Site);
            IR.Emit_Array_Fill
              (Unit, A, (Kind => IR.Frame_Slot, Slot => T), 1, N, Site,
               Field =>
                 (if Harm = Array_Fill_Slot_Field_Is_Out_Of_Range
                  then 2 else 1));
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Array_Fill_Value_Has_The_Wrong_Type =>
            N := IR.Emit_Truth (Unit, A, True, Site);
            IR.Emit_Array_Fill
              (Unit, A, (Kind => IR.Frame_Slot, Slot => Q), 1, N, Site);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Array_Fill_First_Is_Outside_Array =>
            N := IR.Emit_Number
              (Unit, A, Landin.Types.U16, 1, False, Site);
            IR.Emit_Array_Fill
              (Unit, A, (Kind => IR.Frame_Slot, Slot => Q),
               IR.Part_Position (4_294_967_296),
               N, Site);
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);

         when Array_Fill_Field_First_Is_Outside_Array =>
            N := IR.Emit_Number
              (Unit, A, Landin.Types.U32, 1, False, Site);
            IR.Emit_Array_Fill
              (Unit, A, (Kind => IR.Frame_Slot, Slot => T), 3, N, Site,
               Field => 1);
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
              (Unit, E, (Kind => IR.Module_Datum, Datum => E), 1, N, Site);
            IR.Emit_Leave (Unit, E, IR.No_Value, Site);
            IR.Leave_Block (Unit, E);

         --  D187: [1940]'s module value executes nothing, so no edge of
         --  its can be the one a region removes.  The opposite half of
         --  that rule -- the flag on an opcode carrying no removable
         --  edge -- cannot be built at all, because Append is the only
         --  writer and holds it to Check_Is_Removable itself.
         when Unchecked_Inside_A_Datum =>
            N := IR.Emit_Load (Unit, A, S, Site);
            IR.Emit_Leave (Unit, A, N, Site);
            IR.Leave_Block (Unit, A);
            B := IR.Add_Block
              (Unit, E, Landin.Resolution.Program_Scope, Site);
            IR.Enter (Unit, E, B);
            IR.Begin_Unchecked (Unit, E);
            N := IR.Emit_Number
              (Unit, E, Landin.Types.U32, 1, False, Site);
            N := IR.Emit_Binary
              (Unit, E, IR.Add, N, N, Landin.Types.U32, Site);
            IR.End_Unchecked (Unit, E);
            pragma Assert (IR.Is_Unchecked (Unit, E, N));
            IR.Emit_Leave (Unit, E, IR.No_Value, Site);
            IR.Leave_Block (Unit, E);

         --  D188: a bound the checked type does not hold would make the
         --  emitted comparison meaningless rather than merely redundant,
         --  so the verifier refuses it.  The other half -- a result type
         --  that is not its operand's -- cannot be built here, because
         --  Emit_Range_Check takes one type for both.
         when Range_Check_Bound_Is_Not_A_Value_Of_The_Type =>
            N := IR.Emit_Number
                   (Unit, A, Landin.Types.U8, 1, False, Site);
            N := IR.Emit_Range_Check
                   (Unit, A, N, Landin.Types.U8, 0, 300, Site);
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

         when Function_Signature_Part_Is_Malformed
            | Function_Parameter_Uses_A_Different_Signature
            | Function_Datum_Uses_A_Different_Signature =>
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

         when Indirect_Call_Uses_A_Different_Signature =>
            declare
               Other : constant IR.Signature_Id :=
                 IR.Add_Signature
                   (Unit, IR.No_Signature_Parts,
                    (Kind => Landin.Types.U32, others => <>));
            begin
               N := IR.Emit_Function_Address (Unit, A, A, Site);
               M := IR.Emit_Indirect_Call
                 (Unit, A, Other, Landin.Types.U32, Site);
               IR.Add_Argument (Unit, A, M, N);
               N := IR.Emit_Load (Unit, A, S, Site);
               IR.Emit_Leave (Unit, A, N, Site);
               IR.Leave_Block (Unit, A);
            end;

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
         (Measurement_Result_Is_Not_Usize, V.Result_Disagrees),
         (Scalar_Measurement_Length_Is_Not_One,
          V.Field_Shape_Malformed),
         (Aggregate_Measurement_Run_Overflows,
          V.Field_Shape_Malformed),
         (Variant_Measurement_Tag_Is_Signed,
          V.Field_Shape_Malformed),
         (Variant_Measurement_Case_Run_Overflows,
          V.Field_Shape_Malformed),
         (Variant_Datum_Tag_Is_Signed,
          V.Field_Shape_Malformed),
         (Variant_Slot_Case_Run_Overflows,
          V.Field_Shape_Malformed),
         (Aggregate_Scalar_Length_Is_Not_One,
          V.Field_Shape_Malformed),
         (Slot_Scalar_Length_Is_Not_One,
          V.Field_Shape_Malformed),
         (Operands_Of_Two_Types,      V.Operands_Disagree),
         (Store_Of_The_Wrong_Type,    V.Store_Disagrees_With_Slot),
         (Store_To_A_Parameter,       V.Store_To_A_Parameter),
         (Callee_Is_A_Datum,          V.Callee_Is_Not_A_Routine),
         (Datum_Load_Names_A_Routine, V.Named_Item_Is_Not_A_Datum),
         (Datum_Load_Names_An_Aggregate,
          V.Aggregate_Datum_Is_Not_A_Value),
         (Storage_Address_Names_A_Scalar,
          V.Storage_Address_Is_Not_An_Aggregate),
         (Storage_Address_Nested_Field_Beyond_The_Child,
          V.Element_Field_Is_Not_An_Array),
         (Field_Beyond_The_Aggregate, V.Field_Out_Of_Range),
         (Nested_Field_Beyond_The_Child, V.Field_Is_Not_A_Scalar),
         (Path_Step_Below_A_Scalar_Leaf, V.Field_Is_Not_A_Scalar),
         (Variant_Path_Reaches_A_Scalar,
          V.Variant_Field_Is_Not_A_Variant),
         (Whole_Element_Beyond_The_Array,
          V.Element_Field_Is_Not_An_Array),
         (Element_Path_Below_A_Scalar_Element,
          V.Element_Field_Is_Not_An_Array),
         (Nested_Element_Beyond_The_Child,
          V.Element_Field_Is_Not_An_Array),
         (Field_Operation_Names_An_Array, V.Field_Is_Not_A_Scalar),
         (Field_Store_Names_An_Array, V.Field_Is_Not_A_Scalar),
         (Slot_Field_Operation_Names_An_Array,
          V.Field_Is_Not_A_Scalar),
         (Slot_Field_Store_Names_An_Array,
          V.Field_Is_Not_A_Scalar),
         (Field_Store_Of_The_Wrong_Type, V.Store_Datum_Disagrees),
         (Local_Array_Part_Is_Out_Of_Range, V.Field_Out_Of_Range),
         (Local_Array_Load_Has_The_Wrong_Type, V.Result_Disagrees),
         (Local_Array_Store_Has_The_Wrong_Type,
          V.Store_Datum_Disagrees),
         (Element_Datum_Is_Not_An_Array,
          V.Element_Datum_Is_Not_An_Array),
         (Element_Datum_Field_Is_Out_Of_Range,
          V.Element_Field_Out_Of_Range),
         (Element_Datum_Field_Is_Not_An_Array,
          V.Element_Field_Is_Not_An_Array),
         (Element_Index_Is_Not_Usize, V.Element_Index_Is_Not_Usize),
         (Element_Load_Of_The_Wrong_Type, V.Result_Disagrees),
         (Element_Store_Of_The_Wrong_Type, V.Store_Datum_Disagrees),
         (Slot_Element_Reaches_A_Nonarray_Slot,
          V.Element_Datum_Is_Not_An_Array),
         (Slot_Element_Field_Is_Out_Of_Range,
          V.Element_Field_Out_Of_Range),
         (Slot_Element_Field_Is_Not_An_Array,
          V.Element_Field_Is_Not_An_Array),
         (Slot_Element_Load_Of_The_Wrong_Type, V.Result_Disagrees),
         (Slot_Element_Store_Of_The_Wrong_Type,
          V.Store_Datum_Disagrees),
         (Array_Copy_Endpoint_Is_Scalar,
          V.Array_Storage_Is_Not_An_Array),
         (Array_Copy_Aggregate_Is_Not_An_Array,
          V.Array_Storage_Is_Not_An_Array),
         (Array_Copy_Lengths_Disagree, V.Array_Copy_Shapes_Disagree),
         (Array_Copy_Elements_Disagree, V.Array_Copy_Shapes_Disagree),
         (Array_Copy_Source_Field_Is_Out_Of_Range,
          V.Element_Field_Out_Of_Range),
         (Array_Copy_Source_Field_Is_Not_An_Array,
          V.Element_Field_Is_Not_An_Array),
         (Nested_Array_Copy_Source_Beyond_The_Child,
          V.Element_Field_Is_Not_An_Array),
         (Array_Copy_Destination_Field_Is_Out_Of_Range,
          V.Element_Field_Out_Of_Range),
         (Array_Copy_Destination_Field_Is_Not_An_Array,
          V.Element_Field_Is_Not_An_Array),
         (Array_Copy_Field_Shape_Disagrees,
          V.Array_Copy_Shapes_Disagree),
         (Array_Copy_Slot_Is_Not_Owned, V.Slot_Out_Of_Range),
         (Array_Copy_Inside_A_Datum, V.Array_Copy_Inside_A_Datum),
         (Array_Clear_Destination_Is_Scalar,
          V.Array_Storage_Is_Not_An_Array),
         (Array_Clear_Slot_Is_Not_Owned, V.Slot_Out_Of_Range),
         (Array_Clear_Datum_Field_Is_Out_Of_Range,
          V.Element_Field_Out_Of_Range),
         (Array_Clear_Datum_Field_Is_Not_An_Array,
          V.Element_Field_Is_Not_An_Array),
         (Array_Clear_Slot_Field_Is_Out_Of_Range,
          V.Element_Field_Out_Of_Range),
         (Array_Clear_Slot_Field_Is_Not_An_Array,
          V.Element_Field_Is_Not_An_Array),
         (Array_Clear_Inside_A_Datum, V.Array_Clear_Inside_A_Datum),
         (Array_Fill_Destination_Is_Scalar,
          V.Array_Storage_Is_Not_An_Array),
         (Array_Fill_Aggregate_Is_Not_An_Array,
          V.Array_Storage_Is_Not_An_Array),
         (Array_Fill_Slot_Is_Not_Owned, V.Slot_Out_Of_Range),
         (Array_Fill_Datum_Field_Is_Out_Of_Range,
          V.Element_Field_Out_Of_Range),
         (Array_Fill_Datum_Field_Is_Not_An_Array,
          V.Element_Field_Is_Not_An_Array),
         (Array_Fill_Slot_Field_Is_Out_Of_Range,
          V.Element_Field_Out_Of_Range),
         (Array_Fill_Slot_Field_Is_Not_An_Array,
          V.Element_Field_Is_Not_An_Array),
         (Array_Fill_Value_Has_The_Wrong_Type,
          V.Array_Fill_Value_Disagrees),
         (Array_Fill_First_Is_Outside_Array,
          V.Array_Fill_First_Out_Of_Range),
         (Array_Fill_Field_First_Is_Outside_Array,
          V.Array_Fill_First_Out_Of_Range),
         (Array_Fill_Inside_A_Datum, V.Array_Fill_Inside_A_Datum),
         (Unchecked_Inside_A_Datum,  V.Unchecked_Not_Removable),
         (Range_Check_Bound_Is_Not_A_Value_Of_The_Type,
          V.Result_Disagrees),
         (Condition_Is_A_Number,      V.Condition_Is_Not_A_Bool),
         (Function_Signature_Part_Is_Malformed,
          V.Signature_Part_Malformed),
         (Function_Parameter_Uses_A_Different_Signature,
          V.Routine_Signature_Disagrees),
         (Function_Datum_Uses_A_Different_Signature,
          V.Function_Value_Signature_Disagrees),
         (Call_Missing_An_Argument,   V.Wrong_Operand_Count),
         (Indirect_Call_Uses_A_Different_Signature,
          V.Function_Value_Signature_Disagrees),
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

   --  D76's release checks walk storage, field, case and payload in that
   --  order.  Each malformed identity is constructible through the public
   --  builder and must be refused before the next accessor is used.
   procedure Malformed_Variant_Operations_Are_Rejected
     (Item : in out Landin.Testing.Context);

   procedure Malformed_Variant_Operations_Are_Rejected
     (Item : in out Landin.Testing.Context)
   is
      type Damage is
        (Field_Out_Of_Range,
         Field_Is_Not_A_Variant,
         Case_Out_Of_Range,
         Payload_Field_Out_Of_Range,
         Payload_Field_Is_Not_A_Scalar,
         Array_Case_Out_Of_Range,
         Array_Payload_Field_Out_Of_Range,
         Array_Payload_Field_Is_Not_An_Array,
         Payload_Value_Disagrees,
         Payload_Result_Disagrees,
         Tag_Result_Disagrees,
         Copy_Shapes_Disagree,
         Operation_Inside_A_Datum);

      function Built
        (Unit : in out IR.Unit;
         Site : Landin.Provenance.Origin;
         Harm : Damage) return V.Fault;

      function Built
        (Unit : in out IR.Unit;
         Site : Landin.Provenance.Origin;
         Harm : Damage) return V.Fault
      is
         Routine, Datum : IR.Item_Id;
         Result, Aggregate, Other : IR.Slot_Id;
         Block : IR.Block_Id;
         Value : IR.Value_Id;
      begin
         Routine := IR.Add_Item
           (Unit, IR.Routine, 1, Landin.Types.U32, Site);
         Result := IR.Add_Slot
           (Unit, Routine, Landin.Types.U32, 1, Site);
         Aggregate := IR.Add_Aggregate_Slot
           (Unit, Routine, IR.No_Declaration, Site);

         if Harm in Field_Out_Of_Range | Field_Is_Not_A_Variant then
            IR.Add_Slot_Field (Unit, Routine, Aggregate, Landin.Types.U8);
         else
            IR.Add_Slot_Field
              (Unit, Routine, Aggregate,
               (Kind           => IR.Variant_Field_Shape,
                Element        => Landin.Types.U8,
                Length         => 1,
                Cases          => 2,
                Payloads_First => 1,
                others         => <>),
               Cases => [(First => 0, Count => 0),
                         (First => 1, Count => 1)],
               Payloads =>
                 [(if Harm in Payload_Field_Is_Not_A_Scalar
                            | Array_Case_Out_Of_Range
                            | Array_Payload_Field_Out_Of_Range
                   then (Kind    => IR.Array_Field_Shape,
                         Element => Landin.Types.U32,
                         Length  => 2,
                         others  => <>)
                   else (Kind    => IR.Scalar_Field_Shape,
                         Element => Landin.Types.U32,
                         Length  => 1,
                         others  => <>))]);
         end if;
         IR.Set_Result_Slot (Unit, Routine, Result);

         if Harm = Copy_Shapes_Disagree then
            Other := IR.Add_Aggregate_Slot
              (Unit, Routine, IR.No_Declaration, Site);
            IR.Add_Slot_Field
              (Unit, Routine, Other,
               (Kind           => IR.Variant_Field_Shape,
                Element        => Landin.Types.U8,
                Length         => 1,
                Cases          => 1,
                Payloads_First => 1,
                others         => <>),
               Cases => [(First => 0, Count => 0)],
               Payloads => IR.No_Field_Shapes);
         else
            Other := IR.No_Slot;
         end if;

         Block := IR.Add_Block
           (Unit, Routine, Landin.Resolution.Program_Scope, Site);
         IR.Enter (Unit, Routine, Block);
         Value := IR.Emit_Number
           (Unit, Routine,
            (if Harm = Payload_Value_Disagrees
             then Landin.Types.U16 else Landin.Types.U32),
            1, False, Site);

         case Harm is
            when Field_Out_Of_Range =>
               IR.Emit_Variant_Select
                 (Unit, Routine,
                  (Kind => IR.Frame_Slot, Slot => Aggregate),
                  2, 1, Site);
            when Field_Is_Not_A_Variant =>
               IR.Emit_Variant_Select
                 (Unit, Routine,
                  (Kind => IR.Frame_Slot, Slot => Aggregate),
                  1, 1, Site);
            when Case_Out_Of_Range =>
               IR.Emit_Variant_Select
                 (Unit, Routine,
                  (Kind => IR.Frame_Slot, Slot => Aggregate),
                  1, 3, Site);
            when Payload_Field_Out_Of_Range =>
               IR.Emit_Variant_Field_Store
                 (Unit, Routine,
                  (Kind => IR.Frame_Slot, Slot => Aggregate),
                  1, 2, 2, Value, Site);
            when Payload_Field_Is_Not_A_Scalar
               | Payload_Value_Disagrees =>
               IR.Emit_Variant_Field_Store
                 (Unit, Routine,
                  (Kind => IR.Frame_Slot, Slot => Aggregate),
                  1, 2, 1, Value, Site);
            when Array_Case_Out_Of_Range
               | Array_Payload_Field_Out_Of_Range
               | Array_Payload_Field_Is_Not_An_Array =>
               declare
                  Index : constant IR.Value_Id :=
                    IR.Emit_Number
                      (Unit, Routine, Landin.Types.Usize, 0, False, Site);
               begin
                  IR.Emit_Store_Slot_Element
                    (Unit, Routine, Aggregate, Index, Value, Site,
                     Field => 1,
                     Variant_Case =>
                       (if Harm = Array_Case_Out_Of_Range then 3 else 2),
                     Variant_Payload_Field =>
                       (if Harm = Array_Payload_Field_Out_Of_Range
                        then 2 else 1));
               end;
            when Payload_Result_Disagrees =>
               Value := IR.Emit_Variant_Field_Load
                 (Unit, Routine,
                  (Kind => IR.Frame_Slot, Slot => Aggregate),
                  1, 2, 1, Landin.Types.U16, Site);
            when Tag_Result_Disagrees =>
               Value := IR.Emit_Variant_Tag_Load
                 (Unit, Routine,
                  (Kind => IR.Frame_Slot, Slot => Aggregate),
                  1, Landin.Types.U16, Site);
            when Copy_Shapes_Disagree =>
               IR.Emit_Variant_Copy
                 (Unit, Routine,
                  (Kind => IR.Frame_Slot, Slot => Aggregate),
                  (Kind => IR.Frame_Slot, Slot => Other), 1, Site);
            when Operation_Inside_A_Datum =>
               null;
         end case;

         IR.Emit_Store (Unit, Routine, Result, Value, Site);
         IR.Emit_Leave (Unit, Routine, Value, Site);
         IR.Leave_Block (Unit, Routine);

         if Harm = Operation_Inside_A_Datum then
            Datum := IR.Add_Item
              (Unit, IR.Datum, 5, Landin.Types.Aggregate, Site);
            IR.Add_Field
              (Unit, Datum,
               (Kind           => IR.Variant_Field_Shape,
                Element        => Landin.Types.U8,
                Length         => 1,
                Cases          => 1,
                Payloads_First => 1,
                others         => <>),
               Cases => [(First => 0, Count => 0)],
               Payloads => IR.No_Field_Shapes);
            Block := IR.Add_Block
              (Unit, Datum, Landin.Resolution.Program_Scope, Site);
            IR.Enter (Unit, Datum, Block);
            IR.Emit_Variant_Select
              (Unit, Datum, (Kind => IR.Module_Datum, Datum => Datum),
               1, 1, Site);
            IR.Emit_Leave (Unit, Datum, IR.No_Value, Site);
            IR.Leave_Block (Unit, Datum);
         end if;

         return V.Check (Unit);
      end Built;

      type Row is record
         Harm : Damage;
         Kind : V.Fault_Kind;
      end record;
      Wanted : constant array (Positive range <>) of Row :=
        [(Field_Out_Of_Range, V.Variant_Field_Out_Of_Range),
         (Field_Is_Not_A_Variant, V.Variant_Field_Is_Not_A_Variant),
         (Case_Out_Of_Range, V.Variant_Case_Out_Of_Range),
         (Payload_Field_Out_Of_Range,
          V.Variant_Payload_Field_Out_Of_Range),
         (Payload_Field_Is_Not_A_Scalar,
          V.Variant_Payload_Field_Is_Not_A_Scalar),
         (Array_Case_Out_Of_Range, V.Variant_Case_Out_Of_Range),
         (Array_Payload_Field_Out_Of_Range,
          V.Variant_Payload_Field_Out_Of_Range),
         (Array_Payload_Field_Is_Not_An_Array,
          V.Element_Field_Is_Not_An_Array),
         (Payload_Value_Disagrees, V.Variant_Payload_Value_Disagrees),
         (Payload_Result_Disagrees, V.Variant_Payload_Result_Disagrees),
         (Tag_Result_Disagrees, V.Variant_Tag_Result_Disagrees),
         (Copy_Shapes_Disagree, V.Variant_Copy_Shapes_Disagree),
         (Operation_Inside_A_Datum, V.Variant_Operation_Inside_A_Datum)];
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
      for Mismatch in Boolean loop
         declare
            Work : Landin.Stages.Compilation :=
              Landin.Stages.Create (Landin.Targets.Linux_X86_64);
            Site : Landin.Provenance.Origin;
            Unit : IR.Unit;
            Routine : IR.Item_Id;
            Source, Destination : IR.Slot_Id;
            Signature : IR.Signature_Id;
            Block : IR.Block_Id;
            Child : IR.Field_Shape;
         begin
            Ready (Work, Site);
            IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
            Routine := IR.Add_Item
              (Unit, IR.Routine, 1, Landin.Types.No_Value, Site);
            Source := IR.Add_Aggregate_Slot
              (Unit, Routine, IR.No_Declaration, Site);
            Destination := IR.Add_Aggregate_Slot
              (Unit, Routine, IR.No_Declaration, Site);
            for Index in 1 .. 2 loop
               Signature := IR.Add_Signature
                 (Unit, IR.No_Signature_Parts,
                  (Kind => Landin.Types.No_Value, others => <>),
                  C_ABI => not Mismatch or else Index = 1);
               Child := IR.Make_Array_Shape
                 (Unit, 2, (Element => Landin.Types.Usize,
                            Signature => Signature, others => <>));
               IR.Add_Slot_Field
                 (Unit, Routine,
                  (if Index = 1 then Source else Destination),
                  (Kind => IR.Variant_Field_Shape,
                   Element => Landin.Types.U8,
                   Cases => 1, Payloads_First => 1, others => <>),
                  Cases => [1 => (First => 1, Count => 1)],
                  Payloads => [1 => Child]);
            end loop;
            Block := IR.Add_Block
              (Unit, Routine, Landin.Resolution.Program_Scope, Site);
            IR.Enter (Unit, Routine, Block);
            IR.Emit_Variant_Copy
              (Unit, Routine,
               (Kind => IR.Frame_Slot, Slot => Destination),
               (Kind => IR.Frame_Slot, Slot => Source), 1, Site);
            IR.Emit_Leave (Unit, Routine, IR.No_Value, Site);
            IR.Leave_Block (Unit, Routine);
            Expect
              (Item, V.Check (Unit),
               (if Mismatch then V.Variant_Copy_Shapes_Disagree
                else V.Nothing_Wrong),
               "variant payload copies retain callback array identity"
                 & Mismatch'Image);
         end;
      end loop;
   end Malformed_Variant_Operations_Are_Rejected;

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

      --  D38 checks the finite prefix and one suffix pattern, not every
      --  position in a target-sized declared extent.
      for Bad_Prefix in Boolean loop
         declare
            Work : Landin.Stages.Compilation :=
              Landin.Stages.Create (Landin.Targets.Linux_X86_64);
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
            IR.Set_Array
              (Unit, Datum, Landin.Types.U8, IR.Element_Total'Last);
            IR.Set_Hybrid_Array_Image
              (Unit, Datum,
               Landin.Types.Folded_Array'
                 (1 => (if Bad_Prefix then 300 else 1)),
               (if Bad_Prefix then 2 else 300));
            Block := IR.Add_Block
              (Unit, Datum, Landin.Resolution.Program_Scope, Site);
            IR.Enter (Unit, Datum, Block);
            IR.Emit_Leave (Unit, Datum, IR.No_Value, Site);
            IR.Leave_Block (Unit, Datum);

            Result := V.Check (Unit, Landin.Targets.Linux_X86_64);
            Landin.Testing.Check
              (Item, Result.Kind = V.Array_Image_Value_Does_Not_Fit,
               (if Bad_Prefix then "bad hybrid prefix is rejected"
                else "bad hybrid suffix is rejected"));
         end;
      end loop;
   end Malformed_Image_Values_Are_Rejected;

   --  D66: aggregate image verification is explicit in release builds.
   --  The run must match the field run, an array field carries only zero in
   --  this first carrier, and scalar folds fit the selected target.
   procedure Malformed_Aggregate_Images_Are_Rejected
     (Item : in out Landin.Testing.Context);

   procedure Malformed_Aggregate_Images_Are_Rejected
     (Item : in out Landin.Testing.Context)
   is
      procedure Finish
        (Unit : in out IR.Unit;
         Datum : IR.Item_Id;
         Site : Landin.Provenance.Origin);

      procedure Finish
        (Unit : in out IR.Unit;
         Datum : IR.Item_Id;
         Site : Landin.Provenance.Origin)
      is
         Block : constant IR.Block_Id :=
           IR.Add_Block
             (Unit, Datum, Landin.Resolution.Program_Scope, Site);
      begin
         IR.Enter (Unit, Datum, Block);
         IR.Emit_Leave (Unit, Datum, IR.No_Value, Site);
         IR.Leave_Block (Unit, Datum);
      end Finish;

      procedure Add_Nested_Usize_Field
        (Unit : in out IR.Unit; Datum : IR.Item_Id);

      procedure Add_Nested_Usize_Field
        (Unit : in out IR.Unit; Datum : IR.Item_Id)
      is
      begin
         IR.Add_Field
           (Unit, Datum,
            (Kind           => IR.Aggregate_Field_Shape,
             Element        => Landin.Types.Bool,
             Length         => 1,
             Cases          => 1,
             Payloads_First => 1,
             Nominal        => Test_Nominal (Unit),
             others         => <>),
            IR.No_Case_Runs,
            [(Kind    => IR.Scalar_Field_Shape,
              Element => Landin.Types.Usize,
              Length  => 1,
              others  => <>)]);
      end Add_Nested_Usize_Field;
   begin
      declare
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Site : Landin.Provenance.Origin;
         Unit : IR.Unit;
         Datum : IR.Item_Id;
      begin
         Ready (Work, Site);
         IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
         Datum := IR.Add_Item
           (Unit, IR.Datum, 1, Landin.Types.Aggregate, Site);
         IR.Add_Field (Unit, Datum, Landin.Types.U8);
         IR.Set_Aggregate_Image
           (Unit, Datum, Landin.Types.Folded_Array'(1 => 1));
         --  The builder normally finishes the field run first; this legal
         --  structural mutation makes a short image without corrupting the
         --  shared image-vector partition.
         IR.Add_Field (Unit, Datum, Landin.Types.U16);
         Finish (Unit, Datum, Site);
         Expect
           (Item, V.Check (Unit, Landin.Targets.Linux_X86_64),
            V.Aggregate_Image_Length_Disagrees,
            "an aggregate image shorter than its field run is refused");
      end;

      declare
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Site : Landin.Provenance.Origin;
         Unit : IR.Unit;
         Datum : IR.Item_Id;
      begin
         Ready (Work, Site);
         IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
         Datum := IR.Add_Item
           (Unit, IR.Datum, 1, Landin.Types.Aggregate, Site);
         Add_Nested_Usize_Field (Unit, Datum);
         IR.Set_Aggregate_Image
           (Unit, Datum, Landin.Types.Folded_Array'(1 => 0),
            IR.Aggregate_Field_Image_Array'
              (1 => (Form => IR.Nested,
                     Offset => 0, Count => 1, Value => 0,
                     others => <>)),
            IR.Aggregate_Field_Image_Array'
              (1 => (Form => IR.Absent,
                     Offset => 0, Count => 0, Value => 2 ** 32,
                     others => <>)),
            Landin.Types.Folded_Array'(1 .. 0 => 0));
         Finish (Unit, Datum, Site);
         Expect
           (Item, V.Check (Unit, Landin.Targets.Synthetic_32),
            V.Aggregate_Field_Image_Value_Does_Not_Fit,
            "a nested usize fold follows the 32-bit target");
         Expect
           (Item, V.Check (Unit, Landin.Targets.Linux_X86_64),
            V.Nothing_Wrong,
            "the same recursive fold fits the 64-bit target");
      end;

      declare
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Site : Landin.Provenance.Origin;
         Unit : IR.Unit;
         Datum : IR.Item_Id;
      begin
         Ready (Work, Site);
         IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
         Datum := IR.Add_Item
           (Unit, IR.Datum, 1, Landin.Types.Aggregate, Site);
         Add_Nested_Usize_Field (Unit, Datum);
         IR.Set_Aggregate_Image
           (Unit, Datum, Landin.Types.Folded_Array'(1 => 0),
            IR.Aggregate_Field_Image_Array'
              (1 => (Form => IR.Nested,
                     Offset => 0, Count => 0, Value => 0,
                     others => <>)),
            Landin.Types.Folded_Array'(1 .. 0 => 0));
         Finish (Unit, Datum, Site);
         Expect
           (Item, V.Check (Unit, Landin.Targets.Linux_X86_64),
            V.Aggregate_Field_Image_Length_Disagrees,
            "a nested descriptor must name every direct child");
      end;

      declare
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Site : Landin.Provenance.Origin;
         Unit : IR.Unit;
         Datum : IR.Item_Id;
      begin
         Ready (Work, Site);
         IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
         Datum := IR.Add_Item
           (Unit, IR.Datum, 1, Landin.Types.Aggregate, Site);
         Add_Nested_Usize_Field (Unit, Datum);
         IR.Set_Aggregate_Image
           (Unit, Datum, Landin.Types.Folded_Array'(1 => 0),
            IR.Aggregate_Field_Image_Array'
              (1 => (Form => IR.Nested,
                     Offset => 1, Count => 1, Value => 0,
                     others => <>)),
            IR.Aggregate_Field_Image_Array'
              (1 => (Form => IR.Absent,
                     Offset => 0, Count => 0, Value => 1,
                     others => <>)),
            Landin.Types.Folded_Array'(1 .. 0 => 0));
         Finish (Unit, Datum, Site);
         Expect
           (Item, V.Check (Unit, Landin.Targets.Linux_X86_64),
            V.Aggregate_Image_On_Aggregate_Field,
            "a recursive descriptor offset cannot skip or point backward");
      end;

      declare
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Site : Landin.Provenance.Origin;
         Unit : IR.Unit;
         Datum : IR.Item_Id;
      begin
         Ready (Work, Site);
         IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
         Datum := IR.Add_Item
           (Unit, IR.Datum, 1, Landin.Types.Aggregate, Site);
         IR.Add_Field
           (Unit, Datum,
            (Kind    => IR.Array_Field_Shape,
             Element => Landin.Types.Usize,
             Length  => 1,
             others => <>));
         IR.Set_Aggregate_Image
           (Unit, Datum, Landin.Types.Folded_Array'(1 => 0),
            IR.Aggregate_Field_Image_Array'
              (1 => (Form => IR.Finite,
                     Offset => 0, Count => 1, Value => 0, others => <>)),
            Landin.Types.Folded_Array'(1 => 2 ** 32));
         Finish (Unit, Datum, Site);
         Expect
           (Item, V.Check (Unit, Landin.Targets.Synthetic_32),
            V.Aggregate_Field_Image_Value_Does_Not_Fit,
            "a finite usize fold follows the 32-bit target");
         Expect
           (Item, V.Check (Unit, Landin.Targets.Linux_X86_64),
            V.Nothing_Wrong,
            "the same finite usize fold fits the 64-bit target");
      end;

      declare
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Site : Landin.Provenance.Origin;
         Unit : IR.Unit;
         Datum : IR.Item_Id;
      begin
         Ready (Work, Site);
         IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
         Datum := IR.Add_Item
           (Unit, IR.Datum, 1, Landin.Types.Aggregate, Site);
         IR.Add_Field
           (Unit, Datum,
            (Kind    => IR.Array_Field_Shape,
             Element => Landin.Types.U8,
             Length  => 2,
             others => <>));
         IR.Set_Aggregate_Image
           (Unit, Datum, Landin.Types.Folded_Array'(1 => 1));
         Finish (Unit, Datum, Site);
         Expect
           (Item, V.Check (Unit, Landin.Targets.Linux_X86_64),
            V.Aggregate_Image_On_Array_Field,
            "a nonzero array-field placeholder is refused");
      end;

      declare
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Site : Landin.Provenance.Origin;
         Unit : IR.Unit;
         Datum : IR.Item_Id;
      begin
         Ready (Work, Site);
         IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
         Datum := IR.Add_Item
           (Unit, IR.Datum, 1, Landin.Types.Aggregate, Site);
         IR.Add_Field
           (Unit, Datum,
            (Kind           => IR.Variant_Field_Shape,
             Element        => Landin.Types.U8,
             Length         => 1,
             Cases          => 1,
             Payloads_First => 1,
             others         => <>),
            Cases => [(First => 0, Count => 0)],
            Payloads => IR.No_Field_Shapes);
         IR.Set_Aggregate_Image
           (Unit, Datum, Landin.Types.Folded_Array'(1 => 0));
         Finish (Unit, Datum, Site);
         Expect
           (Item, V.Check (Unit, Landin.Targets.Linux_X86_64),
            V.Nothing_Wrong,
            "an absent variant field is valid in a written aggregate image");
      end;

      declare
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Site : Landin.Provenance.Origin;
         Unit : IR.Unit;
         Datum : IR.Item_Id;
      begin
         Ready (Work, Site);
         IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
         Datum := IR.Add_Item
           (Unit, IR.Datum, 1, Landin.Types.Aggregate, Site);
         IR.Add_Field
           (Unit, Datum,
            (Kind           => IR.Variant_Field_Shape,
             Element        => Landin.Types.U8,
             Length         => 1,
             Cases          => 1,
             Payloads_First => 1,
             others         => <>),
            Cases => [(First => 1, Count => 1)],
            Payloads =>
              [(Kind    => IR.Scalar_Field_Shape,
                Element => Landin.Types.U16,
                Length  => 1,
                others  => <>)]);
         IR.Set_Aggregate_Image
           (Unit, Datum, Landin.Types.Folded_Array'(1 => 0),
            IR.Aggregate_Field_Image_Array'
              (1 => (Form => IR.Selected,
                     Offset => 0, Count => 1, Value => 1, others => <>)),
            IR.Aggregate_Field_Image_Array'
              (1 => (Form => IR.Absent,
                     Offset => 0, Count => 0, Value => 13, others => <>)),
            Landin.Types.Folded_Array'(1 .. 0 => 0));
         Finish (Unit, Datum, Site);
         Expect
           (Item, V.Check (Unit, Landin.Targets.Linux_X86_64),
            V.Nothing_Wrong,
            "a selected variant case carries its scalar payload image");
      end;

      declare
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Site : Landin.Provenance.Origin;
         Unit : IR.Unit;
         Datum : IR.Item_Id;
      begin
         Ready (Work, Site);
         IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
         Datum := IR.Add_Item
           (Unit, IR.Datum, 1, Landin.Types.Aggregate, Site);
         IR.Add_Field
           (Unit, Datum,
            (Kind           => IR.Variant_Field_Shape,
             Element        => Landin.Types.U8,
             Length         => 1,
             Cases          => 1,
             Payloads_First => 1,
             others         => <>),
            Cases => [(First => 1, Count => 1)],
            Payloads =>
              [(Kind    => IR.Array_Field_Shape,
                Element => Landin.Types.U8,
                Length  => 3,
                others  => <>)]);
         IR.Set_Aggregate_Image
           (Unit, Datum, Landin.Types.Folded_Array'(1 => 0),
            IR.Aggregate_Field_Image_Array'
              (1 => (Form => IR.Selected,
                     Offset => 0, Count => 1, Value => 1, others => <>)),
            IR.Aggregate_Field_Image_Array'
              (1 => (Form => IR.Hybrid,
                     Offset => 0, Count => 1, Value => 7, others => <>)),
            Landin.Types.Folded_Array'(1 => 5));
         Finish (Unit, Datum, Site);
         Expect
           (Item, V.Check (Unit, Landin.Targets.Linux_X86_64),
            V.Nothing_Wrong,
            "a selected case carries a compact array payload image");
      end;

      declare
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Site : Landin.Provenance.Origin;
         Unit : IR.Unit;
         Datum : IR.Item_Id;
      begin
         Ready (Work, Site);
         IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
         Datum := IR.Add_Item
           (Unit, IR.Datum, 1, Landin.Types.Aggregate, Site);
         IR.Add_Field
           (Unit, Datum,
            (Kind           => IR.Variant_Field_Shape,
             Element        => Landin.Types.U8,
             Length         => 1,
             Cases          => 1,
             Payloads_First => 1,
             others         => <>),
            Cases => [(First => 0, Count => 0)],
            Payloads => IR.No_Field_Shapes);
         IR.Set_Aggregate_Image
           (Unit, Datum, Landin.Types.Folded_Array'(1 => 0),
            IR.Aggregate_Field_Image_Array'
              (1 => (Form => IR.Selected,
                     Offset => 0, Count => 0, Value => 2, others => <>)),
            Landin.Types.Folded_Array'(1 .. 0 => 0));
         Finish (Unit, Datum, Site);
         Expect
           (Item, V.Check (Unit, Landin.Targets.Linux_X86_64),
            V.Aggregate_Image_On_Variant_Field,
            "a selected case outside the variant is refused");
      end;

      declare
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Site : Landin.Provenance.Origin;
         Unit : IR.Unit;
         Datum : IR.Item_Id;
      begin
         Ready (Work, Site);
         IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
         Datum := IR.Add_Item
           (Unit, IR.Datum, 1, Landin.Types.Aggregate, Site);
         IR.Add_Field (Unit, Datum, Landin.Types.Usize);
         IR.Set_Aggregate_Image
           (Unit, Datum,
            Landin.Types.Folded_Array'(1 => 2 ** 32));
         Finish (Unit, Datum, Site);
         Expect
           (Item, V.Check (Unit, Landin.Targets.Synthetic_32),
            V.Aggregate_Image_Value_Does_Not_Fit,
            "a usize aggregate fold follows the 32-bit target");
         Expect
           (Item, V.Check (Unit, Landin.Targets.Linux_X86_64),
            V.Nothing_Wrong,
            "the same target-neutral fold fits the 64-bit target");
      end;

      declare
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Site : Landin.Provenance.Origin;
         Unit : IR.Unit;
         Datum : IR.Item_Id;
      begin
         Ready (Work, Site);
         IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
         Datum := IR.Add_Item
           (Unit, IR.Datum, 1, Landin.Types.Aggregate, Site);
         IR.Add_Field
           (Unit, Datum,
            (Kind    => IR.Array_Field_Shape,
             Element => Landin.Types.U8,
             Length  => 2,
             others => <>));
         IR.Set_Aggregate_Image
           (Unit, Datum, Landin.Types.Folded_Array'(1 => 0),
            IR.Aggregate_Field_Image_Array'
              (1 => (Form => IR.Finite,
                     Offset => 0, Count => 1, Value => 0, others => <>)),
            Landin.Types.Folded_Array'(1 => 1));
         Finish (Unit, Datum, Site);
         Expect
           (Item, V.Check (Unit, Landin.Targets.Linux_X86_64),
            V.Aggregate_Field_Image_Length_Disagrees,
            "a finite field image must fill its declared array");
      end;

      declare
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Site : Landin.Provenance.Origin;
         Unit : IR.Unit;
         Datum : IR.Item_Id;
      begin
         Ready (Work, Site);
         IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
         Datum := IR.Add_Item
           (Unit, IR.Datum, 1, Landin.Types.Aggregate, Site);
         IR.Add_Field
           (Unit, Datum,
            (Kind    => IR.Array_Field_Shape,
             Element => Landin.Types.U8,
             Length  => 1,
             others => <>));
         IR.Set_Aggregate_Image
           (Unit, Datum, Landin.Types.Folded_Array'(1 => 0),
            IR.Aggregate_Field_Image_Array'
              (1 => (Form => IR.Finite,
                     Offset => 0, Count => 1, Value => 0, others => <>)),
            Landin.Types.Folded_Array'(1 => 300));
         Finish (Unit, Datum, Site);
         Expect
           (Item, V.Check (Unit, Landin.Targets.Linux_X86_64),
            V.Aggregate_Field_Image_Value_Does_Not_Fit,
            "a finite field fold follows its selected target element type");
      end;

      declare
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Site : Landin.Provenance.Origin;
         Unit : IR.Unit;
         Datum : IR.Item_Id;
      begin
         Ready (Work, Site);
         IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
         Datum := IR.Add_Item
           (Unit, IR.Datum, 1, Landin.Types.Aggregate, Site);
         IR.Add_Field (Unit, Datum, Landin.Types.U8);
         IR.Set_Aggregate_Image
           (Unit, Datum, Landin.Types.Folded_Array'(1 => 1),
            IR.Aggregate_Field_Image_Array'
              (1 => (Form => IR.Finite,
                     Offset => 0, Count => 1, Value => 0, others => <>)),
            Landin.Types.Folded_Array'(1 => 1));
         Finish (Unit, Datum, Site);
         Expect
           (Item, V.Check (Unit, Landin.Targets.Linux_X86_64),
            V.Aggregate_Field_Image_On_Scalar_Field,
            "a scalar field cannot carry an array image descriptor");
      end;

      declare
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Site : Landin.Provenance.Origin;
         Unit : IR.Unit;
         Datum : IR.Item_Id;
      begin
         Ready (Work, Site);
         IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
         Datum := IR.Add_Item
           (Unit, IR.Datum, 1, Landin.Types.Aggregate, Site);
         IR.Add_Field
           (Unit, Datum,
            (Kind    => IR.Array_Field_Shape,
             Element => Landin.Types.U8,
             Length  => 2,
             others => <>));
         IR.Set_Aggregate_Image
           (Unit, Datum, Landin.Types.Folded_Array'(1 => 0),
            IR.Aggregate_Field_Image_Array'
              (1 => (Form => IR.Repeated,
                     Offset => 0, Count => 0, Value => 0, others => <>)),
            Landin.Types.Folded_Array'(1 .. 0 => 0));
         Finish (Unit, Datum, Site);
         Expect
           (Item, V.Check (Unit, Landin.Targets.Linux_X86_64),
            V.Aggregate_Field_Image_Pattern_Not_Canonical,
            "a repeated zero pattern must use the absent form");
      end;

      declare
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Site : Landin.Provenance.Origin;
         Unit : IR.Unit;
         Datum : IR.Item_Id;
      begin
         Ready (Work, Site);
         IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
         Datum := IR.Add_Item
           (Unit, IR.Datum, 1, Landin.Types.Aggregate, Site);
         IR.Add_Field
           (Unit, Datum,
            (Kind    => IR.Array_Field_Shape,
             Element => Landin.Types.U8,
             Length  => 2,
             others => <>));
         IR.Set_Aggregate_Image
           (Unit, Datum, Landin.Types.Folded_Array'(1 => 0),
            IR.Aggregate_Field_Image_Array'
              (1 => (Form => IR.Hybrid,
                     Offset => 0, Count => 2, Value => 1, others => <>)),
            Landin.Types.Folded_Array'(1, 2));
         Finish (Unit, Datum, Site);
         Expect
           (Item, V.Check (Unit, Landin.Targets.Linux_X86_64),
            V.Aggregate_Field_Image_Pattern_Not_Canonical,
            "a hybrid prefix must leave a repeated suffix");
      end;

      declare
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Site : Landin.Provenance.Origin;
         Unit : IR.Unit;
         Datum : IR.Item_Id;
      begin
         Ready (Work, Site);
         IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
         Datum := IR.Add_Item
           (Unit, IR.Datum, 1, Landin.Types.Aggregate, Site);
         IR.Add_Field
           (Unit, Datum,
            (Kind    => IR.Array_Field_Shape,
             Element => Landin.Types.Usize,
             Length  => 2,
             others => <>));
         IR.Set_Aggregate_Image
           (Unit, Datum, Landin.Types.Folded_Array'(1 => 0),
            IR.Aggregate_Field_Image_Array'
              (1 => (Form => IR.Repeated,
                     Offset => 0, Count => 0, Value => 2 ** 32, others => <>)),
            Landin.Types.Folded_Array'(1 .. 0 => 0));
         Finish (Unit, Datum, Site);
         Expect
           (Item, V.Check (Unit, Landin.Targets.Synthetic_32),
            V.Aggregate_Field_Image_Value_Does_Not_Fit,
            "a repeated usize pattern follows the 32-bit target");
         Expect
           (Item, V.Check (Unit, Landin.Targets.Linux_X86_64),
            V.Nothing_Wrong,
            "the same repeated usize pattern fits the 64-bit target");
      end;

      declare
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Site : Landin.Provenance.Origin;
         Unit : IR.Unit;
         Datum : IR.Item_Id;
      begin
         Ready (Work, Site);
         IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
         Datum := IR.Add_Item
           (Unit, IR.Datum, 1, Landin.Types.Aggregate, Site);
         IR.Add_Field
           (Unit, Datum,
            (Kind    => IR.Array_Field_Shape,
             Element => Landin.Types.U8,
             Length  => 1,
             others => <>));
         IR.Set_Aggregate_Image
           (Unit, Datum, Landin.Types.Folded_Array'(1 => 0),
            IR.Aggregate_Field_Image_Array'
              (1 => (Form => IR.Absent,
                     Offset => 0, Count => 0, Value => 1, others => <>)),
            Landin.Types.Folded_Array'(1 .. 0 => 0));
         Finish (Unit, Datum, Site);
         Expect
           (Item, V.Check (Unit, Landin.Targets.Linux_X86_64),
            V.Aggregate_Field_Image_Pattern_Not_Canonical,
            "an absent field image cannot hide a pattern value");
      end;

      declare
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Site : Landin.Provenance.Origin;
         Unit : IR.Unit;
         Datum : IR.Item_Id;
      begin
         Ready (Work, Site);
         IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
         Datum := IR.Add_Item
           (Unit, IR.Datum, 1, Landin.Types.Aggregate, Site);
         IR.Add_Field
           (Unit, Datum,
            (Kind    => IR.Array_Field_Shape,
             Element => Landin.Types.U8,
             Length  => 1,
             others => <>));
         IR.Set_Aggregate_Image
           (Unit, Datum, Landin.Types.Folded_Array'(1 => 0),
            IR.Aggregate_Field_Image_Array'
              (1 => (Form => IR.Finite,
                     Offset => 0, Count => 1, Value => 1, others => <>)),
            Landin.Types.Folded_Array'(1 => 7));
         Finish (Unit, Datum, Site);
         Expect
           (Item, V.Check (Unit, Landin.Targets.Linux_X86_64),
            V.Aggregate_Field_Image_Pattern_Not_Canonical,
            "a finite field image cannot also carry a suffix pattern");
      end;

      declare
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Site : Landin.Provenance.Origin;
         Unit : IR.Unit;
         Datum : IR.Item_Id;
      begin
         Ready (Work, Site);
         IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
         Datum := IR.Add_Item
           (Unit, IR.Datum, 1, Landin.Types.Aggregate, Site);
         IR.Add_Field
           (Unit, Datum,
            (Kind    => IR.Array_Field_Shape,
             Element => Landin.Types.Bool,
             Length  => 2,
             others => <>));
         IR.Set_Aggregate_Image
           (Unit, Datum, Landin.Types.Folded_Array'(1 => 0),
            IR.Aggregate_Field_Image_Array'
              (1 => (Form => IR.Repeated,
                     Offset => 0, Count => 0, Value => 2, others => <>)),
            Landin.Types.Folded_Array'(1 .. 0 => 0));
         Finish (Unit, Datum, Site);
         Expect
           (Item, V.Check (Unit, Landin.Targets.Linux_X86_64),
            V.Aggregate_Field_Image_Value_Does_Not_Fit,
            "a repeated bool pattern must remain zero or one");
      end;

      --  D131: a static function field is a routine relocation, not a
      --  folded integer.  Its target must carry the field's descriptor.
      declare
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Site : Landin.Provenance.Origin;
         Unit : IR.Unit;
         Expected, Other : IR.Signature_Id;
         Target, Datum : IR.Item_Id;
         Parameter : IR.Slot_Id;
      begin
         Ready (Work, Site);
         IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
         Expected := IR.Add_Signature
           (Unit, IR.No_Signature_Parts,
            (Kind => Landin.Types.No_Value, others => <>));
         Other := IR.Add_Signature
           (Unit,
            [(Kind => Landin.Types.I32, others => <>)],
            (Kind => Landin.Types.No_Value, others => <>));
         Target := IR.Add_Item
           (Unit, IR.Routine, IR.No_Declaration,
            Landin.Types.No_Value, Site);
         IR.Set_Signature (Unit, Target, Other);
         Parameter := IR.Add_Parameter
           (Unit, Target, Landin.Types.I32, 1, Site);
         pragma Unreferenced (Parameter);
         Finish (Unit, Target, Site);

         Datum := IR.Add_Item
           (Unit, IR.Datum, 1, Landin.Types.Aggregate, Site);
         IR.Add_Field
           (Unit, Datum,
            (Kind => IR.Scalar_Field_Shape,
             Element => Landin.Types.Usize,
             Length => 1,
             Signature => Expected,
             others => <>));
         IR.Set_Aggregate_Image
           (Unit, Datum, Landin.Types.Folded_Array'(1 => 0),
            IR.Aggregate_Field_Image_Array'
              (1 => (Target => Target, others => <>)),
            Landin.Types.Folded_Array'(1 .. 0 => 0));
         Finish (Unit, Datum, Site);
         Expect
           (Item, V.Check (Unit),
            V.Function_Value_Signature_Disagrees,
            "a function-field relocation retains its signature");
      end;

      --  D132 keeps D131's relocation checks at every recursive descriptor
      --  depth rather than treating a nested function as a folded integer.
      declare
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Site : Landin.Provenance.Origin;
         Unit : IR.Unit;
         Expected, Other : IR.Signature_Id;
         Target, Datum : IR.Item_Id;
         Parameter : IR.Slot_Id;
      begin
         Ready (Work, Site);
         IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
         Expected := IR.Add_Signature
           (Unit, IR.No_Signature_Parts,
            (Kind => Landin.Types.No_Value, others => <>));
         Other := IR.Add_Signature
           (Unit,
            [(Kind => Landin.Types.I32, others => <>)],
            (Kind => Landin.Types.No_Value, others => <>));
         Target := IR.Add_Item
           (Unit, IR.Routine, IR.No_Declaration,
            Landin.Types.No_Value, Site);
         IR.Set_Signature (Unit, Target, Other);
         Parameter := IR.Add_Parameter
           (Unit, Target, Landin.Types.I32, 1, Site);
         pragma Unreferenced (Parameter);
         Finish (Unit, Target, Site);

         Datum := IR.Add_Item
           (Unit, IR.Datum, 1, Landin.Types.Aggregate, Site);
         IR.Add_Field
           (Unit, Datum,
            (Kind           => IR.Aggregate_Field_Shape,
             Element        => Landin.Types.Bool,
             Length         => 1,
             Cases          => 1,
             Payloads_First => 1,
             Nominal        => Test_Nominal (Unit),
             others         => <>),
            IR.No_Case_Runs,
            [(Kind      => IR.Scalar_Field_Shape,
              Element   => Landin.Types.Usize,
              Length    => 1,
              Signature => Expected,
              others    => <>)]);
         IR.Set_Aggregate_Image
           (Unit, Datum, Landin.Types.Folded_Array'(1 => 0),
            IR.Aggregate_Field_Image_Array'
              (1 => (Form => IR.Nested, Count => 1, others => <>)),
            IR.Aggregate_Field_Image_Array'
              (1 => (Target => Target, others => <>)),
            Landin.Types.Folded_Array'(1 .. 0 => 0));
         Finish (Unit, Datum, Site);
         Expect
           (Item, V.Check (Unit),
            V.Function_Value_Signature_Disagrees,
            "a nested function relocation retains its signature");
      end;
   end Malformed_Aggregate_Images_Are_Rejected;

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

   procedure Malformed_Multiple_Results_Are_Rejected
     (Item : in out Landin.Testing.Context);

   procedure Malformed_Multiple_Results_Are_Rejected
     (Item : in out Landin.Testing.Context)
   is
      procedure Finish_Routine
        (Unit : in out IR.Unit;
         Routine : IR.Item_Id;
         Site : Landin.Provenance.Origin);

      procedure Finish_Routine
        (Unit : in out IR.Unit;
         Routine : IR.Item_Id;
         Site : Landin.Provenance.Origin)
      is
         Block : constant IR.Block_Id := IR.Add_Block
           (Unit, Routine, Landin.Resolution.Program_Scope, Site);
      begin
         IR.Enter (Unit, Routine, Block);
         IR.Emit_Leave (Unit, Routine, IR.No_Value, Site);
         IR.Leave_Block (Unit, Routine);
      end Finish_Routine;
   begin
      declare
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Site : Landin.Provenance.Origin;
         Unit : IR.Unit;
         Signature : IR.Signature_Id;
         Routine : IR.Item_Id;
         Hidden, Result : IR.Slot_Id;
      begin
         Ready (Work, Site);
         IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
         Signature := IR.Add_Signature_With_Results
           (Unit, IR.No_Signature_Parts,
            [(Kind => Landin.Types.U32, others => <>),
             (Kind => Landin.Types.Bool, others => <>)]);
         Routine := IR.Add_Item
           (Unit, IR.Routine, 1, Landin.Types.Aggregate, Site);
         IR.Set_Signature (Unit, Routine, Signature);
         Hidden := IR.Add_Parameter
           (Unit, Routine, Landin.Types.Usize, 1, Site);
         pragma Unreferenced (Hidden);
         Result := IR.Add_Aggregate_Slot
           (Unit, Routine, IR.No_Declaration, Site);
         IR.Add_Slot_Field (Unit, Routine, Result, Landin.Types.U32);
         IR.Set_Result_Slot (Unit, Routine, Result);
         Finish_Routine (Unit, Routine, Site);
         Expect
           (Item, V.Check (Unit), V.Routine_Signature_Disagrees,
            "a multiple-result slot must carry every result field");
      end;

      declare
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Site : Landin.Provenance.Origin;
         Unit : IR.Unit;
         Expected, Other, Signature : IR.Signature_Id;
         Routine : IR.Item_Id;
         Hidden, Result : IR.Slot_Id;
      begin
         Ready (Work, Site);
         IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
         Expected := IR.Add_Signature
           (Unit, IR.No_Signature_Parts,
            (Kind => Landin.Types.U32, others => <>));
         Other := IR.Add_Signature
           (Unit, IR.No_Signature_Parts,
            (Kind => Landin.Types.Bool, others => <>));
         Signature := IR.Add_Signature_With_Results
           (Unit, IR.No_Signature_Parts,
            [(Kind => Landin.Types.Function_Value,
              Signature => Expected, others => <>),
             (Kind => Landin.Types.U32, others => <>)]);
         Routine := IR.Add_Item
           (Unit, IR.Routine, 1, Landin.Types.Aggregate, Site);
         IR.Set_Signature (Unit, Routine, Signature);
         Hidden := IR.Add_Parameter
           (Unit, Routine, Landin.Types.Usize, 1, Site);
         pragma Unreferenced (Hidden);
         Result := IR.Add_Aggregate_Slot
           (Unit, Routine, IR.No_Declaration, Site);
         IR.Add_Slot_Field
           (Unit, Routine, Result,
            (Kind => IR.Scalar_Field_Shape,
             Element => Landin.Types.Usize,
             Length => 1,
             Signature => Other,
             others => <>));
         IR.Add_Slot_Field (Unit, Routine, Result, Landin.Types.U32);
         IR.Set_Result_Slot (Unit, Routine, Result);
         Finish_Routine (Unit, Routine, Site);
         Expect
           (Item, V.Check (Unit), V.Routine_Signature_Disagrees,
            "a function-valued result field retains its nested signature");
      end;
      for Scenario in 0 .. 3 loop
         declare
            Work : Landin.Stages.Compilation :=
              Landin.Stages.Create (Landin.Targets.Linux_X86_64);
            Site : Landin.Provenance.Origin;
            Unit : IR.Unit;
            Expected, Actual, Signature : IR.Signature_Id;
            Routine : IR.Item_Id;
            Hidden, Result : IR.Slot_Id;
            Child, Shape : IR.Field_Shape;
         begin
            Ready (Work, Site);
            IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
            Expected := IR.Add_Signature
              (Unit, IR.No_Signature_Parts,
               (Kind => Landin.Types.No_Value, others => <>), C_ABI => True);
            Actual := IR.Add_Signature
              (Unit, IR.No_Signature_Parts,
               (Kind => Landin.Types.No_Value, others => <>),
               C_ABI => Scenario /= 1);
            Child := (Element => Landin.Types.Usize,
                      Signature => Expected, others => <>);
            Signature := IR.Add_Signature_With_Results
              (Unit, IR.No_Signature_Parts,
               [(Kind => Landin.Types.Fixed_Array, Length => 2,
                 Element => Landin.Types.Usize,
                 Element_Shape => (if Scenario = 2 then (others => <>)
                                   else Child), others => <>),
                (Kind => Landin.Types.U32, others => <>)]);
            Routine := IR.Add_Item
              (Unit, IR.Routine, 1, Landin.Types.Aggregate, Site);
            IR.Set_Signature (Unit, Routine, Signature);
            Hidden := IR.Add_Parameter
              (Unit, Routine, Landin.Types.Usize, 1, Site);
            pragma Unreferenced (Hidden);
            Result := IR.Add_Aggregate_Slot
              (Unit, Routine, IR.No_Declaration, Site);
            Child.Signature := Actual;
            Shape := IR.Make_Array_Shape
              (Unit, (if Scenario = 3 then 3 else 2), Child);
            IR.Add_Slot_Field (Unit, Routine, Result, Shape);
            IR.Add_Slot_Field (Unit, Routine, Result, Landin.Types.U32);
            IR.Set_Result_Slot (Unit, Routine, Result);
            Finish_Routine (Unit, Routine, Site);
            Expect
              (Item, V.Check (Unit),
               (if Scenario = 0 then V.Nothing_Wrong
                else V.Routine_Signature_Disagrees),
               "array-valued multiple result retains callbacks and extent"
                 & Scenario'Image);
         end;
      end loop;
   end Malformed_Multiple_Results_Are_Rejected;

   --  R2.30: atom identity and the orthogonal failure edge stay explicit in
   --  neutral IR.  Each malformed shape below is builder-reachable, so each
   --  verifier rule can fail independently rather than existing only in prose.
   procedure Malformed_Error_IR_Is_Rejected
     (Item : in out Landin.Testing.Context);

   procedure Malformed_Error_IR_Is_Rejected
     (Item : in out Landin.Testing.Context)
   is
   begin
      declare
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Site : Landin.Provenance.Origin;
         Unit : IR.Unit;
         Duplicate : IR.Atom_Set_Id;
      begin
         Ready (Work, Site);
         IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
         Duplicate := IR.Add_Atom_Set (Unit, [5, 5]);
         pragma Unreferenced (Duplicate);
         Expect
           (Item, V.Check (Unit), V.Atom_Set_Malformed,
            "a duplicated atom identity is refused");
      end;

      declare
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Site : Landin.Provenance.Origin;
         Unit : IR.Unit;
         Atoms : IR.Atom_Set_Id;
         Signature : IR.Signature_Id;
         Routine : IR.Item_Id;
         Result : IR.Slot_Id;
         Block : IR.Block_Id;
         Value : IR.Value_Id;
      begin
         Ready (Work, Site);
         IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
         Atoms := IR.Add_Atom_Set (Unit, [1 => 5]);
         Signature := IR.Add_Signature
           (Unit, IR.No_Signature_Parts,
            (Kind => Landin.Types.U32, Atoms => Atoms, others => <>));
         Routine := IR.Add_Item
           (Unit, IR.Routine, 1, Landin.Types.U32, Site);
         IR.Set_Atom_Set (Unit, Routine, Atoms);
         IR.Set_Signature (Unit, Routine, Signature);
         Result := IR.Add_Slot
           (Unit, Routine, Landin.Types.U32, 2, Site, Atoms => Atoms);
         IR.Set_Result_Slot (Unit, Routine, Result);
         Block := IR.Add_Block
           (Unit, Routine, Landin.Resolution.Program_Scope, Site);
         IR.Enter (Unit, Routine, Block);
         Value := IR.Emit_Atom (Unit, Routine, 6, Atoms, Site);
         IR.Emit_Store (Unit, Routine, Result, Value, Site);
         Value := IR.Emit_Load (Unit, Routine, Result, Site);
         IR.Emit_Leave (Unit, Routine, Value, Site);
         IR.Leave_Block (Unit, Routine);
         Expect
           (Item, V.Check (Unit), V.Atom_Identity_Not_In_Set,
            "an atom constant outside its structural set is refused");
      end;

      declare
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Site : Landin.Provenance.Origin;
         Unit : IR.Unit;
         Expected, Actual : IR.Atom_Set_Id;
         Signature : IR.Signature_Id;
         Routine : IR.Item_Id;
         Result, Aggregate : IR.Slot_Id;
         Block : IR.Block_Id;
         Value : IR.Value_Id;
      begin
         Ready (Work, Site);
         IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
         Expected := IR.Add_Atom_Set (Unit, [1 => 5]);
         Actual := IR.Add_Atom_Set (Unit, [1 => 6]);
         Signature := IR.Add_Signature
           (Unit, IR.No_Signature_Parts,
            (Kind => Landin.Types.U32, others => <>));
         Routine := IR.Add_Item
           (Unit, IR.Routine, 1, Landin.Types.U32, Site);
         IR.Set_Signature (Unit, Routine, Signature);
         Result := IR.Add_Slot
           (Unit, Routine, Landin.Types.U32, 2, Site);
         Aggregate := IR.Add_Aggregate_Slot
           (Unit, Routine, IR.No_Declaration, Site);
         IR.Add_Slot_Field
           (Unit, Routine, Aggregate,
            (Kind    => IR.Scalar_Field_Shape,
             Element => Landin.Types.U32,
             Length  => 1,
             Atoms   => Expected,
             others  => <>));
         IR.Set_Result_Slot (Unit, Routine, Result);
         Block := IR.Add_Block
           (Unit, Routine, Landin.Resolution.Program_Scope, Site);
         IR.Enter (Unit, Routine, Block);
         Value := IR.Emit_Atom (Unit, Routine, 6, Actual, Site);
         IR.Emit_Store_Slot_Field
           (Unit, Routine, Aggregate, 1, Value, Site);
         Value := IR.Emit_Number
           (Unit, Routine, Landin.Types.U32, 0, False, Site);
         IR.Emit_Store (Unit, Routine, Result, Value, Site);
         Value := IR.Emit_Load (Unit, Routine, Result, Site);
         IR.Emit_Leave (Unit, Routine, Value, Site);
         IR.Leave_Block (Unit, Routine);
         Expect
           (Item, V.Check (Unit), V.Atom_Metadata_Disagrees,
            "an anonymous result field retains its structural atom set");
      end;

      declare
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Site : Landin.Provenance.Origin;
         Unit : IR.Unit;
         Errors : IR.Atom_Set_Id;
         Callee_Signature, Caller_Signature : IR.Signature_Id;
         Callee, Caller : IR.Item_Id;
         Callee_Result, Caller_Result, Wrong : IR.Slot_Id;
         Callee_Block, Caller_Block : IR.Block_Id;
         Value : IR.Value_Id;
      begin
         Ready (Work, Site);
         IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
         Errors := IR.Add_Atom_Set (Unit, [1 => 5]);
         Callee_Signature := IR.Add_Signature
           (Unit, IR.No_Signature_Parts,
            (Kind => Landin.Types.U32, others => <>), Errors);
         Caller_Signature := IR.Add_Signature
           (Unit, IR.No_Signature_Parts,
            (Kind => Landin.Types.U32, others => <>));
         Callee := IR.Add_Item
           (Unit, IR.Routine, 1, Landin.Types.U32, Site);
         Caller := IR.Add_Item
           (Unit, IR.Routine, 3, Landin.Types.U32, Site);
         IR.Set_Signature (Unit, Callee, Callee_Signature);
         IR.Set_Signature (Unit, Caller, Caller_Signature);
         Callee_Result := IR.Add_Slot
           (Unit, Callee, Landin.Types.U32, 2, Site);
         Caller_Result := IR.Add_Slot
           (Unit, Caller, Landin.Types.U32, 4, Site);
         Wrong := IR.Add_Slot
           (Unit, Caller, Landin.Types.Bool, IR.No_Declaration, Site);
         IR.Set_Result_Slot (Unit, Callee, Callee_Result);
         IR.Set_Result_Slot (Unit, Caller, Caller_Result);

         Callee_Block := IR.Add_Block
           (Unit, Callee, Landin.Resolution.Program_Scope, Site);
         IR.Enter (Unit, Callee, Callee_Block);
         Value := IR.Emit_Number
           (Unit, Callee, Landin.Types.U32, 1, False, Site);
         IR.Emit_Store (Unit, Callee, Callee_Result, Value, Site);
         Value := IR.Emit_Load (Unit, Callee, Callee_Result, Site);
         IR.Emit_Leave (Unit, Callee, Value, Site);
         IR.Leave_Block (Unit, Callee);

         Caller_Block := IR.Add_Block
           (Unit, Caller, Landin.Resolution.Program_Scope, Site);
         IR.Enter (Unit, Caller, Caller_Block);
         Value := IR.Emit_Call
           (Unit, Caller, Callee, Landin.Types.U32, Site,
            Failure => Wrong);
         IR.Emit_Store (Unit, Caller, Caller_Result, Value, Site);
         Value := IR.Emit_Load (Unit, Caller, Caller_Result, Site);
         IR.Emit_Leave (Unit, Caller, Value, Site);
         IR.Leave_Block (Unit, Caller);
         Expect
           (Item, V.Check (Unit), V.Call_Failure_Slot_Disagrees,
            "a failing call cannot write an ordinary bool slot");
      end;

      declare
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Site : Landin.Provenance.Origin;
         Unit : IR.Unit;
         Atoms : IR.Atom_Set_Id;
         Signature : IR.Signature_Id;
         Routine : IR.Item_Id;
         Result : IR.Slot_Id;
         Block : IR.Block_Id;
         Value : IR.Value_Id;
      begin
         Ready (Work, Site);
         IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
         Atoms := IR.Add_Atom_Set (Unit, [1 => 5]);
         Signature := IR.Add_Signature
           (Unit, IR.No_Signature_Parts,
            (Kind => Landin.Types.U32, others => <>));
         --  A lowered generic instance is an ordinary local routine item.
         --  Give this malformed failure edge that provenance explicitly: the
         --  verifier must still reject it from the concrete signature, with
         --  no generic-only error opcode or static ABI position to inspect.
         Routine := IR.Add_Routine_Instance_Item
           (Unit, 1, 1, Landin.Types.U32, Site);
         IR.Set_Signature (Unit, Routine, Signature);
         Result := IR.Add_Slot
           (Unit, Routine, Landin.Types.U32, 2, Site);
         IR.Set_Result_Slot (Unit, Routine, Result);
         Block := IR.Add_Block
           (Unit, Routine, Landin.Resolution.Program_Scope, Site);
         IR.Enter (Unit, Routine, Block);
         Value := IR.Emit_Atom (Unit, Routine, 5, Atoms, Site);
         IR.Emit_Fail (Unit, Routine, Value, Site);
         IR.Leave_Block (Unit, Routine);
         Expect
           (Item, V.Check (Unit), V.Fail_Disagrees_With_Signature,
            "an infallible signature cannot contain a failure edge");
      end;
   end Malformed_Error_IR_Is_Rejected;

   procedure Malformed_Evidence_Is_Rejected
     (Item : in out Landin.Testing.Context);

   procedure Malformed_Evidence_Is_Rejected
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

         procedure Build
           (Unit     : in out IR.Unit;
            Caller   : out IR.Item_Id;
            Table    : out IR.Value_Id;
            Function_Value : out IR.Value_Id;
            Wrong_Signature : out IR.Signature_Id);

         procedure Build
           (Unit     : in out IR.Unit;
            Caller   : out IR.Item_Id;
            Table    : out IR.Value_Id;
            Function_Value : out IR.Value_Id;
            Wrong_Signature : out IR.Signature_Id)
         is
            Provider : IR.Item_Id;
            Provider_Signature : IR.Signature_Id;
            Evidence : IR.Evidence_Id;
            Result : IR.Slot_Id;
            Block : IR.Block_Id;
            Value : IR.Value_Id;
         begin
            IR.Prepare (Unit, Meanings.all);
            Provider_Signature := IR.Add_Signature
              (Unit, IR.No_Signature_Parts,
               (Kind => Landin.Types.U32, others => <>));
            Wrong_Signature := IR.Add_Signature
              (Unit, IR.No_Signature_Parts,
               (Kind => Landin.Types.I32, others => <>));
            Provider := IR.Add_Item
              (Unit, IR.Routine, 1, Landin.Types.U32, Site);
            IR.Set_Signature (Unit, Provider, Provider_Signature);
            Result := IR.Add_Slot
              (Unit, Provider, Landin.Types.U32, 2, Site);
            IR.Set_Result_Slot (Unit, Provider, Result);
            Block := IR.Add_Block
              (Unit, Provider, Landin.Resolution.Program_Scope, Site);
            IR.Enter (Unit, Provider, Block);
            Value := IR.Emit_Number
              (Unit, Provider, Landin.Types.U32, 42, False, Site);
            IR.Emit_Store (Unit, Provider, Result, Value, Site);
            Value := IR.Emit_Load (Unit, Provider, Result, Site);
            IR.Emit_Leave (Unit, Provider, Value, Site);
            IR.Leave_Block (Unit, Provider);

            Evidence := IR.Add_Evidence
              (Unit,
               (Kind => IR.Scalar_Field_Shape,
                Element => Landin.Types.U32,
                Length => 1, others => <>));
            IR.Add_Evidence_Entry
              (Unit, Evidence, Provider, Provider_Signature);

            Caller := IR.Add_Item
              (Unit, IR.Routine, 2, Landin.Types.Usize, Site);
            Block := IR.Add_Block
              (Unit, Caller, Landin.Resolution.Program_Scope, Site);
            IR.Enter (Unit, Caller, Block);
            Table := IR.Emit_Evidence_Address
              (Unit, Caller, Evidence, Site);
            Function_Value := IR.Emit_Evidence_Function
              (Unit, Caller, Table, Evidence, 1, Site);
            IR.Emit_Leave (Unit, Caller, Function_Value, Site);
            IR.Leave_Block (Unit, Caller);
         end Build;
      begin
         declare
            Unit : IR.Unit;
            Caller : IR.Item_Id;
            Table, Function_Value : IR.Value_Id;
            Wrong : IR.Signature_Id;
         begin
            Build (Unit, Caller, Table, Function_Value, Wrong);
            Expect (Item, V.Check (Unit), V.Nothing_Wrong,
                    "a sound evidence descriptor and load are accepted");
            Landin.IR.Testing_Support.Overwrite_Value_Evidence
              (Unit, Caller, Table,
               IR.Evidence_Id (IR.Evidence_Count (Unit) + 1));
            Expect (Item, V.Check (Unit), V.Evidence_Out_Of_Range,
                    "an evidence address cannot name an absent table");
         end;

         declare
            Unit : IR.Unit;
            Caller : IR.Item_Id;
            Table, Function_Value : IR.Value_Id;
            Wrong : IR.Signature_Id;
         begin
            Build (Unit, Caller, Table, Function_Value, Wrong);
            Landin.IR.Testing_Support.Overwrite_Value_Evidence_Entry
              (Unit, Caller, Function_Value, 2);
            Expect (Item, V.Check (Unit), V.Evidence_Entry_Out_Of_Range,
                    "an evidence function cannot name an absent entry");
         end;

         declare
            Unit : IR.Unit;
            Caller : IR.Item_Id;
            Table, Function_Value : IR.Value_Id;
            Wrong : IR.Signature_Id;
         begin
            Build (Unit, Caller, Table, Function_Value, Wrong);
            Landin.IR.Testing_Support.Overwrite_Value_Signature
              (Unit, Caller, Function_Value, Wrong);
            Expect
              (Item, V.Check (Unit),
               V.Evidence_Entry_Signature_Disagrees,
               "an evidence function keeps its provider signature");
         end;
      end;
   end Malformed_Evidence_Is_Rejected;

   procedure Malformed_Runtime_Addresses_Are_Rejected
     (Item : in out Landin.Testing.Context);

   procedure Malformed_Runtime_Addresses_Are_Rejected
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Site : Landin.Provenance.Origin;
   begin
      Ready (Work, Site);
      declare
         Unit : IR.Unit;
         Routine : IR.Item_Id;
         Result, Address : IR.Slot_Id;
         Block : IR.Block_Id;
         Value : IR.Value_Id;
         First : Natural;
         Shape : IR.Field_Shape;
      begin
         IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
         Routine := IR.Add_Item
           (Unit, IR.Routine, 1, Landin.Types.U32, Site);
         Result := IR.Add_Slot
           (Unit, Routine, Landin.Types.U32, 2, Site);
         IR.Set_Result_Slot (Unit, Routine, Result);
         First := IR.Add_Shape_Run
           (Unit,
            [(Kind => IR.Scalar_Field_Shape,
              Element => Landin.Types.U32,
              Length => 1, others => <>)]);
         Shape :=
           (Kind => IR.Aggregate_Field_Shape,
            Element => Landin.Types.Bool,
            Length => 1,
            Cases => 1,
            Payloads_First => First,
            Nominal => Test_Nominal (Unit),
            others => <>);
         Address := IR.Add_Address_Slot
           (Unit, Routine, Shape, Site);
         Block := IR.Add_Block
           (Unit, Routine, Landin.Resolution.Program_Scope, Site);
         IR.Enter (Unit, Routine, Block);
         Value := IR.Emit_Number
           (Unit, Routine, Landin.Types.Usize, 0, False, Site);
         IR.Emit_Store (Unit, Routine, Address, Value, Site);
         Value := IR.Emit_Number
           (Unit, Routine, Landin.Types.U32, 0, False, Site);
         IR.Emit_Store (Unit, Routine, Result, Value, Site);
         Value := IR.Emit_Load (Unit, Routine, Result, Site);
         IR.Emit_Leave (Unit, Routine, Value, Site);
         IR.Leave_Block (Unit, Routine);
         Expect
           (Item, V.Check (Unit), V.Address_Value_Disagrees,
            "an integer cannot substitute for a checked storage address");
      end;
   end Malformed_Runtime_Addresses_Are_Rejected;

   procedure Nested_Array_Address_Shapes_Keep_Children
     (Item : in out Landin.Testing.Context);

   procedure Nested_Array_Address_Shapes_Keep_Children
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Site : Landin.Provenance.Origin;
   begin
      Ready (Work, Site);
      for Scenario in 1 .. 3 loop
         declare
            Unit : IR.Unit;
            Routine : IR.Item_Id;
            Result, Address : IR.Slot_Id;
            Block : IR.Block_Id;
            Value : IR.Value_Id;
            First : Natural;
            Child : IR.Field_Shape :=
              (Kind => IR.Array_Field_Shape, Element => Landin.Types.Usize,
               Length => 2, others => <>);
         begin
            IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
            Routine := IR.Add_Item
              (Unit, IR.Routine, 1, Landin.Types.U32, Site);
            Result := IR.Add_Slot
              (Unit, Routine, Landin.Types.U32, 2, Site);
            IR.Set_Result_Slot (Unit, Routine, Result);
            if Scenario = 2 then
               Child := (Kind => IR.Scalar_Field_Shape,
                         Element => Landin.Types.Usize, others => <>);
            elsif Scenario = 3 then
               Child.Cases := 2;
            end if;
            First := IR.Add_Shape_Run (Unit, [1 => Child]);
            Address := IR.Add_Address_Slot
              (Unit, Routine,
               (Kind => IR.Array_Field_Shape, Element => Landin.Types.Usize,
                Length => 3, Cases => 1, Payloads_First => First,
                others => <>), Site);
            Landin.Testing.Check
              (Item, IR.Is_Address (Unit, Routine, Address),
               "the nested array uses an existing address slot");
            Block := IR.Add_Block
              (Unit, Routine, Landin.Resolution.Program_Scope, Site);
            IR.Enter (Unit, Routine, Block);
            Value := IR.Emit_Number
              (Unit, Routine, Landin.Types.U32, 0, False, Site);
            IR.Emit_Store (Unit, Routine, Result, Value, Site);
            Value := IR.Emit_Load (Unit, Routine, Result, Site);
            IR.Emit_Leave (Unit, Routine, Value, Site);
            IR.Leave_Block (Unit, Routine);
            Expect
              (Item, V.Check (Unit),
               (if Scenario in 1 .. 2 then V.Nothing_Wrong
                else V.Runtime_Address_Is_Not_Valid),
               "array children keep complete scalar or compound shapes");
         end;
      end loop;
   end Nested_Array_Address_Shapes_Keep_Children;

   procedure Array_Routine_Parts_Keep_Complete_Children
     (Item : in out Landin.Testing.Context);

   procedure Array_Routine_Parts_Keep_Complete_Children
     (Item : in out Landin.Testing.Context)
   is
      type Scenario_Kind is
        (Legacy_Scalar, Scalar_Versus_Descriptor, Exact_Descriptor,
         Wrong_Descriptor_Length, Legacy_Nominal, Scalar_Versus_Variant,
         Wrong_Explicit_Scalar, Exact_Scalar, Callback_Exact,
         Callback_Convention, Callback_Variadic, Callback_Legacy,
         Callback_Parameter, Callback_Result, Corrupt_Slot_Run);
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Site : Landin.Provenance.Origin;
   begin
      Ready (Work, Site);
      for Scenario in Scenario_Kind loop
         declare
            Unit : IR.Unit;
            Routine : IR.Item_Id;
            Parameter : IR.Slot_Id;
            Signature : IR.Signature_Id;
            Block : IR.Block_Id;
            First : Natural;
            Part : IR.Signature_Part :=
              (Kind => Landin.Types.Fixed_Array, Length => 3,
               Element => Landin.Types.Usize, others => <>);
            Child : IR.Field_Shape :=
              (Kind => IR.Scalar_Field_Shape,
               Element => Landin.Types.Usize, others => <>);
         begin
            IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
            case Scenario is
               when Legacy_Scalar => null;
               when Scalar_Versus_Descriptor | Exact_Descriptor
                    | Wrong_Descriptor_Length =>
                  --  Slice and any carriers use array-shaped children.
                  --  Equal scalar carrier kinds cannot erase that extent.
                  Child.Kind := IR.Array_Field_Shape;
                  Child.Length := 2;
                  if Scenario /= Scalar_Versus_Descriptor then
                     Part.Element_Shape := Child;
                     if Scenario = Wrong_Descriptor_Length then
                        Part.Element_Shape.Length := 3;
                     end if;
                  end if;
               when Legacy_Nominal =>
                  Part.Element := Landin.Types.Bool;
                  Part.Nominal := IR.Add_Nominal_Type (Unit, 3);
                  First := IR.Add_Shape_Run (Unit, [1 => Child]);
                  Child :=
                    (Kind => IR.Aggregate_Field_Shape,
                     Element => Landin.Types.Bool, Length => 1,
                     Cases => 1, Payloads_First => First,
                     Nominal => Part.Nominal, others => <>);
               when Scalar_Versus_Variant =>
                  First := IR.Add_Shape_Run (Unit, [1 => Child]);
                  First := IR.Add_Case_Run
                    (Unit, [1 => (First => First, Count => 1)]);
                  Child :=
                    (Kind => IR.Variant_Field_Shape,
                     Element => Landin.Types.U8, Length => 1,
                     Cases => 1, Payloads_First => First, others => <>);
                  Part.Element := Landin.Types.U8;
               when Wrong_Explicit_Scalar =>
                  Part.Element_Shape :=
                    (Kind => IR.Scalar_Field_Shape,
                     Element => Landin.Types.U32, others => <>);
               when Exact_Scalar =>
                  Part.Element_Shape := Child;
               when Callback_Exact .. Corrupt_Slot_Run =>
                  declare
                     Expected, Actual : IR.Signature_Id;
                  begin
                     Expected := IR.Add_Signature
                       (Unit,
                        [1 => (Kind => Landin.Types.I32, others => <>)],
                        (Kind => Landin.Types.No_Value, others => <>),
                        C_ABI => True);
                     Actual := IR.Add_Signature
                       (Unit,
                        [1 => (Kind =>
                          (if Scenario = Callback_Parameter
                           then Landin.Types.U32 else Landin.Types.I32),
                          others => <>)],
                        (Kind => (if Scenario = Callback_Result
                                  then Landin.Types.I32
                                  else Landin.Types.No_Value), others => <>),
                        C_ABI => Scenario /= Callback_Convention,
                        Variadic => Scenario = Callback_Variadic);
                     Child.Signature := Actual;
                     if Scenario /= Callback_Legacy then
                        Part.Element_Shape :=
                          (Element => Landin.Types.Usize,
                           Signature => Expected, others => <>);
                     end if;
                  end;
            end case;
            Signature := IR.Add_Signature
              (Unit, [1 => Part], (Kind => Landin.Types.No_Value,
                                  others => <>));
            Routine := IR.Add_Item
              (Unit, IR.Routine, 1, Landin.Types.No_Value, Site);
            IR.Set_Signature (Unit, Routine, Signature);
            Parameter := IR.Add_Array_Parameter
              (Unit, Routine, Child, 3, 2, Site);
            Landin.Testing.Check
              (Item, IR.Is_Array (Unit, Routine, Parameter),
               "the parameter holds the separately supplied child shape");
            Block := IR.Add_Block
              (Unit, Routine, Landin.Resolution.Program_Scope, Site);
            IR.Enter (Unit, Routine, Block);
            IR.Emit_Leave (Unit, Routine, IR.No_Value, Site);
            IR.Leave_Block (Unit, Routine);
            if Scenario = Corrupt_Slot_Run then
               IR.Testing_Support.Overwrite_Array_Element_Run
                 (Unit, Routine, Natural'Last, Slot => Parameter);
            end if;
            Expect
              (Item, V.Check (Unit),
               (if Scenario in Legacy_Scalar | Exact_Descriptor
                    | Legacy_Nominal | Exact_Scalar | Callback_Exact
                then V.Nothing_Wrong
                elsif Scenario = Wrong_Explicit_Scalar
                then V.Signature_Part_Malformed
                elsif Scenario in Scalar_Versus_Variant | Corrupt_Slot_Run
                then V.Field_Shape_Malformed
                else V.Routine_Signature_Disagrees),
               "complete array parameter child: " & Scenario'Image);
         end;
      end loop;
   end Array_Routine_Parts_Keep_Complete_Children;

   procedure C_Signatures_And_Linkage_Are_Checked
     (Item : in out Landin.Testing.Context);

   procedure C_Signatures_And_Linkage_Are_Checked
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Site : Landin.Provenance.Origin;
      type Link_Case is
        (Imports_Only, Import_Then_Definition, Definition_Then_Import,
         Two_Definitions, Conflicting_Imports, Variadic_Definition,
         Native_Definition);
   begin
      Ready (Work, Site);
      declare
         Meanings : constant not null access Landin.Resolution.Table :=
           Landin.Stages.Meanings (Work);
      begin
         for Which in Link_Case loop
            declare
               Unit : IR.Unit;
               Signature, Other : IR.Signature_Id;
               Routine : IR.Item_Id;
               Block : IR.Block_Id;
               Parameter : IR.Slot_Id;
               pragma Unreferenced (Parameter);
            begin
               IR.Prepare (Unit, Meanings.all);
               Signature := IR.Add_Signature
                 (Unit,
                  (if Which = Variadic_Definition
                   then [1 => (Kind => Landin.Types.I32, others => <>)]
                   else IR.No_Signature_Parts),
                  (Kind => Landin.Types.No_Value, others => <>),
                  C_ABI => Which /= Native_Definition,
                  Variadic => Which = Variadic_Definition);
               Other := IR.Add_Signature
                 (Unit, IR.No_Signature_Parts,
                  (Kind => Landin.Types.No_Value, others => <>),
                  C_ABI => Which /= Conflicting_Imports);
               for Index in 1 .. (if Which = Native_Definition then 1 else 2)
               loop
                  Routine := IR.Add_Item
                    (Unit, IR.Routine, IR.Declaration_Id (Index),
                     Landin.Types.No_Value, Site);
                  IR.Set_Signature
                    (Unit, Routine,
                     (if Index = 2 and then Which = Conflicting_Imports
                      then Other else Signature));
                  IR.Set_Link_Symbol
                    (Unit, Routine,
                     Landin.Resolution.Name_Of (Meanings.all, 1));
                  if Which in Two_Definitions | Variadic_Definition
                    | Native_Definition
                    or else (Which = Import_Then_Definition and then Index = 2)
                    or else (Which = Definition_Then_Import and then Index = 1)
                  then
                     if Which = Variadic_Definition then
                        Parameter := IR.Add_Parameter
                          (Unit, Routine, Landin.Types.I32,
                           IR.No_Declaration, Site);
                     end if;
                     Block := IR.Add_Block
                       (Unit, Routine, Landin.Resolution.Program_Scope, Site);
                     IR.Enter (Unit, Routine, Block);
                     IR.Emit_Leave (Unit, Routine, IR.No_Value, Site);
                     IR.Leave_Block (Unit, Routine);
                  else
                     IR.Mark_External (Unit, Routine);
                  end if;
               end loop;
               Expect
                 (Item, V.Check (Unit, Landin.Targets.Linux_X86_64),
                  (if Which in Imports_Only | Import_Then_Definition
                      | Definition_Then_Import | Native_Definition
                   then V.Nothing_Wrong else V.Routine_Signature_Disagrees),
                  "C link declarations: " & Which'Image);
            end;
         end loop;

         for Convention in IR.Parameter_Convention loop
            declare
               Unit : IR.Unit;
               Signature : IR.Signature_Id;
            begin
               IR.Prepare (Unit, Meanings.all);
               Signature := IR.Add_Signature
                 (Unit,
                  [1 => (Kind => Landin.Types.Usize,
                         Convention => Convention, Escaping => True,
                         others => <>)],
                  (Kind => Landin.Types.Usize, others => <>),
                  Sources => [1 => (Result => 1, Parameter => 1)],
                  C_ABI => True);
               pragma Unreferenced (Signature);
               Expect
                 (Item, V.Check (Unit, Landin.Targets.Linux_X86_64),
                  (if Convention = IR.In_Value then V.Nothing_Wrong
                   else V.Signature_Part_Malformed),
                  "C permits only in, preserving escaping/from promises");
            end;
         end loop;

         declare
            Unit : IR.Unit;
            Native, Fixed_C, Variadic_C, Empty_Variadic : IR.Signature_Id;
            Parts : constant IR.Signature_Part_Array :=
              [1 => (Kind => Landin.Types.I32, others => <>)];
         begin
            IR.Prepare (Unit, Meanings.all);
            Native := IR.Add_Signature
              (Unit, Parts, (Kind => Landin.Types.No_Value, others => <>));
            Fixed_C := IR.Add_Signature
              (Unit, Parts, (Kind => Landin.Types.No_Value, others => <>),
               C_ABI => True);
            Variadic_C := IR.Add_Signature
              (Unit, Parts, (Kind => Landin.Types.No_Value, others => <>),
               C_ABI => True, Variadic => True);
            Landin.Testing.Check
              (Item, not IR.Signatures_Agree (Unit, Native, Fixed_C)
               and then not IR.Signatures_Agree (Unit, Fixed_C, Variadic_C),
               "convention and variadicness are callable identity");
            Expect
              (Item, V.Check (Unit, Landin.Targets.Synthetic_32),
               V.Signature_Part_Malformed, "C requires a supported target");
            Empty_Variadic := IR.Add_Signature
              (Unit, IR.No_Signature_Parts,
               (Kind => Landin.Types.No_Value, others => <>),
               C_ABI => True, Variadic => True);
            pragma Unreferenced (Empty_Variadic);
            Expect
              (Item, V.Check (Unit), V.Signature_Part_Malformed,
               "a variadic prototype must retain a fixed prefix");
         end;
      end;
   end C_Signatures_And_Linkage_Are_Checked;

   procedure C_Aggregate_Carriers_Are_Checked
     (Item : in out Landin.Testing.Context);

   procedure C_Aggregate_Carriers_Are_Checked
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Site : Landin.Provenance.Origin;
      type Carrier_Case is
        (Sound, Wrong_Parameter, Wrong_Result, Scalar_Tail, Aggregate_Tail,
         Unpromoted_Tail);
   begin
      Ready (Work, Site);
      for Indirect in Boolean loop
         for Which in Carrier_Case loop
            declare
               Unit : IR.Unit;
               Nominal : IR.Nominal_Type_Id;
               Signature : IR.Signature_Id;
               Imported, Caller : IR.Item_Id;
               Storage : IR.Slot_Id;
               Block : IR.Block_Id;
               Code, Address, Integer, Tail, Call : IR.Value_Id;
            begin
               IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
               Nominal := IR.Add_Nominal_Type (Unit, 1);
               IR.Set_Nominal_Shape
                 (Unit, Nominal,
                  [1 => (Kind => IR.Scalar_Field_Shape,
                         Element => Landin.Types.I32, others => <>)],
                  C_Layout => True);
               Signature := IR.Add_Signature
                 (Unit,
                  [1 => (Kind => Landin.Types.Aggregate,
                         Nominal => Nominal, others => <>)],
                  (Kind => Landin.Types.Aggregate,
                   Nominal => Nominal, others => <>),
                  C_ABI => True,
                  Variadic => Which in Scalar_Tail | Aggregate_Tail
                    | Unpromoted_Tail);
               Imported := IR.Add_Item
                 (Unit, IR.Routine, 1, Landin.Types.Aggregate, Site, Nominal);
               IR.Set_Signature (Unit, Imported, Signature);
               IR.Set_Link_Symbol
                 (Unit, Imported, Landin.Resolution.Name_Of
                    (Landin.Stages.Meanings (Work).all, 1));
               IR.Mark_External (Unit, Imported);
               Expect
                 (Item, V.Check (Unit), V.Nothing_Wrong,
                  "an imported aggregate result needs no body result slot");
               Caller := IR.Add_Item
                 (Unit, IR.Routine, 2, Landin.Types.No_Value, Site);
               Storage := IR.Add_Aggregate_Slot
                 (Unit, Caller, IR.No_Declaration, Site, Nominal);
               IR.Add_Slot_Field (Unit, Caller, Storage, Landin.Types.I32);
               Block := IR.Add_Block
                 (Unit, Caller, Landin.Resolution.Program_Scope, Site);
               IR.Enter (Unit, Caller, Block);
               Code := IR.Emit_Function_Address (Unit, Caller, Imported, Site);
               Address := IR.Emit_Storage_Address
                 (Unit, Caller,
                  (Kind => IR.Frame_Slot, Slot => Storage), Site);
               Integer := IR.Emit_Number
                 (Unit, Caller, Landin.Types.Usize, 1, False, Site);
               Tail := IR.Emit_Number
                 (Unit, Caller,
                  (if Which = Unpromoted_Tail
                   then Landin.Types.U8 else Landin.Types.I32),
                  7, False, Site);
               Call :=
                 (if Indirect then IR.Emit_Indirect_Call
                    (Unit, Caller, Signature, Landin.Types.No_Value, Site)
                  else IR.Emit_Call
                    (Unit, Caller, Imported, Landin.Types.No_Value, Site));
               if Indirect then
                  IR.Add_Argument (Unit, Caller, Call, Code);
               end if;
               IR.Add_Argument
                 (Unit, Caller, Call,
                  (if Which = Wrong_Result then Integer else Address));
               IR.Add_Argument
                 (Unit, Caller, Call,
                  (if Which = Wrong_Parameter then Integer else Address));
               if Which in Scalar_Tail | Aggregate_Tail | Unpromoted_Tail then
                  IR.Add_Argument
                    (Unit, Caller, Call,
                     (if Which = Aggregate_Tail then Address else Tail));
               end if;
               IR.Emit_Leave (Unit, Caller, IR.No_Value, Site);
               IR.Leave_Block (Unit, Caller);
               Expect
                 (Item, V.Check (Unit, Landin.Targets.Linux_X86_64),
                  (if Which in Sound | Scalar_Tail then V.Nothing_Wrong
                   else V.Operands_Disagree),
                  "C aggregate call carrier: " & Which'Image
                  & " indirect " & Indirect'Image);
            end;
         end loop;
      end loop;
   end C_Aggregate_Carriers_Are_Checked;

   procedure Canonical_And_Storage_Runs_Are_Checked
     (Item : in out Landin.Testing.Context);

   procedure Canonical_And_Storage_Runs_Are_Checked
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Site : Landin.Provenance.Origin;
      package Damage renames IR.Testing_Support;
   begin
      Ready (Work, Site);
      for Which in Damage.Item_Run_Kind loop
         declare
            Unit : IR.Unit;
            Routine : IR.Item_Id;
         begin
            IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
            Routine := IR.Add_Item
              (Unit, IR.Routine, 1, Landin.Types.No_Value, Site);
            Damage.Overwrite_Item_Run
              (Unit, Routine, Which, Natural'Last, Natural'Last);
            Expect
              (Item, V.Check (Unit), V.Item_Runs_Overlap,
               "storage run bounds precede indexed reads: " & Which'Image);
         end;
      end loop;
      declare
         Unit : IR.Unit;
         Routine : IR.Item_Id;
         Parameter : IR.Slot_Id;
      begin
         IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
         Routine := IR.Add_Item
           (Unit, IR.Routine, 1, Landin.Types.No_Value, Site);
         Parameter := IR.Add_Parameter
           (Unit, Routine, Landin.Types.I32, IR.No_Declaration, Site);
         Damage.Overwrite_Parameter
           (Unit, Routine, Positive (Parameter), IR.No_Slot);
         Expect
           (Item, V.Check (Unit), V.Slot_Out_Of_Range,
            "parameter references are checked before signature slot reads");
      end;
      for Empty in Boolean loop
         declare
            Unit : IR.Unit;
            Nominal : IR.Nominal_Type_Id;
         begin
            IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
            Nominal := IR.Add_Nominal_Type (Unit, 1);
            IR.Set_Nominal_Shape
              (Unit, Nominal,
               (if Empty then IR.No_Field_Shapes
                else [1 => (Kind => IR.Scalar_Field_Shape,
                            Element => Landin.Types.I32, others => <>)]));
            Expect
              (Item, V.Check (Unit), V.Nothing_Wrong,
               "ordinary canonical bodies may be empty");
            Damage.Overwrite_Nominal_Run
              (Unit, Nominal, Natural'Last, Natural'Last);
            Expect
              (Item, V.Check (Unit), V.Nominal_Metadata_Malformed,
               "canonical run validation is subtraction-safe in release");
         end;
      end loop;
      for Cyclic in Boolean loop
         declare
            Unit : IR.Unit;
            Nominal, Outer : IR.Nominal_Type_Id;
            Datum : IR.Item_Id;
            First : Natural;
         begin
            IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
            Nominal := IR.Add_Nominal_Type (Unit, 1);
            if Cyclic then
               IR.Set_Nominal_Shape
                 (Unit, Nominal,
                  [1 => (Kind => IR.Aggregate_Field_Shape,
                         Nominal => Nominal, others => <>)],
                  C_Layout => True);
               Expect
                 (Item, V.Check (Unit), V.Field_Shape_Malformed,
                  "canonical-only recursive storage must terminate");
               Landin.Testing.Check
                 (Item, Ada.Strings.Fixed.Index
                    (IR.Dump.Text
                       (Unit, Landin.Stages.Meanings (Work).all,
                        Landin.Stages.Identities (Work).all),
                     "invalid recursive shape") > 0,
                  "a diagnostic dump also terminates on a canonical cycle");
            else
               IR.Set_Nominal_Shape
                 (Unit, Nominal,
                  [1 => (Kind => IR.Scalar_Field_Shape,
                         Element => Landin.Types.U8, others => <>)]);
               Outer := IR.Add_Nominal_Type (Unit, 2);
               Datum := IR.Add_Item
                 (Unit, IR.Datum, 3, Landin.Types.Aggregate, Site, Outer);
               First := IR.Add_Shape_Run
                 (Unit, [1 => (Kind => IR.Scalar_Field_Shape,
                               Element => Landin.Types.U16, others => <>)]);
               IR.Add_Field
                 (Unit, Datum,
                  (Kind => IR.Aggregate_Field_Shape, Nominal => Nominal,
                   Cases => 1, Payloads_First => First, others => <>));
               Expect
                 (Item, V.Check (Unit), V.Nominal_Shape_Disagrees,
                  "canonical lookup cannot hide a contradictory local body");
            end if;
         end;
      end loop;
   end Canonical_And_Storage_Runs_Are_Checked;

   procedure Recursive_Array_Images_Are_Checked
     (Item : in out Landin.Testing.Context);

   procedure Recursive_Array_Images_Are_Checked
     (Item : in out Landin.Testing.Context)
   is
      type Scenario_Kind is
        (Sound, Finite_Sequence, Mixed_Sequence, Empty_Sequence,
         Zero_Suffix, Bad_Zero_Suffix, Negative_Multiplicity,
         Huge_Multiplicity, Wrong_Coverage, Missing_Children,
         Descendant_Offset, Descendant_Cycle, Fold_Offset, Fold_Count,
         Orphan_Descriptor, Orphan_Fold, Descriptor_Run, Fold_Run,
         Second_Item, Aggregate_Prefix);
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Site : Landin.Provenance.Origin;
   begin
      Ready (Work, Site);
      for Scenario in Scenario_Kind loop
         declare
            Unit : IR.Unit;
            Datum : IR.Item_Id;
            Child, Outer : IR.Field_Shape;
            Length : constant IR.Element_Total :=
              (case Scenario is
                 when Empty_Sequence => 0,
                 when Zero_Suffix | Bad_Zero_Suffix => 1,
                 when Mixed_Sequence => 5,
                 when others => 2);
            Count : constant Natural :=
              (case Scenario is
                 when Empty_Sequence => 0,
                 when Finite_Sequence | Mixed_Sequence | Zero_Suffix
                    | Bad_Zero_Suffix | Orphan_Descriptor => 2,
                 when others => 1);
            Root : IR.Aggregate_Field_Image :=
              (Form => IR.Element_Sequence, Count => Count,
               Value => (if Count = 0 then 0
                         else Landin.Types.Folded
                           (Length - IR.Element_Total (Count - 1))),
               others => <>);
            Children : IR.Aggregate_Field_Image_Array (1 .. Count) :=
              [others => (Form => IR.Finite, Count => 2, others => <>)];
            Folds : constant Landin.Types.Folded_Array
              (1 .. Count * 2 + (if Scenario = Orphan_Fold then 1 else 0)) :=
                [others => 7];
            Expected : V.Fault_Kind := V.Nothing_Wrong;
         begin
            IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
            Child := IR.Make_Array_Shape
              (Unit, 2, (Element => Landin.Types.U8, others => <>));
            Outer := IR.Make_Array_Shape (Unit, Length, Child);
            for Index in Children'Range loop
               Children (Index).Offset := (Index - 1) * 2;
            end loop;
            if Scenario = Second_Item then
               --  Both arenas have nonzero global bases for the next item.
               Datum := IR.Add_Item
                 (Unit, IR.Datum, 6, Landin.Types.Fixed_Array, Site);
               IR.Set_Array (Unit, Datum, Child, Length);
               IR.Set_Array_Image (Unit, Datum, Root, Children, Folds);
               Add_Empty_Body (Unit, Datum, Site);
            end if;
            Datum := IR.Add_Item
              (Unit, IR.Datum, 5,
               (if Scenario = Aggregate_Prefix then Landin.Types.Aggregate
                else Landin.Types.Fixed_Array), Site);
            if Scenario = Aggregate_Prefix then
               IR.Add_Field (Unit, Datum, Landin.Types.U16);
               IR.Add_Field (Unit, Datum, Outer);
               IR.Set_Aggregate_Image
                 (Unit, Datum, [31, 0],
                  [(others => <>), Root], Children, Folds);
            else
               IR.Set_Array (Unit, Datum, Child, Length);
               IR.Set_Array_Image (Unit, Datum, Root, Children, Folds);
            end if;
            Add_Empty_Body (Unit, Datum, Site);
            --  Corrupt after construction: these are verifier checks even
            --  when builder contracts are absent in a release executable.
            case Scenario is
               when Negative_Multiplicity => Root.Value := -1;
               when Huge_Multiplicity =>
                  Root.Value := Landin.Types.Folded'Last;
               when Wrong_Coverage => Root.Value := 1;
               when Missing_Children => Root.Count := Natural'Last;
               when Descendant_Offset => Root.Offset := Natural'Last;
               when Orphan_Descriptor =>
                  Root.Count := 1;
                  Root.Value := 2;
               when others => null;
            end case;
            if Scenario in Negative_Multiplicity .. Descendant_Offset
              or else Scenario = Orphan_Descriptor
            then
               IR.Testing_Support.Overwrite_Image_Descriptor
                 (Unit, Datum, 1, Root);
               Expected := V.Aggregate_Field_Image_Length_Disagrees;
            elsif Scenario in Bad_Zero_Suffix | Descendant_Cycle
              | Fold_Offset | Fold_Count
            then
               declare
                  Position : constant Positive :=
                    (if Scenario = Bad_Zero_Suffix then 2 else 1);
                  Image : IR.Aggregate_Field_Image := Children (Position);
               begin
                  if Scenario = Descendant_Cycle then
                     Image := (Form => IR.Element_Sequence,
                               Count => 1, Value => 2, others => <>);
                  elsif Scenario = Fold_Count then
                     Image.Count := Natural'Last;
                  else
                     Image.Offset := Natural'Last;
                  end if;
                  IR.Testing_Support.Overwrite_Image_Descriptor
                    (Unit, Datum, Position + 1, Image);
               end;
               Expected := V.Aggregate_Field_Image_Length_Disagrees;
            elsif Scenario = Descriptor_Run then
               IR.Testing_Support.Overwrite_Descriptor_Run
                 (Unit, Datum, Natural'Last, 2);
               Expected := V.Item_Runs_Overlap;
            elsif Scenario = Fold_Run then
               IR.Testing_Support.Overwrite_Image_Run
                 (Unit, Datum, Natural'Last, 2);
               Expected := V.Item_Runs_Overlap;
            elsif Scenario = Orphan_Fold then
               Expected := V.Aggregate_Field_Image_Length_Disagrees;
            end if;
            Expect (Item, V.Check (Unit), Expected,
                    "recursive image structure: " & Scenario'Image);
            Expect (Item, V.Check (Unit, Landin.Targets.Linux_X86_64),
                    Expected, "recursive image folds: " & Scenario'Image);
         end;
      end loop;
   end Recursive_Array_Images_Are_Checked;

   procedure Callback_Array_Images_Are_Checked
     (Item : in out Landin.Testing.Context);

   procedure Callback_Array_Images_Are_Checked
     (Item : in out Landin.Testing.Context)
   is
      type Scenario_Kind is
        (Sound, Huge_Repetition, Record_Child, Nested_Array,
         Wrong_Convention, Wrong_Variadicness,
         Wrong_Parameter, Wrong_Result, Missing_Target, Datum_Target,
         Nonzero_Placeholder, Missing_Run, Outside_Run, Cached_Child,
         Shape_Cycle, Signature_Cycle, Array_Signature_Cycle);
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Site : Landin.Provenance.Origin;
   begin
      Ready (Work, Site);
      for Scenario in Scenario_Kind loop
         declare
            Unit : IR.Unit;
            Target, Datum : IR.Item_Id;
            Expected_Signature, Actual_Signature : IR.Signature_Id;
            Child, Outer : IR.Field_Shape;
            Part : IR.Signature_Part :=
              (Kind => Landin.Types.I32, others => <>);
            Result : IR.Signature_Part :=
              (Kind => Landin.Types.No_Value, others => <>);
            Length : constant IR.Element_Total :=
              (if Scenario = Huge_Repetition then 2 ** 32 + 1 else 3);
            Image : IR.Aggregate_Field_Image;
            Expected : V.Fault_Kind := V.Nothing_Wrong;
         begin
            IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
            if Scenario = Wrong_Parameter then
               Part.Kind := Landin.Types.U32;
            elsif Scenario = Wrong_Result then
               Result.Kind := Landin.Types.I32;
            end if;
            Expected_Signature := IR.Add_Signature
              (Unit, [1 => Part], Result,
               C_ABI => Scenario /= Wrong_Convention,
               Variadic => Scenario = Wrong_Variadicness);
            Actual_Signature := IR.Add_Signature
              (Unit, [1 => (Kind => Landin.Types.I32, others => <>)],
               (Kind => Landin.Types.No_Value, others => <>), C_ABI => True);
            Target := IR.Add_Item
              (Unit, IR.Routine, 1, Landin.Types.No_Value, Site);
            IR.Set_Signature (Unit, Target, Actual_Signature);
            IR.Set_Link_Symbol
              (Unit, Target,
               Landin.Resolution.Name_Of
                 (Landin.Stages.Meanings (Work).all, 1));
            IR.Mark_External (Unit, Target);
            Child := (Element => Landin.Types.Usize,
                      Signature => Expected_Signature, others => <>);
            if Scenario = Record_Child then
               declare
                  Nominal : constant IR.Nominal_Type_Id :=
                    Test_Nominal (Unit);
               begin
                  IR.Set_Nominal_Shape (Unit, Nominal, [1 => Child]);
                  Child := (Kind => IR.Aggregate_Field_Shape,
                            Nominal => Nominal, others => <>);
               end;
            elsif Scenario = Nested_Array then
               Child := IR.Make_Array_Shape (Unit, 2, Child);
            end if;
            Datum := IR.Add_Item
              (Unit, IR.Datum, 5, Landin.Types.Fixed_Array, Site);
            IR.Set_Array (Unit, Datum, Child, Length);
            Outer := IR.Whole_Array_Shape (Unit, Datum);
            Image := (Target => Target, others => <>);
            IR.Set_Array_Image
              (Unit, Datum,
               (Form => IR.Element_Sequence, Count => 1,
                Value => Landin.Types.Folded (Length), others => <>),
               (if Scenario in Record_Child | Nested_Array
                then [(Form => (if Scenario = Record_Child then IR.Nested
                                else IR.Element_Sequence),
                       Offset => 1, Count => 1,
                       Value => (if Scenario = Nested_Array then 2 else 0),
                       others => <>), Image]
                else [1 => Image]), []);
            Add_Empty_Body (Unit, Datum, Site);
            case Scenario is
               when Wrong_Convention | Wrong_Variadicness
                  | Wrong_Parameter | Wrong_Result =>
                  Expected := V.Function_Value_Signature_Disagrees;
               when Missing_Target | Datum_Target | Nonzero_Placeholder =>
                  if Scenario = Missing_Target then
                     Image.Target := IR.Item_Id'Last;
                  elsif Scenario = Datum_Target then
                     Image.Target := Datum;
                  else
                     Image.Value := 1;
                  end if;
                  IR.Testing_Support.Overwrite_Image_Descriptor
                    (Unit, Datum, 2, Image);
                  Expected := V.Function_Value_Signature_Disagrees;
               when Missing_Run | Outside_Run =>
                  IR.Testing_Support.Overwrite_Array_Element_Run
                    (Unit, Datum,
                     (if Scenario = Missing_Run then 0 else Natural'Last));
                  Expected := V.Field_Shape_Malformed;
               when Cached_Child | Shape_Cycle =>
                  IR.Testing_Support.Overwrite_Shape
                    (Unit, Outer.Payloads_First,
                     (if Scenario = Shape_Cycle then Outer
                      else (Element => Landin.Types.U32, others => <>)));
                  Expected := V.Field_Shape_Malformed;
               when Signature_Cycle | Array_Signature_Cycle =>
                  Part :=
                    (if Scenario = Signature_Cycle
                     then (Kind => Landin.Types.Function_Value,
                           Signature => Expected_Signature, others => <>)
                     else (Kind => Landin.Types.Fixed_Array, Length => 2,
                           Element => Landin.Types.Usize,
                           Element_Shape => Child, others => <>));
                  IR.Testing_Support.Overwrite_Signature_Parameter
                    (Unit, Expected_Signature, 1, Part);
                  Expected := V.Signature_Part_Malformed;
               when Sound | Huge_Repetition | Record_Child | Nested_Array =>
                  null;
            end case;
            Expect (Item, V.Check (Unit), Expected,
                    "callback image structure: " & Scenario'Image);
            Expect (Item, V.Check (Unit, Landin.Targets.Linux_X86_64),
                    Expected, "callback image target: " & Scenario'Image);
         end;
      end loop;
   end Callback_Array_Images_Are_Checked;

   procedure Typed_Indirect_Witnesses_Are_Checked
     (Item : in out Landin.Testing.Context);

   procedure Typed_Indirect_Witnesses_Are_Checked
     (Item : in out Landin.Testing.Context)
   is
      type Scenario_Kind is
        (Sound, Address_Copy, Legacy_Scalar, Forged_Legacy,
         Missing_Witness, Outside_Witness, Nonaddress_Witness,
         Aggregate_Witness, Other_Witness, Nonload_Operand,
         Other_Load_Operand, Wrong_Result, Wrong_Signature,
         Forged_Address_Load, Wrong_Store_Value, Wrong_Place_Origin,
         Raw_Pointer_Origin, Wrong_Copy_Origin, Callable_Fill, Wrong_Fill,
         Indexed_Origin, Wrong_Indexed_Origin);
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Site : Landin.Provenance.Origin;
   begin
      Ready (Work, Site);
      for Scenario in Scenario_Kind loop
         declare
            Unit : IR.Unit;
            Routine, Target : IR.Item_Id;
            Signature, Equivalent, Other : IR.Signature_Id;
            Cell, Plain, Address, Alternate, Aggregate_Address : IR.Slot_Id;
            Filled : IR.Slot_Id;
            Block : IR.Block_Id;
            Callback, Raw, Origin, Other_Load, Loaded, Stored : IR.Value_Id;
            Child, Aggregate_Child : IR.Field_Shape;
            Expected : V.Fault_Kind := V.Nothing_Wrong;
         begin
            IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
            Signature := IR.Add_Signature
              (Unit, IR.No_Signature_Parts,
               (Kind => Landin.Types.No_Value, others => <>), C_ABI => True);
            Equivalent := IR.Add_Signature
              (Unit, IR.No_Signature_Parts,
               (Kind => Landin.Types.No_Value, others => <>), C_ABI => True);
            Other := IR.Add_Signature
              (Unit, IR.No_Signature_Parts,
               (Kind => Landin.Types.No_Value, others => <>));
            Target := IR.Add_Item
              (Unit, IR.Routine, 3, Landin.Types.No_Value, Site);
            IR.Set_Signature (Unit, Target, Equivalent);
            IR.Set_Link_Symbol
              (Unit, Target,
               Landin.Resolution.Name_Of
                 (Landin.Stages.Meanings (Work).all, 3));
            IR.Mark_External (Unit, Target);
            Routine := IR.Add_Item
              (Unit, IR.Routine, 1, Landin.Types.No_Value, Site);
            Child := (Element => Landin.Types.Usize,
                      Signature => Signature, others => <>);
            Cell := IR.Add_Slot
              (Unit, Routine, Landin.Types.Usize, 2, Site,
               Signature => Equivalent);
            Plain := IR.Add_Slot
              (Unit, Routine, Landin.Types.Usize, IR.No_Declaration, Site);
            Address := IR.Add_Address_Slot (Unit, Routine, Child, Site);
            Alternate := IR.Add_Address_Slot
              (Unit, Routine,
               (if Scenario = Wrong_Copy_Origin
                then (Element => Landin.Types.Usize, others => <>)
                else Child), Site);
            Aggregate_Child := IR.Make_Array_Shape (Unit, 2, Child);
            Aggregate_Address := IR.Add_Address_Slot
              (Unit, Routine, Aggregate_Child, Site);
            Filled := IR.Add_Array_Slot
              (Unit, Routine,
               (if Scenario = Wrong_Indexed_Origin
                then (Element => Landin.Types.Usize,
                      Signature => Other, others => <>) else Child),
               2, IR.No_Declaration, Site);
            Block := IR.Add_Block
              (Unit, Routine, Landin.Resolution.Program_Scope, Site);
            IR.Enter (Unit, Routine, Block);
            Callback := IR.Emit_Function_Address (Unit, Routine, Target, Site);
            IR.Emit_Store (Unit, Routine, Cell, Callback, Site);
            Raw := IR.Emit_Number
              (Unit, Routine, Landin.Types.Usize, 0, False, Site);
            IR.Emit_Store (Unit, Routine, Plain, Raw, Site);
            if Scenario in Callable_Fill | Wrong_Fill | Indexed_Origin then
               IR.Emit_Array_Fill
                 (Unit, Routine, (Kind => IR.Frame_Slot, Slot => Filled), 1,
                  (if Scenario = Wrong_Fill then Raw else Callback), Site);
            end if;
            Origin := IR.Emit_Place_Address
              (Unit, Routine,
               (Kind => IR.Frame_Slot,
                Slot => (if Scenario = Wrong_Place_Origin then Plain
                         else Cell)), Site);
            if Scenario = Raw_Pointer_Origin then
               Origin := IR.Emit_Pointer_Address (Unit, Routine, Raw, Site);
            elsif Scenario in Indexed_Origin | Wrong_Indexed_Origin then
               Origin := IR.Emit_Storage_Address
                 (Unit, Routine, (Kind => IR.Frame_Slot, Slot => Filled),
                  Site, Index => Raw);
            end if;
            IR.Emit_Store (Unit, Routine, Address, Origin, Site);
            Origin := IR.Emit_Place_Address
              (Unit, Routine,
               (Kind => IR.Frame_Slot,
                Slot => (if Scenario = Wrong_Copy_Origin then Plain
                         else Cell)), Site);
            IR.Emit_Store (Unit, Routine, Alternate, Origin, Site);
            Other_Load := IR.Emit_Load (Unit, Routine, Alternate, Site);
            if Scenario in Address_Copy | Wrong_Copy_Origin then
               IR.Emit_Store (Unit, Routine, Address, Other_Load, Site);
            end if;
            if Scenario in Legacy_Scalar | Forged_Legacy then
               Loaded := IR.Emit_Load_Indirect
                 (Unit, Routine, Raw, Landin.Types.Usize, Site);
               IR.Emit_Store_Indirect (Unit, Routine, Raw, Loaded, Site);
            else
               Loaded := IR.Emit_Load_Indirect (Unit, Routine, Address, Site);
               IR.Emit_Store_Indirect (Unit, Routine, Address, Callback, Site);
            end if;
            Stored := IR.Nth_Value
              (Unit, Routine, Block, IR.Length (Unit, Routine, Block));
            IR.Emit_Leave (Unit, Routine, IR.No_Value, Site);
            IR.Leave_Block (Unit, Routine);
            case Scenario is
               when Missing_Witness | Outside_Witness | Nonaddress_Witness
                  | Aggregate_Witness | Other_Witness =>
                  IR.Testing_Support.Overwrite_Indirect_Address_Slot
                    (Unit, Routine, Loaded,
                     (case Scenario is
                        when Missing_Witness => IR.No_Slot,
                        when Outside_Witness => IR.Slot_Id'Last,
                        when Nonaddress_Witness => Cell,
                        when Aggregate_Witness => Aggregate_Address,
                        when others => Alternate));
                  Expected :=
                    (if Scenario = Missing_Witness
                     then V.Function_Value_Signature_Disagrees
                     elsif Scenario = Other_Witness
                     then V.Address_Value_Disagrees
                     else V.Runtime_Address_Is_Not_Valid);
               when Nonload_Operand | Other_Load_Operand =>
                  IR.Testing_Support.Overwrite_Operand
                    (Unit, Routine, Loaded, 1,
                     (if Scenario = Nonload_Operand then Origin
                      else Other_Load));
                  Expected := V.Address_Value_Disagrees;
               when Wrong_Result =>
                  IR.Testing_Support.Overwrite_Value_Type
                    (Unit, Routine, Loaded, Landin.Types.U32);
                  Expected := V.Result_Disagrees;
               when Forged_Legacy | Wrong_Signature =>
                  IR.Testing_Support.Overwrite_Value_Signature
                    (Unit, Routine, Loaded, Other);
                  Expected := V.Function_Value_Signature_Disagrees;
               when Forged_Address_Load =>
                  IR.Testing_Support.Overwrite_Value_Signature
                    (Unit, Routine,
                     IR.Nth_Operand (Unit, Routine, Loaded, 1), Signature);
                  Expected := V.Function_Value_Signature_Disagrees;
               when Wrong_Store_Value =>
                  IR.Testing_Support.Overwrite_Operand
                    (Unit, Routine, Stored, 2, Raw);
                  Expected := V.Function_Value_Signature_Disagrees;
               when Wrong_Place_Origin | Raw_Pointer_Origin
                  | Wrong_Copy_Origin | Wrong_Indexed_Origin =>
                  Expected := V.Address_Value_Disagrees;
               when Wrong_Fill =>
                  Expected := V.Array_Fill_Value_Disagrees;
               when Sound | Address_Copy | Legacy_Scalar | Callable_Fill
                  | Indexed_Origin =>
                  null;
            end case;
            Expect (Item, V.Check (Unit), Expected,
                    "typed indirect witness: " & Scenario'Image);
            Expect (Item, V.Check (Unit, Landin.Targets.Linux_X86_64),
                    Expected, "typed indirect target: " & Scenario'Image);
         end;
      end loop;
   end Typed_Indirect_Witnesses_Are_Checked;

   procedure Range_Bounds_Need_Target_Facts
     (Item : in out Landin.Testing.Context);

   procedure Range_Bounds_Need_Target_Facts
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Site : Landin.Provenance.Origin;
   begin
      Ready (Work, Site);
      for Scenario in 1 .. 3 loop
         declare
            Unit : IR.Unit;
            Routine : IR.Item_Id;
            Block : IR.Block_Id;
            Value, Checked : IR.Value_Id;
            Kind : constant Landin.Types.Integer_Name :=
              (case Scenario is
                 when 1 => Landin.Types.Usize,
                 when 2 => Landin.Types.Isize,
                 when others => Landin.Types.U8);
            Upper : constant Landin.Types.Folded :=
              (if Scenario = 3 then 256 else 2 ** 32);
         begin
            IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
            Routine := IR.Add_Item
              (Unit, IR.Routine, 1, Landin.Types.No_Value, Site);
            Block := IR.Add_Block
              (Unit, Routine, Landin.Resolution.Program_Scope, Site);
            IR.Enter (Unit, Routine, Block);
            Value := IR.Emit_Number (Unit, Routine, Kind, 1, False, Site);
            Checked := IR.Emit_Range_Check
              (Unit, Routine, Value, Kind, 0, Upper, Site);
            pragma Assert (Checked /= IR.No_Value);
            IR.Emit_Leave (Unit, Routine, IR.No_Value, Site);
            IR.Leave_Block (Unit, Routine);
            Expect
              (Item, V.Check (Unit),
               (if Scenario = 3 then V.Result_Disagrees
                else V.Nothing_Wrong),
               "only pointer-sized range limits depend on target facts");
            Expect
              (Item, V.Check (Unit, Landin.Targets.Linux_X86_64),
               (if Scenario = 3 then V.Result_Disagrees
                else V.Nothing_Wrong),
               "a 64-bit range still rejects overflowing fixed-width limits");
            Expect (Item, V.Check (Unit, Landin.Targets.Synthetic_32),
                    V.Result_Disagrees,
                    "32-bit target limits are always checked");
         end;
      end loop;
   end Range_Bounds_Need_Target_Facts;

   procedure Read_Only_Images_Are_Required
     (Item : in out Landin.Testing.Context);

   procedure Read_Only_Images_Are_Required
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Site : Landin.Provenance.Origin;
   begin
      Ready (Work, Site);
      for Width in 1 .. 2 loop
         declare
            Unit : IR.Unit;
            Datum : IR.Item_Id;
         begin
            IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
            Datum := IR.Add_Item
              (Unit, IR.Datum, 5, Landin.Types.Fixed_Array, Site);
            IR.Set_Array
              (Unit, Datum,
               (if Width = 1 then Landin.Types.U8 else Landin.Types.U16), 2);
            IR.Set_Array_Image (Unit, Datum, [42, 0]);
            IR.Mark_Read_Only (Unit, Datum);
            Add_Empty_Body (Unit, Datum, Site);
            Expect (Item, V.Check (Unit), V.Nothing_Wrong,
                    "a complete read-only text image is valid");

            --  Remove the image without orphaning its run.  The marker
            --  survives, so the backend would otherwise read missing folds.
            IR.Testing_Support.Overwrite_Image_Run (Unit, Datum, 0, 0);
            IR.Testing_Support.Truncate_Image_Bytes (Unit, 0);
            Expect (Item, V.Check (Unit), V.Array_Image_Length_Disagrees,
                    "a read-only marker cannot survive a removed image");
            Expect
              (Item, V.Check (Unit, Landin.Targets.Linux_X86_64),
               V.Array_Image_Length_Disagrees,
               "target verification also refuses a missing text image");
         end;

         declare
            Unit : IR.Unit;
            Datum : IR.Item_Id;
         begin
            IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
            Datum := IR.Add_Item
              (Unit, IR.Datum, 5, Landin.Types.Fixed_Array, Site);
            IR.Set_Array
              (Unit, Datum,
               (if Width = 1 then Landin.Types.U8 else Landin.Types.U16), 2);
            IR.Set_Array_Image
              (Unit, Datum,
               (Form => IR.Finite, Count => 2, others => <>), [], [42, 0]);
            IR.Mark_Read_Only (Unit, Datum);
            Add_Empty_Body (Unit, Datum, Site);
            Expect (Item, V.Check (Unit), V.Nothing_Wrong,
                    "a descriptor may hold a read-only text image");
            Expect
              (Item, V.Check (Unit, Landin.Targets.Linux_X86_64),
               V.Nothing_Wrong,
               "a descriptor text image also passes target verification");
         end;
      end loop;
   end Read_Only_Images_Are_Required;

   procedure Recursive_Image_Relocations_And_Widths
     (Item : in out Landin.Testing.Context);

   procedure Recursive_Image_Relocations_And_Widths
     (Item : in out Landin.Testing.Context)
   is
      type Scenario_Kind is
        (Address_Relocation, Nonzero_Placeholder, Missing_Target,
         Writable_Target, Nested_Target, Wide_Scalar, Wide_Fold,
         Null_Slice, Nonempty_Null_Slice, Null_Slice_Offset);
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Site : Landin.Provenance.Origin;
   begin
      Ready (Work, Site);
      for Scenario in Scenario_Kind loop
         declare
            Unit : IR.Unit;
            Datum, Target : IR.Item_Id;
            Child : IR.Field_Shape :=
              (Element => Landin.Types.Usize, others => <>);
            Image : IR.Aggregate_Field_Image;
            Expected : V.Fault_Kind := V.Nothing_Wrong;
         begin
            IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
            Target := IR.Add_Item
              (Unit, IR.Datum, 6, Landin.Types.Fixed_Array, Site);
            if Scenario = Nested_Target then
               Child := IR.Make_Array_Shape
                 (Unit, 2, (Element => Landin.Types.U8, others => <>));
               IR.Set_Array (Unit, Target, Child, 2);
               IR.Set_Array_Image
                 (Unit, Target,
                  (Form => IR.Element_Sequence, Count => 1, Value => 2,
                   others => <>),
                  [1 => (Form => IR.Finite, Count => 2, others => <>)],
                  [0, 0]);
            else
               IR.Set_Array (Unit, Target, Landin.Types.U8, 2);
               IR.Set_Array_Image (Unit, Target, [0, 0]);
               if Scenario /= Writable_Target then
                  IR.Mark_Read_Only (Unit, Target);
               end if;
            end if;
            Add_Empty_Body (Unit, Target, Site);
            Datum := IR.Add_Item
              (Unit, IR.Datum, 5, Landin.Types.Fixed_Array, Site);
            Child := (Element => Landin.Types.Usize, others => <>);
            if Scenario in Null_Slice .. Null_Slice_Offset then
               IR.Set_Array (Unit, Datum, Child, 2);
               IR.Set_Slice_Image
                 (Unit, Datum, Child,
                  (if Scenario = Nonempty_Null_Slice then 1 else 0),
                  First => (if Scenario = Null_Slice_Offset then 1 else 0));
               if Scenario /= Null_Slice then
                  Expected := V.Array_Image_Length_Disagrees;
               end if;
            else
               Image := (Target => Target, others => <>);
               if Scenario = Nonzero_Placeholder then
                  Image.Value := 1;
               elsif Scenario = Missing_Target then
                  Image.Target := IR.Item_Id'Last;
               elsif Scenario in Wide_Scalar | Wide_Fold then
                  Image := (Value => 2 ** 32, others => <>);
               end if;
               if Scenario = Wide_Fold then
                  Child := IR.Make_Array_Shape (Unit, 1, Child);
                  Image := (Form => IR.Finite, Count => 1, others => <>);
               end if;
               IR.Set_Array (Unit, Datum, Child, 1);
               IR.Set_Array_Image
                 (Unit, Datum,
                  (Form => IR.Element_Sequence, Count => 1, Value => 1,
                   others => <>), [1 => Image],
                  (if Scenario = Wide_Fold then [1 => 2 ** 32] else []));
               if Scenario in Nonzero_Placeholder .. Nested_Target then
                  Expected := V.Address_Value_Disagrees;
               end if;
            end if;
            Add_Empty_Body (Unit, Datum, Site);
            Expect (Item, V.Check (Unit), Expected,
                    "recursive relocation structure: " & Scenario'Image);
            Expect (Item, V.Check (Unit, Landin.Targets.Linux_X86_64),
                    Expected,
                    "recursive relocation 64-bit: " & Scenario'Image);
            Expect
              (Item, V.Check (Unit, Landin.Targets.Synthetic_32),
               (if Scenario in Wide_Scalar | Wide_Fold
                then V.Aggregate_Field_Image_Value_Does_Not_Fit else Expected),
               "recursive relocation 32-bit: " & Scenario'Image);
         end;
      end loop;
   end Recursive_Image_Relocations_And_Widths;

   procedure Atom_Comparisons_Keep_Identity
     (Item : in out Landin.Testing.Context);

   procedure Atom_Comparisons_Keep_Identity
     (Item : in out Landin.Testing.Context)
   is
      type Scenario_Kind is
        (Disjoint, Overlap, Same_Set, Numeric_Right, Invalid_Set,
         Ordered, Arithmetic);
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Site : Landin.Provenance.Origin;
   begin
      Ready (Work, Site);
      for Scenario in Scenario_Kind loop
         for Equal in Boolean loop
            declare
               Unit : IR.Unit;
               Routine : IR.Item_Id;
               Left_Set, Right_Set : IR.Atom_Set_Id;
               Block : IR.Block_Id;
               Left, Right, Compared : IR.Value_Id;
               Op : constant IR.Binary_Kind :=
                 (if Scenario = Ordered then IR.Less_Than
                  elsif Scenario = Arithmetic then IR.Add
                  elsif Equal then IR.Equal_To else IR.Not_Equal_To);
            begin
               IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
               Left_Set := IR.Add_Atom_Set (Unit, [1, 2]);
               Right_Set := IR.Add_Atom_Set
                 (Unit, (if Scenario = Disjoint then IR.Atom_Array'[3, 4]
                         elsif Scenario = Overlap then IR.Atom_Array'[2, 3]
                         else IR.Atom_Array'[1, 2]));
               Routine := IR.Add_Item
                 (Unit, IR.Routine, 1, Landin.Types.No_Value, Site);
               Block := IR.Add_Block
                 (Unit, Routine, Landin.Resolution.Program_Scope, Site);
               IR.Enter (Unit, Routine, Block);
               Left := IR.Emit_Atom (Unit, Routine, 1, Left_Set, Site);
               Right :=
                 (if Scenario = Numeric_Right then IR.Emit_Number
                    (Unit, Routine, Landin.Types.U32, 6, False, Site)
                  else IR.Emit_Atom
                    (Unit, Routine,
                     (if Scenario = Disjoint then 3 else 2), Right_Set, Site));
               if Scenario = Invalid_Set then
                  IR.Testing_Support.Overwrite_Value_Atoms
                    (Unit, Routine, Right, IR.Atom_Set_Id'Last);
               end if;
               Compared := IR.Emit_Binary
                 (Unit, Routine, Op, Left, Right,
                  (if Scenario = Arithmetic then Landin.Types.U32
                   else Landin.Types.Bool), Site);
               pragma Unreferenced (Compared);
               IR.Emit_Leave (Unit, Routine, IR.No_Value, Site);
               IR.Leave_Block (Unit, Routine);
               Expect
                 (Item, V.Check (Unit),
                  (if Scenario in Disjoint | Overlap | Same_Set
                   then V.Nothing_Wrong else V.Atom_Metadata_Disagrees),
                  "atom comparison identity: " & Scenario'Image);
            end;
         end loop;
      end loop;
   end Atom_Comparisons_Keep_Identity;

   procedure Typed_Indirect_Atoms_Are_Checked
     (Item : in out Landin.Testing.Context);

   procedure Typed_Indirect_Atoms_Are_Checked
     (Item : in out Landin.Testing.Context)
   is
      type Scenario_Kind is
        (Sound, Wrong_Load, Wrong_Store, Address_Metadata, Legacy_Metadata);
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Site : Landin.Provenance.Origin;
   begin
      Ready (Work, Site);
      for Scenario in Scenario_Kind loop
         declare
            Unit : IR.Unit;
            Routine : IR.Item_Id;
            Expected, Equivalent, Other : IR.Atom_Set_Id;
            Cell, Address : IR.Slot_Id;
            Block : IR.Block_Id;
            Value, Wrong, Origin, Loaded, Stored : IR.Value_Id;
         begin
            IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
            Expected := IR.Add_Atom_Set (Unit, [1 => 5]);
            Equivalent := IR.Add_Atom_Set (Unit, [1 => 5]);
            Other := IR.Add_Atom_Set (Unit, [1 => 6]);
            Routine := IR.Add_Item
              (Unit, IR.Routine, 1, Landin.Types.No_Value, Site);
            Cell := IR.Add_Slot
              (Unit, Routine, Landin.Types.U32, 2, Site, Atoms => Equivalent);
            Address := IR.Add_Address_Slot
              (Unit, Routine, (Element => Landin.Types.U32,
                               Atoms => Expected, others => <>), Site);
            Block := IR.Add_Block
              (Unit, Routine, Landin.Resolution.Program_Scope, Site);
            IR.Enter (Unit, Routine, Block);
            Value := IR.Emit_Atom (Unit, Routine, 5, Equivalent, Site);
            Wrong := IR.Emit_Atom (Unit, Routine, 6, Other, Site);
            IR.Emit_Store (Unit, Routine, Cell, Value, Site);
            Origin := IR.Emit_Place_Address
              (Unit, Routine, (Kind => IR.Frame_Slot, Slot => Cell), Site);
            IR.Emit_Store (Unit, Routine, Address, Origin, Site);
            if Scenario = Legacy_Metadata then
               Loaded := IR.Emit_Load_Indirect
                 (Unit, Routine, Origin, Landin.Types.U32, Site);
            else
               Loaded := IR.Emit_Load_Indirect (Unit, Routine, Address, Site);
            end if;
            IR.Emit_Store_Indirect (Unit, Routine, Address, Value, Site);
            Stored := IR.Nth_Value
              (Unit, Routine, Block, IR.Length (Unit, Routine, Block));
            IR.Emit_Leave (Unit, Routine, IR.No_Value, Site);
            IR.Leave_Block (Unit, Routine);
            case Scenario is
               when Wrong_Load | Legacy_Metadata =>
                  IR.Testing_Support.Overwrite_Value_Atoms
                    (Unit, Routine, Loaded, Other);
               when Wrong_Store =>
                  IR.Testing_Support.Overwrite_Operand
                    (Unit, Routine, Stored, 2, Wrong);
               when Address_Metadata =>
                  IR.Testing_Support.Overwrite_Value_Atoms
                    (Unit, Routine,
                     IR.Nth_Operand (Unit, Routine, Loaded, 1), Expected);
               when Sound => null;
            end case;
            Expect
              (Item, V.Check (Unit),
               (if Scenario = Sound then V.Nothing_Wrong
                else V.Atom_Metadata_Disagrees),
               "typed indirect atom shape: " & Scenario'Image);
         end;
      end loop;
   end Typed_Indirect_Atoms_Are_Checked;

   procedure Pointer_Origins_Are_Checked
     (Item : in out Landin.Testing.Context);

   procedure Pointer_Origins_Are_Checked
     (Item : in out Landin.Testing.Context)
   is
      type Scenario_Kind is
        (Direct_Place, Saved_Alias, Integer_Cast, Forged_Number,
         Forged_Conversion, Wrong_Referent, Missing_Pointee,
         Uninitialised_Pointer, Uninitialised_Address, Forged_Load,
         Invalid_Pointee, Zero_Check_Missing);
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Site : Landin.Provenance.Origin;
   begin
      Ready (Work, Site);
      for Wide in Boolean loop
         for Scenario in Scenario_Kind loop
            declare
               Facts : constant Landin.Targets.Target_Facts :=
                 (if Wide then Landin.Targets.Linux_X86_64
                  else Landin.Targets.Synthetic_32);
               Unit : IR.Unit;
               Routine, Target : IR.Item_Id;
               Inner, Signature, Other : IR.Signature_Id;
               Reached, Wrong : IR.Pointee_Id;
               Child : IR.Field_Shape;
               Parameter, Cell, Saved, Address : IR.Slot_Id;
               Block : IR.Block_Id;
               Callback, Raw, Pointer, Origin, Loaded : IR.Value_Id;
               Expected : constant V.Fault_Kind :=
                 (if Scenario in Direct_Place .. Integer_Cast
                  then V.Nothing_Wrong else V.Address_Value_Disagrees);
            begin
               IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
               Inner := IR.Add_Signature
                 (Unit, IR.No_Signature_Parts,
                  (Kind => Landin.Types.No_Value, others => <>),
                  C_ABI => Wide);
               Signature := IR.Add_Signature
                 (Unit, [1 => (Kind => Landin.Types.Function_Value,
                               Signature => Inner, others => <>)],
                  (Kind => Landin.Types.No_Value, others => <>),
                  C_ABI => Wide);
               Other := IR.Add_Signature
                 (Unit,
                  [(Kind => Landin.Types.Function_Value,
                    Signature => Inner, others => <>),
                   (Kind => Landin.Types.I32, others => <>)],
                  (Kind => Landin.Types.No_Value, others => <>),
                  C_ABI => Wide);
               Child := (Element => Landin.Types.Usize,
                         Signature => Signature, others => <>);
               Reached := IR.Add_Pointee (Unit, Child);
               Wrong := IR.Add_Pointee
                 (Unit, (Element => Landin.Types.Usize,
                         Signature => Other, others => <>));
               Target := IR.Add_Item
                 (Unit, IR.Routine, 3, Landin.Types.No_Value, Site);
               IR.Set_Signature (Unit, Target, Signature);
               Parameter := IR.Add_Parameter
                 (Unit, Target, Landin.Types.Usize, 4, Site,
                  Signature => Inner);
               pragma Assert (IR.Holds (Unit, Target, Parameter));
               IR.Set_Link_Symbol
                 (Unit, Target, Landin.Resolution.Name_Of
                    (Landin.Stages.Meanings (Work).all, 3));
               Add_Empty_Body (Unit, Target, Site);
               Routine := IR.Add_Item
                 (Unit, IR.Routine, 1, Landin.Types.No_Value, Site);
               Cell := IR.Add_Slot
                 (Unit, Routine, Landin.Types.Usize, 2, Site,
                  Signature => Signature);
               Saved := IR.Add_Slot
                 (Unit, Routine, Landin.Types.Usize, IR.No_Declaration, Site,
                  Pointee => Reached);
               Address := IR.Add_Address_Slot (Unit, Routine, Child, Site);
               Block := IR.Add_Block
                 (Unit, Routine, Landin.Resolution.Program_Scope, Site);
               IR.Enter (Unit, Routine, Block);
               Callback := IR.Emit_Function_Address
                 (Unit, Routine, Target, Site);
               IR.Emit_Store (Unit, Routine, Cell, Callback, Site);
               Raw := IR.Emit_Number
                 (Unit, Routine, Landin.Types.Usize, 4096, False, Site);
               if Scenario in Integer_Cast | Forged_Conversion
                 | Zero_Check_Missing
               then
                  Pointer := IR.Emit_Conversion
                    (Unit, Routine, Raw, Landin.Types.Usize, Site);
                  if Scenario /= Forged_Conversion then
                     Pointer := IR.Emit_Range_Check
                       (Unit, Routine, Pointer, Landin.Types.Usize,
                        (if Scenario = Zero_Check_Missing then 0 else 1),
                        Landin.Types.Folded
                          (Landin.Targets.Maximum_Object_Size (Facts)), Site);
                  end if;
               elsif Scenario = Forged_Number then
                  Pointer := Raw;
               else
                  Pointer := IR.Emit_Place_Address
                    (Unit, Routine,
                     (Kind => IR.Frame_Slot, Slot => Cell), Site);
               end if;
               if Scenario /= Missing_Pointee then
                  IR.Set_Pointee
                    (Unit, Routine, Pointer,
                     (if Scenario = Wrong_Referent then Wrong else Reached));
               end if;
               if Scenario in Saved_Alias | Uninitialised_Pointer
                 | Forged_Load
               then
                  if Scenario /= Uninitialised_Pointer then
                     IR.Emit_Store (Unit, Routine, Saved, Pointer, Site);
                  end if;
                  Pointer := IR.Emit_Load (Unit, Routine, Saved, Site);
                  if Scenario = Forged_Load then
                     IR.Testing_Support.Overwrite_Value_Pointee
                       (Unit, Routine, Pointer, Wrong);
                  end if;
               elsif Scenario = Invalid_Pointee then
                  IR.Testing_Support.Overwrite_Value_Pointee
                    (Unit, Routine, Pointer, IR.Pointee_Id'Last);
               end if;
               Origin := IR.Emit_Pointer_Address
                 (Unit, Routine, Pointer, Site);
               if Scenario /= Uninitialised_Address then
                  IR.Emit_Store (Unit, Routine, Address, Origin, Site);
               end if;
               Loaded := IR.Emit_Load_Indirect (Unit, Routine, Address, Site);
               IR.Emit_Store_Indirect (Unit, Routine, Address, Loaded, Site);
               IR.Emit_Leave (Unit, Routine, IR.No_Value, Site);
               IR.Leave_Block (Unit, Routine);
               Expect (Item, V.Check (Unit), Expected,
                       "pointer origin structure: " & Scenario'Image);
               Expect (Item, V.Check (Unit, Facts), Expected,
                       "pointer origin target: " & Scenario'Image);
            end;
         end loop;
      end loop;
   end Pointer_Origins_Are_Checked;

   procedure Inout_Reached_Types_Are_Checked
     (Item : in out Landin.Testing.Context);

   procedure Inout_Reached_Types_Are_Checked
     (Item : in out Landin.Testing.Context)
   is
      type Scenario_Kind is
        (Sound, Forwarded, Saved_Argument, Wrong_Parameter, Erased_Parameter,
         Plain_Parameter, Wrong_Argument, Raw_Argument,
         Uninitialised_Argument);
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Site : Landin.Provenance.Origin;
   begin
      Ready (Work, Site);
      for Atoms in Boolean loop
         for Scenario in Scenario_Kind loop
            declare
               Unit : IR.Unit;
               Caller, Callee, Target : IR.Item_Id;
               Callback_Type, Other_Callback, Signature : IR.Signature_Id;
               Atom_Type, Other_Atoms : IR.Atom_Set_Id;
               Reached : IR.Pointee_Id;
               Child, Other_Child : IR.Field_Shape;
               Parameter, Cell, Saved : IR.Slot_Id;
               Block : IR.Block_Id;
               Loaded, Address, Value, Called : IR.Value_Id;
               Expected : constant V.Fault_Kind :=
                 (case Scenario is
                     when Sound | Forwarded | Saved_Argument =>
                        V.Nothing_Wrong,
                     when Wrong_Parameter | Plain_Parameter =>
                        V.Routine_Signature_Disagrees,
                     when Erased_Parameter => V.Signature_Part_Malformed,
                     when Uninitialised_Argument => V.Address_Value_Disagrees,
                     when others => V.Operands_Disagree);
            begin
               IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
               Callback_Type := IR.Add_Signature
                 (Unit, IR.No_Signature_Parts,
                  (Kind => Landin.Types.No_Value, others => <>),
                  C_ABI => True);
               Other_Callback := IR.Add_Signature
                 (Unit, IR.No_Signature_Parts,
                  (Kind => Landin.Types.No_Value, others => <>));
               Atom_Type := IR.Add_Atom_Set (Unit, [1 => 5]);
               Other_Atoms := IR.Add_Atom_Set (Unit, [1 => 6]);
               Child :=
                 (if Atoms then (Element => Landin.Types.U32,
                                 Atoms => Atom_Type, others => <>)
                  else (Element => Landin.Types.Usize,
                        Signature => Callback_Type, others => <>));
               Other_Child :=
                 (if Atoms then (Element => Landin.Types.U32,
                                 Atoms => Other_Atoms, others => <>)
                  else (Element => Landin.Types.Usize,
                        Signature => Other_Callback, others => <>));
               Reached := IR.Add_Pointee (Unit, Child);
               Signature := IR.Add_Signature
                 (Unit,
                  [1 => (Kind => Landin.Types.Usize,
                         Convention => IR.Inout_Place,
                         Pointee =>
                           (if Scenario = Erased_Parameter
                            then IR.No_Pointee else Reached), others => <>)],
                  (Kind => Landin.Types.No_Value, others => <>));
               Target := IR.Add_Item
                 (Unit, IR.Routine, 5, Landin.Types.No_Value, Site);
               IR.Set_Signature (Unit, Target, Callback_Type);
               IR.Set_Link_Symbol
                 (Unit, Target, Landin.Resolution.Name_Of
                    (Landin.Stages.Meanings (Work).all, 5));
               IR.Mark_External (Unit, Target);
               Callee := IR.Add_Item
                 (Unit, IR.Routine, 3, Landin.Types.No_Value, Site);
               IR.Set_Signature (Unit, Callee, Signature);
               if Scenario = Plain_Parameter then
                  Parameter := IR.Add_Parameter
                    (Unit, Callee, Landin.Types.Usize,
                     IR.No_Declaration, Site);
               else
                  Parameter := IR.Add_Address_Parameter
                    (Unit, Callee,
                     (if Scenario = Wrong_Parameter then Other_Child
                      else Child), 4, Site);
               end if;
               Block := IR.Add_Block
                 (Unit, Callee, Landin.Resolution.Program_Scope, Site);
               IR.Enter (Unit, Callee, Block);
               if Scenario /= Plain_Parameter then
                  Loaded := IR.Emit_Load_Indirect
                    (Unit, Callee, Parameter, Site);
                  IR.Emit_Store_Indirect
                    (Unit, Callee, Parameter, Loaded, Site);
               end if;
               IR.Emit_Leave (Unit, Callee, IR.No_Value, Site);
               IR.Leave_Block (Unit, Callee);
               Caller := IR.Add_Item
                 (Unit, IR.Routine, 1, Landin.Types.No_Value, Site);
               if Scenario = Forwarded then
                  IR.Set_Signature (Unit, Caller, Signature);
                  Cell := IR.Add_Address_Parameter
                    (Unit, Caller, Child, 2, Site);
               else
                  Cell := IR.Add_Slot
                    (Unit, Caller,
                     (if Scenario = Wrong_Argument then Landin.Types.Usize
                      else Child.Element), IR.No_Declaration, Site,
                     Signature => (if Scenario = Wrong_Argument
                                   then IR.No_Signature else Child.Signature),
                     Atoms => (if Scenario = Wrong_Argument
                               then IR.No_Atom_Set else Child.Atoms));
               end if;
               Saved := IR.Add_Address_Slot (Unit, Caller, Child, Site);
               Block := IR.Add_Block
                 (Unit, Caller, Landin.Resolution.Program_Scope, Site);
               IR.Enter (Unit, Caller, Block);
               if Scenario = Forwarded then
                  Address := IR.Emit_Load (Unit, Caller, Cell, Site);
               else
                  Value :=
                    (if Scenario = Wrong_Argument then IR.Emit_Number
                       (Unit, Caller, Landin.Types.Usize, 4096, False, Site)
                     elsif Atoms then IR.Emit_Atom
                       (Unit, Caller, 5, Atom_Type, Site)
                     else IR.Emit_Function_Address
                       (Unit, Caller, Target, Site));
                  IR.Emit_Store (Unit, Caller, Cell, Value, Site);
                  Address := IR.Emit_Place_Address
                    (Unit, Caller,
                     (Kind => IR.Frame_Slot, Slot => Cell), Site);
               end if;
               if Scenario = Raw_Argument then
                  Address := IR.Emit_Number
                    (Unit, Caller, Landin.Types.Usize, 4096, False, Site);
               elsif Scenario in Saved_Argument | Uninitialised_Argument then
                  if Scenario = Saved_Argument then
                     IR.Emit_Store (Unit, Caller, Saved, Address, Site);
                  end if;
                  Address := IR.Emit_Load (Unit, Caller, Saved, Site);
               end if;
               Called := IR.Emit_Call
                 (Unit, Caller, Callee, Landin.Types.No_Value, Site);
               IR.Add_Argument (Unit, Caller, Called, Address);
               pragma Assert (Called /= IR.No_Value);
               IR.Emit_Leave (Unit, Caller, IR.No_Value, Site);
               IR.Leave_Block (Unit, Caller);
               Expect (Item, V.Check (Unit), Expected,
                       "inout complete reached type: " & Scenario'Image);
            end;
         end loop;
      end loop;
   end Inout_Reached_Types_Are_Checked;

   procedure Pointee_Graphs_Are_Checked
     (Item : in out Landin.Testing.Context);

   procedure Pointee_Graphs_Are_Checked
     (Item : in out Landin.Testing.Context)
   is
      type Scenario_Kind is
        (Nominal_Link, Invalid_Edge, Pointer_Cycle, Callable_Cycle, Bad_Run);
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Site : Landin.Provenance.Origin;
   begin
      Ready (Work, Site);
      pragma Assert (Landin.Provenance.Is_Known (Site));
      for Scenario in Scenario_Kind loop
         declare
            Unit : IR.Unit;
            Reached : IR.Pointee_Id;
            Signature : IR.Signature_Id;
            Nominal : IR.Nominal_Type_Id;
            Expected : constant V.Fault_Kind :=
              (case Scenario is
                  when Nominal_Link => V.Nothing_Wrong,
                  when Callable_Cycle => V.Signature_Part_Malformed,
                  when others => V.Field_Shape_Malformed);
         begin
            IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
            Reached := IR.Add_Pointee
              (Unit, (Element => Landin.Types.U8, others => <>));
            case Scenario is
               when Nominal_Link =>
                  Nominal := IR.Add_Nominal_Type (Unit, 1);
                  IR.Testing_Support.Overwrite_Pointee
                    (Unit, Reached, (Kind => IR.Aggregate_Field_Shape,
                                     Nominal => Nominal, others => <>));
                  IR.Set_Nominal_Shape
                    (Unit, Nominal,
                     [1 => (Element => Landin.Types.Usize,
                            Pointee => Reached, others => <>)]);
               when Invalid_Edge | Pointer_Cycle =>
                  IR.Testing_Support.Overwrite_Pointee
                    (Unit, Reached,
                     (Element => Landin.Types.Usize,
                      Pointee => (if Scenario = Invalid_Edge
                                  then IR.Pointee_Id'Last else Reached),
                      others => <>));
               when Callable_Cycle =>
                  Signature := IR.Add_Signature
                    (Unit, [1 => (Kind => Landin.Types.Usize,
                                  Pointee => Reached, others => <>)],
                     (Kind => Landin.Types.No_Value, others => <>));
                  IR.Testing_Support.Overwrite_Pointee
                    (Unit, Reached, (Element => Landin.Types.Usize,
                                     Signature => Signature, others => <>));
               when Bad_Run =>
                  IR.Testing_Support.Overwrite_Pointee
                    (Unit, Reached,
                     (Kind => IR.Array_Field_Shape,
                      Element => Landin.Types.Usize, Length => 2, Cases => 1,
                      Payloads_First => Natural'Last, others => <>));
            end case;
            Expect (Item, V.Check (Unit), Expected,
                    "pointee graph: " & Scenario'Image);
         end;
      end loop;
   end Pointee_Graphs_Are_Checked;

   procedure Address_Initialisation_Is_Checked
     (Item : in out Landin.Testing.Context);

   procedure Address_Initialisation_Is_Checked
     (Item : in out Landin.Testing.Context)
   is
      type Scenario_Kind is
        (Both_Arms, One_Arm, Initialised_Loop, Uninitialised_Loop);
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Site : Landin.Provenance.Origin;
   begin
      Ready (Work, Site);
      for Scenario in Scenario_Kind loop
         declare
            Unit : IR.Unit;
            Routine : IR.Item_Id;
            Cell, Address : IR.Slot_Id;
            Blocks : array (1 .. 4) of IR.Block_Id;
            Origin, Loaded, Condition : IR.Value_Id;
            Looping : constant Boolean :=
              Scenario in Initialised_Loop | Uninitialised_Loop;
         begin
            IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
            Routine := IR.Add_Item
              (Unit, IR.Routine, 1, Landin.Types.No_Value, Site);
            Cell := IR.Add_Slot
              (Unit, Routine, Landin.Types.U32, 2, Site);
            Address := IR.Add_Address_Slot
              (Unit, Routine, (Element => Landin.Types.U32, others => <>),
               Site);
            for B in Blocks'Range loop
               Blocks (B) := IR.Add_Block
                 (Unit, Routine, Landin.Resolution.Program_Scope, Site);
            end loop;
            IR.Enter (Unit, Routine, Blocks (1));
            if Scenario = Initialised_Loop then
               Origin := IR.Emit_Place_Address
                 (Unit, Routine, (Kind => IR.Frame_Slot, Slot => Cell), Site);
               IR.Emit_Store (Unit, Routine, Address, Origin, Site);
            end if;
            Condition := IR.Emit_Truth (Unit, Routine, True, Site);
            if Looping then
               IR.Emit_Jump (Unit, Routine, Blocks (2), Site);
            else
               IR.Emit_Branch
                 (Unit, Routine, Condition, Blocks (2), Blocks (3), Site);
            end if;
            IR.Leave_Block (Unit, Routine);
            for B in 2 .. 3 loop
               IR.Enter (Unit, Routine, Blocks (B));
               if Looping and then B = 2 then
                  Loaded := IR.Emit_Load_Indirect
                    (Unit, Routine, Address, Site);
                  IR.Emit_Store_Indirect
                    (Unit, Routine, Address, Loaded, Site);
               end if;
               if B = 2 or else Scenario /= One_Arm then
                  Origin := IR.Emit_Place_Address
                    (Unit, Routine,
                     (Kind => IR.Frame_Slot, Slot => Cell), Site);
                  IR.Emit_Store (Unit, Routine, Address, Origin, Site);
               end if;
               if Looping and then B = 2 then
                  Condition := IR.Emit_Truth (Unit, Routine, False, Site);
                  IR.Emit_Branch
                    (Unit, Routine, Condition, Blocks (2), Blocks (3), Site);
               else
                  IR.Emit_Jump (Unit, Routine, Blocks (4), Site);
               end if;
               IR.Leave_Block (Unit, Routine);
            end loop;
            IR.Enter (Unit, Routine, Blocks (4));
            Loaded := IR.Emit_Load_Indirect (Unit, Routine, Address, Site);
            IR.Emit_Store_Indirect (Unit, Routine, Address, Loaded, Site);
            IR.Emit_Leave (Unit, Routine, IR.No_Value, Site);
            IR.Leave_Block (Unit, Routine);
            Expect
              (Item, V.Check (Unit),
               (if Scenario in Both_Arms | Initialised_Loop
                then V.Nothing_Wrong else V.Address_Value_Disagrees),
               "address must-initialisation: " & Scenario'Image);
         end;
      end loop;
   end Address_Initialisation_Is_Checked;

   procedure Erased_Dispatch_Is_Bound
     (Item : in out Landin.Testing.Context);

   procedure Erased_Dispatch_Is_Bound
     (Item : in out Landin.Testing.Context)
   is
      type Scenario_Kind is
        (Sound, Cross_Receiver, Raw_Self, Ordinary_Self,
         Missing_Descriptor, Wrong_Descriptor, Store_Between, Call_Between,
         Spilled_Function, Stored_Dispatch, Routine_Dispatch,
         Parameter_Dispatch, Result_Dispatch, Field_Dispatch,
         Self_Pointee, Self_Signature, Self_Atoms,
         Nonself_Pointee, Result_Pointee, Wrong_Errors, Wrong_Sources,
         Wrong_Convention, Wrong_Escape, Provider_Shape, Provider_No_Pointee,
         Ordinary_Dispatch, Invalid_Evidence, Zero_Entry, Invalid_Entry,
         Invalid_Receiver, Invalid_Self, Invalid_Dispatch,
         Invalid_Function_Signature, Wrong_Call_Signature);
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Site : Landin.Provenance.Origin;
   begin
      Ready (Work, Site);
      for Scenario in Scenario_Kind loop
         declare
            Unit : IR.Unit;
            Provider, Caller, Helper : IR.Item_Id;
            Concrete, Dispatch, Helper_Signature : IR.Signature_Id;
            Erased, Ordinary : IR.Evidence_Id;
            Self_Type, Other_Type : IR.Pointee_Id;
            Errors, Other_Errors : IR.Atom_Set_Id;
            Parameter, Result, Failure, Cell, Descriptor_A, Descriptor_B,
              Bad_Descriptor, Spill : IR.Slot_Id;
            Block : IR.Block_Id;
            Raw, One, Actual, Address_A, Address_B, Bad_Address, Table,
              Ordinary_Function, Function_A, Function_B, Self_A, Self_B,
              Callee, Value, Call_Value : IR.Value_Id;
            Expected : V.Fault_Kind := V.Nothing_Wrong;
            Part : IR.Signature_Part;
         begin
            IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
            Self_Type := IR.Add_Pointee
              (Unit, (Element => Landin.Types.U32, others => <>));
            Other_Type := IR.Add_Pointee
              (Unit, (Element => Landin.Types.U16, others => <>));
            Errors := IR.Add_Atom_Set (Unit, [1 => 5]);
            Other_Errors := IR.Add_Atom_Set (Unit, [1 => 6]);
            Concrete := IR.Add_Signature
              (Unit,
               [(Kind => Landin.Types.Usize, Pointee => Self_Type,
                 others => <>),
                (Kind => Landin.Types.Usize, Pointee => Other_Type,
                 others => <>)],
               (Kind => Landin.Types.Usize, Pointee => Other_Type,
                others => <>), Errors,
               Sources => [1 => (Result => 1, Parameter => 2)]);
            Helper_Signature := IR.Add_Signature
              (Unit, IR.No_Signature_Parts,
               (Kind => Landin.Types.No_Value, others => <>));
            Provider := IR.Add_Item
              (Unit, IR.Routine, 1, Landin.Types.Usize, Site);
            IR.Set_Signature (Unit, Provider, Concrete);
            declare
               Self : constant IR.Slot_Id := IR.Add_Parameter
                 (Unit, Provider, Landin.Types.Usize, IR.No_Declaration,
                  Site, Pointee => Self_Type);
               pragma Unreferenced (Self);
            begin
               null;
            end;
            Parameter := IR.Add_Parameter
              (Unit, Provider, Landin.Types.Usize, IR.No_Declaration,
               Site, Pointee => Other_Type);
            Result := IR.Add_Slot
              (Unit, Provider, Landin.Types.Usize, IR.No_Declaration,
               Site, Pointee => Other_Type);
            IR.Set_Result_Slot (Unit, Provider, Result);
            Block := IR.Add_Block
              (Unit, Provider, Landin.Resolution.Program_Scope, Site);
            IR.Enter (Unit, Provider, Block);
            Value := IR.Emit_Load (Unit, Provider, Parameter, Site);
            IR.Emit_Store (Unit, Provider, Result, Value, Site);
            IR.Emit_Leave (Unit, Provider, Value, Site);
            IR.Leave_Block (Unit, Provider);
            Helper := IR.Add_Item
              (Unit, IR.Routine, IR.No_Declaration,
               Landin.Types.No_Value, Site);
            IR.Set_Signature (Unit, Helper, Helper_Signature);
            Add_Empty_Body (Unit, Helper, Site);

            Ordinary := IR.Add_Evidence
              (Unit, (Element => Landin.Types.U32, others => <>));
            IR.Add_Evidence_Entry (Unit, Ordinary, Provider, Concrete);
            Erased := IR.Add_Evidence
              (Unit, (Element => (if Scenario = Provider_Shape
                                  then Landin.Types.U64 else Landin.Types.U32),
                      others => <>), Erased => True);
            IR.Add_Evidence_Entry (Unit, Erased, Provider, Concrete);
            Dispatch := IR.Evidence_Entry_Dispatch_Signature (Unit, Erased, 1);
            Landin.Testing.Check
              (Item, not IR.Signatures_Agree (Unit, Concrete, Dispatch),
               "dispatch and provider remain distinct: " & Scenario'Image);

            Caller := IR.Add_Item
              (Unit, IR.Routine, IR.No_Declaration,
               Landin.Types.No_Value, Site);
            Cell := IR.Add_Slot
              (Unit, Caller, Landin.Types.U16, IR.No_Declaration, Site);
            Failure := IR.Add_Slot
              (Unit, Caller, Landin.Types.U32, IR.No_Declaration, Site,
               Atoms => Errors);
            Descriptor_A := IR.Add_Array_Slot
              (Unit, Caller, Landin.Types.Usize, 2, IR.No_Declaration, Site);
            Descriptor_B := IR.Add_Array_Slot
              (Unit, Caller, Landin.Types.Usize, 2, IR.No_Declaration, Site);
            Bad_Descriptor := IR.Add_Array_Slot
              (Unit, Caller, Landin.Types.U32, 2, IR.No_Declaration, Site);
            Spill := IR.Add_Slot
              (Unit, Caller, Landin.Types.Usize, IR.No_Declaration, Site,
               Signature => (if Scenario = Stored_Dispatch
                             then Dispatch else IR.No_Signature));
            if Scenario = Field_Dispatch then
               declare
                  Aggregate : constant IR.Slot_Id := IR.Add_Aggregate_Slot
                    (Unit, Caller, IR.No_Declaration, Site);
               begin
                  IR.Add_Slot_Field
                    (Unit, Caller, Aggregate,
                     (Element => Landin.Types.Usize, Signature => Dispatch,
                      others => <>));
               end;
            end if;
            Block := IR.Add_Block
              (Unit, Caller, Landin.Resolution.Program_Scope, Site);
            IR.Enter (Unit, Caller, Block);
            Raw := IR.Emit_Number
              (Unit, Caller, Landin.Types.Usize, 123, False, Site);
            One := IR.Emit_Number
              (Unit, Caller, Landin.Types.Usize, 1, False, Site);
            Actual := IR.Emit_Place_Address
              (Unit, Caller, (Kind => IR.Frame_Slot, Slot => Cell), Site);
            IR.Set_Pointee (Unit, Caller, Actual, Other_Type);
            --  These verifier-only descriptors exercise the existing private
            --  two-word convention, not authenticity of fabricated contents.
            Address_A := IR.Emit_Storage_Address
              (Unit, Caller,
               (Kind => IR.Frame_Slot, Slot => Descriptor_A), Site);
            Address_B := IR.Emit_Storage_Address
              (Unit, Caller,
               (Kind => IR.Frame_Slot, Slot => Descriptor_B), Site);
            Bad_Address := IR.Emit_Storage_Address
              (Unit, Caller,
               (Kind => IR.Frame_Slot, Slot => Bad_Descriptor), Site);
            Table := IR.Emit_Evidence_Address (Unit, Caller, Ordinary, Site);
            Ordinary_Function := IR.Emit_Evidence_Function
              (Unit, Caller, Table, Ordinary, 1, Site);
            Function_A := IR.Emit_Erased_Evidence_Function
              (Unit, Caller, Address_A, Erased, 1, Site);
            if Scenario = Store_Between then
               IR.Emit_Store_Slot_Element
                 (Unit, Caller, Descriptor_A, One, Raw, Site);
            elsif Scenario = Call_Between then
               declare
                  Ignored : constant IR.Value_Id := IR.Emit_Call
                    (Unit, Caller, Helper, Landin.Types.No_Value, Site);
                  pragma Unreferenced (Ignored);
               begin
                  null;
               end;
            end if;
            Self_A := IR.Emit_Evidence_Self
              (Unit, Caller, Function_A, Site);
            Function_B := IR.Emit_Erased_Evidence_Function
              (Unit, Caller, Address_B, Erased, 1, Site);
            Self_B := IR.Emit_Evidence_Self
              (Unit, Caller, Function_B, Site);
            Callee := Function_A;
            if Scenario = Spilled_Function then
               IR.Emit_Store (Unit, Caller, Spill, Function_A, Site);
               Callee := IR.Emit_Load (Unit, Caller, Spill, Site);
               IR.Testing_Support.Overwrite_Value_Signature
                 (Unit, Caller, Callee, Dispatch);
            end if;
            Call_Value := IR.Emit_Indirect_Call
              (Unit, Caller, Dispatch, Landin.Types.Usize, Site,
               Failure => Failure);
            IR.Add_Argument (Unit, Caller, Call_Value, Callee);
            IR.Add_Argument (Unit, Caller, Call_Value, Self_A);
            IR.Add_Argument (Unit, Caller, Call_Value, Actual);
            IR.Emit_Leave (Unit, Caller, IR.No_Value, Site);
            IR.Leave_Block (Unit, Caller);

            case Scenario is
               when Sound => null;
               when Cross_Receiver | Raw_Self =>
                  IR.Testing_Support.Overwrite_Operand
                    (Unit, Caller, Call_Value, 2,
                     (if Scenario = Cross_Receiver then Self_B else Raw));
                  Expected := V.Evidence_Self_Disagrees;
               when Ordinary_Self =>
                  IR.Testing_Support.Overwrite_Operand
                    (Unit, Caller, Self_A, 1, Ordinary_Function);
                  Expected := V.Evidence_Self_Disagrees;
               when Missing_Descriptor | Wrong_Descriptor =>
                  IR.Testing_Support.Overwrite_Operand
                    (Unit, Caller, Function_A, 1,
                     (if Scenario = Missing_Descriptor
                      then Raw else Bad_Address));
                  Expected := V.Address_Value_Disagrees;
               when Store_Between | Call_Between =>
                  Expected := V.Evidence_Self_Disagrees;
               when Spilled_Function =>
                  Expected := V.Erased_Dispatch_Malformed;
               when Stored_Dispatch | Field_Dispatch =>
                  Expected := (if Scenario = Field_Dispatch
                               then V.Field_Shape_Malformed
                               else V.Erased_Dispatch_Malformed);
               when Routine_Dispatch =>
                  IR.Testing_Support.Overwrite_Item_Signature
                    (Unit, Caller, Dispatch);
                  Expected := V.Erased_Dispatch_Malformed;
               when Parameter_Dispatch | Result_Dispatch =>
                  declare
                     Bad : constant IR.Signature_Id := IR.Add_Signature
                       (Unit,
                        (if Scenario = Parameter_Dispatch
                         then [1 => (Kind => Landin.Types.Function_Value,
                                     Signature => Dispatch, others => <>)]
                         else IR.No_Signature_Parts),
                        (if Scenario = Result_Dispatch
                         then (Kind => Landin.Types.Function_Value,
                               Signature => Dispatch, others => <>)
                         else (Kind => Landin.Types.No_Value, others => <>)));
                     pragma Unreferenced (Bad);
                  begin
                     null;
                  end;
                  Expected := V.Signature_Part_Malformed;
               when Self_Pointee =>
                  IR.Testing_Support.Overwrite_Value_Pointee
                    (Unit, Caller, Self_A, Self_Type);
                  Expected := V.Evidence_Self_Disagrees;
               when Self_Signature =>
                  IR.Testing_Support.Overwrite_Value_Signature
                    (Unit, Caller, Self_A, Concrete);
                  Expected := V.Evidence_Self_Disagrees;
               when Self_Atoms =>
                  IR.Testing_Support.Overwrite_Value_Atoms
                    (Unit, Caller, Self_A, Errors);
                  Expected := V.Evidence_Self_Disagrees;
               when Nonself_Pointee | Wrong_Convention | Wrong_Escape =>
                  Part := IR.Nth_Signature_Parameter (Unit, Dispatch, 2);
                  if Scenario = Nonself_Pointee then
                     Part.Pointee := IR.No_Pointee;
                  elsif Scenario = Wrong_Convention then
                     Part.Convention := IR.Sink_Value;
                  else
                     Part.Escaping := True;
                  end if;
                  IR.Testing_Support.Overwrite_Signature_Parameter
                    (Unit, Dispatch, 2, Part);
                  Expected := V.Erased_Dispatch_Malformed;
               when Result_Pointee =>
                  Part := IR.Signature_Result (Unit, Dispatch);
                  Part.Pointee := IR.No_Pointee;
                  IR.Testing_Support.Overwrite_Signature_Result
                    (Unit, Dispatch, 1, Part);
                  Expected := V.Erased_Dispatch_Malformed;
               when Wrong_Errors =>
                  IR.Testing_Support.Overwrite_Signature_Errors
                    (Unit, Dispatch, Other_Errors);
                  Expected := V.Erased_Dispatch_Malformed;
               when Wrong_Sources =>
                  IR.Testing_Support.Overwrite_Signature_Source
                    (Unit, Dispatch, 1, (Result => 1, Parameter => 1));
                  Expected := V.Erased_Dispatch_Malformed;
               when Provider_Shape =>
                  Expected := V.Erased_Dispatch_Malformed;
               when Provider_No_Pointee =>
                  Part := IR.Nth_Signature_Parameter (Unit, Concrete, 1);
                  Part.Pointee := IR.No_Pointee;
                  IR.Testing_Support.Overwrite_Signature_Parameter
                    (Unit, Concrete, 1, Part);
                  Expected := V.Erased_Dispatch_Malformed;
               when Ordinary_Dispatch | Invalid_Dispatch =>
                  IR.Testing_Support.Overwrite_Evidence_Dispatch
                    (Unit, Erased, 1,
                     (if Scenario = Ordinary_Dispatch then Concrete
                      else IR.Signature_Id'Last));
                  Expected := V.Erased_Dispatch_Malformed;
               when Invalid_Evidence =>
                  IR.Testing_Support.Overwrite_Value_Evidence
                    (Unit, Caller, Function_A, IR.Evidence_Id'Last);
                  Expected := V.Evidence_Out_Of_Range;
               when Zero_Entry | Invalid_Entry =>
                  IR.Testing_Support.Overwrite_Value_Evidence_Entry
                    (Unit, Caller, Function_A,
                     (if Scenario = Zero_Entry then 0 else Natural'Last));
                  Expected := V.Evidence_Entry_Out_Of_Range;
               when Invalid_Receiver | Invalid_Self =>
                  IR.Testing_Support.Overwrite_Operand
                    (Unit, Caller,
                     (if Scenario = Invalid_Receiver
                      then Function_A else Self_A), 1, IR.Value_Id'Last);
                  Expected := V.Operand_Out_Of_Range;
               when Invalid_Function_Signature =>
                  IR.Testing_Support.Overwrite_Value_Signature
                    (Unit, Caller, Function_A, IR.Signature_Id'Last);
                  Expected := V.Evidence_Entry_Signature_Disagrees;
               when Wrong_Call_Signature =>
                  IR.Testing_Support.Overwrite_Value_Signature
                    (Unit, Caller, Call_Value, Concrete);
                  Expected := V.Function_Value_Signature_Disagrees;
            end case;
            Expect (Item, V.Check (Unit), Expected,
                    "erased dispatch transport: " & Scenario'Image);
            Expect
              (Item, V.Check (Unit, Landin.Targets.Synthetic_32), Expected,
               "erased dispatch transport synthetic-32: " & Scenario'Image);
         end;
      end loop;
   end Erased_Dispatch_Is_Bound;

   procedure Erasure_Does_Not_Weaken_Pointers
     (Item : in out Landin.Testing.Context);

   procedure Erasure_Does_Not_Weaken_Pointers
     (Item : in out Landin.Testing.Context)
   is
      type Scenario_Kind is (Sound, Missing, Wrong_Nominal, Erased_Self);
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Site : Landin.Provenance.Origin;
   begin
      Ready (Work, Site);
      for Indirect in Boolean loop
         for Scenario in Scenario_Kind loop
            declare
               Unit : IR.Unit;
               Left, Right : IR.Nominal_Type_Id;
               Left_Pointer, Right_Pointer : IR.Pointee_Id;
               Signature : IR.Signature_Id;
               Provider, Caller : IR.Item_Id;
               Parameter, Cell, Descriptor : IR.Slot_Id;
               Evidence : IR.Evidence_Id;
               Block : IR.Block_Id;
               Address, Actual, Bound, Function_Value, Called : IR.Value_Id;
            begin
               IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
               Left := IR.Add_Nominal_Type (Unit, 3);
               Right := IR.Add_Nominal_Type (Unit, 4);
               IR.Set_Nominal_Shape
                 (Unit, Left,
                  [1 => (Element => Landin.Types.U32, others => <>)]);
               IR.Set_Nominal_Shape
                 (Unit, Right,
                  [1 => (Element => Landin.Types.U32, others => <>)]);
               Left_Pointer := IR.Add_Pointee
                 (Unit, (Kind => IR.Aggregate_Field_Shape,
                         Nominal => Left, others => <>));
               Right_Pointer := IR.Add_Pointee
                 (Unit, (Kind => IR.Aggregate_Field_Shape,
                         Nominal => Right, others => <>));
               Signature := IR.Add_Signature
                 (Unit,
                  [1 => (Kind => Landin.Types.Usize,
                         Pointee => Left_Pointer, others => <>)],
                  (Kind => Landin.Types.No_Value, others => <>));
               Provider := IR.Add_Item
                 (Unit, IR.Routine, 1, Landin.Types.No_Value, Site);
               IR.Set_Signature (Unit, Provider, Signature);
               Parameter := IR.Add_Parameter
                 (Unit, Provider, Landin.Types.Usize, IR.No_Declaration,
                  Site, Pointee => Left_Pointer);
               pragma Unreferenced (Parameter);
               Add_Empty_Body (Unit, Provider, Site);
               Evidence := IR.Add_Evidence
                 (Unit, IR.Pointee_Shape (Unit, Left_Pointer), Erased => True);
               IR.Add_Evidence_Entry (Unit, Evidence, Provider, Signature);
               Caller := IR.Add_Item
                 (Unit, IR.Routine, 2, Landin.Types.No_Value, Site);
               Cell := IR.Add_Aggregate_Slot
                 (Unit, Caller, IR.No_Declaration, Site,
                  (if Scenario = Wrong_Nominal then Right else Left));
               IR.Add_Slot_Field (Unit, Caller, Cell, Landin.Types.U32);
               Descriptor := IR.Add_Array_Slot
                 (Unit, Caller, Landin.Types.Usize, 2,
                  IR.No_Declaration, Site);
               Block := IR.Add_Block
                 (Unit, Caller, Landin.Resolution.Program_Scope, Site);
               IR.Enter (Unit, Caller, Block);
               Function_Value := IR.Emit_Function_Address
                 (Unit, Caller, Provider, Site);
               if Scenario = Erased_Self then
                  Address := IR.Emit_Storage_Address
                    (Unit, Caller,
                     (Kind => IR.Frame_Slot, Slot => Descriptor), Site);
                  Bound := IR.Emit_Erased_Evidence_Function
                    (Unit, Caller, Address, Evidence, 1, Site);
                  Actual := IR.Emit_Evidence_Self (Unit, Caller, Bound, Site);
               else
                  Actual := IR.Emit_Storage_Address
                    (Unit, Caller,
                     (Kind => IR.Frame_Slot, Slot => Cell), Site);
                  if Scenario /= Missing then
                     IR.Set_Pointee
                       (Unit, Caller, Actual,
                        (if Scenario = Wrong_Nominal
                         then Right_Pointer else Left_Pointer));
                  end if;
               end if;
               Called :=
                 (if Indirect then IR.Emit_Indirect_Call
                    (Unit, Caller, Signature, Landin.Types.No_Value, Site)
                  else IR.Emit_Call
                    (Unit, Caller, Provider, Landin.Types.No_Value, Site));
               if Indirect then
                  IR.Add_Argument (Unit, Caller, Called, Function_Value);
               end if;
               IR.Add_Argument (Unit, Caller, Called, Actual);
               IR.Emit_Leave (Unit, Caller, IR.No_Value, Site);
               IR.Leave_Block (Unit, Caller);
               Expect
                 (Item, V.Check (Unit),
                  (if Scenario = Sound then V.Nothing_Wrong
                   else V.Operands_Disagree),
                  "ordinary pointer call stays nominal: " & Scenario'Image
                  & " indirect " & Indirect'Image);
            end;
         end loop;
      end loop;
   end Erasure_Does_Not_Weaken_Pointers;

   procedure Erased_Hidden_Results_Keep_Descriptors
     (Item : in out Landin.Testing.Context);

   procedure Erased_Hidden_Results_Keep_Descriptors
     (Item : in out Landin.Testing.Context)
   is
      type Scenario_Kind is
        (Sound, Sound_Nested, Sound_Saved, Sound_Runtime,
         Array_Metadata, Callback_Metadata, Result_Metadata,
         Wrong_Hidden, Wrong_Hidden_Address, Wrong_Array_Address, Wrong_Self,
         Wrong_Array_Length, Wrong_Array_Element, Wrong_Aggregate_Nominal,
         Wrong_Result_Count, Wrong_Result_Field, Wrong_Nested_Result_Field);
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Site : Landin.Provenance.Origin;
   begin
      Ready (Work, Site);
      for Scenario in Scenario_Kind loop
         declare
            Unit : IR.Unit;
            Callback, Other_Callback, Concrete, Dispatch : IR.Signature_Id;
            Pointer : IR.Pointee_Id;
            Evidence : IR.Evidence_Id;
            Provider, Helper, Caller : IR.Item_Id;
            Result, Descriptor, Array_Slot, Record_Slot,
              Destination : IR.Slot_Id;
            Saved_Result, Saved_Array, Saved_Record : IR.Slot_Id := IR.No_Slot;
            Record_Nominal, Other_Record, Tuple_Nominal,
              Container_Nominal : IR.Nominal_Type_Id;
            Tuple_Shape, Array_Shape, Record_Shape : IR.Field_Shape;
            Nested : constant Boolean := Scenario in
              Sound_Nested | Sound_Saved | Sound_Runtime
                | Wrong_Nested_Result_Field;
            Block : IR.Block_Id;
            Function_Value, Self, Receiver, Callback_Value, Record_Value,
              Array_Value, Result_Value, Bad_Result, Called : IR.Value_Id;
            Part : IR.Signature_Part;
            Expected : V.Fault_Kind := V.Nothing_Wrong;
         begin
            IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
            Callback := IR.Add_Signature
              (Unit, IR.No_Signature_Parts,
               (Kind => Landin.Types.No_Value, others => <>));
            Other_Callback := IR.Add_Signature
              (Unit, IR.No_Signature_Parts,
               (Kind => Landin.Types.U32, others => <>));
            Pointer := IR.Add_Pointee
              (Unit, (Element => Landin.Types.U32, others => <>));
            Record_Nominal := IR.Add_Nominal_Type (Unit, 1);
            Other_Record := IR.Add_Nominal_Type (Unit, 2);
            Tuple_Nominal := IR.Add_Nominal_Type (Unit, 3);
            Container_Nominal := IR.Add_Nominal_Type (Unit, 4);
            IR.Set_Nominal_Shape
              (Unit, Record_Nominal,
               [1 => (Element => Landin.Types.U32, others => <>)]);
            IR.Set_Nominal_Shape
              (Unit, Other_Record,
               [1 => (Element => Landin.Types.U32, others => <>)]);
            IR.Set_Nominal_Shape
              (Unit, Tuple_Nominal,
               [(Element => Landin.Types.U32, others => <>),
                (Element => (if Scenario = Wrong_Nested_Result_Field
                             then Landin.Types.U8 else Landin.Types.Bool),
                 others => <>)]);
            Tuple_Shape := (Kind => IR.Aggregate_Field_Shape,
                            Nominal => Tuple_Nominal, others => <>);
            Array_Shape := (Kind => IR.Array_Field_Shape, Length => 2,
                            Element => Landin.Types.U16, others => <>);
            Record_Shape := (Kind => IR.Aggregate_Field_Shape,
                             Nominal => Record_Nominal, others => <>);
            IR.Set_Nominal_Shape
              (Unit, Container_Nominal,
               [Tuple_Shape, Array_Shape, Record_Shape]);
            Concrete := IR.Add_Signature_With_Results
              (Unit,
               [(Kind => Landin.Types.Usize, Pointee => Pointer, others => <>),
                (Kind => Landin.Types.Function_Value, Signature => Callback,
                 others => <>),
                (Kind => Landin.Types.Fixed_Array, Length => 2,
                 Element => Landin.Types.U16,
                 Element_Shape => (Element => Landin.Types.U16, others => <>),
                 others => <>),
                (Kind => Landin.Types.Aggregate, Nominal => Record_Nominal,
                 others => <>)],
               [(Kind => Landin.Types.U32, others => <>),
                (Kind => Landin.Types.Bool, others => <>)]);
            Provider := IR.Add_Item
              (Unit, IR.Routine, 1, Landin.Types.Aggregate, Site);
            IR.Set_Signature (Unit, Provider, Concrete);
            declare
               Hidden : constant IR.Slot_Id := IR.Add_Parameter
                 (Unit, Provider, Landin.Types.Usize, 1, Site);
               Self_Parameter : constant IR.Slot_Id := IR.Add_Parameter
                 (Unit, Provider, Landin.Types.Usize, IR.No_Declaration,
                  Site, Pointee => Pointer);
               Callback_Parameter : constant IR.Slot_Id := IR.Add_Parameter
                 (Unit, Provider, Landin.Types.Usize, IR.No_Declaration,
                  Site, Signature => Callback);
               Array_Parameter : constant IR.Slot_Id := IR.Add_Array_Parameter
                 (Unit, Provider, Landin.Types.U16, 2, 2, Site);
               Record_Parameter : constant IR.Slot_Id :=
                 IR.Add_Aggregate_Parameter
                   (Unit, Provider, 3, Site, Record_Nominal);
               pragma Unreferenced
                 (Hidden, Self_Parameter, Callback_Parameter, Array_Parameter);
            begin
               IR.Add_Slot_Field
                 (Unit, Provider, Record_Parameter, Landin.Types.U32);
            end;
            Result := IR.Add_Aggregate_Slot
              (Unit, Provider, IR.No_Declaration, Site);
            IR.Add_Slot_Field (Unit, Provider, Result, Landin.Types.U32);
            IR.Add_Slot_Field (Unit, Provider, Result, Landin.Types.Bool);
            IR.Set_Result_Slot (Unit, Provider, Result);
            Add_Empty_Body (Unit, Provider, Site);
            Helper := IR.Add_Item
              (Unit, IR.Routine, IR.No_Declaration,
               Landin.Types.No_Value, Site);
            IR.Set_Signature (Unit, Helper, Callback);
            Add_Empty_Body (Unit, Helper, Site);
            Evidence := IR.Add_Evidence
              (Unit, IR.Pointee_Shape (Unit, Pointer), Erased => True);
            IR.Add_Evidence_Entry (Unit, Evidence, Provider, Concrete);
            Dispatch := IR.Evidence_Entry_Dispatch_Signature
              (Unit, Evidence, 1);
            Caller := IR.Add_Item
              (Unit, IR.Routine, IR.No_Declaration,
               Landin.Types.No_Value, Site);
            Descriptor := IR.Add_Array_Slot
              (Unit, Caller, Landin.Types.Usize, 2, IR.No_Declaration, Site);
            Array_Slot := IR.Add_Array_Slot
              (Unit, Caller,
               (if Scenario = Wrong_Array_Element
                then Landin.Types.I16 else Landin.Types.U16),
               (if Scenario = Wrong_Array_Length then 3 else 2),
               IR.No_Declaration, Site);
            Record_Slot := IR.Add_Aggregate_Slot
              (Unit, Caller, IR.No_Declaration, Site,
               (if Scenario = Wrong_Aggregate_Nominal
                then Other_Record else Record_Nominal));
            IR.Add_Slot_Field (Unit, Caller, Record_Slot, Landin.Types.U32);
            Destination := IR.Add_Aggregate_Slot
              (Unit, Caller, IR.No_Declaration, Site);
            if Nested then
               IR.Add_Slot_Field
                 (Unit, Caller, Destination,
                  (Kind => IR.Aggregate_Field_Shape,
                   Nominal => Container_Nominal, others => <>));
            else
               IR.Add_Slot_Field
                 (Unit, Caller, Destination, Landin.Types.U32);
               if Scenario /= Wrong_Result_Count then
                  IR.Add_Slot_Field
                    (Unit, Caller, Destination,
                     (if Scenario = Wrong_Result_Field
                      then Landin.Types.U8 else Landin.Types.Bool));
               end if;
            end if;
            if Scenario in Sound_Saved | Sound_Runtime then
               Saved_Result := IR.Add_Address_Slot
                 (Unit, Caller, Tuple_Shape, Site);
               Saved_Array := IR.Add_Address_Slot
                 (Unit, Caller, Array_Shape, Site);
               Saved_Record := IR.Add_Address_Slot
                 (Unit, Caller, Record_Shape, Site);
            end if;
            Block := IR.Add_Block
              (Unit, Caller, Landin.Resolution.Program_Scope, Site);
            IR.Enter (Unit, Caller, Block);
            Bad_Result := IR.Emit_Number
              (Unit, Caller,
               (if Scenario in Wrong_Hidden_Address | Wrong_Array_Address
                then Landin.Types.Usize else Landin.Types.U32),
               1, False, Site);
            Callback_Value := IR.Emit_Function_Address
              (Unit, Caller, Helper, Site);
            Array_Value := IR.Emit_Storage_Address
              (Unit, Caller,
               (Kind => IR.Frame_Slot,
                Slot => (if Nested then Destination else Array_Slot)), Site,
               Field => (if Nested then 1 else 0),
               Nested => Below (if Nested then 2 else 0));
            Record_Value := IR.Emit_Storage_Address
              (Unit, Caller,
               (Kind => IR.Frame_Slot,
                Slot => (if Nested then Destination else Record_Slot)), Site,
               Field => (if Nested then 1 else 0),
               Nested => Below (if Nested then 3 else 0));
            Result_Value := IR.Emit_Storage_Address
              (Unit, Caller,
               (Kind => IR.Frame_Slot, Slot => Destination), Site,
               Field => (if Nested then 1 else 0),
               Nested => Below (if Nested then 1 else 0));
            if Scenario in Sound_Saved | Sound_Runtime then
               IR.Emit_Store
                 (Unit, Caller, Saved_Result, Result_Value, Site);
               IR.Emit_Store (Unit, Caller, Saved_Array, Array_Value, Site);
               IR.Emit_Store (Unit, Caller, Saved_Record, Record_Value, Site);
               if Scenario = Sound_Saved then
                  Result_Value := IR.Emit_Load
                    (Unit, Caller, Saved_Result, Site);
                  Array_Value := IR.Emit_Load
                    (Unit, Caller, Saved_Array, Site);
                  Record_Value := IR.Emit_Load
                    (Unit, Caller, Saved_Record, Site);
               else
                  Result_Value := IR.Emit_Storage_Address
                    (Unit, Caller,
                     (Kind => IR.Runtime_Address, Address => Saved_Result),
                     Site);
                  Array_Value := IR.Emit_Storage_Address
                    (Unit, Caller,
                     (Kind => IR.Runtime_Address, Address => Saved_Array),
                     Site);
                  Record_Value := IR.Emit_Storage_Address
                    (Unit, Caller,
                     (Kind => IR.Runtime_Address, Address => Saved_Record),
                     Site);
               end if;
            end if;
            Receiver := IR.Emit_Storage_Address
              (Unit, Caller,
               (Kind => IR.Frame_Slot, Slot => Descriptor), Site);
            Function_Value := IR.Emit_Erased_Evidence_Function
              (Unit, Caller, Receiver, Evidence, 1, Site);
            Self := IR.Emit_Evidence_Self
              (Unit, Caller, Function_Value, Site);
            Called := IR.Emit_Indirect_Call
              (Unit, Caller, Dispatch, Landin.Types.No_Value, Site);
            IR.Add_Argument (Unit, Caller, Called, Function_Value);
            IR.Add_Argument (Unit, Caller, Called, Result_Value);
            IR.Add_Argument (Unit, Caller, Called, Self);
            IR.Add_Argument (Unit, Caller, Called, Callback_Value);
            IR.Add_Argument (Unit, Caller, Called, Array_Value);
            IR.Add_Argument (Unit, Caller, Called, Record_Value);
            IR.Emit_Leave (Unit, Caller, IR.No_Value, Site);
            IR.Leave_Block (Unit, Caller);
            case Scenario is
               when Sound | Sound_Nested | Sound_Saved | Sound_Runtime =>
                  null;
               when Wrong_Array_Length | Wrong_Array_Element
                  | Wrong_Aggregate_Nominal | Wrong_Result_Count
                  | Wrong_Result_Field | Wrong_Nested_Result_Field =>
                  Expected := V.Operands_Disagree;
               when Array_Metadata =>
                  Part := IR.Nth_Signature_Parameter (Unit, Dispatch, 3);
                  Part.Length := 3;
                  IR.Testing_Support.Overwrite_Signature_Parameter
                    (Unit, Dispatch, 3, Part);
                  Expected := V.Erased_Dispatch_Malformed;
               when Callback_Metadata =>
                  Part := IR.Nth_Signature_Parameter (Unit, Dispatch, 2);
                  Part.Signature := Other_Callback;
                  IR.Testing_Support.Overwrite_Signature_Parameter
                    (Unit, Dispatch, 2, Part);
                  Expected := V.Erased_Dispatch_Malformed;
               when Result_Metadata =>
                  IR.Testing_Support.Overwrite_Signature_Result
                    (Unit, Dispatch, 2,
                     (Kind => Landin.Types.U8, others => <>));
                  Expected := V.Erased_Dispatch_Malformed;
               when Wrong_Hidden | Wrong_Hidden_Address =>
                  IR.Testing_Support.Overwrite_Operand
                    (Unit, Caller, Called, 2, Bad_Result);
                  Expected := V.Operands_Disagree;
               when Wrong_Array_Address =>
                  IR.Testing_Support.Overwrite_Operand
                    (Unit, Caller, Called, 5, Bad_Result);
                  Expected := V.Operands_Disagree;
               when Wrong_Self =>
                  IR.Testing_Support.Overwrite_Operand
                    (Unit, Caller, Called, 3, Receiver);
                  Expected := V.Evidence_Self_Disagrees;
            end case;
            Expect (Item, V.Check (Unit), Expected,
                    "erased hidden-result descriptors: " & Scenario'Image);
         end;
      end loop;
   end Erased_Hidden_Results_Keep_Descriptors;

   procedure Erased_Single_Result_Carriers_Are_Checked
     (Item : in out Landin.Testing.Context);

   procedure Erased_Single_Result_Carriers_Are_Checked
     (Item : in out Landin.Testing.Context)
   is
      type Scenario_Kind is
        (Sound, Sound_Nested, Sound_Indexed,
         Wrong_Hidden_Integer, Wrong_Argument_Integer,
         Wrong_Hidden_Shape, Wrong_Argument_Shape,
         Wrong_Hidden_Element, Wrong_Argument_Element);
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Site : Landin.Provenance.Origin;
   begin
      Ready (Work, Site);
      for Arrays in Boolean loop
         for Scenario in Scenario_Kind loop
            if Arrays or else Scenario not in
              Wrong_Hidden_Element | Wrong_Argument_Element
            then
               declare
                  Unit : IR.Unit;
                  Nominal, Other, Wrapper : IR.Nominal_Type_Id;
                  Good, Bad, Wrapper_Shape : IR.Field_Shape;
                  Part : IR.Signature_Part;
                  Concrete, Dispatch : IR.Signature_Id;
                  Pointer : IR.Pointee_Id;
                  Evidence : IR.Evidence_Id;
                  Provider, Caller : IR.Item_Id;
                  Result, Parameter, Descriptor, Destination,
                    Argument : IR.Slot_Id;
                  Block : IR.Block_Id;
                  Integer, Hidden_Value, Argument_Value, Receiver,
                    Function_Value, Self, Called : IR.Value_Id;

                  function Add_Storage (Shape : IR.Field_Shape)
                    return IR.Slot_Id;

                  function Add_Storage (Shape : IR.Field_Shape)
                    return IR.Slot_Id
                  is
                     Slot : IR.Slot_Id;
                  begin
                     if Scenario = Sound_Indexed then
                        return IR.Add_Array_Slot
                          (Unit, Caller, Shape, 2, IR.No_Declaration, Site);
                     elsif Scenario = Sound_Nested then
                        Slot := IR.Add_Aggregate_Slot
                          (Unit, Caller, IR.No_Declaration, Site);
                        IR.Add_Slot_Field
                          (Unit, Caller, Slot, Wrapper_Shape);
                        return Slot;
                     elsif Arrays then
                        return IR.Add_Array_Slot
                          (Unit, Caller, IR.Array_Element_Shape (Unit, Shape),
                           Shape.Length, IR.No_Declaration, Site);
                     end if;
                     Slot := IR.Add_Aggregate_Slot
                       (Unit, Caller, IR.No_Declaration, Site, Shape.Nominal);
                     IR.Add_Slot_Field
                       (Unit, Caller, Slot, Landin.Types.U32);
                     return Slot;
                  end Add_Storage;
               begin
                  IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
                  Nominal := IR.Add_Nominal_Type (Unit, 1);
                  Other := IR.Add_Nominal_Type (Unit, 2);
                  Wrapper := IR.Add_Nominal_Type (Unit, 3);
                  IR.Set_Nominal_Shape
                    (Unit, Nominal,
                     [1 => (Element => Landin.Types.U32, others => <>)]);
                  IR.Set_Nominal_Shape
                    (Unit, Other,
                     [1 => (Element => Landin.Types.U32, others => <>)]);
                  Good :=
                    (if Arrays then
                       (Kind => IR.Array_Field_Shape, Length => 2,
                        Element => Landin.Types.U16, others => <>)
                     else
                       (Kind => IR.Aggregate_Field_Shape,
                        Nominal => Nominal, others => <>));
                  Bad := Good;
                  if Arrays then
                     if Scenario in Wrong_Hidden_Element
                       | Wrong_Argument_Element
                     then
                        Bad.Element := Landin.Types.I16;
                     else
                        Bad.Length := 3;
                     end if;
                  else
                     Bad.Nominal := Other;
                  end if;
                  IR.Set_Nominal_Shape (Unit, Wrapper, [1 => Good]);
                  Wrapper_Shape := (Kind => IR.Aggregate_Field_Shape,
                                    Nominal => Wrapper, others => <>);
                  Part :=
                    (if Arrays then
                       (Kind => Landin.Types.Fixed_Array, Length => 2,
                        Element => Landin.Types.U16,
                        Element_Shape =>
                          (Element => Landin.Types.U16, others => <>),
                        others => <>)
                     else
                       (Kind => Landin.Types.Aggregate,
                        Nominal => Nominal, others => <>));
                  Pointer := IR.Add_Pointee
                    (Unit, (Element => Landin.Types.U32, others => <>));
                  Concrete := IR.Add_Signature
                    (Unit,
                     [(Kind => Landin.Types.Usize, Pointee => Pointer,
                       others => <>), Part], Part);
                  Provider := IR.Add_Item
                    (Unit, IR.Routine, 1, Part.Kind, Site, Part.Nominal);
                  IR.Set_Signature (Unit, Provider, Concrete);
                  declare
                     Hidden : constant IR.Slot_Id := IR.Add_Parameter
                       (Unit, Provider, Landin.Types.Usize, 1, Site);
                     Self_Parameter : constant IR.Slot_Id := IR.Add_Parameter
                       (Unit, Provider, Landin.Types.Usize, IR.No_Declaration,
                        Site, Pointee => Pointer);
                     pragma Unreferenced (Hidden, Self_Parameter);
                  begin
                     null;
                  end;
                  if Arrays then
                     Parameter := IR.Add_Array_Parameter
                       (Unit, Provider, Landin.Types.U16, 2, 2, Site);
                     Result := IR.Add_Array_Slot
                       (Unit, Provider, Landin.Types.U16, 2,
                        IR.No_Declaration, Site);
                  else
                     Parameter := IR.Add_Aggregate_Parameter
                       (Unit, Provider, 2, Site, Nominal);
                     IR.Add_Slot_Field
                       (Unit, Provider, Parameter, Landin.Types.U32);
                     Result := IR.Add_Aggregate_Slot
                       (Unit, Provider, IR.No_Declaration, Site, Nominal);
                     IR.Add_Slot_Field
                       (Unit, Provider, Result, Landin.Types.U32);
                  end if;
                  IR.Set_Result_Slot (Unit, Provider, Result);
                  Add_Empty_Body (Unit, Provider, Site);
                  Evidence := IR.Add_Evidence
                    (Unit, IR.Pointee_Shape (Unit, Pointer), Erased => True);
                  IR.Add_Evidence_Entry (Unit, Evidence, Provider, Concrete);
                  Dispatch := IR.Evidence_Entry_Dispatch_Signature
                    (Unit, Evidence, 1);
                  Caller := IR.Add_Item
                    (Unit, IR.Routine, IR.No_Declaration,
                     Landin.Types.No_Value, Site);
                  Descriptor := IR.Add_Array_Slot
                    (Unit, Caller, Landin.Types.Usize, 2,
                     IR.No_Declaration, Site);
                  Destination := Add_Storage
                    (if Scenario in Wrong_Hidden_Shape | Wrong_Hidden_Element
                     then Bad else Good);
                  Argument := Add_Storage
                    (if Scenario in Wrong_Argument_Shape
                       | Wrong_Argument_Element then Bad else Good);
                  Block := IR.Add_Block
                    (Unit, Caller, Landin.Resolution.Program_Scope, Site);
                  IR.Enter (Unit, Caller, Block);
                  Integer := IR.Emit_Number
                    (Unit, Caller, Landin.Types.Usize, 1, False, Site);
                  Hidden_Value := IR.Emit_Storage_Address
                    (Unit, Caller,
                     (Kind => IR.Frame_Slot, Slot => Destination), Site,
                     Field => (if Scenario = Sound_Nested then 1 else 0),
                     Nested => Below (if Scenario = Sound_Nested
                                      then 1 else 0),
                     Index => (if Scenario = Sound_Indexed
                               then Integer else IR.No_Value));
                  Argument_Value := IR.Emit_Storage_Address
                    (Unit, Caller,
                     (Kind => IR.Frame_Slot, Slot => Argument), Site,
                     Field => (if Scenario = Sound_Nested then 1 else 0),
                     Nested => Below (if Scenario = Sound_Nested
                                      then 1 else 0),
                     Index => (if Scenario = Sound_Indexed
                               then Integer else IR.No_Value));
                  Receiver := IR.Emit_Storage_Address
                    (Unit, Caller,
                     (Kind => IR.Frame_Slot, Slot => Descriptor), Site);
                  Function_Value := IR.Emit_Erased_Evidence_Function
                    (Unit, Caller, Receiver, Evidence, 1, Site);
                  Self := IR.Emit_Evidence_Self
                    (Unit, Caller, Function_Value, Site);
                  Called := IR.Emit_Indirect_Call
                    (Unit, Caller, Dispatch, Landin.Types.No_Value, Site);
                  IR.Add_Argument (Unit, Caller, Called, Function_Value);
                  IR.Add_Argument
                    (Unit, Caller, Called,
                     (if Scenario = Wrong_Hidden_Integer
                      then Integer else Hidden_Value));
                  IR.Add_Argument (Unit, Caller, Called, Self);
                  IR.Add_Argument
                    (Unit, Caller, Called,
                     (if Scenario = Wrong_Argument_Integer
                      then Integer else Argument_Value));
                  IR.Emit_Leave (Unit, Caller, IR.No_Value, Site);
                  IR.Leave_Block (Unit, Caller);
                  Expect
                    (Item, V.Check (Unit),
                     (if Scenario in Sound | Sound_Nested | Sound_Indexed
                      then V.Nothing_Wrong else V.Operands_Disagree),
                     "erased single-result carrier: " & Scenario'Image
                       & " arrays " & Arrays'Image);
               end;
            end if;
         end loop;
      end loop;
   end Erased_Single_Result_Carriers_Are_Checked;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "verifier", "erased single-result carriers are checked",
         Erased_Single_Result_Carriers_Are_Checked'Access);
      Landin.Testing.Register
        (Into, "verifier", "erased hidden results keep descriptors",
         Erased_Hidden_Results_Keep_Descriptors'Access);
      Landin.Testing.Register
        (Into, "verifier", "erasure keeps ordinary pointers strict",
         Erasure_Does_Not_Weaken_Pointers'Access);
      Landin.Testing.Register
        (Into, "verifier", "erased dispatch is evidence bound",
         Erased_Dispatch_Is_Bound'Access);
      Landin.Testing.Register
        (Into, "verifier", "address initialisation is checked",
         Address_Initialisation_Is_Checked'Access);
      Landin.Testing.Register
        (Into, "verifier", "pointer origins are checked",
         Pointer_Origins_Are_Checked'Access);
      Landin.Testing.Register
        (Into, "verifier", "inout reached types are checked",
         Inout_Reached_Types_Are_Checked'Access);
      Landin.Testing.Register
        (Into, "verifier", "pointee graphs are checked",
         Pointee_Graphs_Are_Checked'Access);
      Landin.Testing.Register
        (Into, "verifier", "atom comparisons keep identity",
         Atom_Comparisons_Keep_Identity'Access);
      Landin.Testing.Register
        (Into, "verifier", "typed indirect atoms are checked",
         Typed_Indirect_Atoms_Are_Checked'Access);
      Landin.Testing.Register
        (Into, "verifier", "range bounds need target facts",
         Range_Bounds_Need_Target_Facts'Access);
      Landin.Testing.Register
        (Into, "verifier", "read-only images remain required",
         Read_Only_Images_Are_Required'Access);
      Landin.Testing.Register
        (Into, "verifier", "recursive image relocations and widths",
         Recursive_Image_Relocations_And_Widths'Access);
      Landin.Testing.Register
        (Into, "verifier", "recursive array images are checked",
         Recursive_Array_Images_Are_Checked'Access);
      Landin.Testing.Register
        (Into, "verifier", "callback array images are checked",
         Callback_Array_Images_Are_Checked'Access);
      Landin.Testing.Register
        (Into, "verifier", "typed indirect witnesses are checked",
         Typed_Indirect_Witnesses_Are_Checked'Access);
      Landin.Testing.Register
        (Into, "verifier", "canonical and storage runs checked in release",
         Canonical_And_Storage_Runs_Are_Checked'Access);
      Landin.Testing.Register
        (Into, "verifier", "C signatures and compatible linkage",
         C_Signatures_And_Linkage_Are_Checked'Access);
      Landin.Testing.Register
        (Into, "verifier", "C aggregate call carriers",
         C_Aggregate_Carriers_Are_Checked'Access);
      Landin.Testing.Register
        (Into, "verifier", "array routine parts keep complete children",
         Array_Routine_Parts_Keep_Complete_Children'Access);
      Landin.Testing.Register
        (Into, "verifier", "a sound unit is accepted",
         A_Sound_Unit_Is_Accepted'Access);
      Landin.Testing.Register
        (Into, "verifier", "same-layout nominals disagree",
         Same_Layout_Nominals_Do_Not_Agree_In_Signatures'Access);
      Landin.Testing.Register
        (Into, "verifier", "nominal aggregate routine metadata is checked",
         Nominal_Aggregate_Routine_Metadata_Is_Checked'Access);
      Landin.Testing.Register
        (Into, "verifier", "nominal root metadata is checked",
         Nominal_Root_Metadata_Is_Checked'Access);
      Landin.Testing.Register
        (Into, "verifier", "nominal shapes are canonical",
         Nominal_Shapes_Are_Canonical'Access);
      Landin.Testing.Register
        (Into, "verifier", "malformed shapes are rejected",
         Malformed_Shapes_Are_Rejected'Access);
      Landin.Testing.Register
        (Into, "verifier", "malformed variant operations are rejected",
         Malformed_Variant_Operations_Are_Rejected'Access);
      Landin.Testing.Register
        (Into, "verifier", "malformed image values are rejected",
         Malformed_Image_Values_Are_Rejected'Access);
      Landin.Testing.Register
        (Into, "verifier", "malformed aggregate images are rejected",
         Malformed_Aggregate_Images_Are_Rejected'Access);
      Landin.Testing.Register
        (Into, "verifier", "malformed image runs are rejected",
         Malformed_Image_Runs_Are_Rejected'Access);
      Landin.Testing.Register
        (Into, "verifier", "malformed multiple results are rejected",
         Malformed_Multiple_Results_Are_Rejected'Access);
      Landin.Testing.Register
        (Into, "verifier", "malformed error IR is rejected",
         Malformed_Error_IR_Is_Rejected'Access);
      Landin.Testing.Register
        (Into, "verifier", "malformed evidence is rejected",
         Malformed_Evidence_Is_Rejected'Access);
      Landin.Testing.Register
        (Into, "verifier", "malformed runtime addresses are rejected",
         Malformed_Runtime_Addresses_Are_Rejected'Access);
      Landin.Testing.Register
        (Into, "verifier", "nested array address shapes keep children",
         Nested_Array_Address_Shapes_Keep_Children'Access);
   end Register;

end Landin.Tests.Verifier_Suite;
