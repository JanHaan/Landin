with Landin.Targets.Packed;

package body Landin.IR.Shape_Measurement is

   package Targets renames Landin.Targets;
   package Layout renames Landin.Targets.Layouts;
   use type Targets.Byte_Count;
   use type Ada.Containers.Hash_Type;
   use type Ada.Containers.Count_Type;

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
      Mix (Ada.Containers.Hash_Type'Mod (Key.Shape.Slice_Element));
      Mix (Ada.Containers.Hash_Type'Mod (Key.Shape.Packing.First));
      Mix (Ada.Containers.Hash_Type'Mod (Key.Shape.Packing.Bits));
      Mix (Ada.Containers.Hash_Type'Mod (Key.Shape.Packing.Storage));
      Mix (Ada.Containers.Hash_Type'Mod (Key.Nominal_Position));
      return Result;
   end Hash;

   function Hash (Key : Case_Key) return Ada.Containers.Hash_Type is
   begin
      return (Hash (Key.Shape) xor Ada.Containers.Hash_Type (Key.Which))
        * 16_777_619;
   end Hash;

   function Cached_Plan_Count (Cache : Layout_Cache) return Natural is
     (Natural (Cache.Plans.Length + Cache.Variants.Length
               + Cache.Cases.Length));

   --  Ordinary public queries own one memo and discard it on return. The
   --  caller-owned layout cache keeps its memo for one fixed query group.

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
      if Shape.Packing.Bits /= 0 then
         declare
            Held : constant Targets.Scalar_Size :=
              Targets.Packed.Carrier (Shape.Packing.Storage);
         begin
            return (Targets.Byte_Count (Targets.Bytes (Held)),
                    Targets.Alignment_Of (Facts, Held));
         end;
      end if;
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

   function Cached_Aggregate_Field_Offset
     (Cache : in out Layout_Cache;
      Of_Unit : Unit; Shape : Field_Shape; Field : Positive;
      Facts : Landin.Targets.Target_Facts;
      Maximum : Landin.Targets.Byte_Count) return Targets.Byte_Count
   is
      Key : constant Shape_Key :=
        (Shape => Shape,
         Nominal_Position =>
           (if Holds (Of_Unit, Shape.Nominal)
            then Nominal_Identities.Position (Of_Unit, Shape.Nominal)
            else 0));
      Position : Layout_Maps.Cursor := Cache.Plans.Find (Key);
   begin
      if not Layout_Maps.Has_Element (Position) then
         declare
            Placed : constant Layout.Plan := Aggregate_Layout
              (Cache.Extents, Of_Unit, Shape, Facts, Maximum);
         begin
            Cache.Plans.Insert (Key, Placed);
         end;
         Position := Cache.Plans.Find (Key);
      end if;
      return Layout_Maps.Constant_Reference
        (Cache.Plans, Position).Element.Offsets (Field);
   end Cached_Aggregate_Field_Offset;

   function Cached_Field_Extent
     (Cache : in out Layout_Cache;
      Of_Unit : Unit; Shape : Field_Shape;
      Facts : Landin.Targets.Target_Facts;
      Maximum : Landin.Targets.Byte_Count)
      return Layout.Field_Extent
   is
   begin
      return Extent (Cache.Extents, Of_Unit, Shape, Facts, Maximum);
   end Cached_Field_Extent;

   function Cached_Case_Position
     (Cache : in out Layout_Cache;
      Of_Unit : Unit; Shape : Field_Shape; Which : Positive;
      Facts : Landin.Targets.Target_Facts;
      Maximum : Landin.Targets.Byte_Count) return Case_Maps.Cursor;

   function Cached_Case_Position
     (Cache : in out Layout_Cache;
      Of_Unit : Unit; Shape : Field_Shape; Which : Positive;
      Facts : Landin.Targets.Target_Facts;
      Maximum : Landin.Targets.Byte_Count) return Case_Maps.Cursor
   is
      Key : constant Case_Key :=
        (Shape =>
           (Shape => Shape,
            Nominal_Position =>
              (if Holds (Of_Unit, Shape.Nominal)
               then Nominal_Identities.Position (Of_Unit, Shape.Nominal)
               else 0)),
         Which => Which);
      Position : Case_Maps.Cursor := Cache.Cases.Find (Key);
   begin
      if not Case_Maps.Has_Element (Position) then
         declare
            Placed : constant Layout.Plan := Case_Layout
              (Cache.Extents, Of_Unit, Shape, Which, Facts, Maximum);
         begin
            Cache.Cases.Insert (Key, Placed);
         end;
         Position := Cache.Cases.Find (Key);
      end if;
      return Position;
   end Cached_Case_Position;

   function Cached_Variant_Position
     (Cache : in out Layout_Cache;
      Of_Unit : Unit; Shape : Field_Shape;
      Facts : Landin.Targets.Target_Facts;
      Maximum : Landin.Targets.Byte_Count) return Layout_Maps.Cursor;

   function Cached_Variant_Position
     (Cache : in out Layout_Cache;
      Of_Unit : Unit; Shape : Field_Shape;
      Facts : Landin.Targets.Target_Facts;
      Maximum : Landin.Targets.Byte_Count) return Layout_Maps.Cursor
   is
      Key : constant Shape_Key :=
        (Shape => Shape,
         Nominal_Position =>
           (if Holds (Of_Unit, Shape.Nominal)
            then Nominal_Identities.Position (Of_Unit, Shape.Nominal)
            else 0));
      Position : Layout_Maps.Cursor := Cache.Variants.Find (Key);
   begin
      if not Layout_Maps.Has_Element (Position) then
         declare
            Tag : constant Targets.Scalar_Size :=
              Landin.Types.Storage_Size (Shape.Element, Facts);
            Fields : Layout.Field_Extent_Array (1 .. 2) :=
              [1 => (Targets.Byte_Count (Targets.Bytes (Tag)),
                     Targets.Alignment_Of (Facts, Tag)),
               2 => (0, 1)];
         begin
            for Which in 1 .. Shape.Cases loop
               declare
                  Case_Position : constant Case_Maps.Cursor :=
                    Cached_Case_Position
                    (Cache, Of_Unit, Shape, Which, Facts, Maximum);
                  Payload : constant Case_Maps.Constant_Reference_Type :=
                    Case_Maps.Constant_Reference (Cache.Cases, Case_Position);
               begin
                  Fields (2).Size := Targets.Byte_Count'Max
                    (Fields (2).Size, Payload.Element.Size);
                  Fields (2).Alignment := Targets.Byte_Alignment'Max
                    (Fields (2).Alignment, Payload.Element.Alignment);
               end;
            end loop;
            declare
               Placed : constant Layout.Plan :=
                 Layout.Make (Fields, Landin.Layouts.Natural, Maximum);
            begin
               Cache.Variants.Insert (Key, Placed);
            end;
         end;
         Position := Cache.Variants.Find (Key);
      end if;
      return Position;
   end Cached_Variant_Position;

   function Cached_Variant_Payload_Field_Offset
     (Cache : in out Layout_Cache;
      Of_Unit : Unit; Shape : Field_Shape; Which, Field : Positive;
      Facts : Landin.Targets.Target_Facts;
      Maximum : Landin.Targets.Byte_Count) return Targets.Byte_Count
   is
      Part : constant Layout_Maps.Cursor := Cached_Variant_Position
        (Cache, Of_Unit, Shape, Facts, Maximum);
      Payload : constant Case_Maps.Cursor := Cached_Case_Position
        (Cache, Of_Unit, Shape, Which, Facts, Maximum);
   begin
      if Field > Case_Maps.Constant_Reference
        (Cache.Cases, Payload).Element.Count
      then
         raise Compiler_Defect with "no such variant payload field";
      end if;
      return Layout_Maps.Constant_Reference
        (Cache.Variants, Part).Element.Offsets (2)
        + Case_Maps.Constant_Reference
            (Cache.Cases, Payload).Element.Offsets (Field);
   end Cached_Variant_Payload_Field_Offset;

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
