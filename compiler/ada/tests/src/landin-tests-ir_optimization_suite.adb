with Ada.Exceptions;
with Landin.Backend.X86_64;
with Landin.Build_Reports;
with Landin.IR.Control_Flow;
with Landin.IR.Dump;
with Landin.IR.Simplification;
with Landin.IR.Specialization;
with Landin.IR.Specialization_Policy;
with Landin.IR.Verifier;
with Landin.Optimization;
with Landin.Provenance;
with Landin.Resolution;
with Landin.Source;
with Landin.Stages.Checking;
with Landin.Stages.Configuration;
with Landin.Stages.Lowering;
with Landin.Stages.Resolution;
with Landin.Stages.Syntax;
with Landin.Targets;
with Landin.Types;

package body Landin.Tests.IR_Optimization_Suite is
   package IR renames Landin.IR;
   package Opt renames Landin.Optimization;
   package Reports renames Landin.Build_Reports;
   use type IR.Opcode;
   use type IR.Block_Id;
   use type Opt.Objective;
   use type Landin.Provenance.Origin;
   use type Reports.Specialization_Action;
   use type Reports.Decision_Reason;
   use type Opt.Specialization_Mode;
   use type Landin.Source.Source_Id;
   use type Landin.Types.Magnitude;
   use type Landin.Types.Folded;
   use type IR.Verifier.Fault_Kind;

   Frontend : aliased Landin.Stages.Syntax.Instance;
   Configurer : aliased Landin.Stages.Configuration.Instance;
   Resolver : aliased Landin.Stages.Resolution.Instance;
   Checker : aliased Landin.Stages.Checking.Instance;
   Lowerer : aliased Landin.Stages.Lowering.Instance;

   Generic_Source : constant String :=
     "ordered: type = concept (t: type) "
     & "less: (a: t, b: t) -> (r: bool) end ordered "
     & "less: (a: i32, b: i32) -> (r: bool) = a < b end less "
     & "i32 is ordered (less: less) "
     & "choose: (t: type is ordered, a: t, b: t) -> (r: t) = "
     & "if t.less(a,b) then r = a else r = b end if end choose "
     & "public main: () -> (r: i32) = r = choose(42,43) end main";

   procedure Lower
     (Item : in out Landin.Testing.Context;
      Work : in out Landin.Stages.Compilation; Text : String);
   function Text (Work : in out Landin.Stages.Compilation) return String;
   function Count (Code : IR.Unit; Op : IR.Opcode) return Natural;
   procedure Constant_Shifts (Item : in out Landin.Testing.Context);
   procedure Effect_Preservation (Item : in out Landin.Testing.Context);
   procedure Static_Dispatch (Item : in out Landin.Testing.Context);
   procedure Exposed_Evidence (Item : in out Landin.Testing.Context);
   procedure Raw_Any (Item : in out Landin.Testing.Context);
   procedure Incoming_Evidence (Item : in out Landin.Testing.Context);
   procedure Instance_Costs (Item : in out Landin.Testing.Context);
   procedure Large_Graph (Item : in out Landin.Testing.Context);
   procedure Scalar_Boundaries (Item : in out Landin.Testing.Context);
   procedure Policy_Boundaries (Item : in out Landin.Testing.Context);
   procedure Cyclic_Islands (Item : in out Landin.Testing.Context);

   type Incoming_Kind is (Literal_Table, Unknown_Table, Wrong_Table);
   procedure Evidence_Unit
     (Code : in out IR.Unit; Work : in out Landin.Stages.Compilation;
      Incoming : Incoming_Kind; Instances : Positive; Recursive : Boolean);

   procedure Lower
     (Item : in out Landin.Testing.Context;
      Work : in out Landin.Stages.Compilation; Text : String)
   is
      Order : Landin.Stages.Pipeline;
      Written : constant Landin.Source.Source_Id :=
        Landin.Stages.Add_Source (Work, "ir-opt.ldn", Text);
      Ran : Natural;
   begin
      pragma Assert (Written /= Landin.Source.No_Source);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Resolver'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Landin.Stages.Append (Order, Lowerer'Access);
      Ran := Landin.Stages.Run (Order, Work);
      Landin.Testing.Check_Equal
        (Item, Ran, 5, "source reaches verified lowering: "
         & Landin.Stages.Rendered_Report (Work));
   end Lower;

   function Text (Work : in out Landin.Stages.Compilation) return String is
     (IR.Dump.Text (Landin.Stages.Code (Work).all,
                    Landin.Stages.Meanings (Work).all,
                    Landin.Stages.Identities (Work).all));

   function Count (Code : IR.Unit; Op : IR.Opcode) return Natural is
      Total : Natural := 0;
   begin
      for I in 1 .. IR.Item_Count (Code) loop
         for V in 1 .. IR.Value_Count (Code, IR.Item_Id (I)) loop
            if IR.Op_Of (Code, IR.Item_Id (I), IR.Value_Id (V)) = Op then
               Total := Total + 1;
            end if;
         end loop;
      end loop;
      return Total;
   end Count;

   procedure Constant_Shifts (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
   begin
      Lower (Item, Work,
        "public f: () -> (r: i32) = r = -1 >> 32 end f");
      declare
         Before : constant String := Text (Work);
      begin
         IR.Simplification.Run
           (Landin.Stages.Code (Work).all, Landin.Stages.Target (Work),
            Opt.None);
         Landin.Testing.Check_Equal
           (Item, Text (Work), Before, "none keeps the lowering oracle");
      end;
      IR.Simplification.Run
        (Landin.Stages.Code (Work).all, Landin.Stages.Target (Work), Opt.Size);
      Landin.Testing.Check_Equal
        (Item, Count (Landin.Stages.Code (Work).all, IR.Shift_Right), 0,
         "the constant shift is folded");
      declare
         Code : IR.Unit renames Landin.Stages.Code (Work).all;
         Return_Value : constant IR.Value_Id := IR.Nth_Operand
           (Code, 1, IR.Value_Id (IR.Value_Count (Code, 1)), 1);
      begin
         Landin.Testing.Check
           (Item, IR.Op_Of (Code, 1, Return_Value) = IR.Number
            and then IR.Number_Of (Code, 1, Return_Value) = 0
            and then not IR.Is_Negated (Code, 1, Return_Value),
            "every beyond-width shift is zero, including signed right shift");
      end;
   end Constant_Shifts;

   procedure Effect_Preservation (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
   begin
      Lower (Item, Work,
        "extern(c) link(symbol: ""tick"") tick: () -> (r: i32) "
        & "public f: (x: i32, y: i32) -> (r: i32) = "
        & "_ = tick() unchecked begin r = x / y end unchecked end f");
      IR.Simplification.Run
        (Landin.Stages.Code (Work).all, Landin.Stages.Target (Work), Opt.Size);
      Landin.Testing.Check
        (Item, Count (Landin.Stages.Code (Work).all, IR.Call) = 1
         and then Count (Landin.Stages.Code (Work).all, IR.Divide) = 1,
         "discarded effects and unknown division survive");
      declare
         Before : constant String := Text (Work);
      begin
         IR.Simplification.Run
           (Landin.Stages.Code (Work).all, Landin.Stages.Target (Work),
            Opt.Size);
         Landin.Testing.Check_Equal
           (Item, Text (Work), Before, "a settled rewrite is repeatable");
      end;
   end Effect_Preservation;

   procedure Static_Dispatch (Item : in out Landin.Testing.Context) is
   begin
      for Mode in Opt.Specialization_Mode loop
         declare
            Work : Landin.Stages.Compilation :=
              Landin.Stages.Create (Landin.Targets.Linux_X86_64);
            Report : Reports.Report;
         begin
            Lower (Item, Work, Generic_Source);
            declare
               Before : constant String := Text (Work);
            begin
               IR.Specialization.Run
                 (Landin.Stages.Code (Work).all, Landin.Stages.Target (Work),
                  (Opt.None, Mode), Report);
               Landin.Testing.Check_Equal
                 (Item, Reports.Specialization_Count (Report), 1,
                  "one semantic instance gets one decision");
               if Mode = Opt.Off then
                  Landin.Testing.Check_Equal
                    (Item, Text (Work), Before,
                     "off preserves every evidence dispatch instruction");
               else
                  Landin.Testing.Check
                    (Item, Count (Landin.Stages.Code (Work).all,
                                  IR.Indirect_Call) = 0
                     and then Reports.Nth_Specialization
                       (Report, 1).Direct_Calls_Made = 1,
                     "a saved-and-reloaded static callee becomes direct");
               end if;
            end;
            IR.Verifier.Verify
              (Landin.Stages.Code (Work).all, Landin.Stages.Target (Work));
         end;
      end loop;
   end Static_Dispatch;

   procedure Exposed_Evidence (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Report : Reports.Report;
   begin
      Lower (Item, Work, Generic_Source);
      for I in 1 .. IR.Item_Count (Landin.Stages.Code (Work).all) loop
         if IR.Instance_Position_Of
           (Landin.Stages.Code (Work).all, IR.Item_Id (I)) /= 0
         then
            IR.Mark_Address_Exposed
              (Landin.Stages.Code (Work).all, IR.Item_Id (I));
         end if;
      end loop;
      IR.Specialization.Run
        (Landin.Stages.Code (Work).all, Landin.Stages.Target (Work),
         (Opt.Speed, Opt.All_Eligible), Report);
      Landin.Testing.Check
        (Item, Count (Landin.Stages.Code (Work).all, IR.Indirect_Call) = 1
         and then Reports.Nth_Specialization (Report, 1).Action
           = Reports.Declined
         and then Reports.Nth_Specialization (Report, 1).Reason
           = Reports.Address_Exposed,
         "all never assumes the expected table for an exposed entry");
   end Exposed_Evidence;

   procedure Raw_Any (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Report : Reports.Report;
   begin
      Lower (Item, Work,
        "display: type = concept (t: type) "
        & "code: (self: ptr t) -> (value: i32) end display "
        & "code: (self: ptr u32) -> (value: i32) = 42 end code "
        & "u32 is display (code: code) "
        & "erase_raw: () -> (result: any display) = "
        & "raw: ptr u32 = ptr(0x4002_0000) result = any(raw) end erase_raw "
        & "public main: () -> (code: i32) = _ = erase_raw() code = 42 "
        & "end main");
      IR.Specialization.Run
        (Landin.Stages.Code (Work).all, Landin.Stages.Target (Work),
         Opt.Default_Options, Report);
      IR.Simplification.Run
        (Landin.Stages.Code (Work).all, Landin.Stages.Target (Work), Opt.Size);
      declare
         Assembly : constant String := Landin.Backend.X86_64.Text
           (Landin.Stages.Code (Work).all, Landin.Stages.Meanings (Work).all,
            Landin.Stages.Identities (Work).all, Landin.Stages.Target (Work),
            Opt.Default_Options);
      begin
         Landin.Testing.Check (Item, Assembly'Length > 0,
                              "raw pointer evidence retains carrier shape");
      end;
      declare
         Dynamic : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Decisions : Reports.Report;
      begin
         Lower (Item, Dynamic,
           "display: type = concept (t: type) "
           & "code: (self: ptr t) -> (value: i32) end display "
           & "code: (self: ptr i32) -> (value: i32) = self.val end code "
           & "i32 is display (code: code) "
           & "public main: () -> (result: i32) = value: i32 = 42 "
           & "erased: any display = any(addr value) "
           & "result = erased.code() end main");
         IR.Specialization.Run
           (Landin.Stages.Code (Dynamic).all, Landin.Stages.Target (Dynamic),
            (Opt.Speed, Opt.All_Eligible), Decisions);
         IR.Simplification.Run
           (Landin.Stages.Code (Dynamic).all, Landin.Stages.Target (Dynamic),
            Opt.Speed);
         Landin.Testing.Check
           (Item, Count
              (Landin.Stages.Code (Dynamic).all, IR.Evidence_Self) = 1
            and then Count
              (Landin.Stages.Code (Dynamic).all, IR.Indirect_Call) = 1,
            "all retains verified erased projection and self adjacency");
      end;
   exception
      when Problem : others =>
         Landin.Testing.Fail
           (Item, Ada.Exceptions.Exception_Information (Problem)
            & Text (Work));
   end Raw_Any;

   procedure Evidence_Unit
     (Code : in out IR.Unit; Work : in out Landin.Stages.Compilation;
      Incoming : Incoming_Kind; Instances : Positive; Recursive : Boolean)
   is
      Site : constant Landin.Provenance.Origin :=
        IR.Origin_Of (Landin.Stages.Code (Work).all, 1);
      Generic_Items : array (1 .. Instances) of IR.Item_Id;
      Parameters : array (Generic_Items'Range) of IR.Slot_Id;
      Root, Provider : IR.Item_Id;
      Hidden : IR.Slot_Id := IR.No_Slot;
      Signature, Empty : IR.Signature_Id;
      Expected, Other : IR.Evidence_Id;
      Block : IR.Block_Id;
      Table, Projection, Called : IR.Value_Id;
   begin
      IR.Prepare (Code, Landin.Stages.Meanings (Work).all);
      Signature := IR.Add_Signature_With_Results
        (Code, [1 => (Kind => Landin.Types.Usize, others => <>)],
         IR.No_Signature_Parts);
      Empty := IR.Add_Signature_With_Results
        (Code, IR.No_Signature_Parts, IR.No_Signature_Parts);
      Provider := IR.Add_Item
        (Code, IR.Routine, IR.No_Declaration, Landin.Types.No_Value, Site);
      IR.Set_Signature (Code, Provider, Empty);
      Block := IR.Add_Block
        (Code, Provider, Landin.Resolution.Program_Scope, Site);
      IR.Enter (Code, Provider, Block);
      IR.Emit_Leave (Code, Provider, IR.No_Value, Site);
      IR.Leave_Block (Code, Provider);
      Expected := IR.Add_Evidence
        (Code, (Element => Landin.Types.I32, others => <>));
      IR.Add_Evidence_Entry (Code, Expected, Provider, Empty);
      Other := IR.Add_Evidence
        (Code, (Element => Landin.Types.I32, others => <>));
      IR.Add_Evidence_Entry (Code, Other, Provider, Empty);
      for I in Generic_Items'Range loop
         Generic_Items (I) := IR.Add_Routine_Instance_Item
           (Code, I, 1, Landin.Types.No_Value, Site);
         IR.Set_Signature (Code, Generic_Items (I), Signature);
         Parameters (I) := IR.Add_Parameter
           (Code, Generic_Items (I), Landin.Types.Usize,
            IR.No_Declaration, Site);
         IR.Bind_Evidence_Parameter (Code, Generic_Items (I), 1, Expected);
      end loop;
      Root := IR.Add_Item
        (Code, IR.Routine, IR.No_Declaration, Landin.Types.No_Value, Site);
      IR.Set_Signature
        (Code, Root, (if Incoming = Unknown_Table then Signature else Empty));
      if Incoming = Unknown_Table then
         Hidden := IR.Add_Parameter
           (Code, Root, Landin.Types.Usize, IR.No_Declaration, Site);
      end if;
      for I in Generic_Items'Range loop
         Block := IR.Add_Block
           (Code, Generic_Items (I), Landin.Resolution.Program_Scope, Site);
         IR.Enter (Code, Generic_Items (I), Block);
         Table := IR.Emit_Load (Code, Generic_Items (I), Parameters (I), Site);
         Projection := IR.Emit_Evidence_Function
           (Code, Generic_Items (I), Table, Expected, 1, Site);
         IR.Set_Loop_Depth (Code, Generic_Items (I), 1);
         Called := IR.Emit_Indirect_Call
           (Code, Generic_Items (I), Empty, Landin.Types.No_Value, Site);
         IR.Add_Argument (Code, Generic_Items (I), Called, Projection);
         IR.Set_Loop_Depth (Code, Generic_Items (I), 0);
         if Recursive then
            Called := IR.Emit_Call
              (Code, Generic_Items (I), Generic_Items (I),
               Landin.Types.No_Value, Site);
            IR.Add_Argument (Code, Generic_Items (I), Called, Table);
         end if;
         IR.Emit_Leave (Code, Generic_Items (I), IR.No_Value, Site);
         IR.Leave_Block (Code, Generic_Items (I));
      end loop;
      Block := IR.Add_Block
        (Code, Root, Landin.Resolution.Program_Scope, Site);
      IR.Enter (Code, Root, Block);
      if Incoming = Unknown_Table then
         Table := IR.Emit_Load (Code, Root, Hidden, Site);
      else
         Table := IR.Emit_Evidence_Address
           (Code, Root, (if Incoming = Wrong_Table then Other else Expected),
            Site);
      end if;
      for Generic_Item of Generic_Items loop
         Called := IR.Emit_Call
           (Code, Root, Generic_Item, Landin.Types.No_Value, Site);
         IR.Add_Argument (Code, Root, Called, Table);
      end loop;
      IR.Emit_Leave (Code, Root, IR.No_Value, Site);
      IR.Leave_Block (Code, Root);
      IR.Verifier.Verify (Code, Landin.Stages.Target (Work));
   end Evidence_Unit;

   procedure Incoming_Evidence (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
   begin
      Lower (Item, Work, "f: () -> none = end f");
      for Incoming in Incoming_Kind loop
         for Recursive in Boolean loop
            declare
               Code : IR.Unit;
               Report : Reports.Report;
            begin
               Evidence_Unit (Code, Work, Incoming, 1, Recursive);
               IR.Specialization.Run
                 (Code, Landin.Stages.Target (Work),
                  (Opt.Speed, Opt.All_Eligible), Report);
               declare
                  Decision : constant Reports.Specialization_Decision :=
                    Reports.Nth_Specialization (Report, 1);
               begin
                  Landin.Testing.Check
                    (Item, (if Incoming = Literal_Table
                            then Decision.Action = Reports.Specialized
                              and then Count (Code, IR.Indirect_Call) = 0
                            else Decision.Action = Reports.Declined
                              and then Decision.Reason
                                = Reports.Unknown_Evidence
                              and then Count (Code, IR.Indirect_Call) = 1),
                     "incoming proof, including a recursive forwarding edge: "
                     & Incoming'Image & Recursive'Image);
               end;
            end;
         end loop;
      end loop;
      declare
         Code : IR.Unit;
         Report : Reports.Report;
         Callable : IR.Evidence_Id;
      begin
         Evidence_Unit (Code, Work, Literal_Table, 1, True);
         Callable := IR.Add_Evidence
           (Code, (Element => Landin.Types.I32, others => <>));
         IR.Add_Evidence_Entry
           (Code, Callable, 2, IR.Signature_Of (Code, IR.Item_Id'(2)));
         IR.Specialization.Run
           (Code, Landin.Stages.Target (Work),
            (Opt.Speed, Opt.All_Eligible), Report);
         Landin.Testing.Check
           (Item, Reports.Nth_Specialization (Report, 1).Reason
              = Reports.Address_Exposed
            and then Count (Code, IR.Indirect_Call) = 1,
            "table-callable recursion keeps an unknown-evidence fallback");
      end;
   end Incoming_Evidence;

   procedure Instance_Costs (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
   begin
      Lower (Item, Work, "f: () -> none = end f");
      for Objective in Opt.Objective loop
         for Mode in Opt.Specialization_Mode loop
            declare
               Code : IR.Unit;
               Report : Reports.Report;
               Selected : constant Boolean := Mode = Opt.All_Eligible
                 or else (Mode = Opt.Auto and then Objective = Opt.Speed);
            begin
               Evidence_Unit (Code, Work, Literal_Table, 2, False);
               IR.Specialization.Run
                 (Code, Landin.Stages.Target (Work),
                  (Objective, Mode), Report);
               Landin.Testing.Check_Equal
                 (Item, Count (Code, IR.Indirect_Call),
                  (if Selected then 0 else 2),
                  "two instances use independent objective and mode");
               for I in 1 .. 2 loop
                  declare
                     Decision : constant Reports.Specialization_Decision :=
                       Reports.Nth_Specialization (Report, I);
                  begin
                     Landin.Testing.Check
                       (Item, Decision.Benefit = 17
                        and then Decision.Estimated_Growth = 12
                        and then Decision.Reason =
                          (if Mode = Opt.Off then Reports.Disabled
                           elsif Mode = Opt.All_Eligible then Reports.Forced
                           elsif Selected then Reports.Profitable
                           else Reports.Cost_Threshold),
                        "measured IR cost uses the documented threshold");
                  end;
               end loop;
            end;
         end loop;
      end loop;
   end Instance_Costs;

   procedure Large_Graph (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Code : IR.Unit;
      Routine : IR.Item_Id;
      Blocks : array (1 .. 2048) of IR.Block_Id;
      Condition : IR.Value_Id;
   begin
      Lower (Item, Work, "f: () -> none = end f");
      IR.Prepare (Code, Landin.Stages.Meanings (Work).all);
      declare
         Site : constant Landin.Provenance.Origin :=
           IR.Origin_Of (Landin.Stages.Code (Work).all, 1);
      begin
         Routine := IR.Add_Item
           (Code, IR.Routine, 1, Landin.Types.No_Value, Site);
         for B in Blocks'Range loop
            Blocks (B) := IR.Add_Block
              (Code, Routine, Landin.Resolution.Program_Scope, Site);
         end loop;
         for B in Blocks'Range loop
            IR.Enter (Code, Routine, Blocks (B));
            if B <= 1023 then
               Condition := IR.Emit_Truth (Code, Routine, True, Site);
               IR.Emit_Branch
                 (Code, Routine, Condition, Blocks (B + 1),
                  Blocks (B + 1024), Site);
            elsif B = 1024 then
               IR.Emit_Jump (Code, Routine, Blocks (2048), Site);
            else
               IR.Emit_Leave (Code, Routine, IR.No_Value, Site);
            end if;
            IR.Leave_Block (Code, Routine);
         end loop;
         IR.Verifier.Verify (Code, Landin.Stages.Target (Work));
         declare
            Graph : constant IR.Control_Flow.Graph :=
              IR.Control_Flow.Make (Code, Routine);
         begin
            Landin.Testing.Check
              (Item, IR.Control_Flow.Node_Visits (Graph) = 2048
               and then IR.Control_Flow.Edge_Visits (Graph) = 2047,
               "large sparse CFG traversal visits each node and edge once");
         end;
         IR.Simplification.Run
           (Code, Landin.Stages.Target (Work), Opt.Size);
         Landin.Testing.Check
           (Item, IR.Block_Count (Code, Routine) = 1025
            and then Count (Code, IR.Branch) = 0
            and then IR.Target_Of
              (Code, Routine, IR.Nth_Value (Code, Routine, 1024, 1)) = 1025
            and then IR.Origin_Of (Code, Routine, IR.Value_Id'(1)) = Site,
            "compaction removes islands and remaps jumps, keeping sites");
         Blocks (1) := IR.Add_Block
           (Code, Routine, Landin.Resolution.Program_Scope, Site);
         declare
            Before : constant String := IR.Dump.Text
              (Code, Landin.Stages.Meanings (Work).all,
               Landin.Stages.Identities (Work).all);
         begin
            begin
               IR.Simplification.Run
                 (Code, Landin.Stages.Target (Work), Opt.Size);
               Landin.Testing.Fail (Item, "malformed input accepted");
            exception
               when Landin.Compiler_Defect =>
                  Landin.Testing.Check_Equal
                    (Item, IR.Dump.Text
                       (Code, Landin.Stages.Meanings (Work).all,
                        Landin.Stages.Identities (Work).all), Before,
                     "invalid input is refused before any rewrite");
            end;
         end;
      end;
   end Large_Graph;

   procedure Scalar_Boundaries (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      type Example is record
         Kind : Landin.Types.Integer_Name;
         Op : IR.Binary_Kind;
         Left, Right, Answer : Landin.Types.Folded;
         Folds, Unchecked : Boolean;
      end record;
      Examples : constant array (Positive range <>) of Example :=
        [(Landin.Types.U64, IR.Wrapping_Add, 2 ** 64 - 1, 1, 0, True, False),
         (Landin.Types.U64, IR.Add, 2 ** 64 - 1, 1, 0, False, False),
         (Landin.Types.U64, IR.Multiply, 2 ** 64 - 1,
          2 ** 64 - 1, 0, False, False),
         (Landin.Types.U64, IR.Wrapping_Multiply, 2 ** 64 - 1,
          2 ** 64 - 1, 1, True, False),
         (Landin.Types.I64, IR.Divide, -(2 ** 63), -1, 0, False, False),
         (Landin.Types.I64, IR.Remainder, -(2 ** 63), -1, 0, True, False),
         (Landin.Types.I32, IR.Divide, 3, 0, 0, False, True),
         (Landin.Types.I32, IR.Shift_Left, 1, -1, 0, False, True),
         (Landin.Types.I32, IR.Shift_Right, -16, 2, -4, True, False),
         (Landin.Types.I8, IR.Add, 127, 1, -128, True, True),
         (Landin.Types.I8, IR.Subtract, -128, 1, 0, False, False),
         (Landin.Types.I8, IR.Wrapping_Subtract, -128, 1, 127, True, False)];
   begin
      Lower (Item, Work, "f: () -> none = end f");
      for Example of Examples loop
         for Discard in Boolean loop
            declare
               Code : IR.Unit;
               Site : constant Landin.Provenance.Origin :=
                 IR.Origin_Of (Landin.Stages.Code (Work).all, 1);
               Routine : IR.Item_Id;
               Block : IR.Block_Id;
               Left, Right, Answer : IR.Value_Id;
            begin
               IR.Prepare (Code, Landin.Stages.Meanings (Work).all);
               Routine := IR.Add_Item
                 (Code, IR.Routine, 1,
                  (if Discard then Landin.Types.No_Value else Example.Kind),
                  Site);
               Block := IR.Add_Block
                 (Code, Routine, Landin.Resolution.Program_Scope, Site);
               IR.Enter (Code, Routine, Block);
               Left := IR.Emit_Number
                 (Code, Routine, Example.Kind,
                  Landin.Types.Magnitude (abs Example.Left),
                  Example.Left < 0, Site);
               Right := IR.Emit_Number
                 (Code, Routine, Example.Kind,
                  Landin.Types.Magnitude (abs Example.Right),
                  Example.Right < 0, Site);
               if Example.Unchecked then
                  IR.Begin_Unchecked (Code, Routine);
               end if;
               Answer := IR.Emit_Binary
                 (Code, Routine, Example.Op, Left, Right, Example.Kind, Site);
               if Example.Unchecked then
                  IR.End_Unchecked (Code, Routine);
               end if;
               IR.Emit_Leave
                 (Code, Routine, (if Discard then IR.No_Value else Answer),
                  Site);
               IR.Leave_Block (Code, Routine);
               IR.Simplification.Run
                 (Code, Landin.Stages.Target (Work), Opt.Size);
               Landin.Testing.Check_Equal
                 (Item, Count (Code, Example.Op),
                  (if Example.Folds then 0 else 1),
                  "safe folds and discarded mandatory traps: "
                  & Example.Op'Image & Discard'Image);
               if Example.Folds and then not Discard then
                  Answer := IR.Nth_Operand
                    (Code, Routine,
                     IR.Value_Id (IR.Value_Count (Code, Routine)), 1);
                  Landin.Testing.Check
                    (Item, IR.Op_Of (Code, Routine, Answer) = IR.Number
                     and then IR.Number_Of (Code, Routine, Answer)
                       = Landin.Types.Magnitude (abs Example.Answer)
                     and then IR.Is_Negated (Code, Routine, Answer)
                       = (Example.Answer < 0),
                     "folded result retains exact target integer bits");
               end if;
            end;
         end loop;
      end loop;
      for Synthetic in Boolean loop
         declare
            Code : IR.Unit;
            Facts : constant Landin.Targets.Target_Facts :=
              (if Synthetic then Landin.Targets.Synthetic_32
               else Landin.Targets.Linux_X86_64);
            Site : constant Landin.Provenance.Origin :=
              IR.Origin_Of (Landin.Stages.Code (Work).all, 1);
            Routine : IR.Item_Id;
            Block : IR.Block_Id;
            Left, Right, Answer : IR.Value_Id;
         begin
            IR.Prepare (Code, Landin.Stages.Meanings (Work).all);
            Routine := IR.Add_Item
              (Code, IR.Routine, 1, Landin.Types.Usize, Site);
            Block := IR.Add_Block
              (Code, Routine, Landin.Resolution.Program_Scope, Site);
            IR.Enter (Code, Routine, Block);
            Left := IR.Emit_Number
              (Code, Routine, Landin.Types.Usize, 2 ** 32 - 1, False, Site);
            Right := IR.Emit_Number
              (Code, Routine, Landin.Types.Usize, 1, False, Site);
            Answer := IR.Emit_Binary
              (Code, Routine, IR.Wrapping_Add, Left, Right,
               Landin.Types.Usize, Site);
            IR.Emit_Leave (Code, Routine, Answer, Site);
            IR.Leave_Block (Code, Routine);
            IR.Simplification.Run (Code, Facts, Opt.Size);
            Answer := IR.Nth_Operand
              (Code, Routine, IR.Value_Id (IR.Value_Count (Code, Routine)), 1);
            Landin.Testing.Check
              (Item, IR.Op_Of (Code, Routine, Answer) = IR.Number
               and then IR.Number_Of (Code, Routine, Answer)
                 = (if Synthetic then 0 else 2 ** 32),
               "usize folding uses the selected target, not the host");
         end;
      end loop;
   end Scalar_Boundaries;

   procedure Policy_Boundaries (Item : in out Landin.Testing.Context) is
      package Policy renames IR.Specialization_Policy;
   begin
      Landin.Testing.Check
        (Item, Policy.Benefit (0, 0, 0) = 0
         and then Policy.Benefit (1, 0, 1) = 9
         and then Policy.Benefit (32, 4, 16) = 1296
         and then Policy.Benefit
           (Natural'Last, Natural'Last, Natural'Last) = 1296,
         "entry, loop and size caps bound cost arithmetic");
      Landin.Testing.Check
        (Item, not Policy.Profitable (39, 10, Opt.Size)
         and then Policy.Profitable (40, 10, Opt.Size)
         and then not Policy.Profitable (9, 10, Opt.Speed)
         and then Policy.Profitable (10, 10, Opt.Speed)
         and then not Policy.Profitable (39, 10, Opt.None)
         and then not Policy.Profitable
           (Natural'Last, Natural'Last, Opt.Size),
         "inclusive size/speed thresholds do not overflow growth times four");
   end Policy_Boundaries;

   procedure Cyclic_Islands (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Sizes : constant array (1 .. 2) of Positive := [1000, 10000];
   begin
      Lower (Item, Work, "f: () -> none = end f");
      for Size of Sizes loop
         for Island in Boolean loop
            declare
               Code : IR.Unit;
               Site : constant Landin.Provenance.Origin :=
                 IR.Origin_Of (Landin.Stages.Code (Work).all, 1);
               Routine : IR.Item_Id;
               Blocks : array (1 .. Size) of IR.Block_Id;
            begin
               IR.Prepare (Code, Landin.Stages.Meanings (Work).all);
               Routine := IR.Add_Item
                 (Code, IR.Routine, 1, Landin.Types.No_Value, Site);
               for B in Blocks'Range loop
                  Blocks (B) := IR.Add_Block
                    (Code, Routine, Landin.Resolution.Program_Scope, Site);
               end loop;
               for B in Blocks'Range loop
                  IR.Enter (Code, Routine, Blocks (B));
                  if Island and then B = Size - 2 then
                     IR.Emit_Leave (Code, Routine, IR.No_Value, Site);
                  else
                     IR.Emit_Jump
                       (Code, Routine,
                        (if B = Size then Blocks (Size - 1)
                         else Blocks (B + 1)), Site);
                  end if;
                  IR.Leave_Block (Code, Routine);
               end loop;
               declare
                  Graph : constant IR.Control_Flow.Graph :=
                    IR.Control_Flow.Make (Code, Routine);
                  Fault : constant IR.Verifier.Fault := IR.Verifier.Check
                    (Code, Landin.Stages.Target (Work));
                  Edges : Natural := 0;
               begin
                  for B in Blocks'Range loop
                     declare
                        Edge : Natural := IR.Control_Flow.First_Predecessor
                          (Graph, Blocks (B));
                     begin
                        while Edge /= 0 loop
                           Edges := Edges + 1;
                           Edge := IR.Control_Flow.Next_Predecessor
                             (Graph, Edge);
                        end loop;
                     end;
                  end loop;
                  Landin.Testing.Check
                    (Item, Edges = Size - (if Island then 1 else 0)
                     and then IR.Control_Flow.Node_Visits (Graph)
                       = Size - (if Island then 2 else 0)
                     and then IR.Control_Flow.Edge_Visits (Graph)
                       = Size - (if Island then 3 else 0),
                     "successor and predecessor work scales with edges: "
                     & Size'Image & Island'Image);
                  Landin.Testing.Check
                    (Item, (if Island then Fault.Kind
                              = IR.Verifier.Block_Unreachable
                            and then Fault.Block = IR.Block_Id (Size - 1)
                            else Fault.Kind = IR.Verifier.Nothing_Wrong),
                     "incoming edges do not prove a cyclic island reachable");
               end;
            end;
         end loop;
      end loop;
   end Cyclic_Islands;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "ir opt", "constant shifts", Constant_Shifts'Access);
      Landin.Testing.Register
        (Into, "ir opt", "effect preservation", Effect_Preservation'Access);
      Landin.Testing.Register
        (Into, "ir opt", "static dispatch", Static_Dispatch'Access);
      Landin.Testing.Register
        (Into, "ir opt", "exposed evidence", Exposed_Evidence'Access);
      Landin.Testing.Register
        (Into, "ir opt", "raw any", Raw_Any'Access);
      Landin.Testing.Register
        (Into, "ir opt", "incoming evidence", Incoming_Evidence'Access);
      Landin.Testing.Register
        (Into, "ir opt", "instance costs", Instance_Costs'Access);
      Landin.Testing.Register
        (Into, "ir opt", "large graph", Large_Graph'Access);
      Landin.Testing.Register
        (Into, "ir opt", "scalar boundaries", Scalar_Boundaries'Access);
      Landin.Testing.Register
        (Into, "ir opt", "policy boundaries", Policy_Boundaries'Access);
      Landin.Testing.Register
        (Into, "ir opt", "cyclic islands", Cyclic_Islands'Access);
   end Register;
end Landin.Tests.IR_Optimization_Suite;
