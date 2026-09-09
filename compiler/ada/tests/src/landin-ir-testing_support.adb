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

   procedure Overwrite_Item_Run
     (Into : in out Unit; Item : Item_Id; Which : Item_Run_Kind;
      First, Count : Natural)
   is
      Held : Item_Record := Into.Items (Positive (Item));
      Replacement : constant Run := (First => First, Count => Count);
   begin
      case Which is
         when Slot_Run      => Held.Slots := Replacement;
         when Parameter_Run => Held.Parameters := Replacement;
         when Block_Run     => Held.Blocks := Replacement;
         when Value_Run     => Held.Values := Replacement;
         when Field_Run     => Held.Fields := Replacement;
      end case;
      Into.Items (Positive (Item)) := Held;
   end Overwrite_Item_Run;

   procedure Overwrite_Parameter
     (Into : in out Unit; Item : Item_Id; Index : Positive; Slot : Slot_Id)
   is
   begin
      Into.Parameters
        (Into.Items (Positive (Item)).Parameters.First + Index) := Slot;
   end Overwrite_Parameter;

   procedure Overwrite_Nominal_Run
     (Into : in out Unit; Nominal : Nominal_Type_Id; First, Count : Natural)
   is
      Position : constant Positive :=
        Nominal_Identities.Position (Into, Nominal);
      Held : Nominal_Shape_Record := Into.Nominal_Shapes (Position);
   begin
      Held.Fields := (First => First, Count => Count);
      Into.Nominal_Shapes (Position) := Held;
   end Overwrite_Nominal_Run;

   procedure Overwrite_Shape
     (Into : in out Unit; Position : Positive; Shape : Field_Shape) is
   begin
      Into.Variant_Fields (Position) := Shape;
   end Overwrite_Shape;

   procedure Overwrite_Array_Element_Run
     (Into : in out Unit; Item : Item_Id; First : Natural;
      Slot : Slot_Id := No_Slot) is
   begin
      if Slot = No_Slot then
         Into.Items (Positive (Item)).Element_Run := First;
      else
         declare
            Position : constant Positive :=
              Into.Items (Positive (Item)).Slots.First + Positive (Slot);
         begin
            Into.Slots (Position).Element_Run := First;
         end;
      end if;
   end Overwrite_Array_Element_Run;

   procedure Overwrite_Image_Descriptor
     (Into : in out Unit; Item : Item_Id; Position : Positive;
      Image : Aggregate_Field_Image) is
   begin
      Into.Aggregate_Images
        (Into.Items (Positive (Item)).Aggregate_Images.First + Position) :=
          Image;
   end Overwrite_Image_Descriptor;

   procedure Overwrite_Descriptor_Run
     (Into : in out Unit; Item : Item_Id; First, Count : Natural) is
   begin
      Into.Items (Positive (Item)).Aggregate_Images :=
        (First => First, Count => Count);
   end Overwrite_Descriptor_Run;

   procedure Overwrite_Signature_Parameter
     (Into : in out Unit; Signature : Signature_Id; Index : Positive;
      Part : Signature_Part) is
   begin
      Into.Signature_Parts
        (Into.Signatures (Positive (Signature)).Parameters.First + Index) :=
          Part;
   end Overwrite_Signature_Parameter;

   procedure Overwrite_Signature_Result
     (Into : in out Unit; Signature : Signature_Id; Index : Positive;
      Part : Signature_Part) is
   begin
      Into.Signature_Parts
        (Into.Signatures (Positive (Signature)).Results.First + Index) := Part;
   end Overwrite_Signature_Result;

   procedure Overwrite_Signature_Errors
     (Into : in out Unit; Signature : Signature_Id; Errors : Atom_Set_Id) is
   begin
      Into.Signatures (Positive (Signature)).Errors := Errors;
   end Overwrite_Signature_Errors;

   procedure Overwrite_Signature_Source
     (Into : in out Unit; Signature : Signature_Id; Index : Positive;
      Source : Return_Source_Association) is
   begin
      Into.Return_Sources
        (Into.Signatures (Positive (Signature)).Sources.First + Index) :=
          Source;
   end Overwrite_Signature_Source;

   procedure Overwrite_Evidence_Dispatch
     (Into : in out Unit; Evidence : Evidence_Id; Which : Positive;
      Signature : Signature_Id) is
   begin
      Into.Evidence_Entries
        (Into.Evidence (Positive (Evidence)).Entries.First + Which).Dispatch :=
          Signature;
   end Overwrite_Evidence_Dispatch;

   procedure Overwrite_Item_Signature
     (Into : in out Unit; Item : Item_Id; Signature : Signature_Id) is
   begin
      Into.Items (Positive (Item)).Signature := Signature;
   end Overwrite_Item_Signature;

   procedure Overwrite_Indirect_Address_Slot
     (Into : in out Unit; Item : Item_Id; Value : Value_Id; Slot : Slot_Id) is
   begin
      Into.Code
        (Into.Items (Positive (Item)).Values.First + Positive (Value)).Slot :=
          Slot;
   end Overwrite_Indirect_Address_Slot;

   procedure Overwrite_Operand
     (Into : in out Unit; Item : Item_Id; Value : Value_Id;
      Index : Positive; Operand : Value_Id)
   is
      Code : constant Instruction := Into.Code
        (Into.Items (Positive (Item)).Values.First + Positive (Value));
   begin
      Into.Operands (Code.First_Arg + Index) := Operand;
   end Overwrite_Operand;

   procedure Overwrite_Value_Atoms
     (Into : in out Unit; Item : Item_Id; Value : Value_Id;
      Atoms : Atom_Set_Id)
   is
      Position : constant Positive :=
        Into.Items (Positive (Item)).Values.First + Positive (Value);
   begin
      Into.Code (Position).Atom_Set := Atoms;
   end Overwrite_Value_Atoms;

   procedure Overwrite_Value_Type
     (Into : in out Unit; Item : Item_Id; Value : Value_Id;
      Result : Landin.Types.Type_Kind)
   is
      Position : constant Positive :=
        Into.Items (Positive (Item)).Values.First + Positive (Value);
   begin
      Into.Code (Position).Result := Result;
   end Overwrite_Value_Type;

   procedure Overwrite_Pointee
     (Into : in out Unit; Pointee : Pointee_Id; Shape : Field_Shape) is
   begin
      Into.Pointees (Positive (Pointee)) := Shape;
   end Overwrite_Pointee;

   procedure Overwrite_Value_Pointee
     (Into : in out Unit; Item : Item_Id; Value : Value_Id;
      Pointee : Pointee_Id)
   is
      Position : constant Positive :=
        Into.Items (Positive (Item)).Values.First + Positive (Value);
   begin
      Into.Code (Position).Pointee := Pointee;
   end Overwrite_Value_Pointee;

end Landin.IR.Testing_Support;
