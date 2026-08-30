with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Landin.Types;

package body Landin.IR.Dump is

   package Unbounded renames Ada.Strings.Unbounded;

   LF : constant Character := Character'Val (10);

   --  `Integer'Image` leads with a blank for a non-negative number and a
   --  golden file is bytes, so the blank is a byte.  The same trim, for
   --  the same reason, as Landin.Syntax.Dump's.
   function Trimmed (Value : String) return String
     is (Ada.Strings.Fixed.Trim (Value, Ada.Strings.Both));

   function Shown (Item : Landin.Types.Type_Kind) return String
     is (if Item in Landin.Types.Scalar_Name
         then Landin.Types.Spelling (Item)
         elsif Item = Landin.Types.No_Value then "none"
         --  [0710]'s identity is which declaration wrote it, and the item
         --  is named on this line already, so the category is what a dump
         --  can say without repeating the name beside it.
         elsif Item = Landin.Types.Aggregate then "struct"
         elsif Item = Landin.Types.Fixed_Array then "array"
         else "");

   function Text
     (Of_Unit  : Unit;
      Meanings : Landin.Resolution.Table;
      Names    : Landin.Source.Names.Table) return String
   is
      Out_Text : Unbounded.Unbounded_String;

      procedure Put (Line : String);

      procedure Put (Line : String) is
      begin
         Unbounded.Append (Out_Text, Line & LF);
      end Put;

      --  A declaration's spelling, or `-` where nothing declared it --
      --  which is the slot a short circuit's answer crosses its merge in.
      function Named (Id : Declaration_Id) return String;

      function Named (Id : Declaration_Id) return String is
      begin
         if Id = No_Declaration
           or else not Landin.Resolution.Contains (Meanings, Id)
         then
            return "-";
         end if;

         return Landin.Source.Names.Spelling
                  (Names, Landin.Resolution.Name_Of (Meanings, Id));
      end Named;

      function Item_Named (Id : Item_Id) return String
        is (if Holds (Of_Unit, Id)
            then Named (Declares (Of_Unit, Id)) else "-");

      function Atom_Set_Text (Set_Id : Atom_Set_Id) return String;

      function Atom_Set_Text (Set_Id : Atom_Set_Id) return String
      is
         Text : Unbounded.Unbounded_String;
      begin
         if Set_Id = No_Atom_Set then
            return "";
         end if;
         Unbounded.Append (Text, " atoms {");
         for Index in 1 .. Atom_Count (Of_Unit, Set_Id) loop
            if Index > 1 then
               Unbounded.Append (Text, ", ");
            end if;
            Unbounded.Append
              (Text, Named (Nth_Atom (Of_Unit, Set_Id, Index)));
         end loop;
         Unbounded.Append (Text, "}");
         return Unbounded.To_String (Text);
      end Atom_Set_Text;

      function Signature_Part_Text (Part : Signature_Part) return String
        is (case Part.Kind is
               when Landin.Types.No_Value => "none",
               when Landin.Types.Scalar_Name =>
                  Shown (Part.Kind) & Atom_Set_Text (Part.Atoms),
               when Landin.Types.Aggregate =>
                  "struct " & Named (Template_Of (Of_Unit, Part.Nominal)),
               when Landin.Types.Fixed_Array =>
                  "[" & Trimmed (Element_Total'Image (Part.Length)) & "]"
                  & (if Part.Nominal = No_Nominal_Type
                     then Landin.Types.Spelling (Part.Element)
                     else "struct "
                       & Named (Template_Of (Of_Unit, Part.Nominal))),
               when Landin.Types.Function_Value =>
                  "function signature "
                  & Trimmed (Signature_Id'Image (Part.Signature)),
               when Landin.Types.Atom_Value =>
                  "atom-set " & Trimmed (Atom_Set_Id'Image (Part.Atoms)),
               when others => "invalid");

      --  D74/D75 use one target-neutral shape spelling for measurement,
      --  datum and slot runs.  Variant payloads are depth-one leaves, so
      --  their case runs can be rendered without inventing target offsets.
      function Shape_Text (Shape : Field_Shape) return String;

      function Shape_Text (Shape : Field_Shape) return String is
         Result : Unbounded.Unbounded_String;
      begin
         case Shape.Kind is
            when Scalar_Field_Shape =>
               return Landin.Types.Spelling (Shape.Element)
                 & (if Shape.Signature = No_Signature then ""
                    else " signature "
                      & Trimmed (Signature_Id'Image (Shape.Signature)))
                 & Atom_Set_Text (Shape.Atoms);
            when Array_Field_Shape =>
               --  D121: the element may be an ordinary struct, and then it
               --  is spelt by the same one spelling every shape is.
               return "[" & Trimmed (Element_Total'Image (Shape.Length))
                 & "]" & Shape_Text (Array_Element_Shape (Of_Unit, Shape));
            when Aggregate_Field_Shape =>
               Unbounded.Append (Result, "struct (");
               for Field in 1 .. Aggregate_Field_Count
                 (Of_Unit, Shape)
               loop
                  if Field > 1 then
                     Unbounded.Append (Result, ",");
                  end if;
                  Unbounded.Append
                    (Result,
                     Shape_Text
                       (Nth_Aggregate_Field (Of_Unit, Shape, Field)));
               end loop;
               Unbounded.Append (Result, ")");
               return Unbounded.To_String (Result);
            when Variant_Field_Shape =>
               Unbounded.Append
                 (Result,
                  "variant " & Landin.Types.Spelling (Shape.Element)
                  & " cases" & Trimmed (Natural'Image (Shape.Cases)));
               for Which in 1 .. Shape.Cases loop
                  Unbounded.Append (Result, " (");
                  for Payload in 1 .. Variant_Case_Field_Count
                    (Of_Unit, Shape, Which)
                  loop
                     if Payload > 1 then
                        Unbounded.Append (Result, ",");
                     end if;
                     --  D120 lets a payload be an ordinary struct, so a
                     --  payload is spelt by the same one spelling every
                     --  other shape is.
                     Unbounded.Append
                       (Result,
                        Shape_Text
                          (Nth_Variant_Case_Field
                             (Of_Unit, Shape, Which, Payload)));
                  end loop;
                  Unbounded.Append (Result, ")");
               end loop;
               return Unbounded.To_String (Result);
         end case;
      end Shape_Text;

      procedure Put_Recursive_Image
        (Item   : Item_Id;
         Prefix : String;
         Shape  : Field_Shape;
         Image  : Aggregate_Field_Image);

      procedure Put_Recursive_Image
        (Item   : Item_Id;
         Prefix : String;
         Shape  : Field_Shape;
         Image  : Aggregate_Field_Image)
      is
         Rendered : Unbounded.Unbounded_String;
      begin
         case Shape.Kind is
            when Scalar_Field_Shape =>
               Put
                 (Prefix
                  & (if Shape.Signature /= No_Signature
                     then " function target "
                       & Trimmed (Item_Id'Image (Image.Target))
                     else " image "
                       & Trimmed
                           (Landin.Types.Folded'Image (Image.Value))));

            when Array_Field_Shape =>
               if Image.Form = Absent then
                  Put (Prefix & " zeroed");
                  return;
               end if;
               if Image.Form in Finite | Hybrid then
                  for Position in 1 .. Image.Count loop
                     if Position /= 1 then
                        Unbounded.Append (Rendered, " ");
                     end if;
                     Unbounded.Append
                       (Rendered,
                        Trimmed
                          (Landin.Types.Folded'Image
                             (Nth_Descriptor_Element
                                (Of_Unit, Item, Image,
                                 Part_Position (Position)))));
                  end loop;
               end if;
               if Image.Form in Repeated | Hybrid then
                  if Image.Form = Hybrid then
                     Unbounded.Append (Rendered, " ");
                  end if;
                  Unbounded.Append
                    (Rendered,
                     "repeat "
                     & Trimmed
                         (Landin.Types.Folded'Image (Image.Value)));
               end if;
               Put (Prefix & " image " & Unbounded.To_String (Rendered));

            when Aggregate_Field_Shape =>
               if Image.Form = Absent then
                  Put (Prefix & " zeroed");
               else
                  Put (Prefix & " nested");
                  for Child in 1 .. Image.Count loop
                     Put_Recursive_Image
                       (Item,
                        Prefix & "."
                        & Trimmed (Natural'Image (Child)),
                        Nth_Aggregate_Field (Of_Unit, Shape, Child),
                        Descendant_Image_Of
                          (Of_Unit, Item, Image, Child));
                  end loop;
               end if;

            when Variant_Field_Shape =>
               if Image.Form = Absent then
                  Put (Prefix & " zeroed");
               else
                  Put
                    (Prefix & " case "
                     & Trimmed
                         (Landin.Types.Folded'Image (Image.Value)));
                  for Payload in 1 .. Image.Count loop
                     Put_Recursive_Image
                       (Item,
                        Prefix & " payload "
                        & Trimmed (Natural'Image (Payload)),
                        Nth_Variant_Case_Field
                          (Of_Unit, Shape, Positive (Image.Value), Payload),
                        Descendant_Image_Of
                          (Of_Unit, Item, Image, Payload));
                  end loop;
               end if;
         end case;
      end Put_Recursive_Image;

      --  Every operand of every opcode, in one run, whatever the opcode.
      function Operands (Item : Item_Id; Value : Value_Id) return String;

      function Operands (Item : Item_Id; Value : Value_Id) return String is
         Run : Unbounded.Unbounded_String;
      begin
         for Index in 1 .. Operand_Count (Of_Unit, Item, Value) loop
            Unbounded.Append
              (Run,
               " " & Trimmed
                       (Value_Id'Image
                          (Nth_Operand (Of_Unit, Item, Value, Index))));
         end loop;

         if Unbounded.Length (Run) = 0 then
            return "";
         end if;

         return " <-" & Unbounded.To_String (Run);
      end Operands;

      function Endpoint (Place : Storage) return String;

      function Endpoint (Place : Storage) return String is
      begin
         case Place.Kind is
            when Module_Datum =>
               return "datum " & Trimmed (Item_Id'Image (Place.Datum))
                 & " " & Item_Named (Place.Datum);
            when Frame_Slot =>
               return "slot " & Trimmed (Slot_Id'Image (Place.Slot));
            when Runtime_Address =>
               return "address slot "
                 & Trimmed (Slot_Id'Image (Place.Address));
         end case;
      end Endpoint;

      function Rendered (Item : Item_Id; Value : Value_Id) return String;

      function Rendered (Item : Item_Id; Value : Value_Id) return String
      is
         function Variant_Qualifier return String;

         function Variant_Qualifier return String is
         begin
            if Variant_Payload_Field_Of (Of_Unit, Item, Value) = 0 then
               return "";
            end if;
            return " case "
              & Trimmed
                  (Natural'Image
                     (Variant_Case_Of (Of_Unit, Item, Value)))
              & " payload field "
              & Trimmed
                  (Natural'Image
                     (Variant_Payload_Field_Of
                        (Of_Unit, Item, Value)));
         end Variant_Qualifier;

         --  D118's subobject path.  One step still reads as the `nested`
         --  the parent/child pair spelt, and a further step is another
         --  one, so a recorded run says which part of which child an
         --  operation reached rather than only that it reached one.
         function Path_Qualifier return String;

         function Path_Qualifier return String is
            Path : constant Path_Step_Array :=
              Path_Of (Of_Unit, Item, Value);
            Text : Unbounded.Unbounded_String;
         begin
            for Step of Path loop
               if Step.Case_Index /= 0 then
                  Unbounded.Append
                    (Text,
                     " case "
                     & Trimmed (Natural'Image (Step.Case_Index)));
               end if;
               Unbounded.Append
                 (Text,
                  " nested "
                  & Trimmed (Part_Position'Image (Step.Field)));
            end loop;
            return Unbounded.To_String (Text);
         end Path_Qualifier;

         --  D121's run inside an indexed element.  Without it a recorded
         --  run could not tell `a[i].x` from `a[i].y`.
         function Below_Qualifier return String;

         function Below_Qualifier return String is
            Path : constant Path_Step_Array :=
              (if Op_Of (Of_Unit, Item, Value)
                    in Load_Element | Store_Element
               then Element_Path_Of (Of_Unit, Item, Value)
               else No_Path_Steps);
            Text : Unbounded.Unbounded_String;
         begin
            for Step of Path loop
               Unbounded.Append
                 (Text,
                  " inside "
                  & Trimmed (Part_Position'Image (Step.Field)));
            end loop;
            return Unbounded.To_String (Text);
         end Below_Qualifier;

         function Source_Path_Qualifier return String;

         function Source_Path_Qualifier return String is
            Path : constant Path_Step_Array :=
              Source_Path_Of (Of_Unit, Item, Value);
            Text : Unbounded.Unbounded_String;
         begin
            for Step of Path loop
               if Step.Case_Index /= 0 then
                  Unbounded.Append
                    (Text,
                     " case "
                     & Trimmed (Natural'Image (Step.Case_Index)));
               end if;
               Unbounded.Append
                 (Text,
                  " nested "
                  & Trimmed (Part_Position'Image (Step.Field)));
            end loop;
            return Unbounded.To_String (Text);
         end Source_Path_Qualifier;

         Op : constant Opcode := Op_Of (Of_Unit, Item, Value);
         Held : constant String := Shown (Result_Of (Of_Unit, Item, Value));
         Lead : constant String :=
           Trimmed (Value_Id'Image (Value)) & " " & Opcode'Image (Op)
           & (if Held = "" then "" else " " & Held);
      begin
         case Op is
            when Number =>
               return Lead & " "
                      & Trimmed
                          (Landin.Types.Magnitude'Image
                             (Number_Of (Of_Unit, Item, Value)))
                      & (if Is_Negated (Of_Unit, Item, Value)
                         then " negated" else "");

            when Truth =>
               return Lead & " "
                      & (if Truth_Of (Of_Unit, Item, Value)
                         then "true" else "false");

            when Atom =>
               return Lead & " identity "
                 & Named (Atom_Of (Of_Unit, Item, Value))
                 & Atom_Set_Text (Atom_Set_Of (Of_Unit, Item, Value));

            when Load | Store =>
               return Lead & " slot "
                      & Trimmed
                          (Slot_Id'Image (Slot_Of (Of_Unit, Item, Value)))
                      & Operands (Item, Value);

            when Storage_Address =>
               return Lead & " storage "
                 & Endpoint (Destination_Of (Of_Unit, Item, Value))
                 & (if Element_Field_Of (Of_Unit, Item, Value) = 0
                    then ""
                    else " field "
                      & Trimmed
                          (Natural'Image
                             (Element_Field_Of (Of_Unit, Item, Value))))
                 & Path_Qualifier
                 & Operands (Item, Value);

            when Load_Datum | Store_Datum =>
               declare
                  D : constant Item_Id := Datum_Of (Of_Unit, Item, Value);
               begin
                  return Lead & " datum " & Trimmed (Item_Id'Image (D))
                         & " " & Item_Named (D)
                         & Operands (Item, Value);
               end;

            when Load_Element | Store_Element =>
               if Reaches_A_Slot (Of_Unit, Item, Value) then
                  return Lead & " slot "
                         & Trimmed
                             (Slot_Id'Image (Slot_Of (Of_Unit, Item, Value)))
                         & (if Element_Field_Of (Of_Unit, Item, Value) = 0
                            then ""
                            else " field "
                              & Trimmed
                                  (Natural'Image
                                     (Element_Field_Of
                                        (Of_Unit, Item, Value))))
                         & Variant_Qualifier
                         & Path_Qualifier
                         & Below_Qualifier
                         & Operands (Item, Value);
               end if;

               declare
                  D : constant Item_Id := Datum_Of (Of_Unit, Item, Value);
               begin
                  return Lead & " datum " & Trimmed (Item_Id'Image (D))
                         & " " & Item_Named (D)
                         & (if Element_Field_Of (Of_Unit, Item, Value) = 0
                            then ""
                            else " field "
                              & Trimmed
                                  (Natural'Image
                                     (Element_Field_Of
                                        (Of_Unit, Item, Value))))
                         & Variant_Qualifier
                         & Path_Qualifier
                         & Below_Qualifier
                         & Operands (Item, Value);
               end;

            when Copy_Array =>
               return Lead & " from "
                 & Endpoint (Source_Of (Of_Unit, Item, Value))
                 & (if Source_Field_Of (Of_Unit, Item, Value) = 0
                    then ""
                    else " field "
                      & Trimmed
                          (Natural'Image
                             (Source_Field_Of (Of_Unit, Item, Value))))
                 & Source_Path_Qualifier
                 & " to " & Endpoint (Destination_Of (Of_Unit, Item, Value))
                 & (if Element_Field_Of (Of_Unit, Item, Value) = 0
                    then ""
                    else " field "
                      & Trimmed
                          (Natural'Image
                             (Element_Field_Of (Of_Unit, Item, Value))))
                 & Variant_Qualifier
                 & Path_Qualifier;

            when Copy_Variant =>
               return Lead & " from "
                 & Endpoint (Source_Of (Of_Unit, Item, Value))
                 & " field "
                 & Trimmed
                     (Natural'Image
                        (Source_Field_Of (Of_Unit, Item, Value)))
                 & Source_Path_Qualifier
                 & " to "
                 & Endpoint (Destination_Of (Of_Unit, Item, Value))
                 & " field "
                 & Trimmed
                     (Natural'Image
                        (Element_Field_Of (Of_Unit, Item, Value)))
                 & Path_Qualifier;

            when Clear_Array =>
               return Lead & " destination "
                 & Endpoint (Destination_Of (Of_Unit, Item, Value))
                 & (if Element_Field_Of (Of_Unit, Item, Value) = 0
                    then ""
                    else " field "
                      & Trimmed
                          (Natural'Image
                             (Element_Field_Of (Of_Unit, Item, Value))))
                 & Path_Qualifier;

            when Fill_Array =>
               return Lead & " destination "
                 & Endpoint (Destination_Of (Of_Unit, Item, Value))
                 & (if Element_Field_Of (Of_Unit, Item, Value) = 0
                    then ""
                    else " field "
                      & Trimmed
                          (Natural'Image
                             (Element_Field_Of (Of_Unit, Item, Value))))
                 & Variant_Qualifier
                 & Path_Qualifier
                 & " first "
                 & Trimmed
                     (Part_Position'Image
                        (First_Part_Of (Of_Unit, Item, Value)))
                 & Operands (Item, Value);

            when Load_Variant_Tag =>
               return Lead & " from "
                 & Endpoint (Source_Of (Of_Unit, Item, Value))
                 & " field "
                 & Trimmed
                     (Natural'Image
                        (Element_Field_Of (Of_Unit, Item, Value)))
                 & Path_Qualifier;

            when Load_Variant_Field =>
               return Lead & " from "
                 & Endpoint (Source_Of (Of_Unit, Item, Value))
                 & " field "
                 & Trimmed
                     (Natural'Image
                        (Element_Field_Of (Of_Unit, Item, Value)))
                 & Path_Qualifier
                 & " case "
                 & Trimmed
                     (Natural'Image
                        (Variant_Case_Of (Of_Unit, Item, Value)))
                 & " payload field "
                 & Trimmed
                     (Natural'Image
                        (Variant_Payload_Field_Of
                           (Of_Unit, Item, Value)));

            when Select_Variant =>
               return Lead & " destination "
                 & Endpoint (Destination_Of (Of_Unit, Item, Value))
                 & " field "
                 & Trimmed
                     (Natural'Image
                        (Element_Field_Of (Of_Unit, Item, Value)))
                 & Path_Qualifier
                 & " case "
                 & Trimmed
                     (Natural'Image
                        (Variant_Case_Of (Of_Unit, Item, Value)));

            when Store_Variant_Field =>
               return Lead & " destination "
                 & Endpoint (Destination_Of (Of_Unit, Item, Value))
                 & " field "
                 & Trimmed
                     (Natural'Image
                        (Element_Field_Of (Of_Unit, Item, Value)))
                 & Path_Qualifier
                 & " case "
                 & Trimmed
                     (Natural'Image
                        (Variant_Case_Of (Of_Unit, Item, Value)))
                 & " payload field "
                 & Trimmed
                     (Natural'Image
                        (Variant_Payload_Field_Of
                           (Of_Unit, Item, Value)))
                 & Operands (Item, Value);

            when Measure_Size | Measure_Align =>
               if not Is_Aggregate_Measurement (Of_Unit, Item, Value) then
                  return Lead & Operands (Item, Value);
               end if;

               declare
                  Fields : Unbounded.Unbounded_String;
               begin
                  for Field in
                    1 .. Measurement_Field_Count (Of_Unit, Item, Value)
                  loop
                     declare
                        Part : constant Field_Shape :=
                          Nth_Measurement_Field
                            (Of_Unit, Item, Value, Field);
                     begin
                        Unbounded.Append
                          (Fields, " " & Shape_Text (Part));
                     end;
                  end loop;
                  return Lead & " fields" & Unbounded.To_String (Fields);
               end;

            when Function_Address =>
               declare
                  C : constant Item_Id := Callee_Of (Of_Unit, Item, Value);
               begin
                  return Lead & " target " & Trimmed (Item_Id'Image (C))
                    & " " & Item_Named (C) & " signature "
                    & Trimmed
                        (Signature_Id'Image
                           (Signature_Of (Of_Unit, Item, Value)));
               end;

            when Call =>
               declare
                  C : constant Item_Id := Callee_Of (Of_Unit, Item, Value);
               begin
                  return Lead & " callee " & Trimmed (Item_Id'Image (C))
                         & " " & Item_Named (C)
                         & " signature "
                         & Trimmed
                             (Signature_Id'Image
                                (Call_Signature (Of_Unit, Item, Value)))
                         & (if Failure_Slot_Of (Of_Unit, Item, Value)
                                  = No_Slot
                            then ""
                            else " failure slot "
                              & Trimmed
                                  (Slot_Id'Image
                                     (Failure_Slot_Of
                                        (Of_Unit, Item, Value))))
                         & Operands (Item, Value);
               end;

            when Indirect_Call =>
               return Lead & " signature "
                 & Trimmed
                     (Signature_Id'Image
                        (Call_Signature (Of_Unit, Item, Value)))
                 & (if Failure_Slot_Of (Of_Unit, Item, Value) = No_Slot
                    then ""
                    else " failure slot "
                      & Trimmed
                          (Slot_Id'Image
                             (Failure_Slot_Of (Of_Unit, Item, Value))))
                 & Operands (Item, Value);

            when Jump =>
               return Lead & " target "
                      & Trimmed
                          (Block_Id'Image
                             (Target_Of (Of_Unit, Item, Value)));

            when Branch =>
               return Lead & " target "
                      & Trimmed
                          (Block_Id'Image
                             (Target_Of (Of_Unit, Item, Value)))
                      & " alternative "
                      & Trimmed
                          (Block_Id'Image
                             (Alternative_Of (Of_Unit, Item, Value)))
                      & Operands (Item, Value);

            --  Which field, and since D118 which part below it.  Without
            --  both, a recorded run cannot tell `a.b.c` from `a.b.d`, and
            --  a fixture over deeper storage would assert nothing.
            when Load_Field | Store_Field =>
               return Lead & " "
                 & (if Reaches_A_Slot (Of_Unit, Item, Value)
                    then "slot "
                      & Trimmed
                          (Slot_Id'Image (Slot_Of (Of_Unit, Item, Value)))
                    else Endpoint
                           ((Kind  => Module_Datum,
                             Datum => Datum_Of (Of_Unit, Item, Value))))
                 & " field "
                 & Trimmed
                     (Part_Position'Image (Field_Of (Of_Unit, Item, Value)))
                 & Path_Qualifier
                 & Operands (Item, Value);

            when others =>
               return Lead & Operands (Item, Value);
         end case;
      end Rendered;

   begin
      Put
        ("unit signatures "
         & Trimmed (Natural'Image (Signature_Count (Of_Unit)))
         & " items " & Trimmed (Natural'Image (Item_Count (Of_Unit))));

      for Which in 1 .. Atom_Set_Count (Of_Unit) loop
         Put
           ("atom set " & Trimmed (Atom_Set_Id'Image (Atom_Set_Id (Which)))
            & Atom_Set_Text (Atom_Set_Id (Which)));
      end loop;

      for Which in 1 .. Signature_Count (Of_Unit) loop
         declare
            Id : constant Signature_Id := Signature_Id (Which);
            Parameters : Unbounded.Unbounded_String;
            Results : Unbounded.Unbounded_String;
         begin
            for Index in 1 .. Signature_Parameter_Count (Of_Unit, Id) loop
               if Index > 1 then
                  Unbounded.Append (Parameters, ", ");
               end if;
               Unbounded.Append
                 (Parameters,
                  Signature_Part_Text
                    (Nth_Signature_Parameter (Of_Unit, Id, Index)));
            end loop;
            for Index in 1 .. Signature_Result_Count (Of_Unit, Id) loop
               if Index > 1 then
                  Unbounded.Append (Results, ", ");
               end if;
               Unbounded.Append
                 (Results,
                  Signature_Part_Text
                    (Nth_Signature_Result (Of_Unit, Id, Index)));
            end loop;
            Put
              ("signature " & Trimmed (Signature_Id'Image (Id))
               & " (" & Unbounded.To_String (Parameters) & ") -> "
               & (if Signature_Result_Count (Of_Unit, Id) = 0
                  then "none"
                  elsif Signature_Result_Count (Of_Unit, Id) = 1
                  then Unbounded.To_String (Results)
                  else "(" & Unbounded.To_String (Results) & ")")
               & (if Signature_Errors (Of_Unit, Id) = No_Atom_Set
                  then ""
                  else " errors"
                    & Atom_Set_Text (Signature_Errors (Of_Unit, Id))));
         end;
      end loop;

      for Which in 1 .. Item_Count (Of_Unit) loop
         declare
            Id : constant Item_Id := Item_Id (Which);
            Claimed : array (1 .. Positive'Max
                                    (1, Value_Count (Of_Unit, Id)))
              of Boolean := [others => False];
         begin
            Put ("item " & Trimmed (Item_Id'Image (Id))
                 & " " & Item_Kind'Image (Kind_Of (Of_Unit, Id))
                 & " " & Item_Named (Id)
                 & " result " & Shown (Result_Of (Of_Unit, Id))
                 & Atom_Set_Text (Atom_Set_Of (Of_Unit, Id))
                 & (if Signature_Of (Of_Unit, Id) = No_Signature then ""
                    else " signature "
                      & Trimmed
                          (Signature_Id'Image
                             (Signature_Of (Of_Unit, Id))))
                 & (if Function_Target (Of_Unit, Id) = No_Item then ""
                    else " function target "
                      & Trimmed
                          (Item_Id'Image (Function_Target (Of_Unit, Id))))
                 & " params "
                 & Trimmed (Natural'Image (Parameter_Count (Of_Unit, Id)))
                 & " slots "
                 & Trimmed (Natural'Image (Slot_Count (Of_Unit, Id)))
                 & " blocks "
                 & Trimmed (Natural'Image (Block_Count (Of_Unit, Id)))
                 & " values "
                 & Trimmed (Natural'Image (Value_Count (Of_Unit, Id))));

            --  [0520]'s shape, which is the whole of what an array item
            --  says about itself: how many bytes that comes to needs a
            --  target and a dump has none.
            if Result_Of (Of_Unit, Id) = Landin.Types.Fixed_Array then
               Put ("  elements "
                    & Trimmed (Element_Total'Image
                                 (Array_Length (Of_Unit, Id)))
                    & " of "
                    & Shape_Text (Array_Element_Shape (Of_Unit, Id)));

               --  D24: an initial image is the source-order run of folded
               --  values.  An array datum with no image is D10's zero and
               --  says so by omitting this line.
               if Is_Repeated_Image (Of_Unit, Id) then
                  declare
                     Rendered : Unbounded.Unbounded_String;
                     Prefix : constant Element_Total :=
                       Image_Prefix_Length (Of_Unit, Id);
                  begin
                     if Prefix > 0 then
                        Unbounded.Append (Rendered, " prefix");
                        for P in Part_Position'(1)
                                 .. Part_Position (Prefix)
                        loop
                           Unbounded.Append
                             (Rendered,
                              " " & Trimmed
                                (Landin.Types.Folded'Image
                                   (Nth_Image (Of_Unit, Id, P))));
                        end loop;
                     end if;
                     Unbounded.Append
                       (Rendered,
                        " repeat " & Trimmed
                          (Landin.Types.Folded'Image
                             (Repeated_Image_Value (Of_Unit, Id))));
                     Put ("  image" & Unbounded.To_String (Rendered));
                  end;
               elsif Has_Image (Of_Unit, Id) then
                  declare
                     Rendered : Unbounded.Unbounded_String;
                  begin
                     for P in Part_Position'(1)
                              .. Part_Position (Image_Length (Of_Unit, Id))
                     loop
                        if P /= 1 then
                           Unbounded.Append (Rendered, " ");
                        end if;
                        Unbounded.Append
                          (Rendered,
                           Trimmed
                             (Landin.Types.Folded'Image
                                (Nth_Image (Of_Unit, Id, P))));
                     end loop;
                     Put ("  image "
                          & Unbounded.To_String (Rendered));
                  end;
               end if;
            end if;

            --  [0750]'s order, which is the whole of what an aggregate
            --  item says about itself: where each field sits needs a
            --  target and a dump has none.
            for F in 1 .. Field_Count (Of_Unit, Id) loop
               declare
                  Shape : constant Field_Shape :=
                    Nth_Field_Shape (Of_Unit, Id, F);
               begin
                  Put
                    ("  field " & Trimmed (Natural'Image (F)) & " "
                     & Shape_Text (Shape));
               end;
            end loop;

            --  D66: aggregate images begin with declaration-order field folds.
            --  Omitted and explicit whole-zero images have no run and keep
            --  the dump unchanged; a fixed-array field's zero placeholder is
            --  shown like every other entry without inventing target bytes.
            --  D67 prints each finite field segment separately, still as
            --  folds rather than target widths, offsets or padding.
            if Result_Of (Of_Unit, Id) = Landin.Types.Aggregate
              and then Has_Image (Of_Unit, Id)
            then
               declare
                  Rendered : Unbounded.Unbounded_String;
               begin
                  for F in 1 .. Field_Count (Of_Unit, Id) loop
                     if F /= 1 then
                        Unbounded.Append (Rendered, " ");
                     end if;
                     Unbounded.Append
                       (Rendered,
                        Trimmed
                          (Landin.Types.Folded'Image
                             (Nth_Field_Image (Of_Unit, Id, F))));
                  end loop;
                  Put ("  image " & Unbounded.To_String (Rendered));
               end;

               for F in 1 .. Field_Count (Of_Unit, Id) loop
                  declare
                     Image : constant Aggregate_Field_Image :=
                       Field_Image_Of (Of_Unit, Id, F);
                     Rendered : Unbounded.Unbounded_String;
                  begin
                     if Image.Form = Nested then
                        Put_Recursive_Image
                          (Id,
                           "  field " & Trimmed (Natural'Image (F)),
                           Nth_Field_Shape (Of_Unit, Id, F), Image);
                     elsif Image.Form = Selected then
                        Put
                          ("  field " & Trimmed (Natural'Image (F))
                           & " case "
                           & Trimmed
                               (Landin.Types.Folded'Image (Image.Value)));
                        declare
                           Shape : constant Field_Shape :=
                             Nth_Field_Shape (Of_Unit, Id, F);
                        begin
                           for Payload in 1 .. Image.Count loop
                              declare
                                 Leaf : constant Field_Shape :=
                                   Nth_Variant_Case_Field
                                     (Of_Unit, Shape,
                                      Positive (Image.Value), Payload);
                                 Payload_Image : constant
                                   Aggregate_Field_Image :=
                                     Variant_Payload_Image_Of
                                       (Of_Unit, Id, F, Payload);
                              begin
                                 Unbounded.Set_Unbounded_String
                                   (Rendered, "");
                                 if Leaf.Kind = Scalar_Field_Shape then
                                    Put
                                      ("    payload "
                                       & Trimmed
                                           (Natural'Image (Payload))
                                       & (if Leaf.Signature /= No_Signature
                                          then " function target "
                                            & Trimmed
                                              (Item_Id'Image
                                                 (Payload_Image.Target))
                                          else " image "
                                            & Trimmed
                                              (Landin.Types.Folded'Image
                                                 (Payload_Image.Value))));
                                 elsif Payload_Image.Form = Nested then
                                    Put_Recursive_Image
                                      (Id,
                                       "    payload "
                                       & Trimmed
                                           (Natural'Image (Payload)),
                                       Leaf, Payload_Image);
                                 elsif Payload_Image.Form = Absent then
                                    Put
                                      ("    payload "
                                       & Trimmed
                                           (Natural'Image (Payload))
                                       & " zeroed");
                                 else
                                    if Payload_Image.Form
                                      in Finite | Hybrid
                                    then
                                       for P in 1 .. Payload_Image.Count loop
                                          if P /= 1 then
                                             Unbounded.Append
                                               (Rendered, " ");
                                          end if;
                                          Unbounded.Append
                                            (Rendered,
                                             Trimmed
                                               (Landin.Types.Folded'Image
                                                  (Nth_Variant_Field_Element
                                                     (Of_Unit, Id, F,
                                                      Payload,
                                                      Part_Position (P)))));
                                       end loop;
                                    end if;

                                    if Payload_Image.Form
                                      in Repeated | Hybrid
                                    then
                                       if Payload_Image.Form = Hybrid then
                                          Unbounded.Append (Rendered, " ");
                                       end if;
                                       Unbounded.Append
                                         (Rendered,
                                          "repeat "
                                          & Trimmed
                                              (Landin.Types.Folded'Image
                                                 (Payload_Image.Value)));
                                    end if;

                                    Put
                                      ("    payload "
                                       & Trimmed
                                           (Natural'Image (Payload))
                                       & " image "
                                       & Unbounded.To_String (Rendered));
                                 end if;
                              end;
                           end loop;
                        end;
                     elsif Image.Target /= No_Item then
                        Put
                          ("  field " & Trimmed (Natural'Image (F))
                           & " function target "
                           & Trimmed (Item_Id'Image (Image.Target)));
                     elsif Image.Form /= Absent then
                        if Image.Form in Finite | Hybrid then
                           for P in 1 .. Image.Count loop
                              if P /= 1 then
                                 Unbounded.Append (Rendered, " ");
                              end if;
                              Unbounded.Append
                                (Rendered,
                                 Trimmed
                                   (Landin.Types.Folded'Image
                                      (Nth_Field_Element
                                         (Of_Unit, Id, F,
                                          Part_Position (P)))));
                           end loop;
                        end if;

                        if Image.Form in Repeated | Hybrid then
                           if Image.Form = Hybrid then
                              Unbounded.Append (Rendered, " ");
                           end if;
                           Unbounded.Append
                             (Rendered,
                              "repeat "
                              & Trimmed
                                  (Landin.Types.Folded'Image (Image.Value)));
                        end if;

                        Put
                          ("  field " & Trimmed (Natural'Image (F))
                           & " image " & Unbounded.To_String (Rendered));
                     end if;
                  end;
               end loop;
            end if;

            for S in 1 .. Slot_Count (Of_Unit, Id) loop
               declare
                  Slot : constant Slot_Id := Slot_Id (S);
                  Marks : Unbounded.Unbounded_String;
                  Fields : Unbounded.Unbounded_String;
               begin
                  --  The marks come from Nth_Parameter and Result_Slot,
                  --  so a unit whose counts and marks disagree says so.
                  for P in 1 .. Parameter_Count (Of_Unit, Id) loop
                     if Nth_Parameter (Of_Unit, Id, P) = Slot then
                        Unbounded.Append
                          (Marks,
                           " param " & Trimmed (Natural'Image (P)));
                     end if;
                  end loop;

                  if Result_Slot (Of_Unit, Id) = Slot then
                     Unbounded.Append (Marks, " return");
                  end if;

                  if Is_Aggregate (Of_Unit, Id, Slot) then
                     for Field in
                       1 .. Slot_Field_Count (Of_Unit, Id, Slot)
                     loop
                        declare
                           Shape : constant Field_Shape :=
                             Nth_Slot_Field_Shape
                               (Of_Unit, Id, Slot, Field);
                        begin
                           Unbounded.Append
                             (Fields, " " & Shape_Text (Shape));
                        end;
                     end loop;
                  end if;

                  Put
                    ("  slot " & Trimmed (Slot_Id'Image (Slot))
                     & " " & Named (Declares (Of_Unit, Id, Slot)) & " "
                     & (if Is_Array (Of_Unit, Id, Slot)
                        then "elements "
                             & Trimmed
                                 (Element_Total'Image
                                    (Slot_Array_Length (Of_Unit, Id, Slot)))
                             & " of "
                             & Shape_Text
                                 (Slot_Array_Element_Shape
                                    (Of_Unit, Id, Slot))
                        elsif Is_Aggregate (Of_Unit, Id, Slot)
                        then "aggregate fields"
                             & Unbounded.To_String (Fields)
                        else Landin.Types.Spelling
                               (Type_Of (Of_Unit, Id, Slot)))
                     & Atom_Set_Text (Atom_Set_Of (Of_Unit, Id, Slot))
                     & (if Signature_Of (Of_Unit, Id, Slot) = No_Signature
                        then ""
                        else " signature "
                          & Trimmed
                              (Signature_Id'Image
                                 (Signature_Of (Of_Unit, Id, Slot))))
                     & Unbounded.To_String (Marks));
               end;
            end loop;

            for B in 1 .. Block_Count (Of_Unit, Id) loop
               declare
                  Block : constant Block_Id := Block_Id (B);
                  Scope : constant Scope_Id := Scope_Of (Of_Unit, Id,
                                                         Block);
               begin
                  Put ("  block " & Trimmed (Block_Id'Image (Block))
                       & " scope " & Trimmed (Scope_Id'Image (Scope))
                       & " "
                       & (if Landin.Resolution.Holds (Meanings, Scope)
                          then Landin.Resolution.Scope_Sort'Image
                                 (Landin.Resolution.Sort_Of
                                    (Meanings, Scope))
                          else "-")
                       & " length "
                       & Trimmed
                           (Natural'Image (Length (Of_Unit, Id, Block))));

                  for Position in 1 .. Length (Of_Unit, Id, Block) loop
                     declare
                        V : constant Value_Id :=
                          Nth_Value (Of_Unit, Id, Block, Position);
                     begin
                        Claimed (Positive (V)) := True;
                        Put ("    " & Rendered (Id, V));
                     end;
                  end loop;
               end;
            end loop;

            --  An instruction no block claimed is a builder defect, and
            --  three of that family have already been found in this item.
            --  A dump that dropped one silently would be the wrong tool
            --  to hold in your hand while looking for the fourth.
            declare
               Loose : Unbounded.Unbounded_String;
            begin
               for V in 1 .. Value_Count (Of_Unit, Id) loop
                  if not Claimed (V) then
                     Unbounded.Append
                       (Loose, " " & Trimmed (Natural'Image (V)));
                  end if;
               end loop;

               if Unbounded.Length (Loose) > 0 then
                  Put ("  loose" & Unbounded.To_String (Loose));
               end if;
            end;
         end;
      end loop;

      return Unbounded.To_String (Out_Text);
   end Text;

end Landin.IR.Dump;
