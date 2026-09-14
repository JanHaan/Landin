with Ada.Containers.Hashed_Maps;

package body Landin.IR.Shape_Measurement is

   package Targets renames Landin.Targets;
   package Layout renames Landin.Targets.Layouts;
   use type Targets.Byte_Count;
   use type Ada.Containers.Hash_Type;

   type Shape_Key is record
      Shape : Field_Shape;
      Nominal_Position : Natural;
   end record;

   function Hash (Key : Shape_Key) return Ada.Containers.Hash_Type;

   function Hash (Key : Shape_Key) return Ada.Containers.Hash_Type is
      Result : Ada.Containers.Hash_Type := 0;
      procedure Mix (Value : Ada.Containers.Hash_Type);

      procedure Mix (Value : Ada.Containers.Hash_Type) is
      begin
         Result := (Result xor Value) * 16_777_619;
      end Mix;
   begin
      Mix (Field_Shape_Kind'Pos (Key.Shape.Kind));
      Mix (Landin.Types.Scalar_Name'Pos (Key.Shape.Element));
      Mix (Ada.Containers.Hash_Type'Mod (Key.Shape.Length));
      Mix (Ada.Containers.Hash_Type'Mod (Key.Shape.Cases));
      Mix (Ada.Containers.Hash_Type'Mod (Key.Shape.Payloads_First));
      Mix (Ada.Containers.Hash_Type'Mod (Key.Shape.Signature));
      Mix (Ada.Containers.Hash_Type'Mod (Key.Shape.Atoms));
      Mix (Ada.Containers.Hash_Type'Mod (Key.Shape.Pointee));
      Mix (Ada.Containers.Hash_Type'Mod (Key.Nominal_Position));
      return Result;
   end Hash;

   type Cached_Extent is record
      Ready : Boolean := False;
      Value : Layout.Field_Extent := (0, 1);
   end record;

   package Extent_Maps is new Ada.Containers.Hashed_Maps
     (Key_Type => Shape_Key, Element_Type => Cached_Extent,
      Hash => Hash, Equivalent_Keys => "=");

   --  Every public query owns one memo. Unit, target and limit stay fixed
   --  throughout its recursive calls; no result survives the query.
   type Memo is record
      Values : Extent_Maps.Map;
   end record;

   function Extent
     (Cache : in out Memo;
      Of_Unit : Unit; Shape : Field_Shape;
      Facts : Landin.Targets.Target_Facts;
      Maximum : Landin.Targets.Byte_Count)
      return Landin.Targets.Layouts.Field_Extent;

   function Fields_Layout
     (Cache : in out Memo;
      Of_Unit : Unit; Fields : Field_Shape_Array;
      Policy : Landin.Layouts.Policy; Facts : Landin.Targets.Target_Facts;
      Maximum : Landin.Targets.Byte_Count) return Landin.Targets.Layouts.Plan;

   function Aggregate_Layout
     (Cache : in out Memo;
      Of_Unit : Unit; Shape : Field_Shape;
      Facts : Landin.Targets.Target_Facts;
      Maximum : Landin.Targets.Byte_Count) return Landin.Targets.Layouts.Plan;

   function Case_Layout
     (Cache : in out Memo;
      Of_Unit : Unit; Shape : Field_Shape; Which : Positive;
      Facts : Landin.Targets.Target_Facts;
      Maximum : Landin.Targets.Byte_Count) return Landin.Targets.Layouts.Plan;

   function Variant_Layout
     (Cache : in out Memo;
      Of_Unit : Unit; Shape : Field_Shape;
      Facts : Landin.Targets.Target_Facts;
      Maximum : Landin.Targets.Byte_Count) return Landin.Targets.Layouts.Plan;

   function Fields_Layout
     (Cache : in out Memo;
      Of_Unit : Unit; Fields : Field_Shape_Array;
      Policy : Landin.Layouts.Policy; Facts : Targets.Target_Facts;
      Maximum : Targets.Byte_Count) return Layout.Plan
   is
      Extents : Layout.Field_Extent_Array (Fields'Range);
   begin
      for Index in Fields'Range loop
         Extents (Index) :=
           Extent (Cache, Of_Unit, Fields (Index), Facts, Maximum);
      end loop;
      return Layout.Make (Extents, Policy, Maximum);
   end Fields_Layout;

   function Aggregate_Layout
     (Cache : in out Memo;
      Of_Unit : Unit; Shape : Field_Shape; Facts : Targets.Target_Facts;
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
           (Cache, Of_Unit, Fields, Layout_Of (Of_Unit, Shape),
            Facts, Maximum);
      end;
   end Aggregate_Layout;

   function Case_Layout
     (Cache : in out Memo;
      Of_Unit : Unit; Shape : Field_Shape; Which : Positive;
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
        (Cache, Of_Unit, Fields, Landin.Layouts.Natural, Facts, Maximum);
   end Case_Layout;

   function Variant_Layout
     (Cache : in out Memo;
      Of_Unit : Unit; Shape : Field_Shape; Facts : Targets.Target_Facts;
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
              Case_Layout (Cache, Of_Unit, Shape, Which, Facts, Maximum);
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
     (Cache : in out Memo;
      Of_Unit : Unit; Shape : Field_Shape; Facts : Targets.Target_Facts;
      Maximum : Targets.Byte_Count) return Layout.Field_Extent
   is
      Key : constant Shape_Key :=
        (Shape => Shape,
         Nominal_Position =>
           (if Holds (Of_Unit, Shape.Nominal)
            then Nominal_Identities.Position (Of_Unit, Shape.Nominal)
            else 0));
      Position : constant Extent_Maps.Cursor :=
        (if Shape.Kind = Scalar_Field_Shape then Extent_Maps.No_Element
         else Cache.Values.Find (Key));
      Measured : Layout.Field_Extent;
   begin
      if Extent_Maps.Has_Element (Position) then
         declare
            Saved : constant Cached_Extent := Extent_Maps.Element (Position);
         begin
            if not Saved.Ready then
               raise Compiler_Defect with "cyclic represented shape";
            end if;
            return Saved.Value;
         end;
      end if;
      --  A scalar has no descendants to reuse; keep that common query free
      --  of memo allocation even when it is a field of a compound shape.
      if Shape.Kind /= Scalar_Field_Shape then
         Cache.Values.Insert (Key, Cached_Extent'(others => <>));
      end if;
      case Shape.Kind is
         when Scalar_Field_Shape =>
            declare
               Held : constant Targets.Scalar_Size :=
                 Landin.Types.Storage_Size (Shape.Element, Facts);
            begin
               Measured :=
                 (Targets.Byte_Count (Targets.Bytes (Held)),
                  Targets.Alignment_Of (Facts, Held));
            end;
         when Array_Field_Shape =>
            Measured := Repeated
              (Extent (Cache, Of_Unit, Array_Element_Shape (Of_Unit, Shape),
                       Facts, Maximum), Shape.Length, Maximum);
         when Aggregate_Field_Shape | Variant_Field_Shape =>
            declare
               Placed : constant Layout.Plan :=
                 (if Shape.Kind = Aggregate_Field_Shape
                  then Aggregate_Layout (Cache, Of_Unit, Shape, Facts, Maximum)
                  else Variant_Layout (Cache, Of_Unit, Shape, Facts, Maximum));
            begin
               Measured := (Placed.Size, Placed.Alignment);
            end;
      end case;
      if Shape.Kind /= Scalar_Field_Shape then
         Cache.Values.Replace (Key, (Ready => True, Value => Measured));
      end if;
      return Measured;
   end Extent;

   function Extent
     (Of_Unit : Unit; Shape : Field_Shape;
      Facts : Landin.Targets.Target_Facts;
      Maximum : Landin.Targets.Byte_Count)
      return Landin.Targets.Layouts.Field_Extent
   is
      Cache : Memo;
   begin
      return Extent
        (Cache, Of_Unit, Shape, Facts, Maximum);
   end Extent;

   function Fields_Layout
     (Of_Unit : Unit; Fields : Field_Shape_Array;
      Policy : Landin.Layouts.Policy; Facts : Landin.Targets.Target_Facts;
      Maximum : Landin.Targets.Byte_Count) return Landin.Targets.Layouts.Plan
   is
      Cache : Memo;
   begin
      return Fields_Layout
        (Cache, Of_Unit, Fields, Policy, Facts, Maximum);
   end Fields_Layout;

   function Aggregate_Layout
     (Of_Unit : Unit; Shape : Field_Shape;
      Facts : Landin.Targets.Target_Facts;
      Maximum : Landin.Targets.Byte_Count) return Landin.Targets.Layouts.Plan
   is
      Cache : Memo;
   begin
      return Aggregate_Layout
        (Cache, Of_Unit, Shape, Facts, Maximum);
   end Aggregate_Layout;

   function Case_Layout
     (Of_Unit : Unit; Shape : Field_Shape; Which : Positive;
      Facts : Landin.Targets.Target_Facts;
      Maximum : Landin.Targets.Byte_Count) return Landin.Targets.Layouts.Plan
   is
      Cache : Memo;
   begin
      return Case_Layout
        (Cache, Of_Unit, Shape, Which, Facts, Maximum);
   end Case_Layout;

   function Variant_Layout
     (Of_Unit : Unit; Shape : Field_Shape;
      Facts : Landin.Targets.Target_Facts;
      Maximum : Landin.Targets.Byte_Count) return Landin.Targets.Layouts.Plan
   is
      Cache : Memo;
   begin
      return Variant_Layout
        (Cache, Of_Unit, Shape, Facts, Maximum);
   end Variant_Layout;

end Landin.IR.Shape_Measurement;
