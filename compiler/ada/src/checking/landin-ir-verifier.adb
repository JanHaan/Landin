with Landin.Types;

package body Landin.IR.Verifier is

   function Describe (Of_Kind : Fault_Kind) return String
     is (case Of_Kind is
            when Nothing_Wrong        => "nothing wrong",
            when Unprepared_Unit      =>
               "the unit was never prepared",
            when Item_Runs_Overlap    =>
               "an item's slots, blocks or instructions are not where its"
               & " run says they are",
            when Operand_Runs_Overlap =>
               "a call's operands are not where its run says they are",
            when Item_Without_A_Block =>
               "an item has no block, so it describes nothing",
            when Item_Still_Building  =>
               "an item was left with a block still open",
            when Empty_Block          =>
               "a block holds no instruction at all",
            when Block_Without_A_Terminator =>
               "a block does not end with a terminator",
            when Terminator_Inside_A_Block  =>
               "a terminator is not the last instruction of its block",
            when Block_Unreachable    =>
               "a block after the first that nothing reaches",
            when Target_Out_Of_Range  =>
               "a jump or a branch names a block the item does not have",
            when Wrong_Operand_Count  =>
               "an instruction carries the wrong number of operands",
            when Operand_Out_Of_Range =>
               "an operand names a value the item does not have",
            when Operand_In_Another_Block =>
               "an operand names a value defined in another block",
            when Operand_Not_Above_Its_Use =>
               "an operand names a value not defined above its use",
            when Operand_Defines_Nothing   =>
               "an operand names an instruction that defines no value",
            when Operands_Disagree    =>
               "two operands of one operator do not have one type",
            when Result_Disagrees     =>
               "an instruction's result is not the type its operands give",
            when Condition_Is_Not_A_Bool =>
               "a branch's condition is not a bool",
            when Slot_Out_Of_Range    =>
               "a load or a store names a slot the item does not have",
            when Store_Disagrees_With_Slot =>
               "a store writes a value the slot's type does not hold",
            when Store_To_A_Parameter =>
               "a store writes a parameter, which [1900] does not permit",
            when Named_Item_Is_Not_A_Datum =>
               "a datum load or store names an item that is a routine",
            when Store_Datum_Disagrees =>
               "a datum store writes a value the datum's type does not"
               & " hold",
            when Aggregate_Datum_Is_Not_A_Value =>
               "a datum load or store names an aggregate, which is"
               & " storage and not a value yet",
            when Field_Out_Of_Range =>
               "a field load names a field the aggregate does not have",
            when Callee_Is_Not_A_Routine =>
               "a call names an item that is not a routine",
            when Call_Inside_A_Datum  =>
               "a datum contains a call, and [1940] admits none",
            when Leave_Disagrees_With_Item =>
               "a leave carries a value the item does not give back");

   --  How many operands each opcode carries.  [1820] decides every row
   --  but Call, whose count is its callee's parameter count [1920].
   function Wanted (Of_Code : Opcode) return Natural
     is (case Of_Code is
            when Constant_Kind => 0,
            --  [0370] carries a type and not an operand.
            when Measure_Size | Measure_Align => 0,
            when Load          => 0,
            when Load_Datum    => 0,
            when Load_Field    => 0,
            when Store         => 1,
            when Store_Datum   => 1,
            when Unary_Kind    => 1,
            when Binary_Kind   => 2,
            when Call          => 0,
            when Jump          => 0,
            when Branch        => 1,
            when Leave         => 0);

   function Check (Of_Unit : Unit) return Fault is
   begin
      if not Is_Prepared (Of_Unit) then
         return (Kind => Unprepared_Unit, others => <>);
      end if;

      --  First, and before anything indexes a run.  A base that is wrong
      --  makes Nth_Value raise Constraint_Error, so a later rule would
      --  never get to speak.
      declare
         Slots      : Natural := 0;
         Parameters : Natural := 0;
         Blocks     : Natural := 0;
         Values     : Natural := 0;
         Fields     : Natural := 0;
      begin
         for Which in 1 .. Item_Count (Of_Unit) loop
            declare
               Held : constant Item_Record :=
                 Of_Unit.Items (Which);
            begin
               if Held.Slots.Count /= 0
                 and then Held.Slots.First /= Slots
               then
                  return (Kind => Item_Runs_Overlap,
                          Item => Item_Id (Which), others => <>);
               end if;

               if Held.Parameters.Count /= 0
                 and then Held.Parameters.First /= Parameters
               then
                  return (Kind => Item_Runs_Overlap,
                          Item => Item_Id (Which), others => <>);
               end if;

               if Held.Blocks.Count /= 0
                 and then Held.Blocks.First /= Blocks
               then
                  return (Kind => Item_Runs_Overlap,
                          Item => Item_Id (Which), others => <>);
               end if;

               if Held.Values.Count /= 0
                 and then Held.Values.First /= Values
               then
                  return (Kind => Item_Runs_Overlap,
                          Item => Item_Id (Which), others => <>);
               end if;

               if Held.Fields.Count /= 0
                 and then Held.Fields.First /= Fields
               then
                  return (Kind => Item_Runs_Overlap,
                          Item => Item_Id (Which), others => <>);
               end if;

               Slots      := Slots + Held.Slots.Count;
               Parameters := Parameters + Held.Parameters.Count;
               Blocks     := Blocks + Held.Blocks.Count;
               Values     := Values + Held.Values.Count;
               Fields     := Fields + Held.Fields.Count;
            end;
         end loop;
      end;

      --  The operand vector, which is the fifth run and the one a call
      --  extends after the fact.
      declare
         Seen : Natural := 0;
      begin
         for Position in 1 .. Natural (Of_Unit.Code.Length) loop
            declare
               What : constant Instruction := Of_Unit.Code (Position);
            begin
               if What.Args /= 0 and then What.First_Arg /= Seen then
                  return (Kind => Operand_Runs_Overlap, others => <>);
               end if;

               Seen := Seen + What.Args;
            end;
         end loop;
      end;

      for Which in 1 .. Item_Count (Of_Unit) loop
         declare
            Id : constant Item_Id := Item_Id (Which);
            Is_Datum : constant Boolean := Kind_Of (Of_Unit, Id) = Datum;
            Blocks : constant Natural := Block_Count (Of_Unit, Id);
            Reached : array (1 .. Positive'Max (1, Blocks)) of Boolean :=
              [others => False];
         begin
            if Blocks = 0 then
               return (Kind => Item_Without_A_Block, Item => Id,
                       others => <>);
            end if;

            if Open_Block (Of_Unit, Id) /= No_Block then
               return (Kind => Item_Still_Building, Item => Id,
                       others => <>);
            end if;

            --  [1550]: block 1 is where an item starts, and every other
            --  block is reached from one before it.
            Reached (1) := True;

            for B in 1 .. Blocks loop
               declare
                  Block : constant Block_Id := Block_Id (B);
                  Last  : constant Natural := Length (Of_Unit, Id, Block);
               begin
                  if Last = 0 then
                     return (Kind => Empty_Block, Item => Id,
                             Block => Block, others => <>);
                  end if;

                  for Position in 1 .. Last loop
                     declare
                        V : constant Value_Id :=
                          Nth_Value (Of_Unit, Id, Block, Position);
                        Op : constant Opcode := Op_Of (Of_Unit, Id, V);
                        Ends : constant Boolean := Op in Terminator_Kind;
                     begin
                        if Ends and then Position /= Last then
                           return (Kind => Terminator_Inside_A_Block,
                                   Item => Id, Block => Block, Value => V);
                        end if;

                        if Position = Last and then not Ends then
                           return (Kind => Block_Without_A_Terminator,
                                   Item => Id, Block => Block, Value => V);
                        end if;

                        --  Step one: what a later step indexes.  A
                        --  callee, a slot, a datum or a target that does
                        --  not exist has to be caught before anything
                        --  asks it a question.
                        case Op is
                           when Load | Store =>
                              if not Holds
                                       (Of_Unit, Id,
                                        Slot_Of (Of_Unit, Id, V))
                              then
                                 return (Kind => Slot_Out_Of_Range,
                                         Item => Id, Block => Block,
                                         Value => V);
                              end if;

                           when Load_Field =>
                              declare
                                 D : constant Item_Id :=
                                   Datum_Of (Of_Unit, Id, V);
                              begin
                                 if not Holds (Of_Unit, D)
                                   or else Kind_Of (Of_Unit, D) /= Datum
                                 then
                                    return
                                      (Kind => Named_Item_Is_Not_A_Datum,
                                       Item => Id, Block => Block,
                                       Value => V);
                                 end if;

                                 --  [0750]: a struct has the fields it
                                 --  was declared with, so a selection of
                                 --  any other is an IR nobody may build.
                                 if Result_Of (Of_Unit, D)
                                    /= Landin.Types.Aggregate
                                   or else Field_Of (Of_Unit, Id, V)
                                           > Field_Count (Of_Unit, D)
                                 then
                                    return
                                      (Kind => Field_Out_Of_Range,
                                       Item => Id, Block => Block,
                                       Value => V);
                                 end if;

                                 if Result_Of (Of_Unit, Id, V)
                                    /= Nth_Field
                                         (Of_Unit, D,
                                          Field_Of (Of_Unit, Id, V))
                                 then
                                    return
                                      (Kind => Result_Disagrees,
                                       Item => Id, Block => Block,
                                       Value => V);
                                 end if;
                              end;

                           when Load_Datum | Store_Datum =>
                              declare
                                 D : constant Item_Id :=
                                   Datum_Of (Of_Unit, Id, V);
                              begin
                                 if not Holds (Of_Unit, D)
                                   or else Kind_Of (Of_Unit, D) /= Datum
                                 then
                                    return
                                      (Kind => Named_Item_Is_Not_A_Datum,
                                       Item => Id, Block => Block,
                                       Value => V);
                                 end if;

                                 --  [0670]'s state is storage and not a
                                 --  value yet: reading or writing the
                                 --  whole of one needs a rule for
                                 --  carrying it that R2.20 has not
                                 --  written, so the IR may not say it.
                                 if Result_Of (Of_Unit, D)
                                    = Landin.Types.Aggregate
                                 then
                                    return
                                      (Kind =>
                                         Aggregate_Datum_Is_Not_A_Value,
                                       Item => Id, Block => Block,
                                       Value => V);
                                 end if;
                              end;

                           when Call =>
                              --  [1940]: a module value is not a call.
                              if Is_Datum then
                                 return (Kind => Call_Inside_A_Datum,
                                         Item => Id, Block => Block,
                                         Value => V);
                              end if;

                              declare
                                 C : constant Item_Id :=
                                   Callee_Of (Of_Unit, Id, V);
                              begin
                                 if not Holds (Of_Unit, C)
                                   or else Kind_Of (Of_Unit, C) /= Routine
                                 then
                                    return
                                      (Kind => Callee_Is_Not_A_Routine,
                                       Item => Id, Block => Block,
                                       Value => V);
                                 end if;
                              end;

                           when Jump | Branch =>
                              --  A datum may branch.  [0410] makes the
                              --  logical words short-circuit and
                              --  Landin.IR has no opcode for them, and
                              --  [1940] admits an operator of [1820]
                              --  over literals -- so `k: bool = true and
                              --  false` is a legal module value whose
                              --  only lowering is blocks.  R1.70
                              --  considered folding it here instead and
                              --  refused: that is a second constant
                              --  folder beside the checker's, over the
                              --  whole of [1820] including the widths.
                              if not Holds
                                       (Of_Unit, Id,
                                        Target_Of (Of_Unit, Id, V))
                                or else (Op = Branch
                                         and then not Holds
                                                        (Of_Unit, Id,
                                                         Alternative_Of
                                                           (Of_Unit, Id,
                                                            V)))
                              then
                                 return (Kind => Target_Out_Of_Range,
                                         Item => Id, Block => Block,
                                         Value => V);
                              end if;

                              Reached
                                (Positive
                                   (Target_Of (Of_Unit, Id, V))) := True;

                              if Op = Branch then
                                 Reached
                                   (Positive
                                      (Alternative_Of
                                         (Of_Unit, Id, V))) := True;
                              end if;

                           when others =>
                              null;
                        end case;

                        --  Step two: how many operands.  [1820] decides
                        --  every opcode but two: a call takes what its
                        --  callee declares [1920], and a leave carries
                        --  what its item gives back, which is nothing
                        --  for `-> none` and nothing for [0670]'s state,
                        --  whose storage its fields describe.
                        declare
                           Expect : constant Natural :=
                             (case Op is
                                 when Call =>
                                    Parameter_Count
                                      (Of_Unit,
                                       Callee_Of (Of_Unit, Id, V)),
                                 when Leave =>
                                    (if Result_Of (Of_Unit, Id)
                                        in Landin.Types.Scalar_Name
                                     then 1 else 0),
                                 when others => Wanted (Op));
                        begin
                           if Operand_Count (Of_Unit, Id, V) /= Expect
                           then
                              return (Kind => Wrong_Operand_Count,
                                      Item => Id, Block => Block,
                                      Value => V);
                           end if;
                        end;

                        --  Step three: every operand names a value this
                        --  block already defined.  Block-local and above
                        --  the use, which is the invariant that lets one
                        --  comparison stand in for a dominance relation.
                        for Index in
                          1 .. Operand_Count (Of_Unit, Id, V)
                        loop
                           declare
                              Arg : constant Value_Id :=
                                Nth_Operand (Of_Unit, Id, V, Index);
                           begin
                              if not Holds (Of_Unit, Id, Arg) then
                                 return (Kind => Operand_Out_Of_Range,
                                         Item => Id, Block => Block,
                                         Value => V);
                              end if;

                              if Arg >= V then
                                 return
                                   (Kind => Operand_Not_Above_Its_Use,
                                    Item => Id, Block => Block,
                                    Value => V);
                              end if;

                              if Block_Of (Of_Unit, Id, Arg) /= Block then
                                 return (Kind => Operand_In_Another_Block,
                                         Item => Id, Block => Block,
                                         Value => V);
                              end if;

                              if Defines_Nothing
                                   (Op_Of (Of_Unit, Id, Arg))
                              then
                                 return (Kind => Operand_Defines_Nothing,
                                         Item => Id, Block => Block,
                                         Value => V);
                              end if;
                           end;
                        end loop;

                        --  Step four: the types [1890].
                        case Op is
                           when Binary_Kind =>
                              declare
                                 L : constant Value_Id :=
                                   Nth_Operand (Of_Unit, Id, V, 1);
                                 R : constant Value_Id :=
                                   Nth_Operand (Of_Unit, Id, V, 2);
                              begin
                                 if Result_Of (Of_Unit, Id, L)
                                    /= Result_Of (Of_Unit, Id, R)
                                 then
                                    return (Kind => Operands_Disagree,
                                            Item => Id, Block => Block,
                                            Value => V);
                                 end if;

                                 --  and that type back, or a bool from a
                                 --  comparison [0350].
                                 if Result_Of (Of_Unit, Id, V)
                                    /= (if Op in Comparison_Kind
                                        then Landin.Types.Bool
                                        else Result_Of (Of_Unit, Id, L))
                                 then
                                    return (Kind => Result_Disagrees,
                                            Item => Id, Block => Block,
                                            Value => V);
                                 end if;
                              end;

                           when Unary_Kind =>
                              if Result_Of (Of_Unit, Id, V)
                                 /= Result_Of
                                      (Of_Unit, Id,
                                       Nth_Operand (Of_Unit, Id, V, 1))
                              then
                                 return (Kind => Result_Disagrees,
                                         Item => Id, Block => Block,
                                         Value => V);
                              end if;

                           when Store =>
                              declare
                                 S : constant Slot_Id :=
                                   Slot_Of (Of_Unit, Id, V);
                              begin
                                 if Type_Of (Of_Unit, Id, S)
                                    /= Result_Of
                                         (Of_Unit, Id,
                                          Nth_Operand (Of_Unit, Id, V, 1))
                                 then
                                    return
                                      (Kind => Store_Disagrees_With_Slot,
                                       Item => Id, Block => Block,
                                       Value => V);
                                 end if;

                                 --  [1900]: a parameter may not be
                                 --  written, because the unmarked
                                 --  convention is [0900]'s `in`.
                                 for P in
                                   1 .. Parameter_Count (Of_Unit, Id)
                                 loop
                                    if Nth_Parameter (Of_Unit, Id, P) = S
                                    then
                                       return
                                         (Kind => Store_To_A_Parameter,
                                          Item => Id, Block => Block,
                                          Value => V);
                                    end if;
                                 end loop;
                              end;

                           when Store_Datum =>
                              if Result_Of
                                   (Of_Unit, Datum_Of (Of_Unit, Id, V))
                                 /= Result_Of
                                      (Of_Unit, Id,
                                       Nth_Operand (Of_Unit, Id, V, 1))
                              then
                                 return (Kind => Store_Datum_Disagrees,
                                         Item => Id, Block => Block,
                                         Value => V);
                              end if;

                           when Branch =>
                              if Result_Of
                                   (Of_Unit, Id,
                                    Nth_Operand (Of_Unit, Id, V, 1))
                                 /= Landin.Types.Bool
                              then
                                 return (Kind => Condition_Is_Not_A_Bool,
                                         Item => Id, Block => Block,
                                         Value => V);
                              end if;

                           when Call =>
                              declare
                                 C : constant Item_Id :=
                                   Callee_Of (Of_Unit, Id, V);
                              begin
                                 if Result_Of (Of_Unit, Id, V)
                                    /= Result_Of (Of_Unit, C)
                                 then
                                    return (Kind => Result_Disagrees,
                                            Item => Id, Block => Block,
                                            Value => V);
                                 end if;

                                 --  [1920]: each argument has its
                                 --  parameter's type, in order.
                                 for P in
                                   1 .. Parameter_Count (Of_Unit, C)
                                 loop
                                    if Type_Of
                                         (Of_Unit, C,
                                          Nth_Parameter (Of_Unit, C, P))
                                       /= Result_Of
                                            (Of_Unit, Id,
                                             Nth_Operand
                                               (Of_Unit, Id, V, P))
                                    then
                                       return (Kind => Operands_Disagree,
                                               Item => Id, Block => Block,
                                               Value => V);
                                    end if;
                                 end loop;
                              end;

                           when Leave =>
                              --  An aggregate item hands nothing back:
                              --  [0670]'s state is storage the fields
                              --  describe, and a value of one is not
                              --  lowered yet.  So only a scalar result is
                              --  a result a leave has to carry.
                              if Result_Of (Of_Unit, Id)
                                 in Landin.Types.Scalar_Name
                                and then Operand_Count (Of_Unit, Id, V) >= 1
                                and then Result_Of
                                           (Of_Unit, Id,
                                            Nth_Operand
                                              (Of_Unit, Id, V, 1))
                                         /= Result_Of (Of_Unit, Id)
                              then
                                 return
                                   (Kind => Leave_Disagrees_With_Item,
                                    Item => Id, Block => Block,
                                    Value => V);
                              end if;

                           when others =>
                              null;
                        end case;
                     end;
                  end loop;
               end;
            end loop;

            for B in 2 .. Blocks loop
               if not Reached (B) then
                  return (Kind => Block_Unreachable, Item => Id,
                          Block => Block_Id (B), others => <>);
               end if;
            end loop;
         end;
      end loop;

      return Sound;
   end Check;

   procedure Verify (Of_Unit : Unit) is
      Found : constant Fault := Check (Of_Unit);
   begin
      if Found.Kind /= Nothing_Wrong then
         raise Landin.Compiler_Defect with
           "malformed IR: " & Describe (Found.Kind)
           & " (item" & Found.Item'Image
           & ", block" & Found.Block'Image
           & ", value" & Found.Value'Image & ")";
      end if;
   end Verify;

end Landin.IR.Verifier;
