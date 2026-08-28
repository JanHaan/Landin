package body Landin.IR is

   ------------------------------------------------------------------
   --  Runs
   --
   --  Every per-item table is one run in one vector, so a reference is
   --  one addition.  These four helpers are the only place a run's
   --  arithmetic is written.
   ------------------------------------------------------------------

   function Element (Of_Unit : Unit; Item : Item_Id) return Item_Record
     is (Of_Unit.Items (Positive (Item)));

   function Slot_At
     (Of_Unit : Unit; Item : Item_Id; Slot : Slot_Id) return Positive
     is (Element (Of_Unit, Item).Slots.First + Positive (Slot));

   function Block_At
     (Of_Unit : Unit; Item : Item_Id; Block : Block_Id) return Positive
     is (Element (Of_Unit, Item).Blocks.First + Positive (Block));

   function Value_At
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id) return Positive
     is (Element (Of_Unit, Item).Values.First + Positive (Value));

   ------------------------------------------------------------------
   --  Building
   ------------------------------------------------------------------

   function Is_Prepared (Of_Unit : Unit) return Boolean
     is (Of_Unit.Ready);

   function Declaration_Limit (Of_Unit : Unit) return Natural
     is (Natural (Of_Unit.Standing.Length));

   function Item_Count (Of_Unit : Unit) return Natural
     is (Natural (Of_Unit.Items.Length));

   procedure Prepare
     (Into : in out Unit; Meanings : Landin.Resolution.Table) is
   begin
      --  One entry per declaration, so Item_For is an index rather than a
      --  scan, and No_Item means "no item stands for this declaration".
      for Unused in
        1 .. Landin.Resolution.Declaration_Count (Meanings)
      loop
         Into.Standing.Append (No_Item);
      end loop;

      Into.Ready := True;
   end Prepare;

   function Add_Item
     (Into     : in out Unit;
      Kind     : Item_Kind;
      Declares : Declaration_Id;
      Result   : Landin.Types.Type_Kind;
      Site     : Landin.Provenance.Origin) return Item_Id
   is
      Made : Item_Record;
   begin
      Made.Kind := Kind;
      Made.Declaration := Declares;
      Made.Result := Result;
      Made.Site := Site;
      --  A run's base is taken on its first append and not here.  [1740]
      --  makes a module a set, so `f` may call `g` written below it, and
      --  Emit_Call's `Holds (Into, Callee)` therefore forces a lowering to
      --  create every item before it fills any.  Taking the base here gave
      --  all of them the same one, and item two's slots then read back as
      --  item one's -- silently in a release build, where Add_Slot's
      --  postcondition is not there to catch it.
      Made.Slots      := Run'(First => 0, Count => 0);
      Made.Parameters := Run'(First => 0, Count => 0);
      Made.Blocks     := Run'(First => 0, Count => 0);
      Made.Values     := Run'(First => 0, Count => 0);
      Made.Fields     := Run'(First => 0, Count => 0);

      Into.Items.Append (Made);

      if Declares /= No_Declaration then
         Into.Standing (Positive (Declares)) :=
           Item_Id (Into.Items.Last_Index);
      end if;

      return Item_Id (Into.Items.Last_Index);
   end Add_Item;

   function Kind_Of (Of_Unit : Unit; Id : Item_Id) return Item_Kind
     is (Element (Of_Unit, Id).Kind);

   function Declares (Of_Unit : Unit; Id : Item_Id) return Declaration_Id
     is (Element (Of_Unit, Id).Declaration);

   function Result_Of (Of_Unit : Unit; Id : Item_Id)
     return Landin.Types.Type_Kind
     is (Element (Of_Unit, Id).Result);

   function Origin_Of (Of_Unit : Unit; Id : Item_Id)
     return Landin.Provenance.Origin
     is (Element (Of_Unit, Id).Site);

   function Item_For (Of_Unit : Unit; Declared : Declaration_Id)
     return Item_Id
     is (Of_Unit.Standing (Positive (Declared)));

   ------------------------------------------------------------------
   --  An aggregate item's fields
   ------------------------------------------------------------------

   function Field_Count (Of_Unit : Unit; Item : Item_Id) return Natural
     is (Element (Of_Unit, Item).Fields.Count);

   function Nth_Field
     (Of_Unit : Unit; Item : Item_Id; Index : Positive)
     return Landin.Types.Scalar_Name
     is (Nth_Field_Shape (Of_Unit, Item, Index).Element);

   function Nth_Field_Shape
     (Of_Unit : Unit; Item : Item_Id; Index : Positive)
      return Field_Shape
     is (Of_Unit.Fields
           (Element (Of_Unit, Item).Fields.First + Index));

   ------------------------------------------------------------------
   --  Slots
   ------------------------------------------------------------------

   function Slot_Count (Of_Unit : Unit; Item : Item_Id) return Natural
     is (Element (Of_Unit, Item).Slots.Count);

   --  Opens a run on its first append, and refuses one that is no longer
   --  at the end of its vector.  A Run is a base and a count, so an item's
   --  entities have to be contiguous; filling item one after starting item
   --  two would silently interleave two runs and leave both wrong.  The
   --  rule is the body's and holds in every mode, which is what
   --  Landin.Targets learnt when a release build accepted an alignment of
   --  twelve that only a precondition had refused.
   procedure Open_Run (Into : in out Run; Length : Natural);

   procedure Open_Run (Into : in out Run; Length : Natural) is
   begin
      if Into.Count = 0 then
         Into.First := Length;
      elsif Into.First + Into.Count /= Length then
         raise Landin.Compiler_Defect with
           "an item's run is no longer at the end of its vector, so two"
           & " items were filled at once";
      end if;
   end Open_Run;

   procedure Add_Field
     (Into    : in out Unit;
      Item    : Item_Id;
      Of_Type : Landin.Types.Scalar_Name)
   is
   begin
      Add_Field
        (Into, Item,
         (Kind => Scalar_Field_Shape, Element => Of_Type, Length => 1,
          others => <>));
   end Add_Field;

   procedure Add_Field
     (Into : in out Unit;
      Item : Item_Id;
      Shape : Field_Shape)
   is
      Held : Item_Record := Element (Into, Item);
   begin
      Open_Run (Held.Fields, Natural (Into.Fields.Length));
      Into.Fields.Append (Shape);
      Held.Fields.Count := Held.Fields.Count + 1;
      Into.Items (Positive (Item)) := Held;
   end Add_Field;

   procedure Add_Field
     (Into     : in out Unit;
      Item     : Item_Id;
      Shape    : Field_Shape;
      Cases    : Case_Run_Array;
      Payloads : Field_Shape_Array)
   is
      Stored : Field_Shape := Shape;
      Payload_Base : constant Natural :=
        Natural (Into.Variant_Fields.Length);
      Case_Base : constant Natural := Natural (Into.Variant_Cases.Length);
   begin
      for Payload of Payloads loop
         Into.Variant_Fields.Append (Payload);
      end loop;
      for Run of Cases loop
         Into.Variant_Cases.Append
           (Case_Run'
              (First =>
                 (if Run.Count = 0 then 0 else Payload_Base + Run.First),
               Count => Run.Count));
      end loop;
      Stored.Payloads_First := Case_Base + Shape.Payloads_First;
      Add_Field (Into, Item, Stored);
   end Add_Field;

   function Add_Slot
     (Into     : in out Unit;
      Item     : Item_Id;
      Of_Type  : Landin.Types.Scalar_Name;
      Declares : Declaration_Id;
      Site     : Landin.Provenance.Origin) return Slot_Id
   is
      Held : Item_Record := Element (Into, Item);
   begin
      Open_Run (Held.Slots, Natural (Into.Slots.Length));
      Into.Slots.Append
        (Slot_Record'(Of_Type     => Of_Type,
                      Declaration => Declares,
                      Site        => Site,
                      others      => <>));
      Held.Slots.Count := Held.Slots.Count + 1;
      Into.Items (Positive (Item)) := Held;
      return Slot_Id (Held.Slots.Count);
   end Add_Slot;

   function Add_Aggregate_Slot
     (Into     : in out Unit;
      Item     : Item_Id;
      Declares : Declaration_Id;
      Site     : Landin.Provenance.Origin) return Slot_Id
   is
      Held : Item_Record := Element (Into, Item);
   begin
      Open_Run (Held.Slots, Natural (Into.Slots.Length));
      Into.Slots.Append
        (Slot_Record'(Aggregate   => True,
                      Declaration => Declares,
                      Site        => Site,
                      others      => <>));
      Held.Slots.Count := Held.Slots.Count + 1;
      Into.Items (Positive (Item)) := Held;
      return Slot_Id (Held.Slots.Count);
   end Add_Aggregate_Slot;

   function Part_Count (Of_Unit : Unit; Item : Item_Id) return Element_Total
     is (if Result_Of (Of_Unit, Item) = Landin.Types.Fixed_Array
         then Array_Length (Of_Unit, Item)
         else Element_Total (Field_Count (Of_Unit, Item)));

   function Part_Is_Scalar
     (Of_Unit : Unit; Item : Item_Id; Index : Part_Position) return Boolean
     is (Result_Of (Of_Unit, Item) = Landin.Types.Fixed_Array
         or else Nth_Field_Shape
           (Of_Unit, Item, Positive (Index)).Kind = Scalar_Field_Shape);

   function Nth_Part
     (Of_Unit : Unit; Item : Item_Id; Index : Part_Position)
     return Landin.Types.Scalar_Name
     is (if Result_Of (Of_Unit, Item) = Landin.Types.Fixed_Array
         then Array_Element (Of_Unit, Item)
         else Nth_Field (Of_Unit, Item, Positive (Index)));

   procedure Set_Array
     (Into    : in out Unit;
      Item    : Item_Id;
      Of_Type : Landin.Types.Scalar_Name;
      Length  : Element_Total)
   is
      Held : Item_Record := Element (Into, Item);
   begin
      Held.Element := Of_Type;
      Held.Length := Length;
      Into.Items (Positive (Item)) := Held;
   end Set_Array;

   function Array_Element
     (Of_Unit : Unit; Item : Item_Id) return Landin.Types.Scalar_Name
     is (Element (Of_Unit, Item).Element);

   function Array_Length
     (Of_Unit : Unit; Item : Item_Id) return Element_Total
     is (Element (Of_Unit, Item).Length);

   function Field_Image_Element_Count
     (Fields : Aggregate_Field_Image_Array) return Element_Total
   is
      Result : Element_Total := 0;
   begin
      for Field of Fields loop
         if Field.Form in Finite | Hybrid then
            Result := Result + Element_Total (Field.Count);
         end if;
      end loop;
      return Result;
   end Field_Image_Element_Count;

   procedure Set_Aggregate_Image
     (Into   : in out Unit;
      Item   : Item_Id;
      Fields : Landin.Types.Folded_Array)
   is
      Arrays : constant Aggregate_Field_Image_Array (Fields'Range) :=
        [others => (others => <>)];
      Elements : constant Landin.Types.Folded_Array (1 .. 0) := [];
   begin
      Set_Aggregate_Image (Into, Item, Fields, Arrays, Elements);
   end Set_Aggregate_Image;

   procedure Set_Aggregate_Image
     (Into    : in out Unit;
      Item    : Item_Id;
      Fields  : Landin.Types.Folded_Array;
      Arrays  : Aggregate_Field_Image_Array;
      Elements : Landin.Types.Folded_Array)
   is
      Payloads : constant Aggregate_Field_Image_Array (1 .. 0) := [];
   begin
      Set_Aggregate_Image
        (Into, Item, Fields, Arrays, Payloads, Elements);
   end Set_Aggregate_Image;

   procedure Set_Aggregate_Image
     (Into     : in out Unit;
      Item     : Item_Id;
      Fields   : Landin.Types.Folded_Array;
      Images   : Aggregate_Field_Image_Array;
      Payloads : Aggregate_Field_Image_Array;
      Elements : Landin.Types.Folded_Array)
   is
      Held : Item_Record := Element (Into, Item);
   begin
      Open_Run (Held.Image, Natural (Into.Images.Length));
      for Field in Fields'Range loop
         Into.Images.Append (Fields (Field));
         Held.Image.Count := Held.Image.Count + 1;
      end loop;
      for Position in Elements'Range loop
         Into.Images.Append (Elements (Position));
         Held.Image.Count := Held.Image.Count + 1;
      end loop;

      Open_Run
        (Held.Aggregate_Images, Natural (Into.Aggregate_Images.Length));
      for Field in Images'Range loop
         Into.Aggregate_Images.Append (Images (Field));
         Held.Aggregate_Images.Count := Held.Aggregate_Images.Count + 1;
      end loop;
      for Payload in Payloads'Range loop
         Into.Aggregate_Images.Append (Payloads (Payload));
         Held.Aggregate_Images.Count := Held.Aggregate_Images.Count + 1;
      end loop;
      Held.Has_Image := True;
      Into.Items (Positive (Item)) := Held;
   end Set_Aggregate_Image;

   function Aggregate_Field_Image_Count
     (Of_Unit : Unit; Item : Item_Id) return Natural
     is (Element (Of_Unit, Item).Aggregate_Images.Count);

   function Field_Image_Of
     (Of_Unit : Unit; Item : Item_Id; Field : Positive)
      return Aggregate_Field_Image
     is (Of_Unit.Aggregate_Images
           (Element (Of_Unit, Item).Aggregate_Images.First + Field));

   function Nth_Field_Element
     (Of_Unit : Unit;
      Item    : Item_Id;
      Field   : Positive;
      Position : Part_Position) return Landin.Types.Folded
   is
      Image : constant Aggregate_Field_Image :=
        Field_Image_Of (Of_Unit, Item, Field);
   begin
      return Of_Unit.Images
        (Element (Of_Unit, Item).Image.First
         + Field_Count (Of_Unit, Item)
         + Image.Offset
         + Positive (Position));
   end Nth_Field_Element;

   function Variant_Payload_Image_Of
     (Of_Unit : Unit;
      Item    : Item_Id;
      Field   : Positive;
      Payload : Positive) return Aggregate_Field_Image
   is
      Image : constant Aggregate_Field_Image :=
        Field_Image_Of (Of_Unit, Item, Field);
   begin
      return Field_Image_Of
        (Of_Unit, Item,
         Field_Count (Of_Unit, Item) + Image.Offset + Payload);
   end Variant_Payload_Image_Of;

   function Nth_Variant_Field_Element
     (Of_Unit : Unit;
      Item    : Item_Id;
      Field   : Positive;
      Payload : Positive;
      Position : Part_Position) return Landin.Types.Folded
   is
      Image : constant Aggregate_Field_Image :=
        Variant_Payload_Image_Of (Of_Unit, Item, Field, Payload);
   begin
      return Of_Unit.Images
        (Element (Of_Unit, Item).Image.First
         + Field_Count (Of_Unit, Item)
         + Image.Offset
         + Positive (Position));
   end Nth_Variant_Field_Element;

   function Nth_Field_Image
     (Of_Unit : Unit; Item : Item_Id; Field : Positive)
      return Landin.Types.Folded
     is (Of_Unit.Images
           (Element (Of_Unit, Item).Image.First + Field));

   procedure Set_Array_Image
     (Into     : in out Unit;
      Item     : Item_Id;
      Elements : Landin.Types.Folded_Array)
   is
      Held : Item_Record := Element (Into, Item);
   begin
      Open_Run (Held.Image, Natural (Into.Images.Length));
      for Position in Elements'Range loop
         Into.Images.Append (Elements (Position));
         Held.Image.Count := Held.Image.Count + 1;
      end loop;
      Held.Has_Image := True;
      Into.Items (Positive (Item)) := Held;
   end Set_Array_Image;

   procedure Set_Repeated_Array_Image
     (Into  : in out Unit;
      Item  : Item_Id;
      Value : Landin.Types.Folded)
   is
      Held : Item_Record := Element (Into, Item);
   begin
      Open_Run (Held.Image, Natural (Into.Images.Length));
      Into.Images.Append (Value);
      Held.Image.Count := 1;
      Held.Has_Image := True;
      Held.Repeated_Image := True;
      Into.Items (Positive (Item)) := Held;
   end Set_Repeated_Array_Image;

   procedure Set_Hybrid_Array_Image
     (Into   : in out Unit;
      Item   : Item_Id;
      Prefix : Landin.Types.Folded_Array;
      Value  : Landin.Types.Folded)
   is
      Held : Item_Record := Element (Into, Item);
   begin
      Open_Run (Held.Image, Natural (Into.Images.Length));
      for Position in Prefix'Range loop
         Into.Images.Append (Prefix (Position));
         Held.Image.Count := Held.Image.Count + 1;
      end loop;
      Into.Images.Append (Value);
      Held.Image.Count := Held.Image.Count + 1;
      Held.Has_Image := True;
      Held.Repeated_Image := True;
      Into.Items (Positive (Item)) := Held;
   end Set_Hybrid_Array_Image;

   function Has_Image (Of_Unit : Unit; Item : Item_Id) return Boolean
     is (Element (Of_Unit, Item).Has_Image);

   function Is_Repeated_Image
     (Of_Unit : Unit; Item : Item_Id) return Boolean
     is (Element (Of_Unit, Item).Repeated_Image);

   function Image_Prefix_Length
     (Of_Unit : Unit; Item : Item_Id) return Element_Total
     is (Element_Total (Element (Of_Unit, Item).Image.Count - 1));

   function Repeated_Image_Value
     (Of_Unit : Unit; Item : Item_Id) return Landin.Types.Folded
     is (Of_Unit.Images
           (Element (Of_Unit, Item).Image.First
            + Element (Of_Unit, Item).Image.Count));

   function Image_Length
     (Of_Unit : Unit; Item : Item_Id) return Element_Total
     is (if Result_Of (Of_Unit, Item) = Landin.Types.Fixed_Array
              and then Is_Repeated_Image (Of_Unit, Item)
         then Array_Length (Of_Unit, Item)
         else Element_Total (Element (Of_Unit, Item).Image.Count));

   function Nth_Image
     (Of_Unit : Unit; Item : Item_Id; Index : Part_Position)
     return Landin.Types.Folded
     is (if Is_Repeated_Image (Of_Unit, Item)
              and then Element_Total (Index)
                       > Image_Prefix_Length (Of_Unit, Item)
         then Repeated_Image_Value (Of_Unit, Item)
         else Of_Unit.Images
                (Element (Of_Unit, Item).Image.First + Positive (Index)));

   function Is_Aggregate
     (Of_Unit : Unit; Item : Item_Id; Slot : Slot_Id) return Boolean
     is (Of_Unit.Slots (Slot_At (Of_Unit, Item, Slot)).Aggregate);

   function Add_Array_Slot
     (Into     : in out Unit;
      Item     : Item_Id;
      Of_Type  : Landin.Types.Scalar_Name;
      Length   : Element_Total;
      Declares : Declaration_Id;
      Site     : Landin.Provenance.Origin) return Slot_Id
   is
      Held : Item_Record := Element (Into, Item);
   begin
      Open_Run (Held.Slots, Natural (Into.Slots.Length));
      Into.Slots.Append
        (Slot_Record'(Array_Shape => True,
                      Element     => Of_Type,
                      Length      => Length,
                      Declaration => Declares,
                      Site        => Site,
                      others      => <>));
      Held.Slots.Count := Held.Slots.Count + 1;
      Into.Items (Positive (Item)) := Held;
      return Slot_Id (Held.Slots.Count);
   end Add_Array_Slot;

   function Is_Array
     (Of_Unit : Unit; Item : Item_Id; Slot : Slot_Id) return Boolean
     is (Of_Unit.Slots (Slot_At (Of_Unit, Item, Slot)).Array_Shape);

   function Slot_Array_Element
     (Of_Unit : Unit; Item : Item_Id; Slot : Slot_Id)
      return Landin.Types.Scalar_Name
     is (Of_Unit.Slots (Slot_At (Of_Unit, Item, Slot)).Element);

   function Slot_Array_Length
     (Of_Unit : Unit; Item : Item_Id; Slot : Slot_Id) return Element_Total
     is (Of_Unit.Slots (Slot_At (Of_Unit, Item, Slot)).Length);

   function Slot_Part_Count
     (Of_Unit : Unit; Item : Item_Id; Slot : Slot_Id) return Element_Total
     is (if Is_Array (Of_Unit, Item, Slot)
         then Slot_Array_Length (Of_Unit, Item, Slot)
         elsif Is_Aggregate (Of_Unit, Item, Slot)
         then Element_Total (Slot_Field_Count (Of_Unit, Item, Slot))
         else 0);

   function Slot_Part_Is_Scalar
     (Of_Unit : Unit; Item : Item_Id; Slot : Slot_Id;
      Index : Part_Position) return Boolean
     is (Is_Array (Of_Unit, Item, Slot)
         or else Nth_Slot_Field_Shape
           (Of_Unit, Item, Slot, Positive (Index)).Kind
                   = Scalar_Field_Shape);

   function Nth_Slot_Part
     (Of_Unit : Unit; Item : Item_Id; Slot : Slot_Id;
      Index : Part_Position) return Landin.Types.Scalar_Name
     is (if Is_Array (Of_Unit, Item, Slot)
         then Slot_Array_Element (Of_Unit, Item, Slot)
         else Nth_Slot_Field_Shape
           (Of_Unit, Item, Slot, Positive (Index)).Element);

   function Slot_Field_Count
     (Of_Unit : Unit; Item : Item_Id; Slot : Slot_Id) return Natural
     is (Of_Unit.Slots (Slot_At (Of_Unit, Item, Slot)).Fields.Count);

   procedure Add_Slot_Field
     (Into    : in out Unit;
      Item    : Item_Id;
      Slot    : Slot_Id;
      Of_Type : Landin.Types.Scalar_Name)
   is
   begin
      Add_Slot_Field
        (Into, Item, Slot,
         (Kind => Scalar_Field_Shape, Element => Of_Type, Length => 1,
          others => <>));
   end Add_Slot_Field;

   procedure Add_Slot_Field
     (Into : in out Unit;
      Item : Item_Id;
      Slot : Slot_Id;
      Shape : Field_Shape)
   is
      Where : constant Positive := Slot_At (Into, Item, Slot);
      Held  : Slot_Record := Into.Slots (Where);
   begin
      Open_Run (Held.Fields, Natural (Into.Slot_Fields.Length));
      Into.Slot_Fields.Append (Shape);
      Held.Fields.Count := Held.Fields.Count + 1;
      Into.Slots (Where) := Held;
   end Add_Slot_Field;

   procedure Add_Slot_Field
     (Into     : in out Unit;
      Item     : Item_Id;
      Slot     : Slot_Id;
      Shape    : Field_Shape;
      Cases    : Case_Run_Array;
      Payloads : Field_Shape_Array)
   is
      Stored : Field_Shape := Shape;
      Payload_Base : constant Natural :=
        Natural (Into.Variant_Fields.Length);
      Case_Base : constant Natural := Natural (Into.Variant_Cases.Length);
   begin
      for Payload of Payloads loop
         Into.Variant_Fields.Append (Payload);
      end loop;
      for Run of Cases loop
         Into.Variant_Cases.Append
           (Case_Run'
              (First =>
                 (if Run.Count = 0 then 0 else Payload_Base + Run.First),
               Count => Run.Count));
      end loop;
      Stored.Payloads_First := Case_Base + Shape.Payloads_First;
      Add_Slot_Field (Into, Item, Slot, Stored);
   end Add_Slot_Field;

   function Nth_Slot_Field_Shape
     (Of_Unit : Unit;
      Item    : Item_Id;
      Slot    : Slot_Id;
      Index   : Positive) return Field_Shape
     is (Of_Unit.Slot_Fields
           (Of_Unit.Slots (Slot_At (Of_Unit, Item, Slot)).Fields.First
            + Index));

   function Nth_Slot_Field
     (Of_Unit : Unit;
      Item    : Item_Id;
      Slot    : Slot_Id;
      Index   : Positive) return Landin.Types.Scalar_Name
     is (Nth_Slot_Field_Shape (Of_Unit, Item, Slot, Index).Element);

   function Add_Parameter
     (Into     : in out Unit;
      Item     : Item_Id;
      Of_Type  : Landin.Types.Scalar_Name;
      Declares : Declaration_Id;
      Site     : Landin.Provenance.Origin) return Slot_Id
   is
      Made : constant Slot_Id :=
        Add_Slot (Into, Item, Of_Type, Declares, Site);
      Held : Item_Record := Element (Into, Item);
   begin
      --  A parameter is a slot the caller filled, and the run below is
      --  the order [1920] names the parameters in.
      Open_Run (Held.Parameters, Natural (Into.Parameters.Length));
      Into.Parameters.Append (Made);
      Held.Parameters.Count := Held.Parameters.Count + 1;
      Into.Items (Positive (Item)) := Held;
      return Made;
   end Add_Parameter;

   function Parameter_Count (Of_Unit : Unit; Item : Item_Id) return Natural
     is (Element (Of_Unit, Item).Parameters.Count);

   function Nth_Parameter
     (Of_Unit : Unit; Item : Item_Id; Index : Positive) return Slot_Id
     is (Of_Unit.Parameters
           (Element (Of_Unit, Item).Parameters.First + Index));

   procedure Set_Result_Slot
     (Into : in out Unit; Item : Item_Id; Slot : Slot_Id)
   is
      Held : Item_Record := Element (Into, Item);
   begin
      Held.Returns_To := Slot;
      Into.Items (Positive (Item)) := Held;
   end Set_Result_Slot;

   function Result_Slot (Of_Unit : Unit; Item : Item_Id) return Slot_Id
     is (Element (Of_Unit, Item).Returns_To);

   function Type_Of (Of_Unit : Unit; Item : Item_Id; Slot : Slot_Id)
     return Landin.Types.Scalar_Name
     is (Of_Unit.Slots (Slot_At (Of_Unit, Item, Slot)).Of_Type);

   function Declares
     (Of_Unit : Unit; Item : Item_Id; Slot : Slot_Id)
     return Declaration_Id
     is (Of_Unit.Slots (Slot_At (Of_Unit, Item, Slot)).Declaration);

   function Origin_Of
     (Of_Unit : Unit; Item : Item_Id; Slot : Slot_Id)
     return Landin.Provenance.Origin
     is (Of_Unit.Slots (Slot_At (Of_Unit, Item, Slot)).Site);

   ------------------------------------------------------------------
   --  Blocks
   ------------------------------------------------------------------

   function Block_Count (Of_Unit : Unit; Item : Item_Id) return Natural
     is (Element (Of_Unit, Item).Blocks.Count);

   function Add_Block
     (Into  : in out Unit;
      Item  : Item_Id;
      Scope : Scope_Id;
      Site  : Landin.Provenance.Origin) return Block_Id
   is
      Held : Item_Record := Element (Into, Item);
   begin
      --  First_Value is Enter's and not this one's.  Landin.IR's header
      --  says blocks are created out of fill order -- "an `if`'s
      --  else-entry is created before the then-arm's inner blocks and
      --  filled after them" -- so a base taken at creation belongs to
      --  whichever block was filled first, and every later block reports
      --  that one's instructions.
      Open_Run (Held.Blocks, Natural (Into.Blocks.Length));
      Into.Blocks.Append
        (Block_Record'(Scope       => Scope,
                       Site        => Site,
                       First_Value => 0,
                       Values      => 0));
      Held.Blocks.Count := Held.Blocks.Count + 1;
      Into.Items (Positive (Item)) := Held;
      return Block_Id (Held.Blocks.Count);
   end Add_Block;

   procedure Enter
     (Into : in out Unit; Item : Item_Id; Block : Block_Id)
   is
      Held  : Item_Record := Element (Into, Item);
      Where : constant Positive := Block_At (Into, Item, Block);
      Ready : Block_Record := Into.Blocks (Where);
   begin
      --  The block is empty here -- Enter's precondition says so -- so
      --  there is no run to move, and this is the first moment at which
      --  where its instructions will land is known.
      Ready.First_Value := Natural (Into.Code.Length);
      Into.Blocks (Where) := Ready;

      Held.Open := Block;
      Into.Items (Positive (Item)) := Held;
   end Enter;

   procedure Leave_Block (Into : in out Unit; Item : Item_Id) is
      Held : Item_Record := Element (Into, Item);
   begin
      Held.Open := No_Block;
      Into.Items (Positive (Item)) := Held;
   end Leave_Block;

   function Open_Block (Of_Unit : Unit; Item : Item_Id) return Block_Id
     is (Element (Of_Unit, Item).Open);

   function Scope_Of
     (Of_Unit : Unit; Item : Item_Id; Block : Block_Id) return Scope_Id
     is (Of_Unit.Blocks (Block_At (Of_Unit, Item, Block)).Scope);

   function Origin_Of
     (Of_Unit : Unit; Item : Item_Id; Block : Block_Id)
     return Landin.Provenance.Origin
     is (Of_Unit.Blocks (Block_At (Of_Unit, Item, Block)).Site);

   function Length
     (Of_Unit : Unit; Item : Item_Id; Block : Block_Id) return Natural
     is (Of_Unit.Blocks (Block_At (Of_Unit, Item, Block)).Values);

   function Nth_Value
     (Of_Unit : Unit;
      Item    : Item_Id;
      Block   : Block_Id;
      Index   : Positive) return Value_Id
     is (Value_Id
           (Of_Unit.Blocks
              (Block_At (Of_Unit, Item, Block)).First_Value
            - Element (Of_Unit, Item).Values.First
            + Index));

   ------------------------------------------------------------------
   --  Instructions
   ------------------------------------------------------------------

   function Value_Count (Of_Unit : Unit; Item : Item_Id) return Natural
     is (Element (Of_Unit, Item).Values.Count);

   function Held (Of_Unit : Unit; Item : Item_Id; Value : Value_Id)
     return Instruction
     is (Of_Unit.Code (Value_At (Of_Unit, Item, Value)));

   function Op_Of (Of_Unit : Unit; Item : Item_Id; Value : Value_Id)
     return Opcode
     is (Held (Of_Unit, Item, Value).Op);

   function Result_Of (Of_Unit : Unit; Item : Item_Id; Value : Value_Id)
     return Landin.Types.Type_Kind
     is (Held (Of_Unit, Item, Value).Result);

   function Origin_Of (Of_Unit : Unit; Item : Item_Id; Value : Value_Id)
     return Landin.Provenance.Origin
     is (Held (Of_Unit, Item, Value).Site);

   function Block_Of (Of_Unit : Unit; Item : Item_Id; Value : Value_Id)
     return Block_Id
     is (Held (Of_Unit, Item, Value).In_Block);

   function Operand_Count
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id) return Natural
     is (Held (Of_Unit, Item, Value).Args);

   function Nth_Operand
     (Of_Unit : Unit;
      Item    : Item_Id;
      Value   : Value_Id;
      Index   : Positive) return Value_Id
     is (Of_Unit.Operands
           (Held (Of_Unit, Item, Value).First_Arg + Index));

   function Slot_Of (Of_Unit : Unit; Item : Item_Id; Value : Value_Id)
     return Slot_Id
     is (Held (Of_Unit, Item, Value).Slot);

   function Datum_Of (Of_Unit : Unit; Item : Item_Id; Value : Value_Id)
     return Item_Id
     is (Held (Of_Unit, Item, Value).Named);

   function Field_Of (Of_Unit : Unit; Item : Item_Id; Value : Value_Id)
     return Part_Position
     is (Held (Of_Unit, Item, Value).Part);

   function Element_Field_Of
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id) return Natural
     is (Held (Of_Unit, Item, Value).Element_Field);

   function First_Part_Of
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id)
      return Part_Position
     is (Held (Of_Unit, Item, Value).Part);

   function Reaches_A_Slot
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id) return Boolean
     is (Held (Of_Unit, Item, Value).Slot /= No_Slot);

   function Source_Of
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id) return Storage
     is (Held (Of_Unit, Item, Value).Source);

   function Source_Field_Of
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id) return Natural
     is (Held (Of_Unit, Item, Value).Source_Field);

   function Destination_Of
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id) return Storage
     is (Held (Of_Unit, Item, Value).Destination);

   function Variant_Case_Of
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id) return Natural
     is (Held (Of_Unit, Item, Value).Variant_Case);

   function Variant_Payload_Field_Of
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id) return Natural
     is (Held (Of_Unit, Item, Value).Variant_Payload_Field);

   function Callee_Of (Of_Unit : Unit; Item : Item_Id; Value : Value_Id)
     return Item_Id
     is (Held (Of_Unit, Item, Value).Named);

   function Target_Of (Of_Unit : Unit; Item : Item_Id; Value : Value_Id)
     return Block_Id
     is (Held (Of_Unit, Item, Value).Target);

   function Alternative_Of
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id) return Block_Id
     is (Held (Of_Unit, Item, Value).Alternative);

   function Measured_Of
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id)
     return Landin.Types.Scalar_Name
     is (Held (Of_Unit, Item, Value).Measured);

   function Is_Aggregate_Measurement
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id) return Boolean
     is (Held (Of_Unit, Item, Value).Aggregate_Measurement);

   function Measurement_Field_Count
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id) return Natural
     is (Held (Of_Unit, Item, Value).Measurement_Field_Total);

   function Nth_Measurement_Field
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id; Field : Positive)
      return Field_Shape
   is
      First : constant Natural :=
        Held (Of_Unit, Item, Value).First_Measurement_Field;
   begin
      return Of_Unit.Measurement_Fields (First + Field);
   end Nth_Measurement_Field;

   function Variant_Case_Run_Count (Of_Unit : Unit) return Natural
     is (Natural (Of_Unit.Variant_Cases.Length));

   function Variant_Field_Shape_Count (Of_Unit : Unit) return Natural
     is (Natural (Of_Unit.Variant_Fields.Length));

   function Variant_Case_Run_Is_Valid
     (Of_Unit : Unit; Shape : Field_Shape; Which : Positive)
      return Boolean
   is
      Run : constant Case_Run := Of_Unit.Variant_Cases
        (Shape.Payloads_First + Which - 1);
   begin
      return (if Run.Count = 0
              then Run.First = 0
              else Run.First > 0
                   and then Run.First
                              <= Variant_Field_Shape_Count (Of_Unit)
                   and then Run.Count
                              <= Variant_Field_Shape_Count (Of_Unit)
                                   - Run.First + 1);
   end Variant_Case_Run_Is_Valid;

   function Variant_Case_Field_Count
     (Of_Unit : Unit; Shape : Field_Shape; Which : Positive)
      return Natural
     is (Of_Unit.Variant_Cases
           (Shape.Payloads_First + Which - 1).Count);

   function Nth_Variant_Case_Field
     (Of_Unit : Unit;
      Shape   : Field_Shape;
      Which   : Positive;
      Field   : Positive) return Field_Shape
   is
      Run : constant Case_Run := Of_Unit.Variant_Cases
        (Shape.Payloads_First + Which - 1);
   begin
      return Of_Unit.Variant_Fields (Run.First + Field - 1);
   end Nth_Variant_Case_Field;

   function Number_Of
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id)
     return Landin.Types.Magnitude
     is (Held (Of_Unit, Item, Value).Number);

   function Is_Negated
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id) return Boolean
     is (Held (Of_Unit, Item, Value).Negated);

   function Truth_Of
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id) return Boolean
     is (Held (Of_Unit, Item, Value).Truth);

   ------------------------------------------------------------------
   --  Emitting
   --
   --  Every Emit goes through Append, which is the only place an
   --  instruction is put in the table and the only place a block's count
   --  and an item's count move together.
   ------------------------------------------------------------------

   function Append
     (Into : in out Unit; Item : Item_Id; What : Instruction)
     return Value_Id;

   function Append
     (Into : in out Unit; Item : Item_Id; What : Instruction)
     return Value_Id
   is
      Held  : Item_Record := Element (Into, Item);
      Where : constant Positive :=
        Block_At (Into, Item, Held.Open);
      Block : Block_Record := Into.Blocks (Where);
      Made  : Instruction := What;
   begin
      Made.In_Block := Held.Open;
      Open_Run (Held.Values, Natural (Into.Code.Length));
      Into.Code.Append (Made);

      Held.Values.Count := Held.Values.Count + 1;
      Block.Values := Block.Values + 1;

      Into.Items (Positive (Item)) := Held;
      Into.Blocks (Where) := Block;

      return Value_Id (Held.Values.Count);
   end Append;

   function Emit_Number
     (Into    : in out Unit;
      Item    : Item_Id;
      Of_Type : Landin.Types.Integer_Name;
      Value   : Landin.Types.Magnitude;
      Negated : Boolean;
      Site    : Landin.Provenance.Origin) return Value_Id
     is (Append
           (Into, Item,
            Instruction'(Op      => Number,
                         Result  => Of_Type,
                         Site    => Site,
                         Number  => Value,
                         Negated => Negated,
                         others  => <>)));

   function Emit_Measurement
     (Into     : in out Unit;
      Item     : Item_Id;
      Of_Code  : Opcode;
      Measured : Landin.Types.Scalar_Name;
      Gives    : Landin.Types.Scalar_Name;
      Site     : Landin.Provenance.Origin) return Value_Id
     is (Append
           (Into, Item,
            Instruction'(Op       => Of_Code,
                         Result   => Gives,
                         Site     => Site,
                         Measured => Measured,
                         others   => <>)));

   function Emit_Aggregate_Measurement
     (Into    : in out Unit;
      Item    : Item_Id;
      Of_Code : Opcode;
      Fields  : Field_Shape_Array;
      Gives   : Landin.Types.Scalar_Name;
      Site    : Landin.Provenance.Origin;
      Cases   : Case_Run_Array := No_Case_Runs;
      Payloads : Field_Shape_Array := No_Field_Shapes) return Value_Id
   is
      Payload_Base : constant Natural :=
        Natural (Into.Variant_Fields.Length);
      Case_Base : constant Natural :=
        Natural (Into.Variant_Cases.Length);
   begin
      for Payload of Payloads loop
         Into.Variant_Fields.Append (Payload);
      end loop;

      for Run of Cases loop
         Into.Variant_Cases.Append
           (Case_Run'
              (First =>
                 (if Run.Count = 0 then 0 else Payload_Base + Run.First),
               Count => Run.Count));
      end loop;

      declare
         First : constant Natural :=
           Natural (Into.Measurement_Fields.Length);
      begin
         for Field of Fields loop
            declare
               Stored : Field_Shape := Field;
            begin
               if Stored.Kind = Variant_Field_Shape then
                  Stored.Payloads_First :=
                    Case_Base + Stored.Payloads_First;
               end if;
               Into.Measurement_Fields.Append (Stored);
            end;
         end loop;

         return Append
           (Into, Item,
            Instruction'(Op                      => Of_Code,
                         Result                  => Gives,
                         Site                    => Site,
                         First_Measurement_Field => First,
                         Measurement_Field_Total => Fields'Length,
                         Aggregate_Measurement   => True,
                         others                  => <>));
      end;
   end Emit_Aggregate_Measurement;

   function Emit_Truth
     (Into  : in out Unit;
      Item  : Item_Id;
      Value : Boolean;
      Site  : Landin.Provenance.Origin) return Value_Id
     is (Append
           (Into, Item,
            Instruction'(Op     => Truth,
                         Result => Landin.Types.Bool,
                         Site   => Site,
                         Truth  => Value,
                         others => <>)));

   function Emit_Load
     (Into : in out Unit;
      Item : Item_Id;
      Slot : Slot_Id;
      Site : Landin.Provenance.Origin) return Value_Id
     is (Append
           (Into, Item,
            Instruction'(Op     => Load,
                         Result => Type_Of (Into, Item, Slot),
                         Site   => Site,
                         Slot   => Slot,
                         others => <>)));

   procedure Emit_Store
     (Into  : in out Unit;
      Item  : Item_Id;
      Slot  : Slot_Id;
      Value : Value_Id;
      Site  : Landin.Provenance.Origin)
   is
      Made : Instruction :=
        Instruction'(Op     => Store,
                     Site   => Site,
                     Slot   => Slot,
                     others => <>);
      Where : Value_Id;
   begin
      Made.First_Arg := Natural (Into.Operands.Length);
      Made.Args := 1;
      Into.Operands.Append (Value);
      Where := Append (Into, Item, Made);
      pragma Assert (Where /= No_Value);
   end Emit_Store;

   function Emit_Load_Datum
     (Into  : in out Unit;
      Item  : Item_Id;
      Datum : Item_Id;
      Site  : Landin.Provenance.Origin) return Value_Id
     is (Append
           (Into, Item,
            Instruction'(Op     => Load_Datum,
                         Result => Result_Of (Into, Datum),
                         Site   => Site,
                         Named  => Datum,
                         others => <>)));

   function Emit_Load_Field
     (Into   : in out Unit;
      Item   : Item_Id;
      Datum  : Item_Id;
      Field  : Part_Position;
      Result : Landin.Types.Scalar_Name;
      Site   : Landin.Provenance.Origin) return Value_Id
     is (Append
           (Into, Item,
            Instruction'(Op     => Load_Field,
                         Result => Result,
                         Site   => Site,
                         Named  => Datum,
                         Part   => Field,
                         others => <>)));

   function Emit_Load_Slot_Field
     (Into   : in out Unit;
      Item   : Item_Id;
      Slot   : Slot_Id;
      Field  : Part_Position;
      Result : Landin.Types.Scalar_Name;
      Site   : Landin.Provenance.Origin) return Value_Id
     is (Append
           (Into, Item,
            Instruction'(Op     => Load_Field,
                         Result => Result,
                         Site   => Site,
                         Slot   => Slot,
                         Part   => Field,
                         others => <>)));

   procedure Emit_Store_Slot_Field
     (Into  : in out Unit;
      Item  : Item_Id;
      Slot  : Slot_Id;
      Field : Part_Position;
      Value : Value_Id;
      Site  : Landin.Provenance.Origin)
   is
      Made : Instruction :=
        Instruction'(Op     => Store_Field,
                     Site   => Site,
                     Slot   => Slot,
                     Part   => Field,
                     others => <>);
      Where : Value_Id;
   begin
      Made.First_Arg := Natural (Into.Operands.Length);
      Made.Args := 1;
      Into.Operands.Append (Value);
      Where := Append (Into, Item, Made);
      pragma Assert (Where /= No_Value);
   end Emit_Store_Slot_Field;

   procedure Emit_Store_Field
     (Into  : in out Unit;
      Item  : Item_Id;
      Datum : Item_Id;
      Field : Part_Position;
      Value : Value_Id;
      Site  : Landin.Provenance.Origin)
   is
      Made : Instruction :=
        Instruction'(Op     => Store_Field,
                     Site   => Site,
                     Named  => Datum,
                     Part   => Field,
                     others => <>);
      Where : Value_Id;
   begin
      Made.First_Arg := Natural (Into.Operands.Length);
      Made.Args := 1;
      Into.Operands.Append (Value);
      Where := Append (Into, Item, Made);
      pragma Assert (Where /= No_Value);
   end Emit_Store_Field;

   function Emit_Load_Element
     (Into   : in out Unit;
      Item   : Item_Id;
      Datum  : Item_Id;
      Index  : Value_Id;
      Result : Landin.Types.Scalar_Name;
      Site   : Landin.Provenance.Origin;
      Field  : Natural := 0;
      Variant_Case : Natural := 0;
      Variant_Payload_Field : Natural := 0) return Value_Id
   is
      Made : Instruction :=
        Instruction'(Op     => Load_Element,
                     Result => Result,
                     Site   => Site,
                     Named  => Datum,
                     Element_Field => Field,
                     Variant_Case => Variant_Case,
                     Variant_Payload_Field => Variant_Payload_Field,
                     others => <>);
   begin
      Made.First_Arg := Natural (Into.Operands.Length);
      Made.Args := 1;
      Into.Operands.Append (Index);
      return Append (Into, Item, Made);
   end Emit_Load_Element;

   procedure Emit_Store_Element
     (Into  : in out Unit;
      Item  : Item_Id;
      Datum : Item_Id;
      Index : Value_Id;
      Value : Value_Id;
      Site  : Landin.Provenance.Origin;
      Field : Natural := 0;
      Variant_Case : Natural := 0;
      Variant_Payload_Field : Natural := 0)
   is
      Made : Instruction :=
        Instruction'(Op     => Store_Element,
                     Site   => Site,
                     Named  => Datum,
                     Element_Field => Field,
                     Variant_Case => Variant_Case,
                     Variant_Payload_Field => Variant_Payload_Field,
                     others => <>);
      Where : Value_Id;
   begin
      Made.First_Arg := Natural (Into.Operands.Length);
      Made.Args := 2;
      Into.Operands.Append (Index);
      Into.Operands.Append (Value);
      Where := Append (Into, Item, Made);
      pragma Assert (Where /= No_Value);
   end Emit_Store_Element;

   function Emit_Load_Slot_Element
     (Into   : in out Unit;
      Item   : Item_Id;
      Slot   : Slot_Id;
      Index  : Value_Id;
      Result : Landin.Types.Scalar_Name;
      Site   : Landin.Provenance.Origin;
      Field  : Natural := 0;
      Variant_Case : Natural := 0;
      Variant_Payload_Field : Natural := 0) return Value_Id
   is
      Made : Instruction :=
        Instruction'(Op     => Load_Element,
                     Result => Result,
                     Site   => Site,
                     Slot   => Slot,
                     Element_Field => Field,
                     Variant_Case => Variant_Case,
                     Variant_Payload_Field => Variant_Payload_Field,
                     others => <>);
   begin
      Made.First_Arg := Natural (Into.Operands.Length);
      Made.Args := 1;
      Into.Operands.Append (Index);
      return Append (Into, Item, Made);
   end Emit_Load_Slot_Element;

   procedure Emit_Store_Slot_Element
     (Into  : in out Unit;
      Item  : Item_Id;
      Slot  : Slot_Id;
      Index : Value_Id;
      Value : Value_Id;
      Site  : Landin.Provenance.Origin;
      Field : Natural := 0;
      Variant_Case : Natural := 0;
      Variant_Payload_Field : Natural := 0)
   is
      Made : Instruction :=
        Instruction'(Op     => Store_Element,
                     Site   => Site,
                     Slot   => Slot,
                     Element_Field => Field,
                     Variant_Case => Variant_Case,
                     Variant_Payload_Field => Variant_Payload_Field,
                     others => <>);
      Where : Value_Id;
   begin
      Made.First_Arg := Natural (Into.Operands.Length);
      Made.Args := 2;
      Into.Operands.Append (Index);
      Into.Operands.Append (Value);
      Where := Append (Into, Item, Made);
      pragma Assert (Where /= No_Value);
   end Emit_Store_Slot_Element;

   function Slot_Element_Length
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id) return Element_Total
     is (if Element_Field_Of (Of_Unit, Item, Value) = 0
         then Slot_Array_Length
                (Of_Unit, Item, Held (Of_Unit, Item, Value).Slot)
         else Nth_Slot_Field_Shape
                (Of_Unit, Item, Held (Of_Unit, Item, Value).Slot,
                 Positive (Element_Field_Of (Of_Unit, Item, Value))).Length);

   function Slot_Element_Type
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id)
     return Landin.Types.Scalar_Name
     is (if Element_Field_Of (Of_Unit, Item, Value) = 0
         then Slot_Array_Element
                (Of_Unit, Item, Held (Of_Unit, Item, Value).Slot)
         else Nth_Slot_Field_Shape
                (Of_Unit, Item, Held (Of_Unit, Item, Value).Slot,
                 Positive (Element_Field_Of (Of_Unit, Item, Value))).Element);

   procedure Emit_Array_Copy
     (Into        : in out Unit;
      Item        : Item_Id;
      Source      : Storage;
      Destination : Storage;
      Site        : Landin.Provenance.Origin;
      Source_Field : Natural := 0;
      Destination_Field : Natural := 0;
      Destination_Variant_Case : Natural := 0;
      Destination_Variant_Payload_Field : Natural := 0)
   is
      Where : constant Value_Id :=
        Append
          (Into, Item,
           Instruction'(Op          => Copy_Array,
                        Site        => Site,
                        Source      => Source,
                        Source_Field => Source_Field,
                        Destination => Destination,
                        Element_Field => Destination_Field,
                        Variant_Case => Destination_Variant_Case,
                        Variant_Payload_Field =>
                          Destination_Variant_Payload_Field,
                        others      => <>));
   begin
      pragma Assert (Where /= No_Value);
   end Emit_Array_Copy;

   procedure Emit_Variant_Copy
     (Into        : in out Unit;
      Item        : Item_Id;
      Source      : Storage;
      Destination : Storage;
      Field       : Positive;
      Site        : Landin.Provenance.Origin)
   is
      Where : constant Value_Id :=
        Append
          (Into, Item,
           Instruction'(Op            => Copy_Variant,
                        Site          => Site,
                        Source        => Source,
                        Source_Field  => Field,
                        Destination   => Destination,
                        Element_Field => Field,
                        others        => <>));
   begin
      pragma Assert (Where /= No_Value);
   end Emit_Variant_Copy;

   procedure Emit_Array_Clear
     (Into        : in out Unit;
      Item        : Item_Id;
      Destination : Storage;
      Site        : Landin.Provenance.Origin;
      Field       : Natural := 0)
   is
      Where : constant Value_Id :=
        Append
          (Into, Item,
           Instruction'(Op          => Clear_Array,
                        Site        => Site,
                        Destination => Destination,
                        Element_Field => Field,
                        others      => <>));
   begin
      pragma Assert (Where /= No_Value);
   end Emit_Array_Clear;

   procedure Emit_Array_Fill
     (Into        : in out Unit;
      Item        : Item_Id;
      Destination : Storage;
      First       : Part_Position;
      Value       : Value_Id;
      Site        : Landin.Provenance.Origin;
      Field       : Natural := 0;
      Variant_Case : Natural := 0;
      Variant_Payload_Field : Natural := 0)
   is
      Made : Instruction :=
        Instruction'(Op          => Fill_Array,
                     Site        => Site,
                     Destination => Destination,
                     Part        => First,
                     Element_Field => Field,
                     Variant_Case => Variant_Case,
                     Variant_Payload_Field => Variant_Payload_Field,
                     others      => <>);
      Where : Value_Id;
   begin
      Made.First_Arg := Natural (Into.Operands.Length);
      Made.Args := 1;
      Into.Operands.Append (Value);
      Where := Append (Into, Item, Made);
      pragma Assert (Where /= No_Value);
   end Emit_Array_Fill;

   procedure Emit_Variant_Select
     (Into        : in out Unit;
      Item        : Item_Id;
      Destination : Storage;
      Field       : Positive;
      Which       : Positive;
      Site        : Landin.Provenance.Origin)
   is
      Where : constant Value_Id :=
        Append
          (Into, Item,
           Instruction'(Op            => Select_Variant,
                        Site          => Site,
                        Destination   => Destination,
                        Element_Field => Field,
                        Variant_Case  => Which,
                        others        => <>));
   begin
      pragma Assert (Where /= No_Value);
   end Emit_Variant_Select;

   function Emit_Variant_Tag_Load
     (Into   : in out Unit;
      Item   : Item_Id;
      Source : Storage;
      Field  : Positive;
      Result : Landin.Types.Scalar_Name;
      Site   : Landin.Provenance.Origin) return Value_Id
   is
   begin
      return Append
        (Into, Item,
         Instruction'(Op            => Load_Variant_Tag,
                      Result        => Result,
                      Site          => Site,
                      Source        => Source,
                      Element_Field => Field,
                      others        => <>));
   end Emit_Variant_Tag_Load;

   function Emit_Variant_Field_Load
     (Into          : in out Unit;
      Item          : Item_Id;
      Source        : Storage;
      Field         : Positive;
      Which         : Positive;
      Payload_Field : Positive;
      Result        : Landin.Types.Scalar_Name;
      Site          : Landin.Provenance.Origin) return Value_Id
   is
   begin
      return Append
        (Into, Item,
         Instruction'(Op                    => Load_Variant_Field,
                      Result                => Result,
                      Site                  => Site,
                      Source                => Source,
                      Element_Field         => Field,
                      Variant_Case          => Which,
                      Variant_Payload_Field => Payload_Field,
                      others                => <>));
   end Emit_Variant_Field_Load;

   procedure Emit_Variant_Field_Store
     (Into          : in out Unit;
      Item          : Item_Id;
      Destination   : Storage;
      Field         : Positive;
      Which         : Positive;
      Payload_Field : Positive;
      Value         : Value_Id;
      Site          : Landin.Provenance.Origin)
   is
      Made : Instruction :=
        Instruction'(Op                    => Store_Variant_Field,
                     Site                  => Site,
                     Destination           => Destination,
                     Element_Field         => Field,
                     Variant_Case          => Which,
                     Variant_Payload_Field => Payload_Field,
                     others                => <>);
      Where : Value_Id;
   begin
      Made.First_Arg := Natural (Into.Operands.Length);
      Made.Args := 1;
      Into.Operands.Append (Value);
      Where := Append (Into, Item, Made);
      pragma Assert (Where /= No_Value);
   end Emit_Variant_Field_Store;

   procedure Emit_Store_Datum
     (Into  : in out Unit;
      Item  : Item_Id;
      Datum : Item_Id;
      Value : Value_Id;
      Site  : Landin.Provenance.Origin)
   is
      Made : Instruction :=
        Instruction'(Op     => Store_Datum,
                     Site   => Site,
                     Named  => Datum,
                     others => <>);
      Where : Value_Id;
   begin
      Made.First_Arg := Natural (Into.Operands.Length);
      Made.Args := 1;
      Into.Operands.Append (Value);
      Where := Append (Into, Item, Made);
      pragma Assert (Where /= No_Value);
   end Emit_Store_Datum;

   function Emit_Unary
     (Into    : in out Unit;
      Item    : Item_Id;
      Op      : Unary_Kind;
      Operand : Value_Id;
      Result  : Landin.Types.Scalar_Name;
      Site    : Landin.Provenance.Origin) return Value_Id
   is
      Made : Instruction :=
        Instruction'(Op     => Op,
                     Result => Result,
                     Site   => Site,
                     others => <>);
   begin
      Made.First_Arg := Natural (Into.Operands.Length);
      Made.Args := 1;
      Into.Operands.Append (Operand);
      return Append (Into, Item, Made);
   end Emit_Unary;

   function Emit_Binary
     (Into   : in out Unit;
      Item   : Item_Id;
      Op     : Binary_Kind;
      Left   : Value_Id;
      Right  : Value_Id;
      Result : Landin.Types.Scalar_Name;
      Site   : Landin.Provenance.Origin) return Value_Id
   is
      Made : Instruction :=
        Instruction'(Op     => Op,
                     Result => Result,
                     Site   => Site,
                     others => <>);
   begin
      Made.First_Arg := Natural (Into.Operands.Length);
      Made.Args := 2;
      Into.Operands.Append (Left);
      Into.Operands.Append (Right);
      return Append (Into, Item, Made);
   end Emit_Binary;

   function Emit_Call
     (Into   : in out Unit;
      Item   : Item_Id;
      Callee : Item_Id;
      Result : Landin.Types.Type_Kind;
      Site   : Landin.Provenance.Origin) return Value_Id
     is (Append
           (Into, Item,
            Instruction'(Op        => Call,
                         Result    => Result,
                         Site      => Site,
                         Named     => Callee,
                         First_Arg => 0,
                         Args      => 0,
                         others    => <>)));

   procedure Add_Argument
     (Into  : in out Unit;
      Item  : Item_Id;
      Call  : Value_Id;
      Value : Value_Id)
   is
      Where : constant Positive := Value_At (Into, Item, Call);
      What  : Instruction := Into.Code (Where);
      Their : Run := Run'(First => What.First_Arg, Count => What.Args);
   begin
      --  The fifth vector, and the one Open_Run did not reach when it was
      --  written.  Every other instruction records its operands in the
      --  same call that creates them, so no two of those runs can
      --  interleave; a call's arguments arrive afterwards, and nothing
      --  stops another item being filled in between -- Enter asks only
      --  that *this* item has no open block, not that no other item does.
      --  Measured before this line existed: a call was given one value
      --  and read back another item's, in debug and in release, with
      --  every precondition satisfied.
      Open_Run (Their, Natural (Into.Operands.Length));
      Into.Operands.Append (Value);

      What.First_Arg := Their.First;
      What.Args      := Their.Count + 1;
      Into.Code (Where) := What;
   end Add_Argument;

   procedure Emit_Jump
     (Into   : in out Unit;
      Item   : Item_Id;
      Target : Block_Id;
      Site   : Landin.Provenance.Origin)
   is
      Where : constant Value_Id :=
        Append (Into, Item,
                Instruction'(Op     => Jump,
                             Site   => Site,
                             Target => Target,
                             others => <>));
   begin
      pragma Assert (Where /= No_Value);
   end Emit_Jump;

   procedure Emit_Branch
     (Into        : in out Unit;
      Item        : Item_Id;
      Condition   : Value_Id;
      Target      : Block_Id;
      Alternative : Block_Id;
      Site        : Landin.Provenance.Origin)
   is
      Made : Instruction :=
        Instruction'(Op          => Branch,
                     Site        => Site,
                     Target      => Target,
                     Alternative => Alternative,
                     others      => <>);
      Where : Value_Id;
   begin
      Made.First_Arg := Natural (Into.Operands.Length);
      Made.Args := 1;
      Into.Operands.Append (Condition);
      Where := Append (Into, Item, Made);
      pragma Assert (Where /= No_Value);
   end Emit_Branch;

   procedure Emit_Leave
     (Into  : in out Unit;
      Item  : Item_Id;
      Value : Value_Id;
      Site  : Landin.Provenance.Origin)
   is
      Made : Instruction :=
        Instruction'(Op     => Leave,
                     Site   => Site,
                     others => <>);
      Where : Value_Id;
   begin
      Made.First_Arg := Natural (Into.Operands.Length);

      if Value /= No_Value then
         Made.Args := 1;
         Into.Operands.Append (Value);
      end if;

      Where := Append (Into, Item, Made);
      pragma Assert (Where /= No_Value);
   end Emit_Leave;

end Landin.IR;
