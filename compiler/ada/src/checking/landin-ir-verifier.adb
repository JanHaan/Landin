with Landin.Types;

package body Landin.IR.Verifier is

   use type Landin.Types.Folded;

   function Describe (Of_Kind : Fault_Kind) return String
     is (case Of_Kind is
            when Nothing_Wrong        => "nothing wrong",
            when Unprepared_Unit      =>
               "the unit was never prepared",
            when Item_Runs_Overlap    =>
               "an item's slots, blocks or instructions are not where its"
               & " run says they are",
            when Operand_Runs_Overlap =>
               "a call's operands are not where its run says they are",
            when Item_Without_A_Block =>
               "an item has no block, so it describes nothing",
            when Item_Still_Building  =>
               "an item was left with a block still open",
            when Empty_Block          =>
               "a block holds no instruction at all",
            when Block_Without_A_Terminator =>
               "a block does not end with a terminator",
            when Terminator_Inside_A_Block  =>
               "a terminator is not the last instruction of its block",
            when Block_Unreachable    =>
               "a block after the first that nothing reaches",
            when Target_Out_Of_Range  =>
               "a jump or a branch names a block the item does not have",
            when Wrong_Operand_Count  =>
               "an instruction carries the wrong number of operands",
            when Operand_Out_Of_Range =>
               "an operand names a value the item does not have",
            when Operand_In_Another_Block =>
               "an operand names a value defined in another block",
            when Operand_Not_Above_Its_Use =>
               "an operand names a value not defined above its use",
            when Operand_Defines_Nothing   =>
               "an operand names an instruction that defines no value",
            when Operands_Disagree    =>
               "two operands of one operator do not have one type",
            when Result_Disagrees     =>
               "an instruction's result is not the type its operands give",
            when Field_Shape_Malformed =>
               "an aggregate's scalar field has a length other than one",
            when Condition_Is_Not_A_Bool =>
               "a branch's condition is not a bool",
            when Slot_Out_Of_Range    =>
               "a load or a store names a slot the item does not have",
            when Store_Disagrees_With_Slot =>
               "a store writes a value the slot's type does not hold",
            when Store_To_A_Parameter =>
               "a store writes a parameter, which [1900] does not permit",
            when Named_Item_Is_Not_A_Datum =>
               "a datum load or store names an item that is a routine",
            when Store_Datum_Disagrees =>
               "a datum store writes a value the datum's type does not"
               & " hold",
            when Aggregate_Datum_Is_Not_A_Value =>
               "a datum load or store names an aggregate, which is"
               & " storage and not a value yet",
            when Field_Out_Of_Range =>
               "a field load names a field the aggregate does not have",
            when Field_Is_Not_A_Scalar =>
               "a scalar field operation names a fixed-array field",
            when Element_Datum_Is_Not_An_Array =>
               "an element load or store names a datum that is not an array",
            when Element_Field_Out_Of_Range =>
               "an element load or store names a field the aggregate does"
               & " not have",
            when Element_Field_Is_Not_An_Array =>
               "an element load or store names a scalar aggregate field",
            when Element_Index_Is_Not_Usize =>
               "an element load or store indexes with a value other than"
               & " usize",
            when Array_Storage_Is_Not_An_Array =>
               "an array operation names storage that is not a fixed array",
            when Array_Copy_Shapes_Disagree =>
               "an array copy's endpoints differ in length or element type",
            when Array_Copy_Inside_A_Datum =>
               "a datum contains an array copy, and [1940] admits none",
            when Array_Clear_Inside_A_Datum =>
               "a datum contains an array clear, and [1940] admits none",
            when Array_Fill_Inside_A_Datum =>
               "a datum contains an array fill, and [1940] admits none",
            when Array_Fill_Value_Disagrees =>
               "an array fill's scalar disagrees with its element type",
            when Array_Fill_First_Out_Of_Range =>
               "an array fill begins beyond its destination's last part",
            when Variant_Operation_Inside_A_Datum =>
               "a datum contains a runtime variant operation, and [1940]"
               & " admits none",
            when Variant_Field_Out_Of_Range =>
               "a variant operation names a field the aggregate does not"
               & " have",
            when Variant_Field_Is_Not_A_Variant =>
               "a variant operation names a scalar or fixed-array field",
            when Variant_Case_Out_Of_Range =>
               "a variant operation names a case the field does not have",
            when Variant_Payload_Field_Out_Of_Range =>
               "a variant payload store names a field the case does not"
               & " have",
            when Variant_Payload_Field_Is_Not_A_Scalar =>
               "a variant payload store names a fixed-array field",
            when Variant_Payload_Value_Disagrees =>
               "a variant payload store's scalar disagrees with its field",
            when Variant_Tag_Result_Disagrees =>
               "a variant tag load's result disagrees with its tag type",
            when Array_Image_Length_Disagrees =>
               "an array datum's image does not have one value per element",
            when Array_Image_Value_Does_Not_Fit =>
               "an array datum's image carries a value the element type"
               & " cannot hold on this target",
            when Aggregate_Image_Length_Disagrees =>
               "an aggregate datum's image does not have one value per"
               & " field",
            when Aggregate_Image_Value_Does_Not_Fit =>
               "an aggregate datum's image carries a value the field type"
               & " cannot hold on this target",
            when Aggregate_Image_On_Array_Field =>
               "an aggregate datum's first image form carries a nonzero"
               & " value for a fixed-array field",
            when Aggregate_Image_On_Variant_Field =>
               "a variant-bearing aggregate datum carries a written image"
               & " although D75 admits only its absent zero image",
            when Aggregate_Field_Image_Length_Disagrees =>
               "an aggregate datum's field-image run disagrees with its"
               & " declared fields",
            when Aggregate_Field_Image_Value_Does_Not_Fit =>
               "an aggregate datum's array-field image carries a value the"
               & " element type cannot hold on this target",
            when Aggregate_Field_Image_On_Scalar_Field =>
               "an aggregate datum carries an array image on a scalar field",
            when Aggregate_Field_Image_Pattern_Not_Canonical =>
               "an aggregate datum carries a noncanonical array-field"
               & " repetition image",
            when Callee_Is_Not_A_Routine =>
               "a call names an item that is not a routine",
            when Call_Inside_A_Datum  =>
               "a datum contains a call, and [1940] admits none",
            when Leave_Disagrees_With_Item =>
               "a leave carries a value the item does not give back");

   --  How many operands each opcode carries.  [1820] decides every row
   --  but Call, whose count is its callee's parameter count [1920].
   function Wanted (Of_Code : Opcode) return Natural
     is (case Of_Code is
            when Constant_Kind => 0,
            --  [0370] carries a type and not an operand.
            when Measure_Size | Measure_Align => 0,
            when Load          => 0,
            when Load_Datum    => 0,
            when Load_Field    => 0,
            when Store_Field   => 1,
            when Load_Element  => 1,
            when Store_Element => 2,
            when Copy_Array | Clear_Array => 0,
            when Fill_Array    => 1,
            when Load_Variant_Tag | Select_Variant => 0,
            when Store_Variant_Field => 1,
            when Store         => 1,
            when Store_Datum   => 1,
            when Unary_Kind    => 1,
            when Binary_Kind   => 2,
            when Call          => 0,
            when Jump          => 0,
            when Branch        => 1,
            when Leave         => 0);

   function Check
     (Of_Unit    : Unit;
      Facts      : Landin.Targets.Target_Facts;
      Check_Image : Boolean) return Fault;

   function Check (Of_Unit : Unit) return Fault
     is (Check (Of_Unit,
                --  Synthetic_32 is a legitimate description but this walk
                --  cannot look at any image and so does not read it.  The
                --  value stands in for the missing argument the same way
                --  a checker-neutral default does in Landin.Types.
                Landin.Targets.Synthetic_32,
                Check_Image => False));

   function Check
     (Of_Unit : Unit;
      Facts   : Landin.Targets.Target_Facts) return Fault
     is (Check (Of_Unit, Facts, Check_Image => True));

   function Check
     (Of_Unit    : Unit;
      Facts      : Landin.Targets.Target_Facts;
      Check_Image : Boolean) return Fault is

      Field_Length_Fault : constant Fault_Kind :=
        Aggregate_Field_Image_Length_Disagrees;
      Field_Value_Fault : constant Fault_Kind :=
        Aggregate_Field_Image_Value_Does_Not_Fit;
      Field_Pattern_Fault : constant Fault_Kind :=
        Aggregate_Field_Image_Pattern_Not_Canonical;

      function Shape_Of
        (Item    : Item_Id;
         Place   : Storage;
         Field   : Natural;
         Element : out Landin.Types.Scalar_Name;
         Length  : out Element_Total) return Fault_Kind;

      function Shape_Of
        (Item    : Item_Id;
         Place   : Storage;
         Field   : Natural;
         Element : out Landin.Types.Scalar_Name;
         Length  : out Element_Total) return Fault_Kind
      is
      begin
         Element := Landin.Types.Bool;
         Length := 0;

         case Place.Kind is
            when Module_Datum =>
               if not Holds (Of_Unit, Place.Datum)
                 or else Kind_Of (Of_Unit, Place.Datum) /= Datum
               then
                  return Named_Item_Is_Not_A_Datum;
               end if;

               if Field = 0 then
                  if Result_Of (Of_Unit, Place.Datum)
                       /= Landin.Types.Fixed_Array
                  then
                     return Array_Storage_Is_Not_An_Array;
                  end if;

                  Element := Array_Element (Of_Unit, Place.Datum);
                  Length := Array_Length (Of_Unit, Place.Datum);
               else
                  if Result_Of (Of_Unit, Place.Datum)
                       /= Landin.Types.Aggregate
                    or else Field > Field_Count (Of_Unit, Place.Datum)
                  then
                     return Element_Field_Out_Of_Range;
                  end if;

                  if Nth_Field_Shape
                       (Of_Unit, Place.Datum, Positive (Field)).Kind
                       /= Array_Field_Shape
                  then
                     return Element_Field_Is_Not_An_Array;
                  end if;

                  Element := Nth_Field_Shape
                    (Of_Unit, Place.Datum, Positive (Field)).Element;
                  Length := Nth_Field_Shape
                    (Of_Unit, Place.Datum, Positive (Field)).Length;
               end if;

            when Frame_Slot =>
               if not Holds (Of_Unit, Item, Place.Slot) then
                  return Slot_Out_Of_Range;
               end if;

               if Field = 0 then
                  if not Is_Array (Of_Unit, Item, Place.Slot) then
                     return Array_Storage_Is_Not_An_Array;
                  end if;

                  Element := Slot_Array_Element (Of_Unit, Item, Place.Slot);
                  Length := Slot_Array_Length (Of_Unit, Item, Place.Slot);
               else
                  if not Is_Aggregate (Of_Unit, Item, Place.Slot)
                    or else Field >
                      Slot_Field_Count (Of_Unit, Item, Place.Slot)
                  then
                     return Element_Field_Out_Of_Range;
                  end if;

                  if Nth_Slot_Field_Shape
                       (Of_Unit, Item, Place.Slot, Positive (Field)).Kind
                       /= Array_Field_Shape
                  then
                     return Element_Field_Is_Not_An_Array;
                  end if;

                  Element := Nth_Slot_Field_Shape
                    (Of_Unit, Item, Place.Slot, Positive (Field)).Element;
                  Length := Nth_Slot_Field_Shape
                    (Of_Unit, Item, Place.Slot, Positive (Field)).Length;
               end if;
         end case;

         return Nothing_Wrong;
      end Shape_Of;

      --  D57 gives field zero of Clear_Array one additional meaning: the
      --  complete padded extent of aggregate storage.  This predicate is
      --  deliberately safe on invented identities; a false answer falls
      --  through Shape_Of, which owns the precise existing storage fault.
      function Is_Whole_Aggregate
        (Item : Item_Id; Place : Storage) return Boolean
      is
        (case Place.Kind is
            when Module_Datum =>
              Holds (Of_Unit, Place.Datum)
              and then Kind_Of (Of_Unit, Place.Datum) = Datum
              and then Result_Of (Of_Unit, Place.Datum)
                         = Landin.Types.Aggregate,
            when Frame_Slot =>
              Holds (Of_Unit, Item, Place.Slot)
              and then Is_Aggregate (Of_Unit, Item, Place.Slot));

      --  D76's two operations share one release-safe shape gate.  Storage,
      --  top-level field, variant kind, case run and optional payload field
      --  are proved in that order before any accessor reads the next layer.
      function Variant_Shape_Of
        (Item          : Item_Id;
         Place         : Storage;
         Field         : Natural;
         Which         : Natural;
         Payload_Field : Natural;
         Shape         : out Field_Shape;
         Leaf          : out Field_Shape) return Fault_Kind;

      function Variant_Shape_Of
        (Item          : Item_Id;
         Place         : Storage;
         Field         : Natural;
         Which         : Natural;
         Payload_Field : Natural;
         Shape         : out Field_Shape;
         Leaf          : out Field_Shape) return Fault_Kind
      is
      begin
         Shape := (others => <>);
         Leaf := (others => <>);

         case Place.Kind is
            when Module_Datum =>
               if not Holds (Of_Unit, Place.Datum)
                 or else Kind_Of (Of_Unit, Place.Datum) /= Datum
               then
                  return Named_Item_Is_Not_A_Datum;
               end if;
               if Result_Of (Of_Unit, Place.Datum)
                    /= Landin.Types.Aggregate
                 or else Field = 0
                 or else Field > Field_Count (Of_Unit, Place.Datum)
               then
                  return Variant_Field_Out_Of_Range;
               end if;
               Shape := Nth_Field_Shape
                 (Of_Unit, Place.Datum, Positive (Field));

            when Frame_Slot =>
               if not Holds (Of_Unit, Item, Place.Slot) then
                  return Slot_Out_Of_Range;
               end if;
               if not Is_Aggregate (Of_Unit, Item, Place.Slot)
                 or else Field = 0
                 or else Field > Slot_Field_Count
                   (Of_Unit, Item, Place.Slot)
               then
                  return Variant_Field_Out_Of_Range;
               end if;
               Shape := Nth_Slot_Field_Shape
                 (Of_Unit, Item, Place.Slot, Positive (Field));
         end case;

         if Shape.Kind /= Variant_Field_Shape then
            return Variant_Field_Is_Not_A_Variant;
         end if;
         --  D77's tag load needs the part shape but no case run.  Runtime
         --  writes continue below with a positive source-order case.
         if Which = 0 and then Payload_Field = 0 then
            return Nothing_Wrong;
         end if;
         if Which = 0 or else Which > Shape.Cases then
            return Variant_Case_Out_Of_Range;
         end if;
         if not Variant_Case_Run_Is_Valid
           (Of_Unit, Shape, Positive (Which))
         then
            return Field_Shape_Malformed;
         end if;
         if Payload_Field = 0 then
            return Nothing_Wrong;
         end if;
         if Payload_Field > Variant_Case_Field_Count
           (Of_Unit, Shape, Positive (Which))
         then
            return Variant_Payload_Field_Out_Of_Range;
         end if;

         Leaf := Nth_Variant_Case_Field
           (Of_Unit, Shape, Positive (Which), Positive (Payload_Field));
         if Leaf.Kind /= Scalar_Field_Shape then
            return Variant_Payload_Field_Is_Not_A_Scalar;
         end if;
         return Nothing_Wrong;
      end Variant_Shape_Of;

      --  D74 introduced this carrier for measurements; D75 uses the same
      --  target-neutral shape for datum and slot storage.  Prove every run
      --  and leaf before any accessor reads it, in every build mode.
      function Field_Shape_Is_Malformed (Shape : Field_Shape)
        return Boolean;

      function Field_Shape_Is_Malformed (Shape : Field_Shape)
        return Boolean
      is
      begin
         if Shape.Kind = Scalar_Field_Shape then
            return Shape.Length /= 1
              or else Shape.Cases /= 0
              or else Shape.Payloads_First /= 0;
         elsif Shape.Kind = Array_Field_Shape then
            return Shape.Cases /= 0 or else Shape.Payloads_First /= 0;
         end if;

         if Shape.Length /= 1
           or else Shape.Element not in
             Landin.Types.U8 | Landin.Types.U16 | Landin.Types.U32
           or else Shape.Cases = 0
           or else Shape.Payloads_First = 0
           or else Shape.Payloads_First > Variant_Case_Run_Count (Of_Unit)
           or else Shape.Cases
             > Variant_Case_Run_Count (Of_Unit)
                 - Shape.Payloads_First + 1
         then
            return True;
         end if;

         for Which in 1 .. Shape.Cases loop
            if not Variant_Case_Run_Is_Valid (Of_Unit, Shape, Which) then
               return True;
            end if;

            for Payload in 1 ..
              Variant_Case_Field_Count (Of_Unit, Shape, Which)
            loop
               declare
                  Leaf : constant Field_Shape :=
                    Nth_Variant_Case_Field
                      (Of_Unit, Shape, Which, Payload);
               begin
                  --  D74/D75 keep payloads depth one.  A future nested
                  --  aggregate representation must choose its own carrier.
                  if Leaf.Kind = Variant_Field_Shape
                    or else Leaf.Cases /= 0
                    or else Leaf.Payloads_First /= 0
                    or else
                      (Leaf.Kind = Scalar_Field_Shape
                       and then Leaf.Length /= 1)
                  then
                     return True;
                  end if;
               end;
            end loop;
         end loop;

         return False;
      end Field_Shape_Is_Malformed;

   begin
      if not Is_Prepared (Of_Unit) then
         return (Kind => Unprepared_Unit, others => <>);
      end if;

      --  First, and before anything indexes a run.  A base that is wrong
      --  makes Nth_Value raise Constraint_Error, so a later rule would
      --  never get to speak.
      declare
         Slots      : Natural := 0;
         Parameters : Natural := 0;
         Blocks     : Natural := 0;
         Values     : Natural := 0;
         Fields     : Natural := 0;
      begin
         for Which in 1 .. Item_Count (Of_Unit) loop
            declare
               Held : constant Item_Record :=
                 Of_Unit.Items (Which);
            begin
               if Held.Slots.Count /= 0
                 and then Held.Slots.First /= Slots
               then
                  return (Kind => Item_Runs_Overlap,
                          Item => Item_Id (Which), others => <>);
               end if;

               if Held.Parameters.Count /= 0
                 and then Held.Parameters.First /= Parameters
               then
                  return (Kind => Item_Runs_Overlap,
                          Item => Item_Id (Which), others => <>);
               end if;

               if Held.Blocks.Count /= 0
                 and then Held.Blocks.First /= Blocks
               then
                  return (Kind => Item_Runs_Overlap,
                          Item => Item_Id (Which), others => <>);
               end if;

               if Held.Values.Count /= 0
                 and then Held.Values.First /= Values
               then
                  return (Kind => Item_Runs_Overlap,
                          Item => Item_Id (Which), others => <>);
               end if;

               if Held.Fields.Count /= 0
                 and then Held.Fields.First /= Fields
               then
                  return (Kind => Item_Runs_Overlap,
                          Item => Item_Id (Which), others => <>);
               end if;

               Slots      := Slots + Held.Slots.Count;
               Parameters := Parameters + Held.Parameters.Count;
               Blocks     := Blocks + Held.Blocks.Count;
               Values     := Values + Held.Values.Count;
               Fields     := Fields + Held.Fields.Count;
            end;
         end loop;
      end;

      --  Images do not partition in item-order the way the four runs
      --  above do: D21 chain resolution fills the source's image
      --  before its destination's, so item 1's Image.First can land
      --  beyond item 3's.  The partition still has to hold -- no run
      --  may cross another and no byte of the vector may belong to no
      --  item -- so this walk marks every position and reports the
      --  first item that would overlap, land out of range or leave a
      --  gap.
      declare
         Total : constant Natural := Natural (Of_Unit.Images.Length);
         Seen  : array (1 .. Positive'Max (1, Total))
                   of Item_Id := [others => No_Item];
      begin
         for Which in 1 .. Item_Count (Of_Unit) loop
            declare
               Held : constant Item_Record :=
                 Of_Unit.Items (Which);
            begin
               if Held.Image.Count /= 0 then
                  --  Subtraction-safe against Natural overflow, so a
                  --  corrupt Held.Image.First at Natural'Last does not
                  --  raise Constraint_Error before the walk speaks.  The
                  --  two conditions read left-to-right: the base has to
                  --  be inside the vector, and the run past the base has
                  --  to fit the bytes that follow.
                  if Held.Image.First > Total
                    or else Held.Image.Count > Total - Held.Image.First
                  then
                     return (Kind => Item_Runs_Overlap,
                             Item => Item_Id (Which), others => <>);
                  end if;

                  for Position in
                    Held.Image.First + 1
                    .. Held.Image.First + Held.Image.Count
                  loop
                     if Seen (Position) /= No_Item then
                        return (Kind => Item_Runs_Overlap,
                                Item => Item_Id (Which), others => <>);
                     end if;
                     Seen (Position) := Item_Id (Which);
                  end loop;
               end if;
            end;
         end loop;

         for Position in 1 .. Total loop
            if Seen (Position) = No_Item then
               return (Kind => Item_Runs_Overlap, others => <>);
            end if;
         end loop;
      end;

      --  D67's one descriptor per aggregate field is filled in the same
      --  image-resolution order as the folded runs above.  Hold this separate
      --  vector to the same complete, non-overlapping partition before any
      --  Field_Image_Of accessor is used.
      declare
         Total : constant Natural :=
           Natural (Of_Unit.Aggregate_Images.Length);
         Seen  : array (1 .. Positive'Max (1, Total))
                   of Item_Id := [others => No_Item];
      begin
         for Which in 1 .. Item_Count (Of_Unit) loop
            declare
               Held : constant Item_Record := Of_Unit.Items (Which);
            begin
               if Held.Aggregate_Images.Count /= 0 then
                  if Held.Aggregate_Images.First > Total
                    or else Held.Aggregate_Images.Count
                              > Total - Held.Aggregate_Images.First
                  then
                     return (Kind => Item_Runs_Overlap,
                             Item => Item_Id (Which), others => <>);
                  end if;

                  for Position in
                    Held.Aggregate_Images.First + 1
                    .. Held.Aggregate_Images.First
                         + Held.Aggregate_Images.Count
                  loop
                     if Seen (Position) /= No_Item then
                        return (Kind => Item_Runs_Overlap,
                                Item => Item_Id (Which), others => <>);
                     end if;
                     Seen (Position) := Item_Id (Which);
                  end loop;
               end if;
            end;
         end loop;

         for Position in 1 .. Total loop
            if Seen (Position) = No_Item then
               return (Kind => Item_Runs_Overlap, others => <>);
            end if;
         end loop;
      end;

      --  The operand vector, which is the fifth run and the one a call
      --  extends after the fact.
      declare
         Seen : Natural := 0;
      begin
         for Position in 1 .. Natural (Of_Unit.Code.Length) loop
            declare
               What : constant Instruction := Of_Unit.Code (Position);
            begin
               if What.Args /= 0 and then What.First_Arg /= Seen then
                  return (Kind => Operand_Runs_Overlap, others => <>);
               end if;

               Seen := Seen + What.Args;
            end;
         end loop;
      end;

      --  D46 shares one target-neutral field shape between aggregate
      --  storage and D45's measurement.  Hold the aggregate run to its
      --  canonical scalar representation before inspecting any item's
      --  blocks, just as the vector partition checks above precede uses of
      --  the vectors they protect.
      for Which in 1 .. Item_Count (Of_Unit) loop
         declare
            Id : constant Item_Id := Item_Id (Which);
         begin
            if Result_Of (Of_Unit, Id) = Landin.Types.Aggregate then
               for Field in 1 .. Field_Count (Of_Unit, Id) loop
                  declare
                     Shape : constant Field_Shape :=
                       Nth_Field_Shape (Of_Unit, Id, Field);
                  begin
                     if Field_Shape_Is_Malformed (Shape) then
                        return (Kind => Field_Shape_Malformed,
                                Item => Id, others => <>);
                     end if;
                  end;
               end loop;
            end if;

            for Slot in 1 .. Slot_Count (Of_Unit, Id) loop
               if Is_Aggregate (Of_Unit, Id, Slot_Id (Slot)) then
                  for Field in
                    1 .. Slot_Field_Count (Of_Unit, Id, Slot_Id (Slot))
                  loop
                     declare
                        Shape : constant Field_Shape :=
                          Nth_Slot_Field_Shape
                            (Of_Unit, Id, Slot_Id (Slot), Field);
                     begin
                        if Field_Shape_Is_Malformed (Shape) then
                           return (Kind => Field_Shape_Malformed,
                                   Item => Id, others => <>);
                        end if;
                     end;
                  end loop;
               end if;
            end loop;
         end;
      end loop;

      for Which in 1 .. Item_Count (Of_Unit) loop
         declare
            Id : constant Item_Id := Item_Id (Which);
            Is_Datum : constant Boolean := Kind_Of (Of_Unit, Id) = Datum;
            Blocks : constant Natural := Block_Count (Of_Unit, Id);
            Reached : array (1 .. Positive'Max (1, Blocks)) of Boolean :=
              [others => False];
         begin
            if Blocks = 0 then
               return (Kind => Item_Without_A_Block, Item => Id,
                       others => <>);
            end if;

            if Open_Block (Of_Unit, Id) /= No_Block then
               return (Kind => Item_Still_Building, Item => Id,
                       others => <>);
            end if;

            --  D24: an array item's image, when it has one, has one value
            --  per declared position.  A datum with no image is D10's zero
            --  storage and this check has nothing to say about it.
            if Result_Of (Of_Unit, Id) = Landin.Types.Fixed_Array
              and then Has_Image (Of_Unit, Id)
              and then Image_Length (Of_Unit, Id)
                       /= Array_Length (Of_Unit, Id)
            then
               return (Kind => Array_Image_Length_Disagrees,
                       Item => Id, others => <>);
            end if;

            --  D24: each per-position folded value has to fit its element
            --  type at the compilation's target facts.  An u8 that holds
            --  300, a bool that holds 2, or a `usize` that overflows a
            --  32-bit description are IR whose bytes the backend has no
            --  defined answer for, and a defect here is caught before an
            --  `.data` directive lies about the bytes.
            if Check_Image
              and then Result_Of (Of_Unit, Id) = Landin.Types.Fixed_Array
              and then Has_Image (Of_Unit, Id)
              and then Image_Length (Of_Unit, Id)
                       = Array_Length (Of_Unit, Id)
            then
               declare
                  Element : constant Landin.Types.Scalar_Name :=
                    Array_Element (Of_Unit, Id);
                  Last : constant Part_Position :=
                    (if Is_Repeated_Image (Of_Unit, Id)
                     then Part_Position
                            (Image_Prefix_Length (Of_Unit, Id) + 1)
                     else Part_Position (Image_Length (Of_Unit, Id)));
               begin
                  --  D34 verifies one repeated scalar once; D38 verifies its
                  --  finite prefix and one suffix scalar.  Walking the
                  --  declared extent would turn either compact image back
                  --  into a target-sized host computation.
                  for Position in Part_Position'(1) .. Last
                  loop
                     declare
                        Held : constant Landin.Types.Folded :=
                          Nth_Image (Of_Unit, Id, Position);
                        Fits : Boolean;
                     begin
                        if Element = Landin.Types.Bool then
                           Fits := Held in 0 .. 1;
                        else
                           Fits :=
                             Landin.Types.Holds
                               (Held,
                                Landin.Types.Integer_Name (Element),
                                Facts);
                        end if;

                        if not Fits then
                           return
                             (Kind  => Array_Image_Value_Does_Not_Fit,
                              Item  => Id,
                              others => <>);
                        end if;
                     end;
                  end loop;
               end;
            end if;

            --  D66/D67: the flat image starts with one folded entry for each
            --  declaration-order field, followed by D67's finite array-field
            --  segments.  The descriptor count and every offset/form/length
            --  are checked before Nth_Field_Element, so release builds never
            --  rely on an accessor contract for malformed input.
            if Result_Of (Of_Unit, Id) = Landin.Types.Aggregate
              and then Has_Image (Of_Unit, Id)
              and then Image_Length (Of_Unit, Id)
                       < Element_Total (Field_Count (Of_Unit, Id))
            then
               return (Kind => Aggregate_Image_Length_Disagrees,
                       Item => Id, others => <>);
            end if;

            if Result_Of (Of_Unit, Id) = Landin.Types.Aggregate
              and then Has_Image (Of_Unit, Id)
              and then Image_Length (Of_Unit, Id)
                       >= Element_Total (Field_Count (Of_Unit, Id))
              and then Aggregate_Field_Image_Count (Of_Unit, Id)
                       /= Field_Count (Of_Unit, Id)
            then
               return (Kind => Aggregate_Field_Image_Length_Disagrees,
                       Item => Id, others => <>);
            end if;

            if Result_Of (Of_Unit, Id) = Landin.Types.Aggregate
              and then Has_Image (Of_Unit, Id)
              and then Image_Length (Of_Unit, Id)
                       >= Element_Total (Field_Count (Of_Unit, Id))
              and then Aggregate_Field_Image_Count (Of_Unit, Id)
                       = Field_Count (Of_Unit, Id)
            then
               declare
                  Expected : Natural := 0;
                  Elements : constant Natural :=
                    Natural
                      (Image_Length (Of_Unit, Id)
                       - Element_Total (Field_Count (Of_Unit, Id)));
               begin
                  for Field in 1 .. Field_Count (Of_Unit, Id) loop
                     declare
                        Shape : constant Field_Shape :=
                          Nth_Field_Shape (Of_Unit, Id, Field);
                        Held : constant Landin.Types.Folded :=
                          Nth_Field_Image (Of_Unit, Id, Field);
                        Image : constant Aggregate_Field_Image :=
                          Field_Image_Of (Of_Unit, Id, Field);
                        Fits : Boolean := True;
                     begin
                        if Image.Offset /= Expected
                          or else Image.Count > Elements - Expected
                        then
                           return
                             (Kind => Aggregate_Field_Image_Length_Disagrees,
                              Item => Id, others => <>);
                        end if;

                        if Shape.Kind = Variant_Field_Shape then
                           return
                             (Kind => Aggregate_Image_On_Variant_Field,
                              Item => Id, others => <>);
                        elsif Shape.Kind = Scalar_Field_Shape then
                           if Image.Form /= Absent or else Image.Count /= 0
                           then
                              return
                                (Kind =>
                                   Aggregate_Field_Image_On_Scalar_Field,
                                 Item => Id, others => <>);
                           elsif Check_Image then
                              if Shape.Element = Landin.Types.Bool then
                                 Fits := Held in 0 .. 1;
                              else
                                 Fits :=
                                   Landin.Types.Holds
                                     (Held,
                                      Landin.Types.Integer_Name
                                        (Shape.Element),
                                      Facts);
                              end if;

                              if not Fits then
                                 return
                                   (Kind =>
                                      Aggregate_Image_Value_Does_Not_Fit,
                                    Item => Id, others => <>);
                              end if;
                           end if;
                        else
                           if Held /= 0 then
                              return
                                (Kind => Aggregate_Image_On_Array_Field,
                                 Item => Id, others => <>);
                           end if;

                           case Image.Form is
                              when Absent =>
                                 if Image.Count /= 0 then
                                    return
                                      (Kind => Field_Length_Fault,
                                       Item => Id, others => <>);
                                 elsif Image.Value /= 0 then
                                    return
                                      (Kind => Field_Pattern_Fault,
                                       Item => Id, others => <>);
                                 end if;
                              when Finite =>
                                 if Element_Total (Image.Count)
                                      /= Shape.Length
                                 then
                                    return
                                      (Kind => Field_Length_Fault,
                                       Item => Id, others => <>);
                                 elsif Image.Value /= 0 then
                                    return
                                      (Kind => Field_Pattern_Fault,
                                       Item => Id, others => <>);
                                 end if;
                              when Repeated =>
                                 if Image.Count /= 0 or else Image.Value = 0
                                 then
                                    return
                                      (Kind => Field_Pattern_Fault,
                                       Item => Id, others => <>);
                                 end if;
                              when Hybrid =>
                                 if Image.Count = 0
                                   or else Element_Total (Image.Count)
                                             >= Shape.Length
                                 then
                                    return
                                      (Kind => Field_Pattern_Fault,
                                       Item => Id, others => <>);
                                 end if;
                           end case;
                        end if;

                        Expected := Expected + Image.Count;
                     end;
                  end loop;

                  if Expected /= Elements then
                     return
                       (Kind => Aggregate_Field_Image_Length_Disagrees,
                        Item => Id, others => <>);
                  end if;

                  if Check_Image then
                     for Field in 1 .. Field_Count (Of_Unit, Id) loop
                        declare
                           Shape : constant Field_Shape :=
                             Nth_Field_Shape (Of_Unit, Id, Field);
                           Image : constant Aggregate_Field_Image :=
                             Field_Image_Of (Of_Unit, Id, Field);
                        begin
                           if Shape.Kind = Array_Field_Shape
                             and then Image.Form in Finite | Hybrid
                           then
                              for Position in 1 .. Image.Count loop
                                 declare
                                    Held : constant Landin.Types.Folded :=
                                      Nth_Field_Element
                                        (Of_Unit, Id, Field,
                                         Part_Position (Position));
                                    Fits : Boolean;
                                 begin
                                    if Shape.Element = Landin.Types.Bool then
                                       Fits := Held in 0 .. 1;
                                    else
                                       Fits :=
                                         Landin.Types.Holds
                                           (Held,
                                            Landin.Types.Integer_Name
                                              (Shape.Element),
                                            Facts);
                                    end if;

                                    if not Fits then
                                       return
                                         (Kind => Field_Value_Fault,
                                          Item => Id, others => <>);
                                    end if;
                                 end;
                              end loop;
                           end if;

                           if Shape.Kind = Array_Field_Shape
                             and then Image.Form in Repeated | Hybrid
                           then
                              declare
                                 Fits : Boolean;
                              begin
                                 if Shape.Element = Landin.Types.Bool then
                                    Fits := Image.Value in 0 .. 1;
                                 else
                                    Fits :=
                                      Landin.Types.Holds
                                        (Image.Value,
                                         Landin.Types.Integer_Name
                                           (Shape.Element),
                                         Facts);
                                 end if;

                                 if not Fits then
                                    return
                                      (Kind => Field_Value_Fault,
                                       Item => Id, others => <>);
                                 end if;
                              end;
                           end if;
                        end;
                     end loop;
                  end if;
               end;
            end if;

            --  [1550]: block 1 is where an item starts, and every other
            --  block is reached from one before it.
            Reached (1) := True;

            for B in 1 .. Blocks loop
               declare
                  Block : constant Block_Id := Block_Id (B);
                  Last  : constant Natural := Length (Of_Unit, Id, Block);
               begin
                  if Last = 0 then
                     return (Kind => Empty_Block, Item => Id,
                             Block => Block, others => <>);
                  end if;

                  for Position in 1 .. Last loop
                     declare
                        V : constant Value_Id :=
                          Nth_Value (Of_Unit, Id, Block, Position);
                        Op : constant Opcode := Op_Of (Of_Unit, Id, V);
                        Ends : constant Boolean := Op in Terminator_Kind;
                     begin
                        if Ends and then Position /= Last then
                           return (Kind => Terminator_Inside_A_Block,
                                   Item => Id, Block => Block, Value => V);
                        end if;

                        if Position = Last and then not Ends then
                           return (Kind => Block_Without_A_Terminator,
                                   Item => Id, Block => Block, Value => V);
                        end if;

                        --  Step one: what a later step indexes.  A
                        --  callee, a slot, a datum or a target that does
                        --  not exist has to be caught before anything
                        --  asks it a question.
                        case Op is
                           when Load | Store =>
                              if not Holds
                                       (Of_Unit, Id,
                                        Slot_Of (Of_Unit, Id, V))
                              then
                                 return (Kind => Slot_Out_Of_Range,
                                         Item => Id, Block => Block,
                                         Value => V);
                              end if;

                           when Load_Field | Store_Field =>
                              if Reaches_A_Slot (Of_Unit, Id, V) then
                                 --  [1810]'s local: a cell of this item,
                                 --  which has to be one it has, has to
                                 --  hold an aggregate, and has to have
                                 --  the field named.
                                 declare
                                    Cell : constant Slot_Id :=
                                      Slot_Of (Of_Unit, Id, V);
                                 begin
                                    if not Holds (Of_Unit, Id, Cell) then
                                       return (Kind => Slot_Out_Of_Range,
                                               Item => Id, Block => Block,
                                               Value => V);
                                    end if;

                                    if (not Is_Aggregate (Of_Unit, Id, Cell)
                                        and then not Is_Array
                                                       (Of_Unit, Id, Cell))
                                      or else Element_Total
                                                (Field_Of (Of_Unit, Id, V))
                                              > Slot_Part_Count
                                                  (Of_Unit, Id, Cell)
                                    then
                                       return (Kind => Field_Out_Of_Range,
                                               Item => Id, Block => Block,
                                               Value => V);
                                    end if;

                                    if not Slot_Part_Is_Scalar
                                      (Of_Unit, Id, Cell,
                                       Field_Of (Of_Unit, Id, V))
                                    then
                                       return
                                         (Kind => Field_Is_Not_A_Scalar,
                                          Item => Id, Block => Block,
                                          Value => V);
                                    end if;

                                    if Op = Load_Field
                                      and then Result_Of (Of_Unit, Id, V)
                                               /= Nth_Slot_Part
                                                    (Of_Unit, Id, Cell,
                                                     Field_Of
                                                       (Of_Unit, Id, V))
                                    then
                                       return (Kind => Result_Disagrees,
                                               Item => Id, Block => Block,
                                               Value => V);
                                    end if;
                                 end;
                              else
                                 declare
                                    D : constant Item_Id :=
                                      Datum_Of (Of_Unit, Id, V);
                                 begin
                                    if not Holds (Of_Unit, D)
                                      or else Kind_Of (Of_Unit, D) /= Datum
                                    then
                                       return
                                         (Kind => Named_Item_Is_Not_A_Datum,
                                          Item => Id, Block => Block,
                                          Value => V);
                                    end if;

                                    --  A part of an aggregate item is a
                                    --  field of [0670]'s struct or an
                                    --  element of [0520]'s array, and the
                                    --  two differ only in how many there
                                    --  are and what they hold.
                                    if Result_Of (Of_Unit, D)
                                       not in Landin.Types.Aggregate
                                              | Landin.Types.Fixed_Array
                                      or else Element_Total
                                                (Field_Of (Of_Unit, Id, V))
                                              > Part_Count (Of_Unit, D)
                                    then
                                       return
                                         (Kind => Field_Out_Of_Range,
                                          Item => Id, Block => Block,
                                         Value => V);
                                    end if;

                                    if not Part_Is_Scalar
                                      (Of_Unit, D,
                                       Field_Of (Of_Unit, Id, V))
                                    then
                                       return
                                         (Kind => Field_Is_Not_A_Scalar,
                                          Item => Id, Block => Block,
                                          Value => V);
                                    end if;

                                    if Op = Load_Field
                                      and then Result_Of (Of_Unit, Id, V)
                                               /= Nth_Part
                                                    (Of_Unit, D,
                                                     Field_Of (Of_Unit, Id, V))
                                    then
                                       return
                                         (Kind => Result_Disagrees,
                                          Item => Id, Block => Block,
                                          Value => V);
                                    end if;
                                 end;
                              end if;

                           when Load_Element | Store_Element =>
                              if Reaches_A_Slot (Of_Unit, Id, V) then
                                 --  D22: a computed element of an
                                 --  [1810] local array in this item's
                                 --  frame.  The slot has to exist and
                                 --  has to be one Add_Array_Slot made.
                                 declare
                                    Cell : constant Slot_Id :=
                                      Slot_Of (Of_Unit, Id, V);
                                 begin
                                    if not Holds (Of_Unit, Id, Cell) then
                                       return (Kind => Slot_Out_Of_Range,
                                               Item => Id, Block => Block,
                                               Value => V);
                                    end if;

                                    if Element_Field_Of (Of_Unit, Id, V) = 0
                                      and then not Is_Array
                                                     (Of_Unit, Id, Cell)
                                    then
                                       return
                                         (Kind =>
                                            Element_Datum_Is_Not_An_Array,
                                          Item => Id, Block => Block,
                                          Value => V);
                                    end if;

                                    if Element_Field_Of (Of_Unit, Id, V) > 0
                                    then
                                       declare
                                          Field : constant Natural :=
                                            Element_Field_Of
                                              (Of_Unit, Id, V);
                                          Not_Array : constant Fault_Kind :=
                                            Element_Field_Is_Not_An_Array;
                                       begin
                                          if not Is_Aggregate
                                                   (Of_Unit, Id, Cell)
                                            or else Field > Slot_Field_Count
                                                              (Of_Unit, Id,
                                                               Cell)
                                          then
                                             return
                                               (Kind =>
                                                  Element_Field_Out_Of_Range,
                                                Item => Id, Block => Block,
                                                Value => V);
                                          end if;

                                          if Nth_Slot_Field_Shape
                                               (Of_Unit, Id, Cell,
                                                Positive (Field)).Kind
                                               /= Array_Field_Shape
                                          then
                                             return
                                               (Kind => Not_Array,
                                                Item => Id, Block => Block,
                                                Value => V);
                                          end if;
                                       end;
                                    end if;
                                 end;
                              else
                                 declare
                                    D : constant Item_Id :=
                                      Datum_Of (Of_Unit, Id, V);
                                 begin
                                    if not Holds (Of_Unit, D)
                                      or else Kind_Of (Of_Unit, D) /= Datum
                                    then
                                       return
                                         (Kind => Named_Item_Is_Not_A_Datum,
                                          Item => Id, Block => Block,
                                          Value => V);
                                    end if;

                                    if Element_Field_Of (Of_Unit, Id, V) = 0
                                      and then Result_Of (Of_Unit, D)
                                                   /= Landin.Types.Fixed_Array
                                    then
                                       return
                                         (Kind =>
                                            Element_Datum_Is_Not_An_Array,
                                          Item => Id, Block => Block,
                                          Value => V);
                                    end if;

                                    if Element_Field_Of (Of_Unit, Id, V) > 0
                                    then
                                       declare
                                          Field : constant Natural :=
                                            Element_Field_Of
                                              (Of_Unit, Id, V);
                                          Not_Array : constant Fault_Kind :=
                                            Element_Field_Is_Not_An_Array;
                                       begin
                                          if Result_Of (Of_Unit, D)
                                               /= Landin.Types.Aggregate
                                            or else Field > Field_Count
                                                              (Of_Unit, D)
                                          then
                                             return
                                               (Kind =>
                                                  Element_Field_Out_Of_Range,
                                                Item => Id, Block => Block,
                                                Value => V);
                                          end if;

                                          if Nth_Field_Shape
                                               (Of_Unit, D,
                                                Positive (Field)).Kind
                                               /= Array_Field_Shape
                                          then
                                             return
                                               (Kind => Not_Array,
                                                Item => Id, Block => Block,
                                                Value => V);
                                          end if;
                                       end;
                                    end if;
                                 end;
                              end if;

                           when Copy_Array =>
                              if Is_Datum then
                                 return
                                   (Kind  => Array_Copy_Inside_A_Datum,
                                    Item  => Id,
                                    Block => Block,
                                    Value => V);
                              end if;

                              declare
                                 Source_Element, Destination_Element :
                                   Landin.Types.Scalar_Name;
                                 Source_Length, Destination_Length :
                                   Element_Total;
                                 Bad : Fault_Kind;
                              begin
                                 Bad := Shape_Of
                                   (Id, Source_Of (Of_Unit, Id, V),
                                    Source_Field_Of (Of_Unit, Id, V),
                                    Source_Element, Source_Length);
                                 if Bad /= Nothing_Wrong then
                                    return (Kind => Bad, Item => Id,
                                            Block => Block, Value => V);
                                 end if;

                                 Bad := Shape_Of
                                   (Id, Destination_Of (Of_Unit, Id, V),
                                    Element_Field_Of (Of_Unit, Id, V),
                                    Destination_Element, Destination_Length);
                                 if Bad /= Nothing_Wrong then
                                    return (Kind => Bad, Item => Id,
                                            Block => Block, Value => V);
                                 end if;

                                 if Source_Element /= Destination_Element
                                   or else Source_Length /= Destination_Length
                                 then
                                    return
                                      (Kind => Array_Copy_Shapes_Disagree,
                                       Item => Id, Block => Block, Value => V);
                                 end if;
                              end;

                           when Clear_Array =>
                              if Is_Datum then
                                 return
                                   (Kind  => Array_Clear_Inside_A_Datum,
                                    Item  => Id,
                                    Block => Block,
                                    Value => V);
                              end if;

                              declare
                                 Destination : constant Storage :=
                                   Destination_Of (Of_Unit, Id, V);
                                 Field : constant Natural :=
                                   Element_Field_Of (Of_Unit, Id, V);
                                 Element : Landin.Types.Scalar_Name;
                                 Length  : Element_Total;
                                 Bad     : Fault_Kind := Nothing_Wrong;
                              begin
                                 if Field /= 0
                                   or else not Is_Whole_Aggregate
                                                 (Id, Destination)
                                 then
                                    --  Arrays and positive aggregate array
                                    --  fields retain their exact D49 checks.
                                    --  Invalid storage also comes here;
                                    --  Shape_Of reports it before an accessor.
                                    Bad := Shape_Of
                                      (Id, Destination, Field,
                                       Element, Length);
                                 end if;

                                 if Bad /= Nothing_Wrong then
                                    return (Kind => Bad, Item => Id,
                                            Block => Block, Value => V);
                                 end if;
                              end;

                           when Load_Variant_Tag
                              | Select_Variant | Store_Variant_Field =>
                              if Is_Datum then
                                 return
                                   (Kind  => Variant_Operation_Inside_A_Datum,
                                    Item  => Id,
                                    Block => Block,
                                    Value => V);
                              end if;

                              declare
                                 Shape, Leaf : Field_Shape;
                                 Bad : constant Fault_Kind :=
                                   Variant_Shape_Of
                                     (Id,
                                      (if Op = Load_Variant_Tag
                                       then Source_Of (Of_Unit, Id, V)
                                       else Destination_Of
                                         (Of_Unit, Id, V)),
                                      Element_Field_Of (Of_Unit, Id, V),
                                      (if Op = Load_Variant_Tag then 0
                                       else Variant_Case_Of
                                         (Of_Unit, Id, V)),
                                      (if Op = Store_Variant_Field
                                       then Variant_Payload_Field_Of
                                         (Of_Unit, Id, V)
                                       else 0),
                                      Shape, Leaf);
                              begin
                                 if Bad /= Nothing_Wrong then
                                    return (Kind => Bad, Item => Id,
                                            Block => Block, Value => V);
                                 end if;
                              end;

                           when Fill_Array =>
                              if Is_Datum then
                                 return
                                   (Kind  => Array_Fill_Inside_A_Datum,
                                    Item  => Id,
                                    Block => Block,
                                    Value => V);
                              end if;

                              declare
                                 Element : Landin.Types.Scalar_Name;
                                 Length  : Element_Total;
                                 Bad     : constant Fault_Kind :=
                                   Shape_Of
                                     (Id,
                                      Destination_Of (Of_Unit, Id, V),
                                      Element_Field_Of (Of_Unit, Id, V),
                                      Element, Length);
                              begin
                                 if Bad /= Nothing_Wrong then
                                    return (Kind => Bad, Item => Id,
                                            Block => Block, Value => V);
                                 end if;

                                 if Element_Total
                                      (First_Part_Of (Of_Unit, Id, V))
                                      > Length
                                 then
                                    return
                                      (Kind => Array_Fill_First_Out_Of_Range,
                                       Item => Id, Block => Block, Value => V);
                                 end if;

                                 if Result_Of
                                      (Of_Unit, Id,
                                       Nth_Operand (Of_Unit, Id, V, 1))
                                      /= Element
                                 then
                                    return
                                      (Kind => Array_Fill_Value_Disagrees,
                                       Item => Id, Block => Block, Value => V);
                                 end if;
                              end;

                           when Load_Datum | Store_Datum =>
                              declare
                                 D : constant Item_Id :=
                                   Datum_Of (Of_Unit, Id, V);
                              begin
                                 if not Holds (Of_Unit, D)
                                   or else Kind_Of (Of_Unit, D) /= Datum
                                 then
                                    return
                                      (Kind => Named_Item_Is_Not_A_Datum,
                                       Item => Id, Block => Block,
                                       Value => V);
                                 end if;

                                 --  [0670]'s state is storage and not a
                                 --  value yet: reading or writing the
                                 --  whole of one needs a rule for
                                 --  carrying it that R2.20 has not
                                 --  written, so the IR may not say it.
                                 if Result_Of (Of_Unit, D)
                                    = Landin.Types.Aggregate
                                 then
                                    return
                                      (Kind =>
                                         Aggregate_Datum_Is_Not_A_Value,
                                       Item => Id, Block => Block,
                                       Value => V);
                                 end if;
                              end;

                           when Call =>
                              --  [1940]: a module value is not a call.
                              if Is_Datum then
                                 return (Kind => Call_Inside_A_Datum,
                                         Item => Id, Block => Block,
                                         Value => V);
                              end if;

                              declare
                                 C : constant Item_Id :=
                                   Callee_Of (Of_Unit, Id, V);
                              begin
                                 if not Holds (Of_Unit, C)
                                   or else Kind_Of (Of_Unit, C) /= Routine
                                 then
                                    return
                                      (Kind => Callee_Is_Not_A_Routine,
                                       Item => Id, Block => Block,
                                       Value => V);
                                 end if;
                              end;

                           when Jump | Branch =>
                              --  A datum may branch.  [0410] makes the
                              --  logical words short-circuit and
                              --  Landin.IR has no opcode for them, and
                              --  [1940] admits an operator of [1820]
                              --  over literals -- so `k: bool = true and
                              --  false` is a legal module value whose
                              --  only lowering is blocks.  R1.70
                              --  considered folding it here instead and
                              --  refused: that is a second constant
                              --  folder beside the checker's, over the
                              --  whole of [1820] including the widths.
                              if not Holds
                                       (Of_Unit, Id,
                                        Target_Of (Of_Unit, Id, V))
                                or else (Op = Branch
                                         and then not Holds
                                                        (Of_Unit, Id,
                                                         Alternative_Of
                                                           (Of_Unit, Id,
                                                            V)))
                              then
                                 return (Kind => Target_Out_Of_Range,
                                         Item => Id, Block => Block,
                                         Value => V);
                              end if;

                              Reached
                                (Positive
                                   (Target_Of (Of_Unit, Id, V))) := True;

                              if Op = Branch then
                                 Reached
                                   (Positive
                                      (Alternative_Of
                                         (Of_Unit, Id, V))) := True;
                              end if;

                           when others =>
                              null;
                        end case;

                        --  Step two: how many operands.  [1820] decides
                        --  every opcode but two: a call takes what its
                        --  callee declares [1920], and a leave carries
                        --  what its item gives back, which is nothing
                        --  for `-> none` and nothing for [0670]'s state,
                        --  whose storage its fields describe.
                        declare
                           Expect : constant Natural :=
                             (case Op is
                                 when Call =>
                                    Parameter_Count
                                      (Of_Unit,
                                       Callee_Of (Of_Unit, Id, V)),
                                 when Leave =>
                                    (if Result_Of (Of_Unit, Id)
                                        in Landin.Types.Scalar_Name
                                     then 1 else 0),
                                 when others => Wanted (Op));
                        begin
                           if Operand_Count (Of_Unit, Id, V) /= Expect
                           then
                              return (Kind => Wrong_Operand_Count,
                                      Item => Id, Block => Block,
                                      Value => V);
                           end if;
                        end;

                        --  Step three: every operand names a value this
                        --  block already defined.  Block-local and above
                        --  the use, which is the invariant that lets one
                        --  comparison stand in for a dominance relation.
                        for Index in
                          1 .. Operand_Count (Of_Unit, Id, V)
                        loop
                           declare
                              Arg : constant Value_Id :=
                                Nth_Operand (Of_Unit, Id, V, Index);
                           begin
                              if not Holds (Of_Unit, Id, Arg) then
                                 return (Kind => Operand_Out_Of_Range,
                                         Item => Id, Block => Block,
                                         Value => V);
                              end if;

                              if Arg >= V then
                                 return
                                   (Kind => Operand_Not_Above_Its_Use,
                                    Item => Id, Block => Block,
                                    Value => V);
                              end if;

                              if Block_Of (Of_Unit, Id, Arg) /= Block then
                                 return (Kind => Operand_In_Another_Block,
                                         Item => Id, Block => Block,
                                         Value => V);
                              end if;

                              if Defines_Nothing
                                   (Op_Of (Of_Unit, Id, Arg))
                              then
                                 return (Kind => Operand_Defines_Nothing,
                                         Item => Id, Block => Block,
                                         Value => V);
                              end if;
                           end;
                        end loop;

                        --  Step four: the types [1890].
                        case Op is
                           when Binary_Kind =>
                              declare
                                 L : constant Value_Id :=
                                   Nth_Operand (Of_Unit, Id, V, 1);
                                 R : constant Value_Id :=
                                   Nth_Operand (Of_Unit, Id, V, 2);
                              begin
                                 if Result_Of (Of_Unit, Id, L)
                                    /= Result_Of (Of_Unit, Id, R)
                                 then
                                    return (Kind => Operands_Disagree,
                                            Item => Id, Block => Block,
                                            Value => V);
                                 end if;

                                 --  and that type back, or a bool from a
                                 --  comparison [0350].
                                 if Result_Of (Of_Unit, Id, V)
                                    /= (if Op in Comparison_Kind
                                        then Landin.Types.Bool
                                        else Result_Of (Of_Unit, Id, L))
                                 then
                                    return (Kind => Result_Disagrees,
                                            Item => Id, Block => Block,
                                            Value => V);
                                 end if;
                              end;

                           when Unary_Kind =>
                              if Result_Of (Of_Unit, Id, V)
                                 /= Result_Of
                                      (Of_Unit, Id,
                                       Nth_Operand (Of_Unit, Id, V, 1))
                              then
                                 return (Kind => Result_Disagrees,
                                         Item => Id, Block => Block,
                                         Value => V);
                              end if;

                           when Measure_Size | Measure_Align =>
                              if Result_Of (Of_Unit, Id, V)
                                /= Landin.Types.Usize
                              then
                                 return (Kind => Result_Disagrees,
                                         Item => Id, Block => Block,
                                         Value => V);
                              end if;

                              if Is_Aggregate_Measurement
                                   (Of_Unit, Id, V)
                              then
                                 for Field in
                                   1 .. Measurement_Field_Count
                                          (Of_Unit, Id, V)
                                 loop
                                    declare
                                       Part : constant Field_Shape :=
                                         Nth_Measurement_Field
                                           (Of_Unit, Id, V, Field);
                                    begin
                                       if Field_Shape_Is_Malformed (Part) then
                                          return
                                            (Field_Shape_Malformed,
                                             Id, Block, V);
                                       end if;
                                    end;
                                 end loop;
                              end if;

                           when Store =>
                              declare
                                 S : constant Slot_Id :=
                                   Slot_Of (Of_Unit, Id, V);
                              begin
                                 if Type_Of (Of_Unit, Id, S)
                                    /= Result_Of
                                         (Of_Unit, Id,
                                          Nth_Operand (Of_Unit, Id, V, 1))
                                 then
                                    return
                                      (Kind => Store_Disagrees_With_Slot,
                                       Item => Id, Block => Block,
                                       Value => V);
                                 end if;

                                 --  [1900]: a parameter may not be
                                 --  written, because the unmarked
                                 --  convention is [0900]'s `in`.
                                 for P in
                                   1 .. Parameter_Count (Of_Unit, Id)
                                 loop
                                    if Nth_Parameter (Of_Unit, Id, P) = S
                                    then
                                       return
                                         (Kind => Store_To_A_Parameter,
                                          Item => Id, Block => Block,
                                          Value => V);
                                    end if;
                                 end loop;
                              end;

                           when Store_Datum =>
                              if Result_Of
                                   (Of_Unit, Datum_Of (Of_Unit, Id, V))
                                 /= Result_Of
                                      (Of_Unit, Id,
                                       Nth_Operand (Of_Unit, Id, V, 1))
                              then
                                 return (Kind => Store_Datum_Disagrees,
                                         Item => Id, Block => Block,
                                         Value => V);
                              end if;

                           when Load_Element | Store_Element =>
                              declare
                                 Index : constant Value_Id :=
                                   Nth_Operand (Of_Unit, Id, V, 1);
                                 Element : constant Landin.Types.Scalar_Name
                                   :=
                                     (if Reaches_A_Slot (Of_Unit, Id, V)
                                      then Slot_Element_Type
                                             (Of_Unit, Id, V)
                                      elsif Element_Field_Of
                                              (Of_Unit, Id, V) = 0
                                      then Array_Element
                                             (Of_Unit,
                                              Datum_Of (Of_Unit, Id, V))
                                      else Nth_Field_Shape
                                             (Of_Unit,
                                              Datum_Of (Of_Unit, Id, V),
                                              Positive
                                                (Element_Field_Of
                                                   (Of_Unit, Id, V))).Element);
                              begin
                                 if Result_Of (Of_Unit, Id, Index)
                                      /= Landin.Types.Usize
                                 then
                                    return
                                      (Kind => Element_Index_Is_Not_Usize,
                                       Item => Id, Block => Block,
                                       Value => V);
                                 end if;

                                 if Op = Load_Element then
                                    if Result_Of (Of_Unit, Id, V) /= Element
                                    then
                                       return
                                         (Kind => Result_Disagrees,
                                          Item => Id, Block => Block,
                                          Value => V);
                                    end if;
                                 elsif Result_Of
                                         (Of_Unit, Id,
                                          Nth_Operand (Of_Unit, Id, V, 2))
                                       /= Element
                                 then
                                    return
                                      (Kind => Store_Datum_Disagrees,
                                       Item => Id, Block => Block,
                                       Value => V);
                                 end if;
                              end;

                           when Store_Field =>
                              declare
                                 Wants : constant Landin.Types.Scalar_Name
                                   :=
                                     (if Reaches_A_Slot (Of_Unit, Id, V)
                                      then Nth_Slot_Part
                                             (Of_Unit, Id,
                                              Slot_Of (Of_Unit, Id, V),
                                              Field_Of (Of_Unit, Id, V))
                                      else Nth_Part
                                             (Of_Unit,
                                              Datum_Of (Of_Unit, Id, V),
                                              Field_Of (Of_Unit, Id, V)));
                              begin
                                 if Wants
                                    /= Result_Of
                                         (Of_Unit, Id,
                                          Nth_Operand (Of_Unit, Id, V, 1))
                                 then
                                    return
                                      (Kind => Store_Datum_Disagrees,
                                       Item => Id, Block => Block,
                                       Value => V);
                                 end if;
                              end;

                           when Store_Variant_Field =>
                              declare
                                 Shape, Leaf : Field_Shape;
                                 Bad : constant Fault_Kind :=
                                   Variant_Shape_Of
                                     (Id,
                                      Destination_Of (Of_Unit, Id, V),
                                      Element_Field_Of (Of_Unit, Id, V),
                                      Variant_Case_Of (Of_Unit, Id, V),
                                      Variant_Payload_Field_Of
                                        (Of_Unit, Id, V),
                                      Shape, Leaf);
                              begin
                                 if Bad /= Nothing_Wrong then
                                    return (Kind => Bad, Item => Id,
                                            Block => Block, Value => V);
                                 elsif Result_Of
                                      (Of_Unit, Id,
                                       Nth_Operand (Of_Unit, Id, V, 1))
                                      /= Leaf.Element
                                 then
                                    return
                                      (Kind => Variant_Payload_Value_Disagrees,
                                       Item => Id, Block => Block, Value => V);
                                 end if;
                              end;

                           when Load_Variant_Tag =>
                              declare
                                 Shape, Leaf : Field_Shape;
                                 Bad : constant Fault_Kind :=
                                   Variant_Shape_Of
                                     (Id, Source_Of (Of_Unit, Id, V),
                                      Element_Field_Of (Of_Unit, Id, V),
                                      0, 0, Shape, Leaf);
                              begin
                                 if Bad /= Nothing_Wrong then
                                    return (Kind => Bad, Item => Id,
                                            Block => Block, Value => V);
                                 elsif Result_Of (Of_Unit, Id, V)
                                       /= Shape.Element
                                 then
                                    return
                                      (Kind => Variant_Tag_Result_Disagrees,
                                       Item => Id, Block => Block, Value => V);
                                 end if;
                              end;

                           when Branch =>
                              if Result_Of
                                   (Of_Unit, Id,
                                    Nth_Operand (Of_Unit, Id, V, 1))
                                 /= Landin.Types.Bool
                              then
                                 return (Kind => Condition_Is_Not_A_Bool,
                                         Item => Id, Block => Block,
                                         Value => V);
                              end if;

                           when Call =>
                              declare
                                 C : constant Item_Id :=
                                   Callee_Of (Of_Unit, Id, V);
                              begin
                                 if Result_Of (Of_Unit, Id, V)
                                    /= Result_Of (Of_Unit, C)
                                 then
                                    return (Kind => Result_Disagrees,
                                            Item => Id, Block => Block,
                                            Value => V);
                                 end if;

                                 --  [1920]: each argument has its
                                 --  parameter's type, in order.
                                 for P in
                                   1 .. Parameter_Count (Of_Unit, C)
                                 loop
                                    if Type_Of
                                         (Of_Unit, C,
                                          Nth_Parameter (Of_Unit, C, P))
                                       /= Result_Of
                                            (Of_Unit, Id,
                                             Nth_Operand
                                               (Of_Unit, Id, V, P))
                                    then
                                       return (Kind => Operands_Disagree,
                                               Item => Id, Block => Block,
                                               Value => V);
                                    end if;
                                 end loop;
                              end;

                           when Leave =>
                              --  An aggregate item hands nothing back:
                              --  [0670]'s state is storage the fields
                              --  describe, and a value of one is not
                              --  lowered yet.  So only a scalar result is
                              --  a result a leave has to carry.
                              if Result_Of (Of_Unit, Id)
                                 in Landin.Types.Scalar_Name
                                and then Operand_Count (Of_Unit, Id, V) >= 1
                                and then Result_Of
                                           (Of_Unit, Id,
                                            Nth_Operand
                                              (Of_Unit, Id, V, 1))
                                         /= Result_Of (Of_Unit, Id)
                              then
                                 return
                                   (Kind => Leave_Disagrees_With_Item,
                                    Item => Id, Block => Block,
                                    Value => V);
                              end if;

                           when others =>
                              null;
                        end case;
                     end;
                  end loop;
               end;
            end loop;

            for B in 2 .. Blocks loop
               if not Reached (B) then
                  return (Kind => Block_Unreachable, Item => Id,
                          Block => Block_Id (B), others => <>);
               end if;
            end loop;
         end;
      end loop;

      return Sound;
   end Check;

   procedure Raise_On (Found : Fault);

   procedure Raise_On (Found : Fault) is
   begin
      if Found.Kind /= Nothing_Wrong then
         raise Landin.Compiler_Defect with
           "malformed IR: " & Describe (Found.Kind)
           & " (item" & Found.Item'Image
           & ", block" & Found.Block'Image
           & ", value" & Found.Value'Image & ")";
      end if;
   end Raise_On;

   procedure Verify (Of_Unit : Unit) is
   begin
      Raise_On (Check (Of_Unit));
   end Verify;

   procedure Verify
     (Of_Unit : Unit;
      Facts   : Landin.Targets.Target_Facts) is
   begin
      Raise_On (Check (Of_Unit, Facts));
   end Verify;

end Landin.IR.Verifier;
