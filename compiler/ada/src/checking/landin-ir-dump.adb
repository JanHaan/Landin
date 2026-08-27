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
         end case;
      end Endpoint;

      function Rendered (Item : Item_Id; Value : Value_Id) return String;

      function Rendered (Item : Item_Id; Value : Value_Id) return String
      is
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

            when Load | Store =>
               return Lead & " slot "
                      & Trimmed
                          (Slot_Id'Image (Slot_Of (Of_Unit, Item, Value)))
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
                         & Operands (Item, Value);
               end;

            when Copy_Array =>
               return Lead & " from "
                 & Endpoint (Source_Of (Of_Unit, Item, Value))
                 & " to " & Endpoint (Destination_Of (Of_Unit, Item, Value));

            when Clear_Array =>
               return Lead & " destination "
                 & Endpoint (Destination_Of (Of_Unit, Item, Value))
                 & (if Element_Field_Of (Of_Unit, Item, Value) = 0
                    then ""
                    else " field "
                      & Trimmed
                          (Natural'Image
                             (Element_Field_Of (Of_Unit, Item, Value))));

            when Fill_Array =>
               return Lead & " destination "
                 & Endpoint (Destination_Of (Of_Unit, Item, Value))
                 & " first "
                 & Trimmed
                     (Part_Position'Image
                        (First_Part_Of (Of_Unit, Item, Value)))
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
                        Unbounded.Append (Fields, " ");
                        if Part.Kind = Scalar_Field_Shape then
                           Unbounded.Append
                             (Fields, Landin.Types.Spelling (Part.Element));
                        else
                           Unbounded.Append
                             (Fields,
                              "[" & Trimmed
                                (Element_Total'Image (Part.Length))
                              & "]" & Landin.Types.Spelling (Part.Element));
                        end if;
                     end;
                  end loop;
                  return Lead & " fields" & Unbounded.To_String (Fields);
               end;

            when Call =>
               declare
                  C : constant Item_Id := Callee_Of (Of_Unit, Item, Value);
               begin
                  return Lead & " callee " & Trimmed (Item_Id'Image (C))
                         & " " & Item_Named (C)
                         & Operands (Item, Value);
               end;

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

            when others =>
               return Lead & Operands (Item, Value);
         end case;
      end Rendered;

   begin
      Put ("unit items " & Trimmed (Natural'Image (Item_Count (Of_Unit))));

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
                    & Landin.Types.Spelling (Array_Element (Of_Unit, Id)));

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
                     & (if Shape.Kind = Scalar_Field_Shape
                        then Landin.Types.Spelling (Shape.Element)
                        else "[" & Trimmed
                          (Element_Total'Image (Shape.Length)) & "]"
                          & Landin.Types.Spelling (Shape.Element)));
               end;
            end loop;

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
                           Unbounded.Append (Fields, " ");
                           if Shape.Kind = Array_Field_Shape then
                              Unbounded.Append
                                (Fields,
                                 "[" & Trimmed
                                   (Element_Total'Image (Shape.Length))
                                 & "]");
                           end if;
                           Unbounded.Append
                             (Fields, Landin.Types.Spelling (Shape.Element));
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
                             & Landin.Types.Spelling
                                 (Slot_Array_Element (Of_Unit, Id, Slot))
                        elsif Is_Aggregate (Of_Unit, Id, Slot)
                        then "aggregate fields"
                             & Unbounded.To_String (Fields)
                        else Landin.Types.Spelling
                               (Type_Of (Of_Unit, Id, Slot)))
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
