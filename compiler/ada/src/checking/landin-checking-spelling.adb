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

   function Declaration_Text
     (From   : Tables;
      Id     : Res.Declaration_Id;
      Within : Landin.Source.Source_Id := Landin.Source.No_Source)
      return String
   is
      Qualifier : constant String :=
        Res.Qualifier_From
          (From.Meanings.all, From.Spellings.all, Id, Within);
   begin
      return (if Qualifier = "" then "" else Qualifier & ".")
        & Spelled (From, Res.Name_Of (From.Meanings.all, Id));
   end Declaration_Text;

   function Concept_Name
     (From   : Tables;
      Id     : Concept_Id;
      Within : Landin.Source.Source_Id := Landin.Source.No_Source)
      return String
     --  The compiler's one concept is declared by no source.
     is (if Is_Compiler_Concept (From.Types.all, Id) then "zeroable"
         else Declaration_Text
           (From, Concept_Declaration (From.Types.all, Id), Within));

   function Nominal_Text
     (From   : Tables;
      Id     : Nominal_Type_Id;
      Within : Landin.Source.Source_Id := Landin.Source.No_Source)
      return String
   is
      Types : Table renames From.Types.all;
   begin
      if Is_Pointer_Union (Types, Id) then
         return "(" & Atoms_Text (From, Union_Atoms (Types, Id))
           & " | " & Reference_Text (From, Union_Pointer (Types, Id), Within)
           & ")";
      end if;
      declare
         Template : constant Res.Declaration_Id := Template_Of (Types, Id);
         --  Outside its module a private type is written by its public
         --  alias, whose formals are its own in order.
         Written : constant Res.Declaration_Id :=
           (if not Res.Is_Public (From.Meanings.all, Template)
              and then Public_Alias_Of (Types, Template) /= No_Declaration
              and then Res.Qualifier_From
                (From.Meanings.all, From.Spellings.all, Template, Within)
                  /= ""
            then Public_Alias_Of (Types, Template)
            else Template);
         Text : US.Unbounded_String := US.To_Unbounded_String
           (Declaration_Text (From, Written, Within));
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
                          (Text,
                           Nominal_Text
                             (From, Nominal_Of (Types, Key), Within));
                     when Reference_Actual_Type =>
                        US.Append
                          (Text,
                           Reference_Text
                             (From, Reference_Of (Types, Key), Within));
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

   function Shape_Text
     (From   : Tables;
      Shape  : Field_Shape;
      Within : Landin.Source.Source_Id := Landin.Source.No_Source)
      return String is
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
            return Reference_Text (From, Shape.Reference, Within);
         when Aggregate_Field =>
            return Nominal_Text (From, Shape.Nominal, Within);
         when Fixed_Array_Field =>
            return "[" & Ada.Strings.Fixed.Trim
              (Element_Count'Image (Shape.Length), Ada.Strings.Both) & "]"
              & Shape_Text
                  (From, Array_Field_Element (From.Types.all, Shape), Within);
         when Variant_Field =>
            return "variant";
      end case;
   end Shape_Text;

   function Concept_Text
     (From : Tables; Id : Concept_Id; Within : Landin.Source.Source_Id)
      return String
     is ("any " & Concept_Name (From, Id, Within));

   function Referent_Text
     (From   : Tables;
      Item   : Reference_Descriptor;
      Within : Landin.Source.Source_Id := Landin.Source.No_Source)
      return String is
   begin
      case Item.Referent is
         when Ty.Scalar_Name =>
            return Ty.Spelling (Item.Referent);
         when Ty.Aggregate =>
            return Nominal_Text (From, Item.Nominal, Within);
         when Ty.Atom_Value =>
            return Atoms_Text (From, Item.Atoms);
         when Ty.Pointer_Value | Ty.Slice_Value =>
            return Reference_Text (From, Item.Reference, Within);
         --  An erased referent records its concept, not a reference.
         when Ty.Any_Value =>
            return Concept_Text (From, Item.Concept, Within);
         when Ty.Function_Value =>
            return "function";
         when Ty.Fixed_Array =>
            return "[" & Ada.Strings.Fixed.Trim
              (Element_Count'Image (Item.Length), Ada.Strings.Both) & "]"
              & (if Item.Element_Nominal /= No_Nominal_Type
                 then Nominal_Text (From, Item.Element_Nominal, Within)
                 elsif Item.Element_Shape.Kind /= Scalar_Field
                   or else Item.Element_Shape.Atoms /= No_Atom_Set
                 then Shape_Text (From, Item.Element_Shape, Within)
                 else Ty.Spelling (Item.Element));
         when others =>
            return "_";
      end case;
   end Referent_Text;

   function Reference_Text
     (From   : Tables;
      Id     : Reference_Id;
      Within : Landin.Source.Source_Id := Landin.Source.No_Source)
      return String
   is
      Item : constant Reference_Descriptor :=
        Descriptor_Of (From.Types.all, Id);
   begin
      if Item.View in Ty.Text_View then
         return Ty.Spelling (Item.View);
      end if;
      --  D189: a pointer with one atom for its empty case is the union a
      --  program writes as that atom and the pointer.
      if Item.Kind = Ty.Pointer_Value
        and then Item.Empty_Atom /= No_Declaration
      then
         return "(" & Spelled
           (From, Res.Name_Of (From.Meanings.all, Item.Empty_Atom))
           & " | ptr " & (if Item.Mutable then "mut " else "")
           & Referent_Text (From, Item, Within) & ")";
      end if;
      case Item.Kind is
         when Ty.Pointer_Value =>
            return "ptr " & (if Item.Mutable then "mut " else "")
              & Referent_Text (From, Item, Within);
         when Ty.Slice_Value =>
            return "[]" & (if Item.Mutable then "mut " else "")
              & Referent_Text (From, Item, Within);
         when Ty.Any_Value =>
            return Concept_Text (From, Item.Concept, Within);
         when others =>
            return "_";
      end case;
   end Reference_Text;

end Landin.Checking.Spelling;
