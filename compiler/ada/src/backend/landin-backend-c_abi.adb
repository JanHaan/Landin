with Landin.Types;

package body Landin.Backend.C_ABI is

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

      procedure Visit
        (Shape : Landin.IR.Field_Shape;
         At_Byte : Landin.Targets.Byte_Count);

      procedure Visit
        (Shape : Landin.IR.Field_Shape;
         At_Byte : Landin.Targets.Byte_Count)
      is
         Size : Landin.Targets.Byte_Count;
         Alignment : Landin.Targets.Byte_Alignment;
      begin
         Field_Extent (Of_Unit, Shape, Facts, Size, Alignment);
         if At_Byte mod Landin.Targets.Byte_Count (Alignment) /= 0 then
            Answer.Memory := True;
            return;
         end if;
         case Shape.Kind is
            when Landin.IR.Scalar_Field_Shape =>
               declare
                  Class : constant Eightbyte_Class :=
                    (if Shape.Element in Landin.Types.Float_Name
                     then SSE_Class else Integer_Class);
               begin
                  for Byte in At_Byte .. At_Byte + Size - 1 loop
                     declare
                        Index : constant Positive :=
                          Positive (Byte / 8 + 1);
                     begin
                        if Answer.Classes (Index) = No_Class
                          or else Class = Integer_Class
                        then
                           Answer.Classes (Index) := Class;
                        end if;
                     end;
                  end loop;
               end;
            when Landin.IR.Aggregate_Field_Shape =>
               if not Landin.IR.Has_C_Layout (Of_Unit, Shape.Nominal) then
                  raise Compiler_Defect with
                    "a non-C-layout aggregate reached C classification";
               end if;
               declare
                  Placed : Landin.Targets.Placement :=
                    Landin.Targets.Empty_Placement;
                  Offset : Landin.Targets.Byte_Count;
               begin
                  for Index in 1 .. Landin.IR.Aggregate_Field_Count
                    (Of_Unit, Shape)
                  loop
                     declare
                        Field : constant Landin.IR.Field_Shape :=
                          Landin.IR.Nth_Aggregate_Field
                            (Of_Unit, Shape, Index);
                        Field_Size : Landin.Targets.Byte_Count;
                        Field_Alignment : Landin.Targets.Byte_Alignment;
                     begin
                        Field_Extent
                          (Of_Unit, Field, Facts,
                           Field_Size, Field_Alignment);
                        Landin.Targets.Place
                          (Placed, Field_Size, Field_Alignment, Offset);
                        Visit (Field, At_Byte + Offset);
                     end;
                  end loop;
               end;
            when Landin.IR.Array_Field_Shape =>
               declare
                  Element : constant Landin.IR.Field_Shape :=
                    Landin.IR.Array_Element_Shape (Of_Unit, Shape);
                  Stride : Landin.Targets.Byte_Count;
                  Element_Alignment : Landin.Targets.Byte_Alignment;
               begin
                  Field_Extent
                    (Of_Unit, Element, Facts, Stride, Element_Alignment);
                  --  Visit runs only for an object at most sixteen bytes:
                  --  a large array is MEMORY without enumerating elements.
                  for Index in 1 .. Shape.Length loop
                     Visit
                       (Element, At_Byte
                        + (Landin.Targets.Byte_Count (Index) - 1) * Stride);
                  end loop;
               end;
            when Landin.IR.Variant_Field_Shape =>
               raise Compiler_Defect with
                 "a tagged variant reached native C classification";
         end case;
      end Visit;
   begin
      if Landin.Targets.C_ABI_Of (Facts)
        /= Landin.Targets.SysV_AMD64_LP64
      then
         raise Compiler_Defect with "no native C ABI for this target";
      end if;
      if Part.Kind = Landin.Types.No_Value then
         return Answer;
      elsif Part.Convention = Landin.IR.Inout_Place
        or else Part.Kind = Landin.Types.Function_Value
      then
         Answer.Size := 8;
         Answer.Alignment := 8;
         Answer.Count := 1;
         Answer.Classes (1) := Integer_Class;
         return Answer;
      elsif Part.Kind in Landin.Types.Scalar_Name then
         declare
            Held : constant Landin.Targets.Scalar_Size :=
              Size_Of (Part.Kind, Facts);
         begin
            Answer.Size := Landin.Targets.Byte_Count
              (Landin.Targets.Bytes (Held));
            Answer.Alignment := Landin.Targets.Alignment_Of (Facts, Held);
            Answer.Count := 1;
            Answer.Classes (1) :=
              (if Part.Kind in Landin.Types.Float_Name
               then SSE_Class else Integer_Class);
            return Answer;
         end;
      elsif Part.Kind not in Landin.Types.Aggregate
                             | Landin.Types.Fixed_Array
      then
         raise Compiler_Defect with "unsupported native C carrier";
      end if;

      declare
         Shape : constant Landin.IR.Field_Shape :=
           (if Part.Kind = Landin.Types.Aggregate
            then (Kind => Landin.IR.Aggregate_Field_Shape,
                  Nominal => Part.Nominal, others => <>)
            else (Kind => Landin.IR.Array_Field_Shape,
                  Element => Part.Element,
                  Length => Part.Length,
                  Nominal => Part.Element_Shape.Nominal, others => <>));
      begin
         Answer.Aggregate := True;
         Field_Extent
           (Of_Unit, Shape, Facts, Answer.Size, Answer.Alignment);
         if Answer.Size = 0 then
            raise Compiler_Defect with "an empty C aggregate was accepted";
         elsif Answer.Size > 16 then
            Answer.Memory := True;
         else
            Answer.Count := Natural ((Answer.Size + 7) / 8);
            Visit (Shape, 0);
         end if;
      end;
      return Answer;
   end Classify;

   function Assign
     (Of_Unit    : Landin.IR.Unit;
      Parameters : Landin.IR.Signature_Part_Array;
      Result     : Landin.IR.Signature_Part;
      Facts      : Landin.Targets.Target_Facts) return Plan
   is
      Answer : Plan (Parameters'Length);
      Stack_End : Landin.Targets.Byte_Count := 0;
   begin
      Answer.Result.Shape := Classify (Of_Unit, Result, Facts);
      if Answer.Result.Shape.Memory then
         Answer.GP_Used := 1;
      else
         declare
            GP, SSE : Natural := 0;
         begin
            for Index in 1 .. Answer.Result.Shape.Count loop
               case Answer.Result.Shape.Classes (Index) is
                  when Integer_Class =>
                     GP := GP + 1;
                     Answer.Result.Registers (Index) := GP;
                  when SSE_Class =>
                     SSE := SSE + 1;
                     Answer.Result.Registers (Index) := SSE;
                  when No_Class => null;
               end case;
            end loop;
         end;
      end if;
      for Index in Answer.Arguments'Range loop
         declare
            Item : Location renames Answer.Arguments (Index);
            GP, SSE : Natural := 0;
         begin
            Item.Shape := Classify
              (Of_Unit, Parameters (Parameters'First + Index - 1), Facts);
            for Class of Item.Shape.Classes loop
               case Class is
                  when Integer_Class => GP := GP + 1;
                  when SSE_Class => SSE := SSE + 1;
                  when No_Class => null;
               end case;
            end loop;
            --  An aggregate either fits both banks in its entirety or
            --  consumes neither.  A later scalar can use the rolled-back
            --  bank even though this argument went on the stack.
            if Item.Shape.Memory
              or else Answer.GP_Used + GP > 6
              or else Answer.SSE_Used + SSE > 8
            then
               Item.On_Stack := True;
               Item.Stack_At := Landin.Targets.Align_Up
                 (Stack_End,
                  Landin.Targets.Byte_Alignment'Max
                    (8, Item.Shape.Alignment));
               Stack_End := Item.Stack_At
                 + Landin.Targets.Align_Up (Item.Shape.Size, 8);
            else
               for Chunk in 1 .. Item.Shape.Count loop
                  case Item.Shape.Classes (Chunk) is
                     when Integer_Class =>
                        Answer.GP_Used := Answer.GP_Used + 1;
                        Item.Registers (Chunk) := Answer.GP_Used;
                     when SSE_Class =>
                        Answer.SSE_Used := Answer.SSE_Used + 1;
                        Item.Registers (Chunk) := Answer.SSE_Used;
                     when No_Class => null;
                  end case;
               end loop;
            end if;
         end;
      end loop;
      Answer.Stack_Bytes := Landin.Targets.Align_Up
        (Stack_End, Landin.Targets.Stack_Alignment (Facts));
      return Answer;
   end Assign;

   function Call_Plan
     (Of_Unit : Landin.IR.Unit;
      Item    : Landin.IR.Item_Id;
      Call    : Landin.IR.Value_Id;
      Facts   : Landin.Targets.Target_Facts) return Plan
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
      return Assign (Of_Unit, Parameters, Result, Facts);
   end Call_Plan;

   function Signature_Plan
     (Of_Unit   : Landin.IR.Unit;
      Signature : Landin.IR.Signature_Id;
      Facts     : Landin.Targets.Target_Facts) return Plan
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
         Facts);
   end Signature_Plan;

end Landin.Backend.C_ABI;
