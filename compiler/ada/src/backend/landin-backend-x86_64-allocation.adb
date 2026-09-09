with Ada.Containers;
with Landin.Backend.Work_Arrays;
with Landin.Targets.Layouts;
with Landin.Types;

package body Landin.Backend.X86_64.Allocation is

   use type Landin.IR.Block_Id;
   use type Landin.IR.Opcode;
   use type Landin.IR.Signature_Id;
   use type Landin.IR.Slot_Id;
   use type Landin.Optimization.Objective;
   use type Landin.Types.Type_Kind;

   function Name (Register : Saved_Register; Size : Width) return String is
   begin
      case Register is
         when RBX =>
            return (case Size is
                       when Landin.Targets.Byte_1 => "%bl",
                       when Landin.Targets.Byte_2 => "%bx",
                       when Landin.Targets.Byte_4 => "%ebx",
                       when Landin.Targets.Byte_8 => "%rbx");
         when R12 =>
            return (case Size is
                       when Landin.Targets.Byte_1 => "%r12b",
                       when Landin.Targets.Byte_2 => "%r12w",
                       when Landin.Targets.Byte_4 => "%r12d",
                       when Landin.Targets.Byte_8 => "%r12");
         when R13 =>
            return (case Size is
                       when Landin.Targets.Byte_1 => "%r13b",
                       when Landin.Targets.Byte_2 => "%r13w",
                       when Landin.Targets.Byte_4 => "%r13d",
                       when Landin.Targets.Byte_8 => "%r13");
         when R14 =>
            return (case Size is
                       when Landin.Targets.Byte_1 => "%r14b",
                       when Landin.Targets.Byte_2 => "%r14w",
                       when Landin.Targets.Byte_4 => "%r14d",
                       when Landin.Targets.Byte_8 => "%r14");
         when R15 =>
            return (case Size is
                       when Landin.Targets.Byte_1 => "%r15b",
                       when Landin.Targets.Byte_2 => "%r15w",
                       when Landin.Targets.Byte_4 => "%r15d",
                       when Landin.Targets.Byte_8 => "%r15");
      end case;
   end Name;

   function Save_Count (Of_Plan : Plan) return Natural is
      Count : Natural := 0;
   begin
      for Used of Of_Plan.Used loop
         if Used then
            Count := Count + 1;
         end if;
      end loop;
      return Count;
   end Save_Count;

   function Save_Index
     (Of_Plan : Plan; Register : Saved_Register) return Positive
   is
      Count : Natural := 0;
   begin
      for Which in Saved_Register loop
         if Of_Plan.Used (Which) then
            Count := Count + 1;
         end if;
         if Which = Register and then Of_Plan.Used (Which) then
            return Positive (Count);
         end if;
      end loop;
      raise Landin.Compiler_Defect with "an unsaved register has no save home";
   end Save_Index;

   function Make
     (Of_Unit : Landin.IR.Unit;
      Item : Landin.IR.Item_Id;
      Facts : Landin.Targets.Target_Facts;
      Options : Landin.Optimization.Options) return Plan
   is
      Slot_Count : constant Natural := Landin.IR.Slot_Count (Of_Unit, Item);
      Value_Count : constant Natural := Landin.IR.Value_Count (Of_Unit, Item);
      Result : Plan (Slot_Count, Value_Count);
   begin
      Result.Slot := Location_Vectors.To_Vector
        (Location'(others => <>), Ada.Containers.Count_Type (Slot_Count));
      Result.Value := Location_Vectors.To_Vector
        (Location'(others => <>), Ada.Containers.Count_Type (Value_Count));
      if Options.Optimize = Landin.Optimization.None then
         --  No liveness, promotion or reuse scratch belongs to reference
         --  emission.  Every scalar retains its individual instruction home.
         for Index in 1 .. Slot_Count loop
            Result.Slot (Index).Kind := Stack;
            Result.Slot (Index).Home := Index;
            if not Landin.IR.Is_Aggregate
              (Of_Unit, Item, Landin.IR.Slot_Id (Index))
              and then not Landin.IR.Is_Array
                (Of_Unit, Item, Landin.IR.Slot_Id (Index))
            then
               Result.Slot (Index).Size := Size_Of
                 (Landin.IR.Type_Of
                    (Of_Unit, Item, Landin.IR.Slot_Id (Index)), Facts);
            end if;
         end loop;
         for Index in 1 .. Value_Count loop
            declare
               Kind : constant Landin.Types.Type_Kind := Landin.IR.Result_Of
                 (Of_Unit, Item, Landin.IR.Value_Id (Index));
            begin
               if Kind in Landin.Types.Scalar_Name then
                  Result.Spill_Homes := Result.Spill_Homes + 1;
                  Result.Value (Index) :=
                    (Kind => Stack, Size => Size_Of (Kind, Facts),
                     Home => Result.Spill_Homes, others => <>);
               end if;
            end;
         end loop;
         return Result;
      end if;
      declare
         type Counts is array (Positive range <>) of Natural;
         type Blocks is array (Positive range <>) of Landin.IR.Block_Id;
         package Count_Buffers is new Work_Arrays (Natural, Counts, 0);
         package Block_Buffers is new Work_Arrays
           (Landin.IR.Block_Id, Blocks, Landin.IR.No_Block);
         package Mask_Buffers is new Work_Arrays (Boolean, Home_Mask, False);
         Start_Data, Last_Data, Sequence_Data :
           Count_Buffers.Buffer (Value_Count);
         Use_Data : Count_Buffers.Buffer (Slot_Count);
         Block_Data : Block_Buffers.Buffer (Slot_Count);
         Across_Data, Eligible_Data : Mask_Buffers.Buffer (Slot_Count);
         Starts : Counts renames Start_Data.Data.all;
         Lasts : Counts renames Last_Data.Data.all;
         Sequence : Counts renames Sequence_Data.Data.all;
         Uses : Counts renames Use_Data.Data.all;
         First_Block : Blocks renames Block_Data.Data.all;
         Across_Blocks : Home_Mask renames Across_Data.Data.all;
         Eligible : Home_Mask renames Eligible_Data.Data.all;
         Permanent : Register_Set := [others => False];
         Busy_Until : array (Saved_Register) of Natural := [others => 0];
         --  Release buckets make spill reuse linear in instruction count,
         --  without scanning all previous homes at every definition.
         Release_Data : Count_Buffers.Buffer (Value_Count + 1);
         Next_Release_Data, Free_Data : Count_Buffers.Buffer (Value_Count);
         Releases : Counts renames Release_Data.Data.all;
         Next_Release : Counts renames Next_Release_Data.Data.all;
         Free_Homes : array (Width) of Natural := [others => 0];
         Next_Free : Counts renames Free_Data.Data.all;
         Tick : Natural := 0;
         Traffic : Natural := 0;
         Allocate_GP : Boolean;
         C_Entry : constant Boolean :=
           Landin.IR.Signature_Of (Of_Unit, Item) /= Landin.IR.No_Signature
           and then Landin.IR.Signature_Uses_C_ABI
             (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item));

         procedure Pin (Place : Landin.IR.Storage);
         procedure Pin_Value (Value : Landin.IR.Value_Id);

         procedure Pin (Place : Landin.IR.Storage) is
         begin
            case Place.Kind is
               when Landin.IR.Frame_Slot =>
                  Eligible (Positive (Place.Slot)) := False;
               when Landin.IR.Runtime_Address =>
                  Eligible (Positive (Place.Address)) := False;
               when Landin.IR.Module_Datum => null;
            end case;
         end Pin;

         procedure Pin_Value (Value : Landin.IR.Value_Id) is
         begin
            if Result.Value (Positive (Value)).Kind /= Absent then
               Result.Value (Positive (Value)).Address_Required := True;
            end if;
         end Pin_Value;
      begin
         for Index in 1 .. Slot_Count loop
            declare
               Slot : constant Landin.IR.Slot_Id := Landin.IR.Slot_Id (Index);
               Kind : constant Landin.Types.Type_Kind :=
                 (if Landin.IR.Is_Aggregate (Of_Unit, Item, Slot)
                    or else Landin.IR.Is_Array (Of_Unit, Item, Slot)
                  then Landin.Types.No_Value
                  else Landin.IR.Type_Of (Of_Unit, Item, Slot));
            begin
               Result.Slot (Index).Kind := Stack;
               Result.Slot (Index).Home := Index;
               if Kind in Landin.Types.Scalar_Name then
                  Result.Slot (Index).Size := Size_Of (Kind, Facts);
                  Eligible (Index) := Kind not in Landin.Types.Float_Name
                    and then not Landin.IR.Is_Address (Of_Unit, Item, Slot);
               end if;
            end;
         end loop;
         --  C entry copies use addresses, including scalar entries.  Hidden
         --  destinations/results are implicit uses, never promoted.
         if C_Entry then
            for Index in 1 .. Landin.IR.Parameter_Count (Of_Unit, Item) loop
               Eligible (Positive
                 (Landin.IR.Nth_Parameter (Of_Unit, Item, Index))) := False;
            end loop;
         end if;
         if Landin.IR.Result_Slot (Of_Unit, Item) /= Landin.IR.No_Slot then
            Eligible
              (Positive (Landin.IR.Result_Slot (Of_Unit, Item))) := False;
         end if;
         for Block_Index in 1 .. Landin.IR.Block_Count (Of_Unit, Item) loop
            declare
               Block : constant Landin.IR.Block_Id :=
                 Landin.IR.Block_Id (Block_Index);
            begin
               for Position in 1 .. Landin.IR.Length
                 (Of_Unit, Item, Block)
               loop
                  declare
                     Value : constant Landin.IR.Value_Id :=
                       Landin.IR.Nth_Value (Of_Unit, Item, Block, Position);
                     Index : constant Positive := Positive (Value);
                     Kind : constant Landin.Types.Type_Kind :=
                       Landin.IR.Result_Of (Of_Unit, Item, Value);
                  begin
                     Tick := Tick + 1;
                     Sequence (Tick) := Index;
                     Starts (Index) := Tick;
                     Lasts (Index) := Tick;
                     if Kind in Landin.Types.Scalar_Name then
                        Result.Value (Index).Kind := Stack;
                        Result.Value (Index).Size := Size_Of (Kind, Facts);
                        Traffic := Traffic + 1;
                     end if;
                  end;
               end loop;
            end;
         end loop;
         for Index in 1 .. Value_Count loop
            declare
               Value : constant Landin.IR.Value_Id :=
                 Landin.IR.Value_Id (Index);
               Op : constant Landin.IR.Opcode :=
                 Landin.IR.Op_Of (Of_Unit, Item, Value);
            begin
               for Position in 1 .. Landin.IR.Operand_Count
                 (Of_Unit, Item, Value)
               loop
                  declare
                     Operand : constant Positive :=
                       Positive (Landin.IR.Nth_Operand
                         (Of_Unit, Item, Value, Position));
                  begin
                     Lasts (Operand) := Natural'Max
                       (Lasts (Operand), Starts (Index));
                     Traffic := Traffic + 1;
                  end;
               end loop;
               --  The emitter rereads the receiver through Evidence_Function.
               --  This transitive use is not an ordinary operand of Self.
               if Op = Landin.IR.Evidence_Self then
                  declare
                     Projection : constant Landin.IR.Value_Id :=
                       Landin.IR.Nth_Operand (Of_Unit, Item, Value, 1);
                     Receiver : constant Positive := Positive
                       (Landin.IR.Nth_Operand (Of_Unit, Item, Projection, 1));
                  begin
                     Lasts (Receiver) := Natural'Max
                       (Lasts (Receiver), Starts (Index));
                  end;
               end if;
               case Op is
                  when Landin.IR.Load | Landin.IR.Store =>
                     declare
                        Slot : constant Positive := Positive
                          (Landin.IR.Slot_Of (Of_Unit, Item, Value));
                        Block : constant Landin.IR.Block_Id :=
                          Landin.IR.Block_Of (Of_Unit, Item, Value);
                     begin
                        Uses (Slot) := Uses (Slot) + 1;
                        if First_Block (Slot) = Landin.IR.No_Block then
                           First_Block (Slot) := Block;
                        elsif First_Block (Slot) /= Block then
                           Across_Blocks (Slot) := True;
                        end if;
                     end;
                  when Landin.IR.Load_Field | Landin.IR.Store_Field
                     | Landin.IR.Load_Element | Landin.IR.Store_Element =>
                     if Landin.IR.Reaches_A_Slot (Of_Unit, Item, Value) then
                        Eligible (Positive
                          (Landin.IR.Slot_Of (Of_Unit, Item, Value))) := False;
                     end if;
                  when Landin.IR.Copy_Array | Landin.IR.Copy_Variant =>
                     Pin (Landin.IR.Source_Of (Of_Unit, Item, Value));
                     Pin (Landin.IR.Destination_Of (Of_Unit, Item, Value));
                  when Landin.IR.Load_Variant_Tag
                     | Landin.IR.Load_Variant_Field =>
                     Pin (Landin.IR.Source_Of (Of_Unit, Item, Value));
                  when Landin.IR.Storage_Address | Landin.IR.Place_Address
                     | Landin.IR.Clear_Array | Landin.IR.Fill_Array
                     | Landin.IR.Select_Variant
                     | Landin.IR.Store_Variant_Field =>
                     Pin (Landin.IR.Destination_Of (Of_Unit, Item, Value));
                  when Landin.IR.Call | Landin.IR.Indirect_Call =>
                     declare
                        Signature : constant Landin.IR.Signature_Id :=
                          (if Op = Landin.IR.Indirect_Call
                           then Landin.IR.Call_Signature (Of_Unit, Item, Value)
                           else Landin.IR.Signature_Of
                             (Of_Unit, Landin.IR.Callee_Of
                                (Of_Unit, Item, Value)));
                        Failure : constant Landin.IR.Slot_Id :=
                          Landin.IR.Failure_Slot_Of (Of_Unit, Item, Value);
                     begin
                        if Failure /= Landin.IR.No_Slot then
                           Eligible (Positive (Failure)) := False;
                        end if;
                        if Signature /= Landin.IR.No_Signature
                          and then Landin.IR.Signature_Uses_C_ABI
                            (Of_Unit, Signature)
                        then
                           Pin_Value (Value);
                           for Position in 1 .. Landin.IR.Operand_Count
                             (Of_Unit, Item, Value)
                           loop
                              Pin_Value (Landin.IR.Nth_Operand
                                (Of_Unit, Item, Value, Position));
                           end loop;
                        end if;
                     end;
                  when Landin.IR.Leave =>
                     if C_Entry then
                        for Position in 1 .. Landin.IR.Operand_Count
                          (Of_Unit, Item, Value)
                        loop
                           Pin_Value (Landin.IR.Nth_Operand
                             (Of_Unit, Item, Value, Position));
                        end loop;
                     end if;
                  when others => null;
               end case;
            end;
         end loop;
         Allocate_GP := Options.Optimize /= Landin.Optimization.None
           and then Traffic >= 12;
         if Allocate_GP then
            --  Three whole-function slots retain two interval registers.
            --  Highest static use count wins; source identity breaks ties.
            --  Only cross-block ordinary scalar slots qualify.  Exposure
            --  above removes a slot irrespective of lexical unchecked.
            for Register in RBX .. R13 loop
               declare
                  Best : Natural := 0;
               begin
                  for Index in 1 .. Slot_Count loop
                     if Eligible (Index) and then Across_Blocks (Index)
                       and then Uses (Index) >= 3
                       and then (Best = 0 or else Uses (Index) > Uses (Best))
                     then
                        Best := Index;
                     end if;
                  end loop;
                  if Best /= 0 then
                     Result.Slot (Best).Kind := GP;
                     Result.Slot (Best).Register := Register;
                     Result.Slot (Best).Home := 0;
                     Eligible (Best) := False;
                     Permanent (Register) := True;
                     Result.Used (Register) := True;
                  end if;
               end;
            end loop;
         end if;
         for Position in 1 .. Value_Count loop
            declare
               Index : constant Positive := Positive (Sequence (Position));
               Value : constant Landin.IR.Value_Id :=
                 Landin.IR.Value_Id (Index);
               Place : Location renames Result.Value (Index);
               Released : Natural := Releases (Position);
            begin
               while Released /= 0 loop
                  declare
                     Old : Location renames Result.Value (Released);
                  begin
                     Next_Free (Old.Home) := Free_Homes (Old.Size);
                     Free_Homes (Old.Size) := Old.Home;
                     Released := Next_Release (Released);
                  end;
               end loop;
               if Place.Kind /= Absent then
                  if Allocate_GP and then not Place.Address_Required
                    and then Landin.IR.Result_Of (Of_Unit, Item, Value)
                      not in Landin.Types.Float_Name
                  then
                     for Register in Saved_Register loop
                        if not Permanent (Register)
                          and then Busy_Until (Register) < Position
                        then
                           Place.Kind := GP;
                           Place.Register := Register;
                           Busy_Until (Register) := Lasts (Index);
                           Result.Used (Register) := True;
                           exit;
                        end if;
                     end loop;
                  end if;
                  if Place.Kind = Stack then
                     if Options.Optimize /= Landin.Optimization.None
                       and then Free_Homes (Place.Size) /= 0
                     then
                        Place.Home := Free_Homes (Place.Size);
                        Free_Homes (Place.Size) := Next_Free (Place.Home);
                     else
                        Result.Spill_Homes := Result.Spill_Homes + 1;
                        Place.Home := Result.Spill_Homes;
                     end if;
                     Next_Release (Index) := Releases (Lasts (Index) + 1);
                     Releases (Lasts (Index) + 1) := Index;
                  end if;
               end if;
            end;
         end loop;
      end;
      return Result;
   end Make;

   function Frame_For
     (Of_Unit : Landin.IR.Unit;
      Item : Landin.IR.Item_Id;
      Facts : Landin.Targets.Target_Facts;
      Of_Plan : Plan;
      Options : Landin.Optimization.Options) return Frame
   is
   begin
      if Options.Optimize = Landin.Optimization.None then
         return Laid_Out (Of_Unit, Item, Facts);
      end if;
      declare
         package Mask_Buffers is new Work_Arrays (Boolean, Home_Mask, False);
         package Value_Buffers is new Work_Arrays
           (Natural, Spill_Assignments, 0);
         package Extent_Buffers is new Work_Arrays
           (Landin.Targets.Layouts.Field_Extent,
            Landin.Targets.Layouts.Field_Extent_Array, (0, 1));
         Slot_Data : Mask_Buffers.Buffer (Of_Plan.Slots);
         Value_Data : Value_Buffers.Buffer (Of_Plan.Values);
         Spill_Data : Extent_Buffers.Buffer (Of_Plan.Spill_Homes);
         Slots : Home_Mask renames Slot_Data.Data.all;
         Values : Spill_Assignments renames Value_Data.Data.all;
         Spills : Landin.Targets.Layouts.Field_Extent_Array renames
           Spill_Data.Data.all;
         Saves : constant Landin.Targets.Layouts.Field_Extent_Array
           (1 .. Save_Count (Of_Plan)) :=
             [others => (Size => 8, Alignment => 8)];
      begin
         for Index in Slots'Range loop
            Slots (Index) := Of_Plan.Slot (Index).Kind = Stack;
         end loop;
         for Index in Values'Range loop
            declare
               Place : Location renames Of_Plan.Value (Index);
            begin
               Values (Index) := Place.Home;
               if Place.Kind = Stack then
                  Spills (Place.Home) :=
                    (Size => Landin.Targets.Byte_Count
                       (Landin.Targets.Bytes (Place.Size)),
                     Alignment =>
                       Landin.Targets.Alignment_Of (Facts, Place.Size));
               end if;
            end;
         end loop;
         return Laid_Out (Of_Unit, Item, Facts, Slots, Values, Spills, Saves);
      end;
   end Frame_For;

end Landin.Backend.X86_64.Allocation;
