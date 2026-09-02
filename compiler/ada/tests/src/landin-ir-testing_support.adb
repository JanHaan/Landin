package body Landin.IR.Testing_Support is

   function Image_Byte_Count (Of_Unit : Unit) return Natural
     is (Natural (Of_Unit.Images.Length));

   procedure Overwrite_Image_Run
     (Into  : in out Unit;
      Item  : Item_Id;
      First : Natural;
      Count : Natural)
   is
      Held : Item_Record := Into.Items (Positive (Item));
   begin
      Held.Image := (First => First, Count => Count);
      Held.Has_Image := Count > 0;
      Into.Items (Positive (Item)) := Held;
   end Overwrite_Image_Run;

   procedure Append_Image_Bytes
     (Into  : in out Unit;
      Count : Natural)
   is
   begin
      for Ignored in 1 .. Count loop
         pragma Unreferenced (Ignored);
         Into.Images.Append (0);
      end loop;
   end Append_Image_Bytes;

   procedure Truncate_Image_Bytes
     (Into : in out Unit;
      Down_To : Natural)
   is
   begin
      while Natural (Into.Images.Length) > Down_To loop
         Into.Images.Delete_Last;
      end loop;
   end Truncate_Image_Bytes;

   procedure Overwrite_Item_Nominal
     (Into   : in out Unit;
      Item   : Item_Id;
      Nominal : Nominal_Type_Id)
   is
      Held : Item_Record := Into.Items (Positive (Item));
   begin
      Held.Nominal := Nominal;
      Into.Items (Positive (Item)) := Held;
   end Overwrite_Item_Nominal;

   procedure Overwrite_Slot_Nominal
     (Into   : in out Unit;
      Item   : Item_Id;
      Slot   : Slot_Id;
      Nominal : Nominal_Type_Id)
   is
      Position : constant Positive :=
        Into.Items (Positive (Item)).Slots.First + Positive (Slot);
      Held : Slot_Record := Into.Slots (Position);
   begin
      Held.Nominal := Nominal;
      Into.Slots (Position) := Held;
   end Overwrite_Slot_Nominal;

   procedure Overwrite_Value_Evidence
     (Into     : in out Unit;
      Item     : Item_Id;
      Value    : Value_Id;
      Evidence : Evidence_Id)
   is
      Position : constant Positive :=
        Into.Items (Positive (Item)).Values.First + Positive (Value);
      Held : Instruction := Into.Code (Position);
   begin
      Held.Evidence := Evidence;
      Into.Code (Position) := Held;
   end Overwrite_Value_Evidence;

   procedure Overwrite_Value_Evidence_Entry
     (Into  : in out Unit;
      Item  : Item_Id;
      Value : Value_Id;
      Which : Natural)
   is
      Position : constant Positive :=
        Into.Items (Positive (Item)).Values.First + Positive (Value);
      Held : Instruction := Into.Code (Position);
   begin
      Held.Evidence_Entry := Which;
      Into.Code (Position) := Held;
   end Overwrite_Value_Evidence_Entry;

   procedure Overwrite_Value_Signature
     (Into     : in out Unit;
      Item     : Item_Id;
      Value    : Value_Id;
      Signature : Signature_Id)
   is
      Position : constant Positive :=
        Into.Items (Positive (Item)).Values.First + Positive (Value);
      Held : Instruction := Into.Code (Position);
   begin
      Held.Signature := Signature;
      Into.Code (Position) := Held;
   end Overwrite_Value_Signature;

end Landin.IR.Testing_Support;
