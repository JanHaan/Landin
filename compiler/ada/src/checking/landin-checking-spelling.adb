with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Landin.Types;

package body Landin.Checking.Spelling is

   package US renames Ada.Strings.Unbounded;
   package Res renames Landin.Resolution;
   package Ty renames Landin.Types;

   function Spelled
     (From : Tables; Of_Name : Landin.Source.Names.Name_Id) return String
     is (Landin.Source.Names.Spelling (From.Spellings.all, Of_Name));

   function Atoms_Text (From : Tables; Set_Id : Atom_Set_Id) return String
   is
      Count : constant Natural := Atom_Count (From.Types.all, Set_Id);
      Order : array (1 .. Count) of Res.Declaration_Id;
      Text : US.Unbounded_String;

      function Name (Atom : Res.Declaration_Id) return String
        is (Spelled (From, Res.Name_Of (From.Meanings.all, Atom)));

      function Before (Left, Right : Res.Declaration_Id) return Boolean
        is (Name (Left) < Name (Right)
            or else (Name (Left) = Name (Right) and then Left < Right));
   begin
      for Index in Order'Range loop
         Order (Index) := Nth_Atom (From.Types.all, Set_Id, Index);
      end loop;
      for Index in 2 .. Count loop
         declare
            Moving : constant Res.Declaration_Id := Order (Index);
            Place : Natural := Index - 1;
         begin
            while Place >= 1 and then Before (Moving, Order (Place)) loop
               Order (Place + 1) := Order (Place);
               Place := Place - 1;
            end loop;
            Order (Place + 1) := Moving;
         end;
      end loop;
      for Index in Order'Range loop
         if Index > 1 then
            US.Append (Text, " | ");
         end if;
         US.Append (Text, Name (Order (Index)));
      end loop;
      return US.To_String (Text);
   end Atoms_Text;

   function Nominal_Text (From : Tables; Id : Nominal_Type_Id) return String
   is
      Types : Table renames From.Types.all;
   begin
      if Is_Pointer_Union (Types, Id) then
         return "(" & Atoms_Text (From, Union_Atoms (Types, Id))
           & " | " & Reference_Text (From, Union_Pointer (Types, Id)) & ")";
      end if;
      declare
         Text : US.Unbounded_String := US.To_Unbounded_String
           (Spelled (From, Res.Name_Of
              (From.Meanings.all, Template_Of (Types, Id))));
         Count : constant Natural := Instance_Actual_Count (Types, Id);
      begin
         for Position in 1 .. Count loop
            declare
               Key : constant Actual_Key :=
                 Nth_Instance_Actual (Types, Id, Position);
            begin
               US.Append (Text, (if Position = 1 then "(" else ", "));
               if Actual_Kind_Of (Key) = Fixed_Actual_Kind then
                  US.Append (Text, Ada.Strings.Fixed.Trim
                    (Ty.Magnitude'Image (Fixed_Magnitude_Of (Key)),
                     Ada.Strings.Both));
               else
                  case Type_Form_Of (Key) is
                     when Scalar_Actual_Type =>
                        US.Append (Text, Ty.Spelling (Scalar_Of (Types, Key)));
                     when Nominal_Actual_Type =>
                        US.Append
                          (Text, Nominal_Text (From, Nominal_Of (Types, Key)));
                     when Reference_Actual_Type =>
                        US.Append
                          (Text,
                           Reference_Text (From, Reference_Of (Types, Key)));
                     when Atom_Set_Actual_Type =>
                        US.Append
                          (Text, Atoms_Text (From, Atom_Set_Of (Types, Key)));
                     when others =>
                        US.Append (Text, "_");
                  end case;
               end if;
            end;
         end loop;
         if Count > 0 then
            US.Append (Text, ")");
         end if;
         return US.To_String (Text);
      end;
   end Nominal_Text;

   function Shape_Text (From : Tables; Shape : Field_Shape) return String is
   begin
      case Shape.Kind is
         when Scalar_Field =>
            if Shape.Atoms /= No_Atom_Set then
               return Atoms_Text (From, Shape.Atoms);
            elsif Shape.Signature /= No_Signature then
               return "function";
            end if;
            return Ty.Spelling (Shape.Element);
         when Reference_Field =>
            return Reference_Text (From, Shape.Reference);
         when Aggregate_Field =>
            return Nominal_Text (From, Shape.Nominal);
         when Fixed_Array_Field =>
            return "[" & Ada.Strings.Fixed.Trim
              (Element_Count'Image (Shape.Length), Ada.Strings.Both) & "]"
              & Shape_Text (From, Array_Field_Element (From.Types.all, Shape));
         when Variant_Field =>
            return "variant";
      end case;
   end Shape_Text;

   function Referent_Text
     (From : Tables; Item : Reference_Descriptor) return String is
   begin
      case Item.Referent is
         when Ty.Scalar_Name =>
            return Ty.Spelling (Item.Referent);
         when Ty.Aggregate =>
            return Nominal_Text (From, Item.Nominal);
         when Ty.Atom_Value =>
            return Atoms_Text (From, Item.Atoms);
         when Ty.Pointer_Value | Ty.Slice_Value | Ty.Any_Value =>
            return Reference_Text (From, Item.Reference);
         when Ty.Function_Value =>
            return "function";
         when Ty.Fixed_Array =>
            return "[" & Ada.Strings.Fixed.Trim
              (Element_Count'Image (Item.Length), Ada.Strings.Both) & "]"
              & (if Item.Element_Nominal /= No_Nominal_Type
                 then Nominal_Text (From, Item.Element_Nominal)
                 elsif Item.Element_Shape.Kind /= Scalar_Field
                   or else Item.Element_Shape.Atoms /= No_Atom_Set
                 then Shape_Text (From, Item.Element_Shape)
                 else Ty.Spelling (Item.Element));
         when others =>
            return "_";
      end case;
   end Referent_Text;

   function Reference_Text (From : Tables; Id : Reference_Id) return String
   is
      Item : constant Reference_Descriptor :=
        Descriptor_Of (From.Types.all, Id);
   begin
      if Item.View in Ty.Text_View then
         return Ty.Spelling (Item.View);
      end if;
      case Item.Kind is
         when Ty.Pointer_Value =>
            return "ptr " & (if Item.Mutable then "mut " else "")
              & Referent_Text (From, Item);
         when Ty.Slice_Value =>
            return "[]" & (if Item.Mutable then "mut " else "")
              & Referent_Text (From, Item);
         when Ty.Any_Value =>
            return "any " & Spelled (From, Res.Name_Of
              (From.Meanings.all,
               Concept_Declaration (From.Types.all, Item.Concept)));
         when others =>
            return "_";
      end case;
   end Reference_Text;

end Landin.Checking.Spelling;
