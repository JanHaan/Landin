with Landin.IR.Control_Flow;
with Landin.Types;

package body Landin.IR.Verifier is

   use type Landin.Targets.C_ABI_Kind;
   use type Landin.Source.Names.Name_Id;
   use type Landin.Types.Magnitude;

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
            when Atom_Set_Runs_Overlap =>
               "an atom set's members are not where its run says they are",
            when Atom_Set_Malformed =>
               "an atom set is empty, duplicated or names no declaration",
            when Signature_Runs_Overlap =>
               "a signature's parameters are not where its run says they are",
            when Signature_Part_Malformed =>
               "a signature carries a malformed target-neutral type part",
            when Nominal_Metadata_Malformed =>
               "an item or slot carries invalid nominal aggregate metadata",
            when Nominal_Shape_Disagrees =>
               "one nominal identity denotes two structural aggregate shapes",
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
            when Signature_Out_Of_Range =>
               "a callable value names a signature the unit does not have",
            when Routine_Signature_Disagrees =>
               "a routine's slots disagree with its signature descriptor",
            when Function_Value_Signature_Disagrees =>
               "a function value disagrees with its slot or call signature",
            when Evidence_Out_Of_Range =>
               "an evidence operation names no table in this unit",
            when Evidence_Entry_Out_Of_Range =>
               "an evidence operation names no direct concept entry",
            when Evidence_Entry_Signature_Disagrees =>
               "an evidence entry's signature disagrees with its provider",
            when Erased_Dispatch_Malformed =>
               "an erased signature differs from its provider beyond self"
               & " or is used as an ordinary callable",
            when Evidence_Self_Disagrees =>
               "an erased call does not pair its function and receiver",
            when Atom_Metadata_Disagrees =>
               "an atom carrier disagrees with its structural atom set",
            when Atom_Identity_Not_In_Set =>
               "an atom constant's declaration is not in its atom set",
            when Field_Shape_Malformed =>
               "an aggregate's scalar field has a length other than one",
            when Condition_Is_Not_A_Bool =>
               "a branch's condition is not a bool",
            when Unchecked_Not_Removable =>
               "an instruction is marked unchecked and carries no check"
               & " D187 removes, or sits in a module value",
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
            when Storage_Address_Is_Not_An_Aggregate =>
               "an internal aggregate address names non-aggregate storage",
            when Runtime_Address_Is_Not_Valid =>
               "a runtime storage endpoint names no checked address slot",
            when Address_Value_Disagrees =>
               "a checked address slot is filled by another shape or value",
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
            when Variant_Copy_Shapes_Disagree =>
               "a variant copy's source and destination shapes disagree",
            when Variant_Field_Out_Of_Range =>
               "a variant operation names a field the aggregate does not"
               & " have",
            when Variant_Field_Is_Not_A_Variant =>
               "a variant operation names a scalar or fixed-array field",
            when Variant_Case_Out_Of_Range =>
               "a variant operation names a case the field does not have",
            when Variant_Payload_Field_Out_Of_Range =>
               "a variant payload operation names a field the case does not"
               & " have",
            when Variant_Payload_Field_Is_Not_A_Scalar =>
               "a variant payload operation names a fixed-array field",
            when Variant_Payload_Value_Disagrees =>
               "a variant payload store's scalar disagrees with its field",
            when Variant_Payload_Result_Disagrees =>
               "a variant payload load's result disagrees with its field",
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
               "an aggregate datum carries a malformed fixed-array image",
            when Aggregate_Image_On_Aggregate_Field =>
               "an aggregate datum carries a malformed nested field image",
            when Aggregate_Image_On_Variant_Field =>
               "an aggregate datum carries a malformed selected variant"
               & " image",
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
            when Call_Failure_Slot_Disagrees =>
               "a call's failure slot disagrees with its declared errors",
            when Leave_Disagrees_With_Item =>
               "a leave carries a value the item does not give back",
            when Fail_Disagrees_With_Signature =>
               "a fail carries an atom outside its routine's error set");

   --  How many operands each opcode carries.  [1820] decides every row
   --  but Call, whose count is its callee's parameter count [1920].
   function Wanted (Of_Code : Opcode) return Natural
     is (case Of_Code is
            when Constant_Kind => 0,
            --  [0370] carries a type and not an operand.
            when Measure_Size | Measure_Align => 0,
            when Load => 0,
            when Slice_Address => 4,
            when Empty_Slice_Base => 0,
            when Conversion | Pointer_Address => 1,
            when Range_Check   => 1,
            when Load_Indirect => 1,
            when Store_Indirect => 2,
            when Load_Datum    => 0,
            when Load_Field    => 0,
            when Store_Field   => 1,
            when Load_Element  => 1,
            when Store_Element => 2,
            when Copy_Array | Copy_Variant | Clear_Array => 0,
            when Fill_Array    => 1,
            when Load_Variant_Tag | Load_Variant_Field
               | Select_Variant => 0,
            when Store_Variant_Field => 1,
            when Store         => 1,
            when Store_Datum   => 1,
            when Unary_Kind    => 1,
            when Binary_Kind   => 2,
            when Failure_Test  => 1,
            when Evidence_Function | Evidence_Self => 1,
            when Storage_Address | Place_Address | Function_Address
               | Evidence_Address | Call | Indirect_Call => 0,
            when Jump          => 0,
            when Branch        => 1,
            when Leave         => 0,
            when Fail          => 1);

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
      Signature_Mismatch : constant Fault_Kind :=
        Function_Value_Signature_Disagrees;

      function Run_Fits (Held : Run; Total : Natural) return Boolean
        is (Held.First <= Total
            and then Held.Count <= Total - Held.First);

      function Variant_Shape_Of
        (Item          : Item_Id;
         Place         : Storage;
         Field         : Natural;
         Which         : Natural;
         Payload_Field : Natural;
         Shape         : out Field_Shape;
         Leaf          : out Field_Shape;
         Nested        : Path_Step_Array := No_Path_Steps) return Fault_Kind;

      function Scalar_Field_Of
        (Item    : Item_Id;
         Place   : Storage;
         Field   : Part_Position;
         Nested  : Path_Step_Array;
         Element : out Landin.Types.Scalar_Name) return Fault_Kind;

      function Scalar_Field_Signature
        (Item   : Item_Id;
         Place  : Storage;
         Field  : Part_Position;
         Nested : Path_Step_Array) return Signature_Id;

      function Scalar_Field_Atoms
        (Item   : Item_Id;
         Place  : Storage;
         Field  : Part_Position;
         Nested : Path_Step_Array) return Atom_Set_Id;

      --  D121: an array's element may be an aggregate, so what an array
      --  shape answers is the element's shape and not a scalar name.
      function Shape_Of
        (Item    : Item_Id;
         Place   : Storage;
         Field   : Natural;
         Element : out Field_Shape;
         Length  : out Element_Total;
         Which   : Natural := 0;
         Payload_Field : Natural := 0;
         Nested  : Path_Step_Array := No_Path_Steps;
         Aggregate_Field : Boolean := False) return Fault_Kind;

      function Root_Shape_Of
        (Item  : Item_Id;
         Place : Storage;
         Field : Natural;
         Shape : out Field_Shape) return Boolean;

      function Scalar_Field_Of
        (Item    : Item_Id;
         Place   : Storage;
         Field   : Part_Position;
         Nested  : Path_Step_Array;
         Element : out Landin.Types.Scalar_Name) return Fault_Kind
      is
         Shape : Field_Shape;
      begin
         Element := Landin.Types.Bool;

         case Place.Kind is
            when Module_Datum =>
               if not Holds (Of_Unit, Place.Datum)
                 or else Kind_Of (Of_Unit, Place.Datum) /= Datum
               then
                  return Named_Item_Is_Not_A_Datum;
               end if;
               if Result_Of (Of_Unit, Place.Datum)
                    not in Landin.Types.Aggregate | Landin.Types.Fixed_Array
                 or else Element_Total (Field)
                           > Part_Count (Of_Unit, Place.Datum)
               then
                  return Field_Out_Of_Range;
               end if;
               if Nested'Length = 0 then
                  if not Part_Is_Scalar (Of_Unit, Place.Datum, Field) then
                     return Field_Is_Not_A_Scalar;
                  end if;
                  Element := Nth_Part (Of_Unit, Place.Datum, Field);
                  return Nothing_Wrong;
               end if;
               --  D127: for an array the base is [0520]'s element
               --  position, so the run starts at the element's shape.
               Shape :=
                 (if Result_Of (Of_Unit, Place.Datum)
                       = Landin.Types.Fixed_Array
                  then Array_Element_Shape (Of_Unit, Place.Datum)
                  else Nth_Field_Shape
                    (Of_Unit, Place.Datum, Positive (Field)));

            when Frame_Slot =>
               if not Holds (Of_Unit, Item, Place.Slot) then
                  return Slot_Out_Of_Range;
               end if;
               if (not Is_Aggregate (Of_Unit, Item, Place.Slot)
                   and then not Is_Array (Of_Unit, Item, Place.Slot))
                 or else Element_Total (Field)
                           > Slot_Part_Count (Of_Unit, Item, Place.Slot)
               then
                  return Field_Out_Of_Range;
               end if;
               if Nested'Length = 0 then
                  if not Slot_Part_Is_Scalar
                    (Of_Unit, Item, Place.Slot, Field)
                  then
                     return Field_Is_Not_A_Scalar;
                  end if;
                  Element := Nth_Slot_Part
                    (Of_Unit, Item, Place.Slot, Field);
                  return Nothing_Wrong;
               end if;
               Shape :=
                 (if Is_Array (Of_Unit, Item, Place.Slot)
                  then Slot_Array_Element_Shape (Of_Unit, Item, Place.Slot)
                  else Nth_Slot_Field_Shape
                    (Of_Unit, Item, Place.Slot, Positive (Field)));

            when Runtime_Address =>
               if not Holds (Of_Unit, Item, Place.Address)
                 or else not Is_Address (Of_Unit, Item, Place.Address)
               then
                  return Runtime_Address_Is_Not_Valid;
               end if;
               Shape := Address_Shape (Of_Unit, Item, Place.Address);
               if Shape.Kind = Array_Field_Shape then
                  if Element_Total (Field) > Shape.Length then
                     return Field_Out_Of_Range;
                  end if;
                  Shape := Array_Element_Shape (Of_Unit, Shape);
               elsif Shape.Kind = Aggregate_Field_Shape then
                  if Natural (Field) > Aggregate_Field_Count
                    (Of_Unit, Shape)
                  then
                     return Field_Out_Of_Range;
                  end if;
                  Shape := Nth_Aggregate_Field
                    (Of_Unit, Shape, Positive (Field));
               else
                  return Field_Out_Of_Range;
               end if;
               if Nested'Length = 0 then
                  if Shape.Kind /= Scalar_Field_Shape then
                     return Field_Is_Not_A_Scalar;
                  end if;
                  Element := Shape.Element;
                  return Nothing_Wrong;
               end if;
         end case;

         --  D118: however many steps the path has, the walk is one
         --  question asked of Landin.IR, which is the package that owns
         --  what a step may index.
         if not Path_Is_Valid (Of_Unit, Shape, Nested) then
            return Field_Is_Not_A_Scalar;
         end if;

         declare
            Leaf : constant Field_Shape :=
              Shape_At (Of_Unit, Shape, Nested);
         begin
            if Leaf.Kind /= Scalar_Field_Shape then
               return Field_Is_Not_A_Scalar;
            end if;
            Element := Leaf.Element;
            return Nothing_Wrong;
         end;
      end Scalar_Field_Of;

      function Scalar_Field_Signature
        (Item   : Item_Id;
         Place  : Storage;
         Field  : Part_Position;
         Nested : Path_Step_Array) return Signature_Id
      is
         Root : Field_Shape;
      begin
         case Place.Kind is
            when Module_Datum =>
               Root :=
                 (if Result_Of (Of_Unit, Place.Datum)
                       = Landin.Types.Fixed_Array
                  then Array_Element_Shape (Of_Unit, Place.Datum)
                  else Nth_Field_Shape
                    (Of_Unit, Place.Datum, Positive (Field)));
            when Frame_Slot =>
               Root :=
                 (if Is_Array (Of_Unit, Item, Place.Slot)
                  then Slot_Array_Element_Shape
                    (Of_Unit, Item, Place.Slot)
                  else Nth_Slot_Field_Shape
                    (Of_Unit, Item, Place.Slot, Positive (Field)));
            when Runtime_Address =>
               Root :=
                 (if Address_Shape (Of_Unit, Item, Place.Address).Kind
                       = Array_Field_Shape
                  then Array_Element_Shape
                    (Of_Unit, Address_Shape
                       (Of_Unit, Item, Place.Address))
                  else Nth_Aggregate_Field
                    (Of_Unit,
                     Address_Shape (Of_Unit, Item, Place.Address),
                     Positive (Field)));
         end case;
         return Shape_At (Of_Unit, Root, Nested).Signature;
      end Scalar_Field_Signature;

      function Scalar_Field_Atoms
        (Item   : Item_Id;
         Place  : Storage;
         Field  : Part_Position;
         Nested : Path_Step_Array) return Atom_Set_Id
      is
         Root : Field_Shape;
      begin
         case Place.Kind is
            when Module_Datum =>
               Root :=
                 (if Result_Of (Of_Unit, Place.Datum)
                       = Landin.Types.Fixed_Array
                  then Array_Element_Shape (Of_Unit, Place.Datum)
                  else Nth_Field_Shape
                    (Of_Unit, Place.Datum, Positive (Field)));
            when Frame_Slot =>
               Root :=
                 (if Is_Array (Of_Unit, Item, Place.Slot)
                  then Slot_Array_Element_Shape
                    (Of_Unit, Item, Place.Slot)
                  else Nth_Slot_Field_Shape
                    (Of_Unit, Item, Place.Slot, Positive (Field)));
            when Runtime_Address =>
               Root :=
                 (if Address_Shape (Of_Unit, Item, Place.Address).Kind
                       = Array_Field_Shape
                  then Array_Element_Shape
                    (Of_Unit, Address_Shape
                       (Of_Unit, Item, Place.Address))
                  else Nth_Aggregate_Field
                    (Of_Unit,
                     Address_Shape (Of_Unit, Item, Place.Address),
                     Positive (Field)));
         end case;
         return Shape_At (Of_Unit, Root, Nested).Atoms;
      end Scalar_Field_Atoms;

      function Shape_Of
        (Item    : Item_Id;
         Place   : Storage;
         Field   : Natural;
         Element : out Field_Shape;
         Length  : out Element_Total;
         Which   : Natural := 0;
         Payload_Field : Natural := 0;
         Nested  : Path_Step_Array := No_Path_Steps;
         Aggregate_Field : Boolean := False) return Fault_Kind
      is
      begin
         Element := (others => <>);
         Length := 0;

         if Nested'Length /= 0 then
            if Which /= 0 or else Payload_Field /= 0 then
               return Element_Field_Is_Not_An_Array;
            end if;
            declare
               Shape : Field_Shape;
            begin
               --  D127: a run may start at whole array storage as well as
               --  at a base field.
               if not Root_Shape_Of (Item, Place, Field, Shape) then
                  return Element_Field_Out_Of_Range;
               end if;

               if not Path_Is_Valid (Of_Unit, Shape, Nested) then
                  return Element_Field_Is_Not_An_Array;
               end if;

               declare
                  Leaf : constant Field_Shape :=
                    Shape_At (Of_Unit, Shape, Nested);
               begin
                  if Leaf.Kind = Aggregate_Field_Shape
                    and then Aggregate_Field
                  then
                     Element := Leaf;
                     Length := 1;
                  elsif Leaf.Kind = Array_Field_Shape then
                     Element := Array_Element_Shape (Of_Unit, Leaf);
                     Length := Leaf.Length;
                  else
                     return Element_Field_Is_Not_An_Array;
                  end if;
                  return Nothing_Wrong;
               end;
            end;
         end if;

         if Which /= 0 or else Payload_Field /= 0 then
            declare
               Shape, Leaf : Field_Shape;
               Bad : constant Fault_Kind :=
                 Variant_Shape_Of
                   (Item, Place, Field, Which, Payload_Field, Shape, Leaf,
                    Nested);
            begin
               if Bad /= Nothing_Wrong then
                  return Bad;
               end if;
               if Leaf.Kind /= Array_Field_Shape then
                  return Element_Field_Is_Not_An_Array;
               end if;
               Element := Array_Element_Shape (Of_Unit, Leaf);
               Length := Leaf.Length;
               return Nothing_Wrong;
            end;
         end if;

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

                  Element := Array_Element_Shape (Of_Unit, Place.Datum);
                  Length := Array_Length (Of_Unit, Place.Datum);
               else
                  if Result_Of (Of_Unit, Place.Datum)
                       /= Landin.Types.Aggregate
                    or else Field > Field_Count (Of_Unit, Place.Datum)
                  then
                     return Element_Field_Out_Of_Range;
                  end if;

                  declare
                     Shape : constant Field_Shape :=
                       Nth_Field_Shape
                         (Of_Unit, Place.Datum, Positive (Field));
                  begin
                     if Shape.Kind = Aggregate_Field_Shape
                       and then Aggregate_Field
                     then
                        Element := Shape;
                        Length := 1;
                     elsif Shape.Kind = Array_Field_Shape then
                        Element := Array_Element_Shape (Of_Unit, Shape);
                        Length := Shape.Length;
                     else
                        return Element_Field_Is_Not_An_Array;
                     end if;
                  end;
               end if;

            when Frame_Slot =>
               if not Holds (Of_Unit, Item, Place.Slot) then
                  return Slot_Out_Of_Range;
               end if;

               if Field = 0 then
                  if not Is_Array (Of_Unit, Item, Place.Slot) then
                     return Array_Storage_Is_Not_An_Array;
                  end if;

                  Element := Slot_Array_Element_Shape
                    (Of_Unit, Item, Place.Slot);
                  Length := Slot_Array_Length (Of_Unit, Item, Place.Slot);
               else
                  if not Is_Aggregate (Of_Unit, Item, Place.Slot)
                    or else Field >
                      Slot_Field_Count (Of_Unit, Item, Place.Slot)
                  then
                     return Element_Field_Out_Of_Range;
                  end if;

                  declare
                     Shape : constant Field_Shape :=
                       Nth_Slot_Field_Shape
                         (Of_Unit, Item, Place.Slot, Positive (Field));
                  begin
                     if Shape.Kind = Aggregate_Field_Shape
                       and then Aggregate_Field
                     then
                        Element := Shape;
                        Length := 1;
                     elsif Shape.Kind = Array_Field_Shape then
                        Element := Array_Element_Shape (Of_Unit, Shape);
                        Length := Shape.Length;
                     else
                        return Element_Field_Is_Not_An_Array;
                     end if;
                  end;
               end if;

            when Runtime_Address =>
               if not Holds (Of_Unit, Item, Place.Address)
                 or else not Is_Address (Of_Unit, Item, Place.Address)
               then
                  return Runtime_Address_Is_Not_Valid;
               end if;
               declare
                  Shape : Field_Shape :=
                    Address_Shape (Of_Unit, Item, Place.Address);
               begin
                  if Field > 0 then
                     if Shape.Kind /= Aggregate_Field_Shape
                       or else Field > Aggregate_Field_Count
                         (Of_Unit, Shape)
                     then
                        return Element_Field_Out_Of_Range;
                     end if;
                     Shape := Nth_Aggregate_Field
                       (Of_Unit, Shape, Positive (Field));
                  end if;
                  if Shape.Kind = Aggregate_Field_Shape
                    and then Aggregate_Field
                  then
                     Element := Shape;
                     Length := 1;
                  elsif Shape.Kind = Array_Field_Shape then
                     Element := Array_Element_Shape (Of_Unit, Shape);
                     Length := Shape.Length;
                  else
                     return Element_Field_Is_Not_An_Array;
                  end if;
               end;
         end case;

         return Nothing_Wrong;
      end Shape_Of;

      --  D57 gives field zero of Clear_Array the complete padded aggregate;
      --  D91 gives a positive aggregate-field identity its child extent.
      --  These predicates are deliberately safe on invented identities; a
      --  false answer falls
      --  through Shape_Of, which owns the precise existing storage fault.
      --  D127: where a run starts.  A positive base field is that field's
      --  shape; base zero is storage that is itself an array, said as one
      --  shape so a run may start there too.  False when the storage is
      --  not what the base field claims; the caller's own fault covers it.
      function Root_Shape_Of
        (Item  : Item_Id;
         Place : Storage;
         Field : Natural;
         Shape : out Field_Shape) return Boolean
      is
      begin
         Shape := (others => <>);
         case Place.Kind is
            when Module_Datum =>
               if not Holds (Of_Unit, Place.Datum)
                 or else Kind_Of (Of_Unit, Place.Datum) /= Datum
               then
                  return False;
               end if;
               if Field = 0 then
                  if Result_Of (Of_Unit, Place.Datum)
                       /= Landin.Types.Fixed_Array
                  then
                     return False;
                  end if;
                  Shape := Whole_Array_Shape (Of_Unit, Place.Datum);
                  return True;
               end if;
               --  D127: on an array the base is [0520]'s element
               --  position, so the run starts at the element.
               if Result_Of (Of_Unit, Place.Datum)
                    = Landin.Types.Fixed_Array
               then
                  if Element_Total (Field)
                       > Array_Length (Of_Unit, Place.Datum)
                  then
                     return False;
                  end if;
                  Shape := Array_Element_Shape (Of_Unit, Place.Datum);
                  return True;
               end if;
               if Result_Of (Of_Unit, Place.Datum)
                    /= Landin.Types.Aggregate
                 or else Field > Field_Count (Of_Unit, Place.Datum)
               then
                  return False;
               end if;
               Shape := Nth_Field_Shape
                 (Of_Unit, Place.Datum, Positive (Field));
               return True;

            when Frame_Slot =>
               if not Holds (Of_Unit, Item, Place.Slot) then
                  return False;
               end if;
               if Field = 0 then
                  if not Is_Array (Of_Unit, Item, Place.Slot) then
                     return False;
                  end if;
                  Shape := Whole_Slot_Array_Shape
                    (Of_Unit, Item, Place.Slot);
                  return True;
               end if;
               if Is_Array (Of_Unit, Item, Place.Slot) then
                  if Element_Total (Field)
                       > Slot_Array_Length (Of_Unit, Item, Place.Slot)
                  then
                     return False;
                  end if;
                  Shape := Slot_Array_Element_Shape
                    (Of_Unit, Item, Place.Slot);
                  return True;
               end if;
               if not Is_Aggregate (Of_Unit, Item, Place.Slot)
                 or else Field
                           > Slot_Field_Count (Of_Unit, Item, Place.Slot)
               then
                  return False;
               end if;
               Shape := Nth_Slot_Field_Shape
                 (Of_Unit, Item, Place.Slot, Positive (Field));
               return True;

            when Runtime_Address =>
               if not Holds (Of_Unit, Item, Place.Address)
                 or else not Is_Address (Of_Unit, Item, Place.Address)
               then
                  return False;
               end if;
               Shape := Address_Shape (Of_Unit, Item, Place.Address);
               if Field = 0 then
                  return True;
               elsif Shape.Kind = Array_Field_Shape then
                  if Element_Total (Field) > Shape.Length then
                     return False;
                  end if;
                  Shape := Array_Element_Shape (Of_Unit, Shape);
                  return True;
               elsif Shape.Kind /= Aggregate_Field_Shape
                 or else Field > Aggregate_Field_Count (Of_Unit, Shape)
               then
                  return False;
               end if;
               Shape := Nth_Aggregate_Field
                 (Of_Unit, Shape, Positive (Field));
               return True;
         end case;
      end Root_Shape_Of;

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
              and then Is_Aggregate (Of_Unit, Item, Place.Slot),
            when Runtime_Address =>
              Holds (Of_Unit, Item, Place.Address)
              and then Is_Address (Of_Unit, Item, Place.Address)
              and then Address_Shape (Of_Unit, Item, Place.Address).Kind
                = Aggregate_Field_Shape);

      function Is_Whole_Array
        (Item : Item_Id; Place : Storage) return Boolean
      is
        (case Place.Kind is
            when Module_Datum =>
              Holds (Of_Unit, Place.Datum)
              and then Kind_Of (Of_Unit, Place.Datum) = Datum
              and then Result_Of (Of_Unit, Place.Datum)
                         = Landin.Types.Fixed_Array,
            when Frame_Slot =>
              Holds (Of_Unit, Item, Place.Slot)
              and then Is_Array (Of_Unit, Item, Place.Slot),
            when Runtime_Address =>
              Holds (Of_Unit, Item, Place.Address)
              and then Is_Address (Of_Unit, Item, Place.Address)
              and then Address_Shape (Of_Unit, Item, Place.Address).Kind
                = Array_Field_Shape);

      --  D91 recognised one whole child at the base field; D119 lets the
      --  path go on before the part it reaches has to be one.  The base
      --  field is proved to exist before the path is walked, and the walk
      --  is Landin.IR's own, so an invented identity answers False here
      --  rather than reaching an accessor.
      function Is_Whole_Aggregate_Field
        (Item : Item_Id; Place : Storage; Field : Natural;
         Path : Path_Step_Array := No_Path_Steps) return Boolean;

      function Is_Whole_Aggregate_Field
        (Item : Item_Id; Place : Storage; Field : Natural;
         Path : Path_Step_Array := No_Path_Steps) return Boolean
      is
         Base : Field_Shape;
      begin
         --  D127: base zero with a run is whole array storage the run
         --  starts at; base zero with no run is the storage itself, which
         --  Is_Whole_Aggregate answers.
         if Field = 0 and then Path'Length = 0 then
            return False;
         end if;

         if not Root_Shape_Of (Item, Place, Field, Base) then
            return False;
         end if;

         return Path_Is_Valid (Of_Unit, Base, Path)
           and then Shape_At (Of_Unit, Base, Path).Kind
                      = Aggregate_Field_Shape;
      end Is_Whole_Aggregate_Field;

      function Stored_Shape_Agrees
        (Item     : Item_Id;
         Place    : Storage;
         Field    : Natural;
         Nested   : Path_Step_Array;
         Expected : Field_Shape) return Boolean;

      function Stored_Shape_Agrees
        (Item     : Item_Id;
         Place    : Storage;
         Field    : Natural;
         Nested   : Path_Step_Array;
         Expected : Field_Shape) return Boolean
      is
         Reached : Field_Shape;
      begin
         if Field > 0 or else Nested'Length > 0 then
            if not Root_Shape_Of (Item, Place, Field, Reached)
              or else not Path_Is_Valid (Of_Unit, Reached, Nested)
            then
               return False;
            end if;
            return Same_Shape
              (Of_Unit, Shape_At (Of_Unit, Reached, Nested), Expected);
         end if;

         case Place.Kind is
            when Runtime_Address =>
               return Holds (Of_Unit, Item, Place.Address)
                 and then Is_Address (Of_Unit, Item, Place.Address)
                 and then Same_Shape
                   (Of_Unit,
                    Address_Shape (Of_Unit, Item, Place.Address), Expected);

            when Module_Datum =>
               if not Holds (Of_Unit, Place.Datum)
                 or else Kind_Of (Of_Unit, Place.Datum) /= Datum
               then
                  return False;
               elsif Result_Of (Of_Unit, Place.Datum)
                       = Landin.Types.Fixed_Array
               then
                  return Same_Shape
                    (Of_Unit, Whole_Array_Shape (Of_Unit, Place.Datum),
                     Expected);
               elsif Result_Of (Of_Unit, Place.Datum)
                       in Landin.Types.Scalar_Name
               then
                  return Same_Shape
                    (Of_Unit,
                     (Element => Landin.Types.Scalar_Name
                        (Result_Of (Of_Unit, Place.Datum)),
                      Signature => Signature_Of (Of_Unit, Place.Datum),
                      Atoms => Atom_Set_Of (Of_Unit, Place.Datum),
                      Pointee => Pointee_Of (Of_Unit, Place.Datum),
                      others => <>), Expected);
               elsif Result_Of (Of_Unit, Place.Datum)
                       /= Landin.Types.Aggregate
                 or else Expected.Kind /= Aggregate_Field_Shape
                 or else Nominal_Of (Of_Unit, Place.Datum) /= Expected.Nominal
                 or else Field_Count (Of_Unit, Place.Datum)
                           /= Aggregate_Field_Count (Of_Unit, Expected)
               then
                  return False;
               end if;
               for Position in 1 .. Field_Count (Of_Unit, Place.Datum) loop
                  if not Same_Shape
                    (Of_Unit,
                     Nth_Field_Shape (Of_Unit, Place.Datum, Position),
                     Nth_Aggregate_Field
                       (Of_Unit, Expected, Position))
                  then
                     return False;
                  end if;
               end loop;
               return True;

            when Frame_Slot =>
               if not Holds (Of_Unit, Item, Place.Slot) then
                  return False;
               elsif Is_Array (Of_Unit, Item, Place.Slot) then
                  return Same_Shape
                    (Of_Unit,
                     Whole_Slot_Array_Shape
                       (Of_Unit, Item, Place.Slot), Expected);
               elsif not Is_Aggregate (Of_Unit, Item, Place.Slot) then
                  return Same_Shape
                    (Of_Unit,
                     (Element => Type_Of (Of_Unit, Item, Place.Slot),
                      Signature => Signature_Of (Of_Unit, Item, Place.Slot),
                      Atoms => Atom_Set_Of (Of_Unit, Item, Place.Slot),
                      Pointee => Pointee_Of (Of_Unit, Item, Place.Slot),
                      others => <>), Expected);
               elsif Expected.Kind /= Aggregate_Field_Shape
                 or else Nominal_Of (Of_Unit, Item, Place.Slot)
                   /= Expected.Nominal
                 or else Slot_Field_Count (Of_Unit, Item, Place.Slot)
                           /= Aggregate_Field_Count (Of_Unit, Expected)
               then
                  return False;
               end if;
               for Position in
                 1 .. Slot_Field_Count (Of_Unit, Item, Place.Slot)
               loop
                  if not Same_Shape
                    (Of_Unit,
                     Nth_Slot_Field_Shape
                       (Of_Unit, Item, Place.Slot, Position),
                     Nth_Aggregate_Field
                       (Of_Unit, Expected, Position))
                  then
                     return False;
                  end if;
               end loop;
               return True;
         end case;
      end Stored_Shape_Agrees;

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
         Leaf          : out Field_Shape;
         Nested        : Path_Step_Array := No_Path_Steps) return Fault_Kind
      is
      begin
         Shape := (others => <>);
         Leaf := (others => <>);

         --  D127: where the run starts is one question for every
         --  operation, and an array element is a base like a field.
         if Field = 0 or else not Root_Shape_Of (Item, Place, Field, Shape)
         then
            return
              (case Place.Kind is
                  when Module_Datum =>
                    (if Holds (Of_Unit, Place.Datum)
                       and then Kind_Of (Of_Unit, Place.Datum) = Datum
                     then Variant_Field_Out_Of_Range
                     else Named_Item_Is_Not_A_Datum),
                  when Frame_Slot =>
                    (if Holds (Of_Unit, Item, Place.Slot)
                     then Variant_Field_Out_Of_Range
                     else Slot_Out_Of_Range),
                  when Runtime_Address =>
                    (if Holds (Of_Unit, Item, Place.Address)
                       and then Is_Address
                         (Of_Unit, Item, Place.Address)
                     then Variant_Field_Out_Of_Range
                     else Runtime_Address_Is_Not_Valid));
         end if;

         --  D126: the variant part may sit below that base field, and the
         --  walk down to it is the one Landin.IR owns.
         if not Path_Is_Valid (Of_Unit, Shape, Nested) then
            return Variant_Field_Is_Not_A_Variant;
         end if;
         Shape := Shape_At (Of_Unit, Shape, Nested);

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
         return Nothing_Wrong;
      end Variant_Shape_Of;

      --  D86 introduced this carrier for measurements; D87 uses the same
      --  target-neutral shape for datum and slot storage.  Prove every run
      --  and leaf before any accessor reads it, in every build mode.
      --  A run may hold a shape naming another run, and nothing in the
      --  vector proves that naming is acyclic, so the walk carries a
      --  budget: a well-formed nesting cannot be deeper than the number
      --  of shapes there are, and anything deeper is a cycle rather than
      --  a program.  D118 is what makes the walk recursive at all.
      function Field_Shape_Is_Malformed
        (Shape : Field_Shape;
         Aggregate_Allowed : Boolean := False;
         Budget : Natural := Natural'Last)
        return Boolean;

      function Shape_Needs_Recursive_Image
        (Shape : Field_Shape) return Boolean;

      function Item_Needs_Recursive_Image
        (Item : Item_Id) return Boolean;

      function Signature_Part_Is_Malformed
        (Part : Signature_Part) return Boolean;

      --  Called only after the shape walk has proved finite child runs.
      function Shape_Has_Callable (Shape : Field_Shape) return Boolean;

      function Shape_Has_Callable (Shape : Field_Shape) return Boolean is
      begin
         case Shape.Kind is
            when Scalar_Field_Shape =>
               return Shape.Signature /= No_Signature;
            when Array_Field_Shape =>
               return Shape.Length > 0
                 and then Shape_Has_Callable
                   (Array_Element_Shape (Of_Unit, Shape));
            when Aggregate_Field_Shape =>
               for Field in 1 .. Aggregate_Field_Count (Of_Unit, Shape) loop
                  if Shape_Has_Callable
                    (Nth_Aggregate_Field (Of_Unit, Shape, Field))
                  then
                     return True;
                  end if;
               end loop;
            when Variant_Field_Shape =>
               for Which in 1 .. Shape.Cases loop
                  for Field in
                    1 .. Variant_Case_Field_Count (Of_Unit, Shape, Which)
                  loop
                     if Shape_Has_Callable
                       (Nth_Variant_Case_Field (Of_Unit, Shape, Which, Field))
                     then
                        return True;
                     end if;
                  end loop;
               end loop;
         end case;
         return False;
      end Shape_Has_Callable;

      type Aggregate_Source_Kind is
        (No_Aggregate_Source, Nominal_Aggregate_Source,
         Item_Aggregate_Source, Slot_Aggregate_Source,
         Nested_Aggregate_Source);

      type Aggregate_Source is record
         Kind    : Aggregate_Source_Kind := No_Aggregate_Source;
         Item    : Item_Id := No_Item;
         Slot    : Slot_Id := No_Slot;
         Shape   : Field_Shape := (others => <>);
         Nominal : Nominal_Type_Id := No_Nominal_Type;
      end record;

      type Aggregate_Source_Array is
        array (Positive range <>) of Aggregate_Source;

      Canonical_Nominals : Aggregate_Source_Array
        (1 .. Positive'Max (1, Nominal_Type_Count (Of_Unit))) :=
          [others => (others => <>)];

      function Source_Field_Count
        (Source : Aggregate_Source) return Natural;

      function Nth_Source_Field
        (Source : Aggregate_Source; Field : Positive) return Field_Shape;

      function Sources_Agree
        (Left, Right : Aggregate_Source) return Boolean;

      function Register (Source : Aggregate_Source) return Fault_Kind;

      function Register_Shape
        (Shape : Field_Shape;
         Budget : Natural) return Fault_Kind;

      function Signature_Carrier_Count
        (Signature : Signature_Id) return Natural;

      function Carrier_Kind (Part : Signature_Part)
        return Landin.Types.Type_Kind;

      function Atom_Metadata_Is_Subset
        (Left, Right : Atom_Set_Id) return Boolean;

      function Indirect_Fault
        (Item : Item_Id; Value : Value_Id) return Fault_Kind;
      function Pointer_Fault
        (Item : Item_Id; Value : Value_Id) return Fault_Kind;
      function Pointer_Provenance (Item : Item_Id) return Fault;

      --  A legacy array part has the default Element_Shape. Its Element
      --  fixes a scalar extent, or its Nominal names the canonical body
      --  checked independently below. No other child can use that fallback.
      function Part_Agrees_With_Slot
        (Item : Item_Id; Part : Signature_Part; Slot : Slot_Id)
         return Boolean;

      function Results_Agree_With_Slot
        (Item : Item_Id; Signature : Signature_Id; Slot : Slot_Id)
         return Boolean;

      --  Classification uses the registry, but verification must also read
      --  explicit occurrence runs: otherwise canonical lookup would hide a
      --  corrupt or contradictory body attached to the same nominal.
      function Local_Field_Count (Shape : Field_Shape) return Natural
        is (if Shape.Cases = 0
            then Aggregate_Field_Count (Of_Unit, Shape) else Shape.Cases);

      function Nth_Local_Field
        (Shape : Field_Shape; Field : Positive) return Field_Shape
        is (if Shape.Cases = 0
            then Nth_Aggregate_Field (Of_Unit, Shape, Field)
            else Of_Unit.Variant_Fields
              (Shape.Payloads_First + Field - 1));

      function Field_Shape_Is_Malformed
        (Shape : Field_Shape;
         Aggregate_Allowed : Boolean := False;
         Budget : Natural := Natural'Last)
        return Boolean
      is
         Left : constant Natural :=
           (if Budget = Natural'Last
            then Variant_Field_Shape_Count (Of_Unit)
              + Nominal_Type_Count (Of_Unit) + 1 else Budget);
      begin
         if Shape.Kind = Scalar_Field_Shape then
            return Shape.Nominal /= No_Nominal_Type
              or else Shape.Length /= 1
              or else Shape.Cases /= 0
              or else Shape.Payloads_First /= 0
              or else
                (Shape.Pointee /= No_Pointee
                 and then
                   (not Holds (Of_Unit, Shape.Pointee)
                    or else Shape.Element /= Landin.Types.Usize
                    or else Shape.Signature /= No_Signature
                    or else Shape.Atoms /= No_Atom_Set))
              or else
                (Shape.Signature /= No_Signature
                 and then
                   (Shape.Atoms /= No_Atom_Set
                    or else Shape.Element /= Landin.Types.Usize
                    or else not Holds (Of_Unit, Shape.Signature)
                    or else Signature_Has_Erased_Self
                      (Of_Unit, Shape.Signature)))
              or else
                (Shape.Atoms /= No_Atom_Set
                 and then
                   (Shape.Signature /= No_Signature
                    or else Shape.Element /= Landin.Types.U32
                    or else not Holds (Of_Unit, Shape.Atoms)));
         elsif Shape.Signature /= No_Signature
           or else Shape.Atoms /= No_Atom_Set
           or else Shape.Pointee /= No_Pointee
         then
            return True;
         elsif Shape.Kind = Array_Field_Shape then
            --  An explicit child may itself be scalar: callable and atom
            --  metadata cannot use the legacy inline scalar representation.
            if not Array_Element_Run_Is_Valid (Of_Unit, Shape) then
               return True;
            elsif Shape.Cases = 0 then
               return Shape.Nominal /= No_Nominal_Type;
            end if;
            declare
               Child : constant Field_Shape :=
                 Array_Element_Shape (Of_Unit, Shape);
            begin
               return Child.Kind = Variant_Field_Shape
                 or else Child.Nominal /= Shape.Nominal
                 or else Child.Element /= Shape.Element
                 or else Left = 0
                 or else Field_Shape_Is_Malformed
                   (Child, Aggregate_Allowed => True, Budget => Left - 1);
            end;
         elsif Shape.Kind = Aggregate_Field_Shape then
            if not Aggregate_Allowed
              or else not Holds (Of_Unit, Shape.Nominal)
              or else Shape.Length /= 1
              or else Shape.Element /= Landin.Types.Bool
              or else (Shape.Cases = 0 and then Shape.Payloads_First /= 0)
              or else (Shape.Cases > 0
                and then (Shape.Payloads_First = 0
                  or else Shape.Payloads_First
                    > Variant_Field_Shape_Count (Of_Unit)
                  or else Shape.Cases > Variant_Field_Shape_Count (Of_Unit)
                    - Shape.Payloads_First + 1))
              or else not Aggregate_Field_Run_Is_Valid (Of_Unit, Shape)
            then
               return True;
            end if;

            if Left = 0 then
               return True;
            end if;

            for Field in 1 .. Local_Field_Count (Shape) loop
               if Field_Shape_Is_Malformed
                    (Nth_Local_Field (Shape, Field),
                     Aggregate_Allowed => True,
                     Budget => Left - 1)
               then
                  return True;
               end if;
            end loop;

            return False;
         end if;

         if Shape.Nominal /= No_Nominal_Type
           or else Shape.Length /= 1
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

            if Left = 0 then
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
                  --  D120 admits an ordinary struct payload, which is the
                  --  same run and the same walk as an ordinary child's.  A
                  --  variant part inside a payload still has no carrier.
                  if Leaf.Kind = Variant_Field_Shape
                    or else Field_Shape_Is_Malformed
                      (Leaf,
                       Aggregate_Allowed => True,
                       Budget => Left - 1)
                  then
                     return True;
                  end if;
               end;
            end loop;
         end loop;

         return False;
      end Field_Shape_Is_Malformed;

      function Shape_Needs_Recursive_Image
        (Shape : Field_Shape) return Boolean
      is
      begin
         if Shape.Kind = Aggregate_Field_Shape then
            return True;
         elsif Shape.Kind = Array_Field_Shape
           and then Array_Element_Is_Aggregate (Of_Unit, Shape)
         then
            return True;
         elsif Shape.Kind = Variant_Field_Shape then
            for Variant_Case in 1 .. Shape.Cases loop
               for Payload in
                 1 .. Variant_Case_Field_Count
                        (Of_Unit, Shape, Variant_Case)
               loop
                  if Shape_Needs_Recursive_Image
                    (Nth_Variant_Case_Field
                       (Of_Unit, Shape, Variant_Case, Payload))
                  then
                     return True;
                  end if;
               end loop;
            end loop;
         end if;
         return False;
      end Shape_Needs_Recursive_Image;

      function Item_Needs_Recursive_Image
        (Item : Item_Id) return Boolean
      is
      begin
         for Field in 1 .. Field_Count (Of_Unit, Item) loop
            if Shape_Needs_Recursive_Image
              (Nth_Field_Shape (Of_Unit, Item, Field))
            then
               return True;
            end if;
         end loop;
         --  An inline scalar array may also use the recursive descriptor
         --  representation. Its spelling, not just its child kind, selects
         --  the walker; orphan descriptors are still rejected there.
         for Position in 1 .. Aggregate_Field_Image_Count (Of_Unit, Item) loop
            if Nth_Image_Descriptor (Of_Unit, Item, Position).Form
              = Element_Sequence
            then
               return True;
            end if;
         end loop;
         return False;
      end Item_Needs_Recursive_Image;

      function Signature_Part_Is_Malformed
        (Part : Signature_Part) return Boolean
      is
      begin
         if Part.Convention = Inout_Place
           and then (Part.Kind /= Landin.Types.Usize
             or else not Holds (Of_Unit, Part.Pointee))
         then
            return True;
         elsif Part.Pointee /= No_Pointee
           and then (Part.Kind /= Landin.Types.Usize
             or else Part.Atoms /= No_Atom_Set
             or else Part.Signature /= No_Signature
             or else not Holds (Of_Unit, Part.Pointee))
         then
            return True;
         end if;
         case Part.Kind is
            when Landin.Types.No_Value =>
               return True;
            when Landin.Types.Scalar_Name =>
               return Part.Nominal /= No_Nominal_Type
                 or else Part.Length /= 0
                 or else Part.Signature /= No_Signature
                 or else
                   (Part.Atoms /= No_Atom_Set
                    and then
                      (Part.Kind /= Landin.Types.U32
                       or else not Holds (Of_Unit, Part.Atoms)));
            when Landin.Types.Aggregate =>
               return not Holds (Of_Unit, Part.Nominal)
                 or else Part.Length /= 0
                 or else Part.Signature /= No_Signature
                 or else Part.Atoms /= No_Atom_Set;
            when Landin.Types.Fixed_Array =>
               return Field_Shape_Is_Malformed
                 (Part.Element_Shape, Aggregate_Allowed => True)
                 or else (Part.Nominal /= No_Nominal_Type
                         and then not Holds (Of_Unit, Part.Nominal))
                 or else (Part.Element_Shape /= Field_Shape'(others => <>)
                   and then (Part.Element_Shape.Element /= Part.Element
                     or else Part.Element_Shape.Nominal /= Part.Nominal))
                 or else Part.Signature /= No_Signature
                 or else Part.Atoms /= No_Atom_Set;
            when Landin.Types.Function_Value =>
               return Part.Nominal /= No_Nominal_Type
                 or else Part.Length /= 0
                 or else not Holds (Of_Unit, Part.Signature)
                 or else Signature_Has_Erased_Self (Of_Unit, Part.Signature)
                 or else Part.Atoms /= No_Atom_Set;
            when others =>
               return True;
         end case;
      end Signature_Part_Is_Malformed;

      --  Erasure is a derived descriptor, not a wildcard in ordinary
      --  signature or pointee equality. The builder copies every part;
      --  even unused part metadata must remain identical to that copy.
      function Dispatch_Agrees
        (Held : Evidence_Record; Provider : Evidence_Entry_Record)
         return Boolean;

      function Dispatch_Agrees
        (Held : Evidence_Record; Provider : Evidence_Entry_Record)
         return Boolean
      is
      begin
         if not Holds (Of_Unit, Provider.Signature)
           or else Signature_Has_Erased_Self (Of_Unit, Provider.Signature)
           or else not Holds (Of_Unit, Provider.Dispatch)
         then
            return False;
         elsif not Held.Erased then
            return Provider.Dispatch = Provider.Signature;
         elsif not Signature_Has_Erased_Self (Of_Unit, Provider.Dispatch) then
            return False;
         end if;
         declare
            Concrete : constant Signature_Record :=
              Of_Unit.Signatures (Positive (Provider.Signature));
            Dispatch : constant Signature_Record :=
              Of_Unit.Signatures (Positive (Provider.Dispatch));
         begin
            if Concrete.Parameters.Count = 0
              or else Concrete.Parameters.Count /= Dispatch.Parameters.Count
              or else Concrete.Results.Count /= Dispatch.Results.Count
              or else Concrete.Sources.Count /= Dispatch.Sources.Count
              or else Concrete.Errors /= Dispatch.Errors
              or else Concrete.C_ABI /= Dispatch.C_ABI
              or else Concrete.Variadic /= Dispatch.Variadic
            then
               return False;
            end if;
            for Index in 1 .. Concrete.Parameters.Count loop
               declare
                  Expected : Signature_Part := Nth_Signature_Parameter
                    (Of_Unit, Provider.Signature, Index);
               begin
                  if Index = 1 then
                     if Expected.Kind /= Landin.Types.Usize
                       or else Expected.Convention /= In_Value
                       or else not Holds (Of_Unit, Expected.Pointee)
                       or else not Same_Shape
                         (Of_Unit, Pointee_Shape (Of_Unit, Expected.Pointee),
                          Held.Represented)
                     then
                        return False;
                     end if;
                     Expected.Pointee := No_Pointee;
                  end if;
                  if Expected /= Nth_Signature_Parameter
                    (Of_Unit, Provider.Dispatch, Index)
                  then
                     return False;
                  end if;
               end;
            end loop;
            for Index in 1 .. Concrete.Results.Count loop
               if Nth_Signature_Result (Of_Unit, Provider.Signature, Index)
                 /= Nth_Signature_Result (Of_Unit, Provider.Dispatch, Index)
               then
                  return False;
               end if;
            end loop;
            for Index in 1 .. Concrete.Sources.Count loop
               if Of_Unit.Return_Sources (Concrete.Sources.First + Index)
                 /= Of_Unit.Return_Sources (Dispatch.Sources.First + Index)
               then
                  return False;
               end if;
            end loop;
         end;
         return True;
      end Dispatch_Agrees;

      --  Callable identities remain semantic types.  A function pointer
      --  crossing C names a fixed C prototype, never the Landin convention
      --  or a failure channel.  Every signature is checked independently
      --  after all of its runs have been proved, so callback cycles do not
      --  turn this predicate into recursive signature traversal.
      function Is_C_Callback (Signature : Signature_Id) return Boolean
        is (Holds (Of_Unit, Signature)
            and then Signature_Uses_C_ABI (Of_Unit, Signature)
            and then not Signature_Is_Variadic (Of_Unit, Signature)
            and then Signature_Errors (Of_Unit, Signature) = No_Atom_Set);

      function Is_C_Field
        (Shape : Field_Shape; Budget : Natural) return Boolean;

      function Is_C_Field
        (Shape : Field_Shape; Budget : Natural) return Boolean
      is
      begin
         if Budget = 0 or else Shape.Atoms /= No_Atom_Set then
            return False;
         end if;
         case Shape.Kind is
            when Scalar_Field_Shape =>
               return Shape.Signature = No_Signature
                 or else Is_C_Callback (Shape.Signature);
            when Array_Field_Shape =>
               return Shape.Length > 0
                 and then Is_C_Field
                   (Array_Element_Shape (Of_Unit, Shape), Budget - 1);
            when Aggregate_Field_Shape =>
               if not Has_Nominal_Shape (Of_Unit, Shape.Nominal)
                 or else not Has_C_Layout (Of_Unit, Shape.Nominal)
                 or else Aggregate_Field_Count (Of_Unit, Shape) = 0
               then
                  return False;
               end if;
               for Field in 1 .. Aggregate_Field_Count (Of_Unit, Shape) loop
                  if not Is_C_Field
                    (Nth_Aggregate_Field (Of_Unit, Shape, Field), Budget - 1)
                  then
                     return False;
                  end if;
               end loop;
               return True;
            when Variant_Field_Shape =>
               return False;
         end case;
      end Is_C_Field;

      function Is_C_Part (Part : Signature_Part) return Boolean;

      function Is_C_Part (Part : Signature_Part) return Boolean is
      begin
         if Part.Convention /= In_Value or else Part.Atoms /= No_Atom_Set then
            return False;
         end if;
         case Part.Kind is
            when Landin.Types.Scalar_Name =>
               return True;
            when Landin.Types.Function_Value =>
               return Is_C_Callback (Part.Signature);
            when Landin.Types.Aggregate =>
               return Has_Nominal_Shape (Of_Unit, Part.Nominal)
                 and then Has_C_Layout (Of_Unit, Part.Nominal)
                 and then Nominal_Field_Count (Of_Unit, Part.Nominal) > 0;
            when others =>
               return False;
         end case;
      end Is_C_Part;

      --  C aggregate carriers are addresses logically, but an arbitrary
      --  usize is not proof that the ABI may read or write a struct there.
      --  Saved actuals use typed address slots; direct operands retain the
      --  storage endpoint and subobject path checked by the normal walk.
      function Address_Has_Nominal
        (Item : Item_Id; Value : Value_Id; Nominal : Nominal_Type_Id)
         return Boolean;

      function Address_Has_Nominal
        (Item : Item_Id; Value : Value_Id; Nominal : Nominal_Type_Id)
         return Boolean
      is
         Shape : Field_Shape;
         Length : Element_Total;
         Bad : Fault_Kind;
      begin
         if Op_Of (Of_Unit, Item, Value) = Load then
            declare
               Slot : constant Slot_Id := Slot_Of (Of_Unit, Item, Value);
            begin
               return Is_Address (Of_Unit, Item, Slot)
                 and then Address_Shape (Of_Unit, Item, Slot).Kind
                   = Aggregate_Field_Shape
                 and then Address_Shape (Of_Unit, Item, Slot).Nominal
                   = Nominal;
            end;
         elsif Op_Of (Of_Unit, Item, Value) /= Storage_Address then
            return False;
         end if;
         declare
            Place : constant Storage :=
              Destination_Of (Of_Unit, Item, Value);
            Field : constant Natural :=
              Element_Field_Of (Of_Unit, Item, Value);
            Path : constant Path_Step_Array := Path_Of (Of_Unit, Item, Value);
         begin
            if Storage_Address_Has_Index (Of_Unit, Item, Value) then
               Bad := Shape_Of
                 (Item, Place, Field, Shape, Length, Nested => Path);
               return Bad = Nothing_Wrong
                 and then Shape.Kind = Aggregate_Field_Shape
                 and then Shape.Nominal = Nominal;
            elsif Field /= 0 or else Path'Length /= 0 then
               return Root_Shape_Of (Item, Place, Field, Shape)
                 and then Path_Is_Valid (Of_Unit, Shape, Path)
                 and then Shape_At (Of_Unit, Shape, Path).Kind
                   = Aggregate_Field_Shape
                 and then Shape_At (Of_Unit, Shape, Path).Nominal = Nominal;
            end if;
            case Place.Kind is
               when Module_Datum =>
                  return Result_Of (Of_Unit, Place.Datum)
                    = Landin.Types.Aggregate
                    and then Nominal_Of (Of_Unit, Place.Datum) = Nominal;
               when Frame_Slot =>
                  return Is_Aggregate (Of_Unit, Item, Place.Slot)
                    and then Nominal_Of (Of_Unit, Item, Place.Slot) = Nominal;
               when Runtime_Address =>
                  return Address_Shape (Of_Unit, Item, Place.Address).Kind
                    = Aggregate_Field_Shape
                    and then Address_Shape
                      (Of_Unit, Item, Place.Address).Nominal = Nominal;
            end case;
         end;
      end Address_Has_Nominal;

      function Source_Field_Count (Source : Aggregate_Source) return Natural
        is (case Source.Kind is
               when Nominal_Aggregate_Source =>
                  Nominal_Field_Count (Of_Unit, Source.Nominal),
               when Item_Aggregate_Source =>
                  Field_Count (Of_Unit, Source.Item),
               when Slot_Aggregate_Source =>
                  Slot_Field_Count (Of_Unit, Source.Item, Source.Slot),
               when Nested_Aggregate_Source =>
                  Local_Field_Count (Source.Shape),
               when No_Aggregate_Source => 0);

      function Nth_Source_Field
        (Source : Aggregate_Source; Field : Positive) return Field_Shape
        is (case Source.Kind is
               when Nominal_Aggregate_Source =>
                  Nth_Nominal_Field (Of_Unit, Source.Nominal, Field),
               when Item_Aggregate_Source =>
                  Nth_Field_Shape (Of_Unit, Source.Item, Field),
               when Slot_Aggregate_Source =>
                  Nth_Slot_Field_Shape
                    (Of_Unit, Source.Item, Source.Slot, Field),
               when Nested_Aggregate_Source =>
                  Nth_Local_Field (Source.Shape, Field),
               when No_Aggregate_Source => (others => <>));

      function Sources_Agree
        (Left, Right : Aggregate_Source) return Boolean
      is
      begin
         if Left.Nominal /= Right.Nominal
           or else Source_Field_Count (Left) /= Source_Field_Count (Right)
         then
            return False;
         end if;

         for Field in 1 .. Source_Field_Count (Left) loop
            if not Same_Shape
              (Of_Unit,
               Nth_Source_Field (Left, Field),
               Nth_Source_Field (Right, Field))
            then
               return False;
            end if;
         end loop;
         return True;
      end Sources_Agree;

      function Register (Source : Aggregate_Source) return Fault_Kind
      is
      begin
         if Source.Kind = No_Aggregate_Source
           or else not Holds (Of_Unit, Source.Nominal)
         then
            return Nominal_Metadata_Malformed;
         end if;

         --  Identities are opaque, so find the registry position through
         --  its public enumeration rather than recovering its representation.
         --  The scan is bounded by the unit's nominal count in every build.
         for Position in 1 .. Nominal_Type_Count (Of_Unit) loop
            if Nth_Nominal_Type (Of_Unit, Position) = Source.Nominal then
               if Canonical_Nominals (Position).Kind = No_Aggregate_Source
               then
                  Canonical_Nominals (Position) := Source;
               elsif not Sources_Agree
                 (Canonical_Nominals (Position), Source)
               then
                  return Nominal_Shape_Disagrees;
               end if;
               return Nothing_Wrong;
            end if;
         end loop;
         return Nominal_Metadata_Malformed;
      end Register;

      function Register_Shape
        (Shape : Field_Shape;
         Budget : Natural) return Fault_Kind
      is
         Bad : Fault_Kind;
      begin
         if Budget = 0 then
            return Field_Shape_Malformed;
         end if;

         case Shape.Kind is
            when Scalar_Field_Shape =>
               return Nothing_Wrong;

            when Array_Field_Shape =>
               if not Array_Element_Is_Aggregate (Of_Unit, Shape) then
                  return Nothing_Wrong;
               end if;
               return Register_Shape
                 (Array_Element_Shape (Of_Unit, Shape), Budget - 1);

            when Aggregate_Field_Shape =>
               Bad := Register
                 ((Kind    => Nested_Aggregate_Source,
                   Shape   => Shape,
                   Nominal => Shape.Nominal,
                   others  => <>));
               if Bad /= Nothing_Wrong then
                  return Bad;
               end if;
               for Field in 1 .. Local_Field_Count (Shape) loop
                  Bad := Register_Shape
                    (Nth_Local_Field (Shape, Field), Budget - 1);
                  if Bad /= Nothing_Wrong then
                     return Bad;
                  end if;
               end loop;
               return Nothing_Wrong;

            when Variant_Field_Shape =>
               for Which in 1 .. Shape.Cases loop
                  for Field in
                    1 .. Variant_Case_Field_Count (Of_Unit, Shape, Which)
                  loop
                     Bad := Register_Shape
                       (Nth_Variant_Case_Field
                          (Of_Unit, Shape, Which, Field),
                        Budget - 1);
                     if Bad /= Nothing_Wrong then
                        return Bad;
                     end if;
                  end loop;
               end loop;
               return Nothing_Wrong;
         end case;
      end Register_Shape;

      function Signature_Carrier_Count
        (Signature : Signature_Id) return Natural
        is (Signature_Parameter_Count (Of_Unit, Signature)
            + (if Signature_Result_Count (Of_Unit, Signature) > 1
               or else
                 (Signature_Result_Count (Of_Unit, Signature) = 1
                  and then Nth_Signature_Result
                    (Of_Unit, Signature, 1).Kind
                      in Landin.Types.Aggregate | Landin.Types.Fixed_Array)
               then 1 else 0));

      function Carrier_Kind (Part : Signature_Part)
        return Landin.Types.Type_Kind
        is (if Part.Kind = Landin.Types.Function_Value
            then Landin.Types.Usize else Part.Kind);

      function Function_Metadata_Agrees
        (Left, Right : Signature_Id) return Boolean
        is ((Left = No_Signature and then Right = No_Signature)
            or else
              (Holds (Of_Unit, Left)
               and then Holds (Of_Unit, Right)
               and then Signatures_Agree (Of_Unit, Left, Right)));

      function Image_Target_Agrees
        (Shape : Field_Shape; Target : Item_Id) return Boolean
        is (Shape.Kind = Scalar_Field_Shape
            and then Shape.Signature /= No_Signature
            and then Holds (Of_Unit, Target)
            and then Kind_Of (Of_Unit, Target) = Routine
            and then Holds (Of_Unit, Signature_Of (Of_Unit, Target))
            and then Signatures_Agree
              (Of_Unit, Shape.Signature,
               Signature_Of (Of_Unit, Target)));

      function Address_Image_Target_Agrees
        (Shape : Field_Shape; Target : Item_Id) return Boolean
        is (Shape.Kind = Scalar_Field_Shape
            and then Shape.Element = Landin.Types.Usize
            and then Shape.Signature = No_Signature
            and then Holds (Of_Unit, Target)
            and then Kind_Of (Of_Unit, Target) = Datum
            and then Result_Of (Of_Unit, Target)
              = Landin.Types.Fixed_Array
            and then Array_Element_Shape (Of_Unit, Target)
              = Field_Shape'(Element => Landin.Types.U8, others => <>)
            and then Is_Read_Only (Of_Unit, Target));

      function Atom_Metadata_Agrees
        (Left, Right : Atom_Set_Id) return Boolean
        is ((Left = No_Atom_Set and then Right = No_Atom_Set)
            or else
              (Holds (Of_Unit, Left)
               and then Holds (Of_Unit, Right)
               and then Atom_Sets_Agree (Of_Unit, Left, Right)));

      function Atom_Metadata_Is_Subset
        (Left, Right : Atom_Set_Id) return Boolean
      is
      begin
         if Left = No_Atom_Set or else Right = No_Atom_Set then
            return Left = Right;
         end if;
         if not Holds (Of_Unit, Left) or else not Holds (Of_Unit, Right) then
            return False;
         end if;
         for Index in 1 .. Atom_Count (Of_Unit, Left) loop
            if not Contains_Atom
              (Of_Unit, Right, Nth_Atom (Of_Unit, Left, Index))
            then
               return False;
            end if;
         end loop;
         return True;
      end Atom_Metadata_Is_Subset;

      function Address_Agrees
        (Item : Item_Id; Value : Value_Id; Shape : Field_Shape)
         return Boolean;

      function Indirect_Fault
        (Item : Item_Id; Value : Value_Id) return Fault_Kind
      is
         Op : constant Opcode := Op_Of (Of_Unit, Item, Value);
         Address : constant Value_Id :=
           Nth_Operand (Of_Unit, Item, Value, 1);
         Witness : constant Slot_Id :=
           Indirect_Address_Slot (Of_Unit, Item, Value);
         Scalar : constant Value_Id :=
           (if Op = Load_Indirect then Value
            else Nth_Operand (Of_Unit, Item, Value, 2));
      begin
         if Result_Of (Of_Unit, Item, Address) /= Landin.Types.Usize
           or else Result_Of (Of_Unit, Item, Scalar)
             not in Landin.Types.Scalar_Name
         then
            return Result_Disagrees;
         elsif Signature_Of (Of_Unit, Item, Address) /= No_Signature
           or else Atom_Set_Of (Of_Unit, Item, Address) /= No_Atom_Set
         then
            return Address_Value_Disagrees;
         elsif Witness = No_Slot then
            --  The legacy scalar reader has no callable type witness.  A
            --  corruption hook must not turn raw bytes into a typed callee.
            if Op = Load_Indirect
              and then Signature_Of (Of_Unit, Item, Value) /= No_Signature
            then
               return Function_Value_Signature_Disagrees;
            elsif Atom_Set_Of (Of_Unit, Item, Value) /= No_Atom_Set then
               return Atom_Metadata_Disagrees;
            end if;
            declare
               Shape : constant Field_Shape :=
                 (Element => Landin.Types.Scalar_Name
                    (Result_Of (Of_Unit, Item, Scalar)),
                  Signature => Signature_Of (Of_Unit, Item, Scalar),
                  Atoms => Atom_Set_Of (Of_Unit, Item, Scalar),
                  Pointee => Pointee_Of (Of_Unit, Item, Scalar), others => <>);
            begin
               if Pointee_Of (Of_Unit, Item, Address) /= No_Pointee then
                  if not Holds
                    (Of_Unit, Pointee_Of (Of_Unit, Item, Address))
                    or else not Same_Shape
                      (Of_Unit, Shape, Pointee_Shape
                         (Of_Unit, Pointee_Of (Of_Unit, Item, Address)))
                  then
                     return Address_Value_Disagrees;
                  end if;
               elsif Op_Of (Of_Unit, Item, Address) = Place_Address
                 or else (Op_Of (Of_Unit, Item, Address) = Load
                   and then Is_Address (Of_Unit, Item,
                     Slot_Of (Of_Unit, Item, Address)))
               then
                  if not Address_Agrees (Item, Address, Shape) then
                     return Address_Value_Disagrees;
                  end if;
               end if;
            end;
            return Nothing_Wrong;
         elsif not Holds (Of_Unit, Item, Witness)
           or else not Is_Address (Of_Unit, Item, Witness)
           or else Address_Shape (Of_Unit, Item, Witness).Kind
             /= Scalar_Field_Shape
         then
            return Runtime_Address_Is_Not_Valid;
         elsif Op_Of (Of_Unit, Item, Address) /= Load
           or else Slot_Of (Of_Unit, Item, Address) /= Witness
         then
            return Address_Value_Disagrees;
         end if;
         declare
            Shape : constant Field_Shape :=
              Address_Shape (Of_Unit, Item, Witness);
         begin
            if Result_Of (Of_Unit, Item, Scalar) /= Shape.Element then
               return Result_Disagrees;
            elsif not Function_Metadata_Agrees
              (Shape.Signature, Signature_Of (Of_Unit, Item, Scalar))
            then
               return Function_Value_Signature_Disagrees;
            elsif not Pointees_Agree
              (Of_Unit, Shape.Pointee, Pointee_Of (Of_Unit, Item, Scalar))
            then
               return Address_Value_Disagrees;
            elsif not Atom_Metadata_Agrees
              (Shape.Atoms, Atom_Set_Of (Of_Unit, Item, Scalar))
            then
               return Atom_Metadata_Disagrees;
            end if;
         end;
         return Nothing_Wrong;
      end Indirect_Fault;

      function Array_Part_Agrees
        (Part : Signature_Part; Child : Field_Shape) return Boolean
        is (Child.Element = Part.Element
            and then Child.Nominal = Part.Nominal
            and then
              (if Part.Element_Shape = Field_Shape'(others => <>)
               then Child.Kind = Aggregate_Field_Shape
                 or else Child = Field_Shape'
                   (Element => Part.Element, others => <>)
               else Same_Shape (Of_Unit, Child, Part.Element_Shape)));

      function Part_Agrees_With_Shape
        (Part : Signature_Part; Shape : Field_Shape) return Boolean
        is (case Part.Kind is
               when Landin.Types.Scalar_Name =>
                  Shape.Kind = Scalar_Field_Shape
                  and then Shape.Element = Part.Kind
                  and then Shape.Signature = No_Signature
                  and then Pointees_Agree
                    (Of_Unit, Part.Pointee, Shape.Pointee)
                  and then Atom_Metadata_Agrees (Part.Atoms, Shape.Atoms),
               when Landin.Types.Function_Value =>
                  Shape.Kind = Scalar_Field_Shape
                  and then Shape.Element = Landin.Types.Usize
                  and then Holds (Of_Unit, Shape.Signature)
                  and then Signatures_Agree
                    (Of_Unit, Part.Signature, Shape.Signature),
               when Landin.Types.Aggregate =>
                  Shape.Kind = Aggregate_Field_Shape
                  and then Shape.Nominal = Part.Nominal,
               when Landin.Types.Fixed_Array =>
                  Shape.Kind = Array_Field_Shape
                  and then Shape.Length = Part.Length
                  and then Array_Part_Agrees
                    (Part, Array_Element_Shape (Of_Unit, Shape)),
               when others => False);

      function Part_Agrees_With_Slot
        (Item : Item_Id; Part : Signature_Part; Slot : Slot_Id)
         return Boolean
        is (if Part.Convention = Inout_Place
            then Is_Address (Of_Unit, Item, Slot)
              and then Same_Shape
                (Of_Unit, Pointee_Shape (Of_Unit, Part.Pointee),
                 Address_Shape (Of_Unit, Item, Slot))
            else not Is_Address (Of_Unit, Item, Slot)
              and then (case Part.Kind is
               when Landin.Types.Scalar_Name =>
                  not Is_Aggregate (Of_Unit, Item, Slot)
                  and then not Is_Array (Of_Unit, Item, Slot)
                  and then Type_Of (Of_Unit, Item, Slot) = Part.Kind
                  and then Signature_Of (Of_Unit, Item, Slot) = No_Signature
                  and then Pointees_Agree
                    (Of_Unit, Part.Pointee, Pointee_Of (Of_Unit, Item, Slot))
                  and then Atom_Metadata_Agrees
                    (Part.Atoms, Atom_Set_Of (Of_Unit, Item, Slot)),
               when Landin.Types.Aggregate =>
                  Is_Aggregate (Of_Unit, Item, Slot)
                  and then Nominal_Of (Of_Unit, Item, Slot) = Part.Nominal,
               when Landin.Types.Fixed_Array =>
                  Is_Array (Of_Unit, Item, Slot)
                  and then Slot_Array_Length (Of_Unit, Item, Slot)
                             = Part.Length
                  and then Array_Part_Agrees
                    (Part, Slot_Array_Element_Shape (Of_Unit, Item, Slot)),
               when Landin.Types.Function_Value =>
                  not Is_Aggregate (Of_Unit, Item, Slot)
                  and then not Is_Array (Of_Unit, Item, Slot)
                  and then Type_Of (Of_Unit, Item, Slot)
                             = Landin.Types.Usize
                  and then Signature_Of (Of_Unit, Item, Slot)
                             /= No_Signature
                  and then Signatures_Agree
                    (Of_Unit, Part.Signature,
                     Signature_Of (Of_Unit, Item, Slot)),
               when others => False));

      function Results_Agree_With_Slot
        (Item : Item_Id; Signature : Signature_Id; Slot : Slot_Id)
         return Boolean
      is
         Count : constant Natural :=
           Signature_Result_Count (Of_Unit, Signature);
      begin
         if not Is_Aggregate (Of_Unit, Item, Slot)
           or else Slot_Field_Count (Of_Unit, Item, Slot) /= Count
         then
            return False;
         end if;
         for Index in 1 .. Count loop
            if not Part_Agrees_With_Shape
              (Nth_Signature_Result (Of_Unit, Signature, Index),
               Nth_Slot_Field_Shape (Of_Unit, Item, Slot, Index))
            then
               return False;
            end if;
         end loop;
         return True;
      end Results_Agree_With_Slot;

      function Address_Agrees
        (Item : Item_Id; Value : Value_Id; Shape : Field_Shape)
         return Boolean
      is
         Op : constant Opcode := Op_Of (Of_Unit, Item, Value);
         Child : Field_Shape;
         Count : Element_Total;
      begin
         case Op is
            when Load =>
               return Is_Address
                 (Of_Unit, Item, Slot_Of (Of_Unit, Item, Value))
                 and then Same_Shape
                   (Of_Unit, Shape, Address_Shape
                      (Of_Unit, Item, Slot_Of (Of_Unit, Item, Value)));
            when Pointer_Address =>
               return Holds (Of_Unit, Pointee_Of (Of_Unit, Item, Value))
                 and then Same_Shape
                   (Of_Unit, Shape, Pointee_Shape
                      (Of_Unit, Pointee_Of (Of_Unit, Item, Value)));
            when Slice_Address =>
               return Same_Shape
                 (Of_Unit, Shape, Slice_Element_Shape (Of_Unit, Item, Value));
            when Place_Address | Storage_Address =>
               if Op = Storage_Address
                 and then Storage_Address_Has_Index (Of_Unit, Item, Value)
               then
                  return Shape_Of
                    (Item, Destination_Of (Of_Unit, Item, Value),
                     Element_Field_Of (Of_Unit, Item, Value), Child, Count,
                     Nested => Path_Of (Of_Unit, Item, Value)) = Nothing_Wrong
                    and then Same_Shape (Of_Unit, Child, Shape);
               end if;
               return Stored_Shape_Agrees
                 (Item, Destination_Of (Of_Unit, Item, Value),
                  Element_Field_Of (Of_Unit, Item, Value),
                  Path_Of (Of_Unit, Item, Value), Shape);
            when others =>
               return False;
         end case;
      end Address_Agrees;

      --  Marked dispatch erases only self, not the storage addressed by a
      --  hidden result or another shaped parameter. Parameter zero denotes
      --  the hidden result. Nominal bodies and operand definitions have been
      --  verified before this walk; an anonymous result tuple instead keeps
      --  its actual field source. No synthetic shape is added to the unit.
      function Erased_Carrier_Agrees
        (Item      : Item_Id;
         Value     : Value_Id;
         Signature : Signature_Id;
         Parameter : Natural := 0) return Boolean;

      function Erased_Carrier_Agrees
        (Item      : Item_Id;
         Value     : Value_Id;
         Signature : Signature_Id;
         Parameter : Natural := 0) return Boolean
      is
         Op : constant Opcode := Op_Of (Of_Unit, Item, Value);
         Shape : Field_Shape;
         Fields : Aggregate_Source := (others => <>);
         Length : Element_Total;
      begin
         case Op is
            when Load =>
               if not Is_Address
                 (Of_Unit, Item, Slot_Of (Of_Unit, Item, Value))
               then
                  return False;
               end if;
               Shape := Address_Shape
                 (Of_Unit, Item, Slot_Of (Of_Unit, Item, Value));
            when Pointer_Address =>
               if not Holds (Of_Unit, Pointee_Of (Of_Unit, Item, Value)) then
                  return False;
               end if;
               Shape := Pointee_Shape
                 (Of_Unit, Pointee_Of (Of_Unit, Item, Value));
            when Slice_Address =>
               Shape := Slice_Element_Shape (Of_Unit, Item, Value);
            when Place_Address | Storage_Address =>
               declare
                  Place : constant Storage :=
                    Destination_Of (Of_Unit, Item, Value);
                  Field : constant Natural :=
                    Element_Field_Of (Of_Unit, Item, Value);
                  Path : constant Path_Step_Array :=
                    Path_Of (Of_Unit, Item, Value);
               begin
                  if Op = Storage_Address
                    and then Storage_Address_Has_Index (Of_Unit, Item, Value)
                  then
                     if Shape_Of
                       (Item, Place, Field, Shape, Length, Nested => Path)
                         /= Nothing_Wrong
                     then
                        return False;
                     end if;
                  elsif Field = 0 and then Path'Length = 0
                    and then Is_Whole_Aggregate (Item, Place)
                  then
                     case Place.Kind is
                        when Module_Datum =>
                           Fields :=
                             (Kind => Item_Aggregate_Source,
                              Item => Place.Datum,
                              Nominal => Nominal_Of (Of_Unit, Place.Datum),
                              others => <>);
                        when Frame_Slot =>
                           Fields :=
                             (Kind => Slot_Aggregate_Source,
                              Item => Item, Slot => Place.Slot,
                              Nominal => Nominal_Of
                                (Of_Unit, Item, Place.Slot), others => <>);
                        when Runtime_Address =>
                           Shape := Address_Shape
                             (Of_Unit, Item, Place.Address);
                     end case;
                     if Fields.Kind /= No_Aggregate_Source then
                        Shape := (Kind => Aggregate_Field_Shape,
                                  Nominal => Fields.Nominal, others => <>);
                     end if;
                  else
                     if not Root_Shape_Of (Item, Place, Field, Shape)
                       or else not Path_Is_Valid (Of_Unit, Shape, Path)
                     then
                        return False;
                     end if;
                     Shape := Shape_At (Of_Unit, Shape, Path);
                  end if;
               end;
            when others =>
               return False;
         end case;

         if Parameter > 0 then
            return Part_Agrees_With_Shape
              (Nth_Signature_Parameter (Of_Unit, Signature, Parameter), Shape);
         elsif Signature_Result_Count (Of_Unit, Signature) = 1 then
            return Part_Agrees_With_Shape
              (Nth_Signature_Result (Of_Unit, Signature, 1), Shape);
         end if;

         if Shape.Kind /= Aggregate_Field_Shape then
            return False;
         elsif Fields.Kind = No_Aggregate_Source then
            Fields := (Kind => Nested_Aggregate_Source, Shape => Shape,
                       Nominal => Shape.Nominal, others => <>);
         end if;
         if Source_Field_Count (Fields)
           /= Signature_Result_Count (Of_Unit, Signature)
         then
            return False;
         end if;
         for Index in 1 .. Source_Field_Count (Fields) loop
            if not Part_Agrees_With_Shape
              (Nth_Signature_Result (Of_Unit, Signature, Index),
               Nth_Source_Field (Fields, Index))
            then
               return False;
            end if;
         end loop;
         return True;
      end Erased_Carrier_Agrees;

      function Is_Erased_Function
        (Item : Item_Id; Value : Value_Id) return Boolean
        is (Holds (Of_Unit, Item, Value)
            and then Op_Of (Of_Unit, Item, Value) = Evidence_Function
            and then Holds (Of_Unit, Evidence_Of (Of_Unit, Item, Value))
            and then Evidence_Is_Erased
              (Of_Unit, Evidence_Of (Of_Unit, Item, Value)));

      --  An annotation cannot turn untyped bytes into a pointer. Storage and
      --  signatures supply load/call metadata; an addr supplies its actual
      --  place shape. Only checked integer construction introduces a new
      --  reached type without such a source. Zero denotes the optional empty
      --  representation, not a nonnull or dereferenceability promise.
      function Pointer_Fault
        (Item : Item_Id; Value : Value_Id) return Fault_Kind
      is
         Code : constant Instruction := Of_Unit.Code
           (Of_Unit.Items (Positive (Item)).Values.First + Positive (Value));
         Expected : constant Pointee_Id := Pointee_Of (Of_Unit, Item, Value);
         Source : Value_Id;
      begin
         if Code.Pointee /= No_Pointee
           and then (not Holds (Of_Unit, Code.Pointee)
             or else Code.Result /= Landin.Types.Usize
             or else Signature_Of (Of_Unit, Item, Value) /= No_Signature
             or else Atom_Set_Of (Of_Unit, Item, Value) /= No_Atom_Set
             or else not Pointees_Agree
               (Of_Unit, Code.Pointee, Expected))
         then
            return Address_Value_Disagrees;
         end if;
         if Code.Op = Pointer_Address then
            Source := Nth_Operand (Of_Unit, Item, Value, 1);
            if not Holds (Of_Unit, Expected)
              or else not Pointees_Agree
                (Of_Unit, Expected, Pointee_Of (Of_Unit, Item, Source))
            then
               return Address_Value_Disagrees;
            end if;
         end if;
         if Expected /= No_Pointee
           and then Code.Op not in Store | Store_Datum | Store_Field
             | Store_Element | Store_Variant_Field | Store_Indirect
         then
            case Code.Op is
               when Load =>
                  if Is_Address (Of_Unit, Item, Code.Slot)
                    and then not Address_Agrees
                      (Item, Value, Pointee_Shape (Of_Unit, Expected))
                  then
                     return Address_Value_Disagrees;
                  end if;
               when Load_Datum | Load_Field | Load_Element
                  | Load_Variant_Field | Call | Indirect_Call =>
                  null;
               when Load_Indirect =>
                  if Code.Slot = No_Slot then
                     return Address_Value_Disagrees;
                  end if;
               when Pointer_Address =>
                  null;
               when Place_Address | Storage_Address | Slice_Address =>
                  if not Address_Agrees
                    (Item, Value, Pointee_Shape (Of_Unit, Expected))
                  then
                     return Address_Value_Disagrees;
                  end if;
               when Range_Check =>
                  Source := Nth_Operand (Of_Unit, Item, Value, 1);
                  if not Pointees_Agree
                    (Of_Unit, Expected, Pointee_Of (Of_Unit, Item, Source))
                    and then
                      (Op_Of (Of_Unit, Item, Source) /= Conversion
                       or else Result_Of (Of_Unit, Item, Source)
                         /= Landin.Types.Usize
                       or else Result_Of (Of_Unit, Item,
                         Nth_Operand (Of_Unit, Item, Source, 1))
                           not in Landin.Types.Integer_Name
                       or else Code.Lower_Bound /= 1
                       or else Code.Upper_Bound < 1
                       or else (Check_Image and then Code.Upper_Bound
                         /= Landin.Types.Folded
                           (Landin.Targets.Maximum_Object_Size (Facts))))
                  then
                     return Address_Value_Disagrees;
                  end if;
               when Number =>
                  if Code.Number /= 0 or else Code.Negated then
                     return Address_Value_Disagrees;
                  end if;
               when others =>
                  return Address_Value_Disagrees;
            end case;
         end if;
         if Code.Op in Store | Store_Datum | Store_Field | Store_Element
           | Store_Variant_Field | Store_Indirect
           and then Expected /= No_Pointee
         then
            Source := Nth_Operand
              (Of_Unit, Item, Value,
               (if Code.Op in Store_Element | Store_Indirect then 2 else 1));
            if not Pointees_Agree
              (Of_Unit, Expected, Pointee_Of (Of_Unit, Item, Source))
            then
               return Address_Value_Disagrees;
            end if;
         elsif Code.Op = Leave and then Code.Args > 0
           and then Pointee_Of (Of_Unit, Item) /= No_Pointee
           and then not Pointees_Agree
             (Of_Unit, Pointee_Of (Of_Unit, Item), Pointee_Of
                (Of_Unit, Item, Nth_Operand (Of_Unit, Item, Value, 1)))
         then
            return Address_Value_Disagrees;
         end if;
         return Nothing_Wrong;
      end Pointer_Fault;

      --  This must analysis is limited to proof-carrying local addresses and
      --  source pointer scalars. It does not claim to initialise memory they
      --  point at, or repeat the source checker's aggregate/element analysis.
      --  Its bounds count source slots and blocks, never target elements.
      function Pointer_Provenance (Item : Item_Id) return Fault
      is
         Blocks : constant Natural := Block_Count (Of_Unit, Item);
         Slots : constant Natural := Slot_Count (Of_Unit, Item);
         type Slot_State is array (1 .. Slots) of Boolean;
         type Block_State is array (1 .. Blocks) of Slot_State;
         Entry_State : Slot_State := [others => False];
         Outputs : Block_State := [others => [others => True]];
         Inputs : Block_State := [others => [others => True]];
         Graph : constant Control_Flow.Graph :=
           Control_Flow.Make (Of_Unit, Item);
         Queue : array (1 .. Blocks) of Positive;
         Queued : array (1 .. Blocks) of Boolean := [others => False];
         Read_At, Write_At : Positive := 1;
         Pending : Natural := 0;

         procedure Enqueue (Block : Positive);

         procedure Enqueue (Block : Positive) is
         begin
            if not Queued (Block) then
               Queue (Write_At) := Block;
               Write_At := (if Write_At = Blocks then 1 else Write_At + 1);
               Pending := Pending + 1;
               Queued (Block) := True;
            end if;
         end Enqueue;

         function Tracked (Slot : Slot_Id) return Boolean
           is (Slot /= No_Slot
               and then (Is_Address (Of_Unit, Item, Slot)
                 or else Pointee_Of (Of_Unit, Item, Slot) /= No_Pointee));
      begin
         for P in 1 .. Parameter_Count (Of_Unit, Item) loop
            if Tracked (Nth_Parameter (Of_Unit, Item, P))
              and then not Holds (Of_Unit, Signature_Of (Of_Unit, Item))
            then
               return (Kind => Routine_Signature_Disagrees,
                       Item => Item, others => <>);
            end if;
            Entry_State (Positive (Nth_Parameter (Of_Unit, Item, P))) := True;
         end loop;
         for B in 1 .. Blocks loop
            if not Control_Flow.Is_Reachable (Graph, Block_Id (B)) then
               return (Kind => Block_Unreachable, Item => Item,
                       Block => Block_Id (B), others => <>);
            end if;
            Enqueue (B);
         end loop;
         while Pending > 0 loop
            declare
               B : constant Positive := Queue (Read_At);
               State : Slot_State :=
                 (if B = 1 then Entry_State else [others => True]);
               Edge : Natural := Control_Flow.First_Predecessor
                 (Graph, Block_Id (B));
            begin
               Read_At := (if Read_At = Blocks then 1 else Read_At + 1);
               Pending := Pending - 1;
               Queued (B) := False;
               if B /= 1 then
                  while Edge /= 0 loop
                     declare
                        Prior : constant Positive := Positive
                          (Control_Flow.Predecessor (Graph, Edge));
                     begin
                        for S in State'Range loop
                           State (S) := State (S) and Outputs (Prior) (S);
                        end loop;
                     end;
                     Edge := Control_Flow.Next_Predecessor (Graph, Edge);
                  end loop;
               end if;
               Inputs (B) := State;
               for P in 1 .. Length (Of_Unit, Item, Block_Id (B)) loop
                  declare
                     V : constant Value_Id := Nth_Value
                       (Of_Unit, Item, Block_Id (B), P);
                  begin
                     if Op_Of (Of_Unit, Item, V) = Store then
                        State (Positive (Slot_Of (Of_Unit, Item, V))) := True;
                     end if;
                  end;
               end loop;
               if State /= Outputs (B) then
                  Outputs (B) := State;
                  for Index in 1 .. 2 loop
                     declare
                        Next : constant Block_Id := Control_Flow.Successor
                          (Graph, Block_Id (B), Index);
                     begin
                        if Next /= No_Block then
                           Enqueue (Positive (Next));
                        end if;
                     end;
                  end loop;
               end if;
            end;
         end loop;
         for B in 1 .. Blocks loop
            declare
               State : Slot_State := Inputs (B);
               function Missing (Place : Storage) return Boolean
                 is (case Place.Kind is
                        when Runtime_Address =>
                          not Holds (Of_Unit, Item, Place.Address)
                          or else not Is_Address
                            (Of_Unit, Item, Place.Address)
                          or else not State (Positive (Place.Address)),
                        when Frame_Slot =>
                          Holds (Of_Unit, Item, Place.Slot)
                          and then Is_Address (Of_Unit, Item, Place.Slot),
                        when Module_Datum => False);
            begin
               for P in 1 .. Length (Of_Unit, Item, Block_Id (B)) loop
                  declare
                     V : constant Value_Id := Nth_Value
                       (Of_Unit, Item, Block_Id (B), P);
                     Code : constant Instruction := Of_Unit.Code
                       (Of_Unit.Items (Positive (Item)).Values.First
                        + Positive (V));
                     Bad : constant Fault_Kind := Pointer_Fault (Item, V);
                  begin
                     if Bad /= Nothing_Wrong then
                        return (Bad, Item, Block_Id (B), V);
                     elsif Missing (Code.Source) or else Missing
                       (Code.Destination)
                       or else (Code.Op in Load | Load_Field | Store_Field
                         | Load_Element | Store_Element | Load_Indirect
                         | Store_Indirect
                         and then Tracked (Code.Slot)
                         and then not State (Positive (Code.Slot)))
                     then
                        return (Address_Value_Disagrees,
                                Item, Block_Id (B), V);
                     end if;
                     if Code.Op = Store then
                        State (Positive (Code.Slot)) := True;
                     end if;
                  end;
               end loop;
            end;
         end loop;
         return Sound;
      end Pointer_Provenance;

   begin
      if not Is_Prepared (Of_Unit) then
         return (Kind => Unprepared_Unit, others => <>);
      end if;

      --  Prove storage bounds and references before shape accessors can
      --  consult incidental storage or routine entry parameters.  Contracts
      --  on those accessors are not a release-build validation boundary.
      for Which in 1 .. Item_Count (Of_Unit) loop
         declare
            Held : constant Item_Record := Of_Unit.Items (Which);
            Id : constant Item_Id := Item_Id (Which);
         begin
            if not Run_Fits (Held.Image, Natural (Of_Unit.Images.Length))
              or else not Run_Fits
                (Held.Aggregate_Images,
                 Natural (Of_Unit.Aggregate_Images.Length))
            then
               return (Kind => Item_Runs_Overlap, Item => Id, others => <>);
            end if;
            if not Run_Fits (Held.Slots, Natural (Of_Unit.Slots.Length))
              or else not Run_Fits
                (Held.Parameters, Natural (Of_Unit.Parameters.Length))
              or else not Run_Fits
                (Held.Blocks, Natural (Of_Unit.Blocks.Length))
              or else not Run_Fits
                (Held.Values, Natural (Of_Unit.Code.Length))
              or else not Run_Fits
                (Held.Fields, Natural (Of_Unit.Fields.Length))
            then
               return (Kind => Item_Runs_Overlap, Item => Id, others => <>);
            end if;
            if (not Held.Has_Image
                and then (Held.Image.Count /= 0
                  or else Held.Aggregate_Images.Count /= 0
                  or else Held.Repeated_Image or else Held.Slice_Image))
              or else (Held.Has_Image
                and then (Held.Kind /= Datum
                  or else Held.Result not in
                    Landin.Types.Aggregate | Landin.Types.Fixed_Array))
              or else (Held.Result /= Landin.Types.Aggregate
                and then Held.Fields.Count /= 0)
              or else (Held.Repeated_Image
                and then (Held.Result /= Landin.Types.Fixed_Array
                  or else Held.Aggregate_Images.Count /= 0
                  or else Held.Slice_Image
                  or else Held.Image.Count = 0
                  or else Element_Total (Held.Image.Count - 1)
                    >= Held.Length))
              or else (Held.Slice_Image
                and then (Held.Result /= Landin.Types.Fixed_Array
                  or else Held.Aggregate_Images.Count /= 0
                  or else Held.Image.Count /= 0))
            then
               return (Kind => Array_Image_Length_Disagrees,
                       Item => Id, others => <>);
            end if;
            for Index in 1 .. Held.Parameters.Count loop
               declare
                  Slot : constant Slot_Id :=
                    Of_Unit.Parameters (Held.Parameters.First + Index);
               begin
                  if not Holds (Of_Unit, Id, Slot) then
                     return (Kind => Slot_Out_Of_Range,
                             Item => Id, others => <>);
                  end if;
               end;
            end loop;
            if not Evidence_Bindings_Are_Valid (Of_Unit, Id) then
               return (Kind => Evidence_Entry_Signature_Disagrees,
                       Item => Id, others => <>);
            end if;
            for Index in 1 .. Held.Blocks.Count loop
               declare
                  Block : constant Block_Record :=
                    Of_Unit.Blocks (Held.Blocks.First + Index);
               begin
                  if not Run_Fits
                    ((First => Block.First_Value, Count => Block.Values),
                     Natural (Of_Unit.Code.Length))
                    or else (Block.Values > 0
                      and then (Block.First_Value < Held.Values.First
                        or else Block.First_Value - Held.Values.First
                          > Held.Values.Count
                        or else Block.Values > Held.Values.Count
                          - (Block.First_Value - Held.Values.First)))
                  then
                     return (Kind => Item_Runs_Overlap,
                             Item => Id, others => <>);
                  end if;
               end;
            end loop;
         end;
      end loop;
      for Slot of Of_Unit.Slots loop
         if not Run_Fits (Slot.Fields, Natural (Of_Unit.Slot_Fields.Length))
         then
            return (Kind => Item_Runs_Overlap, others => <>);
         end if;
      end loop;
      for Code of Of_Unit.Code loop
         if not Run_Fits
           ((First => Code.First_Arg, Count => Code.Args),
            Natural (Of_Unit.Operands.Length))
         then
            return (Kind => Operand_Runs_Overlap, others => <>);
         elsif not Run_Fits
           (Code.Variadic_Types, Natural (Of_Unit.Signature_Parts.Length))
         then
            return (Kind => Signature_Runs_Overlap, others => <>);
         elsif Code.Variadic_Types.Count /= 0 then
            --  The baseline transports promoted scalar actual kinds.  A
            --  descriptor run must not silently enable aggregate transport
            --  before lowering and the backend consume it together.
            return (Kind => Signature_Part_Malformed, others => <>);
         elsif not Run_Fits (Code.Nested, Natural (Of_Unit.Paths.Length))
           or else not Run_Fits
             (Code.Source_Nested, Natural (Of_Unit.Paths.Length))
           or else not Run_Fits
             (Code.Below_Element, Natural (Of_Unit.Paths.Length))
           or else not Run_Fits
             ((First => Code.First_Measurement_Field,
               Count => Code.Measurement_Field_Total),
              Natural (Of_Unit.Measurement_Fields.Length))
         then
            return (Kind => Field_Shape_Malformed, others => <>);
         end if;
      end loop;

      --  Canonical bodies can be reached from signature element shapes, so
      --  prove all registry runs before validating even the first signature.
      if Natural (Of_Unit.Nominal_Shapes.Length)
        /= Nominal_Type_Count (Of_Unit)
      then
         return (Kind => Nominal_Metadata_Malformed, others => <>);
      end if;
      for Position in 1 .. Nominal_Type_Count (Of_Unit) loop
         declare
            Nominal : constant Nominal_Type_Id :=
              Nth_Nominal_Type (Of_Unit, Position);
         begin
            if Has_Nominal_Shape (Of_Unit, Nominal)
              and then not Aggregate_Field_Run_Is_Valid
                (Of_Unit, (Kind => Aggregate_Field_Shape,
                           Nominal => Nominal, others => <>))
            then
               return (Kind => Nominal_Metadata_Malformed, others => <>);
            end if;
         end;
      end loop;

      --  [0630]/[0640]: sets partition one declaration-identity vector.
      --  Validate it before a signature, slot or instruction asks membership.
      declare
         Members : Natural := 0;
      begin
         for Which in 1 .. Atom_Set_Count (Of_Unit) loop
            declare
               Held : constant Atom_Set_Record := Of_Unit.Atom_Sets (Which);
            begin
               if Held.Members.Count = 0
                 or else Held.Members.First /= Members
                 or else Held.Members.First > Natural (Of_Unit.Atoms.Length)
                 or else Held.Members.Count
                   > Natural (Of_Unit.Atoms.Length) - Held.Members.First
               then
                  return (Kind => Atom_Set_Runs_Overlap, others => <>);
               end if;

               for Index in 1 .. Held.Members.Count loop
                  declare
                     Atom : constant Declaration_Id :=
                       Of_Unit.Atoms (Held.Members.First + Index);
                  begin
                     if Atom = No_Declaration
                       or else Natural (Atom) > Declaration_Limit (Of_Unit)
                     then
                        return (Kind => Atom_Set_Malformed, others => <>);
                     end if;
                     for Prior in 1 .. Index - 1 loop
                        if Of_Unit.Atoms (Held.Members.First + Prior) = Atom
                        then
                           return (Kind => Atom_Set_Malformed, others => <>);
                        end if;
                     end loop;
                  end;
               end loop;
               Members := Members + Held.Members.Count;
            end;
         end loop;
         if Members /= Natural (Of_Unit.Atoms.Length) then
            return (Kind => Atom_Set_Runs_Overlap, others => <>);
         end if;
      end;

      --  D117's descriptors partition one parameter vector.  Validate the
      --  runs and every semantic part before an item or instruction asks a
      --  descriptor any question.
      declare
         Parts : Natural := 0;
         Sources : Natural := 0;
      begin
         for Which in 1 .. Signature_Count (Of_Unit) loop
            declare
               Held : constant Signature_Record :=
                 Of_Unit.Signatures (Which);
            begin
               if Held.Errors /= No_Atom_Set
                 and then not Holds (Of_Unit, Held.Errors)
               then
                  return (Kind => Signature_Part_Malformed, others => <>);
               end if;
               if Held.Parameters.Count /= 0
                 and then Held.Parameters.First /= Parts
               then
                  return (Kind => Signature_Runs_Overlap, others => <>);
               end if;
               if Held.Parameters.First >
                    Natural (Of_Unit.Signature_Parts.Length)
                 or else Held.Parameters.Count
                    > Natural (Of_Unit.Signature_Parts.Length)
                        - Held.Parameters.First
               then
                  return (Kind => Signature_Runs_Overlap, others => <>);
               end if;
               for Index in 1 .. Held.Parameters.Count loop
                  if Signature_Part_Is_Malformed
                    (Of_Unit.Signature_Parts
                       (Held.Parameters.First + Index))
                  then
                     return
                       (Kind => Signature_Part_Malformed, others => <>);
                  end if;
               end loop;
               Parts := Parts + Held.Parameters.Count;

               if Held.Results.Count /= 0
                 and then Held.Results.First /= Parts
               then
                  return (Kind => Signature_Runs_Overlap, others => <>);
               end if;
               if Held.Results.First >
                    Natural (Of_Unit.Signature_Parts.Length)
                 or else Held.Results.Count
                    > Natural (Of_Unit.Signature_Parts.Length)
                        - Held.Results.First
               then
                  return (Kind => Signature_Runs_Overlap, others => <>);
               end if;
               for Index in 1 .. Held.Results.Count loop
                  if Signature_Part_Is_Malformed
                    (Of_Unit.Signature_Parts
                       (Held.Results.First + Index))
                  then
                     return
                       (Kind => Signature_Part_Malformed, others => <>);
                  end if;
               end loop;
               Parts := Parts + Held.Results.Count;

               if Held.Sources.Count /= 0
                 and then Held.Sources.First /= Sources
               then
                  return (Kind => Signature_Runs_Overlap, others => <>);
               end if;
               if Held.Sources.First > Natural (Of_Unit.Return_Sources.Length)
                 or else Held.Sources.Count
                   > Natural (Of_Unit.Return_Sources.Length)
                       - Held.Sources.First
               then
                  return (Kind => Signature_Runs_Overlap, others => <>);
               end if;
               for Index in 1 .. Held.Sources.Count loop
                  declare
                     Source : constant Return_Source_Association :=
                       Of_Unit.Return_Sources (Held.Sources.First + Index);
                  begin
                     if Source.Result > Held.Results.Count
                       or else Source.Parameter > Held.Parameters.Count
                     then
                        return
                          (Kind => Signature_Part_Malformed, others => <>);
                     end if;
                  end;
               end loop;
               Sources := Sources + Held.Sources.Count;
            end;
         end loop;
         if Parts /= Natural (Of_Unit.Signature_Parts.Length)
           or else Sources /= Natural (Of_Unit.Return_Sources.Length)
         then
            return (Kind => Signature_Runs_Overlap, others => <>);
         end if;
      end;

      --  Canonical nominal bodies exist independently of storage.  This
      --  includes imported-only types, which have no result or parameter
      --  slots from which a backend could recover an ABI classification.
      for Position in 1 .. Nominal_Type_Count (Of_Unit) loop
         declare
            Nominal : constant Nominal_Type_Id :=
              Nth_Nominal_Type (Of_Unit, Position);
         begin
            if Has_Nominal_Shape (Of_Unit, Nominal) then
               for Field in 1 .. Nominal_Field_Count (Of_Unit, Nominal) loop
                  if Field_Shape_Is_Malformed
                    (Nth_Nominal_Field (Of_Unit, Nominal, Field),
                     Aggregate_Allowed => True)
                  then
                     return (Kind => Field_Shape_Malformed, others => <>);
                  end if;
               end loop;
               Canonical_Nominals (Position) :=
                 (Kind => Nominal_Aggregate_Source,
                  Nominal => Nominal, others => <>);
            elsif Has_C_Layout (Of_Unit, Nominal) then
               return (Kind => Nominal_Metadata_Malformed, others => <>);
            end if;
         end;
      end loop;

      for Shape of Of_Unit.Pointees loop
         if Field_Shape_Is_Malformed (Shape, Aggregate_Allowed => True) then
            return (Kind => Field_Shape_Malformed, others => <>);
         end if;
      end loop;

      --  Callable/array recursion is structural, unlike a nominal identity
      --  in a signature part.  Prove its graph acyclic once, before equality
      --  is used by canonical registration, relocations or instructions.
      declare
         type Visit_State is (Unseen, Active, Complete);
         Seen : array (1 .. Signature_Count (Of_Unit)) of Visit_State :=
           [others => Unseen];

         Pointers : array (1 .. Pointee_Count (Of_Unit)) of Visit_State :=
           [others => Unseen];

         function Visit (Signature : Signature_Id) return Boolean;
         function Visit_Pointer (Pointee : Pointee_Id) return Boolean;
         function Visit_Shape (Shape : Field_Shape) return Boolean;
         function Visit_Part (Part : Signature_Part) return Boolean;

         function Visit_Shape (Shape : Field_Shape) return Boolean is
         begin
            case Shape.Kind is
               when Scalar_Field_Shape =>
                  return
                    (Shape.Signature = No_Signature
                     or else Visit (Shape.Signature))
                    and then Visit_Pointer (Shape.Pointee);
               when Array_Field_Shape =>
                  return Visit_Shape (Array_Element_Shape (Of_Unit, Shape));
               when Aggregate_Field_Shape =>
                  for Field in 1 .. Local_Field_Count (Shape) loop
                     if not Visit_Shape (Nth_Local_Field (Shape, Field)) then
                        return False;
                     end if;
                  end loop;
               when Variant_Field_Shape =>
                  for Which in 1 .. Shape.Cases loop
                     for Field in
                       1 .. Variant_Case_Field_Count (Of_Unit, Shape, Which)
                     loop
                        if not Visit_Shape
                          (Nth_Variant_Case_Field
                             (Of_Unit, Shape, Which, Field))
                        then
                           return False;
                        end if;
                     end loop;
                  end loop;
            end case;
            return True;
         end Visit_Shape;

         function Visit_Part (Part : Signature_Part) return Boolean
           is (Visit_Pointer (Part.Pointee)
               and then (case Part.Kind is
                  when Landin.Types.Function_Value => Visit (Part.Signature),
                  when Landin.Types.Fixed_Array =>
                     Visit_Shape (Part.Element_Shape),
                  when others => True));

         function Visit_Pointer (Pointee : Pointee_Id) return Boolean is
         begin
            if Pointee = No_Pointee then
               return True;
            elsif Pointers (Positive (Pointee)) = Active then
               return False;
            elsif Pointers (Positive (Pointee)) = Complete then
               return True;
            end if;
            Pointers (Positive (Pointee)) := Active;
            --  A nominal referent is an identity edge, not by-value layout.
            --  Its canonical fields were checked independently above.
            if Pointee_Shape (Of_Unit, Pointee).Kind
              /= Aggregate_Field_Shape
              and then not Visit_Shape (Pointee_Shape (Of_Unit, Pointee))
            then
               return False;
            end if;
            Pointers (Positive (Pointee)) := Complete;
            return True;
         end Visit_Pointer;

         function Visit (Signature : Signature_Id) return Boolean is
         begin
            if Seen (Positive (Signature)) = Active then
               return False;
            elsif Seen (Positive (Signature)) = Complete then
               return True;
            end if;
            Seen (Positive (Signature)) := Active;
            for Index in 1 .. Signature_Parameter_Count
              (Of_Unit, Signature)
            loop
               if not Visit_Part
                 (Nth_Signature_Parameter (Of_Unit, Signature, Index))
               then
                  return False;
               end if;
            end loop;
            for Index in 1 .. Signature_Result_Count (Of_Unit, Signature) loop
               if not Visit_Part
                 (Nth_Signature_Result (Of_Unit, Signature, Index))
               then
                  return False;
               end if;
            end loop;
            Seen (Positive (Signature)) := Complete;
            return True;
         end Visit;
      begin
         for Position in 1 .. Signature_Count (Of_Unit) loop
            if not Visit (Signature_Id (Position)) then
               return (Kind => Signature_Part_Malformed, others => <>);
            end if;
         end loop;
         for Position in 1 .. Pointee_Count (Of_Unit) loop
            if not Visit_Pointer (Pointee_Id (Position)) then
               return (Kind => Field_Shape_Malformed, others => <>);
            end if;
         end loop;
      end;

      for Slot of Of_Unit.Slots loop
         if Holds (Of_Unit, Slot.Signature)
           and then Signature_Has_Erased_Self (Of_Unit, Slot.Signature)
         then
            return (Kind => Erased_Dispatch_Malformed, others => <>);
         end if;
         if Slot.Pointee /= No_Pointee
           and then (not Holds (Of_Unit, Slot.Pointee)
             or else Slot.Of_Type /= Landin.Types.Usize
             or else Slot.Aggregate or else Slot.Array_Shape
             or else Slot.Addressed or else Slot.Signature /= No_Signature
             or else Slot.Atom_Set /= No_Atom_Set)
         then
            return (Kind => Address_Value_Disagrees, others => <>);
         end if;
      end loop;
      for Item of Of_Unit.Items loop
         if Holds (Of_Unit, Item.Signature)
           and then Signature_Has_Erased_Self (Of_Unit, Item.Signature)
         then
            return (Kind => Erased_Dispatch_Malformed, others => <>);
         end if;
         if Item.Pointee /= No_Pointee
           and then (not Holds (Of_Unit, Item.Pointee)
             or else Item.Result /= Landin.Types.Usize
             or else Item.Kind /= Datum
             or else Item.Signature /= No_Signature
             or else Item.Atom_Set /= No_Atom_Set)
         then
            return (Kind => Address_Value_Disagrees, others => <>);
         end if;
      end loop;

      for Position in 1 .. Nominal_Type_Count (Of_Unit) loop
         declare
            Nominal : constant Nominal_Type_Id :=
              Nth_Nominal_Type (Of_Unit, Position);
            Budget : constant Natural :=
              Variant_Field_Shape_Count (Of_Unit)
                + Nominal_Type_Count (Of_Unit) + 1;
            Bad : Fault_Kind;
         begin
            if Has_Nominal_Shape (Of_Unit, Nominal) then
               if Has_C_Layout (Of_Unit, Nominal)
                 and then Nominal_Field_Count (Of_Unit, Nominal) = 0
               then
                  return (Kind => Nominal_Metadata_Malformed, others => <>);
               end if;
               for Field in 1 .. Nominal_Field_Count (Of_Unit, Nominal) loop
                  declare
                     Shape : constant Field_Shape :=
                       Nth_Nominal_Field (Of_Unit, Nominal, Field);
                  begin
                     Bad := Register_Shape (Shape, Budget);
                     if Bad /= Nothing_Wrong then
                        return (Kind => Bad, others => <>);
                     elsif Has_C_Layout (Of_Unit, Nominal)
                       and then not Is_C_Field (Shape, Budget)
                     then
                        return (Kind => Nominal_Metadata_Malformed,
                                others => <>);
                     end if;
                  end;
               end loop;
            end if;
         end;
      end loop;

      --  Do this only after every signature run and canonical field tree
      --  is sound: a callback may name a signature later in the registry.
      for Position in 1 .. Signature_Count (Of_Unit) loop
         declare
            Signature : constant Signature_Id := Signature_Id (Position);
         begin
            if Signature_Has_Erased_Self (Of_Unit, Signature) then
               if Signature_Parameter_Count (Of_Unit, Signature) = 0 then
                  return (Kind => Erased_Dispatch_Malformed, others => <>);
               end if;
               declare
                  Self : constant Signature_Part :=
                    Nth_Signature_Parameter (Of_Unit, Signature, 1);
               begin
                  if Self.Kind /= Landin.Types.Usize
                    or else Self.Convention /= In_Value
                    or else Self.Pointee /= No_Pointee
                  then
                     return (Kind => Erased_Dispatch_Malformed, others => <>);
                  end if;
               end;
            end if;
            if Signature_Is_Variadic (Of_Unit, Signature)
              and then not Signature_Uses_C_ABI (Of_Unit, Signature)
            then
               return (Kind => Signature_Part_Malformed, others => <>);
            end if;
            if Signature_Uses_C_ABI (Of_Unit, Signature) then
               if Signature_Errors (Of_Unit, Signature) /= No_Atom_Set
                 or else Signature_Result_Count (Of_Unit, Signature) > 1
                 or else (Signature_Is_Variadic (Of_Unit, Signature)
                   and then Signature_Parameter_Count
                     (Of_Unit, Signature) = 0)
                 or else (Check_Image and then Landin.Targets.C_ABI_Of
                   (Facts) /= Landin.Targets.SysV_AMD64_LP64)
               then
                  return (Kind => Signature_Part_Malformed, others => <>);
               end if;
               for Index in 1 .. Signature_Parameter_Count
                 (Of_Unit, Signature)
               loop
                  if not Is_C_Part
                    (Nth_Signature_Parameter (Of_Unit, Signature, Index))
                  then
                     return (Kind => Signature_Part_Malformed, others => <>);
                  end if;
               end loop;
               for Index in 1 .. Signature_Result_Count (Of_Unit, Signature)
               loop
                  if not Is_C_Part
                    (Nth_Signature_Result (Of_Unit, Signature, Index))
                  then
                     return (Kind => Signature_Part_Malformed, others => <>);
                  end if;
               end loop;
            end if;
         end;
      end loop;

      --  R2.70 tables partition their direct-entry vector.  The represented
      --  shape is target-neutral; every code word names a routine carrying
      --  exactly the retained semantic signature.
      declare
         Entries : Natural := 0;
      begin
         for Which in 1 .. Evidence_Count (Of_Unit) loop
            declare
               Held : constant Evidence_Record := Of_Unit.Evidence (Which);
            begin
               if Field_Shape_Is_Malformed
                 (Held.Represented, Aggregate_Allowed => True)
               then
                  return (Kind => Field_Shape_Malformed, others => <>);
               elsif Held.Entries.Count /= 0
                 and then Held.Entries.First /= Entries
               then
                  return (Kind => Evidence_Entry_Out_Of_Range, others => <>);
               elsif Held.Entries.First
                       > Natural (Of_Unit.Evidence_Entries.Length)
                 or else Held.Entries.Count
                   > Natural (Of_Unit.Evidence_Entries.Length)
                       - Held.Entries.First
               then
                  return (Kind => Evidence_Entry_Out_Of_Range, others => <>);
               end if;
               for Which in 1 .. Held.Entries.Count loop
                  declare
                     Provider : constant Evidence_Entry_Record :=
                       Of_Unit.Evidence_Entries
                         (Held.Entries.First + Which);
                  begin
                     if not Holds (Of_Unit, Provider.Target)
                       or else Kind_Of (Of_Unit, Provider.Target) /= Routine
                     then
                        return (Kind => Callee_Is_Not_A_Routine,
                                others => <>);
                     elsif not Holds (Of_Unit, Provider.Signature)
                       or else not Holds
                         (Of_Unit, Signature_Of (Of_Unit, Provider.Target))
                       or else not Signatures_Agree
                         (Of_Unit, Provider.Signature,
                          Signature_Of (Of_Unit, Provider.Target))
                     then
                        return
                          (Kind => Evidence_Entry_Signature_Disagrees,
                           others => <>);
                     elsif not Dispatch_Agrees (Held, Provider) then
                        return (Kind => Erased_Dispatch_Malformed,
                                others => <>);
                     end if;
                  end;
               end loop;
               Entries := Entries + Held.Entries.Count;
            end;
         end loop;
         if Entries /= Natural (Of_Unit.Evidence_Entries.Length) then
            return (Kind => Evidence_Entry_Out_Of_Range, others => <>);
         end if;
      end;

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
            if Is_External (Of_Unit, Id)
              and then
                (Kind_Of (Of_Unit, Id) /= Routine
                 or else Block_Count (Of_Unit, Id) /= 0
                 or else Slot_Count (Of_Unit, Id) /= 0
                 or else Parameter_Count (Of_Unit, Id) /= 0
                 or else Result_Slot (Of_Unit, Id) /= No_Slot
                 or else not Holds (Of_Unit, Signature_Of (Of_Unit, Id))
                 or else not Signature_Uses_C_ABI
                   (Of_Unit, Signature_Of (Of_Unit, Id))
                 or else Link_Symbol (Of_Unit, Id)
                   = Landin.Source.Names.No_Name)
            then
               return (Kind => Routine_Signature_Disagrees,
                       Item => Id, others => <>);
            end if;
            if Link_Symbol (Of_Unit, Id) /= Landin.Source.Names.No_Name then
               if Kind_Of (Of_Unit, Id) /= Routine
                 or else not Holds (Of_Unit, Signature_Of (Of_Unit, Id))
               then
                  return (Kind => Routine_Signature_Disagrees,
                          Item => Id, others => <>);
               end if;
               for Prior in 1 .. Which - 1 loop
                  declare
                     Other : constant Item_Id := Item_Id (Prior);
                  begin
                     if Link_Symbol (Of_Unit, Other)
                          = Link_Symbol (Of_Unit, Id)
                       and then
                         ((not Is_External (Of_Unit, Id)
                           and then not Is_External (Of_Unit, Other))
                          or else not Signatures_Agree
                            (Of_Unit, Signature_Of (Of_Unit, Id),
                             Signature_Of (Of_Unit, Other)))
                     then
                        return (Kind => Routine_Signature_Disagrees,
                                Item => Id, others => <>);
                     end if;
                  end;
               end loop;
            end if;

            if Nominal_Of (Of_Unit, Id) /= No_Nominal_Type
              and then
                (Result_Of (Of_Unit, Id) /= Landin.Types.Aggregate
                 or else not Holds (Of_Unit, Nominal_Of (Of_Unit, Id))
                 or else
                   (Kind_Of (Of_Unit, Id) = Routine
                    and then Signature_Of (Of_Unit, Id) = No_Signature))
            then
               return (Kind => Nominal_Metadata_Malformed,
                       Item => Id, others => <>);
            end if;

            if Result_Of (Of_Unit, Id) = Landin.Types.Aggregate then
               for Field in 1 .. Field_Count (Of_Unit, Id) loop
                  declare
                     Shape : constant Field_Shape :=
                       Nth_Field_Shape (Of_Unit, Id, Field);
                  begin
                     if Field_Shape_Is_Malformed
                          (Shape, Aggregate_Allowed => True)
                     then
                        return (Kind => Field_Shape_Malformed,
                                Item => Id, others => <>);
                     end if;
                  end;
               end loop;
            elsif Result_Of (Of_Unit, Id) = Landin.Types.Fixed_Array
              and then
                (Field_Shape_Is_Malformed
                   (Whole_Array_Shape (Of_Unit, Id),
                    Aggregate_Allowed => True)
                 or else Field_Shape_Is_Malformed
                   (Array_Element_Shape (Of_Unit, Id),
                    Aggregate_Allowed => True)
                 or else not Same_Shape
                   (Of_Unit, Array_Element_Shape (Of_Unit, Id),
                    Array_Element_Shape
                      (Of_Unit, Whole_Array_Shape (Of_Unit, Id))))
            then
               return (Kind => Field_Shape_Malformed,
                       Item => Id, others => <>);
            end if;

            for Slot in 1 .. Slot_Count (Of_Unit, Id) loop
               if Nominal_Of (Of_Unit, Id, Slot_Id (Slot))
                    /= No_Nominal_Type
                 and then
                   (not Is_Aggregate (Of_Unit, Id, Slot_Id (Slot))
                    or else not Holds
                      (Of_Unit,
                       Nominal_Of (Of_Unit, Id, Slot_Id (Slot))))
               then
                  return (Kind => Nominal_Metadata_Malformed,
                          Item => Id, others => <>);
               end if;

               if Is_Address (Of_Unit, Id, Slot_Id (Slot))
                 and then
                   (Is_Aggregate (Of_Unit, Id, Slot_Id (Slot))
                    or else Is_Array (Of_Unit, Id, Slot_Id (Slot))
                    or else Type_Of (Of_Unit, Id, Slot_Id (Slot))
                              /= Landin.Types.Usize
                    or else Signature_Of (Of_Unit, Id, Slot_Id (Slot))
                              /= No_Signature
                    or else Atom_Set_Of (Of_Unit, Id, Slot_Id (Slot))
                              /= No_Atom_Set
                    or else Field_Shape_Is_Malformed
                      (Address_Shape (Of_Unit, Id, Slot_Id (Slot)),
                       Aggregate_Allowed => True))
               then
                  return (Kind => Runtime_Address_Is_Not_Valid,
                          Item => Id, others => <>);
               end if;

               if Is_Aggregate (Of_Unit, Id, Slot_Id (Slot)) then
                  for Field in
                    1 .. Slot_Field_Count (Of_Unit, Id, Slot_Id (Slot))
                  loop
                     declare
                        Shape : constant Field_Shape :=
                          Nth_Slot_Field_Shape
                            (Of_Unit, Id, Slot_Id (Slot), Field);
                     begin
                        if Field_Shape_Is_Malformed
                             (Shape, Aggregate_Allowed => True)
                        then
                           return (Kind => Field_Shape_Malformed,
                                   Item => Id, others => <>);
                        end if;
                     end;
                  end loop;
               elsif Is_Array (Of_Unit, Id, Slot_Id (Slot))
                 and then
                   (Field_Shape_Is_Malformed
                      (Whole_Slot_Array_Shape
                         (Of_Unit, Id, Slot_Id (Slot)),
                       Aggregate_Allowed => True)
                    or else Field_Shape_Is_Malformed
                      (Slot_Array_Element_Shape
                         (Of_Unit, Id, Slot_Id (Slot)),
                       Aggregate_Allowed => True)
                    or else not Same_Shape
                      (Of_Unit, Slot_Array_Element_Shape
                         (Of_Unit, Id, Slot_Id (Slot)),
                       Array_Element_Shape
                         (Of_Unit, Whole_Slot_Array_Shape
                            (Of_Unit, Id, Slot_Id (Slot)))))
               then
                  return (Kind => Field_Shape_Malformed,
                          Item => Id, others => <>);
               end if;

               declare
                  Signature : constant Signature_Id :=
                    Signature_Of (Of_Unit, Id, Slot_Id (Slot));
                  Atoms : constant Atom_Set_Id :=
                    Atom_Set_Of (Of_Unit, Id, Slot_Id (Slot));
               begin
                  if Signature /= No_Signature
                    and then
                      (not Holds (Of_Unit, Signature)
                       or else Is_Aggregate
                         (Of_Unit, Id, Slot_Id (Slot))
                       or else Is_Array (Of_Unit, Id, Slot_Id (Slot))
                       or else Type_Of (Of_Unit, Id, Slot_Id (Slot))
                                 /= Landin.Types.Usize)
                  then
                     return
                       (Kind =>
                          (if Holds (Of_Unit, Signature)
                           then Function_Value_Signature_Disagrees
                           else Signature_Out_Of_Range),
                        Item => Id, others => <>);
                  elsif Atoms /= No_Atom_Set
                    and then
                      (not Holds (Of_Unit, Atoms)
                       or else Signature /= No_Signature
                       or else Is_Aggregate
                         (Of_Unit, Id, Slot_Id (Slot))
                       or else Is_Array (Of_Unit, Id, Slot_Id (Slot))
                       or else Type_Of (Of_Unit, Id, Slot_Id (Slot))
                                 /= Landin.Types.U32)
                  then
                     return (Kind => Atom_Metadata_Disagrees,
                             Item => Id, others => <>);
                  end if;
               end;
            end loop;

            if Atom_Set_Of (Of_Unit, Id) /= No_Atom_Set
              and then
                (not Holds (Of_Unit, Atom_Set_Of (Of_Unit, Id))
                 or else Result_Of (Of_Unit, Id) /= Landin.Types.U32
                 or else
                   (Kind_Of (Of_Unit, Id) = Datum
                    and then Signature_Of (Of_Unit, Id) /= No_Signature))
            then
               return (Kind => Atom_Metadata_Disagrees,
                       Item => Id, others => <>);
            end if;

            if Kind_Of (Of_Unit, Id) = Datum
              and then (Signature_Of (Of_Unit, Id) /= No_Signature
                        or else Function_Target (Of_Unit, Id) /= No_Item)
            then
               declare
                  Signature : constant Signature_Id :=
                    Signature_Of (Of_Unit, Id);
                  Target : constant Item_Id := Function_Target (Of_Unit, Id);
               begin
                  if not Holds (Of_Unit, Signature) then
                     return (Kind => Signature_Out_Of_Range,
                             Item => Id, others => <>);
                  elsif Result_Of (Of_Unit, Id) /= Landin.Types.Usize
                    or else not Holds (Of_Unit, Target)
                    or else Kind_Of (Of_Unit, Target) /= Routine
                    or else Signature_Of (Of_Unit, Target) = No_Signature
                    or else not Signatures_Agree
                      (Of_Unit, Signature, Signature_Of (Of_Unit, Target))
                  then
                     return
                       (Kind => Function_Value_Signature_Disagrees,
                        Item => Id, others => <>);
                  end if;
               end;
            end if;

            if Address_Target (Of_Unit, Id) /= No_Item then
               declare
                  Target : constant Item_Id := Address_Target (Of_Unit, Id);
               begin
                  if Kind_Of (Of_Unit, Id) /= Datum
                    or else Result_Of (Of_Unit, Id) /= Landin.Types.Usize
                    or else Signature_Of (Of_Unit, Id) /= No_Signature
                    or else Function_Target (Of_Unit, Id) /= No_Item
                    or else not Holds (Of_Unit, Target)
                    or else Kind_Of (Of_Unit, Target) /= Datum
                    or else Result_Of (Of_Unit, Target)
                      /= Landin.Types.Fixed_Array
                    or else Array_Element (Of_Unit, Target)
                      /= Landin.Types.U8
                    or else not Is_Read_Only (Of_Unit, Target)
                  then
                     return (Kind => Address_Value_Disagrees,
                             Item => Id, others => <>);
                  end if;
               end;
            end if;

            if Kind_Of (Of_Unit, Id) = Routine
              and then Signature_Of (Of_Unit, Id) /= No_Signature
            then
               declare
                  Signature : constant Signature_Id :=
                    Signature_Of (Of_Unit, Id);
               begin
                  if not Holds (Of_Unit, Signature) then
                     return (Kind => Signature_Out_Of_Range,
                             Item => Id, others => <>);
                  end if;

                  if Signature_Is_Variadic (Of_Unit, Signature)
                    and then not Is_External (Of_Unit, Id)
                  then
                     return (Kind => Routine_Signature_Disagrees,
                             Item => Id, others => <>);
                  end if;

                  declare
                     Count : constant Natural :=
                       Signature_Result_Count (Of_Unit, Signature);
                     Result : constant Signature_Part :=
                       (if Count = 1
                        then Nth_Signature_Result
                          (Of_Unit, Signature, 1)
                        else (Kind => Landin.Types.No_Value, others => <>));
                     Hidden : constant Natural :=
                       (if Count > 1
                          or else
                            (Count = 1
                             and then Result.Kind in Landin.Types.Aggregate
                                                   | Landin.Types.Fixed_Array)
                        then 1 else 0);
                     Carrier : constant Landin.Types.Type_Kind :=
                       (if Count = 0 then Landin.Types.No_Value
                        elsif Count > 1 then Landin.Types.Aggregate
                        else Carrier_Kind (Result));
                  begin
                     if not Atom_Metadata_Agrees
                       (Atom_Set_Of (Of_Unit, Id),
                        (if Count = 1 then Result.Atoms else No_Atom_Set))
                     then
                        return (Kind => Atom_Metadata_Disagrees,
                                Item => Id, others => <>);
                     end if;

                     if Result_Of (Of_Unit, Id) /= Carrier
                       or else (not Is_External (Of_Unit, Id)
                         and then Parameter_Count (Of_Unit, Id)
                           /= Signature_Carrier_Count (Signature))
                       or else
                         (if Count = 1
                               and then Result.Kind = Landin.Types.Aggregate
                          then Nominal_Of (Of_Unit, Id) /= Result.Nominal
                          else Nominal_Of (Of_Unit, Id)
                                 /= No_Nominal_Type)
                     then
                        return (Kind => Routine_Signature_Disagrees,
                                Item => Id, others => <>);
                     end if;

                     if not Is_External (Of_Unit, Id)
                       and then
                         ((Count = 0
                         and then Result_Slot (Of_Unit, Id) /= No_Slot)
                       or else
                         (Count = 1
                          and then
                            (not Holds
                               (Of_Unit, Id, Result_Slot (Of_Unit, Id))
                             or else not Part_Agrees_With_Slot
                               (Id, Result,
                                Result_Slot (Of_Unit, Id))))
                       or else
                         (Count > 1
                          and then
                            (not Holds
                               (Of_Unit, Id, Result_Slot (Of_Unit, Id))
                             or else not Results_Agree_With_Slot
                               (Id, Signature,
                                Result_Slot (Of_Unit, Id)))))
                     then
                        return (Kind => Routine_Signature_Disagrees,
                                Item => Id, others => <>);
                     end if;

                     if not Is_External (Of_Unit, Id) and then Hidden = 1 then
                        declare
                           Slot : constant Slot_Id :=
                             Nth_Parameter (Of_Unit, Id, 1);
                        begin
                           if Is_Aggregate (Of_Unit, Id, Slot)
                             or else Is_Array (Of_Unit, Id, Slot)
                             or else Type_Of (Of_Unit, Id, Slot)
                                       /= Landin.Types.Usize
                           then
                              return
                                (Kind => Routine_Signature_Disagrees,
                                 Item => Id, others => <>);
                           end if;
                        end;
                     end if;

                     if not Is_External (Of_Unit, Id) then
                        for Index in
                          1 .. Signature_Parameter_Count
                                 (Of_Unit, Signature)
                        loop
                           if not Part_Agrees_With_Slot
                             (Id,
                              Nth_Signature_Parameter
                                (Of_Unit, Signature, Index),
                              Nth_Parameter
                                (Of_Unit, Id, Index + Hidden))
                           then
                              return
                                (Kind => Routine_Signature_Disagrees,
                                 Item => Id, others => <>);
                           end if;
                        end loop;
                     end if;
                  end;
               end;
            end if;
         end;
      end loop;

      --  Measurement runs are also structural aggregate occurrences.  Check
      --  every stored shape before the nominal-consistency walk indexes a
      --  nested run; orphaned shapes are harmless but may not be malformed.
      for Shape of Of_Unit.Measurement_Fields loop
         if Field_Shape_Is_Malformed
           (Shape, Aggregate_Allowed => True)
         then
            return (Kind => Field_Shape_Malformed, others => <>);
         end if;
      end loop;

      --  One target-neutral nominal identity denotes one structural field
      --  tree wherever it occurs.  Record the first root, then compare every
      --  item, slot, nested field, array element, checked address and
      --  measurement occurrence against it.  Same_Shape and Register_Shape
      --  carry bounds derived only from finite IR vectors; no target layout
      --  participates in identity.
      declare
         Bad : Fault_Kind;
         Budget : constant Natural :=
           Variant_Field_Shape_Count (Of_Unit)
             + Nominal_Type_Count (Of_Unit) + 1;
      begin
         for Which in 1 .. Item_Count (Of_Unit) loop
            declare
               Id : constant Item_Id := Item_Id (Which);
            begin
               if Nominal_Of (Of_Unit, Id) /= No_Nominal_Type
                 and then not Is_External (Of_Unit, Id)
               then
                  Bad :=
                    (if Kind_Of (Of_Unit, Id) = Datum
                     then Register
                       ((Kind    => Item_Aggregate_Source,
                         Item    => Id,
                         Nominal => Nominal_Of (Of_Unit, Id),
                         others  => <>))
                     else Register
                       ((Kind    => Slot_Aggregate_Source,
                         Item    => Id,
                         Slot    => Result_Slot (Of_Unit, Id),
                         Nominal => Nominal_Of (Of_Unit, Id),
                         others  => <>)));
                  if Bad /= Nothing_Wrong then
                     return (Kind => Bad, Item => Id, others => <>);
                  end if;
               end if;

               if Result_Of (Of_Unit, Id) = Landin.Types.Aggregate then
                  for Field in 1 .. Field_Count (Of_Unit, Id) loop
                     Bad := Register_Shape
                       (Nth_Field_Shape (Of_Unit, Id, Field), Budget);
                     if Bad /= Nothing_Wrong then
                        return (Kind => Bad, Item => Id, others => <>);
                     end if;
                  end loop;
               elsif Result_Of (Of_Unit, Id) = Landin.Types.Fixed_Array then
                  Bad := Register_Shape
                    (Array_Element_Shape (Of_Unit, Id), Budget);
                  if Bad /= Nothing_Wrong then
                     return (Kind => Bad, Item => Id, others => <>);
                  end if;
               end if;

               for Slot in 1 .. Slot_Count (Of_Unit, Id) loop
                  declare
                     Slot_Id_Value : constant Slot_Id := Slot_Id (Slot);
                  begin
                     if Nominal_Of (Of_Unit, Id, Slot_Id_Value)
                          /= No_Nominal_Type
                     then
                        Bad := Register
                          ((Kind    => Slot_Aggregate_Source,
                            Item    => Id,
                            Slot    => Slot_Id_Value,
                            Nominal =>
                              Nominal_Of (Of_Unit, Id, Slot_Id_Value),
                            others  => <>));
                        if Bad /= Nothing_Wrong then
                           return (Kind => Bad, Item => Id, others => <>);
                        end if;
                     end if;

                     if Is_Aggregate (Of_Unit, Id, Slot_Id_Value) then
                        for Field in
                          1 .. Slot_Field_Count
                                 (Of_Unit, Id, Slot_Id_Value)
                        loop
                           Bad := Register_Shape
                             (Nth_Slot_Field_Shape
                                (Of_Unit, Id, Slot_Id_Value, Field),
                              Budget);
                           if Bad /= Nothing_Wrong then
                              return
                                (Kind => Bad, Item => Id, others => <>);
                           end if;
                        end loop;
                     elsif Is_Array (Of_Unit, Id, Slot_Id_Value) then
                        Bad := Register_Shape
                          (Slot_Array_Element_Shape
                             (Of_Unit, Id, Slot_Id_Value),
                           Budget);
                        if Bad /= Nothing_Wrong then
                           return (Kind => Bad, Item => Id, others => <>);
                        end if;
                     elsif Is_Address (Of_Unit, Id, Slot_Id_Value) then
                        Bad := Register_Shape
                          (Address_Shape (Of_Unit, Id, Slot_Id_Value),
                           Budget);
                        if Bad /= Nothing_Wrong then
                           return (Kind => Bad, Item => Id, others => <>);
                        end if;
                     end if;
                  end;
               end loop;
            end;
         end loop;

         for Shape of Of_Unit.Pointees loop
            Bad := Register_Shape (Shape, Budget);
            if Bad /= Nothing_Wrong then
               return (Kind => Bad, others => <>);
            end if;
         end loop;
         for Shape of Of_Unit.Measurement_Fields loop
            Bad := Register_Shape (Shape, Budget);
            if Bad /= Nothing_Wrong then
               return (Kind => Bad, others => <>);
            end if;
         end loop;
      end;

      for Which in 1 .. Item_Count (Of_Unit) loop
         declare
            Id : constant Item_Id := Item_Id (Which);
            Is_Datum : constant Boolean := Kind_Of (Of_Unit, Id) = Datum;
            Blocks : constant Natural := Block_Count (Of_Unit, Id);
            Reached : array (1 .. Positive'Max (1, Blocks)) of Boolean :=
              [others => False];
         begin
            --  Read-only data needs a complete numeric text image.
            --  Recheck builder eligibility after every metadata mutation.
            if Is_Read_Only (Of_Unit, Id)
              and then
                (not Is_Datum
                 or else Result_Of (Of_Unit, Id) /= Landin.Types.Fixed_Array
                 or else not Has_Image (Of_Unit, Id)
                 or else Has_Slice_Image (Of_Unit, Id)
                 or else Array_Element (Of_Unit, Id)
                   not in Landin.Types.U8 | Landin.Types.U16)
            then
               return (Kind => Array_Image_Length_Disagrees,
                       Item => Id, others => <>);
            end if;

            if Blocks = 0 then
               if Is_External (Of_Unit, Id) then
                  goto Next_IR_Item;
               else
                  return (Kind => Item_Without_A_Block, Item => Id,
                          others => <>);
               end if;
            end if;

            if Open_Block (Of_Unit, Id) /= No_Block then
               return (Kind => Item_Still_Building, Item => Id,
                       others => <>);
            end if;

            if Has_Slice_Image (Of_Unit, Id) then
               declare
                  Source : constant Item_Id :=
                    Slice_Image_Source (Of_Unit, Id);
               begin
                  if Array_Length (Of_Unit, Id) /= 2
                    or else Array_Element_Shape (Of_Unit, Id)
                      /= Field_Shape'
                        (Element => Landin.Types.Usize, others => <>)
                    or else (Source = No_Item
                      and then (Slice_Image_Length (Of_Unit, Id) /= 0
                        or else Slice_Image_First (Of_Unit, Id) /= 0))
                    or else Field_Shape_Is_Malformed
                      (Slice_Image_Element (Of_Unit, Id),
                       Aggregate_Allowed => True)
                    or else
                      (Source /= No_Item
                       and then
                      (not Holds (Of_Unit, Source)
                       or else Kind_Of (Of_Unit, Source) /= Datum
                       or else Result_Of (Of_Unit, Source)
                         /= Landin.Types.Fixed_Array
                       or else not Same_Shape
                         (Of_Unit,
                          Slice_Image_Element (Of_Unit, Id),
                          Array_Element_Shape (Of_Unit, Source))
                       or else Slice_Image_First (Of_Unit, Id)
                         > Array_Length (Of_Unit, Source)
                       or else Slice_Image_Length (Of_Unit, Id)
                         > Array_Length (Of_Unit, Source)
                           - Slice_Image_First (Of_Unit, Id)))
                  then
                     return (Kind => Array_Image_Length_Disagrees,
                             Item => Id, others => <>);
                  end if;
               end;
            end if;

            if Result_Of (Of_Unit, Id) = Landin.Types.Fixed_Array
              and then Has_Image (Of_Unit, Id)
              and then not Has_Slice_Image (Of_Unit, Id)
              and then not Has_Recursive_Array_Image (Of_Unit, Id)
              and then Array_Element_Shape (Of_Unit, Id) /= Field_Shape'
                (Element => Array_Element (Of_Unit, Id), others => <>)
            then
               --  Numeric images have no place for a callable relocation
               --  or the immediate shape of a nested array/record.
               return (Kind => Array_Image_Length_Disagrees,
                       Item => Id, others => <>);
            end if;

            --  D24: an array item's image, when it has one, has one value
            --  per declared position.  A datum with no image is D10's zero
            --  storage and this check has nothing to say about it.
            if Result_Of (Of_Unit, Id) = Landin.Types.Fixed_Array
              and then Has_Image (Of_Unit, Id)
              and then not Has_Slice_Image (Of_Unit, Id)
              and then not Has_Recursive_Array_Image (Of_Unit, Id)
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
              and then not Has_Slice_Image (Of_Unit, Id)
              and then not Has_Recursive_Array_Image (Of_Unit, Id)
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
                        elsif Element in Landin.Types.Float_Name then
                           Fits := Held >= 0
                             and then Held <= Landin.Types.Folded
                               (2 ** Natural
                                  (Landin.Types.Float_Width
                                     (Landin.Types.Float_Name (Element)))
                                - 1);
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
                       < Field_Count (Of_Unit, Id)
            then
               return (Kind => Aggregate_Field_Image_Length_Disagrees,
                       Item => Id, others => <>);
            end if;

            --  D132 uses one recursively indexed descriptor run when an
            --  ordinary child occurs anywhere in the shape.  Selected and
            --  Nested reserve contiguous direct-child groups and those
            --  children may reserve later groups in turn.  Fold offsets and
            --  descriptor offsets are checked independently before either
            --  accessor is used, so a malformed recursive image is an IR
            --  fault in release builds rather than a failed contract.
            if Has_Recursive_Array_Image (Of_Unit, Id)
              or else (Result_Of (Of_Unit, Id) = Landin.Types.Aggregate
                and then Has_Image (Of_Unit, Id)
                and then Item_Needs_Recursive_Image (Id))
            then
               declare
                  Top_Count : constant Natural :=
                    Image_Root_Count (Of_Unit, Id);
                  Flat_Count : constant Natural := Field_Count (Of_Unit, Id);
                  Element_Count : constant Natural := Natural
                    (Image_Length (Of_Unit, Id)
                     - Element_Total (Flat_Count));
                  Descendant_Count : constant Natural :=
                    Aggregate_Field_Image_Count (Of_Unit, Id) - Top_Count;
                  Expected_Elements : Natural := 0;
                  Expected_Descendants : Natural := 0;

                  function Fits
                    (Held : Landin.Types.Folded;
                     Element : Landin.Types.Scalar_Name) return Boolean;

                  function Check_Field_Image
                    (Shape    : Field_Shape;
                     Image    : Aggregate_Field_Image;
                     Flat     : Landin.Types.Folded;
                     Top      : Boolean) return Fault_Kind;

                  function Fits
                    (Held : Landin.Types.Folded;
                     Element : Landin.Types.Scalar_Name) return Boolean
                  is (if Element = Landin.Types.Bool
                      then Held in 0 .. 1
                      elsif Element in Landin.Types.Float_Name
                      then Held >= 0
                        and then Held <= Landin.Types.Folded
                          (2 ** Natural
                             (Landin.Types.Float_Width
                                (Landin.Types.Float_Name (Element))) - 1)
                      else Landin.Types.Holds
                        (Held, Landin.Types.Integer_Name (Element), Facts));

                  function Check_Field_Image
                    (Shape    : Field_Shape;
                     Image    : Aggregate_Field_Image;
                     Flat     : Landin.Types.Folded;
                     Top      : Boolean) return Fault_Kind
                  is
                     Scalar_Value : constant Landin.Types.Folded :=
                       (if Top then Flat else Image.Value);
                  begin
                     case Shape.Kind is
                        when Scalar_Field_Shape =>
                           if Image.Offset /= Expected_Elements
                             or else Image.Form /= Absent
                             or else Image.Count /= 0
                             or else (Top and then Image.Value /= 0)
                             or else Image.Slice
                           then
                              return Aggregate_Field_Image_On_Scalar_Field;
                           elsif Shape.Signature /= No_Signature
                             and then
                               (Scalar_Value /= 0
                                or else not Image_Target_Agrees
                                  (Shape, Image.Target))
                           then
                              return Function_Value_Signature_Disagrees;
                           elsif Shape.Signature = No_Signature
                             and then Image.Target /= No_Item
                             and then (Scalar_Value /= 0
                               or else not Address_Image_Target_Agrees
                                 (Shape, Image.Target))
                           then
                              return Address_Value_Disagrees;
                           elsif Check_Image
                             and then Shape.Signature = No_Signature
                             and then Image.Target = No_Item
                             and then not Fits (Scalar_Value, Shape.Element)
                           then
                              return
                                (if Top
                                 then Aggregate_Image_Value_Does_Not_Fit
                                 else
                                   Aggregate_Field_Image_Value_Does_Not_Fit);
                           end if;
                           return Nothing_Wrong;

                        when Array_Field_Shape =>
                           if Image.Slice then
                              if Image.Offset /= Expected_Elements
                                or else Shape.Length /= 2
                                or else Array_Element_Shape (Of_Unit, Shape)
                                  /= Field_Shape'
                                    (Element => Landin.Types.Usize,
                                     others => <>)
                                or else Field_Shape_Is_Malformed
                                  (Image.Slice_Element,
                                   Aggregate_Allowed => True)
                                or else Image.Value < 0
                                or else (Image.Target = No_Item
                                  and then (Image.Value /= 0
                                    or else Image.Slice_First /= 0))
                                or else Image.Form /= Absent
                                or else Image.Count /= 0
                                or else (Top and then Flat /= 0)
                                or else
                                  (Image.Target /= No_Item
                                   and then
                                     (not Holds (Of_Unit, Image.Target)
                                      or else Kind_Of
                                        (Of_Unit, Image.Target) /= Datum
                                      or else Result_Of
                                        (Of_Unit, Image.Target)
                                          /= Landin.Types.Fixed_Array
                                      or else not Same_Shape
                                        (Of_Unit, Image.Slice_Element,
                                         Array_Element_Shape
                                           (Of_Unit, Image.Target))
                                      or else Image.Slice_First
                                        > Array_Length
                                          (Of_Unit, Image.Target)
                                      or else Landin.Types.Folded
                                        (Array_Length
                                           (Of_Unit, Image.Target)
                                         - Image.Slice_First) < Image.Value))
                              then
                                 return
                                   Aggregate_Field_Image_Length_Disagrees;
                              end if;
                              return Nothing_Wrong;
                           end if;
                           if Image.Form = Element_Sequence then
                              if Image.Offset /= Expected_Descendants
                                or else (Top and then Flat /= 0)
                                or else Image.Target /= No_Item
                                or else Image.Value < 0
                                or else Image.Value
                                  > Landin.Types.Folded (Shape.Length)
                                or else Expected_Descendants > Descendant_Count
                                or else Image.Count
                                  > Descendant_Count - Expected_Descendants
                                or else
                                  (if Image.Count = 0
                                   then Image.Value /= 0
                                     or else Shape.Length /= 0
                                   else Element_Total (Image.Count - 1)
                                     /= Shape.Length
                                       - Element_Total (Image.Value))
                              then
                                 return Field_Length_Fault;
                              end if;
                              declare
                                 First : constant Natural :=
                                   Expected_Descendants;
                                 Child : constant Field_Shape :=
                                   Array_Element_Shape (Of_Unit, Shape);
                              begin
                                 --  Reserve the whole immediate group before
                                 --  descending.  Offsets can never revisit an
                                 --  ancestor or overlap another child's run.
                                 Expected_Descendants :=
                                   Expected_Descendants + Image.Count;
                                 for Position in 1 .. Image.Count loop
                                    declare
                                       Child_Image : constant
                                         Aggregate_Field_Image :=
                                           Nth_Image_Descriptor
                                             (Of_Unit, Id,
                                              Top_Count + First + Position);
                                       Bad : constant Fault_Kind :=
                                         Check_Field_Image
                                           (Child, Child_Image,
                                            Child_Image.Value, False);
                                    begin
                                       if Bad /= Nothing_Wrong then
                                          return Bad;
                                       end if;
                                    end;
                                 end loop;
                              end;
                              return Nothing_Wrong;
                           end if;
                           if Image.Offset /= Expected_Elements
                             or else (Top and then Flat /= 0)
                             or else Image.Target /= No_Item
                             or else Expected_Elements > Element_Count
                             or else Image.Count
                               > Element_Count - Expected_Elements
                           then
                              return Aggregate_Field_Image_Length_Disagrees;
                           end if;

                           if Array_Element_Is_Aggregate (Of_Unit, Shape) then
                              if Image.Form /= Absent
                                or else Image.Count /= 0
                                or else Image.Value /= 0
                              then
                                 return Aggregate_Image_On_Array_Field;
                              elsif Shape_Has_Callable (Shape) then
                                 return Function_Value_Signature_Disagrees;
                              end if;
                              return Nothing_Wrong;
                           end if;

                           case Image.Form is
                              when Absent =>
                                 if Image.Count /= 0 or else Image.Value /= 0
                                 then
                                    return Field_Pattern_Fault;
                                 end if;
                              when Finite =>
                                 if Element_Total (Image.Count) /= Shape.Length
                                   or else Image.Value /= 0
                                 then
                                    return Field_Length_Fault;
                                 end if;
                              when Repeated =>
                                 if Image.Count /= 0 or else Image.Value = 0
                                 then
                                    return Field_Pattern_Fault;
                                 end if;
                              when Hybrid =>
                                 if Image.Count = 0
                                   or else Element_Total (Image.Count)
                                             >= Shape.Length
                                 then
                                    return Field_Pattern_Fault;
                                 end if;
                              when Selected | Nested | Element_Sequence =>
                                 return Aggregate_Image_On_Array_Field;
                           end case;

                           if Check_Image then
                              if Image.Form in Finite | Hybrid then
                                 for Position in 1 .. Image.Count loop
                                    if not Fits
                                      (Nth_Descriptor_Element
                                         (Of_Unit, Id, Image,
                                          Part_Position (Position)),
                                       Shape.Element)
                                    then
                                       return Field_Value_Fault;
                                    end if;
                                 end loop;
                              end if;
                              if Image.Form in Repeated | Hybrid
                                and then not Fits
                                  (Image.Value, Shape.Element)
                              then
                                 return Field_Value_Fault;
                              end if;
                           end if;
                           Expected_Elements :=
                             Expected_Elements + Image.Count;
                           return Nothing_Wrong;

                        when Aggregate_Field_Shape =>
                           if Image.Offset /= Expected_Descendants
                             or else (Top and then Flat /= 0)
                             or else Image.Value /= 0
                             or else Image.Target /= No_Item
                             or else Image.Slice
                           then
                              return Aggregate_Image_On_Aggregate_Field;
                           elsif Image.Form = Absent then
                              if Image.Count /= 0 then
                                 return Aggregate_Image_On_Aggregate_Field;
                              elsif Shape_Has_Callable (Shape) then
                                 return Function_Value_Signature_Disagrees;
                              end if;
                              return Nothing_Wrong;
                           elsif Image.Form /= Nested
                           then
                              return Aggregate_Image_On_Aggregate_Field;
                           end if;

                           declare
                              Count : constant Natural :=
                                Aggregate_Field_Count (Of_Unit, Shape);
                              First : constant Natural :=
                                Expected_Descendants;
                           begin
                              if Image.Count /= Count
                                or else Count
                                  > Descendant_Count - Expected_Descendants
                              then
                                 return
                                   Aggregate_Field_Image_Length_Disagrees;
                              end if;
                              Expected_Descendants :=
                                Expected_Descendants + Count;
                              for Child in 1 .. Count loop
                                 declare
                                    Child_Image : constant
                                      Aggregate_Field_Image :=
                                        Nth_Image_Descriptor
                                          (Of_Unit, Id,
                                           Top_Count + First + Child);
                                    Fault : constant Fault_Kind :=
                                      Check_Field_Image
                                        (Nth_Aggregate_Field
                                           (Of_Unit, Shape, Child),
                                         Child_Image, Child_Image.Value,
                                         False);
                                 begin
                                    if Fault /= Nothing_Wrong then
                                       return Fault;
                                    end if;
                                 end;
                              end loop;
                           end;
                           return Nothing_Wrong;

                        when Variant_Field_Shape =>
                           if Image.Offset /= Expected_Descendants
                             or else (Top and then Flat /= 0)
                             or else Image.Target /= No_Item
                             or else Image.Slice
                           then
                              return Aggregate_Image_On_Variant_Field;
                           elsif Image.Form = Absent then
                              if Image.Count /= 0 or else Image.Value /= 0
                              then
                                 return Aggregate_Image_On_Variant_Field;
                              end if;
                              return Nothing_Wrong;
                           elsif Image.Form /= Selected
                             or else Image.Value < 1
                             or else Image.Value
                               > Landin.Types.Folded (Shape.Cases)
                           then
                              return Aggregate_Image_On_Variant_Field;
                           end if;

                           declare
                              Selected : constant Positive :=
                                Positive (Image.Value);
                              Count : constant Natural :=
                                Variant_Case_Field_Count
                                  (Of_Unit, Shape, Selected);
                              First : constant Natural :=
                                Expected_Descendants;
                           begin
                              if not Variant_Case_Run_Is_Valid
                                (Of_Unit, Shape, Selected)
                                or else Image.Count /= Count
                                or else Count
                                  > Descendant_Count - Expected_Descendants
                              then
                                 return Aggregate_Image_On_Variant_Field;
                              end if;
                              Expected_Descendants :=
                                Expected_Descendants + Count;
                              for Payload in 1 .. Count loop
                                 declare
                                    Payload_Image : constant
                                      Aggregate_Field_Image :=
                                        Nth_Image_Descriptor
                                          (Of_Unit, Id,
                                           Top_Count + First + Payload);
                                    Fault : constant Fault_Kind :=
                                      Check_Field_Image
                                        (Nth_Variant_Case_Field
                                           (Of_Unit, Shape, Selected,
                                            Payload),
                                         Payload_Image,
                                         Payload_Image.Value, False);
                                 begin
                                    if Fault /= Nothing_Wrong then
                                       return Fault;
                                    end if;
                                 end;
                              end loop;
                           end;
                           return Nothing_Wrong;
                     end case;
                  end Check_Field_Image;
               begin
                  if Has_Recursive_Array_Image (Of_Unit, Id) then
                     declare
                        Bad : constant Fault_Kind := Check_Field_Image
                          (Whole_Array_Shape (Of_Unit, Id),
                           Array_Image_Of (Of_Unit, Id), 0, False);
                     begin
                        if Bad /= Nothing_Wrong then
                           return (Kind => Bad, Item => Id, others => <>);
                        end if;
                     end;
                  else
                     for Field in 1 .. Top_Count loop
                        declare
                           Bad : constant Fault_Kind := Check_Field_Image
                             (Nth_Field_Shape (Of_Unit, Id, Field),
                              Field_Image_Of (Of_Unit, Id, Field),
                              Nth_Field_Image (Of_Unit, Id, Field), True);
                        begin
                           if Bad /= Nothing_Wrong then
                              return (Kind => Bad, Item => Id, others => <>);
                           end if;
                        end;
                     end loop;
                  end if;

                  if Expected_Elements /= Element_Count
                    or else Expected_Descendants /= Descendant_Count
                  then
                     return
                       (Kind => Aggregate_Field_Image_Length_Disagrees,
                        Item => Id, others => <>);
                  end if;
               end;
            end if;

            if Result_Of (Of_Unit, Id) = Landin.Types.Aggregate
              and then Has_Image (Of_Unit, Id)
              and then Image_Length (Of_Unit, Id)
                       >= Element_Total (Field_Count (Of_Unit, Id))
              and then Aggregate_Field_Image_Count (Of_Unit, Id)
                       >= Field_Count (Of_Unit, Id)
              and then not Item_Needs_Recursive_Image (Id)
            then
               declare
                  Expected : Natural := 0;
                  Expected_Payloads : Natural := 0;
                  Elements : constant Natural :=
                    Natural
                      (Image_Length (Of_Unit, Id)
                       - Element_Total (Field_Count (Of_Unit, Id)));
                  Payloads : constant Natural :=
                    Aggregate_Field_Image_Count (Of_Unit, Id)
                    - Field_Count (Of_Unit, Id);
                  Run_Fault : constant Fault_Kind :=
                    Aggregate_Field_Image_Length_Disagrees;
                  Scalar_Fault : constant Fault_Kind :=
                    Aggregate_Field_Image_On_Scalar_Field;
                  Value_Fault : constant Fault_Kind :=
                    Aggregate_Image_Value_Does_Not_Fit;
                  Variant_Fault : constant Fault_Kind :=
                    Aggregate_Image_On_Variant_Field;
                  Function_Fault : constant Fault_Kind :=
                    Function_Value_Signature_Disagrees;

                  function Fits
                    (Held : Landin.Types.Folded;
                     Element : Landin.Types.Scalar_Name) return Boolean
                  is (if Element = Landin.Types.Bool
                      then Held in 0 .. 1
                      elsif Element in Landin.Types.Float_Name
                      then Held >= 0
                        and then Held <= Landin.Types.Folded
                          (2 ** Natural
                             (Landin.Types.Float_Width
                                (Landin.Types.Float_Name (Element))) - 1)
                      else Landin.Types.Holds
                        (Held, Landin.Types.Integer_Name (Element), Facts));
               begin
                  for Field in 1 .. Field_Count (Of_Unit, Id) loop
                     declare
                        Shape : constant Field_Shape :=
                          Nth_Field_Shape (Of_Unit, Id, Field);
                        Held : constant Landin.Types.Folded :=
                          Nth_Field_Image (Of_Unit, Id, Field);
                        Image : constant Aggregate_Field_Image :=
                          Field_Image_Of (Of_Unit, Id, Field);
                     begin
                        if Shape.Kind = Variant_Field_Shape then
                           if Held /= 0
                             or else Image.Target /= No_Item
                             or else Image.Offset /= Expected_Payloads
                           then
                              return
                                (Kind => Aggregate_Image_On_Variant_Field,
                                 Item => Id, others => <>);
                           elsif Image.Form = Absent then
                              if Image.Count /= 0 or else Image.Value /= 0
                              then
                                 return
                                   (Kind => Aggregate_Image_On_Variant_Field,
                                    Item => Id, others => <>);
                              end if;
                           elsif Image.Form = Selected then
                              if Image.Value < 1
                                or else Image.Value
                                  > Landin.Types.Folded (Shape.Cases)
                                or else not Variant_Case_Run_Is_Valid
                                  (Of_Unit, Shape,
                                   Positive (Image.Value))
                                or else Image.Count
                                  /= Variant_Case_Field_Count
                                    (Of_Unit, Shape,
                                     Positive (Image.Value))
                                or else Image.Count
                                  > Payloads - Expected_Payloads
                              then
                                 return
                                   (Kind => Aggregate_Image_On_Variant_Field,
                                    Item => Id, others => <>);
                              end if;

                              for Payload in 1 .. Image.Count loop
                                 declare
                                    Leaf : constant Field_Shape :=
                                      Nth_Variant_Case_Field
                                        (Of_Unit, Shape,
                                         Positive (Image.Value), Payload);
                                    Payload_Image : constant
                                      Aggregate_Field_Image :=
                                        Variant_Payload_Image_Of
                                          (Of_Unit, Id, Field, Payload);
                                 begin
                                    if Payload_Image.Offset /= Expected
                                      or else Expected > Elements
                                      or else Payload_Image.Count
                                        > Elements - Expected
                                    then
                                       return
                                         (Kind => Run_Fault,
                                          Item => Id, others => <>);
                                    elsif Leaf.Kind = Scalar_Field_Shape then
                                       if Payload_Image.Form /= Absent
                                         or else Payload_Image.Count /= 0
                                       then
                                          return
                                            (Kind => Scalar_Fault,
                                             Item => Id, others => <>);
                                       elsif Leaf.Signature /= No_Signature
                                         and then
                                           (Payload_Image.Value /= 0
                                            or else not Image_Target_Agrees
                                              (Leaf,
                                               Payload_Image.Target))
                                       then
                                          return
                                            (Kind => Function_Fault,
                                             Item => Id, others => <>);
                                       elsif Leaf.Signature = No_Signature
                                         and then
                                           Payload_Image.Target /= No_Item
                                         and then (Payload_Image.Value /= 0
                                           or else not
                                             Address_Image_Target_Agrees
                                               (Leaf, Payload_Image.Target))
                                       then
                                          return
                                            (Kind => Address_Value_Disagrees,
                                             Item => Id, others => <>);
                                       elsif Check_Image
                                         and then Leaf.Signature = No_Signature
                                         and then
                                           Payload_Image.Target = No_Item
                                         and then not Fits
                                           (Payload_Image.Value,
                                            Leaf.Element)
                                       then
                                          return
                                            (Kind => Value_Fault,
                                             Item => Id, others => <>);
                                       end if;
                                    elsif Leaf.Kind = Variant_Field_Shape then
                                       return
                                         (Kind => Field_Shape_Malformed,
                                          Item => Id, others => <>);
                                    else
                                       if Payload_Image.Target /= No_Item then
                                          return
                                            (Kind => Function_Fault,
                                             Item => Id, others => <>);
                                       end if;
                                       case Payload_Image.Form is
                                          when Absent =>
                                             if Payload_Image.Count /= 0
                                               or else
                                                 Payload_Image.Value /= 0
                                             then
                                                return
                                                  (Kind =>
                                                     Field_Pattern_Fault,
                                                   Item => Id, others => <>);
                                             end if;
                                          when Finite =>
                                             if Element_Total
                                                  (Payload_Image.Count)
                                                  /= Leaf.Length
                                               or else
                                                 Payload_Image.Value /= 0
                                             then
                                                return
                                                  (Kind =>
                                                     Field_Length_Fault,
                                                   Item => Id, others => <>);
                                             end if;
                                          when Repeated =>
                                             if Payload_Image.Count /= 0
                                               or else
                                                 Payload_Image.Value = 0
                                             then
                                                return
                                                  (Kind =>
                                                     Field_Pattern_Fault,
                                                   Item => Id, others => <>);
                                             end if;
                                          when Hybrid =>
                                             if Payload_Image.Count = 0
                                               or else Element_Total
                                                 (Payload_Image.Count)
                                                   >= Leaf.Length
                                             then
                                                return
                                                  (Kind =>
                                                     Field_Pattern_Fault,
                                                   Item => Id, others => <>);
                                             end if;
                                          when Selected | Nested
                                             | Element_Sequence =>
                                             return
                                               (Kind => Variant_Fault,
                                                Item => Id, others => <>);
                                       end case;

                                       if Check_Image then
                                          if Payload_Image.Form
                                               in Finite | Hybrid
                                          then
                                             for Position in
                                               1 .. Payload_Image.Count
                                             loop
                                                if not Fits
                                                  (Nth_Variant_Field_Element
                                                     (Of_Unit, Id, Field,
                                                      Payload,
                                                      Part_Position
                                                        (Position)),
                                                   Leaf.Element)
                                                then
                                                   return
                                                     (Kind =>
                                                        Field_Value_Fault,
                                                      Item => Id,
                                                      others => <>);
                                                end if;
                                             end loop;
                                          end if;

                                          if Payload_Image.Form
                                               in Repeated | Hybrid
                                            and then not Fits
                                              (Payload_Image.Value,
                                               Leaf.Element)
                                          then
                                             return
                                               (Kind => Field_Value_Fault,
                                                Item => Id, others => <>);
                                          end if;
                                       end if;

                                       Expected := Expected
                                         + Payload_Image.Count;
                                    end if;
                                 end;
                              end loop;
                              Expected_Payloads := Expected_Payloads
                                + Image.Count;
                           else
                              return
                                (Kind => Aggregate_Image_On_Variant_Field,
                                 Item => Id, others => <>);
                           end if;
                        elsif Shape.Kind = Scalar_Field_Shape then
                           if Image.Offset /= Expected
                             or else Image.Form /= Absent
                             or else Image.Count /= 0
                           then
                              return
                                (Kind =>
                                   Aggregate_Field_Image_On_Scalar_Field,
                                 Item => Id, others => <>);
                           elsif Shape.Signature /= No_Signature
                             and then
                               (Held /= 0
                                or else not Image_Target_Agrees
                                  (Shape, Image.Target))
                           then
                              return
                                (Kind => Function_Fault,
                                 Item => Id, others => <>);
                           elsif Shape.Signature = No_Signature
                             and then Image.Target /= No_Item
                             and then (Held /= 0
                               or else not Address_Image_Target_Agrees
                                 (Shape, Image.Target))
                           then
                              return
                                (Kind => Address_Value_Disagrees,
                                 Item => Id, others => <>);
                           elsif Check_Image
                             and then Shape.Signature = No_Signature
                             and then Image.Target = No_Item
                           then
                              if not Fits (Held, Shape.Element) then
                                 return
                                   (Kind =>
                                      Aggregate_Image_Value_Does_Not_Fit,
                                    Item => Id, others => <>);
                              end if;
                           end if;
                        else
                           if Image.Slice then
                              if Shape.Length /= 2
                                or else Array_Element_Shape (Of_Unit, Shape)
                                  /= Field_Shape'
                                    (Element => Landin.Types.Usize,
                                     others => <>)
                                or else Field_Shape_Is_Malformed
                                  (Image.Slice_Element,
                                   Aggregate_Allowed => True)
                                or else Image.Value < 0
                                or else (Image.Target = No_Item
                                  and then (Image.Value /= 0
                                    or else Image.Slice_First /= 0))
                                or else Image.Form /= Absent
                                or else Image.Count /= 0
                                or else Held /= 0
                                or else
                                  (Image.Target /= No_Item
                                   and then
                                     (not Holds (Of_Unit, Image.Target)
                                      or else Kind_Of
                                        (Of_Unit, Image.Target) /= Datum
                                      or else Result_Of
                                        (Of_Unit, Image.Target)
                                          /= Landin.Types.Fixed_Array
                                      or else not Same_Shape
                                        (Of_Unit, Image.Slice_Element,
                                         Array_Element_Shape
                                           (Of_Unit, Image.Target))
                                      or else Image.Slice_First
                                        > Array_Length
                                          (Of_Unit, Image.Target)
                                      or else Landin.Types.Folded
                                        (Array_Length
                                           (Of_Unit, Image.Target)
                                         - Image.Slice_First) < Image.Value))
                              then
                                 return
                                   (Kind => Field_Length_Fault,
                                    Item => Id, others => <>);
                              end if;
                           elsif Image.Target /= No_Item then
                              return
                                (Kind => Function_Fault,
                                 Item => Id, others => <>);
                           elsif Image.Offset /= Expected
                             or else Expected > Elements
                             or else Image.Count > Elements - Expected
                           then
                              return
                                (Kind =>
                                   Aggregate_Field_Image_Length_Disagrees,
                                 Item => Id, others => <>);
                           elsif Held /= 0 then
                              return
                                (Kind => Aggregate_Image_On_Array_Field,
                                 Item => Id, others => <>);
                           end if;

                           case Image.Form is
                              when Absent =>
                                 if not Image.Slice and then Image.Count /= 0
                                 then
                                    return
                                      (Kind => Field_Length_Fault,
                                       Item => Id, others => <>);
                                 elsif not Image.Slice
                                   and then Image.Value /= 0
                                 then
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
                              when Selected | Nested | Element_Sequence =>
                                 return
                                   (Kind => Aggregate_Image_On_Variant_Field,
                                    Item => Id, others => <>);
                           end case;

                           if Check_Image and then not Image.Slice then
                              if Image.Form in Finite | Hybrid then
                                 for Position in 1 .. Image.Count loop
                                    if not Fits
                                      (Nth_Field_Element
                                         (Of_Unit, Id, Field,
                                          Part_Position (Position)),
                                       Shape.Element)
                                    then
                                       return
                                         (Kind => Field_Value_Fault,
                                          Item => Id, others => <>);
                                    end if;
                                 end loop;
                              end if;

                              if Image.Form in Repeated | Hybrid
                                and then not Fits
                                  (Image.Value, Shape.Element)
                              then
                                 return
                                   (Kind => Field_Value_Fault,
                                    Item => Id, others => <>);
                              end if;
                           end if;

                           Expected := Expected + Image.Count;
                        end if;
                     end;
                  end loop;

                  if Expected /= Elements
                    or else Expected_Payloads /= Payloads
                  then
                     return
                       (Kind => Aggregate_Field_Image_Length_Disagrees,
                        Item => Id, others => <>);
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

                        --  D187: the flag says a check edge this
                        --  instruction would have carried is not emitted,
                        --  so it belongs only to an instruction that
                        --  carries one -- which its opcode alone does not
                        --  decide -- and never inside [1940]'s module
                        --  value, which executes nothing at all.
                        if Is_Unchecked (Of_Unit, Id, V)
                          and then (Is_Datum
                                    or else not Check_Is_Removable
                                                  (Of_Unit, Id, V))
                        then
                           return (Kind => Unchecked_Not_Removable,
                                   Item => Id, Block => Block, Value => V);
                        end if;

                        --  Step one: what a later step indexes.  A
                        --  callee, a slot, a datum or a target that does
                        --  not exist has to be caught before anything
                        --  asks it a question.
                        case Op is
                           when Atom =>
                              if not Holds
                                (Of_Unit, Atom_Set_Of (Of_Unit, Id, V))
                              then
                                 return (Kind => Atom_Metadata_Disagrees,
                                         Item => Id, Block => Block,
                                         Value => V);
                              elsif not Contains_Atom
                                (Of_Unit, Atom_Set_Of (Of_Unit, Id, V),
                                 Atom_Of (Of_Unit, Id, V))
                              then
                                 return (Kind => Atom_Identity_Not_In_Set,
                                         Item => Id, Block => Block,
                                         Value => V);
                              end if;

                           when Place_Address =>
                              declare
                                 Place : constant Storage :=
                                   Destination_Of (Of_Unit, Id, V);
                              begin
                                 case Place.Kind is
                                    when Module_Datum =>
                                       if not Holds (Of_Unit, Place.Datum)
                                         or else Kind_Of
                                           (Of_Unit, Place.Datum) /= Datum
                                       then
                                          return
                                            (Kind => Named_Item_Is_Not_A_Datum,
                                             Item => Id, Block => Block,
                                             Value => V);
                                       end if;
                                    when Frame_Slot =>
                                       if not Holds (Of_Unit, Id, Place.Slot)
                                       then
                                          return
                                            (Kind => Slot_Out_Of_Range,
                                             Item => Id, Block => Block,
                                             Value => V);
                                       end if;
                                    when Runtime_Address =>
                                       if not Holds
                                         (Of_Unit, Id, Place.Address)
                                         or else not Is_Address
                                           (Of_Unit, Id, Place.Address)
                                       then
                                          return
                                            (Kind =>
                                               Runtime_Address_Is_Not_Valid,
                                             Item => Id, Block => Block,
                                             Value => V);
                                       end if;
                                 end case;
                              end;

                           when Storage_Address =>
                              declare
                                 Place : constant Storage :=
                                   Destination_Of (Of_Unit, Id, V);
                                 Field : constant Natural :=
                                   Element_Field_Of (Of_Unit, Id, V);
                                 Nested : constant Path_Step_Array :=
                                   Path_Of (Of_Unit, Id, V);
                                 Element : Field_Shape;
                                 Length : Element_Total;
                                 Bad : Fault_Kind := Nothing_Wrong;
                              begin
                                 if Is_Datum then
                                    if Place.Kind = Module_Datum
                                      and then Field = 0
                                      and then Nested'Length = 0
                                      and then not Storage_Address_Has_Index
                                        (Of_Unit, Id, V)
                                      and then Address_Target (Of_Unit, Id)
                                                   = Place.Datum
                                    then
                                       --  D181: the instruction and static
                                       --  cstring relocation describe the
                                       --  same pooled read-only byte datum.
                                       null;
                                    else
                                       Bad :=
                                         Storage_Address_Is_Not_An_Aggregate;
                                    end if;
                                 elsif Storage_Address_Has_Index
                                   (Of_Unit, Id, V)
                                 then
                                    Bad := Shape_Of
                                      (Id, Place, Field, Element, Length,
                                       Nested => Nested);
                                 elsif Field = 0 then
                                    if not Is_Whole_Aggregate (Id, Place)
                                      and then not Is_Whole_Array (Id, Place)
                                    then
                                       Bad :=
                                         Storage_Address_Is_Not_An_Aggregate;
                                    end if;
                                 elsif Is_Whole_Aggregate_Field
                                   (Id, Place, Field, Nested)
                                 then
                                    null;
                                 else
                                    Bad := Shape_Of
                                      (Id, Place, Field, Element, Length,
                                       Nested => Nested);
                                 end if;

                                 if Bad /= Nothing_Wrong then
                                    return (Kind => Bad, Item => Id,
                                            Block => Block, Value => V);
                                 end if;
                              end;

                           when Slice_Address | Empty_Slice_Base | Conversion
                              | Range_Check
                              | Pointer_Address | Load_Indirect
                              | Store_Indirect =>
                              null;

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

                                    if not Is_Address
                                      (Of_Unit, Id, Cell)
                                      and then
                                        ((not Is_Aggregate
                                            (Of_Unit, Id, Cell)
                                          and then not Is_Array
                                            (Of_Unit, Id, Cell))
                                         or else Element_Total
                                           (Field_Of (Of_Unit, Id, V))
                                             > Slot_Part_Count
                                               (Of_Unit, Id, Cell))
                                    then
                                       return (Kind => Field_Out_Of_Range,
                                               Item => Id, Block => Block,
                                               Value => V);
                                    end if;

                                    declare
                                       Place : constant Storage :=
                                         (if Is_Address (Of_Unit, Id, Cell)
                                          then (Kind => Runtime_Address,
                                                Address => Cell)
                                          else (Kind => Frame_Slot,
                                                Slot => Cell));
                                       Element : Landin.Types.Scalar_Name;
                                       Bad : constant Fault_Kind :=
                                         Scalar_Field_Of
                                           (Id, Place,
                                            Field_Of (Of_Unit, Id, V),
                                            Path_Of
                                              (Of_Unit, Id, V),
                                            Element);
                                    begin
                                       if Bad /= Nothing_Wrong then
                                          return
                                            (Kind => Bad, Item => Id,
                                             Block => Block, Value => V);
                                       end if;
                                       if Op = Load_Field
                                         and then Result_Of (Of_Unit, Id, V)
                                                    /= Element
                                       then
                                          return
                                            (Kind => Result_Disagrees,
                                             Item => Id, Block => Block,
                                             Value => V);
                                       end if;
                                       if Op = Load_Field then
                                          declare
                                             Expected : constant
                                               Signature_Id :=
                                               Scalar_Field_Signature
                                                 (Id, Place,
                                                  Field_Of (Of_Unit, Id, V),
                                                  Path_Of (Of_Unit, Id, V));
                                             Actual : constant Signature_Id :=
                                               Signature_Of
                                                 (Of_Unit, Id, V);
                                             Expected_Atoms : constant
                                               Atom_Set_Id :=
                                               Scalar_Field_Atoms
                                                 (Id, Place,
                                                  Field_Of (Of_Unit, Id, V),
                                                  Path_Of (Of_Unit, Id, V));
                                          begin
                                             if (Expected = No_Signature)
                                                  /= (Actual = No_Signature)
                                               or else
                                                 (Expected /= No_Signature
                                                  and then
                                                    (not Holds
                                                       (Of_Unit, Actual)
                                                     or else not
                                                       Signatures_Agree
                                                         (Of_Unit, Expected,
                                                          Actual)))
                                             then
                                                return
                                                  (Kind => Signature_Mismatch,
                                                   Item => Id, Block => Block,
                                                   Value => V);
                                             elsif not Atom_Metadata_Agrees
                                               (Expected_Atoms,
                                                Atom_Set_Of
                                                  (Of_Unit, Id, V))
                                             then
                                                return
                                                  (Kind =>
                                                     Atom_Metadata_Disagrees,
                                                   Item => Id, Block => Block,
                                                   Value => V);
                                             end if;
                                          end;
                                       end if;
                                    end;
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

                                    declare
                                       Element : Landin.Types.Scalar_Name;
                                       Bad : constant Fault_Kind :=
                                         Scalar_Field_Of
                                           (Id,
                                            (Kind => Module_Datum,
                                             Datum => D),
                                            Field_Of (Of_Unit, Id, V),
                                            Path_Of
                                              (Of_Unit, Id, V),
                                            Element);
                                    begin
                                       if Bad /= Nothing_Wrong then
                                          return
                                            (Kind => Bad, Item => Id,
                                             Block => Block, Value => V);
                                       end if;
                                       if Op = Load_Field
                                         and then Result_Of (Of_Unit, Id, V)
                                                    /= Element
                                       then
                                          return
                                            (Kind => Result_Disagrees,
                                             Item => Id, Block => Block,
                                             Value => V);
                                       end if;
                                       if Op = Load_Field then
                                          declare
                                             Expected : constant
                                               Signature_Id :=
                                               Scalar_Field_Signature
                                                 (Id,
                                                  (Kind => Module_Datum,
                                                   Datum => D),
                                                  Field_Of (Of_Unit, Id, V),
                                                  Path_Of (Of_Unit, Id, V));
                                             Actual : constant Signature_Id :=
                                               Signature_Of
                                                 (Of_Unit, Id, V);
                                             Expected_Atoms : constant
                                               Atom_Set_Id :=
                                               Scalar_Field_Atoms
                                                 (Id,
                                                  (Kind => Module_Datum,
                                                   Datum => D),
                                                  Field_Of (Of_Unit, Id, V),
                                                  Path_Of (Of_Unit, Id, V));
                                          begin
                                             if (Expected = No_Signature)
                                                  /= (Actual = No_Signature)
                                               or else
                                                 (Expected /= No_Signature
                                                  and then
                                                    (not Holds
                                                       (Of_Unit, Actual)
                                                     or else not
                                                       Signatures_Agree
                                                         (Of_Unit, Expected,
                                                          Actual)))
                                             then
                                                return
                                                  (Kind => Signature_Mismatch,
                                                   Item => Id, Block => Block,
                                                   Value => V);
                                             elsif not Atom_Metadata_Agrees
                                               (Expected_Atoms,
                                                Atom_Set_Of
                                                  (Of_Unit, Id, V))
                                             then
                                                return
                                                  (Kind =>
                                                     Atom_Metadata_Disagrees,
                                                   Item => Id, Block => Block,
                                                   Value => V);
                                             end if;
                                          end;
                                       end if;
                                    end;
                                 end;
                              end if;

                           when Load_Element | Store_Element =>
                              declare
                                 Place : constant Storage :=
                                   (if Reaches_A_Slot (Of_Unit, Id, V)
                                    then (Kind => Frame_Slot,
                                          Slot => Slot_Of (Of_Unit, Id, V))
                                    else (Kind => Module_Datum,
                                          Datum => Datum_Of
                                            (Of_Unit, Id, V)));
                                 Element : Field_Shape;
                                 Length : Element_Total;
                                 Bad : Fault_Kind :=
                                   Shape_Of
                                     (Id, Place,
                                      Element_Field_Of (Of_Unit, Id, V),
                                      Element, Length,
                                      Variant_Case_Of (Of_Unit, Id, V),
                                      Variant_Payload_Field_Of
                                        (Of_Unit, Id, V),
                                      Nested => Path_Of
                                        (Of_Unit, Id, V));
                              begin
                                 --  Preserve D22's public fault for field
                                 --  zero while D84's variant payload and
                                 --  D89's ordinary child route array leaves
                                 --  through the same release-safe shape walk.
                                 if Bad = Array_Storage_Is_Not_An_Array
                                   and then Element_Field_Of
                                     (Of_Unit, Id, V) = 0
                                 then
                                    Bad := Element_Datum_Is_Not_An_Array;
                                 end if;
                                 if Bad /= Nothing_Wrong then
                                    return (Kind => Bad, Item => Id,
                                            Block => Block, Value => V);
                                 end if;
                              end;

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
                                   Field_Shape;
                                 Source_Length, Destination_Length :
                                   Element_Total;
                                 Bad : Fault_Kind;
                              begin
                                 Bad := Shape_Of
                                   (Id, Source_Of (Of_Unit, Id, V),
                                    Source_Field_Of (Of_Unit, Id, V),
                                    Source_Element, Source_Length,
                                    Nested => Source_Path_Of
                                      (Of_Unit, Id, V),
                                    Aggregate_Field => True);
                                 if Bad /= Nothing_Wrong then
                                    return (Kind => Bad, Item => Id,
                                            Block => Block, Value => V);
                                 end if;

                                 Bad := Shape_Of
                                   (Id, Destination_Of (Of_Unit, Id, V),
                                    Element_Field_Of (Of_Unit, Id, V),
                                    Destination_Element, Destination_Length,
                                    Variant_Case_Of (Of_Unit, Id, V),
                                    Variant_Payload_Field_Of
                                      (Of_Unit, Id, V),
                                    Nested => Path_Of
                                      (Of_Unit, Id, V),
                                    Aggregate_Field => True);
                                 if Bad /= Nothing_Wrong then
                                    return (Kind => Bad, Item => Id,
                                            Block => Block, Value => V);
                                 end if;

                                 if not Same_Shape
                                   (Of_Unit, Source_Element,
                                    Destination_Element)
                                   or else Source_Length /= Destination_Length
                                 then
                                    return
                                      (Kind => Array_Copy_Shapes_Disagree,
                                       Item => Id, Block => Block, Value => V);
                                 end if;
                              end;

                           when Copy_Variant =>
                              if Is_Datum then
                                 return
                                   (Kind  => Variant_Operation_Inside_A_Datum,
                                    Item  => Id,
                                    Block => Block,
                                    Value => V);
                              end if;

                              declare
                                 Source_Shape, Destination_Shape, Leaf :
                                   Field_Shape;
                                 Bad : Fault_Kind;
                              begin
                                 Bad := Variant_Shape_Of
                                   (Id, Source_Of (Of_Unit, Id, V),
                                    Source_Field_Of (Of_Unit, Id, V),
                                    0, 0, Source_Shape, Leaf,
                                    Source_Path_Of (Of_Unit, Id, V));
                                 if Bad /= Nothing_Wrong then
                                    return (Kind => Bad, Item => Id,
                                            Block => Block, Value => V);
                                 end if;

                                 Bad := Variant_Shape_Of
                                   (Id, Destination_Of (Of_Unit, Id, V),
                                    Element_Field_Of (Of_Unit, Id, V),
                                    0, 0, Destination_Shape, Leaf,
                                    Path_Of (Of_Unit, Id, V));
                                 if Bad /= Nothing_Wrong then
                                    return (Kind => Bad, Item => Id,
                                            Block => Block, Value => V);
                                 end if;

                                 if not Same_Shape
                                   (Of_Unit, Source_Shape, Destination_Shape)
                                 then
                                    return
                                      (Kind => Variant_Copy_Shapes_Disagree,
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
                                 Element : Field_Shape;
                                 Length  : Element_Total;
                                 Bad     : Fault_Kind := Nothing_Wrong;
                              begin
                                 if not
                                   ((Field = 0
                                     and then Path_Of (Of_Unit, Id, V)'Length
                                                = 0
                                     and then Is_Whole_Aggregate
                                       (Id, Destination))
                                    or else Is_Whole_Aggregate_Field
                                      (Id, Destination, Field,
                                       Path_Of (Of_Unit, Id, V)))
                                 then
                                    --  Arrays and positive aggregate array
                                    --  fields retain their exact D49 checks.
                                    --  Invalid storage also comes here;
                                    --  Shape_Of reports it before an accessor.
                                    Bad := Shape_Of
                                      (Id, Destination, Field,
                                       Element, Length,
                                       Nested => Path_Of
                                         (Of_Unit, Id, V));
                                 end if;

                                 if Bad /= Nothing_Wrong then
                                    return (Kind => Bad, Item => Id,
                                            Block => Block, Value => V);
                                 end if;
                              end;

                           when Load_Variant_Tag | Load_Variant_Field
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
                                      (if Op in Load_Variant_Tag
                                              | Load_Variant_Field
                                       then Source_Of (Of_Unit, Id, V)
                                       else Destination_Of
                                         (Of_Unit, Id, V)),
                                      Element_Field_Of (Of_Unit, Id, V),
                                      (if Op = Load_Variant_Tag then 0
                                       else Variant_Case_Of
                                         (Of_Unit, Id, V)),
                                      (if Op in Load_Variant_Field
                                               | Store_Variant_Field
                                       then Variant_Payload_Field_Of
                                         (Of_Unit, Id, V)
                                       else 0),
                                      Shape, Leaf,
                                      Path_Of (Of_Unit, Id, V));
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
                                 Element : Field_Shape;
                                 Length  : Element_Total;
                                 Bad     : constant Fault_Kind :=
                                   Shape_Of
                                     (Id,
                                      Destination_Of (Of_Unit, Id, V),
                                      Element_Field_Of (Of_Unit, Id, V),
                                      Element, Length,
                                      Variant_Case_Of (Of_Unit, Id, V),
                                      Variant_Payload_Field_Of
                                        (Of_Unit, Id, V),
                                      Nested => Path_Of
                                        (Of_Unit, Id, V));
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

                                 --  A fill repeats one scalar pattern, so
                                 --  D121's aggregate element has none.
                                 if Element.Kind /= Scalar_Field_Shape then
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

                           when Evidence_Address =>
                              if not Holds
                                (Of_Unit, Evidence_Of (Of_Unit, Id, V))
                              then
                                 return
                                   (Kind => Evidence_Out_Of_Range,
                                    Item => Id, Block => Block, Value => V);
                              end if;

                           when Evidence_Function =>
                              declare
                                 Evidence : constant Evidence_Id :=
                                   Evidence_Of (Of_Unit, Id, V);
                                 Which : constant Natural :=
                                   Evidence_Entry_Of (Of_Unit, Id, V);
                              begin
                                 if not Holds (Of_Unit, Evidence) then
                                    return
                                      (Kind => Evidence_Out_Of_Range,
                                       Item => Id, Block => Block, Value => V);
                                 elsif Which = 0
                                   or else Which > Evidence_Entry_Count
                                     (Of_Unit, Evidence)
                                 then
                                    return
                                      (Kind => Evidence_Entry_Out_Of_Range,
                                       Item => Id, Block => Block, Value => V);
                                 end if;
                                 declare
                                    Signature : constant Signature_Id :=
                                      Evidence_Entry_Dispatch_Signature
                                        (Of_Unit, Evidence, Which);
                                 begin
                                    if (if Evidence_Is_Erased
                                          (Of_Unit, Evidence)
                                        then Signature_Of (Of_Unit, Id, V)
                                          /= Signature
                                        else not Function_Metadata_Agrees
                                          (Signature,
                                           Signature_Of (Of_Unit, Id, V)))
                                    then
                                       return
                                         (Kind =>
                                            Evidence_Entry_Signature_Disagrees,
                                          Item => Id, Block => Block,
                                          Value => V);
                                    end if;
                                 end;
                              end;

                           when Function_Address =>
                              declare
                                 C : constant Item_Id :=
                                   Callee_Of (Of_Unit, Id, V);
                                 Signature : constant Signature_Id :=
                                   Signature_Of (Of_Unit, Id, V);
                              begin
                                 if not Holds (Of_Unit, C)
                                   or else Kind_Of (Of_Unit, C) /= Routine
                                 then
                                    return
                                      (Kind => Callee_Is_Not_A_Routine,
                                       Item => Id, Block => Block,
                                       Value => V);
                                 elsif not Holds (Of_Unit, Signature) then
                                    return
                                      (Kind => Signature_Out_Of_Range,
                                       Item => Id, Block => Block,
                                       Value => V);
                                 elsif Signature_Of (Of_Unit, C)
                                         = No_Signature
                                   or else not Signatures_Agree
                                     (Of_Unit, Signature,
                                      Signature_Of (Of_Unit, C))
                                 then
                                    return
                                      (Kind =>
                                         Function_Value_Signature_Disagrees,
                                       Item => Id, Block => Block,
                                       Value => V);
                                 end if;
                              end;

                           when Call | Indirect_Call =>
                              --  [1940]: a module value is not a call.
                              if Is_Datum then
                                 return (Kind => Call_Inside_A_Datum,
                                         Item => Id, Block => Block,
                                         Value => V);
                              end if;

                              declare
                                 Signature : constant Signature_Id :=
                                   Call_Signature (Of_Unit, Id, V);
                              begin
                                 if Op = Call then
                                    declare
                                       C : constant Item_Id :=
                                         Callee_Of (Of_Unit, Id, V);
                                    begin
                                       if not Holds (Of_Unit, C)
                                         or else Kind_Of (Of_Unit, C)
                                                   /= Routine
                                       then
                                          return
                                            (Kind => Callee_Is_Not_A_Routine,
                                             Item => Id, Block => Block,
                                             Value => V);
                                       end if;
                                    end;
                                 end if;

                                 if not Holds (Of_Unit, Signature) then
                                    return
                                      (Kind => Signature_Out_Of_Range,
                                       Item => Id, Block => Block,
                                       Value => V);
                                 end if;

                                 if Op = Call then
                                    declare
                                       C : constant Item_Id :=
                                         Callee_Of (Of_Unit, Id, V);
                                    begin
                                       if Signature_Of (Of_Unit, C)
                                            = No_Signature
                                         or else not Signatures_Agree
                                           (Of_Unit, Signature,
                                            Signature_Of (Of_Unit, C))
                                       then
                                          return
                                            (Kind =>
                                               Routine_Signature_Disagrees,
                                             Item => Id, Block => Block,
                                             Value => V);
                                       end if;
                                    end;
                                 end if;

                                 declare
                                    Errors : constant Atom_Set_Id :=
                                      Signature_Errors
                                        (Of_Unit, Signature);
                                    Failure : constant Slot_Id :=
                                      Failure_Slot_Of (Of_Unit, Id, V);
                                 begin
                                    if Errors = No_Atom_Set then
                                       if Failure /= No_Slot then
                                          return
                                            (Kind =>
                                               Call_Failure_Slot_Disagrees,
                                             Item => Id, Block => Block,
                                             Value => V);
                                       end if;
                                    elsif not Holds
                                      (Of_Unit, Id, Failure)
                                      or else Type_Of
                                        (Of_Unit, Id, Failure)
                                          /= Landin.Types.U32
                                      or else not Atom_Metadata_Agrees
                                        (Errors,
                                         Atom_Set_Of
                                           (Of_Unit, Id, Failure))
                                    then
                                       return
                                         (Kind =>
                                            Call_Failure_Slot_Disagrees,
                                          Item => Id, Block => Block,
                                          Value => V);
                                    end if;
                                 end;
                              end;

                           when Jump | Branch =>
                              --  D177 keeps a module bool in its static image
                              --  instead of routing [0340] through CFG here.
                              --  The lowering therefore creates no such datum
                              --  edge; this generic target check remains for
                              --  hand-built IR and routine CFG.
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
                                    Signature_Carrier_Count
                                      (Call_Signature (Of_Unit, Id, V)),
                                 when Indirect_Call =>
                                    Signature_Carrier_Count
                                      (Call_Signature (Of_Unit, Id, V)) + 1,
                                 when Storage_Address =>
                                    (if Storage_Address_Has_Index
                                       (Of_Unit, Id, V)
                                     then 1 else 0),
                                 when Leave =>
                                    (if Result_Of (Of_Unit, Id)
                                        in Landin.Types.Scalar_Name
                                       and then not
                                         (Is_Datum
                                          and then Has_Bool_Image
                                            (Of_Unit, Id))
                                     then 1 else 0),
                                 when others => Wanted (Op));
                        begin
                           if Operand_Count (Of_Unit, Id, V) < Expect
                             or else (Operand_Count (Of_Unit, Id, V) > Expect
                               and then not
                                 (Op in Call | Indirect_Call
                                  and then Signature_Is_Variadic
                                    (Of_Unit,
                                     Call_Signature (Of_Unit, Id, V))))
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

                              --  A bound function is not a first-class word:
                              --  only its paired self projection and direct
                              --  indirect-callee position may consume it.
                              declare
                                 Signature : constant Signature_Id :=
                                   Signature_Of (Of_Unit, Id, Arg);
                              begin
                                 if Holds (Of_Unit, Signature)
                                   and then Signature_Has_Erased_Self
                                     (Of_Unit, Signature)
                                   and then not
                                     (Index = 1 and then Op in
                                        Evidence_Self | Indirect_Call)
                                 then
                                    return
                                      (Kind => Erased_Dispatch_Malformed,
                                       Item => Id, Block => Block, Value => V);
                                 end if;
                              end;
                           end;
                        end loop;

                        --  Marked descriptors are transient dispatch types.
                        --  In particular, no slot reload or ordinary code
                        --  address can recover an erased callable.
                        declare
                           Code : constant Instruction := Of_Unit.Code
                             (Of_Unit.Items (Positive (Id)).Values.First
                              + Positive (V));
                        begin
                           if Holds (Of_Unit, Code.Signature)
                             and then Signature_Has_Erased_Self
                               (Of_Unit, Code.Signature)
                             and then Op not in Evidence_Function
                               | Indirect_Call
                           then
                              return (Kind => Erased_Dispatch_Malformed,
                                      Item => Id, Block => Block, Value => V);
                           end if;
                        end;

                        --  Step four: the types [1890].
                        case Op is
                           when Load =>
                              declare
                                 Slot : constant Slot_Id :=
                                   Slot_Of (Of_Unit, Id, V);
                              begin
                                 if Is_Aggregate (Of_Unit, Id, Slot)
                                   or else Is_Array (Of_Unit, Id, Slot)
                                   or else Result_Of (Of_Unit, Id, V)
                                     /= Type_Of (Of_Unit, Id, Slot)
                                 then
                                    return (Kind => Result_Disagrees,
                                            Item => Id, Block => Block,
                                            Value => V);
                                 elsif not Function_Metadata_Agrees
                                   (Signature_Of (Of_Unit, Id, Slot),
                                    Signature_Of (Of_Unit, Id, V))
                                 then
                                    return (Kind => Signature_Mismatch,
                                            Item => Id, Block => Block,
                                            Value => V);
                                 elsif not Atom_Metadata_Agrees
                                   (Atom_Set_Of (Of_Unit, Id, Slot),
                                    Atom_Set_Of (Of_Unit, Id, V))
                                 then
                                    return (Kind => Atom_Metadata_Disagrees,
                                            Item => Id, Block => Block,
                                            Value => V);
                                 end if;
                              end;

                           when Fill_Array =>
                              declare
                                 Element : Field_Shape;
                                 Length : Element_Total;
                                 Bad : constant Fault_Kind := Shape_Of
                                   (Id, Destination_Of (Of_Unit, Id, V),
                                    Element_Field_Of (Of_Unit, Id, V),
                                    Element, Length,
                                    Variant_Case_Of (Of_Unit, Id, V),
                                    Variant_Payload_Field_Of (Of_Unit, Id, V),
                                    Nested => Path_Of (Of_Unit, Id, V));
                                 Source : constant Value_Id :=
                                   Nth_Operand (Of_Unit, Id, V, 1);
                              begin
                                 if Bad /= Nothing_Wrong
                                   or else Result_Of (Of_Unit, Id, Source)
                                     /= Element.Element
                                   or else not Function_Metadata_Agrees
                                     (Element.Signature,
                                      Signature_Of (Of_Unit, Id, Source))
                                   or else (Element.Pointee /= No_Pointee
                                     and then not Pointees_Agree
                                       (Of_Unit, Element.Pointee,
                                        Pointee_Of (Of_Unit, Id, Source)))
                                   or else not Atom_Metadata_Agrees
                                     (Element.Atoms,
                                      Atom_Set_Of (Of_Unit, Id, Source))
                                 then
                                    return
                                      (Kind => Array_Fill_Value_Disagrees,
                                       Item => Id, Block => Block, Value => V);
                                 end if;
                              end;

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

                                 declare
                                    Operand_Kind : constant
                                      Landin.Types.Type_Kind :=
                                        Result_Of (Of_Unit, Id, L);
                                    Ordinary_Numeric : constant Boolean :=
                                      Op in Multiply | Divide | Add | Subtract;
                                 begin
                                    if Op in Numeric_Kind
                                      and then
                                        (if Ordinary_Numeric
                                         then Operand_Kind
                                                not in
                                                  Landin.Types.Numeric_Name
                                         else Operand_Kind
                                                not in
                                                  Landin.Types.Integer_Name)
                                    then
                                       return
                                         (Kind => Result_Disagrees,
                                          Item => Id, Block => Block,
                                          Value => V);
                                    end if;
                                 end;

                                 declare
                                    Left_Signature : constant Signature_Id :=
                                      Signature_Of (Of_Unit, Id, L);
                                    Right_Signature : constant Signature_Id :=
                                      Signature_Of (Of_Unit, Id, R);
                                 begin
                                    if (Left_Signature = No_Signature)
                                         /= (Right_Signature = No_Signature)
                                      or else
                                        (Left_Signature /= No_Signature
                                         and then Op not in Comparison_Kind)
                                      or else
                                        (Left_Signature /= No_Signature
                                         and then
                                           (not Holds
                                              (Of_Unit, Right_Signature)
                                            or else not Signatures_Agree
                                              (Of_Unit, Left_Signature,
                                               Right_Signature)))
                                    then
                                       return
                                         (Kind =>
                                            Function_Value_Signature_Disagrees,
                                          Item => Id, Block => Block,
                                          Value => V);
                                    end if;
                                 end;

                                 declare
                                    Left_Atoms : constant Atom_Set_Id :=
                                      Atom_Set_Of (Of_Unit, Id, L);
                                    Right_Atoms : constant Atom_Set_Id :=
                                      Atom_Set_Of (Of_Unit, Id, R);
                                 begin
                                    if (Left_Atoms = No_Atom_Set)
                                         /= (Right_Atoms = No_Atom_Set)
                                      or else
                                        (Left_Atoms /= No_Atom_Set
                                         and then
                                           (Op not in Comparison_Kind
                                            or else
                                              (not Atom_Metadata_Is_Subset
                                                 (Left_Atoms, Right_Atoms)
                                               and then not
                                                 Atom_Metadata_Is_Subset
                                                   (Right_Atoms,
                                                    Left_Atoms))))
                                    then
                                       return
                                         (Kind => Atom_Metadata_Disagrees,
                                          Item => Id, Block => Block,
                                          Value => V);
                                    end if;
                                 end;

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
                              declare
                                 Operand_Kind : constant
                                   Landin.Types.Type_Kind :=
                                     Result_Of
                                       (Of_Unit, Id,
                                        Nth_Operand (Of_Unit, Id, V, 1));
                              begin
                                 if Result_Of (Of_Unit, Id, V) /= Operand_Kind
                                   or else
                                     (case Op is
                                         when Negation =>
                                           Operand_Kind not in
                                             Landin.Types.Numeric_Name,
                                         when Complement =>
                                           Operand_Kind not in
                                             Landin.Types.Integer_Name,
                                         when Logical_Not =>
                                           Operand_Kind /= Landin.Types.Bool,
                                         when others => True)
                                 then
                                    return (Kind => Result_Disagrees,
                                            Item => Id, Block => Block,
                                            Value => V);
                                 end if;
                              end;

                           when Pointer_Address =>
                              if Result_Of (Of_Unit, Id, V)
                                   /= Landin.Types.Usize
                                or else Result_Of
                                  (Of_Unit, Id,
                                   Nth_Operand (Of_Unit, Id, V, 1))
                                    /= Landin.Types.Usize
                              then
                                 return (Kind => Result_Disagrees,
                                         Item => Id, Block => Block,
                                         Value => V);
                              end if;

                           when Conversion =>
                              declare
                                 Result_Kind : constant
                                   Landin.Types.Type_Kind :=
                                     Result_Of (Of_Unit, Id, V);
                                 Operand_Kind : constant
                                   Landin.Types.Type_Kind :=
                                     Result_Of
                                       (Of_Unit, Id,
                                        Nth_Operand
                                          (Of_Unit, Id, V, 1));
                              begin
                                 if not
                                   ((Result_Kind
                                       in Landin.Types.Numeric_Name
                                     and then
                                       Operand_Kind
                                         in Landin.Types.Numeric_Name
                                             | Landin.Types.Bool)
                                    or else
                                      (Result_Kind = Landin.Types.Bool
                                       and then Operand_Kind
                                         in Landin.Types.Numeric_Name))
                                 then
                                    return (Kind => Result_Disagrees,
                                            Item => Id, Block => Block,
                                            Value => V);
                                 end if;
                              end;

                           when Range_Check =>
                              --  D188: this neither widens nor narrows, so
                              --  its result type is its operand's, both are
                              --  integers, and both bounds are values that
                              --  type holds.  A bound the type does not
                              --  hold would make the emitted comparison
                              --  meaningless rather than merely redundant.
                              --  Pointer-sized bounds require a chosen target,
                              --  not the structural walk's placeholder facts.
                              declare
                                 Result_Kind : constant
                                   Landin.Types.Type_Kind :=
                                     Result_Of (Of_Unit, Id, V);
                                 Operand_Kind : constant
                                   Landin.Types.Type_Kind :=
                                     Result_Of
                                       (Of_Unit, Id,
                                        Nth_Operand (Of_Unit, Id, V, 1));
                              begin
                                 if Result_Kind not in
                                      Landin.Types.Integer_Name
                                   or else Operand_Kind /= Result_Kind
                                   or else Range_Lower (Of_Unit, Id, V)
                                             > Range_Upper (Of_Unit, Id, V)
                                   or else
                                     ((Check_Image
                                       or else Result_Kind not in
                                         Landin.Types.Usize
                                           | Landin.Types.Isize)
                                      and then
                                        (not Landin.Types.Holds
                                           (Range_Lower (Of_Unit, Id, V),
                                            Result_Kind, Facts)
                                         or else not Landin.Types.Holds
                                           (Range_Upper (Of_Unit, Id, V),
                                            Result_Kind, Facts)))
                                 then
                                    return (Kind => Result_Disagrees,
                                            Item => Id, Block => Block,
                                            Value => V);
                                 end if;
                              end;

                           when Slice_Address =>
                              if Field_Shape_Is_Malformed
                                (Slice_Element_Shape (Of_Unit, Id, V),
                                 Aggregate_Allowed => True)
                              then
                                 return (Kind => Field_Shape_Malformed,
                                         Item => Id, Block => Block,
                                         Value => V);
                              elsif Result_Of (Of_Unit, Id, V)
                                   /= Landin.Types.Usize
                              then
                                 return (Kind => Result_Disagrees,
                                         Item => Id, Block => Block,
                                         Value => V);
                              end if;
                              for Argument in 1 .. 4 loop
                                 if Result_Of
                                      (Of_Unit, Id,
                                       Nth_Operand
                                         (Of_Unit, Id, V, Argument))
                                      /= Landin.Types.Usize
                                 then
                                    return (Kind => Result_Disagrees,
                                            Item => Id, Block => Block,
                                            Value => V);
                                 end if;
                              end loop;

                           when Empty_Slice_Base =>
                              if Field_Shape_Is_Malformed
                                (Slice_Element_Shape (Of_Unit, Id, V),
                                 Aggregate_Allowed => True)
                              then
                                 return (Kind => Field_Shape_Malformed,
                                         Item => Id, Block => Block,
                                         Value => V);
                              elsif Result_Of (Of_Unit, Id, V)
                                   /= Landin.Types.Usize
                              then
                                 return (Kind => Result_Disagrees,
                                         Item => Id, Block => Block,
                                         Value => V);
                              end if;

                           when Load_Indirect | Store_Indirect =>
                              declare
                                 Bad : constant Fault_Kind :=
                                   Indirect_Fault (Id, V);
                              begin
                                 if Bad /= Nothing_Wrong then
                                    return (Kind => Bad, Item => Id,
                                            Block => Block, Value => V);
                                 end if;
                              end;

                           when Place_Address =>
                              if Result_Of (Of_Unit, Id, V)
                                   /= Landin.Types.Usize
                              then
                                 return (Kind => Result_Disagrees,
                                         Item => Id, Block => Block,
                                         Value => V);
                              end if;

                           when Storage_Address =>
                              if Result_Of (Of_Unit, Id, V)
                                /= Landin.Types.Usize
                              then
                                 return (Kind => Result_Disagrees,
                                         Item => Id, Block => Block,
                                         Value => V);
                              elsif Storage_Address_Has_Index
                                (Of_Unit, Id, V)
                                and then Result_Of
                                  (Of_Unit, Id,
                                   Nth_Operand (Of_Unit, Id, V, 1))
                                    /= Landin.Types.Usize
                              then
                                 return (Kind => Element_Index_Is_Not_Usize,
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
                                       if Field_Shape_Is_Malformed
                                         (Part, Aggregate_Allowed => True)
                                       then
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
                                 if Is_Address (Of_Unit, Id, S) then
                                    declare
                                       Source : constant Value_Id :=
                                         Nth_Operand (Of_Unit, Id, V, 1);
                                       Element : Field_Shape;
                                       Length : Element_Total;
                                       Bad : Fault_Kind;
                                    begin
                                       if Op_Of (Of_Unit, Id, Source)
                                            = Slice_Address
                                       then
                                          if not Same_Shape
                                            (Of_Unit,
                                             Address_Shape (Of_Unit, Id, S),
                                             Slice_Element_Shape
                                               (Of_Unit, Id, Source))
                                          then
                                             return
                                               (Kind =>
                                                  Address_Value_Disagrees,
                                                Item => Id, Block => Block,
                                                Value => V);
                                          end if;
                                       elsif Op_Of (Of_Unit, Id, Source)
                                            = Pointer_Address
                                       then
                                          if not Holds (Of_Unit,
                                            Pointee_Of (Of_Unit, Id, Source))
                                            or else not Same_Shape
                                              (Of_Unit, Address_Shape
                                                 (Of_Unit, Id, S),
                                               Pointee_Shape (Of_Unit,
                                                 Pointee_Of
                                                   (Of_Unit, Id, Source)))
                                          then
                                             return
                                               (Kind =>
                                                  Address_Value_Disagrees,
                                                Item => Id, Block => Block,
                                                Value => V);
                                          end if;
                                       elsif Op_Of (Of_Unit, Id, Source) = Load
                                       then
                                          declare
                                             From : constant Slot_Id :=
                                               Slot_Of (Of_Unit, Id, Source);
                                          begin
                                             if not Is_Address
                                               (Of_Unit, Id, From)
                                               or else not Same_Shape
                                                 (Of_Unit, Address_Shape
                                                    (Of_Unit, Id, From),
                                                  Address_Shape
                                                    (Of_Unit, Id, S))
                                             then
                                                return
                                                  (Kind =>
                                                     Address_Value_Disagrees,
                                                   Item => Id, Block => Block,
                                                   Value => V);
                                             end if;
                                          end;
                                       elsif Op_Of (Of_Unit, Id, Source)
                                            = Place_Address
                                       then
                                          if not Stored_Shape_Agrees
                                            (Id, Destination_Of
                                               (Of_Unit, Id, Source),
                                             Element_Field_Of
                                               (Of_Unit, Id, Source),
                                             Path_Of (Of_Unit, Id, Source),
                                             Address_Shape (Of_Unit, Id, S))
                                          then
                                             return
                                               (Kind =>
                                                  Address_Value_Disagrees,
                                                Item => Id, Block => Block,
                                                Value => V);
                                          end if;
                                       elsif Op_Of (Of_Unit, Id, Source)
                                            /= Storage_Address
                                       then
                                          return
                                            (Kind => Address_Value_Disagrees,
                                             Item => Id, Block => Block,
                                             Value => V);
                                       elsif Storage_Address_Has_Index
                                         (Of_Unit, Id, Source)
                                       then
                                          Bad := Shape_Of
                                            (Id,
                                             Destination_Of
                                               (Of_Unit, Id, Source),
                                             Element_Field_Of
                                               (Of_Unit, Id, Source),
                                             Element, Length,
                                             Nested => Path_Of
                                               (Of_Unit, Id, Source));
                                          if Bad /= Nothing_Wrong
                                            or else not Same_Shape
                                              (Of_Unit, Element,
                                               Address_Shape
                                                 (Of_Unit, Id, S))
                                          then
                                             return
                                               (Kind =>
                                                  Address_Value_Disagrees,
                                                Item => Id, Block => Block,
                                                Value => V);
                                          end if;
                                       elsif not Stored_Shape_Agrees
                                         (Id,
                                          Destination_Of
                                            (Of_Unit, Id, Source),
                                          Element_Field_Of
                                            (Of_Unit, Id, Source),
                                          Path_Of (Of_Unit, Id, Source),
                                          Address_Shape (Of_Unit, Id, S))
                                       then
                                          return
                                            (Kind => Address_Value_Disagrees,
                                             Item => Id, Block => Block,
                                             Value => V);
                                       end if;
                                    end;
                                 end if;

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

                                 declare
                                    Slot_Signature : constant Signature_Id :=
                                      Signature_Of (Of_Unit, Id, S);
                                    Value_Signature : constant Signature_Id :=
                                      Signature_Of
                                        (Of_Unit, Id,
                                         Nth_Operand
                                           (Of_Unit, Id, V, 1));
                                 begin
                                    if (Slot_Signature = No_Signature)
                                         /= (Value_Signature = No_Signature)
                                      or else
                                        (Slot_Signature /= No_Signature
                                         and then
                                           (not Holds
                                              (Of_Unit, Value_Signature)
                                            or else not Signatures_Agree
                                              (Of_Unit, Slot_Signature,
                                               Value_Signature)))
                                    then
                                       return
                                         (Kind =>
                                            Function_Value_Signature_Disagrees,
                                          Item => Id, Block => Block,
                                          Value => V);
                                    end if;
                                 end;

                                 if not Atom_Metadata_Is_Subset
                                   (Atom_Set_Of
                                      (Of_Unit, Id,
                                       Nth_Operand (Of_Unit, Id, V, 1)),
                                    Atom_Set_Of (Of_Unit, Id, S))
                                 then
                                    return
                                      (Kind => Atom_Metadata_Disagrees,
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
                              declare
                                 Datum : constant Item_Id :=
                                   Datum_Of (Of_Unit, Id, V);
                                 Stored : constant Value_Id :=
                                   Nth_Operand (Of_Unit, Id, V, 1);
                                 Datum_Signature : constant Signature_Id :=
                                   Signature_Of (Of_Unit, Datum);
                                 Value_Signature : constant Signature_Id :=
                                   Signature_Of (Of_Unit, Id, Stored);
                              begin
                                 if Result_Of (Of_Unit, Datum)
                                      /= Result_Of (Of_Unit, Id, Stored)
                                 then
                                    return (Kind => Store_Datum_Disagrees,
                                            Item => Id, Block => Block,
                                            Value => V);
                                 elsif (Datum_Signature = No_Signature)
                                         /= (Value_Signature = No_Signature)
                                   or else
                                     (Datum_Signature /= No_Signature
                                      and then
                                        (not Holds
                                           (Of_Unit, Value_Signature)
                                         or else not Signatures_Agree
                                           (Of_Unit, Datum_Signature,
                                            Value_Signature)))
                                 then
                                    return
                                      (Kind =>
                                         Function_Value_Signature_Disagrees,
                                       Item => Id, Block => Block,
                                       Value => V);
                                 elsif not Atom_Metadata_Is_Subset
                                   (Atom_Set_Of (Of_Unit, Id, Stored),
                                    Atom_Set_Of (Of_Unit, Datum))
                                 then
                                    return
                                      (Kind => Atom_Metadata_Disagrees,
                                       Item => Id, Block => Block,
                                       Value => V);
                                 end if;
                              end;

                           when Load_Element | Store_Element =>
                              declare
                                 Index : constant Value_Id :=
                                   Nth_Operand (Of_Unit, Id, V, 1);
                                 Place : constant Storage :=
                                   (if Reaches_A_Slot (Of_Unit, Id, V)
                                    then (Kind => Frame_Slot,
                                          Slot => Slot_Of (Of_Unit, Id, V))
                                    else (Kind => Module_Datum,
                                          Datum => Datum_Of
                                            (Of_Unit, Id, V)));
                                 Element : Field_Shape;
                                 Length : Element_Total;
                                 Bad : constant Fault_Kind :=
                                   Shape_Of
                                     (Id, Place,
                                      Element_Field_Of (Of_Unit, Id, V),
                                      Element, Length,
                                      Variant_Case_Of (Of_Unit, Id, V),
                                      Variant_Payload_Field_Of
                                        (Of_Unit, Id, V),
                                      Nested => Path_Of
                                        (Of_Unit, Id, V));
                              begin
                                 if Bad /= Nothing_Wrong then
                                    return (Kind => Bad, Item => Id,
                                            Block => Block, Value => V);
                                 end if;
                                 if Result_Of (Of_Unit, Id, Index)
                                      /= Landin.Types.Usize
                                 then
                                    return
                                      (Kind => Element_Index_Is_Not_Usize,
                                       Item => Id, Block => Block,
                                       Value => V);
                                 end if;

                                 --  D121: the operation reaches the
                                 --  element, and then whatever run [0420]
                                 --  selected inside it.
                                 if not Path_Is_Valid
                                   (Of_Unit, Element,
                                    Element_Path_Of (Of_Unit, Id, V))
                                   or else Shape_At
                                     (Of_Unit, Element,
                                      Element_Path_Of (Of_Unit, Id, V)).Kind
                                       /= Scalar_Field_Shape
                                 then
                                    return
                                      (Kind => Element_Field_Is_Not_An_Array,
                                       Item => Id, Block => Block,
                                       Value => V);
                                 end if;

                                 declare
                                    Leaf : constant Field_Shape :=
                                      Shape_At
                                        (Of_Unit, Element,
                                         Element_Path_Of (Of_Unit, Id, V));
                                    Value : constant Value_Id :=
                                      (if Op = Load_Element then V
                                       else Nth_Operand
                                         (Of_Unit, Id, V, 2));
                                 begin
                                    if Result_Of (Of_Unit, Id, Value)
                                         /= Leaf.Element
                                    then
                                       return
                                         (Kind =>
                                            (if Op = Load_Element
                                             then Result_Disagrees
                                             else Store_Datum_Disagrees),
                                          Item => Id, Block => Block,
                                          Value => V);
                                    elsif not Function_Metadata_Agrees
                                      (Leaf.Signature,
                                       Signature_Of
                                         (Of_Unit, Id, Value))
                                    then
                                       return
                                         (Kind =>
                                            Function_Value_Signature_Disagrees,
                                          Item => Id, Block => Block,
                                          Value => V);
                                    elsif not Atom_Metadata_Agrees
                                      (Leaf.Atoms,
                                       Atom_Set_Of (Of_Unit, Id, Value))
                                    then
                                       return
                                         (Kind => Atom_Metadata_Disagrees,
                                          Item => Id, Block => Block,
                                          Value => V);
                                    end if;
                                 end;
                              end;

                           when Store_Field =>
                              declare
                                 Slot : constant Slot_Id :=
                                   (if Reaches_A_Slot (Of_Unit, Id, V)
                                    then Slot_Of (Of_Unit, Id, V)
                                    else No_Slot);
                                 Place : constant Storage :=
                                   (if Reaches_A_Slot (Of_Unit, Id, V)
                                      and then Is_Address
                                        (Of_Unit, Id, Slot)
                                    then (Kind => Runtime_Address,
                                          Address => Slot)
                                    elsif Reaches_A_Slot (Of_Unit, Id, V)
                                    then (Kind => Frame_Slot, Slot => Slot)
                                    else (Kind => Module_Datum,
                                          Datum => Datum_Of
                                            (Of_Unit, Id, V)));
                                 Wants : Landin.Types.Scalar_Name;
                                 Bad : constant Fault_Kind :=
                                   Scalar_Field_Of
                                     (Id, Place,
                                      Field_Of (Of_Unit, Id, V),
                                      Path_Of (Of_Unit, Id, V),
                                      Wants);
                              begin
                                 if Bad /= Nothing_Wrong then
                                    return (Kind => Bad, Item => Id,
                                            Block => Block, Value => V);
                                 end if;
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
                                 declare
                                    Expected : constant Signature_Id :=
                                      Scalar_Field_Signature
                                        (Id, Place,
                                         Field_Of (Of_Unit, Id, V),
                                         Path_Of (Of_Unit, Id, V));
                                    Actual : constant Signature_Id :=
                                      Signature_Of
                                        (Of_Unit, Id,
                                         Nth_Operand (Of_Unit, Id, V, 1));
                                    Expected_Atoms : constant Atom_Set_Id :=
                                      Scalar_Field_Atoms
                                        (Id, Place,
                                         Field_Of (Of_Unit, Id, V),
                                         Path_Of (Of_Unit, Id, V));
                                    Actual_Atoms : constant Atom_Set_Id :=
                                      Atom_Set_Of
                                        (Of_Unit, Id,
                                         Nth_Operand (Of_Unit, Id, V, 1));
                                 begin
                                    if (Expected = No_Signature)
                                         /= (Actual = No_Signature)
                                      or else
                                        (Expected /= No_Signature
                                         and then
                                           (not Holds (Of_Unit, Actual)
                                            or else not Signatures_Agree
                                              (Of_Unit, Expected, Actual)))
                                    then
                                       return
                                         (Kind =>
                                            Function_Value_Signature_Disagrees,
                                          Item => Id, Block => Block,
                                          Value => V);
                                    elsif not Atom_Metadata_Is_Subset
                                      (Actual_Atoms, Expected_Atoms)
                                    then
                                       return
                                         (Kind => Atom_Metadata_Disagrees,
                                          Item => Id, Block => Block,
                                          Value => V);
                                    end if;
                                 end;
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
                                      Shape, Leaf,
                                      Path_Of (Of_Unit, Id, V));
                              begin
                                 if Bad /= Nothing_Wrong then
                                    return (Kind => Bad, Item => Id,
                                            Block => Block, Value => V);
                                 elsif Leaf.Kind /= Scalar_Field_Shape then
                                    return
                                      (Kind =>
                                         Variant_Payload_Field_Is_Not_A_Scalar,
                                       Item => Id, Block => Block, Value => V);
                                 elsif Result_Of
                                      (Of_Unit, Id,
                                       Nth_Operand (Of_Unit, Id, V, 1))
                                      /= Leaf.Element
                                 then
                                    return
                                      (Kind => Variant_Payload_Value_Disagrees,
                                       Item => Id, Block => Block, Value => V);
                                 elsif not Function_Metadata_Agrees
                                   (Leaf.Signature,
                                    Signature_Of
                                      (Of_Unit, Id,
                                       Nth_Operand (Of_Unit, Id, V, 1)))
                                 then
                                    return
                                      (Kind =>
                                         Function_Value_Signature_Disagrees,
                                       Item => Id, Block => Block, Value => V);
                                 elsif not Atom_Metadata_Is_Subset
                                   (Atom_Set_Of
                                      (Of_Unit, Id,
                                       Nth_Operand (Of_Unit, Id, V, 1)),
                                    Leaf.Atoms)
                                 then
                                    return
                                      (Kind => Atom_Metadata_Disagrees,
                                       Item => Id, Block => Block, Value => V);
                                 end if;
                              end;

                           when Load_Variant_Field =>
                              declare
                                 Shape, Leaf : Field_Shape;
                                 Bad : constant Fault_Kind :=
                                   Variant_Shape_Of
                                     (Id, Source_Of (Of_Unit, Id, V),
                                      Element_Field_Of (Of_Unit, Id, V),
                                      Variant_Case_Of (Of_Unit, Id, V),
                                      Variant_Payload_Field_Of
                                        (Of_Unit, Id, V),
                                      Shape, Leaf,
                                      Path_Of (Of_Unit, Id, V));
                              begin
                                 if Bad /= Nothing_Wrong then
                                    return (Kind => Bad, Item => Id,
                                            Block => Block, Value => V);
                                 elsif Leaf.Kind /= Scalar_Field_Shape then
                                    return
                                      (Kind =>
                                         Variant_Payload_Field_Is_Not_A_Scalar,
                                       Item => Id, Block => Block, Value => V);
                                 elsif Result_Of (Of_Unit, Id, V)
                                       /= Leaf.Element
                                 then
                                    return
                                      (Kind =>
                                         Variant_Payload_Result_Disagrees,
                                       Item => Id, Block => Block, Value => V);
                                 elsif not Function_Metadata_Agrees
                                   (Leaf.Signature,
                                    Signature_Of (Of_Unit, Id, V))
                                 then
                                    return
                                      (Kind =>
                                         Function_Value_Signature_Disagrees,
                                       Item => Id, Block => Block, Value => V);
                                 elsif not Atom_Metadata_Agrees
                                   (Leaf.Atoms,
                                    Atom_Set_Of (Of_Unit, Id, V))
                                 then
                                    return
                                      (Kind => Atom_Metadata_Disagrees,
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
                                      0, 0, Shape, Leaf,
                                      Path_Of (Of_Unit, Id, V));
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

                           when Failure_Test =>
                              declare
                                 Error : constant Value_Id :=
                                   Nth_Operand (Of_Unit, Id, V, 1);
                              begin
                                 if Result_Of (Of_Unit, Id, V)
                                      /= Landin.Types.Bool
                                   or else Result_Of (Of_Unit, Id, Error)
                                      /= Landin.Types.U32
                                   or else not Holds
                                     (Of_Unit,
                                      Atom_Set_Of (Of_Unit, Id, Error))
                                 then
                                    return
                                      (Kind => Atom_Metadata_Disagrees,
                                       Item => Id, Block => Block,
                                       Value => V);
                                 end if;
                              end;

                           when Atom =>
                              if Result_Of (Of_Unit, Id, V)
                                   /= Landin.Types.U32
                              then
                                 return
                                   (Kind => Atom_Metadata_Disagrees,
                                    Item => Id, Block => Block, Value => V);
                              end if;

                           when Function_Address | Evidence_Address =>
                              if Result_Of (Of_Unit, Id, V)
                                   /= Landin.Types.Usize
                              then
                                 return (Kind => Result_Disagrees,
                                         Item => Id, Block => Block,
                                         Value => V);
                              end if;

                           when Evidence_Function =>
                              if Result_Of (Of_Unit, Id, V)
                                   /= Landin.Types.Usize
                                or else Result_Of
                                  (Of_Unit, Id,
                                   Nth_Operand (Of_Unit, Id, V, 1))
                                    /= Landin.Types.Usize
                              then
                                 return (Kind => Result_Disagrees,
                                         Item => Id, Block => Block,
                                         Value => V);
                              end if;
                              --  D147's existing private descriptor boundary:
                              --  prove complete transport shape, not that
                              --  arbitrary two-word memory is authentic any.
                              if Is_Erased_Function (Id, V)
                                and then not Address_Agrees
                                  (Id, Nth_Operand (Of_Unit, Id, V, 1),
                                   (Kind => Array_Field_Shape,
                                    Element => Landin.Types.Usize,
                                    Length => 2, others => <>))
                              then
                                 return (Kind => Address_Value_Disagrees,
                                         Item => Id, Block => Block,
                                         Value => V);
                              end if;

                           when Evidence_Self =>
                              declare
                                 Bound : constant Value_Id :=
                                   Nth_Operand (Of_Unit, Id, V, 1);
                                 Code : constant Instruction := Of_Unit.Code
                                   (Of_Unit.Items (Positive (Id)).Values.First
                                    + Positive (V));
                              begin
                                 if not Is_Erased_Function (Id, Bound)
                                   or else Bound /= V - 1
                                   or else Block_Of (Of_Unit, Id, Bound)
                                     /= Block
                                   or else Code.Result /= Landin.Types.Usize
                                   or else Code.Signature /= No_Signature
                                   or else Code.Pointee /= No_Pointee
                                   or else Code.Atom_Set /= No_Atom_Set
                                 then
                                    return (Kind => Evidence_Self_Disagrees,
                                            Item => Id, Block => Block,
                                            Value => V);
                                 end if;
                              end;

                           when Call | Indirect_Call =>
                              declare
                                 Signature : constant Signature_Id :=
                                   Call_Signature (Of_Unit, Id, V);
                                 Result_Count : constant Natural :=
                                   Signature_Result_Count
                                     (Of_Unit, Signature);
                                 Declared_Result : constant Signature_Part :=
                                   (if Result_Count = 1
                                    then Nth_Signature_Result
                                      (Of_Unit, Signature, 1)
                                    else (Kind => Landin.Types.No_Value,
                                          others => <>));
                                 Indirect : constant Boolean :=
                                   Op = Indirect_Call;
                                 Hidden : constant Natural :=
                                   (if Result_Count > 1
                                      or else
                                        (Result_Count = 1
                                         and then Declared_Result.Kind in
                                           Landin.Types.Aggregate
                                             | Landin.Types.Fixed_Array)
                                    then 1 else 0);
                                 Offset : constant Natural :=
                                   (if Indirect then 1 else 0);
                              begin
                                 if (if Hidden = 1 or else Result_Count = 0
                                     then Result_Of (Of_Unit, Id, V)
                                            /= Landin.Types.No_Value
                                     else Result_Of (Of_Unit, Id, V)
                                            /= Carrier_Kind (Declared_Result))
                                 then
                                    return (Kind => Result_Disagrees,
                                            Item => Id, Block => Block,
                                            Value => V);
                                 elsif not Atom_Metadata_Agrees
                                   (Atom_Set_Of (Of_Unit, Id, V),
                                    Declared_Result.Atoms)
                                 then
                                    return
                                      (Kind => Atom_Metadata_Disagrees,
                                       Item => Id, Block => Block,
                                       Value => V);
                                 end if;

                                 if Indirect
                                   and then Result_Of
                                     (Of_Unit, Id,
                                      Nth_Operand (Of_Unit, Id, V, 1))
                                       /= Landin.Types.Usize
                                 then
                                    return (Kind => Operands_Disagree,
                                            Item => Id, Block => Block,
                                            Value => V);
                                 end if;

                                 if Signature_Has_Erased_Self
                                   (Of_Unit, Signature)
                                 then
                                    if not Indirect then
                                       return (Kind => Evidence_Self_Disagrees,
                                               Item => Id, Block => Block,
                                               Value => V);
                                    end if;
                                    declare
                                       Bound : constant Value_Id :=
                                         Nth_Operand (Of_Unit, Id, V, 1);
                                       Self : constant Value_Id := Nth_Operand
                                         (Of_Unit, Id, V, Offset + Hidden + 1);
                                    begin
                                       if not Is_Erased_Function (Id, Bound)
                                         or else Signature /= Signature_Of
                                           (Of_Unit, Id, Bound)
                                         or else Op_Of (Of_Unit, Id, Self)
                                           /= Evidence_Self
                                         or else Nth_Operand
                                           (Of_Unit, Id, Self, 1) /= Bound
                                       then
                                          return
                                            (Kind => Evidence_Self_Disagrees,
                                             Item => Id, Block => Block,
                                             Value => V);
                                       end if;
                                    end;
                                 end if;

                                 if Indirect then
                                    declare
                                       Address : constant Value_Id :=
                                         Nth_Operand (Of_Unit, Id, V, 1);
                                       Address_Signature : constant
                                         Signature_Id :=
                                           Signature_Of
                                             (Of_Unit, Id, Address);
                                    begin
                                       if not Holds
                                         (Of_Unit, Address_Signature)
                                         or else not Signatures_Agree
                                           (Of_Unit, Signature,
                                            Address_Signature)
                                       then
                                          return
                                            (Kind => Signature_Mismatch,
                                             Item => Id, Block => Block,
                                             Value => V);
                                       end if;
                                    end;
                                 end if;

                                 if Hidden = 1
                                   and then Result_Of
                                     (Of_Unit, Id,
                                      Nth_Operand
                                        (Of_Unit, Id, V, Offset + 1))
                                       /= Landin.Types.Usize
                                 then
                                    return (Kind => Operands_Disagree,
                                            Item => Id, Block => Block,
                                            Value => V);
                                 end if;

                                 if Hidden = 1
                                   and then Signature_Uses_C_ABI
                                     (Of_Unit, Signature)
                                   and then not Address_Has_Nominal
                                     (Id, Nth_Operand
                                        (Of_Unit, Id, V, Offset + 1),
                                      Declared_Result.Nominal)
                                 then
                                    return (Kind => Operands_Disagree,
                                            Item => Id, Block => Block,
                                            Value => V);
                                 end if;

                                 if Hidden = 1
                                   and then Signature_Has_Erased_Self
                                     (Of_Unit, Signature)
                                   and then not Erased_Carrier_Agrees
                                     (Id, Nth_Operand
                                        (Of_Unit, Id, V, Offset + 1),
                                      Signature)
                                 then
                                    return (Kind => Operands_Disagree,
                                            Item => Id, Block => Block,
                                            Value => V);
                                 end if;

                                 --  [1920]: each argument has its
                                 --  parameter's type, in order.
                                 for P in
                                   1 .. Signature_Parameter_Count
                                          (Of_Unit, Signature)
                                 loop
                                    declare
                                       Parameter : constant Signature_Part :=
                                         Nth_Signature_Parameter
                                           (Of_Unit, Signature, P);
                                       Argument : constant Value_Id :=
                                         Nth_Operand
                                           (Of_Unit, Id, V,
                                            P + Offset + Hidden);
                                       Agrees : constant Boolean :=
                                         (if Parameter.Kind in
                                               Landin.Types.Aggregate
                                                 | Landin.Types.Fixed_Array
                                                 | Landin.Types.Function_Value
                                          then Result_Of
                                                 (Of_Unit, Id, Argument)
                                                 = Landin.Types.Usize
                                          else Parameter.Kind = Result_Of
                                                   (Of_Unit, Id, Argument));
                                       Signature_Agrees : constant Boolean :=
                                         Parameter.Kind /=
                                           Landin.Types.Function_Value
                                         or else
                                           (Holds
                                              (Of_Unit,
                                               Signature_Of
                                                 (Of_Unit, Id, Argument))
                                            and then Signatures_Agree
                                              (Of_Unit, Parameter.Signature,
                                               Signature_Of
                                                 (Of_Unit, Id, Argument)));
                                    begin
                                       if not Agrees
                                         or else not Signature_Agrees
                                         or else
                                           (if Parameter.Convention
                                              = Inout_Place
                                            then not Address_Agrees
                                              (Id, Argument, Pointee_Shape
                                                 (Of_Unit, Parameter.Pointee))
                                            elsif Parameter.Pointee
                                              /= No_Pointee
                                            then not Pointees_Agree
                                              (Of_Unit, Parameter.Pointee,
                                               Pointee_Of
                                                 (Of_Unit, Id, Argument))
                                            else False)
                                         or else
                                           (Parameter.Kind
                                              = Landin.Types.Aggregate
                                            and then Signature_Uses_C_ABI
                                              (Of_Unit, Signature)
                                            and then not Address_Has_Nominal
                                              (Id, Argument,
                                               Parameter.Nominal))
                                         or else
                                           (P > 1
                                            and then Signature_Has_Erased_Self
                                              (Of_Unit, Signature)
                                            and then Parameter.Kind in
                                              Landin.Types.Aggregate
                                                | Landin.Types.Fixed_Array
                                            and then not Erased_Carrier_Agrees
                                              (Id, Argument, Signature, P))
                                         or else not Atom_Metadata_Is_Subset
                                           (Atom_Set_Of
                                              (Of_Unit, Id, Argument),
                                            Parameter.Atoms)
                                       then
                                          return
                                            (Kind => Operands_Disagree,
                                             Item => Id, Block => Block,
                                             Value => V);
                                       end if;
                                    end;
                                 end loop;

                                 --  Unnamed actuals retain their own scalar
                                 --  descriptors after C default promotion.
                                 --  Aggregate tails have no native carrier.
                                 --  Storage_Address and typed address-slot
                                 --  loads are internal carriers, not source
                                 --  pointers (addr emits Place_Address).
                                 for P in Signature_Carrier_Count (Signature)
                                   + Offset + 1
                                   .. Operand_Count (Of_Unit, Id, V)
                                 loop
                                    declare
                                       Argument : constant Value_Id :=
                                         Nth_Operand (Of_Unit, Id, V, P);
                                       Callback : constant Signature_Id :=
                                         Signature_Of (Of_Unit, Id, Argument);
                                    begin
                                       if Op_Of (Of_Unit, Id, Argument)
                                            = Storage_Address
                                         or else
                                           (Op_Of (Of_Unit, Id, Argument)
                                              = Load
                                            and then Is_Address
                                              (Of_Unit, Id, Slot_Of
                                                 (Of_Unit, Id, Argument)))
                                       then
                                          return
                                            (Kind => Operands_Disagree,
                                             Item => Id, Block => Block,
                                             Value => V);
                                       end if;
                                       if Result_Of (Of_Unit, Id, Argument)
                                         not in Landin.Types.I32
                                           | Landin.Types.U32
                                           | Landin.Types.I64
                                           | Landin.Types.U64
                                           | Landin.Types.Isize
                                           | Landin.Types.Usize
                                           | Landin.Types.F64
                                         or else Atom_Set_Of
                                           (Of_Unit, Id, Argument)
                                             /= No_Atom_Set
                                         or else (Callback /= No_Signature
                                           and then not Is_C_Callback
                                             (Callback))
                                       then
                                          return
                                            (Kind => Operands_Disagree,
                                             Item => Id, Block => Block,
                                             Value => V);
                                       end if;
                                    end;
                                 end loop;
                              end;

                           when Fail =>
                              declare
                                 Error : constant Value_Id :=
                                   Nth_Operand (Of_Unit, Id, V, 1);
                                 Signature : constant Signature_Id :=
                                   Signature_Of (Of_Unit, Id);
                              begin
                                 if Is_Datum
                                   or else not Holds (Of_Unit, Signature)
                                   or else Signature_Errors
                                     (Of_Unit, Signature) = No_Atom_Set
                                   or else Result_Of (Of_Unit, Id, Error)
                                     /= Landin.Types.U32
                                   or else not Atom_Metadata_Is_Subset
                                     (Atom_Set_Of (Of_Unit, Id, Error),
                                      Signature_Errors
                                        (Of_Unit, Signature))
                                 then
                                    return
                                      (Kind => Fail_Disagrees_With_Signature,
                                       Item => Id, Block => Block,
                                       Value => V);
                                 end if;
                              end;

                           when Leave =>
                              --  Aggregate results use caller storage.  Every
                              --  scalar carrier, including a function code
                              --  address, is carried by the leave itself.
                              if Result_Of (Of_Unit, Id)
                                 in Landin.Types.Scalar_Name
                                and then Operand_Count (Of_Unit, Id, V) >= 1
                              then
                                 declare
                                    Returned : constant Value_Id :=
                                      Nth_Operand (Of_Unit, Id, V, 1);
                                    Expected_Signature : Signature_Id :=
                                      No_Signature;
                                 begin
                                    if Result_Of (Of_Unit, Id, Returned)
                                         /= Result_Of (Of_Unit, Id)
                                    then
                                       return
                                         (Kind => Leave_Disagrees_With_Item,
                                          Item => Id, Block => Block,
                                          Value => V);
                                    end if;

                                    if Signature_Of (Of_Unit, Id)
                                         /= No_Signature
                                    then
                                       if Kind_Of (Of_Unit, Id) = Datum then
                                          Expected_Signature :=
                                            Signature_Of (Of_Unit, Id);
                                       elsif Signature_Result_Count
                                         (Of_Unit,
                                          Signature_Of (Of_Unit, Id)) = 1
                                         and then Signature_Result
                                           (Of_Unit,
                                            Signature_Of (Of_Unit, Id)).Kind
                                             = Landin.Types.Function_Value
                                       then
                                          Expected_Signature :=
                                            Signature_Result
                                              (Of_Unit,
                                               Signature_Of
                                                 (Of_Unit, Id)).Signature;
                                       end if;
                                    end if;

                                    if Expected_Signature /= No_Signature
                                      and then
                                        (not Holds
                                           (Of_Unit,
                                            Signature_Of
                                              (Of_Unit, Id, Returned))
                                         or else not Signatures_Agree
                                           (Of_Unit, Expected_Signature,
                                            Signature_Of
                                              (Of_Unit, Id, Returned)))
                                    then
                                       return
                                         (Kind =>
                                            Function_Value_Signature_Disagrees,
                                          Item => Id, Block => Block,
                                          Value => V);
                                    elsif not Atom_Metadata_Is_Subset
                                      (Atom_Set_Of
                                         (Of_Unit, Id, Returned),
                                       Atom_Set_Of (Of_Unit, Id))
                                    then
                                       return
                                         (Kind => Atom_Metadata_Disagrees,
                                          Item => Id, Block => Block,
                                          Value => V);
                                    end if;
                                 end;
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

            declare
               Bad : constant Fault := Pointer_Provenance (Id);
            begin
               if Bad.Kind /= Nothing_Wrong then
                  return Bad;
               end if;
            end;

            <<Next_IR_Item>>
            null;
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
