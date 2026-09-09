with Ada.Strings.Fixed;

with Landin.Build_Reports;
with Landin.IR;
with Landin.Layouts;
with Landin.Optimization;
with Landin.Provenance;
with Landin.Resolution;
with Landin.Source;
with Landin.Stages.Configuration;
with Landin.Stages.Resolution;
with Landin.Stages.Syntax;
with Landin.Targets;
with Landin.Targets.Layouts;
with Landin.Types;

package body Landin.Tests.Optimization_Foundations_Suite is

   package IR renames Landin.IR;
   package Opt renames Landin.Optimization;
   package Reports renames Landin.Build_Reports;
   package Layout renames Landin.Targets.Layouts;
   use type IR.Evidence_Id;
   use type Landin.Layouts.Policy;
   use type Opt.Objective;
   use type Opt.Specialization_Mode;
   use type Layout.Field_Order;
   use type Layout.Field_Offsets;
   use type Landin.Targets.Byte_Count;
   use type Landin.Targets.Byte_Alignment;

   Frontend : aliased Landin.Stages.Syntax.Instance;
   Configurer : aliased Landin.Stages.Configuration.Instance;
   Resolver : aliased Landin.Stages.Resolution.Instance;

   procedure Exact_Options (Item : in out Landin.Testing.Context);
   procedure Target_Placement (Item : in out Landin.Testing.Context);
   procedure Concrete_Metadata (Item : in out Landin.Testing.Context);
   procedure Deterministic_Reports (Item : in out Landin.Testing.Context);

   procedure Exact_Options (Item : in out Landin.Testing.Context) is
      Objective : Opt.Objective;
      Mode : Opt.Specialization_Mode;
      Accepted : Boolean;
   begin
      Landin.Testing.Check
        (Item, Opt.Default_Options.Optimize = Opt.Size
         and then Opt.Default_Options.Specialize = Opt.Auto
         and then Opt.Reference_Options.Optimize = Opt.None
         and then Opt.Reference_Options.Specialize = Opt.Off,
         "default and explicit reference axes are independent");
      for Value in Opt.Objective loop
         Opt.Parse (Opt.Spelling (Value), Objective, Accepted);
         Landin.Testing.Check
           (Item, Accepted and then Objective = Value,
            "every objective round trips");
      end loop;
      for Value in Opt.Specialization_Mode loop
         Opt.Parse (Opt.Spelling (Value), Mode, Accepted);
         Landin.Testing.Check
           (Item, Accepted and then Mode = Value,
            "every specialization mode round trips");
      end loop;
      Opt.Parse ("SIZE", Objective, Accepted);
      Landin.Testing.Check (Item, not Accepted, "uppercase is not a request");
      Opt.Parse ("auto ", Mode, Accepted);
      Landin.Testing.Check (Item, not Accepted, "trailing space is refused");
      Opt.Parse ("", Mode, Accepted);
      Landin.Testing.Check (Item, not Accepted, "empty mode is refused");
      Opt.Parse ("all", Mode, Accepted);
      Landin.Testing.Check
        (Item, Accepted and then Mode = Opt.All_Eligible,
         "all bypasses cost, not proof eligibility");
   end Exact_Options;

   procedure Target_Placement (Item : in out Landin.Testing.Context) is
      use Landin.Targets;
      Fields : constant Layout.Field_Extent_Array :=
        [(1, 1), (8, 8), (1, 1), (8, 8)];
      Natural_Plan : constant Layout.Plan := Layout.Make (Fields);
      C_Plan : constant Layout.Plan := Layout.Make (Fields, Landin.Layouts.C);
      Optimal : constant Layout.Plan :=
        Layout.Make (Fields, Landin.Layouts.Optimal);
   begin
      Landin.Testing.Check
        (Item, Natural_Plan.Size = 32
         and then Natural_Plan.Offsets = [0, 8, 16, 24]
         and then C_Plan.Offsets = Natural_Plan.Offsets
         and then C_Plan.Size = Natural_Plan.Size,
         "natural and C retain source-order placement");
      Landin.Testing.Check
        (Item, Optimal.Size = 24 and then Optimal.Natural_Size = 32
         and then Optimal.Saved_Bytes = 8
         and then Optimal.Order = [2, 4, 1, 3]
         and then Optimal.Offsets = [16, 0, 17, 8],
         "optimal saves padding with stable alignment ties");
      declare
         Equal_Size : constant Layout.Plan := Layout.Make
           ([(1, 1), (8, 8)], Landin.Layouts.Optimal);
         Larger_Candidate : constant Layout.Plan := Layout.Make
           ([(0, 2), (1, 4), (3, 1)], Landin.Layouts.Optimal);
         Overflowing_Candidate : constant Layout.Plan := Layout.Make
           ([(0, 2), (1, 4), (Byte_Count'Last - 4, 1)],
            Landin.Layouts.Optimal);
         Empty : constant Layout.Plan := Layout.Make
           (Layout.Field_Extent_Array'(1 .. 0 => <>), Landin.Layouts.Optimal);
         Zero_Size : constant Layout.Plan := Layout.Make
           ([(1, 1), (0, 8), (1, 1)], Landin.Layouts.Optimal);
         Shifted : constant Layout.Plan := Layout.Make
           (Layout.Field_Extent_Array'(7 => (1, 1), 8 => (8, 8),
                                       9 => (1, 1), 10 => (8, 8)),
            Landin.Layouts.Optimal);
      begin
         Landin.Testing.Check
           (Item, Equal_Size.Order = [1, 2]
            and then Equal_Size.Saved_Bytes = 0,
            "an equal padded size keeps natural order");
         Landin.Testing.Check
           (Item, Larger_Candidate.Size = 4
            and then Larger_Candidate.Order = [1, 2, 3]
            and then Overflowing_Candidate.Size = Byte_Count'Last - 3
            and then Overflowing_Candidate.Order = [1, 2, 3],
            "a larger or overflowing candidate retains valid natural layout");
         Landin.Testing.Check
           (Item, Empty.Count = 0 and then Empty.Size = 0
            and then Empty.Alignment = 1,
            "empty placement has byte alignment and zero extent");
         Landin.Testing.Check
           (Item, Zero_Size.Size = 8 and then Zero_Size.Alignment = 8
            and then Zero_Size.Offsets = [0, 0, 1],
            "zero-sized fields retain alignment without consuming bytes");
         Landin.Testing.Check
           (Item, Shifted.Offsets = Optimal.Offsets
            and then Shifted.Order = Optimal.Order,
            "input lower bounds never become field identities");
      end;
      for Small in Boolean loop
         declare
            Facts : constant Target_Facts :=
              (if Small then Synthetic_32 else Linux_X86_64);
            Pointer : constant Byte_Count :=
              Byte_Count (Bytes (Pointer_Size (Facts)));
            Alignment : constant Byte_Alignment := Pointer_Alignment (Facts);
            Placed : constant Layout.Plan := Layout.Make
              ([(1, 1), (Pointer, Alignment), (1, 1), (Pointer, Alignment)],
               Landin.Layouts.Optimal, Maximum_Object_Size (Facts));
         begin
            Landin.Testing.Check
              (Item, Placed.Size = (if Small then 12 else 24)
               and then Placed.Natural_Size = (if Small then 16 else 32)
               and then Placed.Offsets = [2 * Pointer, 0, 2 * Pointer + 1,
                                         Pointer],
               "pointer-field placement follows the selected target");
         end;
      end loop;
      Landin.Testing.Check
        (Item, not Layout.Fits ([(1, 3)])
         and then not Layout.Fits ([(Byte_Count'Last, 8)])
         and then not Layout.Fits ([(Byte_Count'Last, 1), (1, 1)])
         and then not Layout.Fits (Fields, Maximum => 24)
         and then Layout.Fits (Fields, Landin.Layouts.Optimal, 24),
         "invalid alignment, overflow and target object limits are explicit");
      declare
         Huge : constant Layout.Plan := Layout.Make
           ([(2 ** 40, 8), (1, 1)], Landin.Layouts.Optimal);
      begin
         Landin.Testing.Check
           (Item, Huge.Count = 2 and then Huge.Size = 2 ** 40 + 8,
            "target byte extent never expands into metadata entries");
      end;
   end Target_Placement;

   procedure Concrete_Metadata (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Written : constant Landin.Source.Source_Id := Landin.Stages.Add_Source
        (Work, "metadata.ldn", "f: () -> none = end f");
      Site : constant Landin.Provenance.Origin :=
        (Written, Landin.Source.Empty_Span);
      Unit : IR.Unit;
      Generic_Item, Other : IR.Item_Id;
      Slot, Ordinary : IR.Slot_Id;
      Table, Erased : IR.Evidence_Id;
      Signature : IR.Signature_Id;
      Block : IR.Block_Id;
      Call, Address : IR.Value_Id;
      Nominal : IR.Nominal_Type_Id;
   begin
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Resolver'Access);
      Landin.Testing.Check_Equal
        (Item, Landin.Stages.Run (Order, Work), 3,
         "the in-memory source supplies declaration provenance");
      IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
      Generic_Item := IR.Add_Routine_Instance_Item
        (Unit, 7, 1, Landin.Types.No_Value, Site);
      Other := IR.Add_Item
        (Unit, IR.Routine, 1, Landin.Types.No_Value, Site);
      Signature := IR.Add_Signature_With_Results
        (Unit, IR.No_Signature_Parts, IR.No_Signature_Parts);
      IR.Set_Signature (Unit, Other, Signature);
      Slot := IR.Add_Parameter
        (Unit, Generic_Item, Landin.Types.Usize, IR.No_Declaration, Site);
      Ordinary := IR.Add_Parameter
        (Unit, Generic_Item, Landin.Types.Usize, 1, Site);
      Table := IR.Add_Evidence (Unit, (others => <>));
      Erased := IR.Add_Evidence (Unit, (others => <>), Erased => True);
      IR.Bind_Evidence_Parameter (Unit, Generic_Item, 1, Table);
      Landin.Testing.Check
        (Item, IR.Instance_Position_Of (Unit, Generic_Item) = 7
         and then IR.Instance_Position_Of (Unit, Other) = 0
         and then IR.Evidence_Binding_Count (Unit, Generic_Item) = 1
         and then IR.Nth_Evidence_Binding (Unit, Generic_Item, 1).Parameter = 1
         and then IR.Bound_Evidence (Unit, Generic_Item, Slot) = Table
         and then IR.Bound_Evidence (Unit, Generic_Item, Ordinary)
           = IR.No_Evidence
         and then IR.Evidence_Bindings_Are_Valid (Unit, Generic_Item),
         "only an explicitly bound hidden parameter supplies evidence");
      for Case_Index in 1 .. 4 loop
         begin
            case Case_Index is
               when 1 =>
                  IR.Bind_Evidence_Parameter (Unit, Generic_Item, 1, Table);
               when 2 =>
                  IR.Bind_Evidence_Parameter (Unit, Generic_Item, 2, Table);
               when 3 =>
                  IR.Bind_Evidence_Parameter (Unit, Generic_Item, 1, Erased);
               when 4 =>
                  IR.Bind_Evidence_Parameter (Unit, Generic_Item, 3, Table);
            end case;
            Landin.Testing.Fail
              (Item, "invalid metadata binding was accepted");
         exception
            when Landin.Compiler_Defect =>
               Landin.Testing.Check (Item, True, "invalid binding refused");
         end;
      end loop;
      Landin.Testing.Check
        (Item, not IR.Has_Address_Exposure (Unit, Other),
         "a direct-only routine starts unexposed");
      Block := IR.Add_Block
        (Unit, Generic_Item, Landin.Resolution.Program_Scope, Site);
      IR.Enter (Unit, Generic_Item, Block);
      IR.Set_Loop_Depth (Unit, Generic_Item, 3);
      Call := IR.Emit_Call (Unit, Generic_Item, Other, Landin.Types.No_Value,
                            Site);
      IR.Set_Loop_Depth (Unit, Generic_Item, 0);
      Landin.Testing.Check
        (Item, IR.Call_Loop_Depth (Unit, Generic_Item, Call) = 3
         and then IR.Loop_Depth (Unit, Generic_Item) = 0
         and then IR.Loop_Depth (Unit, Other) = 0,
         "calls snapshot source nesting without affecting another item");
      Address := IR.Emit_Function_Address (Unit, Generic_Item, Other, Site);
      Landin.Testing.Check
        (Item, IR.Holds (Unit, Generic_Item, Address)
         and then IR.Has_Address_Exposure (Unit, Other),
         "existing function-address construction exposes entry identity");
      IR.Mark_Address_Exposed (Unit, Generic_Item);
      Landin.Testing.Check
        (Item, IR.Has_Address_Exposure (Unit, Generic_Item),
         "lowering can mark externally observable entry identity");
      Nominal := IR.Add_Nominal_Type (Unit, 1);
      IR.Set_Nominal_Shape
        (Unit, Nominal, IR.Field_Shape_Array'[1 => (others => <>)],
         Policy => Landin.Layouts.Optimal);
      Landin.Testing.Check
        (Item, IR.Layout_Of (Unit, Nominal) = Landin.Layouts.Optimal
         and then not IR.Has_C_Layout (Unit, Nominal),
         "nominal shape stores one explicit neutral layout policy");
   end Concrete_Metadata;

   procedure Deterministic_Reports (Item : in out Landin.Testing.Context) is
      Report : Reports.Report;
      Decision : constant Reports.Specialization_Decision :=
        (Item => 1, Reason => Reports.Disabled, others => <>);
      Placement : constant Layout.Plan := Layout.Make
        ([(1, 1), (8, 8), (1, 1), (8, 8)], Landin.Layouts.Optimal);
   begin
      Reports.Append (Report, Decision);
      Reports.Append
        (Report, Reports.Routine_Statistics'
           (Item => 1, Frame_Bytes => 2 ** 40, Instructions => 17,
            others => <>));
      Reports.Append_Layout (Report, 3, Landin.Layouts.Optimal, Placement);
      declare
         First : constant String := Reports.JSON
           (Report, Landin.Targets.Linux_X86_64, Opt.Reference_Options);
         Again : constant String := Reports.JSON
           (Report, Landin.Targets.Linux_X86_64, Opt.Reference_Options);
      begin
         Landin.Testing.Check_Equal
           (Item, First, Again, "equivalent reports are byte-identical");
         Landin.Testing.Check
           (Item, Ada.Strings.Fixed.Index
              (First, """reason"":""disabled""") > 0
            and then Ada.Strings.Fixed.Index
              (First, """frame_bytes"":1099511627776") > 0
            and then Ada.Strings.Fixed.Index
              (First, """offsets"": [16,0,17,8]") > 0,
            "negative decisions and target-byte measurements render exactly");
      end;
      Landin.Testing.Check
        (Item, Reports.Layout_Position (Report, 1) = 3
         and then Reports.Layout_Policy (Report, 1) = Landin.Layouts.Optimal
         and then Reports.Layout_Plan (Report, 1).Offsets = Placement.Offsets,
         "typed layout data round trips independently of JSON");
      begin
         Reports.Append (Report, Decision);
         Landin.Testing.Fail (Item, "duplicate report identity was accepted");
      exception
         when Landin.Compiler_Defect =>
            Landin.Testing.Check (Item, True, "duplicate identity refused");
      end;
      Reports.Clear (Report);
      Landin.Testing.Check
        (Item, Reports.Specialization_Count (Report) = 0
         and then Reports.Routine_Count (Report) = 0
         and then Reports.Layout_Count (Report) = 0,
         "report state belongs to one compilation request");
   end Deterministic_Reports;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "opt foundations", "exact independent options",
         Exact_Options'Access);
      Landin.Testing.Register
        (Into, "opt foundations", "target placement", Target_Placement'Access);
      Landin.Testing.Register
        (Into, "opt foundations", "concrete metadata",
         Concrete_Metadata'Access);
      Landin.Testing.Register
        (Into, "opt foundations", "deterministic reports",
         Deterministic_Reports'Access);
   end Register;

end Landin.Tests.Optimization_Foundations_Suite;
