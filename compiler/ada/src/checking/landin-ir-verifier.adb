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
            when Atom_Set_Runs_Overlap =>
               "an atom set's members are not where its run says they are",
            when Atom_Set_Malformed =>
               "an atom set is empty, duplicated or names no declaration",
            when Signature_Runs_Overlap =>
               "a signature's parameters are not where its run says they are",
            when Signature_Part_Malformed =>
               "a signature carries a malformed target-neutral type part",
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
            when Atom_Metadata_Disagrees =>
               "an atom carrier disagrees with its structural atom set",
            when Atom_Identity_Not_In_Set =>
               "an atom constant's declaration is not in its atom set",
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
            when Storage_Address_Is_Not_An_Aggregate =>
               "an internal aggregate address names non-aggregate storage",
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
               "an aggregate datum's first image form carries a nonzero"
               & " value for a fixed-array field",
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
            when Load | Storage_Address => 0,
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
            when Function_Address | Call | Indirect_Call => 0,
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
               if Result_Of (Of_Unit, Place.Datum)
                    = Landin.Types.Fixed_Array
               then
                  return No_Signature;
               end if;
               Root := Nth_Field_Shape
                 (Of_Unit, Place.Datum, Positive (Field));
            when Frame_Slot =>
               if Is_Array (Of_Unit, Item, Place.Slot) then
                  return No_Signature;
               end if;
               Root := Nth_Slot_Field_Shape
                 (Of_Unit, Item, Place.Slot, Positive (Field));
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
               if Result_Of (Of_Unit, Place.Datum)
                    = Landin.Types.Fixed_Array
               then
                  return No_Atom_Set;
               end if;
               Root := Nth_Field_Shape
                 (Of_Unit, Place.Datum, Positive (Field));
            when Frame_Slot =>
               if Is_Array (Of_Unit, Item, Place.Slot) then
                  return No_Atom_Set;
               end if;
               Root := Nth_Slot_Field_Shape
                 (Of_Unit, Item, Place.Slot, Positive (Field));
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
              and then Is_Aggregate (Of_Unit, Item, Place.Slot));

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
              and then Is_Array (Of_Unit, Item, Place.Slot));

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
                     else Slot_Out_Of_Range));
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
         Budget : Natural := 0)
        return Boolean;

      function Signature_Part_Is_Malformed
        (Part : Signature_Part) return Boolean;

      function Signature_Carrier_Count
        (Signature : Signature_Id) return Natural;

      function Carrier_Kind (Part : Signature_Part)
        return Landin.Types.Type_Kind;

      function Atom_Metadata_Is_Subset
        (Left, Right : Atom_Set_Id) return Boolean;

      function Part_Agrees_With_Slot
        (Item : Item_Id; Part : Signature_Part; Slot : Slot_Id)
         return Boolean;

      function Results_Agree_With_Slot
        (Item : Item_Id; Signature : Signature_Id; Slot : Slot_Id)
         return Boolean;

      function Field_Shape_Is_Malformed
        (Shape : Field_Shape;
         Aggregate_Allowed : Boolean := False;
         Budget : Natural := 0)
        return Boolean
      is
         Left : constant Natural :=
           (if Budget = 0 then Variant_Field_Shape_Count (Of_Unit) + 1
            else Budget);
      begin
         if Shape.Kind = Scalar_Field_Shape then
            return Shape.Length /= 1
              or else Shape.Cases /= 0
              or else Shape.Payloads_First /= 0
              or else
                (Shape.Signature /= No_Signature
                 and then
                   (Shape.Atoms /= No_Atom_Set
                    or else Shape.Element /= Landin.Types.Usize
                    or else not Holds (Of_Unit, Shape.Signature)))
              or else
                (Shape.Atoms /= No_Atom_Set
                 and then
                   (Shape.Signature /= No_Signature
                    or else Shape.Element /= Landin.Types.U32
                    or else not Holds (Of_Unit, Shape.Atoms)));
         elsif Shape.Signature /= No_Signature
           or else Shape.Atoms /= No_Atom_Set
         then
            return True;
         elsif Shape.Kind = Array_Field_Shape then
            --  D121: an aggregate element is one run of exactly one shape.
            --  No run at all is the scalar element every array had before.
            if Shape.Cases = 0 then
               return Shape.Payloads_First /= 0;
            end if;
            return Shape.Cases /= 1
              or else not Array_Element_Is_Aggregate (Of_Unit, Shape)
              or else Left = 0
              or else Field_Shape_Is_Malformed
                (Array_Element_Shape (Of_Unit, Shape),
                 Aggregate_Allowed => True,
                 Budget => Left - 1);
         elsif Shape.Kind = Aggregate_Field_Shape then
            if not Aggregate_Allowed
              or else Shape.Length /= 1
              or else Shape.Element /= Landin.Types.Bool
              or else not Aggregate_Field_Run_Is_Valid (Of_Unit, Shape)
            then
               return True;
            end if;

            if Left = 0 then
               return True;
            end if;

            for Field in 1 .. Aggregate_Field_Count (Of_Unit, Shape) loop
               if Field_Shape_Is_Malformed
                    (Nth_Aggregate_Field (Of_Unit, Shape, Field),
                     Aggregate_Allowed => True,
                     Budget => Left - 1)
               then
                  return True;
               end if;
            end loop;

            return False;
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

      function Signature_Part_Is_Malformed
        (Part : Signature_Part) return Boolean
      is
      begin
         case Part.Kind is
            when Landin.Types.No_Value =>
               return True;
            when Landin.Types.Scalar_Name =>
               return Part.Aggregate_Body /= No_Declaration
                 or else Part.Length /= 0
                 or else Part.Signature /= No_Signature
                 or else
                   (Part.Atoms /= No_Atom_Set
                    and then
                      (Part.Kind /= Landin.Types.U32
                       or else not Holds (Of_Unit, Part.Atoms)));
            when Landin.Types.Aggregate =>
               return Part.Aggregate_Body = No_Declaration
                 or else Natural (Part.Aggregate_Body)
                           > Declaration_Limit (Of_Unit)
                 or else Part.Length /= 0
                 or else Part.Signature /= No_Signature
                 or else Part.Atoms /= No_Atom_Set;
            when Landin.Types.Fixed_Array =>
               return (Part.Aggregate_Body /= No_Declaration
                         and then Natural (Part.Aggregate_Body)
                           > Declaration_Limit (Of_Unit))
                 or else Part.Signature /= No_Signature
                 or else Part.Atoms /= No_Atom_Set;
            when Landin.Types.Function_Value =>
               return Part.Aggregate_Body /= No_Declaration
                 or else Part.Length /= 0
                 or else not Holds (Of_Unit, Part.Signature)
                 or else Part.Atoms /= No_Atom_Set;
            when others =>
               return True;
         end case;
      end Signature_Part_Is_Malformed;

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

      function Part_Agrees_With_Slot
        (Item : Item_Id; Part : Signature_Part; Slot : Slot_Id)
         return Boolean
        is (case Part.Kind is
               when Landin.Types.Scalar_Name =>
                  not Is_Aggregate (Of_Unit, Item, Slot)
                  and then not Is_Array (Of_Unit, Item, Slot)
                  and then Type_Of (Of_Unit, Item, Slot) = Part.Kind
                  and then Atom_Metadata_Agrees
                    (Part.Atoms, Atom_Set_Of (Of_Unit, Item, Slot)),
               when Landin.Types.Aggregate =>
                  Is_Aggregate (Of_Unit, Item, Slot),
               when Landin.Types.Fixed_Array =>
                  Is_Array (Of_Unit, Item, Slot)
                  and then Slot_Array_Length (Of_Unit, Item, Slot)
                             = Part.Length
                  and then Slot_Array_Element (Of_Unit, Item, Slot)
                             = Part.Element,
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
               when others => False);

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
            declare
               Part : constant Signature_Part :=
                 Nth_Signature_Result (Of_Unit, Signature, Index);
               Shape : constant Field_Shape :=
                 Nth_Slot_Field_Shape (Of_Unit, Item, Slot, Index);
               Agrees : Boolean;
            begin
               case Part.Kind is
                  when Landin.Types.Scalar_Name =>
                     Agrees := Shape.Kind = Scalar_Field_Shape
                       and then Shape.Element = Part.Kind
                       and then Shape.Signature = No_Signature;
                  when Landin.Types.Function_Value =>
                     Agrees := Shape.Kind = Scalar_Field_Shape
                       and then Shape.Element = Landin.Types.Usize
                       and then Holds (Of_Unit, Shape.Signature)
                       and then Signatures_Agree
                         (Of_Unit, Part.Signature, Shape.Signature);
                  when Landin.Types.Aggregate =>
                     Agrees := Shape.Kind = Aggregate_Field_Shape;
                  when Landin.Types.Fixed_Array =>
                     Agrees := Shape.Kind = Array_Field_Shape
                       and then Shape.Length = Part.Length
                       and then
                         (if Part.Aggregate_Body = No_Declaration
                          then not Array_Element_Is_Aggregate
                            (Of_Unit, Shape)
                            and then Shape.Element = Part.Element
                          else Array_Element_Is_Aggregate (Of_Unit, Shape));
                  when others =>
                     Agrees := False;
               end case;
               if not Agrees then
                  return False;
               end if;
            end;
         end loop;
         return True;
      end Results_Agree_With_Slot;

   begin
      if not Is_Prepared (Of_Unit) then
         return (Kind => Unprepared_Unit, others => <>);
      end if;

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
            end;
         end loop;
         if Parts /= Natural (Of_Unit.Signature_Parts.Length) then
            return (Kind => Signature_Runs_Overlap, others => <>);
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
                        if Field_Shape_Is_Malformed
                             (Shape, Aggregate_Allowed => True)
                        then
                           return (Kind => Field_Shape_Malformed,
                                   Item => Id, others => <>);
                        end if;
                     end;
                  end loop;
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
                       or else Parameter_Count (Of_Unit, Id)
                                 /= Signature_Carrier_Count (Signature)
                     then
                        return (Kind => Routine_Signature_Disagrees,
                                Item => Id, others => <>);
                     end if;

                     if (Count = 0
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
                                Result_Slot (Of_Unit, Id))))
                     then
                        return (Kind => Routine_Signature_Disagrees,
                                Item => Id, others => <>);
                     end if;

                     if Hidden = 1 then
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
                  end;
               end;
            end if;
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
                       < Field_Count (Of_Unit, Id)
            then
               return (Kind => Aggregate_Field_Image_Length_Disagrees,
                       Item => Id, others => <>);
            end if;

            if Result_Of (Of_Unit, Id) = Landin.Types.Aggregate
              and then Has_Image (Of_Unit, Id)
              and then Image_Length (Of_Unit, Id)
                       >= Element_Total (Field_Count (Of_Unit, Id))
              and then Aggregate_Field_Image_Count (Of_Unit, Id)
                       >= Field_Count (Of_Unit, Id)
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

                  function Fits
                    (Held : Landin.Types.Folded;
                     Element : Landin.Types.Scalar_Name) return Boolean
                  is (if Element = Landin.Types.Bool
                      then Held in 0 .. 1
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
                                       elsif Check_Image
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
                                          when Selected =>
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
                           elsif Check_Image then
                              if not Fits (Held, Shape.Element) then
                                 return
                                   (Kind =>
                                      Aggregate_Image_Value_Does_Not_Fit,
                                    Item => Id, others => <>);
                              end if;
                           end if;
                        else
                           if Image.Offset /= Expected
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
                              when Selected =>
                                 return
                                   (Kind => Aggregate_Image_On_Variant_Field,
                                    Item => Id, others => <>);
                           end case;

                           if Check_Image then
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
                                    Bad :=
                                      Storage_Address_Is_Not_An_Aggregate;
                                 elsif Field = 0 then
                                    if not Is_Whole_Aggregate (Id, Place)
                                      and then not Is_Whole_Array (Id, Place)
                                    then
                                       Bad :=
                                         Storage_Address_Is_Not_An_Aggregate;
                                    end if;
                                 elsif Nested'Length = 0
                                   and then Is_Whole_Aggregate_Field
                                     (Id, Place, Field)
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

                                    declare
                                       Element : Landin.Types.Scalar_Name;
                                       Bad : constant Fault_Kind :=
                                         Scalar_Field_Of
                                           (Id,
                                            (Kind => Frame_Slot,
                                             Slot => Cell),
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
                                                  (Kind => Frame_Slot,
                                                   Slot => Cell),
                                                  Field_Of (Of_Unit, Id, V),
                                                  Path_Of (Of_Unit, Id, V));
                                             Actual : constant Signature_Id :=
                                               Signature_Of
                                                 (Of_Unit, Id, V);
                                             Expected_Atoms : constant
                                               Atom_Set_Id :=
                                               Scalar_Field_Atoms
                                                 (Id,
                                                  (Kind => Frame_Slot,
                                                   Slot => Cell),
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
                                 Agree : Boolean := True;
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

                                 Agree :=
                                   Source_Shape.Element
                                     = Destination_Shape.Element
                                   and then Source_Shape.Cases
                                     = Destination_Shape.Cases;
                                 if Agree then
                                    for Which in 1 .. Source_Shape.Cases loop
                                       Agree :=
                                         Variant_Case_Field_Count
                                           (Of_Unit, Source_Shape, Which)
                                         = Variant_Case_Field_Count
                                           (Of_Unit, Destination_Shape,
                                            Which);
                                       exit when not Agree;
                                       for Field in 1 ..
                                         Variant_Case_Field_Count
                                           (Of_Unit, Source_Shape, Which)
                                       loop
                                          declare
                                             Source_Leaf : constant
                                               Field_Shape :=
                                                 Nth_Variant_Case_Field
                                                   (Of_Unit, Source_Shape,
                                                    Which, Field);
                                             Destination_Leaf : constant
                                               Field_Shape :=
                                                 Nth_Variant_Case_Field
                                                   (Of_Unit,
                                                    Destination_Shape,
                                                    Which, Field);
                                          begin
                                             Agree :=
                                               Source_Leaf.Kind
                                                 = Destination_Leaf.Kind
                                               and then Source_Leaf.Element
                                                 = Destination_Leaf.Element
                                               and then Source_Leaf.Length
                                                 = Destination_Leaf.Length;
                                          end;
                                          exit when not Agree;
                                       end loop;
                                    end loop;
                                 end if;

                                 if not Agree then
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
                                 if Element.Kind /= Scalar_Field_Shape
                                   or else Result_Of
                                      (Of_Unit, Id,
                                       Nth_Operand (Of_Unit, Id, V, 1))
                                      /= Element.Element
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
                                    Signature_Carrier_Count
                                      (Call_Signature (Of_Unit, Id, V)),
                                 when Indirect_Call =>
                                    Signature_Carrier_Count
                                      (Call_Signature (Of_Unit, Id, V)) + 1,
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
                              if Result_Of (Of_Unit, Id, V)
                                 /= Result_Of
                                      (Of_Unit, Id,
                                       Nth_Operand (Of_Unit, Id, V, 1))
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

                                 if Op = Load_Element then
                                    if Result_Of (Of_Unit, Id, V)
                                       /= Shape_At
                                            (Of_Unit, Element,
                                             Element_Path_Of
                                               (Of_Unit, Id, V)).Element
                                    then
                                       return
                                         (Kind => Result_Disagrees,
                                          Item => Id, Block => Block,
                                          Value => V);
                                    end if;
                                 elsif Result_Of
                                         (Of_Unit, Id,
                                          Nth_Operand (Of_Unit, Id, V, 2))
                                       /= Shape_At
                                            (Of_Unit, Element,
                                             Element_Path_Of
                                               (Of_Unit, Id, V)).Element
                                 then
                                    return
                                      (Kind => Store_Datum_Disagrees,
                                       Item => Id, Block => Block,
                                       Value => V);
                                 end if;
                              end;

                           when Store_Field =>
                              declare
                                 Place : constant Storage :=
                                   (if Reaches_A_Slot (Of_Unit, Id, V)
                                    then (Kind => Frame_Slot,
                                          Slot => Slot_Of
                                            (Of_Unit, Id, V))
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

                           when Function_Address =>
                              if Result_Of (Of_Unit, Id, V)
                                   /= Landin.Types.Usize
                              then
                                 return (Kind => Result_Disagrees,
                                         Item => Id, Block => Block,
                                         Value => V);
                              end if;

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
