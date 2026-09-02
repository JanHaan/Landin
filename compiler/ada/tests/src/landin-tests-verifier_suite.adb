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

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
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
   end Register;

end Landin.Tests.Verifier_Suite;
