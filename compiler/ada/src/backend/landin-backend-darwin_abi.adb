with Landin.Types;

package body Landin.Backend.Darwin_ABI is

   use type Landin.IR.Opcode;
   use type Landin.IR.Parameter_Convention;
   use type Landin.Targets.Byte_Count;
   use type Landin.Targets.C_ABI_Kind;
   use type Landin.Types.Type_Kind;

   function Classify
     (Of_Unit : Landin.IR.Unit;
      Part    : Landin.IR.Signature_Part;
      Facts   : Landin.Targets.Target_Facts) return Classification
   is
      Answer : Classification;
      Float_Kind : Landin.Types.Type_Kind := Landin.Types.No_Value;
      Members : Natural := 0;
      Homogeneous : Boolean := True;

      procedure Visit (Shape : Landin.IR.Field_Shape);

      procedure Visit (Shape : Landin.IR.Field_Shape) is
      begin
         if not Homogeneous then
            return;
         end if;
         case Shape.Kind is
            when Landin.IR.Scalar_Field_Shape =>
               if Shape.Element not in Landin.Types.Float_Name
                 or else Members = 4
                 or else (Members > 0 and then Float_Kind /= Shape.Element)
               then
                  Homogeneous := False;
               else
                  Float_Kind := Shape.Element;
                  Members := Members + 1;
               end if;
            when Landin.IR.Aggregate_Field_Shape =>
               if not Landin.IR.Has_C_Layout (Of_Unit, Shape.Nominal) then
                  raise Compiler_Defect with "non-C Darwin aggregate";
               end if;
               for Index in 1 .. Landin.IR.Aggregate_Field_Count
                 (Of_Unit, Shape)
               loop
                  Visit (Landin.IR.Nth_Aggregate_Field
                    (Of_Unit, Shape, Index));
                  exit when not Homogeneous;
               end loop;
            when Landin.IR.Array_Field_Shape =>
               --  Five visits suffice to disprove an HFA; never enumerate
               --  a target-sized array to classify its transport.
               for Index in 1 .. Landin.IR.Element_Total'Min
                 (Shape.Length, 5)
               loop
                  Visit (Landin.IR.Array_Element_Shape (Of_Unit, Shape));
                  exit when not Homogeneous;
               end loop;
            when Landin.IR.Variant_Field_Shape =>
               raise Compiler_Defect with "variant in Darwin C signature";
         end case;
      end Visit;
   begin
      if Landin.Targets.C_ABI_Of (Facts)
        /= Landin.Targets.Darwin_AAPCS64_LP64
      then
         raise Compiler_Defect with "Darwin C ABI needs Darwin facts";
      end if;
      if Part.Kind = Landin.Types.No_Value then
         return Answer;
      elsif Part.Convention = Landin.IR.Inout_Place
        or else Part.Kind = Landin.Types.Function_Value
      then
         Answer.Size := 8;
         Answer.Alignment := 8;
      elsif Part.Kind in Landin.Types.Scalar_Name then
         declare
            Held : constant Landin.Targets.Scalar_Size :=
              Size_Of (Part.Kind, Facts);
         begin
            Answer.Size := Landin.Targets.Byte_Count
              (Landin.Targets.Bytes (Held));
            Answer.Alignment := Landin.Targets.Alignment_Of (Facts, Held);
         end;
         if Part.Kind in Landin.Types.Float_Name then
            Answer.Float_Bytes := Answer.Size;
         end if;
      elsif Part.Kind in Landin.Types.Aggregate | Landin.Types.Fixed_Array
      then
         declare
            Shape : constant Landin.IR.Field_Shape :=
              (if Part.Kind = Landin.Types.Aggregate
               then (Kind => Landin.IR.Aggregate_Field_Shape,
                     Nominal => Part.Nominal, others => <>)
               else (Kind => Landin.IR.Array_Field_Shape,
                     Element => Part.Element, Length => Part.Length,
                     Nominal => Part.Element_Shape.Nominal, others => <>));
         begin
            Answer.Aggregate := True;
            Field_Extent
              (Of_Unit, Shape, Facts, Answer.Size, Answer.Alignment);
            if Answer.Size = 0 then
               raise Compiler_Defect with "empty Darwin C aggregate";
            end if;
            Visit (Shape);
            if Homogeneous and then Members > 0 then
               Answer.Count := Members;
               Answer.Float_Bytes :=
                 (if Float_Kind = Landin.Types.F32 then 4 else 8);
            elsif Answer.Size > 16 then
               Answer.Indirect := True;
            else
               Answer.Count := Natural ((Answer.Size + 7) / 8);
            end if;
         end;
      else
         raise Compiler_Defect with "unsupported Darwin C carrier";
      end if;
      if Answer.Count = 0 then
         Answer.Count := 1;
      end if;
      for Index in 1 .. Answer.Count loop
         Answer.Classes (Index) :=
           (if Answer.Float_Bytes > 0 then Float_Class else Integer_Class);
      end loop;
      return Answer;
   end Classify;

   function Assign
     (Of_Unit    : Landin.IR.Unit;
      Parameters : Landin.IR.Signature_Part_Array;
      Result     : Landin.IR.Signature_Part;
      Facts      : Landin.Targets.Target_Facts;
      Maximum : Landin.Targets.Byte_Count :=
        Landin.Targets.Byte_Count'Last;
      Fixed_Count : Natural := Natural'Last) return Plan
   is
      Answer : Plan (Parameters'Length);
      Stack_End : Landin.Targets.Byte_Count := 0;
   begin
      Answer.Result.Shape := Classify (Of_Unit, Result, Facts);
      --  The indirect result pointer is x8 and consumes no argument register.
      for Index in 1 .. Answer.Result.Shape.Count loop
         Answer.Result.Registers (Index) :=
           (if Answer.Result.Shape.Indirect then 9 else Index);
      end loop;
      for Index in Answer.Arguments'Range loop
         declare
            Item : Location renames Answer.Arguments (Index);
            Variadic : constant Boolean := Index > Fixed_Count;
            Bytes : Landin.Targets.Byte_Count;
            Alignment : Landin.Targets.Byte_Alignment;
         begin
            Item.Shape := Classify
              (Of_Unit, Parameters (Parameters'First + Index - 1), Facts);
            Bytes := (if Item.Shape.Indirect then 8 else Item.Shape.Size);
            Alignment :=
              (if Item.Shape.Indirect then 8 else Item.Shape.Alignment);
            if Variadic then
               Item.On_Stack := True;
               Alignment := Landin.Targets.Byte_Alignment'Max (8, Alignment);
               Bytes := Stack_Align (Bytes, 8, Maximum);
            elsif Item.Shape.Float_Bytes > 0 then
               if Answer.FP_Used + Item.Shape.Count <= 8 then
                  for Chunk in 1 .. Item.Shape.Count loop
                     Answer.FP_Used := Answer.FP_Used + 1;
                     Item.Registers (Chunk) := Answer.FP_Used;
                  end loop;
               else
                  Answer.FP_Used := 8;
                  Item.On_Stack := True;
               end if;
            elsif Answer.GP_Used + Item.Shape.Count <= 8 then
               for Chunk in 1 .. Item.Shape.Count loop
                  Answer.GP_Used := Answer.GP_Used + 1;
                  Item.Registers (Chunk) := Answer.GP_Used;
               end loop;
            else
               Answer.GP_Used := 8;
               Item.On_Stack := True;
            end if;
            if Item.On_Stack then
               Item.Stack_At := Stack_Align (Stack_End, Alignment, Maximum);
               Stack_End := Stack_Add (Item.Stack_At, Bytes, Maximum);
            end if;
         end;
      end loop;
      Answer.Stack_Bytes := Stack_Align
        (Stack_End, Landin.Targets.Stack_Alignment (Facts), Maximum);
      return Answer;
   end Assign;

   function Call_Plan
     (Of_Unit : Landin.IR.Unit;
      Item    : Landin.IR.Item_Id;
      Call    : Landin.IR.Value_Id;
      Facts   : Landin.Targets.Target_Facts;
      Maximum : Landin.Targets.Byte_Count :=
        Landin.Targets.Byte_Count'Last) return Plan
   is
      Indirect : constant Boolean :=
        Landin.IR.Op_Of (Of_Unit, Item, Call) = Landin.IR.Indirect_Call;
      Signature : constant Landin.IR.Signature_Id :=
        (if Indirect then Landin.IR.Call_Signature (Of_Unit, Item, Call)
         else Landin.IR.Signature_Of
           (Of_Unit, Landin.IR.Callee_Of (Of_Unit, Item, Call)));
      Result : constant Landin.IR.Signature_Part :=
        (if Landin.IR.Signature_Result_Count (Of_Unit, Signature) = 0
         then (others => <>)
         else Landin.IR.Nth_Signature_Result (Of_Unit, Signature, 1));
      Hidden : constant Natural :=
        (if Result.Kind in Landin.Types.Aggregate | Landin.Types.Fixed_Array
         then 1 else 0);
      Offset : constant Natural := (if Indirect then 1 else 0);
      Fixed : constant Natural :=
        Landin.IR.Signature_Parameter_Count (Of_Unit, Signature);
      Parameters : Landin.IR.Signature_Part_Array
        (1 .. Landin.IR.Operand_Count (Of_Unit, Item, Call) - Offset - Hidden);
   begin
      for Index in Parameters'Range loop
         Parameters (Index) :=
           (if Index <= Fixed
            then Landin.IR.Nth_Signature_Parameter (Of_Unit, Signature, Index)
            else (Kind => Landin.IR.Result_Of
                    (Of_Unit, Item, Landin.IR.Nth_Operand
                       (Of_Unit, Item, Call, Index + Offset + Hidden)),
                  others => <>));
      end loop;
      return Assign
        (Of_Unit, Parameters, Result, Facts, Maximum, Fixed);
   end Call_Plan;

   function Signature_Plan
     (Of_Unit   : Landin.IR.Unit;
      Signature : Landin.IR.Signature_Id;
      Facts     : Landin.Targets.Target_Facts;
      Maximum : Landin.Targets.Byte_Count :=
        Landin.Targets.Byte_Count'Last) return Plan
   is
      Parameters : Landin.IR.Signature_Part_Array
        (1 .. Landin.IR.Signature_Parameter_Count (Of_Unit, Signature));
   begin
      for Index in Parameters'Range loop
         Parameters (Index) := Landin.IR.Nth_Signature_Parameter
           (Of_Unit, Signature, Index);
      end loop;
      return Assign
        (Of_Unit, Parameters,
         (if Landin.IR.Signature_Result_Count (Of_Unit, Signature) = 0
          then (others => <>)
          else Landin.IR.Nth_Signature_Result (Of_Unit, Signature, 1)),
         Facts, Maximum);
   end Signature_Plan;

end Landin.Backend.Darwin_ABI;
