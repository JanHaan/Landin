with Ada.Exceptions;
with Ada.Strings.Fixed;
with Landin.Backend;
with Landin.Checking;
with Landin.IR;
with Landin.Layouts;
with Landin.Source;
with Landin.Stages.Checking;
with Landin.Stages.Configuration;
with Landin.Stages.Lowering;
with Landin.Stages.Resolution;
with Landin.Stages.Syntax;
with Landin.Targets;
with Landin.Targets.Layouts;
with Landin.Types;

package body Landin.Tests.Array_Layout_Suite is

   package IR renames Landin.IR;
   use type IR.Opcode;
   use type Landin.Layouts.Policy;
   use type Landin.Source.Source_Id;
   use type Landin.Targets.Byte_Count;
   use type Landin.Targets.Byte_Alignment;
   use type Landin.Types.Type_Kind;

   Frontend : aliased Landin.Stages.Syntax.Instance;
   Configurer : aliased Landin.Stages.Configuration.Instance;
   Resolver : aliased Landin.Stages.Resolution.Instance;
   Checker : aliased Landin.Stages.Checking.Instance;
   Lowerer : aliased Landin.Stages.Lowering.Instance;
   LF : constant Character := Character'Val (10);

   procedure Lower
     (Item : in out Landin.Testing.Context;
      Work : in out Landin.Stages.Compilation;
      Text : String);
   procedure Compact_Arrays (Item : in out Landin.Testing.Context);
   procedure Source_Layouts (Item : in out Landin.Testing.Context);
   procedure Source_Loops (Item : in out Landin.Testing.Context);
   procedure Source_Evidence (Item : in out Landin.Testing.Context);
   procedure Array_Composition (Item : in out Landin.Testing.Context);
   procedure Array_Refusals (Item : in out Landin.Testing.Context);
   procedure Fixed_Operands (Item : in out Landin.Testing.Context);

   procedure Lower
     (Item : in out Landin.Testing.Context;
      Work : in out Landin.Stages.Compilation;
      Text : String)
   is
      Order : Landin.Stages.Pipeline;
      Written : constant Landin.Source.Source_Id :=
        Landin.Stages.Add_Source (Work, "r450.ldn", Text);
   begin
      pragma Assert (Written /= Landin.Source.No_Source);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Resolver'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Landin.Stages.Append (Order, Lowerer'Access);
      Landin.Testing.Check_Equal
        (Item, Landin.Stages.Run (Order, Work), 5,
         "in-memory source reaches verified IR");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "no frontend diagnostics: " & Landin.Stages.Rendered_Report (Work));
   exception
      when Problem : others =>
         Landin.Testing.Check
           (Item, False, Ada.Exceptions.Exception_Information (Problem));
   end Lower;

   procedure Compact_Arrays (Item : in out Landin.Testing.Context) is
      Counts : constant array (Positive range <>) of Natural :=
        [0, 1, 4096, 1_048_576];
      Baseline_Values, Baseline_Blocks, Baseline_Slots : Natural := 0;
   begin
      for Count of Counts loop
         declare
            Work : Landin.Stages.Compilation :=
              Landin.Stages.Create (Landin.Targets.Linux_X86_64);
            Unit : constant not null access IR.Unit :=
              Landin.Stages.Code (Work);
            Scalar_Adds : Natural := 0;
         begin
            Lower (Item, Work,
              "f: (a: [" & Count'Image & "]i32) -> (r: ["
              & Count'Image & "]i32) =" & LF
              & "r = a + 3" & LF & "end f");
            if Landin.Stages.Failed (Work) then
               return;
            end if;
            for Position in 1 .. IR.Value_Count (Unit.all, 1) loop
               declare
                  Value : constant IR.Value_Id := IR.Value_Id (Position);
               begin
                  if IR.Op_Of (Unit.all, 1, Value) = IR.Add
                    and then IR.Result_Of (Unit.all, 1, Value)
                      = Landin.Types.I32
                  then
                     Scalar_Adds := Scalar_Adds + 1;
                  end if;
               end;
            end loop;
            Landin.Testing.Check_Equal
              (Item, Scalar_Adds, (if Count = 0 then 0 else 1),
               "empty arrays execute no element arithmetic; others loop");
            if Count = 1 then
               Baseline_Values := IR.Value_Count (Unit.all, 1);
               Baseline_Blocks := IR.Block_Count (Unit.all, 1);
               Baseline_Slots := IR.Slot_Count (Unit.all, 1);
            elsif Count > 1 then
               Landin.Testing.Check
                 (Item, IR.Value_Count (Unit.all, 1) = Baseline_Values
                  and then IR.Block_Count (Unit.all, 1) = Baseline_Blocks
                  and then IR.Slot_Count (Unit.all, 1) = Baseline_Slots,
                  "array length does not expand code or shape metadata");
            end if;
         end;
      end loop;
   end Compact_Arrays;

   procedure Source_Layouts (Item : in out Landin.Testing.Context) is
   begin
      for Small in Boolean loop
         declare
            Facts : constant Landin.Targets.Target_Facts :=
              (if Small then Landin.Targets.Synthetic_32
               else Landin.Targets.Linux_X86_64);
            Work : Landin.Stages.Compilation := Landin.Stages.Create (Facts);
            Unit : constant not null access IR.Unit :=
              Landin.Stages.Code (Work);
            Types : constant not null access Landin.Checking.Table :=
              Landin.Stages.Types (Work);
         begin
            Lower (Item, Work,
              "natural: type = struct"
              & " a: u8 b: usize c: u8 d: usize end natural"
              & LF & "compact: type = layout(optimal) struct"
              & " a: u8 b: usize c: u8 d: usize end compact"
              --  Synthetic32 has no selected C ABI; neutral C placement is
              --  tested separately by backend plans on both target models.
              & (if Small then "" else
                   LF & "foreign: type = layout(c) struct"
                   & " a: u8 b: usize c: u8 d: usize end foreign")
              & LF & "f: () -> (r: usize) = sizeof compact end f");
            if Landin.Stages.Failed (Work) then
               return;
            end if;
            Landin.Testing.Check_Equal
              (Item, IR.Nominal_Type_Count (Unit.all),
               (if Small then 2 else 3),
               "all source layout policies have canonical identities");
            for Position in 1 .. IR.Nominal_Type_Count (Unit.all) loop
               declare
                  Nominal : constant IR.Nominal_Type_Id :=
                    IR.Nth_Nominal_Type (Unit.all, Position);
                  Checked : constant Landin.Checking.Nominal_Type_Id :=
                    Landin.Checking.Nth_Nominal_Type (Types.all, Position);
                  Plan : constant Landin.Targets.Layouts.Plan :=
                    Landin.Backend.Nominal_Layout (Unit.all, Nominal, Facts);
                  Expected : constant Landin.Layouts.Policy :=
                    (case Position is
                        when 1 => Landin.Layouts.Natural,
                        when 2 => Landin.Layouts.Optimal,
                        when others => Landin.Layouts.C);
               begin
                  Landin.Testing.Check
                    (Item, IR.Layout_Of (Unit.all, Nominal) = Expected
                     and then Landin.Checking.Layout_Of (Types.all, Checked)
                       = Expected
                     and then Landin.Checking.Layout_Size (Types.all, Checked)
                       = Plan.Size
                     and then Landin.Checking.Layout_Alignment
                       (Types.all, Checked) = Plan.Alignment,
                     "checker and backend measure the same target policy");
                  for Field in 1 .. Plan.Count loop
                     Landin.Testing.Check
                       (Item, Landin.Checking.Field_Offset
                          (Types.all, Checked, Field) = Plan.Offsets (Field),
                        "field identities stay source-indexed");
                  end loop;
               end;
            end loop;
         end;
      end loop;
   end Source_Layouts;

   procedure Source_Loops (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Unit : constant not null access IR.Unit := Landin.Stages.Code (Work);
      Seen : array (0 .. 2) of Natural := [others => 0];
   begin
      Lower (Item, Work,
        "tick: () -> none = end tick" & LF
        & "public f: () -> none =" & LF
        & "tick()" & LF & "mut i: usize = 0" & LF
        & "while i < 2 do" & LF & "tick()" & LF
        & "mut j: usize = 0" & LF & "while j < 2 do" & LF
        & "tick()" & LF & "inc j" & LF & "end while" & LF
        & "inc i" & LF & "end while" & LF & "tick()" & LF & "end f");
      if Landin.Stages.Failed (Work) then
         return;
      end if;
      for Position in 1 .. IR.Value_Count (Unit.all, 2) loop
         declare
            Value : constant IR.Value_Id := IR.Value_Id (Position);
         begin
            if IR.Op_Of (Unit.all, 2, Value) = IR.Call then
               declare
                  Depth : constant Natural :=
                    IR.Call_Loop_Depth (Unit.all, 2, Value);
               begin
                  Landin.Testing.Check
                    (Item, Depth <= 2, "source depth bound");
                  if Depth <= 2 then
                     Seen (Depth) := Seen (Depth) + 1;
                  end if;
               end;
            end if;
         end;
      end loop;
      Landin.Testing.Check
        (Item, Seen = [2, 1, 1] and then IR.Loop_Depth (Unit.all, 2) = 0
         and then IR.Has_Address_Exposure (Unit.all, 2),
         "nested calls snapshot depth, restore it and expose public entries");
   end Source_Loops;

   procedure Source_Evidence (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Unit : constant not null access IR.Unit := Landin.Stages.Code (Work);
      Instances : Natural := 0;
   begin
      Lower (Item, Work,
        "ordered: type = concept (t: type)"
        & " less: (a: t, b: t) -> (r: bool) end ordered" & LF
        & "less: (a: i32, b: i32) -> (r: bool) = a < b end less" & LF
        & "i32 is ordered (less: less)" & LF
        & "choose: (t: type is ordered, a: t, b: t) -> (r: [2]i32) ="
        & LF & "if t.less(a, b) then r = [42, 0]"
        & " else r = [1, 0] end if end choose" & LF
        & "f: () -> (r: i32) = a: i32 = 1 b: i32 = 2"
        & " values := choose(a, b) r = values[0] end f");
      if Landin.Stages.Failed (Work) then
         return;
      end if;
      for Position in 1 .. IR.Item_Count (Unit.all) loop
         declare
            Routine : constant IR.Item_Id := IR.Item_Id (Position);
         begin
            if IR.Instance_Position_Of (Unit.all, Routine) /= 0 then
               Instances := Instances + 1;
               Landin.Testing.Check
                 (Item, IR.Evidence_Binding_Count (Unit.all, Routine) = 1
                  and then IR.Evidence_Bindings_Are_Valid (Unit.all, Routine),
                  "lowering binds each expected semantic evidence parameter");
               if IR.Evidence_Binding_Count (Unit.all, Routine) = 1 then
                  Landin.Testing.Check
                    (Item, IR.Nth_Evidence_Binding
                       (Unit.all, Routine, 1).Parameter = 2
                     and then IR.Parameter_Count (Unit.all, Routine) = 4,
                     "binding index includes the hidden result address");
               end if;
            end if;
         end;
      end loop;
      Landin.Testing.Check_Equal
        (Item, Instances, 1, "one source instance retains metadata");
   end Source_Evidence;

   procedure Array_Composition (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
   begin
      Lower (Item, Work,
        "row: type = [3]i32 "
        & "box: type = struct values: row end box "
        & "make: () -> (r: row) = r = [2, 4, 6] end make "
        & "scale: (values: row) -> (r: row) = r = values * 2 end scale "
        & "public main: () -> (code: i32) = "
        & "a: row = make() b := a + 3 c: row = 20 - a d := -a "
        & "mut stored: box = zeroed "
        & "stored.values = scale(a + 1) / 2 "
        & "p: ptr mut row = addr stored.values "
        & "p.val = p.val + make() "
        & "fractions: [3]f64 = [2.0, 4.0, 8.0] "
        & "floats := 16.0 / fractions + 0.5 "
        & "code = i32(floats[0]) + p.val[1] + c[0] + d[0] + b[0] "
        & "end main");
   end Array_Composition;

   procedure Fixed_Operands (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
   begin
      Lower (Item, Work,
        "f: (fixed n: u32, x: u32) -> (r: u32) = "
        & "r = if n < 10 then x + n else x end if end f "
        & "public main: () -> (r: i32) = "
        & "i32(f(n: 4, x: u32(38))) end main");
   end Fixed_Operands;

   procedure Array_Refusals (Item : in out Landin.Testing.Context) is
   begin
      for Unary in Boolean loop
         declare
            Work : Landin.Stages.Compilation :=
              Landin.Stages.Create (Landin.Targets.Linux_X86_64);
            Order : Landin.Stages.Pipeline;
            Written : constant Landin.Source.Source_Id :=
              Landin.Stages.Add_Source (Work, "refused.ldn",
                "f: () -> none = a: [2]i32 = [1, 2] _ = "
                & (if Unary then "~a" else "a & a") & " end f");
         begin
            pragma Assert (Written /= Landin.Source.No_Source);
            Landin.Stages.Append (Order, Frontend'Access);
            Landin.Stages.Append (Order, Configurer'Access);
            Landin.Stages.Append (Order, Resolver'Access);
            Landin.Stages.Append (Order, Checker'Access);
            Landin.Stages.Append (Order, Lowerer'Access);
            Landin.Testing.Check_Equal
              (Item, Landin.Stages.Run (Order, Work), 4,
               "array refusal stops at checking, without a compiler defect");
            Landin.Testing.Check
              (Item, Landin.Stages.Failed (Work)
               and then Ada.Strings.Fixed.Index
                 (Landin.Stages.Rendered_Report (Work), "error[L0301]") > 0,
               "array mismatch supplies the catalogue's required label");
         end;
      end loop;
   end Array_Refusals;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "array layout", "array refusals", Array_Refusals'Access);
      Landin.Testing.Register
        (Into, "array layout", "fixed operands", Fixed_Operands'Access);
      Landin.Testing.Register
        (Into, "array layout", "array composition", Array_Composition'Access);
      Landin.Testing.Register
        (Into, "array layout", "compact scalar loops", Compact_Arrays'Access);
      Landin.Testing.Register
        (Into, "array layout", "source layout policies",
         Source_Layouts'Access);
      Landin.Testing.Register
        (Into, "array layout", "source loop metadata", Source_Loops'Access);
      Landin.Testing.Register
        (Into, "array layout", "source evidence metadata",
         Source_Evidence'Access);
   end Register;

end Landin.Tests.Array_Layout_Suite;
