--  Represented extents from target facts, independent of machine placement.
--  The caller chooses its limit explicitly: backend placement uses the
--  target object limit; specialization measures representable target bytes.
with Landin.Targets.Layouts;

package Landin.IR.Shape_Measurement is

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

end Landin.IR.Shape_Measurement;
