package body Landin.IR.Shape_Measurement is

   package Targets renames Landin.Targets;
   package Layout renames Landin.Targets.Layouts;
   use type Targets.Byte_Count;

   function Fields_Layout
     (Of_Unit : Unit; Fields : Field_Shape_Array;
      Policy : Landin.Layouts.Policy; Facts : Targets.Target_Facts;
      Maximum : Targets.Byte_Count) return Layout.Plan
   is
      Extents : Layout.Field_Extent_Array (Fields'Range);
   begin
      for Index in Fields'Range loop
         Extents (Index) := Extent (Of_Unit, Fields (Index), Facts, Maximum);
      end loop;
      return Layout.Make (Extents, Policy, Maximum);
   end Fields_Layout;

   function Aggregate_Layout
     (Of_Unit : Unit; Shape : Field_Shape; Facts : Targets.Target_Facts;
      Maximum : Targets.Byte_Count) return Layout.Plan
   is
   begin
      if Shape.Kind /= Aggregate_Field_Shape then
         raise Compiler_Defect with "an aggregate layout needs an aggregate";
      end if;
      declare
         Fields : Field_Shape_Array
           (1 .. Aggregate_Field_Count (Of_Unit, Shape));
      begin
         for Index in Fields'Range loop
            Fields (Index) := Nth_Aggregate_Field (Of_Unit, Shape, Index);
         end loop;
         return Fields_Layout
           (Of_Unit, Fields, Layout_Of (Of_Unit, Shape), Facts, Maximum);
      end;
   end Aggregate_Layout;

   function Case_Layout
     (Of_Unit : Unit; Shape : Field_Shape; Which : Positive;
      Facts : Targets.Target_Facts; Maximum : Targets.Byte_Count)
      return Layout.Plan
   is
      Fields : Field_Shape_Array
        (1 .. Variant_Case_Field_Count (Of_Unit, Shape, Which));
   begin
      for Index in Fields'Range loop
         Fields (Index) := Nth_Variant_Case_Field
           (Of_Unit, Shape, Which, Index);
      end loop;
      return Fields_Layout
        (Of_Unit, Fields, Landin.Layouts.Natural, Facts, Maximum);
   end Case_Layout;

   function Variant_Layout
     (Of_Unit : Unit; Shape : Field_Shape; Facts : Targets.Target_Facts;
      Maximum : Targets.Byte_Count) return Layout.Plan
   is
      Tag : constant Targets.Scalar_Size :=
        Landin.Types.Storage_Size (Shape.Element, Facts);
      Fields : Layout.Field_Extent_Array (1 .. 2) :=
        [1 => (Targets.Byte_Count (Targets.Bytes (Tag)),
               Targets.Alignment_Of (Facts, Tag)),
         2 => (0, 1)];
   begin
      for Which in 1 .. Shape.Cases loop
         declare
            Payload : constant Layout.Plan :=
              Case_Layout (Of_Unit, Shape, Which, Facts, Maximum);
         begin
            Fields (2).Size := Targets.Byte_Count'Max
              (Fields (2).Size, Payload.Size);
            Fields (2).Alignment := Targets.Byte_Alignment'Max
              (Fields (2).Alignment, Payload.Alignment);
         end;
      end loop;
      return Layout.Make (Fields, Landin.Layouts.Natural, Maximum);
   end Variant_Layout;

   function Repeated
     (Element : Layout.Field_Extent; Length : Element_Total;
      Maximum : Targets.Byte_Count) return Layout.Field_Extent
   is
   begin
      if Element.Size /= 0
        and then Targets.Byte_Count (Length) > Maximum / Element.Size
      then
         raise Compiler_Defect with "an array extent exceeds its limit";
      end if;
      return (Size => Targets.Byte_Count (Length) * Element.Size,
              Alignment => (if Length = 0 then 1 else Element.Alignment));
   end Repeated;

   function Extent
     (Of_Unit : Unit; Shape : Field_Shape; Facts : Targets.Target_Facts;
      Maximum : Targets.Byte_Count) return Layout.Field_Extent
   is
   begin
      case Shape.Kind is
         when Scalar_Field_Shape =>
            declare
               Held : constant Targets.Scalar_Size :=
                 Landin.Types.Storage_Size (Shape.Element, Facts);
            begin
               return (Targets.Byte_Count (Targets.Bytes (Held)),
                       Targets.Alignment_Of (Facts, Held));
            end;
         when Array_Field_Shape =>
            return Repeated
              (Extent (Of_Unit, Array_Element_Shape (Of_Unit, Shape),
                       Facts, Maximum), Shape.Length, Maximum);
         when Aggregate_Field_Shape | Variant_Field_Shape =>
            declare
               Placed : constant Layout.Plan :=
                 (if Shape.Kind = Aggregate_Field_Shape
                  then Aggregate_Layout (Of_Unit, Shape, Facts, Maximum)
                  else Variant_Layout (Of_Unit, Shape, Facts, Maximum));
            begin
               return (Placed.Size, Placed.Alignment);
            end;
      end case;
   end Extent;

end Landin.IR.Shape_Measurement;
