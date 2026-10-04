--  Represented extents from target facts, independent of machine placement.
--  The caller chooses its limit explicitly: backend placement uses the
--  target object limit; specialization measures representable target bytes.
with Landin.Targets.Layouts;
private with Ada.Containers.Hashed_Maps;
private with Ada.Containers.Indefinite_Hashed_Maps;

package Landin.IR.Shape_Measurement is

   --  A query group for one immutable unit, target and object limit. Keep
   --  it local to that group; it retains complete aggregate plans as well
   --  as descendant extents until the group ends.
   type Layout_Cache is private;

   --  Observable plan inventory for repeated-query regression checks.
   function Cached_Plan_Count (Cache : Layout_Cache) return Natural;

   function Cached_Aggregate_Field_Offset
     (Cache : in out Layout_Cache;
      Of_Unit : Unit; Shape : Field_Shape; Field : Positive;
      Facts : Landin.Targets.Target_Facts;
      Maximum : Landin.Targets.Byte_Count)
      return Landin.Targets.Byte_Count;

   function Cached_Field_Extent
     (Cache : in out Layout_Cache;
      Of_Unit : Unit; Shape : Field_Shape;
      Facts : Landin.Targets.Target_Facts;
      Maximum : Landin.Targets.Byte_Count)
      return Landin.Targets.Layouts.Field_Extent;

   function Cached_Variant_Payload_Field_Offset
     (Cache : in out Layout_Cache;
      Of_Unit : Unit; Shape : Field_Shape; Which, Field : Positive;
      Facts : Landin.Targets.Target_Facts;
      Maximum : Landin.Targets.Byte_Count)
      return Landin.Targets.Byte_Count;

   --  Each query memoizes repeated descendant shapes for its fixed unit,
   --  target and limit, and discards that memo on return or failure.
   function Extent
     (Of_Unit : Unit; Shape : Field_Shape;
      Facts : Landin.Targets.Target_Facts;
      Maximum : Landin.Targets.Byte_Count)
      return Landin.Targets.Layouts.Field_Extent;

   function Repeated
     (Element : Landin.Targets.Layouts.Field_Extent;
      Length : Element_Total; Maximum : Landin.Targets.Byte_Count)
      return Landin.Targets.Layouts.Field_Extent;

   function Fields_Layout
     (Of_Unit : Unit; Fields : Field_Shape_Array;
      Policy : Landin.Layouts.Policy; Facts : Landin.Targets.Target_Facts;
      Maximum : Landin.Targets.Byte_Count) return Landin.Targets.Layouts.Plan;

   function Aggregate_Layout
     (Of_Unit : Unit; Shape : Field_Shape;
      Facts : Landin.Targets.Target_Facts;
      Maximum : Landin.Targets.Byte_Count) return Landin.Targets.Layouts.Plan;

   function Case_Layout
     (Of_Unit : Unit; Shape : Field_Shape; Which : Positive;
      Facts : Landin.Targets.Target_Facts;
      Maximum : Landin.Targets.Byte_Count) return Landin.Targets.Layouts.Plan;

   function Variant_Layout
     (Of_Unit : Unit; Shape : Field_Shape;
      Facts : Landin.Targets.Target_Facts;
      Maximum : Landin.Targets.Byte_Count) return Landin.Targets.Layouts.Plan;

private
   type Shape_Key is record
      Shape : Field_Shape;
      Nominal_Position : Natural;
   end record;

   function Hash (Key : Shape_Key) return Ada.Containers.Hash_Type;

   type Cached_Extent is record
      Ready : Boolean := False;
      Value : Landin.Targets.Layouts.Field_Extent := (0, 1);
   end record;

   package Extent_Maps is new Ada.Containers.Hashed_Maps
     (Key_Type => Shape_Key, Element_Type => Cached_Extent,
      Hash => Hash, Equivalent_Keys => "=");

   type Memo is record
      Values : Extent_Maps.Map;
   end record;

   package Layout_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type => Shape_Key,
      Element_Type => Landin.Targets.Layouts.Plan,
      Hash => Hash, Equivalent_Keys => "=",
      "=" => Landin.Targets.Layouts."=");

   type Case_Key is record
      Shape : Shape_Key;
      Which : Positive;
   end record;

   function Hash (Key : Case_Key) return Ada.Containers.Hash_Type;

   package Case_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type => Case_Key,
      Element_Type => Landin.Targets.Layouts.Plan,
      Hash => Hash, Equivalent_Keys => "=",
      "=" => Landin.Targets.Layouts."=");

   type Layout_Cache is record
      Extents : Memo;
      Plans : Layout_Maps.Map;
      Variants : Layout_Maps.Map;
      Cases : Case_Maps.Map;
   end record;

end Landin.IR.Shape_Measurement;
