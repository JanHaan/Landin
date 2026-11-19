with Landin.IR.Control_Flow;
with Landin.Memory;
with Landin.Types;

package body Landin.Backend.Placement is

   use type Landin.IR.Opcode;
   use type Landin.IR.Signature_Id;
   use type Landin.IR.Slot_Id;
   use type Landin.IR.Declaration_Id;
   use type Landin.Memory.Operation;

   --  D450: compiler.stack_switch is a call of the program's switch
   --  routine, which returns with only the callee-saved registers kept.
   function Is_Switch
     (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id;
      Value : Landin.IR.Value_Id) return Boolean
     is (Landin.IR.Op_Of (Of_Unit, Item, Value) = Landin.IR.Memory_Access
         and then Landin.IR.Memory_Operation (Of_Unit, Item, Value)
           = Landin.Memory.Stack_Switch);

   procedure Measure
     (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id;
      Speed : Boolean; Into : in out Usage;
      Debugger_Spans : Boolean := True)
   is
      Value_Count : constant Natural := Into.Values;
      Slot_Count : constant Natural := Into.Slots;
      Sequence : Counts renames Into.Sequence.Data.all;
      Starts : Counts renames Into.Starts.Data.all;
      Lasts : Counts renames Into.Lasts.Data.all;
      Written_After : Counts renames Into.Written_After.Data.all;
      Calls_Before : Counts renames Into.Calls_Before.Data.all;
      Address_Required : Home_Mask renames Into.Address_Required.Data.all;
      Uses : Counts renames Into.Uses.Data.all;
      Weights : Counts renames Into.Weights.Data.all;
      Parameter_Of : Counts renames Into.Parameter_Of.Data.all;
      First_Use : Counts renames Into.First_Use.Data.all;
      Last_Use : Counts renames Into.Last_Use.Data.all;
      First_Block : Counts renames Into.First_Block.Data.all;
      Across_Blocks : Home_Mask renames Into.Across_Blocks.Data.all;
      Eligible : Home_Mask renames Into.Eligible.Data.all;
      Graph : constant Landin.IR.Control_Flow.Graph :=
        Landin.IR.Control_Flow.Make (Of_Unit, Item);
      Depth : constant Landin.IR.Liveness.Count_Vectors.Vector :=
        (if Speed then Landin.IR.Liveness.Loop_Depths (Graph)
         else Landin.IR.Liveness.Count_Vectors.Empty_Vector);
      Tick : Natural := 0;

      procedure Reach
        (Place : Landin.IR.Storage; Value : Landin.IR.Value_Id);
      procedure Count_Use
        (Of_Slot : Landin.IR.Slot_Id; Value : Landin.IR.Value_Id);

      --  An operation reaching storage needs a frame slot's cell, and
      --  reads only the address an address slot holds.
      procedure Reach
        (Place : Landin.IR.Storage; Value : Landin.IR.Value_Id) is
      begin
         case Place.Kind is
            when Landin.IR.Frame_Slot =>
               Eligible (Positive (Place.Slot)) := False;
            when Landin.IR.Runtime_Address =>
               Count_Use (Place.Address, Value);
            when Landin.IR.Module_Datum => null;
         end case;
      end Reach;

      procedure Count_Use
        (Of_Slot : Landin.IR.Slot_Id; Value : Landin.IR.Value_Id)
      is
         Slot : constant Positive := Positive (Of_Slot);
         At_Position : constant Positive := Starts (Positive (Value));
         Block : constant Positive :=
           Positive (Landin.IR.Block_Of (Of_Unit, Item, Value));
         Step : constant Natural :=
           (if Speed then 8 ** Natural'Min (Depth (Block), 4) else 1);
      begin
         if First_Use (Slot) = 0 or else At_Position < First_Use (Slot) then
            First_Use (Slot) := At_Position;
         end if;
         Last_Use (Slot) := Natural'Max (Last_Use (Slot), At_Position);
         if First_Block (Slot) = 0 then
            First_Block (Slot) := Block;
         elsif First_Block (Slot) /= Block then
            Across_Blocks (Slot) := True;
         end if;
         Uses (Slot) := Uses (Slot) + 1;
         Weights (Slot) :=
           (if Weights (Slot) > Natural'Last - Step
            then Natural'Last else Weights (Slot) + Step);
      end Count_Use;
   begin
      Into.C_Entry :=
        Landin.IR.Signature_Of (Of_Unit, Item) /= Landin.IR.No_Signature
        and then Landin.IR.Signature_Uses_C_ABI
          (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item));
      Into.Spans := Landin.IR.Liveness.Slot_Intervals (Of_Unit, Item, Graph);
      for Block_Index in 1 .. Landin.IR.Block_Count (Of_Unit, Item) loop
         declare
            Block : constant Landin.IR.Block_Id :=
              Landin.IR.Block_Id (Block_Index);
         begin
            for Position in 1 .. Landin.IR.Length (Of_Unit, Item, Block) loop
               declare
                  Index : constant Positive := Positive
                    (Landin.IR.Nth_Value (Of_Unit, Item, Block, Position));
               begin
                  Tick := Tick + 1;
                  Sequence (Tick) := Index;
                  Starts (Index) := Tick;
                  Lasts (Index) := Tick;
                  Calls_Before (Tick + 1) := Calls_Before (Tick)
                    + (if Landin.IR.Op_Of
                            (Of_Unit, Item, Landin.IR.Value_Id (Index))
                          in Landin.IR.Call | Landin.IR.Indirect_Call
                           | Landin.IR.Assembly
                         or else Is_Switch
                           (Of_Unit, Item, Landin.IR.Value_Id (Index))
                       then 1 else 0);
               end;
            end loop;
         end;
      end loop;
      for Index in 1 .. Landin.IR.Parameter_Count (Of_Unit, Item) loop
         Parameter_Of (Positive
           (Landin.IR.Nth_Parameter (Of_Unit, Item, Index))) := Index;
      end loop;
      --  A scalar slot may be held in a register.  A C entry's parameters
      --  and result slot are reached by address, as is every slot a frame
      --  storage operand names.  A Landin routine's result slot is read by
      --  nothing but the leave's own operand.
      for Index in 1 .. Slot_Count loop
         declare
            Slot : constant Landin.IR.Slot_Id := Landin.IR.Slot_Id (Index);
         begin
            Eligible (Index) :=
              not Landin.IR.Is_Aggregate (Of_Unit, Item, Slot)
              and then not Landin.IR.Is_Array (Of_Unit, Item, Slot);
         end;
      end loop;
      if Into.C_Entry then
         for Index in 1 .. Landin.IR.Parameter_Count (Of_Unit, Item) loop
            Eligible (Positive
              (Landin.IR.Nth_Parameter (Of_Unit, Item, Index))) := False;
         end loop;
         if Landin.IR.Result_Slot (Of_Unit, Item) /= Landin.IR.No_Slot then
            Eligible (Positive (Landin.IR.Result_Slot (Of_Unit, Item))) :=
              False;
         end if;
      end if;
      for Index in 1 .. Landin.IR.Source_Alias_Count (Of_Unit, Item) loop
         declare
            Place : constant Landin.IR.Storage :=
              Landin.IR.Nth_Source_Alias (Of_Unit, Item, Index).Place;
         begin
            --  An alias is described through its storage throughout.
            case Place.Kind is
               when Landin.IR.Frame_Slot =>
                  Eligible (Positive (Place.Slot)) := False;
               when Landin.IR.Runtime_Address =>
                  Eligible (Positive (Place.Address)) := False;
               when Landin.IR.Module_Datum => null;
            end case;
         end;
      end loop;
      for Index in 1 .. Value_Count loop
         declare
            Value : constant Landin.IR.Value_Id := Landin.IR.Value_Id (Index);
            Op : constant Landin.IR.Opcode :=
              Landin.IR.Op_Of (Of_Unit, Item, Value);
            --  Assembly reads its inputs, and C transport its scalar
            --  arguments and result, through their frame homes.  A native
            --  call moves each from wherever it is.
            Addressed : constant Boolean :=
              Op = Landin.IR.Assembly
              or else
                (Op in Landin.IR.Call | Landin.IR.Indirect_Call
                 and then Landin.IR.Signature_Uses_C_ABI
                   (Of_Unit,
                    (if Op = Landin.IR.Indirect_Call
                     then Landin.IR.Call_Signature (Of_Unit, Item, Value)
                     else Landin.IR.Signature_Of
                       (Of_Unit,
                        Landin.IR.Callee_Of (Of_Unit, Item, Value)))));
         begin
            if Landin.IR.Result_Of (Of_Unit, Item, Value) in
              Landin.Types.Scalar_Name
            then
               Into.Traffic := Into.Traffic + 1;
            end if;
            for Position in 1 .. Landin.IR.Operand_Count
              (Of_Unit, Item, Value)
            loop
               declare
                  Operand : constant Positive := Positive
                    (Landin.IR.Nth_Operand (Of_Unit, Item, Value, Position));
               begin
                  Lasts (Operand) :=
                    Natural'Max (Lasts (Operand), Starts (Index));
                  Into.Traffic := Into.Traffic + 1;
                  if Addressed then
                     Address_Required (Operand) := True;
                  end if;
               end;
            end loop;
            if Op = Landin.IR.Evidence_Self then
               declare
                  Projection : constant Landin.IR.Value_Id :=
                    Landin.IR.Nth_Operand (Of_Unit, Item, Value, 1);
                  Receiver : constant Positive := Positive
                    (Landin.IR.Nth_Operand (Of_Unit, Item, Projection, 1));
               begin
                  Lasts (Receiver) :=
                    Natural'Max (Lasts (Receiver), Starts (Index));
               end;
            end if;
            if Addressed then
               Address_Required (Index) := True;
            elsif Op = Landin.IR.Leave and then Into.C_Entry then
               for Position in 1 .. Landin.IR.Operand_Count
                 (Of_Unit, Item, Value)
               loop
                  Address_Required (Positive (Landin.IR.Nth_Operand
                    (Of_Unit, Item, Value, Position))) := True;
               end loop;
            end if;
            case Op is
               when Landin.IR.Load | Landin.IR.Store =>
                  Count_Use (Landin.IR.Slot_Of (Of_Unit, Item, Value), Value);
               when Landin.IR.Load_Field | Landin.IR.Store_Field
                  | Landin.IR.Load_Element | Landin.IR.Store_Element =>
                  if Landin.IR.Reaches_A_Slot (Of_Unit, Item, Value) then
                     Reach
                       ((if Landin.IR.Is_Address
                           (Of_Unit, Item,
                            Landin.IR.Slot_Of (Of_Unit, Item, Value))
                         then (Kind => Landin.IR.Runtime_Address,
                               Address => Landin.IR.Slot_Of
                                 (Of_Unit, Item, Value))
                         else (Kind => Landin.IR.Frame_Slot,
                               Slot => Landin.IR.Slot_Of
                                 (Of_Unit, Item, Value))),
                        Value);
                  end if;
               when Landin.IR.Copy_Array | Landin.IR.Copy_Variant =>
                  Reach (Landin.IR.Source_Of (Of_Unit, Item, Value), Value);
                  Reach (Landin.IR.Destination_Of (Of_Unit, Item, Value),
                         Value);
               when Landin.IR.Load_Variant_Tag
                  | Landin.IR.Load_Variant_Field =>
                  Reach (Landin.IR.Source_Of (Of_Unit, Item, Value), Value);
               when Landin.IR.Storage_Address
                  | Landin.IR.Place_Address
                  | Landin.IR.Clear_Array | Landin.IR.Fill_Array
                  | Landin.IR.Select_Variant
                  | Landin.IR.Store_Variant_Field =>
                  Reach (Landin.IR.Destination_Of (Of_Unit, Item, Value),
                         Value);
               when Landin.IR.Call | Landin.IR.Indirect_Call =>
                  if Landin.IR.Failure_Slot_Of (Of_Unit, Item, Value)
                    /= Landin.IR.No_Slot
                  then
                     Eligible (Positive (Landin.IR.Failure_Slot_Of
                       (Of_Unit, Item, Value))) := False;
                  end if;
               when Landin.IR.Assembly =>
                  --  Assembly text may name any register.
                  Into.Has_Assembly := True;
               when others => null;
            end case;
         end;
      end loop;
      if Into.Has_Assembly then
         return;
      end if;
      declare
         Stamp_Data, Next_Data : Count_Buffers.Buffer (Slot_Count);
         Stamp : Counts renames Stamp_Data.Data.all;
         Next_Store : Counts renames Next_Data.Data.all;
      begin
         for Position in reverse 1 .. Value_Count loop
            declare
               Value : constant Landin.IR.Value_Id :=
                 Landin.IR.Value_Id (Sequence (Position));
               Block : constant Positive :=
                 Positive (Landin.IR.Block_Of (Of_Unit, Item, Value));
               Op : constant Landin.IR.Opcode :=
                 Landin.IR.Op_Of (Of_Unit, Item, Value);
            begin
               if Op in Landin.IR.Load | Landin.IR.Store then
                  declare
                     Slot : constant Positive :=
                       Positive (Landin.IR.Slot_Of (Of_Unit, Item, Value));
                  begin
                     if Op = Landin.IR.Store then
                        Stamp (Slot) := Block;
                        Next_Store (Slot) := Position;
                     else
                        Written_After (Positive (Value)) :=
                          (if Stamp (Slot) = Block
                           then Next_Store (Slot) else Natural'Last);
                     end if;
                  end;
               end if;
            end;
         end loop;
      end;
      --  A parameter is written at entry too, and a Landin routine's
      --  result slot read at its leave.
      for Index in 1 .. Slot_Count loop
         if Parameter_Of (Index) /= 0 then
            Uses (Index) := Uses (Index) + 1;
         end if;
      end loop;
      if not Into.C_Entry
        and then Landin.IR.Result_Slot (Of_Unit, Item) /= Landin.IR.No_Slot
      then
         Uses (Positive (Landin.IR.Result_Slot (Of_Unit, Item))) :=
           Uses (Positive (Landin.IR.Result_Slot (Of_Unit, Item))) + 1;
      end if;
      --  Size holds a source variable it gives a register there
      --  throughout, as it holds one in its frame cell, so that a debugger
      --  finds it anywhere in the routine, as x86-64's size does.
      if not Speed and then Debugger_Spans then
         for Index in 1 .. Slot_Count loop
            if not Landin.IR.Liveness.Is_Empty (Into.Spans (Index))
              and then Landin.IR.Declares
                (Of_Unit, Item, Landin.IR.Slot_Id (Index))
                /= Landin.IR.No_Declaration
            then
               Into.Spans (Index) := (0, Value_Count);
            end if;
         end loop;
      end if;
   end Measure;

end Landin.Backend.Placement;
