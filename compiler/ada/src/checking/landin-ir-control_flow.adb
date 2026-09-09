package body Landin.IR.Control_Flow is

   function Make (Of_Unit : Unit; Item : Item_Id) return Graph is
      Count : constant Natural := Block_Count (Of_Unit, Item);
      Queue : Block_Array (1 .. Count);
      Read_At : Positive := 1;
      Used, Edges : Natural := 0;
   begin
      return Result : Graph (Count) do
         for B in 1 .. Count loop
            declare
               Block : constant Block_Id := Block_Id (B);
               Last : constant Value_Id := Nth_Value
                 (Of_Unit, Item, Block, Length (Of_Unit, Item, Block));
               Op : constant Opcode := Op_Of (Of_Unit, Item, Last);

               procedure Connect (Target : Block_Id);
               procedure Connect (Target : Block_Id) is
               begin
                  if Target = No_Block or else Natural (Target) > Count then
                     raise Landin.Compiler_Defect with
                       "control-flow adjacency requires checked targets";
                  end if;
                  Edges := Edges + 1;
                  Result.Edges ((Edges - 1) / 2 + 1)
                    ((Edges - 1) mod 2 + 1) :=
                    (Source => Block,
                     Next => Result.Incoming (Positive (Target)));
                  Result.Incoming (Positive (Target)) := Edges;
               end Connect;
            begin
               if Op in Jump | Branch then
                  Result.First (B) := Target_Of (Of_Unit, Item, Last);
                  Connect (Result.First (B));
                  if Op = Branch then
                     Result.Second (B) :=
                       Alternative_Of (Of_Unit, Item, Last);
                     Connect (Result.Second (B));
                  end if;
               end if;
            end;
         end loop;
         if Count > 0 then
            Used := 1;
            Queue (1) := Block_Id (1);
            Result.Live (1) := True;
         end if;
         while Read_At <= Used loop
            declare
               Block : constant Positive := Positive (Queue (Read_At));
            begin
               Read_At := Read_At + 1;
               Result.Nodes_Visited := Result.Nodes_Visited + 1;
               for Index in 1 .. 2 loop
                  declare
                     Target : constant Block_Id :=
                       (if Index = 1 then Result.First (Block)
                        else Result.Second (Block));
                  begin
                     if Target /= No_Block then
                        Result.Edges_Visited := Result.Edges_Visited + 1;
                        if not Result.Live (Positive (Target)) then
                           Result.Live (Positive (Target)) := True;
                           Used := Used + 1;
                           Queue (Used) := Target;
                        end if;
                     end if;
                  end;
               end loop;
            end;
         end loop;
      end return;
   end Make;

   function Is_Reachable (Of_Graph : Graph; Block : Block_Id) return Boolean
     is (Of_Graph.Live (Positive (Block)));

   function Successor
     (Of_Graph : Graph; Block : Block_Id; Index : Positive) return Block_Id
     is (if Index = 1 then Of_Graph.First (Positive (Block))
         elsif Index = 2 then Of_Graph.Second (Positive (Block))
         else No_Block);

   function First_Predecessor
     (Of_Graph : Graph; Block : Block_Id) return Natural
     is (Of_Graph.Incoming (Positive (Block)));

   function Next_Predecessor
     (Of_Graph : Graph; Edge : Positive) return Natural
     is (Of_Graph.Edges ((Edge - 1) / 2 + 1)
           ((Edge - 1) mod 2 + 1).Next);

   function Predecessor
     (Of_Graph : Graph; Edge : Positive) return Block_Id
     is (Of_Graph.Edges ((Edge - 1) / 2 + 1)
           ((Edge - 1) mod 2 + 1).Source);

   function Node_Visits (Of_Graph : Graph) return Natural
     is (Of_Graph.Nodes_Visited);

   function Edge_Visits (Of_Graph : Graph) return Natural
     is (Of_Graph.Edges_Visited);

end Landin.IR.Control_Flow;
