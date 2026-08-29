package body Landin.Backend is

   use type Landin.IR.Element_Total;
   use type Landin.IR.Field_Shape_Kind;
   use type Landin.Targets.Byte_Count;

   ------------------------------------------------------------------
   --  Size_Of
   ------------------------------------------------------------------

   function Size_Of
     (Item : Landin.Types.Scalar_Name;
      Facts : Landin.Targets.Target_Facts)
     return Landin.Targets.Scalar_Size
     is (Landin.Types.Storage_Size (Item, Facts));

   procedure Field_Extent
     (Of_Unit   : Landin.IR.Unit;
      Shape     : Landin.IR.Field_Shape;
      Facts     : Landin.Targets.Target_Facts;
      Size      : out Landin.Targets.Byte_Count;
      Alignment : out Landin.Targets.Byte_Alignment)
   is
      Held : constant Landin.Targets.Scalar_Size :=
        Size_Of (Shape.Element, Facts);
      Bytes : constant Landin.Targets.Byte_Count :=
        Landin.Targets.Byte_Count (Landin.Targets.Bytes (Held));
   begin
      if Shape.Kind = Landin.IR.Scalar_Field_Shape then
         Size := Bytes;
         Alignment := Landin.Targets.Alignment_Of (Facts, Held);
         return;
      end if;

      if Shape.Kind = Landin.IR.Aggregate_Field_Shape then
         declare
            Placed : Landin.Targets.Placement :=
              Landin.Targets.Empty_Placement;
            Ignored : Landin.Targets.Byte_Count;
         begin
            for Field in 1 .. Landin.IR.Aggregate_Field_Count
              (Of_Unit, Shape)
            loop
               declare
                  Part_Size : Landin.Targets.Byte_Count;
                  Part_Alignment : Landin.Targets.Byte_Alignment;
               begin
                  Field_Extent
                    (Of_Unit,
                     Landin.IR.Nth_Aggregate_Field
                       (Of_Unit, Shape, Field),
                     Facts, Part_Size, Part_Alignment);
                  if not Landin.Targets.Can_Place
                    (Placed, Part_Size, Part_Alignment,
                     Landin.Targets.Maximum_Object_Size (Facts))
                  then
                     raise Landin.Compiler_Defect with
                       "a nested aggregate extent overflows";
                  end if;
                  Landin.Targets.Place
                    (Placed, Part_Size, Part_Alignment, Ignored);
               end;
            end loop;
            Size := Landin.Targets.Size_Of (Placed);
            Alignment := Landin.Targets.Alignment_Of (Placed);
            return;
         end;
      end if;

      if Shape.Kind = Landin.IR.Variant_Field_Shape then
         declare
            Payload_Size : Landin.Targets.Byte_Count := 0;
            Payload_Alignment : Landin.Targets.Byte_Alignment := 1;
            Variant_Placement : Landin.Targets.Placement :=
              Landin.Targets.Empty_Placement;
            Ignored : Landin.Targets.Byte_Count;
         begin
            for Which in 1 .. Shape.Cases loop
               declare
                  Payload_Placement : Landin.Targets.Placement :=
                    Landin.Targets.Empty_Placement;
               begin
                  for Field in 1 ..
                    Landin.IR.Variant_Case_Field_Count
                      (Of_Unit, Shape, Which)
                  loop
                     declare
                        Part_Size : Landin.Targets.Byte_Count;
                        Part_Alignment : Landin.Targets.Byte_Alignment;
                     begin
                        Field_Extent
                          (Of_Unit,
                           Landin.IR.Nth_Variant_Case_Field
                             (Of_Unit, Shape, Which, Field),
                           Facts, Part_Size, Part_Alignment);
                        if not Landin.Targets.Can_Place
                          (Payload_Placement, Part_Size, Part_Alignment,
                           Landin.Targets.Maximum_Object_Size (Facts))
                        then
                           raise Landin.Compiler_Defect with
                             "a variant payload extent overflows";
                        end if;
                        Landin.Targets.Place
                          (Payload_Placement, Part_Size, Part_Alignment,
                           Ignored);
                     end;
                  end loop;

                  Payload_Size := Landin.Targets.Byte_Count'Max
                    (Payload_Size,
                     Landin.Targets.Size_Of (Payload_Placement));
                  Payload_Alignment := Landin.Targets.Byte_Alignment'Max
                    (Payload_Alignment,
                     Landin.Targets.Alignment_Of (Payload_Placement));
               end;
            end loop;

            Landin.Targets.Place
              (Variant_Placement, Held, Facts, Ignored);
            if not Landin.Targets.Can_Place
              (Variant_Placement, Payload_Size, Payload_Alignment,
               Landin.Targets.Maximum_Object_Size (Facts))
            then
               raise Landin.Compiler_Defect with
                 "a variant field extent overflows";
            end if;
            Landin.Targets.Place
              (Variant_Placement, Payload_Size, Payload_Alignment, Ignored);
            Size := Landin.Targets.Size_Of (Variant_Placement);
            Alignment := Landin.Targets.Alignment_Of (Variant_Placement);
            return;
         end;
      end if;

      --  D121: an aggregate element repeats its own padded extent, which
      --  is the same recursion this procedure already is.
      declare
         Element_Size : Landin.Targets.Byte_Count := Bytes;
         Element_Alignment : Landin.Targets.Byte_Alignment :=
           Landin.Targets.Alignment_Of (Facts, Held);
      begin
         if Landin.IR.Array_Element_Is_Aggregate (Of_Unit, Shape) then
            Field_Extent
              (Of_Unit, Landin.IR.Array_Element_Shape (Of_Unit, Shape),
               Facts, Element_Size, Element_Alignment);
         end if;

         if Element_Size > 0
           and then Landin.Targets.Byte_Count (Shape.Length)
                      > Landin.Targets.Byte_Count'Last / Element_Size
         then
            raise Landin.Compiler_Defect with
              "an IR aggregate array field extent overflows";
         end if;

         Size := Landin.Targets.Byte_Count (Shape.Length) * Element_Size;
         Alignment :=
           (if Shape.Length = 0 then 1 else Element_Alignment);
      end;
   end Field_Extent;

   function Variant_Payload_Field_Offset
     (Of_Unit       : Landin.IR.Unit;
      Shape         : Landin.IR.Field_Shape;
      Which         : Positive;
      Payload_Field : Positive;
      Facts         : Landin.Targets.Target_Facts)
      return Landin.Targets.Byte_Count
   is
      Payload_Size : Landin.Targets.Byte_Count := 0;
      Payload_Alignment : Landin.Targets.Byte_Alignment := 1;
      Part : Landin.Targets.Placement := Landin.Targets.Empty_Placement;
      Selected : Landin.Targets.Placement :=
        Landin.Targets.Empty_Placement;
      Payload_At, Ignored : Landin.Targets.Byte_Count;
      Field_At : Landin.Targets.Byte_Count := 0;
   begin
      --  First find the union payload's alignment and maximum padded extent.
      for Case_Index in 1 .. Shape.Cases loop
         declare
            Placed : Landin.Targets.Placement :=
              Landin.Targets.Empty_Placement;
         begin
            for Field in 1 .. Landin.IR.Variant_Case_Field_Count
              (Of_Unit, Shape, Case_Index)
            loop
               declare
                  Size : Landin.Targets.Byte_Count;
                  Alignment : Landin.Targets.Byte_Alignment;
               begin
                  Field_Extent
                    (Of_Unit,
                     Landin.IR.Nth_Variant_Case_Field
                       (Of_Unit, Shape, Case_Index, Field),
                     Facts, Size, Alignment);
                  Landin.Targets.Place
                    (Placed, Size, Alignment, Ignored);
               end;
            end loop;
            Payload_Size := Landin.Targets.Byte_Count'Max
              (Payload_Size, Landin.Targets.Size_Of (Placed));
            Payload_Alignment := Landin.Targets.Byte_Alignment'Max
              (Payload_Alignment, Landin.Targets.Alignment_Of (Placed));
         end;
      end loop;

      --  The tag is first.  Placing the maximum payload next gives its
      --  shared base, exactly as Field_Extent does for the whole part.
      Landin.Targets.Place
        (Part, Landin.Types.Storage_Size (Shape.Element, Facts),
         Facts, Ignored);
      Landin.Targets.Place
        (Part, Payload_Size, Payload_Alignment, Payload_At);

      --  A selected case retains ordinary D44/D45 declaration-order layout.
      for Field in 1 .. Payload_Field loop
         declare
            Size : Landin.Targets.Byte_Count;
            Alignment : Landin.Targets.Byte_Alignment;
            This_At : Landin.Targets.Byte_Count;
         begin
            Field_Extent
              (Of_Unit,
               Landin.IR.Nth_Variant_Case_Field
                 (Of_Unit, Shape, Which, Field),
               Facts, Size, Alignment);
            Landin.Targets.Place
              (Selected, Size, Alignment, This_At);
            if Field = Payload_Field then
               Field_At := This_At;
            end if;
         end;
      end loop;

      return Payload_At + Field_At;
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
            Placed : Landin.Targets.Placement :=
              Landin.Targets.Empty_Placement;
            Ignored : Landin.Targets.Byte_Count;
         begin
            for Field in
              1 .. Landin.IR.Measurement_Field_Count (Of_Unit, Item, Value)
            loop
               declare
                  Part : constant Landin.IR.Field_Shape :=
                    Landin.IR.Nth_Measurement_Field
                      (Of_Unit, Item, Value, Field);
                  Part_Size : Landin.Targets.Byte_Count;
                  Part_Alignment : Landin.Targets.Byte_Alignment;
               begin
                  Field_Extent
                    (Of_Unit, Part, Facts, Part_Size, Part_Alignment);
                  Landin.Targets.Place
                    (Placed, Part_Size, Part_Alignment, Ignored);
               end;
            end loop;
            Size := Landin.Targets.Size_Of (Placed);
            Alignment := Landin.Targets.Alignment_Of (Placed);
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

   --  [0750] over a slot's own field run, which is the same arithmetic
   --  Landin.Checking did over the same types: the placement is a
   --  function of the run and the description and of nothing else.
   procedure Place_Slot_Fields
     (Of_Unit : Landin.IR.Unit;
      Item    : Landin.IR.Item_Id;
      Slot    : Landin.IR.Slot_Id;
      Facts   : Landin.Targets.Target_Facts;
      Wanted  : Natural;
      Placed  : out Landin.Targets.Placement;
      Offset  : out Landin.Targets.Byte_Count);

   procedure Place_Slot_Fields
     (Of_Unit : Landin.IR.Unit;
      Item    : Landin.IR.Item_Id;
      Slot    : Landin.IR.Slot_Id;
      Facts   : Landin.Targets.Target_Facts;
      Wanted  : Natural;
      Placed  : out Landin.Targets.Placement;
      Offset  : out Landin.Targets.Byte_Count) is
   begin
      Placed := Landin.Targets.Empty_Placement;
      Offset := 0;

      for Field in
        1 .. Landin.IR.Slot_Field_Count (Of_Unit, Item, Slot)
      loop
         declare
            Shape     : constant Landin.IR.Field_Shape :=
              Landin.IR.Nth_Slot_Field_Shape
                (Of_Unit, Item, Slot, Field);
            Size      : Landin.Targets.Byte_Count;
            Alignment : Landin.Targets.Byte_Alignment;
            At_Offset : Landin.Targets.Byte_Count;
         begin
            Field_Extent (Of_Unit, Shape, Facts, Size, Alignment);
            Landin.Targets.Place
              (Placed, Size, Alignment, At_Offset);

            if Field = Wanted then
               Offset := At_Offset;
            end if;
         end;
      end loop;
   end Place_Slot_Fields;

   procedure Aggregate_Extent
     (Of_Unit   : Landin.IR.Unit;
      Item      : Landin.IR.Item_Id;
      Slot      : Landin.IR.Slot_Id;
      Facts     : Landin.Targets.Target_Facts;
      Size      : out Landin.Targets.Byte_Count;
      Alignment : out Landin.Targets.Byte_Alignment)
   is
      Placed  : Landin.Targets.Placement;
      Ignored : Landin.Targets.Byte_Count;
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
            Size :=
              Landin.Targets.Byte_Count
                (Landin.IR.Slot_Array_Length (Of_Unit, Item, Slot))
              * Element_Size;
            Alignment := Element_Alignment;
         end;
      else
         Place_Slot_Fields
           (Of_Unit, Item, Slot, Facts, 0, Placed, Ignored);
         Size := Landin.Targets.Size_Of (Placed);
         Alignment := Landin.Targets.Alignment_Of (Placed);
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
      Placed : Landin.Targets.Placement;
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
         Place_Slot_Fields
           (Of_Unit, Item, Slot, Facts, Positive (Field), Placed, Offset);
      end if;
      return Slot_Offset (Of_Frame, Slot) - Offset;
   end Field_Offset;

   ------------------------------------------------------------------
   --  Laid_Out
   ------------------------------------------------------------------

   function Laid_Out
     (Of_Unit : Landin.IR.Unit;
      Item    : Landin.IR.Item_Id;
      Facts   : Landin.Targets.Target_Facts) return Frame
   is
      Built : Frame;
      Below : Landin.Targets.Byte_Count := 0;

      --  Places one cell and reports how far below the frame pointer it
      --  starts.  Grown first and then aligned, so the distance is at
      --  least the cell's own size and a multiple of its alignment: the
      --  address it names is then aligned, which the count alone would
      --  not make it.
      function Placed
        (Of_Type : Landin.Types.Scalar_Name)
        return Landin.Targets.Byte_Count;

      function Placed
        (Of_Type : Landin.Types.Scalar_Name)
        return Landin.Targets.Byte_Count
      is
         Size : constant Landin.Targets.Scalar_Size :=
           Size_Of (Of_Type, Facts);
      begin
         Below :=
           Landin.Targets.Align_Up
             (Below + Landin.Targets.Byte_Count
                        (Landin.Targets.Bytes (Size)),
              Landin.Targets.Alignment_Of (Facts, Size));
         return Below;
      end Placed;

   begin
      if not Landin.Targets.Frame_Pointer (Facts) then
         raise Compiler_Defect
           with "this frame is described against a frame pointer";
      end if;

      for Slot in 1 .. Landin.IR.Slot_Count (Of_Unit, Item) loop
         if Landin.IR.Is_Aggregate
              (Of_Unit, Item, Landin.IR.Slot_Id (Slot))
           or else Landin.IR.Is_Array
                     (Of_Unit, Item, Landin.IR.Slot_Id (Slot))
         then
            --  A whole [0750] placement, rounded up to its own alignment
            --  so the cell holds an aggregate the way an array element
            --  would, and then aligned as a cell like any other.
            declare
               Size : Landin.Targets.Byte_Count;
               Alignment : Landin.Targets.Byte_Alignment;
            begin
               Aggregate_Extent
                 (Of_Unit, Item, Landin.IR.Slot_Id (Slot), Facts,
                  Size, Alignment);
               Below := Landin.Targets.Align_Up (Below + Size, Alignment);
               Built.Slots.Append (Below);
            end;
         else
            Built.Slots.Append
              (Placed
                 (Landin.IR.Type_Of
                    (Of_Unit, Item, Landin.IR.Slot_Id (Slot))));
         end if;
      end loop;

      --  A cell for every value, including the ones that define nothing:
      --  a store and a terminator are numbered like any other
      --  instruction, and an offset vector indexed by Value_Id is one
      --  index rather than a second numbering to keep in step.
      for Index in 1 .. Landin.IR.Value_Count (Of_Unit, Item) loop
         declare
            Value : constant Landin.IR.Value_Id :=
              Landin.IR.Value_Id (Index);
            Held  : constant Landin.Types.Type_Kind :=
              Landin.IR.Result_Of (Of_Unit, Item, Value);
         begin
            if Held in Landin.Types.Scalar_Name then
               Built.Values.Append (Placed (Held));
            else
               Built.Values.Append (0);
            end if;
         end;
      end loop;

      Built.Size :=
        Landin.Targets.Align_Up
          (Below, Landin.Targets.Stack_Alignment (Facts));
      return Built;
   end Laid_Out;

   ------------------------------------------------------------------
   --  Reading one back
   ------------------------------------------------------------------

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
