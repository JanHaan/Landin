package body Landin.Configuration is

   use type Landin.Source.Source_Id;
   use type Landin.Syntax.Node_Id;

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

end Landin.Configuration;
