with Landin.Backend.Work_Arrays;
with Landin.IR.Shape_Measurement;

package body Landin.Backend is

   use type Landin.IR.Element_Total;
   use type Landin.IR.Field_Shape_Kind;
   use type Landin.Targets.Byte_Count;
   use type Landin.Targets.Byte_Alignment;
   use type Landin.Types.Type_Kind;

   package IR renames Landin.IR;
   package Targets renames Landin.Targets;
   package Layout renames Landin.Targets.Layouts;

   function Fields_Layout
     (Of_Unit : IR.Unit;
      Fields  : IR.Field_Shape_Array;
      Policy  : Landin.Layouts.Policy;
      Facts   : Targets.Target_Facts) return Layout.Plan
     is (IR.Shape_Measurement.Fields_Layout
           (Of_Unit, Fields, Policy, Facts,
            Targets.Maximum_Object_Size (Facts)));

   function Aggregate_Layout
     (Of_Unit : IR.Unit;
      Shape   : IR.Field_Shape;
      Facts   : Targets.Target_Facts) return Layout.Plan
     is (IR.Shape_Measurement.Aggregate_Layout
           (Of_Unit, Shape, Facts, Targets.Maximum_Object_Size (Facts)));

   function Path_Offset
     (Of_Unit : Landin.IR.Unit;
      Shape : Landin.IR.Field_Shape;
      Path  : Landin.IR.Path_Step_Array;
      Facts : Landin.Targets.Target_Facts)
      return Landin.Targets.Byte_Count
   is
      Reached : Landin.IR.Field_Shape := Shape;
      Total   : Landin.Targets.Byte_Count := 0;
   begin
      for Step of Path loop
         if Step.Case_Index = 0
           and then Reached.Kind = Landin.IR.Array_Field_Shape
         then
            --  D127: a step into an array names [0520]'s element
            --  position, so the offset is one multiplication.
            declare
               Element : constant Landin.IR.Field_Shape :=
                 Landin.IR.Array_Element_Shape (Of_Unit, Reached);
               Size : Landin.Targets.Byte_Count;
               Alignment : Landin.Targets.Byte_Alignment;
            begin
               Landin.Backend.Field_Extent
                 (Of_Unit, Element, Facts, Size, Alignment);
               Total := Total
                 + Landin.Targets.Byte_Count
                     (Landin.IR.Element_Total (Step.Field) - 1)
                   * Size;
               Reached := Element;
            end;
         elsif Step.Case_Index = 0 then
            declare
               Plan : constant Landin.Targets.Layouts.Plan :=
                 Aggregate_Layout (Of_Unit, Reached, Facts);
            begin
               Total := Total + Plan.Offsets (Positive (Step.Field));
               Reached := Landin.IR.Nth_Aggregate_Field
                 (Of_Unit, Reached, Positive (Step.Field));
            end;
         else
            Total := Total
              + Landin.Backend.Variant_Payload_Field_Offset
                  (Of_Unit, Reached, Step.Case_Index,
                   Positive (Step.Field), Facts);
            Reached := Landin.IR.Nth_Variant_Case_Field
              (Of_Unit, Reached, Step.Case_Index,
               Positive (Step.Field));
         end if;
      end loop;
      return Total;
   end Path_Offset;

   function Nominal_Layout
     (Of_Unit : IR.Unit;
      Nominal : IR.Nominal_Type_Id;
      Facts   : Targets.Target_Facts) return Layout.Plan
   is
      Fields : IR.Field_Shape_Array
        (1 .. IR.Nominal_Field_Count (Of_Unit, Nominal));
   begin
      for Index in Fields'Range loop
         Fields (Index) := IR.Nth_Nominal_Field (Of_Unit, Nominal, Index);
      end loop;
      return Fields_Layout
        (Of_Unit, Fields, IR.Layout_Of (Of_Unit, Nominal), Facts);
   end Nominal_Layout;

   function Slot_Layout
     (Of_Unit : IR.Unit;
      Item    : IR.Item_Id;
      Slot    : IR.Slot_Id;
      Facts   : Targets.Target_Facts) return Layout.Plan
   is
   begin
      if not IR.Holds (Of_Unit, Item, Slot)
        or else not IR.Is_Aggregate (Of_Unit, Item, Slot)
      then
         raise Compiler_Defect with "a slot layout needs an aggregate slot";
      end if;
      declare
         Fields : IR.Field_Shape_Array
           (1 .. IR.Slot_Field_Count (Of_Unit, Item, Slot));
      begin
         for Index in Fields'Range loop
            Fields (Index) := IR.Nth_Slot_Field_Shape
              (Of_Unit, Item, Slot, Index);
         end loop;
         return Fields_Layout
           (Of_Unit, Fields, IR.Layout_Of (Of_Unit, Item, Slot), Facts);
      end;
   end Slot_Layout;

   function Datum_Layout
     (Of_Unit : IR.Unit;
      Item    : IR.Item_Id;
      Facts   : Targets.Target_Facts) return Layout.Plan
   is
   begin
      if not IR.Holds (Of_Unit, Item)
        or else IR.Result_Of (Of_Unit, Item) /= Landin.Types.Aggregate
      then
         raise Compiler_Defect with "a datum layout needs an aggregate";
      end if;
      declare
         Fields : IR.Field_Shape_Array (1 .. IR.Field_Count (Of_Unit, Item));
      begin
         for Index in Fields'Range loop
            Fields (Index) := IR.Nth_Field_Shape (Of_Unit, Item, Index);
         end loop;
         return Fields_Layout
           (Of_Unit, Fields, IR.Layout_Of (Of_Unit, Item), Facts);
      end;
   end Datum_Layout;

   function Measurement_Layout
     (Of_Unit : IR.Unit;
      Item    : IR.Item_Id;
      Value   : IR.Value_Id;
      Facts   : Targets.Target_Facts) return Layout.Plan
   is
   begin
      if not IR.Holds (Of_Unit, Item, Value)
        or else not IR.Is_Aggregate_Measurement (Of_Unit, Item, Value)
      then
         raise Compiler_Defect with "a measurement layout needs an aggregate";
      end if;
      declare
         Fields : IR.Field_Shape_Array
           (1 .. IR.Measurement_Field_Count (Of_Unit, Item, Value));
      begin
         for Index in Fields'Range loop
            Fields (Index) := IR.Nth_Measurement_Field
              (Of_Unit, Item, Value, Index);
         end loop;
         return Fields_Layout
           (Of_Unit, Fields, IR.Layout_Of (Of_Unit, Item, Value), Facts);
      end;
   end Measurement_Layout;

   ------------------------------------------------------------------
   --  Size_Of
   ------------------------------------------------------------------

   function Size_Of
     (Item : Landin.Types.Scalar_Name;
      Facts : Landin.Targets.Target_Facts)
     return Landin.Targets.Scalar_Size
     is (Landin.Types.Storage_Size (Item, Facts));

   function Case_Layout
     (Of_Unit : IR.Unit; Shape : IR.Field_Shape; Which : Positive;
      Facts : Targets.Target_Facts) return Layout.Plan
     is (IR.Shape_Measurement.Case_Layout
           (Of_Unit, Shape, Which, Facts,
            Targets.Maximum_Object_Size (Facts)));

   function Variant_Layout
     (Of_Unit : IR.Unit; Shape : IR.Field_Shape;
      Facts : Targets.Target_Facts) return Layout.Plan
     is (IR.Shape_Measurement.Variant_Layout
           (Of_Unit, Shape, Facts, Targets.Maximum_Object_Size (Facts)));

   procedure Repeat_Extent
     (Length : IR.Element_Total; Facts : Targets.Target_Facts;
      Size : in out Targets.Byte_Count;
      Alignment : in out Targets.Byte_Alignment);

   procedure Repeat_Extent
     (Length : IR.Element_Total; Facts : Targets.Target_Facts;
      Size : in out Targets.Byte_Count;
      Alignment : in out Targets.Byte_Alignment)
   is
      Repeated : constant Layout.Field_Extent := IR.Shape_Measurement.Repeated
        ((Size, Alignment), Length, Targets.Maximum_Object_Size (Facts));
   begin
      Size := Repeated.Size;
      Alignment := Repeated.Alignment;
   end Repeat_Extent;

   procedure Field_Extent
     (Of_Unit   : Landin.IR.Unit;
      Shape     : Landin.IR.Field_Shape;
      Facts     : Landin.Targets.Target_Facts;
      Size      : out Landin.Targets.Byte_Count;
      Alignment : out Landin.Targets.Byte_Alignment)
   is
      Measured : constant Layout.Field_Extent := IR.Shape_Measurement.Extent
        (Of_Unit, Shape, Facts, Targets.Maximum_Object_Size (Facts));
   begin
      Size := Measured.Size;
      Alignment := Measured.Alignment;
   end Field_Extent;

   function Variant_Payload_Field_Offset
     (Of_Unit       : Landin.IR.Unit;
      Shape         : Landin.IR.Field_Shape;
      Which         : Positive;
      Payload_Field : Positive;
      Facts         : Landin.Targets.Target_Facts)
      return Landin.Targets.Byte_Count
   is
      Part : constant Layout.Plan := Variant_Layout (Of_Unit, Shape, Facts);
      Payload : constant Layout.Plan :=
        Case_Layout (Of_Unit, Shape, Which, Facts);
   begin
      if Payload_Field > Payload.Count then
         raise Compiler_Defect with "no such variant payload field";
      end if;
      return Part.Offsets (2) + Payload.Offsets (Payload_Field);
   end Variant_Payload_Field_Offset;

   ------------------------------------------------------------------
   --  A target-neutral measurement
   ------------------------------------------------------------------

   procedure Measurement_Extent
     (Of_Unit   : Landin.IR.Unit;
      Item      : Landin.IR.Item_Id;
      Value     : Landin.IR.Value_Id;
      Facts     : Landin.Targets.Target_Facts;
      Size      : out Landin.Targets.Byte_Count;
      Alignment : out Landin.Targets.Byte_Alignment)
   is
   begin
      if Landin.IR.Is_Aggregate_Measurement (Of_Unit, Item, Value) then
         declare
            Placed : constant Layout.Plan :=
              Measurement_Layout (Of_Unit, Item, Value, Facts);
         begin
            Size := Placed.Size;
            Alignment := Placed.Alignment;
         end;
      else
         declare
            Held : constant Landin.Targets.Scalar_Size :=
              Size_Of (Landin.IR.Measured_Of (Of_Unit, Item, Value), Facts);
         begin
            Size := Landin.Targets.Byte_Count (Landin.Targets.Bytes (Held));
            Alignment := Landin.Targets.Alignment_Of (Facts, Held);
         end;
      end if;
   end Measurement_Extent;

   ------------------------------------------------------------------
   --  An aggregate cell
   ------------------------------------------------------------------

   procedure Aggregate_Extent
     (Of_Unit   : Landin.IR.Unit;
      Item      : Landin.IR.Item_Id;
      Slot      : Landin.IR.Slot_Id;
      Facts     : Landin.Targets.Target_Facts;
      Size      : out Landin.Targets.Byte_Count;
      Alignment : out Landin.Targets.Byte_Alignment)
   is
   begin
      if Landin.IR.Is_Array (Of_Unit, Item, Slot) then
         declare
            Element_Size : Landin.Targets.Byte_Count;
            Element_Alignment : Landin.Targets.Byte_Alignment;
         begin
            Field_Extent
              (Of_Unit,
               Landin.IR.Slot_Array_Element_Shape (Of_Unit, Item, Slot),
               Facts, Element_Size, Element_Alignment);
            Repeat_Extent
              (IR.Slot_Array_Length (Of_Unit, Item, Slot), Facts,
               Element_Size, Element_Alignment);
            Size := Element_Size;
            Alignment := Element_Alignment;
         end;
      else
         declare
            Placed : constant Layout.Plan :=
              Slot_Layout (Of_Unit, Item, Slot, Facts);
         begin
            Size := Placed.Size;
            Alignment := Placed.Alignment;
         end;
      end if;
   end Aggregate_Extent;

   function Field_Offset
     (Of_Unit  : Landin.IR.Unit;
      Item     : Landin.IR.Item_Id;
      Of_Frame : Frame;
      Slot     : Landin.IR.Slot_Id;
      Field    : Landin.IR.Part_Position;
      Facts    : Landin.Targets.Target_Facts)
     return Landin.Targets.Byte_Count
   is
      Offset : Landin.Targets.Byte_Count;
   begin
      if Landin.IR.Is_Array (Of_Unit, Item, Slot) then
         declare
            Element_Size : Landin.Targets.Byte_Count;
            Element_Alignment : Landin.Targets.Byte_Alignment;
         begin
            Field_Extent
              (Of_Unit,
               Landin.IR.Slot_Array_Element_Shape (Of_Unit, Item, Slot),
               Facts, Element_Size, Element_Alignment);
            Offset :=
              Landin.Targets.Byte_Count
                (Landin.IR.Element_Total (Field) - 1)
              * Element_Size;
         end;
      else
         Offset := Slot_Layout (Of_Unit, Item, Slot, Facts).Offsets
           (Positive (Field));
      end if;
      return Slot_Offset (Of_Frame, Slot) - Offset;
   end Field_Offset;

   ------------------------------------------------------------------
   --  Laid_Out
   ------------------------------------------------------------------

   function Laid_Out
     (Of_Unit : IR.Unit;
      Item    : IR.Item_Id;
      Facts   : Targets.Target_Facts;
      Slots   : Home_Mask;
      Values  : Spill_Assignments;
      Spills  : Layout.Field_Extent_Array;
      Saves   : Layout.Field_Extent_Array) return Frame
   is
      Built : Frame;
      Below : Targets.Byte_Count := 0;
      Maximum : constant Targets.Byte_Count :=
        Targets.Maximum_Object_Size (Facts);

      function Placed
        (Size : Targets.Byte_Count; Alignment : Targets.Byte_Alignment)
         return Targets.Byte_Count;

      function Placed
        (Size : Targets.Byte_Count; Alignment : Targets.Byte_Alignment)
         return Targets.Byte_Count
      is
      begin
         if not Targets.Is_Power_Of_Two (Alignment)
           or else Targets.Stack_Alignment (Facts) mod Alignment /= 0
         then
            raise Compiler_Defect with "a frame home exceeds stack alignment";
         end if;
         if Size > Maximum - Below then
            raise Compiler_Defect with "a frame extent exceeds its target";
         end if;
         Below := Targets.Align_Up (Below + Size, Alignment);
         if Below > Maximum then
            raise Compiler_Defect with "an aligned frame exceeds its target";
         end if;
         return Below;
      end Placed;

   begin
      if not IR.Holds (Of_Unit, Item)
        or else not Targets.Frame_Pointer (Facts)
      then
         raise Compiler_Defect with "a frame needs an item and frame pointer";
      end if;
      if Slots'First /= 1 or else Values'First /= 1
        or else Spills'First /= 1 or else Saves'First /= 1
        or else Slots'Length /= IR.Slot_Count (Of_Unit, Item)
        or else Values'Length /= IR.Value_Count (Of_Unit, Item)
      then
         raise Compiler_Defect with "frame storage runs disagree with the IR";
      end if;

      for Index in Slots'Range loop
         declare
            Slot : constant IR.Slot_Id := IR.Slot_Id (Index);
         begin
            Built.Slot_Homes.Append (Slots (Index));
            if not Slots (Index) then
               Built.Slots.Append (0);
            elsif IR.Is_Aggregate (Of_Unit, Item, Slot)
              or else IR.Is_Array (Of_Unit, Item, Slot)
            then
               declare
                  Size : Targets.Byte_Count;
                  Alignment : Targets.Byte_Alignment;
               begin
                  Aggregate_Extent
                    (Of_Unit, Item, Slot, Facts, Size, Alignment);
                  Built.Slots.Append (Placed (Size, Alignment));
               end;
            else
               declare
                  Held : constant Targets.Scalar_Size :=
                    Size_Of (IR.Type_Of (Of_Unit, Item, Slot), Facts);
               begin
                  Built.Slots.Append
                    (Placed (Targets.Byte_Count (Targets.Bytes (Held)),
                             Targets.Alignment_Of (Facts, Held)));
               end;
            end if;
         end;
      end loop;

      for Home of Spills loop
         Built.Spills.Append (Placed (Home.Size, Home.Alignment));
         Built.Spill_Total := Built.Spill_Total + Home.Size;
      end loop;
      for Home of Saves loop
         Built.Saves.Append (Placed (Home.Size, Home.Alignment));
         Built.Save_Total := Built.Save_Total + Home.Size;
      end loop;

      for Index in Values'Range loop
         declare
            Home : constant Natural := Values (Index);
            Held : constant Landin.Types.Type_Kind :=
              IR.Result_Of (Of_Unit, Item, IR.Value_Id (Index));
         begin
            if Home = 0 then
               Built.Values.Append (0);
            else
               if Home > Spills'Length
                 or else Held not in Landin.Types.Scalar_Name
               then
                  raise Compiler_Defect with "a value names no scalar spill";
               end if;
               declare
                  Size : constant Targets.Scalar_Size := Size_Of (Held, Facts);
               begin
                  if Spills (Home).Size
                       < Targets.Byte_Count (Targets.Bytes (Size))
                    or else Spills (Home).Alignment
                       < Targets.Alignment_Of (Facts, Size)
                  then
                     raise Compiler_Defect with
                       "a spill cannot hold its value";
                  end if;
               end;
               Built.Values.Append (Built.Spills (Home));
            end if;
         end;
      end loop;
      Built.Size := Targets.Align_Up (Below, Targets.Stack_Alignment (Facts));
      if Built.Size > Maximum then
         raise Compiler_Defect with "an aligned frame exceeds its target";
      end if;
      return Built;
   end Laid_Out;

   function Laid_Out
     (Of_Unit : IR.Unit;
      Item    : IR.Item_Id;
      Facts   : Targets.Target_Facts) return Frame
   is
      package Mask_Buffers is new Work_Arrays (Boolean, Home_Mask, True);
      package Value_Buffers is new Work_Arrays
        (Natural, Spill_Assignments, 0);
      package Extent_Buffers is new Work_Arrays
        (Layout.Field_Extent, Layout.Field_Extent_Array, (0, 1));
      Slot_Data : Mask_Buffers.Buffer (IR.Slot_Count (Of_Unit, Item));
      Value_Data : Value_Buffers.Buffer (IR.Value_Count (Of_Unit, Item));
      Spill_Data : Extent_Buffers.Buffer (IR.Value_Count (Of_Unit, Item));
      Slots : Home_Mask renames Slot_Data.Data.all;
      Values : Spill_Assignments renames Value_Data.Data.all;
      Spills : Layout.Field_Extent_Array renames Spill_Data.Data.all;
      Count : Natural := 0;
   begin
      --  The explicit reference plan assigns each scalar its own home in
      --  instruction order.  Storage placement is otherwise exactly shared.
      for Index in Values'Range loop
         declare
            Held : constant Landin.Types.Type_Kind :=
              IR.Result_Of (Of_Unit, Item, IR.Value_Id (Index));
         begin
            if Held in Landin.Types.Scalar_Name then
               declare
                  Size : constant Targets.Scalar_Size := Size_Of (Held, Facts);
               begin
                  Count := Count + 1;
                  Values (Index) := Count;
                  Spills (Count) :=
                    (Targets.Byte_Count (Targets.Bytes (Size)),
                     Targets.Alignment_Of (Facts, Size));
               end;
            end if;
         end;
      end loop;
      return Laid_Out
        (Of_Unit, Item, Facts, Slots, Values, Spills (1 .. Count),
         Layout.Field_Extent_Array'(1 .. 0 => <>));
   end Laid_Out;

   ------------------------------------------------------------------
   --  Reading one back
   ------------------------------------------------------------------

   function Spill_Bytes (Of_Frame : Frame) return Targets.Byte_Count
     is (Of_Frame.Spill_Total);

   function Save_Bytes (Of_Frame : Frame) return Targets.Byte_Count
     is (Of_Frame.Save_Total);

   function Has_Slot_Home
     (Of_Frame : Frame; Slot : IR.Slot_Id) return Boolean
   is
      use type IR.Slot_Id;
   begin
      if Slot = IR.No_Slot
        or else Natural (Slot) > Natural (Of_Frame.Slot_Homes.Length)
      then
         raise Compiler_Defect with "no such frame slot";
      end if;
      return Of_Frame.Slot_Homes (Positive (Slot));
   end Has_Slot_Home;

   function Has_Value_Home
     (Of_Frame : Frame; Value : IR.Value_Id) return Boolean
     is (Value_Offset (Of_Frame, Value) /= 0);

   function Spill_Offset
     (Of_Frame : Frame; Home : Positive) return Targets.Byte_Count
   is
   begin
      if Home > Natural (Of_Frame.Spills.Length) then
         raise Compiler_Defect with "no such frame spill home";
      end if;
      return Of_Frame.Spills (Home);
   end Spill_Offset;

   function Save_Offset
     (Of_Frame : Frame; Home : Positive) return Targets.Byte_Count
   is
   begin
      if Home > Natural (Of_Frame.Saves.Length) then
         raise Compiler_Defect with "no such frame save home";
      end if;
      return Of_Frame.Saves (Home);
   end Save_Offset;

   function Extent (Of_Frame : Frame) return Landin.Targets.Byte_Count
     is (Of_Frame.Size);

   function Slot_Offset
     (Of_Frame : Frame; Slot : Landin.IR.Slot_Id)
     return Landin.Targets.Byte_Count
   is
      use type Landin.IR.Slot_Id;
   begin
      if Slot = Landin.IR.No_Slot
        or else Natural (Slot) > Natural (Of_Frame.Slots.Length)
      then
         raise Compiler_Defect with "no cell was laid out for this slot";
      end if;

      return Of_Frame.Slots (Positive (Slot));
   end Slot_Offset;

   function Value_Offset
     (Of_Frame : Frame; Value : Landin.IR.Value_Id)
     return Landin.Targets.Byte_Count
   is
      use type Landin.IR.Value_Id;
   begin
      if Value = Landin.IR.No_Value
        or else Natural (Value) > Natural (Of_Frame.Values.Length)
      then
         raise Compiler_Defect with "no cell was laid out for this value";
      end if;

      return Of_Frame.Values (Positive (Value));
   end Value_Offset;

end Landin.Backend;
