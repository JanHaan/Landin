with Ada.Unchecked_Deallocation;

with Landin.Syntax.Parser;

package body Landin.Syntax.Forest is

   use type Landin.Source.Names.Name_Id;

   procedure Free is new Ada.Unchecked_Deallocation (Tree, Tree_Access);

   overriding procedure Finalize (Owned : in out Held) is
   begin
      for Item of Owned.Items loop
         Free (Item);
      end loop;
      Owned.Items.Clear;
   end Finalize;

   function Count (Of_Forest : Table) return Natural
     is (Natural (Of_Forest.Owned.Items.Length));

   procedure Add
     (Into   : in out Table;
      From   : Landin.Tokens.Token_Stream;
      Names  : in out Landin.Source.Names.Table;
      Report : in out Landin.Diagnostics.Diagnostic_List)
   is
   begin
      --  The one allocator in the frontend.  The value is a function call
      --  because a limited object can be built nowhere else; the forest
      --  frees it, see the header.
      Into.Owned.Items.Append
        (new Tree'(Landin.Syntax.Parser.Parse (From, Names, Report)));
   end Add;

   procedure Transfer_Next (From : in out Table; Into : in out Table) is
      Index : constant Positive := Count (Into) + 1;
      Item  : constant Tree_Access := From.Owned.Items.Element (Index);
   begin
      if Item = null then
         raise Landin.Compiler_Defect with "syntax tree already transferred";
      end if;
      Into.Owned.Items.Append (Item);
      From.Owned.Items.Replace_Element (Index, null);
   end Transfer_Next;

   procedure Copy_Add
     (Into       : in out Table;
      From       : aliased Table;
      Id         : Landin.Source.Source_Id;
      From_Names : Landin.Source.Names.Table;
      Into_Names : in out Landin.Source.Names.Table)
   is
      Original : constant not null access constant Tree := From.Tree_Of (Id);
      Nodes    : Node_Vectors.Vector := Original.Items;
   begin
      for Position in 1 .. Natural (Nodes.Length) loop
         declare
            Item : Node := Nodes.Element (Position);
         begin
            if Item.Name /= Landin.Source.Names.No_Name then
               Item.Name := Landin.Source.Names.Intern
                 (Into_Names,
                  Landin.Source.Names.Spelling (From_Names, Item.Name));
               Nodes.Replace_Element (Position, Item);
            end if;
         end;
      end loop;
      Into.Owned.Items.Append
        (new Tree'(Source => Landin.Source.Source_Id (Count (Into) + 1),
                   Serial => Landin.Serials.Next,
                   Items  => Nodes,
                   Links  => Original.Links,
                   Signature_Links => Original.Signature_Links,
                   Import_Prefix_Length => Original.Import_Prefix_Length));
   end Copy_Add;

   function Tree_Of (Of_Forest : aliased Table; Id : Landin.Source.Source_Id)
     return not null access constant Tree
     is (Of_Forest.Owned.Items.Element (Positive (Id)));

end Landin.Syntax.Forest;
