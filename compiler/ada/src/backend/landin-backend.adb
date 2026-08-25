package body Landin.Backend is

   use type Landin.Targets.Byte_Count;

   ------------------------------------------------------------------
   --  Size_Of
   ------------------------------------------------------------------

   function Size_Of
     (Item : Landin.Types.Scalar_Name;
      Facts : Landin.Targets.Target_Facts)
     return Landin.Targets.Scalar_Size
     is (Landin.Types.Storage_Size (Item, Facts));

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
         Built.Slots.Append
           (Placed
              (Landin.IR.Type_Of
                 (Of_Unit, Item, Landin.IR.Slot_Id (Slot))));
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
