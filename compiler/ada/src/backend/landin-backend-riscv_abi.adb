package body Landin.Backend.RiscV_ABI is

   use type Landin.IR.Opcode;
   use type Landin.IR.Element_Total;
   use type Landin.IR.Parameter_Convention;
   use type Landin.Targets.Bit_Width;
   use type Landin.Targets.Byte_Alignment;
   use type Landin.Targets.Byte_Count;
   use type Landin.Targets.C_ABI_Kind;
   use type Landin.Types.Type_Kind;

   function Classify
     (Of_Unit : Landin.IR.Unit; Part : Landin.IR.Signature_Part;
      Facts : Landin.Targets.Target_Facts;
      Floating : Boolean := True) return Classification
   is
      Answer : Classification;
      Leaves : Carrier_Array;
      Count : Natural := 0;
      Float_Count : Natural := 0;
      Flattened : Boolean := True;

      procedure Visit
        (Shape : Landin.IR.Field_Shape; Offset : Landin.Targets.Byte_Count);

      procedure Visit
        (Shape : Landin.IR.Field_Shape; Offset : Landin.Targets.Byte_Count)
      is
      begin
         if not Flattened then
            return;
         end if;
         case Shape.Kind is
            when Landin.IR.Scalar_Field_Shape =>
               if Count = 2 then
                  Flattened := False;
               else
                  Count := Count + 1;
                  Leaves (Count) :=
                    (Class => (if Shape.Element in Landin.Types.Float_Name
                               then Float_Class else Integer_Class),
                     Offset => Offset,
                     Bytes => Landin.Targets.Byte_Count
                       (Landin.Targets.Bytes (Size_Of (Shape.Element, Facts))),
                     Scalar => Shape.Element);
                  if Leaves (Count).Class = Float_Class then
                     Float_Count := Float_Count + 1;
                  end if;
               end if;
            when Landin.IR.Aggregate_Field_Shape =>
               if not Landin.IR.Has_C_Layout (Of_Unit, Shape.Nominal) then
                  raise Compiler_Defect with "non-C RISC-V aggregate";
               end if;
               declare
                  Placement : Landin.Targets.Placement :=
                    Landin.Targets.Empty_Placement;
               begin
                  for Index in 1 .. Landin.IR.Aggregate_Field_Count
                    (Of_Unit, Shape)
                  loop
                     declare
                        Field : constant Landin.IR.Field_Shape :=
                          Landin.IR.Nth_Aggregate_Field
                            (Of_Unit, Shape, Index);
                        Bytes, At_Offset : Landin.Targets.Byte_Count;
                        Alignment : Landin.Targets.Byte_Alignment;
                     begin
                        Field_Extent (Of_Unit, Field, Facts, Bytes, Alignment);
                        Landin.Targets.Place
                          (Placement, Bytes, Alignment, At_Offset);
                        Visit (Field, Offset + At_Offset);
                        exit when not Flattened;
                     end;
                  end loop;
               end;
            when Landin.IR.Array_Field_Shape =>
               declare
                  Element : constant Landin.IR.Field_Shape :=
                    Landin.IR.Array_Element_Shape (Of_Unit, Shape);
                  Bytes : Landin.Targets.Byte_Count;
                  Alignment : Landin.Targets.Byte_Alignment;
               begin
                  Field_Extent (Of_Unit, Element, Facts, Bytes, Alignment);
                  --  Three leaves disprove FP transport. Never enumerate a
                  --  target-sized array; empty elements contribute no leaf.
                  if Bytes > 0 then
                     for Index in 1 .. Landin.IR.Element_Total'Min
                       (Shape.Length, 3)
                     loop
                        Visit (Element, Offset
                          + Landin.Targets.Byte_Count (Index - 1) * Bytes);
                        exit when not Flattened;
                     end loop;
                  end if;
               end;
            when Landin.IR.Variant_Field_Shape =>
               raise Compiler_Defect with "variant in RISC-V C signature";
         end case;
      end Visit;
   begin
      if Landin.Targets.C_ABI_Of (Facts) /= Landin.Targets.RiscV_LP64D
        or else Landin.Targets.Pointer_Width (Facts) /= 64
        or else Landin.Targets.Stack_Alignment (Facts) /= 16
      then
         raise Compiler_Defect with "LP64D transport requires RV64 layout";
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
            if Floating and then Part.Kind in Landin.Types.Float_Name then
               Answer.Count := 1;
               Answer.Parts (1) := (Float_Class, 0, Answer.Size, Part.Kind);
               return Answer;
            end if;
         end;
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
            if Floating then
               Visit (Shape, 0);
               if Flattened and then Float_Count > 0 then
                  Answer.Count := Count;
                  Answer.Parts := Leaves;
                  return Answer;
               end if;
            end if;
         end;
      else
         raise Compiler_Defect with "unsupported RISC-V C carrier";
      end if;
      if Answer.Size > 16 then
         Answer.Indirect := True;
         Answer.Count := 1;
         Answer.Parts (1) := (Integer_Class, 0, 8, Landin.Types.Usize);
      else
         Answer.Count := Natural ((Answer.Size + 7) / 8);
         for Index in 1 .. Answer.Count loop
            declare
               Offset : constant Landin.Targets.Byte_Count :=
                 Landin.Targets.Byte_Count (Index - 1) * 8;
            begin
               Answer.Parts (Index) :=
                 (Integer_Class, Offset,
                  Landin.Targets.Byte_Count'Min (8, Answer.Size - Offset),
                  (if Answer.Aggregate then Landin.Types.No_Value
                   else Part.Kind));
            end;
         end loop;
      end if;
      return Answer;
   end Classify;

   function Assign
     (Of_Unit : Landin.IR.Unit;
      Parameters : Landin.IR.Signature_Part_Array;
      Result : Landin.IR.Signature_Part;
      Facts : Landin.Targets.Target_Facts;
      Maximum : Landin.Targets.Byte_Count :=
        Landin.Targets.Byte_Count'Last;
      Fixed_Count : Natural := Natural'Last) return Plan
   is
      Answer : Plan (Parameters'Length);
      Stack_End : Landin.Targets.Byte_Count := 0;
      Variadic_Stack : Boolean := False;
      Result_GP, Result_FP : Natural := 0;
   begin
      Answer.Result.Shape := Classify (Of_Unit, Result, Facts);
      for Index in 1 .. Answer.Result.Shape.Count loop
         if Answer.Result.Shape.Parts (Index).Class = Float_Class then
            Result_FP := Result_FP + 1;
            Answer.Result.Parts (Index).Register := Result_FP;
         else
            Result_GP := Result_GP + 1;
            Answer.Result.Parts (Index).Register := Result_GP;
         end if;
      end loop;
      if Answer.Result.Shape.Indirect then
         --  The result address is an implicit first integer argument.
         Answer.GP_Used := 1;
      end if;
      for Index in Answer.Arguments'Range loop
         declare
            Item : Location renames Answer.Arguments (Index);
            Written : Landin.IR.Signature_Part renames
              Parameters (Parameters'First + Index - 1);
            Variadic : constant Boolean := Index > Fixed_Count;
            GP, FP : Natural := 0;
            Uses_FP : Boolean := False;
         begin
            Item.Shape := Classify (Of_Unit, Written, Facts, not Variadic);
            for Part in 1 .. Item.Shape.Count loop
               if Item.Shape.Parts (Part).Class = Float_Class then
                  FP := FP + 1;
                  Uses_FP := True;
               else
                  GP := GP + 1;
               end if;
            end loop;
            if Uses_FP and then
              (Answer.GP_Used + GP > 8 or else Answer.FP_Used + FP > 8)
            then
               --  Roll back the entire mixed/FP aggregate to integer
               --  transport, without consuming either available bank.
               Item.Shape := Classify (Of_Unit, Written, Facts, False);
               Uses_FP := False;
            end if;
            if Variadic and then not Item.Shape.Indirect
              and then Item.Shape.Alignment = 16
              and then Answer.GP_Used mod 2 /= 0
            then
               Answer.GP_Used := Answer.GP_Used + 1;
            end if;
            for Part in 1 .. Item.Shape.Count loop
               if Uses_FP and then
                 Item.Shape.Parts (Part).Class = Float_Class
               then
                  Answer.FP_Used := Answer.FP_Used + 1;
                  Item.Parts (Part).Register := Answer.FP_Used;
               elsif Answer.GP_Used < 8 and then not Variadic_Stack then
                  Answer.GP_Used := Answer.GP_Used + 1;
                  Item.Parts (Part).Register := Answer.GP_Used;
               else
                  if Part = 1 then
                     Stack_End := Stack_Align
                       (Stack_End, Landin.Targets.Byte_Alignment'Min
                         (16, Landin.Targets.Byte_Alignment'Max
                            (8, Item.Shape.Alignment)), Maximum);
                  end if;
                  Item.Parts (Part).Stack_At := Stack_End;
                  Stack_End := Stack_Add (Stack_End, 8, Maximum);
                  if Variadic then
                     Variadic_Stack := True;
                  end if;
               end if;
            end loop;
         end;
      end loop;
      Answer.Stack_Bytes := Stack_Align (Stack_End, 16, Maximum);
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

end Landin.Backend.RiscV_ABI;
