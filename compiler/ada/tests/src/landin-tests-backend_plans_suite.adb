with Landin.Backend;
with Landin.IR;
with Landin.Layouts;
with Landin.Provenance;
with Landin.Resolution;
with Landin.Source;
with Landin.Stages.Configuration;
with Landin.Stages.Resolution;
with Landin.Stages.Syntax;
with Landin.Targets;
with Landin.Targets.Layouts;
with Landin.Types;

package body Landin.Tests.Backend_Plans_Suite is

   package IR renames Landin.IR;
   package Backend renames Landin.Backend;
   package Targets renames Landin.Targets;
   package Layout renames Landin.Targets.Layouts;
   use type IR.Element_Total;
   use type Targets.Byte_Count;
   use type Targets.Byte_Alignment;
   use type Layout.Field_Order;
   use type Layout.Field_Offsets;

   Frontend : aliased Landin.Stages.Syntax.Instance;
   Configurer : aliased Landin.Stages.Configuration.Instance;
   Resolver : aliased Landin.Stages.Resolution.Instance;

   procedure Prepare
     (Item : in out Landin.Testing.Context; Unit : in out IR.Unit;
      Site : out Landin.Provenance.Origin);
   procedure All_Layout_Consumers (Item : in out Landin.Testing.Context);
   procedure Nested_And_Variant (Item : in out Landin.Testing.Context);
   procedure Allocated_Frames (Item : in out Landin.Testing.Context);
   procedure Invalid_Storage (Item : in out Landin.Testing.Context);

   procedure Prepare
     (Item : in out Landin.Testing.Context; Unit : in out IR.Unit;
      Site : out Landin.Provenance.Origin)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Written : constant Landin.Source.Source_Id := Landin.Stages.Add_Source
        (Work, "plans.ldn", "f: () -> none = end f g: () -> none = end g");
   begin
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Resolver'Access);
      Landin.Testing.Check_Equal
        (Item, Landin.Stages.Run (Order, Work), 3,
         "in-memory declarations supply layout provenance");
      IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
      Site := (Written, Landin.Source.Empty_Span);
   end Prepare;

   procedure All_Layout_Consumers (Item : in out Landin.Testing.Context) is
      Unit : IR.Unit;
      Site : Landin.Provenance.Origin;
      Nominal : IR.Nominal_Type_Id;
      Routine, Datum : IR.Item_Id;
      Slot, Array_Slot, Empty_Slot : IR.Slot_Id;
      Block : IR.Block_Id;
      Measurement, Direct_Measurement : IR.Value_Id;
      Shape : IR.Field_Shape;
      Fields : constant IR.Field_Shape_Array :=
        [(Element => Landin.Types.U8, others => <>),
         (Element => Landin.Types.Usize, others => <>),
         (Element => Landin.Types.U8, others => <>),
         (Element => Landin.Types.Usize, others => <>)];
   begin
      Prepare (Item, Unit, Site);
      Nominal := IR.Add_Nominal_Type (Unit, 1);
      IR.Set_Nominal_Shape (Unit, Nominal, Fields, Landin.Layouts.Optimal);
      Shape := (Kind => IR.Aggregate_Field_Shape, Nominal => Nominal,
                others => <>);
      Routine := IR.Add_Item
        (Unit, IR.Routine, 1, Landin.Types.No_Value, Site);
      Datum := IR.Add_Item
        (Unit, IR.Datum, 2, Landin.Types.Aggregate, Site, Nominal);
      Slot := IR.Add_Aggregate_Slot
        (Unit, Routine, IR.No_Declaration, Site, Nominal);
      for Field of Fields loop
         IR.Add_Field (Unit, Datum, Field);
         IR.Add_Slot_Field (Unit, Routine, Slot, Field);
      end loop;
      Array_Slot := IR.Add_Array_Slot
        (Unit, Routine, Shape, 4096, IR.No_Declaration, Site);
      Empty_Slot := IR.Add_Array_Slot
        (Unit, Routine, Shape, 0, IR.No_Declaration, Site);
      Block := IR.Add_Block
        (Unit, Routine, Landin.Resolution.Program_Scope, Site);
      IR.Enter (Unit, Routine, Block);
      Measurement := IR.Emit_Aggregate_Measurement
        (Unit, Routine, IR.Measure_Size, [1 => Shape],
         Landin.Types.Usize, Site);
      Direct_Measurement := IR.Emit_Aggregate_Measurement
        (Unit, Routine, IR.Measure_Size, Fields, Landin.Types.Usize, Site,
         Policy => Landin.Layouts.Optimal);

      for Small in Boolean loop
         declare
            Facts : constant Targets.Target_Facts :=
              (if Small then Targets.Synthetic_32 else Targets.Linux_X86_64);
            Pointer : constant Targets.Byte_Count :=
              Targets.Byte_Count
                (Targets.Bytes (Targets.Pointer_Size (Facts)));
            Plan : constant Layout.Plan :=
              Backend.Nominal_Layout (Unit, Nominal, Facts);
            Frame : constant Backend.Frame :=
              Backend.Laid_Out (Unit, Routine, Facts);
            Size : Targets.Byte_Count;
            Alignment : Targets.Byte_Alignment;
         begin
            Landin.Testing.Check
              (Item, Plan.Size = 3 * Pointer
               and then Plan.Natural_Size = 4 * Pointer
               and then Plan.Order = [2, 4, 1, 3]
               and then Plan.Offsets =
                 [2 * Pointer, 0, 2 * Pointer + 1, Pointer],
               "source identities retain target-derived optimal placement");
            Landin.Testing.Check
              (Item, Backend.Aggregate_Layout (Unit, Shape, Facts).Offsets
                 = Plan.Offsets
               and then Backend.Datum_Layout (Unit, Datum, Facts).Offsets
                 = Plan.Offsets
               and then Backend.Slot_Layout
                 (Unit, Routine, Slot, Facts).Offsets
                 = Plan.Offsets,
               "nominal nested datum and slot replay agree");
            Backend.Measurement_Extent
              (Unit, Routine, Measurement, Facts, Size, Alignment);
            Landin.Testing.Check
              (Item, Size = Plan.Size and then Alignment = Plan.Alignment
               and then Backend.Measurement_Layout
                 (Unit, Routine, Measurement, Facts).Size = Plan.Size,
               "measurement applies the nested policy");
            Backend.Measurement_Extent
              (Unit, Routine, Direct_Measurement, Facts, Size, Alignment);
            Landin.Testing.Check
              (Item, Size = Plan.Size and then Alignment = Plan.Alignment
               and then Backend.Measurement_Layout
                 (Unit, Routine, Direct_Measurement, Facts).Offsets
                   = Plan.Offsets,
               "a flat measurement retains its own explicit policy");
            for Field in 1 .. 4 loop
               Landin.Testing.Check
                 (Item, Backend.Field_Offset
                    (Unit, Routine, Frame, Slot, IR.Part_Position (Field),
                     Facts) = Backend.Slot_Offset (Frame, Slot)
                       - Plan.Offsets (Field),
                  "slot addressing subtracts physical source-field offset");
            end loop;
            Backend.Aggregate_Extent
              (Unit, Routine, Array_Slot, Facts, Size, Alignment);
            Landin.Testing.Check
              (Item, Size = 4096 * Plan.Size
               and then Alignment = Plan.Alignment
               and then Backend.Field_Offset
                 (Unit, Routine, Frame, Array_Slot, 4096, Facts)
                 = Backend.Slot_Offset (Frame, Array_Slot) - 4095 * Plan.Size,
               "array placement repeats padded elements without expansion");
            Backend.Aggregate_Extent
              (Unit, Routine, Empty_Slot, Facts, Size, Alignment);
            Landin.Testing.Check
              (Item, Size = 0 and then Alignment = 1
               and then Backend.Has_Slot_Home (Frame, Empty_Slot),
               "an empty array retains an explicit zero-byte home");
         end;
      end loop;
   end All_Layout_Consumers;

   procedure Nested_And_Variant (Item : in out Landin.Testing.Context) is
      Unit : IR.Unit;
      Site : Landin.Provenance.Origin;
      Nominal : IR.Nominal_Type_Id;
      Shape, Variant, Repeated, Empty : IR.Field_Shape;
      Run, Cases : Natural;
      Fields : constant IR.Field_Shape_Array :=
        [(Element => Landin.Types.U8, others => <>),
         (Element => Landin.Types.Usize, others => <>),
         (Element => Landin.Types.U8, others => <>),
         (Element => Landin.Types.Usize, others => <>)];
   begin
      Prepare (Item, Unit, Site);
      Landin.Testing.Check
        (Item, Landin.Provenance.Is_Known (Site),
         "nested shape provenance is known");
      Nominal := IR.Add_Nominal_Type (Unit, 1);
      IR.Set_Nominal_Shape (Unit, Nominal, Fields, Landin.Layouts.Optimal);
      Shape := (Kind => IR.Aggregate_Field_Shape, Nominal => Nominal,
                others => <>);
      Run := IR.Add_Shape_Run (Unit, [Fields (1), Shape]);
      Cases := IR.Add_Case_Run (Unit, [1 => (First => Run, Count => 2)]);
      Variant := (Kind => IR.Variant_Field_Shape, Element => Landin.Types.U8,
                  Cases => 1, Payloads_First => Cases, others => <>);
      Repeated := IR.Make_Array_Shape (Unit, 2 ** 30, Shape);
      Empty := IR.Make_Array_Shape (Unit, 0, Shape);
      for Small in Boolean loop
         declare
            Facts : constant Targets.Target_Facts :=
              (if Small then Targets.Synthetic_32 else Targets.Linux_X86_64);
            Pointer : constant Targets.Byte_Count :=
              Targets.Byte_Count
                (Targets.Bytes (Targets.Pointer_Size (Facts)));
            Outer : constant IR.Field_Shape_Array :=
              [Fields (1), Variant, Fields (3), Fields (4)];
            Natural_Plan : constant Layout.Plan := Backend.Fields_Layout
              (Unit, Outer, Landin.Layouts.Natural, Facts);
            C_Plan : constant Layout.Plan := Backend.Fields_Layout
              (Unit, Outer, Landin.Layouts.C, Facts);
            Optimal : constant Layout.Plan := Backend.Fields_Layout
              (Unit, Outer, Landin.Layouts.Optimal, Facts);
            Size : Targets.Byte_Count;
            Alignment : Targets.Byte_Alignment;
         begin
            Backend.Field_Extent (Unit, Variant, Facts, Size, Alignment);
            Landin.Testing.Check
              (Item, Size = 5 * Pointer
               and then Alignment = Targets.Pointer_Alignment (Facts)
               and then Backend.Variant_Payload_Field_Offset
                 (Unit, Variant, 1, 1, Facts) = Pointer
               and then Backend.Variant_Payload_Field_Offset
                 (Unit, Variant, 1, 2, Facts) = 2 * Pointer,
               "variant keeps tag first and payload declaration order");
            Landin.Testing.Check
              (Item, Natural_Plan.Offsets = C_Plan.Offsets
               and then Natural_Plan.Size = 8 * Pointer
               and then Optimal.Size = 7 * Pointer
               and then Optimal.Order = [2, 4, 1, 3],
               "outer policy moves a whole variant and never its payload");
            Backend.Field_Extent (Unit, Empty, Facts, Size, Alignment);
            Landin.Testing.Check
              (Item, Size = 0 and then Alignment = 1,
               "empty aggregate array fields agree with slots");
            if Small then
               begin
                  Backend.Field_Extent
                    (Unit, Repeated, Facts, Size, Alignment);
                  Landin.Testing.Fail
                    (Item, "oversized synthetic array was accepted");
               exception
                  when Landin.Compiler_Defect =>
                     Landin.Testing.Check
                       (Item, True, "synthetic object limit is enforced");
               end;
            else
               Backend.Field_Extent
                 (Unit, Repeated, Facts, Size, Alignment);
               Landin.Testing.Check
                 (Item, Size = 2 ** 30 * 24 and then Alignment = 8,
                  "huge repeated extents use only one child descriptor");
            end if;
         end;
      end loop;
   end Nested_And_Variant;

   procedure Allocated_Frames (Item : in out Landin.Testing.Context) is
      Unit : IR.Unit;
      Site : Landin.Provenance.Origin;
      Routine : IR.Item_Id;
      Promoted, Pinned, Empty : IR.Slot_Id;
      Block : IR.Block_Id;
      Values : Backend.Spill_Assignments (1 .. 512);
   begin
      Prepare (Item, Unit, Site);
      Routine := IR.Add_Item
        (Unit, IR.Routine, 1, Landin.Types.No_Value, Site);
      Promoted := IR.Add_Slot
        (Unit, Routine, Landin.Types.U8, IR.No_Declaration, Site);
      Pinned := IR.Add_Slot
        (Unit, Routine, Landin.Types.Usize, IR.No_Declaration, Site);
      Empty := IR.Add_Aggregate_Slot
        (Unit, Routine, IR.No_Declaration, Site);
      Block := IR.Add_Block
        (Unit, Routine, Landin.Resolution.Program_Scope, Site);
      IR.Enter (Unit, Routine, Block);
      for Index in Values'Range loop
         declare
            Value : constant IR.Value_Id := IR.Emit_Number
              (Unit, Routine, Landin.Types.Usize,
               Landin.Types.Magnitude (Index), False, Site);
         begin
            Values (Positive (Value)) :=
              (if Index = 1 then 0 else 1 + Index mod 2);
         end;
      end loop;
      for Small in Boolean loop
         declare
            Facts : constant Targets.Target_Facts :=
              (if Small then Targets.Synthetic_32 else Targets.Linux_X86_64);
            Pointer : constant Targets.Byte_Count :=
              Targets.Byte_Count
                (Targets.Bytes (Targets.Pointer_Size (Facts)));
            Alignment : constant Targets.Byte_Alignment :=
              Targets.Pointer_Alignment (Facts);
            Homes : constant Layout.Field_Extent_Array :=
              [(Pointer, Alignment), (Pointer, Alignment)];
            Frame : constant Backend.Frame := Backend.Laid_Out
              (Unit, Routine, Facts, [False, True, True],
               Values, Homes, Homes);
            Reference : constant Backend.Frame :=
              Backend.Laid_Out (Unit, Routine, Facts);
         begin
            Landin.Testing.Check
              (Item, not Backend.Has_Slot_Home (Frame, Promoted)
               and then Backend.Slot_Offset (Frame, Promoted) = 0
               and then Backend.Has_Slot_Home (Frame, Pinned)
               and then Backend.Slot_Offset (Frame, Pinned) = Pointer
               and then Backend.Has_Slot_Home (Frame, Empty)
               and then Backend.Slot_Offset (Frame, Empty) = Pointer,
               "only requested slots reserve cells including zero-size homes");
            Landin.Testing.Check
              (Item, not Backend.Has_Value_Home (Frame, 1)
               and then Backend.Value_Offset (Frame, 1) = 0
               and then Backend.Value_Offset (Frame, 2) = 2 * Pointer
               and then Backend.Value_Offset (Frame, 3) = 3 * Pointer
               and then Backend.Value_Offset (Frame, 512) = 2 * Pointer,
               "reused spill homes bound storage independently of values");
            Landin.Testing.Check
              (Item, Backend.Spill_Offset (Frame, 1) = 2 * Pointer
               and then Backend.Save_Offset (Frame, 1) = 4 * Pointer
               and then Backend.Save_Offset (Frame, 2) = 5 * Pointer
               and then Backend.Spill_Bytes (Frame) = 2 * Pointer
               and then Backend.Save_Bytes (Frame) = 2 * Pointer
               and then Backend.Extent (Frame) = Targets.Align_Up
                 (5 * Pointer, Targets.Stack_Alignment (Facts)),
               "save and spill homes never overlap and final extent aligns");
            Landin.Testing.Check
              (Item, Backend.Has_Slot_Home (Reference, Promoted)
               and then Backend.Value_Offset (Reference, 1) = 3 * Pointer
               and then Backend.Extent (Reference)
                 > 50 * Backend.Extent (Frame),
               "reference keeps one scalar cell per instruction");
         end;
      end loop;
   end Allocated_Frames;

   procedure Invalid_Storage (Item : in out Landin.Testing.Context) is
      Unit : IR.Unit;
      Site : Landin.Provenance.Origin;
      Routine : IR.Item_Id;
      Slot : IR.Slot_Id;
      Block : IR.Block_Id;
      Value : IR.Value_Id;
      Facts : constant Targets.Target_Facts := Targets.Linux_X86_64;
   begin
      Prepare (Item, Unit, Site);
      Routine := IR.Add_Item
        (Unit, IR.Routine, 1, Landin.Types.No_Value, Site);
      Slot := IR.Add_Slot
        (Unit, Routine, Landin.Types.U8, IR.No_Declaration, Site);
      Block := IR.Add_Block
        (Unit, Routine, Landin.Resolution.Program_Scope, Site);
      IR.Enter (Unit, Routine, Block);
      Value := IR.Emit_Number
        (Unit, Routine, Landin.Types.Usize, 1, False, Site);
      for Which in 1 .. 8 loop
         declare
            Spills : Layout.Field_Extent_Array := [1 => (8, 8)];
            Saves : Layout.Field_Extent_Array := [1 => (8, 8)];
         begin
            case Which is
               when 3 => Spills (1).Size := 1;
               when 4 => Spills (1).Alignment := 1;
               when 5 => Spills (1).Alignment := 3;
               when 6 => Saves (1).Alignment := 32;
               when 7 => Spills (1).Size := Targets.Byte_Count'Last;
               when others => null;
            end case;
            declare
               Frame : constant Backend.Frame := Backend.Laid_Out
                 (Unit, Routine, Facts,
                  (if Which = 1 then Backend.Home_Mask'(2 => True)
                   else Backend.Home_Mask'(1 => True)),
                  (if Which = 8 then Backend.Spill_Assignments'(1 .. 0 => 0)
                   else Backend.Spill_Assignments'
                     (1 => (if Which = 2 then 2 else 1))),
                  Spills, Saves);
            begin
               Landin.Testing.Fail
                 (Item, "invalid storage plan returned frame size"
                  & Targets.Byte_Count'Image (Backend.Extent (Frame)));
            end;
         exception
            when Landin.Compiler_Defect =>
               Landin.Testing.Check (Item, True, "invalid storage refused");
         end;
      end loop;
      declare
         Frame : constant Backend.Frame := Backend.Laid_Out
           (Unit, Routine, Facts, [1 => False], [1 => 0],
            Layout.Field_Extent_Array'(1 .. 0 => <>),
            Layout.Field_Extent_Array'(1 .. 0 => <>));
      begin
         Landin.Testing.Check
           (Item, Backend.Extent (Frame) = 0
            and then not Backend.Has_Slot_Home (Frame, Slot)
            and then not Backend.Has_Value_Home (Frame, Value),
            "an all-register plan reserves no frame cells");
      end;
      declare
         Frame : constant Backend.Frame := Backend.Laid_Out
           (Unit, Routine, Facts, [1 => True], [1 => 2],
            [(1, 1), (8, 8), (2, 2)], [(16, 16), (1, 1)]);
      begin
         Landin.Testing.Check
           (Item, Backend.Spill_Offset (Frame, 1) = 2
            and then Backend.Spill_Offset (Frame, 2) = 16
            and then Backend.Spill_Offset (Frame, 3) = 18
            and then Backend.Save_Offset (Frame, 1) = 48
            and then Backend.Save_Offset (Frame, 2) = 49
            and then Backend.Spill_Bytes (Frame) = 11
            and then Backend.Save_Bytes (Frame) = 17
            and then Backend.Extent (Frame) = 64,
            "downward placement aligns addresses after reserving each size");
      end;
      declare
         Empty_Routine : constant IR.Item_Id := IR.Add_Item
           (Unit, IR.Routine, IR.No_Declaration, Landin.Types.No_Value, Site);
         Empty : constant IR.Slot_Id := IR.Add_Aggregate_Slot
           (Unit, Empty_Routine, IR.No_Declaration, Site);
         Frame : constant Backend.Frame := Backend.Laid_Out
           (Unit, Empty_Routine, Facts);
      begin
         Landin.Testing.Check
           (Item, Backend.Extent (Frame) = 0
            and then Backend.Slot_Offset (Frame, Empty) = 0
            and then Backend.Has_Slot_Home (Frame, Empty),
            "zero offset does not mean an empty aggregate lost its home");
      end;
   end Invalid_Storage;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "backend plans", "all layout consumers",
         All_Layout_Consumers'Access);
      Landin.Testing.Register
        (Into, "backend plans", "nested and variant placement",
         Nested_And_Variant'Access);
      Landin.Testing.Register
        (Into, "backend plans", "allocated frames", Allocated_Frames'Access);
      Landin.Testing.Register
        (Into, "backend plans", "invalid storage", Invalid_Storage'Access);
   end Register;

end Landin.Tests.Backend_Plans_Suite;
