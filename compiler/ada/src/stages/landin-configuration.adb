package body Landin.Configuration is

   use type Landin.Source.Source_Id;
   use type Landin.Syntax.Node_Id;
   use type Landin.Syntax.Node_Kind;

   procedure Prepare (Into : in out Table) is
   begin
      Into.Inactive.Clear;
   end Prepare;

   procedure Mark_Inactive
     (Into : in out Table;
      Source : Landin.Source.Source_Id;
      Node : Landin.Syntax.Node_Id) is
   begin
      Into.Inactive.Append
        (Inactive_Node'(Source => Source, Node => Node));
   end Mark_Inactive;

   function Is_Active
     (In_Table : Table;
      Source : Landin.Source.Source_Id;
      Node : Landin.Syntax.Node_Id) return Boolean is
   begin
      for Item of In_Table.Inactive loop
         if Item.Source = Source and then Item.Node = Node then
            return False;
         end if;
      end loop;
      return True;
   end Is_Active;

   procedure For_Each_Active_Declaration
     (In_Table : Table; Of_Tree : Landin.Syntax.Tree)
   is
      procedure Visit (Node : Landin.Syntax.Node_Id);

      procedure Visit (Node : Landin.Syntax.Node_Id) is
      begin
         if not Is_Active (In_Table, Landin.Syntax.Source_Of (Of_Tree), Node)
         then
            return;
         end if;

         if Landin.Syntax.Kind (Of_Tree, Node)
              = Landin.Syntax.Fixed_Conditional
         then
            for Arm in 1 .. Landin.Syntax.Fixed_Arm_Count (Of_Tree, Node)
            loop
               declare
                  This : constant Landin.Syntax.Node_Id :=
                    Landin.Syntax.Nth_Fixed_Arm (Of_Tree, Node, Arm);
               begin
                  for Which in 1 .. Landin.Syntax.Fixed_Declaration_Count
                    (Of_Tree, This)
                  loop
                     Visit (Landin.Syntax.Nth_Fixed_Declaration
                       (Of_Tree, This, Which));
                  end loop;
               end;
            end loop;
         else
            Action (Of_Tree, Node);
         end if;
      end Visit;
   begin
      for Position in 1 .. Landin.Syntax.Declaration_Count (Of_Tree) loop
         Visit (Landin.Syntax.Nth_Declaration (Of_Tree, Position));
      end loop;
   end For_Each_Active_Declaration;

end Landin.Configuration;
