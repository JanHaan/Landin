with Landin.IR.Control_Flow;

package body Landin.IR.Rewriting is
   procedure Compact (Into : in out Unit; Keep : Keep_Array) is
      Code : Code_Vectors.Vector;
      Args : Value_Ref_Vectors.Vector;
      Blocks : Block_Vectors.Vector;
      Items : Item_Vectors.Vector := Into.Items;
   begin
      if Keep'First /= 1 or else Keep'Length /= Natural (Into.Code.Length)
      then
         raise Landin.Compiler_Defect with "invalid rewrite retention map";
      end if;
      for I in 1 .. Item_Count (Into) loop
         declare
            Item : constant Item_Id := Item_Id (I);
            Old : constant Item_Record := Into.Items (I);
            Held : Item_Record := Old;
            Graph : constant Control_Flow.Graph :=
              Control_Flow.Make (Into, Item);
            Block_Map : array (1 .. Old.Blocks.Count) of Block_Id :=
              [others => No_Block];
            Value_Map : array (1 .. Old.Values.Count) of Value_Id :=
              [others => No_Value];
         begin
            Held.Blocks := (First => Natural (Blocks.Length), Count => 0);
            Held.Values := (First => Natural (Code.Length), Count => 0);
            for B in Block_Map'Range loop
               if Control_Flow.Is_Reachable (Graph, Block_Id (B)) then
                  declare
                     Block : Block_Record := Into.Blocks
                       (Old.Blocks.First + B);
                  begin
                     Held.Blocks.Count := Held.Blocks.Count + 1;
                     Block_Map (B) := Block_Id (Held.Blocks.Count);
                     Block.First_Value := 0;
                     Block.Values := 0;
                     Blocks.Append (Block);
                  end;
               end if;
            end loop;
            for V in Value_Map'Range loop
               declare
                  Was : constant Instruction := Into.Code
                    (Old.Values.First + V);
                  Now : Instruction := Was;
               begin
                  if Block_Map (Positive (Was.In_Block)) /= No_Block
                    and then Keep (Old.Values.First + V)
                  then
                     Held.Values.Count := Held.Values.Count + 1;
                     Value_Map (V) := Value_Id (Held.Values.Count);
                     Now.In_Block := Block_Map (Positive (Was.In_Block));
                     Now.First_Arg := Natural (Args.Length);
                     for A in 1 .. Was.Args loop
                        declare
                           Before : constant Value_Id := Into.Operands
                             (Was.First_Arg + A);
                           After : constant Value_Id :=
                             Value_Map (Positive (Before));
                        begin
                           if After = No_Value then
                              raise Landin.Compiler_Defect with
                                "rewrite discarded a retained operand";
                           end if;
                           Args.Append (After);
                        end;
                     end loop;
                     if Was.Op in Jump | Branch then
                        Now.Target := Block_Map (Positive (Was.Target));
                        if Was.Op = Branch then
                           Now.Alternative :=
                             Block_Map (Positive (Was.Alternative));
                        end if;
                     end if;
                     declare
                        At_Block : constant Positive := Held.Blocks.First
                          + Positive (Now.In_Block);
                        Block : Block_Record := Blocks (At_Block);
                     begin
                        if Block.Values = 0 then
                           Block.First_Value := Natural (Code.Length);
                        end if;
                        Block.Values := Block.Values + 1;
                        Blocks.Replace_Element (At_Block, Block);
                     end;
                     Code.Append (Now);
                  end if;
               end;
            end loop;
            Items.Replace_Element (I, Held);
         end;
      end loop;
      Into.Items.Move (Items);
      Into.Code.Move (Code);
      Into.Operands.Move (Args);
      Into.Blocks.Move (Blocks);
   end Compact;
end Landin.IR.Rewriting;
