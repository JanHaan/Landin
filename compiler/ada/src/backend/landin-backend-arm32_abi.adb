with Landin.Types;

package body Landin.Backend.Arm32_ABI is

   package IR renames Landin.IR;
   package Ty renames Landin.Types;
   package T renames Landin.Targets;
   use type IR.Atom_Set_Id;
   use type IR.Opcode;
   use type IR.Parameter_Convention;
   use type Ty.Type_Kind;
   use type T.Byte_Count;
   use type T.Byte_Alignment;
   use type T.Target_Facts;

   procedure Require_Target (Facts : T.Target_Facts);

   procedure Require_Target (Facts : T.Target_Facts) is
   begin
      if Facts /= T.Cortex_M then
         raise Compiler_Defect with "ARMv6-M ABI requires Cortex-M facts";
      end if;
   end Require_Target;

   function Classify
     (Of_Unit : IR.Unit;
      Part    : IR.Signature_Part;
      Facts   : T.Target_Facts;
      ABI     : Convention) return Classification
   is
      Answer : Classification;

      procedure Check_C (Shape : IR.Field_Shape);

      procedure Check_C (Shape : IR.Field_Shape) is
      begin
         case Shape.Kind is
            when IR.Scalar_Field_Shape =>
               if Shape.Atoms /= IR.No_Atom_Set then
                  raise Compiler_Defect with "atom in AAPCS C record";
               end if;
            when IR.Aggregate_Field_Shape =>
               if not IR.Has_C_Layout (Of_Unit, Shape.Nominal)
                 or else IR.Aggregate_Field_Count (Of_Unit, Shape) = 0
               then
                  raise Compiler_Defect with "non-C AAPCS aggregate";
               end if;
               for Index in 1 .. IR.Aggregate_Field_Count (Of_Unit, Shape)
               loop
                  Check_C (IR.Nth_Aggregate_Field (Of_Unit, Shape, Index));
               end loop;
            when IR.Array_Field_Shape =>
               Check_C (IR.Array_Element_Shape (Of_Unit, Shape));
            when IR.Variant_Field_Shape =>
               raise Compiler_Defect with "variant in AAPCS C record";
         end case;
      end Check_C;
   begin
      Require_Target (Facts);
      if ABI = External_C
        and then (Part.Atoms /= IR.No_Atom_Set
                  or else Part.Convention /= IR.In_Value
                  or else Part.Kind = Ty.Fixed_Array)
      then
         raise Compiler_Defect with "non-C AAPCS signature part";
      end if;
      if Part.Kind = Ty.No_Value then
         return Answer;
      elsif Part.Convention = IR.Inout_Place
        or else Part.Kind = Ty.Function_Value
      then
         Answer.Size := T.Byte_Count (T.Bytes (T.Pointer_Size (Facts)));
         Answer.Alignment := T.Pointer_Alignment (Facts);
      elsif Part.Kind in Ty.Scalar_Name then
         declare
            Size : constant T.Scalar_Size := Size_Of (Part.Kind, Facts);
         begin
            Answer.Size := T.Byte_Count (T.Bytes (Size));
            Answer.Alignment := T.Alignment_Of (Facts, Size);
            if Answer.Size < 4 then
               Answer.Extend :=
                 (if Part.Kind in Ty.I8 | Ty.I16 then Sign_Extend
                  else Zero_Extend);
            end if;
         end;
      elsif Part.Kind in Ty.Aggregate | Ty.Fixed_Array then
         declare
            Shape : constant IR.Field_Shape :=
              (if Part.Kind = Ty.Aggregate
               then (Kind => IR.Aggregate_Field_Shape,
                     Nominal => Part.Nominal, others => <>)
               else (Kind => IR.Array_Field_Shape,
                     Element => Part.Element, Length => Part.Length,
                     Nominal => Part.Element_Shape.Nominal, others => <>));
         begin
            Field_Extent
              (Of_Unit, Shape, Facts, Answer.Size, Answer.Alignment);
            Answer.Composite := True;
            Answer.Indirect := ABI = Internal_Landin;
            if ABI = External_C then
               if Answer.Size = 0 then
                  raise Compiler_Defect with "empty AAPCS C aggregate";
               end if;
               Check_C (Shape);
            end if;
         end;
      else
         --  Pointers, optional pointers, atoms, slices, any and distinct
         --  types must arrive through lowering's existing neutral carriers.
         raise Compiler_Defect with "unlowered ARMv6-M signature carrier";
      end if;
      return Answer;
   end Classify;

   function Assign
     (Of_Unit    : IR.Unit;
      Parameters : IR.Signature_Part_Array;
      Results    : IR.Signature_Part_Array;
      Facts      : T.Target_Facts;
      ABI        : Convention;
      Has_Error  : Boolean := False;
      Maximum    : T.Byte_Count := 16#FFFF_FFFF#;
      Fixed_Count : Natural := Natural'Last) return Plan
   is
      Answer : Plan (Parameters'Length);
      Next_Core : Natural range 0 .. 4 := 0;
      Stack_End : T.Byte_Count := 0;
      Limit : constant T.Byte_Count :=
        T.Byte_Count'Min (Maximum, T.Maximum_Object_Size (Facts));
   begin
      Require_Target (Facts);
      if ABI = External_C and then (Has_Error or else Results'Length > 1)
      then
         raise Compiler_Defect with "Landin outcome in AAPCS C signature";
      elsif ABI = Internal_Landin and then Fixed_Count /= Natural'Last then
         raise Compiler_Defect with "variadic internal Landin signature";
      end if;
      Answer.Has_Error := Has_Error;
      if Results'Length = 1 then
         Answer.Result.Shape := Classify
           (Of_Unit, Results (Results'First), Facts, ABI);
      elsif Results'Length > 1 then
         declare
            Layout : T.Placement := T.Empty_Placement;
            Offset : T.Byte_Count;
         begin
            for Part of Results loop
               declare
                  Shape : constant Classification :=
                    Classify (Of_Unit, Part, Facts, ABI);
               begin
                  if not T.Can_Place
                    (Layout, Shape.Size, Shape.Alignment,
                     T.Maximum_Object_Size (Facts))
                  then
                     raise Compiler_Defect with "ARMv6-M result overflow";
                  end if;
                  T.Place (Layout, Shape.Size, Shape.Alignment, Offset);
               end;
            end loop;
            Answer.Result.Shape :=
              (Size => T.Size_Of (Layout),
               Alignment => T.Alignment_Of (Layout),
               Composite => True, Indirect => True, others => <>);
         end;
      end if;
      if Answer.Result.Shape.Composite
        and then (ABI = Internal_Landin or else Answer.Result.Shape.Size > 4)
      then
         Answer.Result.Shape.Indirect := True;
         --  Unlike AAPCS64 x8, the hidden destination consumes r0.
         Answer.Result.First_Core := 0;
         Answer.Result.Core_Count := 1;
         Next_Core := 1;
      elsif Answer.Result.Shape.Size > 0 then
         Answer.Result.First_Core := 0;
         Answer.Result.Core_Count :=
           Natural ((Answer.Result.Shape.Size + 3) / 4);
      end if;
      for Index in Answer.Arguments'Range loop
         declare
            Part : constant IR.Signature_Part :=
              Parameters (Parameters'First + Index - 1);
            Item : Location renames Answer.Arguments (Index);
            Bytes : T.Byte_Count;
            Alignment : T.Byte_Alignment;
            Words : T.Byte_Count;
         begin
            if Index > Fixed_Count
              and then (Part.Kind not in Ty.I32 | Ty.U32 | Ty.I64 | Ty.U64
                         | Ty.Isize | Ty.Usize | Ty.F64 | Ty.Function_Value
                        or else Part.Convention /= IR.In_Value)
            then
               raise Compiler_Defect with "unpromoted AAPCS variadic tail";
            end if;
            Item.Shape := Classify (Of_Unit, Part, Facts, ABI);
            if Item.Shape.Size = 0 and then not Item.Shape.Indirect then
               raise Compiler_Defect with "empty ARMv6-M argument";
            end if;
            Bytes := (if Item.Shape.Indirect then 4 else Item.Shape.Size);
            Alignment := (if Item.Shape.Indirect then 4
                          else T.Byte_Alignment'Max (4, Item.Shape.Alignment));
            Bytes := T.Align_Up (Bytes, 4);
            Words := Bytes / 4;
            if Alignment = 8 and then Next_Core mod 2 /= 0 then
               Next_Core := Next_Core + 1;
            end if;
            if Words <= T.Byte_Count (4 - Next_Core) then
               Item.First_Core := Next_Core;
               Item.Core_Count := Natural (Words);
               Next_Core := Next_Core + Item.Core_Count;
            else
               if Next_Core < 4 and then Stack_End = 0 then
                  Item.First_Core := Next_Core;
                  Item.Core_Count := 4 - Next_Core;
                  Bytes := Bytes - T.Byte_Count (Item.Core_Count) * 4;
               end if;
               Next_Core := 4;
               Item.Stack_At := Stack_Align (Stack_End, Alignment, Limit);
               Item.Stack_Bytes := Bytes;
               Stack_End := Stack_Add (Item.Stack_At, Bytes, Limit);
            end if;
         end;
      end loop;
      Answer.Core_Used := Next_Core;
      Answer.Stack_Bytes := Stack_Align (Stack_End, 8, Limit);
      return Answer;
   end Assign;

   function Call_Plan
     (Of_Unit : IR.Unit;
      Item    : IR.Item_Id;
      Call    : IR.Value_Id;
      Facts   : T.Target_Facts;
      Maximum : T.Byte_Count := 16#FFFF_FFFF#) return Plan
   is
      Indirect : constant Boolean :=
        IR.Op_Of (Of_Unit, Item, Call) = IR.Indirect_Call;
      Signature : constant IR.Signature_Id :=
        (if Indirect then IR.Call_Signature (Of_Unit, Item, Call)
         else IR.Signature_Of (Of_Unit, IR.Callee_Of (Of_Unit, Item, Call)));
      Results : IR.Signature_Part_Array
        (1 .. IR.Signature_Result_Count (Of_Unit, Signature));
      Hidden : constant Natural :=
        (if Results'Length > 1
         or else (Results'Length = 1 and then IR.Nth_Signature_Result
           (Of_Unit, Signature, 1).Kind in Ty.Aggregate | Ty.Fixed_Array)
         then 1 else 0);
      Offset : constant Natural := (if Indirect then 1 else 0);
      Fixed : constant Natural :=
        IR.Signature_Parameter_Count (Of_Unit, Signature);
      Parameters : IR.Signature_Part_Array
        (1 .. IR.Operand_Count (Of_Unit, Item, Call) - Offset - Hidden);
      Is_C : constant Boolean := IR.Signature_Uses_C_ABI (Of_Unit, Signature);
   begin
      for Index in Results'Range loop
         Results (Index) := IR.Nth_Signature_Result
           (Of_Unit, Signature, Index);
      end loop;
      for Index in Parameters'Range loop
         Parameters (Index) :=
           (if Index <= Fixed
            then IR.Nth_Signature_Parameter (Of_Unit, Signature, Index)
            else (Kind => IR.Result_Of
                    (Of_Unit, Item, IR.Nth_Operand
                       (Of_Unit, Item, Call, Index + Offset + Hidden)),
                  others => <>));
      end loop;
      return Assign
        (Of_Unit, Parameters, Results, Facts,
         (if Is_C then External_C else Internal_Landin),
         IR.Signature_Errors (Of_Unit, Signature) /= IR.No_Atom_Set,
         Maximum, (if Is_C then Fixed else Natural'Last));
   end Call_Plan;

   function Signature_Plan
     (Of_Unit   : IR.Unit;
      Signature : IR.Signature_Id;
      Facts     : T.Target_Facts;
      Maximum   : T.Byte_Count := 16#FFFF_FFFF#) return Plan
   is
      Parameters : IR.Signature_Part_Array
        (1 .. IR.Signature_Parameter_Count (Of_Unit, Signature));
      Results : IR.Signature_Part_Array
        (1 .. IR.Signature_Result_Count (Of_Unit, Signature));
   begin
      for Index in Parameters'Range loop
         Parameters (Index) := IR.Nth_Signature_Parameter
           (Of_Unit, Signature, Index);
      end loop;
      for Index in Results'Range loop
         Results (Index) := IR.Nth_Signature_Result
           (Of_Unit, Signature, Index);
      end loop;
      return Assign
        (Of_Unit, Parameters, Results, Facts,
         (if IR.Signature_Uses_C_ABI (Of_Unit, Signature)
          then External_C else Internal_Landin),
         IR.Signature_Errors (Of_Unit, Signature) /= IR.No_Atom_Set,
         Maximum);
   end Signature_Plan;

end Landin.Backend.Arm32_ABI;
